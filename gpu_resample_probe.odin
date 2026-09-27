package main

// Headless GPU resample probe (VYPER_GPU_PROBE=1).
//
// De-risks the GPU export path in one shot, before any of it is wired into the
// compositor: create a GPU device with no window, upload a source image, draw a
// scaled quad so the hardware sampler filters it, read the render target back,
// and compare against the committed CPU kernel (yuv.rgba_resample).
//
// The CPU kernel is the reference on purpose. It is already gated against
// swscale per geometry in swsbench's kf_vs_swscale, so a mean_abs here that
// matches swsbench's numbers means the GPU path agrees with the thing we
// already trust, rather than agreeing with a fresh unvalidated expectation.
//
// Every failure mode returns ok=false with a printed reason and the caller
// falls back to the CPU path -- that is the same contract the export will use,
// so a driver without the needed capabilities degrades instead of failing.

import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:time"
import sdl "vendor:sdl3"
import yuv "vendor/yuv"

blit_vertex_spirv := #load("shaders/blit.vert.spv")

GPU_Resample_Probe :: struct {
	device:     ^sdl.GPUDevice,
	pipeline:   ^sdl.GPUGraphicsPipeline,
	sampler:    ^sdl.GPUSampler,
	src_tex:    ^sdl.GPUTexture,
	dst_tex:    ^sdl.GPUTexture,
	up_tb:      ^sdl.GPUTransferBuffer,
	up_cap:     int,
	down_tb:    ^sdl.GPUTransferBuffer,
	down_cap:   int,
	// The probe owns the SDL video subsystem init and the matching Quit, so the
	// export worker must do the same when it moves this code in.
	video_initialized: bool,
	src_w:      int,
	src_h:      int,
	dst_w:      int,
	dst_h:      int,
}

// gpu_resample_setup creates the device, pipeline, and fixed-size textures for
// one src->dst geometry. It allocates nothing per frame afterwards: the
// textures and transfer buffers are sized here and reused, because this runs
// inside the export loop and a per-frame texture create/release is a driver
// allocation on the hot path.
gpu_resample_setup :: proc(src_w, src_h, dst_w, dst_h: int) -> (p: GPU_Resample_Probe, ok: bool) {
	p.src_w, p.src_h, p.dst_w, p.dst_h = src_w, src_h, dst_w, dst_h

	// SDL3 refuses CreateGPUDevice with "Video subsystem not initialized" --
	// the GPU device is owned by the video subsystem even when no window or
	// surface is ever created. So the headless export path still needs this
	// one Init, and the export worker must own the matching Quit.
	if !sdl.Init(sdl.INIT_VIDEO) {
		fmt.println("gpu-probe: SDL_Init(VIDEO) failed:", sdl.GetError())
		return
	}
	p.video_initialized = true

	// The third argument is SDL_HINT_GPU_DRIVER's VALUE, not a device name --
	// passing a free-form string here makes SDL reject it as an unknown driver.
	// nil lets SDL pick the best available backend, which is the portable
	// choice; "vulkan" is the explicit retry when auto-selection finds nothing.
	p.device = sdl.CreateGPUDevice({.SPIRV}, false, nil)
	if p.device == nil {
		p.device = sdl.CreateGPUDevice({.SPIRV}, false, "vulkan")
	}
	if p.device == nil {
		fmt.println("gpu-probe: CreateGPUDevice failed:", sdl.GetError())
		return
	}
	// A sampler with linear min/mag filtering is the whole point: the hardware
	// does the resample. NEAREST here would make the probe measure a copy.
	p.sampler = sdl.CreateGPUSampler(p.device, sdl.GPUSamplerCreateInfo {
		min_filter = .LINEAR,
		mag_filter = .LINEAR,
		mipmap_mode = .NEAREST,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
	})
	if p.sampler == nil {
		fmt.println("gpu-probe: CreateGPUSampler failed:", sdl.GetError())
		ok = false
		return
	}

	vtx := sdl.GPUShaderCreateInfo {
		code_size       = uint(len(blit_vertex_spirv)),
		code            = raw_data(blit_vertex_spirv),
		entrypoint      = "main",
		format          = {.SPIRV},
		stage           = .VERTEX,
		num_uniform_buffers = 1,
	}
	frag := sdl.GPUShaderCreateInfo {
		code_size       = uint(len(preview_fragment_spirv)),
		code            = raw_data(preview_fragment_spirv),
		entrypoint      = "main",
		format          = {.SPIRV},
		stage           = .FRAGMENT,
		num_samplers    = 1,
	}
	vs := sdl.CreateGPUShader(p.device, vtx)
	fs := sdl.CreateGPUShader(p.device, frag)
	if vs == nil || fs == nil {
		fmt.println("gpu-probe: CreateGPUShader failed:", sdl.GetError())
		if vs != nil {
			sdl.ReleaseGPUShader(p.device, vs)
		}
		if fs != nil {
			sdl.ReleaseGPUShader(p.device, fs)
		}
		ok = false
		return
	}
	// No blend: the export's video layer is an opaque copy (render_blit_region
	// uses copy, not blend), so a blending pipeline would be testing behavior
	// the compositor does not use.
	target := sdl.GPUColorTargetDescription {
		format = .R8G8B8A8_UNORM,
		blend_state = {enable_blend = false},
	}
	pipeline := sdl.CreateGPUGraphicsPipeline(p.device, sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader   = vs,
		fragment_shader = fs,
		primitive_type  = .TRIANGLELIST,
		rasterizer_state = {
			fill_mode = .FILL, cull_mode = .NONE,
			front_face = .COUNTER_CLOCKWISE, enable_depth_clip = true,
		},
		multisample_state = {sample_count = ._1},
		target_info = {color_target_descriptions = &target, num_color_targets = 1},
	})
	sdl.ReleaseGPUShader(p.device, vs)
	sdl.ReleaseGPUShader(p.device, fs)
	if pipeline == nil {
		fmt.println("gpu-probe: CreateGPUGraphicsPipeline failed:", sdl.GetError())
		ok = false
		return
	}
	p.pipeline = pipeline

	p.src_tex = sdl.CreateGPUTexture(
		p.device,
		sdl.GPUTextureCreateInfo {
			type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER},
			width = u32(src_w), height = u32(src_h), layer_count_or_depth = 1,
			num_levels = 1, sample_count = ._1,
		},
	)
	p.dst_tex = sdl.CreateGPUTexture(
		p.device,
		sdl.GPUTextureCreateInfo {
			type = .D2, format = .R8G8B8A8_UNORM, usage = {.COLOR_TARGET},
			width = u32(dst_w), height = u32(dst_h), layer_count_or_depth = 1,
			num_levels = 1, sample_count = ._1,
		},
	)
	if p.src_tex == nil || p.dst_tex == nil {
		fmt.println("gpu-probe: CreateGPUTexture failed:", sdl.GetError())
		ok = false
		return
	}
	ok = true
	return
}

