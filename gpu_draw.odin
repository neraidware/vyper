package main

import "core:c"
import "core:fmt"
import "core:sync"
import clay "clay-odin"
import sdl "vendor:sdl3"
import stb "vendor:stb/truetype"

// ---------------------------------------------------------------------------
// Per-frame GPU draw calls: translating Clay render commands into SDF rect/
// text draws, uploading decoded preview frames, and compositing the preview.
// ---------------------------------------------------------------------------

// draw_timeline_ruler renders the timeline ruler's tick marks and frame labels
// plus the vertical playhead line that runs from the ruler bar down through
// every track row. The ruler strip itself is a Clay element ("Ruler"); this
// proc only adds the detail Clay can't lay out cheaply.
draw_timeline_ruler :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass) {
	if len(timeline.tracks) == 0 {
		return
	}
	ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
	if ruler.width <= 0 || ruler.height <= 0 {
		return
	}
	// Everything this proc paints (ticks, labels, the playhead line, its grab
	// handle) lives horizontally inside the ruler bar; clamp it there so the
	// playhead handle can't render over the track-name gutter or off the right
	// edge. Vertically the scissor spans the whole window since the playhead
	// line runs down through every track row.
	sdl.SetGPUScissor(pass, sdl.Rect{c.int(ruler.x), c.int(ruler.y - 8), c.int(ruler.width), c.int(renderer.viewport.y)})
	defer sdl.SetGPUScissor(pass, sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)})
	dur := timeline_duration()
	// Adapt the tick spacing to the current zoom so labels stay ~70px apart.
	major := nice_frame_step(timeline_zoom)
	minor := max(major / 5, 1)

	// Tick marks along the bottom edge of the ruler strip.
	minor_h := ruler.height * 0.35
	major_h := ruler.height * 0.6
	start_f := i64(f32(i64(timeline_view_start / f32(minor))) * f32(minor))
	for f := start_f; f <= dur + 1; f += minor {
		x := ruler.x + (f32(f) - timeline_view_start) * timeline_zoom
		if x < ruler.x {
			continue
		}
		if x > ruler.x + ruler.width {
			break
		}
		is_major := f % major == 0
		tick_h := is_major ? major_h : minor_h
		render_sdf_rect(renderer, command_buffer, pass, {x, ruler.y + ruler.height - tick_h, is_major ? 2 : 1, tick_h}, RULER_TICK_COLOR, 0, 0)
		// Frame label above each major tick.
		if is_major {
			label_buf: [20]u8
			label := fmt.bprintf(label_buf[:], "%d", f)
			chars := ([^]c.char)(raw_data(label))
			slice := clay.StringSlice{length = c.int32_t(len(label)), chars = chars, baseChars = chars}
			text_data := clay.TextRenderData{stringContents = slice, textColor = RULER_LABEL_COLOR, fontSize = 11, lineHeight = 11}
			text_bounds := clay.BoundingBox{x = x + 3, y = ruler.y + 3, width = 64, height = 13}
			render_text(renderer, command_buffer, pass, text_bounds, text_data)
		}
	}

	// Vertical playhead line spanning the ruler and all track rows, plus a grab
	// handle sitting on top of the ruler strip.
	line_x := ruler.x + (f32(playhead.frame) - timeline_view_start) * timeline_zoom
	tracks := clay.GetElementData(clay.ID("TracksSection")).boundingBox
	line_bottom := ruler.y + RULER_HEIGHT + tracks.height
	render_sdf_rect(renderer, command_buffer, pass, {line_x, ruler.y, 2, line_bottom - ruler.y}, BUTTON_BORDER_HOVER, 0, 0)
	render_sdf_rect(renderer, command_buffer, pass, {line_x - 4, ruler.y - 4, 10, 10}, BUTTON_BORDER_HOVER, 2, 0)
}

