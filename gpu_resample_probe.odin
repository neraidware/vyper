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
import "core:os"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
import yuv "vendor/yuv"

blit_lod_fragment_spirv := #load("shaders/blit_lod.frag.spv")
blit_box_fragment_spirv := #load("shaders/blit_box.frag.spv")

// adapter_announced keeps the driver banner to one line per probe run; setup
// runs once per geometry.
adapter_announced := false

// mip_status_announced keeps the mip-generation result to one line per run.
mip_status_announced := false

// Substrings that mark a device as a CPU rasterizer rather than a GPU. The
// driver name cannot be used for this: llvmpipe reports backend "vulkan", the
// same string a real RADV/Intel/NVIDIA adapter reports. Matching the device
// name is the only reliable signal, so the list lives at file scope rather than
// being rebuilt on every setup.
SOFTWARE_RASTERIZER_NAMES :: [5]string{"llvmpipe", "lavapipe", "softpipe", "swiftshader", "warp"}

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
// mip_levels returns the full mip-chain length for a w x h texture: 1 for a
// 1x1, 2 for 2x2, and so on down the largest axis.
mip_levels :: proc(w, h: int) -> u32 {
	n := w
	if h > n {
		n = h
	}
	levels: u32 = 1
	for m := n; m > 1; m >>= 1 {
		levels += 1
	}
	return levels
}

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
	// Announced once, on the first device that actually exists.
	//
	// The DRIVER name cannot tell you whether you are on hardware: a software
	// Vulkan rasterizer also reports "vulkan", so a green probe run is not
	// evidence a GPU did the work. Only the device NAME can, and it is the one
	// piece of information that cost us two wrong conclusions. A green run was
	// read as hardware while the loader was in fact handing SDL3 llvmpipe, and
	// the cause was a stale binary carrying a different Vulkan loader and ICD
	// search path -- not a missing GPU, and not RADV_PERFTEST, which was the
	// second wrong guess and is not needed. So the name is printed on every run
	// and a software rasterizer is called out loudly rather than left for the
	// next person to rediscover.
	adapter := sdl.GetGPUDeviceDriver(p.device)
	device_name := string(
		sdl.GetStringProperty(
			sdl.GetGPUDeviceProperties(p.device),
			"SDL.gpu.device.name",
			"<unknown>",
		),
	)
	driver_info := string(
		sdl.GetStringProperty(
			sdl.GetGPUDeviceProperties(p.device),
			"SDL.gpu.device.driver_info",
			"<unknown>",
		),
	)
	// A software rasterizer on an export path is a silent, enormous slowdown,
	// not a cosmetic detail, so it is reported as a failure. Software fallback
	// for the *export* itself is a legitimate contract, but it must never be
	// mistaken for a GPU measurement.
	software := false
	for token in SOFTWARE_RASTERIZER_NAMES {
		if strings.contains(device_name, token) || strings.contains(driver_info, token) {
			software = true
		}
	}
	if !adapter_announced {
		adapter_announced = true
		fmt.println("gpu-probe: adapter =", device_name, "| backend =", adapter)
		fmt.println("gpu-probe: driver  =", driver_info)
	}
	if software {
		// A software rasterizer is what a stale or differently-linked binary
		// looks like: same source, same flags on paper, different loader, and
		// the GPU silently replaced. Rebuild before believing this.
		fmt.println(
			"gpu-probe: WARNING SOFTWARE RASTERIZER -- no GPU did this work;",
			"these numbers are not a GPU measurement.",
		)
		fmt.println(
			"gpu-probe: if a GPU is present, rebuild before concluding anything --",
			"a stale binary loads a different Vulkan ICD set and gets llvmpipe.",
		)
	}
	// A sampler with linear min/mag filtering is the whole point: the hardware
	// does the resample. NEAREST here would make the probe measure a copy.
	// min_filter/mag_filter LINEAR plus mipmap_mode LINEAR is what makes this a
	// RESAMPLE rather than a copy. The LOD is left automatic: the quad's
	// texcoord derivative is exactly 1/scale for an axis-aligned blit, so the
	// hardware picks log2(minification) itself -- LOD 0 when magnifying, and a
	// prefiltered level when shrinking. mipmap_mode .NEAREST would snap to one
	// level and alias against the neighbouring one.
	// VYPER_GPU_MIP_BIAS forces a LOD offset on the sampler. It exists to
	// answer one question the timings cannot: is the LOD path live at all? A
	// bias shifts every lookup off level 0, so the output IMAGE must change
	// if mip levels are being generated and read. If a large bias leaves the
	// pixels bit-identical, then nothing downstream of the sampler is
	// selecting a level, and the cause is the mip chain or the bind, not the
	// hardware. This is the difference between "llvmpipe cannot do mips" and
	// "our blit ignores them", and guessing between them is what wasted the
	// first two conclusions about this machine.
	// The sampler is deliberately plain. Everything the minification fix needed
	// was measured here and none of it moved a pixel: a mip chain generates
	// successfully (11 levels, no SDL error), a hardcoded textureLod(3.0) still
	// returns level-0 data, a sampler mip_lod_bias of 4 and 8 changed nothing at
	// all, and 16x anisotropy was bit-identical to 1x. This driver clamps every
	// lookup to level 0, so anything relying on sampler LOD or anisotropy
	// silently degrades to a point sample. The filtering therefore lives in the
	// fragment shader (blit_box.frag), which is driver-independent, and the
	// sampler is left in the state that magnification needs. Keep PIN_LOD as the
	// standing check for whether a future driver does honour mips.
	p.sampler = sdl.CreateGPUSampler(p.device, sdl.GPUSamplerCreateInfo {
		min_filter   = .LINEAR,
		mag_filter   = .LINEAR,
		mipmap_mode  = .LINEAR,
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
		code_size       = uint(len(quad_vertex_spirv)),
		code            = raw_data(quad_vertex_spirv),
		entrypoint      = "main",
		format          = {.SPIRV},
		stage           = .VERTEX,
		num_uniform_buffers = 1,
	}
	// The box-average shader is the implementation, not an experiment: it is
	// what the export path should use and what every number below describes.
	// One tap per covered source texel, which is exactly what the CPU kernel
	// walks, so the two agree to mean 0.02 on the high-frequency 3x case that
	// plain bilinear scored 39.94 on.
	//
	// VYPER_GPU_PIN_LOD swaps in a shader that hardcodes LOD 3. It is the
	// standing test for whether this driver ever honours a mip level, and it
	// exists because that answer is the reason the filtering is in the shader:
	// every sampler-side mechanism measured inert here.
	frag_code := blit_box_fragment_spirv
	if _, pin_lod := os.lookup_env_alloc("VYPER_GPU_PIN_LOD", context.temp_allocator); pin_lod {
		frag_code = blit_lod_fragment_spirv
		fmt.println("gpu-probe: PINNED LOD 3 (diagnostic; mip chain content test)")
	}
	frag := sdl.GPUShaderCreateInfo {
		code_size       = uint(len(frag_code)),
		code            = raw_data(frag_code),
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
			// A full mip chain is the anti-aliasing: the hardware blends two
			// prefiltered levels when the derivative lands between them, which is
			// what stops a shrunk sample of high-frequency content from keeping
			// contrast the output cannot represent.
			type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER},
			width = u32(src_w), height = u32(src_h), layer_count_or_depth = 1,
			num_levels = mip_levels(src_w, src_h), sample_count = ._1,
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
gpu_blit_run :: proc(p: ^GPU_Resample_Probe, src: []u8, src_stride: int, out: []u8) -> bool {
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

	// The mip chain is only anti-aliasing if it is actually filled. Without this
	// the higher levels are whatever the driver left there, and sampling LOD>0
	// blends that in -- which showed up as the image getting DARKER than the
	// reference at every pixel, not as an obvious failure.
	levels := mip_levels(p.src_w, p.src_h)
	sdl.GenerateMipmapsForGPUTexture(cb, p.src_tex)
	// The Odin binding drops this function's bool return, but SDL records a
	// failure in the error slot, and a silent mipmap failure is exactly the bug
	// being chased: a chain that was never filled leaves a sampler with nothing
	// to select, so LOD clamps to 0 and anisotropy silently disables itself.
	// Both symptoms look like "the GPU ignores my sampler state".
	if mip_err := sdl.GetError(); mip_err != nil && len(mip_err) > 0 {
		fmt.println(
			"gpu-probe: GenerateMipmaps FAILED (levels requested =", levels, "):",
			mip_err,
		)
	} else if !mip_status_announced {
		mip_status_announced = true
		fmt.println("gpu-probe: mip levels requested =", levels, "mipmaps ok")
	}

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
	// The shared quad uniform, NOT an inline literal: the byte order has to
	// match shaders/quad.vert, and an anonymous struct here is exactly how the
	// fields silently land in the wrong place when the vertex stage changes.
	u := Quad_Uniforms {
		bounds = {0, 0, f32(p.dst_w), f32(p.dst_h)},
		// The EXACT source rect, with no half-texel inset. Destination pixel
		// center p lands at corner p/dst_w, so uv = p/src_w, and a 1:1 draw
		// samples every texel center exactly. Insetting the endpoints by half a
		// texel (the reflex when porting a GL blit) shifts the whole image by
		// half a texel -- caught by the 1:1 exactness gate below, which is
		// exactly why that gate exists.
		uv       = {0.0, 0.0, 1.0, 1.0},
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
		{5760, 3240, 1920, 1080, .HIFREQ, 8.0, 32.0, .GATED},
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

		if !gpu_blit_run(&p, case_src, c.src_w * 4, got) {
			fmt.println("gpu-probe: run failed, falling back to CPU")
			gpu_resample_teardown(&p)
			continue
		}
		t0 := time.tick_now()
		for _ in 0 ..< ITERS {
			gpu_blit_run(&p, case_src, c.src_w * 4, got)
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
		}
		fmt.printf(
			"  %-7s %-21s gpu=%8.3f ms cpu=%8.3f ms %6.2fx mean=%5.2f peak=%3d  %s\n",
			fmt.tprintf("%v", c.fixture),
			fmt.tprintf("%dx%d->%dx%d", c.src_w, c.src_h, c.dst_w, c.dst_h),
			gpu_ms, cpu_ms, cpu_ms / max(gpu_ms, 0.0001), mean, peak, verdict,
		)
		if verdict == "FAIL" {
			// "mean 39" could be all-black, channel-shifted, or flipped, and
			// those are different bugs. Guessing between them is how a plumbing
			// mistake survives as a tuning problem.
		// Sample the actual bytes on a failure: "mean 145" could be all-black,
		// channel-swapped, or shifted by a row, and those are different bugs.
		// Guessing between them is how a plumbing mistake survives as a "tuning"
		// problem.
		{
			w, hh := c.dst_w, c.dst_h
			pts := [4][2]int{{0, 0}, {w / 2, hh / 2}, {w - 1, hh - 1}, {w / 3, hh / 4}}
			for pt in pts {
				o := (pt[1] * w + pt[0]) * 4
				fmt.printf(
					"        at (%4d,%4d) gpu=%3d,%3d,%3d,%3d cpu=%3d,%3d,%3d,%3d\n",
					pt[0], pt[1],
					got[o], got[o + 1], got[o + 2], got[o + 3],
					want[o], want[o + 1], want[o + 2], want[o + 3],
				)
			}
		}

		}
		gpu_resample_teardown(&p)
	}

	if failed {
		return 1
	}
	fmt.println("gpu-probe: ok (headless offscreen resample matches the CPU kernel on gated rows)")
	return 0
}
