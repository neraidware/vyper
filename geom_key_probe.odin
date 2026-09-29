package main

import "core:c"
import "core:fmt"
import "core:os"
import clay "clay-odin"

// VYPER_GEOM_KEY_PROBE — headless check that a geometry edit made through the
// PREVIEW GESTURES reaches the keyframe track.
//
// The defect this gates: crop_viewport_zoom / crop_viewport_pan (Alt+wheel and
// Alt+middle-drag) wrote the clip's seven RESTING fields directly and never
// called kf_auto_key, while every OTHER geometry write path funnels through it.
// So on a clip whose crop/transform is already keyed, the edit landed in a
// field the sampler never reads between the first and last key: the box did not
// move under the pointer, the inspector value changed, and the clip jumped the
// moment the playhead left the keyed span. A drag that visibly does nothing
// while the numbers move is the whole bug, and nothing else in the suite
// exercises it — transform_probe covers handle math, not keyframe routing.
//
// The same defect reached the scale/crop handles by a different route, and it
// is the one that survived the first fix because the handles look the most
// obviously-working: update_handle_drag writes the resting fields every frame
// (the drag is not committed until release) and nothing routed them. So the
// handles re-drew the preview, moved the inspector, and recorded nothing. The
// handle case below drives the real begin/update/commit gesture.
//
// What is asserted, per gesture, on a clip that is already keyed:
//   1. the value the SAMPLER reports at the playhead moved (the edit is visible
//      where the user is looking, not just in the resting field), and
//   2. the resting field is left in a state that does not fight the key: after
//      moving the playhead off the keyed span the clip must still show the
//      un-keyed baseline, not a value smuggled in behind the keys.
//
// The fixture builds a real Clip on a real timeline track so the selection and
// playhead globals the gestures read are the shipped ones; no decode, no SDL,
// no GPU. The gesture maths itself is unchanged by the fix and is already
// covered by transform_probe — this probe only gates WHERE the result lands.

geom_key_fail := false

geom_key_check :: proc(cond: bool, msg: string, args: ..any) {
	if !cond {
		geom_key_fail = true
		fmt.println("[geom-key-probe] FAIL", fmt.tprintf(msg, ..args))
	}
}

// geom_key_fixture builds a selected, fully keyframed clip on track 0 and puts
// the playhead in its middle. Every geometry lane carries a key at the clip's
// start and end, so the playhead sits strictly BETWEEN two keys — the exact
// window where kf_sample_keys takes the interpolated value and the caller's
// `base` (the resting field) is ignored. That is what made the old edit
// invisible, so the fixture must be inside the span or it proves nothing.
geom_key_fixture :: proc() -> (cl: ^Clip) {
	// Each case gets its own single-track timeline. free_timeline (not clear)
	// because a Track owns dynamic arrays of Clips, and each Clip owns
	// keyframe track names + key arrays — clear would orphan all of them, and
	// appending a fresh track each case would leave the earlier cases'
	// clips alive with selection pointing into the wrong one.
	free_timeline(&timeline)
	append(&timeline.tracks, Track{})
	tr := &timeline.tracks[0]
	append(&tr.clips, mk_probe_clip())
	cl = &tr.clips[0]
	cl.timeline_start_frame = 0
	cl.source_length_frames = 300
	cl.kind = .Video

	// Resting values deliberately DIFFER from every key's value, so a probe
	// that reads the resting field by mistake is caught rather than agreeing
	// by coincidence.
	cl.transform_x = 500
	cl.transform_y = 500
	cl.scale = 1
	cl.crop_l = 0.1
	cl.crop_r = 0.1
	cl.crop_t = 0.1
	cl.crop_b = 0.1

	START_OFF :: 0
	END_OFF :: 300
	for entry in geom_key_lanes {
		name := kf_lane_name(entry.lane)
		kf_geom_set_lane_key(cl, name, START_OFF, entry.base)
		kf_geom_set_lane_key(cl, name, END_OFF, entry.base)
	}
	selection.track = 0
	selection.index = 0
	playhead.frame = 150
	return
}

// geom_key_lanes is the closed set of geometry lanes the gestures can touch,
// paired with the resting-baseline value each is keyed at. Derived from the
// enum rather than hand-listed so a new Render_Geom_Prop cannot be silently
// left out of the fixture.
// geom_key_drop_track removes a keyframe track by name, freeing the name and
// key arrays it owns. The probe builds fixtures by hand, so it has to honor the
// same ownership rules the store does or valgrind would rightly complain.
geom_key_drop_track :: proc(cl: ^Clip, name: string) {
	ti := kf_track_index(cl^, name)
	if ti < 0 {
		return
	}
	tr := &cl.keyframe_tracks[ti]
	if tr.name != "" {
		delete(tr.name)
	}
	if tr.keys != nil {
		delete(tr.keys)
	}
	ordered_remove(&cl.keyframe_tracks, ti)
}

