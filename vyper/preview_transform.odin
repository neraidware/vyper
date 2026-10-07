package vyper

import clay "clay-odin"
import "core:c"

// ---------------------------------------------------------------------------
// Preview camera and clip transform math: project<->pixel conversions, camera
// pan/zoom clamping, edge snapping, and the resize/crop handle drag logic.
// ---------------------------------------------------------------------------

preview_canvas :: proc(bounds: clay.BoundingBox) -> clay.BoundingBox {
	pw := f32(project.width)
	ph := f32(project.height)
	if pw <= 0 || ph <= 0 {
		pw = f32(PREVIEW_W)
		ph = f32(PREVIEW_H)
	}
	scale: f32
	if bounds.width > 0 && bounds.height > 0 {
		scale = min(bounds.width / pw, bounds.height / ph)
	} else {
		scale = 1
	}
	w := pw * scale
	h := ph * scale
	return {
		x = bounds.x + (bounds.width - w) / 2,
		y = bounds.y + (bounds.height - h) / 2,
		width = w,
		height = h,
	}
}

// preview_fit_reset snaps the camera to the contain-fit of the canvas in the
// panel: zoom 1, no pan. preview_view then renders exactly preview_canvas, so
// the whole frame is visible. Called when the fit toggle is re-armed.
preview_fit_reset :: proc() {
	preview_cam.zoom = 1.0
	preview_cam.ox = 0
	preview_cam.oy = 0
}

// clamp_preview_camera keeps the zoom in range and the pan inside the
// image-viewer bound: the canvas's on-screen edge may reach the panel edge,
// never cross it. That single rule carries both properties the user wants --
// the view roams freely into the workspace around the canvas (fully past it,
// at the limit), and the canvas can't be lost, because its edge stays pinned
// to the panel. The range grows with zoom: the canvas edge has to travel
// ~zoom*axis/2 before it reaches the panel edge, so bigger zoom = more room,
// and at zoom 1 the canvas still overlaps the panel. A fixed clamp (the old
// "one canvas axis from the origin") was the drift: correct at zoom 1, it
// became an arbitrary wall the moment the view outgrew the window.
clamp_preview_camera :: proc(canvas: clay.BoundingBox) {
	// While the fit toggle is armed, the camera is defined to be the contain-fit
	// every frame. The pan/zoom handlers clear the flag before touching the
	// camera, so this enforcement only re-asserts the fit (e.g. after a resize)
	// -- it never fights a user's pan.
	if preview_cam.fit_to_window {
		preview_fit_reset()
	}
	preview_cam.zoom = clamp(preview_cam.zoom, PREVIEW_CAM_MIN_ZOOM, PREVIEW_CAM_MAX_ZOOM)
	panel := clay.GetElementData(clay.ID("Preview")).boundingBox
	px := panel.width
	py := panel.height
	if px <= 0 {
		px = canvas.width
	}
	if py <= 0 {
		py = canvas.height
	}
	preview_cam.ox = clamp(preview_cam.ox, -(canvas.width * preview_cam.zoom + px) / 2, (canvas.width * preview_cam.zoom + px) / 2)
	preview_cam.oy = clamp(preview_cam.oy, -(canvas.height * preview_cam.zoom + py) / 2, (canvas.height * preview_cam.zoom + py) / 2)
}

// preview_view applies the camera (pan + zoom, centered on the base canvas) to
// produce the on-screen canvas rect used for drawing and hit-testing.
preview_view :: proc(canvas: clay.BoundingBox) -> clay.BoundingBox {
	clamp_preview_camera(canvas)
	w := canvas.width * preview_cam.zoom
	h := canvas.height * preview_cam.zoom
	cx := canvas.x + canvas.width / 2 + preview_cam.ox
	cy := canvas.y + canvas.height / 2 + preview_cam.oy
	return {x = cx - w / 2, y = cy - h / 2, width = w, height = h}
}

// project_to_pixel converts a point in project-resolution coordinates to pixels
// within the (camera-transformed) canvas rect.
project_to_pixel :: proc(canvas: clay.BoundingBox, px, py: f32) -> (f32, f32) {
	v := preview_view(canvas)
	cx := v.x + (px / f32(project.width)) * v.width
	cy := v.y + (py / f32(project.height)) * v.height
	return cx, cy
}

// pixel_to_project converts a pixel position within the (camera-transformed)
// canvas rect back to project-resolution coordinates, clamped to the project
// bounds.
pixel_to_project :: proc(canvas: clay.BoundingBox, x, y: f32) -> (f32, f32) {
	v := preview_view(canvas)
	px := (x - v.x) / v.width * f32(project.width)
	py := (y - v.y) / v.height * f32(project.height)
	px = clamp(px, 0, f32(project.width))
	py = clamp(py, 0, f32(project.height))
	return px, py
}

// pixel_to_project_unclamped is pixel_to_project without the clamp, used for
// handle-drag math that must permit the pointer to leave the project bounds.
pixel_to_project_unclamped :: proc(canvas: clay.BoundingBox, x, y: f32) -> (f32, f32) {
	v := preview_view(canvas)
	px := (x - v.x) / v.width * f32(project.width)
	py := (y - v.y) / v.height * f32(project.height)
	return px, py
}

// snap_margin converts a desired snap margin in rendered (preview) pixels into
// project-resolution units for the current viewport scale.
snap_margin :: proc(canvas: clay.BoundingBox, preview_px: f32) -> f32 {
	v := preview_view(canvas)
	if v.width <= 0 || v.height <= 0 {
		return preview_px
	}
	return preview_px * f32(project.width) / v.width
}

// clip_full_box_dims is full_box_dims (project_geom.odin) with the live canvas
// size filled in. The wrapper is not redundant indirection: the export
// compositor cannot do this, because it runs on a worker thread against a
// Render_Job snapshot and must not read the `project` globals at all. The
// preview is the interactive side and legitimately reads live state.
clip_full_box_dims :: proc(clip: ^Clip, scale: f32) -> (f32, f32) {
	return full_box_dims(
		clip.source_w,
		clip.source_h,
		scale,
		f32(project.width),
		f32(project.height),
	)
}

// snap_transform snaps the clip's visible (cropped) box edges to the project
// canvas borders when they come within the given margin (project units). Force
// insets are normalized, so the visible half-extent from the center is
// (0.5 - crop) * (source axis) * scale. The full box is the source-sized box
// (see clip_full_box_dims), so snapping matches the box the user actually sees.
snap_transform :: proc(clip: ^Clip, margin: f32) {
	PW := f32(project.width)
	PH := f32(project.height)
	// Text clips use a top-left transform anchor (no crop) and scale BOTH axes
	// by a single uniform factor (source px -> project px via PW/PREVIEW_W), so
	// the box is anchored at the transform and the usual center-anchored
	// crop-aware math doesn't apply. Snap its four edges to the canvas borders.
	if clip.kind == .Text {
		if clip.source_w <= 0 || clip.source_h <= 0 {
			return
		}
		f := clip.scale * PW / f32(PREVIEW_W)
		w := f32(clip.source_w) * f
		h := f32(clip.source_h) * f
		// Half-extents from the CENTER, matching the video branch below: it
		// snaps the center to +d_l / PW-d_r, and this branch was writing raw
		// top-left values (0, PW-w) into a field that is now a center. The
		// geometry is the same either way -- only the anchor moved.
		d_l := w / 2
		d_r := w / 2
		d_t := h / 2
		d_b := h / 2
		left := clip.transform_x - d_l
		right := clip.transform_x + d_r
		top := clip.transform_y - d_t
		bottom := clip.transform_y + d_b
		if abs(left) <= margin {
			clip.transform_x = d_l
		} else if abs(right - PW) <= margin {
			clip.transform_x = PW - d_r
		}
		if abs(top) <= margin {
			clip.transform_y = d_t
		} else if abs(bottom - PH) <= margin {
			clip.transform_y = PH - d_b
		}
		return
	}
	cw, ch := clip_full_box_dims(clip, clip.scale)
	d_l := (0.5 - clip.crop_l) * cw
	d_r := (0.5 - clip.crop_r) * cw
	left := clip.transform_x - d_l
	right := clip.transform_x + d_r
	// Left edge to x=0, otherwise right edge to x=project.width.
	if abs(left) <= margin {
		clip.transform_x = d_l
	} else if abs(right - PW) <= margin {
		clip.transform_x = PW - d_r
	}
	d_t := (0.5 - clip.crop_t) * ch
	d_b := (0.5 - clip.crop_b) * ch
	top := clip.transform_y - d_t
	bottom := clip.transform_y + d_b
	// Top edge to y=0, otherwise bottom edge to y=project.height.
	if abs(top) <= margin {
		clip.transform_y = d_t
	} else if abs(bottom - PH) <= margin {
		clip.transform_y = PH - d_b
	}
}

