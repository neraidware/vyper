package main

// GPU resample for the keyed export path.
//
// This replaces exactly one call in render_eval_keyed_geom -- the
// yuvconv.rgba_resample that produces v.kres_scratch -- and nothing else. The
// existing render_blit_region copy, the z-order, and the off-canvas clipping are
// untouched, so the GPU and CPU paths are interchangeable byte-for-byte at the
// seam and the CPU kernel remains a drop-in fallback.
//
// Why it is shaped this way, since the obvious alternative was rejected: keyed
// and static clips interleave in z-order inside one loop, so keyed draws cannot
// be batched into a single pass "on top" -- a static clip that sits above a
// keyed one has to be composited after it. Reading each keyed rect back before
// the next CPU clip draws is what keeps the order exact. The cost is one
// readback per keyed clip, which is the thing the direct NV12 hand-off removes
// later; until then this trades a CPU resample for a GPU draw plus a readback,
// and the resample is the expensive half (13.5 ms/frame against 5.9 ms for
// encode at 1080p).
//
// The filtering is shaders/blit_box.frag -- one texelFetch per covered source
// texel, matching the CPU kernel's footprint walk. It is in the shader rather
// than the sampler because this driver clamps every lookup to mip level 0: a
// generated mip chain plus a hardcoded textureLod(3.0) still returns level-0
// data, and 16x anisotropy was bit-identical to 1x. See TODO.md Active 4.

import "core:fmt"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
import yuvconv "vendor/yuv"

// The SPV blobs are #load-ed once in gpu_renderer.odin next to the other
// stages; sharing them keeps one copy in the binary and one place that can go
// stale. quad_vertex_spirv and blit_box_fragment_spirv are the SAME pair the
// preview pipeline binds, so the two paths cannot drift apart on filtering.

GPU_Resample :: struct {
	device:   ^sdl.GPUDevice,
	pipeline: ^sdl.GPUGraphicsPipeline,
	sampler:  ^sdl.GPUSampler,

	// stage is the uploaded source frame. The TEXTURE is reused across frames
	// so the hot path never re-creates a driver object, but the PIXELS are
	// re-uploaded every call.
	//
	// This used to skip the upload when the source address and size matched
	// the previous call. Measured: 90 uploads, 0 hits over a 90-frame keyed
	// export, because the compositor's blit slots are a two-slot ring
	// (frame_idx & 1) whose buffers are re-pointed per frame, so the key never
	// repeated. It bought nothing and it was one addressing change away from
	// serving a stale frame, so it is gone rather than kept as a comment.
	stage:       ^sdl.GPUTexture,
	stage_w:     int,
	stage_h:     int,

	// dst is the render target, grown to the largest rect seen and reused. It
	// is not resized per frame: a per-frame texture create is a driver
	// allocation on the hot path, and a render pass loading CLEAR means only
	// the drawn sub-rect is ever read.
	dst:     ^sdl.GPUTexture,
	dst_cap: int,

	// canvas is the GPU composite target for video-only exports: one texture
	// at the job's frame size the whole visual walk draws into in z-order,
	// holding LOAD between draws and read back once per frame. S1b's per-keyed
	// readback is dropped with it. Reused across frames (the job size is
	// fixed); the CPU composite is the drop-in fallback whenever text or a
	// crop-scaled static clip is present. SAMPLER usage lets the RGBA->NV12
	// passes read the finished composite back as their source.
	canvas:    ^sdl.GPUTexture,
	canvas_w:  int,
	canvas_h:  int,

	// GPU RGBA->NV12 (S1c part 2): the worker converts the composited canvas on
	// the GPU instead of reading it back as RGBA and letting the encoder's
	// swscale convert. Two one-color-target fragment passes over the canvas
	// (sampled) produce luma and interleaved chroma R8G8B8A8 targets -- same
	// rationale as the probe: R8/RG8 color-attachment support is
	// driver-optional, and the unorm8 quantization is identical either way.
	// The packer then reads the R / R,G channels into the NV12 byte layout.
	// Created lazily on the first converting frame and reused; released in
	// gpu_resample_destroy.
	luma_pipe:   ^sdl.GPUGraphicsPipeline,
	chroma_pipe: ^sdl.GPUGraphicsPipeline,
	luma_tex:    ^sdl.GPUTexture,
	chroma_tex:  ^sdl.GPUTexture,

	up:        ^sdl.GPUTransferBuffer,
	up_cap:    int,
	down:      ^sdl.GPUTransferBuffer,
	down_cap:  int,

	// owns_video records whether this proc is the one that brought up the video
	// subsystem. The export worker runs headless, but the UI may already have
	// video up, and SDL_QuitSubSystem by a worker that did not initialize it
	// would tear the subsystem out from under the window.
	owns_video: bool,
	adapter:    string,
}

// gpu_resample_get returns the worker's compositor, creating it on first use, or
// nil when the GPU path is unavailable -- which is a legitimate outcome, not an
// error: the caller falls back to the CPU kernel. A nil return is cached as
// `disabled` so a headless or driverless environment does not pay the device
// creation cost on every keyed clip, every frame.
// The compositor is a singleton for the worker's lifetime, so it is a value
// with a ready flag rather than a heap pointer: one instance, created once,
// never moved, and nothing to free. gpu_resample_disabled latches a failed
// creation so a driverless or headless environment does not retry device
// creation on every keyed clip of every frame.
// Counts real uploads, so the "always upload, never cache" decision above can
// be re-checked against a number instead of a story about addressing.
gpu_stage_uploads: int

