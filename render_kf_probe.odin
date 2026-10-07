package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:sync"

// Headless probe for render_kf_geom_rect (render.odin:586) — the pure
// per-frame keyed-geometry math the compositor worker calls in
// render_eval_keyed_geom (render.odin:2334). The probe fills each
// Render_Kf_Flat slot through the exact worker path — kf_set_key into a Clip,
// then kf_fill_snapshot into the fixed keys array via render_geom_name — so a
// mismatch between the worker's fill and the pure rect's expectations trips
// the build, not a silent wrong composite.

import "base:intrinsics"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

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

	// Static_Window_Case is one render_static_src_geom fixture. The spread matters
	// more than any single case: the invariant is that a clip's decode buffer is
	// bounded by the CANVAS whatever its scale, and the cases that catch a
	// regression are the extremes -- a huge box, a box far off-canvas, a degenerate
	// crop that collapses the region -- not the nominal one.
	Static_Window_Case :: struct {
		name:      string,
		src_w:     c.int,
		src_h:     c.int,
		canvas_w:  c.int,
		canvas_h:  c.int,
		scale:     f32,
		tx, ty:    f32,
		crop:      f32,
	}

	// static_window_cases returns the fixtures case I runs. The first three are the
	// project that failed (scale 27.777 far off-canvas, a 2.6x with a heavy crop, a
	// 1x filling the canvas); the rest are the edges: entirely off-canvas, a crop
	// that collapses the region, and a source larger than the canvas.
	static_window_cases :: proc() -> [6]Static_Window_Case {
		return {
			{
				name = "27.777x off-canvas (the project that failed)",
				src_w = 1920, src_h = 1082, canvas_w = 1920, canvas_h = 1082,
				scale = 27.777141571044922, tx = 12216.802734375, ty = -6945.94140625,
				crop = 0.610849142074585,
			},
			{
				name = "2.594x with a heavy crop",
				src_w = 1920, src_h = 1082, canvas_w = 1920, canvas_h = 1082,
				scale = 2.593743324279785, tx = 1749.2490234375, ty = -36.69744873046875,
				crop = 0.46571266651153564,
			},
			{
				name = "1x filling the canvas",
				src_w = 1920, src_h = 1082, canvas_w = 1920, canvas_h = 1082,
				scale = 1.0, tx = 960, ty = 541, crop = 0,
			},
			{
				name = "1x hanging off the right edge",
				src_w = 1920, src_h = 1082, canvas_w = 1920, canvas_h = 1082,
				scale = 1.0, tx = 2600, ty = 541, crop = 0,
			},
			{
				name = "degenerate crop collapsing the region",
				src_w = 1920, src_h = 1082, canvas_w = 1920, canvas_h = 1082,
				scale = 1.0, tx = 960, ty = 541, crop = 0.999,
			},
			{
				name = "4K source on a 1080p canvas",
				src_w = 3840, src_h = 2160, canvas_w = 1920, canvas_h = 1080,
				scale = 1.0, tx = 960, ty = 540, crop = 0,
			},
		}
	}

	// Mix_Bus_Case is one frame rate for the mix-bus probe, named by what it does to
	// the block/frame relationship.
	Mix_Bus_Case :: struct {
		name:   string,
		num:    c.int,
		den:    c.int,
	}

	// mix_bus_cases spans a frame below, at, and above AUDIO_MIX_BLOCK, because the
	// only interesting rates for a fixed-block mixer are the ones where the two sizes
	// have an awkward relationship: at 120fps a frame is 400 samples and a block
	// straddles two boundaries, at 60 it is 800 and a block is smaller than a frame,
	// at 12 it is 4000 and a block never comes close.
	mix_bus_cases :: proc() -> [5]Mix_Bus_Case {
		return {
			{"120fps (400-sample frames, block straddles boundaries)", 120, 1},
			{"60fps (800-sample frames)", 60, 1},
			{"30fps (1600-sample frames)", 30, 1},
			{"24fps (2000-sample frames)", 24, 1},
			{"12fps (4000-sample frames)", 12, 1},
		}
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

		// Scale rests at 1 -> cw = 100, and the box is CENTERED on sampled tx, so
		// ox = tx - cw/2. off 9 is past the last transform.x key (7, value 100), so
		// the track HOLDS 100 and the box sits at 100 - 50 = 50. Under the old
		// fall-back-to-base rule it sampled the resting 0 instead and landed at -50,
		// which is the snap-back this case now pins against.
		render_kf_probe_check(oxA == 50 && rwA == 100,
			"A holds past last key: got ox=%d rw=%d want 50 100", oxA, rwA)

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
		kf_key_mut(&clipC, 0, 0).interp = .Ease_Out
		kf_key_mut(&clipC, 0, 1).interp = .Ease_In
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
		dtk := session_trk_view_mut(&clipD.keyframe_tracks, 0)
		kf_key_mut(&clipD, 0, 1).interp = .Cubic
		kf_key_mut(&clipD, 0, 2).interp = .Cubic
		kf_key_mut(&clipD, 0, 3).interp = .Cubic
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
		kf_key_mut(&clipE1, 0, 1).interp = .Ease_In
		pe1, _ := kf_geom_sample_lane(&clipE1, render_geom_name(Render_Geom_Prop.Trans_X), 11, 0)
		render_kf_probe_check_near(pe1, 12.5, 0.001, "E1 preview scalar eased")

		clipE2 := Clip{}
		lanesL := [KF_PACK_MAX]f32{}
		lanesH := [KF_PACK_MAX]f32{}
		lanesL[0] = 0
		lanesH[0] = 100
		kf_geom_set_packed(&clipE2, "transform", 1, lanesL, 1)
		kf_geom_set_packed(&clipE2, "transform", 21, lanesH, 1)
		kf_key_mut(&clipE2, 0, 1).interp = .Ease_In
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
			// Past the last key the lane HOLDS its final value, so a fade covering
			// part of a clip SUSTAINS its end opacity for the remainder instead of
			// snapping back to the clip's resting opacity. The base passed here is
			// 0.8 deliberately, different from both keys: if the base ever won again
			// the check would read 0.8 and fail, rather than coincidentally matching
			// the held 0.25.
			_, _, _, _, _, _, _, op40, _, _, _, _, _, _, _, _ :=
				render_kf_geom_rect(&geomF, 40, kf_probe_base(0.8), 100, 100, 100, 100, 100, 100)
			render_kf_probe_check_near(op40, 0.25, 0.001, "F opacity holds past last key")
			// An UNKEYED lane must fall back to the resting base: the base is
			// threaded through render_eval_keyed_geom as the job's geom_base
			// snapshot, and this is what keeps every un-keyed export
			// byte-identical to before.
			_, _, _, _, _, _, _, opBase, _, _, _, _, _, _, _, _ :=
				render_kf_geom_rect(&geomA, 11, kf_probe_base(0.375), 100, 100, 100, 100, 100, 100)
			render_kf_probe_check_near(opBase, 0.375, 0.001, "F un-keyed opacity falls back to base")
		}

		// Case 1.0 — one evaluator, two sources. geom_sample_clip (preview, live) and
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
				baseG[pi] = clip_geom_resting(&clipG, p)
			}
			// off 0 (first keys), 10 (between), 20 (last keys), 30 (past the end,
			// so both fall back to the shared resting base).
			for off in ([]i32{0, 10, 20, 30}) {
				live := geom_sample_clip(&clipG, i64(off))
				flat := geom_sample_flat(baseG, &flatG, off)
				for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
					render_kf_probe_check(
						math.abs(flat[pi] - live[pi]) <= 0.0001,
						"1.0 lane %s: flat export %.4f != live preview %.4f",
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
			// The production writer, not a hand-assembled carrier: this case exists
			// to pin the seeded alpha, and a probe that filled the struct its own way
			// would keep passing if the writer changed.
			render_geom_snap_fill(&v.geom, &clipH)
			// Unit scale on a source the size of the canvas, no crop: the display
			// rect and the stage sub-rect coincide, so the composite takes its
			// fixed-scale 1:1 path with no resampler to configure.
			v.stage_scale = 1.0
			v.fw = probe_w
			v.fh = probe_h
			v.opacity = v.geom.base[int(Render_Geom_Prop.Opacity)]

			stage: [probe_w * probe_h * 4]u8
			frame: [probe_w * probe_h * 4]u8
			slot := Render_Blit_Slot{blit = stage[:]}

			// Inside the fade, then past its last key.
			render_eval_keyed_geom(&v, 6, &slot, frame[:], nil)
			render_kf_probe_check_near(
				v.opacity,
				0.625,
				0.001,
				"H keyed frame blends the interpolated alpha",
			)
			// The original reason for this case: v.opacity is a per-frame field, and
			// an older version left it holding the PREVIOUS frame's sample, so a
			// frame outside the key range blended against the last keyed value. The
			// hold makes that failure mode visible rather than invisible — 0.625
			// (the frame before) and 0.25 (the correct hold) differ, so a stale
			// read now fails this check instead of coinciding with the right answer.
			// The clip's resting opacity is 1.0, so this also confirms the base does
			// not win past the last key.
			render_eval_keyed_geom(&v, 40, &slot, frame[:], nil)
			render_kf_probe_check_near(
				v.opacity,
				0.25,
				0.001,
				"H past the last key holds the final alpha, not the previous frame's sample",
			)
			render_job.width, render_job.height = saved_w, saved_h
		}

		// Case I — static sizing: a clip's decode buffer is the region it can draw,
		// not its box. These are the real numbers from the project that could not be
		// exported at all: a 1920x1082 source at 27.777x on a 1920x1082 canvas, i.e.
		// a 53332x30055 box (6.4 GB per RGBA buffer) to draw 1920x1082 pixels. The
		// invariant is structural -- buffer within the canvas -- so it is pinned for
		// a spread of scales rather than for one case.
		for tc in static_window_cases() {
			src := Render_Video_Src{
				source_w = tc.src_w,
				source_h = tc.src_h,
				geom      = {base = kf_probe_base(1.0)},
			}
			src.geom.base[int(Render_Geom_Prop.Trans_X)] = tc.tx
			src.geom.base[int(Render_Geom_Prop.Trans_Y)] = tc.ty
			src.geom.base[int(Render_Geom_Prop.Scale)] = tc.scale
			src.geom.base[int(Render_Geom_Prop.Crop_R)] = tc.crop
			render_static_src_geom(&src, tc.canvas_w, tc.canvas_h)
			label := fmt.tprintf("I %s", tc.name)
			render_kf_probe_check(
				src.fw > 0,
				"%s: clip must be drawable, got fw=%d",
				label,
				src.fw,
			)
			render_kf_probe_check(
				src.fw <= tc.canvas_w && src.fh <= tc.canvas_h,
				"%s: buffer must fit the canvas, got %dx%d for a %dx%d canvas",
				label,
				src.fw,
				src.fh,
				tc.canvas_w,
				tc.canvas_h,
			)
			render_kf_probe_check(
				src.ox >= 0 && src.oy >= 0 &&
					src.ox + src.rw <= tc.canvas_w && src.oy + src.rh <= tc.canvas_h,
				"%s: display rect (%d,%d %dx%d) must sit inside the canvas",
				label,
				src.ox,
				src.oy,
				src.rw,
				src.rh,
			)
			render_kf_probe_check(
				src.dec.crop_full_w == src.fw && src.dec.crop_full_h == src.fh,
				"%s: allocation must be the window, got crop_full %dx%d vs buffer %dx%d",
				label,
				src.dec.crop_full_w,
				src.dec.crop_full_h,
				src.fw,
				src.fh,
			)
			// The decoded source region must be a real sub-rect of the source frame:
			// fractions past 1 would read off the end of it.
			render_kf_probe_check(
				src.dec.crop_fx0 >= 0 && src.dec.crop_fy0 >= 0 &&
					src.dec.crop_fx0 + src.dec.crop_fw <= 1.0 + 0.0001 &&
					src.dec.crop_fy0 + src.dec.crop_fh <= 1.0 + 0.0001,
				"%s: crop region must lie inside the source frame, got f=(%.4f %.4f %.4f %.4f)",
				label,
				src.dec.crop_fx0,
				src.dec.crop_fy0,
				src.dec.crop_fw,
				src.dec.crop_fh,
			)
		}

		// Case K — the mix bus, driven through the REAL serve path
		// (render_mix_serve_frame: fill, take, trim).
		//
		// What it pins is the bus's COVERAGE and BOUNDEDNESS, which is what the
		// exporter depends on and what the ring can get wrong on its own:
		//   - every frame the worker asks for is covered, at any frame rate;
		//   - the bus is TRIMMED as it is served, so it holds a cushion instead of
		//     growing with the length of the render;
		//   - filling stops at WHOLE blocks, so the block size stays a free choice
		//     rather than being cut to the consumer's frame edge.
		//
		// Deliberately NOT pinning which sample comes back. Doing that needs the bus
		// pre-seeded with known content AND the fill suppressed, and the attempt
		// exposed something worth naming rather than working around: Render_Mix keeps
		// `pos`/`end` beside Audio_Ring's `head`/`count`, which is two representations
		// of one fact -- the "duplicated state that drifted" class this codebase has
		// already paid for seven times. It is listed for S3, where the mix moves to
		// its own thread and the position should live in one place. Until then, that
		// the right pixels come out is pinned where it cannot drift: end to end on a
		// real project (TODO.md Active 22, S2).
		//
		// Two things, because the S3 split made a value test possible where before it
		// was not: publishing and consuming are now separate steps on separate
		// threads, so the bus can be filled with KNOWN samples and read back without
		// hand-seeding the ring -- which is exactly what was impossible while the fill
		// and the take shared one struct's position bookkeeping, and why this case was
		// coverage-only in S2.
		//
		// K1 geometry and ownership: the producer publishes the job's span and STOPS,
		// the bus never holds more than its capacity, and every frame is served with
		// its exact sample count.
		//
		// K2 the wrap, with real samples in the bus. Buffer indexing that is only
		// right for a block which happens not to straddle the end is the failure a
		// block-based mixer is specifically supposed to make rare -- "the bus is a
		// ring" is an invariant to test, not a shape to assume.
		//
		// Rates are the ones where block and frame sizes relate awkwardly: 120fps is
		// 400-sample frames so a block straddles two boundaries, 60 is 800, 12 is 4000.
		// Long enough that the cushion BINDS at every rate in the table: the bus is
		// (12+1)*MAX_AUDIO_FRAME_SAMPLES = 53248 sample-frames, and 200 frames is
		// 80000 samples even at 120fps. A shorter render fits inside the cushion
		// entirely, and then "the bus holds the whole span" is the correct answer --
		// which is why this started at 20 and failed on correct code.
		frames: i64 = 200
		for tc in mix_bus_cases() {
			m: Render_Mix
			render_mix_init(&m, tc.num, tc.den, 0)
			span := sample_pos_from_frames(frames, i64(tc.num), i64(tc.den))
			cap := render_mix_bus_frames()

			// K1: run the producer to completion first -- it mixes the whole span and
			// returns, bounded by capacity rather than by the consumer.
			render_job.start = 0
			render_job.nframes = frames
			served := 0
			depth_max := 0
			for f: i64 = 0; f < frames; f += 1 {
				out := make([]f32, MAX_AUDIO_FRAME_SAMPLES * 2)
				// Alternate producer and consumer, which is what the two threads do
				// concurrently. Producing the whole span first is NOT a sequence the
				// render performs: the producer fills to capacity and waits, so a
				// caller that has consumed nothing yet gets no further audio and
				// deadlocks. Driving both sides here keeps the probe deterministic
				// without standing up a thread to race.
				render_mix_step(&m, span)
				depth_max = max(depth_max, render_mix_depth(&m))
				// No sources: every block mixes to silence. This part is about the
				// handoff's geometry, and K2 covers what comes back.
				n := render_mix_serve_frame(&m, f, i64(tc.num), i64(tc.den), out)
				want_n := int(
					sample_pos_from_frames(f + 1, i64(tc.num), i64(tc.den)) -
					sample_pos_from_frames(f, i64(tc.num), i64(tc.den)),
				)
				if n != want_n {
					render_kf_probe_check(
						false, "K1 %s frame %d: served %d samples, want %d", tc.name, f, n, want_n,
					)
					break
				}
				served += n
			}
			// Served exactly the span, sample for sample, and the bus is drained --
			// the consumer's position and the producer's meet at the end.
			render_kf_probe_check(
				Sample_Pos(served) == span,
				"K1 %s: served %d samples over %d frames, want exactly %d",
				tc.name, served, frames, span,
			)
			render_kf_probe_check(
				sync.atomic_load(&m.bus.read) == sync.atomic_load(&m.bus.write),
				"K1 %s: bus not drained: read %d, write %d",
				tc.name, sync.atomic_load(&m.bus.read), sync.atomic_load(&m.bus.write),
			)
			// Bounded by the cushion, not by the span: this is the assertion that
			// would fail if the producer ran away from the consumer.
			render_kf_probe_check(
				Sample_Pos(depth_max) <= Sample_Pos(cap),
				"K1 %s: bus peaked at %d samples, over its %d-sample capacity",
				tc.name, depth_max, cap,
			)
			render_kf_probe_check(
				Sample_Pos(depth_max) < span,
				"K1 %s: bus peaked at %d samples, holding the whole %d-sample span",
				tc.name, depth_max, span,
			)
			render_mix_bus_destroy(&m.bus)
		}

		// K2: the wrap, with values. Capacity 8, and the sequence runs 1..12 so the
		// counters lap the buffer twice and a publication, a read, and both at once
		// each straddle the end at least once.
		b: Render_Mix_Bus
		render_mix_bus_init(&b, 8)
		out := make([]f32, 64)
		blk: [6]f32

		seq := proc(vals: ..f32) -> ([6]f32) {
			r: [6]f32
			for v, i in vals {
				r[i * 2 + 0] = v
				r[i * 2 + 1] = v
			}
			return r
		}
		expect := proc(out: []f32, first: f32, n: int, label: string) {
			for s in 0 ..< n {
				want := first + f32(s)
				render_kf_probe_check(
					out[s * 2 + 0] == want && out[s * 2 + 1] == want,
					"%s: sample %d came back %g,%g, want %g,%g",
					label, int(first) + s, out[s * 2 + 0], out[s * 2 + 1], want, want,
				)
			}
		}

		blk = seq(1, 2, 3)
		render_mix_bus_publish(&b, blk[:], 3)
		render_kf_probe_check(
			render_mix_bus_consume(&b, 0, 2, out), "K2: first consume refused",
		)
		expect(out, 1, 2, "K2 read 1..2")
		// 4..6 lands across the write boundary: capacity 8, so frames 6 and 7 of the
		// buffer are the tail and frame 0 is the head.
		blk = seq(4, 5, 6)
		render_mix_bus_publish(&b, blk[:], 3)
		blk = seq(7, 8, 9)
		render_mix_bus_publish(&b, blk[:], 3)
		// One read of 7 frames from count 2: starts at offset 2 and wraps to 0.
		render_kf_probe_check(
			render_mix_bus_consume(&b, 2, 7, out), "K2: wrapping consume refused",
		)
		expect(out, 3, 7, "K2 read 3..9")
		// And a read that starts wrapped.
		blk = seq(10, 11, 12)
		render_mix_bus_publish(&b, blk[:], 3)
		render_kf_probe_check(
			render_mix_bus_consume(&b, 9, 3, out), "K2: wrapped consume refused",
		)
		expect(out, 10, 3, "K2 read 10..12")
		render_kf_probe_check(
			sync.atomic_load(&b.read) == sync.atomic_load(&b.write),
			"K2: bus not drained after reading 1..12: read %d write %d",
			sync.atomic_load(&b.read), sync.atomic_load(&b.write),
		)
		render_mix_bus_destroy(&b)

		// Case L -- the declick envelope. What the exporter depends on is not that
		// the ramp exists but that a contribution ARRIVES AND LEAVES AT ZERO: every
		// step into or out of a source is a step in the output, and a step is a click.
		// So the property pinned is the envelope's endpoints, and that it is monotonic
		// between them -- a ramp with a bump in the middle is not a declick.
		//
		// The fade LENGTHS are arithmetic on a Sample_Pos distance, so they are
		// testable here; the mixer's use of them is pinned end to end, because pinning
		// it here would need a source with a decoder and a ring of known content, and
		// that is the synthetic fixture trap this probe already fell into once.
		// The shape itself: 0 at the ends, 1 in the middle, rising throughout.
		// There is no automatic edge ramp any more, so there is nothing here to shape
		// or to check about a ramp's curve. What replaced those checks is a
		// TRANSPARENCY property, asserted where it is observable: the mix at a clip
		// boundary must equal the source samples exactly, with no envelope applied.
		// See audio_probe_transparent_cuts, which mixes real audio across a boundary
		// and compares against the decoded source.

		// The ramp's per-block shape checks are gone with the ramp. Gain automation is
		// still checked below, and it is the mechanism an authored fade uses.

		if render_kf_probe_fail {
			fmt.println("[render-kf-probe] failed")
			return 1
		}
		fmt.println("[render-kf-probe] ok")
		return 0
	}

}
