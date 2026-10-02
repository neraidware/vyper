package main

import clay "clay-odin"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import avutil "vendor/ffmpeg/avutil"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Entry point: window/device/pipeline setup, the SDL event loop (input
// dispatch, drag-state machine, playback tick), and the per-frame render.

// toggle_playback starts playback from the current playhead (wrapping to
// frame 0 when already at/past the end) or pauses it. playback.stop_frame is
// cleared so a normal run plays the whole timeline.
toggle_playback :: proc() {
	if playhead.playing {
		playhead.playing = false
		preview.playing = false
		// A pause drops the jog speed boost so the next play uses the selected
		// rate again.
		playback.boost = 0
		if vyper_trace {
			fmt.printf("[pb] toggle playing=%v ph=%d\n", playhead.playing, playhead.frame)
		}
		return
	}
	if playback.dir == 1 && playhead.frame >= timeline_duration() {
		playhead.frame = 0
	}
	playback.stop_frame = -1
	playback.accumulator = 0
	playback.last_tick_ns = monotonic_ns()
	audio_prod.was_playing = false
	playhead.playing = true
	preview.playing = true
	if vyper_trace {
		fmt.printf(
			"[pb] toggle playing=%v ph=%d dir=%d\n",
			playhead.playing,
			playhead.frame,
			playback.dir,
		)
	}
}

// jog_playback implements the forward/backward jog controls (and h/l keys):
//   - not playing -> start playing in the given direction,
//   - already playing in that direction -> bump the temporary speed boost,
//   - playing the other way -> flip direction (and reset the boost).
// Audio only plays forward; going backward (dir == -1) mutes audio via
// audio_update.
jog_playback :: proc(dir: int) {
	if !playhead.playing {
		playback.dir = dir
		playback.boost = 0
		if playback.stop_frame < 0 && dir == -1 && playhead.frame <= 0 {
			// Nothing to show backward from frame 0.
			return
		}
		playback.stop_frame = -1
		playback.accumulator = 0
		playback.last_tick_ns = monotonic_ns()
		audio_prod.was_playing = false
		playhead.playing = true
		preview.playing = true
		if vyper_trace {
			fmt.printf("[pb] jog start dir=%d ph=%d\n", dir, playhead.frame)
		}
		return
	}
	// Already playing.
	if playback.dir == dir {
		playback.boost += 1
		if vyper_trace {
			fmt.printf(
				"[pb] jog boost dir=%d boost=%d eff=%.2fx\n",
				dir,
				playback.boost,
				effective_playback_rate(),
			)
		}
	} else {
		playback.dir = dir
		playback.boost = 0
		if vyper_trace {
			fmt.printf("[pb] jog flip dir=%d ph=%d\n", dir, playhead.frame)
		}
	}
}

// effective_playback_rate is the rate the playhead actually advances at: the
// selected rate scaled by the temporary jog boost.
effective_playback_rate :: proc() -> f64 {
	return playback.rate * f64(1 + max(0, playback.boost))
}

// track_gutter_hit_test returns the track whose NAME GUTTER contains (mx,my),
// or -1. This is the right-click target for the dedicated track menu: the
// gutter is the column that identifies a track, so a right-click there means
// "this track" rather than "this frame" (which is what the clip lanes mean).
// Horizontal bounds come from the TrackName box, so the two columns can never
// overlap and a right-click in the lanes can never reach this.
track_gutter_hit_test :: proc(mx, my: f32) -> int {
	for ti in 0 ..< len(timeline.tracks) {
		row := clay.GetElementData(clay.ID("TrackRow", u32(ti))).boundingBox
		name := clay.GetElementData(clay.ID("TrackName", u32(ti))).boundingBox
		if my < row.y ||
		   my > row.y + row.height ||
		   mx < name.x ||
		   mx >= name.x + name.width {
			continue
		}
		return ti
	}
	return -1
}

// timeline_track_hit_test returns the timeline track whose empty (non-clip)
// region the pointer is over, or -1 if the pointer is on a clip, the track
// name, or outside the timeline. Only the clips region of a track (right of the
// name column) counts as that track's empty space.
timeline_track_hit_test :: proc(mx, my: f32) -> int {
	if len(timeline.tracks) == 0 {
		return -1
	}
	for ti in 0 ..< len(timeline.tracks) {
		row := clay.GetElementData(clay.ID("TrackRow", u32(ti))).boundingBox
		if my < row.y || my > row.y + row.height || mx <= row.x {
			continue
		}
		// Over a clip is not empty space.
		on_clip := false
		for ci in 0 ..< len(timeline.tracks[ti].clips) {
			if clay.PointerOver(clay.ID("TimelineClip", u32(ti * 1000 + ci))) {
				on_clip = true
				break
			}
		}
		if on_clip {
			continue
		}
		return ti
	}
	return -1
}

// timeline_resize_edge_at returns 0/1 if (mx,my) is inside the grab area on the
// clip's left/right edge, else -1. The grab band is a fixed few pixels wide on
// each side; the pointer must be over this specific clip.
timeline_resize_edge_at :: proc(track_idx, index: int, mx, my: f32) -> int {
	if !clay.PointerOver(clay.ID("TimelineClip", u32(track_idx * 1000 + index))) {
		return -1
	}
	box := clay.GetElementData(clay.ID("TimelineClip", u32(track_idx * 1000 + index))).boundingBox
	if my < box.y || my > box.y + box.height {
		return -1
	}
	if mx >= box.x && mx <= box.x + CLIP_GRAB {
		return 0
	}
	if mx >= box.x + box.width - CLIP_GRAB && mx <= box.x + box.width {
		return 1
	}
	return -1
}

// timeline_resize_hover reports whether a duration resize is in progress or the
// pointer is over the selected clip's edge grab area (drives the resize cursor).
timeline_resize_hover :: proc(mx, my: f32) -> bool {
	if active_interaction == .Clip_Resize {
		return true
	}
	if tr, cl, ok := selected_clip(); ok {
		for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
			track := &timeline.tracks[track_idx]
			for index := 0; index < len(track.clips); index += 1 {
				if &track.clips[index] == cl {
					return timeline_resize_edge_at(track_idx, index, mx, my) >= 0
				}
			}
		}
	}
	return false
}

// timeline_tracks_content_height is the full height of the track list (every
// track row plus one insert gap above the first and below the last), computed
// purely from the track count, each track's keyframe lane count, and the fixed
// geometry constants. The track region scrolls exactly this far, so content and
// viewport never disagree regardless of layout timing.
timeline_tracks_content_height :: proc() -> f32 {
	total := f32(len(timeline.tracks) + 1) * TRACK_GAP_H
	for &t in timeline.tracks {
		total += TRACK_ROW_H + f32(kf_rows_for(&t)) * KF_ROW_H
	}
	return total
}

// timeline_tracks_max_top returns how far the track list can scroll vertically:
// the data-derived content height minus the visible tracks viewport. 0 when the
// rows fit, so vertical panning only scrolls once there are more tracks than
// room.
timeline_tracks_max_top :: proc() -> f32 {
	if len(timeline.tracks) == 0 {
		return 0
	}
	sec := clay.GetElementData(clay.ID("TracksSection")).boundingBox
	if sec.height <= 0 {
		return 0
	}
	return max(timeline_tracks_content_height() - sec.height, 0)
}

// TRACKS_FIT_TARGET is how many track rows the timeline is fitted to show when
// a clip is imported or a project loads: enough lanes to work in without
// pushing the preview off screen, and the rest reachable by scrolling.
TRACKS_FIT_TARGET :: 5

// tracks_view_height_for is the track-list height that shows `rows` rows
// exactly: the rows, plus the insert gap above each one and the trailing gap
// below the last (the list renders one more gap than it has rows).
tracks_view_height_for :: proc(rows: int) -> f32 {
	return f32(rows) * (TRACK_ROW_H + TRACK_GAP_H) + TRACK_GAP_H
}

// panel_clamp_bounds are the limits on the upper area's height, shared by the
// divider drag and the automatic track fit so both enforce one rule: a short
// window never lets the two areas collide, and the track list keeps room.
panel_clamp_bounds :: proc(window_h: f32) -> (min_h, max_h: f32) {
	min_h = min(460.0, window_h * 0.35)
	max_h = max(min_h, window_h - 140)
	return
}

// fit_timeline_to_tracks makes the track list show at most TRACKS_FIT_TARGET
// rows and scrolls it to the top, so tracks that were just created (or loaded)
// are on screen instead of below the fold. Run on media import and project load.
//
// "At most" is deliberate: the divider only ever moves IN, never out. A user who
// dragged it to a deliberately small track list keeps that, and one whose list
// would show more than the target gets it pulled back — but an import never
// yanks the divider away from a layout they chose.
//
// The window height is read here rather than passed in: both callers (media
// import, project load) run outside the render loop and have no height, and
// asking the one place that knows beats threading a parameter through two
// unrelated paths.
fit_timeline_to_tracks :: proc() {
	window_h := f32(WINDOW_HEIGHT)
	if app_window != nil {
		w, h: c.int
		sdl.GetWindowSize(app_window, &w, &h)
		window_h = f32(h)
	}
	chrome := APP_BAR_H + EDITOR_DIVIDER_H
	tracks_h := tracks_view_height_for(TRACKS_FIT_TARGET)
	current_tracks_h := window_h - chrome - panel_layout.upper_area_height
	if current_tracks_h > tracks_h {
		min_h, max_h := panel_clamp_bounds(window_h)
		panel_layout.upper_area_height =
			clamp(window_h - chrome - tracks_h, min_h, max_h)
	}
	timeline_view.top = 0
}

// scrollbar_geometry turns a container's content and viewport heights into its
// vertical scrollbar geometry: how far the content can travel (max_top), the
// thumb size (proportional to the visible share, never below
// TSCROLLBAR_MIN_H), and the thumb's travel distance within the strip. Zero
// when there is no overflow.
scrollbar_geometry :: proc(content_h, view_h: f32) -> (max_top, thumb_h, travel: f32) {
	if content_h <= view_h {
		return 0, 0, 0
	}
	max_top = content_h - view_h
	thumb_h = clamp(view_h * view_h / content_h, TSCROLLBAR_MIN_H, view_h)
	travel = view_h - thumb_h
	return
}

