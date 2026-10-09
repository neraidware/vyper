package vyper

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

// opacity_from_x maps a pointer x across the opacity slider's captured rect to
// 0..1. Absolute, not a delta from the press point: a slider sets the value
// under the cursor, so clicking the middle jumps to 50%. A zero-width rect
// (slider not laid out yet) resolves to fully opaque rather than dividing.
opacity_from_x :: proc(x: f32) -> f32 {
	if opacity_drag.rect_w <= 0 {
		return 1.0
	}
	return clamp((x - opacity_drag.rect_x) / opacity_drag.rect_w, 0, 1)
}

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
			clip_pan_by(sel, ccx - lcx, ccy - lcy)
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
	}, action = proc(_: Mouse_Input) { playhead_scrub_arm() } },
}

// playhead_scrub_arm begins a ruler scrub. It claims the gesture and nothing else:
// playback continues, and the drag tells the audio engine where the playhead is.
//
// No seek here. An arm-seek to the playhead's current frame was tried and it is
// strictly worse than nothing: the first pointer move supersedes it one frame later,
// so the producer begins a reconcile for a position the user has already left, and the
// two seeks interleave. Measured: a press at frame 36 issued seeks to 74 then to 36 in
// consecutive lines, and the producer was mid-reconcile for 74 when 36 arrived. The
// drag's own seek carries the position, and the release commits the final one.
playhead_scrub_arm :: proc() {
	active_interaction = .Playhead_Scrub
	playhead_scrub.moved = false
	sync.atomic_store(&audio_prod.scrub_active, true)
	playhead_scrub.last_ns = 0
	// HOLD playback for the duration of the drag. Not a pause that is later
	// un-paused: the transport, the video, and the audio engine are all stopped,
	// so nothing advances while the pointer owns the playhead. The scrub audio is
	// the only sound there is. Release restores whatever the transport was doing.
	playhead_scrub.was_playing = playhead.playing
	playhead.playing = false
	preview.playing = false
	// The scrub device is a SEPARATE miniaudio device, opened only for the
	// duration of the drag. Scrub audio never touches the real-time playback
	// device -- that separation is the whole point: the playback device drains
	// at 1x, which is what forced varispeed (pitch shift) on the scrub path.
	if !scrub_device_open() {
		fmt.println("[ui] scrub device unavailable; scrubbing will be silent")
	}
	// Published HERE as well as on every move, because the flag above is visible to
	// the producer before the pointer has moved at all. Without this the producer
	// re-anchors to scrub_playhead's zero value in the window between arming and the
	// first move -- which is exactly how a drag that ends on frame 9 fed frame 0.
	sync.atomic_store(&audio_prod.scrub_playhead, playhead.frame)
	when ODIN_DEBUG {
		if play_trace {
			// Arming is where the playhead stops being a readout and becomes the pointer's,
			// so it is the one moment to record what the clock said on the way in. Without
			// it, a jump measured after the release has no "before" to be measured against.
			fmt.printf(
				"[ui]  scrub ARM at ph=%d (device reads %d, current=%t, playing=%t)\n",
				playhead.frame,
				sync.atomic_load(&playback.dev_frame),
				sync.atomic_load(&playback.dev_resync) == sync.atomic_load(&audio_prod.resync),
				playhead.playing,
			)
		}
	}
	// Seeded with the CURRENT generation, not zero: a zero here would read as
	// "a seek is outstanding" forever and the drag would never tell the producer
	// anything.
	playhead_scrub.requested_resync = sync.atomic_load(&audio_prod.resync)

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
			clip_geom_add_lane_key(sel, .Trans_X)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddTrans")) {
			clip_geom_add_group_key(sel, "transform")
			return true
		}
		if clay.PointerOver(clay.ID("KfAddCrop")) {
			clip_geom_add_group_key(sel, "crop")
			return true
		}
		// Zoom and Pan get per-lane diamonds only, no group caption diamond:
		// they group with no section (kf_geom_sections has no "zoom" section),
		// for the same reason Opacity has none -- there is no packed form to
		// key together, because pan.x and pan.y are genuinely independent
		// (a horizontal slide is not half of a vertical one).
		if clay.PointerOver(clay.ID("KfAddZoom")) {
			clip_geom_add_lane_key(sel, .Zoom)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddPanX")) {
			clip_geom_add_lane_key(sel, .Pan_X)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddPanY")) {
			clip_geom_add_lane_key(sel, .Pan_Y)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddY")) {
			clip_geom_add_lane_key(sel, .Trans_Y)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddS")) {
			clip_geom_add_lane_key(sel, .Scale)
			return true
		}
		// Opacity has its own key button rather than riding a section caption
		// like transform/crop: it groups with nothing (kf_geom_sections has no
		// "opacity" section), so there is no group key to hang it on.
		if clay.PointerOver(clay.ID("KfAddOpacity")) {
			clip_geom_add_lane_key(sel, .Opacity)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddCropL")) {
			clip_geom_add_lane_key(sel, .Crop_L)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddCropR")) {
			clip_geom_add_lane_key(sel, .Crop_R)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddCropT")) {
			clip_geom_add_lane_key(sel, .Crop_T)
			return true
		}
		if clay.PointerOver(clay.ID("KfAddCropB")) {
			clip_geom_add_lane_key(sel, .Crop_B)
			return true
		}
		if clay.PointerOver(clay.ID("PropFieldX")) {
			edit_begin(.X, clip_geom_get(sel, .Trans_X))
			return true
		}
		if clay.PointerOver(clay.ID("PropFieldY")) {
			edit_begin(.Y, clip_geom_get(sel, .Trans_Y))
			return true
		}
		if clay.PointerOver(clay.ID("PropFieldS")) {
			edit_begin(.Scale, clip_geom_get(sel, .Scale))
			return true
		}
		if clay.PointerOver(clay.ID("OpacitySlider")) {
			undo_begin()
			opacity_drag.clip = sel
			// Capture the PLAYHEAD value, not the resting field: on a keyed
			// clip those differ, and both the start-of-gesture comparison (for
			// the release-time undo push) and the first drag sample must be
			// measured against what the user actually saw.
			opacity_drag.start_op = clip_geom_get(sel, .Opacity)
			rect := clay.GetElementData(clay.ID("OpacitySlider")).boundingBox
			opacity_drag.rect_x = rect.x
			opacity_drag.rect_w = rect.width
			// Routed, not assigned: a keyed opacity writes a key at the
			// playhead, so the edit survives auto-key being off.
			clip_geom_set(sel, .Opacity, opacity_from_x(inp.x))
			active_interaction = .Opacity_Drag
			return true
		}
		if clay.PointerOver(clay.ID("PropFieldOpacity")) {
			edit_begin(.Opacity, clip_geom_get(sel, .Opacity) * 100)
			return true
		}
		if clay.PointerOver(clay.ID("PropCropL")) {
			edit_begin(.Crop_L, clip_geom_get(sel, .Crop_L) * 100)
			return true
		}
		if clay.PointerOver(clay.ID("PropCropR")) {
			edit_begin(.Crop_R, clip_geom_get(sel, .Crop_R) * 100)
			return true
		}
		if clay.PointerOver(clay.ID("PropCropT")) {
			edit_begin(.Crop_T, clip_geom_get(sel, .Crop_T) * 100)
			return true
		}
		if clay.PointerOver(clay.ID("PropCropB")) {
			edit_begin(.Crop_B, clip_geom_get(sel, .Crop_B) * 100)
			return true
		}
		if clay.PointerOver(clay.ID("PropFieldZoom")) {
			edit_begin(.Zoom, clip_geom_get(sel, .Zoom) * 100)
			return true
		}
		if clay.PointerOver(clay.ID("PropFieldPanX")) {
			edit_begin(.Pan_X, clip_geom_get(sel, .Pan_X) * 100)
			return true
		}
		if clay.PointerOver(clay.ID("PropFieldPanY")) {
			edit_begin(.Pan_Y, clip_geom_get(sel, .Pan_Y) * 100)
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
		// Speed and pitch, audio clips only. edit_begin takes the value in the
		// field's DISPLAY unit, so speed is passed as a percent and the commit in
		// edit.odin divides it back -- the two ends of that conversion live next
		// to each other on purpose, and a second copy of "divide by 100 here"
		// would be the kind of drift this already had once.
		if cl.kind == .Audio {
			if clay.PointerOver(clay.ID("PropFieldSpeed")) {
				edit_begin(.Speed, f32(clip_speed(cl) * 100.0))
				return true
			}
			if clay.PointerOver(clay.ID("PropFieldPitch")) {
				edit_begin(.Pitch, clip_pitch_at_playhead(cl))
				return true
			}
		}
		return false
	},
	// Keyframe value field (Clip inspector keyframe readout): focuses for
	// typing like the clip fields. Targets the KEYFRAME selection, which the
	// X/Y/Scale/crop and gain handlers above can't see — they resolve
	// selected_clip(), and the two selections are mutually exclusive.
	proc(inp: Mouse_Input) -> bool {
		if clay.PointerOver(clay.ID("PropFieldKf")) {
			// kf_selected resolves only a selection of EXACTLY one key, so a
			// multi-selection cannot land its first key in the editor as though
			// it were the only one. The field is not even offered for a
			// multi-selection (keyframes_readout), so this is a belt-and-braces
			// read of the same contract.
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
	// Resize a selected edge. A touching selected neighbor turns that edge grab
	// into a paired seam roll.
	proc(inp: Mouse_Input) -> bool {
		sel_tr, sel_cl, ok := selected_clip()
		if !ok {
			return false
		}
		if track_idx, left, right, paired := timeline_resize_pair_edge_at(inp.x, inp.y); paired {
			undo_begin()
			active_interaction = .Clip_Resize
			clip_resize.edge = .Roll
			clip_resize.moved = false
			clip_resize.roll_track = track_idx
			clip_resize.roll_left_id = timeline.tracks[track_idx].clips[left].clip_id
			clip_resize.roll_right_id = timeline.tracks[track_idx].clips[right].clip_id
			clear(&clip_move.group_orig)
			return true
		}
		for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
			track := &timeline.tracks[track_idx]
			for index := 0; index < len(track.clips); index += 1 {
				if &track.clips[index] != sel_cl {
					continue
				}
				if edge := timeline_resize_edge_at(track_idx, index, inp.x, inp.y); edge != .None {
					selection.track = track_idx
					selection.index = index
					// SHIFT on an audio edge means STRETCH, not trim. Checked before the
					// resize arm because both gestures start from the same edge hit and
					// they must never both claim it.
					if inp.shift && track.clips[index].kind == .Audio {
						c := &track.clips[index]
						clip_stretch.clip = c
						clip_stretch.edge = edge
						clip_stretch.start_x = inp.x
						clip_stretch.start_speed = clip_speed(c)
						// Captured ONCE. See Clip_Stretch_State: recomputing this during
						// the drag compounds and the clip walks across the timeline.
						clip_stretch.timeline_len = clip_timeline_length(c)
						clip_stretch.moved = false
						undo_begin()
						active_interaction = .Clip_Stretch
						return true
					}
					undo_begin()
					active_interaction = .Clip_Resize
					clip_resize.edge = edge
					clip_resize.moved = false
					clip_resize.roll_track = -1
					clip_resize.roll_left_id = 0
					clip_resize.roll_right_id = 0
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
	// A plain click makes the grabbed one the sole selection — unless it was
	// already part of a run, in which case the press preserves the run for a
	// drag and the narrowing waits for the release (see below). Shift+click is
	// always a plain selection of the clicked key: it arms no move and no
	// hover-select (that is entered from empty space). Both drop any clip set
	// (kf_select owns the S3 exclusivity).
	proc(inp: Mouse_Input) -> bool {
		clear(&kf_hits)
		kf_keys_at(inp.x, inp.y, &kf_hits)
		if len(kf_hits) > 0 {
			grab := kf_hits[0]
			// A press cannot tell a click from a drag, so it may not collapse a
			// selection that the press might have been the start of DRAGGING. When
			// the grabbed key is already part of a run, the run is the payload: the
			// capture below takes all of it and the narrowing is deferred to the
			// release, which is the first frame that knows no drag happened. A press
			// on a key outside the selection has nothing to preserve — the user is
			// starting a fresh selection either way — so it narrows immediately, and
			// a drag from it moves the key it grabbed rather than the old run.
			narrow_click := kf_sel_contains(grab)
			if !narrow_click {
				kf_select(grab.track_idx, grab.clip_index, grab.lane, grab.key)
			}
			if inp.shift {
				// A Shift+click ON a keyframe is just a selection: it narrows to
				// the key clicked and arms NOTHING. Hover-select is entered from
				// empty space (see the TrackArea fallback), because a press on a
				// key is a statement about that key, and letting the pointer then
				// paint the rest of the timeline would run the selection backwards
				// from what was just clicked.
				//
				// It narrows unconditionally, including for a key that was already
				// selected — the deferred narrow above is for the PLAIN press,
				// whose drag has to carry the run, and there is no run to carry here.
				kf_select(grab.track_idx, grab.clip_index, grab.lane, grab.key)
				kf_brush_disarm()
				// The go-to-keyframe double-click is deliberately not reachable
				// with Shift held: a Shift+click is a selection, and pairing it
				// with the plain press next to it into a seek the user never asked
				// for would make that plain press fire instead. Parking the record
				// keeps a press on either side from pairing across this one.
				kf_dbl_click.ns = 0
				return true
			}
			gcl, _, k, kok := kf_resolve_value(grab)
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
			   grab.track_idx == kf_dbl_click.track &&
			   grab.clip_index == kf_dbl_click.clip &&
			   grab.lane == kf_dbl_click.lane &&
			   kf_frame == kf_dbl_click.frame {
				// This press is a seek, not a selection, and it arms no move — so
				// the deferred narrow will never be reached. Settle it here or a
				// double-click on a key inside a run would leave the whole run
				// selected, which is the one case the deferral above changed.
				if narrow_click {
					kf_select(grab.track_idx, grab.clip_index, grab.lane, grab.key)
				}
				f := clamp(
					gcl.timeline_start_frame + i64(kf_frame),
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
			kf_dbl_click.track = grab.track_idx
			kf_dbl_click.clip = grab.clip_index
			kf_dbl_click.lane = grab.lane
			kf_dbl_click.frame = kf_frame
			// The same press that selects ALSO arms the horizontal move gesture
			// (S4). A drag is only distinguishable from a click at release, so
			// arming here with a capture at press + a release-time compare is the
			// honest shape: a click that never slides commits nothing (the
			// clip-stutter rule) and the capture is the pre-move snapshot
			// (undo_begin) for the live drag.
			//
			// The capture is the WHOLE selection, not just the grabbed key, so a
			// drag that starts on any key of a multi-key set slides every key in
			// it — which is the whole point of the multi-select (built by the
			// brush or by a Shift+click pair). The gesture itself only records
			// how far the cursor travels from press_frame; the keys themselves
			// are never written until the release (update_keyframe_drag paints
			// the preview, kf_move holds the only record of where they started).
			// An off-center grab therefore keeps its pivot for free: every key
			// translates by the cursor's own travel.
			//
			// So the capture has to happen whatever the press did to the selection
			// — when the grab was already selected, the run it captured IS the
			// payload, and narrowing it here is precisely the bug.
			if kok {
				kf_capture_sel(&kf_move.snaps)
				kf_move.delta = 0
				kf_move.engaged = false
				kf_move.narrow_click = narrow_click
				kf_move.press_x = inp.x
				// The anchor is the key the pointer is ON, not the first
				// captured one: a capture is ordered by the selection, and the
				// key the cursor grabbed is the one whose pivot the drag
				// expresses. The two differ whenever the press preserved a run
				// (the deferral above) or a brush built a set spanning two
				// clips — in both cases element zero can name a different clip than
				// the cursor, whose wrap box would then be the wrong zoom and pan.
				kf_move.anchor = grab
				box :=
					clay.GetElementData(clay.ID("TimelineClipWrap", u32(grab.track_idx * 1000 + grab.clip_index))).boundingBox
				kf_move.press_frame = (inp.x - box.x) / timeline_view.zoom
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
				kf_clear()

					if inp.shift {
					// Shift+click toggles the clip and its whole LINK GROUP into/out
					// of the multi-selection without dragging: a selection holding
					// one member of a linked pair is a selection no per-clip action
					// can honour.
					cid := track.clips[index].clip_id
					toggle_clip_selection(cid)
					// The anchor leads the selection set UNCONDITIONALLY, so a
					// deselected clip left as the anchor comes straight back into
					// every action's target set -- the click appeared to remove six
					// clips and then acted on one of them anyway. Anchor to the clip
					// only when it is actually selected, or to nothing.
					if cid in selection.extra_set {
						selection.track = track_idx
						selection.index = index
					} else {
						selection.track = -1
						selection.index = -1
					}
					return true
				}
				// A clip that is ALREADY part of the multi-selection keeps the whole
				// selection and drags it together; a clip outside the selection
				// becomes the sole selection. Either way a drag moves exactly what the
				// user can see is selected. Collapsing to one clip here is what made
				// a multi-selection undraggable: the press threw the rest of it away
				// before the drag had begun.
				cid := track.clips[index].clip_id
				in_selection := cid in selection.extra_set
				if !in_selection {
					// Keep the anchor in extra_set so the next Shift+click
					// preserves it when changing anchor.
					select_clip(track_idx, index)
				}
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
				// The drag set is the whole selection when the pressed clip belongs to
				// it, so a multi-selection drags as one; otherwise it is the clip's
				// own link group.
				if in_selection {
					capture_drag_orig(selection_targets())
				} else {
					capture_link_group(clip_move.clip, track_idx)
				}
					// Alt at PRESS latches the gesture as a ripple move: every
					// clip at or after the anchor shifts with it. Captured here,
					// before any frame of live movement, so the set is the
					// timeline as the user saw it when they grabbed the clip.
					clip_move.ripple = inp.alt
					if clip_move.ripple {
						capture_ripple_set(clip_move.clip, track_idx)
					}
					return true
				}
			}
		}
		return false
	},
	// A plain press on timeline space that holds no clip deselects every clip.
	//
	// This is the other half of the shift+click toggle: the toggle can only ever
	// remove the group you point at, so without an empty-space press there is no
	// way to clear a selection that has no clip under the pointer -- and "click
	// away from the selection" is the gesture every editor has for that.
	//
	// Shift is excluded so it falls through to the keyframe brush below, and
	// TrackArea excludes the ruler and the name gutter, which have their own
	// presses. It sits after the clip press, which is what makes "no clip under
	// the pointer" the condition.
	proc(inp: Mouse_Input) -> bool {
		if inp.shift {
			return false
		}
		if !clay.PointerOver(clay.ID("TrackArea")) {
			return false
		}
		clear_clip_selection()
		return true
	},
	// Shift+press on timeline area that holds no clip ARMS the keyframe brush:
	// from here, every keyframe the pointer passes over joins the selection, with
	// no button involved. This is the only way in, because a Shift+click on a
	// keyframe itself is a plain selection of that key.
	//
	// It sits AFTER the clip press on purpose. A press on a clip body is
	// Shift+click-to-add-a-clip-to-the-link-selection, and claiming it here
	// would break that; "no clip under the pointer" is what is left once every
	// earlier probe has declined. TrackArea excludes the ruler and the name
	// gutter, both of which have their own presses.
	proc(inp: Mouse_Input) -> bool {
		if !inp.shift || !clay.PointerOver(clay.ID("TrackArea")) {
			return false
		}
		kf_brush_arm()
		return true
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
		when ODIN_DEBUG {
			if vyper_trace {
				fmt.printf("[tl] reordered track storage=%d to row=%d\n", track_drag.idx, track_drag.hover_row)
			}
		}
	}
	active_interaction = .None
	track_drag.idx = -1
	track_drag.hover_row = -1
}

// drag_move_in_place advances the dragged clip (or whole linked group, or the
// whole Alt+drag ripple set) to `frame` on its source lane, clamped so it never
// overlaps a neighbor. Shared by the plain same-lane drag and the dwell frames
// of a potential vertical drop: a fast flick that skitters across a lane
// boundary must keep the clip glued to the cursor, so the horizontal follow
// can't live inside the hover==source branch alone.
drag_move_in_place :: proc(frame: f32) {
	if clip_move.clip == nil {
		return
	}
	if clip_move.ripple {
		// Ripple move: one shared delta for the whole captured set, measured
		// from the ANCHOR's original start so the grabbed clip's head stays
		// under the cursor exactly as a plain drag keeps it, and clamped to
		// the band every member can hold (see ripple_clamp_delta).
		want := i64(max(frame, 0)) - clip_move.ripple_orig[0].start
		clip_move.ripple_delta = ripple_clamp_delta(want)
		when ODIN_DEBUG {
			if vyper_trace {
				fmt.printf(
					"[tl] drag ripple clips=%d delta=%d (want %d)\n",
					len(clip_move.ripple_orig),
					clip_move.ripple_delta,
					want,
				)
			}
		}
		apply_ripple_drag(clip_move.ripple_delta)
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
				when ODIN_DEBUG {
					if vyper_trace {
						fmt.printf(
							"[tl] drag group link=%d (%d clips) delta=%d\n",
							clip_move.clip.link_id,
							len(clip_move.group_orig),
							delta,
						)
					}
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
			when ODIN_DEBUG {
				if vyper_trace {
					fmt.printf(
						"[tl] drag clip src=%s len=%d start=%d -> %d\n",
						clip_move.clip.path,
						clip_move.clip.source_length_frames,
						clip_move.clip.timeline_start_frame,
						new_start,
					)
				}
			}
			clip_move.clip.timeline_start_frame = new_start
		}
	}
}

// update_keyframe_drag follows the pointer while a Keyframe_Move drag is in
// flight (called every mouse-move while down, like the clip/gain updates).
//
// It is a PREVIEW, not a write: the whole gesture is the frame delta the cursor
// has travelled from the press, and draw_keyframes paints each selected key at
// its captured start plus that delta (kf_sel_frame). Nothing touches the store
// until the release, so the key arrays stay sorted and unique for the duration
// and the release's del + set is a real normalization instead of a repair of an
// array the drag had scrambled. That is what lets more than one key move
// together: with a live in-place write, a key that had already slid could no
// longer be told apart from one that had not. It also means the dragged curve
// cannot flicker in the preview, which re-reads the keys at the playhead.
//
// delta is recomputed from press_frame every tick rather than accumulated, so a
// long slide cannot drift, and it is rounded rather than truncated so a slow
// drag crosses frame boundaries at a half-frame instead of a whole one. The
// move only engages once the cursor travels KF_DRAG_THRESHOLD_PX from the press,
// so a click (even one landing off-center) never nudges a key.
update_keyframe_drag :: proc(mx: f32) {
	if len(kf_move.snaps) == 0 {
		return
	}
	if abs(mx - kf_move.press_x) < KF_DRAG_THRESHOLD_PX {
		return
	}
	// Latch the moment the gesture becomes a drag. The release needs this to tell
	// a click (narrow the selection) from a drag (move it), and delta alone can't:
	// a drag that ends where it started, or one that only pushes keys into a
	// clamp, leaves delta at or near zero.
	kf_move.engaged = true
	// The frame mapping comes from the GRABBED key's clip — the only one whose
	// box the press measured, and the one whose wrap the cursor is over. Read
	// kf_move.anchor, not snaps[0]: a Shift-union set spanning two clips is
	// ordered by the older selection, so snaps[0] can name a different clip and
	// would apply that clip's box to a cursor that never touched it.
	box := clay.GetElementData(clay.ID("TimelineClipWrap", u32(kf_move.anchor.track_idx * 1000 + kf_move.anchor.clip_index))).boundingBox
	if box.width <= 0 {
		return
	}
	cursor_frame := (mx - box.x) / timeline_view.zoom
	kf_move.delta = i32(math.round(cursor_frame - kf_move.press_frame))
}

// commit_keyframe_drag is the Keyframe_Move release path. Every selected key
// was previewed at start + delta during the gesture and the store was never
// written, so this is where the move actually lands, as ONE undo node (the press
// already ran undo_begin, so the pre-drag tree is pending) and only if some key
// actually moved. A no-move click reselects and nothing else — no reseek, no
// reset, no node. A drag that only pushed the outermost keys into their clip's
// clamped edge is a no-move too, which is why the compare is per key rather than
// on the delta alone.
//
// The move normalizes as a pure store pair per key, del(start) + set(final), so
// every array comes back sorted and unique from wherever the drag landed. ALL
// the deletes run before ANY of the sets: two keys on one lane can trade
// frames, and a set landing on a frame another key has not vacated yet is
// swallowed by kf_set_key's same-frame replace — that key would silently vanish
// instead of moving.
//
// Packed (section) keys re-land in the form they came from, not folded: their
// array payload is copied out into the capture before the del and re-landed
// through the packed producer, so a grouped crop/transform key drags as one
// unit. A packed section key's source track name must BE a section and no lane
// of it may exist (the mutual-exclusion invariant, asserted both ends to catch
// a drifted store).
commit_keyframe_drag :: proc() {
	if len(kf_move.snaps) == 0 {
		return
	}
	// A press that never slid is a CLICK, and the whole point of the deferral at
	// press is that this is the first frame that knows so: narrow to the key the
	// pointer actually grabbed, leaving a run alone until the user commits to
	// clicking. Resolved through the anchor rather than the capture, so a stale
	// or empty selection cannot make this a no-op that looks like it worked.
	if !kf_move.engaged {
		if kf_move.narrow_click {
			a := kf_move.anchor
			kf_select(a.track_idx, a.clip_index, a.lane, a.key)
		}
		return
	}
	// Resolve every destination BEFORE the first store op, both because the ops
	// slide the key arrays underneath us and because kf_moved_frame needs the
	// live clip lengths — and because the per-key compare is what decides
	// whether this was a move at all.
	moved := false
	for &s in kf_move.snaps {
		s.final = kf_moved_frame(s, kf_move.delta)
		if s.final != s.start {
			moved = true
		}
	}
	if !moved {
		// A press that never slid, or a drag that only pushed the outermost keys
		// into their clip's clamped edge: reselect and leave the store alone (the
		// clip-stutter rule). The selection is already what it was.
		return
	}
	// Phase 1: delete every key at its captured start frame. ALL deletes run
	// before ANY set (see the header).
	for s in kf_move.snaps {
		cl, ok := kf_clip_at(s.ref.track_idx, s.ref.clip_index)
		if !ok {
			continue
		}
		kf_del_key(cl, s.name, s.start)
	}
	// Phase 2: re-land each key at its destination, form-preserving.
	for s in kf_move.snaps {
		cl, ok := kf_clip_at(s.ref.track_idx, s.ref.clip_index)
		if !ok {
			continue
		}
		if s.mask != 0 {
			sec_idx, is_sec := kf_geom_section_index(s.name)
			assert(is_sec, "a packed section key drag must source a section track name")
			sdefs := kf_geom_sections
			for lane_prop in sdefs[sec_idx].lanes {
				assert(
					kf_track_index(cl^, kf_lane_name(lane_prop)) < 0,
					"a packed section and its lanes may not coexist during a drag re-land",
				)
			}
			kf_set_packed_key(cl, s.name, s.final, s.value, s.mask)
		} else {
			kf_geom_set_lane_key(cl, s.name, s.final, s.value[0])
		}
	}
	// Phase 3: re-stamp each key's easing and rebuild the selection, both under
	// the fresh structure gen. The insert path zero-initializes interp, so
	// without the re-stamp a slid key would quietly straighten back to the
	// .Cubic default. Looking the key up by name + landed frame is also how the
	// selection survives the store ops: the lane index can shift if a track
	// emptied and re-minted, and those ops bumped the gen, which invalidates the
	// selection as it stood.
	picked := make([dynamic]Kf_Ref)
	defer delete(picked)
	for s in kf_move.snaps {
		cl, ok := kf_clip_at(s.ref.track_idx, s.ref.clip_index)
		if !ok {
			continue
		}
		li := kf_track_index(cl^, s.name)
		if li < 0 {
			continue
		}
		trk := session_trk_view_mut(&cl.keyframe_tracks, li)
		session_kf_make_unique(&trk.keys)
		keys := &trk.keys
		for ki in 0 ..< keys.n {
			v := session_kf_view(keys^)
			if v[ki].frame_off == s.final {
				vm := session_kf_view_mut(keys^); vm[ki].interp = s.interp
				append(&picked, Kf_Ref{s.ref.track_idx, s.ref.clip_index, li, ki})
				break
			}
		}
	}
	if len(picked) > 0 {
		// Replacing rather than adding: the ops above bumped the gen, so the old
		// set is stale and must not be carried forward on top of the new one.
		kf_clear()
		kf_select_add(picked[:])
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
	// Locked while an export runs: the file on disk is being written from the
	// snapshot render_start committed, so an edit made now cannot reach it, and
	// the preview is showing that render's composed frame rather than the
	// timeline. Refusing at this one seam covers every editing entry point
	// without each one having to remember. interaction_release still runs, so a
	// gesture that started before the render commits and unwinds instead of
	// sticking in the .Drag state forever.
	if !render_is_busy() {
		interaction_click_dispatch(inp, prev_mouse_down)
		if inp.left {
			interaction_move(inp, prev_mouse_down, height)
		}
	}
	if !inp.left {
		interaction_release(inp)
	}
	was_click := inp.left && !prev_mouse_down
	interaction_jog_click(was_click)
	interaction_rate_click(was_click)
	interaction_encoder_click(was_click)
	interaction_interp_click(was_click)
	interaction_help_click(was_click)
	interaction_tabs_click(was_click)
	interaction_preview_fit_click(was_click)
	interaction_right_click(inp, prev_right_down, was_click)
	interaction_submenu_update(inp)
	update_timeline_cursor(inp.x, inp.y)
	// The returned state is just this frame's button levels: the locals the
	// previous revision seeded from prev_* were overwritten before use.
	return inp.left, inp.right
}
// Fresh-click chain: the element/probe table runs first, then the pane divider
// (press-and-hold drag), then the geometry/loop fallback probes. Each either
// fires a one-shot action or STARTS a gesture; none update live state.
interaction_click_dispatch :: proc(inp: Mouse_Input, prev_mouse_down: bool) {
if inp.left && !prev_mouse_down {
	// A press without Shift is the user saying something else, so it ends
	// hover-select. Central rather than per-handler because the brush is a mode,
	// not a gesture: every one of these presses would otherwise have to remember
	// to disarm it, and the one that forgot would leave the timeline silently
	// painting selections for the rest of the session.
	if !inp.shift {
		kf_brush_disarm()
	}
	if !dispatch_click_table(inp) {
		if clay.PointerOver(clay.ID("DividerHandle")) {
			active_interaction = .Panel_Resize
		} else {
			dispatch_click_fallback(inp)
		}
	}
}
}

// clip_move_drag_moved reports whether the gesture actually relocated anything.
// A press that never moved is a CLICK, not a drag, and the two mean different
// things for the selection: a click on a member of a multi-selection collapses
// the selection to that clip, a drag moves the whole set.
clip_move_drag_moved :: proc() -> bool {
	if clip_move.ripple {
		// The applied delta IS the change: a ripple that clamped to delta 0
		// moved nothing, and a vertical staging that ended on the source lane
		// moved nothing. Read it rather than the anchor's live start -- a
		// vertical drop has already relocated the anchor by the time this runs,
		// so its start no longer says anything about what the drag did.
		return clip_move.ripple_delta != 0 ||
			(clip_move.hover_track >= 0 && clip_move.hover_track != clip_move.source_track)
	}
	if len(clip_move.group_orig) > 1 {
		return clip_move.group_delta != 0 ||
			(clip_move.hover_track >= 0 &&
				clip_move.hover_track != clip_move.source_track &&
				order_row_of(clip_move.hover_track) != order_row_of(clip_move.source_track))
	}
	if len(clip_move.group_orig) > 0 && clip_move.clip != nil {
		return clip_move.clip.timeline_start_frame != clip_move.group_orig[0].start ||
			(clip_move.hover_track >= 0 && clip_move.hover_track != clip_move.source_track)
	}
	return false
}

// Release path: run the per-gesture commit, then drop the gesture payload.
// #partial because several gestures need no commit on release.
interaction_release :: proc(inp: Mouse_Input) {
	// Button lifted: run the per-gesture commit, then drop the payload.
	#partial switch active_interaction {
	case .Media_Bin_Drag:
		// Releasing a bin drag commits the media (creates tracks as
		// needed); releasing nowhere cancels it.
		end_media_drag(inp.x, inp.y)
	case .Track_Drag:
		end_track_drag()
	case .Clip_Move:
		moved := clip_move_drag_moved()
		// A press that never moved is a CLICK, not a drag. Clicking a clip that is
		// part of a multi-selection collapses the selection to that one clip, so the
		// next action (delete, split, rename) applies to the clip under the pointer
		// rather than to a selection the user may have forgotten was there. A drag
		// keeps the whole selection and moves it together -- the press already
		// captured the whole set for exactly that.
		if click_collapses_selection(moved) {
			select_clip(clip_move.source_track, clip_move.source_index)
		}
		// Commit a vertical drop if the ghost hovers another track;
		// horizontal drags already applied their new start live.
		if clip_move.hover_track != clip_move.source_track &&
		   clip_move.hover_track >= 0 &&
		   clip_move.source_track >= 0 {
			if drag_set_is_link_group() {
				// Vertical drop for a linked group is measured in VISUAL rows:
				// the group shifts by the number of stack rows between the
				// anchor's source track and the hovered lane, regardless of
				// storage order.
				delta_rows := order_row_of(clip_move.hover_track) - order_row_of(clip_move.source_track)
				move_linked_group(delta_rows)
			} else if len(clip_move.group_orig) > 1 {
				// A multi-selection of unrelated clips has no unit to move, so each
				// clip goes on its own. Re-resolved by id because every move shifts
				// the indices behind it, and each keeps its own start so the
				// selection's relative layout survives the drop.
				for orig in clip_move.group_orig {
					tr, c, ok := find_clip_by_id(orig.clip_id)
					if !ok {
						continue
					}
					move_clip_to_track(
						track_index_of(tr),
						clip_index_on_track(tr, c),
						clip_move.hover_track,
						orig.start,
					)
				}
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
			if moved {
				label := "Move clip"
				if clip_move.ripple {
					// Named apart from a plain move because it is a different
					// edit: the undo node covers every clip the ripple carried,
					// and "Move clip" on that node reads as though it undoes
					// one clip.
					label = "Ripple move"
				} else if len(clip_move.group_orig) > 1 {
					label = "Move clip(s)"
				}
				undo_push(.Move, label)
				// The drag applied live; this is the one commit the audio
				// engine gets for it. audio_note_edit (not a bare seek)
				// because the clip's new geometry must reach the producer's
				// slab before it re-provisions. See the .Playhead_Scrub
				// update for why the per-frame commit had to go.
				audio_note_edit()
			}
		}
	case .Clip_Stretch:
		// The speed was applied live on every move; this is the single commit, and
		// only if it actually moved. audio_note_edit (not a bare seek) because the
		// clip's LENGTH and every source's speed snapshot changed, which the seek
		// path does not rebuild.
		if clip_stretch.clip != nil && clip_stretch.moved {
			undo_push(.Transform, "Stretch clip")
			audio_note_edit()
		}
		clip_stretch.clip = nil
	case .Clip_Resize:
		// Resize is applied live during the drag; capture the gesture as one
		// undo node on release.
		if clip_resize.moved {
			label := "Resize clip"
			if clip_resize.edge == .Roll {
				label = "Roll clip seam"
			} else if len(clip_move.group_orig) > 1 {
				label = "Resize clip(s)"
			}
			undo_push(.Resize, label)
			// The drag applied live; this is the one commit the audio engine
			// gets for it. audio_note_edit (not a bare seek) because the
			// clip's new geometry must reach the producer's slab before it
			// re-provisions. See the .Playhead_Scrub update.
			audio_note_edit()
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
	case .Opacity_Drag:
		// Opacity is applied live during the drag; one value node on
		// release, and only if the gesture actually moved it. Compared at the
		// playhead, matching the value captured at gesture start — on a keyed
		// clip the resting field can sit still while the visible value moved.
		if opacity_drag.clip != nil &&
		   clip_geom_get(opacity_drag.clip, .Opacity) != opacity_drag.start_op {
			undo_push(.Value, "Set clip opacity")
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
	case .Playhead_Scrub:
		// The scrub moved the playhead live and committed nothing to the
		// audio engine; this is the commit. A press with no drag (the
		// common "click the ruler to set the position" case) moves nothing
		// and so re-provisions nothing.
		if playhead_scrub.moved {
			when ODIN_DEBUG {
				if play_trace {
					// The committed position, the position the engine's clock still names,
					// and the generation gap between them. The third is the one that matters:
					// audio_seek bumps resync, so until the producer adopts it dev_frame is
					// STALE by construction and describes where the sound was BEFORE the
					// scrub. If the playhead jumps forward after this line, that gap is why,
					// and it is visible here rather than inferred afterwards.
					fmt.printf(
						"[ui]  scrub RELEASE commit ph=%d (device still reads %d, %d generation behind)\n",
						playhead.frame,
						sync.atomic_load(&playback.dev_frame),
						sync.atomic_load(&audio_prod.resync) -
						sync.atomic_load(&playback.dev_resync),
					)
				}
			}
			audio_seek(playhead.frame)
		}
		sync.atomic_store(&audio_prod.scrub_active, false)
		playhead.playing = playhead_scrub.was_playing
		preview.playing = playhead_scrub.was_playing
		scrub_device_close()
	}
	active_interaction = .None
	playhead_scrub.moved = false
	handle_drag.handle = nil
	handle_drag.kind = .None
	handle_drag.corner_snapped = false
	clip_move.clip = nil
	gain_drag.clip = nil
	opacity_drag.clip = nil
	kf_move.press_x = 0
	kf_move.press_frame = 0
	kf_move.delta = 0
	kf_move.anchor = {}
	// Drop the captures, but keep the LIST's buffer: the gesture is re-armed on
	// the next diamond press and a realloc per drag is churn the ownership
	// rules forbid. The entries are NOT plain values though — each Kf_Snap owns
	// a cloned track name — so this is not a bare clear(). A bare clear() would
	// zero the rows and hand back the memory the names point at, losing one
	// track-name string per selected key per drag.
	kf_snaps_drop(&kf_move.snaps)
	clip_move.source_track = -1
	clip_move.source_index = -1
	clip_move.hover_track = -1
	clip_move.lane_dwell = 0
	clip_move.group_delta = 0
	clear(&clip_move.group_orig)
	clip_move.ripple = false
	clip_move.ripple_delta = 0
	clear(&clip_move.ripple_orig)
	clip_resize.edge = .None
	clip_resize.moved = false
	clip_resize.roll_track = -1
	clip_resize.roll_left_id = 0
	clip_resize.roll_right_id = 0
}

// Live move path, driven every frame while the button is held. Each case
// updates the in-flight gesture in place; release above is the single commit.
interaction_move :: proc(inp: Mouse_Input, prev_mouse_down: bool, height: c.int) {
	// The keyframe brush runs BEFORE the gesture switch, not as one of its
	// cases: it has no button to hold and no active_interaction to own, and it
	// keeps working across the presses that would otherwise replace that state.
	if kf_brush_armed {
		kf_brush_paint(inp.x, inp.y)
	}
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
			handle_drag_commit(sel)
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
				// Route the moved axes to wherever the clip READS them at the
				// playhead, so the motion lands on the timeline rather than in
				// a resting field the sampler ignores. Snap reads the resting
				// writes above, so those stay direct and the commit happens
				// once, after the snaps have had their say.
				clip_geom_drag(sel, .Trans_X, handle_drag.start_tx)
				clip_geom_drag(sel, .Trans_Y, handle_drag.start_ty)
			}
		}
	case .Clip_Stretch:
		if clip_stretch.clip != nil {
			c := clip_stretch.clip
			dx := inp.x - clip_stretch.start_x
			// Dragging an edge INWARD slows the clip and OUTWARD speeds it up, for
			// both edges. Direction comes from the edge so the gesture matches the
			// trim it replaces: dragging the right edge left means "show me less
			// time", which for a stretch means "play it slower".
			dir := f64(1.0)
			if clip_stretch.edge == .Right {
				dir = -1.0
			}
			want := clip_stretch.start_speed * (1.0 - dir * f64(dx) * CLIP_STRETCH_PCT_PER_PX / 100.0)
			want = clamp(want, CLIP_SPEED_MIN, CLIP_SPEED_MAX)
			if want != clip_speed(c) {
				c.speed = want
				// Hold the timeline span fixed, which is what makes this a stretch.
				c.source_length_frames = max(1, i64(f64(clip_stretch.timeline_len) * want))
				clip_stretch.moved = true
			}
			// No audio_note_edit() here, same reason as the resize gesture: it is a
			// full re-provision per frame. The release commits once.
		}
		clip_stretch.moved = false
	case .Clip_Resize:
		if selection.track >= 0 &&
		   selection.index >= 0 &&
		   selection.track < len(timeline.tracks) &&
		   selection.index < len(timeline.tracks[selection.track].clips) {
			track_start := clay.GetElementData(clay.ID("ClipsSection", 0)).boundingBox.x
			frame := max(f32(0), (inp.x - track_start) / timeline_view.zoom + timeline_view.start)
			// Clip→playhead toggle applies to trim and roll drags too.
			if editor_flags.snap_clips_to_playhead {
				frame = f32(snap_to_playhead(i64(frame)))
			}
			if clip_resize.edge == .Left {
				if len(clip_move.group_orig) > 0 {
					// Linked group: shift every member's head by the same delta.
					resize_group_left(&timeline.tracks[selection.track], selection.index, i64(frame))
				} else {
					resize_clip_left(&timeline.tracks[selection.track], selection.index, i64(frame))
				}
				clip_resize.moved = true
			} else if clip_resize.edge == .Right {
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
				clip_resize.moved = true
			} else if clip_resize.edge == .Roll &&
			          clip_resize.roll_track >= 0 &&
			          clip_resize.roll_track < len(timeline.tracks) {
				track := &timeline.tracks[clip_resize.roll_track]
				left := clip_index_by_id(track, clip_resize.roll_left_id)
				right := clip_index_by_id(track, clip_resize.roll_right_id)
				if left >= 0 && right == left+1 {
					old_seam := clip_timeline_end(track.clips[left])
					applied := resize_clip_seam(track, left, right, i64(frame))
					clip_resize.moved = clip_resize.moved || applied != old_seam
				}
			}
			// No audio_note_edit() here: it is a full re-provision per frame
			// of the drag. The release commits it once.
		}
	case .Opacity_Drag:
		// Written live against the captured rect, so the preview tracks
		// the pointer; the release below is the only undo commit.
		if opacity_drag.clip == nil {
			break
		}
		// clip_geom_set every move, like the geometry drag: on a keyed clip
		// this updates the key at the playhead in place, so the slider stays
		// live instead of writing a resting field the sampler ignores.
		clip_geom_set(opacity_drag.clip, .Opacity, opacity_from_x(inp.x))
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
			// The audio engine is told nothing per frame: audio_note_edit()
			// is a full re-provision, and a drag that asked for one per
			// frame queued re-provisions faster than the producer could
			// retire them. The release commits the moved clip once.
			drag_move_in_place(frame)
			// Stall tracer (VYPER_TRACE): logs the first frame where the
			// cursor's frame target advanced but the clip's start did not —
			// the exact moment a drag would be "cut short", with the lane/
			// pointer context that differs at that frame.
			when ODIN_DEBUG {
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
			when ODIN_DEBUG {
				if vyper_trace {
					fmt.printf(
						"[pb] scrub ph=%d (was %d) playing=%v\n",
						frame,
						playhead.frame,
						playhead.playing,
					)
				}
			}
		}
		if playhead.frame != frame {
			playhead_scrub.moved = true
		}
		was := playhead.frame
		playhead.frame = frame
		when ODIN_DEBUG {
			if play_trace {
				fmt.printf(
					"[ui]  pointer scrub -> ph=%d (was %d) x=%.1f dev=%d resync=%d\n",
					frame,
					was,
					inp.x,
					sync.atomic_load(&playback.dev_frame),
					sync.atomic_load(&audio_prod.resync),
				)
			}
		}
		// SEEK DURING THE DRAG, coalesced to a minimum interval.
		//
		// This used to seek only on release, and the comment above it said why: at
		// the time a seek was a full re-provision, so one per frame queued more work
		// than the producer could retire. That is no longer true -- audio_seek now
		// reconciles, keeping every decoder whose content position did not move -- but
		// the cost of a seek was never the real reason to wait, and the effect was:
		//
		// While playing, the producer keeps feeding from the anchor it last served, so
		// between the drag and the release the sound played from the OLD position while
		// the playhead sat where the pointer was. On release the clock was current and
		// ahead, and it adopted -- snapping the playhead forward to wherever the sound
		// had actually got to. Measured on the user's run: playhead pinned at 57 while
		// the device ran 63 -> 64 -> 65, then the release snapped it forward. That is
		// the "drag back while playing does nothing" symptom, and no guard on clock
		// adoption can fix it: the clock is RIGHT, the producer simply was never told
		// the playhead moved.
		//
		// One outstanding seek at a time, coalesced on ADOPTION rather than on a timer.
		//
		// Every seek asks the device to drop its queue, and audio_producer_feed holds
		// off feeding while a clear is pending -- so a request the producer has not
		// adopted yet does not make the audio track the pointer any better, it just
		// keeps the queue empty. Measured both ways:
		//
		//   40 ms timer: a fast drag outruns the audio. The playhead sat at 57 while
		//   the device was at 49 and the producer still anchored at 43 -- the sound
		//   lagged the pointer by however far you moved inside 40 ms.
		//   every pointer move, uncoalesced: three moves in one tick requested three
		//   clears, the producer reconciled once, and the device stayed frozen 142
		//   frames behind for the whole gesture.
		//
		// Gating on `resync == requested_resync` means "the producer has caught up with
		// my last request", which bounds it to exactly one outstanding seek and lets
		// the drag keep making progress.
		if frame != was && sync.atomic_load(&audio_prod.resync) == playhead_scrub.requested_resync {
			audio_seek(frame, false)
			playhead_scrub.requested_resync = sync.atomic_load(&audio_prod.resync)
		}
		// Published UNCONDITIONALLY, every move, where the coalesced seek above is
		// deliberately rate-limited. The producer aims at the playhead during a drag
		// and re-anchors itself when the playhead leaves it behind; if it only learned
		// the position through that coalesced seek, a fast drag would outrun it and the
		// audio would lag the pointer by whatever the coalescing dropped.
		sync.atomic_store(&audio_prod.scrub_playhead, frame)
		// Varispeed: the crossed frames play at the drag's rate. The device drains at
		// 1x, so at any other rate a fast drag leaves the audio behind and a slow drag
		// leaves it ahead -- the sound does not track the pointer. The drag's velocity
		// is the only clock a scrub has, so it is measured here and published.
		now := monotonic_ns()
		if playhead_scrub.last_ns != 0 {
			dt := f64(now - playhead_scrub.last_ns) / 1e9
			if dt > 0.0005 {
				vel := f64(frame - playhead_scrub.last_frame) / dt
				rate := vel / timeline_fps()
				// atempo is forward-only and needs a positive tempo, so a backward
				// drag plays the crossed content forward at the drag's rate. Clamped:
				// a near-zero rate stalls the graph, a huge one is not audible.
				if rate < 0 {
					rate = -rate
				}
				if rate < SCRUB_MIN_RATE {
					rate = SCRUB_MIN_RATE
				}
				if rate > SCRUB_MAX_RATE {
					rate = SCRUB_MAX_RATE
				}
				// Quantized to 0.1x steps. Raw pointer velocity jitters frame to
				// frame, and EVERY distinct rate rebuilds the atempo graph --
				// measured 485 rebuilds in one drag, each one blocking the
				// producer, which is the chopping. Quantizing to a few discrete
				// rates means the graph rebuilds only when the drag actually
				// crosses a step boundary. 0.1x steps keep the rate within 0.05x
				// of the drag: at 2.4x that is 2%, about half a frame of lead
				// over a second of dragging.
				// Smoothed and coarsely quantized. Raw pointer velocity slams between
				// the floor and the ceiling on every stop-start, and EVERY rate
				// change rebuilds the atempo graph: measured 810 rebuilds and 175%
				// of the drag lost or repeated in a single recording. The EMA damps
				// the stop-start slamming; 0.5x-step quantization means the graph
				// rebuilds only when the smoothed drag actually crosses a boundary.
				if playhead_scrub.smoothed_rate == 0 {
					playhead_scrub.smoothed_rate = rate
				} else {
					playhead_scrub.smoothed_rate =
						0.8 * playhead_scrub.smoothed_rate + 0.2 * rate
				}
				quantized := f64(i64(playhead_scrub.smoothed_rate * 2 + 0.5)) / 2.0
				if quantized < SCRUB_MIN_RATE {
					quantized = SCRUB_MIN_RATE
				}
				sync.atomic_store(&audio_prod.scrub_rate, quantized)
			}
		}
		playhead_scrub.last_frame = frame
		playhead_scrub.last_ns = now
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



interaction_jog_click :: proc(was_click: bool) {
// Jog controls: backward/forward around play (and h/l keys), handled
// independently of the chain above since they're distinct elements.
if was_click && clay.PointerOver(clay.ID("PlayBack")) {
	jog_playback(-1)
} else if was_click && clay.PointerOver(clay.ID("PlayFwd")) {
	jog_playback(1)
}
}

interaction_rate_click :: proc(was_click: bool) {
// Playback-rate dropdown: clicking the rate button toggles the menu;
// clicking a menu option selects that rate and closes it. Any other new
// click while open dismisses the menu without changing the rate.
rate_clicked := was_click && clay.PointerOver(clay.ID("PlayRateButton"))
if was_click {
	handle_playback_rate_click(rate_clicked)
}
}

interaction_encoder_click :: proc(was_click: bool) {
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
}

interaction_interp_click :: proc(was_click: bool) {
// Keyframe-interpolation dropdown: same toggle/select/dismiss shape, gated on a
// live keyframe selection (S3). Choosing a mode commits it on EVERY selected key
// — the segment arriving at a key eases (we ease INTO a breakpoint), and the
// mode is a property of the key rather than of its lane, so one pick covers a
// selection spanning any number of tracks, lanes and clips. One undoable edit
// for the whole set; an unchanged re-click only closes the menu.
if was_click && kf_sel_active() {
	if clay.PointerOver(clay.ID("KfInterpButton")) {
		kf_view.interp_menu_open = !kf_view.interp_menu_open
	} else if kf_view.interp_menu_open && clay.PointerOver(clay.ID("KfInterpMenu")) {
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
			kf_set_interp_all(choice)
			kf_view.interp_menu_open = false
		}
	} else if kf_view.interp_menu_open {
		kf_view.interp_menu_open = false
	}
}
}

interaction_help_click :: proc(was_click: bool) {
// Help overlay: the "?" button toggles it; any other click outside the
// panel dismisses it.
if was_click {
	if clay.PointerOver(clay.ID("HelpButton")) {
		editor_flags.help_open = !editor_flags.help_open
	} else if editor_flags.help_open && !clay.PointerOver(clay.ID("HelpPanel")) {
		editor_flags.help_open = false
	}
}
}

interaction_tabs_click :: proc(was_click: bool) {
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
}

interaction_preview_fit_click :: proc(was_click: bool) {
// Preview fit toggle: re-arming it snaps the camera to the contain-fit;
// panning/zooming already cleared it (interaction_pre_build / event).
if was_click && clay.PointerOver(clay.ID("PreviewFitButton")) {
	preview_cam.fit_to_window = !preview_cam.fit_to_window
	if preview_cam.fit_to_window {
		preview_fit_reset()
	}
}
}

interaction_right_click :: proc(inp: Mouse_Input, prev_right_down, was_click: bool) {
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
}

interaction_submenu_update :: proc(inp: Mouse_Input) {
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
}
