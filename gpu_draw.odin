package main

import clay "clay-odin"
import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
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
	// edge. Vertically the band runs from just above the ruler down to the
	// window's bottom edge, since the playhead line runs through every track row.
	scissor_to_bottom(renderer, pass, ruler.x, ruler.y - 8, ruler.width)
	defer sdl.SetGPUScissor(
		pass,
		sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)},
	)
	dur := timeline_duration()
	// Adapt the tick spacing to the current zoom so labels stay ~70px apart.
	major := nice_frame_step(timeline_view.zoom)
	minor := max(major / 5, 1)

	// Tick marks along the bottom edge of the ruler strip.
	minor_h := ruler.height * 0.35
	major_h := ruler.height * 0.6
	start_f := i64(f32(i64(timeline_view.start / f32(minor))) * f32(minor))
	// Ticks span [0, dur): dur is the exclusive end and holds no frame (the
	// last content frame is dur-1), so a tick/label there reads as a phantom
	// "one frame above the clip's frame count" -- the playhead's max is
	// already dur-1, which draws the boundary instead.
	for f := start_f; f < dur; f += minor {
		x := ruler.x + (f32(f) - timeline_view.start) * timeline_view.zoom
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
	line_x := ruler.x + (f32(playhead.frame) - timeline_view.start) * timeline_view.zoom
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
	scissor_to_bottom(renderer, pass, ruler.x, 0, ruler.width)
	defer sdl.SetGPUScissor(
		pass,
		sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)},
	)
	y := ruler.y + ruler.height
	isect := ruler.x + ruler.width
	if project.start_frame >= 0 &&
	   project.end_frame >= 0 &&
	   project.start_frame < project.end_frame {
		x1 := ruler.x + (f32(project.start_frame) - timeline_view.start) * timeline_view.zoom
		x2 := ruler.x + (f32(project.end_frame) - timeline_view.start) * timeline_view.zoom
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
		x1 := ruler.x + (f32(project.start_frame) - timeline_view.start) * timeline_view.zoom
		if x1 >= ruler.x && x1 <= isect {
			render_sdf_rect(renderer, command_buffer, pass, {x1, y, 2, 8}, RANGE_COLOR, 0, 0)
		}
	}
	if project.end_frame >= 0 {
		x2 := ruler.x + (f32(project.end_frame) - timeline_view.start) * timeline_view.zoom
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
				cr := scissor_intersect(renderer, bounds, current)
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
					corner_mode_for(command.id),
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
				// render_sdf_rect's last arg is a single uniform band width
				// (0 = fill the whole quad). A per-side border therefore
				// cannot go through it directly: passing .left makes a
				// bottom-only border (e.g. the app-bar separator) a border=0
				// fill that paints over the element's own children, which are
				// drawn before the border command. Decompose it into one thin
				// quad per non-zero side instead.
				w := config.width
				if w.left == w.right && w.right == w.top && w.top == w.bottom {
					render_sdf_rect(
						renderer,
						command_buffer,
						pass,
						bounds,
						color,
						config.cornerRadius.topLeft,
						f32(w.left),
						corner_mode_for(command.id),
					)
				} else {
					if w.top > 0 {
						render_sdf_rect(
							renderer,
							command_buffer,
							pass,
							clay.BoundingBox{bounds.x, bounds.y, bounds.width, f32(w.top)},
							color,
							0,
							0,
						)
					}
					if w.bottom > 0 {
						render_sdf_rect(
							renderer,
							command_buffer,
							pass,
							clay.BoundingBox {
								bounds.x,
								bounds.y + bounds.height - f32(w.bottom),
								bounds.width,
								f32(w.bottom),
							},
							color,
							0,
							0,
						)
					}
					if w.left > 0 {
						render_sdf_rect(
							renderer,
							command_buffer,
							pass,
							clay.BoundingBox{bounds.x, bounds.y, f32(w.left), bounds.height},
							color,
							0,
							0,
						)
					}
					if w.right > 0 {
						render_sdf_rect(
							renderer,
							command_buffer,
							pass,
							clay.BoundingBox {
								bounds.x + bounds.width - f32(w.right),
								bounds.y,
								f32(w.right),
								bounds.height,
							},
							color,
							0,
							0,
						)
					}
				}
			}
		case .Text:
			if !suppressed {
				render_text(renderer, command_buffer, pass, bounds, command.renderData.text)
			}
		}
	}
}

// tracks_scroll_box is the track list's own viewport: the TracksSection box, which
// is the rect Clay clips the rows to (clip.vertical) and slides them by
// (childOffset = -timeline_view.top).
//
// It is the ONE rect every track-lane overlay must intersect. draw_clip_markers
// and draw_keyframes run after render_clay, so they do not inherit Clay's scissor
// stack and set their own; scissoring to the row's own ClipsSection box alone let
// a vertically scrolled row paint over the ruler strip and the panels above the
// timeline, because the row box has already moved out of the viewport. Reads zero
// when the timeline is not laid out (empty timeline, collapsed subtree), which the
// callers' `width <= 0` guards already treat as "nothing to paint".
tracks_scroll_box :: proc() -> clay.BoundingBox {
	return clay.GetElementData(clay.ID("TracksSection")).boundingBox
}

// box_union is the smallest rect containing both boxes. The marker pass needs it
// because a track's paintable span is its lane PLUS the insert gap above it. An
// empty input is treated as absent, so unioning a laid-out box with a collapsed
// one returns the laid-out one rather than inflating its bounds to the origin.
box_union :: proc(a, b: clay.BoundingBox) -> clay.BoundingBox {
	if a.width <= 0 || a.height <= 0 {
		return b
	}
	if b.width <= 0 || b.height <= 0 {
		return a
	}
	x := min(a.x, b.x)
	y := min(a.y, b.y)
	return clay.BoundingBox {
		x      = x,
		y      = y,
		width  = max(a.x + a.width, b.x + b.width) - x,
		height = max(a.y + a.height, b.y + b.height) - y,
	}
}

// box_intersect clips `a` to `b`, returning an EMPTY rect (zero or negative
// extent) when they do not overlap. An empty result is the cull signal: the
// overlay loop skips a track rather than setting a degenerate scissor.
box_intersect :: proc(a, b: clay.BoundingBox) -> clay.BoundingBox {
	x := max(a.x, b.x)
	y := max(a.y, b.y)
	x2 := min(a.x + a.width, b.x + b.width)
	y2 := min(a.y + a.height, b.y + b.height)
	return clay.BoundingBox{x = x, y = y, width = x2 - x, height = y2 - y}
}

// kf_lane_rect is the region draw_keyframes paints one track into: its clip lane,
// clipped to the track-list viewport. Empty when the track is scrolled out of view.
kf_lane_rect :: proc(track_idx: int) -> clay.BoundingBox {
	lane := clay.GetElementData(clay.ID("ClipsSection", u32(track_idx))).boundingBox
	if lane.width <= 0 || lane.height <= 0 {
		return {}
	}
	return box_intersect(lane, tracks_scroll_box())
}

// marker_lane_rect is the region draw_clip_markers paints one track into: the
// clip lane plus the insert gap above it, clipped to the track-list viewport. The
// gap holds the point-marker triangles, so it is inside the same rect.
//
// The gap is keyed by ORDER row (ui.odin keys TrackGap by r, ClipsSection by
// storage index), so this is the row the track occupies in the visual stack, not
// its storage index. Storage==row only until the first reorder.
marker_lane_rect :: proc(track_idx: int) -> clay.BoundingBox {
	lane := clay.GetElementData(clay.ID("ClipsSection", u32(track_idx))).boundingBox
	row := order_row_of(track_idx)
	if row < 0 {
		return {}
	}
	gap := clay.GetElementData(clay.ID("TrackGap", u32(row))).boundingBox
	span := box_union(lane, gap)
	if span.width <= 0 || span.height <= 0 {
		return {}
	}
	return box_intersect(span, tracks_scroll_box())
}