// scroll_press starts a scrollbar drag: pressing the thumb drags it directly;
// pressing anywhere else on the strip jumps the thumb to the cursor (grabbed at
// its center so a movement continues the jump). Returns whether the press hit a
// scrollbar, and tags this stack's thumb/strip ids with the container's tag.
scroll_press :: proc(tag: string, my: f32, drag: ^bool, grab: ^f32) -> bool {
	// Clay hashes id strings immediately and keeps no pointer to them, so a
	// fixed stack buffer rebuilt per call is safe and avoids a per-frame heap
	// allocation for id strings that are rebuilt every polled frame.
	id_buf: [64]u8
	thumb_id := clay.ID(fmt.bprintf(id_buf[:], "%sSbThumb", tag))
	strip_id := clay.ID(fmt.bprintf(id_buf[:], "%sScrollbar", tag))
	if clay.PointerOver(thumb_id) {
		drag^ = true
		grab^ = my - clay.GetElementData(thumb_id).boundingBox.y
		return true
	}
	if clay.PointerOver(strip_id) {
		drag^ = true
		grab^ = clay.GetElementData(thumb_id).boundingBox.height / 2
		return true
	}
	return false
}

// scroll_drag_update moves a scroll value while its scrollbar drag is active,
// mapping the cursor's position within the strip onto the scroll range. Ends
// the drag the moment the button lifts.
scroll_drag_update :: proc(
	tag: string,
	down: bool,
	my: f32,
	drag: ^bool,
	grab: ^f32,
	scroll: ^f32,
	content_h, view_h: f32,
) {
	if !drag^ {
		return
	}
	if !down {
		drag^ = false
		return
	}
	id_buf: [64]u8
	strip := clay.GetElementData(clay.ID(fmt.bprintf(id_buf[:], "%sScrollbar", tag))).boundingBox
	max_top, _, travel := scrollbar_geometry(content_h, view_h)
	if strip.height > 0 && travel > 0 {
		pos := (my - strip.y - grab^) / travel
		scroll^ = clamp(pos * max_top, 0, max_top)
	}
}

// Inspector scroll metrics, measured from the scrollport and its content stack.
inspector_content_height :: proc() -> f32 {
	return clay.GetElementData(clay.ID("InspectorContent")).boundingBox.height
}
inspector_view_height :: proc() -> f32 {
	return clay.GetElementData(clay.ID("Inspector")).boundingBox.height
}
inspector_max_scroll :: proc() -> f32 {
	return max(inspector_content_height() - inspector_view_height(), 0)
}

// update_timeline_cursor shows the horizontal-resize cursor while dragging or
// hovering a clip's duration edge, restoring the arrow cursor otherwise.
update_timeline_cursor :: proc(mx, my: f32) {
	if !timeline_resize_hover(mx, my) {
		if clip_resize.arrow_cursor == nil {
			clip_resize.arrow_cursor = sdl.CreateSystemCursor(.DEFAULT)
		}
		_ = sdl.SetCursor(clip_resize.arrow_cursor)
		return
	}
	if clip_resize.resize_cursor == nil {
		clip_resize.resize_cursor = sdl.CreateSystemCursor(.EW_RESIZE)
	}
	_ = sdl.SetCursor(clip_resize.resize_cursor)
}

// open_track_context_menu shows the per-track right-click menu at the pointer,
// snapshotting the click position (frame) so a later Add-text action inserts at
// the original right-click location, not where the pointer ends up hovering
// over the menu.
open_track_context_menu :: proc(mx, my: f32, track: int) {
	// The track menu is a separate popup, but never two at once: right-clicking
	// the lanes while the gutter menu is up replaces it.
	close_track_action_menu()
	ctx_menu.open = true
	// Keep the floating menu fully on-screen: it's about 180px wide and one
	// row tall (+padding), so clamp the anchor so a right-click near a window
	// edge doesn't push the menu past it.
	if app_window != nil {
		w, h: c.int
		sdl.GetWindowSize(app_window, &w, &h)
		ctx_menu.x = clamp(mx, 0, f32(w) - 190)
		ctx_menu.y = clamp(my, 0, f32(h) - 60)
	} else {
		ctx_menu.x = mx
		ctx_menu.y = my
	}
	ctx_menu.target_track = track
	ctx_menu.target_clip_track = -1
	ctx_menu.target_clip_index = -1
	track_start := clay.GetElementData(clay.ID("ClipsSection", 0)).boundingBox.x
	ctx_menu.frame = i64(max(f32(0), (mx - track_start) / timeline_view.zoom + timeline_view.start))
}

// close_context_menu dismisses the context menu, if open.
close_context_menu :: proc() {
	ctx_menu.open = false
	ctx_menu.target_track = -1
	ctx_menu.frame = 0
	ctx_menu.submenu = false
	ctx_menu.submenu_grace = 0
	ctx_menu.target_clip_track = -1
	ctx_menu.target_clip_index = -1
}

// TRACK_MENU_W is the dedicated track menu's row width. Wider than
// CONTEXT_MENU_W because "Duplicate Track" is the longest label either menu
// shows.
TRACK_MENU_W :: 168

// open_track_action_menu shows the track menu at the pointer for `track`,
// replacing the two always-visible gutter buttons it supersedes. Opening it
// closes the timeline menu, so a right-click never leaves two popups up.
open_track_action_menu :: proc(mx, my: f32, track: int) {
	close_context_menu()
	track_ctx.open = true
	track_ctx.target_track = track
	// Keep the popup fully on-screen, same clamp the timeline menu uses.
	if app_window != nil {
		w, h: c.int
		sdl.GetWindowSize(app_window, &w, &h)
		track_ctx.x = clamp(mx, 0, f32(w) - f32(TRACK_MENU_W) - 2 * CONTEXT_MENU_EDGE)
		track_ctx.y = clamp(my, 0, f32(h) - 80)
	} else {
		track_ctx.x = mx
		track_ctx.y = my
	}
}

// close_track_action_menu dismisses the track menu, if open.
close_track_action_menu :: proc() {
	track_ctx.open = false
	track_ctx.target_track = -1
}

// track_action_menu_hover reports whether (mx,my) is inside the track menu
// popup. Like the timeline menu's hover test this reads last frame's element
// geometry rather than clay.PointerOver, so a click on the frame the popup
// mounts still routes to the handler instead of dismissing it.
track_action_menu_hover :: proc(mx, my: f32) -> bool {
	return ctx_point_in(mx, my, clay.GetElementData(clay.ID("TrackMenu")).boundingBox)
}

// handle_track_action_option runs the track-menu action under (mx,my). The
// target is snapshotted at open time, so a click acts on the track that was
// right-clicked even if the pointer has since moved.
handle_track_action_option :: proc(mx, my: f32) {
	t := track_ctx.target_track
	if t < 0 || t >= len(timeline.tracks) {
		close_track_action_menu()
		return
	}
	row := ctx_row_hit(mx, my, clay.GetElementData(clay.ID("TrackMenu")).boundingBox)
	switch row {
	case 0:
		duplicate_track(t)
	case 1:
		remove_track(t)
	}
	close_track_action_menu()
}

// escape_dismiss closes any transient overlay (right-click context menu, the
// playback-rate dropdown, the help overlay). Called on ESC while not editing a
// text field.
escape_dismiss :: proc() {
	// Esc is the universal cancel, and the keyframe brush is a mode a user can
	// walk away from without noticing they armed it — so it ends here.
	kf_brush_disarm()
	close_context_menu()
	close_track_action_menu()
	playback.rate_open = false
	editor_flags.help_open = false
}

// begin_clip_rename opens the generic text field to edit the selected clip's
// name. The value is applied on commit (see apply_rename).
begin_clip_rename :: proc() {
	if _, clip, ok := selected_clip(); ok {
		text_input_begin(string(clip.name), TI_RENAME, clip.clip_id)
	}
}

// apply_rename reads the committed text input and stores it on the clip that
// was being edited (ti.target is the clip_id). In "create" mode a committed
// empty/whitespace name removes the just-created clip instead of capturing it.
apply_rename :: proc() {
	name := text_input_string()
	was_create := ti.is_create
	if was_create {
		ti.is_create = false
		if strings.trim_space(name) == "" {
			delete_selected_clip_raw()
			return
		}
	}
	if _, clip, ok := find_clip_by_id(ti.target); ok {
		new_name := strings.trim_space(name)
		changed := clip.name != new_name
		// In create mode the pre-insert capture (add_text_clip_at) is still
		// pending: the whole create+name is one "Add text clip" node, so the
		// insertion belongs to this node's parent, not to a separate capture.
		if !was_create {
			undo_begin()
		}
		if clip.name != "" {
			delete(clip.name)
		}
		clip.name = strings.clone(new_name)
		if was_create {
			// The create-mode rename is what keeps the just-inserted clip: an
			// empty/cancelled name already deleted it above, so reaching here
			// means a real text clip was added.
			undo_push(.Text, "Add text clip")
		} else if changed {
			undo_push(.Rename, "Rename clip")
		}
	}
}

// apply_command handles a committed command line: it records the text as
// last_command (the prompt's placeholder) and, when the command is known,
// executes it. Supported:
//   open <file>      — open a media/subtitle file through the same flow as the
//                      Open File button (decodable only: no silent junk
//                      imports), or a .vyproj project file (loads its
//                      metadata).
//   save <file>      — write the current project metadata to a .vyproj file.
apply_command :: proc() {
	cmd := text_input_string()
	if len(cmdline_match_state.last_command) > 0 {
		delete(cmdline_match_state.last_command)
	}
	cmdline_match_state.last_command = strings.clone(cmd)

	trimmed := strings.trim_space(cmd)
	sp := 0
	for sp < len(trimmed) && trimmed[sp] != ' ' && trimmed[sp] != '\t' {
		sp += 1
	}
	verb := trimmed[:sp]
	arg := strings.trim_space(trimmed[sp:])

	switch verb {
	case "save":
		// Bare ":save" opens the in-app file finder in Save mode (same picker
		// bare ":open" uses) instead of demanding a typed path.
		if len(arg) == 0 {
			finder_open(.Save)
			return
		}
		if err := project_file_save(arg); len(err) > 0 {
			// show_ui_notice copies, so `err` is ours to free.
			defer delete(err)
			show_ui_notice(err, 4000)
			return
		}
		show_ui_noticef(3000, "Saved '%s'", arg)
	case "open":
		// Bare ":open" (no argument) launches the in-app fuzzy file finder
		// instead of the OS dialog that the Open File button uses; a typed
		// path after "open" still goes down the direct-open path below.
		if len(arg) == 0 {
			finder_open(.Open)
			return
		}
		if project_path_is_project(arg) {
			if err := project_file_open(arg); len(err) > 0 {
				defer delete(err)
				show_ui_notice(err, 4000)
				return
			}
			show_ui_noticef(3000, "Editing '%s'", project.name)
			return
		}
		if !os.exists(arg) {
			show_ui_noticef(4000, "No such file '%s'", arg)
			return
		}
		// open_file_at only reads `cpath` (the bin clones it), so the scratch
		// copy is freed as soon as the open returns.
		cpath := strings.clone_to_cstring(arg)
		open_file_at(cpath)
		delete(cpath)
	case:
		// Unknown command or empty filter text commit; no-op.
	}
}