gpu_resample_teardown :: proc(p: ^GPU_Resample_Probe) {
	if p.device == nil {
		return
	}
	if p.up_tb != nil {
		sdl.ReleaseGPUTransferBuffer(p.device, p.up_tb)
	}
	if p.down_tb != nil {
		sdl.ReleaseGPUTransferBuffer(p.device, p.down_tb)
	}
	if p.src_tex != nil {
		sdl.ReleaseGPUTexture(p.device, p.src_tex)
	}
	if p.dst_tex != nil {
		sdl.ReleaseGPUTexture(p.device, p.dst_tex)
	}
	if p.pipeline != nil {
		sdl.ReleaseGPUGraphicsPipeline(p.device, p.pipeline)
	}
	if p.sampler != nil {
		sdl.ReleaseGPUSampler(p.device, p.sampler)
	}
	sdl.DestroyGPUDevice(p.device)
	p.device = nil
	if p.video_initialized {
		sdl.Quit()
		p.video_initialized = false
	}
}

// transfer_of returns a transfer buffer of at least `size`, reusing *tb when it
// already fits. Same growth policy as the preview path's gpu_upload_tb.
transfer_of :: proc(
	device: ^sdl.GPUDevice,
	tb: ^^sdl.GPUTransferBuffer,
	capacity: ^int,
	size: int,
	usage: sdl.GPUTransferBufferUsage,
) -> ^sdl.GPUTransferBuffer {
	if tb^ != nil && capacity^ >= size {
		return tb^
	}
	if tb^ != nil {
		sdl.ReleaseGPUTransferBuffer(device, tb^)
		tb^ = nil
	}
	tb^ = sdl.CreateGPUTransferBuffer(device, sdl.GPUTransferBufferCreateInfo {
		usage = usage,
		size  = u32(size),
	})
	if tb^ == nil {
		capacity^ = 0
		return nil
	}
	capacity^ = size
	return tb^
}

