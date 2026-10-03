package main

import "core:fmt"
import "core:mem"

// Keyframe probe (VYPER_KEYFRAME_PROBE): headless regression checks for the
// generic keyframe store — sorted insert/replace, the linear sample (a key
// applies on its own frame; between keys the value interpolates and reaches
// the next key's value exactly on its frame; before the first key and past
// the last key the property is inactive and the base/resting value rules), the
// split/trim remaps, the deep-clone round-trip through clone_timeline,
// empty-track deletion, and zero-value Clip{} safety. Builds its own Clip
// structs; no decode, no SDL, no timeline globals.

kf_probe_fail := false

kf_approx :: proc(a, b: f32) -> bool {
	d := a - b
	if d < 0 {
		d = -d
	}
	return d < 0.0001
}

kf_probe_check :: proc(cond: bool, msg: string, args: ..any) {
	if !cond {
		kf_probe_fail = true
		line := fmt.tprintf(msg, ..args)
		fmt.println("[kf-probe] FAIL", line)
	}
}

// --- packed-migration equality helpers ------------------------------------
// A lane profile captures (value, active) per frame for one lane over a frame
// window. Migrations (unwrap/fold) are compared by demanding two profiles of
// the SAME lane/frame-window match — value-exact means the packed and scalar
// forms answer the sampler identically at every sampled frame.

Kf_Lane_Profile :: struct {
	values: [128]f32,
	active: [128]bool,
	count:  int,
}

kf_probe_lane_profile :: proc(clip: ^Clip, lane: string, f0, f1: i32, base: f32) -> Kf_Lane_Profile {
	p: Kf_Lane_Profile
	for f in f0 ..= f1 {
		v, ok := kf_geom_sample_lane(clip, lane, i64(f), base)
		p.values[p.count] = v
		p.active[p.count] = ok
		p.count += 1
	}
	return p
}

kf_probe_profile_match :: proc(a, b: Kf_Lane_Profile) -> bool {
	if a.count != b.count {
		return false
	}
	for i in 0 ..< a.count {
		if a.active[i] != b.active[i] {
			return false
		}
		if !kf_approx(a.values[i], b.values[i]) {
			return false
		}
	}
	return true
}

