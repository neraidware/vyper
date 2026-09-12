package main

import "core:c"
import "core:fmt"
import sdl "vendor:sdl3"
import stb "vendor:stb/truetype"

// ---------------------------------------------------------------------------
// GPU pipeline/shader/texture setup: uniform layouts, renderer struct, and
// one-time creation of pipelines, the font atlas, and preview textures.
// ---------------------------------------------------------------------------

RectVertexUniforms :: struct {
	bounds: [4]f32,
	viewport: [2]f32,
	_padding: [2]f32,
}

RectFragmentUniforms :: struct {
	color: [4]f32,
	shape: [4]f32,
}

TextVertexUniforms :: struct {
	bounds:   [4]f32,
	viewport: [2]f32,
	_padding: [2]f32,
	uv:       [4]f32,
}

TextFragmentUniforms :: struct {
	color: [4]f32,
}

Font_Atlas :: struct {
	texture: ^sdl.GPUTexture,
	sampler: ^sdl.GPUSampler,
	chars:   [95]stb.bakedchar,
}

FONT_ATLAS_SIZE :: 512

GPU_Renderer :: struct {
	device: ^sdl.GPUDevice,
	pipeline: ^sdl.GPUGraphicsPipeline,
	text_pipeline: ^sdl.GPUGraphicsPipeline,
	preview_pipeline: ^sdl.GPUGraphicsPipeline,
	font: Font_Atlas,
	preview_textures: [MAX_PREVIEW_SLOTS]^sdl.GPUTexture,
	preview_sampler: ^sdl.GPUSampler,
	icon_textures: [Icon_Id]^sdl.GPUTexture,
	viewport: [2]f32,
}

rounded_rect_vertex_spirv := #load("shaders/rounded_rect.vert.spv")
rounded_rect_fragment_spirv := #load("shaders/rounded_rect.frag.spv")
text_vertex_spirv := #load("shaders/text.vert.spv")
text_fragment_spirv := #load("shaders/text.frag.spv")
preview_fragment_spirv := #load("shaders/preview.frag.spv")


