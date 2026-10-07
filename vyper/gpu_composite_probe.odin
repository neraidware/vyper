// GPU canvas compositing probe (VYPER_GPU_COMPOSITE_PROBE=1).
//
// S1c's premise is that the keyed/static z-order can be composited on the GPU
// "one composite pass per clip" instead of the CPU render_blit_region calls
// into the canvas buffer -- but that claim has a hidden contract that the
// resample gate does not cover: the per-clip draws must reproduce render_blit_region
// byte-for-byte, INCLUDING clipping, overlap, and z-order, or replacing the
// composite shifts the exported pixels. This probe is that contract.
//
// The same 6-op sequence (1:1 sub-rect copies, box downscales, partially
// off-canvas draws, and an overwrite-within-overwrite) is composited twice
// into a 64x64 canvas -- once on CPU with the ship logic
// (render_blit_region + rgba_resample), once on GPU as a sequence of quad
// draws into one render target. The result must agree per pixel per the rule
// the exporter ACTUALLY owns: where the topmost op is a 1:1 copy, the byte
// must match exactly; where it is a downscale, the known resample deviation
// (mean ~0.11, measured in the blit_box comment) is the only tolerance.
//
// The per-pixel topmost-op mask is what catches a z-order or clipping bug: if
// a later copy were drawn underneath, the pixels it owns would come back as
// DOWN-tolerant-but-wrong or nothing at all, and a reorder changes which
// regions are allowed how much error. The mask is the whole point.

