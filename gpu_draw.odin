package main

import clay "clay-odin"
import "core:c"
import "core:fmt"
import "core:sync"
import "core:unicode/utf8"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Per-frame GPU draw calls: translating Clay render commands into SDF rect/
// text draws, uploading decoded preview frames, and compositing the preview.
// ---------------------------------------------------------------------------

// draw_timeline_ruler renders the timeline ruler's tick marks and frame labels
// plus the vertical playhead line that runs from the ruler bar down through
// every track row. The ruler strip itself is a Clay element ("Ruler"); this
// proc only adds the detail Clay can't lay out cheaply.
draw_timeline_ruler :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
) {
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
	sdl.SetGPUScissor(
		pass,
		sdl.Rect {
			c.int(ruler.x),
			c.int(ruler.y - 8),
			c.int(ruler.width),
			c.int(renderer.viewport.y),
		},
	)
	defer sdl.SetGPUScissor(
		pass,
		sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)},
	)
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
		render_sdf_rect(
			renderer,
			command_buffer,
			pass,
			{x, ruler.y + ruler.height - tick_h, is_major ? 2 : 1, tick_h},
			RULER_TICK_COLOR,
			0,
			0,
		)
		// Frame label above each major tick.
		if is_major {
			label_buf: [20]u8
			label := fmt.bprintf(label_buf[:], "%d", f)
			chars := ([^]c.char)(raw_data(label))
			slice := clay.StringSlice {
				length    = c.int32_t(len(label)),
				chars     = chars,
				baseChars = chars,
			}
			text_data := clay.TextRenderData {
				stringContents = slice,
				textColor      = RULER_LABEL_COLOR,
				fontSize       = FONT_RULER,
				lineHeight     = FONT_RULER,
			}
			text_bounds := clay.BoundingBox {
				x      = x + 3,
				y      = ruler.y + 3,
				width  = 64,
				height = 13,
			}
			render_text(renderer, command_buffer, pass, text_bounds, text_data)
		}
	}

	// Vertical playhead line spanning the ruler and all track rows, plus a grab
	// handle sitting on top of the ruler strip.
	line_x := ruler.x + (f32(playhead.frame) - timeline_view_start) * timeline_zoom
	tracks := clay.GetElementData(clay.ID("TracksSection")).boundingBox
	line_bottom := ruler.y + RULER_HEIGHT + tracks.height
	render_sdf_rect(
		renderer,
		command_buffer,
		pass,
		{line_x, ruler.y, 2, line_bottom - ruler.y},
		BUTTON_BORDER_HOVER,
		0,
		0,
	)
	render_sdf_rect(
		renderer,
		command_buffer,
		pass,
		{line_x - 4, ruler.y - 4, 10, 10},
		BUTTON_BORDER_HOVER,
		2,
		0,
	)
}