// snap_center snaps a dragged/scaled clip so its visible box center lands on
// the project canvas center when it comes within the given margin (project
// units), mirroring the per-axis margin semantics of snap_transform. Active
// only while editor_flags.snap_center_to_canvas is on; returns whether the clip snapped.
snap_center :: proc(clip: ^Clip, margin: f32) -> bool {
	if !editor_flags.snap_center_to_canvas {
		return false
	}
	PW := f32(project.width)
	PH := f32(project.height)
	if clip.kind == .Text {
		if clip.source_w <= 0 || clip.source_h <= 0 {
			return false
		}
		f := clip.scale * PW / f32(PREVIEW_W)
		w := f32(clip.source_w) * f
		h := f32(clip.source_h) * f
		cx := clip.transform_x + w / 2
		cy := clip.transform_y + h / 2
		snapped := false
		if abs(cx - PW / 2) <= margin {
			clip.transform_x = PW / 2 - w / 2
			snapped = true
		}
		if abs(cy - PH / 2) <= margin {
			clip.transform_y = PH / 2 - h / 2
			snapped = true
		}
		return snapped
	}
	cw, ch := clip_full_box_dims(clip, clip.scale)
	cx := clip.transform_x + (clip.crop_l - clip.crop_r) * cw / 2
	cy := clip.transform_y + (clip.crop_t - clip.crop_b) * ch / 2
	snapped := false
	if abs(cx - PW / 2) <= margin {
		clip.transform_x = PW / 2 - (clip.crop_l - clip.crop_r) * cw / 2
		snapped = true
	}
	if abs(cy - PH / 2) <= margin {
		clip.transform_y = PH / 2 - (clip.crop_t - clip.crop_b) * ch / 2
		snapped = true
	}
	return snapped
}

// handle_center_pivot_scale returns the scale factor for a handle drag pivoted
// about the box center (Shift held): the dragged edge/corner tracks the pointer
// while the whole box grows/shrinks about its center, so both sides move
// together instead of pinning the opposite edge. bw/bh are the box dimensions
// in whatever units the caller uses (visible box for video, base text size for
// text); for video the return is a multiplier on scale0, for text (where the
// units are the scale=1 base size) it is already the absolute target scale.
handle_center_pivot_scale :: proc(handle: Handle, cx, cy, pmx, pmy, bw, bh: f32) -> f32 {
	half_w := max(bw / 2, 0.0001)
	half_h := max(bh / 2, 0.0001)
	switch handle {
	case .T: // top
		return (cy - pmy) / half_h
	case .B: // bottom
		return (pmy - cy) / half_h
	case .L: // left
		return (cx - pmx) / half_w
	case .R: // right
		return (pmx - cx) / half_w
	case .TL, .TR, .BR, .BL:
		kx := (pmx - cx) / half_w
		ky := (pmy - cy) / half_h
		// Corner: keep the aspect lock via the dominant axis, same rule as the
		// opposite-pivot path.
		if abs(pmy - cy) / half_h > abs(pmx - cx) / half_w {
			return ky
		}
		return kx
	}
	unreachable()
}

// corner_snap_both snaps a dragged corner so BOTH of its edges land on the
// canvas borders at once when the corner comes within the margin of the canvas
// corner on both axes. Aspect-locked scaling tracks the dominant axis only, so
// a source whose aspect differs from the canvas otherwise leaves the
// perpendicular edge beyond the margin and just one side snaps; this brings the
// box corner flush against the canvas corner (a side and the ceiling/floor
// together). Returns the transform delta and whether it snapped.
corner_snap_both :: proc(
	handle: Handle,
	left, right, top, bottom, margin, pw, ph: f32,
) -> (tx_delta, ty_delta: f32, snapped: bool) {
	switch handle {
	case .TL: // TL corner -> canvas (0,0)
		if abs(left) <= margin && abs(top) <= margin {
			return -left, -top, true
		}
	case .TR: // TR corner -> canvas (pw,0)
		if abs(right - pw) <= margin && abs(top) <= margin {
			return pw - right, -top, true
		}
	case .BR: // BR corner -> canvas (pw,ph)
		if abs(right - pw) <= margin && abs(bottom - ph) <= margin {
			return pw - right, ph - bottom, true
		}
	case .BL: // BL corner -> canvas (0,ph)
		if abs(left) <= margin && abs(bottom - ph) <= margin {
			return -left, ph - bottom, true
		}
	case .T, .B, .L, .R:
		assert(false, "corner_snap_both: edge handle reached a corner-only snap")
	}
	return 0, 0, false
}

