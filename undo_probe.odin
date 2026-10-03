package main

import "core:fmt"
import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// VYPER_UNDO_PROBE: headless validation of the undo-tree data structure and the
// viewer's vim-undotree line renderer. Seeds a history with deliberate
// undo/redo FORKING, then asserts tree invariants and byte-for-byte gutter line
// text (the expected strings below were hand-derived from the undotree rule, not
// from the code under test, so a regression in either the tree or the renderer
// fails loudly).
//
// History under test (slot, label, parent):
//   1 Move clip         -> root
//   2 Split clip        -> 1 (Move)
//   3 Resize clip       -> 2 (Split)
//   4 Delete clip       -> 3 (Resize)
//   5 Rename clip       -> 2 (Split fork;      newest child of Split)
//   6 Duplicate clip    -> 5 (Rename;          newest child of Rename)
//   7 Add text clip     -> 6 (Duplicate;       newest child of Duplicate)
// Cursor ends on 7 after a script of undo/redo branches.
// ---------------------------------------------------------------------------

undo_probe_run :: proc() {
	undo_init()

	undo_push(.Move, "Move clip")
	undo_push(.Split, "Split clip")
	undo_push(.Resize, "Resize clip")
	undo_push(.Delete, "Delete clip") // child of Resize
	undo_undo()
	undo_undo()                         // back to Split (2)
	undo_push(.Rename, "Rename clip")   // fork: Split now has 3 children
	undo_undo()
	undo_redo()
	undo_push(.Duplicate, "Duplicate clip")
	undo_undo()
	undo_redo()
	undo_push(.Text, "Add text clip")

	fail := 0
	check :: proc(cond: bool, msg: string, fail: ^int) {
		if !cond {
			fmt.printf("[undo-probe] FAIL: %s\n", msg)
			fail^ += 1
		}
	}

	// Tree structure.
	check(undo_count() == 7, "expected 7 actions", &fail)
	check(int(undo_hist.current) == 7, "expected cursor on action 7", &fail)
	check(undo_depth(1) == 1 && undo_depth(3) == 3 && undo_depth(7) == 5, "depths", &fail)
	s := undo_hist.slots
	check(s[0].last_child == 1 && s[1].last_child == 2, "root/Move last_child", &fail)
	check(s[2].last_child == 5, "Split last_child is Rename (fork)", &fail)
	check(s[2].first_child == 3 && s[3].next_sibling == 5, "Split child sibling chain reaches both children", &fail)
	check(s[5].next_sibling == -1, "tail sibling terminates", &fail)
	check(s[3].last_child == 4, "Resize last_child is Delete", &fail)
	check(s[4].last_child == -1 && s[7].last_child == -1, "leaf last_child == -1", &fail)
	check(s[5].last_child == 6 && s[6].last_child == 7, "Rename/Duplicate last_child", &fail)
	check(undo_newest_descendant(0) == 7, "root trunk runs to 7", &fail)
	check(undo_newest_descendant(2) == 7 && undo_newest_descendant(5) == 7, "subtree trunks run to 7", &fail)
	check(undo_newest_descendant(3) == 4, "Resize trunk runs to Delete", &fail)
	check(int(undo_hist.slots[7].seq) == 7, "seq counter", &fail)

	// Line renderer, expected strings hand-derived from the undotree gutter
	// rule (newest-first; '|' vertical, '/' split, '\' return, '*' node marker;
	// connector-only lines carry no action). The branch (5->6->7) is the newer
	// child of Split, so it takes the left column and Resize->Delete indents.
	expected := []string{
		" *    7   Add text clip",
		" *    6   Duplicate clip",
		" *    5   Rename clip",
		" | *    4   Delete clip",
		" | *    3   Resize clip",
		" |/",
		" *    2   Split clip",
		" *    1   Move clip",
		" *    0   start",
	}
	want_nodes := []i32{7, 6, 5, 4, 3, -1, 2, 1, 0}
	undo_view_rebuild()
	check(len(undo_tree_view.lines) == len(expected), "line count", &fail)
	for i := 0; i < min(len(undo_tree_view.lines), len(expected)); i += 1 {
		got := string(undo_tree_view.line_bufs[i][:undo_tree_view.lines[i].text_len])
		want := expected[i]
		check(got == want, fmt.tprintf("line %d text mismatch: got %q want %q", i, got, want), &fail)
		check(undo_tree_view.lines[i].node == want_nodes[i], fmt.tprintf("line %d node mismatch", i), &fail)
	}

	// Rebuild is keyed on tree growth: a cursor move must NOT re-run it.
	undo_go_to(4)
	check(int(undo_hist.current) == 4, "go_to(4)", &fail)
	check(undo_tree_view.built_count == len(undo_hist.slots), "rebuild key stays valid", &fail)
	undo_go_to(7)

	// undo/redo cursor walking.
	undo_undo()
	check(int(undo_hist.current) == 6, "undo -> parent", &fail)
	undo_redo()
	check(int(undo_hist.current) == 7, "redo -> newest child", &fail)
	undo_go_to(6)
	undo_undo()
	check(int(undo_hist.current) == 5, "undo from Duplicate -> Rename", &fail)

	fmt.printf(
		"[undo-probe] ok: count=%d current=%d max_depth=%d\n",
		undo_count(),
		undo_hist.current,
		undo_depth(7),
	)

	// Snapshot restore runs last: it rebuilds the timeline and tree.
	undo_probe_restore_checks(&fail)

	// The probe owns its session and tears it down itself (AGENTS.md §9b's probe
	// rule). It seeds a timeline and pushes undo nodes, and both are app-lifetime
	// state that nothing else reclaims: the probe returns out of main rather than
	// os.exit, so the process teardown that reclaims runtime thread/TLS memory
	// never runs either. Without this the live timeline's clip keyframe tracks and
	// the whole undo tree — every snapshot, plus the label clones — are live at
	// exit, and the memory gate reports them as lost. The ui probe calls
	// session_teardown for exactly this reason; this probe seeded the same state
	// and did not.
	session_teardown()

	if fail > 0 {
		fmt.printf("[undo-probe] %d failure(s)\n", fail)
		os.exit(1)
	}
	os.exit(0)
}