// draw_render_range draws the project render range as a band sitting just below
// the timeline ruler bar, from the range's start frame to its end frame (both
// set and ordered). Each boundary also gets a cap marker, drawn independently:
// with only one boundary set its cap still appears so the I/O placement stays
// visible. Only the part inside the ruler's width is drawn.
draw_render_range :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
) {
	if len(timeline.tracks) == 0 || (project.start_frame < 0 && project.end_frame < 0) {
		return
	}
	ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
	if ruler.width <= 0 {
		return
	}
	// The band and its edge caps can stick out over the gutter when the range
	// starts before the current view; keep them inside the ruler bar's width.
	sdl.SetGPUScissor(
		pass,
		sdl.Rect{c.int(ruler.x), 0, c.int(ruler.width), c.int(renderer.viewport.y)},
	)
	defer sdl.SetGPUScissor(
		pass,
		sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)},
	)
	y := ruler.y + ruler.height
	isect := ruler.x + ruler.width
	if project.start_frame >= 0 &&
	   project.end_frame >= 0 &&
	   project.start_frame < project.end_frame {
		x1 := ruler.x + (f32(project.start_frame) - timeline_view_start) * timeline_zoom
		x2 := ruler.x + (f32(project.end_frame) - timeline_view_start) * timeline_zoom
		if x2 > ruler.x && x1 < isect {
			band_x := max(x1, ruler.x)
			band_w := min(x2, isect) - band_x
			if band_w > 0 {
				render_sdf_rect(
					renderer,
					command_buffer,
					pass,
					{band_x, y, band_w, 4},
					RANGE_COLOR,
					0,
					0,
				)
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

// render_clay draws every clay command whose zIndex is in [min_z, max_z).
// The context menu / dropdown / help / modal popups are drawn in a second
// pass (frame.odin interleaves the preview canvas between the two) so the
// preview never overpaints a floating overlay.
render_clay :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	commands: clay.ClayArray(clay.RenderCommand),
	min_z, max_z: i16,
) {
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
	stack: [16]struct {
		current:    sdl.Rect,
		suppressed: bool,
	}
	depth := 0
	current := full
	suppressed := false
	for i in 0 ..< commands.length {
		command := clay.RenderCommandArray_Get(&array, i)
		bounds := command.boundingBox
		if command.zIndex < min_z || command.zIndex >= max_z {
			continue
		}

		#partial switch command.commandType {
		case .ScissorStart:
			if depth < len(stack) {
				stack[depth] = {
					current    = current,
					suppressed = suppressed,
				}
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
				if command.id == clay.ID("OpenFileButton").id &&
				   clay.PointerOver(clay.ID("OpenFileButton")) {
					color = BUTTON_HOVER
				}
				render_sdf_rect(
					renderer,
					command_buffer,
					pass,
					bounds,
					color,
					config.cornerRadius.topLeft,
					0,
				)
			}
		case .Border:
			if !suppressed {
				config := command.renderData.border
				color := config.color
				if command.id == clay.ID("OpenFileButton").id &&
				   clay.PointerOver(clay.ID("OpenFileButton")) {
					color = BUTTON_BORDER_HOVER
				}
				render_sdf_rect(
					renderer,
					command_buffer,
					pass,
					bounds,
					color,
					config.cornerRadius.topLeft,
					f32(config.width.left),
				)
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
// the laid-out field box and per-character advance. Advances come from the
// baked glyph quads (actual variable-width advance of the current face), so the
// caret tracks the real text geometry under a proportional font.
draw_text_input_caret :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
) {
	if !ti.active {
		return
	}
	box := clay.GetElementData(clay.ID("TextInputField")).boundingBox
	if box.width <= 0 || box.height <= 0 {
		return
	}
	field_size: f32 = f32(TEXT_INPUT_FONT)
	scale := field_size / 32.0
	text_x := box.x + CARD_GAP // matches the field's left padding
	sm, lg := text_input_sel()
	if sm != lg {
		x0 := text_x + input_advance_up_to(renderer, sm, scale)
		x1 := text_x + input_advance_up_to(renderer, lg, scale)
		render_sdf_rect(
			renderer,
			command_buffer,
			pass,
			clay.BoundingBox {
				x = x0,
				y = box.y + 4,
				width = max(2, x1 - x0),
				height = box.height - 8,
			},
			clay.Color{127, 187, 179, 170},
			2,
			0,
		)
	}
	// Blinking caret.
	blink := (sdl.GetTicks() / 500) % 2 == 0
	if blink {
		cx := text_x + input_advance_up_to(renderer, ti.cursor, scale)
		render_sdf_rect(
			renderer,
			command_buffer,
			pass,
			clay.BoundingBox{x = cx, y = box.y + 4, width = 2, height = box.height - 8},
			BUTTON_BORDER_HOVER,
			0,
			0,
		)
	}
}

// input_advance_up_to returns the laid-out width of the text-input string up to
// byte offset `at`, mirroring render_text's per-glyph cached-advance
// accumulation (same scale, same skip rules). This is what keeps the caret and
// selection on top of the actual glyph geometry for a variable-width font.
input_advance_up_to :: proc(renderer: ^GPU_Renderer, at: int, scale: f32) -> f32 {
	x: f32 = 0
	atlas := &renderer.font
	txt := text_input_string()
	for i := 0; i < at && i < len(txt); {
		r, size := utf8.decode_rune(txt[i:])
		i += size
		if r == '\n' {
			x = 0
			continue
		}
		s, uok, _ := glyph_ensure(atlas, r)
		if !uok {
			continue
		}
		x += atlas.slots[s].adv
	}
	return x * scale
}

// draw_timeline_resize_focus paints a thin accent bar on the hovered (or
// actively dragged) duration edge of the selected clip, making the edge-grab
// area visible. Drawn as an overlay after Clay because a clip element's laid-out
// box is only available via GetElementData.
draw_timeline_resize_focus :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
) {
	_, cl, ok := selected_clip()
	if !ok {
		return
	}
	edge := -1
	if active_interaction == .Clip_Resize {
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
			box :=
				clay.GetElementData(clay.ID("TimelineClip", u32(track_idx * 1000 + index))).boundingBox
			color := BUTTON_BORDER_HOVER
			if edge == 0 {
				render_sdf_rect(
					renderer,
					command_buffer,
					pass,
					clay.BoundingBox{x = box.x, y = box.y, width = 3, height = box.height},
					color,
					0,
					0,
				)
			} else {
				render_sdf_rect(
					renderer,
					command_buffer,
					pass,
					clay.BoundingBox {
						x = box.x + box.width - 3,
						y = box.y,
						width = 3,
						height = box.height,
					},
					color,
					0,
					0,
				)
			}
			return
		}
	}
}

// draw_clip_markers paints each clip's embedded markers on its timeline tile:
// a thin vertical line from the tile's top to its bottom at the marker's source
// frame, and a small downward-pointing triangle in the insert gap directly above
// the tile, inside the lane region right of the track gutter — the "Add track"
// strip's remaining space marks the point, the line below carries it into the
// tile. Shows the hovered marker's label as a tooltip in the same strip. Drawn
// as an overlay after the Clay command batch because a clip element's final
// laid-out position is only available via GetElementData.
draw_clip_markers :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
) {
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
	// Marker lines and triangles must stay inside their track's column; a marker
	// inside a tile that has slid under the track-name gutter (or off the right
	// edge) would otherwise render on top of neighboring rows and headers. The
	// gap triangle sits above the lane, so the scissor spans lane + insert gap
	// on one column.
	restore_full := false
	for track, track_idx in timeline.tracks {
		lane := clay.GetElementData(clay.ID("ClipsSection", u32(track_idx))).boundingBox
		gap := clay.GetElementData(clay.ID("TrackGap", u32(track_idx))).boundingBox
		gap_bounds = gap
		if lane.width > 0 && lane.height > 0 {
			lo_y := min(lane.y, gap.y)
			hi_y := max(lane.y + lane.height, gap.y + gap.height)
			sdl.SetGPUScissor(
				pass,
				sdl.Rect{c.int(lane.x), c.int(lo_y), c.int(lane.width), c.int(hi_y - lo_y)},
			)
			restore_full = true
		}
		for clip, index in track.clips {
			if len(clip.markers) == 0 {
				continue
			}
			box :=
				clay.GetElementData(clay.ID("TimelineClip", u32(track_idx * 1000 + index))).boundingBox
			if box.width <= 0 || box.height <= 0 {
				continue
			}
			color := BUTTON_BORDER
			if selected_track == track_idx && selected_index == index {
				color = BUTTON_BORDER_HOVER
			}
			rows := [3]f32{5, 3, 1}
			for m in clip.markers {
				line_x := clamp(
					box.x + f32(m.source_frame - clip.source_start_frame) * timeline_zoom,
					box.x,
					box.x + box.width,
				)
				// Thin vertical line from the tile's top down to its bottom.
				render_sdf_rect(
					renderer,
					command_buffer,
					pass,
					clay.BoundingBox{x = line_x - 1, y = box.y, width = 2, height = box.height},
					color,
					0,
					0,
				)
				// Downward-pointing triangle in the insert gap just above the
				// tile, clamped to the lane region right of the gutter.
				y := gap.y + gap.height - 9
				for row, r in rows {
					w := rows[r]
					bx := clamp(line_x - w * 0.5, lane.x, gap.x + gap.width - w)
					render_sdf_rect(
						renderer,
						command_buffer,
						pass,
						clay.BoundingBox{x = bx, y = y, width = w, height = 3},
						color,
						0,
						0,
					)
					y += 3
				}
				// Hover hit box: the marker's column within the insert strip.
				if len(m.label) > 0 && mouse_y >= gap.y && mouse_y <= gap.y + gap.height {
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
			sdl.SetGPUScissor(
				pass,
				sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)},
			)
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
draw_drag_ghost :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
) {
	if active_interaction != .Clip_Move || drag_clip == nil {
		return
	}
	if drag_hover_track < 0 || drag_hover_track >= len(timeline.tracks) {
		return
	}
	if drag_hover_track == drag_source_track {
		return
	}
	// Linked group: paint a ghost for every member in its destination lane at the
	// mouse-aligned position (m.start + drag_group_delta), so the whole unit
	// slides with the drag. If any member can't land at that exact spot on its
	// destination lane the drop is refused, shown red.
	if len(drag_group_orig) > 1 {
		// Visual-row delta through the stack order: storage indices may be
		// scrambled, but the drop targets the visual row under the pointer.
		delta_rows := order_row_of(drag_hover_track) - order_row_of(drag_source_track)
		refused := !group_vertical_feasible(delta_rows, drag_group_delta)
		for m in drag_group_orig {
			src_row := order_row_of(m.track)
			dst := src_row >= 0 ? track_at_row(src_row + delta_rows) : -1
			if dst < 0 {
				continue
			}
			lane := clay.GetElementData(clay.ID("ClipsSection", u32(dst))).boundingBox
			if lane.width <= 0 || lane.height <= 0 {
				continue
			}
			start := max(m.start + drag_group_delta, 0)
			x0 := lane.x + (f32(start) - timeline_view_start) * timeline_zoom
			w := f32(m.length) * timeline_zoom
			bounds := clay.BoundingBox {
				x      = x0,
				y      = lane.y,
				width  = w,
				height = CLIP_TILE_HEIGHT,
			}
			fill := clay.Color{127, 187, 179, 80}
			edge := clay.Color{127, 187, 179, 220}
			if refused {
				fill = clay.Color{230, 126, 128, 80}
				edge = clay.Color{230, 126, 128, 230}
			}
			sdl.SetGPUScissor(
				pass,
				sdl.Rect{c.int(lane.x), c.int(lane.y), c.int(lane.width), c.int(lane.height)},
			)
			render_sdf_rect(renderer, command_buffer, pass, bounds, fill, 6, 0)
			render_sdf_rect(renderer, command_buffer, pass, bounds, edge, 6, 2)
		}
		sdl.SetGPUScissor(
			pass,
			sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)},
		)
		return
	}
	clip_len := drag_clip.source_length_frames
	if clip_len <= 0 {
		return
	}
	// The nearest valid non-overlap slot may differ per frame (it follows the
	// mouse during the drag), but the ghost must never hide an overlap it would
	// cause: clamp once more against the hovered track's live content.
	placed := clip_place_in_track(
		&timeline.tracks[drag_hover_track],
		-1,
		clip_len,
		drag_ghost_start,
	)
	lane := clay.GetElementData(clay.ID("ClipsSection", u32(drag_hover_track))).boundingBox
	if lane.width <= 0 || lane.height <= 0 {
		return
	}
	// Lane origin is at frame 0 = ruler.x; tiles slide with the view offset.
	x0 := lane.x + (f32(placed) - timeline_view_start) * timeline_zoom
	w := f32(clip_len) * timeline_zoom
	// Ghost tile height matches real clips (CLIP_TILE_HEIGHT, same as the layout).
	h := CLIP_TILE_HEIGHT
	bounds := clay.BoundingBox {
		x      = x0,
		y      = lane.y,
		width  = w,
		height = h,
	}
	// Keep the ghost inside the lane (semi-transparent fill + strong border).
	sdl.SetGPUScissor(
		pass,
		sdl.Rect{c.int(lane.x), c.int(lane.y), c.int(lane.width), c.int(lane.height)},
	)
	render_sdf_rect(renderer, command_buffer, pass, bounds, clay.Color{127, 187, 179, 80}, 6, 0)
	render_sdf_rect(renderer, command_buffer, pass, bounds, clay.Color{127, 187, 179, 220}, 6, 2)
	sdl.SetGPUScissor(pass, sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)})
}

