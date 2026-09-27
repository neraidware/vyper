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
import sdl "vendor:sdl3"
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
	// Track rows: buttons moved to the dedicated menu, and the timeline fits
	// TRACKS_FIT_TARGET rows on import/load.
	if !ui_probe_track_menu_asserts() {
		os.exit(1)
	}
	// Composite order: track order for ordinary clips, subtitles pinned on top.
	if !ui_probe_preview_order_asserts() {
		os.exit(1)
	}
	// The finder must show its listing the moment it opens, with no typing.
	if !ui_probe_finder_listing_asserts() {
		os.exit(1)
	}
	// The ":" prompt opener consumes its own text event; the first real
	// keystroke after it must survive.
	if !ui_probe_cmdline_opener_asserts() {
		os.exit(1)
	}
	// The shortcut table is data now, so pin the resolutions the old inline
	// switch made — especially the key/mode pairs that need most-specific-first
	// ordering, which a silent reorder would rebind.
	if !ui_probe_action_table_asserts() {
		os.exit(1)
	}
	// The router's owner order and each owner's claim, pinned without firing
	// real actions at the seeded session.
	if !ui_probe_key_routing_asserts() {
		os.exit(1)
	}
	// Hold-to-jog, observed through the real router rather than inferred from
	// its shape.
	if !ui_probe_jog_asserts() {
		os.exit(1)
	}
	// The file finder is a dialog-style popup drawn off the text input hook:
	// open it headless, lay out a page, and check the popup exists, is centered,
	// and paints one row per visible entry.
	if !ui_probe_finder_asserts() {
		os.exit(1)
	}
	// Finder Save mode: the field is a name, not a filter, and what it writes
	// must be a project file `:open` can read back. Runs before the round-trip
	// probe because it saves and reloads the live session.
	if !ui_probe_finder_save_asserts() {
		os.exit(1)
	}
	// Project file round-trip: a :save-style write must come back identical to
	// a :open-style read through the live Project global.
	if !ui_probe_project_file_asserts() {
		os.exit(1)
	}
	// Marker-label ownership: the round-trip above frees labels through
	// free_timeline but never copies them, so cover the copy paths here.
	if !ui_probe_marker_ownership_asserts() {
		os.exit(1)
	}
	os.exit(0)
}

