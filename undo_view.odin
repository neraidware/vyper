package main

import clay "clay-odin"
import "core:fmt"

// ---------------------------------------------------------------------------
// Undo-tree viewer: fills the media bin's "Undo Tree" view (see state.odin).
// Renders the history with vim-undotree's ASCII gutter: fixed columns drawn with
// '|' (vertical), '/' (fork split) and '\' (branch return), a '*' node marker at
// each action's column, and the sequence + label text to the right. Rows run
// NEWEST at the top to the root at the bottom.
//
// The gutter is a faithful port of undotree's Render() slot machine, so a linear
// history is a single flat column and the line only indents where an edit
// actually forked a new branch (an edit made after undoing to a previous state).
// Connector-only rows ('|/', '\') are emitted between action rows, exactly as
// undotree does, so the display is a list of LINES: action lines carry a slot
// index, connector lines do not.
//
// The whole line list is rebuilt only when the tree GROWS (a push), never per
// frame; the cursor only changes which row is highlighted.
// ---------------------------------------------------------------------------

UNDO_ROW_H :: f32(24)     // one tree row
UNDO_ROW_TEXT :: u16(18)  // layout height of the row text

// One emitted display line. `node` is the undo slot for an action line and -1
// for a connector-only line (never clickable, never highlighted). `text_len` is
// the bytes actually written into undo_tree_view.line_bufs for this line — clay does
// not copy text and a whole fixed buffer would measure 256 columns wide.
Undo_View_Line :: struct {
	node:     i32,
	text_len: int,
}

// Undo_View is the undo-tree viewer's display state: the rebuilt line list
// (slots + text buffers — clay does not copy text and a whole fixed buffer
// would measure 256 columns wide, so each line records its byte count), the
// slot count the lines were built from (len(slots)), the rebuild scratch (one
// slot per display column of the port of mbbill/undotree), and the stats line
// buffer.
Undo_View :: struct {
	lines:      [dynamic]Undo_View_Line,
	line_bufs:  [dynamic][256]u8,
	built_count: int, // len(slots) the lines were built from
	scratch:    [dynamic]Undo_View_Slot,
	stats_buf:  [128]u8,
}
undo_tree_view: Undo_View = {built_count = -1}

// ---------------------------------------------------------------------------
// undotree slot machine (port of mbbill/undotree Render()).
//
// Each slot is one display column: E = the next action to print, P = a fork (a
// run of not-yet-printed siblings sharing a column), X = a dead column. Every
// pass prints the oldest remaining action, prepends its line, then advances that
// column to its child or collapses it.
// ---------------------------------------------------------------------------
Undo_View_Slot_Kind :: enum {
	E,
	P,
	X,
}

Undo_View_Slot :: struct {
	kind:  Undo_View_Slot_Kind,
	node:  i32, // E: action slot; P: first sibling in the chain
	count: int, // P: number of siblings
}