gpu_resample_singleton: GPU_Resample
gpu_resample_ready:     bool
gpu_resample_disabled:  bool

gpu_resample_get :: proc() -> ^GPU_Resample {
	if gpu_resample_disabled {
		return nil
	}
	if !gpu_resample_ready {
		gpu_resample_ready = true
		if !gpu_resample_create(&gpu_resample_singleton) {
			return nil
		}
	}
	return &gpu_resample_singleton
}

gpu_resample_create :: proc(g: ^GPU_Resample) -> bool {
	// SDL3 refuses CreateGPUDevice with "Video subsystem not initialized" -- the
	// GPU device is owned by the video subsystem even when no window or surface
	// is ever created, and the export worker is headless.
	// WasInit returns a bit_set, so emptiness is the test rather than == 0.
	// A worker that initializes video must be the one that shuts it down; the
	// UI may already hold it and SDL_QuitSubSystem would take the window's
	// video subsystem down with it.
	owns_video := (sdl.WasInit(sdl.INIT_VIDEO) & ~sdl.INIT_VIDEO) == (sdl.InitFlags{})
	if owns_video && !sdl.Init(sdl.INIT_VIDEO) {
		fmt.println("render-gpu: SDL_Init(VIDEO) failed, using CPU resample:", sdl.GetError())
		gpu_resample_mark_disabled()
		return false
	}

	g.owns_video = owns_video

	// nil is SDL_HINT_GPU_DRIVER unset, i.e. auto-select; the third argument is
	// a driver name, never a device name.
	g.device = sdl.CreateGPUDevice({.SPIRV}, false, nil)
	if g.device == nil {
		fmt.println("render-gpu: CreateGPUDevice failed, using CPU resample:", sdl.GetError())
		gpu_resample_destroy(g)
		gpu_resample_mark_disabled()
		return false
	}

	// The device name is the only reliable hardware/software signal: a software
	// rasterizer reports backend "vulkan" exactly like real hardware, which is
	// how a software run once read as a GPU measurement. Export still works on
	// one, so this warns rather than disabling.
	g.adapter = string(
		sdl.GetStringProperty(
			sdl.GetGPUDeviceProperties(g.device),
			"SDL.gpu.device.name",
			"<unknown>",
		),
	)
	for token in SOFTWARE_RASTERIZER_NAMES {
		if strings.contains(g.adapter, token) {
			fmt.println(
				"render-gpu: WARNING software rasterizer (",
				g.adapter,
				") -- export will be slow but correct; rebuild before trusting timings.",
			)
		}
	}

	g.sampler = sdl.CreateGPUSampler(g.device, sdl.GPUSamplerCreateInfo {
		min_filter    = .LINEAR,
		mag_filter    = .LINEAR,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
	})
	if g.sampler == nil {
		gpu_resample_destroy(g)
		gpu_resample_mark_disabled()
		return false
	}

	vs := sdl.GPUShaderCreateInfo {
		code_size          = uint(len(quad_vertex_spirv)),
		code               = raw_data(quad_vertex_spirv),
		entrypoint         = "main",
		format             = {.SPIRV},
		stage              = .VERTEX,
		num_uniform_buffers = 1,
	}
	fs := sdl.GPUShaderCreateInfo {
		code_size    = uint(len(blit_box_fragment_spirv)),
		code         = raw_data(blit_box_fragment_spirv),
		entrypoint   = "main",
		format       = {.SPIRV},
		stage        = .FRAGMENT,
		num_samplers = 1,
	}
	vshader := sdl.CreateGPUShader(g.device, vs)
	fshader := sdl.CreateGPUShader(g.device, fs)
	if vshader == nil || fshader == nil {
		fmt.println("render-gpu: shader creation failed, using CPU resample:", sdl.GetError())
		gpu_resample_destroy(g)
		gpu_resample_mark_disabled()
		return false
	}

	// Blending is off because render_blit_region is an opaque copy, not an
	// alpha blend. Enabling it would be a silent quality change on the seam
	// this is meant to be interchangeable with.
	target := sdl.GPUColorTargetDescription {
		format = .R8G8B8A8_UNORM,
		blend_state = {enable_blend = false},
	}
	pi := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader   = vshader,
		fragment_shader = fshader,
		primitive_type  = .TRIANGLELIST,
		rasterizer_state = {
			fill_mode = .FILL, cull_mode = .NONE,
			front_face = .COUNTER_CLOCKWISE, enable_depth_clip = true,
		},
		multisample_state = {sample_count = ._1},
		target_info = {color_target_descriptions = &target, num_color_targets = 1},
	}
	g.pipeline = sdl.CreateGPUGraphicsPipeline(g.device, pi)
	sdl.ReleaseGPUShader(g.device, vshader)
	sdl.ReleaseGPUShader(g.device, fshader)
	if g.pipeline == nil {
		fmt.println("render-gpu: pipeline creation failed, using CPU resample:", sdl.GetError())
		gpu_resample_destroy(g)
		gpu_resample_mark_disabled()
		return false
	}

	fmt.println("render-gpu: resample on", g.adapter)
	return true
}

