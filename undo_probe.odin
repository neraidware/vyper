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