// ---------------------------------------------------------------------------
// Playhead time viewer: numeric timeline navigation. The timeline toolbar's
// time badge (PlayheadTime) opens the generic text input pre-filled with the
// current playhead timecode; on commit the typed value is parsed back into a
// frame and the playhead is sought there (same path as scrubbing).
// ---------------------------------------------------------------------------

// playhead_timecode renders the current playhead frame as an HH:MM:SS:FF
// value. Its scratch lives in ui_text.timecode (never stack/temp): clay keeps
// the returned slice until draw, so the buffer must outlive build_page, and it
// backs exactly one clay.Text element per frame. If more consumers appear,
// each needs its own buffer.

// timecode at the timeline's fps.
playhead_timecode :: proc() -> string {
	fps_i := int(timeline_fps())
	if fps_i <= 0 {
		fps_i = 30
	}
	f := playhead.frame
	ff := f % i64(fps_i)
	total_sec := f / i64(fps_i)
	s := total_sec % 60
	m := (total_sec / 60) % 60
	h := total_sec / (60 * 60)
	return fmt.bprintf(ui_text.timecode[:], "%02d:%02d:%02d:%02d", h, m, s, ff)
}

// begin_playhead_time_edit opens the text field pre-filled with the current
// timecode; the committed value is parsed by apply_playhead_time.
begin_playhead_time_edit :: proc() {
	text_input_begin(playhead_timecode(), TI_PLAYHEAD, 0)
}

// parse_time_input converts the field text into a timeline frame. Accepted:
//   timecodes "MM:SS:FF" ("6:30:15"), "HH:MM:SS:FF" ("1:06:30:15"),
//   MM:SS ("5:03"),
//   "12.5" / "12.5s" seconds (scaled by fps), "1234" raw frames.
parse_time_input :: proc(s: string, fps: f64) -> (i64, bool) {
	t := strings.trim_space(s)
	if len(t) == 0 {
		return 0, false
	}
	if strings.contains(t, ":") || strings.contains(t, ";") {
		sep := ":"
		if strings.contains(t, ";") {
			sep = ";"
		}
		parts := strings.split(t, sep)
		defer delete(parts)
		if len(parts) < 2 || len(parts) > 4 {
			return 0, false
		}
		// Fields map to (hh, mm, ss, ff) but hours only exist in the full
		// 4-field form: 4 = HH:MM:SS:FF, 3 = MM:SS:FF, 2 = MM:SS. The frames
		// slot is clamped below fps.
		vals := [4]i64{}
		shift := 0
		if len(parts) < 4 {
			shift = 1
		}
		for i in 0 ..< len(parts) {
			p := strings.trim_space(parts[i])
			if len(p) == 0 {
				return 0, false
			}
			v, ok := strconv.parse_i64(p, 10)
			if !ok || v < 0 {
				return 0, false
			}
			vals[shift + i] = v
		}
		// The frames field only exists in the 3- and 4-field forms.
		if len(parts) >= 3 && vals[3] >= i64(fps) {
			return 0, false
		}
		return (((vals[0] * 60 + vals[1]) * 60 + vals[2]) * i64(fps) + vals[3]), true
	}
	// Seconds, e.g. "12.5" or "12.5s".
	sec_s := t
	if sec_s[len(sec_s) - 1] == 's' || sec_s[len(sec_s) - 1] == 'S' {
		sec_s = strings.trim_space(sec_s[:len(sec_s) - 1])
		if len(sec_s) == 0 {
			return 0, false
		}
	}
	if strings.contains(sec_s, ".") {
		v, ok := strconv.parse_f64(sec_s)
		if !ok || v < 0 {
			return 0, false
		}
		return i64(v * fps), true
	}
	// Raw frame number.
	v, ok := strconv.parse_i64(sec_s, 10)
	if !ok || v < 0 {
		return 0, false
	}
	return v, true
}

// apply_playhead_time parses the committed time field and seeks the playhead to
// the parsed frame (clamped to the timeline's last real frame, matching scrub).
apply_playhead_time :: proc() {
	fps := timeline_fps()
	if fps <= 0 {
		return
	}
	frame, ok := parse_time_input(text_input_string(), fps)
	if !ok {
		return
	}
	frame = clamp(frame, 0, max(0, timeline_duration() - 1))
	if playhead.frame == frame {
		return
	}
	playhead.frame = frame
	audio_seek(frame)
	sync.atomic_store(&audio_rpt.ph_src, 1)
	sync.atomic_store(&audio_rpt.ph_catch, 0)
}

// handle_ctx_option dispatches a click on a context-menu entry. Selecting
// Add > Text Clip creates a Text generator clip on the right-clicked track at
// the pointer's frame; the clip-action rows (Rename/Duplicate/Delete/Link)
// act on the clip that was right-clicked (ctx_menu.target_clip_*), which is
// selected first so every later action sees the same selection. The clicked
// row is resolved by its GEOMETRY (row index within the mounted menu/flyout
// box), not clay.PointerOver: the click is handled before this frame's clay
// layout, so clay's hover still reflects the previous frame and would misroute
// (or drop) a click on the flyout the same frame it mounts.
handle_ctx_option :: proc(mx, my: f32) {
	ct := ctx_menu.target_clip_track
	ci := ctx_menu.target_clip_index

	if ctx_menu.submenu && ctx_point_in(mx, my, ctx_flyout_rect()) {
		// Click in the "Add >" flyout: row 0 = Text Clip, row 1 = Subtitle.
		if ctx_row_hit(mx, my, ctx_flyout_rect()) == 0 {
			add_text_clip_at()
		} else {
			add_subtitle_clip_at()
		}
		close_context_menu()
		return
	}

	row := ctx_row_hit(mx, my, clay.GetElementData(clay.ID("CtxMenu")).boundingBox)
	if row >= 1 &&
	   ct >= 0 &&
	   ct < len(timeline.tracks) &&
	   ci >= 0 &&
	   ci < len(timeline.tracks[ct].clips) {
		select_clip(ct, ci)
		switch row {
		case 1:
			begin_clip_rename()
		case 2:
			new_i := duplicate_clip(ct, ci)
			// Select the fresh copy so the user immediately sees what appeared.
			select_clip(ct, new_i)
		case 3:
			toggle_links_for_selection()
		case 4:
			delete_clip_at(ct, ci)
		}
	}
	close_context_menu()
}

// select_clip makes (track_idx,index) the sole timeline selection. Selecting a
// clip deselects any keyframe (S3: the two selections are mutually exclusive).
select_clip :: proc(track_idx, index: int) {
	if track_idx < 0 || track_idx >= len(timeline.tracks) {
		return
	}
	if index < 0 || index >= len(timeline.tracks[track_idx].clips) {
		return
	}
	kf_clear()
	selection.track = track_idx
	selection.index = index
	clear(&selection.extra_set)
	selection.extra_set[timeline.tracks[track_idx].clips[index].clip_id] = true
}

// kf_drop_clip_selection is the half of the S3 exclusivity rule every
// keyframe-selection entry point owes: keyframe selected, clip not.
kf_drop_clip_selection :: proc() {
	selection.track = -1
	selection.index = -1
	clear(&selection.extra_set)
}

// kf_clear drops the keyframe selection. clear, not `kf_sel = {}`: Odin's clear
// KEEPS the backing buffer, so growing the list back to this size later never
// reaches the allocator again, while a struct-literal assign would drop it on
// every deselect.
kf_clear :: proc() {
	clear(&kf_sel.items)
}

// kf_selection_free releases the two grow-only keyframe-selection scratch
// buffers for real. It exists because kf_clear's whole reason for being clear
// rather than assign is that it RETAINS the buffer -- which is right for a
// deselect and wrong at session teardown, where retaining it is the leak. A
// `kf_sel = {}` in the teardown would zero the header and hand back the
// selection's memory, and the two grow-only scratches the keyframe hit tests fill
// (kf_hits, and the brush's record of what it has already painted) are the same
// shape: retained across a deselect, so they survive a full session teardown as
// live allocations unless they are handed back here. Session heap, so: freed
// here and nowhere else.
kf_selection_free :: proc() {
	delete(kf_sel.items)
	delete(kf_hits)
	delete(kf_brush_hovered)
	kf_sel = {}
	kf_hits = nil
	kf_brush_hovered = nil
	kf_brush_armed = false
}

// kf_select makes (track_idx,clip_index,lane,key) the SOLE keyframe selection,
// which deselects the clip selection (the two never coexist, S3).
kf_select :: proc(track_idx, clip_index, lane, key: int) {
	clear(&kf_sel.items)
	append(&kf_sel.items, Kf_Ref{track_idx, clip_index, lane, key})
	kf_sel.gen = kf_view.structure_gen
	kf_drop_clip_selection()
}

// kf_select_add grows the selection by every ref in `refs` that is not already
// in it — the Shift+click path, where `refs` is the set of diamonds under the
// pointer.
//
// Adding is a union, NOT a toggle: toggling a set has no honest answer (which
// way does a press flip two hovered keys when one of them is already in?), and
// a press whose whole point is "select these" must not silently drop half of
// them. Recovery from over-selecting is one plain click, which replaces the set.
kf_select_add :: proc(refs: []Kf_Ref) {
	if kf_sel.gen != kf_view.structure_gen {
		// Stale refs would become VISIBLE again the moment we re-stamp the gen
		// below, aliasing keys that have since slid. The new refs are the whole
		// selection.
		clear(&kf_sel.items)
	}
	kf_sel.gen = kf_view.structure_gen
	for r in refs {
		if !kf_sel_contains(r) {
			append(&kf_sel.items, r)
		}
	}
	kf_drop_clip_selection()
}

// kf_brush_arm enters hover-select. The arming click lands on empty timeline
// space, so there is no key under the pointer to record: the hovered set starts
// empty and the first key the pointer reaches is a genuine crossing.
//
// A brush session ACCUMULATES onto whatever is already selected. Clearing here
// would make "build a set in two passes across the timeline" impossible, and the
// user asking for a persistent mode is asking for exactly that.
kf_brush_arm :: proc() {
	kf_brush_armed = true
	clear(&kf_brush_hovered)
}