// gpu_stage_map makes sure `src` is staged in g.up (mapped, copied, unmapped)
// and the stage texture is shaped for w x h. The caller owns the command
// buffer: gpu_resample_stage submits a standalone upload, the composite path
// folds the upload into the frame's own command buffer.
gpu_stage_map :: proc(g: ^GPU_Resample, src: [^]u8, src_bytes: int, w, h: int) -> bool {
	if w <= 0 || h <= 0 {
		return false
	}
	// The upload copies w*h*4 bytes out of a raw pointer, so nothing else in
	// this proc can catch a short source. A decoded stage is w*h*4 by
	// construction, which makes a mismatch a bug, not a recoverable condition.
	assert(src_bytes >= w * h * 4, "gpu_resample: source buffer smaller than its declared dimensions")
	gpu_stage_uploads += 1
	// Recreate the texture only when it is absent or the wrong shape. Creating
	// it unconditionally would re-create a driver object every frame and
	// orphan the previous handle -- a GPU resource leak that no host allocator
	// or Valgrind can see, since the memory is on the other side of the driver.
	if g.stage == nil || g.stage_w != w || g.stage_h != h {
		if g.stage != nil {
			sdl.ReleaseGPUTexture(g.device, g.stage)
			g.stage = nil
		}
		g.stage = sdl.CreateGPUTexture(
			g.device,
			sdl.GPUTextureCreateInfo {
				type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER},
				width = u32(w), height = u32(h), layer_count_or_depth = 1,
				num_levels = 1, sample_count = ._1,
			},
		)
		if g.stage == nil {
			return false
		}
		g.stage_w, g.stage_h = w, h
	}

	bytes := w * h * 4
	if g.up_cap < bytes {
		if g.up != nil {
			sdl.ReleaseGPUTransferBuffer(g.device, g.up)
			g.up = nil
		}
		g.up = sdl.CreateGPUTransferBuffer(g.device, sdl.GPUTransferBufferCreateInfo {
			usage = .UPLOAD, size = u32(bytes),
		})
		if g.up == nil {
			return false
		}
		g.up_cap = bytes
	}
	staged := sdl.MapGPUTransferBuffer(g.device, g.up, true)
	if staged == nil {
		return false
	}
	copy(([^]u8)(staged)[:bytes], src[:bytes])
	sdl.UnmapGPUTransferBuffer(g.device, g.up)
	return true
}

// gpu_resample_stage: standalone upload for the single-resample path.
gpu_resample_stage :: proc(g: ^GPU_Resample, src: [^]u8, src_bytes: int, w, h: int) -> bool {
	if !gpu_stage_map(g, src, src_bytes, w, h) {
		return false
	}
	cb := sdl.AcquireGPUCommandBuffer(g.device)
	cp := sdl.BeginGPUCopyPass(cb)
	sdl.UploadToGPUTexture(
		cp,
		sdl.GPUTextureTransferInfo {
			transfer_buffer = g.up, pixels_per_row = u32(w), rows_per_layer = u32(h),
		},
		sdl.GPUTextureRegion {texture = g.stage, w = u32(w), h = u32(h), d = 1},
		false,
	)
	sdl.EndGPUCopyPass(cp)
	if !sdl.SubmitGPUCommandBuffer(cb) {
		return false
	}
	return true
}

// gpu_resample_dst grows the render target to hold a rw x rh result, reusing it
// when it already fits. Only the drawn sub-rect is read, so a larger texture is
// harmless: the pass loads CLEAR and the viewport is the result size.
gpu_resample_dst :: proc(g: ^GPU_Resample, w, h: int) -> bool {
	if w <= 0 || h <= 0 {
		return false
	}
	if g.dst != nil && g.dst_cap >= w * h {
		return true
	}
	if g.dst != nil {
		sdl.ReleaseGPUTexture(g.device, g.dst)
		g.dst = nil
	}
	g.dst = sdl.CreateGPUTexture(
		g.device,
		sdl.GPUTextureCreateInfo {
			type = .D2, format = .R8G8B8A8_UNORM, usage = {.COLOR_TARGET},
			width = u32(w), height = u32(h), layer_count_or_depth = 1,
			num_levels = 1, sample_count = ._1,
		},
	)
	if g.dst == nil {
		return false
	}
	g.dst_cap = w * h
	return true
}

