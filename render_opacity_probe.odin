package main

// ---------------------------------------------------------------------------
// Opacity composite probe (VYPER_RENDER_OPACITY_PROBE=1).
//
// gpu_composite_probe pins the OTHER end of the opacity contract: that a fully
// opaque layer still composites byte-exactly. This probe pins the end that
// actually makes the feature work -- a fractional opacity blends the layer
// over what is below it -- on both the CPU path (blend_row) and the GPU export
// path (the blit_box fragment alpha + the composite pipeline's "over" blend).
//
// It is deliberately built to catch the two silent failures an opacity feature
// invites: a layer that vanishes (alpha read as 0, so a blend of nothing) and a
// layer that is simply ignored (alpha not applied at all). Both produce a
// wrong-but-plausible frame, so each case asserts the result is the analytic
// mix AND differs from the unblended source.
// ---------------------------------------------------------------------------

import "core:fmt"
import "core:math"
import sdl "vendor:sdl3"

OPACITY_PROBE_W :: 16
OPACITY_PROBE_H :: 16

Opacity_Probe :: struct {
	device:    ^sdl.GPUDevice,
	sampler:   ^sdl.GPUSampler,
	pipeline:  ^sdl.GPUGraphicsPipeline,
	stage:     ^sdl.GPUTexture,
	canvas:    ^sdl.GPUTexture,
	up_tb:     ^sdl.GPUTransferBuffer,
	down_tb:   ^sdl.GPUTransferBuffer,
}

// straight_over is the reference mix, written out independently of blend_row
// so the check is not the implementation grading its own homework: out = src*a
// + dst*(1-a) with a = (src_alpha/255)*opacity, rounded to nearest.
straight_over :: proc(s, d: u8, opacity: f32) -> u8 {
	// The probe's layers are opaque, so the effective source alpha is just
	// the opacity itself.
	v := f32(s) * opacity + f32(d) * (1.0 - opacity)
	return u8(math.round(clamp(v, 0.0, 255.0)))
}

// opacity_probe_cpu checks blend_row against the reference mix for a spread of
// opacities over a known source and background. blend_row is the real function
// the exporter calls, so this is the CPU half of the contract.
opacity_probe_cpu :: proc() -> bool {
	src_px := [4]u8{200, 100, 50, 255}
	dst_px := [4]u8{40, 80, 120, 255}
	src := src_px[:]
	dst := dst_px[:]
	fail := 0
	for op in ([]f32{0.0, 0.25, 0.5, 0.75, 1.0}) {
		for ch in 0 ..< 4 {
			// blend_row reads src/dst in place; feed a copy of dst.
			d := [4]u8{dst_px[0], dst_px[1], dst_px[2], dst_px[3]}
			s := [4]u8{src_px[0], src_px[1], src_px[2], src_px[3]}
			blend_row(d[:], s[:], 1, op)
			want := straight_over(s[ch], dst_px[ch], op)
			got := d[ch]
			if got != want {
				fail += 1
				fmt.println("opacity-cpu: mismatch op =", op, "ch =", ch, "want =", int(want), "got =", int(got))
			}
		}
	}
	if fail > 0 {
		fmt.println("opacity-cpu: FAIL", fail)
		return false
	}
	fmt.println("opacity-cpu: blend_row matches the reference mix at 0/0.25/0.5/0.75/1.0")
	return true
}

