package main

import clay "clay-odin"
import "core:fmt"

// ---------------------------------------------------------------------------
// Undo-tree viewer: fills the media bin's "Undo Tree" view (see state.odin).
// Renders the undo history as a tree, vim-undotree style. Rows run NEWEST at
// the top to OLDEST at the bottom ("bottom to top in sequence"); each row is
// indented to its parent's column and connected to it with box-drawing lines.
//
// Rows are ordered chronologically (append order = slot order, newest first).
// Parent rows always sit BELOW their children, so all connectors run upward.
// The cursor's row is highlighted; clicking a row sends the cursor there
// (state application is the next milestone — today this is tree navigation).
// ---------------------------------------------------------------------------

UNDO_ROW_H :: f32(24)     // one tree row
UNDO_ROW_TEXT :: u16(18)  // layout height of the row text

// Per-row text buffers. Clay does NOT copy text: it keeps the slice until
// draw later in the same frame, so each row needs a buffer that outlives
// build_page. The pool is session-owned and grows only when a new action is
// recorded (never per frame).
undo_row_bufs: [dynamic][256]u8

undo_rows_ensure :: proc() {
	for len(undo_row_bufs) < len(undo_hist.slots) {
		append(&undo_row_bufs, [256]u8{})
	}
}

// undo_row_text renders one row: cursor marker, sequence number, the tree
// prefix (indent columns + connector), then the action label. The columns are
// built with the classic tree rule mirrored for bottom-up rendering:
//   - a column for ancestor A shows a trunk ("│") while A's subtree still has
//     newer content above this row (undo_newest_descendant(A) > idx);
//   - the parent's column ends with "└──" when this node is its newest child,
//     else passes through with "├──".
// Returns the number of bytes written so the caller passes exactly that span
// to clay.Text (a fixed buffer passed whole would measure 256 wide and expand
// the layout).
undo_row_text :: proc(idx: int, buf: []byte) -> int {
	line: [256]u8
	w: int

	if idx == int(undo_hist.current) {
		w += copy(line[w:], "→ ")
	} else {
		w += copy(line[w:], "  ")
	}
	seq := fmt.bprintf(line[w:], "%d ", undo_hist.slots[idx].seq)
	w += len(seq)

	// Ancestor path along the parent chain, path[0] = idx, path[^1] = root.
	path: [96]i32
	depth := 0
	for n := i32(idx); n >= 0 && depth < len(path); n = undo_hist.slots[n].parent {
		path[depth] = n
		depth += 1
	}
	// depth = edges to root; path[k] = ancestor at tree-depth k (path[D]=root).

	// Columns for every ancestor strictly above the parent (edge-depth 0..D-2:
	// root, ..., grandparent). path[depth-1-k] is the ancestor at edge-depth k
	// (path[0] = this node at edge-depth D, path[depth-1] = root).
	for k := 0; k < depth - 2; k += 1 {
		a := path[depth - 1 - k]
		bar := undo_newest_descendant(int(a)) > idx
		chunk := bar ? "│  " : "   "
		assert(w + len(chunk) <= len(line))
		w += copy(line[w:], chunk)
	}
	last := depth > 1 && idx == int(undo_hist.slots[path[1]].last_child)
	conn := last ? "└── " : "├── "
	if depth == 0 {
		conn = "" // the root itself (not rendered, but safe)
	}
	assert(w + len(conn) <= len(line))
	w += copy(line[w:], conn)

	// label
	assert(w + len(undo_hist.slots[idx].label) <= len(line))
	w += copy(line[w:], undo_hist.slots[idx].label)

	copy(buf, line[:w])
	return w
}

// ---------------------------------------------------------------------------
// Embedded tree (the media bin panel's "Undo Tree" view).
// ---------------------------------------------------------------------------

undo_view_rows_height :: proc() -> f32 {
	return clay.GetElementData(clay.ID("UndoRows")).boundingBox.height
}

undo_view_clip_height :: proc() -> f32 {
	return clay.GetElementData(clay.ID("UndoRowsClip")).boundingBox.height
}

undo_view_max_scroll :: proc() -> f32 {
	return max(undo_view_rows_height() - undo_view_clip_height(), 0)
}