// draw_render_range draws the project render range as a band sitting just below
// the timeline ruler bar, from the range's start frame to its end frame (both
// set and ordered). Each boundary also gets a cap marker, drawn independently:
// with only one boundary set its cap still appears so the I/O placement stays
// visible. Only the part inside the ruler's width is drawn.
draw_render_range :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass) {
	if len(timeline.tracks) == 0 || (project.start_frame < 0 && project.end_frame < 0) {
		return
	}
	ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
	if ruler.width <= 0 {
		return
	}
	// The band and its edge caps can stick out over the gutter when the range
	// starts before the current view; keep them inside the ruler bar's width.
	sdl.SetGPUScissor(pass, sdl.Rect{c.int(ruler.x), 0, c.int(ruler.width), c.int(renderer.viewport.y)})
	defer sdl.SetGPUScissor(pass, sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)})
	y := ruler.y + ruler.height
	isect := ruler.x + ruler.width
	if project.start_frame >= 0 && project.end_frame >= 0 && project.start_frame < project.end_frame {
		x1 := ruler.x + (f32(project.start_frame) - timeline_view_start) * timeline_zoom
		x2 := ruler.x + (f32(project.end_frame) - timeline_view_start) * timeline_zoom
		if x2 > ruler.x && x1 < isect {
			band_x := max(x1, ruler.x)
			band_w := min(x2, isect) - band_x
			if band_w > 0 {
				render_sdf_rect(renderer, command_buffer, pass, {band_x, y, band_w, 4}, RANGE_COLOR, 0, 0)
			}
		}
	}
	// Edge caps make the range boundaries readable even when the band is thin;
	// a lone start/end marker is drawn the same way so its placement is visible.
	if project.start_frame >= 0 {
		x1 := ruler.x + (f32(project.start_frame) - timeline_view_start) * timeline_zoom
		if x1 >= ruler.x && x1 <= isect {
			render_sdf_rect(renderer, command_buffer, pass, {x1, y, 2, 8}, RANGE_COLOR, 0, 0)
		}
	}
	if project.end_frame >= 0 {
		x2 := ruler.x + (f32(project.end_frame) - timeline_view_start) * timeline_zoom
		if x2 >= ruler.x && x2 <= isect {
			render_sdf_rect(renderer, command_buffer, pass, {x2 - 2, y, 2, 8}, RANGE_COLOR, 0, 0)
		}
	}
}

// nice_frame_step picks the ruler's label spacing (a round 1/2/5×10^k number)
// so that labelled ticks stay about 70px apart at the current timeline zoom.
nice_frame_step :: proc(zoom: f32) -> i64 {
	target := 70.0 / zoom
	if target <= 1 {
		return 1
	}
	scale: i64 = 1
	mults := [6]i64{1, 2, 5, 10, 20, 50}
	for {
		for m in mults {
			if f32(m) * f32(scale) >= target {
				return m * scale
			}
		}
		scale *= 100
	}
}

render_clay :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, commands: clay.ClayArray(clay.RenderCommand)) {
	array := commands
	full := sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)}
	defer sdl.SetGPUScissor(pass, full)
	// Clay emits ScissorStart/ScissorEnd around clip containers (each track's
	// ClipsSection, whose childOffset slides the clip tiles horizontally).
	// Mirror it with an intersection stack that becomes the GPU scissor, plus a
	// "suppressed" flag that skips drawing while the enclosing clip region
	// collapsed to nothing. Without this handling, scrolled clip tiles are
	// drawn un-clipped over the track-name gutter and neighboring rows, which
	// reads as the tracks moving around when panning.
	stack: [16]struct { current: sdl.Rect, suppressed: bool }
	depth := 0
	current := full
	suppressed := false
	for i in 0..<commands.length {
		command := clay.RenderCommandArray_Get(&array, i)
		bounds := command.boundingBox

		#partial switch command.commandType {
		case .ScissorStart:
			if depth < len(stack) {
				stack[depth] = {current = current, suppressed = suppressed}
				depth += 1
			}
			if !suppressed {
				cr := scissor_intersect(bounds, current)
				if cr.w > 0 && cr.h > 0 {
					current = cr
					sdl.SetGPUScissor(pass, current)
				} else {
					suppressed = true
				}
			}
		case .ScissorEnd:
			if depth > 0 {
				depth -= 1
				current = stack[depth].current
				suppressed = stack[depth].suppressed
				if !suppressed {
					sdl.SetGPUScissor(pass, current)
				}
			}
		case .Rectangle:
			if !suppressed {
				config := command.renderData.rectangle
				color := config.backgroundColor
				if command.id == clay.ID("OpenFileButton").id && clay.PointerOver(clay.ID("OpenFileButton")) {
					color = BUTTON_HOVER
				}
				render_sdf_rect(renderer, command_buffer, pass, bounds, color, config.cornerRadius.topLeft, 0)
			}
		case .Border:
			if !suppressed {
				config := command.renderData.border
				color := config.color
				if command.id == clay.ID("OpenFileButton").id && clay.PointerOver(clay.ID("OpenFileButton")) {
					color = BUTTON_BORDER_HOVER
				}
				render_sdf_rect(renderer, command_buffer, pass, bounds, color, config.cornerRadius.topLeft, f32(config.width.left))
			}
		case .Text:
			if !suppressed {
				render_text(renderer, command_buffer, pass, bounds, command.renderData.text)
			}
		}
	}
}

