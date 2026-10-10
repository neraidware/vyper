package vyper

import clay "clay-odin"
import "core:c"
import "core:fmt"
import "core:math"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Clay UI layout tree for the whole app (build_page), plus small display
// helpers used only by it.
//
// Screen structure (top to bottom):
//   AppBar              -- app name, project badge, help "?" toggle.
//   EditorUpperArea     -- Media Bin | Preview (+ transport) | Inspector.
//   Divider handles     -- resizable split between upper area and timeline.
//   EditorLowerArea     -- the timeline (toolbar, ruler, track lanes), or the
//                          empty-state with the Open-file button.
// Floating overlays     -- context menu, help overlay, text-input popup.
//
// The right-hand Inspector stacks three labeled cards -- Project (canvas
// resolution/fps/render range), Clip (the selected clip's properties), Render
// (output path / run) -- so every project and clip setting has one obvious
// home and nothing hides behind the track count.
// ---------------------------------------------------------------------------

// Per-frame text buffers for clay.Text elements. Clay does NOT copy text: it
// keeps the StringSlice until layout/draw later in the same frame, so the
// backing bytes must outlive build_page. Stack-scoped buffers die as soon as
// their enclosing UI block returns -- long before clay reads them -- which
// rendered every dynamic label that fed clay.Text from a local buffer as
// garbage. Every per-frame label has its own persistent buffer here, one per
// text element, never shared between two clay.Text calls.
// UI_Text_Buffers holds every per-frame text scratch used by build_page. Clay
// does NOT copy the bytes, so each field is one devoted buffer per clay.Text
// element (one per label, never shared between two calls -- a shared buffer
// would render both labels with whichever wrote last). Declared here as one
// process-singleton instance so the whole scratch surface has one owner.
UI_Text_Buffers :: struct {
	app_summary: [512]u8,
	app_fps:     [32]u8,
	state:       [64]u8,
	range:       [64]u8,
	track:       [256]u8,
	file:        [256]u8,
	dur:         [128]u8,
	io:          [128]u8,
	gain:        [64]u8,
	// speed and pitch are formatted into fixed buffers on the frame the inspector
	// draws, not allocated per frame like the rest of the model asks for.
	speed:       [64]u8,
	pitch:       [64]u8,
	opacity:     [64]u8,
	x:           [64]u8,
	y:           [64]u8,
	s:           [64]u8,
	l:           [64]u8,
	r:           [64]u8,
	t:           [64]u8,
	b:           [64]u8,
	// zoom and the two pan axes, formatted as percents for the inspector row.
	z:           [64]u8,
	px:          [64]u8,
	py:          [64]u8,
	out:         [128]u8,
	rate:        [64]u8,
	hint:        [512]u8,
	// keyframe readout scratch: lane name, absolute timeline frame, value text.
	keyframe_name:     [128]u8,
	keyframe_frame:    [64]u8,
	keyframe_val:      [64]u8,
	// "keyframe all modified" row: the heading and the pending-lane list.
	// Eleven lanes plus separators is 47 bytes (28 of names, 20 of ", "), so 64
	// still fits with room for the NUL. The bound is asserted at the write rather
	// than trusted from this comment — the comment was what said "seven lanes"
	// while the table behind it had eight and the enum had eleven.
	keyframe_pending:      [64]u8,
	keyframe_pending_list: [64]u8,
	// The inspector's clip-name label, cut to fit the name field. A display
	// name is a file name, so PATH_MAX is the honest bound; 256 covers every
	// path an editor meets and keeps the buffer off the heap.
	clip_name: [256]u8,
	// playhead timecode (HH:MM:SS:FF) scratch; clay keeps it until draw, so it
	// must outlive build_page and back exactly one clay.Text element per frame.
	timecode:    [32]u8,
	// One label+name buffer per rate for the playback-rate dropdown items. Each
	// menu row must keep its own buffer alive until draw (clay keeps the slices),
	// and the same buffer can never back two rows -- so sizes match PLAYBACK_RATES.
	rate_menu:   [7]struct {
		name:  [64]u8,
		label: [64]u8,
	},
	// file-finder scratch: the current-directory header, the symlink suffix, and
	// the Save-mode field placeholder (the suggested project name, drawn only
	// while the field is empty so Enter still means "descend" until typed).
	finder_dir: [512]u8,
	finder_sym: [512]u8,
	finder_save_hint: [128]u8,
}

ui_text: UI_Text_Buffers

build_page :: proc(width, height: c.int) -> clay.ClayArray(clay.RenderCommand) {
	clay.SetLayoutDimensions({f32(width), f32(height)})
	clay.BeginLayout()
	DEFAULT_BORDER := clay.BorderOutside(1)

	// App-bar project summary text (project label · resolution · fps). Built
	// into the persistent buffers below so the every-frame labels never
	// allocate and outlive build_page (clay keeps the slices until draw).
	project_label := project.name
	if project_label == "" {
		project_label = "untitled project"
	}
	fps_l := "auto"
	if project.frame_rate > 0 {
		fps_l = fmt.bprintf(ui_text.app_fps[:], "%g", project.frame_rate)
	}

	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			layoutDirection = .TopToBottom,
		},
		backgroundColor = BACKGROUND,
	},
	) {
		if clay.UI(clay.ID("AppBar"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(APP_BAR_H)},
				layoutDirection = .LeftToRight,
				childGap = CARD_GAP,
				padding = clay.Padding{left = PANEL_PADDING, right = PANEL_PADDING},
				childAlignment = {x = .Left, y = .Center},
			},
			backgroundColor = EDITOR_BG,
			border = {color = BUTTON_BORDER, width = clay.BorderWidth{bottom = 1}},
		},
		) {
			clay.Text(
				"Vyper",
				clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_HEADING},
			)
			clay.Text(
				"·",
				clay.TextElementConfig{textColor = BUTTON_BORDER, fontSize = FONT_NORMAL},
			)
			clay.Text(
				fmt.bprintf(
					ui_text.app_summary[:],
					"%s · %dx%d @ %sfps",
					project_label,
					project.width,
					project.height,
					fps_l,
				),
				clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL},
			)
			if clay.UI(clay.ID("AppSpacer"))(
			{layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}}},
			) {}
			// Help overlay toggle ("?" / F1).
			if clay.UI(clay.ID("HelpButton"))(
			{
				layout = {
					sizing = {
						width = clay.SizingFixed(f32(BUTTON_HEIGHT) + 6),
						height = clay.SizingFixed(BUTTON_HEIGHT),
					},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
				border = {
					color = editor_flags.help_open ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
					width = clay.BorderOutside(editor_flags.help_open ? 2 : 1),
				},
				cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
			},
			) {
				clay.Text(
					"?",
					clay.TextElementConfig {
						textColor = editor_flags.help_open ? BUTTON_BORDER_HOVER : TEXT,
						fontSize = FONT_HEADING,
					},
				)
			}
		}
		if clay.UI(clay.ID("EditorUpperArea"))(
		{
			layout = {
				sizing = {
					width = clay.SizingGrow({}),
					height = clay.SizingFixed(panel_layout.upper_area_height),
				},
				padding = clay.PaddingAll(PANEL_PADDING),
				childAlignment = {x = .Center, y = .Center},
				layoutDirection = .LeftToRight,
				childGap = SECTION_GAP,
			},
			backgroundColor = EDITOR_BG,
			cornerRadius = clay.CornerRadiusAll(RADIUS_CONTAINER),
		},
		) {
			// Column 1: Media Bin.
			build_media_bin_column(DEFAULT_BORDER)
			// Column 2: Preview with the transport strip beneath it.
			build_preview_column(DEFAULT_BORDER)
			// Column 3: Inspector -- Clip / Project / Render view. The bottom
			// tab row picks which card the scrollport shows; the active card
			// scrolls in its own scrollport (InspectorContent) with a draggable
			// vertical strip when it outgrows the column.
			build_inspector_column()
		}
		if clay.UI(clay.ID("EditorDivider"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(EDITOR_DIVIDER_H)},
				childAlignment = {x = .Center, y = .Center},
			},
		},
		) {
			if clay.UI(clay.ID("DividerHandle"))(
			{
				layout = {sizing = {width = clay.SizingFixed(50), height = clay.SizingFixed(5)}},
				backgroundColor = BUTTON_BORDER,
				cornerRadius = clay.CornerRadiusAll(3),
			},
			) {}
		}
		if clay.UI(clay.ID("EditorLowerArea"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				padding = clay.PaddingAll(PANEL_PADDING),
			},
			backgroundColor = EDITOR_BG,
			cornerRadius = clay.CornerRadiusAll(RADIUS_CONTAINER),
		},
		) {
			build_timeline(DEFAULT_BORDER)
		}
	}
	draw_context_menu()
	draw_track_action_menu()
	draw_help_overlay(width, height)
	draw_text_input_popup(width, height)

	return clay.EndLayout(0)
}

// keyframe_gutter_names collects the distinct keyframe-track names the track-name
// gutter (KeyframeGutterNames) labels one visible lane each: every clip's tracks in
// clip order, deduplicated. Capped at `rows` (the row only has room for that
// many lines); clips keyframing paths others omit still read because each
// label row is aligned to the same KF_ROW_H lanes above the tiles.
keyframe_gutter_names :: proc(track: ^Track, rows: int, out: []string) -> int {
	n := 0
	for &c in track.clips {
		for i in 0..<c.keyframe_tracks.n {
			t := session_trk_view(c.keyframe_tracks,i)
			dup := false
			lane := keyframe_track_name(t)
			for i in 0 ..< n {
				if out[i] == lane {
					dup = true
					break
				}
			}
			if dup {
				continue
			}
			if n >= rows || n >= len(out) {
				return n
			}
			out[n] = lane
			n += 1
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// Inspector cards (column 3).
// ---------------------------------------------------------------------------

// text_px is the width clay's measure_text reports for `text` at `font_size`,
// computed with the same metric so a label cut to a pixel budget is cut exactly
// where clay would have overflowed.
text_px :: proc(text: string, font_size: int) -> f32 {
	n := 0
	for i := 0; i < len(text); {
		_, size := utf8.decode_rune(text[i:])
		n += 1
		i += size
	}
	return f32(n) * f32(font_size) * FONT_ADVANCE_RATIO
}

// INSPECTOR_CARD_MAX_W is the width a card may take inside the inspector: the
// column's own maximum, less the vertical scrollbar that shares the row with it.
// A card is sized by its CONTENT, and a Text child's measured width is that
// content -- so an unbounded card adopted the width of the longest label in it.
// A file name is exactly that label ("A012_C003_20260314_184522_take07.mov"
// measures ~430px in a 346px card), and clay has no max-width on a text element
// to stop it: the name was the widest thing in the panel, so the panel became
// as wide as the name and painted its background over the preview.
//
// The bound and label_truncate_fmt fix that from different sides, and each one
// alone still leaves a bug: with the bound but no cut, the card holds its width
// and the text spills out of the field over the preview instead; with the cut
// but no bound, the next label wider than this one resizes the panel again.
INSPECTOR_CARD_MAX_W :: f32(INSPECTOR_MAX_W - TSCROLLBAR_W)

// label_truncate_fmt writes `text` into `dst` as a NUL-terminated string, cut to
// `max_px` at `font_size` with a trailing ellipsis when it does not fit, and
// returns what it wrote. `text` is written whole when it already fits.
//
// It fills a CALLER's buffer rather than returning a fresh string because this
// runs on the inspector's layout path, once per frame, and an allocated string
// per frame is exactly what the ownership rules forbid — as is a truncation that
// is only approximately right, since the one glyph it overflows by is the glyph
// that makes the panel jump.
//
// The cut lands on a RUNE boundary and the ellipsis is reserved before the
// budget is spent, so the result never exceeds `max_px`. Cutting the string
// rather than leaning on the card's width bound is what keeps the tail legible:
// clay has no max-width on a text element, so an uncut label is not clipped at
// the field — it is laid out at its full measured width and painted over the
// panel next door. It also drops the end of a file name silently, and the end is
// what tells two takes of the same clip apart.
label_truncate_fmt :: proc(dst: []u8, text: string, font_size: int, max_px: f32) -> string {
	if text_px(text, font_size) <= max_px {
		written := copy(dst, text)
		assert(written < len(dst), "clip name display buffer too small for a name that fits the field")
		dst[written] = 0
		return string(dst[:written])
	}
	ellipsis := "..."
	adv := f32(font_size) * FONT_ADVANCE_RATIO
	// Every rune is the same width under this metric, so the budget converts to
	// a rune count directly rather than needing a measuring walk per candidate.
	keep := int((max_px - text_px(ellipsis, font_size)) / adv)
	if keep < 0 {
		keep = 0
	}
	// Walk to the end of the keep-th rune: cutting mid-rune would split a UTF-8
	// sequence and leave a replacement glyph in the label.
	cut := 0
	n := 0
	for i := 0; i < len(text); {
		_, size := utf8.decode_rune(text[i:])
		n += 1
		if n > keep {
			break
		}
		cut = i + size
		i += size
	}
	cut = min(cut, len(text))
	written := copy(dst, text[:cut])
	written += copy(dst[written:], ellipsis)
	// dst is sized off the pixel budget (see ui_text.clip_name), so this can only
	// fire if the budget or the font moved without the buffer following — which
	// is silent corruption of the neighbouring field otherwise, so it asserts
	// rather than clamping.
	assert(written < len(dst), "clip name display buffer too small for its pixel budget")
	dst[written] = 0
	return string(dst[:written])
}

// clip_name_display is the clip's name as the inspector's name row draws it: cut
// to the field and written into the fixed ui_text buffer, because clay holds the
// string until the draw pass and the inspector lays out every frame.
clip_name_display :: proc(cl: ^Clip) -> string {
	return label_truncate_fmt(
		ui_text.clip_name[:],
		clip_label_text(cl),
		FONT_NORMAL,
		clip_name_max_px(),
	)
}

// clip_name_max_px is the width the clip name may occupy in the name row: the
// card's inner width, less the Rename button beside it, the row's child gap, and
// the name field's own padding.
//
// Derived from the WIDEST column rather than the resolved one on purpose. The
// resolved width is only known after layout, and layout is what this text is
// feeding — reading last frame's box back would make the label's length depend
// on the label's length. It is an upper bound on the widest layout, so at a
// narrower window the name is cut a little early rather than late.
clip_name_max_px :: proc() -> f32 {
	pad := f32(FIELD_PAD_H)
	rename_px := text_px("Rename", FONT_SMALL) + 2 * pad
	inner := INSPECTOR_CARD_MAX_W - 2 * PANEL_PADDING
	return inner - rename_px - BUTTON_ROW_GAP - 2 * pad
}

// card_open opens a shared card chrome: a titled panel that returns whether its
// body should be drawn. Title stays the same size/color across all cards so
// the inspector reads consistently.
//
// The width bound is load-bearing, not defensive: it is what makes a label
// unable to resize the panel that shows it (see INSPECTOR_CARD_MAX_W). Every
// card shares this, so the bound is one edit rather than one per card, and no
// card can grow into the scrollbar beside it.
card_open :: proc(id_name: string, title: string) -> bool {
	if clay.UI(clay.ID(id_name))(
		{
			layout = {
				sizing = {
					width  = clay.SizingGrow({max = INSPECTOR_CARD_MAX_W}),
					height = clay.SizingFit({}),
				},
				padding = clay.PaddingAll(PANEL_PADDING),
				childGap = CARD_GAP,
				layoutDirection = .TopToBottom,
			},
			backgroundColor = BUTTON,
			border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
			cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
		},
	) {
		clay.Text(
			title,
			clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_SMALL},
		)
		return true
	}
	return false
}

// panel_caption is the small grey label above a group of controls in a card.
panel_caption :: proc(label: string) {
	clay.Text(label, clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
}

// prop_field renders one editable labelled value box (X/Y/Scale/crop). focused
// highlights the border while that field is being edited.
prop_field :: proc(id_name: string, label, value: string, focused: bool) {
	if clay.UI(clay.ID(id_name))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(FIELD_H)},
			layoutDirection = .LeftToRight,
			childGap = 6,
			padding = clay.PaddingAll(6),
			childAlignment = {x = .Left, y = .Center},
		},
		backgroundColor = BUTTON,
		border = {
			color = focused ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = clay.BorderOutside(focused ? 2 : 1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {
		clay.Text(
			label,
			clay.TextElementConfig {
				textColor = focused ? BUTTON_BORDER_HOVER : TEXT,
				fontSize = FONT_SMALL,
			},
		)
		clay.Text(value, clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA})
	}
}

// keyframe_add_button is the inspector's "key this property at the playhead"
// control: a transparent click pad sized to the diamond glyph (KF_BTN_R*2
// plus KF_BTN_PAD). The diamond itself is painted over it in the overlay pass
// (draw_kf_add_buttons) so the button looks exactly like a keyframe.
keyframe_add_button :: proc(id_name: string) {
	pad := KF_BTN_R * 2 + KF_BTN_PAD * 2
	if clay.UI(clay.ID(id_name))(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(pad),
				height = clay.SizingFixed(pad),
			},
			childAlignment = {x = .Left, y = .Center},
		},
	},
	) {}
}

