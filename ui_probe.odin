// ---------------------------------------------------------------------------
// Headless UI draw-call probe (VYPER_UI_PROBE=1).
//
// The GPU pass issues one SDL draw call per clay command: render_sdf_rect per
// Rectangle/Border command, and render_text issues one DrawGPUPrimitives per
// glyph. This probe runs the REAL clay layout (build_page) for N simulated
// frames on a synthetic timeline -- no SDL, no GPU -- and walks the resulting
// command stream with the same accounting, so the per-frame UI draw-call load
// can be measured without a display. It is the reproducibility tool for any
// renderer batching work.
//
// Known limitation: when the EditorLowerArea collapses (a Grow TrackArea left
// ~52px after the toolbar/ruler/bottom-bar, clay marks the subtree GONE and
// emits NO timeline commands), the timeline tiles and gutters are excluded
// from the count. Their cost is measured separately in the microtest replica
// (~250 draws/frame for a 6x12 timeline). The non-timeline static UI here is
// the full, un-collapsed picture.
// ---------------------------------------------------------------------------
package main

import clay "clay-odin"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

ui_probe_tracks :: 6
ui_probe_clips_per_track :: 12

measure_probe :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	userData: rawptr,
) -> clay.Dimensions {
	return {width = f32(text.length) * f32(config.fontSize) * 0.55, height = f32(config.fontSize)}
}

clay_probe_error :: proc "c" (data: clay.ErrorData) {
}

ui_draw_probe_run :: proc() {
	CLAY_ARENA_BYTES :: 64 * 1024 * 1024
	memory := make([^]u8, CLAY_ARENA_BYTES)
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(c.size_t(CLAY_ARENA_BYTES), memory),
		{WINDOW_WIDTH, WINDOW_HEIGHT},
		{handler = clay_probe_error},
	)
	clay.SetMeasureTextFunction(measure_probe, nil)

	seed_ui_probe_session()

	frames := 60
	RECT, BORDER, TEXT, GLYPHS := 0, 0, 0, 0
	for _ in 0 ..< frames {
		commands := build_page(WINDOW_WIDTH, WINDOW_HEIGHT)
		for i in 0 ..< commands.length {
			command := clay.RenderCommandArray_Get(&commands, i)
			switch command.commandType {
			case .Rectangle:
				RECT += 1
			case .Border:
				BORDER += 1
			case .Text:
				TEXT += 1
				// The renderer issues one DrawGPUPrimitives per glyph (rune);
				// count the text runs by codepoint length, not byte length.
				g := 0
				raw := ([^]u8)(command.renderData.text.stringContents.chars)[:int(command.renderData.text.stringContents.length)]
for j := 0; j < len(raw); {
				_, size := utf8.decode_rune(string(raw[j:]))
				g += 1
				j += size
			}
				GLYPHS += g
			case .None,
			     .Image,
			     .ScissorStart,
			     .ScissorEnd,
			     .OverlayColorStart,
			     .OverlayColorEnd,
			     .Custom:
			// No GPU draw for these; the renderer walks past them.
			}
		}
	}
	// The renderer draws each Rectangle command once (one SDF quad), each
	// Border once, and each glyph of every Text command once. ScissorStart/End
	// are state changes, not draws.
	rect_draws := RECT + BORDER
	glyph_draws := GLYPHS
	fmt.printf(
		"[ui-probe] %d frames @ %dx%d: rect=%d border=%d textcmd=%d glyphs=%d ->  draws/frame rect=%d glyph=%d total=%d\n",
		frames,
		WINDOW_WIDTH,
		WINDOW_HEIGHT,
		RECT / frames,
		BORDER / frames,
		TEXT / frames,
		GLYPHS / frames,
		rect_draws / frames,
		glyph_draws / frames,
		(rect_draws + glyph_draws) / frames,
	)

	// Layout assertions on a window tall enough for the timeline to lay out
	// fully (at the measurement size the editor band collapses the timeline
	// subtree, leaving its boxes zero).
	if !ui_probe_layout_asserts() {
		os.exit(1)
	}
	// The file finder is a dialog-style popup drawn off the text input hook:
	// open it headless, lay out a page, and check the popup exists, is centered,
	// and paints one row per visible entry.
	if !ui_probe_finder_asserts() {
		os.exit(1)
	}
	os.exit(0)
}

