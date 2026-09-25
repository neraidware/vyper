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

render_kf_probe_check_near :: proc(got, want, eps: f32, msg: string) {
	render_kf_probe_check(math.abs(got - want) <= eps, msg, got, want, eps)
}

render_kf_fill_flat :: proc(clip: ^Clip, p: Render_Geom_Prop) -> (flat: Render_Kf_Flat) {
	flat.n, _ = kf_fill_snapshot(clip, render_geom_name(p), flat.keys[:])
	return
}

render_kf_probe_run :: proc() -> int {
	// Case A — transform.x keyed 0 @1 -> 100 @30; everything else rests at
	// its base (tx/ty baseline 0, scale 1, no crops). Box == full stage.
	clipA := Clip{}
	kf_set_key(&clipA, render_geom_name(Render_Geom_Prop.Trans_X), 1, 0)
	kf_set_key(&clipA, render_geom_name(Render_Geom_Prop.Trans_X), 7, 100)
	geomA: [int(Render_Geom_Prop._COUNT)]Render_Kf_Flat
	geomA[int(Render_Geom_Prop.Trans_X)] = render_kf_fill_flat(&clipA, Render_Geom_Prop.Trans_X)
	geomA[int(Render_Geom_Prop.Trans_Y)] = render_kf_fill_flat(&clipA, Render_Geom_Prop.Trans_Y)
	geomA[int(Render_Geom_Prop.Scale)] = render_kf_fill_flat(&clipA, Render_Geom_Prop.Scale)
	geomA[int(Render_Geom_Prop.Crop_L)] = render_kf_fill_flat(&clipA, Render_Geom_Prop.Crop_L)
	geomA[int(Render_Geom_Prop.Crop_R)] = render_kf_fill_flat(&clipA, Render_Geom_Prop.Crop_R)
	geomA[int(Render_Geom_Prop.Crop_T)] = render_kf_fill_flat(&clipA, Render_Geom_Prop.Crop_T)
	geomA[int(Render_Geom_Prop.Crop_B)] = render_kf_fill_flat(&clipA, Render_Geom_Prop.Crop_B)

	tx_a, _, s_a, _, _, _, _, ox_a, _, rw_a, _, _, _, _, _ :=
		render_kf_geom_rect(&geomA, 1, 0, 0, 1, 0, 0, 0, 0,
			100, 100, 100, 100, 100, 100)
	// off=1 is exactly the frame of the first key (tx=0), scale rests at 1,
	// so the box is the full stage centered on the resting tx (=0, base tx).
	render_kf_probe_check(ox_a == -50 && rw_a == 100,
		"A at first key: got ox=%d rw=%d want -50 100", ox_a, rw_a)

	txA, _, sA, _, _, _, _, oxA, _, rwA, _, _, _, _, _ :=
		render_kf_geom_rect(&geomA, 9, 0, 0, 1, 0, 0, 0, 0,
			100, 100, 100, 100, 100, 100)

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
	kf_set_key(&clipB, render_geom_name(Render_Geom_Prop.Crop_L), 1, 0.25)
	kf_set_key(&clipB, render_geom_name(Render_Geom_Prop.Crop_L), 2, 0.25)
	for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
		p := Render_Geom_Prop(pi)
		geomB[int(p)] = render_kf_fill_flat(&clipB, p)
	}
	_, _, _, clB, _, _, _, oxB, _, rwB, _, _, _, _, _ :=
		render_kf_geom_rect(&geomB, 1, 0, 0, 1, 0, 0, 0, 0,
			100, 100, 100, 100, 100, 100)
	render_kf_probe_check_near(clB, 0.25, 0.0001, "B crop-l sampled: cl=%f want 0.25")
	render_kf_probe_check(oxB == -25 && rwB == 75,
		"B src sub-rect + box trim left: got ox=%d rw=%d want -25 75", oxB, rwB)

	if render_kf_probe_fail {
		fmt.println("[render-kf-probe] failed")
		return 1
	}
	fmt.println("[render-kf-probe] ok")
	return 0
}