// prop_field_row lays one property field out with its add-keyframe button: the
// field grows, the fixed diamond button sits right of it.
prop_field_row :: proc(id_name, field_id, label, value: string, focused: bool, btn_id: string) {
	if clay.UI(clay.ID(id_name))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = 6,
			childAlignment = {x = .Left, y = .Center},
		},
	},
	) {
		prop_field(field_id, label, value, focused)
		keyframe_add_button(btn_id)
	}
}

// group_caption_row is a property-section header (Transform, Crop) with the
// whole-group keyframe button on the right: one click keys every lane of the
// section at the playhead. The group button uses the same keyframe_add_button pad,
// so the diamond cluster painted over it in gpu_draw.odin (KF_GROUP_BTN_IDS)
// is hit-tested exactly like a single-lane button.
group_caption_row :: proc(caption_id, spacer_id, label, btn_id: string) {
	if clay.UI(clay.ID(caption_id))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
			childAlignment = {x = .Left, y = .Center},
		},
	},
	) {
		clay.Text(label, clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
		if clay.UI(clay.ID(spacer_id))( // stretch: pushes the button to the right
			{layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}}},
		) {}
		keyframe_add_button(btn_id)
	}
}

// caption_row is a group caption with NO keyframe diamond, for a property group
// that has no section to key as a unit. Zoom and Pan are that: pan.x and pan.y
// are independent (a horizontal slide is not half of a vertical one), so a single
// diamond would either key a combination nobody asked for or need a packed
// section that duplicates the lanes it groups.
//
// Passing a button id to group_caption_row and simply not handling it would draw a
// diamond that does nothing when clicked, which is worse than having none.
caption_row :: proc(caption_id, spacer_id, label: string) {
	if clay.UI(clay.ID(caption_id))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
				layoutDirection = .LeftToRight,
				childGap = BUTTON_ROW_GAP,
				childAlignment = {x = .Left, y = .Center},
			},
		},
	) {
		clay.Text(label, clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
		if clay.UI(clay.ID(spacer_id))( // stretch: keeps the caption flush left
			{layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}}},
		) {}
	}
}

// project_card is the "Project" inspector card: canvas resolution presets,
// orientation, frame rate, and the render range. These controls are always
// reachable (not gated behind an empty timeline).
// geom_key_all_modified_row is the "keyframe all modified" summary: it names the
// geometry lanes that were edited without a keyframe, which the A shortcut keys
// in one undo node.
//
// It names the pending lanes rather than saying "modified properties" and
// hoping. A user who panned a clip sees "L, R" and knows exactly which edges A
// will commit; an action that keys "whatever changed" is one nobody trusts
// enough to press, and the whole point is that they should.
//
// The shortcut is named here because there is no button to hover: without the
// row, a pending set is invisible in the inspector and the only hint is a tint
// on the timeline gutter. With the button gone this row is the whole of it, so
// it carries the key as well as the state.
//
// The row is laid out unconditionally (a stable inspector does not reflow when
// a flag flips) but only LIT when something is pending, so its state is
// readable at a glance without appearing out of nowhere.
//
// Layout uses the `if clay.UI(id)(config) { ... }` BLOCK form, not
// `if !clay.UI(id)(config) { return }`. Both compile and both return true, but
// the early-return form left the element with a zero-height box: Clay's
// _CloseElement is deferred to UI_WithId's natural end, and the non-block
// shape collapsed the row to 0x346 -- laid out but invisible, un-painted, and
// un-hit-testable, with nothing to say so. The block form is the shape the rest
// of this file uses.
geom_key_all_modified_row :: proc(cl: ^Clip) {
	any := clip_geom_any_modified(cl)
	if clay.UI(clay.ID("KeyframeAllModifiedRow"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
				layoutDirection = .LeftToRight,
				childGap = BUTTON_ROW_GAP,
				childAlignment = {x = .Left, y = .Center},
			},
		},
	) {
		// Short labels for the pending lanes, formatted into the fixed ui_text
		// buffer so the row does not allocate a string every inspector frame.
		buf := ui_text.keyframe_pending[:]
		label := fmt.bprintf(buf[:], "A  Key %s", geom_key_pending_labels(cl, any))
		col := any ? TEXT : CMDLINE_PLACEHOLDER
		clay.Text(label, clay.TextElementConfig{textColor = col, fontSize = FONT_SMALL})
	}
}

// geom_key_pending_labels lists the pending lanes as short inspector names
// ("L, R, Scale"), or "none" when the set is empty. The short names are the
// same ones the per-row fields use, so the list reads as a summary of the
// rows above it rather than as track names from the keyframe gutter.
geom_key_pending_labels :: proc(cl: ^Clip, any: bool) -> string {
	if !any {
		return "none"
	}
	buf := ui_text.keyframe_pending_list[:]
	n := 0
	for i in 0 ..< int(Render_Geom_Prop._COUNT) {
		if !clip_geom_key_modified(cl, Render_Geom_Prop(i)) {
			continue
		}
		if n > 0 {
			n += len(fmt.bprintf(buf[n:], ", "))
		}
		n += len(fmt.bprintf(buf[n:], "%s", render_geom_short_name(Render_Geom_Prop(i))))
	}
	// fmt.bprintf truncates silently, so a lane too long for the buffer would draw
	// a clipped list with nothing on screen to say so. Assert instead: the whole
	// set must render, or the buffer needs sizing against _COUNT.
	assert(n <= len(buf), "ui: pending-lane list truncated — size keyframe_pending_list from _COUNT")
	return string(buf[:n])
}

project_card :: proc() {
	if !card_open("ProjectCard", "Project") {
		return
	}
	panel_caption("Resolution")
	if clay.UI(clay.ID("InfoResRow"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
		},
	},
	) {
		res_auto_button()
		res_preset_button("Res720", "720p", 1280, 720)
		res_preset_button("Res1080", "1080p", 1920, 1080)
		res_preset_button("Res4K", "4K", 3840, 2160)
	}
	if clay.UI(clay.ID("InfoOrientRow"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
		},
	},
	) {
		switch_toggle("OrientVertical", "Portrait canvas", project.height > project.width)
	}
	panel_caption("Frame rate")
	if clay.UI(clay.ID("FpsRow1"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
		},
	},
	) {
		fps_preset_button("Fps24", "24", 24)
		fps_preset_button("Fps25", "25", 25)
		fps_preset_button("Fps30", "30", 30)
	}
	if clay.UI(clay.ID("FpsRow2"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
		},
	},
	) {
		fps_preset_button("Fps48", "48", 48)
		fps_preset_button("Fps60", "60", 60)
		fps_preset_button("FpsAuto", "Auto", 0)
	}
	panel_caption("Render range")
	if project.start_frame >= 0 &&
	   project.end_frame >= 0 &&
	   project.end_frame > project.start_frame {
		range_buf := ui_text.range[:]
		clay.Text(
			fmt.bprintf(range_buf[:], "%d – %d", project.start_frame, project.end_frame),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
		)
	} else {
		clay.Text("full timeline", clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA})
	}
}

// clip_label_text returns the display name for a clip (its own name, falling
// back to the file base name).
clip_label_text :: proc(cl: ^Clip) -> string {
	if n := clip_name(cl); n != "" {
		return n
	}
	if cl.path != "" {
		return path_basename(cl.path)
	}
	return "Clip"
}

