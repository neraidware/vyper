package main

import "core:c"
import "core:fmt"
import "core:math"

// Headless probe for render_kf_geom_rect (render.odin:586) — the pure
// per-frame keyed-geometry math the compositor worker calls in
// render_eval_keyed_geom (render.odin:2334). The probe fills each
// Render_Kf_Flat slot through the exact worker path — kf_set_key into a Clip,
// then kf_fill_snapshot into the fixed keys array via render_geom_name — so a
// mismatch between the worker's fill and the pure rect's expectations trips
// the build, not a silent wrong composite.

import "base:intrinsics"

render_kf_probe_fail := false

render_kf_probe_check :: proc(cond: bool, msg: string, args: ..any) {
	if !cond {
		render_kf_probe_fail = true
		fmt.println("[render-kf-probe] FAIL:", fmt.tprintf(msg, ..args))
	}
}

// kf_probe_base is the resting base a fixture snapshots: identity transform,
// unit scale, no crop, and the given resting opacity. Expressed in named lanes
// because that is what a fixture means by it.
kf_probe_base :: proc(op: f32) -> Geom_Sample {
	b: Geom_Sample
	b[int(Render_Geom_Prop.Scale)] = 1.0
	b[int(Render_Geom_Prop.Opacity)] = op
	return b
}

// The values are appended HERE, so a caller's format string stays a plain
// description of the check. Passing them through as bare extra args produced
// `%!(EXTRA ...)` on every failure, which is exactly the line an author reads
// to find out what broke.
render_kf_probe_check_near :: proc(got, want, eps: f32, msg: string) {
	render_kf_probe_check(
		math.abs(got - want) <= eps,
		"%s: got %.4f, want %.4f, eps %.4f",
		msg, got, want, eps,
	)
}

render_kf_fill_flat :: proc(clip: ^Clip, p: Render_Geom_Prop) -> (flat: Render_Kf_Flat) {
	flat.n, _ = kf_geom_fill_snapshot(clip, render_geom_name(p), flat.keys[:])
	return
}