opacity_probe_setup :: proc(p: ^Opacity_Probe) -> bool {
	if !sdl.Init(sdl.INIT_VIDEO) {
		fmt.println("opacity: SDL init failed:", sdl.GetError())
		return false
	}
	p.device = sdl.CreateGPUDevice({.SPIRV}, false, nil)
	if p.device == nil {
		p.device = sdl.CreateGPUDevice({.SPIRV}, false, "vulkan")
	}
	if p.device == nil {
		fmt.println("opacity: CreateGPUDevice failed:", sdl.GetError())
		return false
	}
	p.sampler = sdl.CreateGPUSampler(p.device, sdl.GPUSamplerCreateInfo {
		min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .LINEAR,
		address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE,
	})
	vs := sdl.CreateGPUShader(p.device, sdl.GPUShaderCreateInfo {
		code_size = uint(len(quad_vertex_spirv)), code = raw_data(quad_vertex_spirv),
		entrypoint = "main", format = {.SPIRV}, stage = .VERTEX, num_uniform_buffers = 1,
	})
	fs := sdl.CreateGPUShader(p.device, sdl.GPUShaderCreateInfo {
		code_size = uint(len(blit_box_fragment_spirv)), code = raw_data(blit_box_fragment_spirv),
		entrypoint = "main", format = {.SPIRV}, stage = .FRAGMENT, num_samplers = 1, num_uniform_buffers = 1,
	})
	if p.sampler == nil || vs == nil || fs == nil {
		fmt.println("opacity: shader/sampler creation failed:", sdl.GetError())
		return false
	}
	// Blend ON, matching the export composite pipeline (render_gpu.odin).
	target := sdl.GPUColorTargetDescription {
		format = .R8G8B8A8_UNORM,
		blend_state = {
			src_color_blendfactor = .SRC_ALPHA, dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA, color_blend_op = .ADD,
			src_alpha_blendfactor = .ONE, dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA, alpha_blend_op = .ADD,
			color_write_mask = {.R, .G, .B, .A}, enable_blend = true, enable_color_write_mask = true,
		},
	}
	p.pipeline = sdl.CreateGPUGraphicsPipeline(p.device, sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vs, fragment_shader = fs, primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE, enable_depth_clip = true},
		multisample_state = {sample_count = ._1},
		target_info = {color_target_descriptions = &target, num_color_targets = 1},
	})
	if p.pipeline == nil {
		fmt.println("opacity: pipeline creation failed:", sdl.GetError())
		return false
	}
	p.stage = sdl.CreateGPUTexture(p.device, sdl.GPUTextureCreateInfo {
		type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER},
		width = OPACITY_PROBE_W, height = OPACITY_PROBE_H, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1,
	})
	p.canvas = sdl.CreateGPUTexture(p.device, sdl.GPUTextureCreateInfo {
		type = .D2, format = .R8G8B8A8_UNORM, usage = {.COLOR_TARGET},
		width = OPACITY_PROBE_W, height = OPACITY_PROBE_H, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1,
	})
	if p.stage == nil || p.canvas == nil {
		fmt.println("opacity: texture creation failed:", sdl.GetError())
		return false
	}
	return true
}

opacity_probe_teardown :: proc(p: ^Opacity_Probe) {
	if p.device == nil {
		return
	}
	if p.up_tb != nil {
		sdl.ReleaseGPUTransferBuffer(p.device, p.up_tb)
	}
	if p.down_tb != nil {
		sdl.ReleaseGPUTransferBuffer(p.device, p.down_tb)
	}
	sdl.ReleaseGPUTexture(p.device, p.stage)
	sdl.ReleaseGPUTexture(p.device, p.canvas)
	sdl.ReleaseGPUGraphicsPipeline(p.device, p.pipeline)
	sdl.ReleaseGPUSampler(p.device, p.sampler)
	sdl.DestroyGPUDevice(p.device)
	p.device = nil
	sdl.Quit()
}