// clip_card is the "Clip" inspector card: the selected clip's identity,
// timing, and transform. Fields click-to-edit; crop values are per-box
// percentages.
clip_card :: proc() {
	if !card_open("ClipCard", "Clip") {
		return
	}
	tr, cl, ok := selected_clip()
	if !ok {
		// Selected keyframes substitute for the clip in this card: the keyframe
		// readout (property, frame, editable value — or, for a multi-selection,
		// the properties the whole set shares). The clip fields below are
		// skipped because the two selections never coexist (S3).
		if keyframe_sel_active() {
			keyframe_readout()
			return
		}
		clay.Text(
			"No clip selected",
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL},
		)
		return
	} else {
		if cl.kind != .Audio {
			if clay.UI(clay.ID("NameRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
					layoutDirection = .LeftToRight,
					childGap = BUTTON_ROW_GAP,
					childAlignment = {x = .Left, y = .Center},
				},
			},
			) {
				if clay.UI(clay.ID("NameValue"))(
				{
					layout = {
						sizing = {
							width = clay.SizingGrow({}),
							height = clay.SizingFixed(BUTTON_HEIGHT),
						},
						padding = clay.Padding{left = FIELD_PAD_H, right = FIELD_PAD_H},
						childAlignment = {x = .Left, y = .Center},
					},
					backgroundColor = EDITOR_BG,
					cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
				},
				) {
					clay.Text(
						clip_name_display(cl),
						clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL},
					)
				}
				if clay.UI(clay.ID("PropRename"))(
				{
					layout = {
						sizing = {
							width = clay.SizingFit({}),
							height = clay.SizingFixed(BUTTON_HEIGHT),
						},
						padding = clay.Padding{left = FIELD_PAD_H, right = FIELD_PAD_H},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
					border = {
						color = clay.Hovered() ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
						width = clay.BorderOutside(1),
					},
					cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
				},
				) {
					clay.Text(
						"Rename",
						clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
					)
				}
			}
		}
		// Inspector clip-card readouts, rebuilt every frame. Clay does NOT copy
		// text at the call — it keeps the slice until draw — so every element
		// must own its own buffer: one per line, never a shared buffer rewritten
		// between clay.Text calls.
		track_buf := ui_text.track[:]
		file_buf := ui_text.file[:]
		dur_buf := ui_text.dur[:]
		clay.Text(
			fmt.bprintf(track_buf[:], "Track: %s", tr.name),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
		)
		clay.Text(
			fmt.bprintf(file_buf[:], "File: %s", path_basename(cl.path)),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
		)
		clay.Text(
			fmt.bprintf(dur_buf[:], "Duration: %d frames", cl.source_length_frames),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
		)
		if cl.kind != .Audio {
			io_buf := ui_text.io[:]
			clay.Text(
				fmt.bprintf(
					io_buf[:],
					"In: %d   Out: %d",
					cl.source_start_frame,
					cl.source_start_frame + cl.source_length_frames,
				),
				clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
			)
			x_buf := ui_text.x[:]
			x_val := fmt.bprintf(x_buf[:], "%.0f", clip_geom_get(cl, .Trans_X))
			if edit_state.field == .X {
				x_val = string(edit_state.chars[:edit_state.len])
			}
			group_caption_row("TransCaption", "TransCaptionSpacer", "Transform", "KeyframeAddTrans")
			prop_field_row("PropRowX", "PropFieldX", "X", x_val, edit_state.field == .X, "KeyframeAddX")
			y_buf := ui_text.y[:]
			y_val := fmt.bprintf(y_buf[:], "%.0f", clip_geom_get(cl, .Trans_Y))
			if edit_state.field == .Y {
				y_val = string(edit_state.chars[:edit_state.len])
			}
			prop_field_row("PropRowY", "PropFieldY", "Y", y_val, edit_state.field == .Y, "KeyframeAddY")
			s_buf := ui_text.s[:]
			scl_val := fmt.bprintf(s_buf[:], "%.2f", clip_geom_get(cl, .Scale))
			if edit_state.field == .Scale {
				scl_val = string(edit_state.chars[:edit_state.len])
			}
			prop_field_row("PropRowS", "PropFieldS", "Scale", scl_val, edit_state.field == .Scale, "KeyframeAddS")
			// Opacity: a horizontal slider plus a percent field. The track is
			// clay, not a custom paint pass -- the value is the filled child's
			// percent width, so it needs no overlay drawing like the gain knob.
			// The slider container is the hit target (opacity_from_x maps the
			// pointer across it); the field beside it is the type-in path.
			//
			// Read at the PLAYHEAD (clip_geom_get), like every other lane in this
			// inspector. Reading the resting field would show 100% while the clip
			// visibly faded, and the fill below would disagree with the canvas.
			op_shown := clip_geom_get(cl, .Opacity)
			op_buf := ui_text.opacity[:]
			op_val := fmt.bprintf(op_buf[:], "%.0f%%", op_shown * 100)
			if edit_state.field == .Opacity {
				op_val = string(edit_state.chars[:edit_state.len])
			}
			if clay.UI(clay.ID("OpacityRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
					layoutDirection = .LeftToRight,
					childGap = BUTTON_ROW_GAP,
					childAlignment = {x = .Left, y = .Center},
				},
			},
			) {
				op_active := active_interaction == .Opacity_Drag
				if clay.UI(clay.ID("OpacitySlider"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(FIELD_H)},
						childAlignment = {x = .Left, y = .Center},
					},
				},
				) {
					if clay.UI(clay.ID("OpacityTrack"))(
					{
						layout = {
							sizing = {
								width = clay.SizingGrow({}),
								height = clay.SizingFixed(OPACITY_TRACK_H),
							},
						},
						backgroundColor = BUTTON,
						cornerRadius = clay.CornerRadiusAll(OPACITY_TRACK_H / 2),
					},
					) {
						clay.UI(clay.ID("OpacityFill"))(
						{
							layout = {
								sizing = {
									// clay.SizingPercent is 0-1, NOT 0-100: the fill
									// width is (trackWidth - padding) * this
									// value, and passing opacity*100 made every
									// non-zero opacity overflow the track
									// ~opacity*100x. It also tripped clay's
									// PERCENTAGE_OVER_1 error every frame,
									// which clay_error swallows.
									//
									// op_shown, not cl.opacity: the fill has to
									// agree with the canvas, which composites
									// the playhead-sampled value.
									width = clay.SizingPercent(op_shown),
									height = clay.SizingFixed(OPACITY_TRACK_H),
								},
							},
							backgroundColor = BUTTON_BORDER_HOVER,
							cornerRadius = clay.CornerRadiusAll(OPACITY_TRACK_H / 2),
						},
						)
					}
				}
				op_hovered := op_active
				keyframe_add_button("KeyframeAddOpacity")
				prop_field("PropFieldOpacity", "Opacity", op_val, edit_state.field == .Opacity || op_hovered)
			}
			// Canvas-center snap belongs with the transform settings it governs.
			if clay.UI(clay.ID("SnapRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
					layoutDirection = .LeftToRight,
					childGap = BUTTON_ROW_GAP,
					childAlignment = {x = .Left, y = .Center},
				},
			},
			) {
				switch_toggle("SnapCenter", "Snap center", editor_flags.snap_center_to_canvas)
			}
			group_caption_row("CropCaption", "CropCaptionSpacer", "Crop (percent of box)", "KeyframeAddCrop")
			l_buf := ui_text.l[:]
			l_val := fmt.bprintf(l_buf[:], "%.0f%%", clip_geom_get(cl, .Crop_L) * 100)
			if edit_state.field == .Crop_L {
				l_val = string(edit_state.chars[:edit_state.len])
			}
			r_buf := ui_text.r[:]
			r_val := fmt.bprintf(r_buf[:], "%.0f%%", clip_geom_get(cl, .Crop_R) * 100)
			if edit_state.field == .Crop_R {
				r_val = string(edit_state.chars[:edit_state.len])
			}
			t_buf := ui_text.t[:]
			t_val := fmt.bprintf(t_buf[:], "%.0f%%", clip_geom_get(cl, .Crop_T) * 100)
			if edit_state.field == .Crop_T {
				t_val = string(edit_state.chars[:edit_state.len])
			}
			b_buf := ui_text.b[:]
			b_val := fmt.bprintf(b_buf[:], "%.0f%%", clip_geom_get(cl, .Crop_B) * 100)
			if edit_state.field == .Crop_B {
				b_val = string(edit_state.chars[:edit_state.len])
			}
			if clay.UI(clay.ID("CropRowTop"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
					layoutDirection = .LeftToRight,
					childGap = BUTTON_ROW_GAP,
				},
			},
			) {
				prop_field("PropCropL", "L", l_val, edit_state.field == .Crop_L)
				keyframe_add_button("KeyframeAddCropL")
				prop_field("PropCropR", "R", r_val, edit_state.field == .Crop_R)
				keyframe_add_button("KeyframeAddCropR")
			}
			if clay.UI(clay.ID("CropRowBot"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
					layoutDirection = .LeftToRight,
					childGap = BUTTON_ROW_GAP,
				},
			},
			) {
				prop_field("PropCropT", "T", t_val, edit_state.field == .Crop_T)
				keyframe_add_button("KeyframeAddCropT")
				prop_field("PropCropB", "B", b_val, edit_state.field == .Crop_B)
				keyframe_add_button("KeyframeAddCropB")
			}
			// Zoom and Pan: the content window's magnification and offset. Their own
			// row rather than more crop fields, because they are a different
			// operation — crop trims the box edges and reveals background, these
			// change what the box SHOWS while the box stays exactly put.
			caption_row("ZoomPanCaption", "ZoomPanCaptionSpacer", "Zoom / Pan")
			z_buf := ui_text.z[:]
			z_val := fmt.bprintf(z_buf[:], "%.0f%%", clip_geom_get(cl, .Zoom) * 100)
			if edit_state.field == .Zoom {
				z_val = string(edit_state.chars[:edit_state.len])
			}
			px_buf := ui_text.px[:]
			px_val := fmt.bprintf(px_buf[:], "%.0f%%", clip_geom_get(cl, .Pan_X) * 100)
			if edit_state.field == .Pan_X {
				px_val = string(edit_state.chars[:edit_state.len])
			}
			py_buf := ui_text.py[:]
			py_val := fmt.bprintf(py_buf[:], "%.0f%%", clip_geom_get(cl, .Pan_Y) * 100)
			if edit_state.field == .Pan_Y {
				py_val = string(edit_state.chars[:edit_state.len])
			}
			if clay.UI(clay.ID("ZoomPanRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
					layoutDirection = .LeftToRight,
					childGap = BUTTON_ROW_GAP,
				},
			},
			) {
				prop_field("PropFieldZoom", "Z", z_val, edit_state.field == .Zoom)
				keyframe_add_button("KeyframeAddZoom")
				prop_field("PropFieldPanX", "X", px_val, edit_state.field == .Pan_X)
				keyframe_add_button("KeyframeAddPanX")
				prop_field("PropFieldPanY", "Y", py_val, edit_state.field == .Pan_Y)
				keyframe_add_button("KeyframeAddPanY")
			}
			geom_key_all_modified_row(cl)
		} else {
			// Audio clips get the gain row: a drag-to-set knob (the GainKnob
			// element the interaction probe hit-tests) plus the dB value field.
			// The needle is drawn over the knob after layout (draw_gain_knob).
			if clay.UI(clay.ID("GainRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
					layoutDirection = .LeftToRight,
					childGap = BUTTON_ROW_GAP,
					childAlignment = {x = .Left, y = .Center},
				},
			},
			) {
				knob_active := active_interaction == .Gain_Drag
				if clay.UI(clay.ID("GainKnob"))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(KNOB_DIAMETER), height = clay.SizingFixed(KNOB_DIAMETER)},
					},
					backgroundColor = BUTTON,
					border = {
						color = clay.Hovered() || knob_active ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
						width = clay.BorderOutside(1),
					},
					// cornerRadius = half the side collapses the SDF to an
					// exact circle (matches rounded_rect.frag's clamp).
					cornerRadius = clay.CornerRadiusAll(KNOB_DIAMETER / 2),
				},
				) {}
				clay.Text(
					"Gain",
					clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
				)
				g_buf := ui_text.gain[:]
				// Follow the playhead when gain is keyed, like every geometry
				// lane above (clip_geom_get): the readout should show the level
				// playback is actually using, not the static cl.gain that the
				// keyed curve overrides. clip_gain_db_at_playhead owns that rule.
				g_shown := clip_gain_db_at_playhead(cl)
				g_val := fmt.bprintf(g_buf[:], "%.1f dB", g_shown)
				if edit_state.field == .Gain {
					g_val = string(edit_state.chars[:edit_state.len])
				}
				if clay.UI(clay.ID("PropFieldGain"))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(KNOB_VALUE_W), height = clay.SizingFixed(FIELD_H)},
						childAlignment = {x = .Left, y = .Center},
						padding = clay.PaddingAll(6),
					},
					backgroundColor = edit_state.field == .Gain ? BUTTON_HOVER : BUTTON,
					border = {
						color = edit_state.field == .Gain ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
						width = clay.BorderOutside(edit_state.field == .Gain ? 2 : 1),
					},
					cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
				},
				) {
					clay.Text(
						g_val,
						clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
					)
				}
				keyframe_add_button("KeyframeAddGain")
			}

			// SPEED and PITCH, audio clips only. Two fields rather than one, and
			// placed under Gain rather than beside it because they are the time
			// properties: speed changes how long the clip is, pitch changes its
			// frequency and not its length. Collapsing them into a single "rate"
			// would force the user to pick which one they meant, and in this engine
			// both can be set at once.
			//
			// Neither is keyframable yet, so there is no KeyframeAdd button -- an autofill
			// button that writes nothing is worse than no button. Both mirror the
			// playhead-sampled value (clip_pitch_at_playhead / clip_speed) so the
			// readout shows what playback uses, like the gain lane above.
			if cl.kind == .Audio {
				clay.Text(
					"Speed",
					clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
				)
				sp := fmt.bprintf(ui_text.speed[:], "%.0f%%", clip_speed(cl) * 100.0)
				if edit_state.field == .Speed {
					sp = string(edit_state.chars[:edit_state.len])
				}
				ui_prop_value("PropFieldSpeed", sp, .Speed)

				clay.Text(
					"Pitch",
					clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
				)
				pt := fmt.bprintf(ui_text.pitch[:], "%+.2f st", clip_pitch_at_playhead(cl))
				if edit_state.field == .Pitch {
					pt = string(edit_state.chars[:edit_state.len])
				}
				ui_prop_value("PropFieldPitch", pt, .Pitch)
			}
		}
	}
}

// ui_prop_value draws an editable value box, the same shape as PropFieldGain so the
// inspector's fields are visually identical whether they are knobs or numbers.
ui_prop_value :: proc(id: string, text: string, field: Edit_Field) {
	if clay.UI(clay.ID(id)) (
	{
		layout = {
			sizing = {width = clay.SizingFixed(KNOB_VALUE_W), height = clay.SizingFixed(FIELD_H)},
			childAlignment = {x = .Left, y = .Center},
			padding = clay.PaddingAll(6),
		},
		backgroundColor = edit_state.field == field ? BUTTON_HOVER : BUTTON,
		border = {
			color = edit_state.field == field ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = clay.BorderOutside(edit_state.field == field ? 2 : 1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {
		clay.Text(text, clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA})
	}
}

// keyframe_readout is the "Clip" inspector's keyframe slot, shown in place of
// the clip fields while keyframes are selected (S3, S7). With exactly one
// selected it is the property lane's name, the absolute timeline frame the key
// sits on, the value field, and the interpolation dropdown.
//
// With more than one selected it is keyframes_readout, which offers the
// properties a set of keys genuinely SHARES rather than a var identity.
keyframe_readout :: proc() {
	panel_caption("Keyframe")
	// Dispatch on whether the selection resolves as EXACTLY one key, not on the
	// count: keyframe_selected already carries that contract, and a sole selection
	// whose ref no longer resolves has no clip to name a lane from, so it reads
	// as the set readout too.
	cl, lane, keyframe, one := keyframe_selected()
	if !one {
		keyframes_readout()
		return
	}
	name_buf := ui_text.keyframe_name[:]
	clay.Text(
		fmt.bprintf(name_buf[:], "%s", keyframe_track_name(session_trk_view(cl.keyframe_tracks,lane))),
		clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL},
	)
	frame_buf := ui_text.keyframe_frame[:]
	clay.Text(
		fmt.bprintf(frame_buf[:], "frame %d", cl.timeline_start_frame + i64(keyframe.frame_off)),
		clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
	)
	if clay.UI(clay.ID("KeyframeValRow"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
			childAlignment = {x = .Left, y = .Center},
		},
	},
	) {
		clay.Text(
			"Value",
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
		)
		v_buf := ui_text.keyframe_val[:]
		// A key is a scalar on the lane that owns it (TODO.md Active 52), so the
		// readout is just that value. It used to branch on a packed mask and show
		// lane 0 -- a key now cannot be packed, so the branch is gone rather than
		// defaulted.
		rval := keyframe.value
		v_str := fmt.bprintf(v_buf[:], "%.2f", rval)
		if edit_state.field == .Keyframe_Value {
			v_str = string(edit_state.chars[:edit_state.len])
		}
		if clay.UI(clay.ID("PropFieldKf"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(KNOB_VALUE_W), height = clay.SizingFixed(FIELD_H)},
				childAlignment = {x = .Left, y = .Center},
				padding = clay.PaddingAll(6),
			},
			backgroundColor = edit_state.field == .Keyframe_Value ? BUTTON_HOVER : BUTTON,
			border = {
				color = edit_state.field == .Keyframe_Value ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
				width = clay.BorderOutside(edit_state.field == .Keyframe_Value ? 2 : 1),
			},
			cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
		},
		) {
			clay.Text(
				v_str,
				clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
			)
		}
	}
	if clay.UI(clay.ID("KeyframeInterpRow"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
			childAlignment = {x = .Left, y = .Center},
		},
	},
	) {
		clay.Text(
			"Interp",
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
		)
		interp, mixed, _ := keyframe_sel_interp()
		keyframe_interp_dropdown(interp, mixed)
	}
}

// keyframes_readout is the keyframe slot for a selection of two or more: what
// the set is, where it spans, and the properties the whole set SHARES.
//
// The line between "shared" and "not" is the point of this function, so it is
// worth stating: a property is shared when one value means the same thing on
// every selected key. Interpolation qualifies — it eases the segment arriving at
// a key, so it is a property of the key wherever it sits, and the dropdown
// writes all of them (keyframe_set_interp_all). The VALUE does not: it is one key's
// number for one lane, so with keys on different lanes there is no value that
// means anything, and with keys on the same lane the only "set them all" is
// flattening the animation. So the value field is not offered here at all — a
// "-"-looking field that silently edits keyframes[0] is worse than no field, and
// neither is a field whose "set all" would flatten a ramp the user just
// selected. Same rule for the track NAME, which is a var identity and not a
// property: shown when the whole selection is on one lane (where it is true of
// every key) and replaced by the count otherwise.
keyframes_readout :: proc() {
	count := keyframe_sel_count()
	name_buf := ui_text.keyframe_name[:]
	// The name is only meaningful as a header when it names EVERY selected key,
	// which is exactly the shared-property test: one lane, or many.
	if name, ok := keyframe_sel_same_lane(); ok {
		clay.Text(
			fmt.bprintf(name_buf[:], "%s", name),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL},
		)
	} else {
		clay.Text(
			fmt.bprintf(name_buf[:], "%d keyframes", count),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL},
		)
	}
	// The absolute frame span, which is the one frame-shaped fact true of the
	// whole set. Clips start at different points, so each key's absolute frame
	// is its own clip's start plus its clip-relative offset.
	frame_buf := ui_text.keyframe_frame[:]
	lo, hi := keyframe_sel_frame_span()
	if lo == hi {
		clay.Text(
			fmt.bprintf(frame_buf[:], "frame %d", lo),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
		)
	} else {
		clay.Text(
			fmt.bprintf(frame_buf[:], "frames %d-%d", lo, hi),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
		)
	}
	// The shared property. No row at all when not one ref resolved: a dropdown
	// naming a mode belongs to no selected key then, and an empty label would be
	// the only honest thing to draw.
	interp, mixed, seen := keyframe_sel_interp()
	if seen &&
	   clay.UI(clay.ID("KeyframeInterpRow"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
				layoutDirection = .LeftToRight,
				childGap = BUTTON_ROW_GAP,
				childAlignment = {x = .Left, y = .Center},
			},
		},
		) {
		clay.Text(
			"Interp",
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
		)
		keyframe_interp_dropdown(interp, mixed)
	}
}