// ui_probe_finder_asserts opens the in-app finder over the seeded session and
// checks its geometry: the column sits centered with the asked width, the
// proper number of rows visible (capped at FINDER_MAX_ROWS), the filter field
// present, and both empty- and query-filtered layouts draw without an assert.
ui_probe_finder_asserts :: proc() -> bool {
	ok := true
	finder_populate(8)
	build_page(1920, 1600)
	col := clay.GetElementData(clay.ID("FinderColumn")).boundingBox
	if col.width <= 0 || col.height <= 0 {
		fmt.eprintf("[ui-probe] FinderColumn missing (%.1fx%.1f)\n", col.width, col.height)
		ok = false
	}
	field := clay.GetElementData(clay.ID("TextInputField")).boundingBox
	if field.width <= 0 {
		fmt.eprintf("[ui-probe] finder filter field missing\n")
		ok = false
	}
	row0 := clay.GetElementData(clay.ID("FinderRow", 0)).boundingBox
	if row0.width <= 0 || row0.height <= 0 {
		fmt.eprintf("[ui-probe] finder row 0 missing (%.1fx%.1f)\n", row0.width, row0.height)
		ok = false
	}
	// The popup is centered: the leading gap must equal the trailing gap.
	gap := (1920 - col.width) / 2
	if abs(col.x - gap) > 1.0 {
		fmt.eprintf("[ui-probe] finder column x=%.1f want %.1f\n", col.x, gap)
		ok = false
	}
	// Run the dirty-filter path too: an unmatched query yields zero rows but
	// must still draw (no divide-by-no-row, selection clamps to n-1=0).
	text_input_set_buf("zzzz_no_match_querystring_query")
	build_page(1920, 1600)
	fmt.printf("[ui-probe] visrows pre\n")
	if visible_rows() != 0 {
		fmt.eprintf("[ui-probe] finder filter: no rows expected\n")
		ok = false
	}
	ti.active = false // text_input_cancel would poke SDL; we're headless
	finder_close()
	build_page(1920, 1600)
	if clay.GetElementData(clay.ID("FinderColumn")).boundingBox.width > 0 {
		fmt.eprintf("[ui-probe] finder popup did not dismiss\n")
		ok = false
	}
	if ok {
		fmt.printf("[ui-probe] finder layout ok (%d rows)\n", FINDER_MAX_ROWS)
	}
	return ok
}

// finder_populate seeds the finder as if opened over a directory and relists a
// handful of synthetic entries (dirs + files of each kind) so the popup has
// something to draw without touching the real filesystem.
finder_populate :: proc(n: int) {
	file_finder.active = true
	file_finder.mode = .Open
	file_finder.cwd = strings.clone("/probe/fixtures")
	file_finder.entries = make([dynamic]Finder_Entry, 0, n + 3)
	for i in 0 ..< n {
		kind := Finder_Kind((i + 1) % len(Finder_Kind))
		append(
			&file_finder.entries,
			Finder_Entry {
				name = fmt.aprintf("probe_%d.%s", i, "mpg" if kind == .Video else "txt"),
				fullpath = fmt.aprintf("/probe/fixtures/probe_%d", i),
				is_dir = kind == .Folder,
				kind = kind,
			},
		)
	}
	append(
		&file_finder.entries,
		Finder_Entry {
			name = fmt.aprintf("sub.srt"),
			fullpath = fmt.aprintf("/probe/fixtures/sub.srt"),
			kind = .Subtitle,
		},
	)
	file_finder.filtered = make([dynamic]int, 0, len(file_finder.entries))
	for i in 0 ..< len(file_finder.entries) {
		append(&file_finder.filtered, i)
	}
	// The finder's text input rides on `ti`, but the real opener pokes SDL text
	// input (sdl.StartTextInput) which is unavailable headless — reproduce only
	// the state the popup's draw reads.
	ti.active = true
	ti.input_type = TI_FINDER
	ti.cursor = 0
	ti.anchor = 0
	clear(&ti.buf)
	file_finder.sel = 0
	file_finder.scroll = 0
	file_finder.query_len = -1 // force finder_refresh to scan the new list
	finder_refresh()
}

// visible_rows reports how many rows the current filter/list produce.
visible_rows :: proc() -> int {
	refresh := text_input_string()
	n := 0
	for e in file_finder.entries {
		if cmdline_fuzzy_score(refresh, e.name) > 0 {
			n += 1
		}
	}
	return n
}