// scissor_intersect clips a Clay command's bounds to the active scissor rect.
scissor_intersect :: proc(bounds: clay.BoundingBox, clip: sdl.Rect) -> sdl.Rect {
	x := max(c.int(bounds.x), clip.x)
	y := max(c.int(bounds.y), clip.y)
	x2 := min(c.int(bounds.x + bounds.width), clip.x + clip.w)
	y2 := min(c.int(bounds.y + bounds.height), clip.y + clip.h)
	return sdl.Rect{x, y, x2 - x, y2 - y}
}

// draw_text_input_caret paints the text-input field's selection highlight and
// blinking caret as an overlay (after Clay) because caret alignment depends on
// the laid-out field box and per-character advance. The field font is the
// monospace app font, so advance is a constant per codepoint (matching the
// measure function).
draw_text_input_caret :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass) {
	if !ti.active {
		return
	}
	box := clay.GetElementData(clay.ID("TextInputField")).boundingBox
	if box.width <= 0 || box.height <= 0 {
		return
	}
	field_size: f32 = 18
	adv := f32(0.55) * field_size
	text_x := box.x + 8 // matches the field's left padding
	sm, lg := text_input_sel()
	if sm != lg {
		x0 := text_x + f32(text_input_codepoints_before(sm)) * adv
		x1 := text_x + f32(text_input_codepoints_before(lg)) * adv
		render_sdf_rect(renderer, command_buffer, pass, clay.BoundingBox{x = x0, y = box.y + 4, width = max(2, x1 - x0), height = box.height - 8}, clay.Color{56, 90, 170, 170}, 2, 0)
	}
	// Blinking caret.
	blink := (sdl.GetTicks() / 500) % 2 == 0
	if blink {
		cx := text_x + f32(text_input_codepoints_before(ti.cursor)) * adv
		render_sdf_rect(renderer, command_buffer, pass, clay.BoundingBox{x = cx, y = box.y + 3, width = 2, height = box.height - 6}, BUTTON_BORDER_HOVER, 0, 0)
	}
}

// draw_timeline_resize_focus paints a thin accent bar on the hovered (or
// actively dragged) duration edge of the selected clip, making the edge-grab
// area visible. Drawn as an overlay after Clay because a clip element's laid-out
// box is only available via GetElementData.
draw_timeline_resize_focus :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass) {
	_, cl, ok := selected_clip()
	if !ok {
		return
	}
	edge := -1
	if resizing_clip {
		edge = resize_edge
	} else {
		pointer := clay.GetPointerState()
		mx, my := pointer.position.x, pointer.position.y
		for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
			track := &timeline.tracks[track_idx]
			for index := 0; index < len(track.clips); index += 1 {
				if &track.clips[index] == cl {
					edge = timeline_resize_edge_at(track_idx, index, mx, my)
					break
				}
			}
		}
	}
	if edge < 0 {
		return
	}
	for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
		track := &timeline.tracks[track_idx]
		for index := 0; index < len(track.clips); index += 1 {
			if &track.clips[index] != cl {
				continue
			}
			box := clay.GetElementData(clay.ID("TimelineClip", u32(track_idx * 1000 + index))).boundingBox
			color := BUTTON_BORDER_HOVER
			if edge == 0 {
				render_sdf_rect(renderer, command_buffer, pass, clay.BoundingBox{x = box.x, y = box.y, width = 3, height = box.height}, color, 0, 0)
			} else {
				render_sdf_rect(renderer, command_buffer, pass, clay.BoundingBox{x = box.x + box.width - 3, y = box.y, width = 3, height = box.height}, color, 0, 0)
			}
			return
		}
	}
}