// kf_brush_disarm leaves hover-select. The SELECTION is untouched: a selection
// is not an edit, and the set the user painted out is the result of the mode, not
// part of it. Only the memory of where the pointer was goes, so re-arming cannot
// inherit a stale compare.
kf_brush_disarm :: proc() {
	kf_brush_armed = false
	clear(&kf_brush_hovered)
}

// kf_brush_paint adds every keyframe now under the pointer to the selection. It
// is called from the pointer-move path on every move while the mode is armed,
// with no button requirement — that is the whole difference from a drag.
//
// The hovered-set compare makes it a no-op unless the pointer has crossed onto a
// DIFFERENT set, which is what lets the mode survive a resting pointer. A
// brushed key is added, never substituted: the pointer reaches keys one at a
// time, so replacing would leave only the last one crossed.
kf_brush_paint :: proc(x, y: f32) {
	if !kf_brush_armed {
		return
	}
	clear(&kf_hits)
	kf_keys_at(x, y, &kf_hits)
	if len(kf_hits) == 0 || kf_brush_already_painted(kf_hits[:]) {
		return
	}
	// Record the set BEFORE selecting, so a later compare settles even if the
	// write below is invalidated by a structure bump.
	clear(&kf_brush_hovered)
	for r in kf_hits {
		append(&kf_brush_hovered, r)
	}
	kf_select_add(kf_hits[:])
}

// kf_brush_already_painted reports whether `refs` is exactly the set the last
// paint applied. Element-wise is enough: kf_keys_at walks tracks, then clips,
// then lanes, then keys in fixed order, so the same pointer position always
// produces the same refs in the same order.
kf_brush_already_painted :: proc(refs: []Kf_Ref) -> bool {
	if len(refs) != len(kf_brush_hovered) {
		return false
	}
	for r, i in refs {
		if r != kf_brush_hovered[i] {
			return false
		}
	}
	return true
}

// kf_sel_active reports whether a live keyframe selection exists. A selection
// made before the last structure shift reads as empty: one set/del can slide any
// key into a different index, so the whole set invalidates at once.
kf_sel_active :: proc() -> bool {
	return len(kf_sel.items) > 0 && kf_sel.gen == kf_view.structure_gen
}

// kf_sel_count is the number of LIVE selected keyframes — zero for a stale
// selection. Every site that iterates the selection goes through this rather
// than len(kf_sel.items), so a stale set can never be read as live.
kf_sel_count :: proc() -> int {
	return kf_sel_active() ? len(kf_sel.items) : 0
}

// kf_clip_at resolves (track_idx, clip_index) against the live tree, or
// reports false when it is out of bounds. A keyframe edit never reorders
// tracks or clips, so this half of a Kf_Ref stays valid across store ops — which
// is what lets a captured snapshot find its clip again after the first del.
kf_clip_at :: proc(track_idx, clip_index: int) -> (cl: ^Clip, ok: bool) {
	if track_idx < 0 || track_idx >= len(timeline.tracks) {
		return nil, false
	}
	trn := &timeline.tracks[track_idx]
	if clip_index < 0 || clip_index >= len(trn.clips) {
		return nil, false
	}
	return &trn.clips[clip_index], true
}

// kf_resolve bounds-checks one ref against the LIVE tree, so a stale index
// reads as "gone" rather than aliasing whatever now lives there.
kf_resolve :: proc(r: Kf_Ref) -> (cl: ^Clip, lane: int, k: ^Keyframe, ok: bool) {
	clip, found := kf_clip_at(r.track_idx, r.clip_index)
	if !found {
		return nil, -1, nil, false
	}
	if r.lane < 0 || r.lane >= len(clip.keyframe_tracks) {
		return nil, -1, nil, false
	}
	trk := &clip.keyframe_tracks[r.lane]
	if r.key < 0 || r.key >= len(trk.keys) {
		return nil, -1, nil, false
	}
	return clip, r.lane, &trk.keys[r.key], true
}

// kf_selected resolves the selection when it is EXACTLY ONE keyframe, and
// reports false for an empty or a multi selection. The single-key callers (the
// inspector's value field and its click handler) use it so a multi-selection can
// never half-resolve into the first ref and then be edited as though it were
// the only one.
kf_selected :: proc() -> (cl: ^Clip, lane: int, k: ^Keyframe, ok: bool) {
	if kf_sel_count() != 1 {
		return nil, -1, nil, false
	}
	return kf_resolve(kf_sel.items[0])
}

// kf_sel_contains reports whether `r` is in the LIVE selection. Short scan over
// a short list, touching no allocator — which is what a per-painted-diamond
// membership test has to be.
kf_sel_contains :: proc(r: Kf_Ref) -> bool {
	if !kf_sel_active() {
		return false
	}
	for item in kf_sel.items {
		if item == r {
			return true
		}
	}
	return false
}

// kf_sel_same_lane returns the track NAME of the selection's lane when EVERY
// selected key sits on that one lane, and false otherwise. The inspector shows
// it as a multi-selection's header only in that case: a track name is a var
// identity, not a property, so naming one lane while the selection spans several
// would be a claim about the set that isn't true.
//
// Both halves of the location are compared, not just the name: two clips on
// different tracks can each have a lane 0 with the same name, and two lanes of
// one clip can be distinct tracks that happen to agree on nothing — matching on
// the name alone would report those as one shared lane.
//
// The returned string is BORROWED from the live track and is valid for the
// current frame — the caller renders it immediately, and a layout pass mutates
// nothing. Clone it if it must outlive the call.
kf_sel_same_lane :: proc() -> (name: string, ok: bool) {
	first: Kf_Ref
	for item in kf_sel.items {
		cl, lane, _, resolved := kf_resolve(item)
		if !resolved {
			continue
		}
		if !ok {
			first = item
			name = cl.keyframe_tracks[lane].name
			ok = true
			continue
		}
		if item.track_idx != first.track_idx ||
		   item.clip_index != first.clip_index ||
		   cl.keyframe_tracks[lane].name != name {
			return "", false
		}
	}
	return name, ok
}

// kf_sel_frame_span is the inclusive range of ABSOLUTE timeline frames the live
// selection covers, as the one frame-shaped fact true of the whole set. Absolute
// because each key is its own clip's start plus its clip-relative offset, and a
// selection can span clips. A selection that resolves to nothing reports
// (0,0) rather than an inverted range.
kf_sel_frame_span :: proc() -> (lo, hi: i64) {
	seen := false
	for item in kf_sel.items {
		cl, _, k, ok := kf_resolve(item)
		if !ok {
			continue
		}
		f := cl.timeline_start_frame + i64(k.frame_off)
		if !seen {
			lo, hi = f, f
			seen = true
			continue
		}
		lo = min(lo, f)
		hi = max(hi, f)
	}
	return lo, hi
}

// kf_sel_interp aggregates the interpolation mode across the whole live
// selection: `mixed` is true when two or more of the selected keys disagree (and
// the returned mode is then meaningless — the UI shows "-"), and `seen` is false
// when not one ref resolved, so the caller renders no dropdown at all rather than
// naming a mode that belongs to no key. Interpolation is a property of a KEY —
// it eases the segment arriving at that key — so unlike the value there is
// nothing lane-specific about it and this aggregate is honest for a selection
// spanning any number of tracks, lanes and clips.
kf_sel_interp :: proc() -> (interp: Kf_Interp, mixed, seen: bool) {
	n := 0
	out: Kf_Interp
	for item in kf_sel.items {
		_, _, k, ok := kf_resolve(item)
		if !ok {
			continue
		}
		if n == 0 {
			out = k.interp
		} else if k.interp != out {
			return out, true, true
		}
		n += 1
	}
	return out, false, n > 0
}

// kf_set_interp_all writes one interpolation mode onto EVERY selected key as a
// single undoable edit, returning whether any key actually changed (a re-click
// on the mode already in use is a no-op, not a node). It is a plain in-place
// field write per key — interp lives in the key itself and nothing reallocates
// — so all the keys are resolved before the first write without any of them
// dangling.
kf_set_interp_all :: proc(choice: Kf_Interp) -> bool {
	keys: [dynamic]^Keyframe
	defer delete(keys)
	// Decide `changed` from the scan rather than from the write loop, so the
	// no-op case is known before any undo seam opens.
	changed := false
	for item in kf_sel.items {
		_, _, k, ok := kf_resolve(item)
		if !ok {
			continue
		}
		append(&keys, k)
		changed = changed || k.interp != choice
	}
	if !changed {
		return false
	}
	// undo_begin BEFORE the first write. undo_push snapshots the POST-edit tree
	// as the new node and folds the pending PRE-edit snapshot into the cursor's
	// own action, which is how the edit becomes undoable. Opened after the write
	// instead, the pending snapshot is the already-mutated tree: the node records
	// nothing, and undo_undo lands back on the state that still has the new
	// interp — an undo that appears to work and redoes nothing. kf_add_prop and
	// delete_selected_keyframe are the other two writers, and both open the seam
	// before touching the store.
	undo_begin()
	for k in keys {
		k.interp = choice
	}
	undo_push(.Value, "Set keyframe interpolation")
	return true
}

// kf_sel_frame reports whether `r` is in the live keyframe selection and, when it
// is, the frame its diamond should PAINT. Normally that is the key's own
// frame_off; during a Keyframe_Move drag it is the captured start plus the
// gesture's delta (the drag previews, it never writes — see Kf_Move), clamped
// into the clip's own extent, since a selection can span clips and each has its
// own length.
//
// One scan answers both questions, so the draw pass — which asks about every
// diamond it paints — pays for one lookup, not two. The dragged branch reads the
// captures and the idle branch the selection, because a drag is always armed by
// a press that just set the selection: the captures ARE the selection.
kf_sel_frame :: proc(r: Kf_Ref, live: i32) -> (frame: i32, selected: bool) {
	if len(kf_move.snaps) == 0 {
		return live, kf_sel_contains(r)
	}
	for s in kf_move.snaps {
		if s.ref == r {
			return kf_moved_frame(s, kf_move.delta), true
		}
	}
	return live, false
}

// kf_moved_frame is where one captured keyframe sits DURING a drag (and, with
// the same delta, where it will land): its start plus the delta, clamped into its
// own clip's extent. The draw pass and the drag release both go through it, so
// a key always lands exactly where it was drawn.
kf_moved_frame :: proc(s: Kf_Snap, delta: i32) -> i32 {
	cl, ok := kf_clip_at(s.ref.track_idx, s.ref.clip_index)
	if !ok {
		return s.start
	}
	return clamp(s.start + delta, 0, i32(cl.source_length_frames))
}