// gpu_resample_into is the drop-in replacement for the
// yuvconv.rgba_resample call in render_eval_keyed_geom: it fills `dst` with the
// same rw x rh RGBA result the CPU kernel would produce, from the crop sub-rect
// (srcx, srcy, srcw, srch) of a sw x sh source.
//
// Returns false for any failure, having written nothing to `dst`, so the caller
// can run the CPU kernel over the same rect with no partial-frame state to undo.
gpu_resample_into :: proc(
	g: ^GPU_Resample,
	src: [^]u8, src_bytes: int, sw, sh: int,
	srcx, srcy, srcw, srch: int,
	rw, rh: int,
	dst: [^]u8, dst_bytes: int,
) -> bool {
	if g == nil || gpu_resample_disabled {
		return false
	}
	// The readback copies rw*rh*4 bytes into a raw pointer, so like the source
	// above it cannot be bounds checked from the pointer alone. kres_scratch is
	// sized from the maximum destination rect at keyed setup, so a shortfall
	// means the two sizing paths disagree -- a bug, not a small export.
	assert(dst_bytes >= rw * rh * 4, "gpu_resample: destination buffer smaller than the requested rect")
	// The crop sub-rect is computed by the caller from keyframe geometry; a
	// keyframe that walks it off the stage must fail here, not read past the
	// texture and hand the caller a plausible-looking frame.
	sub_rect_ok := srcx >= 0 && srcy >= 0 && srcw > 0 && srch > 0 \
		&& srcx + srcw <= sw && srcy + srch <= sh
	assert(sub_rect_ok, "gpu_resample: crop sub-rect escapes the source")
	t_stage := time.now()._nsec
	if !gpu_resample_stage(g, src, src_bytes, sw, sh) {
		return false
	}
	upload_done := time.now()._nsec
	if render_split_timing {
		render_pipe.res_upload_ns += upload_done - t_stage
	}
	if !gpu_resample_dst(g, rw, rh) {
		return false
	}
	bytes := rw * rh * 4
	if g.down_cap < bytes {
		if g.down != nil {
			sdl.ReleaseGPUTransferBuffer(g.device, g.down)
			g.down = nil
		}
		g.down = sdl.CreateGPUTransferBuffer(g.device, sdl.GPUTransferBufferCreateInfo {
			usage = .DOWNLOAD, size = u32(bytes),
		})
		if g.down == nil {
			return false
		}
		g.down_cap = bytes
	}

	cb := sdl.AcquireGPUCommandBuffer(g.device)
	target := sdl.GPUColorTargetInfo {
		texture = g.dst, load_op = .CLEAR, store_op = .STORE,
		clear_color = {0, 0, 0, 1},
	}
	pass := sdl.BeginGPURenderPass(cb, &target, 1, nil)
	if pass == nil {
		_ = sdl.CancelGPUCommandBuffer(cb)
		return false
	}
	sdl.SetGPUViewport(
		pass,
		sdl.GPUViewport{x = 0, y = 0, w = f32(rw), h = f32(rh), min_depth = 0.0, max_depth = 1.0},
	)
	sdl.BindGPUGraphicsPipeline(pass, g.pipeline)
	binding := sdl.GPUTextureSamplerBinding{texture = g.stage, sampler = g.sampler}
	sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)

	// Same layout the probe validates, which is the whole point of reusing it:
	// bounds in result pixels, uv normalized over the crop sub-rect,
	// viewport = result size. The EXACT sub-rect with no half-texel inset is
	// what keeps 1:1 bit-exact; a fractional inset shifts the image, and the
	// probe's exactness gate exists to catch exactly that.
	//
	// Pushed through the command buffer rather than a persistent buffer write,
	// matching the probe, so this path is known-good against the gate that
	// already passes.
	vals := Quad_Uniforms {
		bounds = {0, 0, f32(rw), f32(rh)},
		uv = {
			f32(srcx) / f32(sw),
			f32(srcy) / f32(sh),
			(f32(srcx) + f32(srcw)) / f32(sw),
			(f32(srcy) + f32(srch)) / f32(sh),
		},
		viewport = {f32(rw), f32(rh)},
	}
	sdl.PushGPUVertexUniformData(cb, 0, &vals, u32(size_of(vals)))
	sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
	sdl.EndGPURenderPass(pass)

	cp := sdl.BeginGPUCopyPass(cb)
	sdl.DownloadFromGPUTexture(
		cp,
		sdl.GPUTextureRegion {texture = g.dst, x = 0, y = 0, w = u32(rw), h = u32(rh), d = 1},
		sdl.GPUTextureTransferInfo {
			transfer_buffer = g.down, pixels_per_row = u32(rw), rows_per_layer = u32(rh),
		},
	)
	sdl.EndGPUCopyPass(cp)
	pass_done := time.now()._nsec
	if !sdl.SubmitGPUCommandBuffer(cb) {
		return false
	}
	submitted := time.now()._nsec
	if !sdl.WaitForGPUIdle(g.device) {
		return false
	}
	download_done := time.now()._nsec
	if render_split_timing {
		// Submit + wait + the map: everything after the copy pass is
		// recorded, so the readback cost is not understated by putting
		// the map outside.
		render_pipe.res_gpu_ns += download_done - upload_done
		render_pipe.res_submit_ns += submitted - pass_done
		render_pipe.res_wait_ns += download_done - submitted
	}
	back := sdl.MapGPUTransferBuffer(g.device, g.down, true)
	if back == nil {
		return false
	}
	copy(dst[:bytes], ([^]u8)(back)[:bytes])
	sdl.UnmapGPUTransferBuffer(g.device, g.down)
	if render_split_timing {
		render_pipe.res_download_ns += time.now()._nsec - download_done
	}
	return true
}