// draw_clip_markers paints each clip's embedded markers on its timeline tile:
// a small downward-pointing triangle at the tile's top (in the tile's border
// color, highlighted when the tile is selected) with a thin vertical line
// running from the triangle down to the bottom of the tile, positioned at the
// marker's source frame. Shows the hovered marker's label as a tooltip in the
// empty strip directly above the tile. Drawn as an overlay after the Clay
// command batch because a clip element's final laid-out position is only
// available via GetElementData.
draw_clip_markers :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass) {
	if len(timeline.tracks) == 0 {
		return
	}
	pointer := clay.GetPointerState()
	mouse_x := pointer.position.x
	mouse_y := pointer.position.y
	hover_label: string
	hover_x: f32
	gap_bounds: clay.BoundingBox
	best_dist := f32(1e9)
	// Marker lines and triangles must stay inside their track's lane; a marker
	// inside a tile that has slid under the track-name gutter (or off the right
	// edge) would otherwise render on top of neighboring rows and headers.
	restore_full := false
	for track, track_idx in timeline.tracks {
		lane := clay.GetElementData(clay.ID("ClipsSection", u32(track_idx))).boundingBox
		if lane.width > 0 && lane.height > 0 {
			sdl.SetGPUScissor(pass, sdl.Rect{c.int(lane.x), c.int(lane.y), c.int(lane.width), c.int(lane.height)})
			restore_full = true
		}
		for clip, index in track.clips {
			if len(clip.markers) == 0 {
				continue
			}
			box := clay.GetElementData(clay.ID("TimelineClip", u32(track_idx * 1000 + index))).boundingBox
			if box.width <= 0 || box.height <= 0 {
				continue
			}
			// The strip directly above this tile (where "+ Add track" appears
			// when the gap itself is hovered) is where the tooltip renders.
			gap := clay.GetElementData(clay.ID("TrackGap", u32(track_idx))).boundingBox
			gap_bounds = gap
			color := BUTTON_BORDER
			if selected_track == track_idx && selected_index == index {
				color = BUTTON_BORDER_HOVER
			}
			rows := [3]f32{5, 3, 1}
			for m in clip.markers {
				line_x := clamp(box.x + f32(m.source_frame - clip.source_start_frame) * timeline_zoom, box.x, box.x + box.width)
				// Thin vertical line from just below the triangle to the tile bottom.
				render_sdf_rect(renderer, command_buffer, pass, clay.BoundingBox{x = line_x - 1, y = box.y, width = 2, height = box.height}, color, 0, 0)
				// Downward-pointing triangle at the tile's top, at the marker's x.
				y := box.y
				for row, r in rows {
					w := rows[r]
					bx := clamp(line_x - w * 0.5, box.x, box.x + box.width - w)
					render_sdf_rect(renderer, command_buffer, pass, clay.BoundingBox{x = bx, y = y, width = w, height = 3}, color, 0, 0)
					y += 3
				}
				// Hover hit box: the marker's column near the top of the tile.
				if len(m.label) > 0 && mouse_y >= box.y && mouse_y <= box.y + 18 {
					d := abs(mouse_x - line_x)
					if d <= 6 && d < best_dist {
						best_dist = d
						hover_label = m.label
						hover_x = line_x
					}
				}
			}
		}
		if restore_full {
			sdl.SetGPUScissor(pass, sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)})
			restore_full = false
		}
	}
	if hover_label != "" {
		draw_marker_tooltip(renderer, command_buffer, pass, hover_label, hover_x, gap_bounds)
	}
}