// draw_marker_tooltip draws a small pill with the marker's label centered on
// the marker's x position inside the reserved strip above the timeline rows.
draw_marker_tooltip :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	label: string,
	at_x: f32,
	strip: clay.BoundingBox,
) {
	// The strip spans the full tracks area including the name gutter; pin the
	// pill to the clip-lane region so it can't drift over the headers.
	ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
	if ruler.width > 0 {
		sdl.SetGPUScissor(
			pass,
			sdl.Rect {
				c.int(ruler.x),
				c.int(ruler.y - 8),
				c.int(ruler.width),
				c.int(renderer.viewport.y),
			},
		)
		defer sdl.SetGPUScissor(
			pass,
			sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)},
		)
	}
	font_size: f32 = FONT_TOOLTIP
	text_w := f32(len(label)) * font_size * 0.6
	text_x := clamp(at_x - text_w * 0.5, strip.x + 4, strip.x + strip.width - text_w - 4)
	pill := clay.BoundingBox {
		x      = text_x - 4,
		y      = strip.y + 2,
		width  = text_w + 8,
		height = 14,
	}
	render_sdf_rect(renderer, command_buffer, pass, pill, TOOLTIP_BG, 3, 0)
	render_text(
		renderer,
		command_buffer,
		pass,
		clay.BoundingBox{x = text_x, y = pill.y + 1, width = text_w, height = 12},
		clay.TextRenderData {
			stringContents = clay.StringSlice {
				length = c.int32_t(len(label)),
				chars = ([^]c.char)(raw_data(label)),
			},
			textColor = TOOLTIP_TEXT,
			fontSize = FONT_TOOLTIP,
			letterSpacing = 1,
			lineHeight = FONT_TOOLTIP,
		},
	)
}