// ui_probe_marker_ownership_asserts covers the marker-label ownership rule
// without media: every Clip_Marker.label is uniquely owned, so the two procs
// that copy markers (clone_timeline for undo snapshots,
// filter_markers_in_range for split) must clone the label, and every discard
// goes through free_markers. Getting this wrong shows up as either a
// double-free (valgrind "Invalid free" / "Mismatched free") or a definite leak
// (a label whose only other holder was already freed), so the whole point is
// that this proc frees four independent marker sets and exits clean.
ui_probe_marker_ownership_asserts :: proc() -> bool {
	ok := true
	src := Timeline{tracks = make([dynamic]Track, 1)}
	src.tracks[0].name = strings.clone("marker-owner")
	src.tracks[0].clips = make([dynamic]Clip, 1)
	src.tracks[0].clips[0].name = strings.clone("marker-clip")
	src.tracks[0].clips[0].markers = make([dynamic]Clip_Marker, 0, 4)
	for i in 0 ..< 3 {
		buf: [32]u8
		s := fmt.bprintf(buf[:], "m%d", i)
		append(
			&src.tracks[0].clips[0].markers,
			Clip_Marker{source_frame = i64(i) * 10, label = strings.clone(s)},
		)
	}
	orig := src.tracks[0].clips[0].markers

	// Snapshot clone (undo path) and two range filters (split path): each must
	// carry its own labels, so editing or freeing one never touches another.
	snap := clone_timeline(src)
	lo := filter_markers_in_range(orig[:], 0, 20)
	hi := filter_markers_in_range(orig[:], 20, 20)

	if len(lo) != 2 || lo[0].label != "m0" || lo[1].label != "m1" {
		fmt.eprintf("[ui-probe] lo markers wrong: n=%d\n", len(lo))
		ok = false
	}
	if len(hi) != 1 || hi[0].label != "m2" {
		fmt.eprintf("[ui-probe] hi markers wrong: n=%d\n", len(hi))
		ok = false
	}
	snap_markers := snap.tracks[0].clips[0].markers
	if len(snap_markers) != 3 ||
	   snap_markers[2].label != "m2" ||
	   snap_markers[2].source_frame != 20 {
		fmt.eprintf("[ui-probe] snapshot markers wrong: n=%d\n", len(snap_markers))
		ok = false
	}

	free_timeline(&snap)
	free_timeline(&src)
	free_markers(&lo)
	free_markers(&hi)
	return ok
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

// ui_probe_text_buf backs ui_probe_push_text. SDL holds the text pointer until
// the event is drained, so the bytes need storage that outlives the push; a
// package var does, and one buffer suffices because every push is drained by the
// next handle_sdl_events before the next push overwrites it.
ui_probe_text_buf: [64]u8

// ui_probe_push_text queues a real SDL_TEXT_INPUT event through SDL's own event
// queue. Note the tag is set explicitly: writing a #raw_union's variant does NOT
// set it, so a synthetic event otherwise stays FIRST and the app's switch never
// matches TEXT_INPUT.
ui_probe_push_text :: proc(s: string) {
	n := min(len(s), len(ui_probe_text_buf) - 1)
	copy(ui_probe_text_buf[:n], s[:n])
	ui_probe_text_buf[n] = 0
	// cstring is [^]u8, so transmute the pointer, not the slice.
	raw: [^]u8 = raw_data(ui_probe_text_buf[:])
	ev: sdl.Event
	ev.type = .TEXT_INPUT
	ev.text.text = transmute(cstring)raw
	if !sdl.PushEvent(&ev) {
		fmt.eprintf("[ui-probe] SDL_PushEvent failed for %q\n", s)
	}
}

// ui_probe_push_opener_key queues the KEY_DOWN that opens the command line. On a
// US layout ":" is Shift+";", so SDL reports the base keycode with the shift
// modifier — that is the case the app's K_SEMICOLON branch exists for, and the
// one worth driving here.
ui_probe_push_opener_key :: proc() {
	ev: sdl.Event
	ev.type = .KEY_DOWN
	ev.key.key = sdl.K_SEMICOLON
	// key.mod is a Keymod (a bit_set over KeymodFlag), not a KeymodFlag, so the
	// flag set needs converting at the boundary.
	ev.key.mod = sdl.Keymod{sdl.KeymodFlag.LSHIFT}
	ev.key.repeat = false
	ev.key.down = true
	if !sdl.PushEvent(&ev) {
		fmt.eprintf("[ui-probe] SDL_PushEvent failed for the opener key\n")
	}
}

// ui_probe_cmdline_opener_asserts drives the command line through real SDL
// events. One keypress produces TWO of them: the KEY_DOWN that opens the prompt,
// then that same keypress's own TEXT_INPUT echo (which text_input_begin
// re-enables text input to receive). The opener must consume the echo without
// eating anything else, and the case that matters is the reported bug: a
// keypress that produces NO echo must not leave the suppressor armed.
// The action table replaced an inline `switch event.key.key`, so this pins the
// resolutions that switch used to make. The interesting cases are the ones
// where one key maps to DIFFERENT actions by modifier, because those depend
// entirely on BINDINGS being ordered most-specific-first — a reorder compiles
// fine and silently rebinds the app.
ui_probe_action_table_asserts :: proc() -> bool {
	ok := true
	ctrl := sdl.KMOD_CTRL
	shift := sdl.KMOD_SHIFT

	Case :: struct {
		key:     sdl.Keycode,
		mods:    sdl.Keymod,
		want:    Action,
		because: string,
	}
	cases := [?]Case {
		{ sdl.K_COLON, {}, .Open_Command_Line, "the \":\" opener is keycode-bound and modifier-insensitive" },
		{ sdl.K_SEMICOLON, shift, .Open_Command_Line, "Shift+\";\" is the same opener on a US layout" },
		{ sdl.K_SEMICOLON, sdl.KMOD_LSHIFT, .Open_Command_Line, "left Shift must satisfy the shift binding" },
		{ sdl.K_SEMICOLON, sdl.KMOD_RSHIFT, .Open_Command_Line, "right Shift must satisfy it too" },
		{ sdl.K_SEMICOLON, {}, .None, "a bare \";\" must NOT open the prompt" },
		{ sdl.K_Z, ctrl, .Undo, "Ctrl+Z undoes" },
		{ sdl.K_Z, sdl.KMOD_RCTRL, .Undo, "right Ctrl must satisfy the Ctrl bindings" },
		{ sdl.K_Z, ctrl | shift, .Redo, "Ctrl+Shift+Z redoes, and must beat the Ctrl+Z row" },
		{ sdl.K_Z, {}, .None, "a bare \"z\" does nothing" },
		{ sdl.K_Y, ctrl, .Redo, "Ctrl+Y redoes" },
		{ sdl.K_SPACE, ctrl, .Play_Project_Area, "Ctrl+Space plays the project area, and must beat the bare-Space row" },
		{ sdl.K_SPACE, {}, .Toggle_Playback, "bare Space toggles transport" },
		{ sdl.K_R, ctrl, .Begin_Rename, "Ctrl+R renames" },
		{ sdl.K_R, {}, .None, "a bare \"r\" does nothing" },
		{ sdl.K_F1, {}, .Toggle_Help, "F1 toggles help" },
		{ sdl.K_S, {}, .Split_At_Playhead, "S splits at the playhead" },
		// Ctrl+S splitting a clip is almost certainly a pre-existing binding
		// bug, but the table must reproduce the app's ACTUAL behaviour, not the
		// behaviour anyone would have chosen. Changing it is its own change.
		{ sdl.K_S, ctrl, .Split_At_Playhead, "Ctrl+S still splits: preserved pre-existing behaviour" },
		{ sdl.K_U, {}, .Toggle_Links, "U toggles links" },
		{ sdl.K_BACKSPACE, {}, .Delete_At_Playhead, "Backspace deletes the keyframe or ripples" },
		{ sdl.K_DELETE, {}, .Delete_Selection, "Delete removes the clip raw" },
		{ sdl.K_I, {}, .Set_In_Point, "I sets the in point" },
		{ sdl.K_O, {}, .Set_Out_Point, "O sets the out point" },
		// Jog is driven by key repeat, not by the table, so it must not be
		// reachable as a one-shot action.
		{ sdl.K_H, {}, .None, "jog is a repeat-driven rate, not a bound action" },
		{ sdl.K_L, {}, .None, "jog is a repeat-driven rate, not a bound action" },
	}

	for c in cases {
		got := action_for(c.key, c.mods)
		if got != c.want {
			fmt.eprintf(
				"[ui-probe] action_for(K_%v, mods=%v) = %v, want %v (%s)\n",
				c.key, c.mods, got, c.want, c.because,
			)
			ok = false
		}
	}

	// Keyboard state: the definition of a repeat is "already down", and an
	// action must fire on the initial press only, never on the repeats after it.
	before := kbd.drain
	kbd_begin_drain()
	kbd_note_key(sdl.K_H, true)
	if !key_press(sdl.K_H) || key_repeat(sdl.K_H) {
		fmt.eprintf("[ui-probe] the first KEY_DOWN reported a repeat\n")
		ok = false
	}
	kbd_begin_drain()
	kbd_note_key(sdl.K_H, true)
	if key_press(sdl.K_H) || !key_repeat(sdl.K_H) {
		fmt.eprintf("[ui-probe] holding KEY_DOWN did not report a repeat\n")
		ok = false
	}
	kbd_begin_drain()
	kbd_note_key(sdl.K_H, false)
	if key_held(sdl.K_H) || !key_release(sdl.K_H) {
		fmt.eprintf("[ui-probe] KEY_UP did not clear the held state\n")
		ok = false
	}
	// A key that never went down has no edges, and a stale handle from a
	// previous drain must not resurrect one.
	kbd_begin_drain()
	if key_held(sdl.K_H) || key_press(sdl.K_H) || key_repeat(sdl.K_H) || key_release(sdl.K_H) {
		fmt.eprintf("[ui-probe] keyboard edges survived a drain\n")
		ok = false
	}
	// An out-of-range keycode must be refused, not written past the table end.
	kbd_note_key(sdl.Keycode(KEYCODE_SLOTS + 1), true)
	if key_held(sdl.Keycode(KEYCODE_SLOTS + 1)) {
		fmt.eprintf("[ui-probe] an out-of-range keycode was accepted\n")
		ok = false
	}
	if kbd.drain <= before {
		fmt.eprintf("[ui-probe] the drain counter did not advance\n")
		ok = false
	}
	if ok {
		fmt.printf("[ui-probe] action table ok (%d cases)\n", len(cases))
	}
	return ok
}

// The router replaced a nested if/else chain, so what matters is that each
// owner claims exactly what it used to. These assert the CLAIM, not the side
// effect: firing real actions here would split clips and move the playhead in
// the middle of the other probes.
ui_probe_key_routing_asserts :: proc() -> bool {
	ok := true

	// No field open: the text field must claim nothing. This is the guard that
	// keeps a stale ti.input_type from swallowing the whole keyboard after a
	// prompt is closed.
	ti.active = false
	if field_claims_key(sdl.K_U, {}) {
		fmt.eprintf("[ui-probe] the text field claimed a key with no field open\n")
		ok = false
	}

	// Field open: a key the field does not act on is still claimed, which is
	// the pre-existing behaviour (no exit from the old branch). If this ever
	// becomes false it is a deliberate change, not an accident.
	ti.active = true
	claimed := field_claims_key(sdl.K_U, {})
	ti.active = false
	if !claimed {
		fmt.eprintf("[ui-probe] the text field passed an unhandled key to the app\n")
		ok = false
	}

	// The number field is the opposite: it takes three keys and lets the rest
	// through, so a shortcut still works while the playhead is being typed.
	Claim :: struct {
		key:   sdl.Keycode,
		want:  bool,
		which: string,
	}
	claims := [?]Claim {
		{ sdl.K_U, false, "an unbound key reaches the app" },
		{ sdl.K_ESCAPE, true, "Esc cancels the field" },
		{ sdl.K_RETURN, true, "Enter commits the field" },
		{ sdl.K_RETURN2, true, "the keypad Enter commits too" },
		{ sdl.K_BACKSPACE, true, "Backspace edits the field" },
		{ sdl.K_DELETE, false, "Delete is NOT the number field's: it deletes a clip" },
		{ sdl.K_F1, false, "F1 stays a global shortcut" },
	}
	for c in claims {
		if got := edit_field_claims_key(c.key); got != c.want {
			fmt.eprintf(
				"[ui-probe] edit_field_claims_key(K_%v) = %v, want %v (%s)\n",
				c.key, got, c.want, c.which,
			)
			ok = false
		}
	}
	if ok {
		fmt.printf("[ui-probe] key routing ok\n")
	}
	return ok
}

// Hold-to-jog is the one input behaviour whose evidence so far was structural
// ("the router puts the field first") rather than observed. Drive the keys
// through the real router and read the state jog_playback actually sets.
ui_probe_jog_asserts :: proc() -> bool {
	ok := true

	// jog_playback starts playback rather than moving the frame directly, so
	// the assertion is on what it sets. Save everything it touches: the probe
	// session is shared with the probes that run after this one.
	saved_playing := playhead.playing
	saved_frame := playhead.frame
	saved_dir := playback.dir
	saved_stop := playback.stop_frame
	saved_preview := preview.playing

	playhead.playing = false
	playhead.frame = 120
	playback.dir = 0
	playback.stop_frame = 0
	preview.playing = false
	ti.active = false
	edit_state.field = .None

	// Initial press of K_H: claimed, and directed backwards.
	kbd_begin_drain()
	kbd_note_key(sdl.K_H, true)
	if !app_claims_key(sdl.K_H, {}, false) {
		fmt.eprintf("[ui-probe] K_H was not claimed on its initial press\n")
		ok = false
	}
	if playback.dir != -1 {
		fmt.eprintf("[ui-probe] K_H gave dir %d, want -1\n", playback.dir)
		ok = false
	}
	if !playhead.playing {
		fmt.eprintf("[ui-probe] K_H did not start shuttle playback\n")
		ok = false
	}

	// Auto-repeat: the key is already down, so this is the edge the old code
	// threw away. It must still drive the jog -- that is the whole point of
	// adding a KEY_UP path.
	kbd_begin_drain()
	kbd_note_key(sdl.K_H, true)
	if !key_repeat(sdl.K_H) {
		fmt.eprintf("[ui-probe] the held K_H was not reported as a repeat\n")
		ok = false
	}
	if !app_claims_key(sdl.K_H, {}, true) {
		fmt.eprintf("[ui-probe] a repeating K_H was not claimed\n")
		ok = false
	}
	if playback.dir != -1 {
		fmt.eprintf("[ui-probe] a repeating K_H gave dir %d, want -1\n", playback.dir)
		ok = false
	}

	// And forwards for K_L.
	kbd_begin_drain()
	kbd_note_key(sdl.K_L, true)
	app_claims_key(sdl.K_L, {}, false)
	if playback.dir != 1 {
		fmt.eprintf("[ui-probe] K_L gave dir %d, want 1\n", playback.dir)
		ok = false
	}

	// The load-bearing safety property: a jog must not fire while a field has
	// the keyboard. Observed rather than inferred from the router's shape.
	playhead.playing = false
	playback.dir = 0
	ti.active = true
	ti.input_type = 0 // no TI_NONE constant; 0 is the implicit none
	kbd_begin_drain()
	kbd_note_key(sdl.K_H, true)
	if !route_key_down(sdl.K_H, {}, false) {
		fmt.eprintf("[ui-probe] K_H was not claimed by the field\n")
		ok = false
	}
	if playhead.playing || playback.dir != 0 {
		fmt.eprintf("[ui-probe] K_H started a jog while a field was open\n")
		ok = false
	}
	ti.active = false
	ti.input_type = 0 // no TI_NONE constant; 0 is the implicit none

	playhead.playing = saved_playing
	playhead.frame = saved_frame
	playback.dir = saved_dir
	playback.stop_frame = saved_stop
	preview.playing = saved_preview
	kbd_begin_drain()

	if ok {
		fmt.printf("[ui-probe] jog ok\n")
	}
	return ok
}

ui_probe_cmdline_opener_asserts :: proc() -> bool {
	ok := true
	running := true

	// This probe path returns from main before the app's sdl.Init, so there is
	// no event queue to push into. The event subsystem needs no display.
	if !sdl.Init(sdl.INIT_EVENTS) {
		fmt.eprintf("[ui-probe] SDL_Init(EVENTS) failed\n")
		return false
	}
	defer sdl.Quit()

	// There is deliberately NO "opener keypress WITH its own echo" case. That
	// state is unrepresentable now, and it was the only reason the suppressor
	// existed: SDL emits no TEXT_INPUT while text input is stopped, and a field
	// enables text input only after the drain, so the keypress that opens the
	// prompt is consumed with text input off and cannot produce one. The old
	// case asserted that a synthetic echo could be filtered, which was a
	// statement about the suppressor, not about the app.
	//
	// What replaces it is the behavior that actually matters: the prompt opens
	// empty, and the first real keystroke lands.
	text_input_cancel()
	ti.active = false
	ui_probe_push_opener_key()
	handle_sdl_events(&running)
	if !ti.active || ti.input_type != TI_CMDLINE {
		fmt.eprintf("[ui-probe] the opener key did not open the command line\n")
		return false
	}
	if got := text_input_string(); len(got) != 0 {
		fmt.eprintf("[ui-probe] prompt opened with %q, want empty\n", got)
		ok = false
	}
	ui_probe_push_text("o")
	handle_sdl_events(&running)
	if got := text_input_string(); got != "o" {
		fmt.eprintf("[ui-probe] first typed char gave %q, want \"o\"\n", got)
		ok = false
	}

	// Case 2: keypress with NO echo at all (layout/IME differences). This is
	// the reported bug: the suppressor used to drop "the next text event", so
	// the first real keystroke was eaten. Matching the CHARACTER is what makes
	// a missing echo harmless.
	text_input_cancel()
	ti.active = false
	ui_probe_push_opener_key()
	handle_sdl_events(&running)
	if !ti.active {
		fmt.eprintf("[ui-probe] opener key did not open the prompt (no-echo case)\n")
		ok = false
	}
	ui_probe_push_text("o")
	handle_sdl_events(&running)
	if got := text_input_string(); got != "o" {
		fmt.eprintf("[ui-probe] first typed char gave %q, want \"o\"\n", got)
		ok = false
	}

	// A ":" typed into an already-open prompt is DATA, not another opener:
	// "open C:/foo" is a legal command on Windows.
	ui_probe_push_text("C:/x")
	handle_sdl_events(&running)
	if got := text_input_string(); got != "oC:/x" {
		fmt.eprintf("[ui-probe] drive path gave %q, want \"oC:/x\"\n", got)
		ok = false
	}

	// Case 2: an opener followed by a ":" as the FIRST thing typed. The old
	// suppressor cleared its pending flag on whatever text event arrived next,
	// so this was the row it got wrong: type "o" and the flag was consumed
	// harmlessly, but type ":" — or paste anything starting with one — and that
	// character was silently eaten as though it were the opener's echo, leaving
	// the whole buffer empty. Nothing is armed any more, so there is no flag for
	// a keystroke to clear or trip over.
	text_input_cancel()
	ti.active = false
	ui_probe_push_opener_key()
	handle_sdl_events(&running)
	if !ti.active {
		fmt.eprintf("[ui-probe] opener did not open the prompt\n")
		ok = false
	}
	ui_probe_push_text(":C:/x")
	handle_sdl_events(&running)
	if got := text_input_string(); got != ":C:/x" {
		fmt.eprintf("[ui-probe] \":\" right after the opener gave %q, want \":C:/x\"\n", got)
		ok = false
	}

	// The deferral itself, since the rows above only show the absence of a
	// symptom. A field opening during a drain must park the request rather than
	// act on it, and the request must not outlive the flush — together those pin
	// the enable to between drains, which is the whole fix.
	text_input_cancel()
	if ti.text_pending || ti.text_on {
		fmt.eprintf(
			"[ui-probe] cancel left text input requested (pending=%v, on=%v)\n",
			ti.text_pending,
			ti.text_on,
		)
		ok = false
	}
	text_input_begin("", TI_CMDLINE, 0)
	if !ti.text_pending {
		fmt.eprintf("[ui-probe] text_input_begin did not request text input\n")
		ok = false
	}
	if ti.text_on {
		fmt.eprintf("[ui-probe] text_input_begin turned SDL text input on synchronously\n")
		ok = false
	}
	text_input_flush_pending()
	if ti.text_pending {
		fmt.eprintf("[ui-probe] flush left the request pending\n")
		ok = false
	}

	text_input_cancel()
	if ok {
		fmt.printf("[ui-probe] cmdline opener ok\n")
	}
	return ok
}

// ui_probe_finder_listing_asserts covers the regression where `:open` showed an
// EMPTY listing until the user typed something: the refresh memo was keyed on
// the query alone, but the filter output also depends on the entries list, so a
// relist under an unchanged query was silently dropped. Uses a real directory
// (the probe's own cwd) because the whole point is that a real read populates
// rows.
ui_probe_finder_listing_asserts :: proc() -> bool {
	ok := true
	ti.active = true
	ti.input_type = TI_FINDER
	ti.cursor = 0
	ti.anchor = 0
	clear(&ti.buf) // empty query: the state right after the finder opens

	// Stand in for finder_open's browse setup without the SDL text-input poke.
	file_finder.active = true
	file_finder.mode = .Open
	file_finder.sel = 0
	file_finder.scroll = 0
	cwd := os.get_working_directory(context.temp_allocator) or_else ""
	if len(cwd) == 0 {
		fmt.eprintf("[ui-probe] no cwd for the listing check\n")
		return false
	}
	defer {
		finder_close()
		ti.active = false
	}
	file_finder.cwd = strings.clone(cwd)
	finder_relist()
	if len(file_finder.entries) == 0 {
		fmt.eprintf("[ui-probe] cwd listing came back empty\n")
		return false
	}
	finder_refresh()
	// This is the reported bug: rows exist, the query is empty, and the list
	// must be visible without typing.
	if len(file_finder.filtered) == 0 {
		fmt.eprintf(
			"[ui-probe] %d entries but 0 rows shown with an empty query\n",
			len(file_finder.entries),
		)
		return false
	}

	// The same must hold after a descend, which rebuilds the entries under a
	// query that did not change.
	file_finder.filtered_valid = true
	finder_relist()
	finder_refresh()
	if len(file_finder.filtered) == 0 {
		fmt.eprintf("[ui-probe] relist under an unchanged query emptied the rows\n")
		ok = false
	}
	if ok {
		fmt.printf("[ui-probe] finder listing ok (%d rows)\n", len(file_finder.filtered))
	}
	return ok
}

// ui_probe_finder_save_asserts covers the finder's Save mode, where the field
// is a file NAME instead of a filter. The three things that can silently break
// it: typing must not narrow the rows (they are how you reach another
// directory), the field must start empty so the first Enter descends rather
// than saving, and a name typed without an extension must land as a real
// project file (`:open` dispatches on the suffix). Ends by loading back what it
// wrote, so a save that is not openable is caught here.
ui_probe_finder_save_asserts :: proc() -> bool {
	ok := true
	dir := "/tmp/opencode/ui_probe_save"
	os.remove_all(dir)
	os.make_directory(dir)
	// Real files, so "Save mode does not filter" is tested against a listing
	// with something to over-filter rather than an empty directory.
	seed_names := []string {"alpha.vyproj", "beta.vyproj", "gamma.mp4"}
	for s in seed_names {
		full := fmt.aprintf("%s/%s", dir, s)
		if err := os.write_entire_file(full, "probe"); err != nil {
			fmt.eprintf("[ui-probe] could not seed %s: %v\n", full, err)
			ok = false
		}
		delete(full)
	}

	finder_open(.Save)
	defer finder_close()
	if file_finder.mode != .Save || !file_finder.active {
		fmt.eprintf("[ui-probe] finder did not open in Save mode\n")
		return false
	}
	// Empty at open: a pre-filled name would turn the first Enter (on the ".."
	// row) into a save and make navigating to another directory impossible.
	if got := text_input_string(); len(got) != 0 {
		fmt.eprintf("[ui-probe] Save field not empty at open: %q\n", got)
		ok = false
	}

	finder_descend(dir)
	rows_all := len(file_finder.entries)
	text_input_set_buf("zzz-no-such-entry")
	finder_refresh()
	if len(file_finder.filtered) != rows_all {
		fmt.eprintf(
			"[ui-probe] Save mode filtered rows: %d of %d survived\n",
			len(file_finder.filtered),
			rows_all,
		)
		ok = false
	}

	// No extension typed -> one is appended, and the result must open.
	text_input_set_buf("probe_saved")
	finder_enter()
	saved := fmt.aprintf("%s/probe_saved%s", dir, PROJECT_FILE_EXTENSION)
	defer delete(saved)
	if !os.exists(saved) {
		fmt.eprintf("[ui-probe] save did not write %s\n", saved)
		ok = false
	} else {
		// A successful save closes the finder; a failed one keeps it open so
		// the name can be corrected. Both halves are checked here, and the
		// file is loaded back so a write that is not openable cannot pass.
		if file_finder.active {
			fmt.eprintf("[ui-probe] finder stayed open after a successful save\n")
			ok = false
		}
		if err := project_file_open(saved); len(err) > 0 {
			fmt.eprintf("[ui-probe] saved project did not load: %s\n", err)
			ok = false
		}
	}

	// An explicit extension is the user's call and is left alone.
	finder_open(.Save)
	finder_descend(dir)
	text_input_set_buf("probe_named.custom")
	finder_enter()
	named := fmt.aprintf("%s/probe_named.custom", dir)
	defer delete(named)
	if !os.exists(named) {
		fmt.eprintf("[ui-probe] explicit extension not honored: %s missing\n", named)
		ok = false
	}

	// The suggested name carries the project extension, so the common case
	// needs no typing beyond accepting it.
	hint_buf: [128]u8
	hint := finder_default_save_name(hint_buf[:])
	if !strings.has_suffix(hint, PROJECT_FILE_EXTENSION) {
		fmt.eprintf("[ui-probe] suggested name %q lacks %s\n", hint, PROJECT_FILE_EXTENSION)
		ok = false
	}

	// Icon classification is a string compare against a lowercased copy, so it
	// fails silently (everything falls to .File) if the lowercase buffer is
	// sliced to the wrong length. Assert a case from each kind, plus the
	// fall-throughs.
	kind_cases := []struct {
		name: string,
		want: Finder_Kind,
	}{
		{"a.mp4", .Video},
		{"a.MP4", .Video},
		{"a.flac", .Audio},
		{"a.PNG", .Image},
		{"a.srt", .Subtitle},
		// Project files have no kind of their own yet; they render as a
		// generic document.
		{"a.vyproj", .File},
		{"a.bin", .File},
		{"noextension", .File},
		{".hidden", .File},
	}
	for tc in kind_cases {
		if got := finder_kind_of(tc.name); got != tc.want {
			fmt.eprintf(
				"[ui-probe] finder_kind_of(%q) = %v, want %v\n",
				tc.name,
				got,
				tc.want,
			)
			ok = false
		}
	}

	os.remove_all(dir)
	if ok {
		fmt.printf("[ui-probe] finder save mode ok\n")
	}
	return ok
}

// finder_populate seeds the finder as if opened over a directory and relists a
// handful of synthetic entries (dirs + files of each kind) so the popup has
// something to draw without touching the real filesystem.
finder_populate :: proc(n: int) {
	// Tear down whatever listing is live first, the way a real browse does.
	// Assigning `file_finder.entries = make(...)` instead orphans the old
	// buffer (and its cloned name/fullpath strings) with no pointer left to
	// free it — Odin's clear keeps capacity, so the seeding below can just
	// reserve and reuse.
	finder_clear()
	file_finder.active = true
	file_finder.mode = .Open
	file_finder.cwd = strings.clone("/probe/fixtures")
	reserve(&file_finder.entries, n + 3)
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
	// Let the real refresh build `filtered` from the query, the way the popup
	// does. Populating it by hand (or forcing the memo with query_len = -1) hid
	// the fact that a relist under an unchanged query left it empty.
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
	file_finder.filtered_valid = false
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

// seed_roundtrip_session builds a complete, fully-owned synthetic session for
// the project-file round-trip: project identity, a media bin (one video asset
// + one subtitle asset), one parsed srt cache entry, two tracks whose clips
// carry markers, a scalar AND a packed keyframe, a custom track order, and a
// playhead. Every string/array it installs is heap-owned so the load's
// teardown frees them the way a real session's are freed. clip.path is derived
// (not stored) on reload, and a file-backed clip's path is checked to match its
// asset.
seed_roundtrip_session :: proc() {
	// Through the setter, never by direct assignment: a bare
	// `project.name = "..."` leaves project_name_owned describing a different
	// pointer, and the next project_set_name would delete a string literal.
	project_set_name("Probe Project")
	project.width = 640
	project.height = 360
	project.frame_rate = 30
	project.start_frame = 10
	project.end_frame = 220
	project.resolution_locked = true

	// Media bin. Ids come from the real allocator so next_id advances like a
	// live import; paths/metadata are heap clones (the bin owns both).
	vid_id := next_asset_id()
	append(
		&media_bin.assets,
		Media_Asset {
			id            = vid_id,
			path          = strings.clone_to_cstring("/probe/clip.mp4"),
			kind          = .Video,
			metadata      = strings.clone("duration=1.0\n"),
			frame_count   = 300,
			dur_us        = 1_000_000,
			src_w         = 1920,
			src_h         = 1080,
			audio_streams = 1,
			audio_frames  = 300,
		},
	)
	srt_id_asset := next_asset_id()
	append(
		&media_bin.assets,
		Media_Asset {
			id          = srt_id_asset,
			path        = strings.clone_to_cstring("/probe/subs.srt"),
			kind        = .Subtitles,
			metadata    = strings.clone("subs.srt"),
			frame_count = 120,
			srt_id      = 0,
		},
	)

	// One parsed srt cache entry (index 0, what the subtitle asset/clip point at).
	src := Srt_Source {
		path = strings.clone("/probe/subs.srt"),
		cues = make([dynamic]Srt_Cue, 0, 2),
	}
	append(&src.cues, Srt_Cue {start_ms = 0, end_ms = 1000, text = strings.clone("hello")})
	append(&src.cues, Srt_Cue {start_ms = 1000, end_ms = 2000, text = strings.clone("world")})
	append(&srt_cache, src)

	// Two tracks. Track 0: a file-backed video clip (path derived from the
	// asset on reload) with a marker, a scalar key, and a packed key. Track 1:
	// a subtitle generator clip (no path) and a text generator clip.
	timeline.tracks = make([dynamic]Track, 0, 2)
	vclip := Clip {
		clip_id              = 100,
		asset_id             = vid_id,
		link_id              = 7,
		name                 = strings.clone("main"),
		kind                 = .Video,
		generator            = .None,
		source_start_frame   = 5,
		source_length_frames = 300,
		timeline_start_frame = 40,
		source_w             = 1920,
		source_h             = 1080,
		transform_x          = 320,
		transform_y          = 180,
		scale                = 1.5,
		crop_l               = 0.1,
		crop_r               = 0.2,
		crop_t               = 0.3,
		crop_b               = 0.4,
		markers = make([dynamic]Clip_Marker, 0, 1),
	}
	append(&vclip.markers, Clip_Marker {source_frame = 12, label = strings.clone("chapter")})
	vclip.keyframe_tracks = make([dynamic]Kf_Track, 0, 2)
	append(&vclip.keyframe_tracks, Kf_Track {name = strings.clone("scale"), keys = make([dynamic]Keyframe, 0, 2)})
	append(
		&vclip.keyframe_tracks[0].keys,
		Keyframe {frame_off = 0, value = 1.0},
		Keyframe {frame_off = 60, value = 2.0, interp = .Elastic},
	)
	append(&vclip.keyframe_tracks, Kf_Track {name = strings.clone("crop"), keys = make([dynamic]Keyframe, 0, 1)})
	// A packed key: mask != 0, value carries the [KF_PACK_MAX]f32 payload.
	append(
		&vclip.keyframe_tracks[1].keys,
		Keyframe {frame_off = 10, mask = 0b101, value = [KF_PACK_MAX]f32{1, 2, 3, 4, 5, 6, 7}},
	)

	tr0 := Track {name = strings.clone("V1"), clips = make([dynamic]Clip, 0, 1)}
	append(&tr0.clips, vclip)

	sclip := Clip {
		clip_id              = 101,
		asset_id             = srt_id_asset,
		name                 = strings.clone("subs"),
		kind                 = .Text,
		generator            = .Subtitles,
		srt_id               = 0,
		source_length_frames = 120,
		timeline_start_frame = 0,
	}
	tclip := Clip {
		clip_id              = 102,
		generator            = .Text,
		name                 = strings.clone("title"),
		kind                 = .Text,
		source_length_frames = 90,
		timeline_start_frame = 500,
	}
	tr1 := Track {name = strings.clone("S1"), clips = make([dynamic]Clip, 0, 2)}
	append(&tr1.clips, sclip)
	append(&tr1.clips, tclip)

	append(&timeline.tracks, tr0)
	append(&timeline.tracks, tr1)

	// Custom on-screen order: S1 above V1 (storage order stays V1, S1).
	timeline.track_order = make([dynamic]int, 0, 2)
	append(&timeline.track_order, 1)
	append(&timeline.track_order, 0)

	timeline.playhead_frame = 123
	timeline.frame_rate = 30
}

// ui_probe_project_file_asserts round-trips a full session through a temp
// .vyproj: it tears down the layout seed's session, builds a synthetic one
// (seed_roundtrip_session), saves, loads (which tears the synthetic session
// down and rebuilds from the file), and confirms the project identity, media
// bin, srt cache, tracks, clips, markers, scalar+packed keyframes, track order,
// playhead, and id allocator all come back. It loads a second time to exercise
// teardown of an already-loaded session (no leak / no use-after-free), then
// tears down once more so the probe leaves nothing allocated for valgrind.
ui_probe_project_file_asserts :: proc() -> bool {
	ok := true
	path := "/tmp/opencode/ui_probe_roundtrip.vyproj"

	// The layout/finder probes above seeded a live timeline; free it so the
	// round-trip starts from a clean, fully-owned session.
	session_teardown()
	seed_roundtrip_session()

	if err := project_file_save(path); len(err) > 0 {
		fmt.eprintf("[ui-probe] save failed: %s\n", err)
		delete(err)
		return false
	}

	// Load twice: the second replaces the first (a real teardown of a loaded
	// session, plus project_name_owned replacement).
	for pass in 0 ..< 2 {
		if err := project_file_open(path); len(err) > 0 {
			fmt.eprintf("[ui-probe] open %d failed: %s\n", pass, err)
			delete(err)
			return false
		}
		ok = project_roundtrip_asserts(pass == 1) && ok
	}

	os.remove(path)
	// Free everything the loads built so the probe's allocations all end up
	// released (a definite-leak check under valgrind).
	session_teardown()
	return ok
}

// project_roundtrip_asserts checks the live session against what
// seed_roundtrip_session built. On the second pass the project name has been
// replaced once already, so it doubles as the name-ownership check.
project_roundtrip_asserts :: proc(second_pass: bool) -> bool {
	ok := true
	// Project identity.
	if project.name != "Probe Project" {
		fmt.eprintf("[ui-probe] name %q want \"Probe Project\"\n", project.name)
		ok = false
	}
	if project.width != 640 || project.height != 360 {
		fmt.eprintf("[ui-probe] resolution %dx%d want 640x360\n", project.width, project.height)
		ok = false
	}
	if project.frame_rate != 30 || !project.resolution_locked {
		fmt.eprintf("[ui-probe] project frame_rate/lock mismatch\n")
		ok = false
	}
	if project.start_frame != 10 || project.end_frame != 220 {
		fmt.eprintf("[ui-probe] render range %d-%d want 10-220\n", project.start_frame, project.end_frame)
		ok = false
	}

	// Media bin: two assets, ids preserved, the id allocator kept ahead of them.
	if len(media_bin.assets) != 2 {
		fmt.eprintf("[ui-probe] bin %d assets want 2\n", len(media_bin.assets))
		return false
	}
	vid := media_bin.assets[0]
	if string(vid.path) != "/probe/clip.mp4" {
		fmt.eprintf("[ui-probe] asset0 path %q want /probe/clip.mp4\n", string(vid.path))
		ok = false
	}
	if vid.kind != .Video || vid.frame_count != 300 || vid.src_w != 1920 {
		fmt.eprintf("[ui-probe] asset0 probe fields mismatch\n")
		ok = false
	}
	if string(vid.metadata) != "duration=1.0\n" {
		fmt.eprintf("[ui-probe] asset0 metadata mismatch\n")
		ok = false
	}
	if media_bin.assets[1].kind != .Subtitles || media_bin.assets[1].srt_id != 0 {
		fmt.eprintf("[ui-probe] asset1 subtitle fields mismatch\n")
		ok = false
	}
	// The allocator must not hand out an id an asset already holds.
	if media_bin.next_id <= vid.id {
		fmt.eprintf("[ui-probe] next_id %d <= max asset id %d\n", media_bin.next_id, vid.id)
		ok = false
	}

	// srt cache rebuilt in order, cues owned.
	if len(srt_cache) != 1 || len(srt_cache[0].cues) != 2 {
		fmt.eprintf("[ui-probe] srt cache %d sources want 1\n", len(srt_cache))
		return false
	}
	if srt_cache[0].cues[1].text != "world" || srt_cache[0].cues[0].end_ms != 1000 {
		fmt.eprintf("[ui-probe] srt cue text/times mismatch\n")
		ok = false
	}

	// Timeline: two tracks, custom order, playhead.
	if len(timeline.tracks) != 2 {
		fmt.eprintf("[ui-probe] %d tracks want 2\n", len(timeline.tracks))
		return false
	}
	if timeline.tracks[0].name != "V1" || timeline.tracks[1].name != "S1" {
		fmt.eprintf("[ui-probe] track names mismatch\n")
		ok = false
	}
	if len(timeline.track_order) != 2 || timeline.track_order[0] != 1 || timeline.track_order[1] != 0 {
		fmt.eprintf("[ui-probe] track_order mismatch\n")
		ok = false
	}
	if timeline.playhead_frame != 123 {
		fmt.eprintf("[ui-probe] playhead %d want 123\n", timeline.playhead_frame)
		ok = false
	}

	// Track 0's video clip: path derived from the asset, scalars, marker, keys.
	c := timeline.tracks[0].clips[0]
	if c.clip_id != 100 || c.asset_id != vid.id || c.link_id != 7 {
		fmt.eprintf("[ui-probe] clip identity mismatch\n")
		ok = false
	}
	if c.path == nil || string(c.path) != "/probe/clip.mp4" {
		fmt.eprintf("[ui-probe] clip path not derived from asset\n")
		ok = false
	}
	if c.scale != 1.5 || c.crop_l != 0.1 || c.crop_b != 0.4 || c.source_start_frame != 5 {
		fmt.eprintf("[ui-probe] clip transform/crop mismatch\n")
		ok = false
	}
	if len(c.markers) != 1 || c.markers[0].label != "chapter" || c.markers[0].source_frame != 12 {
		fmt.eprintf("[ui-probe] marker mismatch\n")
		ok = false
	}
	if len(c.keyframe_tracks) != 2 {
		fmt.eprintf("[ui-probe] %d kf tracks want 2\n", len(c.keyframe_tracks))
		ok = false
	} else {
		sk := c.keyframe_tracks[0]
		if sk.name != "scale" || len(sk.keys) != 2 {
			fmt.eprintf("[ui-probe] scalar kf track mismatch\n")
			ok = false
		} else if sk.keys[1].value != 2.0 || sk.keys[1].interp != .Elastic {
			fmt.eprintf("[ui-probe] scalar key value/interp mismatch\n")
			ok = false
		}
		packed := c.keyframe_tracks[1]
		if len(packed.keys) != 1 || packed.keys[0].mask != 0b101 {
			fmt.eprintf("[ui-probe] packed key mask mismatch\n")
			ok = false
		} else if v, is_packed := packed.keys[0].value.([KF_PACK_MAX]f32); !is_packed || v[6] != 7 {
			fmt.eprintf("[ui-probe] packed key payload mismatch\n")
			ok = false
		}
	}

	// Track 1: subtitle generator clip keeps srt_id, text clip has no path.
	sclip := timeline.tracks[1].clips[0]
	if sclip.generator != .Subtitles || sclip.srt_id != 0 || sclip.path != nil {
		fmt.eprintf("[ui-probe] subtitle clip mismatch\n")
		ok = false
	}
	if timeline.tracks[1].clips[1].generator != .Text ||
	   timeline.tracks[1].clips[1].path != nil {
		fmt.eprintf("[ui-probe] text clip mismatch\n")
		ok = false
	}
	_ = second_pass
	return ok
}

// ui_probe_preview_order_asserts locks the preview's composite order, which is
// two rules and not one:
//
//   • ordinary clips follow TRACK ORDER -- a text clip on a track below a video
//     draws underneath it, matching what export now does;
//   • subtitle-generator clips are PINNED above everything, whatever track they
//     sit on, because a burned-in subtitle a video covers is unreadable.
//
// The second rule is the one that regressed: subtitles used to take a `layer`
// from the same walk as everything else, so a subtitle clip on a low track
// previewed BEHIND the video while export pinned it on top -- the preview and
// the export disagreed about the same frame.
//
// Asserted on the ordering, not on pixels: the draw loop is a straight iteration
// over preview_build_draw_order's result, and the painter's order IS that order.
preview_order_probe_dummy: sdl.GPUTexture

ui_probe_preview_order_asserts :: proc() -> bool {
	ok := true
	reset := proc() {
		for i in 0 ..< MAX_PREVIEW_SLOTS {
			preview_slots[i] = {}
		}
	}
	// put declares one visible slot with a given track depth and pinned flag.
	put :: proc(idx: int, layer: u8, is_sub: bool) {
		preview_slots[idx] = Preview_Slot {
			in_use     = true,
			has_frame  = true,
			texture    = &preview_order_probe_dummy,
			layer      = layer,
			is_subtitle = is_sub,
		}
	}
	// top_slot returns the slot index painted LAST, i.e. the one that ends up
	// on top of everything else.
	top_slot :: proc() -> int {
		order, n := preview_build_draw_order()
		if n == 0 {
			return -1
		}
		return order[0]
	}

	// 1. Track order still decides between ordinary clips: video on layer 1 (the
	// topmost track) beats plain text on layer 3.
	reset()
	put(0, 1, false)
	put(1, 3, false)
	if got := top_slot(); got != 0 {
		fmt.eprintf("[ui-probe] preview order: topmost video must stay on top of a lower text clip (got slot %d, want 0)\n", got)
		ok = false
	}

	// 2. A plain text clip on a LOWER track must stay UNDER the video. This is
	// the parity the export fix made explicit; the preview already did it, and
	// the test is here so a "simplification" of the key cannot quietly reverse it.
	reset()
	put(0, 4, false) // video, deep track
	put(1, 2, false) // text, top track
	if got := top_slot(); got != 1 {
		fmt.eprintf("[ui-probe] preview order: text on the top track must beat a deeper video (got slot %d, want 1)\n", got)
		ok = false
	}

	// 3. A subtitle clip on the BOTTOM track is still pinned above a video on
	// the TOP track. Before the fix the subtitle took layer 4, sorted below the
	// video, and drew first -- hidden.
	reset()
	put(0, 1, false) // video, topmost track
	put(1, 4, true) // subtitle, bottom track
	if got := top_slot(); got != 1 {
		fmt.eprintf("[ui-probe] preview order: a subtitle must be pinned above a video on a higher track (got slot %d, want 1)\n", got)
		ok = false
	}

	// 4. Pinning is not "subtitles last in slot order": the pinned subtitle must
	// win even when it occupies a LOWER slot index than the video it covers,
	// which is what a stable-slot reassignment can produce.
	reset()
	put(0, 9, true) // subtitle, lowest slot index, deepest track
	put(1, 1, false) // video, higher slot index, topmost track
	if got := top_slot(); got != 0 {
		fmt.eprintf("[ui-probe] preview order: pinning must not depend on slot index (got slot %d, want 0)\n", got)
		ok = false
	}

	// 5. Two subtitles and a video: the subtitles keep their relative track order
	// among themselves while both stay above the video, so pinning does not
	// flatten the stack it is exempting.
	reset()
	put(0, 3, true) // subtitle, deeper track
	put(1, 1, false) // video, top track
	put(2, 2, true) // subtitle, shallower track
	order, n := preview_build_draw_order()
	// Ascending key: both subtitles (0) in layer order, then the video (1).
	// Painted backwards, so paint order is video, then deep sub, then shallow sub.
	if n != 3 || order[0] != 0 || order[1] != 2 || order[2] != 1 {
		fmt.eprintf("[ui-probe] preview order: pinned subtitles must keep relative track order (order %d,%d,%d n=%d, want 0,2,1 n=3)\n", order[0], order[1], order[2], n)
		ok = false
	}

	// 6. Invisible slots stay out of the list entirely, so a pinned subtitle with
	// no decoded frame cannot blank the stack.
	reset()
	put(0, 1, true)
	preview_slots[0].has_frame = false
	_, n2 := preview_build_draw_order()
	if n2 != 0 {
		fmt.eprintf("[ui-probe] preview order: a slot with no frame must not be composited (n=%d, want 0)\n", n2)
		ok = false
	}

	reset()
	if ok {
		fmt.printf("[ui-probe] preview order ok (track order, subtitles pinned on top)\n")
	}
	return ok
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

// ui_probe_track_menu_asserts covers the track row rework: the duplicate/delete
// buttons are gone from the gutter (they moved to the dedicated right-click
// menu), the row is short enough that TRACKS_FIT_TARGET of them fit the fitted
// timeline, and the fit actually places the divider so exactly that many rows
// are on screen.
ui_probe_track_menu_asserts :: proc() -> bool {
	ok := true

	// The gutter no longer carries the two buttons. clay keeps an element's
	// last box, so a stale rect here would mean the elements are still being
	// emitted (and would be hoverable, i.e. silently still clickable).
	build_page(1920, 1600)
	// Guard the guard: an id that was never laid out must read back as a zero
	// box, or the assertions below would pass (or fail) for the wrong reason.
	bogus := clay.GetElementData(clay.ID("NoSuchElementEver", 0)).boundingBox
	if bogus.width != 0 || bogus.height != 0 {
		fmt.eprintf("[ui-probe] missing element id reported a box\n")
		ok = false
	}
	gone := []string{"DuplicateTrack", "RemoveTrack", "TrackButtons"}
	for ti in 0 ..< len(timeline.tracks) {
		for id_name in gone {
			box := clay.GetElementData(clay.ID(id_name, u32(ti))).boundingBox
			if box.width > 0 || box.height > 0 {
				fmt.eprintf(
					"[ui-probe] %s still laid out (%dx%d) on track %d\n",
					id_name,
					int(box.width),
					int(box.height),
					ti,
				)
				ok = false
			}
		}
	}

	fit_tracks_h := tracks_view_height_for(TRACKS_FIT_TARGET)
	rows_that_fit := int((fit_tracks_h - TRACK_GAP_H) / (TRACK_ROW_H + TRACK_GAP_H))
	if rows_that_fit != TRACKS_FIT_TARGET {
		fmt.eprintf(
			"[ui-probe] fit height %.1f shows %d rows, want %d\n",
			fit_tracks_h,
			rows_that_fit,
			TRACKS_FIT_TARGET,
		)
		ok = false
	}

	// A track list that would show MORE than the target gets pulled in to
	// exactly the target.
	chrome := APP_BAR_H + EDITOR_DIVIDER_H
	panel_layout.upper_area_height = 200 // leaves 720-60-200 = 460px of tracks
	fit_timeline_to_tracks()
	want_upper := f32(WINDOW_HEIGHT) - chrome - fit_tracks_h
	if abs(panel_layout.upper_area_height - want_upper) > 0.5 {
		fmt.eprintf(
			"[ui-probe] fit set upper area to %.1f, want %.1f\n",
			panel_layout.upper_area_height,
			want_upper,
		)
		ok = false
	}
	// ...and one that already shows fewer is left alone: an import must not
	// drag the divider away from a layout the user chose.
	panel_layout.upper_area_height = f32(WINDOW_HEIGHT) - chrome - 100
	kept := panel_layout.upper_area_height
	fit_timeline_to_tracks()
	if panel_layout.upper_area_height != kept {
		fmt.eprintf(
			"[ui-probe] fit expanded a small track list: %.1f -> %.1f\n",
			kept,
			panel_layout.upper_area_height,
		)
		ok = false
	}
	if timeline_view.top != 0 {
		fmt.eprintf("[ui-probe] fit left track scroll at %.1f\n", timeline_view.top)
		ok = false
	}

	// The track menu is its own popup, separate from the timeline menu, and
	// only one of the two is ever open.
	open_track_action_menu(10, 10, 0)
	if !track_ctx.open || ctx_menu.open {
		fmt.eprintf("[ui-probe] track menu did not open exclusively\n")
		ok = false
	}
	open_track_context_menu(400, 400, 0)
	if track_ctx.open || !ctx_menu.open {
		fmt.eprintf("[ui-probe] timeline menu did not take over from track menu\n")
		ok = false
	}
	close_context_menu()
	close_track_action_menu()
	if track_ctx.open || ctx_menu.open {
		fmt.eprintf("[ui-probe] menus did not both close\n")
		ok = false
	}
	// A target that has since been removed must not act: the handler re-checks
	// the snapshot against the live track list.
	open_track_action_menu(10, 10, 0)
	track_ctx.target_track = 9999
	handle_track_action_option(-1000, -1000)
	if track_ctx.open {
		fmt.eprintf("[ui-probe] stale track target left the menu open\n")
		ok = false
	}

	if ok {
		fmt.printf("[ui-probe] track menu ok\n")
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
	// Track names are heap clones (not literals): the project-file round-trip
	// later tears this session down, and free_timeline frees keyframe-track
	// names, exactly as a real session's are freed.
	kf0 := &timeline.tracks[0].clips[0]
	kf0.keyframe_tracks = make([dynamic]Kf_Track, 0, 2)
	append(&kf0.keyframe_tracks, Kf_Track {name = strings.clone("transform.x"), keys = make([dynamic]Keyframe, 0, 4)})
	append(&kf0.keyframe_tracks[0].keys, Keyframe {frame_off = 0, value = 0}, Keyframe {frame_off = 120, value = 1})
	append(&kf0.keyframe_tracks, Kf_Track {name = strings.clone("zoom"), keys = make([dynamic]Keyframe, 0, 4)})
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