// corner_snap_scale snaps the box so the driven corner lands flush on the
// canvas corner with an EXACT scale, not a rigid translate. corner_snap_both
// nudges the transform by the residual gap, which leaves the scale pointer-
// ballistic and shifts the pinned opposite corner on BOTH axes. This solves the
// scale about the pinned corner so the driven edge lands exactly on its flush
// target along the DOMINANT axis (the driven edge farther from flush), then
// closes only the perpendicular residual with a bounded translate (≤ margin).
// For an aspect-matched box the perpendicular residual is ~0, so the snap is
// perfectly scale-exact about a stationary pinned corner. All geometry (box
// edges in project units) is computed the same way as snap_driven_handle.
corner_snap_scale :: proc(
	clip: ^Clip,
	handle: Handle,
	s, tx, ty, l, r, t, b, margin, pw, ph: f32,
) -> (s_out, tx_out, ty_out: f32, snapped: bool) {
	s_out = s
	tx_out = tx
	ty_out = ty
	dx, dy, txg, tyg, px, py: f32
	switch handle {
	case .TL: // TL driven corner -> canvas (0,0), pinned BR
		dx, dy, txg, tyg, px, py = l, t, 0.0, 0.0, r, b
	case .TR: // TR -> canvas (pw,0), pinned BL
		dx, dy, txg, tyg, px, py = r, t, pw, 0.0, l, b
	case .BR: // BR -> canvas (pw,ph), pinned TL
		dx, dy, txg, tyg, px, py = r, b, pw, ph, l, t
	case .BL: // BL -> canvas (0,ph), pinned TR
		dx, dy, txg, tyg, px, py = l, b, 0.0, ph, r, t
	case .T, .B, .L, .R:
		assert(false, "corner_snap_scale: edge handle reached a corner-only snap")
	}
	// The scale solves to (target - pinned) / (driven - pinned); a zero-size box
	// would divide by zero here. The drag caller clamps scale to [0.05, 100] and
	// crop keeps the visible box >= one pixel, so the driven and pinned edges
	// are never equal on either axis.
	assert(dx - px != 0 && dy - py != 0, "corner_snap_scale: degenerate zero-size box")
	gx := abs(dx - txg)
	gy := abs(dy - tyg)
	if gx > margin || gy > margin {
		return
	}
	// Scale about the pinned corner to land the driven edge on its flush
	// target: new = pinned + (driven - pinned) * k, so k = (target - pinned) /
	// (driven - pinned) per axis. An aspect-locked box can only land one edge
	// exactly, so the axis whose driven edge is farther from flush wins.
	kx := (txg - px) / (dx - px)
	ky := (tyg - py) / (dy - py)
	k := kx
	if gy > gx {
		k = ky
	}
	s_out = s * k
	// Reanchor the transform on the pinned corner at the new scale.
	cw2, ch2 := clip_full_box_dims(clip, s_out)
	dl2 := (0.5 - clip.crop_l) * cw2
	dr2 := (0.5 - clip.crop_r) * cw2
	dt2 := (0.5 - clip.crop_t) * ch2
	db2 := (0.5 - clip.crop_b) * ch2
	switch handle {
	case .TL: // keep pinned BR fixed
		tx_out = r - dr2
		ty_out = b - db2
	case .TR: // keep pinned BL fixed
		tx_out = l + dl2
		ty_out = b - db2
	case .BR: // keep pinned TL fixed
		tx_out = l + dl2
		ty_out = t + dt2
	case .BL: // keep pinned TR fixed
		tx_out = r - dr2
		ty_out = t + dt2
	case .T, .B, .L, .R:
		assert(false, "corner_snap_scale: edge handle reached reanchor")
	}
	// Close only the perpendicular residual (bounded by the margin) so the
	// corner sits flush on both edges; the pinned corner rides at most that
	// single-axis residual. The scaled (dominant) axis keeps its exact flush.
	l2 := tx_out - dl2
	t2 := ty_out - dt2
	resx: f32
	resy: f32
	switch handle {
	case .TL:
		resx = -l2
		resy = -t2
	case .TR:
		resx = pw - (tx_out + dr2)
		resy = -t2
	case .BR:
		resx = pw - (tx_out + dr2)
		resy = ph - (ty_out + db2)
	case .BL:
		resx = -l2
		resy = ph - (ty_out + db2)
	case .T, .B, .L, .R:
		assert(false, "corner_snap_scale: edge handle reached residual")
	}
	if gx > gy {
		if abs(resy) <= margin {
			ty_out += resy
		}
	} else {
		if abs(resx) <= margin {
			tx_out += resx
		}
	}
	return s_out, tx_out, ty_out, abs(gx) <= margin && abs(gy) <= margin
}

// clip_image_bounds returns the pixel-space rect the clip occupies in the
// preview: the crop-adjusted (visible) box. Crop insets are normalized
// fractions (0..1) of the scale box, so the visible box is the scale box
// anchored at its top-left corner and trimmed by the per-edge crop insets. The
// opposite edge stays fixed when cropping a single edge (crop is per-edge, not
// centered). The cropped source fills it, so it matches the output.
//
// Every input is read with clip_geom_get, never off the resting fields, for the
// reason clip_zoom_by documents: on a clip whose geometry is keyed
// the resting fields are not what the preview is drawing. The image itself is
// drawn from the sampled preview slot, so a bounds box computed from resting
// state disagrees with the pixels inside it — and this box is what the
// selection border, the handles, and the hit-test all use, so the visible
// result is a handle that does not sit on the image it is attached to.
clip_image_bounds :: proc(canvas: clay.BoundingBox, clip: ^Clip) -> clay.BoundingBox {
	geom: Geom_Sample
	for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
		geom[pi] = clip_geom_get(clip, Render_Geom_Prop(pi))
	}
	return clip_image_bounds_geom(canvas, clip.kind, geom, clip.source_w, clip.source_h)
}

// clip_image_bounds_geom is clip_image_bounds over already-EVALUATED geometry.
// The preview draw pass has the values in its slot latch (the live clip may
// have been edited since), and taking them directly is what lets it draw the
// box for the pixels it is drawing; the alternative was rebuilding a
// throwaway Clip from the latch, a hand-copied property list that a new
// Render_Geom_Prop would have to be added to separately.
clip_image_bounds_geom :: proc(
	canvas: clay.BoundingBox,
	kind: Media_Kind,
	geom: Geom_Sample,
	source_w, source_h: c.int,
) -> clay.BoundingBox {
	v := preview_view(canvas)
	// A text clip is not a full-canvas image: its bounds are exactly the text
	// extent. The text was rasterized into a buffer at tight text-pixel
	// dimensions (clip.source_w x source_h are TEXT pixels, not project units),
	// which must map to screen with ONE uniform scale so the title never gets
	// squished (an aspect probe through project resolution would scale x and y
	// differently for any project that isn't 16:9).
	//
	// transform_x/y is the text's CENTER, exactly as it is for video and for
	// subtitles. It used to be the text's top-left, which made text the one
	// source whose two transform fields meant something its siblings' did not --
	// so a keyframed text transform and a keyframed video transform animated
	// around different points while reading the same fields, and every box the
	// preview drew for text needed its own anchor arithmetic to compensate.
	if kind == .Text && source_w > 0 && source_h > 0 {
		w, h := text_box_dims(
			source_w,
			source_h,
			geom[int(Render_Geom_Prop.Scale)],
			v.width,
		)
		cx, cy := project_to_pixel(
			canvas,
			geom[int(Render_Geom_Prop.Trans_X)],
			geom[int(Render_Geom_Prop.Trans_Y)],
		)
		return {x = cx - w / 2, y = cy - h / 2, width = w, height = h}
	}
	cx, cy := project_to_pixel(
		canvas,
		geom[int(Render_Geom_Prop.Trans_X)],
		geom[int(Render_Geom_Prop.Trans_Y)],
	)
	// The source-sized box is in PROJECT units (scale relative to the source's
	// own pixels: scale 1 = native size); scale it onto the screen by the
	// view's pixels-per-project-unit so the drawn quad matches the box the
	// handle math sees. With an unknown source size (0) the box falls back to
	// the canvas.
	// clip_full_box_dims is full_box_dims over the live canvas size; spelled
	// out here because the caller has source dims, not a clip.
	cu_w, cu_h := full_box_dims(
		source_w,
		source_h,
		geom[int(Render_Geom_Prop.Scale)],
		f32(project.width),
		f32(project.height),
	)
	pu := f32(project.width)
	if pu <= 0 {
		pu = f32(PREVIEW_W)
	}
	k := v.width / pu
	sw := cu_w * k
	sh := cu_h * k
	// The shared geometry, so the preview and the export place a crop the same
	// way. The extent is derived from the edges rather than recomputed as
	// sw*(1-crop_l-crop_r): the export rounds these edges, and a width formed
	// any other way can differ from it by a pixel.
	// The BOX insets — crop only. Zoom and pan select CONTENT and must never
	// reach here: cropped_box_edges reads an inset as a box trim, so an
	// asymmetric pair moves the box, and both zoom-about-an-offset-crop and pan
	// produce exactly that. See geom_box_insets vs geom_content_insets.
	cl, cr, ct, cb := geom_box_insets(geom)
	l, t, r, b := cropped_box_edges(cx, cy, sw, sh, cl, cr, ct, cb)
	return {x = l, y = t, width = r - l, height = b - t}
}