// keyframe_interp_label is the keyframe interpolation dropdown's display text.
keyframe_interp_label :: proc(interp: Keyframe_Interp) -> string {
	switch interp {
	case .Linear:
		return "Linear"
	case .Cubic:
		return "Cubic"
	case .Ease_In:
		return "Ease in"
	case .Ease_Out:
		return "Ease out"
	case .Ease_In_Out:
		return "Ease in/out"
	case .Elastic:
		return "Elastic"
	}
	return "Linear"
}

// keyframe_interp_mixed_label is what a multi-selection's interpolation dropdown shows
// when the selected keys do NOT agree: no single mode is current, so naming one
// would be a lie about the set. A named constant because the literal and the
// reasoning travel together — the menu still offers every mode, and picking one
// writes the whole selection (keyframe_set_interp_all).
KF_INTERP_MIXED_LABEL :: "-"

// keyframe_interp_dropdown renders the interpolation selector as a collapsed button
// toggling a floating menu, the same toggle/select/dismiss shape as the
// export-encoder dropdown. Picking a mode sets how the segment ARRIVING at the
// key eases (we ease into a breakpoint, so the key you're heading to owns the
// curve); an undoable edit, like the value field.
//
// `mixed` is the multi-selection case: the keys disagree, so the button shows "-"
// and no menu entry is marked current, but the menu is the full list and any pick
// applies to the whole set.
keyframe_interp_dropdown :: proc(interp: Keyframe_Interp, mixed: bool) {
	if clay.UI(clay.ID("KeyframeInterpButton"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(120), height = clay.SizingFixed(BUTTON_HEIGHT)},
			padding = clay.Padding{left = 8, right = 8},
			childAlignment = {x = .Left, y = .Center},
		},
		backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
		border = {
			color = keyframe_view.interp_menu_open ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = clay.BorderOutside(1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {
		clay.Text(
			mixed ? KF_INTERP_MIXED_LABEL : keyframe_interp_label(interp),
			clay.TextElementConfig {
				textColor = keyframe_view.interp_menu_open ? BUTTON_BORDER_HOVER : TEXT,
				fontSize = FONT_SMALL,
			},
		)
	}
	if keyframe_view.interp_menu_open {
		if clay.UI(clay.ID("KeyframeInterpMenu"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(120), height = clay.SizingFit({})},
				layoutDirection = .TopToBottom,
				childGap = 2,
				padding = clay.PaddingAll(4),
			},
			backgroundColor = BUTTON,
			border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
			cornerRadius = clay.CornerRadiusAll(4),
			floating = {
				offset = {0, 4},
				parentId = clay.ID("KeyframeInterpButton").id,
				zIndex = 1000,
				attachment = {element = .LeftTop, parent = .LeftBottom},
				attachTo = .ElementWithId,
				pointerCaptureMode = .Capture,
				clipTo = .None,
			},
		},
		) {
			// No entry is marked current when the selection is mixed: the whole
			// list is offered, and a pick writes every selected key.
			settings_button(
				"KeyframeInterpLinear",
				keyframe_interp_label(.Linear),
				!mixed && interp == .Linear,
				fill_width = true,
			)
			settings_button(
				"KeyframeInterpCubic",
				keyframe_interp_label(.Cubic),
				!mixed && interp == .Cubic,
				fill_width = true,
			)
			settings_button(
				"KeyframeInterpEaseIn",
				keyframe_interp_label(.Ease_In),
				!mixed && interp == .Ease_In,
				fill_width = true,
			)
			settings_button(
				"KeyframeInterpEaseOut",
				keyframe_interp_label(.Ease_Out),
				!mixed && interp == .Ease_Out,
				fill_width = true,
			)
			settings_button(
				"KeyframeInterpEaseInOut",
				keyframe_interp_label(.Ease_In_Out),
				!mixed && interp == .Ease_In_Out,
				fill_width = true,
			)
			settings_button(
				"KeyframeInterpElastic",
				keyframe_interp_label(.Elastic),
				!mixed && interp == .Elastic,
				fill_width = true,
			)
		}
	}
}

// render_encoder_label returns the export encoder choices' display text: GPU
// means "the first hardware H.264 encoder that opens" (quality traded for
// speed), CPU the libx264 baseline.
render_encoder_label :: proc(choice: Render_Encoder_Choice) -> string {
	if choice == .GPU {
		return "Fast (GPU)"
	}
	return "High quality (CPU)"
}

// render_encoder_dropdown renders the export encoder selector in the render
// panel: a collapsed button toggling a floating menu of the two choices, the
// same shape as the playback-rate dropdown. Choosing one sets the choice and
// closes the menu. A GPU choice that finds no working hardware encoder on this
// machine falls back to libx264 at render time (never a failed render).
render_encoder_dropdown :: proc() {
	enc_border := clay.BorderOutside(1)
	if clay.UI(clay.ID("RenderEncoderButton"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(170), height = clay.SizingFixed(BUTTON_HEIGHT)},
			padding = clay.Padding{left = 8, right = 8},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
		border = {
			color = render_encoder_ui.menu_open ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = enc_border,
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {
		clay.Text(
			render_encoder_label(render_encoder_ui.choice),
			clay.TextElementConfig {
				textColor = render_encoder_ui.menu_open ? BUTTON_BORDER_HOVER : TEXT,
				fontSize = FONT_SMALL,
			},
		)
	}
	if render_encoder_ui.menu_open {
		if clay.UI(clay.ID("RenderEncoderMenu"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(170), height = clay.SizingFit({})},
				layoutDirection = .TopToBottom,
				childGap = 2,
				padding = clay.PaddingAll(4),
			},
			backgroundColor = BUTTON,
			border = {color = BUTTON_BORDER, width = enc_border},
			cornerRadius = clay.CornerRadiusAll(4),
			floating = {
				offset = {0, 4},
				parentId = clay.ID("RenderEncoderButton").id,
				zIndex = 1000,
				attachment = {element = .LeftTop, parent = .LeftBottom},
				attachTo = .ElementWithId,
				pointerCaptureMode = .Capture,
				clipTo = .None,
			},
		},
		) {
			settings_button("EncChoiceCPU", "High quality (CPU)", render_encoder_ui.choice == .CPU, fill_width = true)
			settings_button("EncChoiceGPU", "Fast (GPU)", render_encoder_ui.choice == .GPU, fill_width = true)
		}
	}
}

// render_card is the "Render" inspector card: pick an output path, start/cancel
// an export, and show progress.
render_card :: proc() {
	if !card_open("RenderCard", "Render") {
		return
	}
	render_encoder_dropdown()
	if clay.UI(clay.ID("RenderButtonsRow"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = CARD_GAP,
		},
	},
	) {
		if clay.UI(clay.ID("RenderPickButton"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(BUTTON_HEIGHT)},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = BUTTON,
			border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
			cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
		},
		) {
			clay.Text(
				"Pick file path",
				clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
			)
		}
		if clay.UI(clay.ID("RenderRunButton"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(BUTTON_HEIGHT)},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = BUTTON,
			border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
			cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
		},
		) {
			label := render_is_busy() ? "Rendering..." : "Render"
			clay.Text(label, clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
		}
		if render_is_busy() {
			if clay.UI(clay.ID("RenderCancelButton"))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow({}),
						height = clay.SizingFixed(BUTTON_HEIGHT),
					},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = BUTTON,
				border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
				cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
			},
			) {
				clay.Text(
					"Cancel",
					clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
				)
			}
		}
	}
	out_buf := ui_text.out[:]
	clay.Text(
		fmt.bprintf(out_buf[:], "Output: %s", render_output_name()),
		clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL, wrapMode = .Words},
	)
	switch_toggle("RenderOverwrite", "Overwrite existing output", render_output.overwrite)
	clay.Text(
		render_status_text(),
		clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL, wrapMode = .Words},
	)
}

// ---------------------------------------------------------------------------
// Shared controls.
// ---------------------------------------------------------------------------

// bar_caption is the little grey label between tool groups in the timeline bar.
bar_caption :: proc(label: string) {
	clay.Text(
		label,
		clay.TextElementConfig {
			textColor = BUTTON_BORDER,
			fontSize = FONT_SMALL,
			textAlignment = .Center,
		},
	)
}

// tool_button renders a small square-ish timeline-bar button with a text label.
tool_button :: proc(name: string, label: string) {
	if clay.UI(clay.ID(name))(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(label == "Fit" ? 38 : 30),
				height = clay.SizingFixed(BUTTON_HEIGHT),
			},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
		border = {
			color = clay.Hovered() ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = clay.BorderOutside(1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {
		clay.Text(
			label,
			clay.TextElementConfig {
				textColor = TEXT,
				fontSize = FONT_NORMAL,
				textAlignment = .Center,
			},
		)
	}
}

// v_scrollbar renders a vertical scrollbar strip for a scrollable container,
// derived from the container's scroll position plus its data/measured content
// and viewport heights (scrollbar_geometry). The strip only appears when the
// content overflows; the thumb's size and position mirror the exact geometry
// that dragging produces, so what's drawn is always what dragging yields (press
// = jump, hold = drag; main.odin routes both).
v_scrollbar :: proc(tag: string, scroll, content_h, view_h: f32) {
	max_top, thumb_h, travel := scrollbar_geometry(content_h, view_h)
	if thumb_h <= 0 || travel <= 0 {
		return
	}
	// Clay hashes id strings immediately, so one fixed stack buffer rebuilt for
	// each id is safe (no retention, no per-frame alloc).
	id_buf: [64]u8
	thumb_top := scroll / max_top * travel
	if clay.UI(clay.ID(fmt.bprintf(id_buf[:], "%sScrollbar", tag)))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(TSCROLLBAR_W), height = clay.SizingGrow({})},
			layoutDirection = .TopToBottom,
			childGap = 0,
		},
		backgroundColor = TRACK_GUTTER_BG,
	},
	) {
		if clay.UI(clay.ID(fmt.bprintf(id_buf[:], "%sSbPad", tag)))(
		{layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(thumb_top)}}},
		) {}
		if clay.UI(clay.ID(fmt.bprintf(id_buf[:], "%sSbThumb", tag)))(
		{
			layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(thumb_h)}},
			backgroundColor = clay.PointerOver(clay.ID(fmt.bprintf(id_buf[:], "%sSbThumb", tag))) ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			cornerRadius = clay.CornerRadiusAll(4),
		},
		) {}
	}
}

// tab_button renders one low-profile view-separator tab: no chrome when idle,
// a subtle highlight when it is the active view. Active state is decided by the
// caller; clicks are handled in interaction.odin (was_click block).
tab_button :: proc(id_name: string, label: string, active: bool) {
	if clay.UI(clay.ID(id_name))(
	{
		layout = {
			sizing = {width = clay.SizingFit({}), height = clay.SizingFixed(TAB_H)},
			padding = clay.Padding{left = 10, right = 10},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = active ? BUTTON_HOVER : clay.Color{0, 0, 0, 0},
		border = {
			color = active ? BUTTON_BORDER_HOVER : clay.Color{0, 0, 0, 0},
			width = clay.BorderOutside(active ? 1 : 0),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {
		clay.Text(
			label,
			clay.TextElementConfig{textColor = active ? BUTTON_BORDER_HOVER : TEXT, fontSize = FONT_SMALL},
		)
	}
}

// media_bin_tabs renders the bottom separator row of the media-bin panel:
// "Media Bin | Undo Tree".
media_bin_tabs :: proc() {
	if clay.UI(clay.ID("MediaBinTabs"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(TAB_H)},
			layoutDirection = .LeftToRight,
			childGap = 6,
			childAlignment = {x = .Left, y = .Center},
		},
		border = {color = BUTTON_BORDER, width = clay.BorderWidth{top = 1}},
	},
	) {
		tab_button("MediaTabBin", "Media Bin", panel_views.media_bin_view == .Bin)
		tab_button("MediaTabUndo", "Undo Tree", panel_views.media_bin_view == .Undo)
	}
}

// inspector_tabs renders the bottom separator row of the inspector column:
// "Clip | Project | Render".
inspector_tabs :: proc() {
	if clay.UI(clay.ID("InspectorTabs"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(TAB_H)},
			layoutDirection = .LeftToRight,
			childGap = 6,
			childAlignment = {x = .Left, y = .Center},
		},
		border = {color = BUTTON_BORDER, width = clay.BorderWidth{top = 1}},
	},
	) {
		tab_button("InspTabClip", "Clip", panel_views.inspector_view == .Clip)
		tab_button("InspTabProject", "Project", panel_views.inspector_view == .Project)
		tab_button("InspTabRender", "Render", panel_views.inspector_view == .Render)
	}
}

