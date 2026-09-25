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
		v, ok := kf_sample_for(clip, lane, i64(f), base)
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

	// --- packed sections: grouped whole-crop/transform keys -----------------
	// A packed key lives on a SECTION track ("crop"), n > 0 lanes. Section and
	// lane tracks never coexist. Full pack first: sorted insert + same-frame
	// replace, lane readout, lane-absent invariant.
	crop := Clip {}
	kf_set_key_packed(&crop, "crop", 10, {10.0, 14.0, 4.0, 6.0, 0, 0, 0}, 0b1111)
	kf_set_key_packed(&crop, "crop", 30, {20.0, 8.0, 1.0, 9.0, 0, 0, 0}, 0b1111)
	kf_set_key_packed(&crop, "crop", 10, {11.0, 13.0, 3.0, 7.0, 0, 0, 0}, 0b1111)
	cti := kf_track_index(crop, "crop")
	kf_probe_check(cti >= 0, "packed: section track exists")
	kf_probe_check(len(crop.keyframe_tracks) == 1, "packed: one section track, got %d", len(crop.keyframe_tracks))
	kf_probe_check(
		kf_section_full_mask("crop") == 0b1111 && kf_section_full_mask("transform") == 0b11,
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
	v, ok = kf_sample_for(&crop, "crop.l", 10, 0.0)
	kf_probe_check(ok && v == 11.0, "packed: lane 0 key applies on its frame (got %v)", v)
	v, _ = kf_sample_for(&crop, "crop.r", 20, 0.0)
	kf_probe_check(kf_approx(v, 10.5), "packed: lane 1 interpolates 13->8 at the midpoint (got %v)", v)
	v, _ = kf_sample_for(&crop, "crop.t", 30, 0.0)
	kf_probe_check(v == 1.0, "packed: lane 2 arrives at the next key's value (got %v)", v)
	v, ok = kf_sample_for(&crop, "crop.b", 35, 0.0)
	kf_probe_check(!ok && v == 0.0, "packed: past the last key a lane rests, base kept (v=%v ok=%v)", v, ok)
	v, ok = kf_sample_for(&crop, "crop.l", 5, 0.0)
	kf_probe_check(!ok && v == 0.0, "packed: before the first key, base (v=%v ok=%v)", v, ok)

	// --- partial pack: n < section width leaves uncovered lanes resting -----
	pp := Clip {}
	kf_set_key_packed(&pp, "crop", 10, {5.0, 6.0, 0, 0, 0, 0, 0}, 0b11)
	unv, unok := kf_sample_for(&pp, "crop.t", 10, 9.0)
	kf_probe_check(!unok && unv == 9.0, "partial pack: an uncovered lane rests (got %v)", unv)
	unv, unok = kf_sample_for(&pp, "crop.b", 7, 9.0)
	kf_probe_check(!unok && unv == 9.0, "partial pack: rest before, during, and after, base holds (got %v)", unv)
	lv, lok := kf_sample_for(&pp, "crop.l", 10, 9.0)
	kf_probe_check(lok && lv == 5.0, "partial pack: covered lane still applies (got %v)", lv)

	// --- packed snapshot (worker seam): section expands to per-lane scalars --
	sl := Clip {}
	kf_set_key_packed(&sl, "transform", 10, {4.0, 8.0, 0, 0, 0, 0, 0}, 0b11)
	kf_set_key_packed(&sl, "transform", 24, {9.0, 1.0, 0, 0, 0, 0, 0}, 0b11)
	snap_dst: [32]Keyframe
	sn, stotal := kf_fill_snapshot(&sl, "transform.x", snap_dst[:])
	kf_probe_check(sn == 2 && stotal == 2, "snapshot: packed section expands to 2 scalar keys, got %d/%d", sn, stotal)
	snap_ok := sn == 2
	if snap_ok {
		snap_ok = snap_dst[0] == Keyframe {10, 0, 4.0} && snap_dst[1] == Keyframe {24, 0, 9.0}
	}
	kf_probe_check(snap_ok, "snapshot: expanded keys match the packed lane values (got %v %v)", snap_dst[0], snap_dst[1])
	for off := i32(0); off <= 30; off += 1 {
		sv2, sok := kf_sample_for(&sl, "transform.x", i64(off), 0.0)
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
	gn, gtotal := kf_fill_snapshot(&gain_clip, "gain", snap_dst[:])
	kf_probe_check(gn == 1 && gtotal == 1 && snap_dst[0] == Keyframe {5, 0, 7.0}, "snapshot: scalar track copies unchanged")

	// --- unwrap: keying an individual lane makes the group give way ---------
	uv := Clip {}
	kf_set_key_packed(&uv, "transform", 10, {4.0, 8.0, 0, 0, 0, 0, 0}, 0b11)
	kf_set_key_packed(&uv, "transform", 24, {9.0, 1.0, 0, 0, 0, 0, 0}, 0b11)
	kf_set_key(&uv, "transform.y", 18, 5.0) // the unwrap trigger
	kf_probe_check(kf_track_index(uv, "transform") < 0, "unwrap: section track gone after a lane key")
	kf_probe_check(kf_track_index(uv, "transform.x") >= 0, "unwrap: sibling lane track exists")
	kf_probe_check(kf_track_index(uv, "transform.y") >= 0, "unwrap: keyed lane track exists")
	// Oracle: the unwrap result must match the SAME edits landing on scalar
	// tracks from the start — lane 0 untouched (keys 10:4, 24:9), lane 1 with
	// the new key at 18 (10:8, 18:5, 24:1). The new key legitimately reshapes
	// the 10→24 segment, so comparing against the PRE-unwrap packed curve
	// (skip-the-new-key) is the wrong oracle.
	uo := Clip {}
	kf_set_key(&uo, "transform.x", 10, 4.0)
	kf_set_key(&uo, "transform.x", 24, 9.0)
	kf_set_key(&uo, "transform.y", 10, 8.0)
	kf_set_key(&uo, "transform.y", 18, 5.0)
	kf_set_key(&uo, "transform.y", 24, 1.0)
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
	kf_set_key_packed(&sv_clip, "transform", 10, {4.0, 8.0, 0, 0, 0, 0, 0}, 0b11)
	kf_set_key_packed(&sv_clip, "transform", 24, {9.0, 1.0, 0, 0, 0, 0, 0}, 0b11)
	kf_set_value(&sv_clip, "transform", 10, 6.5)
	kf_probe_check(kf_track_index(sv_clip, "transform") < 0, "kf_set_value: section unwrapped")
	ev, eok := kf_sample_for(&sv_clip, "transform.x", 10, 0.0)
	kf_probe_check(eok && ev == 6.5, "kf_set_value: lane 0 holds the edited value (got %v)", ev)
	ey, _ := kf_sample_for(&sv_clip, "transform.y", 10, 0.0)
	kf_probe_check(ey == 8.0, "kf_set_value: the untouched sibling lane keeps its value (got %v)", ey)

	// --- fold: keying the whole section over keyed lanes --------------------
	fv := Clip {}
	kf_set_key(&fv, "crop.l", 10, 1.0)
	kf_set_key(&fv, "crop.r", 10, 2.0)
	kf_set_key(&fv, "crop.l", 22, 5.0)
	kf_set_key(&fv, "crop.r", 30, 6.0)
	kf_set_key(&fv, "crop.t", 10, 3.0)
	kf_set_key(&fv, "crop.t", 30, 4.0)
	kf_set_key(&fv, "crop.b", 10, 7.0)
	kf_set_key(&fv, "crop.b", 30, 8.0)
	// Oracle: the pre-fold lanes plus the same group edit applied per-lane.
	oracle := Clip {}
	kf_set_key(&oracle, "crop.l", 10, 1.0)
	kf_set_key(&oracle, "crop.r", 10, 2.0)
	kf_set_key(&oracle, "crop.l", 22, 5.0)
	kf_set_key(&oracle, "crop.r", 30, 6.0)
	kf_set_key(&oracle, "crop.t", 10, 3.0)
	kf_set_key(&oracle, "crop.t", 30, 4.0)
	kf_set_key(&oracle, "crop.b", 10, 7.0)
	kf_set_key(&oracle, "crop.b", 30, 8.0)
	kf_set_key(&oracle, "crop.l", 16, 2.5)
	kf_set_key(&oracle, "crop.r", 16, 3.5)
	kf_set_key(&oracle, "crop.t", 16, 3.25)
	kf_set_key(&oracle, "crop.b", 16, 7.25)
	// The fold trigger: a whole-crop key on frame 16 with the group edit values.
	kf_set_key_packed(&fv, "crop", 16, {2.5, 3.5, 3.25, 7.25, 0, 0, 0}, 0b1111)
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
	kf_set_key(&rb, "crop.l", 10, 2.0)
	kf_set_key(&rb, "crop.r", 40, 9.0) // first key LATER than frame 10's union knot
	br, brok := kf_sample_for(&rb, "crop.r", 12, 1.0)
	kf_probe_check(!brok && br == 1.0, "fold setup: crop.r rests pre-edit, base 1 (got %v)", br)
	kf_set_key_packed(&rb, "crop", 20, {3.0, 4.0, 0, 0, 0, 0, 0}, 0b11)
	rr, rrok := kf_sample_for(&rb, "crop.r", 12, 1.0)
	kf_probe_check(!rrok && rr == 1.0, "fold: crop.r keeps resting base 1 before its first key (got %v)", rr)

	// --- del / trim / split on a packed section (n survives remaps) ----------
	pc := Clip {}
	kf_set_key_packed(&pc, "crop", 5, {1.0, 2.0, 3.0, 4.0, 0, 0, 0}, 0b1111)
	kf_set_key_packed(&pc, "crop", 40, {2.0, 4.0, 6.0, 8.0, 0, 0, 0}, 0b1111)
	kf_del_key(&pc, "crop", 5)
	pk := kf_track_index(pc, "crop")
	del_ok := false
	if pk >= 0 {
		keys := pc.keyframe_tracks[pk].keys
		del_ok = len(keys) == 1 && keys[0].frame_off == 40 && keys[0].mask == 0b1111
	}
	kf_probe_check(del_ok, "del on a packed section drops only the frame, n survives")
	th := Clip {}
	kf_set_key_packed(&th, "crop", 5, {1.0, 2.0, 3.0, 4.0, 0, 0, 0}, 0b1111)
	kf_set_key_packed(&th, "crop", 40, {2.0, 4.0, 6.0, 8.0, 0, 0, 0}, 0b1111)
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
	kf_set_key_packed(&sp2, "crop", 10, {1.0, 2.0, 3.0, 4.0, 0, 0, 0}, 0b1111)
	kf_set_key_packed(&sp2, "crop", 30, {2.0, 4.0, 6.0, 8.0, 0, 0, 0}, 0b1111)
	kf_set_key_packed(&sp2, "crop", 50, {3.0, 6.0, 9.0, 12.0, 0, 0, 0}, 0b1111)
	sp2r := sp2
	kf_split_parts(&sp2, &sp2r, 30)
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
	kf_set_key_packed(&cp, "crop", 10, {1.0, 2.0, 3.0, 4.0, 0, 0, 0}, 0b1111)
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

	if kf_probe_fail {
		fmt.println("[kf-probe] summary: FAIL")
		return 1
	}
	fmt.println("[kf-probe] ok")
	return 0
}