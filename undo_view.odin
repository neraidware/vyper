package main

import clay "clay-odin"
import "core:c"
import "core:fmt"

// ---------------------------------------------------------------------------
// Undo-tree viewer: a toggled floating panel that renders the undo history as
// a tree, vim-undotree style. Rows run NEWEST at the top to OLDEST at the
// bottom ("bottom to top in sequence"); each row is indented to its parent's
// column and connected to it with box-drawing lines.
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
undo_row_text :: proc(idx: int, buf: []byte) {
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
}

// ---------------------------------------------------------------------------
// Viewer panel (floating overlay, z-order under the help overlay).
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
		clay.Text(
			string(undo_row_bufs[idx][:]),
			clay.TextElementConfig{textColor = cur ? BUTTON_BORDER_HOVER : TEXT, fontSize = FONT_SMALL, lineHeight = UNDO_ROW_TEXT},
		)
	}
}

// draw_undo_view renders the undo-tree panel as a floating overlay. Mirrors
// draw_help_overlay's placement, with its own scrollport (clip + childOffset)
// and a v_scrollbar when the tree outgrows the panel.
draw_undo_view :: proc(width, height: c.int) {
	if !undo_hist.view_open {
		return
	}
	undo_rows_ensure()

	pw := min(f32(640), f32(width) * 0.9)
	px := (f32(width) - pw) / 2
	ph := min(f32(height) * 0.6, 500)
	py := max(PANEL_PADDING, (f32(height) - ph) / 2)

	if clay.UI(clay.ID("UndoPanel"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(pw), height = clay.SizingFixed(ph)},
				layoutDirection = .TopToBottom,
				childGap = BUTTON_ROW_GAP,
				padding = clay.PaddingAll(PANEL_PADDING),
				childAlignment = {x = .Left, y = .Top},
			},
			backgroundColor = BUTTON,
			border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
			cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
			floating = {
				offset = {px, py},
				zIndex = 250,
				attachTo = .Root,
				pointerCaptureMode = .Capture,
			},
		},
	) {
		clay.Text(
			"Undo tree",
			clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_HEADING},
		)
		clay.Text(
			"In-memory edit history — F2 toggles · Ctrl+Z / Ctrl+Shift+Z walk the tree · state apply next",
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
		)
		stats := fmt.bprintf(
			undo_view_stats_buf[:],
			"%d action%s · cursor at act %d%s",
			undo_count(),
			undo_count() == 1 ? "" : "s",
			undo_hist.current,
			"",
		)
		clay.Text(
			stats,
			clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_SMALL},
		)

		if len(undo_hist.slots) <= 1 {
			clay.Text(
				"no actions yet — move, split, resize or delete a clip and it shows up here",
				clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
			)
		} else if clay.UI(clay.ID("UndoRowsArea"))(
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
					clip = {vertical = true, childOffset = {0, -undo_hist.view_scroll}},
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
}

undo_view_stats_buf: [128]u8

// undo_view_row_click wires row clicks: any click inside a tree row moves the
// cursor to that action. Added first in the click chain so an open viewer
// claims its own rows before anything underneath. Returns false when the
// viewer is closed (never intercepts anything).
undo_view_row_click :: proc(inp: Mouse_Input) -> bool {
	if !undo_hist.view_open || len(undo_hist.slots) <= 1 {
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