render_kf_probe_run :: proc() -> int {
	// Case A — transform.x keyed 0 @1 -> 100 @30; everything else rests at
	// its base (tx/ty baseline 0, scale 1, no crops). Box == full stage.
	clipA := Clip{}
	kf_geom_set_lane_key(&clipA, render_geom_name(Render_Geom_Prop.Trans_X), 1, 0)
	kf_geom_set_lane_key(&clipA, render_geom_name(Render_Geom_Prop.Trans_X), 7, 100)
	geomA: [int(Render_Geom_Prop._COUNT)]Render_Kf_Flat
	geomA[int(Render_Geom_Prop.Trans_X)] = render_kf_fill_flat(&clipA, Render_Geom_Prop.Trans_X)
	geomA[int(Render_Geom_Prop.Trans_Y)] = render_kf_fill_flat(&clipA, Render_Geom_Prop.Trans_Y)
	geomA[int(Render_Geom_Prop.Scale)] = render_kf_fill_flat(&clipA, Render_Geom_Prop.Scale)
	geomA[int(Render_Geom_Prop.Crop_L)] = render_kf_fill_flat(&clipA, Render_Geom_Prop.Crop_L)
	geomA[int(Render_Geom_Prop.Crop_R)] = render_kf_fill_flat(&clipA, Render_Geom_Prop.Crop_R)
	geomA[int(Render_Geom_Prop.Crop_T)] = render_kf_fill_flat(&clipA, Render_Geom_Prop.Crop_T)
	geomA[int(Render_Geom_Prop.Crop_B)] = render_kf_fill_flat(&clipA, Render_Geom_Prop.Crop_B)

	tx_a, _, s_a, _, _, _, _, _, ox_a, _, rw_a, _, _, _, _, _ :=
		render_kf_geom_rect(&geomA, 1, kf_probe_base(1.0), 100, 100, 100, 100, 100, 100)
	// off=1 is exactly the frame of the first key (tx=0), scale rests at 1,
	// so the box is the full stage centered on the resting tx (=0, base tx).
	render_kf_probe_check(ox_a == -50 && rw_a == 100,
		"A at first key: got ox=%d rw=%d want -50 100", ox_a, rw_a)

	txA, _, sA, _, _, _, _, _, oxA, _, rwA, _, _, _, _, _ :=
		render_kf_geom_rect(&geomA, 9, kf_probe_base(1.0), 100, 100, 100, 100, 100, 100)

	// Scale rests at 1 -> cw = draw_w * s = 100, ox centered on sampled tx.
	// tx at off 9 between keys 1..7: lerp 0 -> 100 gives 133.3 past end;
	// sampling clamps past-last to base (resting) because kf_fill_snapshot
	// only copied keys whose range covers the frame. So tx rests at base 0.
	render_kf_probe_check(oxA == -50 && rwA == 100,
		"A rests past last key: got ox=%d rw=%d want -50 100", oxA, rwA)

	// Case B — crop-l keyed 0.25 with scale rest and tx rest: the box trims
	// left, src sub-rect cuts into the stage, ox/rw follow the visible rect.
	geomB: [int(Render_Geom_Prop._COUNT)]Render_Kf_Flat
	clipB := Clip{}
	kf_geom_set_lane_key(&clipB, render_geom_name(Render_Geom_Prop.Crop_L), 1, 0.25)
	kf_geom_set_lane_key(&clipB, render_geom_name(Render_Geom_Prop.Crop_L), 2, 0.25)
	for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
		p := Render_Geom_Prop(pi)
		geomB[int(p)] = render_kf_fill_flat(&clipB, p)
	}
	_, _, _, clB, _, _, _, _, oxB, _, rwB, _, _, _, _, _ :=
		render_kf_geom_rect(&geomB, 1, kf_probe_base(1.0), 100, 100, 100, 100, 100, 100)
	render_kf_probe_check_near(clB, 0.25, 0.0001, "B crop-l sampled")
	render_kf_probe_check(oxB == -25 && rwB == 75,
		"B src sub-rect + box trim left: got ox=%d rw=%d want -25 75", oxB, rwB)

	// Case C — the eased mode flows through the WORKER seam end to end. The
	// seam copies the track into the flat worker copy (kf_geom_fill_snapshot)
	// and the rect's sampler (kf_sample_keys) then eases with it. Keys tx
	// 0@1 -> 100@21, arriving key .Ease_In: at off=11 (t=1/2) the t^3 curve
	// gives 12.5, box 100 wide -> l=-37.5, ox=-38. A linear path would give
	// 50 / ox 0, so a dropped interp trips this hard.
	clipC := Clip{}
	kf_geom_set_lane_key(&clipC, render_geom_name(Render_Geom_Prop.Trans_X), 1, 0)
	kf_geom_set_lane_key(&clipC, render_geom_name(Render_Geom_Prop.Trans_X), 21, 100)
	clipC.keyframe_tracks[0].keys[0].interp = .Ease_Out
	clipC.keyframe_tracks[0].keys[1].interp = .Ease_In
	geomC: [int(Render_Geom_Prop._COUNT)]Render_Kf_Flat
	for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
		p := Render_Geom_Prop(pi)
		geomC[int(p)] = render_kf_fill_flat(&clipC, p)
	}
	// Both modes are non-default so the seam genuinely has to carry per-key
	// interp; a dropped/zeroed mode would fail here (`.Cubic`, the zero
	// value, would only be caught by the eased sample below).
	render_kf_probe_check(
		geomC[int(Render_Geom_Prop.Trans_X)].keys[0].interp == .Ease_Out &&
			geomC[int(Render_Geom_Prop.Trans_X)].keys[1].interp == .Ease_In,
		"worker seam copy carries each key's interpolation mode",
	)
	txC, _, _, _, _, _, _, _, oxC, _, rwC, _, _, _, _, _ :=
		render_kf_geom_rect(&geomC, 11, kf_probe_base(1.0), 100, 100, 100, 100, 100, 100)
	render_kf_probe_check_near(txC, 12.5, 0.001, "C eased tx")
	render_kf_probe_check(oxC == -38 && rwC == 100,
		"C eased box: got ox=%d rw=%d want -38 100", oxC, rwC)

	// Case D — the spline mode through the same worker rect. Keys tx
	// 0@1 100@11 250@21 350@31, all .Cubic: segment 11->21 has symmetric
	// tangents (12.5 both edges), so its midpoint is exactly 175 -> ox 125.
	clipD := Clip{}
	kf_geom_set_lane_key(&clipD, render_geom_name(Render_Geom_Prop.Trans_X), 1, 0)
	kf_geom_set_lane_key(&clipD, render_geom_name(Render_Geom_Prop.Trans_X), 11, 100)
	kf_geom_set_lane_key(&clipD, render_geom_name(Render_Geom_Prop.Trans_X), 21, 250)
	kf_geom_set_lane_key(&clipD, render_geom_name(Render_Geom_Prop.Trans_X), 31, 350)
	dtk := &clipD.keyframe_tracks[0]
	dtk.keys[1].interp = .Cubic
	dtk.keys[2].interp = .Cubic
	dtk.keys[3].interp = .Cubic
	geomD: [int(Render_Geom_Prop._COUNT)]Render_Kf_Flat
	for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
		p := Render_Geom_Prop(pi)
		geomD[int(p)] = render_kf_fill_flat(&clipD, p)
	}
	txD, _, _, _, _, _, _, _, oxD, _, rwD, _, _, _, _, _ :=
		render_kf_geom_rect(&geomD, 16, kf_probe_base(1.0), 100, 100, 100, 100, 100, 100)
	render_kf_probe_check_near(txD, 175.0, 0.001, "D spline tx")
	render_kf_probe_check(oxD == 125 && rwD == 100,
		"D spline box: got ox=%d rw=%d want 125 100", oxD, rwD)

	// Case E — the PREVIEW (GPU) seam, kf_geom_sample_lane, the exact call the
	// per-frame preview_state sampling makes before handing floats to the GPU.
	// E1: scalar eased track. E2: a PACKED "transform" section (the grouped
	// form) whose lane is sampled; both must ride the arriving key's mode.
	clipE1 := Clip{}
	kf_set_key(&clipE1, render_geom_name(Render_Geom_Prop.Trans_X), 1, 0)
	kf_set_key(&clipE1, render_geom_name(Render_Geom_Prop.Trans_X), 21, 100)
	clipE1.keyframe_tracks[0].keys[1].interp = .Ease_In
	pe1, _ := kf_geom_sample_lane(&clipE1, render_geom_name(Render_Geom_Prop.Trans_X), 11, 0)
	render_kf_probe_check_near(pe1, 12.5, 0.001, "E1 preview scalar eased")

	clipE2 := Clip{}
	lanesL := [KF_PACK_MAX]f32{}
	lanesH := [KF_PACK_MAX]f32{}
	lanesL[0] = 0
	lanesH[0] = 100
	kf_geom_set_packed(&clipE2, "transform", 1, lanesL, 1)
	kf_geom_set_packed(&clipE2, "transform", 21, lanesH, 1)
	clipE2.keyframe_tracks[0].keys[1].interp = .Ease_In
	pe2, _ := kf_geom_sample_lane(&clipE2, render_geom_name(Render_Geom_Prop.Trans_X), 11, 0)
	render_kf_probe_check_near(pe2, 12.5, 0.001, "E2 preview packed lane eased")

	// Case F — a KEYED opacity lane sampled through the worker's own rect call.
	// This is the end-to-end shape of the feature: the opacity keyframe has to
	// reach the compositor as a per-frame value, not stay a resting field on
	// the clip. It goes through render_geom_name + render_kf_geom_rect (the
	// same two steps render_eval_keyed_geom takes) rather than reading the
	// track directly, so a lane that stops being sampled by the worker is
	// caught here instead of producing a clip that ignores its own fade.
	//
	// The resting value is deliberately 1.0 and the keys fade to 0.25: an
	// un-sampled lane would return that 1.0 base and the check would fail,
	// which is exactly the silent failure -- "keyed, but every frame renders
	// fully opaque" -- that no md5 or static check would notice.
	{
		clipF := Clip{}
		kf_geom_set_lane_key(&clipF, render_geom_name(Render_Geom_Prop.Opacity), 1, 1.0)
		kf_geom_set_lane_key(&clipF, render_geom_name(Render_Geom_Prop.Opacity), 21, 0.25)
		geomF: [int(Render_Geom_Prop._COUNT)]Render_Kf_Flat
		geomF[int(Render_Geom_Prop.Opacity)] =
			render_kf_fill_flat(&clipF, Render_Geom_Prop.Opacity)
		render_kf_probe_check(
			geomF[int(Render_Geom_Prop.Opacity)].n == 2,
			"F fixture: the opacity lane snapshot must carry 2 keys, got %d",
			geomF[int(Render_Geom_Prop.Opacity)].n,
		)
		// off 1 (first key), 11 (midpoint), 21 (last key), 40 (past the end).
		baseF := kf_probe_base(1.0)
		_, _, _, _, _, _, _, op1, _, _, _, _, _, _, _, _ :=
			render_kf_geom_rect(&geomF, 1, baseF, 100, 100, 100, 100, 100, 100)
		_, _, _, _, _, _, _, op11, _, _, _, _, _, _, _, _ :=
			render_kf_geom_rect(&geomF, 11, baseF, 100, 100, 100, 100, 100, 100)
		_, _, _, _, _, _, _, op21, _, _, _, _, _, _, _, _ :=
			render_kf_geom_rect(&geomF, 21, baseF, 100, 100, 100, 100, 100, 100)
		render_kf_probe_check_near(op1, 1.0, 0.001, "F opacity at first key")
		render_kf_probe_check_near(op11, 0.625, 0.001, "F opacity interpolated")
		render_kf_probe_check_near(op21, 0.25, 0.001, "F opacity at last key")
		// Past the last key the lane is INACTIVE and the resting base rules
		// (kf_sample_keys returns base past the final key), so a fade that
		// only covers part of the clip returns to the clip's own opacity
		// rather than sticking at the last key's value. This is the existing
		// sampler contract, shared with every geometry lane.
		_, _, _, _, _, _, _, op40, _, _, _, _, _, _, _, _ :=
			render_kf_geom_rect(&geomF, 40, kf_probe_base(0.8), 100, 100, 100, 100, 100, 100)
		render_kf_probe_check_near(op40, 0.8, 0.001, "F opacity past last key falls back to base")
		// An UNKEYED lane must fall back to the resting base: the base is
		// threaded through render_eval_keyed_geom as the job's geom_base
		// snapshot, and this is what keeps every un-keyed export
		// byte-identical to before.
		_, _, _, _, _, _, _, opBase, _, _, _, _, _, _, _, _ :=
			render_kf_geom_rect(&geomA, 11, kf_probe_base(0.375), 100, 100, 100, 100, 100, 100)
		render_kf_probe_check_near(opBase, 0.375, 0.001, "F un-keyed opacity falls back to base")
	}

	// Case G — one evaluator, two sources. geom_sample_clip (preview, live) and
	// geom_sample_flat (export, the job's flat snapshot) must agree on EVERY
	// Render_Geom_Prop lane, for a clip that keys every lane — including a crop
	// that lives in a PACKED section (the grouped form the flat snapshot has to
	// unpack). A property added to the enum but sampled on only one side, or a
	// packed lane the flat path drops, trips here. This is the drift class S3
	// exists to remove; the two sinks still keep their own per-thread latch, but
	// the values they latch are proven identical.
	{
		clipG := Clip {
			transform_x = 7,
			transform_y = -7,
			scale       = 1.5,
			crop_l      = 0.01,
			crop_r      = 0.02,
			crop_t      = 0.03,
			crop_b      = 0.04,
			opacity     = 0.9,
		}
		kf_geom_set_lane_key(&clipG, render_geom_name(Render_Geom_Prop.Trans_X), 0, 3)
		kf_geom_set_lane_key(&clipG, render_geom_name(Render_Geom_Prop.Trans_X), 10, 30)
		kf_geom_set_lane_key(&clipG, render_geom_name(Render_Geom_Prop.Trans_Y), 0, -4)
		kf_geom_set_lane_key(&clipG, render_geom_name(Render_Geom_Prop.Trans_Y), 20, 8)
		kf_geom_set_lane_key(&clipG, render_geom_name(Render_Geom_Prop.Scale), 0, 1)
		kf_geom_set_lane_key(&clipG, render_geom_name(Render_Geom_Prop.Scale), 20, 2)
		kf_geom_set_lane_key(&clipG, render_geom_name(Render_Geom_Prop.Opacity), 5, 1)
		kf_geom_set_lane_key(&clipG, render_geom_name(Render_Geom_Prop.Opacity), 15, 0.25)
		lanes0: [KF_PACK_MAX]f32
		lanes0[0] = 0.1
		lanes0[1] = 0.2
		lanes0[2] = 0.05
		lanes0[3] = 0.15
		lanes1: [KF_PACK_MAX]f32
		lanes1[0] = 0.3
		lanes1[1] = 0.4
		lanes1[2] = 0.25
		lanes1[3] = 0.35
		kf_geom_set_packed(&clipG, "crop", 0, lanes0, 0xF)
		kf_geom_set_packed(&clipG, "crop", 20, lanes1, 0xF)

		flatG: [int(Render_Geom_Prop._COUNT)]Render_Kf_Flat
		baseG: Geom_Sample
		for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
			p := Render_Geom_Prop(pi)
			flatG[pi] = render_kf_fill_flat(&clipG, p)
			baseG[pi] = geom_resting_value(&clipG, p)
		}
		// off 0 (first keys), 10 (between), 20 (last keys), 30 (past the end,
		// so both fall back to the shared resting base).
		for off in ([]i32{0, 10, 20, 30}) {
			live := geom_sample_clip(&clipG, i64(off))
			flat := geom_sample_flat(baseG, &flatG, off)
			for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
				render_kf_probe_check(
					math.abs(flat[pi] - live[pi]) <= 0.0001,
					"G lane %s: flat export %.4f != live preview %.4f",
					render_geom_name(Render_Geom_Prop(pi)),
					flat[pi],
					live[pi],
				)
			}
		}
	}

	// Case H — the resting base must NOT drift across composite frames.
	// render_eval_keyed_geom is called with a keyed opacity lane, and the alpha
	// it writes for frame N must not become frame N+1's fallback. The old field
	// served as both the resting base and the per-frame alpha, so a fade that
	// covers only part of a clip kept the LAST KEYED value forever after:
	// frames past the final key blended at that value instead of the clip's own
	// opacity. Nothing downstream could see it -- the fade looked right over the
	// keyed range and wrong after it -- and the same frame re-evaluated on a
	// re-render came out different.
	//
	// This drives the real proc (not render_kf_geom_rect) because the defect was
	// in which value the proc READ as its base, which only shows up across calls.
	{
		probe_w :: 100
		probe_h :: 100
		saved_w, saved_h := render_job.width, render_job.height
		render_job.width, render_job.height = probe_w, probe_h

		clipH := Clip {opacity = 1.0}
		kf_geom_set_lane_key(&clipH, render_geom_name(Render_Geom_Prop.Opacity), 1, 1.0)
		kf_geom_set_lane_key(&clipH, render_geom_name(Render_Geom_Prop.Opacity), 11, 0.25)

		v: Render_Video_Src
		v.timeline_start_frame = 0
		v.source_w = probe_w
		v.source_h = probe_h
		v.geom_base = geom_sample_resting(&clipH)
		for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
			p := Render_Geom_Prop(pi)
			v.kf_geom[pi] = render_kf_fill_flat(&clipH, p)
		}
		// Unit scale on a source the size of the canvas, no crop: the display
		// rect and the stage sub-rect coincide, so the composite takes its
		// fixed-scale 1:1 path with no resampler to configure.
		v.stage_scale = 1.0
		v.fw = probe_w
		v.fh = probe_h
		v.opacity = v.geom_base[int(Render_Geom_Prop.Opacity)]

		stage: [probe_w * probe_h * 4]u8
		frame: [probe_w * probe_h * 4]u8
		slot := Render_Blit_Slot{blit = stage[:]}

		// Inside the fade, then past its last key. Order matters: the stale-base
		// read only shows up on the SECOND call.
		render_eval_keyed_geom(&v, 6, &slot, frame[:], nil)
		render_kf_probe_check_near(
			v.opacity,
			0.625,
			0.001,
			"H keyed frame blends the interpolated alpha",
		)
		render_eval_keyed_geom(&v, 40, &slot, frame[:], nil)
		render_kf_probe_check_near(
			v.opacity,
			1.0,
			0.001,
			"H past the last key falls back to the resting base, not the last sample",
		)
		render_job.width, render_job.height = saved_w, saved_h
	}

	if render_kf_probe_fail {
		fmt.println("[render-kf-probe] failed")
		return 1
	}
	fmt.println("[render-kf-probe] ok")
	return 0
}
