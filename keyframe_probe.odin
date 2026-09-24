package main

import "core:fmt"

// Keyframe probe (VYPER_KEYFRAME_PROBE): headless regression checks for the
// generic keyframe store — sorted insert/replace, the move-toward sample
// (default + track step, hold on arrival, segment handoff), the split/trim
// remaps, the deep-clone round-trip through clone_timeline, empty-track
// deletion, and zero-value Clip{} safety. Builds its own Clip structs; no
// decode, no SDL, no timeline globals.

kf_probe_fail := false

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
			keys[0] == Keyframe {10, 5.0},
			"inserts must stay sorted and the repeated frame replaced: keys[0]=%v",
			keys[0],
		)
		kf_probe_check(keys[1] == Keyframe {20, 2.0}, "keys[1]=%v", keys[1])
		kf_probe_check(keys[2] == Keyframe {30, 3.0}, "keys[2]=%v", keys[2])
	}

	// --- lookup: missing name ---------------------------------------------
	kf_probe_check(kf_track_index(c, "scale") < 0, "unknown name must miss")

	// --- move-toward sample, default step, base before first key ----------
	// Dedicated two-key clip so the hold/approach scenario is unambiguous
	// (the insert clip above carries a third key at 30).
	smp := Clip {}
	kf_set_key(&smp, "gain", 10, 5.0)
	kf_set_key(&smp, "gain", 20, 2.0)
	gt := kf_track_index(smp, "gain")
	gain: ^Kf_Track
	if gt >= 0 {
		gain = &smp.keyframe_tracks[gt]
	}
	v, ok := kf_sample(gain, 0, 7.0)
	kf_probe_check(!ok && v == 7.0, "before first key: inactive, base kept (v=%v ok=%v)", v, ok)
	v, ok = kf_sample(gain, 9, 7.0)
	kf_probe_check(!ok && v == 7.0, "still before first key at off 9: base kept")
	// first key at 10 target 5, base 0, default step 1.
	v, ok = kf_sample(gain, 10, 0.0)
	kf_probe_check(ok && v == 0.0, "key holds its origin on its own frame (got %v)", v)
	v, _ = kf_sample(gain, 11, 0.0)
	kf_probe_check(v == 1.0, "steps up 1/frame after the key frame (got %v)", v)
	v, _ = kf_sample(gain, 14, 0.0)
	kf_probe_check(v == 4.0, "mid-approach (got %v)", v)
	v, _ = kf_sample(gain, 15, 0.0)
	kf_probe_check(v == 5.0, "arrives exactly at target (got %v)", v)
	v, _ = kf_sample(gain, 16, 0.0)
	kf_probe_check(v == 5.0, "holds after arrival inside the segment (got %v)", v)
	v, _ = kf_sample(gain, 100, 0.0)
	kf_probe_check(v == 2.0, "holds the LAST key's target at end of track (got %v)", v)

	// --- segment handoff: next key starts from the previous arrival --------
	// second key at 20 target 2, origin = 5 (already arrived).
	v, _ = kf_sample(gain, 20, 0.0)
	kf_probe_check(v == 5.0, "new key holds the previous arrival on its own frame")
	v, _ = kf_sample(gain, 21, 0.0)
	kf_probe_check(v == 4.0, "steps down toward the new target (got %v)", v)
	v, _ = kf_sample(gain, 23, 0.0)
	kf_probe_check(v == 2.0, "arrives at second target (got %v)", v)
	v, _ = kf_sample(gain, 50, 0.0)
	kf_probe_check(v == 2.0, "holds second target (got %v)", v)

	// --- descending approach from base -------------------------------------
	d := Clip {}
	kf_set_key(&d, "x", 5, 0.0)
	dt := kf_track_index(d, "x")
	dx: ^Kf_Track
	if dt >= 0 {
		dx = &d.keyframe_tracks[dt]
	}
	v, _ = kf_sample(dx, 5, 10.0)
	kf_probe_check(v == 10.0, "descending key holds base on its frame")
	v, _ = kf_sample(dx, 6, 10.0)
	kf_probe_check(v == 9.0, "descends 1/frame (got %v)", v)
	v, _ = kf_sample(dx, 15, 10.0)
	kf_probe_check(v == 0.0, "arrives at 0 from a descending approach (got %v)", v)

	// --- track step overrides the default ----------------------------------
	s := Clip {}
	kf_set_key(&s, "scale", 3, 10.0, step = 2.0)
	st := kf_track_index(s, "scale")
	sx: ^Kf_Track
	if st >= 0 {
		sx = &s.keyframe_tracks[st]
	}
	v, _ = kf_sample(sx, 4, 0.0)
	kf_probe_check(v == 2.0, "track step 2 (got %v)", v)
	v, _ = kf_sample(sx, 8, 0.0)
	kf_probe_check(v == 10.0, "arrives with the track's step (got %v)", v)

	// --- kf_sample_for at a timeline frame, clip-relative -------------------
	sf := Clip {timeline_start_frame = 100}
	kf_set_key(&sf, "gain", 0, 4.0)
	v, _ = kf_sample_for(&sf, "gain", 100, 9.0)
	kf_probe_check(v == 9.0, "frame 100 == clip-relative off 0: origin held (got %v)", v)
	v, _ = kf_sample_for(&sf, "gain", 101, 9.0)
	kf_probe_check(v == 8.0, "frame 101 == off 1: descends toward 4 (got %v)", v)
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
		left_ok = len(lk) == 1 && lk[0] == Keyframe {10, 1.0}
	}
	kf_probe_check(left_ok, "left keeps only keys < cut, values preserved")
	right_ok := false
	if len(sp_right.keyframe_tracks) == 1 {
		rk := sp_right.keyframe_tracks[0].keys
		right_ok = len(rk) == 3 &&
			rk[0] == Keyframe {0, 2.0} &&
			rk[1] == Keyframe {5, 3.0} &&
			rk[2] == Keyframe {59, 4.0}
	}
	kf_probe_check(right_ok, "right re-relatives keys >= cut by -cut")
	if right_ok {
		v, _ = kf_sample(&sp_right.keyframe_tracks[0], 0, 0.0)
		kf_probe_check(v == 0.0, "right off 0 == old frame 40: origin held")
		v, _ = kf_sample(&sp_right.keyframe_tracks[0], 5, 0.0)
		kf_probe_check(v == 2.0, "right off 5 == old frame 45: arrives at the key value")
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
		trim_ok = len(tk) == 2 && tk[0] == Keyframe {0, 2.0} && tk[1] == Keyframe {5, 3.0}
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
		trim2_ok = len(tk) == 2 && tk[0] == Keyframe {5, 1.0} && tk[1] == Keyframe {40, 2.0}
	}
	kf_probe_check(trim2_ok, "trim_tail drops keys beyond the new length")

	// --- deep clone through clone_timeline: mutate clone, original untouched -
	base := Clip {timeline_start_frame = 50}
	kf_set_key(&base, "gain", 10, 1.5, step = 3.0)
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
	sv, _ := kf_sample_for(&base, "scale", 59, 0.0) // off 9, far past arrival
	kf_probe_check(sv == 9.0, "original scale untouched by the clone's poke (got %v)", sv)
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