// settings_button renders the shared preset control: a fixed-height button that
// stays held (highlighted border + label) when active reports true. This is
// used for both mutually-exclusive presets (resolution/fps, where only the
// matching one is held) and standalone toggles (orientation, held on its own).
// fill_width stretches the button to its container's cross axis -- used for
// dropdown menu rows, which should span the full menu width instead of hugging
// their label.
settings_button :: proc(name: string, label: string, active: bool, fill_width := false) {
	width := clay.SizingFit({})
	if fill_width {
		width = clay.SizingGrow({})
	}
	if clay.UI(clay.ID(name))(
	{
		layout = {
			sizing = {width = width, height = clay.SizingFixed(BUTTON_HEIGHT)},
			padding = clay.Padding{left = BUTTON_H_PAD, right = BUTTON_H_PAD},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = BUTTON,
		border = {
			color = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = clay.BorderOutside(active ? 2 : 1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {
		clay.Text(
			label,
			clay.TextElementConfig {
				textColor = active ? BUTTON_BORDER_HOVER : TEXT,
				fontSize = FONT_NORMAL,
			},
		)
	}
}

// res_preset_button renders a resolution preset, held when it matches the
// project's current (orientation-aware) resolution.
res_preset_button :: proc(name: string, label: string, w, h: c.int) {
	active :=
		(project.width == w && project.height == h) || (project.width == h && project.height == w)
	if !project.resolution_locked && active {
		// A preset shouldn't look held when the canvas just happens to match it
		// but resolution is still on auto (picked up from the file, not chosen).
		active = false
	}
	settings_button(name, label, active)
}

// res_auto_button is the "Auto" resolution control. It stays held while the
// canvas is unlocked (resolution inferred from the next import).
res_auto_button :: proc() {
	settings_button("ResAuto", "Auto", !project.resolution_locked)
}

// switch_toggle is the shared binary control. Only the switch track owns the
// semantic ID used by input handling; the label and surrounding row are
// passive. That means clicking the text never toggles the setting -- the track
// is the only hit target. Icon rows reuse the label slot (drawn right-aligned
// up against the pill by draw_ui_icons). The row sizes to its content rather
// than growing: the control never stretches into extra space it doesn't own,
// so a toggle stays the size of its label plus its pill wherever it sits.
// switch_toggle is the shared binary control. Only the switch track owns the
// semantic ID used by input handling; the label and surrounding row are
// passive. That means clicking the text never toggles the setting -- the track
// is the only hit target. The row sizes to its content rather than growing:
// the control never stretches into extra space it doesn't own.
switch_toggle :: proc(name, label: string, active: bool) {
	row_buf: [64]u8
	label_buf: [64]u8
	knob_buf: [64]u8
	row_id := fmt.bprintf(row_buf[:], "%sSwitchRow", name)
	label_id := fmt.bprintf(label_buf[:], "%sSwitchLabel", name)
	knob_id := fmt.bprintf(knob_buf[:], "%sSwitchKnob", name)

	if clay.UI(clay.ID(row_id))(
	{
		layout = {
			sizing = {width = clay.SizingFit({}), height = clay.SizingFixed(SWITCH_H + 4)},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
			childAlignment = {x = .Left, y = .Center},
		},
	},
	) {
		if clay.UI(clay.ID(label_id))(
		{
			layout = {
				sizing = {width = clay.SizingFit({}), height = clay.SizingGrow({})},
				childAlignment = {x = .Left, y = .Center},
			},
		},
		) {
			clay.Text(
				label,
				clay.TextElementConfig{textColor = active ? TEXT : BUTTON_BORDER, fontSize = FONT_NORMAL},
			)
		}

		// The semantic ID deliberately belongs only to the switch itself. The
		// label is a sibling, so pointer/click hit testing cannot reach `name`
		// when the user clicks the text.
		if clay.UI(clay.ID(name))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(SWITCH_W), height = clay.SizingFixed(SWITCH_H)},
				padding = clay.PaddingAll(3),
				childAlignment = {x = active ? .Right : .Left, y = .Center},
			},
			backgroundColor = active ? SWITCH_TRACK_ON : TEXT_INPUT_BG,
			border = {color = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(1)},
			cornerRadius = clay.CornerRadiusAll(SWITCH_H / 2),
		},
		) {
			if clay.UI(clay.ID(knob_id))(
			{
				layout = {sizing = {width = clay.SizingFixed(SWITCH_KNOB), height = clay.SizingFixed(SWITCH_KNOB)}},
				backgroundColor = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
				cornerRadius = clay.CornerRadiusAll(SWITCH_KNOB / 2),
			},
			) {}
		}
	}
}

// settings_icon_button is a square toggle whose content is an icon, drawn into
// its center by draw_ui_icons (the element id IS the toggle name). Held states
// mirror settings_button -- border + a bg_blue fill -- so the bar's icon
// toggles read as the same control family as the text preset pills.
ICON_BUTTON_SIZE :: 26
settings_icon_button :: proc(name: string, active: bool) {
	if clay.UI(clay.ID(name))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(ICON_BUTTON_SIZE), height = clay.SizingFixed(ICON_BUTTON_SIZE)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = active ? clay.Color{58, 81, 93, 255} : BUTTON,
		border = {
			color = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = clay.BorderOutside(active ? 2 : 1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {}
}

// fps_preset_button renders a frame-rate preset, held when it matches the
// project's current fps (0 = auto).
fps_preset_button :: proc(name: string, label: string, fps: f64) {
	settings_button(name, label, project.frame_rate == fps)
}

// playback_rate_label returns the display text for a playback rate value:
// "Auto" for 0, otherwise "<rate>x". Formatted into the caller's fixed buffer
// so the per-frame dropdown labels never allocate.
playback_rate_label :: proc(rate: f64, buf: []u8) -> string {
	if rate <= 0 {
		return "Auto"
	}
	if rate == f64(int(rate)) {
		return fmt.bprintf(buf, "%dx", int(rate))
	}
	return fmt.bprintf(buf, "%.1fx", rate)
}

// playback_rate_name returns the unique element id string for a rate value
// (used both to render its button and to hit-test it on click). Rates are
// encoded by tenths: 1.5 -> "PlayRate15", 2 -> "PlayRate20", 0 -> "Auto".
// Formatted into the caller's fixed buffer (clay hashes ids immediately, so
// the buffer may be stack-local).
playback_rate_name :: proc(rate: f64, buf: []u8) -> string {
	if rate <= 0 {
		return "PlayRateAuto"
	}
	return fmt.bprintf(buf, "PlayRate%d", int(rate * 10))
}

// playback_rate_dropdown renders the rate selector beside the play button. The
// collapsed control is a button showing the current rate; clicking it toggles a
// small menu of the available rates that drops below it. Picking one sets
// playback.rate and closes the menu. Auto (0) is offered but currently behaves
// as 1x.
playback_rate_dropdown :: proc() {
	rate_border := clay.BorderOutside(1)
	if clay.UI(clay.ID("PlayRateButton"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(64), height = clay.SizingFixed(BUTTON_HEIGHT)},
			padding = clay.Padding{left = 8, right = 8},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = BUTTON,
		border = {
			color = playback.rate_open ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = rate_border,
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {
		rate_lbl := ui_text.rate[:]
		clay.Text(
			playback_rate_label(playback.rate, rate_lbl[:]),
			clay.TextElementConfig {
				textColor = playback.rate_open ? BUTTON_BORDER_HOVER : TEXT,
				fontSize = FONT_NORMAL,
			},
		)
	}
	if playback.rate_open {
		// A proper floating dropdown: the menu overlays the UI anchored just
		// below the rate button instead of expanding the surrounding layout.
		if clay.UI(clay.ID("PlayRateMenu"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(64), height = clay.SizingFit({})},
				layoutDirection = .TopToBottom,
				childGap = 2,
				padding = clay.PaddingAll(4),
			},
			backgroundColor = BUTTON,
			border = {color = BUTTON_BORDER, width = rate_border},
			cornerRadius = clay.CornerRadiusAll(4),
			floating = {
				offset = {0, 4},
				parentId = clay.ID("PlayRateButton").id,
				zIndex = 1000,
				attachment = {element = .LeftTop, parent = .LeftBottom},
				attachTo = .ElementWithId,
				pointerCaptureMode = .Capture,
				clipTo = .None,
			},
		},
		) {
			for rate, i in PLAYBACK_RATES {
				assert(i < len(ui_text.rate_menu))
				settings_button(
					playback_rate_name(rate, ui_text.rate_menu[i].name[:]),
					playback_rate_label(rate, ui_text.rate_menu[i].label[:]),
					playback.rate == rate,
					fill_width = true,
				)
			}
		}
	}
}

// jog_button renders a forward/backward jog control around the play button. It
// is held (highlighted) while playing in that direction; the label shows the
// temporary speed boost when active. dir is +1 (forward) or -1 (backward).
jog_button :: proc(name: string, dir: int) {
	active := playhead.playing && playback.dir == dir
	if clay.UI(clay.ID(name))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(56), height = clay.SizingFixed(BUTTON_HEIGHT)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = BUTTON,
		border = {
			color = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = clay.BorderOutside(active ? 2 : 1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {
		// The skip glyph is drawn as an embedded icon over this element.
	}
}

// preview_fit_button is the small toggle floating in the preview's top-right
// corner. While armed the camera is pinned to the contain-fit of the canvas
// (preview_fit_reset); panning or zooming releases it (interaction/event), so
// the held border reads whether the canvas is currently fit to the panel.
preview_fit_button :: proc() {
	active := preview_cam.fit_to_window
	if clay.UI(clay.ID("PreviewFitButton"))(
	{
		layout = {
			sizing = {width = clay.SizingFit({}), height = clay.SizingFixed(BUTTON_HEIGHT)},
			padding = clay.Padding{left = BUTTON_H_PAD, right = BUTTON_H_PAD},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
		border = {
			color = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = clay.BorderOutside(active ? 2 : 1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
		floating = {
			offset = {-PREVIEW_FIT_MARGIN, PREVIEW_FIT_MARGIN},
			parentId = clay.ID("Preview").id,
			zIndex = 100,
			attachment = {element = .RightTop, parent = .RightTop},
			attachTo = .ElementWithId,
			pointerCaptureMode = .Capture,
			clipTo = .None,
		},
	},
	) {
		clay.Text(
			"Fit",
			clay.TextElementConfig {
				textColor = active ? BUTTON_BORDER_HOVER : TEXT,
				fontSize = FONT_SMALL,
			},
		)
	}
}

// ---------------------------------------------------------------------------
// Floating context menu.
// ---------------------------------------------------------------------------

// CONTEXT_MENU_W is one option row's width. The menu box adds a 1px border and
// 2px padding on every side, so its outer right edge sits at CONTEXT_MENU_W + 6
// from the anchor, and the first row's top edge at CONTEXT_MENU_PAD + 1 from the
// anchor's y. CONTEXT_MENU_EDGE folds those two constants into the flyout's
// offset so it lands flush against the menu with no seam for the cursor.
CONTEXT_MENU_W :: 180
CONTEXT_MENU_PAD :: 2
CONTEXT_MENU_EDGE :: CONTEXT_MENU_PAD + 1 // border + padding to the first row

// CTX_SUBMENU_GRACE is how many frames the "Add >" flyout stays open after the
// cursor leaves its hover zone (the Add row + the flyout + the seam between
// them). It absorbs the one-frame clay-geometry/pointer lag on mount, so the
// flyout can't flap shut under a moving cursor that is still on its way into
// it.
CTX_SUBMENU_GRACE :: 6

// ctx_point_in reports whether (x, y) is inside a rect.
ctx_point_in :: proc(x, y: f32, r: clay.BoundingBox) -> bool {
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

// ctx_add_row_zone is the hover band of the "Add >" row EXTENDED across the
// seam flush to the flyout's left edge, so a cursor sliding from the row into
// the flyout is always inside the open zone — no dead columns between the two
// boxes for the keep-open test to trip on.
ctx_add_row_zone :: proc() -> clay.BoundingBox {
	flyout_left := ctx_menu.x + CONTEXT_MENU_W + 2 * CONTEXT_MENU_EDGE
	return clay.BoundingBox {
		x = ctx_menu.x + CONTEXT_MENU_EDGE,
		y = ctx_menu.y + CONTEXT_MENU_EDGE,
		width = flyout_left - (ctx_menu.x + CONTEXT_MENU_EDGE) + 1,
		height = BUTTON_HEIGHT,
	}
}

// ctx_flyout_rect returns the flyout's box from last frame's layout (zero when
// the flyout is not mounted — callers gate on ctx_menu.submenu).
ctx_flyout_rect :: proc() -> clay.BoundingBox {
	return clay.GetElementData(clay.ID("CtxSubmenu")).boundingBox
}

// ctx_popup_hover reports whether the cursor is inside the floating popup: the
// menu box or, when it is mounted, the Add flyout box. Geometry-based against
// the last frame's rects rather than clay.PointerOver, so tests work the frame
// an element first mounts and never carry clay's one-frame hover lag.
ctx_popup_hover :: proc(x, y: f32) -> bool {
	if ctx_point_in(x, y, clay.GetElementData(clay.ID("CtxMenu")).boundingBox) {
		return true
	}
	if ctx_menu.submenu {
		return ctx_point_in(x, y, ctx_flyout_rect())
	}
	return false
}

// CTX_ROW_GAP is the 1px gutter between context-menu rows (draw_context_menu's
// childGap). It is part of the row geometry, so click/hover tests that resolve
// a row from the container box must agree with it.
CTX_ROW_GAP :: 1

// ctx_row_rect is row `index` within a context-menu container box: the rows
// stack at BUTTON_HEIGHT tall with CTX_ROW_GAP gutters, inset left/right/top
// by CONTEXT_MENU_EDGE (border + padding), exactly as draw_context_menu lays
// them out.
ctx_row_rect :: proc(box: clay.BoundingBox, index: int) -> clay.BoundingBox {
	return clay.BoundingBox {
		x = box.x + CONTEXT_MENU_EDGE,
		y = box.y + CONTEXT_MENU_EDGE + f32(index) * (BUTTON_HEIGHT + CTX_ROW_GAP),
		width = CONTEXT_MENU_W,
		height = BUTTON_HEIGHT,
	}
}

// ctx_row_hit returns the index of the menu row under (x, y) within `box`, or
// -1. The 1px row gutters resolve to the row BELOW them (so a click on a seam
// still acts on the row under it).
ctx_row_hit :: proc(x, y: f32, box: clay.BoundingBox) -> int {
	if ctx_point_in(x, y, box) == false {
		return -1
	}
	at_y := y - (box.y + CONTEXT_MENU_EDGE)
	if at_y < 0 {
		return -1
	}
	i := int(at_y / (BUTTON_HEIGHT + CTX_ROW_GAP))
	if i < 0 || i > 7 {
		return -1
	}
	if ctx_point_in(x, y, ctx_row_rect(box, i)) == false &&
	   at_y - f32(i) * (BUTTON_HEIGHT + CTX_ROW_GAP) >= BUTTON_HEIGHT {
		// Cursor in the gutter between row i and i+1: fold it down to i+1 when
		// that row exists and is under the cursor.
		if i + 1 <= 7 && ctx_point_in(x, y, ctx_row_rect(box, i + 1)) {
			return i + 1
		}
		return -1
	}
	return i
}

// ctx_option renders one row (option) of the floating timeline context menu.
// Rows are borderless and highlight as a solid band on hover so the menu reads
// as one widget, not a grid of cells.
// ctx_option renders one menu row. `width` defaults to the timeline menu's
// width; the dedicated track menu passes its own (longer labels).
ctx_option :: proc(id_name: string, label: string, width: f32 = CONTEXT_MENU_W) {
	hover := clay.PointerOver(clay.ID(id_name))
	if clay.UI(clay.ID(id_name))(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(width),
				height = clay.SizingFixed(BUTTON_HEIGHT),
			},
			padding = clay.Padding{left = BUTTON_H_PAD, right = BUTTON_H_PAD},
			childAlignment = {x = .Left, y = .Center},
		},
		backgroundColor = hover ? BUTTON_HOVER : BUTTON,
		cornerRadius = clay.CornerRadiusAll(0),
	},
	) {
		clay.Text(
			label,
			clay.TextElementConfig {
				textColor = hover ? BUTTON_BORDER_HOVER : TEXT,
				fontSize = FONT_NORMAL,
			},
		)
	}
}

// ctx_add_row renders the "Add >" row that opens the submenu when hovered (or
// clicked). It is highlighted while hovered AND while the submenu is showing
// (so the parent row stays lit while the cursor sits in the flyout).
ctx_add_row :: proc() {
	hover := clay.PointerOver(clay.ID("CtxAdd")) || ctx_menu.submenu
	if clay.UI(clay.ID("CtxAdd"))(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(CONTEXT_MENU_W),
				height = clay.SizingFixed(BUTTON_HEIGHT),
			},
			padding = clay.Padding{left = BUTTON_H_PAD},
			childAlignment = {x = .Left, y = .Center},
		},
		backgroundColor = hover ? BUTTON_HOVER : BUTTON,
		cornerRadius = clay.CornerRadiusAll(0),
	},
	) {
		clay.Text(
			"Add",
			clay.TextElementConfig {
				textColor = hover ? BUTTON_BORDER_HOVER : TEXT,
				fontSize = FONT_NORMAL,
			},
		)
		if clay.UI(clay.ID("CtxAddChevron"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(BUTTON_HEIGHT)},
				childAlignment = {x = .Right, y = .Center},
			},
		},
		) {
			clay.Text(
				">",
				clay.TextElementConfig {
					textColor = hover ? BUTTON_BORDER_HOVER : TEXT,
					fontSize = FONT_NORMAL,
				},
			)
		}
	}
}

// draw_context_menu renders the right-click menu over the timeline as a
// floating overlay anchored at the pointer. Over empty space it offers "Add";
// right-clicking ON a clip adds clip actions (Rename/Duplicate/Delete/Link).
// The "Add >" row expands a flyout submenu positioned flush against its right
// edge (CONTEXT_MENU_W + the menu's 2px padding), listing the clip kinds. The
// flyout is a Root-attached overlay drawn at a fixed offset — never attached to
// the per-frame CtxAdd element, whose clay attach pass would lag a frame and
// make the flyout pop/flicker on the frame it appears. Menu item clicks are
// dispatched by the main loop (handle_ctx_option).
draw_context_menu :: proc() {
	if !ctx_menu.open {
		return
	}
	ctx_border := clay.BorderOutside(1)
	if clay.UI(clay.ID("CtxMenu"))(
	{
		layout = {
			sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})},
			layoutDirection = .TopToBottom,
			childGap = CTX_ROW_GAP,
			padding = clay.PaddingAll(CONTEXT_MENU_PAD),
		},
		backgroundColor = BUTTON,
		border = {color = BUTTON_BORDER, width = ctx_border},
		cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
		floating = {
			offset = {ctx_menu.x, ctx_menu.y},
			zIndex = 2000,
			attachTo = .Root,
			pointerCaptureMode = .Capture,
		},
	},
	) {
		ctx_add_row()
		if ctx_menu.target_clip_track >= 0 && ctx_menu.target_clip_track < len(timeline.tracks) {
			// Right-clicked a clip: offer clip-specific actions.
			clipped := &timeline.tracks[ctx_menu.target_clip_track].clips[ctx_menu.target_clip_index]
			ctx_option("CtxRename", "Rename")
			ctx_option("CtxDuplicate", "Duplicate")
			if clipped.link_id != 0 {
				ctx_option("CtxLink", "Unlink")
			} else {
				ctx_option("CtxLink", "Link")
			}
			ctx_option("CtxDelete", "Delete")
		}
	}
	// Flyout submenu to the right of the "Add >" row, shown while hovered.
	if ctx_menu.submenu {
		if clay.UI(clay.ID("CtxSubmenu"))(
		{
			layout = {
				sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})},
				layoutDirection = .TopToBottom,
				childGap = CTX_ROW_GAP,
				padding = clay.PaddingAll(CONTEXT_MENU_PAD),
			},
			backgroundColor = BUTTON,
			border = {color = BUTTON_BORDER, width = ctx_border},
			cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
			floating = {
				offset = {
					ctx_menu.x + CONTEXT_MENU_W + 2 * CONTEXT_MENU_EDGE,
					ctx_menu.y + CONTEXT_MENU_EDGE,
				},
				zIndex = 2001,
				attachTo = .Root,
				clipTo = .None,
			},
		},
		) {
			ctx_option("CtxTextClip", "Text Clip")
			ctx_option("CtxSubtitleClip", "Subtitle Clip (.srt)")
		}
	}
}