render_text :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	bounds: clay.BoundingBox,
	text: clay.TextRenderData,
) {
	if renderer.font.texture == nil || renderer.text_pipeline == nil {
		return
	}

	// Clay's text command gives us the laid-out origin. The atlas bakes a
	// baseline origin at GLYPH_BAKE_PX, so start one font height below.
	scale := f32(text.fontSize) / f32(GLYPH_BAKE_PX)
	x: f32 = 0
	baseline: f32 = f32(GLYPH_BAKE_PX)
	line_height := f32(text.lineHeight)
	if line_height <= 0 {
		line_height = f32(text.fontSize)
	}
	atlas := &renderer.font
	sdl.BindGPUGraphicsPipeline(pass, renderer.text_pipeline)
	binding := sdl.GPUTextureSamplerBinding {
		texture = atlas.texture,
		sampler = atlas.sampler,
	}
	sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
	txt := string(([^]u8)(text.stringContents.chars)[:int(text.stringContents.length)])
	tex_px := f32(glyph_atlas_texture_px(atlas))
	for i := 0; i < len(txt); {
		r, size := utf8.decode_rune(txt[i:])
		i += size
		if r == '\n' {
			x = 0
			baseline += line_height / scale
			continue
		}
		s, uok, _ := glyph_ensure(atlas, r)
		if !uok {
			continue
		}
		slot := &atlas.slots[s]
		if slot.w > 0 && slot.h > 0 && slot.cell < atlas.baked_until_cell {
			quad_bounds := clay.BoundingBox {
				x      = bounds.x + (x + slot.xoff) * scale,
				y      = bounds.y + (baseline + slot.yoff) * scale,
				width  = f32(slot.w) * scale,
				height = f32(slot.h) * scale,
			}
			cx, cy := glyph_atlas_cell_xy(atlas, slot.cell)
			u0 := (f32(cx) * GLYPH_CELL_PX + GLYPH_CELL_PAD) / tex_px
			v0 := (f32(cy) * GLYPH_CELL_PX + GLYPH_CELL_PAD) / tex_px
			vertex_uniforms := TextVertexUniforms {
				bounds   = {quad_bounds.x, quad_bounds.y, quad_bounds.width, quad_bounds.height},
				viewport = renderer.viewport,
				_padding = {},
				uv       = {u0, v0, u0 + f32(slot.w) / tex_px, v0 + f32(slot.h) / tex_px},
			}
			color := text.textColor
			fragment_uniforms := TextFragmentUniforms {
				color = {
					f32(color[0]) / 255,
					f32(color[1]) / 255,
					f32(color[2]) / 255,
					f32(color[3]) / 255,
				},
			}
			sdl.PushGPUVertexUniformData(
				command_buffer,
				0,
				&vertex_uniforms,
				sdl.Uint32(size_of(vertex_uniforms)),
			)
			sdl.PushGPUFragmentUniformData(
				command_buffer,
				0,
				&fragment_uniforms,
				sdl.Uint32(size_of(fragment_uniforms)),
			)
			sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
		}
		x += slot.adv
		x += f32(text.letterSpacing) / scale
	}
}

