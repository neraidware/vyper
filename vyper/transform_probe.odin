package vyper

// VYPER_TRANSFORM_PROBE — regression check for preview handle scaling.
// Rules under test:
//   • a scale drag follows the pointer with NO canvas clamp — the driven edge
//     (and a whole box) may scale beyond the rendered preview space;
//   • the pinned (opposite) edge is the drag anchor and NEVER moves — not from
//     the drag, and not from a snap;
//   • only the ACTIVE handle snaps: an edge handle snaps its single driven edge
//     onto the canvas border (by adjusting scale, so the pinned edge stays
//     put); a corner snaps with an EXACT scale about the pinned corner so the
//     driven corner lands flush on the canvas corner, then FREEZES while the
//     pointer sits DIAGONALLY beyond that corner (both axes; it does not keep
//     resizing from the opposite corner) and resumes once the pointer crosses
//     back inside on either axis.
//
// Each case builds a full-canvas box, grabs the handle ON its border, then
// asserts the pointer/border behavior. pixel<->project is identity here.

import "core:c"
import "core:math"
import "core:fmt"
import "core:os"
import clay "clay-odin"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	mk_probe_clip :: proc() -> (c: Clip) {
		// Video import now lands source-relative: scale 1 = the clip's own native
		// box, so to probe a FULL-CANVAS 16:9 box the fixture's source must BE the
		// canvas itself (1920x1080). All the flush-on-border cases below then keep
		// measuring a box that is exactly the canvas at scale 1, as before.
		c.source_w = project.width
		c.source_h = project.height
		c.transform_x = f32(project.width) / 2
		c.transform_y = f32(project.height) / 2
		c.scale = 1
		return
	}

	// probe_canvas maps pixel space 1:1 onto project resolution (identity camera,
	// canvas == project size), so pixel<->project conversions are identity.
	probe_canvas :: proc() -> clay.BoundingBox {
		preview_cam.zoom = 1
		preview_cam.ox = 0
		preview_cam.oy = 0
		return {x = 0, y = 0, width = f32(project.width), height = f32(project.height)}
	}

	probe_visible_edges :: proc(c: ^Clip) -> (l, r, t, b: f32) {
		// The probe's mk_probe_clip sets source_w/h = project dims, so scale 1 is
		// still EXACTLY the full canvas (both models agree there) and the geometry
		// this labels "full-canvas box" is unchanged. Under the new source-relative
		// model scale is the only box argument.
		cw2, ch2 := clip_full_box_dims(c, c.scale)
		dl := (0.5 - c.crop_l) * cw2
		dr := (0.5 - c.crop_r) * cw2
		dt := (0.5 - c.crop_t) * ch2
		db := (0.5 - c.crop_b) * ch2
		return c.transform_x - dl, c.transform_x + dr, c.transform_y - dt, c.transform_y + db
	}

	transform_probe_run :: proc(v: string) {
		// preview_view -> clamp_preview_camera reads clay element bounding boxes, so
		// clay must be initialized before this math runs. With no layout built it
		// returns the not-found default and the clamp falls back to the canvas size.
		// (main.odin dispatches probes before its own clay.Initialize.)
		memory := make([^]u8, clay.MinMemorySize())
		clay.Initialize(
			clay.CreateArenaWithCapacityAndMemory(c.size_t(clay.MinMemorySize()), memory),
			{WINDOW_WIDTH, WINDOW_HEIGHT},
			{handler = clay_probe_error},
		)

		PW := f32(project.width)
		PH := f32(project.height)
		canvas := probe_canvas()

		fail := false
		check :: proc(fail: ^bool, cond: bool, msg: string, l, r, t, b: f32) {
			if !cond {
				fail^ = true
				fmt.printf("[transform-probe] FAIL %s (box l=%.1f r=%.1f t=%.1f b=%.1f)\n", msg, l, r, t, b)
			}
		}

		// --- Case 1: TOP handle (1) scales BEYOND the border, pinned bottom stays.
		{
			c := mk_probe_clip() // full-canvas box: t=0, b=PH
			_, _, t0, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .T, PW / 2, t0, false)
			update_handle_drag(&c, canvas, PW / 2, -2000, false) // way above the canvas
			_, _, t, b := probe_visible_edges(&c)
			check(&fail, abs(t - (-2000)) <= 0.5, "top: driven top must follow the pointer beyond the canvas", 0, 0, t, b)
			check(&fail, abs(b - PH) <= 0.5, "top: pinned bottom must not move", 0, 0, t, b)
		}

		// --- Case 2: TOP handle returns inside: driven edge still tracks the pointer.
		{
			c := mk_probe_clip()
			_, _, t0, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .T, PW / 2, t0, false)
			update_handle_drag(&c, canvas, PW / 2, PH / 2, false)
			_, _, t, b := probe_visible_edges(&c)
			check(&fail, abs(t - PH/2) <= 0.5, "top: driven top should track the pointer", 0, 0, t, b)
			check(&fail, abs(b - PH) <= 0.5, "top: pinned bottom must not move", 0, 0, t, b)
		}

		// --- Case 3: TOP handle snaps its DRIVEN edge to the border within the margin.
		{
			c := mk_probe_clip()
			_, _, t0, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .T, PW / 2, t0, false)
			update_handle_drag(&c, canvas, PW / 2, -2, false) // ~within snap margin
			_, _, t, b := probe_visible_edges(&c)
			check(&fail, abs(t) <= 0.05, "top: driven top should snap onto the border", 0, 0, t, b)
			check(&fail, abs(b - PH) <= 0.5, "top: pinned bottom must not move", 0, 0, t, b)
		}

		// --- Case 4: BOTTOM handle (5) scales beyond, pinned top stays.
		{
			c := mk_probe_clip()
			_, _, _, b0 := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .B, PW / 2, b0, false)
			update_handle_drag(&c, canvas, PW / 2, 9999, false) // way below the canvas
			_, _, t, b := probe_visible_edges(&c)
			check(&fail, abs(b - 9999) <= 0.5, "bottom: driven bottom must follow the pointer beyond the canvas", 0, 0, t, b)
			check(&fail, abs(t - 0) <= 0.5, "bottom: pinned top must not move", 0, 0, t, b)
		}

		// --- Case 5: BOTTOM handle returns inside: driven edge tracks the pointer.
		{
			c := mk_probe_clip()
			_, _, _, b0 := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .B, PW / 2, b0, false)
			update_handle_drag(&c, canvas, PW / 2, PH / 2, false)
			_, _, t, b := probe_visible_edges(&c)
			check(&fail, abs(b - PH/2) <= 0.5, "bottom: driven bottom should track the pointer", 0, 0, t, b)
			check(&fail, abs(t - 0) <= 0.5, "bottom: pinned top must not move", 0, 0, t, b)
		}

		// --- Case 6: BOTTOM handle snaps its driven edge to the border.
		{
			c := mk_probe_clip()
			_, _, _, b0 := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .B, PW / 2, b0, false)
			update_handle_drag(&c, canvas, PW / 2, PH + 2, false) // ~within snap margin
			_, _, t, b := probe_visible_edges(&c)
			check(&fail, abs(b - PH) <= 0.05, "bottom: driven bottom should snap onto the border", 0, 0, t, b)
			check(&fail, abs(t - 0) <= 0.5, "bottom: pinned top must not move", 0, 0, t, b)
		}

		// --- Case 7: LEFT handle (7) scales beyond, pinned right stays.
		{
			c := mk_probe_clip()
			l0, _, _, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .L, l0, PH / 2, false)
			update_handle_drag(&c, canvas, -9999, PH / 2, false) // way left of the canvas
			l, r, _, _ := probe_visible_edges(&c)
			check(&fail, abs(l - (-9999)) <= 0.5, "left: driven left must follow the pointer beyond the canvas", l, r, 0, 0)
			check(&fail, abs(r - PW) <= 0.5, "left: pinned right must not move", l, r, 0, 0)
		}

		// --- Case 8: LEFT handle returns inside: driven edge tracks the pointer.
		{
			c := mk_probe_clip()
			l0, _, _, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .L, l0, PH / 2, false)
			update_handle_drag(&c, canvas, PW / 2, PH / 2, false)
			l, r, _, _ := probe_visible_edges(&c)
			check(&fail, abs(l - PW/2) <= 0.5, "left: driven left should track the pointer", l, r, 0, 0)
			check(&fail, abs(r - PW) <= 0.5, "left: pinned right must not move", l, r, 0, 0)
		}

		// --- Case 9: LEFT handle snaps its driven edge to the border.
		{
			c := mk_probe_clip()
			l0, _, _, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .L, l0, PH / 2, false)
			update_handle_drag(&c, canvas, -2, PH / 2, false) // ~within snap margin
			l, r, _, _ := probe_visible_edges(&c)
			check(&fail, abs(l - 0) <= 0.05, "left: driven left should snap onto the border", l, r, 0, 0)
			check(&fail, abs(r - PW) <= 0.5, "left: pinned right must not move", l, r, 0, 0)
		}

		// --- Case 10: RIGHT handle (3) scales beyond, pinned left stays.
		{
			c := mk_probe_clip()
			_, r0, _, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .R, r0, PH / 2, false)
			update_handle_drag(&c, canvas, 9999, PH / 2, false) // way right of the canvas
			l, r, _, _ := probe_visible_edges(&c)
			check(&fail, abs(r - 9999) <= 0.5, "right: driven right must follow the pointer beyond the canvas", l, r, 0, 0)
			check(&fail, abs(l - 0) <= 0.5, "right: pinned left must not move", l, r, 0, 0)
		}

		// --- Case 11: RIGHT handle returns inside: driven edge tracks the pointer.
		{
			c := mk_probe_clip()
			_, r0, _, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .R, r0, PH / 2, false)
			update_handle_drag(&c, canvas, PW / 2, PH / 2, false)
			l, r, _, _ := probe_visible_edges(&c)
			check(&fail, abs(r - PW/2) <= 0.5, "right: driven right should track the pointer", l, r, 0, 0)
			check(&fail, abs(l - 0) <= 0.5, "right: pinned left must not move", l, r, 0, 0)
		}

		// --- Case 12: RIGHT handle snaps its driven edge to the border.
		{
			c := mk_probe_clip()
			_, r0, _, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .R, r0, PH / 2, false)
			update_handle_drag(&c, canvas, PW + 2, PH / 2, false) // ~within snap margin
			l, r, _, _ := probe_visible_edges(&c)
			check(&fail, abs(r - PW) <= 0.05, "right: driven right should snap onto the border", l, r, 0, 0)
			check(&fail, abs(l - 0) <= 0.5, "right: pinned left must not move", l, r, 0, 0)
		}

		// --- Case 13: TL corner (0) driven far out: box scales beyond the canvas,
		// the pinned BR corner never moves.
		{
			c := mk_probe_clip()
			l0, r0, t0, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .TL, l0, t0, false)
			update_handle_drag(&c, canvas, -200, -200, false)
			l, r, t, b := probe_visible_edges(&c)
			check(&fail, l < -0.5 && t < -0.5, "tl corner: driven corner must scale beyond the canvas", l, r, t, b)
			check(&fail, abs(r - PW) <= 0.5 && abs(b - PH) <= 0.5, "tl corner: pinned BR must not move", l, r, t, b)
		}

		// --- Case 14: TL corner mostly-vertical drag: dominant axis is vertical, so
		// the top edge lands EXACTLY at the pointer while the perpendicular sweep lags.
		{
			c := mk_probe_clip()
			l0, r0, t0, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .TL, l0, t0, false)
			update_handle_drag(&c, canvas, 10, -600, false) // 10px on x, ~55% on y
			l, r, t, b := probe_visible_edges(&c)
			check(&fail, abs(t - (-600)) <= 0.5, "tl corner: vertical-dominant drag must scale the driven top to the pointer", l, r, t, b)
			check(&fail, abs(r - PW) <= 0.5 && abs(b - PH) <= 0.5, "tl corner: pinned BR must not move", l, r, t, b)
		}

		// --- Case 15: TL corner both driven edges snap flush on the canvas corner.
		{
			c := mk_probe_clip()
			l0, r0, t0, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .TL, l0, t0, false)
			update_handle_drag(&c, canvas, -2, -2, false) // both driven edges within snap margin
			l, r, t, b := probe_visible_edges(&c)
			check(&fail, abs(l - 0) <= 0.25 && abs(t - 0) <= 0.25, "tl corner: both driven edges must snap flush on the canvas corner", l, r, t, b)
			// The flush is now scale-exact about the pinned corner (aspect-matched
			// box), so the pinned BR does NOT ride along: it stays put.
			check(&fail, abs(r - PW) <= 0.5 && abs(b - PH) <= 0.5, "tl corner: pinned BR must not move on a scale-exact snap", l, r, t, b)
		}

		// --- Case 16: TL corner snapped flush, pointer pushed BEYOND the corner:
		// the box FREEZES at its snapped geometry instead of resizing from the
		// opposite (pinned) corner.
		{
			c := mk_probe_clip()
			l0, r0, t0, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .TL, l0, t0, false)
			update_handle_drag(&c, canvas, -2, -2, false) // snap flush on (0,0)
			s_snapped := c.scale
			_, r_snapped, _, b_snapped := probe_visible_edges(&c)
			update_handle_drag(&c, canvas, -400, -400, false) // well beyond the corner
			l, r, t, b := probe_visible_edges(&c)
			check(&fail, abs(l - 0) <= 0.25 && abs(t - 0) <= 0.25, "tl freeze: driven corner must stay flush while the pointer is beyond it", l, r, t, b)
			check(&fail, abs(r - r_snapped) <= 0.5 && abs(b - b_snapped) <= 0.5, "tl freeze: pinned corner must not move while frozen", l, r, t, b)
			check(&fail, abs(c.scale - s_snapped) <= 0.01, "tl freeze: scale must hold while frozen", l, r, t, b)
		}

		// --- Case 17: TL corner frozen, pointer crosses back inside the margin:
		// resize resumes (the box re-detaches and the driven corner tracks again).
		{
			c := mk_probe_clip()
			l0, r0, t0, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .TL, l0, t0, false)
			update_handle_drag(&c, canvas, -2, -2, false) // snap flush
			update_handle_drag(&c, canvas, -200, -200, false) // freeze
			update_handle_drag(&c, canvas, -2, -2, false) // back inside the snap margin
			l, r, t, b := probe_visible_edges(&c)
			check(&fail, abs(l - 0) <= 0.25 && abs(t - 0) <= 0.25, "tl resume: corner re-snaps flush once the pointer is inside again", l, r, t, b)
			update_handle_drag(&c, canvas, PW / 2, PH / 2, false) // well inside the canvas
			l, r, t, b = probe_visible_edges(&c)
			check(&fail, abs(l - PW/2) <= 0.5 && abs(t - PH/2) <= 0.5, "tl resume: driven corner tracks the pointer again after un-freeze", l, r, t, b)
		}

		// --- Case 18: TL corner snap is scale-exact: a full-canvas 16:9 box dragged
		// to (-2,-2) must end at EXACTLY canvas size (scale 1.0), corner flush on
		// (0,0), pinned BR unmoved. (The old rigid-translate snap left the scale
		// ballistic and shifted BR out of the canvas.)
		{
			c := mk_probe_clip()
			l0, r0, t0, _ := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .TL, l0, t0, false)
			update_handle_drag(&c, canvas, -2, -2, false)
			l, r, t, b := probe_visible_edges(&c)
			check(&fail, abs(c.scale - 1.0) <= 0.01, "tl corner: snapped scale must be the exact flush scale (1.0)", l, r, t, b)
			check(&fail, abs(l - 0) <= 0.25 && abs(t - 0) <= 0.25, "tl corner: corner flush", l, r, t, b)
			check(&fail, abs(r - PW) <= 0.5 && abs(b - PH) <= 0.5, "tl corner: pinned BR exactly on its corner", l, r, t, b)
		}

		// --- Case 19: BR corner snap-freeze-resume (mirror of 16/17 for .BR).
		{
			c := mk_probe_clip()
			_, _, _, b0 := probe_visible_edges(&c)
			begin_handle_drag(&c, canvas, .BR, PW, b0, false)
			update_handle_drag(&c, canvas, PW - 2, PH - 2, false) // snap flush BR
			update_handle_drag(&c, canvas, PW + 400, PH + 400, false) // freeze beyond
			l, r, t, b := probe_visible_edges(&c)
			check(&fail, abs(r - PW) <= 0.25 && abs(b - PH) <= 0.25, "br freeze: driven corner stays flush while beyond", l, r, t, b)
			update_handle_drag(&c, canvas, PW - 400, PH - 300, false) // deep inside
			l, r, t, b = probe_visible_edges(&c)
			check(&fail, abs(r - PW) > 50 && abs(b - PH) > 50, "br resume: box must detach once the pointer is inside", l, r, t, b)
		}

		// --- Case 20: TR corner snap-freeze-resume.
		{
			c := mk_probe_clip()
			begin_handle_drag(&c, canvas, .TR, PW, 0, false)
			update_handle_drag(&c, canvas, PW - 2, 2, false) // snap flush TR
			update_handle_drag(&c, canvas, PW + 400, -400, false) // freeze beyond
			l, r, t, b := probe_visible_edges(&c)
			check(&fail, abs(r - PW) <= 0.25 && abs(t - 0) <= 0.25, "tr freeze: driven corner stays flush while beyond", l, r, t, b)
			update_handle_drag(&c, canvas, PW - 400, 300, false) // deep inside
			l, r, t, b = probe_visible_edges(&c)
			check(&fail, abs(r - PW) > 50 && abs(t - 0) > 50, "tr resume: box must detach once the pointer is inside", l, r, t, b)
		}

		// --- Case 21: BL corner snap-freeze-resume.
		{
			c := mk_probe_clip()
			begin_handle_drag(&c, canvas, .BL, 0, PH, false)
			update_handle_drag(&c, canvas, 2, PH - 2, false) // snap flush BL
			update_handle_drag(&c, canvas, -400, PH + 400, false) // freeze beyond
			l, r, t, b := probe_visible_edges(&c)
			check(&fail, abs(l - 0) <= 0.25 && abs(b - PH) <= 0.25, "bl freeze: driven corner stays flush while beyond", l, r, t, b)
			update_handle_drag(&c, canvas, 400, PH - 300, false) // deep inside
			l, r, t, b = probe_visible_edges(&c)
			check(&fail, abs(l - 0) > 50 && abs(b - PH) > 50, "bl resume: box must detach once the pointer is inside", l, r, t, b)
		}

		// --- Case 22: freeze requires the pointer DIAGONALLY beyond the corner
		// (both axes). Once one axis returns inside the canvas the box must detach
		// immediately -- single-axis-beyond behaves like an edge drag -- so a sweep
		// along the bottom/top edge plane never leaves the handle stuck. Only the
		// diagonal overflow freezes.
		{
			c := mk_probe_clip()
			begin_handle_drag(&c, canvas, .BR, PW, PH, false)
			update_handle_drag(&c, canvas, PW - 2, PH - 2, false) // snap flush BR
			update_handle_drag(&c, canvas, PW + 400, PH + 400, false) // diagonal beyond -> held
			l, r, t, b := probe_visible_edges(&c)
			check(&fail, abs(r - PW) <= 0.25 && abs(b - PH) <= 0.25, "br diagonal: beyond on both axes holds the flush box", l, r, t, b)
			update_handle_drag(&c, canvas, PW - 400, PH + 400, false) // x back inside, y still beyond
			l, r, t, b = probe_visible_edges(&c)
			check(&fail, abs(r - PW) > 50, "br single-axis: box detaches as soon as one axis returns inside", l, r, t, b)
			check(&fail, abs(b - PH) > 50, "br single-axis: driven corner follows the pointer again", l, r, t, b)
		}

		// --- Case 23: the fit-to-window toggle pins the camera to the contain-fit
		// even when zoom/pan were dirtied, and releasing it lets the manual camera
		// apply. This is the "always fits" invariant the toolbar toggle relies on.
		{
			preview_cam.fit_to_window = true
			preview_cam.zoom = 4
			preview_cam.ox = 123
			preview_cam.oy = -45
			v := preview_view(canvas)
			check(
				&fail,
				abs(preview_cam.zoom - 1) <= 0.0001 &&
				abs(preview_cam.ox) <= 0.0001 &&
				abs(preview_cam.oy) <= 0.0001,
				"fit: dirty camera must snap back to zoom 1 / no pan",
				v.x,
				v.x + v.width,
				v.y,
				v.y + v.height,
			)
			check(
				&fail,
				abs(v.x - canvas.x) <= 0.0001 && abs(v.width - canvas.width) <= 0.0001,
				"fit: view must equal the base canvas",
				v.x,
				v.x + v.width,
				v.y,
				v.y + v.height,
			)
			preview_cam.fit_to_window = false
			preview_cam.zoom = 2
			v = preview_view(canvas)
			check(
				&fail,
				abs(v.width - canvas.width * 2) <= 0.0001,
				"released: manual zoom must apply",
				v.x,
				v.x + v.width,
				v.y,
				v.y + v.height,
			)
			preview_cam.fit_to_window = true
		}

		// --- the shared text box: preview and export must place a text clip in the
		// same rectangle. This is the one duplication that changed OUTPUT rather than
		// just removing a copy -- render_text_blit used to scale the raster's measured
		// tight-ink rect while the preview used the clip's base dims, so the two
		// differed in HEIGHT by the font's metric line box (ascent + descent +
		// TEXT_BOX_PAD) around the ink. Every text/subtitle case above measured a
		// VIDEO box, so nothing caught it.
		//
		// The property under test is the box both sinks derive, not a baked
		// rectangle: the preview's clip_image_bounds_geom text branch and the export's
		// render_text_blit now call text_box_dims, so the assertion is that the
		// preview's box equals what the export computes from the same inputs at
		// several scales. A single scale could agree by luck.
		{
			bw, bh: c.int = 320, 96 // base ink dims at font 48
			text_ok := true
			for scale in ([]f32{0.5, 1.0, 1.8, 3.0}) {
				geom: Geom_Sample
				geom[int(Render_Geom_Prop.Scale)] = scale
				geom[int(Render_Geom_Prop.Trans_X)] = f32(project.width) / 2
				geom[int(Render_Geom_Prop.Trans_Y)] = f32(project.height) / 2
				canvas := probe_canvas()
				pv := clip_image_bounds_geom(canvas, .Text, geom, bw, bh)
				// What the export derives for the same clip: the shared helper at the
				// output width. Same proc, so this asserts the CALLERS pass the same
				// inputs rather than that the arithmetic agrees with itself.
				ew, eh := text_box_dims(bw, bh, scale, f32(project.width))
				if abs(pv.width - ew) > 0.01 || abs(pv.height - eh) > 0.01 {
					text_ok = false
					fmt.printf(
						"[transform-probe] FAIL text box scale=%.1f preview %.2fx%.2f export %.2fx%.2f\n",
						scale, pv.width, pv.height, ew, eh,
					)
				}
				// The box is centered on the transform, and it must actually respond
				// to scale -- a box frozen at scale 1 would satisfy a naive equality.
				if abs(pv.width - f32(bw) * scale * f32(project.width) / f32(PREVIEW_W)) > 0.01 {
					text_ok = false
					fmt.printf(
						"[transform-probe] FAIL text box width does not track scale at %.1f: %.2f\n",
						scale, pv.width,
					)
				}
				// Centered: the transform maps to the box's midpoint, which is the
				// anchor Active 25 unified text onto.
				cx, cy := project_to_pixel(canvas, geom[int(Render_Geom_Prop.Trans_X)], geom[int(Render_Geom_Prop.Trans_Y)])
				if abs((pv.x + pv.width / 2) - cx) > 0.01 || abs((pv.y + pv.height / 2) - cy) > 0.01 {
					text_ok = false
					fmt.printf(
						"[transform-probe] FAIL text box center %.2f,%.2f is not the transform %.2f,%.2f\n",
						pv.x + pv.width / 2, pv.y + pv.height / 2, cx, cy,
					)
				}
			}
			check(&fail, text_ok, "text box: preview and export must place the same rectangle", 0, 0, 0, 0)
		}

		// --- the source-frame mapping: one helper, so a clip cannot preview one
		// frame and export another. Three sites used to spell it out, each with its
		// own still-image special case.
		{
			sf_ok := true
			// A non-still maps linearly from its source offset.
			for off in ([]i64{0, 1, 30, 90}) {
				got := clip_source_frame(10, 5, 5 + off, false, project_fps())
				if got != 10 + off {
					sf_ok = false
					fmt.printf(
						"[transform-probe] FAIL source frame: off %d gave %d, want %d\n", off, got, 10 + off,
					)
				}
			}
			// A still pins every timeline frame in its span to its one source frame.
			for off in ([]i64{0, 1, 30, 90}) {
				got := clip_source_frame(7, 5, 5 + off, true, project_fps())
				if got != 7 {
					sf_ok = false
					fmt.printf(
						"[transform-probe] FAIL still frame: off %d gave %d, want 7\n", off, got,
					)
				}
			}
			check(&fail, sf_ok, "source frame: one mapping for preview, export and the proxy picker", 0, 0, 0, 0)

		// --- a clip's SPEED must not depend on the project rate. This is the defect
		// the conform fixes: the mapping used to be unconditionally 1:1, so the
		// project rate WAS every clip's playback speed, and changing it retimed the
		// whole project with no setting anywhere that said so.
		//
		// The property asserted is real-world speed, not per-frame arithmetic: the
		// source frames a clip shows per second of its own playback must equal the
		// source's rate, whatever the project rate is. Asserted by WALKING the clip
		// and timing it, because a per-frame expectation would pass for a mapping
		// that was right on the frames sampled and wrong between them.
		{
			sp_ok := true
			saved_fps := project.frame_rate
			defer project.frame_rate = saved_fps

			SRC_FPS  :: f64(30.0)
			CLIP_SEC :: f64(2.0)

			for proj_fps in ([]f64{24.0, 25.0, 30.0, 50.0, 60.0, 59.94, 29.97}) {
				project.frame_rate = proj_fps
				// The clip occupies exactly CLIP_SEC of its source's content. At a
				// project rate of P that is CLIP_SEC*P timeline frames.
				clip_frames := i64(math.round(CLIP_SEC * proj_fps))
				// How far through the SOURCE it advanced, over the frames it played.
				// Counting DISTINCT frames instead measures the window's edges, not
				// the rate: a 30fps source on a 60fps timeline ends its last frame on
				// 59.5 and rounds up, so 120 timeline frames show 61 distinct frames,
				// not 60.
				advanced := f64(clip_source_frame(0, 0, clip_frames, false, SRC_FPS))
				played := f64(clip_frames)
				// Playback elapsed is played/proj seconds and content elapsed is
				// advanced/SRC_FPS seconds. Native speed means they are equal, i.e. the
				// advance rate is exactly SRC_FPS/proj_fps. One source frame of slack
				// absorbs the rounding at the single boundary frame.
				rate_error := math.abs(advanced / played - SRC_FPS / proj_fps) * played
				if rate_error > 1.0 + 0.001 {
					sp_ok = false
					fmt.printf(
						"[transform-probe] FAIL speed: project %.4f fps, a %.0ffps clip %v frames long advanced %.2f source frames, want %.2f (off by %.2f)\n",
						proj_fps, SRC_FPS, clip_frames, advanced, played * SRC_FPS / proj_fps, rate_error,
					)
				}
			}
			project.frame_rate = saved_fps

			// And the direction, asserted as an ADVANCE RATE at concrete frames
			// rather than as a phase convention. The conform is nearest-frame, so a
			// timeline frame sitting exactly between two source frames (f=1 at ratio
			// 0.5) resolves to the LATER one -- a half-source-frame phase shift at
			// most, and not drift, which is the property that matters. Pinning the
			// phase here would be asserting the rounding, not the speed.
			project.frame_rate = 60.0
			hold_ok := clip_source_frame(0, 0, 0, false, 30.0) == 0 &&
				clip_source_frame(0, 0, 2, false, 30.0) == 1 &&
				clip_source_frame(0, 0, 4, false, 30.0) == 2 &&
				clip_source_frame(0, 0, 100, false, 30.0) == 50
			// And the reverse: a 60fps source on a 30fps timeline DROPS frames —
			// two source frames per timeline frame. The rate has to be set HERE: read
			// at the 60fps left over from the case above, src==proj and the case
			// silently degrades to checking 1:1.
			project.frame_rate = 30.0
			drop_ok := clip_source_frame(0, 0, 0, false, 60.0) == 0 &&
				clip_source_frame(0, 0, 1, false, 60.0) == 2 &&
				clip_source_frame(0, 0, 10, false, 60.0) == 20
			// The decoder-facing invariant: the mapping NEVER goes backwards, in
			// either direction and at any rate. A non-monotonic conform would make the
			// decoder seek backwards on every frame of the clip.
			mono_ok := true
			for rate in ([]f64{23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0, 120.0}) {
				for proj in ([]f64{24.0, 30.0, 60.0}) {
					project.frame_rate = proj
					prev := clip_source_frame(0, 0, 0, false, rate)
					for f in 1 ..< 600 {
						cur := clip_source_frame(0, 0, i64(f), false, rate)
						if cur < prev {
							mono_ok = false
							fmt.printf(
								"[transform-probe] FAIL monotonic: src %.3f at project %.2f went backwards at frame %d (%d -> %d)\n",
								rate, proj, f, prev, cur,
							)
							break
						}
						prev = cur
					}
				}
			}
			// A non-integer rate ratio is where a truncating conform shows: 30/29.97
			// never lands on a whole frame, so truncating creeps early every frame and
			// the clip gains a frame of lead. Rounding must not.
			project.frame_rate = 29.97
			frac_ok := true
			for f in 1 ..< 200 {
				want := i64(math.round(f64(f) * (30.0 / 29.97)))
				got := clip_source_frame(0, 0, i64(f), false, 30.0)
				if got != want {
					frac_ok = false
					fmt.printf(
						"[transform-probe] FAIL non-integer ratio: frame %d gave source %d, want %d\n",
						f, got, want,
					)
					break
				}
			}
			project.frame_rate = saved_fps

			check(&fail, hold_ok, "speed: a 30fps source on a 60fps timeline holds each frame twice", 0, 0, 0, 0)
			check(&fail, drop_ok, "speed: a 60fps source on a 30fps timeline drops frames", 0, 0, 0, 0)
			check(&fail, frac_ok, "speed: a non-integer rate ratio does not creep", 0, 0, 0, 0)
			check(&fail, mono_ok, "speed: the mapping never runs backwards, at any rate pair", 0, 0, 0, 0)

			// An UNPINNED clip (src_fps 0, a project saved before the field existed)
			// must keep the historical 1:1 exactly, whatever the project rate is.
			// Silently re-speeding old projects on load would be a worse bug than
			// the one being fixed.
			unpinned_ok := true
			for proj_fps in ([]f64{24.0, 30.0, 60.0}) {
				project.frame_rate = proj_fps
				for off in ([]i64{0, 1, 7, 90}) {
					if clip_source_frame(10, 5, 5 + off, false, 0) != 10 + off {
						unpinned_ok = false
						fmt.printf(
							"[transform-probe] FAIL unpinned: project %.2f fps off %d gave %d, want %d\n",
							proj_fps, off, clip_source_frame(10, 5, 5 + off, false, 0), 10 + off,
						)
					}
				}
			}
			project.frame_rate = saved_fps
			check(&fail, unpinned_ok, "speed: an unpinned clip keeps the historical 1:1 on old projects", 0, 0, 0, 0)

			check(&fail, sp_ok, "speed: a clip plays at its own rate at every project rate", 0, 0, 0, 0)

		// --- clip_source_span: which source frames a clip can show, under conform.
		// Every caller that bounded a source frame by a clip's extent was written for
		// [source_start, source_start+length), and conform makes that identity wrong.
		// Two live failure modes, one in each direction, so both are asserted.
		{
			saved_fps2 := project.frame_rate
			defer project.frame_rate = saved_fps2

			// The case that FROZE the preview: a 60fps source on a 30fps timeline
			// displays twice the source its 300-frame extent implies, so the old
			// window rejected every frame past 300 as stale and the clip stopped
			// updating. The span must cover what is actually shown.
			project.frame_rate = 30.0
			lo, hi := clip_source_span(0, 0, 300, 60.0)
			// 300 timeline frames at ratio 2 cover source frames 0,2,...,598.
			span_wide_ok := hi == 599 && lo == 0
			// And it must contain the last frame the clip really shows.
			shown_last := clip_source_frame(0, 0, 299, false, 60.0)
			span_wide_ok = span_wide_ok && shown_last < hi && shown_last >= lo
			if !span_wide_ok {
				fmt.printf(
					"[transform-probe] FAIL span wide: 60fps source on a 30fps timeline over 300 frames gave [%d,%d), last shown %d\n",
					lo, hi, shown_last,
				)
			}

			// The permissive direction: a 30fps source on a 60fps timeline displays
			// only 150 of the 300 frames the old window would have accepted, so a
			// stale async result at frame 200 could pass as this clip's.
			project.frame_rate = 60.0
			lo2, hi2 := clip_source_span(0, 0, 300, 30.0)
			// 300 timeline frames at ratio 0.5 cover 0,0,1,1,...,150.
			span_tight_ok := hi2 == 151 && lo2 == 0
			if !span_tight_ok {
				fmt.printf(
					"[transform-probe] FAIL span tight: 30fps source on a 60fps timeline over 300 frames gave [%d,%d), want [0,151)\n",
					lo2, hi2,
				)
			}

			// The identity must still hold exactly when unpinned or rate-equal, or
			// every pre-conform project changes behaviour.
			project.frame_rate = 30.0
			lo3, hi3 := clip_source_span(10, 5, 300, 0)
			lo4, hi4 := clip_source_span(10, 5, 300, 30.0)
			identity_ok := lo3 == 10 && hi3 == 310 && lo4 == 10 && hi4 == 310
			// A zero-length clip is degenerate, not inverted: an empty range, not a
			// backwards one.
			lo5, hi5 := clip_source_span(10, 5, 0, 60.0)
			identity_ok = identity_ok && lo5 == 10 && hi5 == 10
			project.frame_rate = saved_fps2

			check(&fail, span_wide_ok, "span: covers every source frame a conformed clip shows", 0, 0, 0, 0)
			check(&fail, span_tight_ok, "span: excludes frames beyond what a conformed clip shows", 0, 0, 0, 0)
			check(&fail, identity_ok, "span: unpinned and rate-equal clips keep the identity window", 0, 0, 0, 0)
		}
		}
		}

		if !fail {
			fmt.println("[transform-probe] OK: driven edge tracks the pointer, snaps only the active handle, pinned edge holds; text box and source frame shared")
			os.exit(0)
		}
		os.exit(1)
	}

}
