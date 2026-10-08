package vyper

import "core:c"
import "core:fmt"
import "core:os"
import clay "clay-odin"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	// VYPER_GEOM_KEY_PROBE — headless check that a geometry edit made through the
	// PREVIEW GESTURES reaches the keyframe track.
	//
	// The defect this gates: clip_zoom_by / clip_pan_by (Alt+wheel and
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
		// ONE live fixture pointer at a time. free_timeline below deletes the clips
		// array, so a pointer from an earlier call is dangling the moment this one
		// returns — cases that need a second clip must be siblings, not nested, or
		// they read freed memory. (Valgrind found exactly that: 76 invalid-read
		// contexts inside clip_pan_by, from a nested fixture call.)
		//
		// Each case gets its own single-track timeline. free_timeline (not clear)
		// because a Track owns a dynamic Clip array, and its Clips hold session range
		// reservations — clear would orphan those slots and appending a fresh track
		// each case would leave the earlier cases'
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
	// geom_key_drop_track removes a keyframe track by name and returns its exclusive
	// key range. The probe builds fixtures by hand, so it honors session ownership.
	geom_key_drop_track :: proc(cl: ^Clip, name: string) {
		ti := kf_track_index(cl^, name)
		if ti < 0 {
			return
		}
		tr := session_trk_view_mut(&cl.keyframe_tracks, ti)
		// Name is interned; shared key ranges remain with their other holder.
		if tr.keys.slots > 0 && !tr.keys.shared {
			session_kf_release(tr.keys)
		}
		session_trk_erase(&cl.keyframe_tracks, ti)
	}

	// geom_key_unkeyed_fixture is geom_key_fixture with every keyframe track
	// stripped: the same clip, nothing keyed. This is the case where an edit is
	// non-lossy (nothing samples over the resting field) and therefore leaves a
	// lane PENDING — the only state in which the pending set is non-empty, so
	// every pending-related assertion starts here.
	geom_key_unkeyed_fixture :: proc() -> (cl: ^Clip) {
		cl = geom_key_fixture()
		for ti := cl.keyframe_tracks.n - 1; ti >= 0; ti -= 1 {
			name := kf_track_name(&session_trk_view(cl.keyframe_tracks, ti)^)
			if name == "" {
				continue
			}
			geom_key_drop_track(cl, name)
		}
		geom_key_check(cl.keyframe_tracks.n == 0, "fixture: the un-keyed case must start with no tracks")
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
		{Render_Geom_Prop.Opacity, 1.0},
		// Zoom's base must differ from the clip's DEFAULT (1 = no magnification) so a
		// probe reading a resting field by mistake is caught rather than agreeing by
		// luck. Pan's base is 0 — which IS its default, unavoidably, since 0 is
		// "centered" and there is no other neutral value.
		//
		// Pan at 0 is also what keeps the rest of this probe honest: a non-zero pan
		// OFFSETS THE BOX CENTER from the transform (that is what pan does), so a
		// fixture panned off-center would make every box-geometry assertion in the
		// file disagree for a reason that has nothing to do with what it is testing.
		// The pan tests below key their own values where they need a non-zero one.
		{Render_Geom_Prop.Zoom, 2.0},
		{Render_Geom_Prop.Pan_X, 0.0},
		{Render_Geom_Prop.Pan_Y, 0.0},
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
		case .Opacity:
			return cl.opacity
		case .Zoom:
			return cl.zoom
		case .Pan_X:
			return cl.pan_x
		case .Pan_Y:
			return cl.pan_y
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

		// --- Alt+wheel: zoom must move the ZOOM lane where it is sampled, and must
		// not touch crop, scale or the transform. The gesture used to write all three
		// to fake a content zoom; asserting they are UNTOUCHED is what stops that
		// coupling from creeping back.
		{
			cl := geom_key_fixture()
			kf_geom_set_lane_key(cl, render_geom_name(Render_Geom_Prop.Zoom), 0, 1.0)
			kf_geom_set_lane_key(cl, render_geom_name(Render_Geom_Prop.Zoom), 300, 1.0)
			before_z, _ := geom_key_sample(cl, .Zoom)
			before_l, _ := geom_key_sample(cl, .Crop_L)
			before_s, _ := geom_key_sample(cl, .Scale)
			before_x, _ := geom_key_sample(cl, .Trans_X)
			geom_key_check(
				kf_approx(before_z, 1.0),
				"fixture: zoom must sample active inside the keyed span, got %v",
				before_z,
			)
			geom_key_check(
				clip_zoom_by(cl, 2.0, true),
				"Alt+wheel: zoom-in must be accepted inside the keyed span",
			)
			after_z, _ := geom_key_sample(cl, .Zoom)
			geom_key_check(
				kf_approx(after_z, 2.0),
				"Alt+wheel: zoom must change WHERE IT IS SAMPLED (was %v, now %v) — an edit that only moves the resting field is invisible between keys",
				before_z,
				after_z,
			)
			// The decoupling, stated as an assertion. This is the point of the change:
			// the gesture writes ONE lane, so crop / scale / transform are not
			// collateral.
			after_l, _ := geom_key_sample(cl, .Crop_L)
			after_s, _ := geom_key_sample(cl, .Scale)
			after_x, _ := geom_key_sample(cl, .Trans_X)
			geom_key_check(
				kf_approx(after_l, before_l),
				"Alt+wheel must not write crop.l (was %v, now %v)",
				before_l, after_l,
			)
			geom_key_check(
				kf_approx(after_s, before_s),
				"Alt+wheel must not write scale (was %v, now %v)",
				before_s, after_s,
			)
			geom_key_check(
				kf_approx(after_x, before_x),
				"Alt+wheel must not write transform.x (was %v, now %v)",
				before_x, after_x,
			)
			// The playhead key carries the edit, so the curve must reach a DIFFERENT
			// value between keys. Frame 299, not 300: the end key sits at 300 and a
			// key applies ON its own frame.
			playhead.frame = 299
			off_span, _ := geom_key_sample(cl, .Zoom)
			geom_key_check(
				abs(off_span - 1.0) > 0.0001,
				"Alt+wheel: the neighbouring key must be reached by the curve (got %v) — the edit went to a key the timeline never interpolates to",
				off_span,
			)
			playhead.frame = 0
			at_start, _ := geom_key_sample(cl, .Zoom)
			geom_key_check(
				kf_approx(at_start, 1.0),
				"Alt+wheel: the clip's FIRST key must still hold its original value, got %v — a gesture rewrote keys the user never touched",
				at_start,
			)
			playhead.frame = 150
		}

		// --- Alt+middle drag: pan must move the PAN lanes where they are sampled,
		// on both axes, and must not write crop or the transform.
		{
			cl := geom_key_fixture()
			kf_geom_set_lane_key(cl, render_geom_name(Render_Geom_Prop.Pan_X), 0, 0.0)
			kf_geom_set_lane_key(cl, render_geom_name(Render_Geom_Prop.Pan_X), 300, 0.0)
			kf_geom_set_lane_key(cl, render_geom_name(Render_Geom_Prop.Pan_Y), 0, 0.0)
			kf_geom_set_lane_key(cl, render_geom_name(Render_Geom_Prop.Pan_Y), 300, 0.0)
			before_x, _ := geom_key_sample(cl, .Pan_X)
			before_l, _ := geom_key_sample(cl, .Crop_L)
			clip_pan_by(cl, 60, 40)
			after_x, _ := geom_key_sample(cl, .Pan_X)
			after_y, _ := geom_key_sample(cl, .Pan_Y)
			geom_key_check(
				abs(after_x - before_x) > 0.0001,
				"Alt+drag: pan.x must change where it is sampled (was %v, now %v) — the pan landed only in the resting field",
				before_x, after_x,
			)
			geom_key_check(
				abs(after_y) > 0.0001,
				"Alt+drag: a diagonal pan must move pan.y too (got %v)",
				after_y,
			)
			after_l, _ := geom_key_sample(cl, .Crop_L)
			geom_key_check(
				kf_approx(after_l, before_l),
				"Alt+drag must not write crop.l (was %v, now %v)",
				before_l, after_l,
			)
			after_tx, _ := geom_key_sample(cl, .Trans_X)
			geom_key_check(
				kf_approx(after_tx, 960),
				"Alt+drag must not write transform.x (got %v)",
				after_tx,
			)
			playhead.frame = 299
			off_span, _ := geom_key_sample(cl, .Pan_X)
			geom_key_check(
				abs(off_span) > 0.0001,
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
			for ti := cl.keyframe_tracks.n - 1; ti >= 0; ti -= 1 {
				tr := session_trk_view_mut(&cl.keyframe_tracks, ti)
				// name is a pool handle: nothing to free here.
				if tr.keys.slots > 0 && !tr.keys.shared {
					session_kf_release(tr.keys)
				}
				session_trk_erase(&cl.keyframe_tracks, ti)
			}
			geom_key_check(cl.keyframe_tracks.n == 0, "fixture: the un-keyed case must start with no tracks")
			before, _ := geom_key_sample(cl, .Pan_X)
			clip_pan_by(cl, 60, 0)
			after, _ := geom_key_sample(cl, .Pan_X)
			geom_key_check(
				abs(after - before) > 0.0001,
				"un-keyed clip: Alt+drag must still move the value the preview shows (was %v, now %v)",
				before,
				after,
			)
			geom_key_check(
				cl.keyframe_tracks.n == 0,
				"un-keyed clip: Alt+drag must NOT mint a track (auto-key never mints) — got %d tracks",
				cl.keyframe_tracks.n,
			)
			geom_key_check(
				abs(cl.pan_x) > 0.0001,
				"un-keyed clip: Alt+drag must write the resting pan_x, got %v",
				cl.pan_x,
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
			before, _ := geom_key_sample(cl, .Pan_X)
			clip_pan_by(cl, 60, 0)
			after, _ := geom_key_sample(cl, .Pan_X)
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
			keys_before := session_trk_view(cl.keyframe_tracks,ti).keys.n
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
				session_trk_view(cl.keyframe_tracks,ti).keys.n == keys_before,
				"committing the value already on screen must not add a key (%d -> %d)",
				keys_before,
				session_trk_view(cl.keyframe_tracks,ti).keys.n,
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
			for ti := cl.keyframe_tracks.n - 1; ti >= 0; ti -= 1 {
				tr := session_trk_view_mut(&cl.keyframe_tracks, ti)
				if kf_track_name(tr) == "crop" {
					if tr.keys.slots > 0 && !tr.keys.shared {
						session_kf_release(tr.keys)
					}
					session_trk_erase(&cl.keyframe_tracks, ti)
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
			// Keys span [100, 200] and the playhead sits at 50 — BEFORE the first
			// key, which is the only way a lane on a packed clip becomes pending at
			// all. Inside the span the packed section owns the value, so a resting
			// edit there is invisible by design and clip_geom_set would have written
			// a key instead of a pending resting value; past the last key the
			// section now HOLDS its final knot, so that region is likewise keyed.
			// Only ahead of the animation does the resting base rule, so the edit is
			// visible and pending there — and the A shortcut is what turns it into a
			// key.
			playhead.frame = 50
			for off in ([]i32{100, 200}) {
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
			// Ahead of the animation the lane is on its run-up: the resting base is
			// where the run-up STARTS (offset 0), so the playhead reads part of the way
			// to the first knot rather than the base outright.
			geom_key_check(
				clip_geom_get(cl, .Crop_L) > 0.05 && clip_geom_get(cl, .Crop_L) < 0.1,
				"ahead of the first knot the run-up interpolates from the base (got %v)",
				clip_geom_get(cl, .Crop_L),
			)
			// A pan ahead of the animation: visible resting edit, lane marked pending.
			pre_edit_l := clip_geom_get(cl, .Crop_L)
			clip_geom_set(cl, .Crop_L, 0.4)
			geom_key_check(
				clip_geom_key_modified(cl, .Crop_L),
				"a resting edit before the first key must leave the lane pending",
			)
			geom_key_check(
				!clip_geom_key_modified(cl, .Crop_R),
				"an untouched lane must not be pending",
			)
			before_r := clip_geom_get(cl, .Crop_R)
			n := clip_geom_key_all_modified(cl)
			geom_key_check(n == 1, "one pending lane must key exactly one lane, got %d", n)
			// The resting write moved the run-up, so the edit is visible -- but the
			// lane is mid-run-up, so what is on screen is the run-up from the NEW base,
			// not 0.4 outright. That is the cost of interpolating ahead of the first
			// key, and it is the number the knot must then carry.
			on_screen_l := clip_geom_get(cl, .Crop_L)
			geom_key_check(
				on_screen_l > 0.05 && on_screen_l < 0.4 && !kf_approx(on_screen_l, pre_edit_l),
				"a resting edit ahead of the first key must move the run-up (got %v, was %v)",
				on_screen_l,
				pre_edit_l,
			)
			geom_key_check(
				kf_approx(clip_geom_get(cl, .Crop_R), before_r),
				"an untouched lane must keep its value after the shortcut (got %v)",
				clip_geom_get(cl, .Crop_R),
			)
			// The point of the grouping: a pending SUBSET of a section becomes one
			// knot on the section itself, and the section STAYS packed. Writing the
			// lane as a track of its own would fan the user's whole-crop animation
			// out to four per-lane tracks, a storage they did not ask for, as a
			// side effect of asking to key one edge.
			geom_key_check(
				kf_track_index(cl^, "crop") >= 0,
				"keying one lane of a packed section must leave the section packed",
			)
			geom_key_check(
				kf_track_index(cl^, "crop.l") < 0,
				"the section must not have been unwrapped into a 'crop.l' track",
			)
			// The section and its lanes must never both exist: that coexistence is
			// what kf_geom_sample_lane asserts against, so a shortcut press that
			// left both would crash the next preview frame rather than this probe.
			geom_key_check(
				!(kf_track_index(cl^, "crop") >= 0 && kf_track_index(cl^, "crop.l") >= 0),
				"the packed section and its lane must not coexist after the shortcut",
			)
			// The new knot carries ONLY the lane that was pending. A full-mask knot
			// here would key breakpoints on three edges the user never panned, and
			// would pin them to whatever the sampler happened to read — the exact
			// "stamps keys nobody asked for" failure clip_geom_drag exists to avoid.
			crop_ti := kf_track_index(cl^, "crop")
			if crop_ti >= 0 {
				keys := session_trk_view(cl.keyframe_tracks,crop_ti).keys
				off_new := i32(playhead.frame - cl.timeline_start_frame)
				found := false
				kv := session_kf_view(keys)
				for i in 0 ..< keys.n {
					k := kv[i]
					if k.frame_off != off_new {
						continue
					}
					found = true
					if v, is_pack := k.value.([KF_PACK_MAX]f32); is_pack {
						geom_key_check(
							k.mask == 0b0001,
							"the new knot must key the pending lane alone (mask %d)",
							k.mask,
						)
						geom_key_check(
							kf_approx(v[0], on_screen_l),
							"the knot must carry the pending lane's on-screen value (got %v want %v)",
							v[0],
							on_screen_l,
						)
					}
				}
				geom_key_check(
					found,
					"the packed section must have gained a knot on the playhead (off %d)",
					off_new,
				)
			}
			// Every lane must still sample without tripping an assert: this is the
			// check the preview draw makes on the next frame.
			for i in 0 ..< int(Render_Geom_Prop._COUNT) {
				prop := Render_Geom_Prop(i)
				_ = clip_geom_get(cl, prop)
			}
			geom_key_check(true, "sampling every lane after the grouped key did not assert")
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
				keys := session_trk_view(cl.keyframe_tracks,ti).keys
				geom_key_check(
					keys.n == 2,
					"an off-clip edit must not mint a key (2 fixture keys expected, got %d)",
					keys.n,
				)
			}
			geom_key_check(
				kf_approx(cl.crop_l, 0.4),
				"an off-clip edit must still be VISIBLE, as the resting write (got %v)",
				cl.pan_x,
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

			clip_pan_by(cl, 60, 0)
			geom_key_check(
				clip_geom_key_modified(cl, .Pan_X),
				"an Alt+drag on an un-keyed clip must leave pan.x pending for the button",
			)
			geom_key_check(
				!clip_geom_key_modified(cl, .Pan_Y),
				"a purely horizontal pan must not leave pan.y pending",
			)
			geom_key_check(
				!clip_geom_key_modified(cl, .Trans_X),
				"a pan must not leave the transform pending -- it writes no transform",
			)
			geom_key_check(
				!clip_geom_key_modified(cl, .Crop_L),
				"a pan must not leave crop.l pending -- it writes no crop",
			)
			// The crop lanes are what the pan touched; the button must key those
			// and nothing else, so a later "keyframe all" cannot silently animate
			// a property the user never moved.
			n := clip_geom_key_all_modified(cl)
			geom_key_check(n > 0, "the shortcut must report how many lanes it keyed, got %d", n)
			geom_key_check(
				!clip_geom_any_modified(cl),
				"keying every pending lane must clear the pending set",
			)
			// The pan writes exactly ONE lane. It used to write six (four crop edges
			// plus both transforms) to fake the slide, and "key all modified" turned
			// that into six keys the user never asked for -- animating crop AND
			// transform because the gesture could not express itself in one
			// property. That coupling is gone, so the pending set is one lane.
			geom_key_check(
				n == 1,
				"a horizontal pan writes one lane, so one lane must be keyed (got %d)",
				n,
			)
			geom_key_check(
				kf_track_index(cl^, "pan.x") >= 0,
				"the panned lane must be keyed",
			)
			for name in ([]string{
				"crop.l", "crop.r", "crop.t", "crop.b", "transform.x", "transform.y", "pan.y",
			}) {
				geom_key_check(
					kf_track_index(cl^, name) < 0,
					"a pan must not mint a track for a lane it did not touch (%q exists)",
					name,
				)
			}
			// No section may exist for the groups the pan no longer touches. This is
			// the observable consequence of the decoupling: before, the pan wrote whole
			// crop and transform structs, so "key all modified" minted two PACKED
			// section knots the user never asked for. Pan writes one scalar lane, so
			// there is nothing to group.
			for name in ([]string{"crop", "transform"}) {
				geom_key_check(
					kf_track_index(cl^, name) < 0,
					"a pan must not create the %q section (it writes no crop or transform)",
					name,
				)
			}
			// Scale and opacity were never touched by a pan, so the shortcut must
			// not have keyed them — keying either would start animating a property
			// the user left alone.
			geom_key_check(
				kf_track_index(cl^, "scale") < 0,
				"the shortcut must key only the pending lanes — 'scale' was never panned",
			)
			geom_key_check(
				kf_track_index(cl^, "opacity") < 0,
				"the shortcut must key only the pending lanes — 'opacity' was never panned",
			)
			// Pressing it again with nothing pending must be a no-op, not a second
			// undo node full of redundant keys.
			geom_key_check(clip_geom_key_all_modified(cl) == 0, "a second press must key nothing")
		}

		// --- an ALREADY UNWRAPPED section stays unwrapped. Grouping is for a section
		// the user never split up. Once a lane carries its own track, that shape is
		// already on the clip — the user keyed or edited that lane individually, and
		// kf_geom_set_lane_key is what unwrapped it — so re-packing on the next
		// grouped press would delete a real track and rewrite an animation the user
		// built, as a side effect of asking to key a DIFFERENT edge.
		{
			cl := geom_key_unkeyed_fixture()
			playhead.frame = 150
			// Key one crop edge on its own. This is the unwrap.
			clip_geom_add_lane_key(cl, .Crop_L)
			geom_key_check(
				kf_track_index(cl^, "crop") < 0,
				"fixture: keying one crop lane on its own must not make a section track",
			)
			geom_key_check(
				kf_track_index(cl^, "crop.l") >= 0,
				"fixture: the individual lane key must own a 'crop.l' track",
			)
			// A different edge is panned, so it is pending.
			clip_geom_mark_modified(cl, .Crop_T)
			n := clip_geom_key_all_modified(cl)
			geom_key_check(n == 1, "one pending lane must key exactly one lane, got %d", n)
			geom_key_check(
				kf_track_index(cl^, "crop") < 0,
				"an already-unwrapped section must NOT be re-packed into a section track",
			)
			geom_key_check(
				kf_track_index(cl^, "crop.t") >= 0,
				"the pending lane of an unwrapped section must be keyed on its own track",
			)
			geom_key_check(
				kf_track_index(cl^, "crop.l") >= 0,
				"the per-lane key already on the clip must survive a write to a sibling lane",
			)
			for name in ([]string{"crop.r", "crop.b"}) {
				geom_key_check(
					kf_track_index(cl^, name) < 0,
					"keying one lane of an unwrapped section must not mint %q",
					name,
				)
			}
			geom_key_check(
				!clip_geom_any_modified(cl),
				"the shortcut must clear the pending set it consumed (mask %d)",
				cl.geom_modified,
			)
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
		// --- EVERY clip's box is CENTERED on its transform, whatever its kind.
		//
		// Text used to be the exception: clip_image_bounds returned its top-left
		// directly, so the selection border, the handles and the hit-test all measured
		// against a different anchor than every other source, and the export's
		// render_text_blit had to reproduce that same top-left or the preview and the
		// export disagreed about where one clip was. A keyframed text transform and a
		// keyframed video transform animated around different points while reading the
		// same two fields.
		//
		// Asserted on the box's OWN center against the transformed position, which is
		// the property rather than a baked rectangle: it holds for any transform, any
		// scale and any canvas, and it is exactly what was wrong.
		{
			canvas := probe_canvas()
			kinds := [?]Media_Kind{.Video, .Text}
			// Transform, position and scale chosen so the box is off-centre on the
			// canvas at more than one size -- a box that happened to be centred could
			// agree with a top-left implementation by coincidence.
			cases := [3][3]f32{
				{400, 300, 1.0},
				{1200, 700, 2.5},
				{960, 540, 0.4},
			}
			for &k in kinds {
				for &c in cases {
					cl := geom_key_fixture()
					cl.kind = k
					if k == .Text {
						cl.generator = .Text
					}
					clip_geom_set(cl, .Trans_X, c[0])
					clip_geom_set(cl, .Trans_Y, c[1])
					clip_geom_set(cl, .Scale, c[2])
					ib := clip_image_bounds(canvas, cl)
					cx, cy := project_to_pixel(canvas, c[0], c[1])
					label := fmt.tprintf("kind %d at (%.0f,%.0f) scale %.1f: box %vx%v", int(k), c[0], c[1], c[2], ib.width, ib.height)
					render_kf_probe_check_near(
						ib.x + ib.width / 2,
						cx,
						0.75,
						fmt.tprintf("%s -- box center x %.2f, transform maps to %.2f", label, ib.x + ib.width/2, cx),
					)
					render_kf_probe_check_near(
						ib.y + ib.height / 2,
						cy,
						0.75,
						fmt.tprintf("%s -- box center y %.2f, transform maps to %.2f", label, ib.y + ib.height/2, cy),
					)
				}
			}
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

		// --- THE INVARIANT: zoom and pan change what the clip SHOWS and never where
		// it is. This is what the old seven-write gestures had to fake, by computing a
		// new box center under a new crop asymmetry and re-anchoring the transform
		// against it. Asserted as a property over a sweep of values rather than one
		// baked rectangle, so it holds for any transform, scale and canvas.
		//
		// Before this change a zoom at 2x on a clip with a symmetric crop produced the
		// right pixels only because the arithmetic compensated; any drift in that
		// compensation moved the box. Now the box is derived from the window and
		// transform/scale are never written, so "the box does not move" is structural
		// and this check can only fail if someone reintroduces the coupling.
		{
			canvas := probe_canvas()
			box_stable := true
			for &z in ([]f32{1.0, 1.5, 2.0, 4.0}) {
				for &px in ([]f32{-0.3, 0.0, 0.25}) {
					for &py in ([]f32{-0.2, 0.0, 0.4}) {
						cl := geom_key_fixture()
						geom: Geom_Sample
						for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
							geom[pi] = clip_geom_get(cl, Render_Geom_Prop(pi))
						}
						geom[int(Render_Geom_Prop.Zoom)] = z
						geom[int(Render_Geom_Prop.Pan_X)] = px
						geom[int(Render_Geom_Prop.Pan_Y)] = py
						ref: clay.BoundingBox

						// The same clip with zoom and pan actually WRITTEN, which is
						// the path a gesture takes.
						cl2 := geom_key_fixture()
						for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
							clip_geom_set(cl2, Render_Geom_Prop(pi), geom[pi])
						}
						got := clip_image_bounds(canvas, cl2)

						// The REFERENCE is the SAME clip with zoom and pan neutralised --
						// not a second computation of the zoomed one. An earlier draft of
						// this case built the reference by calling clip_image_bounds_geom
						// with the zoomed sample, which is the same path under test, so it
						// agreed by construction and passed while the box was moving a
						// fifth of its width on a quarter pan. A reference that shares the
						// code under test cannot see that code's bug.
						base := geom
						base[int(Render_Geom_Prop.Zoom)] = 1.0
						base[int(Render_Geom_Prop.Pan_X)] = 0.0
						base[int(Render_Geom_Prop.Pan_Y)] = 0.0
						ref = clip_image_bounds_geom(canvas, .Video, base, cl2.source_w, cl2.source_h)

						if abs(got.x - ref.x) > 0.01 || abs(got.y - ref.y) > 0.01 {
							box_stable = false
							fmt.printf(
								"[geom-key-probe] FAIL zoom=%.2f pan=(%.2f,%.2f): box moved (%.2f,%.2f) vs (%.2f,%.2f)\n",
								z, px, py, got.x, got.y, ref.x, ref.y,
							)
						}
					}
				}
			}
			geom_key_check(box_stable, "zoom and pan must not move the clip's box")
		}

		// --- zoom must actually change the window, or the invariant above would pass
		// for a no-op. Asserted on the WINDOW, not the pixels: the box is unchanged by
		// design, so the only observable effect is a wider or narrower window.
		//
		// Source_Window carries INSETS (l is the trim off the left EDGE, not the left
		// edge's coordinate), so window width is 1 - l - r. Reading `r - l` as a width
		// is the mistake an earlier draft of this case made, and it fails for the
		// unzoomed case only because the two insets happen to be equal there.
		win_w :: proc(w: Source_Window) -> f32 { return 1 - w.l - w.r }

	// geom_key_pending_count is how many lanes are pending on a clip. The UI only
	// ever needs the list, so nothing in the app had a count — which is why the
	// eight-entry table survived an eleven-lane enum: no code path compared the two.
	geom_key_pending_count :: proc(cl: ^Clip) -> int {
		n := 0
		for i in 0 ..< int(Render_Geom_Prop._COUNT) {
			if clip_geom_key_modified(cl, Render_Geom_Prop(i)) {
				n += 1
			}
		}
		return n
	}
		win_h :: proc(w: Source_Window) -> f32 { return 1 - w.t - w.b }
		{
			geom: Geom_Sample
			geom[int(Render_Geom_Prop.Zoom)] = 1.0
			full := geom_source_window(geom)
			geom[int(Render_Geom_Prop.Zoom)] = 2.0
			half := geom_source_window(geom)
			geom_key_check(
				kf_approx(win_w(half), win_w(full) / 2),
				"zoom 2 must halve the window width (%v -> %v)",
				win_w(full), win_w(half),
			)
			// Uniform: both axes share the factor, or the box's aspect would change.
			geom_key_check(
				kf_approx(win_h(half), win_h(full) / 2),
				"zoom must be uniform across axes (%v -> %v)",
				win_h(full), win_h(half),
			)
			// Centered: a centered window stays centered under zoom.
			geom_key_check(
				kf_approx((1 + half.l - half.r) / 2, (1 + full.l - full.r) / 2),
				"zoom must not move the window's center",
			)
			// Pan slides the WINDOW by a fraction of its OWN width, toward the source's
			// left for a positive value — so the CONTENT travels the other way, which is
			// what makes a rightward drag move the image rightward.
			geom[int(Render_Geom_Prop.Zoom)] = 2.0
			geom[int(Render_Geom_Prop.Pan_X)] = 0.0
			before := geom_source_window(geom)
			geom[int(Render_Geom_Prop.Pan_X)] = 0.25
			after := geom_source_window(geom)
			geom_key_check(
				kf_approx(before.l - after.l, 0.25 * win_w(before)),
				"pan 0.25 must slide the window left by a quarter of its width (%v of %v)",
				before.l - after.l, win_w(before),
			)
			// Clamped: a pan far past the border pins at the edge instead of running
			// the window off the source, where crop_src_rect would ask for a rect it
			// cannot address.
			geom[int(Render_Geom_Prop.Pan_X)] = 50.0
			far := geom_source_window(geom)
			geom_key_check(
				far.l >= -0.0001 && far.r <= 1.0001,
				"a pan past the border must stay inside the source (l=%v r=%v)",
				far.l, far.r,
			)
			geom_key_check(
				kf_approx(win_w(far), win_w(before)),
				"a far pan pins to an edge rather than resizing the window (%v vs %v)",
				win_w(far), win_w(before),
			)
		}

		// --- the pan gesture's DIRECTION. It regressed once: the sign was read as
		// "the window goes the other way", which is true of the window and not of the
		// thing the user is dragging, so a rightward drag moved the CONTENT leftward.
		// Nothing above catches it — those cases test the resolver, not the gesture —
		// so the gesture is asserted end to end: drag right, and the window the clip
		// samples must move toward the source's LEFT.
		{
			cl := geom_key_fixture()
			// Zoom in first, or the window fills the source and any pan is clamped to
			// no-op — which would make this case pass for the wrong reason.
			geom_key_check(
				clip_zoom_by(cl, 2.0, true),
				"fixture: the pan-direction case needs room to pan",
			)
			geom: Geom_Sample
			for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
				geom[pi] = clip_geom_get(cl, Render_Geom_Prop(pi))
			}
			before := geom_source_window(geom)
			clip_pan_by(cl, 120, 0) // drag RIGHT
			for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
				geom[pi] = clip_geom_get(cl, Render_Geom_Prop(pi))
			}
			after := geom_source_window(geom)
			geom_key_check(
				after.l < before.l,
				"dragging right must move the sampled window toward the source's LEFT (l %v -> %v), so the content moves right with the cursor",
				before.l, after.l,
			)
			// The content must track the CURSOR one-for-one, not merely move the right
			// way. Measured as SCREEN motion of a fixed source point, because that is
			// the quantity the user sees and the only one that can catch a zoom-
			// dependent pan speed:
			//
			//	sx(u) = (u - nl)/nw * cw     [offset from the box's left edge]
			//
			// The previous version of this case asserted `(Δnl) * cw == 120`, which is
			// a source-fraction times a box width — algebraically 120 at EVERY zoom,
			// since Δnl = dx/nw and the nw cancels. It asserted a tautology and passed
			// against the real bug. Anything here must divide by nw to be screen space.
			cw, _ := clip_full_box_dims(cl, clip_geom_get(cl, .Scale))
			u: f32 = 0.5 // some source point that is inside the window
			sx0 := (u - before.l) / win_w(before) * cw
			sx1 := (u - after.l) / win_w(after) * cw
			geom_key_check(
				kf_approx_px(sx1 - sx0, 120),
				"a 120px drag at zoom %.2f must move the content 120px on screen (got %.2f)",
				clip_geom_get(cl, .Zoom), sx1 - sx0,
			)
			// And the y axis agrees rather than being wired backwards.
			clip_pan_by(cl, 0, 120) // drag DOWN
			for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
				geom[pi] = clip_geom_get(cl, Render_Geom_Prop(pi))
			}
			geom_key_check(
				geom_source_window(geom).t < after.t,
				"dragging down must move the sampled window toward the source's TOP (t %v -> %v)",
				after.t, geom_source_window(geom).t,
			)
		}

		// --- pan SPEED must not depend on zoom. Sibling case, never nested inside
		// another: geom_key_fixture frees the timeline, so a second call invalidates
		// the first case's `cl`. Nesting these made the y-axis check above read freed
		// memory — valgrind caught it as 76 contexts of invalid read in clip_pan_by.
		{
			cl := geom_key_fixture()
			geom_key_check(clip_zoom_by(cl, 4.0, true), "fixture: the zoom-invariance case needs a clip")
			clip_geom_set(cl, .Zoom, 4.0)
			clip_geom_set(cl, .Pan_X, 0.0)
			geom: Geom_Sample
			for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
				geom[pi] = clip_geom_get(cl, Render_Geom_Prop(pi))
			}
			before := geom_source_window(geom)
			clip_pan_by(cl, 120, 0)
			for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
				geom[pi] = clip_geom_get(cl, Render_Geom_Prop(pi))
			}
			after := geom_source_window(geom)
			cw, _ := clip_full_box_dims(cl, clip_geom_get(cl, .Scale))
			u: f32 = 0.5
			sx0 := (u - before.l) / win_w(before) * cw
			sx1 := (u - after.l) / win_w(after) * cw
			geom_key_check(
				kf_approx_px(sx1 - sx0, 120),
				"the SAME 120px drag at zoom 4 must move the content 120px (got %.2f) — pan speed must not scale with zoom",
				sx1 - sx0,
			)
		}

		// --- the pan VALUE must stay inside what the window can show. Dragging into
		// an edge used to pin the content while the lane kept climbing, so the
		// number ran away from the picture and a key taken from it recorded a pan the
		// clip was never showing. Asserted as: after a drag far past any border, the
		// stored lane is a value geom_source_window does not clamp, and re-panning
		// from there moves the content again.
		{
			cl := geom_key_fixture()
			geom_key_check(clip_zoom_by(cl, 2.0, true), "fixture: the pan-bound case needs room")
			geom: Geom_Sample
			for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
				geom[pi] = clip_geom_get(cl, Render_Geom_Prop(pi))
			}
			r := geom_pan_range(geom)
			geom_key_check(
				r.x_hi > 0 && r.x_lo < 0,
				"fixture: a zoomed clip must be able to pan both ways (%v..%v)",
				r.x_lo, r.x_hi,
			)
			// Drag far past the right-hand border, in several steps, as a real drag does.
			for _ in 0 ..< 12 {
				clip_pan_by(cl, 200, 0)
			}
			for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
				geom[pi] = clip_geom_get(cl, Render_Geom_Prop(pi))
			}
			stored := clip_geom_get(cl, .Pan_X)
			geom_key_check(
				kf_approx(stored, r.x_hi),
				"a drag into the border must stop the lane at the achievable limit (%v, limit %v)",
				stored, r.x_hi,
			)
			// And the stored value must be one the window does NOT clamp — a lane
			// parked on a clamped value is the original bug, not a fixed version of it.
			// At x_hi the window sits at 0 (the far-left of the source), which is the
			// bound the drag reached.
			p := source_window_parts(geom)
			unclamped := p.cx - p.nw * 0.5 - stored * p.nw
			geom_key_check(
				unclamped >= -0.0001 && unclamped <= 1 - p.nw + 0.0001,
				"the stored pan must land inside the window's clamp (%v of 0..%v)",
				unclamped, 1 - p.nw,
			)
			geom_key_check(
				kf_approx(unclamped, 0),
				"the x_hi bound must put the window at the source's left edge (got %v)",
				unclamped,
			)
			// Panning back must immediately move the content again — the signature of a
			// BOUND rather than a dead end. Dragging left moves the content left, so
			// the window's left edge moves RIGHT.
			w0 := geom_source_window(geom)
			clip_pan_by(cl, -200, 0)
			for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
				geom[pi] = clip_geom_get(cl, Render_Geom_Prop(pi))
			}
			w1 := geom_source_window(geom)
			geom_key_check(
				w1.l > w0.l,
				"panning back from the bound must move the content again (%v -> %v)",
				w0.l, w1.l,
			)
			// The y axis is bounded the same way.
			for _ in 0 ..< 12 {
				clip_pan_by(cl, 0, 200)
			}
			for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
				geom[pi] = clip_geom_get(cl, Render_Geom_Prop(pi))
			}
			geom_key_check(
				kf_approx(clip_geom_get(cl, .Pan_Y), geom_pan_range(geom).y_hi),
				"the y lane must stop at its own limit (got %v)",
				clip_geom_get(cl, .Pan_Y),
			)
		}

		// --- the inspector's pending-lane summary must render EVERY lane. It read
		// past the end of an eight-entry name table whenever nine or more lanes were
		// pending, formatting a garbage string pointer: a segfault reachable only
		// after enough geometry edits to light the high lanes, which is why it needed
		// a real project with a few crop and scale edits rather than any probe.
		// Marking all lanes pending is the only way in, and the count is asserted
		// rather than assumed.
		{
			cl := geom_key_fixture()
			for i in 0 ..< int(Render_Geom_Prop._COUNT) {
				cl.geom_modified |= 1 << uint(i)
			}
			geom_key_check(
				geom_key_pending_count(cl) == int(Render_Geom_Prop._COUNT),
				"fixture: all %v lanes must be pending, got %v",
				int(Render_Geom_Prop._COUNT),
				geom_key_pending_count(cl),
			)
			// Every lane's short name must exist and be non-empty, which is the
			// exhaustiveness the positional table lacked.
			for i in 0 ..< int(Render_Geom_Prop._COUNT) {
				sn := render_geom_short_name(Render_Geom_Prop(i))
				geom_key_check(len(sn) > 0, "lane %v has no short name", i)
			}
			labels := geom_key_pending_labels(cl, true)
			geom_key_check(
				labels == "X, Y, Scale, L, R, T, B, Opac, Zoom, PanX, PanY",
				"pending-lane summary must name all %v lanes, got %q",
				int(Render_Geom_Prop._COUNT),
				labels,
			)
			// And it must fit the fixed buffer with room to spare, since a silent
			// truncation here would look like a correct short list.
			geom_key_check(
				len(labels) < len(ui_text.kf_pending_list),
				"pending-lane summary (%d bytes) must fit kf_pending_list (%d)",
				len(labels),
				len(ui_text.kf_pending_list),
			)
		}

		// --- zoom of ZERO must mean "no magnification", not "infinitely magnified".
		// A bare Clip{} carries 0, and geom_key_fixture is built from Clip{}: if the
		// resolver divided by it the window would collapse to Zoom_Floor and every
		// un-keyed clip would open zoomed to its limit.
		{
			geom: Geom_Sample // all zero, i.e. Clip{}'s geometry
			geom[int(Render_Geom_Prop.Crop_L)] = 0.1
			geom[int(Render_Geom_Prop.Crop_R)] = 0.1
			w := geom_source_window(geom)
			geom_key_check(
				kf_approx(1 - w.l - w.r, 0.8),
				"a zero zoom must leave the crop window alone (width %v)",
				1 - w.l - w.r,
			)
		}

		if geom_key_fail {
			return 1
		}
		fmt.println(
			"[geom-key-probe] OK: geometry writes land where the clip reads — Alt+wheel/Alt-drag/typed edit/handle drag route to the playhead key, unkeyed edits stay visible and pending, the playhead guard mints no off-clip key, key-all-modified keys exactly the pending lanes as whole sections (packed when the section is not already unwrapped), and the clip bounds box is sampled at the playhead rather than read off the resting fields",
		)
		return 0
	}

}
