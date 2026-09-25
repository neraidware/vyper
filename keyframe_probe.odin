package main

import "core:fmt"

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
			keys[0] == Keyframe {10, 0, 5.0},
			"inserts must stay sorted and the repeated frame replaced: keys[0]=%v",
			keys[0],
		)
		kf_probe_check(keys[1] == Keyframe {20, 0, 2.0}, "keys[1]=%v", keys[1])
		kf_probe_check(keys[2] == Keyframe {30, 0, 3.0}, "keys[2]=%v", keys[2])
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
	v, ok = kf_sample_for(&sf, "gain", 100, 9.0)
	kf_probe_check(ok && v == 4.0, "frame 100 == clip-relative off 0: the key's value applies (got %v)", v)
	v, ok = kf_sample_for(&sf, "gain", 101, 9.0)
	kf_probe_check(!ok && v == 9.0, "frame 101 == off 1: lone key past, base applies (got %v)", v)
	v, ok = kf_sample_for(&sf, "scale", 100, 9.0)
	kf_probe_check(!ok && v == 9.0, "unknown property: base kept, inactive")

	// --- split remap (slice-1 rule) -----------------------------------------
	sp := Clip {source_length_frames = 100}
	kf_set_key(&sp, "gain", 10, 1.0)
	kf_set_key(&sp, "gain", 40, 2.0) // on the cut frame -> right half, re-rel 0
	kf_set_key(&sp, "gain", 45, 3.0)
	kf_set_key(&sp, "gain", 99, 4.0)
	sp_right := sp
	kf_split_parts(&sp, &sp_right, 40)
	left_ok := false
	if len(sp.keyframe_tracks) == 1 {
		lk := sp.keyframe_tracks[0].keys
		left_ok = len(lk) == 1 && lk[0] == Keyframe {10, 0, 1.0}
	}
	kf_probe_check(left_ok, "left keeps only keys < cut, values preserved")
	right_ok := false
	if len(sp_right.keyframe_tracks) == 1 {
		rk := sp_right.keyframe_tracks[0].keys
		right_ok = len(rk) == 3 &&
		rk[0] == Keyframe {0, 0, 2.0} &&
		rk[1] == Keyframe {5, 0, 3.0} &&
		rk[2] == Keyframe {59, 0, 4.0}
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
		trim_ok = len(tk) == 2 && tk[0] == Keyframe {0, 0, 2.0} && tk[1] == Keyframe {5, 0, 3.0}
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
		trim2_ok = len(tk) == 2 && tk[0] == Keyframe {5, 0, 1.0} && tk[1] == Keyframe {40, 0, 2.0}
	}
	kf_probe_check(trim2_ok, "trim_tail drops keys beyond the new length")

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
	sv, _ := kf_sample_for(&base, "scale", 59, 0.0) // off 9, past the lone key
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
	v, ok = kf_sample_for(&del, "gain", 7, 2.0)
	kf_probe_check(!ok && v == 2.0, "deleted track is inactive")

	// --- zero-value Clip{} stays safe --------------------------------------
	z := Clip {}
	v, ok = kf_sample_for(&z, "gain", 7, 3.5)
	kf_probe_check(!ok && v == 3.5, "zero-value clip: inactive, base kept")
	kf_probe_check(kf_track_index(z, "gain") < 0, "zero-value clip: no tracks")
	kf_del_key(&z, "gain", 0)
	kf_split_parts(&z, &z, 10)
	kf_trim_head(&z, 5)
	kf_trim_tail(&z, 5)
	kf_probe_check(len(z.keyframe_tracks) == 0, "remaps on zero-value clip are no-ops")

	if kf_probe_fail {
		fmt.println("[kf-probe] summary: FAIL")
		return 1
	}
	fmt.println("[kf-probe] ok")
	return 0
}