// GPU_Composite is the per-frame state of the GPU canvas composite. One
// instance on the worker thread's stack per frame; the draws interleave
// upload passes and z-ordered CLEAR/LOAD render passes in a single command
// buffer, and the frame end reads the canvas back once.
//
// draw is the gpu_composite_probe pattern applied to the exporter: per-clip
// geometry as bounds/uv/viewport goes through the SAME quad + blit_box
// pipeline the probe gates, so a 1:1 sub-rect is byte-exact, a box downscale
// matches the CPU kernel within its agreement bound, and overwrites earlier
// draws (opaque copy, blend off) -- z-order is the draw order, exactly as the
// CPU walk paints back-to-front.
GPU_Composite :: struct {
	g:      ^GPU_Resample,
	cb:     ^sdl.GPUCommandBuffer,
	w:      int,
	h:      int,
	draws:  int,
	scratch: []u8,
}

// gpu_composite_begin opens the frame: canvas sized to the job, download
// buffer at least a full frame, command buffer acquired. The job size is
// fixed, so the canvas is created at most once. FALSE means the caller falls
// back to the CPU composite for the whole run.
gpu_composite_begin :: proc(g: ^GPU_Resample, w, h: int) -> (c: GPU_Composite, ok: bool) {
	if g == nil || gpu_resample_disabled || w <= 0 || h <= 0 {
		return
	}
	if g.canvas == nil || g.canvas_w != w || g.canvas_h != h {
		if g.canvas != nil {
			sdl.ReleaseGPUTexture(g.device, g.canvas)
			g.canvas = nil
		}
		g.canvas = sdl.CreateGPUTexture(
			g.device,
			sdl.GPUTextureCreateInfo {
				type = .D2, format = .R8G8B8A8_UNORM, usage = {.COLOR_TARGET, .SAMPLER},
				width = u32(w), height = u32(h), layer_count_or_depth = 1,
				num_levels = 1, sample_count = ._1,
			},
		)
		if g.canvas == nil {
			return
		}
		g.canvas_w, g.canvas_h = w, h
	}
	// The download buffer is shared by the two composite ends: the RGBA canvas
	// readback (w*h*4) and the GPU-NV12 path, which downloads luma (w*h) plus
	// chroma (w/2*h/2) as R8G8B8A8 -- together 1.25x the RGBA frame. Size for
	// the larger, so a mode switch mid-lifetime never recreates the buffer.
	bytes := w * h * 4
	if g.down_cap < bytes + (w / 2) * (h / 2) * 4 {
		if g.down != nil {
			sdl.ReleaseGPUTransferBuffer(g.device, g.down)
			g.down = nil
		}
		g.down = sdl.CreateGPUTransferBuffer(g.device, sdl.GPUTransferBufferCreateInfo {
			usage = .DOWNLOAD, size = u32(bytes + (w / 2) * (h / 2) * 4),
		})
		if g.down == nil {
			return
		}
		g.down_cap = bytes + (w / 2) * (h / 2) * 4
	}
	c = GPU_Composite{g = g, w = w, h = h}
	c.cb = sdl.AcquireGPUCommandBuffer(g.device)
	if c.cb == nil {
		return
	}
	return c, true
}

// gpu_composite_draw stages one clip's decoded frame and draws its rect into
// the canvas, in z-order. load_policy: the first draw CLEARs to match the CPU
// path's per-frame mem.zero, every later draw LOADs so the stack below it
// stays. Returns false only on a driver-level failure; the caller stops the
// export rather than composite a partially-drawn frame.
gpu_composite_draw :: proc(
	c: ^GPU_Composite,
	src: [^]u8, src_bytes: int, sw, sh: int,
	srcx, srcy, srcw, srch: int,
	ox, oy, rw, rh: int,
) -> bool {
	g := c.g
	if !gpu_stage_map(g, src, src_bytes, sw, sh) {
		render_gpu_abort = true
		return false
	}
	cp := sdl.BeginGPUCopyPass(c.cb)
	sdl.UploadToGPUTexture(
		cp,
		sdl.GPUTextureTransferInfo {
			transfer_buffer = g.up, pixels_per_row = u32(sw), rows_per_layer = u32(sh),
		},
		sdl.GPUTextureRegion {texture = g.stage, w = u32(sw), h = u32(sh), d = 1},
		false,
	)
	sdl.EndGPUCopyPass(cp)

	// CLEAR on the first draw doubles as the background fill: CPU mem.zero
	// writes (0,0,0,0) RGBA and the canvas clear matches those bytes, so the
	// readback is byte-identical there too.
	load := sdl.GPULoadOp.LOAD
	if c.draws == 0 {
		load = .CLEAR
	}
	target := sdl.GPUColorTargetInfo {
		texture = g.canvas, load_op = load, store_op = .STORE,
		clear_color = {0, 0, 0, 0},
	}
	pass := sdl.BeginGPURenderPass(c.cb, &target, 1, nil)
	if pass == nil {
		_ = sdl.CancelGPUCommandBuffer(c.cb)
		render_gpu_abort = true
		return false
	}
	sdl.SetGPUViewport(
		pass,
		sdl.GPUViewport{x = 0, y = 0, w = f32(c.w), h = f32(c.h), min_depth = 0.0, max_depth = 1.0},
	)
	sdl.BindGPUGraphicsPipeline(pass, g.pipeline)
	binding := sdl.GPUTextureSamplerBinding{texture = g.stage, sampler = g.sampler}
	sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
	u := Quad_Uniforms {
		bounds   = {f32(ox), f32(oy), f32(rw), f32(rh)},
		viewport = {f32(c.w), f32(c.h)},
		uv       = {
			f32(srcx) / f32(sw),
			f32(srcy) / f32(sh),
			(f32(srcx) + f32(srcw)) / f32(sw),
			(f32(srcy) + f32(srch)) / f32(sh),
		},
	}
	sdl.PushGPUVertexUniformData(c.cb, 0, &u, u32(size_of(u)))
	sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
	sdl.EndGPURenderPass(pass)
	c.draws += 1
	return true
}