// gpu_resample_run uploads `src` (src_w*src_h*4, stride src_stride) once, then
// draws it scaled into the render target and reads the result back into `out`
// (dst_w*dst_h*4). Returns false if any step fails, which is the caller's cue
// to fall back to the CPU kernel.
gpu_resample_run :: proc(p: ^GPU_Resample_Probe, src: []u8, src_stride: int, out: []u8) -> bool {
	device := p.device
	src_bytes := p.src_w * p.src_h * 4
	dst_bytes := p.dst_w * p.dst_h * 4

	up := transfer_of(device, &p.up_tb, &p.up_cap, src_bytes, .UPLOAD)
	if up == nil {
		return false
	}
	mapped := sdl.MapGPUTransferBuffer(device, up, true)
	if mapped == nil {
		return false
	}
	// Tight rows: SDL3's transfer info is in texels, so the CPU side must be
	// packed to dst_w*4 with no stride slack. The source has one, so pack it.
	row_bytes := p.src_w * 4
	flat := ([^]u8)(mapped)[:]
	for y in 0 ..< p.src_h {
		copy(flat[y * row_bytes:(y + 1) * row_bytes], src[y * src_stride:y * src_stride + row_bytes])
	}
	sdl.UnmapGPUTransferBuffer(device, up)

	down := transfer_of(device, &p.down_tb, &p.down_cap, dst_bytes, .DOWNLOAD)
	if down == nil {
		return false
	}

	cb := sdl.AcquireGPUCommandBuffer(device)
	if cb == nil {
		return false
	}
	// Upload the source.
	cp := sdl.BeginGPUCopyPass(cb)
	sdl.UploadToGPUTexture(
		cp,
		sdl.GPUTextureTransferInfo {
			transfer_buffer = up, pixels_per_row = u32(p.src_w), rows_per_layer = u32(p.src_h),
		},
		sdl.GPUTextureRegion {texture = p.src_tex, w = u32(p.src_w), h = u32(p.src_h), d = 1},
		false,
	)
	sdl.EndGPUCopyPass(cp)

	// Draw the scaled quad. Sampling the FULL source rect across the dst rect
	// is what makes the hardware filter, and it is the geometry the keyed path
	// needs: the animated box is a centered sub-rect of the max-scale stage.
	// Half-texel inset keeps the 1:1 case exact (see below).
	color_target := sdl.GPUColorTargetInfo {
		texture     = p.dst_tex,
		load_op     = .CLEAR,
		store_op    = .STORE,
		clear_color = {0, 0, 0, 1},
	}
	pass := sdl.BeginGPURenderPass(cb, &color_target, 1, nil)
	if pass == nil {
		_ = sdl.CancelGPUCommandBuffer(cb)
		return false
	}
	vp := sdl.GPUViewport{x = 0, y = 0, w = f32(p.dst_w), h = f32(p.dst_h), min_depth = 0.0, max_depth = 1.0}
	sdl.SetGPUViewport(pass, vp)
	sdl.BindGPUGraphicsPipeline(pass, p.pipeline)
	binding := sdl.GPUTextureSamplerBinding{texture = p.src_tex, sampler = p.sampler}
	sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
	u := struct {
		dst_rect: [4]f32,
		src_rect: [4]f32,
		viewport: [2]f32,
	}{
		dst_rect = {0, 0, f32(p.dst_w), f32(p.dst_h)},
		// The EXACT source rect, with no half-texel inset. Destination pixel
		// center p lands at corner p/dst_w, so uv = p/src_w, and a 1:1 draw
		// samples every texel center exactly. Insetting the endpoints by half a
		// texel (the reflex when porting a GL blit) shifts the whole image by
		// half a texel -- caught by the 1:1 exactness gate below, which is
		// exactly why that gate exists.
		src_rect = {0.0, 0.0, 1.0, 1.0},
		viewport = {f32(p.dst_w), f32(p.dst_h)},
	}
	sdl.PushGPUVertexUniformData(cb, 0, &u, u32(size_of(u)))
	sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
	sdl.EndGPURenderPass(pass)

	// Read the render target back.
	cp2 := sdl.BeginGPUCopyPass(cb)
	sdl.DownloadFromGPUTexture(
		cp2,
		sdl.GPUTextureRegion {texture = p.dst_tex, w = u32(p.dst_w), h = u32(p.dst_h), d = 1},
		sdl.GPUTextureTransferInfo {
			transfer_buffer = down, pixels_per_row = u32(p.dst_w), rows_per_layer = u32(p.dst_h),
		},
	)
	sdl.EndGPUCopyPass(cp2)
	if !sdl.SubmitGPUCommandBuffer(cb) {
		fmt.println("gpu-probe: SubmitGPUCommandBuffer failed:", sdl.GetError())
		return false
	}
	// Submit + idle + map is the sync point. The probe is not pipelining, and
	// neither can the export's first GPU stage without a second command buffer
	// in flight -- noted here, not silently assumed.
	if !sdl.WaitForGPUIdle(device) {
		fmt.println("gpu-probe: WaitForGPUIdle failed:", sdl.GetError())
		return false
	}
	back := sdl.MapGPUTransferBuffer(device, down, true)
	if back == nil {
		return false
	}
	copy(out, ([^]u8)(back)[:dst_bytes])
	sdl.UnmapGPUTransferBuffer(device, down)
	return true
}