undo_view_rebuild :: proc() {
	n := len(undo_hist.slots)
	clear(&undo_tree_view.lines)
	clear(&undo_tree_view.line_bufs)
	// Scratch holds one slot per display column; a fork P expansion inserts two
	// slots where one was, so give it two slots of headroom.
	if len(undo_tree_view.scratch) < n + 2 {
		resize(&undo_tree_view.scratch, n + 2)
	}

	scratch := undo_tree_view.scratch[:]
	scratch[0] = Undo_View_Slot{kind = .E, node = 0}
	nslots := 1

	for nslots > 0 {
		// Prefer collapsing a dead column; otherwise print the oldest action.
		foundx := false
		index := 0
		for i in 0 ..< nslots {
			if scratch[i].kind == .X {
				foundx = true
				index = i
				break
			}
		}
		minseq := i32(0x7fffffff)
		minnode := i32(-1)
		if !foundx {
			for i in 0 ..< nslots {
				s := scratch[i]
				if s.kind == .E {
					if undo_hist.slots[s.node].seq < u32(minseq) {
						minseq = i32(undo_hist.slots[s.node].seq)
						index = i
						minnode = s.node
					}
				} else if s.kind == .P {
					for c := s.node; c >= 0; c = undo_hist.slots[c].next_sibling {
						if undo_hist.slots[c].seq < u32(minseq) {
							minseq = i32(undo_hist.slots[c].seq)
							index = i
							minnode = c
						}
					}
				}
			}
		}

		line: [256]u8
		w := 0
		w += copy(line[w:], " ")
		slot := scratch[index]
		kind := slot.kind
		line_node := i32(-1)

		// Gutter is 2 bytes per column; the E line also carries the seq and
		// label. Fail loudly rather than corrupt the stack line.
		if kind == .E {
			assert(nslots*2 + 16 + len(undo_hist.slots[slot.node].label) <= len(line), "undo line too deep")
		} else {
			assert(nslots*2 <= len(line), "undo line too deep")
		}

		if kind == .X {
			// A returning branch: '|' to the left, '\' to the right of the
			// collapsed column.
			if index+1 != nslots {
				for i in 0 ..< nslots {
					if i < index {
						w += copy(line[w:], "| ")
					}
					if i > index {
						w += copy(line[w:], " \\")
					}
				}
			}
			for i := index; i < nslots-1; i += 1 {
				scratch[i] = scratch[i+1]
			}
			nslots -= 1
		}

		if kind == .E {
			for i in 0 ..< nslots {
				if i == index {
					w += copy(line[w:], "* ")
				} else {
					w += copy(line[w:], "| ")
				}
			}
			w += copy(line[w:], "   ")
			seq := fmt.bprintf(line[w:], "%d", undo_hist.slots[slot.node].seq)
			w += len(seq)
			w += copy(line[w:], "   ")
			w += copy(line[w:], undo_hist.slots[slot.node].label)
			line_node = slot.node

			c := undo_hist.slots[slot.node].first_child
			if c < 0 {
				scratch[index] = Undo_View_Slot{kind = .X}
			} else if undo_hist.slots[c].next_sibling < 0 {
				scratch[index] = Undo_View_Slot{kind = .E, node = c}
			} else {
				count := 0
				for s := c; s >= 0; s = undo_hist.slots[s].next_sibling {
					count += 1
				}
				scratch[index] = Undo_View_Slot{kind = .P, node = c, count = count}
			}
		}

		if kind == .P {
			for k in 0 ..< nslots {
				if k < index {
					w += copy(line[w:], "| ")
				}
				if k == index {
					w += copy(line[w:], "|/ ")
				}
				if k > index {
					w += copy(line[w:], " / ")
				}
			}
			for i := index; i < nslots-1; i += 1 {
				scratch[i] = scratch[i+1]
			}
			nslots -= 1

			// The oldest sibling becomes this column's E; the rest stay as a
			// P in the next column. Two siblings split into two E columns
			// (undotree puts the newer one on the left).
			first := slot.node
			if slot.count == 2 {
				a := first
				b := undo_hist.slots[a].next_sibling
				left, right := a, b
				if undo_hist.slots[a].seq < undo_hist.slots[b].seq {
					left, right = b, a
				}
				for i := nslots - 1; i >= index; i -= 1 {
					scratch[i+2] = scratch[i]
				}
				nslots += 2
				scratch[index] = Undo_View_Slot{kind = .E, node = left}
				scratch[index+1] = Undo_View_Slot{kind = .E, node = right}
			} else {
				// Children are linked in ascending seq order, so the oldest
				// (minimum-seq) sibling is always the chain head; the rest is
				// the chain minus that head.
				assert(first == minnode, "undotree sibling chain out of seq order")
				rest_first := undo_hist.slots[first].next_sibling
				for i := nslots - 1; i >= index; i -= 1 {
					scratch[i+2] = scratch[i]
				}
				nslots += 2
				scratch[index] = Undo_View_Slot{kind = .P, node = rest_first, count = slot.count - 1}
				scratch[index+1] = Undo_View_Slot{kind = .E, node = minnode}
			}
		}

		// Strip trailing spaces; an empty line means this pass drew nothing.
		for w > 0 && line[w-1] == ' ' {
			w -= 1
		}
		if w > 1 {
			append(&undo_tree_view.line_bufs, [256]u8{})
			copy(undo_tree_view.line_bufs[len(undo_tree_view.line_bufs)-1][:], line[:w])
			append(&undo_tree_view.lines, Undo_View_Line{node = line_node, text_len = w})
		}
	}

	// The machine emits root-first; the view is newest-first.
	for i := 0; i < len(undo_tree_view.lines) / 2; i += 1 {
		j := len(undo_tree_view.lines) - 1 - i
		undo_tree_view.lines[i], undo_tree_view.lines[j] = undo_tree_view.lines[j], undo_tree_view.lines[i]
		undo_tree_view.line_bufs[i], undo_tree_view.line_bufs[j] = undo_tree_view.line_bufs[j], undo_tree_view.line_bufs[i]
	}
	undo_tree_view.built_count = n
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

undo_row :: proc(line_i: int) {
	line := undo_tree_view.lines[line_i]
	cur := line.node >= 0 && int(line.node) == int(undo_hist.current)
	id := clay.ID("UndoRow", u32(line_i))
	hovered := line.node >= 0 && clay.PointerOver(id)
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
			string(undo_tree_view.line_bufs[line_i][:line.text_len]),
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
		undo_tree_view.stats_buf[:],
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
// until the first action exists, then the scrollable line clip plus a
// v_scrollbar when the tree outgrows the body.
undo_view_content :: proc() {
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
	// Structure only changes on a push; cursor moves reuse the built lines.
	if undo_tree_view.built_count != len(undo_hist.slots) {
		undo_view_rebuild()
	}
	// Width is plain grow: every line is a fixed slice sized to its real text.
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
				for i in 0 ..< len(undo_tree_view.lines) {
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

// undo_row_click wires row clicks: any click inside an action row moves the
// cursor to that action. Connector rows are inert. Added first in the click
// chain so the undo view claims its own rows before anything underneath.
// Returns false when the media bin isn't showing the tree.
undo_view_row_click :: proc(inp: Mouse_Input) -> bool {
	if panel_views.media_bin_view != .Undo || len(undo_hist.slots) <= 1 {
		return false
	}
	if undo_tree_view.built_count != len(undo_hist.slots) {
		undo_view_rebuild()
	}
	for i in 0 ..< len(undo_tree_view.lines) {
		if undo_tree_view.lines[i].node < 0 {
			continue
		}
		if clay.PointerOver(clay.ID("UndoRow", u32(i))) {
			undo_go_to(int(undo_tree_view.lines[i].node))
			return true
		}
	}
	return false
}