// kf_capture_sel snapshots every LIVE selected keyframe into `dst` (appending)
// and returns how many it wrote. The caller passes a [dynamic]Kf_Snap it
// releases with kf_snap_free (caller heap, buffer included) or kf_snaps_drop (names
// only, keeping the buffer for a re-armed gesture). `dst` is emptied through
// kf_snaps_drop first, so a re-armed gesture cannot inherit the previous one's
// captures — and cannot orphan their names either.
//
// A ref that no longer resolves is SKIPPED, not fatal: the selection is already
// gen-gated, so a miss means a lane was dropped by something the gen does not
// cover, and the honest answer is to operate on the keys that are still there.
kf_capture_sel :: proc(dst: ^[dynamic]Kf_Snap) -> int {
	kf_snaps_drop(dst)
	n := 0
	for item in kf_sel.items {
		cl, lane, k, ok := kf_resolve(item)
		if !ok {
			continue
		}
		s: Kf_Snap
		s.ref = item
		s.name = strings.clone(cl.keyframe_tracks[lane].name)
		s.start = k.frame_off
		s.final = k.frame_off
		s.mask = k.mask
		s.interp = k.interp
		if k.mask != 0 {
			s.value = k.value.([KF_PACK_MAX]f32)
		} else {
			s.value[0] = k.value.(f32)
		}
		append(dst, s)
		n += 1
	}
	return n
}

// kf_snaps_drop releases the names a capture owns but KEEPS the list's backing
// buffer, for a caller that re-arms the same list every gesture. That is the
// drag path: kf_move.snaps is filled at press and re-filled at the next press,
// so keeping the buffer saves a realloc per drag while a bare clear() would hand
// back one track-name string per selected key. kf_snap_free is the counterpart
// for a caller that owns the list outright and wants the buffer back too.
kf_snaps_drop :: proc(snaps: ^[dynamic]Kf_Snap) {
	for s in snaps^ {
		delete(s.name)
	}
	// clear takes the pointer to the dynamic array directly, not a deref.
	clear(snaps)
}

// kf_snap_free releases a kf_capture_sel result: every cloned name, then the
// buffer. A result that captured nothing still owns its (empty) buffer, so this
// is safe on it.
kf_snap_free :: proc(snaps: ^[dynamic]Kf_Snap) {
	for s in snaps^ {
		delete(s.name)
	}
	delete(snaps^)
}

// kf_add_prop records a new key on `clip` for track-name `name` at the playhead
// (clip-relative, clamped into the clip's extent) with the property's current
// resting value. Discrete edit on the undo seam. Minting the track name is the
// CONSUMER's job — the store never interprets what `name` means, so the caller
// chooses it because it owns the property→name mapping (interaction.odin's
// field handlers). The write goes through kf_geom_set_lane_key so a name that
// is one lane of a packed group unwraps that group first; a name that groups
// with nothing (gain, scale) lands as an ordinary scalar key.
kf_add_prop :: proc(clip: ^Clip, name: string, value: f32) {
	off := clamp(i32(playhead.frame - clip.timeline_start_frame), 0, i32(clip.source_length_frames))
	undo_begin()
	kf_geom_set_lane_key(clip, name, off, value)
	undo_push(.Value, "Add keyframe")
}

// kf_add_group_prop records a whole-SECTION key at the playhead (both translate
// axes, or all four crop edges) with the clip's current values — the group
// twin of kf_add_prop. It goes through kf_geom_set_packed, the packed producer:
// an already-packed section just lands another full knot; a section whose
// sub-properties own scalar keys FOLDS them into one packed track (each lane
// key survives as a partial knot, the new frame keys the whole group). A group
// key never unwraps the section — unwrap only happens when an individual
// sub-property is keyed afterwards (kf_geom_set_lane_key, see S4).
kf_add_group_prop :: proc(clip: ^Clip, sec: string, lanes: [KF_PACK_MAX]f32) {
	off := clamp(i32(playhead.frame - clip.timeline_start_frame), 0, i32(clip.source_length_frames))
	undo_begin()
	kf_geom_set_packed(clip, sec, off, lanes, kf_geom_full_mask(sec))
	undo_push(.Value, "Add group keyframe")
}

// kf_geom_prop_keyed reports whether `name` holds ANY keyframes right now:
// either its own scalar track exists, or (for a lane name) the section that
// groups it is packed and therefore owns keys.
kf_geom_prop_keyed :: proc(clip: ^Clip, name: string) -> bool {
	if kf_track_index(clip^, name) >= 0 {
		return true
	}
	if sec_index, _, is_lane := kf_geom_section_for_lane(name); is_lane {
		defs := kf_geom_sections
		return kf_track_index(clip^, defs[sec_index].name) >= 0
	}
	return false
}

// kf_auto_key writes `value` onto `name`'s track AT THE PLAYHEAD — the
// auto-keyframing entry point every property edit funnels through. It only
// fires when the toggle is on, the playhead sits inside the clip, and the
// property already has keyframes (a property nobody has keyed yet keeps its
// resting-edit behavior: auto-keying writes into existing tracks, it never
// mints them). A key already on the playhead frame is updated in place — its
// interpolation mode survives (kf_set_key's same-frame replace only touches
// the value) — otherwise a new key is inserted. Returns whether a key was
// written, so callers can keep their resting write when this declines.
kf_auto_key :: proc(clip: ^Clip, name: string, value: f32) -> bool {
	if !editor_flags.auto_keyframe {
		return false
	}
	if !clip_visible_at(playhead.frame, clip.timeline_start_frame, clip.source_length_frames) {
		return false
	}
	if !kf_geom_prop_keyed(clip, name) {
		return false
	}
	off := i32(playhead.frame - clip.timeline_start_frame)
	// Auto-key EXTENDS the animation the user already built, so a lane of a
	// packed section is written into the packed track — the section the user
	// keyed must survive their own toggle. The scalar path here would unwrap it
	// ("you keyed an individual value"), which is the right rule for the
	// inspector's per-lane Key button and the wrong one for a background
	// recording of every edit.
	if kf_geom_set_packed_lane_key(clip, name, off, value) {
		return true
	}
	kf_geom_set_lane_key(clip, name, off, value)
	return true
}

// autokey_gesture feeds one live drag-move value into auto-keyframing: a
// property that DEPARTED from its gesture-start value writes the playhead key
// (updating a key already there, else inserting one) so a drag records onto
// the timeline while it happens. No undo handling here — the gesture began
// with undo_begin() and the release-time push captures the whole drag,
// including any key it inserted.
autokey_gesture :: proc(clip: ^Clip, start, current: f32, name: string) -> bool {
	if current == start {
		return false
	}
	return kf_auto_key(clip, name, current)
}

// delete_selected_keyframe removes EVERY selected keyframe as one undoable
// discrete edit; returns false when nothing is selected so callers fall through
// to their clip-delete path.
//
// The whole selection is captured before the first delete (kf_capture_sel),
// because deleting one key slides the key array of every other selected key on
// that lane — and can free a track name a later delete still has to address by.
// A stale selection (structure gen drifted) reads as "gone" and is just dropped,
// never aliased.
delete_selected_keyframe :: proc() -> bool {
	if !kf_sel_active() {
		return false
	}
	snaps := make([dynamic]Kf_Snap)
	defer kf_snap_free(&snaps)
	if kf_capture_sel(&snaps) == 0 {
		kf_clear()
		return true
	}
	undo_begin()
	for s in snaps {
		cl, ok := kf_clip_at(s.ref.track_idx, s.ref.clip_index)
		if !ok {
			continue
		}
		kf_del_key(cl, s.name, s.start)
	}
	kf_clear()
	undo_push(.Value, "Delete keyframe")
	return true
}

// clip_under_pointer returns the (track_idx, index) of the clip currently under
// the pointer, or (-1,-1) when the pointer is over empty timeline space.
clip_under_pointer :: proc() -> (int, int) {
	for track_idx in 0 ..< len(timeline.tracks) {
		for index in 0 ..< len(timeline.tracks[track_idx].clips) {
			if clay.PointerOver(clay.ID("TimelineClip", u32(track_idx * 1000 + index))) {
				return track_idx, index
			}
		}
	}
	return -1, -1
}

// kf_keys_at appends EVERY keyframe diamond under the pointer to `dst`, in
// timeline order (track, then clip, then lane, then key). A Shift+click needs
// the whole hovered set, not just the first hit, so this replaces the old
// first-hit-only kf_key_at: one traversal answers both questions the press
// handler asks (which diamond did I grab, and what else is under the pointer).
//
// Geometry, not clay: the diamonds paint in the post-layout overlay pass, so no
// element exists under them to PointerOver-test. Uses the same kf_key_center
// geometry draw_keyframes paints with, so the pickable spot IS the painted
// diamond — a key clamped at a trimmed edge stays pickable exactly where it
// paints.
//
// The list is usually one entry: lanes sit KF_ROW_H apart and the pick radius is
// KF_HIT_MARGIN, so only vertically stacked keys overlap it, and only coincident
// frames do that horizontally.
kf_keys_at :: proc(mx, my: f32, dst: ^[dynamic]Kf_Ref) {
	for track, ti in timeline.tracks {
		for clip, ci in track.clips {
			if len(clip.keyframe_tracks) == 0 {
				continue
			}
			box :=
				clay.GetElementData(clay.ID("TimelineClipWrap", u32(ti * 1000 + ci))).boundingBox
			if box.width <= 0 || box.height <= 0 {
				continue
			}
			for tr in 0 ..< len(clip.keyframe_tracks) {
				for k, ki in clip.keyframe_tracks[tr].keys {
					cx, cy := kf_key_center(box, tr, k.frame_off)
					if abs(mx - cx) <= KF_HIT_MARGIN && abs(my - cy) <= KF_HIT_MARGIN {
						append(dst, Kf_Ref{ti, ci, tr, ki})
					}
				}
			}
		}
	}
}

// open_clip_context_menu opens the right-click menu anchored at (mx,my) for the
// clip at (track_idx,index): the menu gains the clip-action rows. The clip is
// selected too, so the menu's target is also the visible selection.
open_clip_context_menu :: proc(mx, my: f32, track_idx, index: int) {
	if track_idx < 0 || track_idx >= len(timeline.tracks) {
		return
	}
	if index < 0 || index >= len(timeline.tracks[track_idx].clips) {
		return
	}
	select_clip(track_idx, index)
	open_track_context_menu(mx, my, track_idx)
	ctx_menu.target_clip_track = track_idx
	ctx_menu.target_clip_index = index
}