create_gpu_renderer :: proc(device: ^sdl.GPUDevice, format: sdl.GPUTextureFormat, width, height: c.int) -> (result: GPU_Renderer, ok: bool) {
	result.device = device
	result.viewport = {f32(width), f32(height)}
	// If a later step fails, release everything created so far. Every return
	// below leaves ok=false, so this block runs; the success path sets ok=true
	// and keeps every handle. GPU handles are driver-managed -- no host
	// allocator or tracking to catch a leak -- and device init/reinit failure
	// (the only path that reaches here) is exactly where silent resource
	// exhaustion shows up, so each created handle is released with the same
	// nil guard the caller's teardown uses.
	defer if !ok {
		if result.pipeline != nil {
			sdl.ReleaseGPUGraphicsPipeline(device, result.pipeline)
		}
		if result.text_pipeline != nil {
			sdl.ReleaseGPUGraphicsPipeline(device, result.text_pipeline)
		}
		if result.preview_pipeline != nil {
			sdl.ReleaseGPUGraphicsPipeline(device, result.preview_pipeline)
		}
		if result.font.texture != nil {
			sdl.ReleaseGPUTexture(device, result.font.texture)
		}
		if result.font.sampler != nil {
			sdl.ReleaseGPUSampler(device, result.font.sampler)
		}
		for t in result.preview_textures {
			if t != nil {
				sdl.ReleaseGPUTexture(device, t)
			}
		}
		if result.preview_sampler != nil {
			sdl.ReleaseGPUSampler(device, result.preview_sampler)
		}
	}
	vertex_info := sdl.GPUShaderCreateInfo{
		code_size = uint(len(rounded_rect_vertex_spirv)), code = raw_data(rounded_rect_vertex_spirv),
		entrypoint = "main", format = {.SPIRV}, stage = .VERTEX, num_uniform_buffers = 1,
	}
	fragment_info := sdl.GPUShaderCreateInfo{
		code_size = uint(len(rounded_rect_fragment_spirv)), code = raw_data(rounded_rect_fragment_spirv),
		entrypoint = "main", format = {.SPIRV}, stage = .FRAGMENT, num_uniform_buffers = 1,
	}
	vertex_shader := sdl.CreateGPUShader(device, vertex_info)
	fragment_shader := sdl.CreateGPUShader(device, fragment_info)
	if vertex_shader == nil || fragment_shader == nil {
		fmt.println("GPU shader creation failed:", sdl.GetError())
		return
	}
	defer sdl.ReleaseGPUShader(device, vertex_shader)
	defer sdl.ReleaseGPUShader(device, fragment_shader)
	blend := sdl.GPUColorTargetBlendState{
		src_color_blendfactor = .SRC_ALPHA, dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA, color_blend_op = .ADD,
		src_alpha_blendfactor = .ONE, dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA, alpha_blend_op = .ADD,
		color_write_mask = {.R, .G, .B, .A}, enable_blend = true, enable_color_write_mask = true,
	}
	target := sdl.GPUColorTargetDescription{format = format, blend_state = blend}
	pipeline_info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader = vertex_shader, fragment_shader = fragment_shader,
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE, enable_depth_clip = true},
		multisample_state = {sample_count = ._1},
		target_info = {color_target_descriptions = &target, num_color_targets = 1},
	}
	pipeline := sdl.CreateGPUGraphicsPipeline(device, pipeline_info)
	if pipeline == nil {
		fmt.println("GPU pipeline creation failed:", sdl.GetError())
		return
	}
	result.pipeline = pipeline
	text_vertex_info := sdl.GPUShaderCreateInfo{
		code_size = uint(len(text_vertex_spirv)), code = raw_data(text_vertex_spirv),
		entrypoint = "main", format = {.SPIRV}, stage = .VERTEX, num_uniform_buffers = 1,
	}
	text_fragment_info := sdl.GPUShaderCreateInfo{
		code_size = uint(len(text_fragment_spirv)), code = raw_data(text_fragment_spirv),
		entrypoint = "main", format = {.SPIRV}, stage = .FRAGMENT, num_samplers = 1, num_uniform_buffers = 1,
	}
	text_vertex_shader := sdl.CreateGPUShader(device, text_vertex_info)
	text_fragment_shader := sdl.CreateGPUShader(device, text_fragment_info)
	if text_vertex_shader == nil || text_fragment_shader == nil {
		fmt.println("Text shader creation failed:", sdl.GetError())
		return
	}
	defer sdl.ReleaseGPUShader(device, text_vertex_shader)
	defer sdl.ReleaseGPUShader(device, text_fragment_shader)
	text_pipeline_info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader = text_vertex_shader, fragment_shader = text_fragment_shader, primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE, enable_depth_clip = true},
		multisample_state = {sample_count = ._1}, target_info = {color_target_descriptions = &target, num_color_targets = 1},
	}
	text_pipeline := sdl.CreateGPUGraphicsPipeline(device, text_pipeline_info)
	if text_pipeline == nil {
		fmt.println("Text pipeline creation failed:", sdl.GetError())
		return
	}
	result.text_pipeline = text_pipeline

	preview_fragment_info := sdl.GPUShaderCreateInfo{
		code_size = uint(len(preview_fragment_spirv)), code = raw_data(preview_fragment_spirv),
		entrypoint = "main", format = {.SPIRV}, stage = .FRAGMENT, num_samplers = 1,
	}
	preview_fragment_shader := sdl.CreateGPUShader(device, preview_fragment_info)
	if preview_fragment_shader == nil {
		fmt.println("Preview shader creation failed:", sdl.GetError())
		return
	}
	defer sdl.ReleaseGPUShader(device, preview_fragment_shader)
	preview_pipeline_info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader = text_vertex_shader, fragment_shader = preview_fragment_shader, primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE, enable_depth_clip = true},
		multisample_state = {sample_count = ._1}, target_info = {color_target_descriptions = &target, num_color_targets = 1},
	}
	preview_pipeline := sdl.CreateGPUGraphicsPipeline(device, preview_pipeline_info)
	if preview_pipeline == nil {
		fmt.println("Preview pipeline creation failed:", sdl.GetError())
		return
	}
	result.preview_pipeline = preview_pipeline

	font_texture := sdl.CreateGPUTexture(device, sdl.GPUTextureCreateInfo{type = .D2, format = .R8_UNORM, usage = {.SAMPLER}, width = FONT_ATLAS_SIZE, height = FONT_ATLAS_SIZE, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1})
	font_sampler := sdl.CreateGPUSampler(device, sdl.GPUSamplerCreateInfo{min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .NEAREST, address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE, max_lod = 1})
	if font_texture == nil || font_sampler == nil {
		fmt.println("Font texture or sampler creation failed:", sdl.GetError())
		return
	}
	result.font.texture = font_texture
	result.font.sampler = font_sampler
	for i in 0 ..< MAX_PREVIEW_SLOTS {
		result.preview_textures[i] = sdl.CreateGPUTexture(device, sdl.GPUTextureCreateInfo{type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER}, width = PREVIEW_W, height = PREVIEW_H, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1})
		if result.preview_textures[i] == nil {
			fmt.println("Preview texture creation failed:", sdl.GetError())
			return
		}
	}
	preview_sampler := sdl.CreateGPUSampler(device, sdl.GPUSamplerCreateInfo{min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .NEAREST, address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE, max_lod = 1})
	if preview_sampler == nil {
		fmt.println("Preview sampler creation failed:", sdl.GetError())
		return
	}
	result.preview_sampler = preview_sampler
	ok = true
	return
}