// undo_probe_restore_checks proves undo/redo restore the DOCUMENT, not just the
// cursor: a recorded move plus a pre-edit capture (undo_begin) must come back
// exactly on undo and redo, including the clip that existed before the first
// recorded action.
undo_probe_restore_checks :: proc(fail: ^int) {
	rcheck :: proc(cond: bool, msg: string, fail: ^int) {
		if !cond {
			fmt.printf("[undo-probe] FAIL: %s\n", msg)
			fail^ += 1
		}
	}
	clip_start :: proc() -> i64 { return timeline.tracks[0].clips[0].timeline_start_frame }

	undo_init()
	timeline = Timeline {
		tracks = make([dynamic]Track, 0, 1),
	}
	append(&timeline.tracks, Track{clips = make([dynamic]Clip, 0, 1)})
	append(
		&timeline.tracks[0].clips,
		Clip {
			clip_id = 1,
			kind = .Video,
			source_length_frames = 50,
			timeline_start_frame = 10,
		},
	)

	// The clip was built with no node of its own; the pre-edit capture at m1
	// must fold it into the base so undoing m1 does not delete it.
	undo_begin()
	undo_push(.Move, "m1")
	timeline.tracks[0].clips[0].timeline_start_frame = 99
	undo_push(.Move, "m2")

	rcheck(int(undo_hist.current) == 2, "cursor on m2", fail)
	undo_undo()
	rcheck(clip_start() == 10, "undo restores m1 state (start 10)", fail)
	undo_undo()
	rcheck(len(timeline.tracks[0].clips) == 1, "undo to base keeps the pre-edit clip", fail)
	rcheck(clip_start() == 10, "base clip still at start 10", fail)
	undo_redo()
	rcheck(clip_start() == 10, "redo restores m1", fail)
	undo_redo()
	rcheck(clip_start() == 99, "redo restores m2", fail)

	// A numeric transform edit is a discrete node: committing a property field
	// records it and undo brings the old value back. Reset to a clean base first.
	undo_init()
	selection.track = 0
	selection.index = 0
	before_x := timeline.tracks[0].clips[0].transform_x
	edit_state.field = .X
	edit_state.chars[0] = '2'
	edit_state.chars[1] = '5'
	edit_state.chars[2] = '0'
	edit_state.len = 3
	edit_commit()
	rcheck(undo_count() == 1, "transform edit adds one node", fail)
	rcheck(timeline.tracks[0].clips[0].transform_x == 250, "transform field applied", fail)
	undo_undo()
	rcheck(
		timeline.tracks[0].clips[0].transform_x == before_x,
		"undo restores pre-edit transform",
		fail,
	)
	undo_redo()
	rcheck(timeline.tracks[0].clips[0].transform_x == 250, "redo restores transform", fail)

	// undo/redo both re-adopted the timeline above; selection must survive the
	// restore by clip_id (indices shift), not get wiped.
	rcheck(
		selection.track == 0 &&
			selection.index == 0 &&
			timeline.tracks[0].clips[0].clip_id == 1,
		"selection survives undo/redo",
		fail,
	)

	// --- S3: keyframe selection + value edit ---------------------------------
	// Exclusivity both ways, live-resolve, a value field committing through
	// undo, and the structure-gen guard against an index selection silently
	// aliasing a key that slid into its slot. Runs AFTER the selection check
	// above because it ends with the keyframe selected (the two never coexist).
	undo_init()
	clip0 := &timeline.tracks[0].clips[0]
	kf_geom_set_lane_key(clip0, "transform.x", 5, 100.0)
	kf_geom_set_lane_key(clip0, "transform.x", 20, 50.0)
	selection.track = 0
	selection.index = 0
	kf_select(0, 0, 0, 0)
	rcheck(
		selection.track == -1 && selection.index == -1 && len(selection.extra_set) == 0,
		"keyframe selection clears the clip selection",
		fail,
	)
	rcheck(
		kf_sel_count() == 1 && kf_sel_contains(Kf_Ref{0, 0, 0, 0}),
		"keyframe selection recorded",
		fail,
	)
	if kcl, klane, k, kok := kf_selected(); kok {
		rcheck(
			kcl == clip0 && klane == 0 && k.frame_off == 5 && k.value == 100.0,
			"kf_selected resolves the picked key",
			fail,
		)
	} else {
		rcheck(false, "kf_selected must resolve a live selection", fail)
	}
	// Back the other way: selecting a clip drops the keyframe.
	select_clip(0, 0)
	rcheck(!kf_sel_active(), "select_clip drops the keyframe selection", fail)

	// A keyframe value edit commits through undo like a numeric field.
	kf_select(0, 0, 0, 0)
	edit_state.field = .Kf_Value
	edit_state.chars[0] = '4'
	edit_state.chars[1] = '2'
	edit_state.len = 2
	edit_commit()
	rcheck(undo_count() == 1, "keyframe value edit adds one node", fail)
	rcheck(
		clip0.keyframe_tracks[0].keys[0].value == 42.0,
		"keyframe value edit applied",
		fail,
	)
	undo_undo()
	// undo_restore replaced the timeline wholesale; re-resolve the clip before
	// touching it (the captured pointer dangles into the freed tree).
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(
		clip0.keyframe_tracks[0].keys[0].value == 100.0,
		"undo restores pre-edit keyframe value",
		fail,
	)
	rcheck(!kf_sel_active(), "undo restore drops the keyframe selection (indices don't survive)", fail)
	undo_redo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(
		clip0.keyframe_tracks[0].keys[0].value == 42.0,
		"redo restores edited keyframe value",
		fail,
	)

	// The interpolation mode is per-key data like the value, so it must ride the
	// same snapshot round trip. A MID key (keys[1]) is used so the edited mode
	// also has a real arriving segment. New keys default to .Cubic (the enum's
	// zero value) — editing TO a non-default mode makes the round trip verify
	// a real transition in both directions.
	undo_begin()
	clip0.keyframe_tracks[0].keys[1].interp = .Ease_In_Out
	undo_push(.Value, "Set keyframe interpolation")
	rcheck(undo_count() == 2, "interpolation edit adds one undo node", fail)
	rcheck(
		clip0.keyframe_tracks[0].keys[1].interp == .Ease_In_Out,
		"interpolation edit applied",
		fail,
	)
	undo_undo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(
		clip0.keyframe_tracks[0].keys[1].interp == .Cubic,
		"undo restores the mode the key had before the edit (default .Cubic)",
		fail,
	)
	undo_redo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(
		clip0.keyframe_tracks[0].keys[1].interp == .Ease_In_Out,
		"redo restores edited interpolation mode",
		fail,
	)

	// A store edit that slides keys must invalidate the selection: inserting a
	// key before the picked one moves the picked key's slot, so resolving the
	// OLD indices would alias the newly inserted key.
	kf_select(0, 0, 0, 0)
	kf_geom_set_lane_key(clip0, "transform.x", 1, 60.0)
	_, _, _, stale_ok := kf_selected()
	rcheck(!stale_ok, "insert before the selected key kills the selection (structure gen)", fail)

	// --- S4: add / move / delete round-trips + the no-op click --------------
	// Shift+click (kf_add_prop) mints a row at the playhead with the field's
	// value; a diamond drag commits ONE move node only when the key actually
	// slid (the no-move click leaves state untouched — the clip-stutter rule);
	// Delete drops the key and, with it, the now-empty track's row. Fresh base
	// first; the timeline survives from the sections above (clip 0 at start
	// frame 10, length 50, one transform.x track from S3).
	undo_init()
	kf_clear()
	select_clip(0, 0)
	// The earlier m2 test left the clip parked at start 99; pin it back to the
	// canonical 10 for this section so the playhead math below is exact.
	// base_fixture re-derives the S7 base state from scratch:
	//   lane 0 "transform.x": 10 -> 1.0, 20 -> 2.0 (.Elastic), 50 -> 3.0
	//   lane 1 "scale":        5 -> 1.0
	// The last lane-0 key sits exactly on the clip's extent (length 50), which is
	// what makes the clamped-drag case below expressible.
	//
	// It is a PROC, not a one-time setup, and every block calls it. Each block
	// MUTATES the store, and undo_init only re-baselines the history — it does
	// not roll the tree back — so a block that is not itself undone would
	// otherwise run against the previous block's leftovers, and the failure reads
	// as a bug in the block under test rather than as a dirty fixture. The one
	// exception is the interp block, which round-trips through undo_undo on
	// purpose: that IS what it is testing.
	base_fixture :: proc() {
		cl := &timeline.tracks[0].clips[0]
		cl.timeline_start_frame = 10
		// A track owns its cloned name AND its key array, so both go before the
		// row is dropped. `clear` and not `delete` on the list itself: clear
		// keeps the outer capacity so the two fixed tracks re-mint into the same
		// buffer, while delete frees the rows and leaves a header that append
		// then re-reserves from (segfaulting on the second base_fixture call).
		for tr in &cl.keyframe_tracks {
			// Lane names are pool handles (TODO.md Active 19); only keys are owned.
			delete(tr.keys)
		}
		clear(&cl.keyframe_tracks)
		append(&cl.keyframe_tracks, Kf_Track{name = session_str_intern("transform.x")})
		append(&cl.keyframe_tracks, Kf_Track{name = session_str_intern("scale")})
		kf_geom_set_lane_key(cl, "transform.x", 10, 1.0)
		kf_geom_set_lane_key(cl, "transform.x", 20, 2.0)
		kf_geom_set_lane_key(cl, "scale", 5, 1.0)
		cl.keyframe_tracks[0].keys[1].interp = .Elastic
		kf_geom_set_lane_key(cl, "transform.x", 50, 3.0)
		undo_init()
	}
	base_fixture()
	clip0 = &timeline.tracks[0].clips[0]

	// The four refs of the widest selection used below, named so the blocks read
	// as the user's action rather than as index arithmetic. kf_select_add is the
	// Shift+click path's body; the HOVERED SET comes from kf_keys_at, which
	// needs a laid-out frame the probe has no run of.
	all4 := [4]Kf_Ref{{0, 0, 0, 0}, {0, 0, 0, 1}, {0, 0, 0, 2}, {0, 0, 1, 0}}
	pair := [2]Kf_Ref{{0, 0, 0, 0}, {0, 0, 0, 1}}
	kf_select_all :: proc(refs: []Kf_Ref) {
		// A press: sole selection on the first, union for the rest, then arm the
		// move exactly as the press handler does.
		kf_select(refs[0].track_idx, refs[0].clip_index, refs[0].lane, refs[0].key)
		if len(refs) > 1 {
			kf_select_add(refs[1:])
		}
		undo_begin()
		kf_capture_sel(&kf_move.snaps)
		kf_move.delta = 0
	}

	// --- union / replace / the no-half-resolve contract ----------------------
	kf_select_all(all4[:])
	rcheck(kf_sel_count() == 4, "shift+click builds a four-key set", fail)
	rcheck(
		kf_sel_contains(Kf_Ref{0, 0, 0, 2}) && kf_sel_contains(Kf_Ref{0, 0, 1, 0}),
		"every added key is in the set, across both lanes",
		fail,
	)
	kf_select_add(all4[1:2])
	rcheck(kf_sel_count() == 4, "adding an already-selected key is a no-op (no duplicate)", fail)
	_, _, _, multi_one := kf_selected()
	rcheck(!multi_one, "kf_selected refuses a multi-selection (no half-resolve to key[0])", fail)
	rcheck(
		selection.track == -1 && selection.index == -1,
		"the keyframe set still owns S3 exclusivity from the clip selection",
		fail,
	)
	kf_select(0, 0, 0, 1)
	rcheck(kf_sel_count() == 1, "a plain press replaces the whole set", fail)
	rcheck(kf_sel_contains(Kf_Ref{0, 0, 0, 1}), "and the pressed key is the one it left selected", fail)
	kf_snaps_drop(&kf_move.snaps)

	// --- the shared-property editor ------------------------------------------
	base_fixture()
	clip0 = &timeline.tracks[0].clips[0]
	kf_select_all(all4[:])
	interp, mixed, seen := kf_sel_interp()
	rcheck(seen, "the aggregate saw the selection", fail)
	rcheck(mixed, "keys that disagree aggregate as mixed", fail)
	rcheck(interp == .Cubic, "the mixed aggregate reports the first key's mode (meaningless)", fail)
	// One lane -> the name is a shared header. Two lanes -> it is not, because a
	// track name is a var identity and not a property.
	_, same := kf_sel_same_lane()
	rcheck(!same, "a set spanning two lanes has no shared name", fail)
	lo, hi := kf_sel_frame_span()
	rcheck(lo == 15 && hi == 60, "the absolute frame span covers the whole set", fail)

	changed := kf_set_interp_all(.Ease_Out)
	rcheck(changed, "the pick reported a change", fail)
	rcheck(undo_count() == 1, "one interp pick on four keys is ONE undo node", fail)
	all_ease := true
	for item in kf_sel.items {
		_, _, k, kok := kf_resolve(item)
		all_ease = all_ease && kok && k.interp == .Ease_Out
	}
	rcheck(all_ease, "the pick wrote every selected key", fail)
	interp2, mixed2, _ := kf_sel_interp()
	rcheck(!mixed2 && interp2 == .Ease_Out, "a set that now agrees aggregates as shared", fail)
	// Re-picking the mode already in use changes nothing and adds no node.
	undo_count_before := undo_count()
	rcheck(
		!kf_set_interp_all(.Ease_Out),
		"re-picking the current mode reports no change",
		fail,
	)
	rcheck(undo_count() == undo_count_before, "and adds no undo node", fail)

	undo_undo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(
		clip0.keyframe_tracks[0].keys[1].interp == .Elastic &&
			clip0.keyframe_tracks[0].keys[0].interp == .Cubic,
		"undo restores the per-key modes the set had before the pick",
		fail,
	)
	undo_redo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(
		clip0.keyframe_tracks[0].keys[0].interp == .Ease_Out,
		"redo re-applies the mode to the whole set",
		fail,
	)
	// Back to the base fixture for the move blocks (and note the selection is
	// gone: undo_restore replaced the tree).
	undo_undo()
	clip0 = &timeline.tracks[0].clips[0]

	// --- a multi-key move ----------------------------------------------------
	// +3 slides the two inner keys and the lane-1 key, while the key already on
	// the clip's extent (50) clamps back onto itself — one gesture, and the clamp
	// is per key.
	base_fixture()
	clip0 = &timeline.tracks[0].clips[0]
	kf_select_all(all4[:])
	kf_move.delta = 3
	commit_keyframe_drag()
	rcheck(undo_count() == 1, "moving four keys is ONE undo node", fail)
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(
		clip0.keyframe_tracks[0].keys[0].frame_off == 13 &&
			clip0.keyframe_tracks[0].keys[1].frame_off == 23 &&
			clip0.keyframe_tracks[0].keys[2].frame_off == 50 &&
			clip0.keyframe_tracks[1].keys[0].frame_off == 8,
		"every key slid by the same delta, each clamped into its own clip",
		fail,
	)
	rcheck(
		clip0.keyframe_tracks[0].keys[1].interp == .Elastic,
		"a move preserves the key's interpolation (the insert path would zero it)",
		fail,
	)
	rcheck(kf_sel_count() == 4, "the whole set is re-selected after the move", fail)
	sorted_ok := true
	for lane in 0 ..< len(clip0.keyframe_tracks) {
		keys := &clip0.keyframe_tracks[lane].keys
		for ki in 1 ..< len(keys) {
			sorted_ok &= keys[ki - 1].frame_off < keys[ki].frame_off
		}
	}
	rcheck(sorted_ok, "every lane comes back sorted and frame-unique", fail)
	kf_snaps_drop(&kf_move.snaps)
	undo_undo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(
		clip0.keyframe_tracks[0].keys[0].frame_off == 10 &&
			clip0.keyframe_tracks[0].keys[1].frame_off == 20 &&
			clip0.keyframe_tracks[1].keys[0].frame_off == 5,
		"undo restores all four frames",
		fail,
	)
	undo_init()
	clip0 = &timeline.tracks[0].clips[0]

	// --- the ordering case: a key sliding onto a frame being vacated --------
	// Keys at 10 and 20, delta +10: the key at 10 must land on 20, which the key
	// at 20 vacates. Interleaving the pair as del-then-set per key would let the
	// first set replace the second key's value in place, and the second delete
	// would then remove it — the key at 10 would vanish, value and all.
	base_fixture()
	clip0 = &timeline.tracks[0].clips[0]
	kf_select_all(pair[:])
	kf_move.delta = 10
	commit_keyframe_drag()
	clip0 = &timeline.tracks[0].clips[0]
	// The unselected key at 50 is untouched, so the lane is [20, 30, 50].
	rcheck(
		len(clip0.keyframe_tracks[0].keys) == 3,
		"a key sliding onto a vacated frame moves both keys, not one",
		fail,
	)
	rcheck(
		clip0.keyframe_tracks[0].keys[0].frame_off == 20 &&
			clip0.keyframe_tracks[0].keys[0].value == 1.0,
		"the slid key re-landed on the vacated frame WITH ITS OWN VALUE",
		fail,
	)
	rcheck(
		clip0.keyframe_tracks[0].keys[1].frame_off == 30 &&
			clip0.keyframe_tracks[1 - 1].keys[1].value == 2.0,
		"and the key it displaced moved on carrying its own value",
		fail,
	)
	kf_snaps_drop(&kf_move.snaps)
	undo_init()
	clip0 = &timeline.tracks[0].clips[0]

	// --- a drag that clamps away entirely is not a move ---------------------
	// The key at 50 is already on the clip's extent, so +10 clamps it straight
	// back onto itself. That is decided per KEY, not from the delta: a selection
	// of just that key commits nothing, while the same delta over a wider
	// selection moves the others and does commit.
	base_fixture()
	clip0 = &timeline.tracks[0].clips[0]
	kf_select(0, 0, 0, 2)
	undo_begin()
	kf_capture_sel(&kf_move.snaps)
	kf_move.delta = 10
	commit_keyframe_drag()
	rcheck(undo_count() == 0, "a drag whose every key clamps back commits no undo node", fail)
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(
		clip0.keyframe_tracks[0].keys[2].frame_off == 50,
		"the clamped key stayed where it was",
		fail,
	)
	kf_snaps_drop(&kf_move.snaps)
	wide_clamp := [2]Kf_Ref{{0, 0, 0, 0}, {0, 0, 0, 2}}
	kf_select_all(wide_clamp[:])
	kf_move.delta = 10
	commit_keyframe_drag()
	rcheck(undo_count() == 1, "the same delta over a wider selection DOES commit", fail)
	clip0 = &timeline.tracks[0].clips[0]
	// The clamped key held 50; the sliding key went 10 -> 20, where an UNSELECTED
	// key already sat. That one is absorbed: kf_set_key replaces a key already on
	// the frame, so the mover's value wins. This is the mirror of the trade case
	// above (landing on a VACATED frame is a clean move, landing on an OCCUPIED
	// one is a replace) and it is pre-existing store semantics, but a multi-move
	// makes it reachable by dragging over keys the user did not pick, so it is
	// pinned here rather than left to be discovered as silent key loss.
	rcheck(
		len(clip0.keyframe_tracks[0].keys) == 2 &&
			clip0.keyframe_tracks[0].keys[0].frame_off == 20 &&
			clip0.keyframe_tracks[0].keys[0].value == 1.0 &&
			clip0.keyframe_tracks[0].keys[1].frame_off == 50 &&
			clip0.keyframe_tracks[0].keys[1].value == 3.0,
		"the clamped key held its frame, the other slid, and the unselected key it landed on was absorbed",
		fail,
	)
	kf_snaps_drop(&kf_move.snaps)

	// --- one store op invalidates the WHOLE set -----------------------------
	base_fixture()
	clip0 = &timeline.tracks[0].clips[0]
	kf_select_all(all4[:])
	rcheck(kf_sel_count() == 4, "four keys selected before the sliding insert", fail)
	kf_geom_set_lane_key(clip0, "transform.x", 1, 60.0)
	rcheck(
		kf_sel_count() == 0,
		"an insert invalidates every selected key, not just the slid one",
		fail,
	)
	rcheck(
		!kf_sel_contains(Kf_Ref{0, 0, 0, 0}),
		"a stale ref is not 'contained', so the paint cannot light it",
		fail,
	)

	// --- delete the whole set ------------------------------------------------
	base_fixture()
	clip0 = &timeline.tracks[0].clips[0]
	kf_select_all(all4[:])
	rcheck(kf_sel_count() == 4, "four keys selected for the delete", fail)
	undo_init()
	del_multi := delete_selected_keyframe()
	rcheck(del_multi, "delete_selected_keyframe fires on a multi-selection", fail)
	rcheck(undo_count() == 1, "deleting four keys is ONE undo node", fail)
	rcheck(!kf_sel_active(), "delete drops the whole selection", fail)
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(
		len(clip0.keyframe_tracks) == 0,
		"every key is gone, and each track dropped with its last one",
		fail,
	)
	undo_undo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(
		len(clip0.keyframe_tracks) == 2 &&
			len(clip0.keyframe_tracks[0].keys) == 3 &&
			len(clip0.keyframe_tracks[1].keys) == 1,
		"undo restores every deleted key and both dropped tracks",
		fail,
	)
	undo_redo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(len(clip0.keyframe_tracks) == 0, "redo deletes the whole set again", fail)
	// A stale set must never come back as live: kf_clear keeps the buffer, so the
	// next selection re-stamps the gen rather than inheriting the old one.
	rcheck(!kf_sel_active(), "the selection is still clear after the redo's tree swap", fail)
}

// handle_undo_probe runs the probe when VYPER_UNDO_PROBE is set (headless; runs
// before any window/GPU is needed, like the UI draw-call probe).
handle_undo_probe :: proc() -> bool {
	if v, _ := os.lookup_env_alloc("VYPER_UNDO_PROBE", context.temp_allocator); v != "" {
		undo_probe_run()
		return true
	}
	return false
}