// delete_clip_at deletes the clip at (track_idx,index), rippling the whole link
// group when the clip is linked (matching Backspace behavior). The region-based
// ripple selects/clears whatever the existing helpers expect.
delete_clip_at :: proc(track_idx, index: int) {
	if track_idx < 0 || track_idx >= len(timeline.tracks) {
		return
	}
	if index < 0 || index >= len(timeline.tracks[track_idx].clips) {
		return
	}
	clip := &timeline.tracks[track_idx].clips[index]
	if clip.link_id != 0 {
		ripple_delete_linked_group(clip.link_id)
	} else {
		ripple_delete_region(clip.timeline_start_frame, clip.source_length_frames)
	}
}

// timeline_zoom_about_playhead multiplies the timeline zoom by factor, keeping
// the playhead's visible frame fixed (same math as the ruler wheel handler).
timeline_zoom_about_playhead :: proc(factor: f32) {
	anchor := f32(playhead.frame - i64(timeline_view.start)) * timeline_view.zoom
	anchor_frame := timeline_view.start + anchor / max(timeline_view.zoom, 0.0001)
	new_zoom := clamp(timeline_view.zoom * factor, TIMELINE_MIN_ZOOM, TIMELINE_MAX_ZOOM)
	if new_zoom != timeline_view.zoom {
		timeline_view.start = clamp(
			anchor_frame - anchor / max(new_zoom, 0.0001),
			0,
			f32(timeline_duration()),
		)
		timeline_view.zoom = new_zoom
	}
}

// timeline_zoom_fit scales the timeline so the whole content fits the ruler
// width, returning to frame 0.
timeline_zoom_fit :: proc() {
	ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
	if ruler.width <= 0 {
		return
	}
	new_zoom := clamp(
		ruler.width / f32(max(timeline_duration(), 1)),
		TIMELINE_MIN_ZOOM,
		TIMELINE_MAX_ZOOM,
	)
	timeline_view.zoom = new_zoom
	timeline_view.start = 0
}

// add_text_clip_at inserts a Text generator clip on ctx_menu.target_track at
// the frame captured when the context menu was opened (right-click), one second
// long (shortened to fit its free gap). After insert the new clip becomes the
// timeline selection.
add_text_clip_at :: proc() {
	if ctx_menu.target_track < 0 ||
	   ctx_menu.target_track >= len(timeline.tracks) {
		return
	}
	undo_begin()
	idx := add_text_generator_clip(&timeline.tracks[ctx_menu.target_track], ctx_menu.frame)
	audio_note_edit()

	selection.track = ctx_menu.target_track
	selection.index = idx

	// A text clip is defined by its title, so creating one requires a name: open
	// the rename field in "create" mode. If the user commits an empty name (or
	// cancels) the just-inserted clip is removed (see apply_rename and the cancel
	// routing), so "Add > Text Clip" never leaves a nameless clip on the track.
	clip := &timeline.tracks[selection.track].clips[selection.index]
	text_input_begin("", TI_RENAME, clip.clip_id)
	ti.is_create = true
}

// add_subtitle_clip_at inserts a Subtitle generator clip on ctx_menu.target_track
// at the frame captured when the context menu was opened. It immediately opens
// an .srt-only file dialog; only a successful pick creates a clip (cancel or a
// parse failure leaves the timeline untouched). The clip's name is the srt's
// basename and its length is the srt's full authored span.
add_subtitle_clip_at :: proc() {
	if ctx_menu.target_track < 0 || ctx_menu.target_track >= len(timeline.tracks) {
		return
	}
	path := open_srt_picker()
	if path == nil {
		return // user cancelled (or picker error) — no clip
	}
	srt_id := srt_load(path)
	if srt_id < 0 {
		show_ui_noticef(4000, "Could not load subtitles from '%s'", path_basename(path))
		return
	}
	name := strings.clone(path_basename(path))
	undo_begin()
	idx := add_subtitle_generator_clip(
		&timeline.tracks[ctx_menu.target_track],
		ctx_menu.frame,
		srt_id,
		name,
	)
	audio_note_edit()

	selection.track = ctx_menu.target_track
	selection.index = idx

	undo_push(.Text, "Add subtitle clip")
}

// is_srt_pick reports whether a picked path is a subtitle file (".srt" suffix,
// case-insensitive). Picks like these are routed to the subtitle flow by the
// media import / open-file buttons, which otherwise can't do anything useful
// with a text file (ffprobe reports no streams).
is_srt_pick :: proc(path: cstring) -> bool {
	p := string(path)
	n := len(p)
	if n < 4 {
		return false
	}
	ext := p[n - 4:n]
	suffix := ".srt"
	for i in 0 ..< 4 {
		ch := ext[i]
		if ch >= 'A' && ch <= 'Z' {
			ch += 32
		}
		if ch != suffix[i] {
			return false
		}
	}
	return true
}

// pointer_over_context_menu reports whether the cursor is inside the context
// menu popup proper or its "Add >" submenu (both are part of the same transient
// UI). It tests the last frame's element GEOMETRY directly (not clay's
// frame-lagged PointerOver), so a click on the flyout the same frame it mounts
// still routes to handle_ctx_option instead of dismissing the menu.
pointer_over_context_menu :: proc(mx, my: f32) -> bool {
	return ctx_popup_hover(mx, my)
}

// handle_playback_rate_click resolves a click for the playback-rate dropdown.
// rate_clicked reports whether the collapsed rate button itself was clicked
// (toggles the menu). Otherwise, if the menu is open, a click on one of its
// options sets playback.rate and closes the menu; any other click dismisses the
// menu. Clicks elsewhere in the UI go through the normal input chain and simply
// close the open menu here.
handle_playback_rate_click :: proc(rate_clicked: bool) {
	if rate_clicked {
		playback.rate_open = !playback.rate_open
		return
	}
	if !playback.rate_open {
		return
	}
	if in_playback_rate_menu() {
		playback.rate = rate_from_element()
		playback.rate_open = false
	} else {
		playback.rate_open = false
	}
}

// in_playback_rate_menu reports whether the pointer is over the open dropdown
// menu (any option). The menu only exists while open, so every candidate id is
// from a currently-rendered element.
in_playback_rate_menu :: proc() -> bool {
	for rate in PLAYBACK_RATES {
		id_buf: [64]u8
		if clay.PointerOver(clay.ID(playback_rate_name(rate, id_buf[:]))) {
			return true
		}
	}
	return false
}

// rate_from_element returns the playback rate whose dropdown option is under
// the pointer (the selection just made). Only valid inside an open menu.
rate_from_element :: proc() -> f64 {
	for rate in PLAYBACK_RATES {
		id_buf: [64]u8
		if clay.PointerOver(clay.ID(playback_rate_name(rate, id_buf[:]))) {
			return rate
		}
	}
	return playback.rate
}

// play_project_area starts playback at the render range's start frame and
// stops at its end frame (exclusive). With no range set it falls back to a
// plain toggle.
play_project_area :: proc() {
	if project.start_frame < 0 || project.end_frame <= project.start_frame {
		toggle_playback()
		return
	}
	playhead.frame = project.start_frame
	playback.stop_frame = project.end_frame
	playback.dir = 1
	playback.boost = 0
	playback.accumulator = 0
	playback.last_tick_ns = monotonic_ns()
	audio_prod.was_playing = false
	playhead.playing = true
	preview.playing = true
	if vyper_trace {
		fmt.printf("[pb] area ph=%d stop=%d\n", playhead.frame, playback.stop_frame)
	}
}

// playback_publish records (frame, wall-time) for the audio producer under a
// seqlock: a reader that samples the pair while the UI is mid-publish retries
// instead of reading a torn frame/time mismatch.
playback_publish :: proc(frame: i64, now_ns: sdl.Uint64) {
	sync.atomic_add(&playback.seq, 1)
	sync.atomic_store(&playback.ui_frame, frame)
	sync.atomic_store(&playback.ui_ns, i64(now_ns))
	sync.atomic_add(&playback.seq, 1)
}

// playback_read_snapshot returns the last published (frame, wall-time) pair,
// retrying until a consistent one is observed.
playback_read_snapshot :: proc() -> (frame: i64, ns: i64) {
	for {
		s0 := sync.atomic_load(&playback.seq)
		if s0 & 1 != 0 {
			continue
		}
		frame = sync.atomic_load(&playback.ui_frame)
		ns = sync.atomic_load(&playback.ui_ns)
		if sync.atomic_load(&playback.seq) == s0 {
			return
		}
	}
}

// playback_playhead_at advances the last published playhead to now_ns using the
// wall clock and the rate audio is actually feeding at. The UI publishes the
// frame it just computed the same tick, so its elapsed is ~0; the producer
// calls this mid-tick, including across a UI stall, so the playhead it targets
// is where playback really is rather than where the UI last managed to render.
// Only forward extrapolation is meaningful -- audio is forward-only.
playback_playhead_at :: proc(now_ns: sdl.Uint64, rate: f64) -> i64 {
	frame, ns := playback_read_snapshot()
	fps := timeline_fps()
	elapsed := f64(i64(now_ns) - ns) / 1e9
	if ns <= 0 || fps <= 0 || elapsed <= 0 {
		return frame
	}
	return frame + i64(elapsed * fps * max(1.0, rate))
}

playback_update :: proc(now_ns: sdl.Uint64) {
	if playback.last_tick_ns == 0 {
		playback.last_tick_ns = now_ns
	}
	if playhead.playing {
		// Playback is real-time: consume the true wall delta, never a clamped
		// one. A clamp silently drops the unapplied remainder, which strands the
		// playhead behind the wall clock permanently and desyncs it from the
		// audio producer (which extrapolates this same clock). A long stall
		// therefore jumps the playhead to where it should be, and audio_update's
		// forward-skip resyncs the producer if it had fallen behind.
		// DIAG (temporary): playback.magic_ms replaces the measured wall
		// delta so the cadence is perfectly jitter-free (or any fixed rate).
		dt_s :=
			playback.magic_ms > 0 ? playback.magic_ms / 1000.0 : f64(now_ns - playback.last_tick_ns) / 1_000_000_000
		// The playhead advances +dir frames at effective_playback_rate against
		// the wall clock (rate * jog boost). Audio pacing at non-1x is the
		// producer's stream frequency ratio; audio is muted going backward.
		playback.accumulator += dt_s * max(0.0, effective_playback_rate())
		playback_fps := timeline_fps()
		catchup := i64(0)
		for playback.accumulator >= 1.0 / playback_fps {
			playhead.frame += i64(playback.dir)
			catchup += 1
			playback.accumulator -= 1.0 / playback_fps
		}
		if catchup > 0 {
			sync.atomic_store(&audio_rpt.ph_src, 2)
			sync.atomic_store(&audio_rpt.ph_catch, catchup)
			if catchup > 1 {
				if vyper_trace {
					fmt.printf(
						"[pb] burst %+d ph=%d dt=%.1fms acc=%.3fs\n",
						i64(playback.dir) * catchup,
						playhead.frame,
						f64(now_ns - playback.last_tick_ns) / 1e6,
						playback.accumulator,
					)
				}
			}
		}
		// Directional boundary: stop at the run end going forward, at frame 0
		// going backward. Resetting the boost on auto-stop so a later play
		// starts from the selected rate.
		stop_frame := playback.stop_frame
		if stop_frame < 0 {
			stop_frame = timeline_duration()
		}
		at_end :=
			(playback.dir == 1 && playhead.frame >= stop_frame) ||
			(playback.dir == -1 && playhead.frame <= 0)
		if at_end {
			playback.stop_frame = -1
			playback.boost = 0
			playhead.frame = clamp(playhead.frame, 0, max(0, stop_frame - 1))
			playhead.playing = false
			preview.playing = false
			if vyper_trace {
				fmt.printf(
					"[pb] auto-stop dir=%d ph=%d stop=%d\n",
					playback.dir,
					playhead.frame,
					stop_frame,
				)
			}
		}
		// Playback is real-time: the playhead (and with it the audio) runs on
		// the wall clock. Video decode is best-effort on top of that clock.
	}
	playback.last_tick_ns = now_ns
}