// draw_track_action_menu renders the dedicated track menu (right-click on a
// track's name gutter) as a floating overlay. It is a separate popup from
// draw_context_menu on purpose: that one acts on clips and the frame under the
// cursor, this one acts on a whole track. Row order must match
// handle_track_action_option: 0 Duplicate, 1 Delete.
draw_track_action_menu :: proc() {
	if !track_ctx.open {
		return
	}
	if clay.UI(clay.ID("TrackMenu"))(
	{
		layout = {
			sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})},
			layoutDirection = .TopToBottom,
			childGap = CTX_ROW_GAP,
			padding = clay.PaddingAll(CONTEXT_MENU_PAD),
		},
		backgroundColor = BUTTON,
		border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
		cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
		floating = {
			offset = {track_ctx.x, track_ctx.y},
			zIndex = 2000,
			attachTo = .Root,
			pointerCaptureMode = .Capture,
		},
	},
	) {
		ctx_option("TrackMenuDuplicate", "Duplicate Track", TRACK_MENU_W)
		ctx_option("TrackMenuDelete", "Delete Track", TRACK_MENU_W)
	}
}

// ---------------------------------------------------------------------------
// Help overlay ("?" / F1).
// ---------------------------------------------------------------------------
// Help_Shortcut is one row of the help overlay: the key(s) and what they do.
Help_Shortcut :: struct {
	key:    string,
	action: string,
}

HELP_SHORTCUTS :: []Help_Shortcut {
	{"Space", "Play / pause"},
	{"H / L", "Jog backward / forward"},
	{"I / O", "Set render-range start / end at the playhead"},
	{"S", "Split clip at playhead"},
	{"A", "Keyframe every modified property on the selected clip"},
	{"Ctrl+R", "Rename selected clip"},
	{":", "Command line (:open <file>)"},
	{"U", "Link / unlink selection"},
	{"Backspace", "Delete (ripple) selected clip or group"},
	{"Delete", "Delete selected clip (raw)"},
	{"Right-click track name", "Track menu (duplicate / delete track)"},
	{"Right-click clip lane", "Add clip, or clip actions on the clip under the cursor"},
	{"Esc", "Dismiss menu / dialog"},
	{"F1 / ?", "Toggle this overlay"},
	{"Media Bin tabs", "Switch between the media grid and the undo tree"},
	{"Inspector tabs", "Switch between clip, project and render views"},
	{"Ctrl+Z", "Undo (move up the undo tree)"},
	{"Ctrl+Shift+Z / Ctrl+Y", "Redo (move down the undo tree)"},
	{"Wheel over ruler/timeline", "Zoom about the playhead"},
	{"Wheel over track lanes", "Scroll the track list"},
	{"Drag timeline scrollbar", "Scroll the track list"},
	{"Middle-drag timeline", "Pan"},
	{"Alt+drag a handle", "Crop the selected box"},
	{"Alt+Wheel over preview", "Crop-zoom the selected clip (box stays put)"},
	{"Alt+Middle-drag preview", "Crop-pan the selected clip (box stays put)"},
	{"Shift+drag a handle", "Scale from center"},
}

// help_entry renders a single key/action row of the help overlay. The key gets
// the highlight color so the two columns scan as columns.
help_entry :: proc(shortcut: Help_Shortcut) {
	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = CARD_GAP,
			childAlignment = {x = .Left, y = .Center},
		},
	},
	) {
		clay.Text(
			shortcut.key,
			clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_NORMAL},
		)
		clay.Text(
			shortcut.action,
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL},
		)
	}
}

// draw_help_overlay renders the keyboard-shortcut reference as a centered
// floating panel. Dismissed by clicking outside it, by the "?" button, by F1,
// or by Esc.
draw_help_overlay :: proc(width, height: c.int) {
	if !editor_flags.help_open {
		return
	}
	pw := min(f32(560), f32(width) * 0.9)
	px := (f32(width) - pw) / 2
	py := f32(height) * 0.1
	if clay.UI(clay.ID("HelpPanel"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(pw), height = clay.SizingFit({})},
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
			zIndex = 300,
			attachTo = .Root,
			pointerCaptureMode = .Capture,
		},
	},
	) {
		clay.Text(
			"Keyboard Shortcuts",
			clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_HEADING},
		)
		clay.Text(
			"F1 or the ? button toggles this overlay; Esc or a click outside closes it.",
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
		)
		for i := 0; i < len(HELP_SHORTCUTS); i += 2 {
			if clay.UI()(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
					layoutDirection = .LeftToRight,
					childGap = SECTION_GAP,
				},
			},
			) {
				shortcuts := HELP_SHORTCUTS
				help_entry(shortcuts[i])
				if i + 1 < len(shortcuts) {
					help_entry(shortcuts[i + 1])
				}
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Text-input dialog.
// ---------------------------------------------------------------------------

// draw_text_input_popup renders the generic modal text-input dialog as a
// floating overlay centered in the window when the text field is active. It is a
// deliberately plain panel holding a raw input field; typing/selection/caret are
// handled by the textinput module and drawn by draw_text_input_caret.
draw_text_input_popup :: proc(width, height: c.int) {
	if !ti.active {
		return
	}
	// The ":" command line is a separate, flatter prompt than the dialog-style
	// rename/time fields — delegate it so its pill bar doesn't inherit the
	// dialog chrome.
	if ti.input_type == TI_CMDLINE {
		draw_cmdline_popup(width, height)
		return
	}
	if ti.input_type == TI_FINDER {
		draw_finder_popup(width, height)
		return
	}
	// Responsive: the popup is at most 460px wide but never wider than 80% of
	// the window, and its height fits its content. Positioned centered
	// horizontally, roughly a third from the top.
	pw := min(f32(460), f32(width) * 0.8)
	px := (f32(width) - pw) / 2
	py := f32(height) * 0.3
	title := "Edit Text"
	if ti.input_type == TI_RENAME {
		title = "Rename Clip"
	} else if ti.input_type == TI_PLAYHEAD {
		title = "Go to Time"
	}
	if clay.UI(clay.ID("TextInputPopup"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(pw), height = clay.SizingFit({})},
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
			zIndex = 3000,
			attachTo = .Root,
			pointerCaptureMode = .Capture,
		},
	},
	) {
		hint_buf := ui_text.hint[:]
		clay.Text(
			fmt.bprintf(hint_buf[:], "%s — Enter to confirm, Esc to cancel", title),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
		)
		if ti.input_type == TI_PLAYHEAD {
			clay.Text(
				"timecode 1:23:45:06 · seconds 12.5 · frames 1234",
				clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_SMALL},
			)
		}
		if clay.UI(clay.ID("TextInputField"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(34)},
				padding = clay.Padding{left = CARD_GAP, right = CARD_GAP},
				childAlignment = {x = .Left, y = .Center},
			},
			backgroundColor = TEXT_INPUT_BG,
			border = {color = BUTTON_BORDER_HOVER, width = clay.BorderOutside(1)},
			cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
		},
		) {
			if len(ti.buf) > 0 {
				clay.Text(
					text_input_string(),
					clay.TextElementConfig{textColor = TEXT, fontSize = TEXT_INPUT_FONT},
				)
			}
		}
	}
}

// draw_cmdline_popup renders the vim-style ":" prompt: a search-bar-shaped pill
// centered in the window, half the window's width, one font-height tall plus
// half a font of vertical padding, with a fully-round accent border. The colon
// is literal; while the buffer is empty the last committed command shows
// dimmed as the placeholder. When the buffer is `open <query>`, a fuzzy file
// match list (cwd-relative paths) drops down below the pill; the highlighted
// row is set by Tab/Shift+Tab/Up/Down and committed by Enter. Drawn via clay
// floating so it sits above the preview like the other overlays; the caret
// rides the same TextInputField id the dialog uses, so draw_text_input_caret
// just works.
draw_cmdline_popup :: proc(width, height: c.int) {
	fh := f32(TEXT_INPUT_FONT)
	pad_v := fh * CMDLINE_PAD_FRAC
	placeholder := "last ran command"
	bw := f32(width) * CMDLINE_WIDTH_FRAC
	bx := (f32(width) - bw) / 2
	bh := fh + pad_v * 2
	// Stable, cache-aware match list; the whole block (pill + rows) is
	// centered so a tall list doesn't push off the bottom.
	cmdline_match_refresh()
	n := min(len(cmdline_match_state.matches), CMDLINE_MATCH_MAX)
	row_h := f32(FONT_NORMAL) + 9
	list_gap: u16 = 6
	list_h := f32(n) * row_h
	block_h := bh + (f32(list_gap) if n > 0 else 0) + list_h
	by := (f32(height) - block_h) / 2
	if clay.UI(clay.ID("CmdlineColumn"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(bw), height = clay.SizingFixed(block_h)},
			layoutDirection = .TopToBottom,
			childGap = list_gap,
		},
		floating = {
			offset = {bx, by},
			zIndex = 3000,
			attachTo = .Root,
			pointerCaptureMode = .Capture,
		},
	},
	) {
		if clay.UI(clay.ID("CmdlinePopup"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(bh)},
				layoutDirection = .LeftToRight,
				childAlignment = {x = .Left, y = .Center},
				childGap = CARD_GAP,
				padding = clay.Padding{left = PANEL_PADDING, right = PANEL_PADDING},
			},
			backgroundColor = TEXT_INPUT_BG,
			border = {color = BUTTON_BORDER_HOVER, width = clay.BorderOutside(1)},
			cornerRadius = clay.CornerRadiusAll(bh / 2),
		},
		) {
			clay.Text(":", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = TEXT_INPUT_FONT})
			text := placeholder
			col := CMDLINE_PLACEHOLDER
			if len(ti.buf) > 0 {
				text = text_input_string()
				col = TEXT
			}
			if clay.UI(clay.ID("TextInputField"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
					// CARD_GAP side padding matches draw_text_input_caret's
					// text_x = box.x + CARD_GAP, so the caret lands on the text.
					padding = clay.Padding{left = CARD_GAP, right = CARD_GAP},
					childAlignment = {x = .Left, y = .Center},
				},
			},
			) {
				clay.Text(text, clay.TextElementConfig{textColor = col, fontSize = TEXT_INPUT_FONT})
			}
		}
		if n > 0 {
			if clay.UI(clay.ID("CmdlineMatches"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(list_h)},
					layoutDirection = .TopToBottom,
					childGap = 2,
				},
			},
			) {
				for i in 0 ..< n {
					sel := i == cmdline_match_state.sel
					if clay.UI(clay.ID("CmdlineMatchRow", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(row_h)},
							padding = clay.Padding{left = CARD_GAP, right = CARD_GAP},
							childAlignment = {x = .Left, y = .Center},
						},
						backgroundColor = sel ? BUTTON_BORDER_HOVER : BUTTON,
						border = {color = sel ? BUTTON_BORDER : BUTTON_BORDER, width = clay.BorderOutside(1)},
						cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
					},
					) {
						m := cmdline_match_state.matches[i]
						runs: [CMDLINE_QUERY_MAX][2]int
						nr := cmdline_match_matched_runs(m.path, runs[:])
						seg_start := 0
						for r in 0 ..< nr {
							seg := runs[r]
							if seg.x > seg_start {
								col := sel ? BACKGROUND : TEXT
								clay.Text(m.path[seg_start:seg.x], clay.TextElementConfig{textColor = col, fontSize = FONT_NORMAL})
							}
							col := sel ? BACKGROUND : BUTTON_BORDER_HOVER
							clay.Text(m.path[seg.x:seg.x + seg.y], clay.TextElementConfig{textColor = col, fontSize = FONT_NORMAL})
							seg_start = seg.x + seg.y
						}
						if seg_start < len(m.path) {
							col := sel ? BACKGROUND : TEXT
							clay.Text(m.path[seg_start:], clay.TextElementConfig{textColor = col, fontSize = FONT_NORMAL})
						}
					}
				}
			}
		}
	}
}

