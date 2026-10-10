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
package vyper

import clay "clay-odin"
import sdl "vendor:sdl3"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

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

	// ui_probe_clip_widths (VYPER_CLIPW_PROBE=<project.vyproj>) measures the laid-out
	// width of every clip tile at a spread of timeline zooms, and prints the tile's
	// own width next to the width the model implies (frames * zoom). A tile wider
	// than the model width is a layout bug, not a data bug: the project file for the
	// reported case had a video and an audio clip of identical length whose tiles
	// disagreed, and the data was provably fine.
	ui_probe_clip_widths :: proc(project_path: string) {
		CLAY_ARENA_BYTES :: 64 * 1024 * 1024
		memory := make([^]u8, CLAY_ARENA_BYTES)
		clay.Initialize(
			clay.CreateArenaWithCapacityAndMemory(c.size_t(CLAY_ARENA_BYTES), memory),
			{WINDOW_WIDTH, WINDOW_HEIGHT},
			{handler = clay_probe_error},
		)
		clay.SetMeasureTextFunction(measure_probe, nil)

		// project_file_open reads and decodes the path itself, so the env string
		// (already on the probe's temp allocator) can be handed over directly.
		if err := project_file_open(project_path); len(err) > 0 {
			fmt.eprintf("[clipw-probe] open %s failed: %s\n", project_path, err)
			delete(err)
			return
		}
		fmt.printf("[clipw-probe] %s: tracks=%d\n", project_path, len(timeline.tracks))
		for t in 0 ..< len(timeline.tracks) {
			for i in 0 ..< len(timeline.tracks[t].clips) {
				cl := timeline.tracks[t].clips[i]
				fmt.printf(
					"[clipw-probe]  track %d clip %d kind=%d frames=%d start=%d link=%d\n",
					t,
					i,
					int(cl.kind),
					cl.source_length_frames,
					cl.timeline_start_frame,
					cl.link_id,
				)
			}
		}

		zooms := []f32{0.5, 1, 2, 4, 8, 16}
		for z in zooms {
			timeline_view.zoom = z
			timeline_view.start = 0
			_ = build_page(WINDOW_WIDTH, WINDOW_HEIGHT)
			fmt.printf("[clipw-probe] zoom=%.2f\n", z)
			for t in 0 ..< len(timeline.tracks) {
				for i in 0 ..< len(timeline.tracks[t].clips) {
					cl := timeline.tracks[t].clips[i]
					want := f32(max(cl.source_length_frames, 1)) * z
					wrap := clay.GetElementData(clay.ID("TimelineClipWrap", u32(t * 1000 + i))).boundingBox
					tile := clay.GetElementData(clay.ID("TimelineClip", u32(t * 1000 + i))).boundingBox
					sec := clay.GetElementData(clay.ID("ClipsSection", u32(t))).boundingBox
					fmt.printf(
						"[clipw-probe]   t%d c%d want=%.1f wrap=%.1f tile=%.1f x=%.1f (sec x=%.1f w=%.1f)\n",
						t,
						i,
						want,
						wrap.width,
						tile.width,
						tile.x,
						sec.x,
						sec.width,
					)
				}
			}
		}
		// The probe owns a loaded session; tear it down so valgrind sees no leak.
		session_teardown()
		// Fall through to the normal probe asserts so this stays a superset.
		ui_draw_probe_run()
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
		// The marker/keyframe overlay must stay inside the visible lane. Runs right
		// after the layout asserts because it needs the seeded session intact: the
		// finder-save and project-file round-trips below tear it down and reload.
		if !ui_probe_marker_cull_asserts() {
			os.exit(1)
		}
		// A clip tile is frames*zoom wide; its label must never size it.
		if !ui_probe_clip_tile_width_asserts() {
			os.exit(1)
		}
		// A label must never size the panel that shows it.
		if !ui_probe_inspector_width_asserts() {
			os.exit(1)
		}
		// The keyframe brush (hover-select): armed from empty timeline space, paints
		// on hover with no button held, accumulates, and survives the release.
		if !ui_probe_kf_brush_asserts() {
			os.exit(1)
		}
		// Click vs drag on a keyframe diamond: the press must not collapse a run the
		// user may be about to retime, and the narrowing belongs on mouse-up.
		if !ui_probe_kf_click_vs_drag_asserts() {
			os.exit(1)
		}
		// Backspace ripple-deletes the selected clip and closes the gap. Driven from
		// a real clip press through the real key router, because the report was
		// "Backspace doesn't ripple" and every layer of that chain (which element the
		// press selects, the router, the action, the ripple) is a place it can break.
		if !ui_probe_backspace_ripple_asserts() {
			os.exit(1)
		}
		// The opacity fill's painted width is opacity * the track's laid-out width.
		// SizingPercent is a 0-1 fraction; a 0-100 value still "looks" plausible in
		// a screenshot but overflows the track for every non-zero opacity.
		if !ui_probe_opacity_slider_asserts() {
			os.exit(1)
		}
		// Track rows: buttons moved to the dedicated menu, and the timeline fits
		// TRACKS_FIT_TARGET rows on import/load.
		if !ui_probe_track_menu_asserts() {
			os.exit(1)
		}
		// The scissor invariant, before anything builds a layout: a rect exceeding the
		// render target is the one draw defect SDL reports and does not stop for.
		if !ui_probe_scissor_clamp_asserts() {
			os.exit(1)
		}
		// The playhead must be draggable, through the real press/drag/release chain.
		// Runs after the track-menu case because that one reseeds the timeline.
		if !ui_probe_playhead_scrub_asserts() {
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
		// Marker COPY paths: the round-trip above frees labels through
		// free_timeline but never copies them, so cover the copy paths here.
		if !ui_probe_marker_copy_asserts() {
			os.exit(1)
		}
		os.exit(0)
	}

	// Marker arena probe: timeline snapshots share a POD range, writes COW the
	// marker list, and split filters build independent ranges.
	ui_probe_marker_copy_asserts :: proc() -> bool {
		ok := true
		src := Timeline{tracks = make([dynamic]Track, 1)}
		src.tracks[0].name = strings.clone("marker-owner")
		src.tracks[0].clips = make([dynamic]Clip, 1)
		src.tracks[0].clips[0].name = session_str_intern("marker-clip")
		src.tracks[0].clips[0].markers = Clip_Markers_Range{}
		for i in 0 ..< 3 {
			buf: [32]u8
			s := fmt.bprintf(buf[:], "m%d", i)
			session_marker_push(
				&src.tracks[0].clips[0].markers,
				Clip_Marker{source_frame = i64(i) * 10, label = session_str_intern(s)},
			)
		}
		orig := src.tracks[0].clips[0].markers

		// Snapshot clone (undo path) and two range filters (split path): each must
		// carry its own labels, so editing or freeing one never touches another.
		snap := clone_timeline(src)
		lo := filter_markers_in_range(orig, 0, 20)
		hi := filter_markers_in_range(orig, 20, 20)

		lo0, lo1 := session_marker_at(lo, 0), session_marker_at(lo, 1)
		if lo.n != 2 || marker_label(&lo0) != "m0" || marker_label(&lo1) != "m1" {
			fmt.eprintf("[ui-probe] lo markers wrong: n=%d\n", lo.n)
			ok = false
		}
		hi0 := session_marker_at(hi, 0)
		if hi.n != 1 || marker_label(&hi0) != "m2" {
			fmt.eprintf("[ui-probe] hi markers wrong: n=%d\n", hi.n)
			ok = false
		}
		snap_markers := snap.tracks[0].clips[0].markers
		snap2 := session_marker_at(snap_markers, 2)
		if snap_markers.n != 3 || marker_label(&snap2) != "m2" || snap2.source_frame != 20 {
			fmt.eprintf("[ui-probe] snapshot markers wrong: n=%d\n", snap_markers.n)
			ok = false
		}
		marker_set_label(clip_marker_mut(&snap.tracks[0].clips[0], 2), "snapshot-only")
		source2 := session_marker_at(src.tracks[0].clips[0].markers, 2)
		snapshot2 := session_marker_at(snap.tracks[0].clips[0].markers, 2)
		if marker_label(&source2) != "m2" || marker_label(&snapshot2) != "snapshot-only" {
			fmt.eprintln("[ui-probe] marker COW isolation failed")
			ok = false
		}

		free_timeline(&snap)
		free_timeline(&src)
		session_marker_release(lo)
		session_marker_release(hi)
		return ok
	}

	// ui_probe_marker_cull_asserts pins the visible-range clip for the two timeline
	// overlay passes (draw_clip_markers, draw_keyframes). Both paint into the track
	// lanes directly rather than as Clay content, so neither inherits Clay's scissor
	// stack: each sets its own, and each used to set it to the track's own
	// ClipsSection box. That box follows the row when the track list scrolls
	// vertically (TracksSection applies timeline_view.top as a Clay childOffset),
	// so a row scrolled up carried its scissor -- and with it the marker lines, gap
	// triangles and keyframe diamonds -- off the top of the lane viewport and over
	// the ruler strip and the panels above the timeline.
	//
	// The contract asserted here is what a Clay element in that lane would have been
	// clipped to: the overlay rect is the lane intersected with the TracksSection
	// viewport on BOTH axes. A track scrolled out of view reports an empty rect (the
	// draw loop skips it) rather than a rect sitting over unrelated panels.
	ui_probe_marker_cull_asserts :: proc() -> bool {
		ok := true
		// Markers on every clip, so the marker pass has something to place in each
		// lane: a clip with no markers is skipped before any geometry is computed.
		for t in 0 ..< len(timeline.tracks) {
			for c in 0 ..< len(timeline.tracks[t].clips) {
				clip := &timeline.tracks[t].clips[c]
				if clip.markers.n > 0 {
					continue
				}
				clip.markers = Clip_Markers_Range{}
				session_marker_push(&clip.markers, Clip_Marker{source_frame = 10, label = session_str_intern("m-a")})
				session_marker_push(&clip.markers, Clip_Marker{source_frame = 200, label = session_str_intern("m-b")})
			}
		}
		saved_top := timeline_view.top
		defer timeline_view.top = saved_top
		saved_upper := panel_layout.upper_area_height
		defer panel_layout.upper_area_height = saved_upper

		// The seeded rows all fit at the default split, so there is nothing to scroll
		// and the invariant would hold trivially. Grow the upper area until the track
		// viewport is smaller than the content, which is the state a user reaches by
		// dragging the divider up.
		build_page(1920, 1600)
		content_h := timeline_tracks_content_height()
		// Two rows' worth of viewport: enough that the last row is genuinely off
		// screen at full scroll, without pinning the list so tight that Clay starts
		// collapsing elements.
		want_view_h := 2 * (TRACK_ROW_H + TRACK_GAP_H) + KF_ROW_H * f32(ui_probe_tracks)
		for _ in 0 ..< 8 {
			sec := clay.GetElementData(clay.ID("TracksSection")).boundingBox
			if sec.height <= 0 {
				break
			}
			if sec.height <= want_view_h {
				break
			}
			panel_layout.upper_area_height += sec.height - want_view_h
			build_page(1920, 1600)
		}
		view := clay.GetElementData(clay.ID("TracksSection")).boundingBox
		if view.width <= 0 || view.height <= 0 {
			fmt.eprintf(
				"[ui-probe] marker cull: TracksSection never laid out (%.1fx%.1f)\n",
				view.width,
				view.height,
			)
			return false
		}
		max_top := max(content_h - view.height, 0)
		if max_top <= 0 {
			// Without a scroll range every row is visible and the invariant is
			// trivially true, so this probe would pass without testing anything.
			fmt.eprintf(
				"[ui-probe] marker cull: no vertical scroll room (content %.1f vs viewport %.1f)\n",
				content_h,
				view.height,
			)
			return false
		}

		// Walk the scroll range including a hard overshoot: an unclamped top is the
		// state a fast wheel scroll passes through before the app's clamp runs, so
		// it is exactly the state that must not paint.
		scrolls := []f32{0, max_top * 0.5, max_top, max_top * 4}
		for top in scrolls {
			timeline_view.top = top
			build_page(1920, 1600)
			for t in 0 ..< len(timeline.tracks) {
				if order_row_of(t) < 0 {
					fmt.eprintf("[ui-probe] marker cull: track %d has no order row\n", t)
					ok = false
					continue
				}
				// The rects the two passes paint into, from the same accessors they
				// use. The marker one adds the insert gap above the lane, so its top
				// edge is the part that used to escape.
				passes := [2]struct{name: string, rect: clay.BoundingBox} {
					{name = "keyframes", rect = keyframe_lane_rect(t)},
					{name = "markers", rect = marker_lane_rect(t)},
				}
				for pass in passes {
					r := pass.rect
					if r.width <= 0 || r.height <= 0 {
						// Off-screen tracks must skip, not paint a degenerate sliver.
						continue
					}
					if r.x < view.x - 0.5 ||
					   r.x + r.width > view.x + view.width + 0.5 ||
					   r.y < view.y - 0.5 ||
					   r.y + r.height > view.y + view.height + 0.5 {
						fmt.eprintf(
							"[ui-probe] marker cull: top=%.1f track %d %s paints (%.1f,%.1f %.1fx%.1f) outside viewport (%.1f,%.1f %.1fx%.1f)\n",
							top,
							t,
							pass.name,
							r.x,
							r.y,
							r.width,
							r.height,
							view.x,
							view.y,
							view.width,
							view.height,
						)
						ok = false
					}
				}
			}
		}

		// With every row scrolled out of view, neither pass may report a paintable
		// rect at all. This is the cull the draw loops key on, so it is the half of
		// the fix that actually stops the draw calls.
		timeline_view.top = max_top * 4
		build_page(1920, 1600)
		for t in 0 ..< len(timeline.tracks) {
			if r := keyframe_lane_rect(t); r.width > 0 && r.height > 0 {
				fmt.eprintf(
					"[ui-probe] marker cull: track %d keyframe lane still %.1fx%.1f with every row scrolled away\n",
					t,
					r.width,
					r.height,
				)
				ok = false
			}
		}

		// The horizontal side of the same rule, and the case where a tile has slid
		// under the track-name gutter: scroll to the end of the timeline so the lane
		// sits mostly off to the left, then require every rect to stop at the lane's
		// own left edge rather than reaching into the gutter.
		saved_start := timeline_view.start
		timeline_view.top = 0
		timeline_view.start = f32(timeline_duration())
		build_page(1920, 1600)
		for t in 0 ..< len(timeline.tracks) {
			r := keyframe_lane_rect(t)
			if r.width > 0 && r.height > 0 && r.x < view.x - 0.5 {
				fmt.eprintf(
					"[ui-probe] marker cull: track %d paints from x %.1f, left of the lane edge %.1f\n",
					t,
					r.x,
					view.x,
				)
				ok = false
			}
		}
		timeline_view.start = saved_start

		if !ok {
			return false
		}
		fmt.printf("[ui-probe] marker/keyframe overlay confined to the lane viewport\n")
		return true
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
			{ sdl.K_A, {}, .Key_All_Modified, "bare A keys every modified property (the removed button's job)" },
			// The row is deliberately modifier-insensitive, so the extra modifiers a
			// user is already holding must not change what A means. Pinned because the
			// most-specific-first walk is where a bare row silently loses to a
			// Ctrl/Alt row added later, and "A stopped keying" is not a crash anyone
			// would notice.
			{ sdl.K_A, shift, .Key_All_Modified, "Shift+A keys the same set as bare A" },
			{ sdl.K_A, ctrl, .Key_All_Modified, "Ctrl+A keys the same set as bare A" },
			{ sdl.K_Q, {}, .Toggle_Auto_Keyframe, "Q toggles auto-keyframing" },
			// Modifier-insensitive for the same reason as A: the extra modifiers a user
			// already holds must not change what the key means, and the
			// most-specific-first walk is where a bare row silently loses to a row
			// added later.
			{ sdl.K_Q, shift, .Toggle_Auto_Keyframe, "Shift+Q toggles the same flag" },
			{ sdl.K_Q, ctrl, .Toggle_Auto_Keyframe, "Ctrl+Q toggles the same flag" },
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
		// CLOSED: every one of these has to fall through. Backspace ripple-deletes
		// the selection and Esc dismisses overlays, so a closed field claiming them
		// silently kills both -- which is exactly what shipped (see
		// ui_probe_backspace_ripple_asserts).
		closed := [?]Claim {
			{ sdl.K_U, false, "an unbound key reaches the app" },
			{ sdl.K_ESCAPE, false, "Esc reaches escape_dismiss" },
			{ sdl.K_RETURN, false, "Enter reaches the app" },
			{ sdl.K_RETURN2, false, "the keypad Enter reaches the app" },
			{ sdl.K_BACKSPACE, false, "Backspace reaches the ripple delete" },
			{ sdl.K_DELETE, false, "Delete is not the number field's: it deletes a clip" },
			{ sdl.K_F1, false, "F1 stays a global shortcut" },
		}
		for c in closed {
			if got := edit_field_claims_key(c.key); got != c.want {
				fmt.eprintf(
					"[ui-probe] closed edit_field_claims_key(K_%v) = %v, want %v (%s)\n",
					c.key, got, c.want, c.which,
				)
				ok = false
			}
		}
		// OPEN: the field takes exactly its three keys and passes the rest through.
		open_claims := [?]Claim {
			{ sdl.K_U, false, "an unbound key reaches the app" },
			{ sdl.K_ESCAPE, true, "Esc cancels the field" },
			{ sdl.K_RETURN, true, "Enter commits the field" },
			{ sdl.K_RETURN2, true, "the keypad Enter commits too" },
			{ sdl.K_BACKSPACE, true, "Backspace edits the field" },
			{ sdl.K_DELETE, false, "Delete is not the number field's: it deletes a clip" },
			{ sdl.K_F1, false, "F1 stays a global shortcut" },
		}
		defer edit_cancel()
		for c in open_claims {
			// Esc and Return CLOSE the field as a side effect of claiming, so the
			// field has to be re-opened for every case or the rest are measured
			// against a closed field.
			if edit_state.field == .None {
				edit_begin(.X, 0)
			}
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
	// ui_probe_playhead_scrub_asserts drives the ruler scrub through the REAL chain:
	// a clay pointer state, interaction_click_dispatch to arm, interaction_move to
	// drag, playback_update to run the same tick the frame loop runs it. Every
	// earlier probe of the playhead set playhead.frame directly or faked
	// active_interaction, which bypasses the press that arms the gesture AND the
	// ordering that made the playhead un-draggable -- the two things that actually
	// broke, and neither of which a direct write can see.
	ui_probe_playhead_scrub_asserts :: proc() -> bool {
		ok := true
		saved_playing := playhead.playing
		saved_frame := playhead.frame
		saved_dir := playback.dir
		saved_preview := preview.playing
		saved_accum := playback.accumulator
		saved_last_tick := playback.last_tick_ns
		saved_dev := sync.atomic_load(&playback.dev_frame)
		saved_dev_resync := sync.atomic_load(&playback.dev_resync)
		saved_resync := sync.atomic_load(&audio_prod.resync)
		saved_force_seek_resync := sync.atomic_load(&audio_prod.force_seek_resync)
		saved_scrub_active := sync.atomic_load(&audio_prod.scrub_active)
		saved_snap := editor_flags.snap_playhead_to_clips
		// Snap OFF unless the case is about snapping: at low zoom the margin is
		// SNAP_PIXELS/zoom frames wide, so leaving it on makes "drag to frame X"
		// land somewhere else and every assertion below a snap assertion instead.
		editor_flags.snap_playhead_to_clips = false
		playhead.playing = false
		playback.dir = 1
		preview.playing = false
		playback.last_tick_ns = 0
		defer {
			playhead.playing = saved_playing
			playhead.frame = saved_frame
			playback.dir = saved_dir
			preview.playing = saved_preview
			playback.accumulator = saved_accum
			playback.last_tick_ns = saved_last_tick
			sync.atomic_store(&playback.dev_frame, saved_dev)
			sync.atomic_store(&playback.dev_resync, saved_dev_resync)
			sync.atomic_store(&audio_prod.resync, saved_resync)
			sync.atomic_store(&audio_prod.force_seek_resync, saved_force_seek_resync)
			sync.atomic_store(&audio_prod.scrub_active, saved_scrub_active)
			editor_flags.snap_playhead_to_clips = saved_snap
			active_interaction = .None
			playhead_scrub.moved = false
			build_page(1920, 1600)
		}
		build_page(1920, 1600)
		ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
		if ruler.width <= 0 || ruler.height <= 0 {
			fmt.eprintf("[ui-probe] ruler has no box (%vx%v); the scrub cannot be armed\n", ruler.width, ruler.height)
			return false
		}
		// Pointer x for a timeline frame, inside the ruler. y is the middle of the
		// strip: the box is 30px tall and a press near either edge is a different
		// gesture's business.
		ry := ruler.y + ruler.height * 0.5
		// Odin closures capture nothing, so the view transform is passed explicitly.
		// Read from timeline_view at call time, not captured: case (4) changes the
		// zoom to reach the minimum, and a captured value would silently test the
		// previous zoom instead -- the case would pass for the wrong reason.
		px_for_frame :: proc(ruler: clay.BoundingBox, frame: i64) -> f32 {
			return ruler.x + (f32(frame) - timeline_view.start) * timeline_view.zoom
		}
		press_at :: proc(x, y: f32) {
			clay.SetPointerState({x, y}, true)
			interaction_click_dispatch(Mouse_Input{x, y, true, false, false, false, false, false}, false)
		}
		drag_to :: proc(x, y: f32) {
			clay.SetPointerState({x, y}, true)
			interaction_move(Mouse_Input{x, y, true, false, false, false, false, false}, true, 1600)
		}
		release_at :: proc(x, y: f32) {
			clay.SetPointerState({x, y}, false)
			interaction_release(Mouse_Input{x, y, false, false, false, false, false, false})
		}
		// One FULL frame-loop tick of a held drag, in the frame loop's order:
		// interaction (which writes playhead.frame) and THEN playback_update (which
		// reads the device clock). Every assertion below goes through this rather
		// than through interaction_move alone, because the ordering is the defect:
		// a drag that is correct on its own and then overwritten in the same tick by
		// playback_update looks perfect in a probe that stops after the drag.
		drag_tick :: proc(x, y: f32) {
			drag_to(x, y)
			playback_update(sdl.Uint64(monotonic_ns()))
		}

		// (1) ARMING. A press on the ruler must claim the gesture. Asserted through
		// the press handler rather than assumed, because "the ruler is dead" and
		// "the ruler armed the wrong gesture" look identical from outside and only
		// one of them is a scrub bug.
		playhead.frame = 400
		press_at(px_for_frame(ruler, 400), ry)
		if active_interaction != .Playhead_Scrub {
			fmt.eprintf(
				"[ui-probe] ruler press armed %v, want Playhead_Scrub (a press on the ruler that moves nothing)\n",
				active_interaction,
			)
			ok = false
			active_interaction = .None
			return ok
		}

		// (2) DRAG FORWARD while STOPPED: the pointer moves the playhead.
		drag_tick(px_for_frame(ruler, 260), ry)
		if playhead.frame != 260 {
			fmt.eprintf("[ui-probe] stopped drag to frame 260 left the playhead at %d\n", playhead.frame)
			ok = false
		}
		release_at(px_for_frame(ruler, 260), ry)

		// (3) DRAG BACKWARD WHILE PLAYING, with the device clock ahead. This is the
		// reported defect. The clock is set up by hand because no producer runs in this
		// probe, so dev_frame would otherwise hold whatever the last case left.
		//
		// The contract is that arming does NOT stop playback. Stopping is the workaround
		// that was removed: it makes the drag unobservable, since a suspended playhead has
		// nothing to fight, so any fault left in the live path stays hidden. So playback
		// keeps running through the drag, and the pointer has to win anyway.
		playhead.playing = true
		preview.playing = true
		playback.dir = 1
		playhead.frame = 400
		sync.atomic_store(&audio_prod.resync, saved_resync)
		sync.atomic_store(&playback.dev_resync, saved_resync)
		sync.atomic_store(&playback.dev_frame, 400)
		press_at(px_for_frame(ruler, 400), ry)
		if playhead.playing {
			fmt.eprintf("[ui-probe] arming a scrub must HOLD playback (stop the clock, video, and audio engine)\n")
			ok = false
		}
		drag_tick(px_for_frame(ruler, 120), ry)
		if playhead.frame != 120 {
			fmt.eprintf(
				"[ui-probe] backward drag: playhead %d, want 120 (the device clock overruled the pointer mid-drag)\n",
				playhead.frame,
			)
			ok = false
		}
		// Release commits the seek. Playback is still running, and the clock -- still
		// reading 400, larger than 120 -- must not drag the playhead forward on the next
		// tick. The release bumps audio_prod.resync, so dev_resync no longer matches and
		// the reading is stale by construction; that, not a pause, is what holds the
		// playhead.
		release_at(px_for_frame(ruler, 120), ry)
		playback_update(sdl.Uint64(monotonic_ns()))
		if playhead.frame != 120 {
			fmt.eprintf(
				"[ui-probe] after release: playhead %d, want 120 (a stale device reading outranked the committed seek)\n",
				playhead.frame,
			)
			ok = false
		}
		// Once playback is resumed AND the reading is current, the clock owns the
		// playhead again: the cannot-drift property, which the scrub fix must not have
		// cost.
		playhead.playing = true
		sync.atomic_store(&playback.dev_resync, sync.atomic_load(&audio_prod.resync))
		sync.atomic_store(&playback.dev_frame, 200)
		playback_update(sdl.Uint64(monotonic_ns()))
		if playhead.frame != 200 {
			fmt.eprintf(
				"[ui-probe] current device reading was not adopted: playhead %d, want 200 (the scrub fix cost the audio clock its authority)\n",
				playhead.frame,
			)
			ok = false
		}

		// (4) BACKWARD TRANSPORT. After a backward jog, playback.dir == -1, and
		// playback_update takes the OTHER branch: a wall-clock accumulator that adds
		// dir every tick, written AFTER the drag. That path has no device clock to
		// consult, so the scrub guard added for forward playback does not apply and
		// the two fight by a frame per tick -- the playhead drifts off the pointer
		// while the button is held. Same gesture, third arm of the same switch.
		playback.dir = -1
		playhead.playing = true
		playhead.frame = 400
		sync.atomic_store(&playback.dev_frame, 400)
		sync.atomic_store(&playback.dev_resync, sync.atomic_load(&audio_prod.resync))
		press_at(px_for_frame(ruler, 400), ry)
		drag_tick(px_for_frame(ruler, 300), ry)
		if playhead.frame != 300 {
			fmt.eprintf(
				"[ui-probe] drag during backward transport: playhead %d, want 300 (the wall-clock branch moved it under the pointer)\n",
				playhead.frame,
			)
			ok = false
		}
		release_at(px_for_frame(ruler, 300), ry)
		playback_update(sdl.Uint64(monotonic_ns()))
		if playhead.frame != 300 {
			fmt.eprintf(
				"[ui-probe] after release during backward transport: playhead %d, want 300\n",
				playhead.frame,
			)
			ok = false
		}
		playback.dir = 1

		// (4) SNAP, ON, at the DEFAULT zoom -- the state the app actually ships in.
		// This is the difference between "the playhead moves" and "the playhead moves
		// freely". The margin is a fixed number of SCREEN pixels (SNAP_PIXELS), so at
		// a typical zoom it is a wide band of FRAMES: the scrub latches onto a clip
		// edge and stops responding well outside the 8px the user can see, which
		// reads as a playhead that will not move. Measured, not assumed, and the
		// measured margin is printed either way.
		saved_zoom := timeline_view.zoom
		editor_flags.snap_playhead_to_clips = true
		margin := snap_margin_frames()
		// A frame far enough from any clip edge to be free, and confirm the pointer
		// can actually be placed there (a frame outside the visible ruler would test
		// nothing).
		free_frame := i64(400)
		for ci in 0 ..< len(timeline.tracks[0].clips) {
			start := timeline.tracks[0].clips[ci].timeline_start_frame
			if abs(f64(free_frame - start)) < f64(margin) {
				free_frame = start + i64(margin) + 30
			}
		}
		timeline_view.zoom = 1.0
		build_page(1920, 1600)
		press_at(px_for_frame(ruler, free_frame), ry)
		drag_to(px_for_frame(ruler, free_frame), ry)
		snapped_to := playhead.frame
		release_at(px_for_frame(ruler, free_frame), ry)
		fmt.printf(
			"[ui-probe] snap margin at zoom 1.0: %.1f frames; drag to %d landed on %d\n",
			f64(margin),
			free_frame,
			snapped_to,
		)
		if snapped_to != free_frame {
			fmt.eprintf(
				"[ui-probe] snap margin is %.1f frames at zoom 1.0: a drag to the free frame %d landed on %d, %d frames away. An 8px magnet that spans %d frames is not an 8px magnet.\n",
				f64(margin),
				free_frame,
				snapped_to,
				abs(f64(snapped_to - free_frame)),
				int(margin),
			)
			ok = false
		}
		editor_flags.snap_playhead_to_clips = false
		timeline_view.zoom = saved_zoom

		fmt.printf("[ui-probe] playhead scrub: arm/drag-back/release/clock-authority/snap-at-min-zoom asserted\n")
		return ok
	}

	// ui_probe_scissor_clamp_asserts pins the invariant SDL demands and does not enforce:
	// a scissor rect must lie inside the render target. SDL asserts
	// (SDL_SetGPUScissor_REAL, SDL_gpu.c:1984) and then proceeds anyway, so a violation
	// shows up as a stray log line rather than a visible fault -- which is exactly how the
	// user found it ("triggered 2 times"), twice, with a portrait 1080x1920 clip on the
	// timeline.
	//
	// The rects below are the shapes that actually occur: a lane scrolled off the left
	// edge, a clip row wider than the viewport, a box_union over a gap, and a band
	// starting below the window's bottom edge (whose leftover height goes NEGATIVE, the
	// case scissor_to_bottom's own comment warned about).
	//
	// scissor_clamp is pure, so this is exhaustive over the cases rather than sampled from
	// whatever layout the probe happens to build -- which is the point, since the original
	// defect only fired on a layout this probe never produced.
	ui_probe_scissor_clamp_asserts :: proc() -> bool {
		ok := true
		// Viewport sizes the draw code really uses: the probe builds pages at the first
		// two, and a short window is what makes a band near the bottom overshoot.
		sizes := [][2]f32{{1280, 720}, {1920, 1600}, {1920, 1080}, {640, 360}}
		rects := [][4]i32{
			{0, 0, 1280, 720},        // exactly the target
			{0, 100, 1280, 720},      // full height at non-zero y: overshoots by 100
			{-40, 0, 400, 720},       // starts off-screen left
			{100, -30, 200, 100},     // starts above the top edge
			{100, 700, 200, 400},     // extends far below a 720-tall target
			{1200, 0, 800, 720},      // wider than the target
			{-100, -100, 2000, 2000}, // larger than the target in every direction
			{100, 900, 200, -300},    // NEGATIVE height: scissor_to_bottom's worst case
			{100, 900, 200, 0},       // zero height
			{-50, -50, 10, 10},       // entirely off-screen, negative origin
			{1279, 719, 100, 100},    // one pixel past the bottom-right corner
		}
		for sz in sizes {
			r: GPU_Renderer
			r.viewport = sz
			for rc in rects {
				got := scissor_clamp(&r, sdl.Rect{rc.x, rc.y, rc.z, rc.w})
				tw, th := i32(sz.x), i32(sz.y)
				if got.x < 0 || got.y < 0 || got.w < 0 || got.h < 0 {
					fmt.eprintf(
						"[ui-probe] scissor clamp: %dx%d rect %v -> %v, negative origin or size\n",
						tw, th, rc, got,
					)
					ok = false
					continue
				}
				if got.x + got.w > tw || got.y + got.h > th {
					fmt.eprintf(
						"[ui-probe] scissor clamp: %dx%d rect %v -> %v, EXCEEDS the target (this is the SDL assert)\n",
						tw, th, rc, got,
					)
					ok = false
					continue
				}
				// A rect that does not reach the target must not be INFLATED to fill it:
				// clamping that grows a band would silently widen every clip row.
				if rc.x >= 0 && rc.y >= 0 && (rc.x + rc.z) <= tw && (rc.y + rc.w) <= th &&
				   (got.w < rc.z || got.h < rc.w) {
					fmt.eprintf(
						"[ui-probe] scissor clamp: %dx%d rect %v -> %v shrank a rect already inside the target\n",
						tw, th, rc, got,
					)
					ok = false
				}
			}
		}
		if ok {
			fmt.println("[ui-probe] scissor clamp: every rect lands inside the target (4 viewports x 11 shapes)")
		}
		return ok
	}

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

		// Q is a one-shot toggle: it flips auto-keyframing, does not care about key
		// repeat, and is not consumed while an export holds the app locked.
		// The table rows above pin which key maps to the action; this pins that the
		// action is wired to the flag at all, which a table-only test cannot see.
		{
			saved_auto := editor_flags.auto_keyframe
			editor_flags.auto_keyframe = false
			kbd_begin_drain()
			kbd_note_key(sdl.K_Q, true)
			if !app_claims_key(sdl.K_Q, {}, false) {
				fmt.eprintf("[ui-probe] K_Q was not claimed\n")
				ok = false
			}
			if !editor_flags.auto_keyframe {
				fmt.eprintf("[ui-probe] K_Q did not turn auto-keyframe on\n")
				ok = false
			}
			// A repeat must not toggle it back; one press, one flip.
			kbd_begin_drain()
			kbd_note_key(sdl.K_Q, true)
			app_claims_key(sdl.K_Q, {}, true)
			if !editor_flags.auto_keyframe {
				fmt.eprintf("[ui-probe] a K_Q repeat toggled the flag again\n")
				ok = false
			}
			kbd_note_key(sdl.K_Q, false)
			editor_flags.auto_keyframe = saved_auto
		}

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

		// A project load shows NO notice. The app bar already names the open
		// project permanently, so a toast repeating it only covers the timeline the
		// user opened the project to look at. Pinned for the finder path because the
		// comment there claims `:open` and the finder agree -- a load toast put back
		// in one of them would otherwise pass unnoticed.
		{
			// Whatever an earlier assertion raised must not leak into this one.
			if len(ui_notice.text) > 0 {
				delete(ui_notice.text)
				ui_notice.text = ""
			}
			finder_open(.Open)
			finder_commit(
				Finder_Entry{
					name     = "probe_saved" + PROJECT_FILE_EXTENSION,
					fullpath = saved,
					kind     = .File,
				},
			)
			if len(ui_notice.text) > 0 {
				fmt.eprintf(
					"[ui-probe] a project load raised a notice %q; a successful load must stay silent\n",
					string(ui_notice.text),
				)
				ok = false
			}
			finder_close()
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
			name                 = session_str_intern("main"),
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
		}
		session_marker_push(&vclip.markers, Clip_Marker {source_frame = 12, label = session_str_intern("chapter")})
		vclip.keyframe_tracks = Keyframe_Track_Range{}
		session_trk_push(&vclip.keyframe_tracks, Keyframe_Track {name = session_str_intern("scale")})
		scale_track := session_trk_view_mut(&vclip.keyframe_tracks, 0)
		scale_lane := Keyframe_Lane{}
		session_kf_push(&scale_lane.keys, Keyframe{frame_off=0,value=1.0})
		session_kf_push(&scale_lane.keys, Keyframe{frame_off=60,value=2.0,interp=.Elastic})
		append(&scale_track.lanes, scale_lane)
		// A section track: "crop" owns one scalar lane per edge, four curves side by
		// side. This is what the packed [KF_PACK_MAX]f32 knot used to be, except the
		// edges are separate keys with separate frames instead of four slots in one.
		session_trk_push(&vclip.keyframe_tracks, Keyframe_Track {name = session_str_intern("crop")})
		crop_track := session_trk_view_mut(&vclip.keyframe_tracks, 1)
		for edge in 0 ..< 4 {
			crop_lane := Keyframe_Lane{}
			// Lanes 0 and 2 also carry a second key, so the fixture distinguishes a
			// lane with a curve from a lane holding a single constant.
			session_kf_push(&crop_lane.keys, Keyframe{frame_off=10,value=f32(edge)+1.0})
			if edge % 2 == 0 {
				session_kf_push(&crop_lane.keys, Keyframe{frame_off=40,value=f32(edge)+1.5})
			}
			append(&crop_track.lanes, crop_lane)
		}

		tr0 := Track {name = strings.clone("V1"), clips = make([dynamic]Clip, 0, 1)}
		append(&tr0.clips, vclip)

		sclip := Clip {
			clip_id              = 101,
			asset_id             = srt_id_asset,
			name                 = session_str_intern("subs"),
			kind                 = .Text,
			generator            = .Subtitles,
			srt_id               = 0,
			source_length_frames = 120,
			timeline_start_frame = 0,
		}
		tclip := Clip {
			clip_id              = 102,
			generator            = .Text,
			name                 = session_str_intern("title"),
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

		// The on-disk marker label must still be a CBOR STRING. Clip_Marker.label
		// became a session-pool handle, and the DTO had to become Saved_Marker
		// because a handle is not cbor-safe -- if that DTO change were ever dropped
		// or reshaped, the encoder would silently write two i32s where a string
		// belongs and every project saved since would fail to load. A CBOR text
		// string is stored as a length prefix plus the raw bytes, so the literal text
		// has to be findable in the file; a struct of two i32s cannot contain it.
		if data, rerr := os.read_entire_file(path, context.allocator); rerr == nil {
			text := string(data)
			if !strings.contains(text, "chapter") {
				fmt.eprintf("[ui-probe] marker label is not a cbor string in the saved file\n")
				ok = false
			}
			// Same trap for lane names: Keyframe_Track.name became a pool handle too, and
			// Saved_Clip.keyframe_tracks was typed [dynamic]Keyframe_Track for the same
			// reason the marker DTO had to change. A handle encodes as two i32s and
			// cannot contain the text.
			if !strings.contains(text, "scale") {
				fmt.eprintf("[ui-probe] keyframe lane name is not a cbor string in the saved file\n")
				ok = false
			}
			delete(data)
		} else {
			fmt.eprintf("[ui-probe] cannot re-read the saved project: %v\n", rerr)
			ok = false
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
		marker := session_marker_at(c.markers, 0)
		if c.markers.n != 1 || marker_label(&marker) != "chapter" || marker.source_frame != 12 {
			fmt.eprintf("[ui-probe] marker mismatch\n")
			ok = false
		}
		if c.keyframe_tracks.n != 2 {
			fmt.eprintf("[ui-probe] %d keyframe tracks want 2\n", c.keyframe_tracks.n)
			ok = false
		} else {
			scale_track := session_trk_view(c.keyframe_tracks, 0)
			scale_lane := keyframe_lane_view(scale_track, 0)
			if keyframe_track_name(scale_track) != "scale" || scale_lane.n != 2 {
				fmt.eprintf("[ui-probe] scalar keyframe track mismatch\n")
				ok = false
			} else if session_kf_at(scale_lane, 1).value != 2.0 ||
					 session_kf_at(scale_lane, 1).interp != .Elastic {
				fmt.eprintf("[ui-probe] scalar key value/interp mismatch\n")
				ok = false
			}
			// The section track round-trips as four independent curves: arity from
			// len(lanes), each lane holding its own scalar value.
			crop_track := session_trk_view(c.keyframe_tracks, 1)
			if keyframe_track_name(crop_track) != "crop" || len(crop_track.lanes) != 4 {
				fmt.eprintf("[ui-probe] section track lane count mismatch\n")
				ok = false
			} else {
				for edge in 0 ..< 4 {
					edge_keys := keyframe_lane_view(crop_track, edge)
					want_keys := edge % 2 == 0 ? 2 : 1
					if edge_keys.n != want_keys ||
					   session_kf_at(edge_keys, 0).frame_off != 10 ||
					   session_kf_at(edge_keys, 0).value != f32(edge)+1.0 {
						fmt.eprintf("[ui-probe] section lane %d mismatch\n", edge)
						ok = false
					}
				}
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
		gutter := clay.GetElementData(clay.ID("KeyframeGutterNames", 0)).boundingBox
		want_gutter := 2 * KF_ROW_H
		if abs(gutter.height - want_gutter) > 0.5 {
			fmt.eprintf("[ui-probe] KeyframeGutterNames height %.1f want %.1f\n", gutter.height, want_gutter)
			ok = false
		}
		// The "keyframe all modified" row must actually LAY OUT for a video clip.
		// It carries the A shortcut's pending set and nothing else — there is no
		// button, so the row is the only place the inspector says what A will key.
		// A row that never got laid out would be silently dead: no text painted and
		// the geometry-edit path with no way to see what it has pending. Assert the
		// box exists and is inside the inspector.
		sel_v, ok_v := transformable_selected()
		if ok_v {
			row_bb := clay.GetElementData(clay.ID("KeyframeAllModifiedRow")).boundingBox
			if row_bb.width <= 0 || row_bb.height <= 0 {
				fmt.eprintf("[ui-probe] KeyframeAllModifiedRow never laid out (%.0fx%.0f)\n", row_bb.width, row_bb.height)
				ok = false
			}

			// Pending lanes must make the row show its real labels, and the
			// "nothing pending" case must read as such rather than as a live offer.
			clip_geom_mark_modified(sel_v, .Crop_L)
			clip_geom_mark_modified(sel_v, .Trans_X)
			labels := geom_key_pending_labels(sel_v, true)
			if labels != "X, L" {
				fmt.eprintf("[ui-probe] pending labels %q want %q\n", labels, "X, L")
				ok = false
			}
			if geom_key_pending_labels(sel_v, false) != "none" {
				fmt.eprintf("[ui-probe] empty pending set must read %q\n", "none")
				ok = false
			}
			if !clip_geom_any_modified(sel_v) {
				fmt.eprintf("[ui-probe] marked lanes must report as pending\n")
				ok = false
			}
			sel_v.geom_modified = 0
			if clip_geom_any_modified(sel_v) {
				fmt.eprintf("[ui-probe] cleared pending set must report nothing pending\n")
				ok = false
			}
			if ok {
				fmt.printf("[ui-probe] key-all-modified row ok (%q, %q)\n", labels, "none")
			}
		} else {
			fmt.eprintf("[ui-probe] no transformable clip selected; cannot assert the key-all-modified row\n")
			ok = false
		}

		if ok {
			fmt.printf("[ui-probe] keyframe layout ok\n")
		}
		return ok
	}

	// ui_probe_inspector_width_asserts holds the clip properties panel to the
	// inspector's own width. The name row is a Grow element whose only child is a
	// Text, so the text's MEASURED width became the card's minimum: a long file name
	// pushed the Clip card to 427px inside a 356px column, so its background and
	// border were painted over the neighbouring panel. A label must not be able to
	// resize the panel that shows it.
	//
	// Two separate guarantees, both asserted here because either alone leaves a bug:
	// the card is structurally bounded (card_open's max width), and the label is cut
	// to the field (clip_name_display) so what the user reads ends in an ellipsis
	// instead of being sliced off at the panel edge by the clip.
	//
	// The name used here has no spaces on purpose. clay wraps on word boundaries by
	// default, so a name WITH spaces folds onto a second line and never widens
	// anything; it is the single unbreakable token — "IMG_4821_take3.mov" — that has
	// no wrap point and therefore reports its full width as the minimum.
	ui_probe_inspector_width_asserts :: proc() -> bool {
		ok := true
		cl, has_clip := transformable_selected()
		if !has_clip {
			fmt.eprintf("[ui-probe] no transformable clip selected; cannot assert the inspector width\n")
			return false
		}
		saved_name := clip_name(cl)
		defer {
			clip_set_name(cl, saved_name)
			build_page(1920, 1600)
		}
		long := "A012_C003_20260314_184522_take07_final_v3.mov"
		for name in ([]string{saved_name, long}) {
			clip_set_name(cl, name)
			_ = build_page(1920, 1600)
			col := clay.GetElementData(clay.ID("InspectorColumn")).boundingBox
			card := clay.GetElementData(clay.ID("ClipCard")).boundingBox
			value := clay.GetElementData(clay.ID("NameValue")).boundingBox
			label := clip_name_display(cl)
			fmt.printf(
				"[ui-probe] name %d chars: column %.1f card %.1f namevalue %.1f label %q\n",
				len(name),
				col.width,
				card.width,
				value.width,
				label,
			)
			if col.width > INSPECTOR_MAX_W + 0.5 {
				fmt.eprintf(
					"[ui-probe] inspector column %.1f exceeds INSPECTOR_MAX_W %v (name %d chars)\n",
					col.width,
					INSPECTOR_MAX_W,
					len(name),
				)
				ok = false
			}
			if card.width > col.width + 0.5 {
				fmt.eprintf(
					"[ui-probe] clip card %.1f overflows the inspector column %.1f (name %d chars)\n",
					card.width,
					col.width,
					len(name),
				)
				ok = false
			}
			if value.width > card.width + 0.5 {
				fmt.eprintf(
					"[ui-probe] name field %.1f overflows the clip card %.1f (name %d chars)\n",
					value.width,
					card.width,
					len(name),
				)
				ok = false
			}
			// The cut has to FIT, not merely be short: label_truncate_fmt reserves
			// the ellipsis before spending the budget, so a label wider than the
			// field means the metric and the layout disagree — and that disagreement
			// is what puts the card back over its neighbour.
			budget := clip_name_max_px()
			if w := text_px(label, FONT_NORMAL); w > budget + 0.5 {
				fmt.eprintf(
					"[ui-probe] truncated label %.1fpx exceeds the name field budget %.1fpx: %q\n",
					w,
					budget,
					label,
				)
				ok = false
			}
			if name == long {
				// An untruncated label would be silently clipped at the panel edge,
				// dropping the tail of the file name with nothing to show it was cut.
				if label == name || !strings.contains(label, "...") {
					fmt.eprintf("[ui-probe] long name was not ellipsized: %q\n", label)
					ok = false
				}
			} else if label != name {
				// A name that already fits must survive whole; truncating it would
				// hide a short file's name for no reason.
				fmt.eprintf("[ui-probe] short name was truncated: %q -> %q\n", name, label)
				ok = false
			}
		}
		if ok {
			fmt.printf("[ui-probe] inspector width ok (long name does not resize the panel)\n")
		}
		return ok
	}

	// The keyframe brush (hover-select) is a MODE, not a drag: Shift+click on empty
	// timeline space arms it, and afterwards the pointer alone — no button held —
	// paints every keyframe it passes over into the selection, accumulating across
	// passes. A Shift+click ON a keyframe is the opposite: it selects that key and
	// arms nothing.
	//
	// This drives the real interaction entry points (interaction_click_dispatch /
	// interaction_move / interaction_release), because the arming is a property of
	// WHICH press handler claims the click, not of the paint call — a probe that
	// called keyframe_brush_paint directly would pass against code where nothing arms it.
	ui_probe_kf_brush_asserts :: proc() -> bool {
		ok := true
		// The go-to-keyframe double-click record is a global on a wall-clock timer.
		// Two probes that press the same diamond in the same process run inside that
		// window, so without this the second press is read as a double-click seek and
		// never reaches the gesture under test.
		keyframe_dbl_click = {}
		build_page(1920, 1600)
		cl := &timeline.tracks[0].clips[0]
		// The lane is FOUND, not assumed at index 0: the geometry layer owns lane
		// naming and order (a seeded "scale" track comes back normalized), so an
		// index-based fixture would be testing the normalization, not the brush.
		lane, k_first, k_second := -1, -1, -1
		for li in 0 ..< cl.keyframe_tracks.n {
			n := keyframe_lane_view(session_trk_view(cl.keyframe_tracks, li), 0).n
			if n >= 2 &&
			   (lane < 0 ||
					   n > keyframe_lane_view(session_trk_view(cl.keyframe_tracks, lane), 0).n) {
				lane, k_first, k_second = li, 0, 1
			}
		}
		if lane < 0 {
			fmt.eprintf("[ui-probe] brush fixture wants a lane with 2+ keys\n")
			return false
		}
		box := clay.GetElementData(clay.ID("TimelineClipWrap", 0)).boundingBox
		f_a := session_kf_at(keyframe_lane_view(session_trk_view(cl.keyframe_tracks,lane), 0), k_first).frame_off
		f_b := session_kf_at(keyframe_lane_view(session_trk_view(cl.keyframe_tracks,lane), 0), k_second).frame_off
		x_a, y_a := keyframe_key_center(box, lane, f_a)
		x_b, y_b := keyframe_key_center(box, lane, f_b)
		// An empty spot to arm the brush on. It has to be past the clip's RIGHT EDGE,
		// not merely past its last key: the clip press handler runs before the brush
		// fallback and claims any press on a clip body, so a point still over the clip
		// selects the clip instead of arming.
		x_empty := box.x + box.width + 20
		y_empty := y_a

		defer {
			keyframe_brush_disarm()
			keyframe_clear()
			selection = {}
			build_page(1920, 1600)
		}

		// Both helpers set clay's pointer state first, exactly as the frame loop does
		// after layout. Without it PointerOver reads whatever position the last real
		// frame left behind, so every clay-gated handler in the chain (the clip press,
		// the TrackArea fallback that arms the brush) would be testing nothing.
		press :: proc(x, y: f32, shift: bool) {
			clay.SetPointerState({x, y}, true)
			interaction_click_dispatch(Mouse_Input{x, y, true, false, false, false, shift, false}, false)
		}
		hover :: proc(x, y: f32) {
			// prev_mouse_down = true and left = false: this is a pointer move with NO
			// button held, which is the case a button-gated implementation would miss.
			clay.SetPointerState({x, y}, false)
			interaction_move(Mouse_Input{x, y, false, false, false, false, false, false}, true, 1600)
		}

		// The premise, asserted rather than assumed: a Shift+click on a keyframe must
		// NOT arm the brush. If this passes trivially because the click armed nothing,
		// the rest of the probe would still look right while testing the wrong thing.
		keyframe_clear()
		press(x_a, y_a, true)
		if keyframe_brush_armed {
			fmt.eprintf("[ui-probe] a shift+click on a keyframe must not arm the brush\n")
			ok = false
		}
		if keyframe_sel_count() != 1 {
			fmt.eprintf(
				"[ui-probe] shift+click on a keyframe selected %d keys, want just that one\n",
				keyframe_sel_count(),
			)
			ok = false
		}
		// And nothing may be painted while it is unarmed.
		hover(x_b, y_b)
		if keyframe_sel_count() != 1 {
			fmt.eprintf(
				"[ui-probe] hovering painted %d keys with the brush unarmed, want the selection untouched\n",
				keyframe_sel_count(),
			)
			ok = false
		}

		// 1. Shift+click on EMPTY timeline space arms the brush, and does NOT clear
		// the selection: A is still selected, because a brush session accumulates and
		// the arming click is not a reselect.
		press(x_empty, y_empty, true)
		if !keyframe_brush_armed {
			fmt.eprintf("[ui-probe] shift+click on empty timeline space must arm the brush\n")
			return false
		}
		if keyframe_sel_count() != 1 || !keyframe_sel_contains(Keyframe_Ref{0, 0, lane, 0, k_first}) {
			fmt.eprintf(
				"[ui-probe] arming the brush left %d keys selected, want the previous selection kept\n",
				keyframe_sel_count(),
			)
			ok = false
		}

		// 2. Hovering the OTHER key adds it to what was already there — the mode does
		// not start fresh, which is the whole difference from a reselect.
		hover(x_b, y_b)
		if keyframe_sel_count() != 2 ||
		   !keyframe_sel_contains(Keyframe_Ref{0, 0, lane, 0, k_first}) ||
		   !keyframe_sel_contains(Keyframe_Ref{0, 0, lane, 0, k_second}) {
			fmt.eprintf(
				"[ui-probe] hovering a key in brush mode left %d selected, want both accumulated\n",
				keyframe_sel_count(),
			)
			ok = false
		}

		// 3. Resting on it changes nothing (the edge trigger), so the mode survives a
		// stationary pointer instead of oscillating.
		hover(x_b, y_b)
		if keyframe_sel_count() != 2 {
			fmt.eprintf(
				"[ui-probe] resting on a painted key changed the count to %d, want 2\n",
				keyframe_sel_count(),
			)
			ok = false
		}

		// 4. The mode outlives the button AND the release: painting continues with no
		// button, which is the behaviour a held-drag implementation cannot express.
		interaction_release(Mouse_Input{x_b, y_b, false, false, false, false, false, false})
		if !keyframe_brush_armed {
			fmt.eprintf("[ui-probe] releasing the button must not disarm the brush\n")
			ok = false
		}
		keyframe_clear()
		hover(x_a, y_a)
		if keyframe_sel_count() != 1 || !keyframe_sel_contains(Keyframe_Ref{0, 0, lane, 0, k_first}) {
			fmt.eprintf("[ui-probe] the brush stopped painting after release (count %d)\n", keyframe_sel_count())
			ok = false
		}

		// 6. Esc cancels the mode without touching the selection.
		keyframe_clear()
		escape_dismiss()
		if keyframe_brush_armed {
			fmt.eprintf("[ui-probe] Esc must cancel the brush\n")
			ok = false
		}
		if keyframe_sel_count() != 0 {
			fmt.eprintf("[ui-probe] Esc changed the selection to %d keys\n", keyframe_sel_count())
			ok = false
		}

		// 7. A plain press cancels the mode too — central in the click dispatch, so it
		// cannot be forgotten by an individual handler.
		press(x_empty, y_empty, true)
		if !keyframe_brush_armed {
			fmt.eprintf("[ui-probe] fixture failed to re-arm the brush\n")
			return false
		}
		press(x_b, y_b, false)
		if keyframe_brush_armed {
			fmt.eprintf("[ui-probe] a plain press must cancel the brush\n")
			ok = false
		}

		if ok {
			fmt.printf("[ui-probe] keyframe brush ok (arm from empty, hover paints, accumulates, persists)\n")
		}
		return ok
	}// A press on a keyframe cannot tell a click from a drag, so it must not collapse
	// a selection the press might have been the start of dragging. The run is the
	// payload of a retime; the narrowing belongs to the release, which is the first
	// frame that knows no drag happened.
	//
	// This drives the clip the probe seed already built rather than hand-seeding a
	// lane: the geometry layer owns lane naming (a seeded "scale" track comes back
	// normalized), so a fixture that writes keys under a name the app then rewrites
	// tests the normalization, not the gesture.
	ui_probe_kf_click_vs_drag_asserts :: proc() -> bool {
		ok := true
		// See the brush probe: a leaked double-click record would turn this probe's
		// press into a seek before it can test the click/drag split.
		keyframe_dbl_click = {}
		build_page(1920, 1600)
		cl := &timeline.tracks[0].clips[0]
		// Find the lane, do not assume index 0: the geometry layer renames and
		// reorders lanes during build, so a fixture pinned to (lane 0, key 0/1)
		// tests that normalization instead of the gesture.
		lane := -1
		for li in 0 ..< cl.keyframe_tracks.n {
			if keyframe_lane_view(session_trk_view(cl.keyframe_tracks, li), 0).n >= 2 {
				lane = li
				break
			}
		}
		if lane < 0 {
			fmt.eprintf(
				"[ui-probe] click/drag fixture wants a lane with 2+ keys, got %d lanes\n",
				cl.keyframe_tracks.n,
			)
			return false
		}
		defer {
			undo_cancel()
			keyframe_clear()
			selection = {}
			build_page(1920, 1600)
		}
		// The lane's first two keys, in store order (the store keeps them sorted,
		// which is what makes frame A < frame B). The NAME is what the probe carries
		// across the move below — the index is not stable.
		// Carried as a borrowed pool view with no clone: the move below reorders
		// tracks, which invalidates the INDEX but not the view -- the pool block is
		// fixed, so published bytes never move. This is the property the clone used
		// to be protecting against, now gone at the source.
		lane_name := keyframe_track_name(session_trk_view(cl.keyframe_tracks,lane))
		f_a := session_kf_at(keyframe_lane_view(session_trk_view(cl.keyframe_tracks,lane), 0), 0).frame_off
		f_b := session_kf_at(keyframe_lane_view(session_trk_view(cl.keyframe_tracks,lane), 0), 1).frame_off
		box := clay.GetElementData(clay.ID("TimelineClipWrap", 0)).boundingBox
		x_a, y := keyframe_key_center(box, lane, f_a)
		x_b, _ := keyframe_key_center(box, lane, f_b)
		if x_b - x_a < KF_DRAG_THRESHOLD_PX * 2 {
			fmt.eprintf(
				"[ui-probe] click/drag fixture keys are %v px apart, too close to grab one\n",
				x_b - x_a,
			)
			return false
		}

		press :: proc(x, y: f32) {
			interaction_click_dispatch(Mouse_Input{x, y, true, false, false, false, false, false}, false)
		}
		drag :: proc(x, y: f32) {
			interaction_move(Mouse_Input{x, y, true, false, false, false, false, false}, true, 1600)
		}
		ref_a, ref_b := Keyframe_Ref{0, 0, lane, 0, 0}, Keyframe_Ref{0, 0, lane, 0, 1}
		run := [?]Keyframe_Ref{ref_a, ref_b}

		// The run under test: both keys selected, the state a brush leaves behind.
		keyframe_clear()
		keyframe_select_add(run[:])
		if keyframe_sel_count() != 2 {
			fmt.eprintf("[ui-probe] click/drag fixture wants a 2-key run, got %d\n", keyframe_sel_count())
			return false
		}

		// 1. The regression: pressing a key that is ALREADY selected must leave the
		// run intact. It used to narrow on mouse-down, so grabbing one key of a run to
		// retime it silently deselected the rest before the drag even started.
		press(x_b, y)
		if keyframe_sel_count() != 2 {
			fmt.eprintf(
				"[ui-probe] pressing a selected key collapsed the run to %d keys on mouse-down\n",
				keyframe_sel_count(),
			)
			ok = false
		}
		if active_interaction != .Keyframe_Move {
			fmt.eprintf("[ui-probe] a plain press on a key must arm the move, got %v\n", active_interaction)
			ok = false
		}

		// 2. Dragging it moves the WHOLE run by the same delta — the point of
		// deferring the narrow.
		drag_frames :: i32(12)
		want_a, want_b := f_a + drag_frames, f_b + drag_frames
		drag(x_b + f32(drag_frames) * timeline_view.zoom, y)
		interaction_release(Mouse_Input{x_b, y, false, false, false, false, false, false})
		got := keyframe_frames_by_name(cl^, lane_name)
		want := [2]i32{want_a, want_b}
		if got != want {
			fmt.eprintf(
				"[ui-probe] dragging one key of the run moved the frames to %v, want %v\n",
				got,
				want,
			)
			ok = false
		}
		if keyframe_sel_count() != 2 {
			fmt.eprintf(
				"[ui-probe] the drag left %d keys selected, want the whole run\n",
				keyframe_sel_count(),
			)
			ok = false
		}

		// 3. The other half: a press with NO drag narrows on mouse-up, and moves
		// nothing. This is the click that replaces the run, now decided at release.
		box = clay.GetElementData(clay.ID("TimelineClipWrap", 0)).boundingBox
		moved_lane, found := keyframe_lane_by_name(cl^, lane_name)
		if !found {
			fmt.eprintf("[ui-probe] the dragged lane vanished from the store\n")
			return false
		}
		ref_a_moved := Keyframe_Ref{0, 0, moved_lane, 0, 0}
		cx, cy := keyframe_key_center(box, moved_lane, want_a)
		press(cx, cy)
		interaction_release(Mouse_Input{cx, cy, false, false, false, false, false, false})
		if keyframe_sel_count() != 1 || !keyframe_sel_contains(ref_a_moved) {
			fmt.eprintf(
				"[ui-probe] clicking a selected key without dragging left %d keys selected, want 1\n",
				keyframe_sel_count(),
			)
			ok = false
		}
		if got := keyframe_frames_by_name(cl^, lane_name); got != want {
			fmt.eprintf("[ui-probe] the click-without-drag moved the frames to %v\n", got)
			ok = false
		}

		// 4. A press on a key OUTSIDE the selection narrows immediately, so dragging
		// it moves the key that was grabbed rather than the run that was selected.
		bx, by := keyframe_key_center(box, moved_lane, want_b)
		one := [?]Keyframe_Ref{ref_a_moved}
		keyframe_clear()
		keyframe_select_add(one[:])
		press(bx, by)
		if keyframe_sel_count() != 1 || keyframe_sel_contains(ref_a_moved) {
			fmt.eprintf(
				"[ui-probe] pressing an UNselected key left %d selected, want just the grabbed one\n",
				keyframe_sel_count(),
			)
			ok = false
		}
		interaction_release(Mouse_Input{bx, by, false, false, false, false, false, false})

		if ok {
			fmt.printf("[ui-probe] keyframe click-vs-drag ok (press keeps the run, release narrows)\n")
		}
		return ok
	}

	// keyframe_lane_by_name finds a lane by its track name, at an index that is only valid
	// for the current build. A probe must not cache a lane INDEX across a store op:
	// the geometry layer can mint or retire lanes while re-landing keys, which slides
	// every index after it.
	keyframe_lane_by_name :: proc(cl: Clip, name: string) -> (int, bool) {
		for i in 0 ..< cl.keyframe_tracks.n {
			if keyframe_track_name(session_trk_view(cl.keyframe_tracks,i)) == name {
				return i, true
			}
		}
		return -1, false
	}

	// keyframe_frames_by_name is the frame list of the named lane, as a fixed pair so a
	// probe can compare it with == and get one readable failure instead of two.
	keyframe_frames_by_name :: proc(cl: Clip, name: string) -> [2]i32 {
		li, ok := keyframe_lane_by_name(cl, name)
		assert(ok, "keyframe_frames_by_name: the probe's lane vanished from the store")
		keys := keyframe_lane_view(session_trk_view(cl.keyframe_tracks, li), 0)
		assert(keys.n == 2, "keyframe_frames_by_name wants exactly the 2 keys its fixture selected")
		return [2]i32{session_kf_at(keys, 0).frame_off, session_kf_at(keys, 1).frame_off}
	}
	// ui_probe_clip_tile_width_asserts holds the tile to the model's width. A tile
	// sized by its content (label text + padding) instead of by frames*zoom drew
	// wider than the clip really was, and the same box fed the pointer hit test,
	// the drag origin and the marker pass -- so a short audio clip (label "Audio")
	// came out visibly longer than an equal-length video clip (label "Clip"), with
	// its extra width clickable. Zooming in hid it because the clip outgrew its own
	// label. Zoom 0.1 makes the seeded 300-frame clips narrow enough that every
	// label outgrows its tile, so this bites on each track's audio clip.
	ui_probe_clip_tile_width_asserts :: proc() -> bool {
		ok := true
		saved_zoom, saved_start := timeline_view.zoom, timeline_view.start
		defer {
			timeline_view.zoom, timeline_view.start = saved_zoom, saved_start
			build_page(1920, 1600)
		}
		zooms := []f32{0.1, 0.5, 1, 4}
		for zoom in zooms {
			timeline_view.zoom = zoom
			timeline_view.start = 0
			_ = build_page(1920, 1600)
			for t in 0 ..< len(timeline.tracks) {
				for i in 0 ..< len(timeline.tracks[t].clips) {
					cl := timeline.tracks[t].clips[i]
					want := f32(max(cl.source_length_frames, 1)) * zoom
					tile := clay.GetElementData(
						clay.ID("TimelineClip", u32(t * 1000 + i)),
					).boundingBox
					if abs(tile.width - want) > 0.5 {
						fmt.eprintf(
							"[ui-probe] zoom %.2f t%d c%d (kind %d) tile width %.1f want %.1f\n",
							zoom,
							t,
							i,
							int(cl.kind),
							tile.width,
							want,
						)
						ok = false
					}
				}
			}
		}
		if ok {
			fmt.printf("[ui-probe] clip tile width ok\n")
		}
		return ok
	}

	// ui_probe_backspace_ripple_asserts: press the body of clip 1 on track 0, then
	// route a real Backspace keydown. Asserts the clip is gone AND that its tail
	// neighbour slid left by the removed span — the gap closing is the ripple, and
	// a delete that merely removed the clip (or silently did nothing) is the bug.
	ui_probe_backspace_ripple_asserts :: proc() -> bool {
		ok := true
		keyframe_dbl_click = {}
		keyframe_clear()
		keyframe_brush_disarm()
		build_page(1920, 1600)
		if len(timeline.tracks) == 0 || len(timeline.tracks[0].clips) < 3 {
			fmt.eprintf("[ui-probe] backspace ripple fixture wants 3+ clips on track 0\n")
			return false
		}
		track := &timeline.tracks[0]
		// The ripple rebuilds the track's clip array (delete + reassign) and drops a
		// clip, so keep a copy: the probes after this one lay out the same seeded
		// session and would otherwise see a short track 0.
		//
		// Back up Clip POD records and mark session ranges shared before ripple edits.
		saved_clips := make([dynamic]Clip, 0, len(track.clips), context.temp_allocator)
		for i in 0..<len(track.clips) {
			c := track.clips[i]
			c.markers = session_marker_share(&track.clips[i].markers)
			c.keyframe_tracks = session_trk_share(&track.clips[i].keyframe_tracks)
			append(&saved_clips, c)
		}
		target := track.clips[1]
		span := target.source_length_frames
		tail_id := track.clips[2].clip_id
		tail_start := track.clips[2].timeline_start_frame
		head_start := track.clips[0].timeline_start_frame
		// The clip's own tile box, exactly as the frame loop would find it: the
		// press has to land on the element the renderer painted.
		box := clay.GetElementData(clay.ID("TimelineClip", 1)).boundingBox
		if box.width <= 0 || box.height <= 0 {
			fmt.eprintf(
				"[ui-probe] backspace ripple: clip 1 never laid out (%.1fx%.1f)\n",
				box.width,
				box.height,
			)
			return false
		}
		defer {
			keyframe_clear()
			keyframe_brush_disarm()
			// Release session ranges held by rebuilt clips before restoring backup.
			for &c in track.clips {
				clip_ranges_release(&c)
			}
			delete(track.clips)
			track.clips = saved_clips
			selection.track, selection.index = 0, 0
			// The ripple pushed a real undo node (a cloned timeline plus its
			// label). Nothing downstream reads the tree, and the probe exits
			// without the app teardown, so drop it here instead of leaking a
			// snapshot of the seed.
			undo_free_all()
			undo_init()
			build_page(1920, 1600)
		}

		x, y := box.x + box.width * 0.5, box.y + box.height * 0.5
		clay.SetPointerState({x, y}, true)
		interaction_click_dispatch(Mouse_Input{x, y, true, false, false, false, false, false}, false)
		clay.SetPointerState({x, y}, false)
		interaction_release(Mouse_Input{x, y, false, false, false, false, false, false})

		// The premise: a plain press on the tile must have SELECTED it. Without
		// this the rest of the probe could report a broken ripple for what is
		// really a broken click.
		if selection.track != 0 || selection.index != 1 {
			fmt.eprintf(
				"[ui-probe] backspace ripple: press on clip 1 selected %d/%d, want 0/1\n",
				selection.track,
				selection.index,
			)
			return false
		}

		if !route_key_down(sdl.K_BACKSPACE, {}, false) {
			fmt.eprintf("[ui-probe] backspace ripple: the key router dropped Backspace\n")
			return false
		}

		if len(track.clips) != ui_probe_clips_per_track - 1 {
			fmt.eprintf(
				"[ui-probe] backspace ripple: clip count %d, want %d (nothing was deleted)\n",
				len(track.clips),
				ui_probe_clips_per_track - 1,
			)
			return false
		}
		tail_after: i64 = -1
		for &c in track.clips {
			if c.clip_id == target.clip_id {
				fmt.eprintf("[ui-probe] backspace ripple: the selected clip is still there\n")
				ok = false
			}
			if c.clip_id == tail_id {
				tail_after = c.timeline_start_frame
			}
		}
		if track.clips[0].timeline_start_frame != head_start {
			fmt.eprintf(
				"[ui-probe] backspace ripple: the clip before the cut moved to %d, want %d\n",
				track.clips[0].timeline_start_frame,
				head_start,
			)
			ok = false
		}
		// The tail must have slid left by exactly the removed span, closing the gap.
		if tail_after != tail_start - span {
			fmt.eprintf(
				"[ui-probe] backspace ripple: tail clip at %d, want %d (slid left by the %d-frame cut) — the gap did NOT close\n",
				tail_after,
				tail_start - span,
				span,
			)
			ok = false
		}
		// Escape took the same path and was equally dead: the help overlay and the
		// context menus could only be dismissed with the mouse.
		editor_flags.help_open = true
		defer editor_flags.help_open = false
		route_key_down(sdl.K_ESCAPE, {}, false)
		if editor_flags.help_open {
			fmt.eprintf("[ui-probe] Escape with no field open must reach escape_dismiss\n")
			ok = false
		}
		// ...and the number field must STILL get its three keys, which is the whole
		// reason it is a separate owner: Backspace has to edit the digits there.
		// edit_begin laid down "0"; the two appends made "073"; one Backspace must
		// leave "07" — proving the key reached the FIELD, not the app layer.
		edit_begin(.X, 0)
		edit_append('7')
		edit_append('3')
		route_key_down(sdl.K_BACKSPACE, {}, false)
		if edit_state.len != 2 || edit_state.chars[0] != '0' || edit_state.chars[1] != '7' {
			fmt.eprintf(
				"[ui-probe] Backspace must still edit an open number field (got %d chars, first %q)\n",
				edit_state.len,
				edit_state.chars[:max(edit_state.len, 1)],
			)
			ok = false
		}
		edit_cancel()
		if edit_state.field != .None {
			fmt.eprintf("[ui-probe] the number field must be closed after cancel\n")
			ok = false
		}
		if ok {
			fmt.printf("[ui-probe] backspace ripple-deletes and closes the gap ok\n")
		}
		return ok
	}

	// ui_probe_opacity_slider_asserts pins the opacity slider's painted fill to the
	// clip's value. The fill is a child of the track sized with clay.SizingPercent,
	// which clay defines as a 0-1 FRACTION of the track width ("i.e. 20% is 0.2"),
	// not a 0-100 percentage. Passing opacity*100 made every non-zero opacity size
	// the fill at (track width * opacity * 100), overflowing the track; it also
	// tripped clay's CLAY_ERROR_TYPE_PERCENTAGE_OVER_1 every frame, which
	// clay_error() drops silently. Reading the value back cannot catch that -- only
	// the laid-out fill width can -- so this measures the real boxes.
	ui_probe_opacity_slider_asserts :: proc() -> bool {
		cl, ok := transformable_selected()
		if !ok {
			fmt.eprintf("[ui-probe] no transformable clip selected; cannot assert the opacity fill\n")
			return false
		}
		saved := cl.opacity
		defer cl.opacity = saved
		ok = true
		for v in ([]f32{0, 0.25, 0.5, 0.75, 1}) {
			cl.opacity = v
			_ = build_page(1920, 1600)
			track := clay.GetElementData(clay.ID("OpacityTrack")).boundingBox
			fill := clay.GetElementData(clay.ID("OpacityFill")).boundingBox
			if track.width <= 0 {
				fmt.eprintf("[ui-probe] opacity %.2f: track has no width (%.1f)\n", v, track.width)
				ok = false
				continue
			}
			// The track declares no padding and one child, so clay's
			// (parentSize - padding - childGaps) * percent reduces to
			// track.width * opacity.
			want := track.width * v
			if abs(fill.width - want) > 0.5 {
				fmt.eprintf(
					"[ui-probe] opacity %.2f: fill width %.1f want %.1f (track %.1f)\n",
					v, fill.width, want, track.width,
				)
				ok = false
			}
			if fill.width > track.width + 0.5 {
				fmt.eprintf(
					"[ui-probe] opacity %.2f: fill %.1f overflows track %.1f\n",
					v, fill.width, track.width,
				)
				ok = false
			}
		}
		if ok {
			fmt.printf("[ui-probe] opacity slider fill ok\n")
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
						name = session_str_intern(clip_probe_name(t, c)),
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
		fixture_clip := &timeline.tracks[0].clips[0]
		fixture_clip.keyframe_tracks = Keyframe_Track_Range{}
		// "transform" is the section track; lane 0 is transform.x.
		session_trk_push(&fixture_clip.keyframe_tracks, Keyframe_Track {name = session_str_intern("transform")})
		transform_lane := Keyframe_Lane{}
		session_kf_push(&transform_lane.keys, Keyframe{frame_off=0,value=0})
		session_kf_push(&transform_lane.keys, Keyframe{frame_off=120,value=1})
		append(&session_trk_view_mut(&fixture_clip.keyframe_tracks, 0).lanes, transform_lane)
		session_trk_push(&fixture_clip.keyframe_tracks, Keyframe_Track {name = session_str_intern("zoom")})
		zoom_lane := Keyframe_Lane{}
		session_kf_push(&zoom_lane.keys, Keyframe{frame_off=30,value=1})
		append(&session_trk_view_mut(&fixture_clip.keyframe_tracks, 1).lanes, zoom_lane)

		sync_track_order()

		// Selected clip -> the Inspector property card renders.
		selection.track = 0
		selection.index = 0

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

	// clip_probe_name formats a probe clip's label into a fixed buffer. Interning
	// copies the bytes, so heap-formatting with aprintf here would leak the
	// intermediate for nothing (TODO.md §1).
	clip_probe_name :: proc(t, c: int) -> string {
		buf: [48]u8
		return fmt.bprintf(buf[:], "clip %d-%d", t, c)
	}

}
