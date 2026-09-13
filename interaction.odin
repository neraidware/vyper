package main

import clay "clay-odin"
import "core:c"
import "core:fmt"
import "core:sync"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Mouse interaction state machine. Owns everything the pointer can do: reading
// the raw SDL button/modifier state, the pre-layout gestures that work on last
// frame's geometry (preview/timeline pan, the inspector scrollbar), and the
// post-layout click chain + live drag updates (which hit-test THIS frame's clay
// geometry). Runs between the event poll and the playback tick.
// ---------------------------------------------------------------------------

// Mouse_Input is the raw pointer state for one frame, read once so the whole
// frame shares a single snapshot instead of re-polling SDL.
Mouse_Input :: struct {
	x, y:                f32,
	left, right, middle: bool,
	alt, shift:          bool,
}

// read_mouse_input snapshots the mouse buttons + modifiers for this frame.
read_mouse_input :: proc() -> Mouse_Input {
	mx, my: f32
	buttons := sdl.GetMouseState(&mx, &my)
	mods := sdl.GetModState()
	return Mouse_Input {
		x = mx,
		y = my,
		left = sdl.MouseButtonFlag.LEFT in buttons,
		right = sdl.MouseButtonFlag.RIGHT in buttons,
		middle = sdl.MouseButtonFlag.MIDDLE in buttons,
		alt = sdl.KeymodFlag.LALT in mods || sdl.KeymodFlag.RALT in mods,
		shift = sdl.KeymodFlag.LSHIFT in mods || sdl.KeymodFlag.RSHIFT in mods,
	}
}

// interaction_pre_build runs before the clay layout so the pans + scrollbar
// drag work on last frame's geometry. Also feeds clay the pointer state, which
// must happen before build_page so PointerOver reflects this frame's layout.
interaction_pre_build :: proc(inp: Mouse_Input) {
	// Middle-button drag over the preview pans the camera (limited to ±one
	// preview axis from the origin via clamp_preview_camera at render time).
	if inp.middle && clay.PointerOver(clay.ID("Preview")) {
		if panning_preview {
			preview_cam_ox += inp.x - pan_last_x
			preview_cam_oy += inp.y - pan_last_y
		}
		panning_preview = true
		pan_last_x = inp.x
		pan_last_y = inp.y
	} else if panning_preview {
		panning_preview = false
	}
	// Middle-drag over the timeline pans it: horizontally along the frames,
	// vertically across the track rows (when they overflow the view). The
	// hit test is a raw box check on the panel's bounding box rather than
	// clay's PointerOver so panning never depends on the pointer-over flag
	// machinery.
	tltl := clay.GetElementData(clay.ID("ClipTimeline")).boundingBox
	if inp.middle &&
	   len(timeline.tracks) > 0 &&
	   tltl.width > 0 &&
	   inp.x >= tltl.x &&
	   inp.x <= tltl.x + tltl.width &&
	   inp.y >= tltl.y &&
	   inp.y <= tltl.y + tltl.height {
		if panning_timeline {
			timeline_view_start -= (inp.x - timeline_pan_last_x) / timeline_zoom
			timeline_view_start = clamp(timeline_view_start, 0, f32(timeline_duration()))
			// Inverted vertical drag (grab-the-content convention): dragging
			// down moves content down ("scroll down" pushes tracks up, the
			// "hand tool" feel), so the view offset moves opposite the pointer.
			timeline_view_top -= inp.y - timeline_pan_last_y
			// Clamp to the row area that overflows the visible tracks box.
			timeline_view_top = clamp(timeline_view_top, 0, timeline_tracks_max_top())
		}
		panning_timeline = true
		timeline_pan_last_x = inp.x
		timeline_pan_last_y = inp.y
	} else if panning_timeline {
		panning_timeline = false
	}
	// Vertical scrollbar drags: the thumb position maps directly onto the
	// container's scroll value, using the same geometry that draws the
	// thumb. Active for the inspector cards column; ends the moment the
	// button lifts. (The timeline scrolls by wheel/pan and needs no bar.)
	scroll_drag_update(
		"InspectorV",
		inp.left,
		inp.y,
		&inspector_scroll_dragging,
		&inspector_scroll_grab,
		&inspector_scroll,
		inspector_content_height(),
		inspector_view_height(),
	)
	clay.SetPointerState({inp.x, inp.y}, inp.left)
}

