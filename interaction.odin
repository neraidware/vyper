package main

import clay "clay-odin"
import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:time"
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
	alt, shift, ctrl:    bool,
}

// read_mouse_input snapshots the mouse buttons + modifiers for this frame.
// GetModState is correct here and is NOT the modifier-race bug fixed in
// event.odin: this is a per-frame sample of what is held *now*, for
// shift-click / alt-click style interactions. There is no discrete event to
// read the modifier off, and a frame snapshot should reflect the frame.
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
		ctrl = sdl.KeymodFlag.LCTRL in mods || sdl.KeymodFlag.RCTRL in mods,
	}
}

// interaction_pre_build runs before the clay layout so the pans + scrollbar
// drag work on last frame's geometry. Also feeds clay the pointer state, which
// must happen before build_page so PointerOver reflects this frame's layout.
interaction_pre_build :: proc(inp: Mouse_Input) {
	// NOTE: Alt+Middle over the preview pans the selected clip's crop viewport
	// (the source window slides inside a stationary visible box) instead of the
	// camera; the gesture commits one "Pan clip" node on release. Any other
	// Middle-drag over the preview pans the camera (image-viewer bound: canvas
	// edge may reach the panel edge, never cross it -- see clamp_preview_camera).
	crop_pan_allowed := inp.middle && inp.alt && clay.PointerOver(clay.ID("Preview"))
	if crop_pan_allowed {
		if sel, ok := transformable_selected(); ok && sel.kind != .Text {
			if !crop_pan.active {
				crop_pan_begin(sel, inp.x, inp.y)
			}
			pb := clay.GetElementData(clay.ID("Preview")).boundingBox
			canvas := preview_canvas(pb)
			lcx, lcy := pixel_to_project_unclamped(canvas, crop_pan.last_x, crop_pan.last_y)
			ccx, ccy := pixel_to_project_unclamped(canvas, inp.x, inp.y)
			crop_viewport_pan(sel, ccx - lcx, ccy - lcy)
			crop_pan.last_x = inp.x
			crop_pan.last_y = inp.y
		} else {
			crop_pan_allowed = false
		}
	} else if crop_pan.active {
		crop_pan_end()
	}
	if inp.middle && !crop_pan_allowed && clay.PointerOver(clay.ID("Preview")) {
		if preview_cam.panning {
			dx := inp.x - preview_cam.pan_last_x
			dy := inp.y - preview_cam.pan_last_y
			if dx != 0 || dy != 0 {
				// The user is steering the camera, so the fit toggle releases and
				// the pan sticks at the dragged position.
				preview_cam.fit_to_window = false
				preview_cam.ox += dx
				preview_cam.oy += dy
			}
		}
		preview_cam.panning = true
		preview_cam.pan_last_x = inp.x
		preview_cam.pan_last_y = inp.y
	} else if preview_cam.panning {
		preview_cam.panning = false
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
		if timeline_pan.panning {
			timeline_view.start -= (inp.x - timeline_pan.last_x) / timeline_view.zoom
			timeline_view.start = clamp(timeline_view.start, 0, f32(timeline_duration()))
			// Inverted vertical drag (grab-the-content convention): dragging
			// down moves content down ("scroll down" pushes tracks up, the
			// "hand tool" feel), so the view offset moves opposite the pointer.
			timeline_view.top -= inp.y - timeline_pan.last_y
			// Clamp to the row area that overflows the visible tracks box.
			timeline_view.top = clamp(timeline_view.top, 0, timeline_tracks_max_top())
		}
		timeline_pan.panning = true
		timeline_pan.last_x = inp.x
		timeline_pan.last_y = inp.y
	} else if timeline_pan.panning {
		timeline_pan.panning = false
	}
	// Vertical scrollbar drags: the thumb position maps directly onto the
	// container's scroll value, using the same geometry that draws the
	// thumb. Active for the inspector cards column; ends the moment the
	// button lifts. (The timeline scrolls by wheel/pan and needs no bar.)
	scroll_drag_update(
		"InspectorV",
		inp.left,
		inp.y,
		&scrollbars.inspector.dragging,
		&scrollbars.inspector.grab,
		&scrollbars.inspector.offset,
		inspector_content_height(),
		inspector_view_height(),
	)
	if panel_views.media_bin_view == .Undo {
		scroll_drag_update(
			"UndoViewer",
			inp.left,
			inp.y,
			&scrollbars.undo_view.dragging,
			&scrollbars.undo_view.grab,
			&undo_hist.view_scroll,
			undo_view_rows_height(),
			undo_view_clip_height(),
		)
	}
	clay.SetPointerState({inp.x, inp.y}, inp.left)
}