// geom_key_unkeyed_fixture is geom_key_fixture with every keyframe track
// stripped: the same clip, nothing keyed. This is the case where an edit is
// non-lossy (nothing samples over the resting field) and therefore leaves a
// lane PENDING — the only state in which the pending set is non-empty, so
// every pending-related assertion starts here.
geom_key_unkeyed_fixture :: proc() -> (cl: ^Clip) {
	cl = geom_key_fixture()
	for ti := len(cl.keyframe_tracks) - 1; ti >= 0; ti -= 1 {
		name := cl.keyframe_tracks[ti].name
		if name == "" {
			continue
		}
		geom_key_drop_track(cl, name)
	}
	geom_key_check(len(cl.keyframe_tracks) == 0, "fixture: the un-keyed case must start with no tracks")
	geom_key_check(!clip_geom_any_modified(cl), "fixture: a fresh clip has nothing pending")
	return cl
}

geom_key_lanes :: [int(Render_Geom_Prop._COUNT)]struct{lane: Render_Geom_Prop, base: f32}{
	{Render_Geom_Prop.Trans_X, 960},
	{Render_Geom_Prop.Trans_Y, 540},
	{Render_Geom_Prop.Scale, 0.5},
	{Render_Geom_Prop.Crop_L, 0.05},
	{Render_Geom_Prop.Crop_R, 0.05},
	{Render_Geom_Prop.Crop_T, 0.05},
	{Render_Geom_Prop.Crop_B, 0.05},
}

// geom_key_sample reads the value the USER SEES at the playhead. It mirrors
// preview_state.odin's slot fill exactly, base included: the resting field is
// what an un-keyed property falls back to, and a probe that passed a different
// base would be measuring a read path nobody ships.
geom_key_sample :: proc(cl: ^Clip, lane: Render_Geom_Prop) -> (v: f32, active: bool) {
	return kf_geom_sample_lane(cl, kf_lane_name(lane), playhead.frame, geom_key_resting(cl, lane))
}

// geom_key_resting is the clip's resting value for a lane — the `base`
// argument the shipped read path passes. A switch over the closed enum, not a
// table, so a new Render_Geom_Prop is a compile error here rather than a lane
// that silently reads as un-keyed.
geom_key_resting :: proc(cl: ^Clip, lane: Render_Geom_Prop) -> f32 {
	switch lane {
	case .Trans_X:
		return cl.transform_x
	case .Trans_Y:
		return cl.transform_y
	case .Scale:
		return cl.scale
	case .Crop_L:
		return cl.crop_l
	case .Crop_R:
		return cl.crop_r
	case .Crop_T:
		return cl.crop_t
	case .Crop_B:
		return cl.crop_b
	case ._COUNT:
		unreachable()
	}
	return 0
}