// CROP_MIN_VISIBLE_FRAC is the smallest crop window (as a fraction of the full
// box) the wheel/pan gestures allow; below it the visible box has no extent and
// the render math divides by zero.
CROP_MIN_VISIBLE_FRAC :: 0.05

// clip_zoom_by multiplies the selected clip's Zoom lane by `factor`, so
// factor > 1 magnifies the content and factor < 1 reveals more of the source.
//
// ONE lane, ONE write. This gesture used to write seven fields across three
// properties — the four crop insets, Scale, and both transforms — recomputing the
// box center each time to keep the visible box exactly where it was. That
// compensation WAS the hack: seven coupled values had to stay in step by hand,
// any one of them drifting moved the box a pixel, and it is why the gesture
// needed a probe of its own (TODO.md Active 3, geom_key_probe's keyed-drag case).
// Now the box is untouched by construction, because Zoom is resolved INSIDE the
// window and the box is derived from the window's center.
//
// Geometry is read with clip_geom_get and written with clip_geom_set, never off
// the resting fields: on a clip whose zoom is keyed the resting field is not
// what the preview is showing, so computing from it and writing to it both reads
// and stores a value the sampler ignores.
//
// With apply=false it only reports whether the edit would change anything (the
// wheel-at-floor no-op guard), so the caller can capture the pre-edit state
// before mutating.
clip_zoom_by :: proc(clip: ^Clip, factor: f32, apply: bool) -> bool {
	if clip.kind == .Text || clip.source_w <= 0 || !(factor > 0.0) {
		return false
	}
	cur := clip_geom_get(clip, .Zoom)
	// The zero value means "no magnification" (geom_source_window), so a bare
	// Clip{} zooms from 1 rather than from 0 — which would divide the window to
	// nothing on the first wheel tick.
	if !(cur > 0.0) {
		cur = 1.0
	}
	next := cur * factor
	// Clamp rather than reject: the window shrinks as 1/zoom, so an unbounded
	// zoom asks the source rect for a region below one pixel. The far end is
	// bounded by the resolver, which will not grow the window past the frame.
	if next <= 0.0 || next == cur {
		return false
	}
	if !apply {
		return true
	}
	clip_geom_set(clip, .Zoom, next)
	return true
}

// clip_pan_by slides the clip's content by a project-space delta, leaving the
// box exactly where it is. dx/dy are in the grab-the-content direction (drag
// right -> content shifts right), matching what the pointer does.
//
// Writes the two Pan lanes and nothing else. The old gesture rewrote all four
// crop insets plus both transforms to achieve the same slide; see
// clip_zoom_by for why that coupling was the defect.
//
// The delta is converted to pan units — a fraction of the ZOOMED window's own
// size — so the same pointer travel moves the same visual distance regardless of
// how far the clip is zoomed, and a zoom that lands mid-drag does not make the
// pan jump.
clip_pan_by :: proc(clip: ^Clip, dx, dy: f32) {
	if clip.kind == .Text || clip.source_w <= 0 || (dx == 0 && dy == 0) {
		return
	}
	geom: Geom_Sample
	for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
		geom[pi] = clip_geom_get(clip, Render_Geom_Prop(pi))
	}
	cw, ch := clip_full_box_dims(clip, geom[int(Render_Geom_Prop.Scale)])
	if cw <= 0.0 || ch <= 0.0 {
		return
	}
	// The pointer direction is grab-the-content, the same convention the gesture
	// had before this property existed: drag right and the CONTENT moves right,
	// because you are dragging the image rather than sliding a viewport past it.
	//
	// So the window moves LEFT, which means pan_x RISES. Pan_x is the window's
	// offset, not the content's: geom_source_window places the window at
	// `center - pan*nw`, so a positive pan_x shifts the sampled region toward the
	// source's left and the content appears to travel right.
	//
	// This was inverted once — the negation read as "the drag goes the other way",
	// which is true of the WINDOW and not of the thing the user is dragging. The
	// symptom was content sliding opposite the cursor.
	//
	// Per-axis, and only when that axis actually moved. Writing a lane its own
	// current value is not a no-op: clip_geom_set marks every lane it touches
	// pending, so a purely horizontal drag would leave pan.y pending and "key
	// all modified" would then mint a key for a value the user never changed --
	// the "stamps keys nobody asked for" failure clip_geom_drag exists to avoid.
	// Bounded by what the window can actually show, so the stored value and the
	// visible window cannot disagree. Clamping in geom_source_window alone was not
	// enough: it pinned the CONTENT while this kept incrementing the lane, so
	// dragging into an edge moved a number forever while the picture stayed put —
	// and the inspector, and any key taken from it, recorded a pan the clip was
	// never showing. The bound depends on zoom and crop, so it cannot be a
	// constant here; geom_pan_range derives it from the same parts the window is.
	//
	// The divisor is the BOX width, not the sampled WINDOW width, and the two
	// differ by exactly the zoom and crop factor `nw` — which is the whole bug.
	// Tracking a fixed source point u through the window:
	//
	//	sx(u) = box_x + (u - nl)/nw * cw,  nl = nl0 - pan * nw
	//	      = const + pan * cw
	//
	// so one unit of pan moves the content `cw` project px, INDEPENDENT of nw.
	// Zoom and crop cancel: they enlarge the source displacement a pan implies,
	// and the window shrinks by the same factor. Hence `dx / cw`.
	//
	// Dividing by the window's width instead (`nw * cw`) made a drag move the
	// content dx/nw px, so pan speed grew with zoom — 2.2x at zoom 2 over a 10%
	// crop, 4.4x at zoom 4 — and the content outran the cursor. It was invisible
	// at zoom 1 uncropped, where nw is exactly 1 and the two divisors coincide,
	// which is why it read as correct until anything was zoomed.
	if dx != 0 {
		clip_geom_set(clip, .Pan_X, clamp_pan_x(geom, clip_geom_get(clip, .Pan_X) + dx / cw))
	}
	if dy != 0 {
		clip_geom_set(clip, .Pan_Y, clamp_pan_y(geom, clip_geom_get(clip, .Pan_Y) + dy / ch))
	}
}

// crop_pan_begin captures the pre-pan transform/crop and opens the undo node
// for the Alt+Middle crop-pan gesture; the box is anchored so the release step
// can tell a no-move press from a real pan. The snapshot is of the PLAYHEAD
// values, not the resting fields — on a keyed clip those differ, and comparing
// against the wrong baseline would make every press look like a move.
crop_pan_begin :: proc(clip: ^Clip, x, y: f32) {
	crop_pan.active = true
	crop_pan.last_x = x
	crop_pan.last_y = y
	crop_pan.start_pan_x = clip_geom_get(clip, .Pan_X)
	crop_pan.start_pan_y = clip_geom_get(clip, .Pan_Y)
	undo_begin()
}

// crop_pan_end commits the crop pan as one transform node when it moved
// anything, or discards the pending capture for a no-move press. Compares the
// playhead values against the snapshot for the same reason crop_pan_begin
// snapshotted those: the resting fields are not what the gesture wrote on a
// keyed clip, and a comparison against them would push an undo node for a
// press that moved nothing.
crop_pan_end :: proc() {
	if !crop_pan.active {
		return
	}
	crop_pan.active = false
	if sel, ok := transformable_selected(); ok && sel.kind != .Text {
		if clip_geom_get(sel, .Pan_X) != crop_pan.start_pan_x ||
		   clip_geom_get(sel, .Pan_Y) != crop_pan.start_pan_y {
			undo_push(.Transform, "Pan clip")
			return
		}
	}
	undo_cancel()
}