render_sdf_rect :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	bounds: clay.BoundingBox,
	color: clay.Color,
	radius, border: f32,
) {
	vertex_uniforms := RectVertexUniforms {
		bounds   = {bounds.x, bounds.y, bounds.width, bounds.height},
		viewport = renderer.viewport,
	}
	fragment_uniforms := RectFragmentUniforms {
		color = {
			f32(color[0]) / 255,
			f32(color[1]) / 255,
			f32(color[2]) / 255,
			f32(color[3]) / 255,
		},
		shape = {bounds.width, bounds.height, radius, border},
	}
	sdl.PushGPUVertexUniformData(
		command_buffer,
		0,
		&vertex_uniforms,
		sdl.Uint32(size_of(vertex_uniforms)),
	)
	sdl.PushGPUFragmentUniformData(
		command_buffer,
		0,
		&fragment_uniforms,
		sdl.Uint32(size_of(fragment_uniforms)),
	)
	sdl.BindGPUGraphicsPipeline(pass, renderer.pipeline)
	sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
}

// render_icon draws one rasterized SVG icon through the text pipeline: the
// icon texture's R channel is the alpha mask, tinted by `color`. The texture
// covers the full [0,1] uv range (one icon per texture).
render_icon :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	bounds: clay.BoundingBox,
	id: Icon_Id,
	color: clay.Color,
) {
	if renderer.icon_textures[id] == nil || renderer.text_pipeline == nil {
		return
	}
	sdl.BindGPUGraphicsPipeline(pass, renderer.text_pipeline)
	binding := sdl.GPUTextureSamplerBinding {
		texture = renderer.icon_textures[id],
		sampler = renderer.preview_sampler,
	}
	sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
	vertex_uniforms := TextVertexUniforms {
		bounds   = {bounds.x, bounds.y, bounds.width, bounds.height},
		viewport = renderer.viewport,
		_padding = {},
		uv       = {0, 0, 1, 1},
	}
	fragment_uniforms := TextFragmentUniforms {
		color = {
			f32(color[0]) / 255,
			f32(color[1]) / 255,
			f32(color[2]) / 255,
			f32(color[3]) / 255,
		},
	}
	sdl.PushGPUVertexUniformData(
		command_buffer,
		0,
		&vertex_uniforms,
		sdl.Uint32(size_of(vertex_uniforms)),
	)
	sdl.PushGPUFragmentUniformData(
		command_buffer,
		0,
		&fragment_uniforms,
		sdl.Uint32(size_of(fragment_uniforms)),
	)
	sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
}

// icon_box returns the box for a `size`px icon centered in the layout box of
// the element `id`, if that element was laid out this frame.
icon_box :: proc(element_id: string, size: f32, hash: ..u32) -> (clay.BoundingBox, bool) {
	id: clay.ElementId
	if len(hash) > 0 {
		id = clay.ID(element_id, hash[0])
	} else {
		id = clay.ID(element_id)
	}
	data := clay.GetElementData(id)
	if !data.found || data.boundingBox.width <= 0 || data.boundingBox.height <= 0 {
		return {}, false
	}
	b := data.boundingBox
	return clay.BoundingBox {
			x = b.x + (b.width - size) / 2,
			y = b.y + (b.height - size) / 2,
			width = size,
			height = size,
		},
		true
}

// draw_ui_icons overlays the vector icons for the duplicate/remove-track and
// jog buttons plus the snap playhead/clip toggle buttons (settings_icon_button).
// The clay elements are hit-test targets (main.odin) with ids unchanged; only
// the visuals move from baked glyphs to embedded icons. Active toggles and the
// highlighted jog direction tint brighter, mirroring the text labels they
// replace.
draw_ui_icons :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
) {
	draw_icon_in_element(
		renderer,
		command_buffer,
		pass,
		"SnapClipToPh",
		.SnapClipToPlayhead,
		snap_clips_to_playhead,
		16,
	)
	draw_icon_in_element(
		renderer,
		command_buffer,
		pass,
		"SnapPhToClip",
		.SnapPlayheadToClip,
		snap_playhead_to_clips,
		16,
	)
	draw_icon_in_element(
		renderer,
		command_buffer,
		pass,
		"PlayBack",
		.SkipBack,
		playhead.playing && playback_dir == -1,
		15,
	)
	draw_icon_in_element(
		renderer,
		command_buffer,
		pass,
		"PlayFwd",
		.SkipForward,
		playhead.playing && playback_dir == 1,
		15,
	)
	// NOTE: The Duplicate/Remove icons sit in the scrolled track-name gutters,
	// so their clay boxes move off-window when a track scrolls out of view.
	// render_icon draws with no scissor: clip the whole gutter-icon pass to the
	// TracksSection viewport so off-screen gutter icons never paint over the
	// ruler/timeline bar.
	sec := clay.GetElementData(clay.ID("TracksSection")).boundingBox
	if sec.width > 0 && sec.height > 0 {
		sdl.SetGPUScissor(
			pass,
			sdl.Rect{c.int(sec.x), c.int(sec.y), c.int(sec.width), c.int(sec.height)},
		)
	}
	for ti in 0 ..< len(timeline.tracks) {
		track_id := clay.ID("DuplicateTrack", u32(ti))
		dup_color := clay.PointerOver(track_id) ? BUTTON_BORDER_HOVER : TEXT
		draw_icon_in_element_color(
			renderer,
			command_buffer,
			pass,
			"DuplicateTrack",
			.Duplicate,
			dup_color,
			16,
			u32(ti),
		)
		remove_id := clay.ID("RemoveTrack", u32(ti))
		remove_color := clay.PointerOver(remove_id) ? BUTTON_BORDER_HOVER : TEXT
		draw_icon_in_element_color(
			renderer,
			command_buffer,
			pass,
			"RemoveTrack",
			.RemoveTrack,
			remove_color,
			16,
			u32(ti),
		)
	}
	sdl.SetGPUScissor(pass, sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)})
}