// clamp_view_scrolls pins the timeline track-list and inspector scroll values
// to their derived ranges after the layout (which their maxes depend on).
clamp_view_scrolls :: proc() {
	if len(timeline.tracks) > 0 {
		timeline_view_top = clamp(timeline_view_top, 0, timeline_tracks_max_top())
	}
	inspector_scroll = clamp(inspector_scroll, 0, inspector_max_scroll())
}

// ---------------------------------------------------------------------------
// Fresh-click dispatch. The old ~300-line else-if hit-test chain became two
// priority-ordered tables: click_cases (element-id + geometric probes, in the
// exact priority the chain had) and, when none match, click_fallbacks (the
// geometry/loop probes the chain's trailing else block handled). First match
// wins; array order IS the priority, so no `handled` flag threading.
// ---------------------------------------------------------------------------
Click_Case :: struct {
	id:     cstring,                          // clay element id to PointerOver-test ("" = custom probe)
	hit:    proc(inp: Mouse_Input) -> bool,   // custom geometric probe (used when id == "")
	action: proc(inp: Mouse_Input),           // runs on first match
}

click_cases := []Click_Case{
	// Import-background cancel is top priority: aborting an active import
	// swallows any click over its overlay box.
	{ hit = proc(inp: Mouse_Input) -> bool {
		return import_bg_active() && box_contains(import_cancel_box, inp.x, inp.y)
	}, action = proc(_: Mouse_Input) { import_bg_cancel() } },
	{ id = "BinImportButton", action = proc(_: Mouse_Input) {
		if path := open_file_picker(); path != nil {
			if is_srt_pick(path) {
				import_srt_to_bin(path)
			} else {
				import_media_to_bin(path)
			}
		}
	} },
	// Pressing a bin cell selects the media and starts the drag-to-timeline
	// gesture (ghost while down, committed on release over a lane).
	{ hit = proc(inp: Mouse_Input) -> bool {
		return len(media_assets) > 0 && media_bin_item_at(inp.x, inp.y) >= 0
	}, action = proc(inp: Mouse_Input) {
		begin_media_drag(media_bin_item_at(inp.x, inp.y), inp.x, inp.y)
	} },
	{ id = "OpenFileButton", action = proc(_: Mouse_Input) {
		if path := open_file_picker(); path != nil {
			if is_srt_pick(path) {
				// Subtitle pick: into the bin as an asset, placed on the
				// timeline only when the user drags it to a track (can't
				// probe a text file as media).
				import_srt_to_bin(path)
			} else {
				// Classic Open File flow: probe the file and drop it straight
				// onto the timeline (appended at the end), keeping its bin
				// entry.
				if asset_id := import_media_to_bin(path); asset_id != 0 {
					add_asset_to_timeline(asset_id, 0, timeline_duration())
				}
			}
		}
	} },
	{ id = "Res720", action = proc(_: Mouse_Input) { set_project_resolution_preset(1280, 720) } },
	{ id = "Res1080", action = proc(_: Mouse_Input) { set_project_resolution_preset(1920, 1080) } },
	{ id = "Res4K", action = proc(_: Mouse_Input) { set_project_resolution_preset(3840, 2160) } },
	{ id = "ResAuto", action = proc(_: Mouse_Input) { set_project_resolution_auto() } },
	{ id = "OrientVertical", action = proc(_: Mouse_Input) { set_project_orientation(!(project.height > project.width)) } },
	{ id = "SnapCenter", action = proc(_: Mouse_Input) { snap_center_to_canvas = !snap_center_to_canvas } },
	{ id = "Fps24", action = proc(_: Mouse_Input) { set_project_fps(24) } },
	{ id = "Fps25", action = proc(_: Mouse_Input) { set_project_fps(25) } },
	{ id = "Fps30", action = proc(_: Mouse_Input) { set_project_fps(30) } },
	{ id = "Fps48", action = proc(_: Mouse_Input) { set_project_fps(48) } },
	{ id = "Fps60", action = proc(_: Mouse_Input) { set_project_fps(60) } },
	{ id = "FpsAuto", action = proc(_: Mouse_Input) { set_project_fps(0) } },
	{ id = "PropRename", action = proc(_: Mouse_Input) { begin_clip_rename() } },
	{ id = "TimelineZoomIn", action = proc(_: Mouse_Input) { timeline_zoom_about_playhead(1.5) } },
	{ id = "TimelineZoomOut", action = proc(_: Mouse_Input) { timeline_zoom_about_playhead(1 / 1.5) } },
	{ id = "TimelineZoomFit", action = proc(_: Mouse_Input) { timeline_zoom_fit() } },
	{ id = "RenderPickButton", action = proc(_: Mouse_Input) { render_pick_output_path() } },
	{ id = "RenderRunButton", action = proc(_: Mouse_Input) { render_start() } },
	{ id = "RenderCancelButton", action = proc(_: Mouse_Input) { render_cancel() } },
	// Clicking the timeline ruler starts a scrub (drag to seek).
	{ hit = proc(inp: Mouse_Input) -> bool {
		return len(timeline.tracks) > 0 && clay.PointerOver(clay.ID("Ruler"))
	}, action = proc(_: Mouse_Input) { active_interaction = .Playhead_Scrub } },
}

