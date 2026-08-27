package main

import "core:c"
import clay "clay-odin"
import sdl "vendor:sdl3"
import stb "vendor:stb/truetype"

// ---------------------------------------------------------------------------
// Per-frame GPU draw calls: translating Clay render commands into SDF rect/
// text draws, uploading decoded preview frames, and compositing the preview.
// ---------------------------------------------------------------------------

render_clay :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, commands: clay.ClayArray(clay.RenderCommand)) {
	array := commands
	for i in 0..<commands.length {
		command := clay.RenderCommandArray_Get(&array, i)
		bounds := command.boundingBox

		#partial switch command.commandType {
		case .Rectangle:
			config := command.renderData.rectangle
			color := config.backgroundColor
			if command.id == clay.ID("OpenFileButton").id && clay.PointerOver(clay.ID("OpenFileButton")) {
				color = BUTTON_HOVER
			}
			render_sdf_rect(renderer, command_buffer, pass, bounds, color, config.cornerRadius.topLeft, 0)
		case .Border:
			config := command.renderData.border
			color := config.color
			if command.id == clay.ID("OpenFileButton").id && clay.PointerOver(clay.ID("OpenFileButton")) {
				color = BUTTON_BORDER_HOVER
			}
			render_sdf_rect(renderer, command_buffer, pass, bounds, color, config.cornerRadius.topLeft, f32(config.width.left))
		case .Text:
			render_text(renderer, command_buffer, pass, bounds, command.renderData.text)
		}
	}
}

render_text :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, bounds: clay.BoundingBox, text: clay.TextRenderData) {
	if renderer.font.texture == nil || renderer.text_pipeline == nil {
		return
	}

	// Clay's text command gives us the laid-out origin. stb's baked quad uses a
	// baseline origin, so start one font height below that origin.
	scale := f32(text.fontSize) / 32.0
	x: f32 = 0
	baseline: f32 = 32
	line_height := f32(text.lineHeight)
	if line_height <= 0 {
		line_height = f32(text.fontSize)
	}
	sdl.BindGPUGraphicsPipeline(pass, renderer.text_pipeline)
	binding := sdl.GPUTextureSamplerBinding{texture = renderer.font.texture, sampler = renderer.font.sampler}
	sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
	for i in 0..<text.stringContents.length {
		code := u8(text.stringContents.chars[i])
		if code == '\n' {
			x = 0
			baseline += line_height / scale
			continue
		}
		if code < 32 || code > 126 {
			continue
		}
		quad: stb.aligned_quad
		stb.GetBakedQuad(&renderer.font.chars[0], 512, 512, c.int(code - 32), &x, &baseline, &quad, false)
		quad_bounds := clay.BoundingBox{x = bounds.x + quad.x0 * scale, y = bounds.y + quad.y0 * scale, width = (quad.x1 - quad.x0) * scale, height = (quad.y1 - quad.y0) * scale}
		vertex_uniforms := TextVertexUniforms{
			bounds = {quad_bounds.x, quad_bounds.y, quad_bounds.width, quad_bounds.height},
			viewport = renderer.viewport,
			_padding = {},
			uv = {quad.s0, quad.t0, quad.s1, quad.t1},
		}
		color := text.textColor
		fragment_uniforms := TextFragmentUniforms{color = {f32(color[0]) / 255, f32(color[1]) / 255, f32(color[2]) / 255, f32(color[3]) / 255}}
		sdl.PushGPUVertexUniformData(command_buffer, 0, &vertex_uniforms, sdl.Uint32(size_of(vertex_uniforms)))
		sdl.PushGPUFragmentUniformData(command_buffer, 0, &fragment_uniforms, sdl.Uint32(size_of(fragment_uniforms)))
		sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
		x += f32(text.letterSpacing) / scale
	}
}

render_sdf_rect :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, bounds: clay.BoundingBox, color: clay.Color, radius, border: f32) {
	vertex_uniforms := RectVertexUniforms{
		bounds = {bounds.x, bounds.y, bounds.width, bounds.height},
		viewport = renderer.viewport,
	}
	fragment_uniforms := RectFragmentUniforms{
		color = {f32(color[0]) / 255, f32(color[1]) / 255, f32(color[2]) / 255, f32(color[3]) / 255},
		shape = {bounds.width, bounds.height, radius, border},
	}
	sdl.PushGPUVertexUniformData(command_buffer, 0, &vertex_uniforms, sdl.Uint32(size_of(vertex_uniforms)))
	sdl.PushGPUFragmentUniformData(command_buffer, 0, &fragment_uniforms, sdl.Uint32(size_of(fragment_uniforms)))
	sdl.BindGPUGraphicsPipeline(pass, renderer.pipeline)
	sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
}