// transformable_clip reports whether the clip currently selected is one with a
// (video/image) transform that can be previewed/moved.
transformable_selected :: proc() -> (^Clip, bool) {
	_, cl, ok := selected_clip()
	if !ok || cl.kind == .Audio {
		return nil, false
	}
	return cl, true
}

// preview_handles returns the 8 resize/crop handle rects around a clip's box in
// screen pixels: 0 TL, 1 T, 2 TR, 3 R, 4 BR, 5 B, 6 BL, 7 L.
preview_handles :: proc(b: clay.BoundingBox) -> [8]clay.BoundingBox {
	cx := b.x + b.width / 2
	cy := b.y + b.height / 2
	s := PREVIEW_HANDLE_SIZE
	return {
		{x = b.x - s / 2, y = b.y - s / 2, width = s, height = s},
		{x = cx - s / 2, y = b.y - s / 2, width = s, height = s},
		{x = b.x + b.width - s / 2, y = b.y - s / 2, width = s, height = s},
		{x = b.x + b.width - s / 2, y = cy - s / 2, width = s, height = s},
		{x = b.x + b.width - s / 2, y = b.y + b.height - s / 2, width = s, height = s},
		{x = cx - s / 2, y = b.y + b.height - s / 2, width = s, height = s},
		{x = b.x - s / 2, y = b.y + b.height - s / 2, width = s, height = s},
		{x = b.x - s / 2, y = cy - s / 2, width = s, height = s},
	}
}

// preview_handle_at returns the index of the handle rect containing the point,
// or -1.
preview_handle_at :: proc(b: clay.BoundingBox, mx, my: f32) -> int {
	handles := preview_handles(b)
	for i in 0 ..< 8 {
		h := handles[i]
		if mx >= h.x && mx <= h.x + h.width && my >= h.y && my <= h.y + h.height {
			return i
		}
	}
	return -1
}

// is_corner reports whether the handle is a diagonal (corner) handle.
is_corner :: proc(handle: Handle) -> bool {
	switch handle {
	case .TL, .TR, .BR, .BL:
		return true
	case .T, .B, .L, .R:
		return false
	}
	unreachable()
}

// begin_handle_drag captures the state needed to scale/crop the selected clip
// from a handle drag. crop=true makes the drag adjust the source crop instead
// of the scale.
begin_handle_drag :: proc(clip: ^Clip, canvas: clay.BoundingBox, handle: Handle, mx, my: f32, crop: bool) {
	handle_drag.handle = handle
	handle_drag.kind = crop ? .Crop : .Scale
	handle_drag.corner_snapped = false
	handle_drag.start_mx = mx
	handle_drag.start_my = my
	// Snapshot the values the user SEES, not the resting fields: the drag math
	// scales from this base, so on a keyed clip a resting snapshot scales from
	// a position that is not on screen and the handle jumps on grab.
	handle_drag.start_scale = clip_geom_get(clip, .Scale)
	handle_drag.start_crop_l = clip_geom_get(clip, .Crop_L)
	handle_drag.start_crop_r = clip_geom_get(clip, .Crop_R)
	handle_drag.start_crop_t = clip_geom_get(clip, .Crop_T)
	handle_drag.start_crop_b = clip_geom_get(clip, .Crop_B)
	tx0 := clip_geom_get(clip, .Trans_X)
	ty0 := clip_geom_get(clip, .Trans_Y)
	cx, cy := project_to_pixel(canvas, tx0, ty0)
	handle_drag.start_center_x = cx
	handle_drag.start_center_y = cy
	handle_drag.start_tx = tx0
	handle_drag.start_ty = ty0
	ib := clip_image_bounds(canvas, clip)
	handle_drag.start_box_w = ib.width
	handle_drag.start_box_h = ib.height
	// Scale/crop is applied live during the drag; capture the pre-edit document
	// here so releasing commits the whole gesture as one transform node.
	undo_begin()
}

// handle_drag_frozen reports whether a corner-handle drag must hold its box
// instead of resizing. Once the driven corner has snapped flush onto a canvas
// corner during this drag (handle_drag.corner_snapped latched), moving the cursor
// DIAGONALLY beyond that corner (past the snap margin on BOTH axes) would keep
// rescaling the box about the pinned opposite corner -- the "resizing on the
// other corner" overflow, the corner-handle version of the old edge bug. The
// box freezes at its snapped geometry while the pointer sits diagonally beyond
// the corner and resumes as soon as it crosses back inside the canvas on
// either axis. Beyond on ONE axis alone must NOT freeze: that is just an edge
// drag (like an edge handle scaling past its border, which is intended). A box
// that merely STARTS flush must still scale outward from its corner, so the
// freeze only engages after a real snap. Edge handles deliberately do NOT
// freeze: scaling an edge past its border is intended.
handle_drag_frozen :: proc(clip: ^Clip, handle: Handle, pmx, pmy, margin: f32) -> bool {
	if clip == nil {
		return false
	}
	if !handle_drag.corner_snapped {
		return false
	}
	PW := f32(project.width)
	PH := f32(project.height)
	l, r, t, b := clip_visible_box_project(clip)
	switch handle {
	case .TL: // TL driven corner flush at canvas (0,0)
		return abs(l) <= margin && abs(t) <= margin && (pmx < -margin && pmy < -margin)
	case .TR: // TR flush at (PW,0)
		return abs(r - PW) <= margin && abs(t) <= margin && (pmx > PW + margin && pmy < -margin)
	case .BR: // BR flush at (PW,PH)
		return abs(r - PW) <= margin && abs(b - PH) <= margin && (pmx > PW + margin && pmy > PH + margin)
	case .BL: // BL flush at (0,PH)
		return abs(l) <= margin && abs(b - PH) <= margin && (pmx < -margin && pmy > PH + margin)
	case .T, .B, .L, .R:
		return false
	}
	unreachable()
}

// clip_visible_box_project returns the clip's current visible (crop-adjusted)
// box edges in project-resolution units, mirroring clip_image_bounds but in
// project space (no camera/pixel mapping).
clip_visible_box_project :: proc(clip: ^Clip) -> (l, r, t, b: f32) {
	PW := f32(project.width)
	PH := f32(project.height)
	if clip.kind == .Text && clip.source_w > 0 && clip.source_h > 0 {
		f := clip.scale * PW / f32(PREVIEW_W)
		w := f32(clip.source_w) * f
		h := f32(clip.source_h) * f
		return clip.transform_x, clip.transform_x + w, clip.transform_y, clip.transform_y + h
	}
	cw, ch := clip_full_box_dims(clip, clip.scale)
	dl := (0.5 - clip.crop_l) * cw
	dr := (0.5 - clip.crop_r) * cw
	dt := (0.5 - clip.crop_t) * ch
	db := (0.5 - clip.crop_b) * ch
	return clip.transform_x - dl, clip.transform_x + dr, clip.transform_y - dt, clip.transform_y + db
}