// Apply a resolution preset without losing the current canvas orientation.
// Presets are stored as landscape dimensions; portrait mode swaps the pair so
// choosing another preset preserves the user's portrait setting.
set_project_resolution_preset :: proc(w, h: c.int) {
	portrait := project.height > project.width
	if portrait {
		set_project_resolution(h, w)
	} else {
		set_project_resolution(w, h)
	}
}

dispatch_click_table :: proc(inp: Mouse_Input) -> bool {
	for c in click_cases {
		hit := c.id != "" ? clay.PointerOver(clay.ID(string(c.id))) : c.hit(inp)
		if hit {
			c.action(inp)
			return true
		}
	}
	return false
}

// dispatch_click_fallback runs the geometry/loop probes: scrollbar, property
// field focus, preview handle grab, preview clip move, snap toggles, track
// add/duplicate/remove, clip resize edge, clip drag. An in-flight property edit
// is committed first, exactly like the old trailing else block, then each probe
// runs in order until one claims the click.
dispatch_click_fallback :: proc(inp: Mouse_Input) -> bool {
	if editing_field != .None && !edit_field_over() {
		edit_commit()
	}
	for fb in click_fallbacks {
		if fb(inp) {
			return true
		}
	}
	return false
}

// click_fallbacks: the chain's trailing else block, as order-kept probes. Each
// returns true when it consumed the click.
click_fallbacks := []proc(inp: Mouse_Input) -> bool{
	// Scrollbar: pressing the thumb starts a drag; pressing anywhere else on
	// the strip jumps the thumb to the cursor. One stack per scrollable column
	// (inspector cards only — the timeline scrolls by wheel/pan).
	proc(inp: Mouse_Input) -> bool {
		if scroll_press(
			"InspectorV",
			inp.y,
			&inspector_scroll_dragging,
			&inspector_scroll_grab,
		) {
			return true
		}
		return false
	},
	// Clicking an X/Y/Scale/crop property field focuses it for typing.
	proc(inp: Mouse_Input) -> bool {
		sel, ok := transformable_selected()
		if !ok {
			return false
		}
		if clay.PointerOver(clay.ID("PropFieldX")) {
			edit_begin(.X, sel.transform_x)
			return true
		}
		if clay.PointerOver(clay.ID("PropFieldY")) {
			edit_begin(.Y, sel.transform_y)
			return true
		}
		if clay.PointerOver(clay.ID("PropFieldS")) {
			edit_begin(.Scale, sel.scale)
			return true
		}
		if clay.PointerOver(clay.ID("PropCropL")) {
			edit_begin(.Crop_L, sel.crop_l * 100)
			return true
		}
		if clay.PointerOver(clay.ID("PropCropR")) {
			edit_begin(.Crop_R, sel.crop_r * 100)
			return true
		}
		if clay.PointerOver(clay.ID("PropCropT")) {
			edit_begin(.Crop_T, sel.crop_t * 100)
			return true
		}
		if clay.PointerOver(clay.ID("PropCropB")) {
			edit_begin(.Crop_B, sel.crop_b * 100)
			return true
		}
		return false
	},
	// Grab one of the selected clip's resize/crop handles. Takes precedence
	// over moving the clip. Default drag scales; holding Alt crops.
	proc(inp: Mouse_Input) -> bool {
		if !clay.PointerOver(clay.ID("Preview")) {
			return false
		}
		sel, ok := transformable_selected()
		if !ok {
			return false
		}
		pb := clay.GetElementData(clay.ID("Preview")).boundingBox
		canvas := preview_canvas(pb)
		ib := clip_image_bounds(canvas, sel)
		if h := preview_handle_at(ib, inp.x, inp.y); h >= 0 {
			begin_handle_drag(sel, canvas, Handle(h), inp.x, inp.y, inp.alt && sel.kind != .Text)
			active_interaction = .Handle_Drag
			return true
		}
		return false
	},
	// Dragging the selected clip inside the preview moves its transform.
	proc(inp: Mouse_Input) -> bool {
		if !clay.PointerOver(clay.ID("Preview")) {
			return false
		}
		sel, ok := transformable_selected()
		if !ok {
			return false
		}
		pb := clay.GetElementData(clay.ID("Preview")).boundingBox
		canvas := preview_canvas(pb)
		ib := clip_image_bounds(canvas, sel)
		if inp.x >= ib.x &&
		   inp.x <= ib.x + ib.width &&
		   inp.y >= ib.y &&
		   inp.y <= ib.y + ib.height {
			// Offset between the click and the clip's center, in project coords.
			// Unclamped so a grab near an off-canvas clip still offsets correctly.
			pcx, pcy := pixel_to_project_unclamped(canvas, inp.x, inp.y)
			preview_drag_offset_x = pcx - sel.transform_x
			preview_drag_offset_y = pcy - sel.transform_y
			active_interaction = .Preview_Move
			return true
		}
		return false
	},
	// Snap toggles + playhead-time nav live in the timeline's bottom bar.
	proc(inp: Mouse_Input) -> bool {
		if clay.PointerOver(clay.ID("SnapClipToPh")) {
			snap_clips_to_playhead = !snap_clips_to_playhead
			return true
		}
		if clay.PointerOver(clay.ID("SnapPhToClip")) {
			snap_playhead_to_clips = !snap_playhead_to_clips
			return true
		}
		if clay.PointerOver(clay.ID("PlayheadTime")) {
			// Clicking the playhead time badge opens numeric navigation (the
			// typed value is parsed and the playhead sought on commit).
			begin_playhead_time_edit()
			return true
		}
		return false
	},
	// Adding a track is limited to the gutter-width button in the insert gap;
	// the rest of the strip is the point-marker lane.
	proc(inp: Mouse_Input) -> bool {
		for i := 0; i <= len(timeline.tracks); i += 1 {
			if clay.PointerOver(clay.ID("AddTrack", u32(i))) {
				insert_track(i)
				return true
			}
		}
		return false
	},
	proc(inp: Mouse_Input) -> bool {
		for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
			if clay.PointerOver(clay.ID("DuplicateTrack", u32(track_idx))) {
				duplicate_track(track_idx)
				return true
			}
		}
		return false
	},
	proc(inp: Mouse_Input) -> bool {
		for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
			if clay.PointerOver(clay.ID("RemoveTrack", u32(track_idx))) {
				remove_track(track_idx)
				return true
			}
		}
		return false
	},
	// Resizing the selected clip's duration: grab its left/right edge. Takes
	// precedence over selecting/dragging a clip, and only the currently
	// selected clip can be resized.
	proc(inp: Mouse_Input) -> bool {
		sel_tr, sel_cl, ok := selected_clip()
		if !ok {
			return false
		}
		for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
			track := &timeline.tracks[track_idx]
			for index := 0; index < len(track.clips); index += 1 {
				if &track.clips[index] != sel_cl {
					continue
				}
				if edge := timeline_resize_edge_at(track_idx, index, inp.x, inp.y); edge >= 0 {
					selected_track = track_idx
					selected_index = index
					active_interaction = .Clip_Resize
					resize_edge = edge
					capture_link_group(&track.clips[index], track_idx)
					return true
				}
			}
		}
		return false
	},
	// Find which (if any) clip the pointer is over and start dragging it.
	proc(inp: Mouse_Input) -> bool {
		for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
			track := &timeline.tracks[track_idx]
			for index := 0; index < len(track.clips); index += 1 {
				if clay.PointerOver(clay.ID("TimelineClip", u32(track_idx * 1000 + index))) {
					selected_track = track_idx
					selected_index = index
					if inp.shift {
						// Shift+click toggles the clip into/out of the
						// multi-selection (for U linking) without dragging.
						cid := track.clips[index].clip_id
						if cid in selected_set {
							delete_key(&selected_set, cid)
						} else {
							selected_set[cid] = true
						}
						return true
					}
					// Plain click = single selection: drop any earlier
					// Shift+clicked extras and grab the clip.
					clear(&selected_set)
					drag_group_delta = 0
					drag_clip = &track.clips[index]
					drag_source_track = track_idx
					drag_source_index = index
					drag_hover_track = track_idx
					active_interaction = .Clip_Move
					clip_drag_offset =
						inp.x -
						clay.GetElementData(clay.ID("TimelineClip", u32(track_idx * 1000 + index))).boundingBox.x
					capture_link_group(drag_clip, track_idx)
					return true
				}
			}
		}
		return false
	},
}