// GPU_Probe_Fixture names a source pattern. The two exist because they fail in
// OPPOSITE directions, and a probe with only one of them cannot catch a
// regression in the other:
//
//   - smooth: band-limited low-frequency sines. Downscale error is near zero for
//     ANY filter, so this row passes even if the sampler aliases badly. Good for
//     catching an outright wrong blit (a flip, a half-texel shift, a bad rect).
//   - hifreq: per-pixel checkerboard, 1px vertical rules, and hash noise. A
//     single point-sampled bilinear fetch aliases this hard under minification,
//     so this is the row that decides whether the hardware filter is good enough
//     as the export default or needs a footprint/mipmap path.
//
// A probe with only the smooth fixture would have reported the 3x downscale as
// excellent (mean 0.05) while hiding the one failure mode that matters.
GPU_Probe_Fixture :: enum { SMOOTH, HIFREQ }

// GPU_Probe_Expect says what a case's diff is allowed to mean. Kept in the data
// rather than in a comment so the verdict logic and the printed label cannot
// drift apart.
GPU_Probe_Expect :: enum {
	// Asserted. A violation is a real bug: geometry, sampler, or a filtering
	// regression in a range where we claim hardware filtering is adequate.
	GATED,
	// Reported only. Nyquist-rate content is unrepresentable in the output
	// raster, so two correct resamplers disagree by phase; asserting it would
	// demand one filter's half-texel convention, not quality.
	NYQUIST,
	// Reported only, and a known-open gap. Single-tap hardware filtering
	// aliases when minifying high-frequency content; a footprint kernel is the
	// fix. This flips to GATED when that kernel lands, so the number stops
	// being a report and becomes a regression gate. See TODO.md Active 4.
	OPEN_ALIASING,
}

// gpu_probe_source builds a test image for `fixture` at the given size.
gpu_probe_source :: proc(w, h: int, fixture: GPU_Probe_Fixture) -> []u8 {
	src := make([]u8, w * h * 4)
	for y in 0 ..< h {
		for x in 0 ..< w {
			r, g, b: f64 = 0, 0, 0
			if fixture == .SMOOTH {
				lum := 110.0 +
					70.0 * math.sin(f64(x) / 37.0) * math.cos(f64(y) / 29.0) +
					25.0 * math.sin(f64(x + y) / 11.0)
				r, g, b = lum + 18.0, lum, lum - 21.0
			} else {
				// Checkerboard at pixel frequency, 1px bright rules every 16px,
				// plus a hash so there is no structure left to alias smoothly.
				hash := f64((u32(x) * 2654435761 + u32(y) * 40503) % 251)
				rule := x % 16 == 0
				rule_y := y % 16 == 0
				lum := 40.0 + hash
				if (x + y) % 2 == 0 {
					lum = 215.0 - hash
				}
				if rule || rule_y {
					lum = 255.0
				}
				r, g, b = lum, lum * 0.85, clamp(lum * 0.7, 0.0, 255.0)
			}
			off := (y * w + x) * 4
			src[off + 0] = u8(clamp(r, 0.0, 255.0))
			src[off + 1] = u8(clamp(g, 0.0, 255.0))
			src[off + 2] = u8(clamp(b, 0.0, 255.0))
			src[off + 3] = 255
		}
	}
	return src
}