// snap_driven_handle snaps only the edge(s) the ACTIVE handle drives to the
// canvas borders when they come within the margin -- the opposite (pinned)
// edges never move. Two snap strategies:
//   • edge handles: nudge the SCALE so the driven edge lands exactly on its
//     border about the pinned edge, then recompute the transform that keeps the
//     pinned edge fixed (the scale change would otherwise shift it).
//   • corner (diagonal) handles: scale about the pinned opposite corner so the
//     driven corner lands exactly flush on the canvas corner along the
//     dominant axis (corner_snap_scale), with only a bounded perpendicular
//     translate (≤ margin) closing the residual an aspect-locked box can't
//     reach by scaling alone. The center-pivot (Shift) case keeps a rigid
//     corner_snap_both translate since it has no single pinned corner.
// The pivot math differs between a pinned-above and a center pivot; `from_center`
// switches to a center-stable scale correction for the Shift+drag case.
snap_driven_handle :: proc(
	clip: ^Clip,
	handle: Handle,
	s, tx, ty, cw, ch, margin: f32,
	from_center: bool,
) {
	PW := f32(project.width)
	PH := f32(project.height)
	cl := clip.crop_l
	cr := clip.crop_r
	ct := clip.crop_t
	cb := clip.crop_b
	dl := (0.5 - cl) * cw
	dr := (0.5 - cr) * cw
	dt := (0.5 - ct) * ch
	db := (0.5 - cb) * ch
	l := tx - dl
	r := tx + dr
	t := ty - dt
	b := ty + db
	s_out := s
	tx_out := tx
	ty_out := ty
	switch handle {
	case .T: // top driven
		if abs(t) > margin {
			break
		}
		if from_center {
			cy: f32 = ty + (dt - db) / 2
			s_out = s * cy / (cy - t)
			_, ch2 := clip_full_box_dims(clip, s_out)
			dt = (0.5 - ct) * ch2
			db = (0.5 - cb) * ch2
			ty_out = cy + (dt - db) / 2
		} else {
			s_out = s * b / (b - t)
			_, ch2 := clip_full_box_dims(clip, s_out)
			dt = (0.5 - ct) * ch2
			db = (0.5 - cb) * ch2
			ty_out = b - db
		}
	case .B: // bottom driven
		if abs(b - PH) > margin {
			break
		}
		if from_center {
			cy: f32 = ty + (dt - db) / 2
			s_out = s * (PH - cy) / (b - cy)
			_, ch2 := clip_full_box_dims(clip, s_out)
			dt = (0.5 - ct) * ch2
			db = (0.5 - cb) * ch2
			ty_out = cy + (dt - db) / 2
		} else {
			s_out = s * (PH - t) / (b - t)
			_, ch2 := clip_full_box_dims(clip, s_out)
			dt = (0.5 - ct) * ch2
			db = (0.5 - cb) * ch2
			ty_out = t + dt
		}
	case .L: // left driven
		if abs(l) > margin {
			break
		}
		if from_center {
			cx: f32 = tx + (dl - dr) / 2
			s_out = s * cx / (cx - l)
			cw2, _ := clip_full_box_dims(clip, s_out)
			dl = (0.5 - cl) * cw2
			dr = (0.5 - cr) * cw2
			tx_out = cx + (dl - dr) / 2
		} else {
			s_out = s * r / (r - l)
			cw2, _ := clip_full_box_dims(clip, s_out)
			dl = (0.5 - cl) * cw2
			dr = (0.5 - cr) * cw2
			tx_out = r - dr
		}
	case .R: // right driven
		if abs(r - PW) > margin {
			break
		}
		if from_center {
			cx: f32 = tx + (dl - dr) / 2
			s_out = s * (PW - cx) / (r - cx)
			cw2, _ := clip_full_box_dims(clip, s_out)
			dl = (0.5 - cl) * cw2
			dr = (0.5 - cr) * cw2
			tx_out = cx + (dl - dr) / 2
		} else {
			s_out = s * (PW - l) / (r - l)
			cw2, _ := clip_full_box_dims(clip, s_out)
			dl = (0.5 - cl) * cw2
			dr = (0.5 - cr) * cw2
			tx_out = l + dl
		}
	case .TL, .TR, .BR, .BL:
		if from_center {
			dtx, dty, ok := corner_snap_both(handle, l, r, t, b, margin, PW, PH)
			if ok {
				tx_out = tx + dtx
				ty_out = ty + dty
			}
		} else {
			ss, tsx, tsy, ok := corner_snap_scale(clip, handle, s, tx, ty, l, r, t, b, margin, PW, PH)
			if ok {
				s_out = ss
				tx_out = tsx
				ty_out = tsy
				handle_drag.corner_snapped = true
			}
		}
	}
	clip.scale = s_out
	clip.transform_x = tx_out
	clip.transform_y = ty_out
}

