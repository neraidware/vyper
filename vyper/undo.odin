package vyper

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
	// snap is the editable timeline (tracks/clips/track_order) as it stood
	// immediately AFTER this action. Restoring a node clones snap back into the
	// live timeline, so a stored snapshot is never mutated by later edits. The
	// root's snap is the session baseline (the timeline at undo_init).
	snap:         Timeline,
}

Undo_History :: struct {
	slots:      [dynamic]Undo_Node, // index 0 = implicit root ("before anything")
	current:    i32,                // slot the live document matches; 0 = pristine
	seq:        u32,                // next sequence number
	view_scroll: f32,               // scroll offset of the tree in the media bin view
	// pending is the pre-edit capture taken by undo_begin; undo_push folds it into
	// the cursor node's snapshot so an edit with no node of its own (import,
	// transform, value) is not lost when the next recorded action is undone.
	pending:       Timeline,
	pending_valid: bool,
}

undo_hist: Undo_History

// ---------------------------------------------------------------------------
// Snapshot ownership. Outer track/clip arrays and track names are cloned;
// Clip POD records share session marker/key ranges through COW. clip.path
// (asset-owned) and interned strings remain shared and are never freed here.
// ---------------------------------------------------------------------------

clone_timeline :: proc(src: Timeline) -> Timeline {
	out := Timeline {
		track_order    = make([dynamic]int, len(src.track_order)),
		playhead_frame = src.playhead_frame,
		playback       = src.playback,
		frame_rate     = src.frame_rate,
	}
	if len(src.tracks) == 0 {
		return out
	}
	out.tracks = make([dynamic]Track, len(src.tracks))
	for i in 0 ..< len(src.tracks) {
		st := src.tracks[i]
		nt := Track {
			name  = strings.clone(st.name),
			clips = make([dynamic]Clip, len(st.clips)),
		}
		for j in 0 ..< len(st.clips) {
			nt.clips[j] = st.clips[j]
			nt.clips[j].markers = session_marker_share(&st.clips[j].markers)
			nt.clips[j].keyframe_tracks = session_trk_share(&st.clips[j].keyframe_tracks)
		}
		out.tracks[i] = nt
	}
	copy(out.track_order[:], src.track_order[:])
	return out
}

free_timeline :: proc(t: ^Timeline) {
	for &tr in t.tracks {
		for &c in tr.clips {
			clip_ranges_release(&c)
		}
		if tr.clips != nil {
			delete(tr.clips)
		}
		if tr.name != "" {
			delete(tr.name)
		}
	}
	if t.tracks != nil {
		delete(t.tracks)
	}
	if t.track_order != nil {
		delete(t.track_order)
	}
	t^ = {}
}

undo_free_all :: proc() {
	for &n in undo_hist.slots {
		free_timeline(&n.snap)
		// The label is a session-heap clone, owned exactly like the snapshot.
		// Leaving it behind leaked one string per undo_push for the life of the
		// process: the tree grows without bound, so an editing session
		// accumulated them indefinitely, and the memory gate saw one 17-41 byte
		// block per recorded edit. Nothing in the running app noticed, because
		// the process never exits and reclaims anyway.
		delete(n.label)
	}
	if undo_hist.pending_valid {
		free_timeline(&undo_hist.pending)
	}
	if undo_hist.slots != nil {
		delete(undo_hist.slots)
	}
	undo_hist = Undo_History{}
}

undo_init :: proc() {
	undo_free_all()
	append(
		&undo_hist.slots,
		Undo_Node {
			parent       = -1,
			first_child  = -1,
			last_child   = -1,
			next_sibling = -1,
			kind         = .None,
			// Cloned, not a literal: undo_free_all frees every label, so the
			// root node has to own its string too. A literal here would be a
			// free of non-heap memory on the next undo_init.
			label        = strings.clone("start"),
			snap         = clone_timeline(timeline),
		},
	)
	undo_hist.current = 0
}

// undo_begin captures the document BEFORE a recorded edit mutates it. undo_push
// folds this capture into the cursor node, so any change made since the cursor's
// action (an untracked import/transform/value) survives undoing the edit.
// Call it at the top of a discrete edit verb, or at the start of a drag gesture.
undo_begin :: proc() {
	if undo_hist.pending_valid {
		free_timeline(&undo_hist.pending)
	}
	undo_hist.pending = clone_timeline(timeline)
	undo_hist.pending_valid = true
}

// undo_cancel drops a pending capture started by undo_begin when the gesture or
// edit ended up making no change. A stale pending must never leak into a later
// undo_push: that fold treats it as an "untracked edit since the cursor's
// action", adopting a snapshot nothing actually produced.
undo_cancel :: proc() {
	if undo_hist.pending_valid {
		free_timeline(&undo_hist.pending)
		undo_hist.pending = {}
		undo_hist.pending_valid = false
	}
}