draw_icon_in_element :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	element_id: string,
	id: Icon_Id,
	active: bool,
	size: f32,
	hash: ..u32,
) {
	color := active ? BUTTON_BORDER_HOVER : TEXT
	draw_icon_in_element_color(renderer, command_buffer, pass, element_id, id, color, size, ..hash)
}

draw_icon_in_element_color :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	element_id: string,
	id: Icon_Id,
	color: clay.Color,
	size: f32,
	hash: ..u32,
) {
	box, ok := icon_box(element_id, size, ..hash)
	if !ok {
		return
	}
	render_icon(renderer, command_buffer, pass, box, id, color)
}

// draw_preview_hud paints the audio-vs-video clock overlay in the corner of the
// preview while playing. It answers the one question that has been argued from
// two sides this whole session with a number everyone can see: does the audio
// content position (A, from the device clock) fall behind the video content
// position (V, the playhead) — and at what delta.
draw_preview_hud :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	preview: clay.BoundingBox,
) {
	if !sync.atomic_load(&audio_run_flag) {
		return
	}
	fps := timeline_fps()
	if fps <= 0 {
		return
	}
	label_buf: [64]u8
	label := fmt.bprintf(
		label_buf[:],
		"A %6.2f  V %6.2f  d %+.2f",
		f64(sync.atomic_load(&audio_dev_frame)) / fps,
		f64(playhead.frame) / fps,
		f64(sync.atomic_load(&audio_dev_frame) - playhead.frame) / fps,
	)
	fs: u16 = FONT_SMALL
	text_w := f32(len(label)) * f32(fs) * 0.6
	pill := clay.BoundingBox {
		x      = preview.x + 8,
		y      = preview.y + 8,
		width  = text_w + 10,
		height = 17,
	}
	render_sdf_rect(renderer, command_buffer, pass, pill, TOOLTIP_BG, 4, 0)
	render_text(
		renderer,
		command_buffer,
		pass,
		clay.BoundingBox{x = pill.x + 5, y = pill.y + 2, width = text_w, height = f32(fs)},
		clay.TextRenderData {
			stringContents = clay.StringSlice {
				length = c.int32_t(len(label)),
				chars = ([^]c.char)(raw_data(label)),
			},
			textColor = TOOLTIP_TEXT,
			fontSize = fs,
			letterSpacing = 1,
			lineHeight = fs,
		},
	)
}

// import_cancel_box is the modal's Cancel button hit-box, set by
// draw_import_progress each frame while the overlay is visible (main.odin uses
// it for manual click dispatch).
import_cancel_box: clay.BoundingBox

// draw_ui_notice paints the transient on-window notice (ui_notice_text) as a
// small dimmed panel centered on the window, shown until its deadline passes.
// main.odin calls clear_expired_ui_notice each frame so the string is freed the
// moment the notice expires.
draw_ui_notice :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	win_w, win_h: f32,
) {
	if len(ui_notice_text) == 0 || sdl.GetTicks() >= ui_notice_until {
		return
	}
	render_sdf_rect(renderer, command_buffer, pass, {0, 0, win_w, win_h}, {6, 7, 10, 205}, 0, 0)

	W: f32 = 480
	H: f32 = 96
	panel := clay.BoundingBox {
		x      = (win_w - W) / 2,
		y      = (win_h - H) / 2,
		width  = W,
		height = H,
	}
	render_sdf_rect(renderer, command_buffer, pass, panel, EDITOR_BG, 10, 0)
	render_sdf_rect(
		renderer,
		command_buffer,
		pass,
		{panel.x, panel.y, panel.width, 3},
		BUTTON_BORDER_HOVER,
		0,
		0,
	)

	msg := string(ui_notice_text)
	msg_len := min(len(msg), 120)
	render_text(
		renderer,
		command_buffer,
		pass,
		clay.BoundingBox {
			x = panel.x + 24,
			y = panel.y + 34,
			width = panel.width - 48,
			height = f32(FONT_NORMAL),
		},
		clay.TextRenderData {
			stringContents = clay.StringSlice {
				length = c.int32_t(msg_len),
				chars = ([^]c.char)(raw_data(msg)),
			},
			textColor = TEXT,
			fontSize = FONT_NORMAL,
			letterSpacing = 1,
			lineHeight = FONT_NORMAL,
		},
	)
}