// draw_drag_ghost paints the translucent drop preview for a clip being dragged
// onto another track: a ghost tile in the hovered lane at the nearest
// non-overlapping slot. Same width as the dragged clip, positioned from
// drag_ghost_start like regular clips (frame * zoom offset by the view).
draw_drag_ghost :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass) {
	if !moving_clip || drag_clip == nil {
		return
	}
	if drag_hover_track < 0 || drag_hover_track >= len(timeline.tracks) {
		return
	}
	if drag_hover_track == drag_source_track {
		return
	}
	clip_len := drag_clip.source_length_frames
	if clip_len <= 0 {
		return
	}
	// The nearest valid non-overlap slot may differ per frame (it follows the
	// mouse during the drag), but the ghost must never hide an overlap it would
	// cause: clamp once more against the hovered track's live content.
	placed := clip_place_in_track(&timeline.tracks[drag_hover_track], -1, clip_len, drag_ghost_start)
	lane := clay.GetElementData(clay.ID("ClipsSection", u32(drag_hover_track))).boundingBox
	if lane.width <= 0 || lane.height <= 0 {
		return
	}
	// Lane origin is at frame 0 = ruler.x; tiles slide with the view offset.
	x0 := lane.x + (f32(placed) - timeline_view_start) * timeline_zoom
	w := f32(clip_len) * timeline_zoom
	// Ghost tile height matches real clips (fixed 56, same as the layout).
	h := f32(56)
	bounds := clay.BoundingBox{x = x0, y = lane.y, width = w, height = h}
	// Keep the ghost inside the lane (semi-transparent fill + strong border).
	sdl.SetGPUScissor(pass, sdl.Rect{c.int(lane.x), c.int(lane.y), c.int(lane.width), c.int(lane.height)})
	render_sdf_rect(renderer, command_buffer, pass, bounds, clay.Color{140, 200, 255, 80}, 6, 0)
	render_sdf_rect(renderer, command_buffer, pass, bounds, clay.Color{140, 200, 255, 220}, 6, 2)
	sdl.SetGPUScissor(pass, sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)})
}

// draw_marker_tooltip draws a small pill with the marker's label centered on
// the marker's x position inside the reserved strip above the timeline rows.
draw_marker_tooltip :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, label: string, at_x: f32, strip: clay.BoundingBox) {
	// The strip spans the full tracks area including the name gutter; pin the
	// pill to the clip-lane region so it can't drift over the headers.
	ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
	if ruler.width > 0 {
		sdl.SetGPUScissor(pass, sdl.Rect{c.int(ruler.x), c.int(ruler.y - 8), c.int(ruler.width), c.int(renderer.viewport.y)})
		defer sdl.SetGPUScissor(pass, sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)})
	}
	font_size: f32 = 12
	text_w := f32(len(label)) * font_size * 0.6
	text_x := clamp(at_x - text_w * 0.5, strip.x + 4, strip.x + strip.width - text_w - 4)
	pill := clay.BoundingBox{x = text_x - 4, y = strip.y + 2, width = text_w + 8, height = 14}
	render_sdf_rect(renderer, command_buffer, pass, pill, TOOLTIP_BG, 3, 0)
	render_text(renderer, command_buffer, pass, clay.BoundingBox{x = text_x, y = pill.y + 1, width = text_w, height = 12}, clay.TextRenderData{
		stringContents = clay.StringSlice{length = c.int32_t(len(label)), chars = ([^]c.char)(raw_data(label))},
		textColor = TOOLTIP_TEXT,
		fontSize = 12,
		letterSpacing = 1,
		lineHeight = 12,
	})
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

// draw_preview_hud paints the audio-vs-video clock overlay in the corner of the
// preview while playing. It answers the one question that has been argued from
// two sides this whole session with a number everyone can see: does the audio
// content position (A, from the device clock) fall behind the video content
// position (V, the playhead) — and at what delta.
draw_preview_hud :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, preview: clay.BoundingBox) {
	if !sync.atomic_load(&audio_run_flag) {
		return
	}
	fps := timeline_fps()
	if fps <= 0 {
		return
	}
	label := fmt.tprintf("A %6.2f  V %6.2f  d %+.2f",
		f64(sync.atomic_load(&audio_dev_frame)) / fps,
		f64(playhead.frame) / fps,
		f64(sync.atomic_load(&audio_dev_frame)-playhead.frame) / fps)
	fs: u16 = 13
	text_w := f32(len(label)) * f32(fs) * 0.6
	pill := clay.BoundingBox{x = preview.x + 8, y = preview.y + 8, width = text_w + 10, height = 17}
	render_sdf_rect(renderer, command_buffer, pass, pill, TOOLTIP_BG, 4, 0)
	render_text(renderer, command_buffer, pass, clay.BoundingBox{x = pill.x + 5, y = pill.y + 2, width = text_w, height = f32(fs)}, clay.TextRenderData{
		stringContents = clay.StringSlice{length = c.int32_t(len(label)), chars = ([^]c.char)(raw_data(label))},
		textColor = TOOLTIP_TEXT,
		fontSize = fs,
		letterSpacing = 1,
		lineHeight = fs,
	})
}

