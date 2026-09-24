package main

import "core:fmt"
import "core:os"

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
	check(len(undo_view_lines) == len(expected), "line count", &fail)
	for i := 0; i < min(len(undo_view_lines), len(expected)); i += 1 {
		got := string(undo_view_line_bufs[i][:undo_view_lines[i].text_len])
		want := expected[i]
		check(got == want, fmt.tprintf("line %d text mismatch: got %q want %q", i, got, want), &fail)
		check(undo_view_lines[i].node == want_nodes[i], fmt.tprintf("line %d node mismatch", i), &fail)
	}

	// Rebuild is keyed on tree growth: a cursor move must NOT re-run it.
	undo_go_to(4)
	check(int(undo_hist.current) == 4, "go_to(4)", &fail)
	check(undo_view_built_count == len(undo_hist.slots), "rebuild key stays valid", &fail)
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
	selected_track = 0
	selected_index = 0
	before_x := timeline.tracks[0].clips[0].transform_x
	editing_field = .X
	edit_chars[0] = '2'
	edit_chars[1] = '5'
	edit_chars[2] = '0'
	edit_len = 3
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
		selected_track == 0 &&
			selected_index == 0 &&
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
	kf_set_key(clip0, "transform.x", 5, 100.0)
	kf_set_key(clip0, "transform.x", 20, 50.0)
	selected_track = 0
	selected_index = 0
	kf_select(0, 0, 0, 0)
	rcheck(
		selected_track == -1 && selected_index == -1 && len(selected_set) == 0,
		"keyframe selection clears the clip selection",
		fail,
	)
	rcheck(
		kf_sel.active && kf_sel.track_idx == 0 &&
			kf_sel.clip_index == 0 && kf_sel.lane == 0 && kf_sel.key == 0,
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
	rcheck(!kf_sel.active, "select_clip drops the keyframe selection", fail)

	// A keyframe value edit commits through undo like a numeric field.
	kf_select(0, 0, 0, 0)
	editing_field = .Kf_Value
	edit_chars[0] = '4'
	edit_chars[1] = '2'
	edit_len = 2
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
	rcheck(!kf_sel.active, "undo restore drops the keyframe selection (indices don't survive)", fail)
	undo_redo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(
		clip0.keyframe_tracks[0].keys[0].value == 42.0,
		"redo restores edited keyframe value",
		fail,
	)

	// A store edit that slides keys must invalidate the selection: inserting a
	// key before the picked one moves the picked key's slot, so resolving the
	// OLD indices would alias the newly inserted key.
	kf_select(0, 0, 0, 0)
	kf_set_key(clip0, "transform.x", 1, 60.0)
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
	clip0 = &timeline.tracks[0].clips[0]
	clip0.timeline_start_frame = 10
	playhead.frame = 15 // clip-relative 5
	kf_add_prop(clip0, "scale", 1.0)
	rcheck(undo_count() == 1, "add keyframe adds one node", fail)
	rcheck(
		selected_track == 0 && selected_index == 0,
		"add keyframe leaves the clip selection alone",
		fail,
	)
	rcheck(
		len(clip0.keyframe_tracks) == 2 &&
			clip0.keyframe_tracks[1].name == "scale" &&
			len(clip0.keyframe_tracks[1].keys) == 1 &&
			clip0.keyframe_tracks[1].keys[0].frame_off == 5 &&
			clip0.keyframe_tracks[1].keys[0].value == 1.0,
		"add keyframe lands at the playhead with the field value (row minted on first key)",
		fail,
	)
	undo_undo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(len(clip0.keyframe_tracks) == 1, "undo removes the added key's track", fail)
	undo_redo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(
		len(clip0.keyframe_tracks) == 2 && clip0.keyframe_tracks[1].keys[0].frame_off == 5,
		"redo restores the added key",
		fail,
	)

	// A diamond drag: the press captures the frame, the live update slides the
	// key, and the release commits one node only when the frame changed. The
	// frame math (pointer vs wrap-box) needs the layout, so the probe drives
	// the update's mutation directly and exercises the commit path.
	kf_select(0, 0, 1, 0)
	rcheck(kf_sel.active, "drag press selects the key", fail)
	undo_begin()
	if _, _, k, kok := kf_selected(); kok {
		kf_drag_start_frame = k.frame_off // press
		k.frame_off += 7                  // the per-frame update applied 7 frames
		commit_keyframe_drag()            // release
	}
	rcheck(undo_count() == 2, "move keyframe adds one node", fail)
	rcheck(
		kf_sel.active && kf_sel.gen == kf_structure_gen,
		"moved key re-selected under the fresh structure gen",
		fail,
	)
	if _, _, k, kok := kf_selected(); kok {
		rcheck(
			k.frame_off == 12 && k.value == 1.0,
			"move lands at the dragged frame with the value intact",
			fail,
		)
	}
	if _, lane, _, _ := kf_selected(); lane >= 0 {
		keys := &clip0.keyframe_tracks[lane].keys
		rcheck(
			len(keys^) == 1,
			"move is a move, not a copy (old frame is not left behind)",
			fail,
		)
		sorted := true
		for ki in 1 ..< len(keys^) {
			sorted &= keys^[ki-1].frame_off < keys^[ki].frame_off
		}
		rcheck(sorted, "move keeps the track sorted and frame-unique", fail)
	}
	undo_undo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(clip0.keyframe_tracks[1].keys[0].frame_off == 5, "undo restores the pre-move frame", fail)
	undo_redo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(clip0.keyframe_tracks[1].keys[0].frame_off == 12, "redo restores the dragged frame", fail)

	// A click that never slides must not reseek/reset anything: no undo node,
	// the selection kept. undo_restore dropped the gen when it rebuilt the tree,
	// so re-select the key first (a real release always has kf_selected live).
	kf_select(0, 0, 1, 0)
	undo_begin()
	if _, _, k, kok := kf_selected(); kok {
		kf_drag_start_frame = k.frame_off // the update ran at the same position
		commit_keyframe_drag()
	}
	rcheck(undo_count() == 2, "no-move click commits nothing", fail)
	rcheck(kf_sel.active, "no-move click keeps the selection", fail)

	// Delete: the selected key and its now-empty track drop as one node.
	kf_select(0, 0, 1, 0)
	del_ok := delete_selected_keyframe()
	rcheck(del_ok, "delete_selected_keyframe fires with a keyframe selected", fail)
	rcheck(undo_count() == 3, "delete adds one node", fail)
	rcheck(!kf_sel.active, "delete drops the keyframe selection", fail)
	rcheck(len(clip0.keyframe_tracks) == 1, "track drops with its last key (row goes away)", fail)
	undo_undo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(
		len(clip0.keyframe_tracks) == 2 && clip0.keyframe_tracks[1].keys[0].frame_off == 12,
		"undo restores the deleted key",
		fail,
	)
	undo_redo()
	clip0 = &timeline.tracks[0].clips[0]
	rcheck(len(clip0.keyframe_tracks) == 1, "redo removes it again", fail)
	// With no keyframe selected the same key must reach the clip path.
	rcheck(!delete_selected_keyframe(), "delete with no keyframe selected falls through to the clip path", fail)
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