keyframe_probe_run :: proc() -> int {
	// --- sorted insert + replace-in-place ---------------------------------
	c := Clip {}
	kf_set_key(&c, "gain", 30, 3.0)
	kf_set_key(&c, "gain", 10, 1.0)
	kf_set_key(&c, "gain", 20, 2.0)
	kf_set_key(&c, "gain", 10, 5.0) // replace the key already on frame 10
	ti := kf_track_index(c, "gain")
	kf_probe_check(ti >= 0, "track 'gain' must exist after 3 inserts")
	kf_probe_check(len(c.keyframe_tracks) == 1, "one property => one track, got %d", len(c.keyframe_tracks))
	if ti >= 0 {
		keys := c.keyframe_tracks[ti].keys
		kf_probe_check(len(keys) == 3, "3 distinct frames => 3 keys, got %d", len(keys))
		kf_probe_check(
			keys[0] == Keyframe {frame_off = 10, value = 5.0},
			"inserts must stay sorted and the repeated frame replaced: keys[0]=%v",
			keys[0],
		)
kf_probe_check(keys[1] == Keyframe {frame_off = 20, value = 2.0}, "keys[1]=%v", keys[1])
	kf_probe_check(keys[2] == Keyframe {frame_off = 30, value = 3.0}, "keys[2]=%v", keys[2])
	}

	// --- lookup: missing name ---------------------------------------------
	kf_probe_check(kf_track_index(c, "scale") < 0, "unknown name must miss")

	// --- linear sample: a key applies on its own frame; between keys the ----
	// value interpolates and reaches the NEXT key's value exactly on its
	// frame. Before the first key and past the last key the caller's base
	// rules (direct edits apply there).
	smp := Clip {}
	kf_set_key(&smp, "gain", 10, 5.0)
	kf_set_key(&smp, "gain", 20, 2.0)
	kf_set_key(&smp, "gain", 30, 8.0)

	kf_set_lane_interp :: proc(clip: ^Clip, name: string, interp: Kf_Interp) {
		if ti := kf_track_index(clip^, name); ti >= 0 {
			for k in 0 ..< len(clip.keyframe_tracks[ti].keys) {
				clip.keyframe_tracks[ti].keys[k].interp = interp
			}
		}
	}

	// New keys default to .Cubic (the zero value); this section exercises the
	// LINEAR sampler, so pin the mode explicitly rather than relying on a
	// default that the spline feature changed.
	kf_set_lane_interp(&smp, "gain", .Linear)
	gt := kf_track_index(smp, "gain")
	gain: ^Kf_Track
	if gt >= 0 {
		gain = &smp.keyframe_tracks[gt]
	}
	v, ok := kf_sample(gain, 0, 7.0)
	kf_probe_check(!ok && v == 7.0, "before first key: inactive, base kept (v=%v ok=%v)", v, ok)
	v, ok = kf_sample(gain, 9, 7.0)
	kf_probe_check(!ok && v == 7.0, "still before first key at off 9: base kept")
	// first key at 10 target 5.
	v, ok = kf_sample(gain, 10, 7.0)
	kf_probe_check(ok && v == 5.0, "a key applies ITS value on its own frame (got %v)", v)
	v, _ = kf_sample(gain, 11, 7.0)
	kf_probe_check(kf_approx(v, 4.7), "interpolates toward the next key's value (got %v)", v)
	v, _ = kf_sample(gain, 14, 7.0)
	kf_probe_check(kf_approx(v, 3.8), "linear across the segment (got %v)", v)
	v, _ = kf_sample(gain, 15, 7.0)
	kf_probe_check(kf_approx(v, 3.5), "midpoint is halfway (got %v)", v)
	v, _ = kf_sample(gain, 19, 7.0)
	kf_probe_check(kf_approx(v, 2.3), "near the next key (got %v)", v)
	v, _ = kf_sample(gain, 20, 7.0)
	kf_probe_check(v == 2.0, "arrives at exactly the next key's value on its frame (got %v)", v)
	// second segment 20->30: 2 -> 8.
	v, _ = kf_sample(gain, 25, 7.0)
	kf_probe_check(v == 5.0, "second segment midpoint (got %v)", v)
	v, _ = kf_sample(gain, 30, 7.0)
	kf_probe_check(v == 8.0, "third key applies its value on its frame (got %v)", v)
	// past the last key: inactive again, resting base wins (direct edits apply).
	v, ok = kf_sample(gain, 31, 7.0)
	kf_probe_check(!ok && v == 7.0, "past the last key: inactive, base restored (v=%v ok=%v)", v, ok)
	v, _ = kf_sample(gain, 100, 7.0)
	kf_probe_check(!ok && v == 7.0, "far past the last key: base holds (got %v)", v)

	// --- lone key / no later target -----------------------------------------
	// A single key pins its frame only; everywhere else the resting base
	// rules, so direct edits show up even though a key exists.
	d := Clip {}
	kf_set_key(&d, "x", 5, 0.0)
	dt := kf_track_index(d, "x")
	dx: ^Kf_Track
	if dt >= 0 {
		dx = &d.keyframe_tracks[dt]
	}
	v, ok = kf_sample(dx, 5, 10.0)
	kf_probe_check(ok && v == 0.0, "lone key pins its frame (got %v)", v)
	v, ok = kf_sample(dx, 6, 10.0)
	kf_probe_check(!ok && v == 10.0, "a frame after the lone key: base restored (v=%v ok=%v)", v, ok)
	v, _ = kf_sample(dx, 15, 10.0)
	kf_probe_check(!ok && v == 10.0, "lone key does not hold to the end (got %v)", v)

	// --- linear segment: exact arrival + deactivation ------------------------
	s := Clip {}
	kf_set_key(&s, "scale", 3, 10.0)
	kf_set_key(&s, "scale", 8, 0.0)
	st := kf_track_index(s, "scale")
	sx: ^Kf_Track
	if st >= 0 {
		sx = &s.keyframe_tracks[st]
	}
	v, ok = kf_sample(sx, 3, 1.0)
	kf_probe_check(ok && v == 10.0, "first key applies at its frame (got %v)", v)
	v, _ = kf_sample(sx, 6, 1.0)
	kf_probe_check(v == 4.0, "linear at 3/5 of the segment (got %v)", v)
	v, _ = kf_sample(sx, 8, 1.0)
	kf_probe_check(v == 0.0, "reaches the next key's value exactly on its frame (got %v)", v)
	v, ok = kf_sample(sx, 9, 1.0)
	kf_probe_check(!ok && v == 1.0, "past the last key: inactive again (v=%v ok=%v)", v, ok)
	v, _ = kf_sample(sx, 10, 1.0)
	kf_probe_check(!ok && v == 1.0, "still base after the last key (got %v)", v)

	// --- kf_sample_for at a timeline frame, clip-relative -------------------
	sf := Clip {timeline_start_frame = 100}
	kf_set_key(&sf, "gain", 0, 4.0)
	v, ok = kf_geom_sample_lane(&sf, "gain", 100, 9.0)
	kf_probe_check(ok && v == 4.0, "frame 100 == clip-relative off 0: the key's value applies (got %v)", v)
	v, ok = kf_geom_sample_lane(&sf, "gain", 101, 9.0)
	kf_probe_check(!ok && v == 9.0, "frame 101 == off 1: lone key past, base applies (got %v)", v)
	v, ok = kf_geom_sample_lane(&sf, "scale", 100, 9.0)
	kf_probe_check(!ok && v == 9.0, "unknown property: base kept, inactive")

	// --- split remap (slice-1 rule) -----------------------------------------
	sp := Clip {source_length_frames = 100}
	kf_set_key(&sp, "gain", 10, 1.0)
	kf_set_key(&sp, "gain", 40, 2.0) // on the cut frame -> right half, re-rel 0
	kf_set_key(&sp, "gain", 45, 3.0)
	kf_set_key(&sp, "gain", 99, 4.0)
	// The halves no longer share one keys backing: the right is an independent
	// copy (clip_deep_copy at every split site) and each half trims its own.
	sp_right := clip_deep_copy(&sp)
	kf_trim_tail(&sp, 40)
	kf_trim_head(&sp_right, 40)
	left_ok := false
	if len(sp.keyframe_tracks) == 1 {
		lk := sp.keyframe_tracks[0].keys
		left_ok = len(lk) == 1 && lk[0] == Keyframe {frame_off = 10, value = 1.0}
	}
	kf_probe_check(left_ok, "left keeps only keys < cut, values preserved")
	right_ok := false
	if len(sp_right.keyframe_tracks) == 1 {
		rk := sp_right.keyframe_tracks[0].keys
		right_ok = len(rk) == 3 &&
		rk[0] == Keyframe {frame_off = 0, value = 2.0} &&
		rk[1] == Keyframe {frame_off = 5, value = 3.0} &&
		rk[2] == Keyframe {frame_off = 59, value = 4.0}
	}
	kf_probe_check(right_ok, "right re-relatives keys >= cut by -cut")
	if right_ok {
		v, _ = kf_sample(&sp_right.keyframe_tracks[0], 0, 0.0)
		kf_probe_check(v == 2.0, "right off 0 == old frame 40: the key's own value applies")
		v, _ = kf_sample(&sp_right.keyframe_tracks[0], 5, 0.0)
		kf_probe_check(v == 3.0, "right off 5 == old frame 45: key value applies at its frame")
	}

	// --- trim head / trim tail ---------------------------------------------
	tr := Clip {}
	kf_set_key(&tr, "gain", 5, 1.0)
	kf_set_key(&tr, "gain", 40, 2.0)
	kf_set_key(&tr, "gain", 45, 3.0)
	kf_trim_head(&tr, 40)
	trim_ok := false
	if len(tr.keyframe_tracks) == 1 {
		tk := tr.keyframe_tracks[0].keys
		trim_ok = len(tk) == 2 && tk[0] == Keyframe {frame_off = 0, value = 2.0} && tk[1] == Keyframe {frame_off = 5, value = 3.0}
	}
	kf_probe_check(trim_ok, "trim_head drops head keys and re-relatives survivors")
	tr2 := Clip {}
	kf_set_key(&tr2, "gain", 5, 1.0)
	kf_set_key(&tr2, "gain", 40, 2.0)
	kf_set_key(&tr2, "gain", 45, 3.0)
	kf_trim_tail(&tr2, 42)
	trim2_ok := false
	if len(tr2.keyframe_tracks) == 1 {
		tk := tr2.keyframe_tracks[0].keys
		trim2_ok = len(tk) == 2 && tk[0] == Keyframe {frame_off = 5, value = 1.0} && tk[1] == Keyframe {frame_off = 40, value = 2.0}
	}
	kf_probe_check(trim2_ok, "trim_tail drops keys beyond the new length")

	// A trim rebuilds the track, so every kept key is a NEW Keyframe there; the
	// interpolation mode must survive that.
	tmt := Clip {}
	kf_set_key(&tmt, "gain", 5, 1.0)
	kf_set_key(&tmt, "gain", 40, 2.0)
	tmt.keyframe_tracks[0].keys[1].interp = .Ease_In_Out
	kf_trim_head(&tmt, 20)
	trim_mode_ok :=
		len(tmt.keyframe_tracks) == 1 &&
		len(tmt.keyframe_tracks[0].keys) == 1 &&
		tmt.keyframe_tracks[0].keys[0] == Keyframe {frame_off = 20, value = 2.0, interp = .Ease_In_Out}
	kf_probe_check(trim_mode_ok, "trim rebuild preserves the key's interpolation mode")

	// --- flat-copy evaluator (the audio producer's sampler) mirrors kf_sample --
	// The audio producer re-evaluates keyed gain each frame from its OWN flat
	// snapshot (kf_sample_keys), never the live track. It must agree with
	// kf_sample on the same keys at every offset.
	fc := Clip {timeline_start_frame = 200}
	kf_set_key(&fc, "gain", 10, 8.0)
	kf_set_key(&fc, "gain", 20, 2.0)
	fc_ti := kf_track_index(fc, "gain")
	fc_same := false
	if fc_ti >= 0 {
		tk := &fc.keyframe_tracks[fc_ti]
		fc_same = true
		for off := i32(0); off <= 40; off += 1 {
			tv, tok := kf_sample(tk, off, 4.0)
			fv, fok := kf_sample_keys(tk.keys[:], off, 4.0)
			if tv != fv || tok != fok {
				fc_same = false
				break
			}
		}
		// Segment-relative addressing is frame - seg.start_a; the key at
		// clip-relative 10 applies its own value at 210, then interpolates
		// toward the next key's 2: 211 -> 7.4, 219 -> 2.6, and past the last
		// key (225) the resting base 4 rules.
		f10, _ := kf_sample_keys(tk.keys[:], i32(210 - 200), 4.0)
		f11, _ := kf_sample_keys(tk.keys[:], i32(211 - 200), 4.0)
		f19, _ := kf_sample_keys(tk.keys[:], i32(219 - 200), 4.0)
		f25, fok := kf_sample_keys(tk.keys[:], i32(225 - 200), 4.0)
		kf_probe_check(
			f10 == 8.0 && kf_approx(f11, 7.4) && kf_approx(f19, 2.6) && !fok && f25 == 4.0,
			"flat sampler is clip-relative on timeline addresses (210->%v 211->%v 219->%v 225->%v ok=%v)",
			f10, f11, f19, f25, fok,
		)
	}
	kf_probe_check(fc_same, "kf_sample_keys agrees with kf_sample on a copied track")

	// --- interpolation modes: closed-form curves, spline, packed parity ------
	// kf_ease signature values at t = 1/2, hand-derived: cubic-in = 1/8,
	// cubic-out = 7/8, in-out = 1/2 at the midpoint by construction.
	ease_mid := kf_ease(.Elastic, 0.5)
	ease_ok :=
		kf_approx(kf_ease(.Linear, 0.5), 0.5) &&
		kf_approx(kf_ease(.Ease_In, 0.5), 0.125) &&
		kf_approx(kf_ease(.Ease_Out, 0.5), 0.875) &&
		kf_approx(kf_ease(.Ease_In_Out, 0.5), 0.5) &&
		kf_ease(.Elastic, 0) == 0 && kf_ease(.Elastic, 1) == 1 && ease_mid > 1.0
	kf_probe_check(
		ease_ok,
		"kf_ease signatures (in=%v out=%v inout=%v elastic-mid=%v)",
		kf_ease(.Ease_In, 0.5),
		kf_ease(.Ease_Out, 0.5),
		kf_ease(.Ease_In_Out, 0.5),
		ease_mid,
	)

	// A TWO-key track with .Cubic is exactly Linear: both spline tangents
	// default to the chord slope (no outside neighbor on either end — the
	// natural edge condition), and a Hermite whose endpoint tangents equal the
	// chord IS the straight line. Pinned so "Cubic did nothing" is known-intent
	// (the curve needs a third key to have anywhere to deviate).
	twok := Clip {}
	kf_set_key(&twok, "gain", 0, 0.0)
	kf_set_key(&twok, "gain", 10, 100.0)
	cubic_ok := true
	if sti := kf_track_index(twok, "gain"); sti >= 0 {
		sk2 := &twok.keyframe_tracks[sti]
		sk2.keys[1].interp = .Cubic
		for off in i32(0) ..= 10 {
			vc, _ := kf_sample(sk2, off, 0.0)
			if !kf_approx(vc, f32(off) * 10.0) {
				cubic_ok = false
				break
			}
		}
	}
	kf_probe_check(cubic_ok, "two-key Cubic collapses to Linear (chord tangents)")

	// The sampler eases INTO the next key, so the segment's mode is the
	// ARRIVING key's, not the departing key's; both endpoints still snap
	// exactly (on-frame returns the key's own value).
	sc := Clip {}
	kf_set_key(&sc, "gain", 0, 0.0)
	kf_set_key(&sc, "gain", 10, 100.0)
	if sti := kf_track_index(sc, "gain"); sti >= 0 {
		sk := &sc.keyframe_tracks[sti]
		sk.keys[1].interp = .Ease_In
		ki0, _ := kf_sample(sk, 0, 0.0)
		kim, _ := kf_sample(sk, 5, 0.0)
		ki1, _ := kf_sample(sk, 10, 0.0)
		sk.keys[1].interp = .Ease_Out
		kom, _ := kf_sample(sk, 5, 0.0)
		sk.keys[1].interp = .Ease_In_Out
		kio_m, _ := kf_sample(sk, 5, 0.0)
		sk.keys[1].interp = .Elastic
		kel_m, _ := kf_sample(sk, 5, 0.0)
		// Ownership pin: setting the FIRST (departing) key's mode must not
		// reshape the segment — nothing arrives at the first key, its mode is
		// inert. Rearm the arriving key to Linear and bounce the first one.
		sk.keys[1].interp = .Linear
		sk.keys[0].interp = .Elastic
		kfirst, _ := kf_sample(sk, 5, 0.0)
		kf_probe_check(
			ki0 == 0.0 && kf_approx(kim, 12.5) && ki1 == 100.0 &&
				kf_approx(kom, 87.5) && kio_m == 50.0 && kel_m > 100.0 &&
				kf_approx(kfirst, 50.0),
			"sampler eases into the arriving key's mode (in=%v out=%v inout=%v elastic=%v first-key-inert=%v)",
			kim, kom, kio_m, kel_m, kfirst,
		)
	}

	// Cubic is a Hermite spline, not an ease curve. Two properties pin it down:
	// a tangent-symmetric segment's midpoint sits exactly on the linear midpoint,
	// and an asymmetric one pulls off the chord (proving it actually curves).
	spc := Clip {}
	kf_set_key(&spc, "gain", 0, 0.0)
	kf_set_key(&spc, "gain", 10, 100.0)
	kf_set_key(&spc, "gain", 20, 250.0)
	kf_set_key(&spc, "gain", 30, 350.0)
	if sti := kf_track_index(spc, "gain"); sti >= 0 {
		spk := &spc.keyframe_tracks[sti]
		spk.keys[0].interp = .Cubic
		spk.keys[1].interp = .Cubic
		spk.keys[2].interp = .Cubic
		// segment 10->20: tangents (250-0)/20 == (350-100)/20 == 12.5 each =>
		// Hermite midpoint == (100+250)/2 == 175.
		sm_mid, _ := kf_sample(spk, 15, 0.0)
		// segment 0->10: m0 chord = 10, m1 = (250-0)/20 = 12.5 => 46.875 at 5.
		sma_mid, _ := kf_sample(spk, 5, 0.0)
		kf_probe_check(
			kf_approx(sm_mid, 175.0) && kf_approx(sma_mid, 46.875),
			"spline curves through keys (sym-mid=%v asym-mid=%v)",
			sm_mid, sma_mid,
		)
	}

	// Packed section lanes ease identically to the scalar path and carry
	// per-knot interp through the fold.
	peck := Clip {}
	lanes0 := [KF_PACK_MAX]f32{}
	lanes1 := [KF_PACK_MAX]f32{}
	lanes0[0] = 0.0
	lanes1[0] = 100.0
	kf_set_packed_key(&peck, "sec", 0, lanes0, 1)
	kf_set_packed_key(&peck, "sec", 10, lanes1, 1)
	if pti := kf_track_index(peck, "sec"); pti >= 0 {
		pk := &peck.keyframe_tracks[pti]
		pk.keys[1].interp = .Ease_Out
		pv_m, pok := kf_sample_packed_lane(pk, 5, 0, 0.0)
		pek := Clip {}
		kf_set_key(&pek, "sec", 0, 0.0)
		kf_set_key(&pek, "sec", 10, 100.0)
		peks := &pek.keyframe_tracks[kf_track_index(pek, "sec")]
		peks.keys[1].interp = .Ease_Out
		sv_m, _ := kf_sample(peks, 5, 0.0)
		kf_probe_check(
			pok && kf_approx(pv_m, 87.5) && pv_m == sv_m,
			"packed lane and scalar track ease identically (%v vs %v)",
			pv_m, sv_m,
		)
	}

	// Spline parity: the packed lane's two-neighbor tangent capture (prev2/next2)
	// must reproduce the scalar Hermite across the whole run of knots.
	pecs := Clip {}
	l0 := [KF_PACK_MAX]f32{}
	l1 := [KF_PACK_MAX]f32{}
	l2 := [KF_PACK_MAX]f32{}
	l3 := [KF_PACK_MAX]f32{}
	l0[0] = 0.0
	l1[0] = 100.0
	l2[0] = 250.0
	l3[0] = 350.0
	kf_set_packed_key(&pecs, "sec", 0, l0, 1)
	kf_set_packed_key(&pecs, "sec", 10, l1, 1)
	kf_set_packed_key(&pecs, "sec", 20, l2, 1)
	kf_set_packed_key(&pecs, "sec", 30, l3, 1)
	seck := &pecs.keyframe_tracks[kf_track_index(pecs, "sec")]
	for i in 0 ..= 2 {
		seck.keys[i].interp = .Cubic
	}
	sc2 := Clip {}
	kf_set_key(&sc2, "sec", 0, 0.0)
	kf_set_key(&sc2, "sec", 10, 100.0)
	kf_set_key(&sc2, "sec", 20, 250.0)
	kf_set_key(&sc2, "sec", 30, 350.0)
	sc2k := &sc2.keyframe_tracks[kf_track_index(sc2, "sec")]
	sc2k.keys[0].interp = .Cubic
	sc2k.keys[1].interp = .Cubic
	sc2k.keys[2].interp = .Cubic
	spline_parity := true
	for off := i32(0); off <= 30; off += 1 {
		pv, _ := kf_sample_packed_lane(seck, off, 0, 0.0)
		sv, _ := kf_sample_keys(sc2k.keys[:], off, 0.0)
		if !kf_approx(pv, sv) {
			spline_parity = false
			break
		}
	}
	kf_probe_check(spline_parity, "packed spline agrees with the scalar spline on every frame")

	// --- deep clone through clone_timeline: mutate clone, original untouched -
	base := Clip {timeline_start_frame = 50}
	kf_set_key(&base, "gain", 10, 1.5)
	kf_set_key(&base, "gain", 20, 2.5)
	kf_set_key(&base, "scale", 0, 9.0)
	src := Timeline {}
	src.track_order = make([dynamic]int, 1)
	src.tracks = make([dynamic]Track, 1)
	src.tracks[0].clips = make([dynamic]Clip, 1)
	src.tracks[0].clips[0] = base
	cloned := clone_timeline(src)
	cl := &cloned.tracks[0].clips[0]
	kf_probe_check(kf_track_index(cl^, "gain") >= 0, "clone carried the gain track")
	kf_probe_check(kf_track_index(cl^, "scale") >= 0, "clone carried the scale track")
	if cgt := kf_track_index(cl^, "gain"); cgt >= 0 {
		cl_gain := cl.keyframe_tracks[cgt].keys[0].value
		kf_probe_check(cl_gain == 1.5, "clone carried the base key's value (got %v)", cl_gain)
	}
	// Poke the clone: delete its key at 20, smash its scale key value.
	kf_del_key(cl, "gain", 20)
	bsi := kf_track_index(cl^, "scale")
	if bsi >= 0 {
		cl.keyframe_tracks[bsi].keys[0].value = -1.0
	}
	// The original must not feel either poke, and vice versa: give the
	// ORIGINAL a new key at 30 and the clone must not see it.
	kf_set_key(&base, "gain", 30, 7.0)
	base_ti := kf_track_index(base, "gain")
	orig_ok := false
	if base_ti >= 0 {
		keys := base.keyframe_tracks[base_ti].keys
		has20 := false
		has30 := false
		for k in keys {
			if k.frame_off == 20 && k.value == 2.5 {
				has20 = true
			}
			if k.frame_off == 30 {
				has30 = true
			}
		}
		orig_ok = has20 && has30 && len(keys) == 3
	}
	kf_probe_check(orig_ok, "original keeps its key 20 AND gains key 30 (clone's delete is invisible)")
	clone_ok := false
	if clone_ti := kf_track_index(cl^, "gain"); clone_ti >= 0 {
		keys := cl.keyframe_tracks[clone_ti].keys
		no30 := true
		for k in keys {
			if k.frame_off == 30 {
				no30 = false
			}
		}
		clone_ok = no30 && len(keys) == 1
	}
	kf_probe_check(clone_ok, "clone is unaffected by the original's new key 30 (deep copy)")
	sv, _ := kf_geom_sample_lane(&base, "scale", 59, 0.0) // off 9, past the lone key
	kf_probe_check(sv == 0.0, "original scale untouched by the clone's poke; resting base rules past the key (got %v)", sv)
	// teardown both timelanes
	free_timeline(&cloned)
	free_timeline(&src)

	// --- delete: track drops once empty ------------------------------------
	del := Clip {}
	kf_set_key(&del, "gain", 7, 1.0)
	ti_d := kf_track_index(del, "gain")
	kf_probe_check(ti_d >= 0, "delete setup: track exists")
	kf_del_key(&del, "gain", 7)
	kf_probe_check(len(del.keyframe_tracks) == 0, "track dropped once its only key is deleted")
	v, ok = kf_geom_sample_lane(&del, "gain", 7, 2.0)
	kf_probe_check(!ok && v == 2.0, "deleted track is inactive")

	// --- zero-value Clip{} stays safe --------------------------------------
	z := Clip {}
	v, ok = kf_geom_sample_lane(&z, "gain", 7, 3.5)
	kf_probe_check(!ok && v == 3.5, "zero-value clip: inactive, base kept")
	kf_probe_check(kf_track_index(z, "gain") < 0, "zero-value clip: no tracks")
	kf_del_key(&z, "gain", 0)
	kf_trim_head(&z, 5)
	kf_trim_tail(&z, 5)
	kf_probe_check(len(z.keyframe_tracks) == 0, "remaps on zero-value clip are no-ops")

	// --- packed sections: grouped whole-crop/transform keys -----------------
	// A packed key lives on a SECTION track ("crop"), n > 0 lanes. Section and
	// lane tracks never coexist. Full pack first: sorted insert + same-frame
	// replace, lane readout, lane-absent invariant.
	crop := Clip {}
	kf_geom_set_packed(&crop, "crop", 10, {10.0, 14.0, 4.0, 6.0, 0, 0, 0}, 0b1111)
	kf_geom_set_packed(&crop, "crop", 30, {20.0, 8.0, 1.0, 9.0, 0, 0, 0}, 0b1111)
	kf_geom_set_packed(&crop, "crop", 10, {11.0, 13.0, 3.0, 7.0, 0, 0, 0}, 0b1111)
	cti := kf_track_index(crop, "crop")
	kf_probe_check(cti >= 0, "packed: section track exists")
	kf_probe_check(len(crop.keyframe_tracks) == 1, "packed: one section track, got %d", len(crop.keyframe_tracks))
	kf_probe_check(
		kf_geom_full_mask("crop") == 0b1111 && kf_geom_full_mask("transform") == 0b11,
		"group masks: whole crop = all 4 edges, whole transform = both axes",
	)
	kf_probe_check(kf_track_index(crop, "crop.l") < 0, "packed: lane track absent while the section is packed")
	if cti >= 0 {
		ck := crop.keyframe_tracks[cti].keys
		kf_probe_check(len(ck) == 2, "packed: same-frame replace keeps 2 keys, got %d", len(ck))
		if len(ck) == 2 {
			kf_probe_check(ck[0].frame_off == 10 && ck[0].mask == 0b1111, "packed: sorted, mask preserved on frame 10 (got %v)", ck[0])
			lv, cov := kf_lane_value(ck[0], 0)
			kf_probe_check(lv == 11.0 && cov, "packed: replace overwrote lane 0 (got %v)", lv)
			rv, rcov := kf_lane_value(ck[1], 1)
			kf_probe_check(rv == 8.0 && rcov, "packed: frame 30 lane 1 (got %v)", rv)
			_, ucv := kf_lane_value(ck[0], 4)
			kf_probe_check(!ucv, "packed: lane index >= n reads as uncovered")
		}
	}

	// --- packed sampling: key on its frame, interpolation between ----------
	v, ok = kf_geom_sample_lane(&crop, "crop.l", 10, 0.0)
	kf_probe_check(ok && v == 11.0, "packed: lane 0 key applies on its frame (got %v)", v)
	v, _ = kf_geom_sample_lane(&crop, "crop.r", 20, 0.0)
	kf_probe_check(kf_approx(v, 10.5), "packed: lane 1 interpolates 13->8 at the midpoint (got %v)", v)
	v, _ = kf_geom_sample_lane(&crop, "crop.t", 30, 0.0)
	kf_probe_check(v == 1.0, "packed: lane 2 arrives at the next key's value (got %v)", v)
	v, ok = kf_geom_sample_lane(&crop, "crop.b", 35, 0.0)
	kf_probe_check(!ok && v == 0.0, "packed: past the last key a lane rests, base kept (v=%v ok=%v)", v, ok)
	v, ok = kf_geom_sample_lane(&crop, "crop.l", 5, 0.0)
	kf_probe_check(!ok && v == 0.0, "packed: before the first key, base (v=%v ok=%v)", v, ok)

	// --- partial pack: n < section width leaves uncovered lanes resting -----
	pp := Clip {}
	kf_geom_set_packed(&pp, "crop", 10, {5.0, 6.0, 0, 0, 0, 0, 0}, 0b11)
	unv, unok := kf_geom_sample_lane(&pp, "crop.t", 10, 9.0)
	kf_probe_check(!unok && unv == 9.0, "partial pack: an uncovered lane rests (got %v)", unv)
	unv, unok = kf_geom_sample_lane(&pp, "crop.b", 7, 9.0)
	kf_probe_check(!unok && unv == 9.0, "partial pack: rest before, during, and after, base holds (got %v)", unv)
	lv, lok := kf_geom_sample_lane(&pp, "crop.l", 10, 9.0)
	kf_probe_check(lok && lv == 5.0, "partial pack: covered lane still applies (got %v)", lv)

	// --- packed snapshot (worker seam): section expands to per-lane scalars --
	sl := Clip {}
	kf_geom_set_packed(&sl, "transform", 10, {4.0, 8.0, 0, 0, 0, 0, 0}, 0b11)
	kf_geom_set_packed(&sl, "transform", 24, {9.0, 1.0, 0, 0, 0, 0, 0}, 0b11)
	snap_dst: [32]Keyframe
	sn, stotal := kf_geom_fill_snapshot(&sl, "transform.x", snap_dst[:])
	kf_probe_check(sn == 2 && stotal == 2, "snapshot: packed section expands to 2 scalar keys, got %d/%d", sn, stotal)
	snap_ok := sn == 2
	if snap_ok {
		snap_ok = snap_dst[0] == Keyframe {frame_off = 10, value = 4.0} && snap_dst[1] == Keyframe {frame_off = 24, value = 9.0}
	}
	kf_probe_check(snap_ok, "snapshot: expanded keys match the packed lane values (got %v %v)", snap_dst[0], snap_dst[1])
	for off := i32(0); off <= 30; off += 1 {
		sv2, sok := kf_geom_sample_lane(&sl, "transform.x", i64(off), 0.0)
		fv, fok := kf_sample_keys(snap_dst[:sn], off, 0.0)
		if !sok && fok || sok && !fok || (sok && fok && !kf_approx(sv2, fv)) {
			snap_ok = false
			break
		}
	}
	kf_probe_check(snap_ok, "snapshot: expanded scalars sample identically to the packed lane")
	// A scalar property still snapshots straight-through.
	gain_clip := Clip {}
	kf_set_key(&gain_clip, "gain", 5, 7.0)
	gn, gtotal := kf_geom_fill_snapshot(&gain_clip, "gain", snap_dst[:])
	kf_probe_check(gn == 1 && gtotal == 1 && snap_dst[0] == Keyframe {frame_off = 5, value = 7.0}, "snapshot: scalar track copies unchanged")

	// --- unwrap: keying an individual lane makes the group give way ---------
	uv := Clip {}
	kf_geom_set_packed(&uv, "transform", 10, {4.0, 8.0, 0, 0, 0, 0, 0}, 0b11)
	kf_geom_set_packed(&uv, "transform", 24, {9.0, 1.0, 0, 0, 0, 0, 0}, 0b11)
	kf_geom_set_lane_key(&uv, "transform.y", 18, 5.0) // the unwrap trigger
	kf_probe_check(kf_track_index(uv, "transform") < 0, "unwrap: section track gone after a lane key")
	kf_probe_check(kf_track_index(uv, "transform.x") >= 0, "unwrap: sibling lane track exists")
	kf_probe_check(kf_track_index(uv, "transform.y") >= 0, "unwrap: keyed lane track exists")
	// Oracle: the unwrap result must match the SAME edits landing on scalar
	// tracks from the start — lane 0 untouched (keys 10:4, 24:9), lane 1 with
	// the new key at 18 (10:8, 18:5, 24:1). The new key legitimately reshapes
	// the 10→24 segment, so comparing against the PRE-unwrap packed curve
	// (skip-the-new-key) is the wrong oracle.
	uo := Clip {}
	kf_geom_set_lane_key(&uo, "transform.x", 10, 4.0)
	kf_geom_set_lane_key(&uo, "transform.x", 24, 9.0)
	kf_geom_set_lane_key(&uo, "transform.y", 10, 8.0)
	kf_geom_set_lane_key(&uo, "transform.y", 18, 5.0)
	kf_geom_set_lane_key(&uo, "transform.y", 24, 1.0)
	q0 := kf_probe_lane_profile(&uv, "transform.x", 0, 30, 0.0)
	q1 := kf_probe_lane_profile(&uv, "transform.y", 0, 30, 0.0)
	o0 := kf_probe_lane_profile(&uo, "transform.x", 0, 30, 0.0)
	o1 := kf_probe_lane_profile(&uo, "transform.y", 0, 30, 0.0)
	kf_probe_check(
		kf_probe_profile_match(q0, o0) && kf_probe_profile_match(q1, o1),
		"unwrap: scalar lanes equal the same edits landed on scalar tracks from the start",
	)

	// --- kf_set_value on a packed section: unwraps, edits lane 0 -------------
	sv_clip := Clip {}
	kf_geom_set_packed(&sv_clip, "transform", 10, {4.0, 8.0, 0, 0, 0, 0, 0}, 0b11)
	kf_geom_set_packed(&sv_clip, "transform", 24, {9.0, 1.0, 0, 0, 0, 0, 0}, 0b11)
	kf_geom_set_value(&sv_clip, "transform", 10, 6.5)
	kf_probe_check(kf_track_index(sv_clip, "transform") < 0, "kf_set_value: section unwrapped")
	ev, eok := kf_geom_sample_lane(&sv_clip, "transform.x", 10, 0.0)
	kf_probe_check(eok && ev == 6.5, "kf_set_value: lane 0 holds the edited value (got %v)", ev)
	ey, _ := kf_geom_sample_lane(&sv_clip, "transform.y", 10, 0.0)
	kf_probe_check(ey == 8.0, "kf_set_value: the untouched sibling lane keeps its value (got %v)", ey)

	// --- fold: keying the whole section over keyed lanes --------------------
	fv := Clip {}
	kf_geom_set_lane_key(&fv, "crop.l", 10, 1.0)
	kf_geom_set_lane_key(&fv, "crop.r", 10, 2.0)
	kf_geom_set_lane_key(&fv, "crop.l", 22, 5.0)
	kf_geom_set_lane_key(&fv, "crop.r", 30, 6.0)
	kf_geom_set_lane_key(&fv, "crop.t", 10, 3.0)
	kf_geom_set_lane_key(&fv, "crop.t", 30, 4.0)
	kf_geom_set_lane_key(&fv, "crop.b", 10, 7.0)
	kf_geom_set_lane_key(&fv, "crop.b", 30, 8.0)
	// Oracle: the pre-fold lanes plus the same group edit applied per-lane.
	oracle := Clip {}
	kf_geom_set_lane_key(&oracle, "crop.l", 10, 1.0)
	kf_geom_set_lane_key(&oracle, "crop.r", 10, 2.0)
	kf_geom_set_lane_key(&oracle, "crop.l", 22, 5.0)
	kf_geom_set_lane_key(&oracle, "crop.r", 30, 6.0)
	kf_geom_set_lane_key(&oracle, "crop.t", 10, 3.0)
	kf_geom_set_lane_key(&oracle, "crop.t", 30, 4.0)
	kf_geom_set_lane_key(&oracle, "crop.b", 10, 7.0)
	kf_geom_set_lane_key(&oracle, "crop.b", 30, 8.0)
	kf_geom_set_lane_key(&oracle, "crop.l", 16, 2.5)
	kf_geom_set_lane_key(&oracle, "crop.r", 16, 3.5)
	kf_geom_set_lane_key(&oracle, "crop.t", 16, 3.25)
	kf_geom_set_lane_key(&oracle, "crop.b", 16, 7.25)
	// The fold trigger: a whole-crop key on frame 16 with the group edit values.
	kf_geom_set_packed(&fv, "crop", 16, {2.5, 3.5, 3.25, 7.25, 0, 0, 0}, 0b1111)
	kf_probe_check(kf_track_index(fv, "crop") >= 0, "fold: section track exists after the group key")
	kf_probe_check(kf_track_index(fv, "crop.l") < 0, "fold: lane tracks folded away")
	kf_probe_check(kf_track_index(fv, "crop.r") < 0, "fold: lane tracks folded away (r)")
	kf_probe_check(kf_track_index(fv, "crop.t") < 0, "fold: lane tracks folded away (t)")
	kf_probe_check(kf_track_index(fv, "crop.b") < 0, "fold: lane tracks folded away (b)")
	fo_l := kf_probe_lane_profile(&fv, "crop.l", 8, 32, 0.0)
	fo_r := kf_probe_lane_profile(&fv, "crop.r", 8, 32, 0.0)
	fo_t := kf_probe_lane_profile(&fv, "crop.t", 8, 32, 0.0)
	fo_b := kf_probe_lane_profile(&fv, "crop.b", 8, 32, 0.0)
	or_l := kf_probe_lane_profile(&oracle, "crop.l", 8, 32, 0.0)
	or_r := kf_probe_lane_profile(&oracle, "crop.r", 8, 32, 0.0)
	or_t := kf_probe_lane_profile(&oracle, "crop.t", 8, 32, 0.0)
	or_b := kf_probe_lane_profile(&oracle, "crop.b", 8, 32, 0.0)
	kf_probe_check(
		kf_probe_profile_match(fo_l, or_l) &&
		kf_probe_profile_match(fo_r, or_r) &&
		kf_probe_profile_match(fo_t, or_t) &&
		kf_probe_profile_match(fo_b, or_b),
		"fold: packed section samples identically to the pre-fold lanes + the group edit",
	)
	// Rest-before-first-key: a lane whose first key is late keeps its resting
	// base at early union frames — the fold must not lift it to the set value.
	rb := Clip {}
	kf_geom_set_lane_key(&rb, "crop.l", 10, 2.0)
	kf_geom_set_lane_key(&rb, "crop.r", 40, 9.0) // first key LATER than frame 10's union knot
	br, brok := kf_geom_sample_lane(&rb, "crop.r", 12, 1.0)
	kf_probe_check(!brok && br == 1.0, "fold setup: crop.r rests pre-edit, base 1 (got %v)", br)
	kf_geom_set_packed(&rb, "crop", 20, {3.0, 4.0, 0, 0, 0, 0, 0}, 0b11)
	rr, rrok := kf_geom_sample_lane(&rb, "crop.r", 12, 1.0)
	kf_probe_check(!rrok && rr == 1.0, "fold: crop.r keeps resting base 1 before its first key (got %v)", rr)

	// --- del / trim / split on a packed section (n survives remaps) ----------
	pc := Clip {}
	kf_geom_set_packed(&pc, "crop", 5, {1.0, 2.0, 3.0, 4.0, 0, 0, 0}, 0b1111)
	kf_geom_set_packed(&pc, "crop", 40, {2.0, 4.0, 6.0, 8.0, 0, 0, 0}, 0b1111)
	kf_del_key(&pc, "crop", 5)
	pk := kf_track_index(pc, "crop")
	del_ok := false
	if pk >= 0 {
		keys := pc.keyframe_tracks[pk].keys
		del_ok = len(keys) == 1 && keys[0].frame_off == 40 && keys[0].mask == 0b1111
	}
	kf_probe_check(del_ok, "del on a packed section drops only the frame, n survives")
	th := Clip {}
	kf_geom_set_packed(&th, "crop", 5, {1.0, 2.0, 3.0, 4.0, 0, 0, 0}, 0b1111)
	kf_geom_set_packed(&th, "crop", 40, {2.0, 4.0, 6.0, 8.0, 0, 0, 0}, 0b1111)
	kf_trim_head(&th, 40)
	th_ok := false
	if ti := kf_track_index(th, "crop"); ti >= 0 {
		keys := th.keyframe_tracks[ti].keys
		th_ok = len(keys) == 1 && keys[0].frame_off == 0 && keys[0].mask == 0b1111
		if th_ok {
			zv, _ := kf_lane_value(keys[0], 0)
			th_ok = zv == 2.0
		}
	}
	kf_probe_check(th_ok, "trim_head re-relatives a packed key, preserving n and value")
	sp2 := Clip {}
	kf_geom_set_packed(&sp2, "crop", 10, {1.0, 2.0, 3.0, 4.0, 0, 0, 0}, 0b1111)
	kf_geom_set_packed(&sp2, "crop", 30, {2.0, 4.0, 6.0, 8.0, 0, 0, 0}, 0b1111)
	kf_geom_set_packed(&sp2, "crop", 50, {3.0, 6.0, 9.0, 12.0, 0, 0, 0}, 0b1111)
	sp2r := clip_deep_copy(&sp2)
	kf_trim_tail(&sp2, 30)
	kf_trim_head(&sp2r, 30)
	sp_ok := false
	if lti := kf_track_index(sp2, "crop"); lti >= 0 {
		lk := sp2.keyframe_tracks[lti].keys
		sp_ok = len(lk) == 1 && lk[0].frame_off == 10 && lk[0].mask == 0b1111
	}
	if sp_ok {
		if rti := kf_track_index(sp2r, "crop"); rti >= 0 {
			rk := sp2r.keyframe_tracks[rti].keys
			sp_ok = len(rk) == 2 && rk[0].frame_off == 0 && rk[0].mask == 0b1111 && rk[1].frame_off == 20 && rk[1].mask == 0b1111
		} else {
			sp_ok = false
		}
	}
	kf_probe_check(sp_ok, "split keeps packed keys n==4 on both halves, re-relative on the right")

	// --- deep clone carries packed sections intact ---------------------------
	cp := Clip {}
	kf_geom_set_packed(&cp, "crop", 10, {1.0, 2.0, 3.0, 4.0, 0, 0, 0}, 0b1111)
	cpt := Timeline {}
	cpt.track_order = make([dynamic]int, 1)
	cpt.tracks = make([dynamic]Track, 1)
	cpt.tracks[0].clips = make([dynamic]Clip, 1)
	cpt.tracks[0].clips[0] = cp
	cp_cloned := clone_timeline(cpt)
	cpcl := &cp_cloned.tracks[0].clips[0]
	cp_ok := false
	if ti := kf_track_index(cpcl^, "crop"); ti >= 0 {
		keys := cpcl.keyframe_tracks[ti].keys
		cp_ok = len(keys) == 1 && keys[0].mask == 0b1111
		if cp_ok {
			cv, _ := kf_lane_value(keys[0], 3)
			cp_ok = cv == 4.0
		}
	}
	kf_probe_check(cp_ok, "clone_timeline carries a packed section with its n and values")
	free_timeline(&cp_cloned)
	free_timeline(&cpt)

	// --- auto-keyframing (kf_auto_key) -------------------------------------
	// With the toggle on, a change to an ALREADY-keyed property writes a key at
	// the playhead; a key already on the frame is updated in place (its interp
	// survives); an unkeyed property or a playhead outside the clip declines.
	ak_saved_toggle := editor_flags.auto_keyframe
	ak_saved_ph := playhead.frame
	defer {
		editor_flags.auto_keyframe = ak_saved_toggle
		playhead.frame = ak_saved_ph
	}
	editor_flags.auto_keyframe = true
	ak := Clip {timeline_start_frame = 10, source_length_frames = 40}
	kf_set_key(&ak, "gain", 5, 1.0)
	kf_set_key(&ak, "gain", 30, 2.0)
	ak.keyframe_tracks[0].keys[1].interp = .Ease_In_Out
	ak_ti := &ak.keyframe_tracks[0]

	// Playhead INSIDE the clip, mid-segment, no key on the frame: insert.
	// (playhead 20 -> clip-relative off 10, between the keys at 5 and 30.)
	playhead.frame = 20
	got_track_before := len(ak.keyframe_tracks[0].keys)
	created := kf_auto_key(&ak, "gain", 3.0)
	ak_ok := created && len(ak_ti.keys) == got_track_before + 1
	if ak_ok {
		akv, _ := kf_sample(ak_ti, 10, 0.0)
		ak_ok = akv == 3.0
	}
	kf_probe_check(ak_ok, "auto-key inserts a new key at the playhead mid-segment")

	// Playhead ON an existing key, same property: update in place, count
	// unchanged, and the key keeps its interpolation mode. The original key
	// sits at clip-relative off 30 (timeline frame 40).
	playhead.frame = 40
	mode_before := ak_ti.keys[2].interp
	updated := kf_auto_key(&ak, "gain", 9.0)
	ak_ok = updated && len(ak_ti.keys) == got_track_before + 1
	if ak_ok {
		akv, _ := kf_sample(ak_ti, 30, 0.0)
		ak_ok = akv == 9.0 && ak_ti.keys[2].interp == mode_before
	}
	kf_probe_check(ak_ok, "auto-key on an existing key updates it in place, preserving its mode")

	// Unkeyed property: declined, no new track minted.
	playhead.frame = 20
	ak_ok = !kf_auto_key(&ak, "scale", 1.5)
	ak_ok = ak_ok && kf_track_index(ak, "scale") < 0
	kf_probe_check(ak_ok, "auto-key declines an unkeyed property and mints no track")

	// Playhead outside the clip: declined even though the property is keyed.
	playhead.frame = 60
	ak_ok = !kf_auto_key(&ak, "gain", 4.0)
	kf_probe_check(ak_ok, "auto-key declines when the playhead sits outside the clip")

	// Toggle off: declined entirely.
	editor_flags.auto_keyframe = false
	playhead.frame = 20
	ak_ok = !kf_auto_key(&ak, "gain", 4.0)
	kf_probe_check(ak_ok, "auto-key declines when the toggle is off")

	// --- keyed gain reaches BOTH mixers in the RIGHT UNIT -----------------
	// The gain track is authored in dB (kf_add_prop keys cl.gain, which the
	// inspector shows as "%.1f dB"), but a mixer multiplies PCM by a LINEAR
	// amplitude. The two used to be conflated: a -40 dB key was applied as a
	// -40x multiplier, so playback opened with an inverted blast instead of
	// near-silence. Playback and export now share kf_gain_linear; this pins the
	// conversion and the two seams that use it.
	{
		db_keys := [2]Keyframe {
			{frame_off = 0, value = f32(-40.0), interp = .Linear},
			{frame_off = 41, value = f32(0.0), interp = .Linear},
		}
		g0 := kf_gain_linear(db_keys[:], 0, 0)
		kf_probe_check(
			kf_approx(g0, db_to_linear(-40)),
			"keyed gain at frame 0: want linear(-40dB)=%.5f, got %.5f (raw dB applied as a multiplier would be -40)",
			db_to_linear(-40),
			g0,
		)
		kf_probe_check(kf_approx(kf_gain_linear(db_keys[:], 41, 0), 1.0), "keyed gain lands at unity on the 0 dB key")
		// Past the last key the track is inactive: the STATIC base rules. Here
		// that base is 0 dB, so the value is unity again (not silence, and not
		// the raw last key value either).
		kf_probe_check(
			kf_approx(kf_gain_linear(db_keys[:], 50, 0), 1.0),
			"past the last gain key the static gain rules",
		)
		// A keyed midpoint sits between the endpoints in amplitude, not at the
		// raw dB number.
		mid := kf_gain_linear(db_keys[:], 20, 0)
		kf_probe_check(
			mid > g0 && mid < 1.0,
			"a keyed segment interpolates in amplitude: mid=%.5f must be inside (%.5f, 1)",
			mid,
			g0,
		)
		// Empty track: the static base, converted. This is the unkeyed clip.
		kf_probe_check(
			kf_approx(kf_gain_linear(db_keys[:0], 3, -20), db_to_linear(-20)),
			"unkeyed gain returns the static dB base, converted",
		)

		// Both mixers read the SAME committed snapshot shape and evaluate it
		// through audio_gain_linear, so a key's dB value can never be treated
		// as a multiplier on one path but not the other.
		snap := Audio_Gain_Snapshot{db = 0, n = 2}
		snap.keys[0] = db_keys[0]
		snap.keys[1] = db_keys[1]
		kf_probe_check(
			kf_approx(audio_gain_linear(&snap, 0), g0),
			"committed gain snapshot must agree with kf_gain_linear",
		)
		kf_probe_check(
			kf_approx(audio_gain_linear(&snap, 20), mid),
			"committed gain snapshot must interpolate in amplitude",
		)

		// Playback seam: Play_Seg latches the committed snapshot; the mix path
		// resolves it through audio_gain_linear.
		kg := Play_Seg{start_a = 0, start_s = 0, len_a = 100, gain = snap}
		kf_probe_check(
			kf_approx(play_seg_gain_linear(&kg, 0), g0),
			"playback seam must agree with audio_gain_linear",
		)

		// Export seam: Render_Audio_Src carries the same snapshot type. The
		// export used to apply NO gain at all, so a rendered file ignored the
		// slider and its automation entirely.
		xg := Render_Audio_Src{gain = snap}
		kf_probe_check(
			kf_approx(audio_gain_linear(&xg.gain, 0), g0),
			"export seam must agree with audio_gain_linear",
		)
		kf_probe_check(
			kf_approx(audio_gain_linear(&xg.gain, 20), mid),
			"export seam must interpolate like playback",
		)

		// Wiring: committing a clip must capture the static dB AND the track;
		// the export job must copy that committed snapshot, not re-derive it.
		// A src that dropped either is exactly how export and playback drifted.
		xc := Clip{timeline_start_frame = 100, source_length_frames = 50, gain = -3}
		kf_set_key(&xc, "gain", 0, -40.0)
		kf_set_key(&xc, "gain", 41, 0.0)
		gs, gtotal := audio_gain_snapshot_from_clip(&xc)
		kf_probe_check(gs.db == -3, "committed gain must carry the static clip gain (got %v)", gs.db)
		kf_probe_check(gs.n == 2, "committed gain must snapshot the track (got %d keys)", gs.n)
		kf_probe_check(gtotal == 2, "committed gain must report the real key count")
		kf_probe_check(
			kf_approx(audio_gain_linear(&gs, 0), db_to_linear(-40)),
			"committed gain at frame 0 must render the keyed gain",
		)

		// render_audio_src_from_chip copies the committed chip verbatim. One
		// heap slot stands in for the committed slab; path_len 0 keeps this
		// off the path arena.
		slot := new(Audio_Geom_Slot)
		defer free(slot)
		slot.chip[0] = Audio_Geom_Chip {
			timeline_start = 5,
			stream_index   = 2,
			gain           = gs,
		}
		rs := render_audio_src_from_chip(slot, &slot.chip[0])
		kf_probe_check(
			rs.gain.db == gs.db && rs.gain.n == gs.n,
			"export src must copy the committed gain snapshot",
		)
		kf_probe_check(
			rs.stream_index == 2 && rs.timeline_start_frame == 5,
			"export src must copy the committed chip identity",
		)
		mem.delete_cstring(rs.path)
	}

	// --- inspector gain readout follows the playhead ----------------------
	// The gain row was the only property whose readout showed the resting field
	// instead of the value at the playhead, so on a keyed clip it disagreed
	// with what playback was doing. clip_gain_db_at_playhead owns the rule.
	{
		gc := Clip {timeline_start_frame = 100, source_length_frames = 50, gain = 0}
		kf_set_key(&gc, "gain", 0, -40.0)
		kf_set_key(&gc, "gain", 41, 0.0)
		playhead.frame = 100 // rel 0, on the first key
		kf_probe_check(
			kf_approx(clip_gain_db_at_playhead(&gc), -40.0),
			"gain readout on the first key must show the keyed dB, got %v",
			clip_gain_db_at_playhead(&gc),
		)
		playhead.frame = 141 // rel 41, on the second key
		kf_probe_check(
			kf_approx(clip_gain_db_at_playhead(&gc), 0.0),
			"gain readout on the last key must show the keyed dB",
		)
		// No gain track: the static value is shown.
		uc := Clip {gain = -6.5}
		playhead.frame = 0
		kf_probe_check(
			clip_gain_db_at_playhead(&uc) == -6.5,
			"gain readout on an unkeyed clip shows the static gain",
		)
	}

	if kf_probe_fail {
		fmt.println("[kf-probe] summary: FAIL")
		return 1
	}
	fmt.println("[kf-probe] ok")
	return 0
}