// create_text_texture creates a tight R8G8B8A8 texture (owned by the slot) for
// a text clip's baked raster. A text slot owns its texture (unlike video slots,
// which point at the shared fixed preview_textures); it must be released via
// release_slot_owned_texture when the slot is freed or reused for a video clip.
create_text_texture :: proc(device: ^sdl.GPUDevice, w, h: c.int) -> ^sdl.GPUTexture {
	return sdl.CreateGPUTexture(device, sdl.GPUTextureCreateInfo{type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER}, width = u32(w), height = u32(h), layer_count_or_depth = 1, num_levels = 1, sample_count = ._1})
}

// release_slot_owned_texture frees a text slot's owned texture + dynamic buffer.
// No-op for video slots, whose texture points at the shared preview_textures.
release_slot_owned_texture :: proc(device: ^sdl.GPUDevice, slot: ^Preview_Slot) {
	if slot.is_text && slot.texture != nil {
		sdl.ReleaseGPUTexture(device, slot.texture)
	}
	slot.texture = nil
	if slot.text_buf != nil {
		delete(slot.text_buf)
		slot.text_buf = nil
	}
}

// upload_preview_slot copies tightly-packed RGBA pixels into a slot's GPU
// texture using a transfer buffer + copy pass on the given command buffer. A
// text slot uploads its tight text_buf into its owned tight texture; a video
// slot uploads the fixed PREVIEW buffer into the shared preview texture.
upload_preview_slot :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, slot: ^Preview_Slot) {
	if slot.texture == nil {
		return
	}
	if slot.is_text {
		upload_text_slot(renderer, command_buffer, slot)
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

// upload_text_slot uploads a text slot's full raster buffer (text_tex_w x
// text_tex_h, the estimated buffer size) into its texture.
upload_text_slot :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, slot: ^Preview_Slot) {
	w := u32(slot.text_tex_w)
	h := u32(slot.text_tex_h)
	if w <= 0 || h <= 0 || slot.text_buf == nil {
		return
	}
	n := int(w) * int(h) * 4
	transfer := sdl.CreateGPUTransferBuffer(renderer.device, sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = u32(n)})
	if transfer == nil {
		return
	}
	defer sdl.ReleaseGPUTransferBuffer(renderer.device, transfer)
	mapped := sdl.MapGPUTransferBuffer(renderer.device, transfer, false)
	if mapped == nil {
		return
	}
	src := ([^]u8)(raw_data(slot.text_buf))[:n]
	dst := ([^]u8)(mapped)[:n]
	copy(dst, src)
	sdl.UnmapGPUTransferBuffer(renderer.device, transfer)
	copy_pass := sdl.BeginGPUCopyPass(command_buffer)
	source := sdl.GPUTextureTransferInfo{transfer_buffer = transfer, pixels_per_row = w, rows_per_layer = h}
	destination := sdl.GPUTextureRegion{texture = slot.texture, w = w, h = h, d = 1}
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

// release_slot_owned_textures frees every text slot's owned tight texture plus
// any orphaned ones still in the pending queue. Called once at shutdown (video
// slots only point at preview_textures, released separately).
release_slot_owned_textures :: proc(device: ^sdl.GPUDevice) {
	for i in 0 ..< MAX_PREVIEW_SLOTS {
		slot := &preview_slots[i]
		if slot.is_text && slot.texture != nil {
			sdl.ReleaseGPUTexture(device, slot.texture)
			slot.texture = nil
		}
	}
	drain_pending_text_releases(device)
}

// ---------------------------------------------------------------------------
// Owned text-texture lifecycle. A text slot owns its tight texture (video
// slots instead point at the shared renderer.preview_textures). When the
// preview state reassigns a slot (it has no GPU device), it stashes the old
// owned texture here; the render loop drains the queue each frame with the
// device in hand, so a texture never leaks across a slot reassignment.
// ---------------------------------------------------------------------------
pending_text_release: [dynamic]^sdl.GPUTexture

queue_text_texture_release :: proc(tex: ^sdl.GPUTexture) {
	if tex != nil {
		append(&pending_text_release, tex)
	}
}

drain_pending_text_releases :: proc(device: ^sdl.GPUDevice) {
	for t in pending_text_release {
		sdl.ReleaseGPUTexture(device, t)
	}
	clear(&pending_text_release)
}


// draw_preview draws the active video clip's frame in the given bounds, placed
// according to the clip's transform (fills the project canvas, centered at its
// x/y), then overlays a selection border around the currently-selected clip's
// image rect. The decode buffer is fixed PREVIEW_W x PREVIEW_H; the source is
// fit (aspect-preserving, letterboxed) into it and the quad samples only the
// fit region so the image is never stretched to the (possibly differently
// shaped) project canvas.
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

	// The clip IMAGE must never paint outside the final rendered area (the
	// project canvas). Clip it to the canvas rect ∩ the preview widget so a clip
	// dragged off-canvas stays hidden in the letterbox/GUI margin even when
	// zoomed past the widget edge.
	ix := max(view.x, bounds.x)
	iy := max(view.y, bounds.y)
	ix2 := min(view.x + view.width, bounds.x + bounds.width)
	iy2 := min(view.y + view.height, bounds.y + bounds.height)
	if ix2 > ix && iy2 > iy {
		sdl.SetGPUScissor(pass, sdl.Rect{c.int(ix), c.int(iy), c.int(ix2 - ix), c.int(iy2 - iy)})
	}

	// Paint every clip covering the playhead with the top track on top. Slots
	// are assigned in track order (track 0 = top = slot 0), so draw slots in
	// reverse so the top track's clip is drawn last and appears on top.
	for i := MAX_PREVIEW_SLOTS - 1; i >= 0; i -= 1 {
		slot := &preview_slots[i]
		if !slot.in_use || !slot.has_frame || slot.texture == nil {
			continue
		}
		is_text := slot.text_w > 0 && slot.text_h > 0
		cb := clip_image_bounds(canvas, &Clip{
			kind = is_text ? Media_Kind.Text : .Video,
			transform_x = slot.transform_x,
			transform_y = slot.transform_y,
			scale = slot.scale,
			crop_l = slot.crop_l,
			crop_r = slot.crop_r,
			crop_t = slot.crop_t,
			crop_b = slot.crop_b,
			source_w = slot.source_w,
			source_h = slot.source_h,
		})
		// The decoded texture holds the source fit (letterboxed) inside the
		// fixed PREVIEW_W x PREVIEW_H buffer. Start the quad from that fit
		// region so the sampled area keeps the source's aspect, then apply the
		// crop insets (normalized fractions of the full source image).
		//
		// A text slot is different: its buffer is the full canvas with the text
		// rasterized at the top-left (tight text_w x text_h), so the quad samples
		// exactly that top-left region rather than a letterboxed fit.
		u0, u1, v0, v1: f32
		if is_text {
			// The texture holds the full estimated buffer; sample only the tight
			// ink sub-rect (text_x/text_y/text_w/text_h) as a fractional region.
			tw := f32(slot.text_tex_w)
			th := f32(slot.text_tex_h)
			u0 = f32(slot.text_x) / tw
			v0 = f32(slot.text_y) / th
			u1 = f32(slot.text_x + slot.text_w) / tw
			v1 = f32(slot.text_y + slot.text_h) / th
		} else {
			fw, fh, fox, foy := source_fit_in_buffer(slot.source_w, slot.source_h, PREVIEW_W, PREVIEW_H)
			u_base := f32(fox) / f32(PREVIEW_W)
			v_base := f32(foy) / f32(PREVIEW_H)
			u_span := f32(fw) / f32(PREVIEW_W)
			v_span := f32(fh) / f32(PREVIEW_H)
			u0 = u_base + slot.crop_l * u_span
			u1 = u_base + (1 - slot.crop_r) * u_span
			v0 = v_base + slot.crop_t * v_span
			v1 = v_base + (1 - slot.crop_b) * v_span
		}
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
	// Border/handles are editor affordances: restore the widget-level scissor so
	// handles on an off-canvas box stay visible/grabbable.
	sdl.SetGPUScissor(pass, sdl.Rect{c.int(bounds.x), c.int(bounds.y), c.int(bounds.width), c.int(bounds.height)})
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