undo_row :: proc(idx: int) {
	cur := idx == int(undo_hist.current)
	id := clay.ID("UndoRow", u32(idx))
	hovered := clay.PointerOver(id)
	if clay.UI(id)(
		{
			layout = {
				sizing = {
					width  = clay.SizingGrow({}),
					height = clay.SizingFixed(UNDO_ROW_H),
				},
				padding = clay.Padding{left = 8, right = 8},
				childAlignment = {x = .Left, y = .Center},
			},
			backgroundColor = cur ? SWITCH_TRACK_ON : (hovered ? BUTTON_HOVER : clay.Color{0, 0, 0, 0}),
			border = {
				color = cur ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
				width = clay.BorderOutside(cur ? 1 : 0),
			},
		},
	) {
		n := undo_row_text(idx, undo_row_bufs[idx][:])
		clay.Text(
			string(undo_row_bufs[idx][:n]),
			clay.TextElementConfig{
				textColor = cur ? BUTTON_BORDER_HOVER : TEXT,
				fontSize = FONT_SMALL,
				lineHeight = UNDO_ROW_TEXT,
				// Rows must render on one line even when a deep chain scrolls
				// the text past the clip: wrapping a long row into several
				// lines overlaps the rows below it and reads as garbage.
				wrapMode = .None,
			},
		)
	}
}

// undo_view_header renders the one-line title plus live stats for the embedded
// tree.
undo_view_header :: proc() {
	stats := fmt.bprintf(
		undo_view_stats_buf[:],
		"Undo tree · %d action%s · cursor %d",
		undo_count(),
		undo_count() == 1 ? "" : "s",
		undo_hist.current,
	)
	clay.Text(
		stats,
		clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_SMALL},
	)
}

// undo_view_content fills its parent with the tree — the "no actions yet" hint
// until the first action exists, then the scrollable row clip plus a
// v_scrollbar when the tree outgrows the body.
undo_view_content :: proc() {
	undo_rows_ensure()
	if len(undo_hist.slots) <= 1 {
		clay.Text(
			"no actions yet",
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
		)
		clay.Text(
			"move, split, resize or delete a clip and it shows up here",
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
		)
		return
	}
	// Width is plain grow: the row text is sliced to its written length (see
	// undo_row_text) so the content measures real width — a fixed 256-byte
	// buffer passed whole once false-expanded this area past the panel.
	if clay.UI(clay.ID("UndoRowsArea"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				layoutDirection = .LeftToRight,
				childGap = 0,
			},
		},
	) {
		if clay.UI(clay.ID("UndoRowsClip"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
					layoutDirection = .TopToBottom,
					childAlignment = {x = .Left, y = .Top},
				},
				// horizontal clip: a deep ancestor chain's row text runs past
				// the clip; cut it at the clip edge instead of spilling into
				// the preview column.
				clip = {horizontal = true, vertical = true, childOffset = {0, -undo_hist.view_scroll}},
			},
		) {
			if clay.UI(clay.ID("UndoRows"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
						layoutDirection = .TopToBottom,
						childGap = 0,
					},
				},
			) {
				// Newest first: rows run top (newest) to bottom (oldest).
				for i := len(undo_hist.slots) - 1; i >= 1; i -= 1 {
					undo_row(i)
				}
			}
		}
		v_scrollbar(
			"UndoViewer",
			undo_hist.view_scroll,
			undo_view_rows_height(),
			undo_view_clip_height(),
		)
	}
}

undo_view_stats_buf: [128]u8

// undo_view_row_click wires row clicks: any click inside a tree row moves the
// cursor to that action. Added first in the click chain so the undo view
// claims its own rows before anything underneath. Returns false when the
// media bin isn't showing the tree (never intercepts anything).
undo_view_row_click :: proc(inp: Mouse_Input) -> bool {
	if media_bin_view != .Undo || len(undo_hist.slots) <= 1 {
		return false
	}
	for i := len(undo_hist.slots) - 1; i >= 1; i -= 1 {
		if clay.PointerOver(clay.ID("UndoRow", u32(i))) {
			undo_go_to(i)
			return true
		}
	}
	return false
}