// upload_preview_slot copies tightly-packed RGBA pixels into a slot's GPU
// texture using a transfer buffer + copy pass on the given command buffer.
upload_preview_slot :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, slot: ^Preview_Slot) {
	if slot.texture == nil {
		return
	}
	transfer := sdl.CreateGPUTransferBuffer(renderer.device, sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = PREVIEW_W * PREVIEW_H * 4})
	if transfer == nil {
		return
	}
	defer sdl.ReleaseGPUTransferBuffer(renderer.device, transfer)
	mapped := sdl.MapGPUTransferBuffer(renderer.device, transfer, false)
	if mapped == nil {
		return
	}
	dst := ([^]u8)(mapped)[:PREVIEW_W * PREVIEW_H * 4]
	copy(dst, slot.buffer[:])
	sdl.UnmapGPUTransferBuffer(renderer.device, transfer)
	copy_pass := sdl.BeginGPUCopyPass(command_buffer)
	source := sdl.GPUTextureTransferInfo{transfer_buffer = transfer, pixels_per_row = PREVIEW_W, rows_per_layer = PREVIEW_H}
	destination := sdl.GPUTextureRegion{texture = slot.texture, w = PREVIEW_W, h = PREVIEW_H, d = 1}
	sdl.UploadToGPUTexture(copy_pass, source, destination, false)
	sdl.EndGPUCopyPass(copy_pass)
	slot.tex_dirty = false
}

// release_preview_textures releases a renderer's per-slot preview textures.
release_preview_textures :: proc(device: ^sdl.GPUDevice, texs: []^sdl.GPUTexture) {
	for t in texs {
		sdl.ReleaseGPUTexture(device, t)
	}
}


// draw_preview draws the active video clip's frame in the given bounds, placed
// according to the clip's transform (fills the project canvas, centered at its
// x/y), then overlays a selection border around the currently-selected clip's
// image rect. The decode buffer is fixed 16:9 (PREVIEW_W x PREVIEW_H) and is
// sampled with a full UV quad.
draw_preview :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, bounds: clay.BoundingBox) {
	if renderer.preview_pipeline == nil {
		return
	}
	// Clip everything (zoomed content, background, border) to the preview window
	// so zooming/panning behaves like a scrollable viewport.
	scissor := sdl.Rect{c.int(bounds.x), c.int(bounds.y), c.int(bounds.width), c.int(bounds.height)}
	sdl.SetGPUScissor(pass, scissor)
	defer sdl.SetGPUScissor(pass, sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)})

	canvas := preview_canvas(bounds)
	// The composited/canvas area has a completely black background.
	view := preview_view(canvas)
	render_sdf_rect(renderer, command_buffer, pass, view, clay.Color{0, 0, 0, 255}, 0, 0)

	// Paint every clip covering the playhead with the top track on top. Slots
	// are assigned in track order (track 0 = top = slot 0), so draw slots in
	// reverse so the top track's clip is drawn last and appears on top.
	for i := MAX_PREVIEW_SLOTS - 1; i >= 0; i -= 1 {
		slot := &preview_slots[i]
		if !slot.in_use || slot.texture == nil {
			continue
		}
		cb := clip_image_bounds(canvas, &Clip{
			transform_x = slot.transform_x,
			transform_y = slot.transform_y,
			scale = slot.scale,
			crop_l = slot.crop_l,
			crop_r = slot.crop_r,
			crop_t = slot.crop_t,
			crop_b = slot.crop_b,
		})
		// The cropped source sub-rect (normalized UV) equals the crop fractions.
		u0 := slot.crop_l
		u1 := 1 - slot.crop_r
		v0 := slot.crop_t
		v1 := 1 - slot.crop_b
		vertex_uniforms := TextVertexUniforms{
			bounds = {cb.x, cb.y, cb.width, cb.height},
			viewport = renderer.viewport,
			_padding = {},
			uv = {u0, v0, u1, v1},
		}
		sdl.BindGPUGraphicsPipeline(pass, renderer.preview_pipeline)
		binding := sdl.GPUTextureSamplerBinding{texture = slot.texture, sampler = renderer.preview_sampler}
		sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
		sdl.PushGPUVertexUniformData(command_buffer, 0, &vertex_uniforms, sdl.Uint32(size_of(vertex_uniforms)))
		sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
	}
	// Draw a border box around the currently-selected clip's image rect.
	if selected_clip, ok := transformable_selected(); ok {
		sb := clip_image_bounds(canvas, selected_clip)
		render_sdf_rect(renderer, command_buffer, pass, sb, SELECT_BORDER, 0, 3)
		// Draw the resize/crop handles on the box (only when not editing a field).
		for h in preview_handles(sb) {
			render_sdf_rect(renderer, command_buffer, pass, h, HANDLE_FILL, 0, 1)
			render_sdf_rect(renderer, command_buffer, pass, h, HANDLE_BORDER, 0.5, 1)
		}
	}
}