package vyper

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import sdl "vendor:sdl3"
import yuvconv "vendor/yuv"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	GPU_COMPOSITE_W :: 64
	GPU_COMPOSITE_H :: 64

	GPU_Composite_Op_Kind :: enum { COPY1, DOWN }

	GPU_Composite_Op :: struct {
		kind:          GPU_Composite_Op_Kind,
		sx, sy, sw, sh: int,
		ox, oy, rw, rh: int,
	}

	// The sequence is deliberately hostile to a blit that only handles aligned,
	// non-overlapping, on-canvas rectangles:
	//
	//   1. a plain sub-rect COPY1 (baseline),
	//   2. a box DOWN resample of the whole stage into a sub-rect,
	//   3. a COPY1 riding the RIGHT edge (clipped by the canvas, not the source),
	//   4. a COPY1 that over-writes the right half of op 2 (z-order over a resample),
	//   5. a DOWN clipped on the LEFT and over the bottom of op 4,
	//   6. a small COPY1 nested inside op 4 (over-write within over-write).
	//
	// Ops 2 and 5 downscale by exactly 2x. The GPU and CPU box kernels pick their
	// integer tap sets by DIFFERENT rules and only agree to ~0.1 mean at INTEGER
	// ratios -- at 64:24 the GPU always takes 3 taps while the CPU spans 2 or 3,
	// and on a changing image that is a full 5-6 mean. That is a resample-quality
	// question (gpu_probe's job), not a composite-plumbing one, so the down
	// regions here use ratios where the two kernels align and the COMPOSITE'S OWN
	// behavior -- z-order, clipping, offset placement -- is what gets measured.
	//
	// The mask makes op 4's pixels byte-exact even though they sit inside op 2's
	// area, and op 6's pixels byte-exact inside op 4's -- a reorder that loses
	// either over-write is a mask/draw disagreement, i.e. exactly this gate.
	GPU_COMPOSITE_OPS :: [6]GPU_Composite_Op{
		{.COPY1, 4, 4,  36, 36,  2,  2, 36, 36},
		{.DOWN,  0, 0,  64, 64,  20, 20, 32, 32},
		{.COPY1, 40, 52, 24, 12,  52, 52, 24, 12},
		{.COPY1, 30, 30, 34, 34,  30, 30, 34, 34},
		{.DOWN,  0, 0,  64, 64,  -8, 50, 32, 32},
		{.COPY1, 0, 0,  8, 8,    46, 46, 8,  8},
	}

	GPU_Composite_Probe :: struct {
		device:      ^sdl.GPUDevice,
		sampler:     ^sdl.GPUSampler,
		pipeline:    ^sdl.GPUGraphicsPipeline,
		stage:       ^sdl.GPUTexture,
		canvas:      ^sdl.GPUTexture,
		up_tb:       ^sdl.GPUTransferBuffer,
		down_tb:     ^sdl.GPUTransferBuffer,
		video_initialized: bool,
	}

	gpu_composite_setup :: proc() -> (p: GPU_Composite_Probe, ok: bool) {
		if !sdl.Init(sdl.INIT_VIDEO) {
			fmt.println("gpu-composite: SDL_Init(VIDEO) failed:", sdl.GetError())
			return
		}
		p.video_initialized = true
		p.device = sdl.CreateGPUDevice({.SPIRV}, false, nil)
		if p.device == nil {
			p.device = sdl.CreateGPUDevice({.SPIRV}, false, "vulkan")
		}
		if p.device == nil {
			fmt.println("gpu-composite: CreateGPUDevice failed:", sdl.GetError())
			return
		}
		fmt.println("gpu-composite: adapter =", sdl.GetGPUDeviceDriver(p.device))

		// The same LINEAR sampler the resample path uses. Exactness at 1:1 does
		// not come from the sampler -- the footprint branch of blit_box.frag uses
		// texelFetch -- so reusing it keeps the composite probe measuring the same
		// pipe the exporter will run.
		p.sampler = sdl.CreateGPUSampler(p.device, sdl.GPUSamplerCreateInfo {
			min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .LINEAR,
			address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE,
			address_mode_w = .CLAMP_TO_EDGE,
		})
		if p.sampler == nil {
			fmt.println("gpu-composite: CreateGPUSampler failed:", sdl.GetError())
			return
		}

		vs := sdl.CreateGPUShader(p.device, sdl.GPUShaderCreateInfo {
			code_size = uint(len(quad_vertex_spirv)), code = raw_data(quad_vertex_spirv),
			entrypoint = "main", format = {.SPIRV}, stage = .VERTEX, num_uniform_buffers = 1,
		})
		fs := sdl.CreateGPUShader(p.device, sdl.GPUShaderCreateInfo {
			code_size = uint(len(blit_box_fragment_spirv)), code = raw_data(blit_box_fragment_spirv),
			entrypoint = "main", format = {.SPIRV}, stage = .FRAGMENT, num_samplers = 1, num_uniform_buffers = 1,
		})
		defer sdl.ReleaseGPUShader(p.device, vs)
		defer sdl.ReleaseGPUShader(p.device, fs)
		if vs == nil || fs == nil {
			fmt.println("gpu-composite: CreateGPUShader failed:", sdl.GetError())
			return
		}
		target := sdl.GPUColorTargetDescription {
			format = .R8G8B8A8_UNORM, blend_state = {enable_blend = false},
		}
		p.pipeline = sdl.CreateGPUGraphicsPipeline(p.device, sdl.GPUGraphicsPipelineCreateInfo {
			vertex_shader = vs, fragment_shader = fs, primitive_type = .TRIANGLELIST,
			rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE, enable_depth_clip = true},
			multisample_state = {sample_count = ._1},
			target_info = {color_target_descriptions = &target, num_color_targets = 1},
		})
		if p.pipeline == nil {
			fmt.println("gpu-composite: CreateGPUGraphicsPipeline failed:", sdl.GetError())
			return
		}
		p.stage = sdl.CreateGPUTexture(p.device, sdl.GPUTextureCreateInfo {
			type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER},
			width = GPU_COMPOSITE_W, height = GPU_COMPOSITE_H, layer_count_or_depth = 1,
			num_levels = 1, sample_count = ._1,
		})
		p.canvas = sdl.CreateGPUTexture(p.device, sdl.GPUTextureCreateInfo {
			type = .D2, format = .R8G8B8A8_UNORM, usage = {.COLOR_TARGET},
			width = GPU_COMPOSITE_W, height = GPU_COMPOSITE_H, layer_count_or_depth = 1,
			num_levels = 1, sample_count = ._1,
		})
		if p.stage == nil || p.canvas == nil {
			fmt.println("gpu-composite: CreateGPUTexture failed:", sdl.GetError())
			return
		}
		ok = true
		return
	}

	gpu_composite_teardown :: proc(p: ^GPU_Composite_Probe) {
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
		if p.video_initialized {
			sdl.Quit()
		}
		p.video_initialized = false
	}

	// gpu_composite_run uploads the stage once, draws every op in order into the
	// canvas (first pass clears, the rest load), then downloads the canvas.
	gpu_composite_run :: proc(p: ^GPU_Composite_Probe, stage: []u8, out: []u8) -> bool {
		device := p.device
		w, h := GPU_COMPOSITE_W, GPU_COMPOSITE_H
		flat := int(w) * int(h) * 4

		if p.up_tb == nil {
			p.up_tb = sdl.CreateGPUTransferBuffer(device, sdl.GPUTransferBufferCreateInfo {
				usage = .UPLOAD, size = u32(flat),
			})
		}
		if p.down_tb == nil {
			p.down_tb = sdl.CreateGPUTransferBuffer(device, sdl.GPUTransferBufferCreateInfo {
				usage = .DOWNLOAD, size = u32(flat),
			})
		}
		mapped := sdl.MapGPUTransferBuffer(device, p.up_tb, true)
		if mapped == nil {
			return false
		}
		copy(([^]u8)(mapped)[:flat], stage)
		sdl.UnmapGPUTransferBuffer(device, p.up_tb)

		cb := sdl.AcquireGPUCommandBuffer(device)
		if cb == nil {
			return false
		}
		cp := sdl.BeginGPUCopyPass(cb)
		sdl.UploadToGPUTexture(
			cp,
			sdl.GPUTextureTransferInfo {transfer_buffer = p.up_tb, pixels_per_row = u32(w), rows_per_layer = u32(h)},
			sdl.GPUTextureRegion {texture = p.stage, w = u32(w), h = u32(h), d = 1},
			false,
		)
		sdl.EndGPUCopyPass(cp)

		ops := GPU_COMPOSITE_OPS
		for i in 0 ..< len(ops) {
			op := ops[i]
			load := sdl.GPULoadOp.LOAD
			if i == 0 {
				load = .CLEAR
			}
			color_target := sdl.GPUColorTargetInfo {
				texture = p.canvas, load_op = load, store_op = .STORE,
				clear_color = {0.047, 0.133, 0.220, 1.0}, // {12, 34, 56, 255} == bg
			}
			pass := sdl.BeginGPURenderPass(cb, &color_target, 1, nil)
			if pass == nil {
				_ = sdl.CancelGPUCommandBuffer(cb)
				return false
			}
			sdl.SetGPUViewport(pass, sdl.GPUViewport{x = 0, y = 0, w = f32(w), h = f32(h), min_depth = 0, max_depth = 1})
			sdl.BindGPUGraphicsPipeline(pass, p.pipeline)
			binding := sdl.GPUTextureSamplerBinding{texture = p.stage, sampler = p.sampler}
			sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
			u := Quad_Uniforms {
				bounds   = {f32(op.ox), f32(op.oy), f32(op.rw), f32(op.rh)},
				viewport = {f32(w), f32(h)},
				uv       = {
					f32(op.sx) / f32(GPU_COMPOSITE_W),
					f32(op.sy) / f32(GPU_COMPOSITE_H),
					(f32(op.sx) + f32(op.sw)) / f32(GPU_COMPOSITE_W),
					(f32(op.sy) + f32(op.sh)) / f32(GPU_COMPOSITE_H),
				},
			}
			sdl.PushGPUVertexUniformData(cb, 0, &u, u32(size_of(u)))
			// Fragment stage: the composite pipeline blends, so the layer alpha
			// must be pushed for every draw. This probe measures the resample seam
			// at full opacity.
			fo := Blit_Opacity_Uniforms{opacity = 1.0}
			sdl.PushGPUFragmentUniformData(cb, 0, &fo, u32(size_of(fo)))
			sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
			sdl.EndGPURenderPass(pass)
		}

		cp2 := sdl.BeginGPUCopyPass(cb)
		sdl.DownloadFromGPUTexture(
			cp2,
			sdl.GPUTextureRegion {texture = p.canvas, w = u32(w), h = u32(h), d = 1},
			sdl.GPUTextureTransferInfo {transfer_buffer = p.down_tb, pixels_per_row = u32(w), rows_per_layer = u32(h)},
		)
		sdl.EndGPUCopyPass(cp2)
		if !sdl.SubmitGPUCommandBuffer(cb) {
			fmt.println("gpu-composite: SubmitGPUCommandBuffer failed:", sdl.GetError())
			return false
		}
		if !sdl.WaitForGPUIdle(device) {
			fmt.println("gpu-composite: WaitForGPUIdle failed:", sdl.GetError())
			return false
		}
		back := sdl.MapGPUTransferBuffer(device, p.down_tb, true)
		if back == nil {
			return false
		}
		copy(out, ([^]u8)(back)[:flat])
		sdl.UnmapGPUTransferBuffer(device, p.down_tb)
		return true
	}

	// Topmost-op mask: kind per canvas pixel, painted in draw order.
	GPU_COMPOSITE_MASK_BG :: 0xFF

	gpu_composite_mask :: proc(mask: []u8) {
		// The mask array is big enough by construction; a smaller one would make
		// the overlap check below walk off it, so assert instead of clamping.
		assert(len(mask) >= GPU_COMPOSITE_W * GPU_COMPOSITE_H)
		for i in 0 ..< len(mask) {
			mask[i] = GPU_COMPOSITE_MASK_BG
		}
		ops := GPU_COMPOSITE_OPS
		for i in 0 ..< len(ops) {
			op := ops[i]
			top := max(op.oy, 0)
			bottom := min(op.oy + op.rh, GPU_COMPOSITE_H)
			left := max(op.ox, 0)
			right := min(op.ox + op.rw, GPU_COMPOSITE_W)
			if bottom <= top || right <= left {
				continue
			}
			for y in top ..< bottom {
				for x in left ..< right {
					mask[y * GPU_COMPOSITE_W + x] = u8(i)
				}
			}
		}
	}

	gpu_composite_probe_run :: proc() -> int {
		w, h := GPU_COMPOSITE_W, GPU_COMPOSITE_H
		flat := w * h * 4

		// Stage: smooth deterministic content. The downscale ops compare the GPU
		// and CPU kernels, and those two disagree by one tap's worth of coverage --
		// a difference that is ~0.1 mean on correlated (video-like) content but
		// large on independent per-byte noise, where adjacent texels carry no
		// information about each other. full-amplitude LCG is the worst case for
		// kernel agreement and hides the real question (is the composite right,
		// z-order, clipping, offsets) behind "kernels differ on noise". The COPY
		// exactness check is content-independent and still proves the plumbing.
		stage := make([]u8, flat)
		defer delete(stage)
		for y in 0 ..< GPU_COMPOSITE_H {
			for x in 0 ..< GPU_COMPOSITE_W {
				i := (y * GPU_COMPOSITE_W + x) * 4
				stage[i + 0] = u8(128 + int(100 * math.sin(f64(x) * 0.42 + f64(y) * 0.17)))
				stage[i + 1] = u8(128 + int(90 * math.sin(f64(x) * 0.19 - f64(y) * 0.31)))
				stage[i + 2] = u8(128 + int(110 * math.sin(f64(x + y) * 0.093)))
				stage[i + 3] = 255
			}
		}

		cpu := make([]u8, flat)
		defer delete(cpu)
		cpu_bg := [4]u8{12, 34, 56, 255}
		for i in 0 ..< len(cpu) / 4 {
			copy(cpu[i * 4:], cpu_bg[:])
		}

		kres := make([]u8, 64 * 64 * 4)
		defer delete(kres)

		mask := make([]u8, w * h)
		defer delete(mask)
		gpu_composite_mask(mask)

		// CPU composite: keep the ship logic -- render_blit_region for copies,
		// rgba_resample into a scratch rect then blit for downscales.
		ops := GPU_COMPOSITE_OPS
		for i in 0 ..< len(ops) {
			op := ops[i]
			switch op.kind {
			case .COPY1:
				render_blit_region(cpu, c.int(w), c.int(h), stage, c.int(w),
					c.int(op.sx), c.int(op.sy), c.int(op.ox), c.int(op.oy), c.int(op.rw), c.int(op.rh), 1.0)
			case .DOWN:
				if !yuvconv.rgba_resample(
					raw_data(stage), w * 4,
					op.sx, op.sy, op.sw, op.sh,
					raw_data(kres), op.rw * 4,
					op.rw, op.rh,
				) {
					fmt.println("gpu-composite: rgba_resample failed")
					return 1
				}
				render_blit_region(cpu, c.int(w), c.int(h), kres, c.int(op.rw),
					0, 0, c.int(op.ox), c.int(op.oy), c.int(op.rw), c.int(op.rh), 1.0)
			}
		}

		p, ok := gpu_composite_setup()
		if !ok {
			fmt.println("gpu-composite: setup failed")
			return 1
		}
		defer gpu_composite_teardown(&p)
		gpu := make([]u8, flat)
		defer delete(gpu)
		if !gpu_composite_run(&p, stage, gpu) {
			fmt.println("gpu-composite: run failed")
			return 1
		}

		// Per-pixel comparison against the topmost-op mask.
		if os.get_env_alloc("VYPER_GPU_COMPOSITE_DEBUG", context.temp_allocator) == "1" {
			// Dump one row inside op2 (a DOWN region) on both sides so a systematic
			// coverage offset can be read off the two byte rows directly.
			for dy in 21 ..< 25 {
				fmt.printf("gc y=%d cpu:", dy)
				for x in 20 ..< 32 {
					fmt.printf(" %3d", cpu[(dy * w + x) * 4])
				}
				fmt.println()
				fmt.printf("gc y=%d gpu:", dy)
				for x in 20 ..< 32 {
					fmt.printf(" %3d", gpu[(dy * w + x) * 4])
				}
				fmt.println()
			}
		}
		exact_mismatch := 0
		down_n := 0
		down_abs_sum := 0
		down_over2 := 0
		first := 0
		for y in 0 ..< h {
			for x in 0 ..< w {
				top := mask[y * w + x]
				kind := GPU_Composite_Op_Kind.COPY1
				if top != GPU_COMPOSITE_MASK_BG {
					kind = ops[int(top)].kind
				}
				for ch in 0 ..< 4 {
					gi := (y * w + x) * 4 + ch
					a := int(cpu[gi])
					b := int(gpu[gi])
					switch kind {
					case .COPY1:
						if a != b {
							exact_mismatch += 1
							if first < 8 {
								fmt.println("gpu-composite: exact mismatch at x =", x, "y =", y, "ch =", ch, "cpu =", a, "gpu =", b)
								first += 1
							}
						}
					case .DOWN:
						down_n += 1
						d := abs(a - b)
						down_abs_sum += d
						if d > 2 {
							down_over2 += 1
						}
					}
				}
			}
		}
		down_mean := f64(down_abs_sum) / f64(max(down_n, 1))
		down_pct := f64(down_over2) / f64(max(down_n, 1))

		fmt.println("gpu-composite: exact mismatches =", exact_mismatch,
			"| down pixels =", down_n, "mean =", fmt.tprintf("%.3f", down_mean),
			"| >2 =", fmt.tprintf("%.4f", down_pct))
		if exact_mismatch > 0 || down_mean > 0.2 || down_pct > 0.01 {
			fmt.println("gpu-composite: FAIL")
			return 1
		}
		fmt.println("gpu-composite:", len(GPU_COMPOSITE_OPS), "ops, byte-exact region ok, resample regions within contract")
		return 0
	}
}