// scissor_clamp clips a scissor rect to the RENDER TARGET.
//
// SDL rejects a scissor whose x+w or y+h exceeds the target and logs an assertion
// for it (SDL_SetGPUScissor_REAL, SDL_gpu.c:1984), and it is an assert, not a clamp:
// the app keeps running and the rect is wrong, which is why this read as a stray
// message rather than a visible bug.
//
// Layout boxes are not bounded by the window. A scrolled lane, a clip row wider than
// the viewport, a box_union over a gap, a band starting near the bottom edge -- each
// of those can name a rect that overshoots. The user hit this twice with a portrait
// 1080x1920 clip on the timeline.
//
// This exists as ONE clamp rather than a check per call site because there are 23
// SetGPUScissor calls in the draw code and every one of them is a place to forget.
// The hazard already documented on scissor_to_bottom (a full-height band at a non-zero
// y overshoots by exactly `top`) is the same missing clamp seen from one direction.
scissor_clamp :: proc(renderer: ^GPU_Renderer, rect: sdl.Rect) -> sdl.Rect {
	tw := i32(renderer.viewport.x)
	th := i32(renderer.viewport.y)
	// Truncation must not round a negative coordinate UP to zero, or a box that
	// starts off-screen left would silently gain a pixel of clamped width.
	x0 := clamp(rect.x, 0, tw)
	y0 := clamp(rect.y, 0, th)
	x1 := clamp(rect.x + rect.w, 0, tw)
	y1 := clamp(rect.y + rect.h, 0, th)
	return sdl.Rect{x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}

// scissor_to_bottom sets a scissor to the vertical band starting at `top` and
// running to the window's bottom edge, `width` wide from `x`.
//
// The height is the window height LEFT OVER below `top`, not the window height
// itself. SDL rejects a scissor whose y+h exceeds the render target
// (SDL_SetGPUScissor_REAL, SDL_gpu.c:1982) and logs an assertion for it, so
// naming the band by its bottom edge is the only way to write it correctly: a
// full-height rect at a non-zero y overshoots by exactly `top`. Every band that
// starts below the window's top edge -- the ruler's playhead column, the render
// range, the marker tooltip -- goes through here rather than spelling the
// subtraction out at each site.
//
// Still clamped on the way out, because `top - 8` (the playhead column starts just
// above the ruler) can itself sit below the window's bottom edge in a short window,
// which would make the leftover height NEGATIVE -- a size SDL also rejects.
scissor_to_bottom :: proc(
	renderer: ^GPU_Renderer,
	pass: ^sdl.GPURenderPass,
	x, top, width: f32,
) {
	sdl.SetGPUScissor(
		pass,
		scissor_clamp(
			renderer,
			sdl.Rect {
				c.int(x),
				c.int(top),
				c.int(width),
				c.int(renderer.viewport.y - top),
			},
		),
	)
}

// scissor_intersect clips a Clay command's bounds to the active scissor rect.
//
// The active rect is clamped to the render target on the way in. Intersecting with a
// rect that already overshoots cannot produce a valid one -- it can only shrink the
// visible area by however much the clip was wrong -- so without this the Clay scissor
// stack could reintroduce exactly the out-of-bounds rect scissor_clamp exists to stop.
scissor_intersect :: proc(renderer: ^GPU_Renderer, bounds: clay.BoundingBox, clip: sdl.Rect) -> sdl.Rect {
	cl := scissor_clamp(renderer, clip)
	x := max(c.int(bounds.x), cl.x)
	y := max(c.int(bounds.y), cl.y)
	x2 := min(c.int(bounds.x + bounds.width), cl.x + cl.w)
	y2 := min(c.int(bounds.y + bounds.height), cl.y + cl.h)
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
	blink := (monotonic_ms() / 500) % 2 == 0
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
	if active_interaction == .Clip_Resize && clip_resize.edge == .Roll {
		if clip_resize.roll_track < 0 || clip_resize.roll_track >= len(timeline.tracks) {
			return
		}
		track := &timeline.tracks[clip_resize.roll_track]
		left := clip_index_by_id(track, clip_resize.roll_left_id)
		right := clip_index_by_id(track, clip_resize.roll_right_id)
		if left < 0 || right != left+1 { return }
		box := clay.GetElementData(
			clay.ID("TimelineClip", u32(clip_resize.roll_track*1000+left)),
		).boundingBox
		render_sdf_rect(
			renderer,
			command_buffer,
			pass,
			clay.BoundingBox{x=box.x+box.width-1.5, y=box.y, width=3, height=box.height},
			BUTTON_BORDER_HOVER,
			0,
			0,
		)
		return
	}
	edge := Clip_Resize_Edge.None
	if active_interaction == .Clip_Resize {
		edge = clip_resize.edge
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
	if edge == .None {
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
			if edge == .Left {
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
	// Marker lines and triangles must stay inside their track's column AND
	// inside the track list's visible viewport; a marker inside a tile that has
	// slid under the track-name gutter (or off the right edge) would otherwise
	// render on top of neighboring rows and headers, and a row scrolled out of
	// the viewport would render on top of the ruler strip and the panels above
	// the timeline. The gap triangle sits above the lane, so the scissor spans
	// lane + insert gap, clipped to the viewport.
	restore_full := false
	for track, track_idx in timeline.tracks {
		// Scissor to the track's lane AND insert gap, clipped to the track-list
		// viewport. The viewport half is what keeps a vertically scrolled row's
		// markers inside the timeline: the row box alone has already slid out
		// under the ruler, so scissoring to it alone painted over the panels
		// above. Empty rect -> the whole track is scrolled out of view.
		span := marker_lane_rect(track_idx)
		if span.width <= 0 || span.height <= 0 {
			continue
		}
		lane := clay.GetElementData(clay.ID("ClipsSection", u32(track_idx))).boundingBox
		gap :=
			clay.GetElementData(
				clay.ID("TrackGap", u32(order_row_of(track_idx))),
			).boundingBox
		sdl.SetGPUScissor(
			pass,
			scissor_clamp(
				renderer,
				sdl.Rect{c.int(span.x), c.int(span.y), c.int(span.width), c.int(span.height)},
			),
		)
		restore_full = true
		for clip, index in track.clips {
			if clip.markers.n == 0 {
				continue
			}
			box :=
				clay.GetElementData(clay.ID("TimelineClip", u32(track_idx * 1000 + index))).boundingBox
			if box.width <= 0 || box.height <= 0 {
				continue
			}
			color := BUTTON_BORDER
			if selection.track == track_idx && selection.index == index {
				color = BUTTON_BORDER_HOVER
			}
			rows := [3]f32{5, 3, 1}
			for marker_idx in 0..<clip.markers.n {
				m := session_marker_at(clip.markers, marker_idx)
				line_x := clamp(
					box.x + f32(m.source_frame - clip.source_start_frame) * timeline_view.zoom,
					box.x,
					box.x + box.width,
				)
				// Cull markers scrolled out of the lane's frame window. The
				// scissor rejects these quads anyway, but each one still costs a
				// uniform upload and a draw, and a long project carries markers
				// far outside the visible range at any zoom.
				if line_x < span.x - MARKER_CULL_SLACK ||
				   line_x > span.x + span.width + MARKER_CULL_SLACK {
					continue
				}
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
				if len(marker_label(&m)) > 0 && mouse_y >= gap.y && mouse_y <= gap.y + gap.height {
					d := abs(mouse_x - line_x)
					if d <= 6 && d < best_dist {
						best_dist = d
						hover_label = marker_label(&m)
						hover_x = line_x
						// The tooltip renders in the gap strip above the marker's
						// OWN track, so the strip travels with the winning marker
						// rather than whichever track was processed last.
						gap_bounds = gap
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

// kf_key_center maps a key to its diamond's center on screen from the clip wrap
// box. Single source of truth for the diamond geometry, shared by draw_keyframes
// and the click hit-test (interaction.odin) so the pickable spot always lines up
// with the painted diamond. Lane tr hugs the tile's bottom edge (ui.odin keys
// KeyframeLane by tr below the fixed-height tile), so y derives from the box and
// the LANE ELEMENT's layout; cx clamps to the wrap so a key that drifted past a
// trimmed edge paints at the edge rather than outside the row.
kf_key_center :: proc(box: clay.BoundingBox, lane: int, frame_off: i32) -> (f32, f32) {
	cy := box.y + CLIP_TILE_HEIGHT + (f32(lane) + 0.5) * KF_ROW_H
	cx := clamp(
		box.x + f32(frame_off) * timeline_view.zoom,
		box.x + KF_DIAMOND_R,
		box.x + box.width - KF_DIAMOND_R,
	)
	return cx, cy
}

// diamond_at paints one keyframe diamond centered on (cx, cy); selected uses
// the light fill so the keyframe cursor reads against the neutral rest state.
// half is the diamond's bounding half-width: KF_DIAMOND_R in the timeline,
// KF_BTN_R for the inspector's add-keyframe buttons. filled draws the diamond
// solid (border 0 in the SDF); otherwise the SDF renders a 1px ring with a
// transparent interior (the button affordance look).
diamond_at :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	cx, cy: f32,
	half: f32,
	fill: clay.Color,
	filled: bool,
) {
	render_sdf_rect(
		renderer,
		command_buffer,
		pass,
		clay.BoundingBox {
			x = cx - half,
			y = cy - half,
			width = half * 2,
			height = half * 2,
		},
		fill,
		KF_DIAMOND_CORNER,
		filled ? 0.0 : KF_DIAMOND_BORDER,
		rotation = KF_DIAMOND_ROT,
	)
}

// draw_keyframes paints each keyframed clip's diamond lane rows below its tile:
// one lane per keyframe track (the KeyframeLane elements in ui.odin), diamonds
// centered on the lane at the key's clip-relative frame. A diamond is the
// 45°-rotated rect SDF — the same rotation path the gain knob's needle uses.
// Overlay after the Clay batch because the wrapper's box only exists via
// GetElementData, and scissored per track so a key that drifted past a trimmed
// edge can never overpaint the gutter or a neighboring row.
draw_keyframes :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
) {
	if len(timeline.tracks) == 0 {
		return
	}
	for track, track_idx in timeline.tracks {
		// Scissor to the track's clip lane CLIPPED TO THE TRACK-LIST VIEWPORT, and
		// skip the track entirely when that is empty. The row's own box has
		// already been slid by the vertical scroll (TracksSection's childOffset),
		// so scissoring to it alone let a row scrolled up or down paint its
		// diamonds over the ruler strip and the panels above the timeline. Empty
		// rect -> the track is off screen and costs no draw calls.
		lane := kf_lane_rect(track_idx)
		if lane.width <= 0 || lane.height <= 0 {
			continue
		}
		sdl.SetGPUScissor(
			pass,
			scissor_clamp(
				renderer,
				sdl.Rect{c.int(lane.x), c.int(lane.y), c.int(lane.width), c.int(lane.height)},
			),
		)
		for clip, index in track.clips {
			rows := clip.keyframe_tracks.n
			if rows == 0 {
				continue
			}
			box :=
				clay.GetElementData(clay.ID("TimelineClipWrap", u32(track_idx * 1000 + index))).boundingBox
			if box.width <= 0 || box.height <= 0 {
				continue
			}
			for tr in 0 ..< rows {
				v := session_kf_view(session_trk_view(clip.keyframe_tracks,tr).keys)
				for k_idx in 0 ..< session_trk_view(clip.keyframe_tracks,tr).keys.n {
					k := v[k_idx]
					// kf_sel_frame answers both questions the paint asks of
					// every diamond — is this key selected, and where should it
					// be — in one scan. During a drag the frame it returns is the
					// previewed destination, not k.frame_off: the gesture writes
					// nothing until its release, so the store still holds where
					// the key will be normalized FROM (see Kf_Move).
					frame, selected :=
						kf_sel_frame(Kf_Ref{track_idx, index, tr, k_idx}, k.frame_off)
					cx, cy := kf_key_center(box, tr, frame)
					// Cull keys scrolled out of the lane's visible range. The
					// scissor rejects these quads anyway, but each still costs two
					// uniform uploads and two draws, and at TIMELINE_MIN_ZOOM a
					// long project's keys sit megabytes off screen -- so the pass
					// paid full price for geometry no one could see.
					if cx < lane.x - KF_DIAMOND_R || cx > lane.x + lane.width + KF_DIAMOND_R {
						continue
					}
					fill := KF_DIAMOND_FILL
					if selected {
						fill = KF_DIAMOND_FILL_SELECTED
					}
					// Two-layer diamond: a full-size accent ring under a fill
					// inset by the border width, so every key gets a thin
					// colored outline against the row background.
					diamond_at(renderer, command_buffer, pass, cx, cy, KF_DIAMOND_R, KF_DIAMOND_BORDER_COLOR, true)
					diamond_at(renderer, command_buffer, pass, cx, cy, KF_DIAMOND_R - f32(KF_DIAMOND_BORDER), fill, true)
				}
			}
		}
		sdl.SetGPUScissor(
			pass,
			sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)},
		)
	}
}

// draw_drag_ghost paints the translucent drop preview for a clip being dragged
// onto another track: a ghost tile in the hovered lane at the nearest
// non-overlapping slot. Same width as the dragged clip, positioned from
// clip_move.ghost_start like regular clips (frame * zoom offset by the view).
draw_drag_ghost :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
) {
	if active_interaction != .Clip_Move || clip_move.clip == nil {
		return
	}
	if clip_move.hover_track < 0 || clip_move.hover_track >= len(timeline.tracks) {
		return
	}
	if clip_move.hover_track == clip_move.source_track {
		return
	}
	// Linked group: paint a ghost for every member in its destination lane at the
	// mouse-aligned position (m.start + clip_move.group_delta), so the whole unit
	// slides with the drag. If any member can't land at that exact spot on its
	// destination lane the drop is refused, shown red.
	if len(clip_move.group_orig) > 1 {
		// Visual-row delta through the stack order: storage indices may be
		// scrambled, but the drop targets the visual row under the pointer.
		delta_rows := order_row_of(clip_move.hover_track) - order_row_of(clip_move.source_track)
		refused := !group_vertical_feasible(delta_rows, clip_move.group_delta)
		for m in clip_move.group_orig {
			src_row := order_row_of(m.track)
			dst := src_row >= 0 ? track_at_row(src_row + delta_rows) : -1
			if dst < 0 {
				continue
			}
			lane := clay.GetElementData(clay.ID("ClipsSection", u32(dst))).boundingBox
			if lane.width <= 0 || lane.height <= 0 {
				continue
			}
			start := max(m.start + clip_move.group_delta, 0)
			x0 := lane.x + (f32(start) - timeline_view.start) * timeline_view.zoom
			w := f32(m.length) * timeline_view.zoom
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
				scissor_clamp(
					renderer,
					sdl.Rect{c.int(lane.x), c.int(lane.y), c.int(lane.width), c.int(lane.height)},
				),
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
	clip_len := clip_move.clip.source_length_frames
	if clip_len <= 0 {
		return
	}
	// The nearest valid non-overlap slot may differ per frame (it follows the
	// mouse during the drag), but the ghost must never hide an overlap it would
	// cause: clamp once more against the hovered track's live content.
	placed := clip_place_in_track(
		&timeline.tracks[clip_move.hover_track],
		-1,
		clip_len,
		clip_move.ghost_start,
	)
	lane := clay.GetElementData(clay.ID("ClipsSection", u32(clip_move.hover_track))).boundingBox
	if lane.width <= 0 || lane.height <= 0 {
		return
	}
	// Lane origin is at frame 0 = ruler.x; tiles slide with the view offset.
	x0 := lane.x + (f32(placed) - timeline_view.start) * timeline_view.zoom
	w := f32(clip_len) * timeline_view.zoom
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
		scissor_clamp(
			renderer,
			sdl.Rect{c.int(lane.x), c.int(lane.y), c.int(lane.width), c.int(lane.height)},
		),
	)
	render_sdf_rect(renderer, command_buffer, pass, bounds, clay.Color{127, 187, 179, 80}, 6, 0)
	render_sdf_rect(renderer, command_buffer, pass, bounds, clay.Color{127, 187, 179, 220}, 6, 2)
	sdl.SetGPUScissor(pass, sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)})
}

// draw_track_drag_ghost paints the drop preview while a whole track row is
// being dragged onto an insert gap (track reorder): the source row is grayed
// out (a translucent dark veil over its full gutter+clips band), and a ghost
// track row -- same teal treatment as the clip ghosts -- sits in the hovered
// gap, showing exactly which stack slot the reorder would fill. Nothing here
// mutates the timeline; move_track_to_row commits only on release.
draw_track_drag_ghost :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
) {
	if active_interaction != .Track_Drag || track_drag.idx < 0 {
		return
	}
	// The whole tracks body (strip incl. the name column) is the safe clip
	// region: a ghost/gray-out must never spill over the marker strip or out of
	// the scroll view.
	body := clay.GetElementData(clay.ID("TracksSection")).boundingBox
	if body.width <= 0 || body.height <= 0 {
		return
	}
	row_box := clay.GetElementData(clay.ID("TrackRow", u32(track_drag.idx))).boundingBox
	if row_box.width <= 0 || row_box.height <= 0 {
		return
	}
	sdl.SetGPUScissor(
		pass,
		scissor_clamp(
			renderer,
			sdl.Rect{c.int(body.x), c.int(body.y), c.int(body.width), c.int(body.height)},
		),
	)
	// Gray out the row being dragged so it reads as "lifted out of the stack".
	render_sdf_rect(renderer, command_buffer, pass, row_box, clay.Color{16, 20, 23, 160}, 4, 0)
	// Ghost row in the hovered gap: a full-width translucent tile (gutter +
	// clips band) centered on the gap strip, plus the gap itself highlighted so
	// the exact "New track" slot the drop targets is unmistakable.
	if track_drag.hover_row >= 0 {
		gap := clay.GetElementData(clay.ID("TrackGap", u32(track_drag.hover_row))).boundingBox
		if gap.width > 0 && gap.height > 0 {
			highlight := gap
			highlight.x = row_box.x
			highlight.width = row_box.width
			render_sdf_rect(renderer, command_buffer, pass, highlight, clay.Color{127, 187, 179, 140}, 3, 0)
			render_sdf_rect(renderer, command_buffer, pass, highlight, clay.Color{127, 187, 179, 230}, 3, 2)
			ghost := row_box
			ghost.y = gap.y + (gap.height - ghost.height) / 2
			render_sdf_rect(renderer, command_buffer, pass, ghost, clay.Color{127, 187, 179, 80}, 4, 0)
			render_sdf_rect(renderer, command_buffer, pass, ghost, clay.Color{127, 187, 179, 220}, 4, 2)
		}
	}
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
		scissor_to_bottom(renderer, pass, ruler.x, ruler.y - 8, ruler.width)
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

	// Clay's text command gives us the laid-out origin. The atlas bakes glyphs
	// with the baseline at the face's true ascent (not a full em) below the
	// box top, so the ink sits vertically centered in clay's measured box.
	// fall back to one em when the face metrics aren't in yet.
	scale := f32(text.fontSize) / f32(GLYPH_BAKE_PX)
	x: f32 = 0
	baseline: f32 = renderer.font.ascent_bake
	if baseline <= 0 {
		baseline = f32(GLYPH_BAKE_PX)
	}
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
			vertex_uniforms := Quad_Uniforms {
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

// corner_mode_for picks the SDF corner primitive for a clay element: the ":" 
// command line draws its pill as a squircle (superellipse corners); everything
// else keeps the plain circular arc.
corner_mode_for :: proc(id: u32) -> f32 {
	if id == clay.ID("CmdlinePopup").id {
		return 1
	}
	return 0
}

render_sdf_rect :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	bounds: clay.BoundingBox,
	color: clay.Color,
	radius, border: f32,
	corner_mode: f32 = 0,
	rotation: [2]f32 = {},
) {
	vertex_uniforms := RectVertexUniforms {
		bounds   = {bounds.x, bounds.y, bounds.width, bounds.height},
		viewport = renderer.viewport,
		rotation = rotation,
	}
	fragment_uniforms := RectFragmentUniforms {
		color = {
			f32(color[0]) / 255,
			f32(color[1]) / 255,
			f32(color[2]) / 255,
			f32(color[3]) / 255,
		},
		shape = {bounds.width, bounds.height, radius, border},
		mode  = {corner_mode, 0, 0, 0},
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

// draw_gain_knob paints the audio gain knob's indicator pointer + hub over the
// baked clay knob body. The body is a clay circle (drawn in the normal passes);
// the pointer needs rotation about the knob center, which clay has no concept
// of, so it draws here as a rotated SDF capsule (see rounded_rect.vert).
draw_gain_knob :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
) {
	_, cl, ok := selected_clip()
	if !ok || cl.kind != .Audio {
		return
	}
	bb := clay.GetElementData(clay.ID("GainKnob")).boundingBox
	if bb.width <= 0 {
		return
	}
	// Angle: 0 dB sits at 12 o'clock. Negative gain sweeps counterclockwise
	// to -sweep at the floor (9 o'clock), positive gain clockwise to +sweep
	// (3 o'clock) -- the pointer never passes the horizontal, so it reads as
	// rotating only through the top half of the dial.
	db := clamp(cl.gain, f32(GAIN_MIN_DB), f32(GAIN_MAX_DB))
	a := f32(0)
	if db <= 0 {
		a = -(db / f32(GAIN_MIN_DB)) * GAIN_KNOB_SWEEP_DEG * math.PI / 180
	} else {
		a = (db / f32(GAIN_MAX_DB)) * GAIN_KNOB_SWEEP_DEG * math.PI / 180
	}
	// Screen space (y down): a=0 points up, +90 rotates clockwise.
	dir := [2]f32{f32(math.sin(a)), f32(-math.cos(a))}
	cx := bb.x + bb.width / 2
	cy := bb.y + bb.height / 2
	half_len := KNOB_DIAMETER * GAIN_KNOB_NEEDLE_LEN * 0.5
	// The pointer is a symmetric capsule (the SDF shader rotates a rect about
	// ITS own center, so a one-sided ray could not pivot at the knob center);
	// rotation = (cos, sin) puts the rect's local x-axis along `dir`.
	needle := clay.BoundingBox {
		x = cx - half_len,
		y = cy - GAIN_KNOB_NEEDLE_W / 2,
		width = half_len * 2,
		height = GAIN_KNOB_NEEDLE_W,
	}
	render_sdf_rect(
		renderer, command_buffer, pass,
		needle, SELECT_BORDER, GAIN_KNOB_NEEDLE_W / 2, 0,
		rotation = dir,
	)
	// Mask the capsule's back half (the part behind the pivot) with a
	// counter-rotated body-colored rect, leaving only the outward pointer.
	// The mask rotates about its own center, which sits at the midpoint of the
	// hidden segment, so it stays glued to the back half at every angle.
	mask_w := f32(GAIN_KNOB_NEEDLE_W) + 4
	mc := [2]f32{cx - dir.x * half_len * 0.5, cy - dir.y * half_len * 0.5}
	mask := clay.BoundingBox {
		x = mc.x - (half_len + 2) / 2,
		y = mc.y - mask_w / 2,
		width = half_len + 2,
		height = mask_w,
	}
	render_sdf_rect(
		renderer, command_buffer, pass,
		mask, BUTTON, mask_w / 2, 0,
		rotation = dir,
	)
	// Center hub: anchors the pointer and recloses the knob body over the
	// mask's rounded near end.
	hub := clay.BoundingBox {
		x = cx - GAIN_KNOB_HUB_R,
		y = cy - GAIN_KNOB_HUB_R,
		width = GAIN_KNOB_HUB_R * 2,
		height = GAIN_KNOB_HUB_R * 2,
	}
	render_sdf_rect(renderer, command_buffer, pass, hub, EDITOR_BG, GAIN_KNOB_HUB_R, 0)
}

// draw_kf_add_buttons paints the inspector's add-keyframe buttons as keyframe
// diamonds (same KF_DIAMOND_* look as the timeline, scaled via KF_BTN_R),
// centered on each button's clay box. Hover lifts the fill like a selected key
// would, a button affordance on top of the exact keyframe glyph. Empty boxes
// (a video clip has no KfAddGain element) paint nothing. Scissored to the
// whole inspector column so a glyph sitting flush at a row edge can never
// overpaint the scrollbar gutter or the column's rounded corner.
draw_kf_add_buttons :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
) {
	ins := clay.GetElementData(clay.ID("Inspector")).boundingBox
	sdl.SetGPUScissor(
		pass,
		scissor_clamp(
			renderer,
			sdl.Rect{c.int(ins.x), c.int(ins.y), c.int(ins.width), c.int(ins.height)},
		),
	)
	for id in KF_ADD_BTN_IDS {
		bb := clay.GetElementData(clay.ID(id)).boundingBox
		if bb.width <= 0 || bb.height <= 0 {
			continue
		}
		// The key-all-modified action is the A shortcut (action.odin), not a
		// button, so there is no disabled diamond to paint for it here.
		fill := clay.PointerOver(clay.ID(id)) ? KF_DIAMOND_FILL_SELECTED : KF_DIAMOND_FILL
		if is_group_kf_btn(id) {
			// Whole-group key button: a 2x2 cluster reads "all lanes at once"
			// against the single per-lane diamond beside the value field.
			cx := bb.x + bb.width / 2
			cy := bb.y + bb.height / 2
			gap := KF_BTN_R * 0.6
			r := KF_BTN_R * 0.5
			diamond_at(renderer, command_buffer, pass, cx - gap, cy - gap, r, fill, false)
			diamond_at(renderer, command_buffer, pass, cx + gap, cy - gap, r, fill, false)
			diamond_at(renderer, command_buffer, pass, cx - gap, cy + gap, r, fill, false)
			diamond_at(renderer, command_buffer, pass, cx + gap, cy + gap, r, fill, false)
			continue
		}
		diamond_at(
			renderer, command_buffer, pass,
			bb.x + bb.width / 2, bb.y + bb.height / 2,
			KF_BTN_R, fill, false,
		)
	}
	sdl.SetGPUScissor(
		pass,
		sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)},
	)
}

// is_group_kf_btn reports whether an add-keyframe button id keys a whole
// property section (KF_GROUP_BTN_IDS) instead of one lane.
is_group_kf_btn :: proc(id: string) -> bool {
	for gid in KF_GROUP_BTN_IDS {
		if id == gid {
			return true
		}
	}
	return false
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
	vertex_uniforms := Quad_Uniforms {
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

// finder_icon_for maps a finder entry kind to the icon that represents it.
finder_icon_for :: proc(kind: Finder_Kind) -> Icon_Id {
	switch kind {
	case .Folder:
		return .FinderFolder
	case .Video:
		return .FinderVideo
	case .Audio:
		return .FinderAudio
	case .Image:
		return .FinderImage
	case .Subtitle:
		return .FinderSubtitle
	case .File:
		return .FinderFile
	case:
		return .FinderFile
	}
}

// draw_finder_rows paints every visible finder row's icon cell over the laid-out
// popup (gpu_draw.odin's icon textures are GPU-side; the clay step only made
// cells). A row whose fullpath matches an imported media-bin asset with a
// decoded thumbnail draws that thumbnail instead of the generic kind icon —
// the finder reuses real thumbs when it has them, icons otherwise.
draw_finder_rows :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
) {
	if !file_finder.active {
		return
	}
	visible := min(FINDER_MAX_ROWS, len(file_finder.filtered))
	for r in 0 ..< visible {
		ri := file_finder.scroll + r
		box, ok := icon_box("FinderRowIcon", 16, u32(ri))
		if !ok {
			continue
		}
		sel := ri == file_finder.sel
		col := sel ? BACKGROUND : TEXT
		entry := file_finder.entries[file_finder.filtered[ri]]
		// Reuse the media-bin thumbnail when this exact path was imported.
		thumb: ^sdl.GPUTexture
		for &a in media_bin.assets {
			if a.has_thumb && a.thumb_tex != nil && strings.compare(string(a.path), entry.fullpath) == 0 {
				thumb = a.thumb_tex
				break
			}
		}
		if thumb != nil {
			draw_tex_quad(renderer, command_buffer, pass, box, thumb, {0, 0, 1, 1})
		} else {
			render_icon(renderer, command_buffer, pass, box, finder_icon_for(entry.kind), col)
		}
	}
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
		editor_flags.snap_clips_to_playhead,
		16,
	)
	draw_icon_in_element(
		renderer,
		command_buffer,
		pass,
		"SnapPhToClip",
		.SnapPlayheadToClip,
		editor_flags.snap_playhead_to_clips,
		16,
	)
	draw_icon_in_element(
		renderer,
		command_buffer,
		pass,
		"AutoKf",
		.AutoKeyframe,
		editor_flags.auto_keyframe,
		16,
	)
	draw_icon_in_element(
		renderer,
		command_buffer,
		pass,
		"PlayBack",
		.SkipBack,
		playhead.playing && playback.dir == -1,
		15,
	)
	draw_icon_in_element(
		renderer,
		command_buffer,
		pass,
		"PlayFwd",
		.SkipForward,
		playhead.playing && playback.dir == 1,
		15,
	)
	// The Duplicate/Remove track icons moved to the track context menu, so the
	// per-track gutter icon pass (and the scissor that clipped it) is gone.
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
//
// When the audio clock lags the playhead by more than AUDIO_DESYNC_ALERT_SEC,
// one console line is dumped (at most once per second) with the producer-side
// state that distinguishes why: prod (where mixing is), q (content queued in
// the stream) vs d (what the device has played), rsync + prov (a provision/
// reopen just happened — the audio clock is parked on a stale anchor for the
// whole reopen), holes + ncov (the producer cannot keep up or finds no covered
// source — the forward-skip should have fired but may be gated), boost (the
// jog boost that only the video side honors).
//
// age is the one field that separates "behind" from "stopped": how long ago the
// producer last published its position at all. It reads ~0.002s while the
// engine feeds, and climbs into the minutes when the producer thread is stuck
// (inside a provision, or starved of feed passes) — in which case every other
// field on the line is a frozen value extrapolated forward by this HUD and
// reads as healthy. Without it, a wedged producer is indistinguishable from a
// merely-behind one, which is what made the 2026-09 scrub-storm wedge
// (prov=1 for hours, every counter static) an hours-long investigation.
AUDIO_DESYNC_ALERT_SEC :: 0.4

// Audio_Skew_Diag is the audio-desync alert's rate limiter: the last tick the
// alert fired (at most once per second) and the previous report's counters, so
// the alert can show how each counter moved since the last line.
Audio_Skew_Diag :: struct {
	tick:       u64,
	prev_rsync: i64,
	prev_holes: i64,
	prev_ncov:  u64,
	prev_full:  u64,
	prev_wedge: u64,
	prev_rebuilt: u64,
}
audio_skew_diag: Audio_Skew_Diag

draw_preview_hud :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	preview: clay.BoundingBox,
) {
	if !sync.atomic_load(&audio_prod.run) {
		return
	}
	fps := timeline_fps()
	if fps <= 0 {
		return
	}
	// Sample both clocks at this instant, not at their last publish: dev is
	// stepped by producer feed passes and playhead.frame steps once per UI
	// frame, so comparing them raw bounces a full frame (~16ms at 60fps) of
	// phantom skew that is never audible. Extrapolate both off the same wall
	// clock (the way the producer pins its queue target) — the residual is the
	// true device-vs-playhead offset, a few ms at most.
	// The skew meter is now a READOUT of a relationship that cannot drift, not a
	// watchdog on one that can. dev_frame is the device's exact consumed position
	// (fed minus queued, two integers in bus samples) and playhead.frame is derived
	// from it, so this delta is bounded by one producer publish and carries no
	// information about drift -- it is here to show that, and to catch the one case
	// that would break it: a stale publish while the producer is stalled.
	//
	// The extrapolation that used to live here is gone. Extrapolating dev_frame off
	// the wall clock was how a device position was turned back into a wall-clock
	// guess, which is the thing this whole change removes.
	now := monotonic_ns()
	dev_at := sync.atomic_load(&playback.dev_at_ns)
	dev := sync.atomic_load(&playback.dev_frame)
	rate_sc := max(1.0, playback.rate)
	ph := playhead.frame
	label_buf: [64]u8
	label := fmt.bprintf(
		label_buf[:],
		"A %6.2f  V %6.2f  d %+.2f",
		f64(dev) / fps,
		f64(ph) / fps,
		f64(dev - ph) / fps,
	)
	// Audio LAGS the playhead means dev < ph, so the alert fires on a NEGATIVE
	// delta past the threshold. The comparison used to be `dev - ph < +SEC*fps`
	// (the negation was missing), which is true for essentially all playback and
	// dumped the line every second during a perfectly healthy mix -- burying the
	// one case it exists to report.
	// The desync alarm. Rate-limited rather than flag-gated, which is exactly the
	// shape a trace-flag sweep cannot see: it prints on a CONDITION, not behind a
	// flag. Gated for the same reason as the traces -- it is a stdout diagnostic,
	// and a shipped GUI has no console to print it to.
	when ODIN_DEBUG {
		if dev - ph < -i64(AUDIO_DESYNC_ALERT_SEC * fps) && now - audio_skew_diag.tick >= u64(1_000_000_000) {
			rsync := sync.atomic_load(&audio_prod.resync)
			prod := sync.atomic_load(&audio_prod.prod_frame)
			holes := sync.atomic_load(&audio_rpt.silence_holes)
			anchor := sync.atomic_load(&audio_prod.anchor_frame)
			// dev_at is sampled after now, so a producer publish landing between the
			// two reads makes it the NEWER stamp; saturate rather than underflow the
			// unsigned delta into a nonsense age.
			age_s := f64(-1.0)
			if dev_at > 0 {
				age_s = u64(dev_at) > now ? 0.0 : f64(now-u64(dev_at))/1e9
			}
			fmt.printf(
				"[skew] d=%+.2fs prod=%+.2fs q=%+.2fs an=%+.2fs rsync=%d(+%d) prov=%d age=%.1fs holes=%d(+%d) ncov=%d(+%d) full=%d(+%d) wedge=%d(+%d) rebuilt=%d(+%d) rate=%.2f boost=%d\n",
				f64(dev-ph)/fps,
				f64(prod)/fps,
				f64(prod-dev)/fps,
				f64(anchor)/fps,
				rsync, rsync-audio_skew_diag.prev_rsync,
				sync.atomic_load(&audio_prod.provisioning) ? 1 : 0,
				age_s,
				holes, holes-audio_skew_diag.prev_holes,
				audio_rpt.skip_nocov, audio_rpt.skip_nocov-audio_skew_diag.prev_ncov,
				audio_rpt.skip_full, audio_rpt.skip_full-audio_skew_diag.prev_full,
				audio_rpt.starve_ticks, audio_rpt.starve_ticks-audio_skew_diag.prev_wedge,
				audio_rpt.rate_rebuilt, audio_rpt.rate_rebuilt-audio_skew_diag.prev_rebuilt,
				playback.rate, playback.boost,
			)
			audio_skew_diag.tick = now
			audio_skew_diag.prev_rsync = rsync
			audio_skew_diag.prev_holes = holes
			audio_skew_diag.prev_ncov = audio_rpt.skip_nocov
			audio_skew_diag.prev_full = audio_rpt.skip_full
			audio_skew_diag.prev_wedge = audio_rpt.starve_ticks
			audio_skew_diag.prev_rebuilt = audio_rpt.rate_rebuilt
		}
	}
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

// import_ui.cancel_box is the corner badge's Cancel button hit-box, set by
// draw_import_progress each frame while the badge is visible (interaction.odin
// uses it for manual click dispatch).

// draw_ui_notice paints the transient on-window notice (ui_notice.text) as a
// small dimmed panel centered on the window, shown until its deadline passes.
// main.odin calls clear_expired_ui_notice each frame so the string is freed the
// moment the notice expires.
draw_ui_notice :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	win_w, win_h: f32,
) {
	if len(ui_notice.text) == 0 || monotonic_ms() >= ui_notice.until {
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

	msg := string(ui_notice.text)
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

// draw_import_progress paints the corner status badge for an on-demand proxy
// build: a compact top-right panel with the source name, phase label, progress
// bar (indeterminate while ffmpeg estimates), percent, and a Cancel button.
// Deliberately NON-MODAL -- it never blocks editing or playback; the scheduler
// keeps the needed window building in the background while the playhead sits on
// it. Drawn last so it sits above every clay/gpu layer.
draw_import_progress :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	win_w, win_h: f32,
) {
	active, frac, phase, src := import_bg_status()
	if !active {
		import_ui.cancel_box = {}
		return
	}

	W: f32 = 300
	H: f32 = 118
	pad: f32 = 16
	panel := clay.BoundingBox {
		x      = win_w - W - pad,
		y      = pad,
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
			x = panel.x + 14,
			y = panel.y + 12,
			width = panel.width - 28,
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
	name_len := min(len(name), 34)
	render_text(
		renderer,
		command_buffer,
		pass,
		clay.BoundingBox {
			x = panel.x + 14,
			y = panel.y + 34,
			width = panel.width - 28,
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
		x      = panel.x + 14,
		y      = panel.y + 56,
		width  = panel.width - 28,
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
				x = panel.x + 14,
				y = panel.y + 74,
				width = panel.width - 28,
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

	cancel_row_y := panel.y + 76
	if frac < 0 || phase != .Building {
		cancel_row_y = panel.y + 84
	}
	cancel := clay.BoundingBox {
		x      = panel.x + panel.width - 86,
		y      = cancel_row_y,
		width  = 72,
		height = 24,
	}
	render_sdf_rect(renderer, command_buffer, pass, cancel, BUTTON, 6, 0)
	render_sdf_rect(renderer, command_buffer, pass, cancel, BUTTON_BORDER, 6, 1)
	import_ui.cancel_box = cancel
	cancel_label := "Cancel"
	render_text(
		renderer,
		command_buffer,
		pass,
		clay.BoundingBox {
			x = cancel.x + 6,
			y = cancel.y + 5,
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

// gpu_upload_tb returns a transfer buffer of at least `size` bytes, reusing
// *tb when it already fits and growing it otherwise. The caller maps it with
// cycle=true so a still-in-flight upload of the previous frame is preserved
// (SDL cycles the internal resource); creating/releasing one per upload was a
// driver allocation on every dirty preview slot, every frame.
// live_tex is the preview sink's texture for the composed export frame (see
// render_live in render.odin). Sink-owned runtime resource, created lazily at
// the job's canvas size and released at shutdown -- it holds PIXELS, not a fact
// about the document, which is exactly the split Active 11 asks for: the
// evaluation is shared, the resources are per-sink.
live_tex: ^sdl.GPUTexture
live_tex_w, live_tex_h: c.int
live_tex_failed: bool

// ensure_live_texture returns the live texture at w x h, (re)creating it when the
// job canvas size changed. `failed` latches so a device that refuses one
// creation is not asked again every frame (SDL would keep failing, and the retry
// per frame is a per-frame driver call on the UI thread).
ensure_live_texture :: proc(device: ^sdl.GPUDevice, w, h: c.int) -> ^sdl.GPUTexture {
	if live_tex_failed {
		return nil
	}
	if w <= 0 || h <= 0 {
		return nil
	}
	if live_tex != nil && live_tex_w == w && live_tex_h == h {
		return live_tex
	}
	if live_tex != nil {
		sdl.ReleaseGPUTexture(device, live_tex)
		live_tex = nil
	}
	live_tex =
		sdl.CreateGPUTexture(
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
	if live_tex == nil {
		live_tex_failed = true
		fmt.println("live preview texture creation failed:", sdl.GetError())
		return nil
	}
	live_tex_w, live_tex_h = w, h
	return live_tex
}

// release_live_preview_texture frees the live texture at shutdown.
release_live_preview_texture :: proc(device: ^sdl.GPUDevice) {
	if live_tex != nil {
		sdl.ReleaseGPUTexture(device, live_tex)
		live_tex = nil
	}
	live_tex_w, live_tex_h = 0, 0
}

// draw_live_preview draws the export's current composed frame over the canvas
// and reports whether it drew (in which case the clip stack must be skipped:
// the composed frame already contains every clip, so drawing them again would
// double-composite the whole timeline on top of the finished output).
//
// Runs BEFORE any render pass is open, like the slot uploads: the transfer has
// to be recorded into the command buffer first.
draw_live_preview :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	// render_live.w/h is this thread's own write from render_live_begin and is
	// immutable for the run, so sizing the transfer off it before the claim is
	// safe -- and it has to be, because the canvas size only becomes known from
	// the drained frame itself.
	if render_live.buf == nil || render_live.w <= 0 || render_live.h <= 0 {
		return false
	}
	n := int(render_live.w) * int(render_live.h) * 4
	transfer :=
		gpu_upload_tb(renderer.device, &renderer.preview_upload_tb, &renderer.preview_upload_capacity, n)
	if transfer == nil {
		return false
	}
	mapped := sdl.MapGPUTransferBuffer(renderer.device, transfer, true)
	if mapped == nil {
		return false
	}
	// Straight from the mailbox into the transfer buffer: no second full-canvas
	// copy of the frame, and the claim is released as this copy finishes.
	_, w, h, ok := render_live_drain(([^]u8)(mapped)[:n])
	sdl.UnmapGPUTransferBuffer(renderer.device, transfer)
	if !ok {
		return false
	}
	tex := ensure_live_texture(renderer.device, w, h)
	if tex == nil {
		return false
	}
	copy_pass := sdl.BeginGPUCopyPass(command_buffer)
	sdl.UploadToGPUTexture(
		copy_pass,
		sdl.GPUTextureTransferInfo {
			transfer_buffer = transfer,
			pixels_per_row  = u32(w),
			rows_per_layer  = u32(h),
		},
		sdl.GPUTextureRegion{texture = tex, w = u32(w), h = u32(h), d = 1},
		false,
	)
	sdl.EndGPUCopyPass(copy_pass)
	// The mailbox has been drained and uploaded, so the composite may refill it
	// from here on. One frame consumed is enough for the composite to start
	// publishing (render_live_publish's usability gate), and it stops the
	// preview sitting on the render's opening frame with no visible progress.
	sync.atomic_store(&render_live.shown, true)
	return true
}

gpu_upload_tb :: proc(
	device: ^sdl.GPUDevice,
	tb: ^^sdl.GPUTransferBuffer,
	capacity: ^int,
	size: int,
) -> ^sdl.GPUTransferBuffer {
	if tb^ != nil && capacity^ >= size {
		return tb^
	}
	if tb^ != nil {
		sdl.ReleaseGPUTransferBuffer(device, tb^)
		tb^ = nil
	}
	tb^ = sdl.CreateGPUTransferBuffer(
		device,
		sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = u32(size)},
	)
	if tb^ == nil {
		capacity^ = 0
		return nil
	}
	capacity^ = size
	return tb^
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
	transfer := gpu_upload_tb(
		renderer.device,
		&renderer.preview_upload_tb,
		&renderer.preview_upload_capacity,
		PREVIEW_W * PREVIEW_H * 4,
	)
	if transfer == nil {
		return
	}
	mapped := sdl.MapGPUTransferBuffer(renderer.device, transfer, true)
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
	transfer := gpu_upload_tb(
		renderer.device,
		&renderer.text_upload_tb,
		&renderer.text_upload_capacity,
		n,
	)
	if transfer == nil {
		return
	}
	mapped := sdl.MapGPUTransferBuffer(renderer.device, transfer, true)
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
// owned texture in text_texture_releases; the render loop drains the queue
// each frame with the device in hand, so a texture never leaks across a slot
// reassignment.
// ---------------------------------------------------------------------------
text_texture_releases: [dynamic]^sdl.GPUTexture

queue_text_texture_release :: proc(tex: ^sdl.GPUTexture) {
	if tex != nil {
		append(&text_texture_releases, tex)
	}
}

drain_pending_text_releases :: proc(device: ^sdl.GPUDevice) {
	for t in text_texture_releases {
		sdl.ReleaseGPUTexture(device, t)
	}
	clear(&text_texture_releases)
}


// draw_preview draws the active video clip's frame in the given bounds, placed
// according to the clip's transform (fills the project canvas, centered at its
// x/y), then overlays a selection border around the currently-selected clip's
// image rect. The decode buffer is fixed PREVIEW_W x PREVIEW_H; the source is
// fit (aspect-preserving, letterboxed) into it and the quad samples only the
// fit region so the image is never stretched to the (possibly differently
// shaped) project canvas.
// draw_image_layer draws one textured quad (the unit quad transformed by
// `uniforms`) with the shared preview pipeline. `uniforms.viewport` is the
// target's pixel size, passed explicitly rather than read from renderer.viewport
// so the export compositor can render into an offscreen target of a different
// size than the window without racing the main thread. This is the seam the
// preview and export compositors share: identical transform/UV/blend plumbing.
draw_image_layer :: proc(
	renderer: ^GPU_Renderer,
	pass: ^sdl.GPURenderPass,
	command_buffer: ^sdl.GPUCommandBuffer,
	texture: ^sdl.GPUTexture,
	sampler: ^sdl.GPUSampler,
	uniforms: Quad_Uniforms,
	opacity: f32,
) {
	sdl.BindGPUGraphicsPipeline(pass, renderer.preview_pipeline)
	binding := sdl.GPUTextureSamplerBinding{texture = texture, sampler = sampler}
	sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
	// PushGPUVertexUniformData takes a rawptr; a parameter has no address, so
	// copy to a local first.
	u := uniforms
	sdl.PushGPUVertexUniformData(command_buffer, 0, &u, sdl.Uint32(size_of(u)))
	// Fragment stage: the per-layer alpha, separate from the vertex transform
	// block above. blit_box.frag scales the sampled alpha by it.
	fo := Blit_Opacity_Uniforms{opacity = opacity}
	sdl.PushGPUFragmentUniformData(command_buffer, 0, &fo, sdl.Uint32(size_of(fo)))
	sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
}

// preview_draw_key is the depth a preview slot sorts by when compositing. The
// rule itself -- what the numbers MEAN, that subtitles pin above everything --
// lives in render_order.odin, because the export has to obey the same rule and
// two statements of one rule is how this pair drifted before. This is the
// preview's adapter onto a Preview_Slot; it exists only to read the two
// inputs the shared rule takes.
preview_draw_key :: proc(slot: ^Preview_Slot) -> int {
	return draw_key(int(slot.layer), slot.is_subtitle)
}

// preview_build_draw_order collects every visible slot and returns their indices
// sorted by preview_draw_key ASCENDING. The caller walks the result BACKWARDS, so
// the last slot painted is order[0] -- the lowest key, i.e. the topmost clip.
//
// Split out of draw_preview so the ordering rule is testable without a GPU pass
// or a live decoder: it is pure data over preview_slots, which is the whole
// point of the rule, and asserting it here is what keeps "pinned subtitles"
// from quietly becoming "subtitles wherever the track walk happened to put them".
preview_build_draw_order :: proc() -> (order: [MAX_PREVIEW_SLOTS]int, n: int) {
	n = 0
	for i := 0; i < MAX_PREVIEW_SLOTS; i += 1 {
		if s := &preview_slots[i]; s.in_use && s.has_frame && s.texture != nil {
			order[n] = i
			n += 1
		}
	}
	// Insertion sort: MAX_PREVIEW_SLOTS is a small fixed bound and the visible
	// set is far smaller, so this beats anything with a setup cost.
	for a := 1; a < n; a += 1 {
		key := order[a]
		b := a
		// Ascending by the shared key, so order[0] is the topmost item and the
		// caller's backwards walk paints it last.
		for b > 0 &&
		   preview_draw_key(&preview_slots[order[b - 1]]) > preview_draw_key(&preview_slots[key]) {
			order[b] = order[b - 1]
			b -= 1
		}
		order[b] = key
	}
	return
}

// draw_preview paints the preview canvas: the export's live composed frame when
// one is being shown (S5), otherwise the clip stack under the playhead.
//
// show_live means the live export frame covers the whole canvas, so the clip
// stack is skipped rather than drawn under it -- the composed frame already
// holds every clip, video, text and subtitle, and painting the slots over it
// would double-composite the timeline on top of the finished output.
draw_preview :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
	bounds: clay.BoundingBox,
	show_live: bool = false,
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
		// Clamped like every other layout-derived rect: the intersection is
		// non-empty, which is not the same as being inside the render target.
		sdl.SetGPUScissor(
			pass,
			scissor_clamp(
				renderer,
				sdl.Rect{c.int(ix), c.int(iy), c.int(ix2 - ix), c.int(iy2 - iy)},
			),
		)
	}

	// The composed export frame fills the canvas rect exactly: it IS the
	// project at output resolution, and `view` is the project's letterboxed
	// pixel rect, so this is a 1:1 blit with no letterbox math of its own.
	if show_live && live_tex != nil {
		draw_image_layer(
			renderer,
			pass,
			command_buffer,
			live_tex,
			renderer.preview_sampler,
			Quad_Uniforms {
				bounds   = {view.x, view.y, view.width, view.height},
				viewport = renderer.viewport,
				_padding = {},
				uv       = {0, 0, 1, 1},
			},
			1.0,
		)
		return
	}

	// Paint every clip covering the playhead with the top track on top. Slots
	// keep a STABLE index per clip identity (update_preview_slots), so index
	// order no longer means depth: sort the visible slots by draw key and draw the
	// LOWEST key last, so the topmost clip is painted last and appears on top.
	// The key is the track-order walk position (lowest = topmost), except that
	// subtitle slots are pinned above everything -- see preview_draw_key.
	order, n := preview_build_draw_order()
	for k := n - 1; k >= 0; k -= 1 {
		slot := &preview_slots[order[k]]
		is_text := slot.text_w > 0 && slot.text_h > 0
		cb := clip_image_bounds_geom(
			canvas,
			is_text ? Media_Kind.Text : Media_Kind.Video,
			slot.geom,
			slot.source_w,
			slot.source_h,
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
			// The CONTENT window — crop, zoom and pan — because these UVs select
			// which source pixels are drawn. This is the correct side for zoom and
			// pan: a pan slides the sampled region without moving the quad.
			ins_l, ins_r, ins_t, ins_b := geom_content_insets(slot.geom)
			u0 = u_base + ins_l * u_span
			u1 = u_base + (1 - ins_r) * u_span
			v0 = v_base + ins_t * v_span
			v1 = v_base + (1 - ins_b) * v_span
		}
		vertex_uniforms := Quad_Uniforms {
			bounds   = {cb.x, cb.y, cb.width, cb.height},
			viewport = renderer.viewport,
			_padding = {},
			uv       = {u0, v0, u1, v1},
		}
		draw_image_layer(
			renderer,
			pass,
			command_buffer,
			slot.texture,
			renderer.preview_sampler,
			vertex_uniforms,
			slot.geom[int(Render_Geom_Prop.Opacity)],
		)
	}
	// Draw a border box around the currently-selected clip's image rect.
	// Border/handles are editor affordances: restore the widget-level scissor so
	// handles on an off-canvas box stay visible/grabbable.
	sdl.SetGPUScissor(
		pass,
		scissor_clamp(
			renderer,
			sdl.Rect{c.int(bounds.x), c.int(bounds.y), c.int(bounds.width), c.int(bounds.height)},
		),
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