// opacity_probe_gpu_draw draws an opaque stage over an opaque background at
// `op` and returns the readback canvas.
opacity_probe_gpu_draw :: proc(p: ^Opacity_Probe, op: f32, out: []u8) -> bool {
	w, h := OPACITY_PROBE_W, OPACITY_PROBE_H
	flat := int(w) * int(h) * 4
	if p.up_tb == nil {
		p.up_tb = sdl.CreateGPUTransferBuffer(p.device, sdl.GPUTransferBufferCreateInfo {usage = .UPLOAD, size = u32(flat)})
	}
	if p.down_tb == nil {
		p.down_tb = sdl.CreateGPUTransferBuffer(p.device, sdl.GPUTransferBufferCreateInfo {usage = .DOWNLOAD, size = u32(flat)})
	}
	// Upload the source layer: one opaque color.
	mapped := sdl.MapGPUTransferBuffer(p.device, p.up_tb, true)
	if mapped == nil {
		return false
	}
	src_pix := [4]u8{200, 100, 50, 255}
	stage: [OPACITY_PROBE_W * OPACITY_PROBE_H * 4]u8
	for i in 0 ..< flat / 4 {
		for c in 0 ..< 4 {
			stage[i * 4 + c] = src_pix[c]
		}
	}
	copy(([^]u8)(mapped)[:flat], stage[:])
	sdl.UnmapGPUTransferBuffer(p.device, p.up_tb)

	cb := sdl.AcquireGPUCommandBuffer(p.device)
	if cb == nil {
		return false
	}
	cp := sdl.BeginGPUCopyPass(cb)
	sdl.UploadToGPUTexture(cp,
		sdl.GPUTextureTransferInfo {transfer_buffer = p.up_tb, pixels_per_row = u32(w), rows_per_layer = u32(h)},
		sdl.GPUTextureRegion {texture = p.stage, w = u32(w), h = u32(h), d = 1}, false)
	sdl.EndGPUCopyPass(cp)

	// Canvas cleared to an opaque background, then one full-canvas draw.
	target := sdl.GPUColorTargetInfo {
		texture = p.canvas, load_op = .CLEAR, store_op = .STORE,
		clear_color = {40.0 / 255.0, 80.0 / 255.0, 120.0 / 255.0, 1.0},
	}
	pass := sdl.BeginGPURenderPass(cb, &target, 1, nil)
	if pass == nil {
		_ = sdl.CancelGPUCommandBuffer(cb)
		return false
	}
	sdl.SetGPUViewport(pass, sdl.GPUViewport{x = 0, y = 0, w = f32(w), h = f32(h), min_depth = 0, max_depth = 1})
	sdl.BindGPUGraphicsPipeline(pass, p.pipeline)
	binding := sdl.GPUTextureSamplerBinding{texture = p.stage, sampler = p.sampler}
	sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
	u := Quad_Uniforms {
		bounds = {0, 0, f32(w), f32(h)},
		viewport = {f32(w), f32(h)},
		uv = {0, 0, 1, 1},
	}
	sdl.PushGPUVertexUniformData(cb, 0, &u, u32(size_of(u)))
	fo := Blit_Opacity_Uniforms{opacity = op}
	sdl.PushGPUFragmentUniformData(cb, 0, &fo, u32(size_of(fo)))
	sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
	sdl.EndGPURenderPass(pass)

	cp2 := sdl.BeginGPUCopyPass(cb)
	sdl.DownloadFromGPUTexture(cp2,
		sdl.GPUTextureRegion {texture = p.canvas, w = u32(w), h = u32(h), d = 1},
		sdl.GPUTextureTransferInfo {transfer_buffer = p.down_tb, pixels_per_row = u32(w), rows_per_layer = u32(h)})
	sdl.EndGPUCopyPass(cp2)
	if !sdl.SubmitGPUCommandBuffer(cb) {
		return false
	}
	if !sdl.WaitForGPUIdle(p.device) {
		return false
	}
	back := sdl.MapGPUTransferBuffer(p.device, p.down_tb, true)
	if back == nil {
		return false
	}
	copy(out, ([^]u8)(back)[:flat])
	sdl.UnmapGPUTransferBuffer(p.device, p.down_tb)
	return true
}

// opacity_probe_gpu checks the GPU export path composites a fractional opacity
// over the background. Tolerance is 2/255: the GPU blends in float and rounds,
// so it need not match the CPU bit-for-bit, only the mix.
opacity_probe_gpu :: proc(p: ^Opacity_Probe) -> bool {
	w := OPACITY_PROBE_W
	src_px := [4]u8{200, 100, 50, 255}
	bg_px := [4]u8{40, 80, 120, 255}
	out: [OPACITY_PROBE_W * OPACITY_PROBE_H * 4]u8
	fail := 0
	for op in ([]f32{0.0, 0.25, 0.5, 0.75, 1.0}) {
		if !opacity_probe_gpu_draw(p, op, out[:]) {
			fmt.println("opacity-gpu: draw failed at op =", op)
			return false
		}
		for ch in 0 ..< 4 {
			got := int(out[ch])
			want := int(straight_over(src_px[ch], bg_px[ch], op))
			if abs(got - want) > 2 {
				fail += 1
				fmt.println("opacity-gpu: mismatch op =", op, "ch =", ch, "want ~=", want, "got =", got)
				continue
			}
			// Guard the silent no-op: at a fractional alpha the result must
			// actually differ from the unblended source (alpha was applied).
			if op > 0.0 && op < 1.0 && ch < 3 && got == int(src_px[ch]) {
				fail += 1
				fmt.println("opacity-gpu: alpha NOT applied at op =", op, "ch =", ch, "got =", got)
			}
		}
	}
	if fail > 0 {
		fmt.println("opacity-gpu: FAIL", fail)
		return false
	}
	fmt.println("opacity-gpu: fractional opacity composites over the background at 0/0.25/0.5/0.75/1.0")
	return true
}

render_opacity_probe_run :: proc() -> int {
	if !opacity_probe_cpu() {
		return 1
	}
	p := Opacity_Probe{}
	if !opacity_probe_setup(&p) {
		return 1
	}
	defer opacity_probe_teardown(&p)
	if !opacity_probe_gpu(&p) {
		return 1
	}
	fmt.println("opacity: cpu + gpu composite agree; opacity works end to end")
	return 0
}