// ---------------------------------------------------------------------------

main :: proc() {
	when ODIN_OS == .Windows {
		crash_handler_install()
		win_ffmpeg_versions_diag()
	}
	vyper_trace = os.get_env_alloc("VYPER_TRACE", context.temp_allocator) == "1"
	flash_rec_init()
	// DIAG: headless playback-rate override (the GUI dropdown is mouse-only);
	// the audio producer reads playback.rate for its atempo graph and cushion.
	if v := os.get_env_alloc("VYPER_RATE", context.temp_allocator); v != "" {
		playback.rate, _ = strconv.parse_f64(v)
		if vyper_trace {
			fmt.printf("[main] VYPER_RATE -> playback.rate=%.2f\n", playback.rate)
		}
	}
	// libav's INFO chatter (libx264 "using cpu capabilities", decoder open
	// lines) used to go to a silenced ffmpeg subprocess (-loglevel error); it
	// is in-process now, so quiet the library globally to match.
	avutil.log_set_level(.Error)
	if os.get_env_alloc("VYPER_HW_ENABLE", context.temp_allocator) == "1" {
		hw_decode_enabled = true
	}
	// Probes below drive real edit paths (split, delete, duplicate, track
	// reorder) that record undo history, so the history must exist before any
	// probe runs. The normal path re-inits at startup; probes return first.
	undo_init()
	if test_path_ok, test_paths := render_test_env(); test_path_ok {
		render_test_run(test_paths)
		return
	}
	if hw_probe, _ := os.lookup_env_alloc("VYPER_HW_PROBE", context.temp_allocator); hw_probe != "" {
		preview_hw_probe_run(hw_probe)
		return
	}
	if ep, _ := os.lookup_env_alloc("VYPER_ENC_PROBE", context.temp_allocator); ep != "" {
		os.exit(enc_probe_run(ep))
	}
	if rp, _ := os.lookup_env_alloc("VYPER_RATE_PROBE", context.temp_allocator); rp != "" {
		preview_rate_probe_run(rp)
		return
	}
	if fp, _ := os.lookup_env_alloc("VYPER_FRAME_PROBE", context.temp_allocator); fp != "" {
		preview_framecheck_run(fp)
		return
	}
	if probe_path_ok, probe_paths := preview_probe_env(); probe_path_ok {
		// These probes step the playhead through update_preview_slots, which
		// routes every slot through its own async worker. Start it in probe
		// mode (deterministic: every step waits for each slot's decode) and
		// tear it down before asserting.
		async_live_mode = false
		async_dec_init()
		defer async_dec_shutdown()
		preview_probe_run(probe_paths)
		return
	}
if psp, _ := os.lookup_env_alloc("VYPER_PROXY_STEP", context.temp_allocator); psp != "" {
		async_live_mode = false
		async_dec_init()
		defer async_dec_shutdown()
		proxy_step_probe_run(psp)
		return
	}
	if bp, _ := os.lookup_env_alloc("VYPER_BOUNDARY_PROBE", context.temp_allocator); bp != "" {
		async_live_mode = false
		async_dec_init()
		defer async_dec_shutdown()
		boundary_probe_run(bp)
		return
	}
	if cp, _ := os.lookup_env_alloc("VYPER_CACHE_PROBE", context.temp_allocator); cp != "" {
		cache_probe_run(cp)
		return
	}
	if tp, _ := os.lookup_env_alloc("VYPER_TRANSFORM_PROBE", context.temp_allocator); tp != "" {
		transform_probe_run(tp)
		return
	}
	if tlp, _ := os.lookup_env_alloc("VYPER_TL_PROBE", context.temp_allocator); tlp != "" {
		timeline_probe_run(tlp)
		return
	}
	if drp, _ := os.lookup_env_alloc("VYPER_DRAG_PROBE", context.temp_allocator); drp != "" {
		drag_probe_run(drp)
		return
	}
	if xp, _ := os.lookup_env_alloc("VYPER_PROXY_PROBE", context.temp_allocator); xp != "" {
		proxy_probe_run(xp)
		return
	}
if xb, _ := os.lookup_env_alloc("VYPER_PROXY_BG_TEST", context.temp_allocator); xb != "" {
		proxy_bg_probe_run(xb)
		return
	}
	if xs, _ := os.lookup_env_alloc("VYPER_PROXY_SCHED_TEST", context.temp_allocator); xs != "" {
		proxy_sched_probe_run(xs)
		return
	}
	if ps, _ := os.lookup_env_alloc("VYPER_PROXY_PICK_SCAN", context.temp_allocator); ps != "" {
		proxy_pick_scan_run(ps)
		return
	}
	if dp, _ := os.lookup_env_alloc("VYPER_DUP_PROBE", context.temp_allocator); dp != "" {
		async_live_mode = false
		async_dec_init()
		defer async_dec_shutdown()
		duplicate_probe_run(dp)
		return
	}
	if fp, _ := os.lookup_env_alloc("VYPER_FLASH_PROBE", context.temp_allocator); fp != "" {
		async_live_mode = false
		async_dec_init()
		defer async_dec_shutdown()
		flash_probe_run(fp)
		return
	}
	if atp, _ := os.lookup_env_alloc("VYPER_ATEMPO_PROBE", context.temp_allocator); atp != "" {
		atempo_probe_run(atp)
		return
	}
	if ap, _ := os.lookup_env_alloc("VYPER_AUDIO_PROBE", context.temp_allocator); ap != "" {
		os.exit(audio_probe_run(ap))
	}
	// Headless undo-tree probe: validates the history tree and the viewer's row
	// renderer without a display (needs no fonts / SDL).
	if handle_undo_probe() {
		return
	}
	// Headless keyframe-store probe: the generic store's sorted insert,
	// linear sample, split/trim remaps, and clone/free round-trip.
	if kp, _ := os.lookup_env_alloc("VYPER_KEYFRAME_PROBE", context.temp_allocator); kp != "" {
		os.exit(keyframe_probe_run())
	}
	if rkp, _ := os.lookup_env_alloc("VYPER_RENDER_KF_PROBE", context.temp_allocator); rkp != "" {
		os.exit(render_kf_probe_run())
	}
	// Headless live-preview mailbox probe: the worker/UI handoff for the export's
	// composed-frame sink (Active 11 S5). Returns out of main on success so the
	// runtime's own teardown allocations are still freed when memcheck takes
	// its census -- the session buffer this probe allocates is exactly the kind
	// of claim the compiler cannot check.
	if render_live_probe_env() {
		if render_live_probe_run() != 0 {
			os.exit(1)
		}
		return
	}
	// Headless gesture-routing probe: an Alt+wheel / Alt+drag edit on a keyed
	// clip must land where the clip is actually read.
	//
	// A passing probe returns out of main rather than calling os.exit(0):
	// os.exit skips the runtime's shutdown, so the thread and TLS allocations
	// the runtime frees at teardown are still live when memcheck takes its
	// census -- they show as "definitely lost" and the memory gate fails on
	// state the program never actually leaked. A failing probe still exits
	// immediately: the non-zero code IS the gate's pass/fail signal, and its
	// memory census is meaningless anyway.
	if _, ok := os.lookup_env_alloc("VYPER_GEOM_KEY_PROBE", context.temp_allocator); ok {
		if geom_key_probe_run() != 0 {
			os.exit(1)
		}
		return
	}
	// Headless UI draw-call probe: runs build_page's clay layout for N frames
	// on a synthetic session and tallies per-frame draw calls (per Rectangle/
	// Border command + per glyph) without a display or GPU.
	// Headless GPU export probe: creates a GPU device with no window, resamples
	// on the hardware sampler, reads back, and gates the result against the
	// committed CPU kernel. This is the first gate of the GPU export path --
	// if the device, the SPIR-V, or the readback does not work here, the export
	// falls back to the CPU and there is nothing further to tune.
	if g, _ := os.lookup_env_alloc("VYPER_GPU_PROBE", context.temp_allocator); g != "" {
		os.exit(gpu_resample_probe_run())
	}
	if _, ok := os.lookup_env_alloc("VYPER_GPU_NV12_PROBE", context.temp_allocator); ok {
		os.exit(gpu_nv12_probe_run())
	}
	if _, ok := os.lookup_env_alloc("VYPER_GPU_COMPOSITE_PROBE", context.temp_allocator); ok {
		os.exit(gpu_composite_probe_run())
	}
	if _, ok := os.lookup_env_alloc("VYPER_RENDER_OPACITY_PROBE", context.temp_allocator); ok {
		os.exit(render_opacity_probe_run())
	}
	if _, ok := os.lookup_env_alloc("VYPER_YUV_EXACT_PROBE", context.temp_allocator); ok {
		os.exit(yuv_exact_probe_run())
	}
	if v, _ := os.lookup_env_alloc("VYPER_CLIPW_PROBE", context.temp_allocator); v != "" {
		ui_probe_clip_widths(v)
		return
	}
	if v, _ := os.lookup_env_alloc("VYPER_UI_PROBE", context.temp_allocator); v != "" {
		ui_draw_probe_run()
	}
	spall_prof_init()
	defer spall_prof_shutdown()
	if !load_font_data() {
		return
	}
	if fp, _ := os.lookup_env_alloc("VYPER_FONT_PROBE", context.temp_allocator); fp != "" {
		font_probe_run()
	}
	if sub_render_probe, _ := os.lookup_env_alloc(
		"VYPER_SUB_RENDER_PROBE",
		context.temp_allocator,
	); sub_render_probe != "" {
		// The probe free-alls the temp arena per simulated frame, so the env
		// string must not live on the temp arena (same rule as the autoplay
		// path below). Clone it to a cstring the probe keeps for the session.
		probe_out := strings.clone_to_cstring(sub_render_probe, context.allocator)
		subtitle_render_probe_run(string(probe_out))
		return
	}
	if !sdl.Init(sdl.INIT_VIDEO | sdl.INIT_AUDIO) {
		fmt.println("SDL initialization failed")
		return
	}
	defer sdl.Quit()

	window := sdl.CreateWindow("vyper", WINDOW_WIDTH, WINDOW_HEIGHT, {.RESIZABLE, .VULKAN})
	if window == nil {
		fmt.println("Could not create vyper window")
		return
	}
	defer sdl.DestroyWindow(window)
	app_window = window
	// SDL text input is instead enabled per edit session: text_input_begin
	// turns it on, text_input_commit/cancel turn it off, so the IME softens
	// nothing while no field is open (global hotkeys stay crisp).

	device := sdl.CreateGPUDevice({.SPIRV}, true, "vulkan")
	if device == nil {
		fmt.println("Could not create SDL GPU device")
		return
	}
	defer sdl.DestroyGPUDevice(device)
	if !sdl.ClaimWindowForGPUDevice(device, window) {
		fmt.println("Could not claim window for SDL GPU device")
		return
	}
	defer sdl.ReleaseWindowFromGPUDevice(device, window)
	format := sdl.GetGPUSwapchainTextureFormat(device, window)
	if format == .INVALID {
		fmt.println("Could not get GPU swapchain format")
		return
	}
	if !sdl.SetGPUSwapchainParameters(device, window, .SDR, .VSYNC) {
		fmt.println("Could not configure GPU swapchain")
		return
	}
	renderer, ok := create_gpu_renderer(device, format, WINDOW_WIDTH, WINDOW_HEIGHT)
	if !ok {
		fmt.println("Could not create rounded rectangle GPU pipeline")
		return
	}
	// Publish the renderer for off-main-thread subsystems (the export worker's
	// GPU compositor). `renderer` is a local of main that lives until shutdown,
	// so this pointer is valid for every worker's lifetime.
	gpu_renderer = &renderer
	defer sdl.ReleaseGPUGraphicsPipeline(device, renderer.pipeline)
	defer sdl.ReleaseGPUGraphicsPipeline(device, renderer.text_pipeline)
	defer sdl.ReleaseGPUGraphicsPipeline(device, renderer.preview_pipeline)
	defer sdl.ReleaseGPUTexture(device, renderer.font.texture)
	defer sdl.ReleaseGPUSampler(device, renderer.font.sampler)
	defer glyph_atlas_destroy(&renderer.font)
	defer release_preview_textures(device, renderer.preview_textures[:])
	// The live-preview mailbox is session heap -- it is sized per job canvas and
	// reused across runs, so freeing it per run would be churn -- and its texture
	// is sink-owned. Both are released here, and only here.
	defer render_live_teardown()
	defer release_live_preview_texture(device)
	defer if renderer.preview_upload_tb != nil {
		sdl.ReleaseGPUTransferBuffer(device, renderer.preview_upload_tb)
	}
	defer if renderer.text_upload_tb != nil {
		sdl.ReleaseGPUTransferBuffer(device, renderer.text_upload_tb)
	}
	defer release_slot_owned_textures(device)
	defer sdl.ReleaseGPUSampler(device, renderer.preview_sampler)
	defer for id in Icon_Id {
		if renderer.icon_textures[id] != nil {
			sdl.ReleaseGPUTexture(device, renderer.icon_textures[id])
		}
	}
	// Media-bin thumbnails own per-asset GPU textures; free them at shutdown.
	defer release_media_asset_textures(device)
	// Cache metrics for printable ASCII so plain-text UI never waits on a
	// grow round-trip; ink pixels land on the first deferred upload pass.
	glyph_atlas_ensure_ascii(&renderer.font)
	initial_upload := sdl.AcquireGPUCommandBuffer(device)
	if initial_upload == nil ||
	   !upload_icons(&renderer, initial_upload) ||
	   !sdl.SubmitGPUCommandBuffer(initial_upload) {
		fmt.println("Could not upload initial GPU data:", sdl.GetError())
		return
	}

	audio_init()
	defer audio_shutdown()
	async_dec_init()
	defer async_dec_shutdown()
	import_bg_init()
	defer import_bg_shutdown()
	undo_init()
	defer if warm.valid {
		clip_decoder_reset(&warm.decoder)
	}
	render_init()

	memory := make([^]u8, clay.MinMemorySize())
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(c.size_t(clay.MinMemorySize()), memory),
		{WINDOW_WIDTH, WINDOW_HEIGHT},
		{handler = clay_error},
	)
	clay.SetMeasureTextFunction(measure_text, nil)

	// DIAG (temporary): magic playhead-clock knobs.
	if v := os.get_env_alloc("VYPER_PLAYBACK_MAGIC_MS", context.temp_allocator); v != "" {
		playback.magic_ms, _ = strconv.parse_f64(v)
	}
	if v := os.get_env_alloc("VYPER_PLAYBACK_FPS", context.temp_allocator); v != "" {
		playback.magic_fps, _ = strconv.parse_f64(v)
	}
	if playback.magic_ms > 0 || playback.magic_fps > 0 {
		if vyper_trace {
			fmt.printf(
				"[pb] DIAG magic clock: magic_ms=%.3f fps_override=%.3f\n",
				playback.magic_ms,
				playback.magic_fps,
			)
		}
	}

	// Media file arguments: `vyper media.mp4 ...` opens each listed file through
	// the normal Open-File flow (probe -> bin + timeline append; a bad path
	// shows the notice and is skipped). This is what the desktop entry's
	// "Open with vyper" hands over. open_file_at only reads the cstring (the bin
	// clones it), so the argv bytes are safe to point at directly.
	for arg_i := 1; arg_i < len(os.args); arg_i += 1 {
		path := cstring(raw_data(os.args[arg_i]))
		if vyper_trace {
			fmt.printf("[args] open \"%s\"\n", os.args[arg_i])
		}
		open_file_at(path)
	}

	// DIAG: env-var autoplay for headless-ish diagnostics — autoloads a file and
	// starts playback after a couple of seconds. Refuses silently-failed imports
	// (bad path, unreadable file, probe failure) instead of opening an empty
	// project that immediately auto-stops without ever playing anything.
	if autoplay := os.get_env_alloc("VYPER_AUTOPLAY", context.temp_allocator); autoplay != "" {
		if vyper_trace {
			fmt.printf("[autoplay] env=\"%s\" step=import\n", autoplay)
		}
		// import_media only reads this cstring (the bin clones it into session
		// heap), so the null-terminated scratch copy dies with the frame arena.
		import_media(strings.clone_to_cstring(autoplay))
		if vyper_trace {
			fmt.printf(
				"[autoplay] env=\"%s\" imported tracks=%d step=delay\n",
				autoplay,
				len(timeline.tracks),
			)
		}
		if len(timeline.tracks) == 0 {
			if vyper_trace {
				fmt.printf(
					"[autoplay] FATAL: VYPER_AUTOPLAY=\"%s\" imported nothing (no audio track)\n",
					autoplay,
				)
			}
			os.exit(1)
		}
		sleep_ms(2500)
		if vyper_trace {
			fmt.printf("[autoplay] env=\"%s\" step=play\n", autoplay)
		}
		playhead.playing = true
		preview.playing = true
		playback.accumulator = 0
		playback.last_tick_ns = monotonic_ns()
		if sec := os.get_env_alloc("VYPER_PLAY_SEC", context.temp_allocator); sec != "" {
			if v, okf := strconv.parse_f64(sec); okf && v > 0 {
				playback.stop_frame = i64(v * timeline_fps())
				if vyper_trace {
					fmt.printf("[autoplay] VYPER_PLAY_SEC=%.0f -> stop=%d\n", v, playback.stop_frame)
				}
			}
		}
		audio_note_edit()
	}


	running := true
	was_mouse_down := false
	was_right_down := false
	ui_report_tick := u64(0)
	ui_frame_count := 0
	ui_dec_us := i64(0)
	for running {
		spall_scope("render_frame")
		// Frame-scoped scratch (timeline edit temporaries, decode error
		// strings, preview decode buffers) lives on the temp arena; reset it
		// once per loop so the arena stays bounded to one frame's peak.
		mem.free_all(context.temp_allocator)
		if spall_expired() {
			running = false
		}
		clear_expired_ui_notice()
		handle_sdl_events(&running)
		// A close/quit event sets running=false inside the event poll above. If
		// we fall through into the render+present, the blocking GPU swapchain
		// acquire (WaitAndAcquireGPUSwapchainTexture) never returns once the
		// window is going away, so the loop would never re-check running and the
		// process would hang instead of exiting. Break now so the defers run.
		if !running {
			break
		}

		width, height: c.int
		sdl.GetWindowSize(window, &width, &height)
		inp := read_mouse_input()
		interaction_pre_build(inp)

		commands := build_page(width, height)
		clamp_view_scrolls()
		was_mouse_down, was_right_down = interaction_post_build(
			inp,
			was_mouse_down,
			was_right_down,
			height,
		)

		now_ns := monotonic_ns()
		playback_update(now_ns)
		playback_publish(playhead.frame, now_ns)
		audio_update()
		poll_completed_thread()
		import_bg_consume_done()
		proxy_build_schedule()
		ui_frame_count += 1
		if ui_report_tick == 0 {
			ui_report_tick = now_ns
		} else if now_ns - ui_report_tick >= 2_000_000_000 {
			if vyper_trace {
				elapsed := f64(now_ns - ui_report_tick) / 1e9
				fmt.printf(
					"[ui] fps=%.1f dec_ms=%.1f playhead=%d acc=%.3fs src=%d catch=%d prod=%d\n",
					f64(ui_frame_count) / elapsed,
					f64(ui_dec_us) / 1000.0 / f64(ui_frame_count),
					playhead.frame,
					playback.accumulator,
					sync.atomic_load(&audio_rpt.ph_src),
					sync.atomic_load(&audio_rpt.ph_catch),
					sync.atomic_load(&audio_prod.prod_frame),
				)
			}
			ui_report_tick = now_ns
			ui_frame_count = 0
			ui_dec_us = 0
		}
		if !render_ui_frame(device, window, &renderer, commands, width, height, &ui_dec_us) {
			continue
		}
	}
}
