package main

import "core:strings"

// ---------------------------------------------------------------------------
// Undo history: an in-memory TREE of discrete edits (vim-undotree model). The
// cursor marks the action the live document matches; new edits push a child of
// the cursor and move it, and an edit made while the cursor is mid-tree FORKS a
// new branch instead of truncating, so work you stepped back from is never
// destroyed.
//
// Undo is a "stash" by design (per IDEAs.md): it lives only in RAM for the
// session and holds no persistent guarantees. Project snapshots (git-like,
// persistent, diffable) are a separate system, not this one.
//
// The tree is session-lifetime data (AGENTS §1 session heap): it grows only by
// user edits, never per frame, and is never freed mid-session. The slots array
// is appended in creation (= chronological) order, and children are a linked
// list (first_child -> next_sibling) so a node costs one slot and zero per-node
// allocations.
// ---------------------------------------------------------------------------

Undo_Kind :: enum {
	None,
	Move,       // clip(s) moved (drag or nudge)
	Split,      // split at playhead, single or linked group
	Resize,     // clip head/tail dragged
	Delete,     // ripple delete (region, group, or single raw clip)
	Duplicate,  // duplicate clip or track
	Rename,     // clip / track rename committed
	Media,      // media added to the timeline
	Text,       // text or subtitle clip added
	Transform,  // clip transform edited (scale / position / crop)
	Value,      // property / parameter edit
	Track,      // add / remove / reorder tracks
	Other,
}

Undo_Node :: struct {
	parent:       i32, // index of the parent action; the implicit root is 0
	first_child:  i32, // head of the child list, -1 = none
	last_child:   i32, // tail of the child list, -1 = none
	next_sibling: i32, // -1 = none
	seq:          u32, // 1-based creation sequence (chronological order)
	kind:         Undo_Kind,
	label:        string, // short human line, session-heap clone
}

Undo_History :: struct {
	slots:      [dynamic]Undo_Node, // index 0 = implicit root ("before anything")
	current:    i32,                // slot the live document matches; 0 = pristine
	seq:        u32,                // next sequence number
	view_scroll: f32,               // scroll offset of the tree in the media bin view
}

undo_hist: Undo_History

undo_init :: proc() {
	undo_hist = Undo_History{}
	append(
		&undo_hist.slots,
		Undo_Node {
			parent       = -1,
			first_child  = -1,
			last_child   = -1,
			next_sibling = -1,
			kind         = .None,
			label        = "start",
		},
	)
	undo_hist.current = 0
}

// undo_push records a committed edit as the next action and moves the cursor to
// it. When the cursor already has children this FORKS a new branch (the edit
// was made after an undo); when it is the newest tip it extends the line.
undo_push :: proc(kind: Undo_Kind, label: string) -> i32 {
	assert(undo_hist.slots != nil, "undo_push before undo_init")
	p := undo_hist.current
	assert(p >= 0 && p < i32(len(undo_hist.slots)), "undo cursor out of range")
	idx := i32(len(undo_hist.slots))
	undo_hist.seq += 1
	append(
		&undo_hist.slots,
		Undo_Node {
			parent       = p,
			first_child  = -1,
			last_child   = -1,
			next_sibling = -1,
			seq          = undo_hist.seq,
			kind         = kind,
			label        = strings.clone(label),
		},
	)
	parent := &undo_hist.slots[p]
	if parent.first_child < 0 {
		parent.first_child = idx
	} else {
		// Link onto the sibling chain so first_child -> next_sibling reaches
		// every child (the renderer walks this chain; last_child alone can't).
		undo_hist.slots[parent.last_child].next_sibling = idx
	}
	parent.last_child = idx
	undo_hist.current = idx
	return idx
}

// undo_undo moves the cursor to the current action's parent — the document
// "returns to" that step's state (payload application is the next milestone;
// today this is tree navigation only). No-op at the pristine root.
undo_undo :: proc() {
	if undo_hist.current <= 0 {
		return
	}
	undo_hist.current = undo_hist.slots[undo_hist.current].parent
}

// undo_redo moves the cursor to the current action's MOST RECENT child — the
// branch tip you undid — which is what vim undotree's redo does.
undo_redo :: proc() {
	c := undo_hist.current
	if c <= 0 || c >= i32(len(undo_hist.slots)) {
		return
	}
	if undo_hist.slots[c].last_child >= 0 {
		undo_hist.current = undo_hist.slots[c].last_child
	}
}

// undo_go_to sends the cursor to any node in the tree (the viewer's click).
undo_go_to :: proc(idx: int) {
	if idx < 0 || idx >= len(undo_hist.slots) {
		return
	}
	undo_hist.current = i32(idx)
}

undo_count :: proc() -> int { return max(len(undo_hist.slots) - 1, 0) }

// undo_depth returns the number of edges from the node to the root.
undo_depth :: proc(idx: int) -> int {
	if idx < 0 || idx >= len(undo_hist.slots) {
		return 0
	}
	d := 0
	for n := idx; undo_hist.slots[n].parent >= 0; n = int(undo_hist.slots[n].parent) {
		d += 1
	}
	return d
}

// undo_newest_descendant walks the last_child chain to the newest (topmost)
// descendant of `idx` — the row at which `idx`'s own trunk must end.
undo_newest_descendant :: proc(idx: int) -> int {
	if idx < 0 || idx >= len(undo_hist.slots) {
		return idx
	}
	n := idx
	for undo_hist.slots[n].last_child >= 0 {
		n = int(undo_hist.slots[n].last_child)
	}
	return n
}