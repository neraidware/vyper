package main

import "core:c"
import clay "clay-odin"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// OS file drag-and-drop: files dragged in from the desktop / file manager.
//
// SDL hands the gesture over as BEGIN -> (POSITION)* -> FILE+ -> COMPLETE.
//
// What shapes this design is that NO backend reveals a dragged file's NAME
// before the user lets go -- X11, Wayland and Windows all report only "a drag
// is over this window" until the drop itself. So there is no asset to preview
// from before the release, and the per-stream ghost lanes a bin drag paints
// cannot exist here: at BEGIN the document does not know what is coming. The
// highlight therefore shows the ZONE (bin vs timeline) and nothing more, and
// the placement itself runs through add_asset_to_timeline -- the exact call
// end_media_drag makes -- so a file dropped on the timeline places identically
// to the same file dragged out of the bin, by construction rather than by two
// paths agreeing today.
//
// Targets:
//   - media bin  -> import into the bin only (the user drags it out later)
//   - timeline   -> import into the bin AND place on the hovered lane
//   - anywhere else -> refused, silently (see drop_file_at)
// ---------------------------------------------------------------------------

// Drop_Zone is what a point over the window means for dropped files.
Drop_Zone :: enum {
	None,      // neither target: dropped files are refused
	Media_Bin, // the bin panel: import, no timeline change
	Timeline,  // a lane a drop could occupy: import and place
}

// File_Drag is the in-flight OS drag. has_position records whether the backend
// ever sent DROP_POSITION: the Wayland xdg-foreign path can go straight from
// BEGIN to FILE, and then the live mouse position is the only point there is.
File_Drag :: struct {
	active:       bool,
	has_position: bool,
	mx, my:       f32,
	zone:         Drop_Zone,
}
file_drag: File_Drag

// file_drag_point returns where a release would land. The last DROP_POSITION
// wins when there is one -- it is the backend's own report of "the pointer is
// over this window" -- and the live mouse state is the fallback for a backend
// that never sends one.
file_drag_point :: proc() -> (f32, f32) {
	if file_drag.has_position {
		return file_drag.mx, file_drag.my
	}
	mx, my: f32
	_ = sdl.GetMouseState(&mx, &my)
	return mx, my
}

// drop_box_hit reports whether (mx, my) is inside box. Half-open on the far
// edges: the point ON a box's right or bottom edge belongs to the neighbour, so
// a drop at a panel seam does not land in two zones.
//
// That half-openness is also what makes an element clay has not laid out yet a
// non-target: such a box is zeroed, and `mx >= x && mx < x + 0` is unsatisfiable
// for every mx, so a degenerate box rejects itself without a special case. That
// matters because a drop can arrive in the frame before the first build_page,
// when every element still reports zero geometry.
drop_box_hit :: proc(mx, my: f32, box: clay.BoundingBox) -> bool {
	return mx >= box.x &&
	       mx < box.x + box.width &&
	       my >= box.y &&
	       my < box.y + box.height
}

// media_bin_box is the panel that accepts files for import, read from last
// frame's layout -- the same one-frame-old geometry every other pointer hit
// test in the app reads (interaction_pre_build works the same way).
media_bin_box :: proc() -> clay.BoundingBox {
	return clay.GetElementData(clay.ID("MediaBin")).boundingBox
}

// timeline_zone_box is which rectangle to PAINT for a timeline drop. Validity
// is never decided here -- timeline_drop_target owns that -- this only picks the
// region to outline. Which element that is follows the same two states the
// resolver has: with tracks, the lane area; with none, the empty-timeline
// panel, which is the whole timeline body in that state (TrackArea is never
// laid out, so a highlight sized from it would cover nothing).
timeline_zone_box :: proc() -> clay.BoundingBox {
	id := clay.ID("EmptyTimeline")
	if len(timeline.tracks) > 0 {
		id = clay.ID("TrackArea")
	}
	return clay.GetElementData(id).boundingBox
}

// drop_zone_at resolves a point against the live layout: the bin imports, a
// valid lane places, everything else refuses.
//
// The lane test is timeline_drop_target, the SAME resolution a bin drag
// releases through -- not a bounding box of the timeline panel. That is the
// whole reason it is not one: the panel's box and the lanes' region disagree
// in both directions. With no tracks at all the panel IS the empty-timeline
// box and the lanes region does not exist, so a box test refused a drop on the
// empty timeline that the bin drag accepts. And beside a short ruler the panel
// is wider than the lanes, so a box test would accept a drop the resolver
// cancels. Asking the resolver keeps "dropped on the timeline" and "dragged out
// of the bin" on one rule instead of two that can disagree about where the
// timeline starts.
drop_zone_at :: proc(mx, my: f32) -> Drop_Zone {
	if drop_box_hit(mx, my, media_bin_box()) {
		return .Media_Bin
	}
	if timeline_drop_target(mx, my) >= 0 {
		return .Timeline
	}
	return .None
}