// gpu_composite_clear_if_empty gives a frame with no visible draws the same
// all-background bytes the CPU path's per-frame mem.zero would: clear the
// canvas to (0,0,0,0) so whatever reads it next -- the RGBA readback or the
// NV12 passes -- converts the same background. No-op once anything drew.
gpu_composite_clear_if_empty :: proc(c: ^GPU_Composite) -> bool {
	if c.draws != 0 {
		return true
	}
	g := c.g
	target := sdl.GPUColorTargetInfo {
		texture = g.canvas, load_op = .CLEAR, store_op = .STORE,
		clear_color = {0, 0, 0, 0},
	}
	pass := sdl.BeginGPURenderPass(c.cb, &target, 1, nil)
	if pass == nil {
		_ = sdl.CancelGPUCommandBuffer(c.cb)
		render_gpu_abort = true
		return false
	}
	sdl.EndGPURenderPass(pass)
	return true
}

// gpu_composite_end finalizes the frame and reads the canvas into `dst` (the
// encoder slot, w x h RGBA). Reads the whole canvas once, which is the single
// readback that replaces S1b's upload+readback per keyed clip. The CPU
// side of the RGBA->encoder conversion (swscale/fast-yuv) consumes this; the
// NV12 variant below replaces this readback and the conversion both.
gpu_composite_end :: proc(c: ^GPU_Composite, dst: []u8) -> bool {
	g := c.g
	bytes := c.w * c.h * 4
	assert(len(dst) >= bytes, "gpu_composite: destination buffer smaller than the canvas")
	if !gpu_composite_clear_if_empty(c) {
		return false
	}
	cp := sdl.BeginGPUCopyPass(c.cb)
	sdl.DownloadFromGPUTexture(
		cp,
		sdl.GPUTextureRegion {texture = g.canvas, x = 0, y = 0, w = u32(c.w), h = u32(c.h), d = 1},
		sdl.GPUTextureTransferInfo {
			transfer_buffer = g.down, pixels_per_row = u32(c.w), rows_per_layer = u32(c.h),
		},
	)
	sdl.EndGPUCopyPass(cp)
	if !sdl.SubmitGPUCommandBuffer(c.cb) {
		render_gpu_abort = true
		return false
	}
	if !sdl.WaitForGPUIdle(g.device) {
		render_gpu_abort = true
		return false
	}
	back := sdl.MapGPUTransferBuffer(g.device, g.down, true)
	if back == nil {
		render_gpu_abort = true
		return false
	}
	copy(dst[:bytes], ([^]u8)(back)[:bytes])
	sdl.UnmapGPUTransferBuffer(g.device, g.down)
	return true
}

