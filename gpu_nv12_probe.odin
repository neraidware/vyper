// GPU RGBA->NV12 byte-exactness probe (VYPER_GPU_NV12_PROBE=1).
//
// This is the gate S1c's shader cannot exist without. Once preview and export
// share the RGBA->NV12 conversion, keyed_export's 1.0x anchor reports
// PSNR=inf and stops being able to see a wrong conversion at all, so a direct
// byte-for-byte comparison has to carry that job. This probe IS that
// comparison: one deterministic RGBA frame goes three ways -- through the
// exporter's own swscale context, through the CPU reference (yuv_exact.odin),
// and through the GPU (nv12_luma.frag + nv12_chroma.frag) -- and all three
// must agree on every byte of the full NV12 frame.
//
// The shader-vs-reference pair is asserted as well as shader-vs-swscale, not
// instead of it. Shader and reference share the coefficients and could both
// drift from shipping behavior together; shader-vs-swscale alone would catch
// that, but loses which side moved. Both relationships are checked.

package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import avutil "vendor/ffmpeg/avutil"
import sws "vendor/ffmpeg/swscale"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	// The probe's own copies. The app's copies live in render_gpu.odin, which is
	// where the NV12 pipeline is actually built -- they were declared HERE, so
	// gating this file took the app's shaders with it.
	nv12_probe_luma_spirv := #load("shaders/nv12_luma.frag.spv")
	nv12_probe_chroma_spirv := #load("shaders/nv12_chroma.frag.spv")

	// The probe copies back into RGBA8 targets even though the output is NV12,
	// and packs the two planes itself. Reason: R8/R8G8 render-target support is
	// driver-optional in Vulkan, and an unsupported color-target format would fail
	// the probe with "not really a GPU problem". The unorm8 quantization the
	// targets impose is the same quantization the shaders specified, so exactness
	// is preserved: a byte written as y/255 round-trips to y.
	//
	// A later stage that writes NV12 in one GPU pass can drop the pack -- the R8/
	// RG8 target formats are a driver-availability question, not a correctness one,
	// and nothing in this probe's exactness claim depends on the target format.
	GPU_NV12_Probe :: struct {
		device:     ^sdl.GPUDevice,
		sampler:    ^sdl.GPUSampler,
		luma_pipe:  ^sdl.GPUGraphicsPipeline,
		chroma_pipe: ^sdl.GPUGraphicsPipeline,
		src_tex:    ^sdl.GPUTexture,
		luma_tex:   ^sdl.GPUTexture,
		chroma_tex: ^sdl.GPUTexture,
		up_tb:      ^sdl.GPUTransferBuffer,
		down_tb:    ^sdl.GPUTransferBuffer,
		video_initialized: bool,
		w:          c.int,
		h:          c.int,
	}

	gpu_nv12_setup :: proc(w, h: c.int) -> (p: GPU_NV12_Probe, ok: bool) {
		p.w, p.h = w, h

		if !sdl.Init(sdl.INIT_VIDEO) {
			fmt.println("gpu-nv12: SDL_Init(VIDEO) failed:", sdl.GetError())
			return
		}
		p.video_initialized = true

		// Identical bootstrap to gpu_resample_probe.odin: the GPU device belongs to
		// the video subsystem, and the software-rasterizer warning below is why a
		// green run on llvmpipe must not be read as a GPU measurement.
		p.device = sdl.CreateGPUDevice({.SPIRV}, false, nil)
		if p.device == nil {
			p.device = sdl.CreateGPUDevice({.SPIRV}, false, "vulkan")
		}
		if p.device == nil {
			fmt.println("gpu-nv12: CreateGPUDevice failed:", sdl.GetError())
			return
		}
		adapter := sdl.GetGPUDeviceDriver(p.device)
		device_name := string(sdl.GetStringProperty(sdl.GetGPUDeviceProperties(p.device), "SDL.gpu.device.name", "<unknown>"))
		software := false
		for token in SOFTWARE_RASTERIZER_NAMES {
			if strings.contains(device_name, token) {
				software = true
			}
		}
		fmt.println("gpu-nv12: adapter =", device_name, "| backend =", adapter)
		if software {
			fmt.println("gpu-nv12: WARNING SOFTWARE RASTERIZER -- no GPU did this work")
		}

		// NEAREST, and it must stay that way. texelFetch ignores filtering, so the
		// sampler choice cannot affect the bytes, but LINEAR would let the *idea*
		// creep into the swap-in later; a filtered sampling of a subsample stage is
		// a different kernel, and the whole point here is that there is exactly one
		// kernel (the shader's).
		p.sampler = sdl.CreateGPUSampler(p.device, sdl.GPUSamplerCreateInfo {
			min_filter     = .NEAREST,
			mag_filter     = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE,
			address_mode_v = .CLAMP_TO_EDGE,
			address_mode_w = .CLAMP_TO_EDGE,
		})
		if p.sampler == nil {
			fmt.println("gpu-nv12: CreateGPUSampler failed:", sdl.GetError())
			return
		}

		boot_pipeline :: proc(
			device: ^sdl.GPUDevice,
			frag_spirv: []u8,
			format: sdl.GPUTextureFormat,
		) -> ^sdl.GPUGraphicsPipeline {
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
				fmt.println("gpu-nv12: CreateGPUShader failed:", sdl.GetError())
				return nil
			}
			target := sdl.GPUColorTargetDescription {
				format      = format,
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
				fmt.println("gpu-nv12: CreateGPUGraphicsPipeline failed:", sdl.GetError())
			}
			return pipe
		}
		p.luma_pipe = boot_pipeline(p.device, nv12_probe_luma_spirv, .R8_UNORM)
		if p.luma_pipe != nil {
			p.chroma_pipe = boot_pipeline(p.device, nv12_probe_chroma_spirv, .R8_UNORM)
		}
		if p.luma_pipe == nil || p.chroma_pipe == nil {
			return
		}

		p.src_tex = sdl.CreateGPUTexture(p.device, sdl.GPUTextureCreateInfo {
			type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER},
			width = u32(w), height = u32(h), layer_count_or_depth = 1,
			num_levels = 1, sample_count = ._1,
		})
		p.luma_tex = sdl.CreateGPUTexture(p.device, sdl.GPUTextureCreateInfo {
			type = .D2, format = .R8_UNORM, usage = {.COLOR_TARGET},
			width = u32(w), height = u32(h), layer_count_or_depth = 1,
			num_levels = 1, sample_count = ._1,
		})
		// 2*uv_w wide, which for even w is just w: the shader writes U and V into
		// adjacent R8 texels so a single-channel target can carry NV12's
		// interleaved chroma plane. (uv_w == w/2, so 2*uv_w == w.)
		p.chroma_tex = sdl.CreateGPUTexture(p.device, sdl.GPUTextureCreateInfo {
			type = .D2, format = .R8_UNORM, usage = {.COLOR_TARGET},
			width = u32(w), height = u32(h / 2), layer_count_or_depth = 1,
			num_levels = 1, sample_count = ._1,
		})
		if p.src_tex == nil || p.luma_tex == nil || p.chroma_tex == nil {
			fmt.println("gpu-nv12: CreateGPUTexture failed:", sdl.GetError())
			return
		}
		ok = true
		return
	}

	gpu_nv12_teardown :: proc(p: ^GPU_NV12_Probe) {
		if p.device == nil {
			return
		}
		if p.up_tb != nil {
			sdl.ReleaseGPUTransferBuffer(p.device, p.up_tb)
		}
		if p.down_tb != nil {
			sdl.ReleaseGPUTransferBuffer(p.device, p.down_tb)
		}
		sdl.ReleaseGPUTexture(p.device, p.src_tex)
		sdl.ReleaseGPUTexture(p.device, p.luma_tex)
		sdl.ReleaseGPUTexture(p.device, p.chroma_tex)
		sdl.ReleaseGPUGraphicsPipeline(p.device, p.luma_pipe)
		sdl.ReleaseGPUGraphicsPipeline(p.device, p.chroma_pipe)
		sdl.ReleaseGPUSampler(p.device, p.sampler)
		sdl.DestroyGPUDevice(p.device)
		p.device = nil
		if p.video_initialized {
			sdl.Quit()
		}
		p.video_initialized = false
	}

	// gpu_nv12_run converts `rgba` (w*h*4, one tightly packed frame) on the GPU and
	// returns the packed NV12 frame in `out` (w*h luma + (w/2)*(h/2)*2 interleaved
	// UV). Out lives on the caller's cursor; this proc never touches the general
	// allocator.
	gpu_nv12_run :: proc(p: ^GPU_NV12_Probe, rgba: []u8, out: []u8) -> bool {
		device := p.device
		w, h := p.w, p.h
		uv_w, uv_h := w / 2, h / 2
		src_bytes := int(w) * int(h) * 4
		down_bytes := int(w) * int(h) * 3 / 2
		luma_bytes := int(w) * int(h)
		// The two R8 planes must tile the NV12 frame exactly. Asserted rather than
		// assumed: a mismatch here silently reads a short chroma plane as garbage
		// in the last rows, which is exactly how the previous mis-sizing presented.
		assert(
			luma_bytes + int(uv_w) * int(uv_h) * 2 == down_bytes,
			"gpu_nv12: R8 planes must sum to the NV12 frame",
		)

		up := gpu_nv12_transfer(device, &p.up_tb, src_bytes, .UPLOAD)
		if up == nil {
			return false
		}
		mapped := sdl.MapGPUTransferBuffer(device, up, true)
		if mapped == nil {
			return false
		}
		copy(([^]u8)(mapped)[:src_bytes], rgba)
		sdl.UnmapGPUTransferBuffer(device, up)

		down := gpu_nv12_transfer(device, &p.down_tb, down_bytes, .DOWNLOAD)
		if down == nil {
			return false
		}

		cb := sdl.AcquireGPUCommandBuffer(device)
		if cb == nil {
			return false
		}
		cp := sdl.BeginGPUCopyPass(cb)
		sdl.UploadToGPUTexture(
			cp,
			sdl.GPUTextureTransferInfo {
				transfer_buffer = up, pixels_per_row = u32(w), rows_per_layer = u32(h),
			},
			sdl.GPUTextureRegion {texture = p.src_tex, w = u32(w), h = u32(h), d = 1},
			false,
		)
		sdl.EndGPUCopyPass(cp)

		render_one :: proc(
			device: ^sdl.GPUDevice,
			cb: ^sdl.GPUCommandBuffer,
			pipe: ^sdl.GPUGraphicsPipeline,
			sampler: ^sdl.GPUSampler,
			src_tex: ^sdl.GPUTexture,
			target: ^sdl.GPUTexture,
			tw, th: u32,
		) -> bool {
			color_target := sdl.GPUColorTargetInfo {
				texture     = target,
				load_op     = .CLEAR,
				store_op    = .STORE,
				clear_color = {0, 0, 0, 1},
			}
			pass := sdl.BeginGPURenderPass(cb, &color_target, 1, nil)
			if pass == nil {
				return false
			}
			vp := sdl.GPUViewport{x = 0, y = 0, w = f32(tw), h = f32(th), min_depth = 0.0, max_depth = 1.0}
			sdl.SetGPUViewport(pass, vp)
			sdl.BindGPUGraphicsPipeline(pass, pipe)
			binding := sdl.GPUTextureSamplerBinding{texture = src_tex, sampler = sampler}
			sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
			u := Quad_Uniforms {
				bounds   = {0, 0, f32(tw), f32(th)},
				viewport = {f32(tw), f32(th)},
				uv       = {0, 0, 1, 1},
			}
			sdl.PushGPUVertexUniformData(cb, 0, &u, u32(size_of(u)))
			sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
			sdl.EndGPURenderPass(pass)
			return true
		}
		if !render_one(device, cb, p.luma_pipe, p.sampler, p.src_tex, p.luma_tex, u32(w), u32(h)) {
			_ = sdl.CancelGPUCommandBuffer(cb)
			return false
		}
		// Chroma viewport is the TARGET width (2*uv_w), not the sample count: the
		// pass writes one texel per U or V byte so the pair lands adjacently.
		if !render_one(device, cb, p.chroma_pipe, p.sampler, p.src_tex, p.chroma_tex, u32(uv_w * 2), u32(uv_h)) {
			_ = sdl.CancelGPUCommandBuffer(cb)
			return false
		}

		cp2 := sdl.BeginGPUCopyPass(cb)
		sdl.DownloadFromGPUTexture(
			cp2,
			sdl.GPUTextureRegion {texture = p.luma_tex, w = u32(w), h = u32(h), d = 1},
			sdl.GPUTextureTransferInfo {
				transfer_buffer = down, offset = 0, pixels_per_row = u32(w), rows_per_layer = u32(h),
			},
		)
		sdl.DownloadFromGPUTexture(
			cp2,
			sdl.GPUTextureRegion {texture = p.chroma_tex, w = u32(uv_w * 2), h = u32(uv_h), d = 1},
			sdl.GPUTextureTransferInfo {
				transfer_buffer = down, offset = u32(luma_bytes), pixels_per_row = u32(uv_w * 2), rows_per_layer = u32(uv_h),
			},
		)
		sdl.EndGPUCopyPass(cp2)
		if !sdl.SubmitGPUCommandBuffer(cb) {
			fmt.println("gpu-nv12: SubmitGPUCommandBuffer failed:", sdl.GetError())
			return false
		}
		// Submit + idle + map is the sync point, same as the resample probe.
		if !sdl.WaitForGPUIdle(device) {
			fmt.println("gpu-nv12: WaitForGPUIdle failed:", sdl.GetError())
			return false
		}
		back := sdl.MapGPUTransferBuffer(device, down, true)
		if back == nil {
			return false
		}
		// R8 targets: the download is already NV12 -- luma contiguous from 0,
		// chroma interleaved from w*h -- so it is a straight copy with no unpack.
		// Anything that needed a pack loop here would mean the passes were not
		// writing NV12 order, which is the bug this probe exists to catch.
		copy(out[:down_bytes], ([^]u8)(back)[:down_bytes])
		sdl.UnmapGPUTransferBuffer(device, down)
		return true
	}

	// gpu_nv12_transfer is transfer_of without carrying capacity: the probe creates
	// transfer buffers sized exactly once per geometry, so growth is a non-issue.
	gpu_nv12_transfer :: proc(
		device: ^sdl.GPUDevice,
		tb: ^^sdl.GPUTransferBuffer,
		size: int,
		usage: sdl.GPUTransferBufferUsage,
	) -> ^sdl.GPUTransferBuffer {
		if tb^ == nil {
			tb^ = sdl.CreateGPUTransferBuffer(device, sdl.GPUTransferBufferCreateInfo {
				usage = usage,
				size  = u32(size),
			})
		}
		return tb^
	}

	gpu_nv12_probe_run :: proc() -> int {
		sizes := []c.int{8, 16, 32, 64, 96, 128, 160, 224, 256}
		failures := 0

		for w in sizes {
			h := w
			uv_w := w / 2
			uv_h := h / 2
			rgba := make([]u8, int(w) * int(h) * 4)
			defer delete(rgba)
			yuv_probe_fill_rgba(rgba, 0x9e3779b9)

			y_ls := yuv_probe_linesize(w)
			buf := make([]u8, int(y_ls) * (int(h) + int(uv_h)))
			defer delete(buf)
			data: [4][^]u8 = {raw_data(buf), raw_data(buf[int(y_ls) * int(h):]), nil, nil}
			ls: [4]c.int = {y_ls, y_ls, 0, 0}
			ctx: ^sws.Context
			if !yuv_probe_convert(rgba, w, h, &data, &ls, &ctx) {
				fmt.println("gpu-nv12: sws.scale failed at", w)
				return 1
			}
			defer sws.freeContext(ctx)

			ref := make([]u8, int(y_ls) * (int(h) + int(uv_h)))
			defer delete(ref)
			scratch_n := ((int(w) + 1) / 2) * int(h)
			su := make([]i32, scratch_n)
			defer delete(su)
			sv := make([]i32, scratch_n)
			defer delete(sv)
			yuv_ref_rgba_to_nv12(rgba, int(w), int(h), int(y_ls), int(y_ls), ref, su, sv)

			p, ok := gpu_nv12_setup(w, h)
			if !ok {
				fmt.println("gpu-nv12: setup failed at", w)
				return 1
			}
			g_out := make([]u8, int(w) * int(h) * 3 / 2)
			defer delete(g_out)
			if !gpu_nv12_run(&p, rgba, g_out) {
				fmt.println("gpu-nv12: run failed at", w)
				gpu_nv12_teardown(&p)
				return 1
			}
			gpu_nv12_teardown(&p)

			// Three-way compare, plane by plane, over only the regions swscale
			// writes (row padding tails excluded -- same rule as the yuv probe).
			uv_w_i := int(uv_w)
			uv_h_i := int(uv_h)
			count_gpu := 0
			count_ref := 0
			first := 0
			for y in 0 ..< int(h) {
				for x in 0 ..< int(w) {
					a := buf[int(y) * int(y_ls) + int(x)]
					bg := g_out[int(y) * int(w) + int(x)]
					br := ref[int(y) * int(y_ls) + int(x)]
					if a != bg {
						count_gpu += 1
						if first < 8 {
							fmt.println("luma", w, "x =", x, "y =", y, "swscale =", a, "gpu =", bg)
							first += 1
						}
					}
					if a != br {
						count_ref += 1
						if first < 8 {
							fmt.println("luma", w, "x =", x, "y =", y, "swscale =", a, "ref =", br)
							first += 1
						}
					}
				}
			}
			for k in 0 ..< uv_h_i {
				for c in 0 ..< uv_w_i {
					base := int(y_ls) * int(h) + int(k) * int(y_ls) + int(c) * 2
					gbase := int(w) * int(h) + (int(k) * uv_w_i + int(c)) * 2
					rbase := int(y_ls) * int(h) + int(k) * int(y_ls) + int(c) * 2
					for ch in 0 ..< 2 {
						a := buf[base + ch]
						bg := g_out[gbase + ch]
						br := ref[rbase + ch]
						if a != bg {
							count_gpu += 1
							if first < 8 {
								fmt.println("uv", w, "c =", c, "row =", k, "ch =", ch, "swscale =", a, "gpu =", bg)
								first += 1
							}
						}
						if a != br {
							count_ref += 1
							if first < 8 {
								fmt.println("uv", w, "c =", c, "row =", k, "ch =", ch, "swscale =", a, "ref =", br)
								first += 1
							}
						}
					}
				}
			}

			if count_gpu == 0 && count_ref == 0 {
				fmt.println("gpu-nv12:", w, "x", h, "ok")
			} else {
				fmt.println("gpu-nv12:", w, "x", h, "gpu mismatches =", count_gpu, "ref mismatches =", count_ref)
				failures += 1
			}
		}
		if failures > 0 {
			return 1
		}
		return 0
	}
}