// draw_finder_popup renders the in-app file finder: a wide floating column
// with the filter field on top (the same TextInputField id the dialog uses,
// so draw_text_input_caret just works) and the current directory's listing
// beneath it as icon + name rows. The current directory shows dimmed under the
// field. Row icons/thumbnails paint in the overdraw pass (draw_finder_rows)
// because the icon textures are GPU-side; here the rows are only cells with
// ids the overdraw looks up.
draw_finder_popup :: proc(width, height: c.int) {
	finder_refresh()
	row_h := f32(FONT_NORMAL) + 9
	finder_width := f32(min(720, int(f32(width) * 0.92)))
	visible := min(FINDER_MAX_ROWS, len(file_finder.filtered))
	list_h := f32(visible) * row_h
	field_h := f32(TEXT_INPUT_FONT) + f32(TEXT_INPUT_FONT) * CMDLINE_PAD_FRAC * 2
	dir_h := f32(FONT_SMALL) + 4
	list_gap: u16 = 4
	block_h := dir_h + field_h + f32(list_gap) * 2 + list_h
	block_w := finder_width
	px := (f32(width) - block_w) / 2
	py := (f32(height) - block_h) / 2
	if clay.UI(clay.ID("FinderColumn"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(block_w), height = clay.SizingFixed(block_h)},
			layoutDirection = .TopToBottom,
			childGap = list_gap,
			padding = clay.Padding{left = 8, right = 8, top = 8, bottom = 8},
		},
		floating = {
			offset = {px, py},
			zIndex = 3000,
			attachTo = .Root,
			pointerCaptureMode = .Capture,
		},
	},
	) {
		dir_buf := ui_text.finder_dir[:]
		clay.Text(
			fmt.bprintf(dir_buf[:], "▸ %s", file_finder.cwd),
			clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_SMALL},
		)
		if clay.UI(clay.ID("TextInputField"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(field_h)},
				// CARD_GAP side padding matches draw_text_input_caret's
				// text_x = box.x + CARD_GAP, so the caret lands on the text.
				padding = clay.Padding{left = CARD_GAP, right = CARD_GAP},
				childAlignment = {x = .Left, y = .Center},
			},
			backgroundColor = TEXT_INPUT_BG,
			border = {color = BUTTON_BORDER_HOVER, width = clay.BorderOutside(1)},
			cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
		},
		) {
			text := "filter files…"
			if file_finder.mode == .Save {
				// Save mode types a name, not a query: say so, or the
				// unfiltered list below reads as a broken filter. The suggested
				// name is a PLACEHOLDER, not field text — real text would make
				// the very first Enter a save, and Enter on ".." must still
				// descend until the user has actually typed a name.
				text = finder_default_save_name(ui_text.finder_save_hint[:])
			}
			col := CMDLINE_PLACEHOLDER
			if len(ti.buf) > 0 {
				text = text_input_string()
				col = TEXT
			}
			clay.Text(text, clay.TextElementConfig{textColor = col, fontSize = TEXT_INPUT_FONT})
		}
		if visible > 0 {
			if clay.UI(clay.ID("FinderRows"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(list_h)},
					layoutDirection = .TopToBottom,
					childGap = 2,
				},
			},
			) {
				for r in 0 ..< visible {
					ri := file_finder.scroll + r
					sel := ri == file_finder.sel
					if clay.UI(clay.ID("FinderRow", u32(ri)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(row_h)},
							layoutDirection = .LeftToRight,
							childGap = 6,
							padding = clay.Padding{left = CARD_GAP, right = CARD_GAP},
							childAlignment = {x = .Left, y = .Center},
						},
						backgroundColor = sel ? BUTTON_BORDER_HOVER : BUTTON,
						border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
						cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
					},
					) {
						// The icon/thumbnail cell: the overdraw pass paints the
						// finder icon (or a media-bin thumbnail) into this box.
						clay.UI(clay.ID("FinderRowIcon", u32(ri)))(
						{
							layout = {
								sizing = {width = clay.SizingFixed(row_h - 6), height = clay.SizingFixed(row_h - 6)},
							},
						},
						)
						entry := file_finder.entries[file_finder.filtered[ri]]
						col := sel ? BACKGROUND : TEXT
						if entry.is_symlink {
							clay.Text(
								fmt.bprintf(ui_text.finder_sym[:], "%s ↪", entry.name),
								clay.TextElementConfig{textColor = col, fontSize = FONT_NORMAL},
							)
						} else {
							clay.Text(entry.name, clay.TextElementConfig{textColor = col, fontSize = FONT_NORMAL})
						}
					}
				}
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Media bin panel.
// ---------------------------------------------------------------------------

// kind_name returns a short label for a media kind (bin display).
kind_name :: proc(kind: Media_Kind) -> string {
	#partial switch kind {
	case .Video:
		return "video"
	case .Audio:
		return "audio"
	case .Image:
		return "image"
	case .Empty:
		return "empty"
	case .Text:
		return "text"
	case .Subtitles:
		return "subtitles"
	case:
		return "other"
	}
}

// media_bin_header renders the "Media Bin" title and the Import button.
media_bin_header :: proc() {
	if clay.UI(clay.ID("MediaBinHeader"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
			childAlignment = {x = .Center, y = .Center},
		},
	},
	) {
		clay.Text(
			"Media Bin",
			clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_SMALL},
		)
		if clay.UI(clay.ID("BinImportButton"))(
		{
			layout = {
				sizing = {
					width = clay.SizingFixed(f32(BUTTON_HEIGHT) * 2),
					height = clay.SizingFixed(f32(BUTTON_HEIGHT)),
				},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
			border = {
				color = clay.Hovered() ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
				width = clay.BorderOutside(1),
			},
			cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
		},
		) {
			clay.Text(
				"Import",
				clay.TextElementConfig {
					textColor = clay.Hovered() ? BUTTON_BORDER_HOVER : TEXT,
					fontSize = FONT_NORMAL,
				},
			)
		}
	}
}

// media_bin_grid lays out the imported assets as a wrapped thumbnail grid
// inside a manually-scrolled clip (childOffset = -panel_views.media_bin_scroll, matching
// the TracksSection pattern). Column count derives from the bin width; rows
// wrap once the cells exceed it.
media_bin_grid :: proc() {
	if len(media_bin.assets) == 0 {
		clay.Text(
			"No media imported",
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL},
		)
		return
	}
	cols := media_bin_cols()
	total_rows := (len(media_bin.assets) + cols - 1) / cols
	if clay.UI(clay.ID("MediaBinScroll"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			layoutDirection = .TopToBottom,
			childGap = CARD_GAP,
		},
		clip = {vertical = true, childOffset = {0, -panel_views.media_bin_scroll}},
	},
	) {
		for row in 0 ..< total_rows {
			if clay.UI(clay.ID("MediaRow", u32(row)))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow({}),
						height = clay.SizingFixed(media_bin_row_height()),
					},
					layoutDirection = .LeftToRight,
					childGap = CARD_GAP,
				},
			},
			) {
				base := row * cols
				for i in base ..< min(base + cols, len(media_bin.assets)) {
					media_bin_item(i)
				}
			}
		}
	}
}

// media_bin_item renders one grid cell: a thumbnail area (drawn over by
// mediabin.odin after layout) plus the asset basename. Selection shows a
// spring-green border.
media_bin_item :: proc(index: int) {
	asset := &media_bin.assets[index]
	selected := asset.id == selection.asset_id
	if clay.UI(clay.ID("MediaItem", u32(index)))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(MEDIA_CELL_W), height = clay.SizingGrow({})},
			padding = clay.PaddingAll(u16(MEDIA_ITEM_PAD)),
			layoutDirection = .TopToBottom,
			childGap = u16(4),
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
		border = {
			color = selected ? SELECT_BORDER : BUTTON_BORDER,
			width = clay.BorderOutside(selected ? 2 : 1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
	},
	) {
		if !clay.UI(clay.ID("MediaItemThumb", u32(index)))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(MEDIA_THUMB_H)},
			},
			backgroundColor = clay.Color{61, 72, 77, 255},
			cornerRadius = clay.CornerRadiusAll(4),
		},
		) {
		}
		clay.Text(
			path_basename(asset.path),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
		)
	}
}