gpu_resample_probe_run :: proc() -> int {
	SW, SH :: 1600, 900

	// The geometries that matter: the keyed near-1:1 case, a plain downscale,
	// a magnification, and a heavy 3x downscale. 1:1 is the correctness anchor
	// -- a filtered sampler MUST reproduce the source there.
	GPU_Probe_Case :: struct {
		src_w,   src_h, dst_w, dst_h: int,
		fixture: GPU_Probe_Fixture,
		// mean/max tolerance vs the CPU kernel. SMOOTH is near-exact and catches
		// geometry bugs; HIFREQ downscales get a real filtering budget.
		max_mean, max_peak: f64,
		expect:   GPU_Probe_Expect,
	}
	cases := [8]GPU_Probe_Case {
		{SW, SH, SW, SH, .SMOOTH, 0.0, 0.0, .GATED},
		{SW, SH, SW, SH, .HIFREQ, 0.0, 0.0, .GATED},
		{SW, SH, 800, 450, .SMOOTH, 1.0, 2.0, .GATED},
		{SW, SH, 800, 450, .HIFREQ, 6.0, 24.0, .GATED},
		{800, 450, SW, SH, .SMOOTH, 2.0, 8.0, .GATED},
		{800, 450, SW, SH, .HIFREQ, 0.0, 0.0, .NYQUIST},
		{5760, 3240, 1920, 1080, .SMOOTH, 1.0, 2.0, .GATED},
		{5760, 3240, 1920, 1080, .HIFREQ, 8.0, 32.0, .OPEN_ALIASING},
	}

	ITERS :: 8
	failed := false
	for c in cases {
		// A per-case source at the case's own size: 5760x3240x4 is 75 MB and
		// does not belong in a shared 1600x900 buffer.
		case_src := gpu_probe_source(c.src_w, c.src_h, c.fixture)
		defer delete(case_src)

		p, ok := gpu_resample_setup(c.src_w, c.src_h, c.dst_w, c.dst_h)
		if !ok {
			fmt.println("gpu-probe: setup failed, falling back to CPU (this is the supported path)")
			gpu_resample_teardown(&p)
			continue
		}

		got := make([]u8, c.dst_w * c.dst_h * 4)
		defer delete(got)
		want := make([]u8, c.dst_w * c.dst_h * 4)
		defer delete(want)
		yuv.rgba_resample(
			raw_data(case_src), c.src_w * 4, 0, 0, c.src_w, c.src_h,
			raw_data(want), c.dst_w * 4, c.dst_w, c.dst_h,
		)

		if !gpu_resample_run(&p, case_src, c.src_w * 4, got) {
			fmt.println("gpu-probe: run failed, falling back to CPU")
			gpu_resample_teardown(&p)
			continue
		}
		t0 := time.tick_now()
		for _ in 0 ..< ITERS {
			gpu_resample_run(&p, case_src, c.src_w * 4, got)
		}
		gpu_ms := f64(time.tick_since(t0)) / 1e6 / f64(ITERS)

		t1 := time.tick_now()
		for _ in 0 ..< ITERS {
			yuv.rgba_resample(
				raw_data(case_src), c.src_w * 4, 0, 0, c.src_w, c.src_h,
				raw_data(want), c.dst_w * 4, c.dst_w, c.dst_h,
			)
		}
		cpu_ms := f64(time.tick_since(t1)) / 1e6 / f64(ITERS)

		sum: i64 = 0
		peak := 0
		for k in 0 ..< c.dst_w * c.dst_h * 4 {
			d := int(got[k]) - int(want[k])
			if d < 0 {
				d = -d
			}
			sum += i64(d)
			if d > peak {
				peak = d
			}
		}
		mean := f64(sum) / f64(c.dst_w * c.dst_h * 4)
		verdict := "ok"
		switch c.expect {
		case .GATED:
			if mean > c.max_mean || f64(peak) > c.max_peak {
				verdict = "FAIL"
				failed = true
			}
		case .NYQUIST:
			verdict = "info (Nyquist)"
		case .OPEN_ALIASING:
			// Report the gap loudly, but do not fail the build on a defect that
			// is not shipped yet -- the GPU blit is not the default path, the
			// CPU kernel is. When the footprint kernel lands this becomes
			// .GATED and the same number turns into a regression gate.
			verdict = fmt.tprintf("open (needs footprint, budget %.0f/%.0f)", c.max_mean, c.max_peak)
		}
		fmt.printf(
			"  %-7s %-21s gpu=%8.3f ms cpu=%8.3f ms %6.2fx mean=%5.2f peak=%3d  %s\n",
			fmt.tprintf("%v", c.fixture),
			fmt.tprintf("%dx%d->%dx%d", c.src_w, c.src_h, c.dst_w, c.dst_h),
			gpu_ms, cpu_ms, cpu_ms / max(gpu_ms, 0.0001), mean, peak, verdict,
		)
		gpu_resample_teardown(&p)
	}

	if failed {
		return 1
	}
	fmt.println("gpu-probe: ok (headless offscreen resample matches the CPU kernel on gated rows)")
	return 0
}