// update_handle_drag applies the current pointer to the active handle drag,
// scaling the clip (default) or trimming its source crop (crop mode). Scaling
// pins the handle opposite the one being dragged: the opposite edge/corner
// stays fixed while the dragged handle tracks the pointer.
update_handle_drag :: proc(clip: ^Clip, canvas: clay.BoundingBox, mx, my: f32, from_center := false) {
	if handle_drag.handle == nil || clip == nil {
		return
	}
	h := handle_drag.handle.?

	// Text clips need their own box SIZE, not their own pivot: clip.source_w/h are
	// TEXT pixels, so the box is the text's base extent mapped through one uniform
	// project factor, where the video path below uses full_box_dims on real source
	// pixels. The PIVOT, though, is the same center every other source uses, so the
	// edges below are derived from the center and the writes store the center.
	// This branch used to be top-left anchored as well, which is why it had its own
	// center0 math to undo the difference.
	if clip.kind == .Text {
		switch handle_drag.kind {
		case .None, .Crop:
			return
		case .Scale:
		}
		PW := f32(project.width)
		PH := f32(project.height)
		twpx := f32(clip.source_w)
		thpx := f32(clip.source_h)
		if twpx <= 0 || thpx <= 0 {
			return
		}
		// Base project-unit size at scale=1. clip_image_bounds renders the text
		// box scaling BOTH axes by the same uniform factor (f = v.width/PREVIEW_W),
		// so the drag math must use that same uniform factor (PW/PREVIEW_W) for w
		// and h; otherwise the geometry the math pins differs from the drawn box
		// and the opposite-handle pivot visibly drifts for non-16:9 projects.
		bw0 := twpx * PW / f32(PREVIEW_W)
		bh0 := thpx * PW / f32(PREVIEW_W)
		scale0 := handle_drag.start_scale
		tx0 := handle_drag.start_tx
		ty0 := handle_drag.start_ty
		left0 := tx0 - bw0 * scale0 / 2
		right0 := tx0 + bw0 * scale0 / 2
		top0 := ty0 - bh0 * scale0 / 2
		bottom0 := ty0 + bh0 * scale0 / 2
		pmx, pmy := pixel_to_project_unclamped(canvas, mx, my)
		if handle_drag_frozen(clip, h, pmx, pmy, snap_margin(canvas, SNAP_MARGIN_PX)) {
			return
		}

		if from_center {
			cpx := left0 + bw0 * scale0 / 2
			cpy := top0 + bh0 * scale0 / 2
			s := max(handle_center_pivot_scale(h, cpx, cpy, pmx, pmy, bw0, bh0), 0.01)
			w := bw0 * s
			h := bh0 * s
			clip.scale = clamp(s, 0.05, 100.0)
			clip.transform_x = cpx
			clip.transform_y = cpy
			return
		}

		k: f32 = 1
		switch h {
		case .T: // top pins bottom
			k = (bottom0 - pmy) / bh0
		case .B: // bottom pins top
			k = (pmy - top0) / bh0
		case .L: // left pins right
			k = (right0 - pmx) / bw0
		case .R: // right pins left
			k = (pmx - left0) / bw0
		case .TL, .TR, .BR, .BL:
			kx: f32 = 1
			ky: f32 = 1
			// Live dominant axis measured from the PINNED (opposite) corner --
			// the pivot the scale math actually anchors -- so a corner drag
			// resizes along whichever axis the pointer sweeps most. The old
			// start-vs-center ratio compared the grab point (the corner) to the
			// clip CENTER, which is always exactly half a box on both axes
			// (0.5 vs 0.5, a tie the `>` never breaks): every corner scale came
			// out horizontal-only and vertical corner drags froze the box.
			dx: f32
			dy: f32
			switch h {
			case .TL: // TL pins BR
				kx = (right0 - pmx) / bw0
				ky = (bottom0 - pmy) / bh0
				dx = right0 - pmx
				dy = bottom0 - pmy
			case .TR: // TR pins BL
				kx = (pmx - left0) / bw0
				ky = (bottom0 - pmy) / bh0
				dx = pmx - left0
				dy = bottom0 - pmy
			case .BR: // BR pins TL
				kx = (pmx - left0) / bw0
				ky = (pmy - top0) / bh0
				dx = pmx - left0
				dy = pmy - top0
			case .BL: // BL pins TR
				kx = (right0 - pmx) / bw0
				ky = (pmy - top0) / bh0
				dx = right0 - pmx
				dy = pmy - top0
			case .T, .B, .L, .R: // corner-only pin, unreachable inside corner group
				assert(false, "DominantAxis: text corner k-switch reached an edge handle")
			}
			if abs(dy) / bh0 > abs(dx) / bw0 {
				k = ky
			} else {
				k = kx
			}
		}
		// The k factors divide by the BASE (scale=1) size bw0/bh0, so k is
		// already the absolute target scale — not a multiplier relative to
		// handle_drag.start_scale. Applying it as `s := max(k, ...)` makes the
		// dragged edge/corner land exactly under the mouse for any starting
		// scale (scale0* would overshoot by scale0x once the text is pre-scaled).
		s := max(k, 0.01)
		new_w := bw0 * s
		new_h := bh0 * s
		// For edge handles the pivot is the OPPOSITE edge, not the top-left
		// corner: keep the box centered on the perpendicular axis so the whole
		// opposite edge stays put (matching video's edge pivots). Corner handles
		// pivot about the opposite corner.
		center_x0 := left0 + bw0 * scale0 / 2
		center_y0 := top0 + bh0 * scale0 / 2
		tx := tx0
		ty := ty0
		switch h {
		case .T: // top pins bottom edge, x stays centered
			ty = bottom0 - new_h
			tx = center_x0 - new_w / 2
		case .B: // bottom pins top edge, x stays centered
			ty = top0
			tx = center_x0 - new_w / 2
		case .L: // left pins right edge, y stays centered
			tx = right0 - new_w
			ty = center_y0 - new_h / 2
		case .R: // right pins left edge, y stays centered
			tx = left0
			ty = center_y0 - new_h / 2
		case .TL: // TL pins BR
			tx = right0 - new_w
			ty = bottom0 - new_h
		case .TR: // TR pins BL
			tx = left0
			ty = bottom0 - new_h
		case .BR: // BR pins TL
			tx = left0
			ty = top0
		case .BL: // BL pins TR
			tx = right0 - new_w
			ty = top0
		}
		clip.scale = clamp(s, 0.05, 100.0)
		// tx/ty are the dragged box's top-left; the transform stores its center.
		clip.transform_x = tx + new_w / 2
		clip.transform_y = ty + new_h / 2
		if is_corner(h) {
			dtx, dty, snapped := corner_snap_both(
				h,
				clip.transform_x, clip.transform_x + new_w,
				clip.transform_y, clip.transform_y + new_h,
				snap_margin(canvas, SNAP_MARGIN_PX), PW, PH,
			)
			if snapped {
				clip.transform_x += dtx
				clip.transform_y += dty
			}
		}
		// Text clips are top-left anchored with a uniform scale; the box is only
		// nudged to a canvas corner via corner_snap_both when the whole corner
		// arrives there, and text may legitimately spill off-canvas otherwise.
		return
	}

	switch handle_drag.kind {
	case .None:
		return
	case .Scale:
		// Uniform (aspect-locked) scale, independent of crop. The visible
		// (cropped) box scales by a uniform factor k about the pinned opposite
		// visible edge/corner while crop fractions stay constant. The new
		// transform is derived by anchoring the pinned visible edge with its
		// scaled offset (0.5 - crop)*axis*new_scale, so scaling after a crop is
		// stable. All in project units with the pointer unclamped. The full box
		// honors the source aspect so the math matches the box the user sees.
		PW := f32(project.width)
		PH := f32(project.height)
		scale0 := handle_drag.start_scale
		cl := handle_drag.start_crop_l
		cr := handle_drag.start_crop_r
		ct := handle_drag.start_crop_t
		cb := handle_drag.start_crop_b
		cw0, ch0 := clip_full_box_dims(clip, scale0)
		dl0 := (0.5 - cl) * cw0
		dr0 := (0.5 - cr) * cw0
		dt0 := (0.5 - ct) * ch0
		db0 := (0.5 - cb) * ch0
		vl0 := handle_drag.start_tx - dl0
		vr0 := handle_drag.start_tx + dr0
		vt0 := handle_drag.start_ty - dt0
		vb0 := handle_drag.start_ty + db0
		w0 := (1 - cl - cr) * cw0
		h0 := (1 - ct - cb) * ch0
		// The k-switch below divides by w0/h0, and every handle's formula uses
		// the box's own extent as its divisor. A fully-inset crop (cl+cr >= 1 or
		// ct+cb >= 1) would zero the visible box; the crop UI pins each edge
		// inside the opposite edge, so assert the divisor has extent.
		assert(w0 > 0 && h0 > 0, "Scale: visible box has zero width or height")
		pmx, pmy := pixel_to_project_unclamped(canvas, mx, my)
		// Corner (diagonal) handles hold their snapped geometry while the
		// pointer sits beyond the flushed canvas corner; edge handles keep
		// scaling past their borders by design. Without this gate an outward
		// drag after a corner snap resizes the box from its opposite corner.
		if handle_drag_frozen(clip, h, pmx, pmy, snap_margin(canvas, SNAP_MARGIN_PX)) {
			return
		}

		if from_center {
			// Shift held: pivot about the visible box center — both edges move,
			// the box never drifts. The center is the transform shifted by the
			// crop asymmetry ((dr-dl)/2), so a cropped clip still resizes about
			// what the user sees.
			pivot_cx := handle_drag.start_tx + (dl0 - dr0) / 2
			pivot_cy := handle_drag.start_ty + (dt0 - db0) / 2
			k := max(handle_center_pivot_scale(h, pivot_cx, pivot_cy, pmx, pmy, w0, h0), 0.01)
			s := scale0 * k
			cw, ch := clip_full_box_dims(clip, s)
			dl := (0.5 - cl) * cw
			dr := (0.5 - cr) * cw
			dt := (0.5 - ct) * ch
			db := (0.5 - cb) * ch
			clip.scale = clamp(s, 0.05, 100.0)
			clip.transform_x = pivot_cx + (dl - dr) / 2
			clip.transform_y = pivot_cy + (dt - db) / 2
			snap_driven_handle(clip, h, clamp(s, 0.05, 100.0), clip.transform_x, clip.transform_y, cw, ch, snap_margin(canvas, SNAP_MARGIN_PX), true)
			return
		}

		k: f32 = 1
		switch h {
		case .T: // top: pin bottom
			k = (vb0 - pmy) / h0
		case .B: // bottom: pin top
			k = (pmy - vt0) / h0
		case .L: // left: pin right
			k = (vr0 - pmx) / w0
		case .R: // right: pin left
			k = (pmx - vl0) / w0
		case .TL, .TR, .BR, .BL: // corners: pin opposite corner, dominant axis
			kx: f32 = 1
			ky: f32 = 1
			// Live dominant axis measured from the PINNED (opposite) corner --
			// the pivot the scale math actually anchors -- so a corner drag
			// resizes along whichever axis the pointer sweeps most. The old
			// start-vs-center ratio compared the grab point (the corner) to the
			// clip CENTER, which is always exactly half a box on both axes
			// (0.5 vs 0.5, a tie the `>` never breaks): every corner scale came
			// out horizontal-only and vertical corner drags froze the box.
			dx: f32
			dy: f32
			switch h {
			case .TL: // TL pins BR
				kx = (vr0 - pmx) / w0
				ky = (vb0 - pmy) / h0
				dx = vr0 - pmx
				dy = vb0 - pmy
			case .TR: // TR pins BL
				kx = (pmx - vl0) / w0
				ky = (vb0 - pmy) / h0
				dx = pmx - vl0
				dy = vb0 - pmy
			case .BR: // BR pins TL
				kx = (pmx - vl0) / w0
				ky = (pmy - vt0) / h0
				dx = pmx - vl0
				dy = pmy - vt0
			case .BL: // BL pins TR
				kx = (vr0 - pmx) / w0
				ky = (pmy - vt0) / h0
				dx = vr0 - pmx
				dy = pmy - vt0
			case .T, .B, .L, .R: // corner-only pin, unreachable inside corner group
				assert(false, "DominantAxis: video corner k-switch reached an edge handle")
			}
			if abs(dy) / h0 > abs(dx) / w0 {
				k = ky
			} else {
				k = kx
			}
		}

		k = max(k, 0.01)
		s := scale0 * k
		cw, ch := clip_full_box_dims(clip, s)
		dl := (0.5 - cl) * cw
		dr := (0.5 - cr) * cw
		dt := (0.5 - ct) * ch
		db := (0.5 - cb) * ch
		tx := handle_drag.start_tx
		ty := handle_drag.start_ty
		switch h {
		case .T: // top pins bottom
			ty = vb0 - db
		case .B: // bottom pins top
			ty = vt0 + dt
		case .L: // left pins right
			tx = vr0 - dr
		case .R: // right pins left
			tx = vl0 + dl
		case .TL: // TL pins BR
			tx = vr0 - dr
			ty = vb0 - db
		case .TR: // TR pins BL
			tx = vl0 + dl
			ty = vb0 - db
		case .BR: // BR pins TL
			tx = vl0 + dl
			ty = vt0 + dt
		case .BL: // BL pins TR
			tx = vr0 - dr
			ty = vt0 + dt
		}

		// Snap ONLY the driven handle: corners snap both their edges flush on
		// the canvas corner, edges snap their single driven edge; the pinned
		// edges are the drag's anchor and are never moved by a snap.
		snap_driven_handle(clip, h, clamp(s, 0.05, 100.0), tx, ty, cw, ch, snap_margin(canvas, SNAP_MARGIN_PX), false)
	case .Crop:
		// Crop trims the visible box: dragging one edge moves that edge (and the
		// adjacent edges for a corner) while the opposite visible edge stays
		// fixed, revealing background. Insets are stored as normalized fractions
		// of the full box, and the scale/transform are not touched, so cropping
		// only crops. Trim-only: each edge can only move toward the opposite edge.
		// The full box honors the source aspect so edges align with what is seen.
		PW := f32(project.width)
		PH := f32(project.height)
		scale0 := handle_drag.start_scale
		out_w, out_h := clip_full_box_dims(clip, scale0)
		OX_L := handle_drag.start_tx - out_w / 2
		OX_R := handle_drag.start_tx + out_w / 2
		OX_T := handle_drag.start_ty - out_h / 2
		OX_B := handle_drag.start_ty + out_h / 2
		cl := handle_drag.start_crop_l
		cr := handle_drag.start_crop_r
		ct := handle_drag.start_crop_t
		cb := handle_drag.start_crop_b
		vl0 := OX_L + cl * out_w
		vr0 := OX_R - cr * out_w
		vt0 := OX_T + ct * out_h
		vb0 := OX_B - cb * out_h
		minsz := f32(0.5)
		pmx, pmy := pixel_to_project_unclamped(canvas, mx, my)
		switch h {
		case .T: // top: keep bottom visible edge fixed, allow un-crop to outer top
			clip.crop_t = (clamp(pmy, OX_T, vb0 - minsz) - OX_T) / out_h
		case .B: // bottom: keep top visible edge fixed
			clip.crop_b = (OX_B - clamp(pmy, vt0 + minsz, OX_B)) / out_h
		case .L: // left: keep right visible edge fixed
			clip.crop_l = (clamp(pmx, OX_L, vr0 - minsz) - OX_L) / out_w
		case .R: // right: keep left visible edge fixed
			clip.crop_r = (OX_R - clamp(pmx, vl0 + minsz, OX_R)) / out_w
		case .TL: // TL: keep right+bottom visible edges fixed
			clip.crop_l = (clamp(pmx, OX_L, vr0 - minsz) - OX_L) / out_w
			clip.crop_t = (clamp(pmy, OX_T, vb0 - minsz) - OX_T) / out_h
		case .TR: // TR: keep left+bottom visible edges fixed
			clip.crop_r = (OX_R - clamp(pmx, vl0 + minsz, OX_R)) / out_w
			clip.crop_t = (clamp(pmy, OX_T, vb0 - minsz) - OX_T) / out_h
		case .BR: // BR: keep left+top visible edges fixed
			clip.crop_r = (OX_R - clamp(pmx, vl0 + minsz, OX_R)) / out_w
			clip.crop_b = (OX_B - clamp(pmy, vt0 + minsz, OX_B)) / out_h
		case .BL: // BL: keep right+top visible edges fixed
			clip.crop_l = (clamp(pmx, OX_L, vr0 - minsz) - OX_L) / out_w
			clip.crop_b = (OX_B - clamp(pmy, vt0 + minsz, OX_B)) / out_h
		}
	}
}