// Timeline panel body: the empty-state import entry point when there are no
// tracks, otherwise the ruler + track lanes + bottom snap/zoom bar. Clay keeps
// appending to the layout build_page began, so this is a straight code move.
build_timeline :: proc(default_border: clay.BorderWidth) {
	if len(timeline.tracks) == 0 {
		// Empty timeline: the import entry point plus its alternatives.
		if clay.UI(clay.ID("EmptyTimeline"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				layoutDirection = .TopToBottom,
				childGap = CARD_GAP,
				childAlignment = {x = .Center, y = .Center},
			},
		},
		) {
			if clay.UI(clay.ID("OpenFileButton"))(
			{
				layout = {
					sizing = {
						width = clay.SizingFixed(220),
						height = clay.SizingFixed(56),
					},
					padding = clay.PaddingAll(TIMELINE_PADDING),
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = BUTTON,
				cornerRadius = clay.CornerRadiusAll(RADIUS_CONTAINER),
				border = {color = BUTTON_BORDER, width = default_border},
			},
			) {
				clay.Text(
					"Open file",
					clay.TextElementConfig {
						textColor = TEXT,
						fontSize = FONT_HEADING,
						textAlignment = .Center,
					},
				)
			}
		}
	} else {
		if clay.UI(clay.ID("ClipTimeline"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				padding = clay.PaddingAll(TIMELINE_PADDING),
				layoutDirection = .TopToBottom,
				childGap = CARD_GAP,
			},
			backgroundColor = BUTTON,
			cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
			border = {color = BUTTON_BORDER, width = default_border},
		},
		) {
			// Timing ruler bar: mirrors the track rows' left gutter so its
			// x-origin (frame 0) aligns exactly with the clip lanes.
			if clay.UI(clay.ID("RulerRow"))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow({}),
						height = clay.SizingFixed(RULER_HEIGHT),
					},
					layoutDirection = .LeftToRight,
					childGap = SECTION_GAP,
				},
			},
			) {
				if clay.UI(clay.ID("RulerGutter"))(
				{
					layout = {
						sizing = {
							width = clay.SizingFixed(GUTTER_WIDTH),
							height = clay.SizingGrow({}),
						},
					},
					backgroundColor = TRACK_GUTTER_BG,
				},
				) {
					// Playhead time viewer: the timecode badge sits in the
					// empty top-left corner above the track-name gutters and
					// before the ruler. Clicking it opens numeric navigation
					// (begin_playhead_time_edit) to jump the playhead.
					if clay.UI(clay.ID("PlayheadTime"))(
					{
						layout = {
							sizing = {
								width = clay.SizingGrow({}),
								height = clay.SizingGrow({}),
							},
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = clay.Hovered() ? BUTTON_HOVER : TRACK_GUTTER_BG,
					},
					) {
						clay.Text(
							playhead_timecode(),
							clay.TextElementConfig {
								textColor = TEXT,
								fontSize = FONT_SMALL,
								textAlignment = .Center,
							},
						)
					}
				}
				if clay.UI(clay.ID("Ruler"))(
				{
					layout = {
						sizing = {
							width = clay.SizingGrow({}),
							height = clay.SizingGrow({}),
						},
					},
					backgroundColor = EDITOR_BG,
					border = {color = BUTTON_BORDER, width = default_border},
					cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
				},
				) {}
			}
			// The track list lives in its own scroll viewport. TrackArea
			// holds the scrollable lanes (TracksSection) plus the vertical
			// scrollbar strip, so the scroll geometry is one clean unit
			// beside the fixed ruler strip above it.
			if clay.UI(clay.ID("TrackArea"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
					layoutDirection = .LeftToRight,
					childGap = 0,
				},
			},
			) {
				if clay.UI(clay.ID("TracksSection"))(
				{
					layout = {
						sizing = {
							width = clay.SizingGrow({}),
							height = clay.SizingGrow({}),
						},
						layoutDirection = .TopToBottom,
						childGap = 0,
					},
					clip = {vertical = true, childOffset = {0, -timeline_view.top}},
				},
				) {
					sync_track_order()
					for r := 0; r <= len(timeline.track_order); r += 1 {
						// Insert gap above each track: the "Add track"
						// button is limited to the gutter column, and the
						// strip's remaining space carries the track's
						// point-marker triangles (drawn by
						// draw_clip_markers). gap/add-track IDs are
						// keyed by ORDER position r (insert_track uses
						// the position to place the new row).
						gap_id := clay.ID("TrackGap", u32(r))
						button_id := clay.ID("AddTrack", u32(r))
						button_hovered := clay.PointerOver(button_id)
						if clay.UI(gap_id)(
						{
							layout = {
								sizing = {
									width = clay.SizingGrow({}),
									height = clay.SizingFixed(TRACK_GAP_H),
								},
								layoutDirection = .LeftToRight,
								childGap = 0,
							},
						},
						) {
							if clay.UI(button_id)(
							{
								layout = {
									sizing = {
										width = clay.SizingFixed(GUTTER_WIDTH),
										height = clay.SizingGrow({}),
									},
									childAlignment = {x = .Center, y = .Center},
								},
								backgroundColor = button_hovered ? clay.Color{58, 81, 93, 255} : EDITOR_BG,
								cornerRadius = clay.CornerRadiusAll(3),
							},
							) {
								if button_hovered {
									clay.Text(
										"+ Add track",
										clay.TextElementConfig {
											textColor = BUTTON_BORDER_HOVER,
											fontSize = FONT_NORMAL,
										},
									)
								}
							}
						}
					if r >= len(timeline.track_order) {
						break
					}
					ti := timeline.track_order[r]
					track := &timeline.tracks[ti]
					keyframe_rows := keyframe_rows_for(track)
					if clay.UI(clay.ID("TrackRow", u32(ti)))(
					{
						layout = {
							sizing = {
								width = clay.SizingGrow({}),
								height = clay.SizingFixed(TRACK_ROW_H + f32(keyframe_rows) * KF_ROW_H),
							},
							layoutDirection = .LeftToRight,
							childGap = SECTION_GAP,
						},
					},
					) {
						if clay.UI(clay.ID("TrackName", u32(ti)))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(GUTTER_WIDTH),
									height = clay.SizingGrow({}),
								},
								layoutDirection = .TopToBottom,
								childGap = 4,
								childAlignment = {x = .Left, y = .Top},
							},
							backgroundColor = TRACK_GUTTER_BG,
						},
						) {
							clay.Text(
								track.name,
								clay.TextElementConfig {
									textColor = TEXT,
									fontSize = FONT_HEADING,
								},
							)
							// No per-track buttons here: duplicate/delete moved
							// to the track menu (right-click the gutter), which
							// keeps the row short enough to fit more tracks.
							if keyframe_rows > 0 {
								// Keyframe property labels: one KF_ROW_H line per
								// visible lane, stacked under the buttons so they
								// line up with the diamond lanes beside them.
								keyframe_names: [32]string
								keyframe_count := keyframe_gutter_names(track, keyframe_rows, keyframe_names[:])
								if clay.UI(clay.ID("KeyframeGutterNames", u32(ti)))(
								{
									layout = {
										sizing = {
											width = clay.SizingGrow({}),
											height = clay.SizingFit({}),
										},
										layoutDirection = .TopToBottom,
									},
								},
								) {
									for i in 0 ..< keyframe_count {
										if clay.UI(clay.ID("KeyframeGutterName", u32(ti * 1000 + i)))(
										{
											layout = {
												sizing = {
													width = clay.SizingGrow({}),
													height = clay.SizingFixed(KF_ROW_H),
												},
												childAlignment = {x = .Left, y = .Center},
											},
										},
										) {
											clay.Text(
												keyframe_names[i],
												clay.TextElementConfig {
													textColor = RULER_LABEL_COLOR,
													fontSize = FONT_SMALL,
												},
											)
										}
									}
								}
							}
						}
						if clay.UI(clay.ID("ClipsSection", u32(ti)))(
						{
							layout = {
								sizing = {
									width = clay.SizingGrow({}),
									height = clay.SizingGrow({}),
								},
								layoutDirection = .LeftToRight,
							},
							backgroundColor = EDITOR_BG,
							clip = {
								horizontal = true,
								vertical = true,
								childOffset = {
									-timeline_view.start * timeline_view.zoom,
									0,
								},
							},
						},
						) {
							clips_content_x: f32 = 0
							for &timeline_clip, index in track.clips {
								target_x :=
									f32(timeline_clip.timeline_start_frame) *
									timeline_view.zoom
								if target_x > clips_content_x {
									spacer_w := target_x - clips_content_x
									clips_content_x = target_x
									clay.UI(
										clay.ID(
											"ClipOffset",
											u32(ti * 1000 + index),
										),
									)(
										{
											layout = {
												sizing = {
													width = clay.SizingFixed(spacer_w),
													height = clay.SizingGrow({}),
												},
											},
										},
									)
								}
								clip_width :=
									f32(max(timeline_clip.source_length_frames, 1)) *
									timeline_view.zoom
								clip_color := BUTTON
								clip_border := BUTTON_BORDER
								clip_border_w: u16 = 2
								clip_label := clip_name(&timeline_clip)
								if timeline_clip.kind == .Audio {
									clip_color = AUDIO_CLIP
									if clip_label == "" {
										clip_label = "Audio"
									}
								} else if clip_label == "" {
									clip_label = "Clip"
								}
								if ti == selection.track &&
								   index == selection.index {
									clip_border = SELECT_BORDER
									clip_border_w = 3
								} else if is_clip_selected(ti, index) {
									if timeline_clip.link_id != 0 {
										clip_border = MARKER_COLOR
									} else {
										clip_border = SELECT_BORDER
									}
									clip_border_w = 3
								}
								next_touches :=
									index + 1 < len(track.clips) &&
									track.clips[index + 1].timeline_start_frame ==
										clip_timeline_end(timeline_clip)
								bw := clip_border_w
								border := clay.BorderWidth {
									left   = bw,
									top    = bw,
									bottom = bw,
								}
								border.right = next_touches ? 0 : bw
								// The tile is wrapped so a keyframed clip grows
								// DOWNWARD: a fixed-height tile (markers, selection,
								// hit tests all key off it) plus one KF_ROW_H lane per
								// keyframe track. The lane elements reserve the space
								// the diamond overlay (draw_keyframes) paints into and
								// give the interaction slice click targets; a hairline
								// on each lane's top makes the stack read as a strip.
								keyframe_n := timeline_clip.keyframe_tracks.n
								if clay.UI(
									clay.ID(
										"TimelineClipWrap",
										u32(ti * 1000 + index),
									),
								)(
									{
										layout = {
											sizing = {
												width = clay.SizingFixed(clip_width),
												height = clay.SizingFixed(
													CLIP_TILE_HEIGHT + f32(keyframe_n) * KF_ROW_H,
												),
											},
											layoutDirection = .TopToBottom,
										},
									},
								) {
									if clay.UI(
										clay.ID(
											"TimelineClip",
											u32(ti * 1000 + index),
										),
									)(
										{
											layout = {
												sizing = {
													// The tile's width is the MODEL's
													// (frames*zoom), never its content's: a
													// Grow tile let the label's measured width
													// plus padding push the tile PAST the
													// wrap's fixed width, so a short clip drew
													// wider than it was -- and its hit test,
													// drag origin and markers inherited that
													// same wrong box. The label is clipped to
													// the tile instead.
													width = clay.SizingFixed(clip_width),
													height = clay.SizingFixed(CLIP_TILE_HEIGHT),
												},
												padding = clay.PaddingAll(CARD_GAP),
											},
											clip = {horizontal = true},
											backgroundColor = clip_color,
											cornerRadius = clay.CornerRadiusAll(
												RADIUS_WIDGET,
											),
											border = {color = clip_border, width = border},
										},
									) {
										clay.Text(
											clip_label,
											clay.TextElementConfig {
												textColor = TEXT,
												fontSize = FONT_HEADING,
											},
										)
									}
									for tr in 0 ..< keyframe_n {
										if clay.UI(
											clay.ID(
												"KeyframeLane",
												u32((ti * 1000 + index) * 1000 + tr),
											),
										)(
											{
												layout = {
													sizing = {
														width = clay.SizingGrow({}),
														height = clay.SizingFixed(KF_ROW_H),
													},
												},
												border = {
													color = RULER_TICK_COLOR,
													width = clay.BorderWidth{top = 1},
												},
											},
										) {}
									}
								}
								clips_content_x += clip_width
							}
						}
					}
				}
				}
			}
			// Bottom bar: the snap toggles on the left, the zoom controls
			// on the right, all under the tracks so the timeline is
			// controllable without a separate top toolbar.
			if clay.UI(clay.ID("TimelineBottomBar"))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow({}),
						height = clay.SizingFixed(TIMELINE_BAR_H),
					},
					layoutDirection = .LeftToRight,
					childGap = BUTTON_ROW_GAP,
					childAlignment = {x = .Left, y = .Center},
				},
			},
			) {
				settings_icon_button("SnapClipToPh", editor_flags.snap_clips_to_playhead)
				settings_icon_button("SnapPhToClip", editor_flags.snap_playhead_to_clips)
				settings_icon_button("AutoKf", editor_flags.auto_keyframe)
				// Grow spacer pushes the zoom group to the right edge,
				// keeping the snap toggles pinned left.
				if clay.UI(clay.ID("TimelineBottomSpacer"))(
				{
					layout = {
						sizing = {
							width = clay.SizingGrow({}),
							height = clay.SizingGrow({}),
						},
					},
				},
				) {}
				bar_caption("Zoom:")
				tool_button("TimelineZoomOut", "−")
				tool_button("TimelineZoomFit", "Fit")
				tool_button("TimelineZoomIn", "+")
			}
		}
	}
}

// Column 1: Media Bin.
build_media_bin_column :: proc(default_border: clay.BorderWidth) {
	if clay.UI(clay.ID("MediaBin"))(
	{
		layout = {
			sizing = {
				width = clay.SizingGrow({min = MEDIA_BIN_MIN_W, max = MEDIA_BIN_MAX_W}),
				height = clay.SizingGrow({}),
			},
			padding = clay.PaddingAll(PANEL_PADDING),
			childGap = CARD_GAP,
			layoutDirection = .TopToBottom,
		},
		backgroundColor = BUTTON,
		border = {color = BUTTON_BORDER, width = default_border},
		cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
	},
	) {
		// The view body grows to fill the panel so the tab row stays
		// pinned to the panel's bottom edge regardless of how much
		// content the active view has (an empty bin must not pull the
		// tabs up under the header).
		if clay.UI(clay.ID("MediaBinBody"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				layoutDirection = .TopToBottom,
				childGap = CARD_GAP,
			},
		},
		) {
			switch panel_views.media_bin_view {
			case .Bin:
				media_bin_header()
				media_bin_grid()
			case .Undo:
				undo_view_header()
				undo_view_content()
			}
		}
		media_bin_tabs()
	}
}

// Column 2: Preview with the transport strip beneath it.
build_preview_column :: proc(default_border: clay.BorderWidth) {
	if clay.UI(clay.ID("PreviewColumn"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			layoutDirection = .TopToBottom,
			childGap = CARD_GAP,
			padding = clay.PaddingAll(CARD_GAP),
		},
		border = {color = BUTTON_BORDER, width = default_border},
		cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
	},
	) {
		// The preview grows to fill the column (bounded below); the
		// decoded image scales to fit whatever the widget becomes, and
		// preview_canvas derives the on-screen canvas from the widget
		// bounds, so this is responsive on resize.
		if clay.UI(clay.ID("Preview"))(
		{
			layout = {
				sizing = {
					width = clay.SizingGrow({}),
					height = clay.SizingGrow({min = 216}),
				},
			},
			image = {imageData = nil},
		},
		) {
			preview_fit_button()
		}
		// Transport strip: jog / play / rate, then the frame counter.
		if clay.UI(clay.ID("ActionsArea"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
				layoutDirection = .LeftToRight,
				childGap = BUTTON_ROW_GAP,
				childAlignment = {x = .Center, y = .Center},
			},
		},
		) {
			// Empty balance spacer. Paired with TransportRight
			// (equal SizingGrow), it splits the strip's free width
			// evenly so PlayRow lands centered under the preview
			// instead of hugging the left edge.
			if clay.UI(clay.ID("TransportSpacerL"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				},
			},
			) {}
			if clay.UI(clay.ID("PlayRow"))(
			{
				layout = {
					sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})},
					layoutDirection = .LeftToRight,
					childAlignment = {x = .Center, y = .Center},
					childGap = BUTTON_ROW_GAP,
				},
			},
			) {
				jog_button("PlayBack", -1)
				if clay.UI(clay.ID("PlayPause"))(
				{
					layout = {
						sizing = {
							width = clay.SizingFixed(96),
							height = clay.SizingFixed(BUTTON_HEIGHT),
						},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = BUTTON,
					border = {color = BUTTON_BORDER, width = default_border},
					cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
				},
				) {
					if playhead.playing {
						clay.Text(
							"Pause",
							clay.TextElementConfig {
								textColor = TEXT,
								fontSize = FONT_NORMAL,
							},
						)
					} else {
						clay.Text(
							"Play",
							clay.TextElementConfig {
								textColor = TEXT,
								fontSize = FONT_NORMAL,
							},
						)
					}
				}
				jog_button("PlayFwd", 1)
				playback_rate_dropdown()
			}
			// TopToBottom so childAlignment.x = .Right is honored
			// (Clay ignores .Right on a LeftToRight main axis); the
			// equal-grow pairing with TransportSpacerL keeps the
			// counter flush right while PlayRow stays centered.
			if clay.UI(clay.ID("TransportRight"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
					layoutDirection = .TopToBottom,
					childAlignment = {x = .Right, y = .Center},
				},
			},
			) {
				clay.Text(
					fmt.bprintf(
						ui_text.state[:],
						"%d / %d  ·  %gfps",
						playhead.frame,
						max(0, timeline_duration() - 1),
						timeline_fps(),
					),
					clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
				)
			}
		}
	}
}

// Column 3: Inspector -- Clip / Project / Render view. The bottom
// tab row picks which card the scrollport shows; the active card
// scrolls in its own scrollport (InspectorContent) with a vertical
// strip when it outgrows the column.
build_inspector_column :: proc() {
	if clay.UI(clay.ID("InspectorColumn"))(
	{
		layout = {
			sizing = {
				width = clay.SizingGrow({min = INSPECTOR_MIN_W, max = INSPECTOR_MAX_W}),
				height = clay.SizingGrow({}),
			},
			layoutDirection = .TopToBottom,
			childGap = 0,
		},
		backgroundColor = EDITOR_BG,
	},
	) {
		if clay.UI(clay.ID("InspectorArea"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				layoutDirection = .LeftToRight,
				childGap = 0,
			},
		},
		) {
			if clay.UI(clay.ID("Inspector"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
					layoutDirection = .TopToBottom,
					childGap = 0,
				},
				clip = {vertical = true, childOffset = {0, -scrollbars.inspector.offset}},
			},
			) {
				if clay.UI(clay.ID("InspectorContent"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
						layoutDirection = .TopToBottom,
						childGap = SECTION_GAP,
					},
				},
				) {
					switch panel_views.inspector_view {
					case .Clip:
						clip_card()
					case .Project:
						project_card()
					case .Render:
						render_card()
					}
				}
			}
			v_scrollbar(
				"InspectorV",
				scrollbars.inspector.offset,
				inspector_content_height(),
				inspector_view_height(),
			)
		}
		inspector_tabs()
	}
}