// gpu_composite_pipeline boots a quad pipeline around one of the NV12 fragment
// shaders, mirroring the probe's boot_pipeline -- the same RGBA8 target (see
// the driver-optional R8/RG8 note on GPU_Resample) and the same single
// fragment sampler + single vertex uniform buffer layout.
gpu_composite_pipeline :: proc(device: ^sdl.GPUDevice, frag_spirv: []u8) -> ^sdl.GPUGraphicsPipeline {
	vs := sdl.CreateGPUShader(device, sdl.GPUShaderCreateInfo {
		code_size           = uint(len(quad_vertex_spirv)),
		code                = raw_data(quad_vertex_spirv),
		entrypoint          = "main",
		format              = {.SPIRV},
		stage               = .VERTEX,
		num_uniform_buffers = 1,
	})
	fs := sdl.CreateGPUShader(device, sdl.GPUShaderCreateInfo {
		code_size       = uint(len(frag_spirv)),
		code            = raw_data(frag_spirv),
		entrypoint      = "main",
		format          = {.SPIRV},
		stage           = .FRAGMENT,
		num_samplers    = 1,
	})
	defer sdl.ReleaseGPUShader(device, vs)
	defer sdl.ReleaseGPUShader(device, fs)
	if vs == nil || fs == nil {
		return nil
	}
	target := sdl.GPUColorTargetDescription {
		format      = .R8G8B8A8_UNORM,
		blend_state = {enable_blend = false},
	}
	pipe := sdl.CreateGPUGraphicsPipeline(device, sdl.GPUGraphicsPipelineCreateInfo {
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
	if pipe == nil {
		fmt.println("gpu-composite: CreateGPUGraphicsPipeline failed:", sdl.GetError())
	}
	return pipe
}

// gpu_composite_nv12_ensure lazily creates the luma/chroma targets and the two
// converting pipelines on the first frame that actually converts. Intelized
// once, reused across frames; only incurred on the NV12 path, so an
// RGBA-readback export never pays for it.
gpu_composite_nv12_ensure :: proc(c: ^GPU_Composite) -> bool {
	g := c.g
	uv_w, uv_h := g.canvas_w / 2, g.canvas_h / 2
	if g.luma_tex == nil {
		g.luma_tex = sdl.CreateGPUTexture(g.device, sdl.GPUTextureCreateInfo {
			type = .D2, format = .R8G8B8A8_UNORM, usage = {.COLOR_TARGET},
			width = u32(g.canvas_w), height = u32(g.canvas_h), layer_count_or_depth = 1,
			num_levels = 1, sample_count = ._1,
		})
		g.chroma_tex = sdl.CreateGPUTexture(g.device, sdl.GPUTextureCreateInfo {
			type = .D2, format = .R8G8B8A8_UNORM, usage = {.COLOR_TARGET},
			width = u32(uv_w), height = u32(uv_h), layer_count_or_depth = 1,
			num_levels = 1, sample_count = ._1,
		})
		if g.luma_tex == nil || g.chroma_tex == nil {
			return false
		}
	}
	if g.luma_pipe == nil {
		g.luma_pipe = gpu_composite_pipeline(g.device, nv12_luma_fragment_spirv)
		g.chroma_pipe = gpu_composite_pipeline(g.device, nv12_chroma_fragment_spirv)
		if g.luma_pipe == nil || g.chroma_pipe == nil {
			return false
		}
	}
	return true
}

// gpu_composite_end_nv12 finalizes the frame and converts the canvas to NV12 on
// the GPU, writing the packed Y + interleaved UV planes into `dst` (the encoder
// slot, w*h luma + w/2*h/2*2 chroma). This replaces the RGBA canvas readback
// AND the encoder's swscale conversion: the encoder's `yuv_data` is pointed
// straight at the packed bytes, so the 5 ms/f swscale pass never runs. The two
// fragment passes (luma, then interleaved chroma at half resolution) are the
// exact shaders the gpu_nv12 probe gates byte-for-byte against swscale, and the
// pack below mirrors the probe's -- same channel reads, same offsets -- so the
// chain composite+convert stays byte-identical to the CPU path the A/B pins.
gpu_composite_end_nv12 :: proc(c: ^GPU_Composite, dst: []u8) -> bool {
	g := c.g
	w, h := c.w, c.h
	assert(w % 2 == 0 && h % 2 == 0, "gpu_composite: NV12 needs even dimensions")
	uv_w, uv_h := w / 2, h / 2
	nv12_bytes := w * h * 3 / 2
	assert(len(dst) >= nv12_bytes, "gpu_composite: NV12 destination buffer too small")
	if !gpu_composite_nv12_ensure(c) {
		render_gpu_abort = true
		return false
	}
	if !gpu_composite_clear_if_empty(c) {
		return false
	}
	render_nv12_pass :: proc(
		c: ^GPU_Composite,
		pipe: ^sdl.GPUGraphicsPipeline,
		target_tex: ^sdl.GPUTexture,
		tw, th: u32,
	) -> bool {
		place := sdl.GPUColorTargetInfo {
			texture = target_tex, load_op = .CLEAR, store_op = .STORE,
			clear_color = {0, 0, 0, 1},
		}
		pass := sdl.BeginGPURenderPass(c.cb, &place, 1, nil)
		if pass == nil {
			return false
		}
		sdl.SetGPUViewport(
			pass,
			sdl.GPUViewport{x = 0, y = 0, w = f32(tw), h = f32(th), min_depth = 0.0, max_depth = 1.0},
		)
		sdl.BindGPUGraphicsPipeline(pass, pipe)
		binding := sdl.GPUTextureSamplerBinding{texture = c.g.canvas, sampler = c.g.sampler}
		sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
		u := Quad_Uniforms {
			bounds   = {0, 0, f32(tw), f32(th)},
			viewport = {f32(tw), f32(th)},
			uv       = {0, 0, 1, 1},
		}
		sdl.PushGPUVertexUniformData(c.cb, 0, &u, u32(size_of(u)))
		sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
		sdl.EndGPURenderPass(pass)
		return true
	}
	t_p0 := time.now()._nsec
	if !render_nv12_pass(c, g.luma_pipe, g.luma_tex, u32(w), u32(h)) {
		_ = sdl.CancelGPUCommandBuffer(c.cb)
		render_gpu_abort = true
		return false
	}
	if !render_nv12_pass(c, g.chroma_pipe, g.chroma_tex, u32(uv_w), u32(uv_h)) {
		_ = sdl.CancelGPUCommandBuffer(c.cb)
		render_gpu_abort = true
		return false
	}
	t_p1 := time.now()._nsec
	// Downloads are R8G8B8A8, so luma costs w*h*4 bytes in the buffer, chroma
	// uv_w*uv_h*4 -- NOT the NV12 byte counts. Sized for that in begin.
	luma_gpu_bytes := w * h * 4
	cp := sdl.BeginGPUCopyPass(c.cb)
	sdl.DownloadFromGPUTexture(
		cp,
		sdl.GPUTextureRegion {texture = g.luma_tex, w = u32(w), h = u32(h), d = 1},
		sdl.GPUTextureTransferInfo {
			transfer_buffer = g.down, offset = 0, pixels_per_row = u32(w), rows_per_layer = u32(h),
		},
	)
	sdl.DownloadFromGPUTexture(
		cp,
		sdl.GPUTextureRegion {texture = g.chroma_tex, w = u32(uv_w), h = u32(uv_h), d = 1},
		sdl.GPUTextureTransferInfo {
			transfer_buffer = g.down, offset = u32(luma_gpu_bytes), pixels_per_row = u32(uv_w), rows_per_layer = u32(uv_h),
		},
	)
	sdl.EndGPUCopyPass(cp)
	t_p2 := time.now()._nsec
	if !sdl.SubmitGPUCommandBuffer(c.cb) {
		render_gpu_abort = true
		return false
	}
	if !sdl.WaitForGPUIdle(g.device) {
		render_gpu_abort = true
		return false
	}
	back := sdl.MapGPUTransferBuffer(g.device, g.down, true)
	if back == nil {
		render_gpu_abort = true
		return false
	}
	t_p3 := time.now()._nsec
	// Pack into NV12 while the buffer is still mapped: luma rows from the R
	// channel of each RGBA8 pixel, chroma U/V from the R,G channels -- the same
	// channel reads and offsets the gpu_nv12 probe packs with. The mapped
	// download is device-visible memory; strided reads straight off it measured
	// 12.5 ms/f on RADV. Copy the planes out SEQUENTIALLY first (the same
	// wide-copy cost as the RGBA readback path), then pack from the now-cached
	// scratch.
	raw_total := luma_gpu_bytes + uv_w * uv_h * 4
	assert(len(c.scratch) >= raw_total, "gpu_composite: nv12 scratch too small")
	t_p3b := time.now()._nsec
	copy(c.scratch[:raw_total], ([^]u8)(back)[:raw_total])
	t_p3c := time.now()._nsec
	src := c.scratch
	for y in 0 ..< h {
		for x in 0 ..< w {
			dst[y * w + x] = src[(y * w + x) * 4]
		}
	}
	chroma_src := src[luma_gpu_bytes:]
	o_base := w * h
	for k in 0 ..< uv_h {
		for c2 in 0 ..< uv_w {
			i := (k * uv_w + c2) * 4
			o := o_base + (k * uv_w + c2) * 2
			dst[o + 0] = chroma_src[i + 0]
			dst[o + 1] = chroma_src[i + 1]
		}
	}
	t_p4 := time.now()._nsec
	sdl.UnmapGPUTransferBuffer(g.device, g.down)
	render_pipe.comp_nv12_pass_ns += t_p1 - t_p0
	render_pipe.comp_nv12_dl_ns += t_p2 - t_p1
	render_pipe.comp_nv12_wait_ns += t_p3 - t_p2
	render_pipe.comp_nv12_cpy_ns += t_p3c - t_p3b
	render_pipe.comp_nv12_pack_ns += t_p4 - t_p3c
	return true
}

gpu_resample_destroy :: proc(g: ^GPU_Resample) {
	if g == nil {
		return
	}
	if g.device != nil {
		if g.down != nil {
			sdl.ReleaseGPUTransferBuffer(g.device, g.down)
		}
		if g.up != nil {
			sdl.ReleaseGPUTransferBuffer(g.device, g.up)
		}
		if g.canvas != nil {
			sdl.ReleaseGPUTexture(g.device, g.canvas)
		}
		if g.dst != nil {
			sdl.ReleaseGPUTexture(g.device, g.dst)
		}
		if g.luma_tex != nil {
			sdl.ReleaseGPUTexture(g.device, g.luma_tex)
		}
		if g.chroma_tex != nil {
			sdl.ReleaseGPUTexture(g.device, g.chroma_tex)
		}
		if g.luma_pipe != nil {
			sdl.ReleaseGPUGraphicsPipeline(g.device, g.luma_pipe)
		}
		if g.chroma_pipe != nil {
			sdl.ReleaseGPUGraphicsPipeline(g.device, g.chroma_pipe)
		}
		if g.stage != nil {
			sdl.ReleaseGPUTexture(g.device, g.stage)
		}
		if g.pipeline != nil {
			sdl.ReleaseGPUGraphicsPipeline(g.device, g.pipeline)
		}
		if g.sampler != nil {
			sdl.ReleaseGPUSampler(g.device, g.sampler)
		}
		sdl.DestroyGPUDevice(g.device)
	}
	// Only bring the subsystem down if this proc brought it up: the UI may be
	// running with video already initialized, and a worker's SDL_QuitSubSystem
	// would take the window's video with it.
	if g.owns_video {
		sdl.QuitSubSystem(sdl.INIT_VIDEO)
	}
}

// gpu_resample_mark_disabled latches the failure so the device is not recreated
// on every keyed clip of every frame. Set once, read everywhere on the worker
// thread that owns the compositor.
gpu_resample_mark_disabled :: proc() {
	gpu_resample_disabled = true
}