// draw_import_progress paints the modal overlay for a background proxy build:
// a dimmed full-window veil, a panel with the source name, phase label,
// progress bar (indeterminate while ffmpeg estimates), percent, and a Cancel
// button. Drawn last so it sits above every clay/gpu layer.
draw_import_progress :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	win_w, win_h: f32,
) {
	active, frac, phase, src := import_bg_status()
	if !active {
		return
	}
	render_sdf_rect(renderer, command_buffer, pass, {0, 0, win_w, win_h}, {6, 7, 10, 215}, 0, 0)

	W: f32 = 440
	H: f32 = 180
	panel := clay.BoundingBox {
		x      = (win_w - W) / 2,
		y      = (win_h - H) / 2,
		width  = W,
		height = H,
	}
	render_sdf_rect(renderer, command_buffer, pass, panel, EDITOR_BG, 10, 0)
	render_sdf_rect(
		renderer,
		command_buffer,
		pass,
		{panel.x, panel.y, panel.width, 3},
		BUTTON_BORDER_HOVER,
		0,
		0,
	)

	title := "Building preview proxy…"
	if phase == .Building {
		title = "Building preview proxy…"
	} else if phase == .Verifying {
		title = "Verifying proxy…"
	} else {
		title = "Preparing proxy…"
	}
	render_text(
		renderer,
		command_buffer,
		pass,
		clay.BoundingBox {
			x = panel.x + 24,
			y = panel.y + 22,
			width = panel.width - 48,
			height = f32(FONT_NORMAL),
		},
		clay.TextRenderData {
			stringContents = clay.StringSlice {
				length = c.int32_t(len(title)),
				chars = ([^]c.char)(raw_data(title)),
			},
			textColor = TEXT,
			fontSize = FONT_NORMAL,
			letterSpacing = 1,
			lineHeight = FONT_NORMAL,
		},
	)

	// Source name, truncated to the panel (raw byte clamp; typical files are ASCII).
	name := string(src)
	name_len := min(len(name), 52)
	render_text(
		renderer,
		command_buffer,
		pass,
		clay.BoundingBox {
			x = panel.x + 24,
			y = panel.y + 50,
			width = panel.width - 48,
			height = f32(FONT_SMALL),
		},
		clay.TextRenderData {
			stringContents = clay.StringSlice {
				length = c.int32_t(name_len),
				chars = ([^]c.char)(raw_data(name)),
			},
			textColor = TOOLTIP_TEXT,
			fontSize = FONT_SMALL,
			letterSpacing = 1,
			lineHeight = FONT_SMALL,
		},
	)

	fill_frac := f32(frac)
	if fill_frac < 0 {
		fill_frac = 0.25 // indeterminate while ffmpeg estimates
	}
	if fill_frac > 1 {
		fill_frac = 1
	}
	track := clay.BoundingBox {
		x      = panel.x + 24,
		y      = panel.y + 84,
		width  = panel.width - 48,
		height = 12,
	}
	render_sdf_rect(renderer, command_buffer, pass, track, HANDLE_FILL, 6, 0)
	if phase == .Building && fill_frac > 0 {
		fill := clay.BoundingBox {
			x      = track.x,
			y      = track.y,
			width  = track.width * fill_frac,
			height = track.height,
		}
		render_sdf_rect(renderer, command_buffer, pass, fill, BUTTON_BORDER_HOVER, 6, 0)
	}

	if frac >= 0 && phase == .Building {
		pct_buf: [16]u8
		pct := fmt.bprintf(pct_buf[:], "%d%%", int(frac * 100 + 0.5))
		render_text(
			renderer,
			command_buffer,
			pass,
			clay.BoundingBox {
				x = panel.x + 24,
				y = panel.y + 102,
				width = panel.width - 48,
				height = f32(FONT_SMALL),
			},
			clay.TextRenderData {
				stringContents = clay.StringSlice {
					length = c.int32_t(len(pct)),
					chars = ([^]c.char)(raw_data(pct)),
				},
				textColor = TOOLTIP_TEXT,
				fontSize = FONT_SMALL,
				letterSpacing = 1,
				lineHeight = FONT_SMALL,
			},
		)
	}

	cancel := clay.BoundingBox {
		x      = panel.x + panel.width - 104,
		y      = panel.y + panel.height - 40,
		width  = 80,
		height = 26,
	}
	render_sdf_rect(renderer, command_buffer, pass, cancel, BUTTON, 6, 0)
	render_sdf_rect(renderer, command_buffer, pass, cancel, BUTTON_BORDER, 6, 1)
	import_cancel_box = cancel
	cancel_label := "Cancel"
	render_text(
		renderer,
		command_buffer,
		pass,
		clay.BoundingBox {
			x = cancel.x + 6,
			y = cancel.y + 6,
			width = cancel.width - 12,
			height = f32(FONT_NORMAL),
		},
		clay.TextRenderData {
			stringContents = clay.StringSlice {
				length = c.int32_t(len(cancel_label)),
				chars = ([^]c.char)(raw_data(cancel_label)),
			},
			textColor = TEXT,
			fontSize = FONT_NORMAL,
			letterSpacing = 1,
			lineHeight = FONT_NORMAL,
		},
	)
}

// create_text_texture creates a tight R8G8B8A8 texture (owned by the slot) for
// a text clip's baked raster. A text slot owns its texture (unlike video slots,
// which point at the shared fixed preview_textures); it must be released via
// release_slot_owned_texture when the slot is freed or reused for a video clip.
create_text_texture :: proc(device: ^sdl.GPUDevice, w, h: c.int) -> ^sdl.GPUTexture {
	if w <= 0 || h <= 0 {
		// SDL asserts on 0-sized textures; a text slot with no ink yet must
		// stay texture-less (draw skips it) until a real raster exists.
		return nil
	}
	return sdl.CreateGPUTexture(
		device,
		sdl.GPUTextureCreateInfo {
			type = .D2,
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = u32(w),
			height = u32(h),
			layer_count_or_depth = 1,
			num_levels = 1,
			sample_count = ._1,
		},
	)
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
upload_preview_slot :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	slot: ^Preview_Slot,
) {
	spall_scope(#procedure)
	if slot.texture == nil {
		return
	}
	if slot.is_text {
		upload_text_slot(renderer, command_buffer, slot)
		return
	}
	transfer := sdl.CreateGPUTransferBuffer(
		renderer.device,
		sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = PREVIEW_W * PREVIEW_H * 4},
	)
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
	source := sdl.GPUTextureTransferInfo {
		transfer_buffer = transfer,
		pixels_per_row  = PREVIEW_W,
		rows_per_layer  = PREVIEW_H,
	}
	destination := sdl.GPUTextureRegion {
		texture = slot.texture,
		w       = PREVIEW_W,
		h       = PREVIEW_H,
		d       = 1,
	}
	sdl.UploadToGPUTexture(copy_pass, source, destination, false)
	sdl.EndGPUCopyPass(copy_pass)
	slot.tex_dirty = false
}