// undo_push records a committed edit as the next action and moves the cursor to
// it. When the cursor already has children this FORKS a new branch (the edit
// was made after an undo); when it is the newest tip it extends the line.
undo_push :: proc(kind: Undo_Kind, label: string) -> i32 {
	assert(undo_hist.slots != nil, "undo_push before undo_init")
	p := undo_hist.current
	assert(p >= 0 && p < i32(len(undo_hist.slots)), "undo cursor out of range")
	// Fold an untracked edit since the cursor's action into the cursor snapshot,
	// so undoing back to it keeps that edit. A drag sets pending at gesture
	// start; a discrete verb at its top.
	if undo_hist.pending_valid {
		free_timeline(&undo_hist.slots[p].snap)
		undo_hist.slots[p].snap = undo_hist.pending
		undo_hist.pending = {}
		undo_hist.pending_valid = false
	}
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
			snap         = clone_timeline(timeline),
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

// undo_sync_current folds any change made since the cursor's action into the
// cursor's snapshot before the cursor leaves it: the live document is the state
// after that action plus untracked edits, and those must survive undoing the
// action.
undo_sync_current :: proc() {
	free_timeline(&undo_hist.slots[undo_hist.current].snap)
	undo_hist.slots[undo_hist.current].snap = clone_timeline(timeline)
}

// undo_restore makes the live document match slot idx: a fresh clone of the
// snapshot is adopted (never aliased) and every piece of state keyed to the old
// clips — selection, in-flight drag, decoded previews — is dropped, the same
// rule any delete follows. Selection survives when the state allows it: the
// anchor and multi-select set are re-resolved by clip_id against the restored
// document (indices shift), and members the restored state no longer contains
// are dropped.
undo_restore :: proc(idx: i32) {
	assert(idx >= 0 && idx < i32(len(undo_hist.slots)), "undo_restore index out of range")
	sel_id: u64
	has_sel := false
	if _, c, ok := selected_clip(); ok {
		sel_id = c.clip_id
		has_sel = true
	}
	extra_ids := make([dynamic]u64, 0, len(selection.extra_set), context.temp_allocator)
	for id in selection.extra_set {
		append(&extra_ids, id)
	}

	new_timeline := clone_timeline(undo_hist.slots[idx].snap)
	free_timeline(&timeline)
	timeline = new_timeline
	undo_hist.current = idx
	undo_hist.pending = {}
	undo_hist.pending_valid = false
	clear(&selection.extra_set)
	selection.track = -1
	selection.index = -1
	// The keyframe selection is INDEX-keyed to whatever document was live; the
	// restore has replaced it wholesale, and a keyframe has no stable id to
	// re-resolve the way clips do — so drop it rather than alias whatever now
	// sits at the old indices (same rule any delete follows).
	kf_clear()
	if has_sel {
		if tr, c, ok := find_clip_by_id(sel_id); ok {
			selection.track = track_index_of(tr)
			selection.index = clip_index_on_track(tr, c)
		}
	}
	for id in extra_ids {
		if _, _, ok := find_clip_by_id(id); ok {
			selection.extra_set[id] = true
		}
	}
	handle_drag.handle = nil
	handle_drag.kind = .None
	active_interaction = .None
	clip_move.clip = nil
	clip_move.source_track = -1
	clip_move.source_index = -1
	clip_move.hover_track = -1
	clip_move.group_delta = 0
	clear(&clip_move.group_orig)
	clip_move.ripple = false
	clip_move.ripple_delta = 0
	clear(&clip_move.ripple_orig)
	clip_resize.edge = .None
	clip_resize.moved = false
	clip_resize.roll_track = -1
	clip_resize.roll_left_id = 0
	clip_resize.roll_right_id = 0
	invalidate_preview_slots()
	audio_note_edit()
}

// undo_undo returns the document to the state before the current action. No-op
// at the pristine root.
undo_undo :: proc() {
	if undo_hist.current <= 0 {
		return
	}
	undo_sync_current()
	undo_restore(undo_hist.slots[undo_hist.current].parent)
}

// undo_redo moves to the current action's MOST RECENT child — the branch tip you
// undid — which is what vim undotree's redo does.
undo_redo :: proc() {
	c := undo_hist.current
	if c < 0 || c >= i32(len(undo_hist.slots)) {
		return
	}
	if undo_hist.slots[c].last_child >= 0 {
		undo_sync_current()
		undo_restore(undo_hist.slots[c].last_child)
	}
}

// undo_go_to sends the document to any node in the tree (the viewer's click).
undo_go_to :: proc(idx: int) {
	if idx < 0 || idx >= len(undo_hist.slots) {
		return
	}
	if i32(idx) == undo_hist.current {
		undo_sync_current()
		return
	}
	undo_sync_current()
	undo_restore(i32(idx))
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