// refresh_file_drag re-resolves the highlighted zone once a frame. The target
// depends on layout as much as on the pointer -- panels resize, tracks scroll,
// the bin can be collapsed to its tabs -- so a zone cached from the last
// DROP_POSITION would light up a stale box. The stored position is left alone:
// on a backend that sends positions it stays authoritative, and on one that
// does not, the fallback in file_drag_point reads the live mouse anyway.
refresh_file_drag :: proc() {
	if !file_drag.active {
		return
	}
	mx, my := file_drag_point()
	file_drag.zone = drop_zone_at(mx, my)
}

// drop_file_at is the commit for one dropped file at one point.
drop_file_at :: proc(path: cstring, mx, my: f32) {
	if path == nil {
		return
	}
	switch drop_zone_at(mx, my) {
	case .Media_Bin:
		import_path_to_bin(path)
	case .Timeline:
		// These two calls ARE end_media_drag's commit, in the same order:
		// import into the bin, then place every stream on the hovered lane at
		// the pointer's frame. Sharing them is the whole point -- a second
		// placement path here would drift from the bin's the first time
		// either gained an alignment rule.
		if asset_id := import_path_to_bin(path); asset_id != 0 {
			add_asset_to_timeline(asset_id, timeline_drop_target(mx, my), timeline_frame_from_x(mx))
		}
	case .None:
		// Refused over neither target, and silently. The pointer already says
		// where the user aimed, and a notice per release would nag on every
		// drag that merely passes over dead space.
	}
}

// handle_file_drop_event consumes the SDL drop half of the event stream.
// DROP_TEXT is routed here too, and dropped on purpose: dragging a text
// selection out of another application means nothing to an editor, and
// importing the clipboard's text as a path would be worse than doing nothing.
handle_file_drop_event :: proc(event: sdl.Event) {
	// #partial: SDL's event type is an open set, and this proc only ever sees
	// the five drop kinds routed to it by handle_sdl_events.
	#partial switch event.type {
	case .DROP_BEGIN:
		file_drag.active = true
		file_drag.has_position = false
		file_drag.zone = .None
	case .DROP_POSITION:
		file_drag.active = true
		file_drag.has_position = true
		file_drag.mx = event.drop.x
		file_drag.my = event.drop.y
		file_drag.zone = drop_zone_at(event.drop.x, event.drop.y)
	case .DROP_FILE:
		mx, my := file_drag_point()
		drop_file_at(event.drop.data, mx, my)
		// SDL owns `data`: it is a buffer SDL allocated for this one event and
		// the bin clones whatever it keeps, so releasing it here is the only
		// owner that can -- skip it and every dropped file leaks.
		sdl.free(rawptr(event.drop.data))
	case .DROP_COMPLETE:
		file_drag = {}
	case .DROP_TEXT:
		// Intentionally nothing (see above).
	}
}

// draw_file_drag_highlight paints the region that would take the files while a
// desktop drag is over the window. Nothing is drawn for .None: the pointer is
// already over a region that refuses, and a "no entry" flash on every pass
// across dead space is noise, not feedback.
draw_file_drag_highlight :: proc(
	renderer: ^GPU_Renderer,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass: ^sdl.GPURenderPass,
) {
	if !file_drag.active {
		return
	}
	box: clay.BoundingBox
	label: string
	switch file_drag.zone {
	case .Media_Bin:
		box = media_bin_box()
		label = "Drop to import"
	case .Timeline:
		box = timeline_zone_box()
		label = "Drop to place"
	case .None:
		return
	}
	render_sdf_rect(renderer, command_buffer, pass, box, DROP_ZONE_TINT, RADIUS_PANEL, 0)
	render_sdf_rect(renderer, command_buffer, pass, box, SELECT_BORDER, RADIUS_PANEL, DROP_ZONE_EDGE_W)

	label_box := clay.BoundingBox {
		x      = box.x + box.width / 2 - DROP_ZONE_LABEL_W / 2,
		y      = box.y + box.height / 2 - f32(FONT_NORMAL) / 2,
		width  = DROP_ZONE_LABEL_W,
		height = f32(FONT_NORMAL),
	}
	render_text(
		renderer,
		command_buffer,
		pass,
		label_box,
		clay.TextRenderData {
			stringContents = clay.StringSlice {
				length = c.int32_t(len(label)),
				chars  = ([^]c.char)(raw_data(label)),
			},
			textColor     = TEXT,
			fontSize      = FONT_NORMAL,
			letterSpacing = 1,
			lineHeight    = FONT_NORMAL,
		},
	)
}