upload_font_atlas :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	transfer := sdl.CreateGPUTransferBuffer(renderer.device, sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = FONT_ATLAS_SIZE * FONT_ATLAS_SIZE})
	if transfer == nil {
		return false
	}
	mapped := sdl.MapGPUTransferBuffer(renderer.device, transfer, false)
	if mapped == nil {
		sdl.ReleaseGPUTransferBuffer(renderer.device, transfer)
		return false
	}
	stb.BakeFontBitmap(raw_data(font_data), 0, 32, cast([^]u8)mapped, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE, 32, 95, &renderer.font.chars[0])
	sdl.UnmapGPUTransferBuffer(renderer.device, transfer)
	copy_pass := sdl.BeginGPUCopyPass(command_buffer)
	source := sdl.GPUTextureTransferInfo{transfer_buffer = transfer, pixels_per_row = FONT_ATLAS_SIZE, rows_per_layer = FONT_ATLAS_SIZE}
	destination := sdl.GPUTextureRegion{texture = renderer.font.texture, w = FONT_ATLAS_SIZE, h = FONT_ATLAS_SIZE, d = 1}
	sdl.UploadToGPUTexture(copy_pass, source, destination, false)
	sdl.EndGPUCopyPass(copy_pass)
	sdl.ReleaseGPUTransferBuffer(renderer.device, transfer)
	return true
}

// upload_icons rasterizes every embedded SVG icon into its own small R8
// texture (uploaded together on the initial command buffer, before any frame).
upload_icons :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	for id in Icon_Id {
		rasterized, ok := rasterize_icon_svg(get_icon_svg(id))
		if !ok {
			fmt.println("Could not rasterize icon:", id)
			return false
		}
		defer delete(rasterized)
		texture := sdl.CreateGPUTexture(renderer.device, sdl.GPUTextureCreateInfo{type = .D2, format = .R8_UNORM, usage = {.SAMPLER}, width = ICON_RASTER, height = ICON_RASTER, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1})
		if texture == nil {
			fmt.println("Could not create icon texture:", sdl.GetError())
			return false
		}
		transfer := sdl.CreateGPUTransferBuffer(renderer.device, sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = ICON_RASTER * ICON_RASTER})
		if transfer == nil {
			sdl.ReleaseGPUTexture(renderer.device, texture)
			return false
		}
		mapped := sdl.MapGPUTransferBuffer(renderer.device, transfer, false)
		if mapped == nil {
			sdl.ReleaseGPUTexture(renderer.device, texture)
			sdl.ReleaseGPUTransferBuffer(renderer.device, transfer)
			return false
		}
		mapped_bytes := (cast([^]u8)mapped)[:ICON_RASTER * ICON_RASTER]
		assert(len(rasterized) == ICON_RASTER * ICON_RASTER, "upload_icons: rasterized icon size mismatch")
		copy(mapped_bytes, rasterized)
		sdl.UnmapGPUTransferBuffer(renderer.device, transfer)
		copy_pass := sdl.BeginGPUCopyPass(command_buffer)
		source := sdl.GPUTextureTransferInfo{transfer_buffer = transfer, pixels_per_row = ICON_RASTER, rows_per_layer = ICON_RASTER}
		destination := sdl.GPUTextureRegion{texture = texture, w = ICON_RASTER, h = ICON_RASTER, d = 1}
		sdl.UploadToGPUTexture(copy_pass, source, destination, false)
		sdl.EndGPUCopyPass(copy_pass)
		sdl.ReleaseGPUTransferBuffer(renderer.device, transfer)
		renderer.icon_textures[id] = texture
	}
	return true
}