// clamp_view_scrolls pins the timeline track-list and inspector scroll values
// to their derived ranges after the layout (which their maxes depend on).
clamp_view_scrolls :: proc() {
	if len(timeline.tracks) > 0 {
		timeline_view.top = clamp(timeline_view.top, 0, timeline_tracks_max_top())
	}
	scrollbars.inspector.offset = clamp(scrollbars.inspector.offset, 0, inspector_max_scroll())
	undo_hist.view_scroll = clamp(undo_hist.view_scroll, 0, undo_view_max_scroll())
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
	// swallows any click over its badge box.
	{ hit = proc(inp: Mouse_Input) -> bool {
		return import_bg_active() && box_contains(import_ui.cancel_box, inp.x, inp.y)
	}, action = proc(_: Mouse_Input) { import_bg_cancel() } },
	{ id = "BinImportButton", action = proc(_: Mouse_Input) {
		// The in-app finder replaces the OS import dialog; ImportBin mode drops
		// the picked file into the media bin without touching the timeline.
		finder_open(.ImportBin)
	} },
	// Pressing a bin cell selects the media and starts the drag-to-timeline
	// gesture (ghost while down, committed on release over a lane).
	{ hit = proc(inp: Mouse_Input) -> bool {
		return len(media_bin.assets) > 0 && media_bin_item_at(inp.x, inp.y) >= 0
	}, action = proc(inp: Mouse_Input) {
		begin_media_drag(media_bin_item_at(inp.x, inp.y), inp.x, inp.y)
	} },
	{ id = "OpenFileButton", action = proc(_: Mouse_Input) {
		finder_open(.Open)
	} },
	{ id = "Res720", action = proc(_: Mouse_Input) { set_project_resolution_preset(1280, 720) } },
	{ id = "Res1080", action = proc(_: Mouse_Input) { set_project_resolution_preset(1920, 1080) } },
	{ id = "Res4K", action = proc(_: Mouse_Input) { set_project_resolution_preset(3840, 2160) } },
	{ id = "ResAuto", action = proc(_: Mouse_Input) { set_project_resolution_auto() } },
	{ id = "OrientVertical", action = proc(_: Mouse_Input) { set_project_orientation(!(project.height > project.width)) } },
	{ id = "SnapCenter", action = proc(_: Mouse_Input) { editor_flags.snap_center_to_canvas = !editor_flags.snap_center_to_canvas } },
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
	{ id = "RenderOverwrite", action = proc(_: Mouse_Input) { render_output.overwrite = !render_output.overwrite } },
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
	if edit_state.field != .None && !edit_field_over() {
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
	// Undo-tree viewer (media bin Undo view): a click on a tree row moves the
	// cursor to that action. First in the chain so the undo view claims its own
	// rows before anything underneath.
	proc(inp: Mouse_Input) -> bool {
		return undo_view_row_click(inp)
	},
	// Undo-tree viewer scrollbar (thumb drag / strip jump).
	proc(inp: Mouse_Input) -> bool {
		if panel_views.media_bin_view != .Undo {
			return false
		}
		if scroll_press(
			"UndoViewer",
			inp.y,
			&scrollbars.undo_view.dragging,
			&scrollbars.undo_view.grab,
		) {
			return true
		}
		return false
	},
	// Scrollbar: pressing the thumb starts a drag; pressing anywhere else on
	// the strip jumps the thumb to the cursor. One stack per scrollable column
	// (inspector cards only — the timeline scrolls by wheel/pan).
	proc(inp: Mouse_Input) -> bool {
		if scroll_press(
			"InspectorV",
			inp.y,
			&scrollbars.inspector.dragging,
			&scrollbars.inspector.grab,
		) {
			return true
		}
		return false
	},
	// Clicking an X/Y/Scale/crop property field focuses it for typing; the
	// diamond button beside it (KfAdd*) adds a keyframe for that property at
	// the playhead. The track name is minted HERE (the consumer owns the
	// property→name mapping; the store never interprets it) — see kf_add_prop.
	proc(inp: Mouse_Input) -> bool {
		sel, ok := transformable_selected()
		if !ok {
			return false
		}
		if clay.PointerOver(clay.ID("KfAddX")) {
			kf_add_prop(sel, "transform.x", sel.transform_x)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddTrans")) {
			kf_add_group_prop(sel, "transform", {sel.transform_x, sel.transform_y, 0, 0, 0, 0, 0})
			return true
		}
		if clay.PointerOver(clay.ID("KfAddCrop")) {
			kf_add_group_prop(sel, "crop", {sel.crop_l, sel.crop_r, sel.crop_t, sel.crop_b, 0, 0, 0})
			return true
		}
		if clay.PointerOver(clay.ID("KfAddY")) {
			kf_add_prop(sel, "transform.y", sel.transform_y)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddS")) {
			kf_add_prop(sel, "scale", sel.scale)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddCropL")) {
			kf_add_prop(sel, "crop.l", sel.crop_l)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddCropR")) {
			kf_add_prop(sel, "crop.r", sel.crop_r)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddCropT")) {
			kf_add_prop(sel, "crop.t", sel.crop_t)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddCropB")) {
			kf_add_prop(sel, "crop.b", sel.crop_b)
			return true
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
	// Gain knob drag + gain value field + gain keyframe diamond: the only
	// inspector edit that targets audio clips (the X/Y/Scale/crop probe above
	// rejects .Audio). The knob starts a live drag; the field focuses for
	// typing like any other field; the KfAddGain diamond keys gain at the
	// playhead.
	proc(inp: Mouse_Input) -> bool {
		_, cl, ok := selected_clip()
		if !ok || cl.kind != .Audio {
			return false
		}
		if clay.PointerOver(clay.ID("KfAddGain")) {
			kf_add_prop(cl, "gain", cl.gain)
			return true
		}
		if clay.PointerOver(clay.ID("GainKnob")) {
			undo_begin()
			gain_drag.clip = cl
			gain_drag.start_x = inp.x
			gain_drag.start_db = cl.gain
			active_interaction = .Gain_Drag
			return true
		}
		if clay.PointerOver(clay.ID("PropFieldGain")) {
			edit_begin(.Gain, cl.gain)
			return true
		}
		return false
	},
	// Keyframe value field (Clip inspector keyframe readout): focuses for
	// typing like the clip fields. Targets the KEYFRAME selection, which the
	// X/Y/Scale/crop and gain handlers above can't see — they resolve
	// selected_clip(), and the two selections are mutually exclusive.
	proc(inp: Mouse_Input) -> bool {
		if !kf_sel.active {
			return false
		}
		if clay.PointerOver(clay.ID("PropFieldKf")) {
			if _, _, k, ok := kf_selected(); ok {
				// A packed (section) key's readout shows lane 0; edit_begin
				// seeds the field with that lane so the typed value and the
				// displayed one agree (commit unwraps and edits that lane).
				v0: f32
				if k.mask != 0 {
					v0, _ = kf_lane_value(k^, 0)
				} else {
					v0 = k.value.(f32)
				}
				edit_begin(.Kf_Value, v0)
				return true
			}
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
			preview_move.start_offset_x = pcx - sel.transform_x
			preview_move.start_offset_y = pcy - sel.transform_y
			// handle_drag.start_tx/ty double as the drag-start transform for the
			// release-time change check; the move is applied live, so begin the
			// pre-edit capture now and push one transform node on release.
			handle_drag.start_tx = sel.transform_x
			handle_drag.start_ty = sel.transform_y
			undo_begin()
			active_interaction = .Preview_Move
			return true
		}
		return false
	},
	// Snap toggles + playhead-time nav live in the timeline's bottom bar.
	proc(inp: Mouse_Input) -> bool {
		if clay.PointerOver(clay.ID("SnapClipToPh")) {
			editor_flags.snap_clips_to_playhead = !editor_flags.snap_clips_to_playhead
			return true
		}
		if clay.PointerOver(clay.ID("SnapPhToClip")) {
			editor_flags.snap_playhead_to_clips = !editor_flags.snap_playhead_to_clips
			return true
		}
		if clay.PointerOver(clay.ID("AutoKf")) {
			editor_flags.auto_keyframe = !editor_flags.auto_keyframe
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
	// the rest of the strip is the point-marker lane. Gap IDs are keyed by the
	// ORDER position, and insert_track places the new row at that position.
	proc(inp: Mouse_Input) -> bool {
		sync_track_order()
		for i := 0; i <= len(timeline.track_order); i += 1 {
			if clay.PointerOver(clay.ID("AddTrack", u32(i))) {
				insert_track(i)
				return true
			}
		}
		return false
	},
	// Grab a track by its name gutter and drag it onto an insert gap to
	// reorder the stack. Runs after the insert-gap button (they share the
	// gutter) so a press on that still wins; a plain click that never hovers a
	// gap ends as a no-op.
	proc(inp: Mouse_Input) -> bool {
		for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
			if clay.PointerOver(clay.ID("TrackName", u32(track_idx))) {
				begin_track_drag(track_idx)
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
					selection.track = track_idx
					selection.index = index
					undo_begin()
					active_interaction = .Clip_Resize
					clip_resize.edge = edge
					capture_link_group(&track.clips[index], track_idx)
					return true
				}
			}
		}
		return false
	},
	// Selecting a keyframe diamond: geometry hit (the diamonds paint in the
	// post-layout overlay, so no clay element sits under them). Runs before the
	// clip press below so a diamond can never fall through to a tile drag.
	// kf_select makes the keyframe the sole selection, dropping any clip set.
	proc(inp: Mouse_Input) -> bool {
		if ti, ci, lane, key, ok := kf_key_at(inp.x, inp.y); ok {
			kf_select(ti, ci, lane, key)
			cl, _, k, kok := kf_selected()
			// A stale hit (the key vanished between the hit-test and the resolve)
			// must read as a plain click, never as a double-click against a
			// borrowed frame: park the record so no second press can match it.
			now := i64(time.now()._nsec)
			kf_frame := kok ? k.frame_off : -1
			// A second press on the SAME key inside the double-click window is a
			// "go to keyframe": move the playhead onto that key's frame (anchoring
			// audio exactly like the scrub) and swallow the press so it never arms
			// a move. The first press of the pair already selected the key.
			if kok &&
			   kf_dbl_click.ns != 0 &&
			   now - kf_dbl_click.ns <= KF_DBL_CLICK_NS &&
			   ti == kf_dbl_click.track &&
			   ci == kf_dbl_click.clip &&
			   lane == kf_dbl_click.lane &&
			   kf_frame == kf_dbl_click.frame {
				f := clamp(
					cl.timeline_start_frame + i64(kf_frame),
					0,
					max(0, timeline_duration() - 1),
				)
				playhead.frame = f
				audio_seek(f)
				sync.atomic_store(&audio_rpt.ph_src, 1)
				sync.atomic_store(&audio_rpt.ph_catch, 0)
				kf_dbl_click.ns = now
				return true
			}
			kf_dbl_click.ns = now
			kf_dbl_click.track = ti
			kf_dbl_click.clip = ci
			kf_dbl_click.lane = lane
			kf_dbl_click.frame = kf_frame
			// The same press that selects ALSO arms the horizontal move gesture
			// (S4). A drag is only distinguishable from a click at release, so
			// arming here with a frame-at-press capture + release-time compare
			// is the honest shape: a click that never slides commits nothing
			// (the clip-stutter rule) and the capture doubles as the pre-move
			// snapshot hook (undo_begin) for the live drag. The drag translates
			// the key by the pointer's own delta from the grab point
			// (kf_move.pivot), so an off-center grab never snaps the key's
			// center to the cursor.
			if kok {
				kf_move.start_frame = k.frame_off
				kf_move.press_x = inp.x
				box :=
					clay.GetElementData(clay.ID("TimelineClipWrap", u32(ti * 1000 + ci))).boundingBox
				kf_move.pivot = f32(k.frame_off) - (inp.x - box.x) / timeline_view.zoom
			}
			undo_begin()
			active_interaction = .Keyframe_Move
			return true
		}
		return false
	},
	// Find which (if any) clip the pointer is over and start dragging it.
	// NOTE: this runs ONLY on a fresh press (inp.left && !prev_mouse_down) —
	// while the button is HELD the drag must follow the cursor past the clip,
	// the lane, even the timeline panel, so nothing here may gate the move.
	proc(inp: Mouse_Input) -> bool {
		for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
			track := &timeline.tracks[track_idx]
			for index := 0; index < len(track.clips); index += 1 {
				if clay.PointerOver(clay.ID("TimelineClip", u32(track_idx * 1000 + index))) {
					// Pressing a tile replaces any keyframe selection (S3: the
					// two are mutually exclusive), both for the plain-click
					// reselect and for a Shift+click multi-toggle.
					kf_sel = {}
					selection.track = track_idx
					selection.index = index
					if inp.shift {
						// Shift+click toggles the clip into/out of the
						// multi-selection (for U linking) without dragging.
						cid := track.clips[index].clip_id
						if cid in selection.extra_set {
							delete_key(&selection.extra_set, cid)
						} else {
							selection.extra_set[cid] = true
						}
						return true
					}
					// Plain click = single selection: drop any earlier
					// Shift+clicked extras and grab the clip.
					clear(&selection.extra_set)
					clip_move.group_delta = 0
					clip_move.lane_dwell = 0
					clip_move.clip = &track.clips[index]
					clip_move.source_track = track_idx
					clip_move.source_index = index
					clip_move.hover_track = track_idx
					undo_begin()
					active_interaction = .Clip_Move
					clip_move.offset =
						inp.x -
						clay.GetElementData(clay.ID("TimelineClip", u32(track_idx * 1000 + index))).boundingBox.x
					capture_link_group(clip_move.clip, track_idx)
					return true
				}
			}
		}
		return false
	},
}

// begin_track_drag arms a track-reorder drag: records the grabbed track's
// storage index and starts following the hover into the insert gaps.
begin_track_drag :: proc(track_idx: int) {
	active_interaction = .Track_Drag
	track_drag.idx = track_idx
	track_drag.hover_row = -1
	update_track_drag()
}

// update_track_drag recomputes which insert gap the pointer hovers while a
// track-reorder drag is in flight (called every mouse-move while down). Gap
// positions are keyed by ORDER row r (top-to-bottom across the strip), the
// same r the ui.odin loop and insert_track use. The last gap (r == len) is
// the strip below the final row.
update_track_drag :: proc() {
	if active_interaction != .Track_Drag {
		return
	}
	sync_track_order()
	hover := -1
	for r := 0; r <= len(timeline.track_order); r += 1 {
		if clay.PointerOver(clay.ID("TrackGap", u32(r))) {
			hover = r
			break
		}
	}
	track_drag.hover_row = hover
}

// end_track_drag finishes a track-reorder drag: when released over a valid
// gap, moves the track to that stack position, then clears the drag state.
// Releasing nowhere (or over the track's own row) just cancels the drag.
end_track_drag :: proc() {
	if track_drag.idx >= 0 && track_drag.hover_row >= 0 {
		move_track_to_row(track_drag.idx, track_drag.hover_row)
		if vyper_trace {
			fmt.printf("[tl] reordered track storage=%d to row=%d\n", track_drag.idx, track_drag.hover_row)
		}
	}
	active_interaction = .None
	track_drag.idx = -1
	track_drag.hover_row = -1
}

// drag_move_in_place advances the dragged clip (or whole linked group) to
// `frame` on its source lane, clamped so it never overlaps a neighbor. Shared
// by the plain same-lane drag and the dwell frames of a potential vertical
// drop: a fast flick that skitters across a lane boundary must keep the clip
// glued to the cursor, so the horizontal follow can't live inside the
// hover==source branch alone.
drag_move_in_place :: proc(frame: f32) {
	if clip_move.clip == nil {
		return
	}
	if len(clip_move.group_orig) > 1 {
		// Linked group: the whole unit shifts by deltas every member can honor
		// exactly -- the anchor never moves into a slot a partner can't reach.
		// A fast flick whose target overshoots a member's blocker is clamped to
		// the binding wall (flush) instead of freezing the group at a stale
		// sampled position; it parks where a slow drag to the same wall would.
		delta := i64(max(frame, 0)) - clip_move.group_orig[0].start
		delta = group_clamp_delta(delta)
		if group_delta_feasible(delta) {
			if clip_move.clip.timeline_start_frame != clip_move.group_orig[0].start + delta {
				if vyper_trace {
					fmt.printf(
						"[tl] drag group link=%d (%d clips) delta=%d\n",
						clip_move.clip.link_id,
						len(clip_move.group_orig),
						delta,
					)
				}
				clip_move.clip.timeline_start_frame = clip_move.group_orig[0].start + delta
			}
			apply_group_drag_to_members(delta)
		}
	} else {
		// Horizontal move: keep the live-follow behavior but clamp so the clip
		// can never overlap a neighbor on this track.
		new_start := clip_slide_in_track(
			&timeline.tracks[clip_move.source_track],
			clip_move.source_index,
			clip_move.clip.source_length_frames,
			i64(max(frame, 0)),
			clip_move.clip.timeline_start_frame,
		)
		if clip_move.clip.timeline_start_frame != new_start {
			if vyper_trace {
				fmt.printf(
					"[tl] drag clip src=%s len=%d start=%d -> %d\n",
					clip_move.clip.path,
					clip_move.clip.source_length_frames,
					clip_move.clip.timeline_start_frame,
					new_start,
				)
			}
			clip_move.clip.timeline_start_frame = new_start
		}
	}
}

// update_keyframe_drag follows the pointer while a Keyframe_Move drag is in
// flight (called every mouse-move while down, like the clip/gain updates). The
// key TRANSLATES by the pointer's own frame delta from the grab point
// (kf_move.pivot), so the diamond keeps the exact offset the user grabbed it at
// — it can never jump its center to the cursor, and the pointer can never
// detach (the mapping is a pure delta, no per-frame accumulation). The move only
// engages once the cursor travels KF_DRAG_THRESHOLD_PX from the press, so a
// click (even one landing off-center) never nudges the key.
update_keyframe_drag :: proc(mx: f32) {
	if kf_sel.track_idx < 0 || kf_sel.clip_index < 0 {
		return
	}
	cl, _, k, ok := kf_selected()
	if !ok {
		return
	}
	if abs(mx - kf_move.press_x) < KF_DRAG_THRESHOLD_PX {
		return
	}
	box :=
		clay.GetElementData(clay.ID("TimelineClipWrap", u32(kf_sel.track_idx * 1000 + kf_sel.clip_index))).boundingBox
	if box.width <= 0 {
		return
	}
	cursor_frame := (mx - box.x) / timeline_view.zoom
	k.frame_off = clamp(i32(cursor_frame + kf_move.pivot), 0, i32(cl.source_length_frames))
}

// commit_keyframe_drag is the Keyframe_Move release path: the frame was applied
// live during the gesture (the keys array may be transiently out of order), so
// it captures one undo node (the press already ran undo_begin, so the pre-drag
// tree is pending) only if the key actually moved. A no-move click reselects and
// nothing else — no reseek, no reset, no node. The move is normalized as a pure
// store pair, del(old frame) + set(final frame), so the array comes back sorted
// and unique from wherever the drag landed; the selection is re-picked by the
// landed frame because those store ops bumped the structure gen.
commit_keyframe_drag :: proc() {
	if !kf_sel.active {
		kf_move.start_frame = 0
		return
	}
	cl, lane, k, ok := kf_selected()
	if !ok {
		kf_move.start_frame = 0
		return
	}
	if k.frame_off == kf_move.start_frame {
		return
	}
	// Capture everything before the store ops — the keys buffer reallocates and
	// the track can even drop/re-mint, so every pointer or borrowed string held
	// across the ops would dangle. The name is cloned because del() frees the
	// track's name string when the last key leaves; set() then re-clones from
	// our copy instead of freed memory. A packed (section) key moves whole: its
	// array payload is copied out before the del, then re-landed via the packed
	// producer so a grouped crop/transform key drags as one unit.
	name := strings.clone(cl.keyframe_tracks[lane].name)
	defer delete(name)
	start_off := kf_move.start_frame
	final_off := k.frame_off
	mask := k.mask
	packed: [KF_PACK_MAX]f32
	scalar: f32
	if mask != 0 {
		packed = k.value.([KF_PACK_MAX]f32)
	} else {
		scalar = k.value.(f32)
	}
	kf_del_key(cl, name, start_off)
	if mask != 0 {
		// A packed (section) key drags as one whole crop/transform unit and
		// lands in the SAME form: form-preserving re-land, never a fold. Its
		// source was a packed section key, so `name` must BE a section and no
		// lane of it may exist (the mutual-exclusion invariant, asserted both
		// ends to catch a drifted store).
		sec_idx, is_sec := kf_geom_section_index(name)
		assert(is_sec, "a packed section key drag must source a section track name")
		sdefs := kf_geom_sections
		for lane_prop in sdefs[sec_idx].lanes {
			assert(
				kf_track_index(cl^, kf_lane_name(lane_prop)) < 0,
				"a packed section and its lanes may not coexist during a drag re-land",
			)
		}
		kf_set_packed_key(cl, name, final_off, packed, mask)
	} else {
		kf_geom_set_lane_key(cl, name, final_off, scalar)
	}
	// Re-select the moved key by name + landed frame (the lane index may have
	// shifted if the track emptied and re-minted), under the fresh gen.
	fresh_lane := kf_track_index(cl^, name)
	if fresh_lane >= 0 {
		fresh := &cl.keyframe_tracks[fresh_lane]
		for ki in 0 ..< len(fresh.keys) {
			if fresh.keys[ki].frame_off == final_off {
				kf_select(kf_sel.track_idx, kf_sel.clip_index, fresh_lane, ki)
				break
			}
		}
	}
	undo_push(.Value, "Move keyframe")
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
		case .Track_Drag:
			end_track_drag()
		case .Clip_Move:
			// Commit a vertical drop if the ghost hovers another track;
			// horizontal drags already applied their new start live.
			if clip_move.hover_track != clip_move.source_track &&
			   clip_move.hover_track >= 0 &&
			   clip_move.source_track >= 0 {
				if len(clip_move.group_orig) > 1 {
					// Vertical drop for a linked group is measured in VISUAL rows:
					// the group shifts by the number of stack rows between the
					// anchor's source track and the hovered lane, regardless of
					// storage order.
					delta_rows := order_row_of(clip_move.hover_track) - order_row_of(clip_move.source_track)
					move_linked_group(delta_rows)
				} else {
					move_clip_to_track(
						clip_move.source_track,
						clip_move.source_index,
						clip_move.hover_track,
						clip_move.ghost_start,
					)
				}
			}
			// Record the move only if the gesture actually changed something:
			// same-track drags already applied their start live, so compare
			// against the capture-time snapshot.
			{
				moved := false
				if len(clip_move.group_orig) > 1 {
					moved =
						clip_move.group_delta != 0 ||
						(clip_move.hover_track >= 0 &&
							clip_move.hover_track != clip_move.source_track &&
							order_row_of(clip_move.hover_track) != order_row_of(clip_move.source_track))
				} else if len(clip_move.group_orig) > 0 && clip_move.clip != nil {
					moved =
						clip_move.clip.timeline_start_frame != clip_move.group_orig[0].start ||
						(clip_move.hover_track >= 0 && clip_move.hover_track != clip_move.source_track)
				}
				if moved {
					label := len(clip_move.group_orig) > 1 ? "Move clip(s)" : "Move clip"
					undo_push(.Move, label)
				}
			}
		case .Clip_Resize:
			// Resize is applied live during the drag; capture the gesture as one
			// undo node on release.
			if clip_resize.moved {
				undo_push(.Resize, len(clip_move.group_orig) > 1 ? "Resize clip(s)" : "Resize clip")
			}
		case .Handle_Drag:
			// Scale/crop is applied live; commit the gesture as one transform
			// node only if the box actually changed.
			if sel, ok := transformable_selected(); ok {
				if sel.scale != handle_drag.start_scale ||
				   sel.crop_l != handle_drag.start_crop_l ||
				   sel.crop_r != handle_drag.start_crop_r ||
				   sel.crop_t != handle_drag.start_crop_t ||
				   sel.crop_b != handle_drag.start_crop_b ||
				   sel.transform_x != handle_drag.start_tx ||
				   sel.transform_y != handle_drag.start_ty {
					undo_push(.Transform, handle_drag.kind == .Crop ? "Crop clip" : "Scale clip")
				}
			}
		case .Preview_Move:
			// A preview move is applied live; commit it as one transform node if
			// the clip actually moved, against the drag-start capture.
			if sel, ok := transformable_selected(); ok {
				if sel.transform_x != handle_drag.start_tx ||
				   sel.transform_y != handle_drag.start_ty {
					undo_push(.Transform, "Move transform")
				}
			}
		case .Gain_Drag:
			// Gain is applied live during the drag; record one value node on
			// release. No re-provision here: the per-move geometry commit +
			// the producer's live gain fold already put the final value on the
			// output, and the old audio_note_edit() on release reopened every
			// decoder (~100s of ms) -- the audible stutter after a knob drag.
			if gain_drag.clip != nil && gain_drag.clip.gain != gain_drag.start_db {
				undo_push(.Value, "Set clip gain")
			}
		case .Keyframe_Move:
			commit_keyframe_drag()
		}
		active_interaction = .None
		handle_drag.handle = nil
		handle_drag.kind = .None
		handle_drag.corner_snapped = false
		clip_move.clip = nil
		gain_drag.clip = nil
		kf_move.start_frame = 0
		kf_move.press_x = 0
		kf_move.pivot = 0
		clip_move.source_track = -1
		clip_move.source_index = -1
		clip_move.hover_track = -1
		clip_move.lane_dwell = 0
		clip_move.group_delta = 0
		clear(&clip_move.group_orig)
		clip_resize.edge = -1
		clip_resize.moved = false
	} else {
		switch active_interaction {
		case .Media_Bin_Drag:
			// A bin drag in flight: recompute the hovered lane + ghost each frame.
			update_media_drag_lanes(inp.x, inp.y)
		case .Track_Drag:
			// Track reorder in flight: recompute the hovered insert gap each frame.
			update_track_drag()
		case .Handle_Drag:
			if sel, ok := transformable_selected(); ok {
				pb := clay.GetElementData(clay.ID("Preview")).boundingBox
				canvas := preview_canvas(pb)
				update_handle_drag(sel, canvas, inp.x, inp.y, inp.shift)
				// Auto-keyframe every property this gesture actually moved (the
				// crop handles reach one or two edges, no more — keying all four
				// would stamp keys the user never touched).
				autokey_gesture(sel, handle_drag.start_scale, sel.scale, "scale")
				autokey_gesture(sel, handle_drag.start_tx, sel.transform_x, "transform.x")
				autokey_gesture(sel, handle_drag.start_ty, sel.transform_y, "transform.y")
				if handle_drag.kind == .Crop {
					autokey_gesture(sel, handle_drag.start_crop_l, sel.crop_l, "crop.l")
					autokey_gesture(sel, handle_drag.start_crop_r, sel.crop_r, "crop.r")
					autokey_gesture(sel, handle_drag.start_crop_t, sel.crop_t, "crop.t")
					autokey_gesture(sel, handle_drag.start_crop_b, sel.crop_b, "crop.b")
				}
			}
		case .Panel_Resize:
			// The divider sits in the root column below the app bar, so the
			// pointer's y is offset by APP_BAR_H; center the grab strip on the
			// cursor by subtracting half its height. Without the app-bar term
			// the handle leads the cursor by exactly that strip's height.
			panel_layout.upper_area_height = inp.y - APP_BAR_H - EDITOR_DIVIDER_H * 0.5
			// Keep a lower-bound that scales with the window so a short window
			// never lets the upper and lower areas collide (the old hardcoded
			// 460/180 bounds collapsed on windows shorter than ~640px). Same
			// bounds the automatic track fit uses.
			min_h, max_h := panel_clamp_bounds(f32(height))
			panel_layout.upper_area_height = clamp(panel_layout.upper_area_height, min_h, max_h)
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
					sel.transform_x = pcx - preview_move.start_offset_x
					sel.transform_y = pcy - preview_move.start_offset_y
					// 5px snap margin (in rendered preview pixels): to the canvas
					// center when near it, and/or to the canvas borders (edge
					// snap runs regardless, so a centered clip still snaps).
					snap_center(sel, snap_margin(canvas, SNAP_MARGIN_PX))
					snap_transform(sel, snap_margin(canvas, SNAP_MARGIN_PX))
					// Auto-keyframe: a moved axis keys at the playhead (new key,
					// or update of a key already sitting there) so the motion is
					// recorded on the timeline, not just the resting transform.
					// A drag's live write rides the key AND the resting value:
					// the preview samples keyed regions from the track, so the
					// on-screen moose must follow the key while it moves.
					autokey_gesture(sel, handle_drag.start_tx, sel.transform_x, "transform.x")
					autokey_gesture(sel, handle_drag.start_ty, sel.transform_y, "transform.y")
				}
			}
		case .Clip_Resize:
			if selection.track >= 0 &&
			   selection.index >= 0 &&
			   selection.track < len(timeline.tracks) &&
			   selection.index < len(timeline.tracks[selection.track].clips) {
				track_start := clay.GetElementData(clay.ID("ClipsSection", 0)).boundingBox.x
				frame := max(f32(0), (inp.x - track_start) / timeline_view.zoom + timeline_view.start)
				// Clip→playhead toggle applies to edge drags too: the dragged edge
				// (head on clip_resize.edge 0, tail on 1) latches onto the playhead
				// within the snap margin, like a clip move.
				if editor_flags.snap_clips_to_playhead {
					frame = f32(snap_to_playhead(i64(frame)))
				}
				if clip_resize.edge == 0 {
					if len(clip_move.group_orig) > 0 {
						// Linked group: shift every member's head by the same delta.
						resize_group_left(&timeline.tracks[selection.track], selection.index, i64(frame))
					} else {
						resize_clip_left(&timeline.tracks[selection.track], selection.index, i64(frame))
					}
				} else if clip_resize.edge == 1 {
					if len(clip_move.group_orig) > 0 {
						// Linked group: move every member's tail by the same delta.
						resize_group_right(
							&timeline.tracks[selection.track],
							selection.index,
							i64(frame),
						)
					} else {
						resize_clip_right(&timeline.tracks[selection.track], selection.index, i64(frame))
					}
				}
				clip_resize.moved = true
				audio_note_edit()
			}
		case .Gain_Drag:
			if gain_drag.clip == nil {
				break
			}
			dx := inp.x - gain_drag.start_x
			db := gain_drag.start_db
			if inp.ctrl {
				// Fine: continuous 0.1 dB per pixel.
				db += dx * GAIN_FINE_DB_PER_PX
			} else {
				// Coarse: one 1 dB step per full 10 px of travel since the
				// gesture began (quantized, monotonic per direction).
				db += math.floor(dx / GAIN_COARSE_PX_PER_STEP) * GAIN_COARSE_DB_PER_10PX
			}
			gain_drag.clip.gain = clamp(db, f32(GAIN_MIN_DB), f32(GAIN_MAX_DB))
			// Auto-keyframe the running gain at the playhead so the move records
			// onto a keyed timeline as it happens.
			autokey_gesture(gain_drag.clip, gain_drag.start_db, gain_drag.clip.gain, "gain")
			// Publish the running value into the audio slab so a provision mid-
			// gesture (play pressed while the knob is held) hears it; the release
			// commits nothing because the producer's live fold already applied it.
			audio_geometry_commit()
		case .Keyframe_Move:
			update_keyframe_drag(inp.x)
		case .Clip_Move:
			if clip_move.clip != nil {
				clip_x := inp.x - clip_move.offset
				track_start := clay.GetElementData(clay.ID("ClipsSection", 0)).boundingBox.x
				frame := (clip_x - track_start) / timeline_view.zoom + timeline_view.start
				frame = max(frame, 0)
				// Clip→playhead toggle: latch the drag target onto the playhead
				// once it comes within the pixel snap margin. Applied to the
				// whole linked group, since every member follows the anchor.
				// But an all-or-nothing group must never be glued onto a
				// playhead slot it cannot clear: latch only when every member can
				// follow, else keep following the cursor and let the feasibility
				// gate park the unit at the true blocker.
				if editor_flags.snap_clips_to_playhead {
					snapped := snap_to_playhead(i64(max(frame, 0)))
					if len(clip_move.group_orig) > 1 &&
					   snapped != i64(frame) &&
					   !group_delta_feasible(snapped - clip_move.group_orig[0].start) {
						snapped = i64(frame)
					}
					frame = f32(snapped)
				}
				// Determine which track lane the pointer hovers: that decides
				// whether this is a horizontal move (same track) or a vertical
				// drop staged on another track (ghost until release).
				hover := clip_move.source_track
				for ti := 0; ti < len(timeline.tracks); ti += 1 {
					lane := clay.GetElementData(clay.ID("ClipsSection", u32(ti))).boundingBox
					if lane.width > 0 && inp.y >= lane.y && inp.y <= lane.y + lane.height {
						hover = ti
						break
					}
				}
				if hover == clip_move.source_track {
					clip_move.lane_dwell = 0
					clip_move.hover_track = hover
				} else {
					// Pointer left the source lane. A vertical drop is staged only
					// once the pointer has RESTED here for DRAG_LANE_DWELL_FRAMES:
					// a fast horizontal flick often skitters across a lane
					// boundary for a frame or two, and staging the ghost instantly
					// froze the source clip mid-stroke so it detached from the
					// cursor before touching its neighbor. Until the dwell clears
					// the clip keeps following the cursor on its own lane (the
					// drag_move_in_place call below is outside this branch).
					clip_move.lane_dwell += 1
					if clip_move.lane_dwell >= DRAG_LANE_DWELL_FRAMES {
						clip_move.hover_track = hover
						// Vertical: clamp to nearest valid slot on the hovered
						// track and show it as a ghost (committed on release).
						// Linked groups slide the whole unit with the mouse's
						// horizontal offset (clip_move.group_delta) on every member's lane.
						clip_move.ghost_start = clip_place_in_track(
							&timeline.tracks[hover],
							-1,
							clip_move.clip.source_length_frames,
							i64(max(frame, 0)),
						)
						if len(clip_move.group_orig) > 1 {
							clip_move.group_delta = i64(max(frame, 0)) - clip_move.group_orig[0].start
						}
					}
				}
				// Live horizontal move: keeps the clip glued to the cursor's X on
				// its source lane regardless of which lane the pointer flicked
				// into, so the drag can never detach under fast motion. When a
				// vertical drop IS staged this previews the X the ghost follows.
				// Resync audio only when the clip actually slid this frame: a
				// plain select arms Clip_Move with the button held, so the update
				// fires for a no-move click too, and note_edit() below would
				// reseek the producer and reopen every decoder for a gesture
				// that changed nothing. Same guard Clip_Resize applies.
				start_before := clip_move.clip.timeline_start_frame
				drag_move_in_place(frame)
				// Stall tracer (VYPER_TRACE): logs the first frame where the
				// cursor's frame target advanced but the clip's start did not —
				// the exact moment a drag would be "cut short", with the lane/
				// pointer context that differs at that frame.
				if vyper_trace {
					tf := i64(max(frame, 0))
					if tf != clip_move.trace_last_target &&
					   clip_move.trace_last_start == clip_move.clip.timeline_start_frame {
						fmt.printf(
							"[drag] STALL target=%d (last=%d) clip=%d hover=%d src=%d y=%.0f x=%.0f snap=%v\n",
							tf,
							clip_move.trace_last_target,
							clip_move.clip.timeline_start_frame,
							hover,
							clip_move.source_track,
							inp.y,
							inp.x,
							editor_flags.snap_clips_to_playhead,
						)
					}
					clip_move.trace_last_target = tf
					clip_move.trace_last_start = clip_move.clip.timeline_start_frame
				}
				if clip_move.clip.timeline_start_frame != start_before {
					audio_note_edit()
				}
			}
		case .Playhead_Scrub:
			// Scrub the playhead to the pointer's frame along the ruler bar.
			ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
			frame := i64((inp.x - ruler.x) / timeline_view.zoom + timeline_view.start)
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
			if editor_flags.snap_playhead_to_clips {
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
			sync.atomic_store(&audio_rpt.ph_src, 1)
			sync.atomic_store(&audio_rpt.ph_catch, 0)
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
	// Export-encoder dropdown: same toggle/select/dismiss shape as the rate
	// menu. Changing the choice only affects the next render, never a live one.
	enc_clicked := was_click && clay.PointerOver(clay.ID("RenderEncoderButton"))
	if was_click {
		if enc_clicked {
			render_encoder_ui.menu_open = !render_encoder_ui.menu_open
		} else if render_encoder_ui.menu_open && clay.PointerOver(clay.ID("RenderEncoderMenu")) {
			if clay.PointerOver(clay.ID("EncChoiceCPU")) {
				render_encoder_ui.choice = .CPU
				render_encoder_ui.menu_open = false
			} else if clay.PointerOver(clay.ID("EncChoiceGPU")) {
				render_encoder_ui.choice = .GPU
				render_encoder_ui.menu_open = false
			}
		} else if render_encoder_ui.menu_open {
			render_encoder_ui.menu_open = false
		}
	}
	// Keyframe-interpolation dropdown: same toggle/select/dismiss shape, gated on
	// a live keyframe selection (S3). Choosing a mode commits it on the selected
	// key — the segment arriving at that key eases (we ease INTO a breakpoint) —
	// as one undoable edit; an unchanged re-click only closes the menu.
	if was_click && kf_sel.active {
		if clay.PointerOver(clay.ID("KfInterpButton")) {
			if _, _, _, ok := kf_selected(); ok {
				kf_view.interp_menu_open = !kf_view.interp_menu_open
			}
		} else if kf_view.interp_menu_open && clay.PointerOver(clay.ID("KfInterpMenu")) {
			_, _, k, ok := kf_selected()
			choice: Kf_Interp
			hit := true
			if clay.PointerOver(clay.ID("KfInterpLinear")) {
				choice = .Linear
			} else if clay.PointerOver(clay.ID("KfInterpCubic")) {
				choice = .Cubic
			} else if clay.PointerOver(clay.ID("KfInterpEaseIn")) {
				choice = .Ease_In
			} else if clay.PointerOver(clay.ID("KfInterpEaseOut")) {
				choice = .Ease_Out
			} else if clay.PointerOver(clay.ID("KfInterpEaseInOut")) {
				choice = .Ease_In_Out
			} else if clay.PointerOver(clay.ID("KfInterpElastic")) {
				choice = .Elastic
			} else {
				hit = false
			}
			if hit {
				if ok {
					if k.interp != choice {
						undo_begin()
						k.interp = choice
						undo_push(.Value, "Set keyframe interpolation")
					}
				}
				kf_view.interp_menu_open = false
			}
		} else if kf_view.interp_menu_open {
			kf_view.interp_menu_open = false
		}
	}
	// Help overlay: the "?" button toggles it; any other click outside the
	// panel dismisses it.
	if was_click {
		if clay.PointerOver(clay.ID("HelpButton")) {
			editor_flags.help_open = !editor_flags.help_open
		} else if editor_flags.help_open && !clay.PointerOver(clay.ID("HelpPanel")) {
			editor_flags.help_open = false
		}
	}
	// View-separator tabs: a click on a bottom-of-panel tab switches that
	// panel's view. The selected tab is always actionable (re-clicking reselects
	// the same view, a no-op).
	if was_click {
		if clay.PointerOver(clay.ID("MediaTabBin")) {
			panel_views.media_bin_view = .Bin
		} else if clay.PointerOver(clay.ID("MediaTabUndo")) {
			panel_views.media_bin_view = .Undo
		} else if clay.PointerOver(clay.ID("InspTabClip")) {
			panel_views.inspector_view = .Clip
		} else if clay.PointerOver(clay.ID("InspTabProject")) {
			panel_views.inspector_view = .Project
		} else if clay.PointerOver(clay.ID("InspTabRender")) {
			panel_views.inspector_view = .Render
		}
	}
	// Preview fit toggle: re-arming it snaps the camera to the contain-fit;
	// panning/zooming already cleared it (interaction_pre_build / event).
	if was_click && clay.PointerOver(clay.ID("PreviewFitButton")) {
		preview_cam.fit_to_window = !preview_cam.fit_to_window
		if preview_cam.fit_to_window {
			preview_fit_reset()
		}
	}
	// Right-click: the track NAME GUTTER gets the dedicated track menu; the
	// clip lanes get the timeline menu (a clip gets clip actions, empty space
	// gets the track "Add" menu). Any fresh left-click, or a new right-click
	// that lands elsewhere, closes whatever menu was open first.
	if inp.right && !prev_right_down {
		if track := track_gutter_hit_test(inp.x, inp.y); track >= 0 {
			open_track_action_menu(inp.x, inp.y, track)
		} else if ct, ci := clip_under_pointer(); ct >= 0 {
			open_clip_context_menu(inp.x, inp.y, ct, ci)
		} else if track := timeline_track_hit_test(inp.x, inp.y); track >= 0 {
			open_track_context_menu(inp.x, inp.y, track)
		} else {
			close_context_menu()
			close_track_action_menu()
		}
	} else if was_click && (ctx_menu.open || track_ctx.open) {
		if track_ctx.open {
			if track_action_menu_hover(inp.x, inp.y) {
				handle_track_action_option(inp.x, inp.y)
			} else {
				close_track_action_menu()
			}
		} else if pointer_over_context_menu(inp.x, inp.y) {
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