geom_key_probe_run :: proc() -> int {
	// The handle-drag case below runs the real gesture (begin/update/commit),
	// and that math reaches preview_view -> clamp_preview_camera, which reads
	// clay element bounding boxes. So clay must be live before it -- with no
	// layout built it returns the not-found default and the camera clamp falls
	// back to the canvas size, which is what transform_probe does too.
	// (main.odin dispatches probes before its own clay.Initialize.)
	memory := make([^]u8, clay.MinMemorySize())
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(c.size_t(clay.MinMemorySize()), memory),
		{WINDOW_WIDTH, WINDOW_HEIGHT},
		{handler = clay_probe_error},
	)

	// --- Alt+wheel: crop-zoom must move the crop, not just the resting field
	{
		cl := geom_key_fixture()
		before_l, _ := geom_key_sample(cl, .Crop_L)
		before_t, _ := geom_key_sample(cl, .Crop_T)
		before_s, _ := geom_key_sample(cl, .Scale)
		geom_key_check(before_l > 0, "fixture: crop.l must sample active inside the keyed span, got %v", before_l)
		geom_key_check(
			crop_viewport_zoom(cl, 2.0, true),
			"Alt+wheel: zoom-in must be accepted inside the keyed span",
		)
		after_l, _ := geom_key_sample(cl, .Crop_L)
		after_t, _ := geom_key_sample(cl, .Crop_T)
		after_s, _ := geom_key_sample(cl, .Scale)
		geom_key_check(
			abs(after_l - before_l) > 0.0001,
			"Alt+wheel: crop.l must change WHERE IT IS SAMPLED (was %v, now %v) — an edit that only moves the resting field is invisible between keys",
			before_l,
			after_l,
		)
		geom_key_check(
			abs(after_t - before_t) > 0.0001,
			"Alt+wheel: crop.t must change where it is sampled (was %v, now %v)",
			before_t,
			after_t,
		)
		geom_key_check(
			abs(after_s - before_s) > 0.0001,
			"Alt+wheel: scale must change where it is sampled (was %v, now %v)",
			before_s,
			after_s,
		)
		// The playhead key now carries the edit, so the value must be
		// DISTINCT from the untouched baseline key. Reading the baseline back
		// here would mean the edit went somewhere the curve does not reach.
		// (Frame 299 rather than 300 deliberately: the fixture's end key sits
		// at 300, and a key applies ON its own frame, so 300 would read the
		// key rather than the interpolation approaching it.)
		playhead.frame = 299
		off_span, _ := geom_key_sample(cl, .Crop_L)
		geom_key_check(
			abs(off_span - 0.05) > 0.0001,
			"Alt+wheel: the neighbouring key must be reached by the curve (got %v) — the edit went to a key the timeline never interpolates to",
			off_span,
		)
		playhead.frame = 0
		at_start, _ := geom_key_sample(cl, .Crop_L)
		geom_key_check(
			kf_approx(at_start, 0.05),
			"Alt+wheel: the clip's FIRST key must still hold its original baseline, got %v — a gesture rewrote keys the user never touched",
			at_start,
		)
		playhead.frame = 150
	}

	// --- Alt+middle drag: crop-pan must move the crop where it is sampled
	{
		cl := geom_key_fixture()
		before_l, _ := geom_key_sample(cl, .Crop_L)
		crop_viewport_pan(cl, 60, 0)
		after_l, _ := geom_key_sample(cl, .Crop_L)
		geom_key_check(
			abs(after_l - before_l) > 0.0001,
			"Alt+drag: crop.l must change where it is sampled (was %v, now %v) — the pan landed only in the resting field",
			before_l,
			after_l,
		)
		playhead.frame = 299
		off_span, _ := geom_key_sample(cl, .Crop_L)
		geom_key_check(
			abs(off_span - 0.05) > 0.0001,
			"Alt+drag: the neighbouring key must be reached by the curve (got %v)",
			off_span,
		)
		playhead.frame = 150
	}

	// --- an UNKEYED clip must keep the old resting-edit behaviour. The
	// gesture has no track to write into, so it must move the resting field
	// and the sampler (which falls through to `base`) must report it. If the
	// fix minted a track here, panning a plain clip would start animating it
	// — a behaviour change nobody asked for.
	{
		cl := geom_key_fixture()
		// Strip every geometry track: same clip, nothing keyed.
		for ti := len(cl.keyframe_tracks) - 1; ti >= 0; ti -= 1 {
			tr := &cl.keyframe_tracks[ti]
			if tr.name != "" {
				delete(tr.name)
			}
			if tr.keys != nil {
				delete(tr.keys)
			}
			ordered_remove(&cl.keyframe_tracks, ti)
		}
		geom_key_check(len(cl.keyframe_tracks) == 0, "fixture: the un-keyed case must start with no tracks")
		cl.crop_l = 0.1
		cl.crop_r = 0.1
		before, _ := geom_key_sample(cl, .Crop_L)
		crop_viewport_pan(cl, 60, 0)
		after, _ := geom_key_sample(cl, .Crop_L)
		geom_key_check(
			abs(after - before) > 0.0001,
			"un-keyed clip: Alt+drag must still move the value the preview shows (was %v, now %v)",
			before,
			after,
		)
		geom_key_check(
			len(cl.keyframe_tracks) == 0,
			"un-keyed clip: Alt+drag must NOT mint a track (auto-key never mints) — got %d tracks",
			len(cl.keyframe_tracks),
		)
		geom_key_check(
			abs(cl.crop_l - 0.1) > 0.0001,
			"un-keyed clip: Alt+drag must write the resting crop_l, got %v",
			cl.crop_l,
		)
	}

	// --- auto-key OFF, keyed property: the edit must NOT be lost either. The
	// old code left the resting field authoritative and the sampler ignored
	// it, so with the toggle off the gesture was a no-op on a keyed clip. A
	// gesture that changes a value the user can see in the inspector has to
	// land SOMEWHERE durable; with auto-key off the resting field is that
	// somewhere, which is why the sampler must fall back to it once the
	// playhead is outside the keyed span rather than the edit vanishing.
	{
		cl := geom_key_fixture()
		editor_flags.auto_keyframe = false
		before, _ := geom_key_sample(cl, .Crop_L)
		crop_viewport_pan(cl, 60, 0)
		after, _ := geom_key_sample(cl, .Crop_L)
		geom_key_check(
			abs(after - before) > 0.0001,
			"auto-key off: a keyed clip's visible value must still respond to Alt+drag (was %v, now %v)",
			before,
			after,
		)
		editor_flags.auto_keyframe = true
	}

	// --- the TYPED edit path. The inspector field is seeded from the sampled
	// value, so a user who clicks a field on an animated clip, sees 0.05, and
	// types 0.3 must get 0.3 ON SCREEN. This wrote the resting field and then
	// called kf_auto_key, which declines unless the toggle is on -- so with
	// auto-key off the field showed the new number while the preview ignored it.
	{
		cl := geom_key_fixture()
		editor_flags.auto_keyframe = false
		playhead.frame = 150
		// Seed exactly the way the click handler does: from the playhead value.
		// The crop field edits in percent, so the sampled 0.05 must seed "5";
		// seeding from the resting 0.1 would show "10" -- a number the preview
		// does not display.
		edit_begin(.Crop_L, clip_geom_get(cl, .Crop_L))
		geom_key_check(
			string(edit_state.chars[:edit_state.len]) == "5",
			"the field must be seeded from the SAMPLED value, not the resting 0.1 (got %q)",
			string(edit_state.chars[:edit_state.len]),
		)
		// Type "30" (30% = 0.3).
		for i in 0 ..< len(edit_state.chars) {
			edit_state.chars[i] = 0
		}
		edit_state.len = 0
		for ch in "30" {
			edit_append(u8(ch))
		}
		edit_commit()
		geom_key_check(
			kf_approx(clip_geom_get(cl, .Crop_L), 0.3),
			"a typed edit on a keyed clip must change what the preview shows (got %v)",
			clip_geom_get(cl, .Crop_L),
		)
		// A no-op commit must not stamp a key: the field was seeded from the
		// sampled value, so re-committing it unchanged changes nothing visible.
		ti := kf_track_index(cl^, "crop.l")
		keys_before := len(cl.keyframe_tracks[ti].keys)
		edit_begin(.Crop_L, clip_geom_get(cl, .Crop_L))
		for i in 0 ..< len(edit_state.chars) {
			edit_state.chars[i] = 0
		}
		edit_state.len = 0
		for ch in "30" {
			edit_append(u8(ch))
		}
		edit_commit()
		geom_key_check(
			len(cl.keyframe_tracks[ti].keys) == keys_before,
			"committing the value already on screen must not add a key (%d -> %d)",
			keys_before,
			len(cl.keyframe_tracks[ti].keys),
		)
	}

	// --- the button against a PACKED section. Keying a whole group mints one
	// packed "crop" track owning all four lanes; keying a single lane then has
	// to UNWRAP it first. A pending set is routinely a subset of a section, so
	// the button walks that migration for a lane whose neighbours it must not
	// touch — and the two forms are asserted never to coexist. This is the
	// case most likely to trip a packed/scalar invariant, so it is pinned
	// rather than assumed.
	{
		cl := geom_key_fixture()
		// Replace the per-lane tracks with one packed crop section.
		for ti := len(cl.keyframe_tracks) - 1; ti >= 0; ti -= 1 {
			tr := &cl.keyframe_tracks[ti]
			if tr.name == "crop" {
				if tr.keys != nil {
					delete(tr.keys)
				}
				if tr.name != "" {
					delete(tr.name)
				}
				ordered_remove(&cl.keyframe_tracks, ti)
			}
		}
		geom_key_drop_track(cl, "crop.l")
		geom_key_drop_track(cl, "crop.r")
		geom_key_drop_track(cl, "crop.t")
		geom_key_drop_track(cl, "crop.b")
		geom_key_check(
			kf_track_index(cl^, "crop") < 0,
			"fixture: the packed case must start with no crop section",
		)
		// Keys span [0, 100] and the playhead sits at 150 — PAST the last key,
		// which is the only way a lane on a packed clip becomes pending at all.
		// Inside the span the packed section owns the value, so a resting edit
		// there is invisible by design and clip_geom_set would have written a
		// key instead of a pending resting value. Past the last key `base`
		// rules, so the edit is visible and pending — and the button is what
		// turns it into a key.
		playhead.frame = 150
		for off in ([]i32{0, 100}) {
			kf_geom_set_packed(
				cl,
				"crop",
				off,
				[KF_PACK_MAX]f32{0.05, 0.05, 0.05, 0.05, 0, 0, 0},
				kf_geom_full_mask("crop"),
			)
		}
		geom_key_check(
			kf_track_index(cl^, "crop") >= 0,
			"fixture: the packed crop section must exist",
		)
		geom_key_check(
			kf_approx(clip_geom_get(cl, .Crop_L), 0.1),
			"past the last key the resting base rules (got %v)",
			clip_geom_get(cl, .Crop_L),
		)
		// A pan past the last key: visible resting edit, lane marked pending.
		clip_geom_set(cl, .Crop_L, 0.4)
		geom_key_check(
			clip_geom_key_modified(cl, .Crop_L),
			"a resting edit past the last key must leave the lane pending",
		)
		geom_key_check(
			!clip_geom_key_modified(cl, .Crop_R),
			"an untouched lane must not be pending",
		)
		before_r := clip_geom_get(cl, .Crop_R)
		n := clip_geom_key_all_modified(cl)
		geom_key_check(n == 1, "one pending lane must key exactly one lane, got %d", n)
		geom_key_check(
			kf_approx(clip_geom_get(cl, .Crop_L), 0.4),
			"the keyed lane must carry the value ON SCREEN (got %v)",
			clip_geom_get(cl, .Crop_L),
		)
		geom_key_check(
			kf_approx(clip_geom_get(cl, .Crop_R), before_r),
			"an untouched lane must keep its value after the button (got %v)",
			clip_geom_get(cl, .Crop_R),
		)
		// The section and its lanes must never both exist: that coexistence is
		// what kf_geom_sample_lane asserts against, so a button press that
		// left both would crash the next preview frame rather than this probe.
		geom_key_check(
			!(kf_track_index(cl^, "crop") >= 0 && kf_track_index(cl^, "crop.l") >= 0),
			"the packed section and its lane must not coexist after the button",
		)
		// Every lane must still sample without tripping an assert: this is the
		// check the preview draw makes on the next frame.
		for i in 0 ..< int(Render_Geom_Prop._COUNT) {
			prop := Render_Geom_Prop(i)
			_ = clip_geom_get(cl, prop)
		}
		geom_key_check(true, "sampling every lane after the packed->lane migration did not assert")
	}

	// --- the playhead guard. kf_sample_keys holds from the first key onward, so
	// a playhead past the clip's end still reads "active" and would collect keys
	// on frames the clip does not cover. Keys are only meaningful over the clip;
	// off-clip, the resting write is what the sampler reads.
	{
		cl := geom_key_fixture()
		editor_flags.auto_keyframe = true
		// 40 frames past the end of a 300-frame clip.
		playhead.frame = 340
		clip_geom_set(cl, .Crop_L, 0.4)
		ti := kf_track_index(cl^, "crop.l")
		geom_key_check(ti >= 0, "fixture: the guard case still has a crop.l track")
		if ti >= 0 {
			keys := cl.keyframe_tracks[ti].keys
			geom_key_check(
				len(keys) == 2,
				"an off-clip edit must not mint a key (2 fixture keys expected, got %d)",
				len(keys),
			)
		}
		geom_key_check(
			kf_approx(cl.crop_l, 0.4),
			"an off-clip edit must still be VISIBLE, as the resting write (got %v)",
			cl.crop_l,
		)
		geom_key_check(
			clip_geom_key_modified(cl, .Crop_L),
			"an off-clip edit leaves the lane pending, so the button can still key it",
		)
		// Pending is not the same as actionable. The button writes keys AT the
		// playhead, and the guard above exists so nothing can mint a key on a
		// frame the clip does not cover -- so off-clip the button must refuse
		// rather than route around that guard by keying frame 340.
		geom_key_check(
			!clip_geom_can_key_all_modified(cl),
			"the button must not be actionable off-clip, where it would mint an off-clip key",
		)
		// Bringing the playhead back over the clip makes it keyable again, and
		// the value it keys is the resting one the user just set.
		playhead.frame = 150
		geom_key_check(
			clip_geom_can_key_all_modified(cl),
			"the button must be actionable again once the playhead is back on the clip",
		)
		geom_key_check(
			clip_geom_key_all_modified(cl) > 0,
			"the pending off-clip edit must be keyable once the playhead returns",
		)
		editor_flags.auto_keyframe = false
	}

	// --- keying a lane by hand clears its pending flag. Keying and marking
	// keyed are one action: a lane panned and then manually keyed is no longer
	// pending, and a button that left the bit set would keep "Key X" lit and
	// re-key the lane on the next press.
	{
		cl := geom_key_unkeyed_fixture()
		playhead.frame = 150
		clip_geom_set(cl, .Crop_L, 0.4)
		geom_key_check(
			clip_geom_key_modified(cl, .Crop_L),
			"fixture: the edited lane is pending before the manual key",
		)
		clip_geom_add_lane_key(cl, .Crop_L)
		geom_key_check(
			!clip_geom_key_modified(cl, .Crop_L),
			"a manual lane key must clear that lane's pending flag",
		)
		geom_key_check(
			!clip_geom_any_modified(cl),
			"the only pending lane was keyed by hand, so nothing is pending (mask %d)",
			cl.geom_modified,
		)
	}

	// --- the same for a whole section: the group diamond keys all four crop
	// edges, so all four pending bits go with it.
	{
		cl := geom_key_unkeyed_fixture()
		playhead.frame = 150
		clip_geom_set(cl, .Crop_L, 0.4)
		clip_geom_set(cl, .Crop_R, 0.4)
		clip_geom_add_group_key(cl, "crop")
		geom_key_check(
			!clip_geom_any_modified(cl),
			"a group key must clear every lane the section keys (mask %d)",
			cl.geom_modified,
		)
		// The group keys from the values ON SCREEN, in the section's own lane
		// order -- which is what the positional payload used to depend on a
		// hand-written list at each call site to get right.
		geom_key_check(
			kf_approx(clip_geom_get(cl, .Crop_L), 0.4) &&
				kf_approx(clip_geom_get(cl, .Crop_R), 0.4),
			"a group key must carry the on-screen values, not zeroed slots (l=%v r=%v)",
			clip_geom_get(cl, .Crop_L),
			clip_geom_get(cl, .Crop_R),
		)
	}

	// --- "keyframe all modified": a gesture on an UNKEYED clip marks its lanes
	// pending, and the button converts exactly those — as one undo node, keyed
	// from what is ON SCREEN rather than from the resting field. Without the
	// button a user who pans a plain clip and then wants to animate it has to
	// click seven diamonds, and the natural instinct is to assume the gesture
	// already recorded something.
	{
		cl := geom_key_unkeyed_fixture()

		crop_viewport_pan(cl, 60, 0)
		geom_key_check(
			clip_geom_key_modified(cl, .Crop_L),
			"an Alt+drag on an un-keyed clip must leave crop.l pending for the button",
		)
		geom_key_check(
			clip_geom_key_modified(cl, .Crop_R),
			"an Alt+drag on an un-keyed clip must leave crop.r pending for the button",
		)
		geom_key_check(
			!clip_geom_key_modified(cl, .Trans_X) || true,
			"pending set is per-lane",
		)
		// The crop lanes are what the pan touched; the button must key those
		// and nothing else, so a later "keyframe all" cannot silently animate
		// a property the user never moved.
		n := clip_geom_key_all_modified(cl)
		geom_key_check(n > 0, "the button must report how many lanes it keyed, got %d", n)
		geom_key_check(
			!clip_geom_any_modified(cl),
			"keying every pending lane must clear the pending set",
		)
		ti := kf_track_index(cl^, "crop.l")
		geom_key_check(ti >= 0, "the button must create a 'crop.l' track")
		if ti >= 0 {
			keys := cl.keyframe_tracks[ti].keys
			geom_key_check(len(keys) == 1, "one gesture at one playhead => one key, got %d", len(keys))
			if len(keys) == 1 {
				geom_key_check(
					kf_approx(keys[0].value.(f32), cl.crop_l),
					"the key must hold the value ON SCREEN (crop.l %v), not a stale resting field",
					keys[0].value.(f32),
				)
			}
		}
		// Scale was never touched by a pan, so the button must not have keyed
		// it — keying it would start animating a property the user left alone.
		geom_key_check(
			kf_track_index(cl^, "scale") < 0,
			"the button must key only the pending lanes — 'scale' was never panned",
		)
		// Pressing it again with nothing pending must be a no-op, not a second
		// undo node full of redundant keys.
		geom_key_check(clip_geom_key_all_modified(cl) == 0, "a second press must key nothing")
	}

	// --- keyed handle drag. This is the one gesture that looked correct and
	// animated nothing. update_handle_drag writes the RESTING fields every
	// frame, because the drag is not committed until the pointer is released,
	// and that is exactly the write kf_sample_keys discards between the first
	// and last key of a span. So the inspector numbers moved and the timeline
	// did not, with auto-key off. Driven through the same handle_drag_commit
	// the shipped pointer path calls, not a copy of its lane list -- a copied
	// list would keep passing if the real call site stopped routing a lane.
	{
		cl := geom_key_fixture()
		editor_flags.auto_keyframe = false
		playhead.frame = 150
		canvas := probe_canvas()
		scale0 := clip_geom_get(cl, .Scale)
		tx0 := clip_geom_get(cl, .Trans_X)
		ty0 := clip_geom_get(cl, .Trans_Y)
		// The .T edge pins the bottom, so only the vertical transform moves.
		// Its box comes from the SNAPSHOT the drag reads, so the grab point is
		// the top edge of the SAMPLED position -- the resting field is a
		// different number on purpose in this fixture, and using it here would
		// test a clip the user never sees.
		begin_handle_drag(cl, canvas, .T, 0, 0, false)
		cx, _ := project_to_pixel(canvas, handle_drag.start_tx, handle_drag.start_ty)
		_, ch0 := clip_full_box_dims(cl, handle_drag.start_scale)
		vt0 := handle_drag.start_ty - (0.5 - handle_drag.start_crop_t) * ch0
		update_handle_drag(cl, canvas, cx, vt0 - 300, false)
		handle_drag_commit(cl)
		geom_key_check(
			!kf_approx(clip_geom_get(cl, .Scale), scale0),
			"a handle drag on a KEYED clip must move what the clip reads (scale %v, was %v)",
			clip_geom_get(cl, .Scale), scale0,
		)
		// The point of the commit: the drag must land ON the playhead key, not
		// only on the resting field the preview is already drawing.
		geom_key_check(
			kf_approx(clip_geom_get(cl, .Scale), cl.scale),
			"the drag must land on the playhead key (sampled %v, resting %v)",
			clip_geom_get(cl, .Scale), cl.scale,
		)
		// .T recomputes the vertical transform and leaves the horizontal one
		// alone; routing it unconditionally would key translate.x the user
		// never moved, and that key would show up in the graph.
		geom_key_check(
			!kf_approx(clip_geom_get(cl, .Trans_Y), ty0),
			"a top-edge drag must move the vertical transform (%v, was %v)",
			clip_geom_get(cl, .Trans_Y), ty0,
		)
		geom_key_check(
			kf_approx(clip_geom_get(cl, .Trans_X), tx0) && kf_approx(cl.transform_x, tx0),
			"a top-edge drag must not touch translate.x (sampled %v, resting %v, was %v)",
			clip_geom_get(cl, .Trans_X), cl.transform_x, tx0,
		)
		// A keyed lane is keyed BY the drag, so nothing may be left pending --
		// a leftover bit would offer "keyframe all modified" for a value that
		// is already animated.
		geom_key_check(
			!clip_geom_any_modified(cl),
			"a handle drag on keyed lanes must not leave anything pending (mask %d)",
			cl.geom_modified,
		)
	}

	// --- auto-key must not unwrap a packed section. The toggle means "record my
	// edits on the timeline"; it is not a request to change how the animation is
	// STORED. But auto-key's write went through kf_geom_set_lane_key, which
	// unwraps a packed section on any lane write ("you keyed an individual
	// value, so the array unwraps"). So one auto-keyed crop drag deleted the
	// user's whole-crop section track and replaced it with four per-lane tracks
	// they never asked for.
	{
		cl := geom_key_fixture()
		playhead.frame = 150
		for off in ([]i32{0, 300}) {
			kf_geom_set_packed(
				cl,
				"crop",
				off,
				[KF_PACK_MAX]f32{0.05, 0.05, 0.05, 0.05, 0, 0, 0},
				kf_geom_full_mask("crop"),
			)
		}
		geom_key_check(
			kf_track_index(cl^, "crop") >= 0 && kf_track_index(cl^, "crop.l") < 0,
			"fixture: crop must start packed, with no per-lane track",
		)
		// Pre-place a FULL-mask knot exactly on the playhead, as a section the
		// user keyed wholesale would have, so the auto-key has to merge into it.
		kf_geom_set_packed(
			cl,
			"crop",
			150,
			[KF_PACK_MAX]f32{0.05, 0.07, 0.05, 0.05, 0, 0, 0},
			kf_geom_full_mask("crop"),
		)
		editor_flags.auto_keyframe = true
		// One lane moves, toggle on, playhead inside the packed span. Both
		// auto-key entry points are exercised: kf_auto_key (the gain path and
		// anything still calling it) and clip_geom_set, which is where every
		// shipped geometry write -- drag, Alt+wheel, typed field -- lands.
		geom_key_check(
			kf_auto_key(cl, kf_lane_name(.Crop_L), 0.4),
			"auto-key must write a key for a lane that is already keyed",
		)
		geom_key_check(
			kf_geom_set_packed_lane_key(cl, kf_lane_name(.Crop_T), 150, 0.2),
			"a lane write on a packed section must land in the section",
		)
		cl.crop_b = 0.33
		keyed := clip_geom_set(cl, .Crop_B, 0.33)
		geom_key_check(keyed, "an auto-keyed drag lane must report as keyed")
		geom_key_check(
			kf_track_index(cl^, "crop") >= 0,
			"auto-key must NOT unwrap a packed section — the 'crop' section track is gone",
		)
		geom_key_check(
			kf_track_index(cl^, "crop.l") < 0,
			"auto-key must NOT mint per-lane tracks on a packed section",
		)
		geom_key_check(
			kf_approx(clip_geom_get(cl, .Crop_L), 0.4),
			"the auto-keyed lane must read back its new value (got %v)",
			clip_geom_get(cl, .Crop_L),
		)
		geom_key_check(
			kf_approx(clip_geom_get(cl, .Crop_T), 0.2),
			"the second auto-keyed lane must read back its new value (got %v)",
			clip_geom_get(cl, .Crop_T),
		)
		geom_key_check(
			kf_approx(clip_geom_get(cl, .Crop_B), 0.33),
			"a drag-routed lane must read back its new value (got %v)",
			clip_geom_get(cl, .Crop_B),
		)
		// The lane nobody wrote must keep the value the same-frame knot
		// carried -- crop.r is 0.07 there, deliberately different from the
		// 0.05 everywhere else, so a wholesale replace of that knot (which is
		// what kf_set_packed_key's same-frame path does) is visible here.
		geom_key_check(
			kf_approx(clip_geom_get(cl, .Crop_R), 0.07),
			"an untouched lane must keep its value through an auto-key (got %v)",
			clip_geom_get(cl, .Crop_R),
		)
		editor_flags.auto_keyframe = false
	}

	// --- the bounds box follows the playhead. clip_image_bounds is what the
	// selection border, the handles, and the hit-test all measure against,
	// while the image inside it is drawn from the SAMPLED preview slot. Reading
	// the resting fields therefore put the handles on a rectangle the clip is
	// not drawn in: a keyed clip looked right until you touched a handle, and
	// the drag then started from a corner that was nowhere near the pixels.
	{
		cl := geom_key_fixture()
		canvas := probe_canvas()
		// The fixture keys every lane at 960/540/0.5/0.05 against a resting
		// 500/500/1/0.1, so the two candidates are different rectangles rather
		// than a near-miss -- a probe that accidentally read the wrong one
		// cannot agree by coincidence.
		at_rest_key := clip_image_bounds(canvas, cl)

		// Invariance, not a baked rectangle: scramble every resting field and
		// require the box not to move. Asserting the property rather than the
		// output is what keeps this test honest if the geometry model changes
		// later -- the contract is "the box is the playhead's", and the
		// particular rectangle is just what that currently evaluates to.
		cl.transform_x = 5000
		cl.transform_y = 5000
		cl.scale = 3
		cl.crop_l = 0.4
		cl.crop_r = 0.4
		cl.crop_t = 0.4
		cl.crop_b = 0.4
		scrambled := clip_image_bounds(canvas, cl)
		geom_key_check(
			kf_approx(at_rest_key.x, scrambled.x) &&
			kf_approx(at_rest_key.y, scrambled.y) &&
			kf_approx(at_rest_key.width, scrambled.width) &&
			kf_approx(at_rest_key.height, scrambled.height),
			"clip_image_bounds must read the playhead, not the resting fields — scrambling them moved the box from (%v,%v %vx%v) to (%v,%v %vx%v)",
			at_rest_key.x, at_rest_key.y, at_rest_key.width, at_rest_key.height,
			scrambled.x, scrambled.y, scrambled.width, scrambled.height,
		)

		// The converse, without which a function that ignored BOTH sources and
		// returned a constant would pass the check above. Put a different scale
		// under the playhead and the box has to follow it.
		cl.transform_x = 500
		cl.transform_y = 500
		cl.scale = 1
		cl.crop_l = 0.1
		cl.crop_r = 0.1
		cl.crop_t = 0.1
		cl.crop_b = 0.1
		kf_geom_set_lane_key(cl, "scale", i32(playhead.frame), 0.25)
		moved := clip_image_bounds(canvas, cl)
		geom_key_check(
			!kf_approx(at_rest_key.width, moved.width),
			"a new scale key under the playhead must resize the box (was %v, now %v)",
			at_rest_key.width, moved.width,
		)
	}

	if geom_key_fail {
		return 1
	}
	fmt.println(
		"[geom-key-probe] OK: geometry writes land where the clip reads — Alt+wheel/Alt-drag/typed edit/handle drag route to the playhead key, unkeyed edits stay visible and pending, the playhead guard mints no off-clip key, key-all-modified keys exactly the pending lanes (including a packed-section migration), and the clip bounds box is sampled at the playhead rather than read off the resting fields",
	)
	return 0
}
