package main

import clay "clay-odin"

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

// clamp_preview_camera keeps the pan within one preview axis of the origin and
// the zoom within its min/max range.
clamp_preview_camera :: proc(canvas: clay.BoundingBox) {
	preview_cam_zoom = clamp(preview_cam_zoom, PREVIEW_CAM_MIN_ZOOM, PREVIEW_CAM_MAX_ZOOM)
	preview_cam_ox = clamp(preview_cam_ox, -canvas.width, canvas.width)
	preview_cam_oy = clamp(preview_cam_oy, -canvas.height, canvas.height)
}

// preview_view applies the camera (pan + zoom, centered on the base canvas) to
// produce the on-screen canvas rect used for drawing and hit-testing.
preview_view :: proc(canvas: clay.BoundingBox) -> clay.BoundingBox {
	clamp_preview_camera(canvas)
	w := canvas.width * preview_cam_zoom
	h := canvas.height * preview_cam_zoom
	cx := canvas.x + canvas.width / 2 + preview_cam_ox
	cy := canvas.y + canvas.height / 2 + preview_cam_oy
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

// clip_full_box_dims returns the uncropped full-image size (project units) for
// a clip whose canvas scale box is out_w x out_h, constrained to the source's
// own aspect (contain-fit, letterboxed). With an unknown source size (0) it is
// the plain canvas box, preserving the old stretch-to-fill behavior.
clip_full_box_dims :: proc(clip: ^Clip, out_w, out_h: f32) -> (f32, f32) {
	if clip.source_w > 0 && clip.source_h > 0 {
		src_ar := f32(clip.source_w) / f32(clip.source_h)
		box_ar := out_w / out_h
		if src_ar > box_ar {
			return out_w, out_w / src_ar
		}
		return out_h * src_ar, out_h
	}
	return out_w, out_h
}

// snap_transform snaps the clip's visible (cropped) box edges to the project
// canvas borders when they come within the given margin (project units). Force
// insets are normalized, so the visible half-extent from the center is
// (0.5 - crop) * (project axis) * scale. The full box honors the source aspect
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
		left := clip.transform_x
		top := clip.transform_y
		if abs(left) <= margin {
			clip.transform_x = 0
		} else if abs(left + w - PW) <= margin {
			clip.transform_x = PW - w
		}
		if abs(top) <= margin {
			clip.transform_y = 0
		} else if abs(top + h - PH) <= margin {
			clip.transform_y = PH - h
		}
		return
	}
	cw, ch := clip_full_box_dims(clip, PW * clip.scale, PH * clip.scale)
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
// only while snap_center_to_canvas is on; returns whether the clip snapped.
snap_center :: proc(clip: ^Clip, margin: f32) -> bool {
	if !snap_center_to_canvas {
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
	cw, ch := clip_full_box_dims(clip, PW * clip.scale, PH * clip.scale)
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
	cw2, ch2 := clip_full_box_dims(clip, pw * s_out, ph * s_out)
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
clip_image_bounds :: proc(canvas: clay.BoundingBox, clip: ^Clip) -> clay.BoundingBox {
	v := preview_view(canvas)
	// A text clip is not a full-canvas image: its bounds are exactly the text
	// extent. The text was rasterized into a buffer at tight text-pixel
	// dimensions (clip.source_w x source_h are TEXT pixels, not project units),
	// which must map to screen with ONE uniform scale so the title never gets
	// squished (an aspect probe through project resolution would scale x and y
	// differently for any project that isn't 16:9). transform_x/y is the text's
	// TOP-LEFT in project coords (the drag + scale math below is written for a
	// top-left anchor), and clip.scale multiplies the text's base pixel size so
	// resizing via the handles works on the text's own bounding box.
	if clip.kind == .Text && clip.source_w > 0 && clip.source_h > 0 {
		f := v.width / f32(PREVIEW_W)
		w := f32(clip.source_w) * f * clip.scale
		h := f32(clip.source_h) * f * clip.scale
		tx, ty := project_to_pixel(canvas, clip.transform_x, clip.transform_y)
		return {x = tx, y = ty, width = w, height = h}
	}
	cx, cy := project_to_pixel(canvas, clip.transform_x, clip.transform_y)
	// Preserve the source's own aspect inside the (canvas-shaped) scale box,
	// letterboxing the excess instead of stretching, so a clip doesn't get
	// squished when its aspect differs from the project canvas. With an
	// unknown source size (0) behavior is unchanged (fill the box).
	sw, sh := clip_full_box_dims(clip, v.width * clip.scale, v.height * clip.scale)
	x := cx - sw / 2 + clip.crop_l * sw
	y := cy - sh / 2 + clip.crop_t * sh
	return {x = x, y = y, width = sw * (1 - clip.crop_l - clip.crop_r), height = sh * (1 - clip.crop_t - clip.crop_b)}
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
	dragging_handle = handle
	handle_kind = crop ? .Crop : .Scale
	handle_corner_snapped = false
	handle_start_mx = mx
	handle_start_my = my
	handle_start_scale = clip.scale
	handle_start_crop_l = clip.crop_l
	handle_start_crop_r = clip.crop_r
	handle_start_crop_t = clip.crop_t
	handle_start_crop_b = clip.crop_b
	cx, cy := project_to_pixel(canvas, clip.transform_x, clip.transform_y)
	handle_start_center_x = cx
	handle_start_center_y = cy
	handle_start_tx = clip.transform_x
	handle_start_ty = clip.transform_y
	ib := clip_image_bounds(canvas, clip)
	handle_start_box_w = ib.width
	handle_start_box_h = ib.height
}

// handle_drag_frozen reports whether a corner-handle drag must hold its box
// instead of resizing. Once the driven corner has snapped flush onto a canvas
// corner during this drag (handle_corner_snapped latched), moving the cursor
// BEYOND that corner would keep rescaling the box about the pinned opposite
// corner -- the "resizing on the other corner" overflow, the corner-handle
// version of the old edge bug. The box freezes at its snapped geometry while
// the pointer sits beyond the corner (past the snap margin on either axis) and
// resumes once it crosses back inside. A box that merely STARTS flush must
// still scale outward from its corner, so the freeze only engages after a real
// snap. Edge handles deliberately do NOT freeze: scaling an edge past its
// border is intended.
handle_drag_frozen :: proc(clip: ^Clip, handle: Handle, pmx, pmy, margin: f32) -> bool {
	if clip == nil {
		return false
	}
	if !handle_corner_snapped {
		return false
	}
	PW := f32(project.width)
	PH := f32(project.height)
	l, r, t, b := clip_visible_box_project(clip)
	switch handle {
	case .TL: // TL driven corner flush at canvas (0,0)
		return abs(l) <= margin && abs(t) <= margin && (pmx < -margin || pmy < -margin)
	case .TR: // TR flush at (PW,0)
		return abs(r - PW) <= margin && abs(t) <= margin && (pmx > PW + margin || pmy < -margin)
	case .BR: // BR flush at (PW,PH)
		return abs(r - PW) <= margin && abs(b - PH) <= margin && (pmx > PW + margin || pmy > PH + margin)
	case .BL: // BL flush at (0,PH)
		return abs(l) <= margin && abs(b - PH) <= margin && (pmx < -margin || pmy > PH + margin)
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
	cw, ch := clip_full_box_dims(clip, PW * clip.scale, PH * clip.scale)
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
			_, ch2 := clip_full_box_dims(clip, PW * s_out, PH * s_out)
			dt = (0.5 - ct) * ch2
			db = (0.5 - cb) * ch2
			ty_out = cy + (dt - db) / 2
		} else {
			s_out = s * b / (b - t)
			_, ch2 := clip_full_box_dims(clip, PW * s_out, PH * s_out)
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
			_, ch2 := clip_full_box_dims(clip, PW * s_out, PH * s_out)
			dt = (0.5 - ct) * ch2
			db = (0.5 - cb) * ch2
			ty_out = cy + (dt - db) / 2
		} else {
			s_out = s * (PH - t) / (b - t)
			_, ch2 := clip_full_box_dims(clip, PW * s_out, PH * s_out)
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
			cw2, _ := clip_full_box_dims(clip, PW * s_out, PH * s_out)
			dl = (0.5 - cl) * cw2
			dr = (0.5 - cr) * cw2
			tx_out = cx + (dl - dr) / 2
		} else {
			s_out = s * r / (r - l)
			cw2, _ := clip_full_box_dims(clip, PW * s_out, PH * s_out)
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
			cw2, _ := clip_full_box_dims(clip, PW * s_out, PH * s_out)
			dl = (0.5 - cl) * cw2
			dr = (0.5 - cr) * cw2
			tx_out = cx + (dl - dr) / 2
		} else {
			s_out = s * (PW - l) / (r - l)
			cw2, _ := clip_full_box_dims(clip, PW * s_out, PH * s_out)
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
				handle_corner_snapped = true
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
	if dragging_handle == nil || clip == nil {
		return
	}
	h := dragging_handle.?
	cx := handle_start_center_x
	cy := handle_start_center_y
	bw := handle_start_box_w
	bh := handle_start_box_h

	// Text clips use a different transform model than video: transform_x/y is
	// the text's TOP-LEFT corner (in project units), not its center, and the box
	// size is the text's base pixel extent scaled by clip.scale (in project
	// units). The video math below anchors the transform as the center, so text
	// scales through its own top-left-anchored math. No cropping for text.
	if clip.kind == .Text {
		switch handle_kind {
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
		scale0 := handle_start_scale
		tx0 := handle_start_tx
		ty0 := handle_start_ty
		left0 := tx0
		right0 := tx0 + bw0 * scale0
		top0 := ty0
		bottom0 := ty0 + bh0 * scale0
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
			clip.transform_x = cpx - w / 2
			clip.transform_y = cpy - h / 2
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
		// handle_start_scale. Applying it as `s := max(k, ...)` makes the
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
		clip.transform_x = tx
		clip.transform_y = ty
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

	switch handle_kind {
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
		scale0 := handle_start_scale
		cl := handle_start_crop_l
		cr := handle_start_crop_r
		ct := handle_start_crop_t
		cb := handle_start_crop_b
		cw0, ch0 := clip_full_box_dims(clip, PW * scale0, PH * scale0)
		dl0 := (0.5 - cl) * cw0
		dr0 := (0.5 - cr) * cw0
		dt0 := (0.5 - ct) * ch0
		db0 := (0.5 - cb) * ch0
		vl0 := handle_start_tx - dl0
		vr0 := handle_start_tx + dr0
		vt0 := handle_start_ty - dt0
		vb0 := handle_start_ty + db0
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
			cx := handle_start_tx + (dl0 - dr0) / 2
			cy := handle_start_ty + (dt0 - db0) / 2
			k := max(handle_center_pivot_scale(h, cx, cy, pmx, pmy, w0, h0), 0.01)
			s := scale0 * k
			cw, ch := clip_full_box_dims(clip, PW * s, PH * s)
			dl := (0.5 - cl) * cw
			dr := (0.5 - cr) * cw
			dt := (0.5 - ct) * ch
			db := (0.5 - cb) * ch
			clip.scale = clamp(s, 0.05, 100.0)
			clip.transform_x = cx + (dl - dr) / 2
			clip.transform_y = cy + (dt - db) / 2
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
		cw, ch := clip_full_box_dims(clip, PW * s, PH * s)
		dl := (0.5 - cl) * cw
		dr := (0.5 - cr) * cw
		dt := (0.5 - ct) * ch
		db := (0.5 - cb) * ch
		tx := handle_start_tx
		ty := handle_start_ty
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
		scale0 := handle_start_scale
		out_w, out_h := clip_full_box_dims(clip, PW * scale0, PH * scale0)
		OX_L := handle_start_tx - out_w / 2
		OX_R := handle_start_tx + out_w / 2
		OX_T := handle_start_ty - out_h / 2
		OX_B := handle_start_ty + out_h / 2
		cl := handle_start_crop_l
		cr := handle_start_crop_r
		ct := handle_start_crop_t
		cb := handle_start_crop_b
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