// upload_text_slot uploads a text slot's full raster buffer (text_tex_w x
// text_tex_h, the estimated buffer size) into its texture.
upload_text_slot :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	slot: ^Preview_Slot,
) {
	w := u32(slot.text_tex_w)
	h := u32(slot.text_tex_h)
	if w <= 0 || h <= 0 || slot.text_buf == nil {
		return
	}
	n := int(w) * int(h) * 4
	transfer := sdl.CreateGPUTransferBuffer(
		renderer.device,
		sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = u32(n)},
	)
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
	source := sdl.GPUTextureTransferInfo {
		transfer_buffer = transfer,
		pixels_per_row  = w,
		rows_per_layer  = h,
	}
	destination := sdl.GPUTextureRegion {
		texture = slot.texture,
		w       = w,
		h       = h,
		d       = 1,
	}
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
draw_preview :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	bounds: clay.BoundingBox,
) {
	if renderer.preview_pipeline == nil {
		return
	}
	// Clip everything (zoomed content, background, border) to the preview window
	// so zooming/panning behaves like a scrollable viewport.
	scissor := sdl.Rect {
		c.int(bounds.x),
		c.int(bounds.y),
		c.int(bounds.width),
		c.int(bounds.height),
	}
	sdl.SetGPUScissor(pass, scissor)
	defer sdl.SetGPUScissor(
		pass,
		sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)},
	)

	canvas := preview_canvas(bounds)
	// The composited/canvas area has a completely black background.
	view := preview_view(canvas)
	render_sdf_rect(renderer, command_buffer, pass, view, clay.Color{0, 0, 0, 255}, 0, 0)

	// IMPORTANT: The clip IMAGE must never paint outside the final rendered area
	// (the project canvas). Clip it to the canvas rect ∩ the preview widget so a clip
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
	// keep a STABLE index per clip identity (update_preview_slots), so index
	// order no longer means depth: sort the visible slots by layer (the
	// track-order walk position, lowest = topmost) and draw the lowest layer
	// last so the top track's clip appears on top.
	order: [MAX_PREVIEW_SLOTS]int
	n := 0
	for i := 0; i < MAX_PREVIEW_SLOTS; i += 1 {
		if s := &preview_slots[i]; s.in_use && s.has_frame && s.texture != nil {
			order[n] = i
			n += 1
		}
	}
	for a := 1; a < n; a += 1 {
		key := order[a]
		b := a
		for b > 0 && preview_slots[order[b - 1]].layer > preview_slots[key].layer {
			order[b] = order[b - 1]
			b -= 1
		}
		order[b] = key
	}
	for k := n - 1; k >= 0; k -= 1 {
		slot := &preview_slots[order[k]]
		is_text := slot.text_w > 0 && slot.text_h > 0
		cb := clip_image_bounds(
			canvas,
			&Clip {
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
			},
		)
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
			fw, fh, fox, foy := source_fit_in_buffer(
				slot.source_w,
				slot.source_h,
				PREVIEW_W,
				PREVIEW_H,
			)
			u_base := f32(fox) / f32(PREVIEW_W)
			v_base := f32(foy) / f32(PREVIEW_H)
			u_span := f32(fw) / f32(PREVIEW_W)
			v_span := f32(fh) / f32(PREVIEW_H)
			u0 = u_base + slot.crop_l * u_span
			u1 = u_base + (1 - slot.crop_r) * u_span
			v0 = v_base + slot.crop_t * v_span
			v1 = v_base + (1 - slot.crop_b) * v_span
		}
		vertex_uniforms := TextVertexUniforms {
			bounds   = {cb.x, cb.y, cb.width, cb.height},
			viewport = renderer.viewport,
			_padding = {},
			uv       = {u0, v0, u1, v1},
		}
		sdl.BindGPUGraphicsPipeline(pass, renderer.preview_pipeline)
		binding := sdl.GPUTextureSamplerBinding {
			texture = slot.texture,
			sampler = renderer.preview_sampler,
		}
		sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
		sdl.PushGPUVertexUniformData(
			command_buffer,
			0,
			&vertex_uniforms,
			sdl.Uint32(size_of(vertex_uniforms)),
		)
		sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
	}
	// Draw a border box around the currently-selected clip's image rect.
	// Border/handles are editor affordances: restore the widget-level scissor so
	// handles on an off-canvas box stay visible/grabbable.
	sdl.SetGPUScissor(
		pass,
		sdl.Rect{c.int(bounds.x), c.int(bounds.y), c.int(bounds.width), c.int(bounds.height)},
	)
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
