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

	if fail > 0 {
		fmt.printf("[undo-probe] %d failure(s)\n", fail)
		os.exit(1)
	}
	fmt.printf("[undo-probe] ok: count=%d current=%d max_depth=%d\n", undo_count(), undo_hist.current, undo_depth(7))
	os.exit(0)
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