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
	// Text clips use a top-left transform anchor with no crop, so the
	// center-anchored crop-aware math below doesn't apply; skip it.
	if clip.kind == .Text {
		return
	}
	PW := f32(project.width)
	PH := f32(project.height)
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

// begin_handle_drag captures the state needed to scale/crop the selected clip
// from a handle drag. crop=true makes the drag adjust the source crop instead
// of the scale.
begin_handle_drag :: proc(clip: ^Clip, canvas: clay.BoundingBox, handle: int, mx, my: f32, crop: bool) {
	dragging_handle = handle
	handle_kind = crop ? .Crop : .Scale
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

// update_handle_drag applies the current pointer to the active handle drag,
// scaling the clip (default) or trimming its source crop (crop mode). Scaling
// pins the handle opposite the one being dragged: the opposite edge/corner
// stays fixed while the dragged handle tracks the pointer.
update_handle_drag :: proc(clip: ^Clip, canvas: clay.BoundingBox, mx, my: f32) {
	if dragging_handle < 0 || clip == nil {
		return
	}
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
		// Base project-unit size at scale=1.
		bw0 := twpx * PW / f32(PREVIEW_W)
		bh0 := thpx * PH / f32(PREVIEW_H)
		scale0 := handle_start_scale
		tx0 := handle_start_tx
		ty0 := handle_start_ty
		left0 := tx0
		right0 := tx0 + bw0 * scale0
		top0 := ty0
		bottom0 := ty0 + bh0 * scale0
		pmx, pmy := pixel_to_project_unclamped(canvas, mx, my)

		k: f32 = 1
		switch dragging_handle {
		case 1: // top pins bottom
			k = (bottom0 - pmy) / bh0
		case 5: // bottom pins top
			k = (pmy - top0) / bh0
		case 7: // left pins right
			k = (right0 - pmx) / bw0
		case 3: // right pins left
			k = (pmx - left0) / bw0
		case 0, 2, 4, 6:
			kx: f32 = 1
			ky: f32 = 1
			switch dragging_handle {
			case 0: // TL pins BR
				kx = (right0 - pmx) / bw0
				ky = (bottom0 - pmy) / bh0
			case 2: // TR pins BL
				kx = (pmx - left0) / bw0
				ky = (bottom0 - pmy) / bh0
			case 4: // BR pins TL
				kx = (pmx - left0) / bw0
				ky = (pmy - top0) / bh0
			case 6: // BL pins TR
				kx = (right0 - pmx) / bw0
				ky = (pmy - top0) / bh0
			}
			if abs(handle_start_my-cy)/bh > abs(handle_start_mx-cx)/bw {
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
		tx := tx0
		ty := ty0
		switch dragging_handle {
		case 1: // top pins bottom edge
			ty = bottom0 - new_h
		case 5: // bottom pins top edge
			ty = top0
		case 7: // left pins right edge
			tx = right0 - new_w
		case 3: // right pins left edge
			tx = left0
		case 0: // TL pins BR
			tx = right0 - new_w
			ty = bottom0 - new_h
		case 2: // TR pins BL
			tx = left0
			ty = bottom0 - new_h
		case 4: // BR pins TL
			tx = left0
			ty = top0
		case 6: // BL pins TR
			tx = right0 - new_w
			ty = top0
		}
		clip.scale = clamp(s, 0.05, 100.0)
		clip.transform_x = tx
		clip.transform_y = ty
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
		pmx, pmy := pixel_to_project_unclamped(canvas, mx, my)

		k: f32 = 1
		switch dragging_handle {
		case 1: // top: pin bottom
			k = (vb0 - pmy) / h0
		case 5: // bottom: pin top
			k = (pmy - vt0) / h0
		case 7: // left: pin right
			k = (vr0 - pmx) / w0
		case 3: // right: pin left
			k = (pmx - vl0) / w0
		case 0, 2, 4, 6: // corners: pin opposite corner, dominant axis
			kx: f32 = 1
			ky: f32 = 1
			switch dragging_handle {
			case 0: // TL pins BR
				kx = (vr0 - pmx) / w0
				ky = (vb0 - pmy) / h0
			case 2: // TR pins BL
				kx = (pmx - vl0) / w0
				ky = (vb0 - pmy) / h0
			case 4: // BR pins TL
				kx = (pmx - vl0) / w0
				ky = (pmy - vt0) / h0
			case 6: // BL pins TR
				kx = (vr0 - pmx) / w0
				ky = (pmy - vt0) / h0
			}
			if abs(handle_start_my-cy)/bh > abs(handle_start_mx-cx)/bw {
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
		switch dragging_handle {
		case 1: // top pins bottom
			ty = vb0 - db
		case 5: // bottom pins top
			ty = vt0 + dt
		case 7: // left pins right
			tx = vr0 - dr
		case 3: // right pins left
			tx = vl0 + dl
		case 0: // TL pins BR
			tx = vr0 - dr
			ty = vb0 - db
		case 2: // TR pins BL
			tx = vl0 + dl
			ty = vb0 - db
		case 4: // BR pins TL
			tx = vl0 + dl
			ty = vt0 + dt
		case 6: // BL pins TR
			tx = vr0 - dr
			ty = vt0 + dt
		}

		clip.scale = clamp(s, 0.05, 100.0)
		clip.transform_x = tx
		clip.transform_y = ty
		// Snap the resulting visible box edges to the project borders.
		snap_transform(clip, snap_margin(canvas, 5))
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
		switch dragging_handle {
		case 1: // top: keep bottom visible edge fixed, allow un-crop to outer top
			clip.crop_t = (clamp(pmy, OX_T, vb0 - minsz) - OX_T) / out_h
		case 5: // bottom: keep top visible edge fixed
			clip.crop_b = (OX_B - clamp(pmy, vt0 + minsz, OX_B)) / out_h
		case 7: // left: keep right visible edge fixed
			clip.crop_l = (clamp(pmx, OX_L, vr0 - minsz) - OX_L) / out_w
		case 3: // right: keep left visible edge fixed
			clip.crop_r = (OX_R - clamp(pmx, vl0 + minsz, OX_R)) / out_w
		case 0: // TL: keep right+bottom visible edges fixed
			clip.crop_l = (clamp(pmx, OX_L, vr0 - minsz) - OX_L) / out_w
			clip.crop_t = (clamp(pmy, OX_T, vb0 - minsz) - OX_T) / out_h
		case 2: // TR: keep left+bottom visible edges fixed
			clip.crop_r = (OX_R - clamp(pmx, vl0 + minsz, OX_R)) / out_w
			clip.crop_t = (clamp(pmy, OX_T, vb0 - minsz) - OX_T) / out_h
		case 4: // BR: keep left+top visible edges fixed
			clip.crop_r = (OX_R - clamp(pmx, vl0 + minsz, OX_R)) / out_w
			clip.crop_b = (OX_B - clamp(pmy, vt0 + minsz, OX_B)) / out_h
		case 6: // BL: keep right+top visible edges fixed
			clip.crop_l = (clamp(pmx, OX_L, vr0 - minsz) - OX_L) / out_w
			clip.crop_b = (OX_B - clamp(pmy, vt0 + minsz, OX_B)) / out_h
		}
	}
}