// interaction_post_build runs after build_page: the click/press chain and the
// live drag updates (both hit-test this frame's geometry), plus the jog buttons,
// the playback-rate dropdown, the help overlay, and right-click context menus.
// Returns the latched mouse state for the next frame.
interaction_post_build :: proc(
	inp: Mouse_Input,
	prev_mouse_down, prev_right_down: bool,
	height: c.int,
) -> (
	was_mouse_down, was_right_down: bool,
) {
	next_left := prev_mouse_down
	next_right := prev_right_down
	// Fresh-click chain: the element/probe table runs first, then the pane
	// divider (press-and-hold drag), then the geometry/loop fallback probes.
	// All of these either fire a one-shot action or START a gesture backed by
	// the active_interaction switch below — none of them update live state.
	if inp.left && !prev_mouse_down {
		if !dispatch_click_table(inp) {
			if clay.PointerOver(clay.ID("DividerHandle")) {
				active_interaction = .Panel_Resize
			} else {
				dispatch_click_fallback(inp)
			}
		}
	}
	if !inp.left {
		// Button lifted: run the per-gesture commit, then drop the payload.
		#partial switch active_interaction {
		case .Media_Bin_Drag:
			// Releasing a bin drag commits the media (creates tracks as
			// needed); releasing nowhere cancels it.
			end_media_drag(inp.x, inp.y)
		case .Clip_Move:
			// Commit a vertical drop if the ghost hovers another track;
			// horizontal drags already applied their new start live.
			if drag_hover_track != drag_source_track &&
			   drag_hover_track >= 0 &&
			   drag_source_track >= 0 {
				if len(drag_group_orig) > 1 {
					move_linked_group(drag_hover_track - drag_source_track)
				} else {
					move_clip_to_track(
						drag_source_track,
						drag_source_index,
						drag_hover_track,
						drag_ghost_start,
					)
				}
			}
		}
		active_interaction = .None
		dragging_handle = nil
		handle_kind = .None
		handle_corner_snapped = false
		drag_clip = nil
		drag_source_track = -1
		drag_source_index = -1
		drag_hover_track = -1
		drag_group_delta = 0
		clear(&drag_group_orig)
		resize_edge = -1
	} else {
		switch active_interaction {
		case .Media_Bin_Drag:
			// A bin drag in flight: recompute the hovered lane + ghost each frame.
			update_media_drag_lanes(inp.x, inp.y)
		case .Handle_Drag:
			if sel, ok := transformable_selected(); ok {
				pb := clay.GetElementData(clay.ID("Preview")).boundingBox
				canvas := preview_canvas(pb)
				update_handle_drag(sel, canvas, inp.x, inp.y, inp.shift)
			}
		case .Panel_Resize:
			upper_area_height = inp.y - 8
			// Keep a lower-bound that scales with the window so a short window
			// never lets the upper and lower areas collide (the old hardcoded
			// 460/180 bounds collapsed on windows shorter than ~640px).
			min_h := min(460.0, f32(height) * 0.35)
			max_h := max(min_h, f32(height) - 140)
			upper_area_height = clamp(upper_area_height, min_h, max_h)
		case .Preview_Move:
			if sel, ok := transformable_selected(); ok {
				pb := clay.GetElementData(clay.ID("Preview")).boundingBox
				// Freeze at the preview widget's edge once the cursor leaves it:
				// otherwise free-move in unclamped project coords, so a cropped
				// clip can slide fully off-canvas like an uncropped one.
				if inp.x >= pb.x &&
				   inp.x <= pb.x + pb.width &&
				   inp.y >= pb.y &&
				   inp.y <= pb.y + pb.height {
					canvas := preview_canvas(pb)
					pcx, pcy := pixel_to_project_unclamped(canvas, inp.x, inp.y)
					sel.transform_x = pcx - preview_drag_offset_x
					sel.transform_y = pcy - preview_drag_offset_y
					// 5px snap margin (in rendered preview pixels): to the canvas
					// center when near it, and/or to the canvas borders (edge
					// snap runs regardless, so a centered clip still snaps).
					snap_center(sel, snap_margin(canvas, SNAP_MARGIN_PX))
					snap_transform(sel, snap_margin(canvas, SNAP_MARGIN_PX))
				}
			}
		case .Clip_Resize:
			if selected_track >= 0 &&
			   selected_index >= 0 &&
			   selected_track < len(timeline.tracks) &&
			   selected_index < len(timeline.tracks[selected_track].clips) {
				track_start := clay.GetElementData(clay.ID("ClipsSection", 0)).boundingBox.x
				frame := max(f32(0), (inp.x - track_start) / timeline_zoom + timeline_view_start)
				// Clip→playhead toggle applies to edge drags too: the dragged edge
				// (head on resize_edge 0, tail on 1) latches onto the playhead
				// within the snap margin, like a clip move.
				if snap_clips_to_playhead {
					frame = f32(snap_to_playhead(i64(frame)))
				}
				if resize_edge == 0 {
					if len(drag_group_orig) > 0 {
						// Linked group: shift every member's head by the same delta.
						resize_group_left(&timeline.tracks[selected_track], selected_index, i64(frame))
					} else {
						resize_clip_left(&timeline.tracks[selected_track], selected_index, i64(frame))
					}
				} else if resize_edge == 1 {
					if len(drag_group_orig) > 0 {
						// Linked group: move every member's tail by the same delta.
						resize_group_right(
							&timeline.tracks[selected_track],
							selected_index,
							i64(frame),
						)
					} else {
						resize_clip_right(&timeline.tracks[selected_track], selected_index, i64(frame))
					}
				}
				audio_note_edit()
			}
		case .Clip_Move:
			if drag_clip != nil {
				clip_x := inp.x - clip_drag_offset
				track_start := clay.GetElementData(clay.ID("ClipsSection", 0)).boundingBox.x
				frame := (clip_x - track_start) / timeline_zoom + timeline_view_start
				frame = max(frame, 0)
				// Clip→playhead toggle: latch the drag target onto the playhead
				// once it comes within the pixel snap margin. Applied to the
				// whole linked group, since every member follows the anchor.
				// But an all-or-nothing group must never be glued onto a
				// playhead slot it cannot clear: latch only when every member can
				// follow, else keep following the cursor and let the feasibility
				// gate park the unit at the true blocker.
				if snap_clips_to_playhead {
					snapped := snap_to_playhead(i64(max(frame, 0)))
					if len(drag_group_orig) > 1 &&
					   snapped != i64(frame) &&
					   !group_delta_feasible(snapped - drag_group_orig[0].start) {
						snapped = i64(frame)
					}
					frame = f32(snapped)
				}
				// Determine which track lane the pointer hovers: that decides
				// whether this is a horizontal move (same track) or a vertical
				// drop staged on another track (ghost until release).
				hover := drag_source_track
				for ti := 0; ti < len(timeline.tracks); ti += 1 {
					lane := clay.GetElementData(clay.ID("ClipsSection", u32(ti))).boundingBox
					if lane.width > 0 && inp.y >= lane.y && inp.y <= lane.y + lane.height {
						hover = ti
						break
					}
				}
				if hover == drag_source_track {
					drag_hover_track = hover
					if len(drag_group_orig) > 1 {
						// Linked group: the whole unit shifts by deltas every
						// member can honor exactly -- the anchor never moves into
						// a slot a partner can't reach. It sticks at the last
						// feasible position when the mouse keeps dragging past a
						// blocked slot.
						delta := i64(max(frame, 0)) - drag_group_orig[0].start
						if group_delta_feasible(delta) {
							if drag_clip.timeline_start_frame != drag_group_orig[0].start + delta {
								if vyper_trace {
									fmt.printf(
										"[tl] drag group link=%d (%d clips) delta=%d\n",
										drag_clip.link_id,
										len(drag_group_orig),
										delta,
									)
								}
								drag_clip.timeline_start_frame = drag_group_orig[0].start + delta
							}
							apply_group_drag_to_members(delta)
						}
					} else {
						// Horizontal move: keep the live-follow behavior but clamp so
						// the clip can never overlap a neighbor on this track.
						new_start := clip_slide_in_track(
							&timeline.tracks[drag_source_track],
							drag_source_index,
							drag_clip.source_length_frames,
							i64(max(frame, 0)),
							drag_clip.timeline_start_frame,
						)
						if drag_clip.timeline_start_frame != new_start {
							if vyper_trace {
								fmt.printf(
									"[tl] drag clip src=%s len=%d start=%d -> %d\n",
									drag_clip.path,
									drag_clip.source_length_frames,
									drag_clip.timeline_start_frame,
									new_start,
								)
							}
							drag_clip.timeline_start_frame = new_start
						}
					}
				} else {
					// Vertical: clamp to nearest valid slot on the hovered track
					// and show it as a ghost (committed on release). Linked
					// groups slide the whole unit with the mouse's horizontal
					// offset (drag_group_delta) on every member's lane.
					drag_hover_track = hover
					drag_ghost_start = clip_place_in_track(
						&timeline.tracks[hover],
						-1,
						drag_clip.source_length_frames,
						i64(max(frame, 0)),
					)
					if len(drag_group_orig) > 1 {
						drag_group_delta = i64(max(frame, 0)) - drag_group_orig[0].start
					}
				}
				audio_note_edit()
			}
		case .Playhead_Scrub:
			// Scrub the playhead to the pointer's frame along the ruler bar.
			ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
			frame := i64((inp.x - ruler.x) / timeline_zoom + timeline_view_start)
			frame = max(frame, 0)
			// Clamp to the last REAL frame of the timeline. timeline_duration()
			// is the exclusive content end, so frame == timeline_duration() is a
			// sheet empty slot past every clip; letting the playhead sit there
			// rendered (and scrubbed) a void after the last clip. The playhead
			// must stop at the final content frame; dragging further right pins
			// it there.
			frame = clamp(frame, 0, max(0, timeline_duration() - 1))
			// Playhead→clip toggle: when a clip's start or end is within the
			// snap margin, pin the scrubbed playhead onto that exact edge.
			if snap_playhead_to_clips {
				frame = snap_playhead_to_clip_edge(frame)
			}
			if playhead.frame != frame {
				if vyper_trace {
					fmt.printf(
						"[pb] scrub ph=%d (was %d) playing=%v\n",
						frame,
						playhead.frame,
						playhead.playing,
					)
				}
			}
			playhead.frame = frame
			// A playhead jump must anchor audio to the new position immediately:
			// otherwise the producer keeps decoding from the pre-scrub position
			// and the sound lags the video until its far-forward guard trips.
			audio_seek(frame)
			sync.atomic_store(&audio_ph_src, 1)
			sync.atomic_store(&audio_ph_catch, 0)
			// The preview requests the exact new playhead frame on its next
			// update (there is no frontier to rewind), so it follows the scrub.
		case .None:
			if inp.left && !prev_mouse_down && clay.PointerOver(clay.ID("PlayPause")) {
				toggle_playback()
			}
		}
	}
	// Jog controls: backward/forward around play (and h/l keys), handled
	// independently of the chain above since they're distinct elements.
	if inp.left && !prev_mouse_down && clay.PointerOver(clay.ID("PlayBack")) {
		jog_playback(-1)
	} else if inp.left && !prev_mouse_down && clay.PointerOver(clay.ID("PlayFwd")) {
		jog_playback(1)
	}
	// Playback-rate dropdown: clicking the rate button toggles the menu;
	// clicking a menu option selects that rate and closes it. Any other new
	// click while open dismisses the menu without changing the rate.
	was_click := inp.left && !prev_mouse_down
	rate_clicked := was_click && clay.PointerOver(clay.ID("PlayRateButton"))
	if was_click {
		handle_playback_rate_click(rate_clicked)
	}
	// Help overlay: the "?" button toggles it; any other click outside the
	// panel dismisses it.
	if was_click {
		if clay.PointerOver(clay.ID("HelpButton")) {
			help_open = !help_open
		} else if help_open && !clay.PointerOver(clay.ID("HelpPanel")) {
			help_open = false
		}
	}
	// Right-click: a clip gets a clip menu; empty space gets the track menu.
	// Any fresh left-click or a new right-click that lands elsewhere closes
	// an open menu first.
	if inp.right && !prev_right_down {
		if ct, ci := clip_under_pointer(); ct >= 0 {
			open_clip_context_menu(inp.x, inp.y, ct, ci)
		} else if track := timeline_track_hit_test(inp.x, inp.y); track >= 0 {
			open_track_context_menu(inp.x, inp.y, track)
		} else {
			close_context_menu()
		}
	} else if was_click && ctx_menu.open {
		if pointer_over_context_menu(inp.x, inp.y) {
			handle_ctx_option(inp.x, inp.y)
		} else {
			close_context_menu()
		}
	}
	// Submenu flyout follows the cursor: show while hovering the "Add >" row,
	// the flyout, or the seam between them; hide only after the cursor has left
	// the whole popup for CTX_SUBMENU_GRACE frames. The hover tests are
	// geometry-based (against last frame's element rects), NOT clay.PointerOver:
	// clay's hover is resolved during the layout pass, so polling it here (before
	// this frame's layout) lags one frame and, the frame the flyout mounts, the
	// element has no prior hover at all — either would make the flyout flap
	// open/closed mid-transit and the cursor could never reach it.
	if ctx_menu.open {
		zone := ctx_add_row_zone()
		fly_up := ctx_menu.submenu || ctx_menu.submenu_grace > 0
		over :=
			ctx_point_in(inp.x, inp.y, zone) ||
			(fly_up && ctx_point_in(inp.x, inp.y, ctx_flyout_rect()))
		if over {
			ctx_menu.submenu_grace = CTX_SUBMENU_GRACE
		} else if ctx_menu.submenu_grace > 0 {
			ctx_menu.submenu_grace -= 1
		}
		ctx_menu.submenu = over
	}
	update_timeline_cursor(inp.x, inp.y)
	next_left = inp.left
	next_right = inp.right
	return next_left, next_right
}