// handle_drag_commit routes everything this gesture just moved to wherever the
// clip READS it. It lives beside begin/update_handle_drag so the drag's whole
// lifetime -- snapshot, apply, commit -- reads in one place, and so a probe
// drives the same call the shipped path does instead of re-declaring which
// lanes the gesture touches (a probe that copied the list would keep passing
// if the real call site stopped routing one of them).
//
// update_handle_drag writes the RESTING fields, because it runs every frame and
// the drag is not yet committed. That is exactly the write kf_sample_keys
// discards between the first and last key, so without this the handles appear to
// work on an unkeyed clip and silently do nothing on a keyed one. clip_geom_drag
// keys the playhead when the property is keyed there, so a keyed clip follows
// the handle with auto-key off; unkeyed, it marks the lane pending for the
// inspector's "key all modified" row.
//
// Crop handles reach one or two edges, no more: routing all four would stamp
// keys on edges the user never touched, so the kind gates the edge block.
handle_drag_commit :: proc(clip: ^Clip) {
	clip_geom_drag(clip, .Scale, handle_drag.start_scale)
	clip_geom_drag(clip, .Trans_X, handle_drag.start_tx)
	clip_geom_drag(clip, .Trans_Y, handle_drag.start_ty)
	if handle_drag.kind == .Crop {
		clip_geom_drag(clip, .Crop_L, handle_drag.start_crop_l)
		clip_geom_drag(clip, .Crop_R, handle_drag.start_crop_r)
		clip_geom_drag(clip, .Crop_T, handle_drag.start_crop_t)
		clip_geom_drag(clip, .Crop_B, handle_drag.start_crop_b)
	}
}