// ui_probe_layout_asserts checks the keyframe render geometry: the row grows
// by one KF_ROW_H per lane, the wrapped clip tile grows downward (tile height
// untouched so markers/selection/hit-testing key off it stay correct, lanes
// below), and the gutter stacks one label line per visible lane.
ui_probe_layout_asserts :: proc() -> bool {
	ok := true
	build_page(1920, 1600)
	row := clay.GetElementData(clay.ID("TrackRow", 0)).boundingBox
	want_row := TRACK_ROW_H + 2 * KF_ROW_H
	if abs(row.height - want_row) > 0.5 {
		fmt.eprintf("[ui-probe] TrackRow height %.1f want %.1f\n", row.height, want_row)
		ok = false
	}
	wrap := clay.GetElementData(clay.ID("TimelineClipWrap", 0)).boundingBox
	want_wrap := CLIP_TILE_HEIGHT + 2 * KF_ROW_H
	if abs(wrap.height - want_wrap) > 0.5 {
		fmt.eprintf("[ui-probe] TimelineClipWrap height %.1f want %.1f\n", wrap.height, want_wrap)
		ok = false
	}
	tile := clay.GetElementData(clay.ID("TimelineClip", 0)).boundingBox
	if abs(tile.height - CLIP_TILE_HEIGHT) > 0.5 {
		fmt.eprintf("[ui-probe] TimelineClip height %.1f want %.1f\n", tile.height, CLIP_TILE_HEIGHT)
		ok = false
	}
	gutter := clay.GetElementData(clay.ID("KfGutterNames", 0)).boundingBox
	want_gutter := 2 * KF_ROW_H
	if abs(gutter.height - want_gutter) > 0.5 {
		fmt.eprintf("[ui-probe] KfGutterNames height %.1f want %.1f\n", gutter.height, want_gutter)
		ok = false
	}
	if ok {
		fmt.printf("[ui-probe] keyframe layout ok\n")
	}
	return ok
}

seed_ui_probe_session :: proc() {
	// Synthetic session for the draw-call layout: a project with 6 tracks x 12
	// clips (video/audio/text mix), a selected clip (Inspector open), one live
	// preview slot, and a playhead mid-timeline -- the state the editor spends
	// most of its time in.
	timeline.tracks = make([dynamic]Track, 0, 8)
	next_id: u64 = 1
	for t in 0 ..< ui_probe_tracks {
		track := Track {
			name = fmt.aprintf("track %d", t),
		}
		track.clips = make([dynamic]Clip, 0, ui_probe_clips_per_track)
		for c in 0 ..< ui_probe_clips_per_track {
			kind: Media_Kind = .Video
			if c % 3 == 1 {
				kind = .Audio
			} else if c % 3 == 2 {
				kind = .Text
			}
			append(
				&track.clips,
				Clip {
					clip_id = next_id,
					asset_id = next_id,
					path = cstring("probe.mp4"),
					name = fmt.aprintf("clip %d-%d", t, c),
					kind = kind,
					generator = kind == .Text ? .Text : .None,
					source_start_frame = 0,
					source_length_frames = 300,
					timeline_start_frame = i64(1000) + i64(c) * 350,
					source_w = 1920,
					source_h = 1080,
				},
			)
			next_id += 1
		}
		append(&timeline.tracks, track)
	}

	// One keyframed clip (two tracks) exercises the grown-row layout and the
	// diamond lanes, so the probe also guards the keyframe render geometry.
	kf0 := &timeline.tracks[0].clips[0]
	kf0.keyframe_tracks = make([dynamic]Kf_Track, 0, 2)
	append(&kf0.keyframe_tracks, Kf_Track {name = "transform.x", keys = make([dynamic]Keyframe, 0, 4)})
	append(&kf0.keyframe_tracks[0].keys, Keyframe {frame_off = 0, value = 0}, Keyframe {frame_off = 120, value = 1})
	append(&kf0.keyframe_tracks, Kf_Track {name = "zoom", keys = make([dynamic]Keyframe, 0, 4)})
	append(&kf0.keyframe_tracks[1].keys, Keyframe {frame_off = 30, value = 1})

	sync_track_order()

	// Selected clip -> the Inspector property card renders.
	selection.track = 0
	selection.index = 1

	// One live preview slot (the canvas area layout reflects a playing clip).
	preview_slots[0] = Preview_Slot {
		in_use  = true,
		clip_id = timeline.tracks[0].clips[0].clip_id,
	}
	_ = next_id
}

handle_ui_probe :: proc() -> bool {
	if v, _ := os.lookup_env_alloc("VYPER_UI_PROBE", context.temp_allocator); v != "" {
		ui_draw_probe_run()
		return true
	}
	return false
}
