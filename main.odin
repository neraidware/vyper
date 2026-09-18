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
// frame 0 when already at/past the end) or pauses it. playback_stop_frame is
// cleared so a normal run plays the whole timeline.
toggle_playback :: proc() {
	if playhead.playing {
		playhead.playing = false
		preview.playing = false
		// A pause drops the jog speed boost so the next play uses the selected
		// rate again.
		playback_boost = 0
		if vyper_trace {
			fmt.printf("[pb] toggle playing=%v ph=%d\n", playhead.playing, playhead.frame)
		}
		return
	}
	if playback_dir == 1 && playhead.frame >= timeline_duration() {
		playhead.frame = 0
	}
	playback_stop_frame = -1
	playhead_accumulator = 0
	last_tick_ns = sdl.GetTicksNS()
	audio_was_playing = false
	playhead.playing = true
	preview.playing = true
	if vyper_trace {
		fmt.printf(
			"[pb] toggle playing=%v ph=%d dir=%d\n",
			playhead.playing,
			playhead.frame,
			playback_dir,
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
		playback_dir = dir
		playback_boost = 0
		if playback_stop_frame < 0 && dir == -1 && playhead.frame <= 0 {
			// Nothing to show backward from frame 0.
			return
		}
		playback_stop_frame = -1
		playhead_accumulator = 0
		last_tick_ns = sdl.GetTicksNS()
		audio_was_playing = false
		playhead.playing = true
		preview.playing = true
		if vyper_trace {
			fmt.printf("[pb] jog start dir=%d ph=%d\n", dir, playhead.frame)
		}
		return
	}
	// Already playing.
	if playback_dir == dir {
		playback_boost += 1
		if vyper_trace {
			fmt.printf(
				"[pb] jog boost dir=%d boost=%d eff=%.2fx\n",
				dir,
				playback_boost,
				effective_playback_rate(),
			)
		}
	} else {
		playback_dir = dir
		playback_boost = 0
		if vyper_trace {
			fmt.printf("[pb] jog flip dir=%d ph=%d\n", dir, playhead.frame)
		}
	}
}

// effective_playback_rate is the rate the playhead actually advances at: the
// selected rate scaled by the temporary jog boost.
effective_playback_rate :: proc() -> f64 {
	return playback_rate * f64(1 + max(0, playback_boost))
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
// purely from the track count and the fixed geometry constants. The track
// region scrolls exactly this far, so content and viewport never disagree
// regardless of layout timing.
timeline_tracks_content_height :: proc() -> f32 {
	n := len(timeline.tracks)
	return f32(n + 1) * TRACK_GAP_H + f32(n) * TRACK_ROW_H
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
		if _timeline_arrow_cursor == nil {
			_timeline_arrow_cursor = sdl.CreateSystemCursor(.DEFAULT)
		}
		_ = sdl.SetCursor(_timeline_arrow_cursor)
		return
	}
	if _timeline_resize_cursor == nil {
		_timeline_resize_cursor = sdl.CreateSystemCursor(.EW_RESIZE)
	}
	_ = sdl.SetCursor(_timeline_resize_cursor)
}

// open_track_context_menu shows the per-track right-click menu at the pointer,
// snapshotting the click position (frame) so a later Add-text action inserts at
// the original right-click location, not where the pointer ends up hovering
// over the menu.
open_track_context_menu :: proc(mx, my: f32, track: int) {
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
	ctx_menu.frame = i64(max(f32(0), (mx - track_start) / timeline_zoom + timeline_view_start))
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

// escape_dismiss closes any transient overlay (right-click context menu, the
// playback-rate dropdown, the help overlay). Called on ESC while not editing a
// text field.
escape_dismiss :: proc() {
	close_context_menu()
	playback_rate_open = false
	help_open = false
	undo_hist.view_open = false
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
	if ti.is_create {
		ti.is_create = false
		if strings.trim_space(name) == "" {
			delete_selected_clip_raw()
			return
		}
	}
	if _, clip, ok := find_clip_by_id(ti.target); ok {
		new_name := strings.trim_space(name)
		changed := clip.name != new_name
		if clip.name != "" {
			delete(clip.name)
		}
		clip.name = strings.clone(new_name)
		if ti.is_create {
			// The create-mode rename is what keeps the just-inserted clip: an
			// empty/cancelled name already deleted it above, so reaching here
			// means a real text clip was added.
			undo_push(.Text, "Add text clip")
		} else if changed {
			undo_push(.Rename, "Rename clip")
		}
	}
}

// ---------------------------------------------------------------------------
// Playhead time viewer: numeric timeline navigation. The timeline toolbar's
// time badge (PlayheadTime) opens the generic text input pre-filled with the
// current playhead timecode; on commit the typed value is parsed back into a
// frame and the playhead is sought there (same path as scrubbing).
// ---------------------------------------------------------------------------

// playhead_timecode renders the current playhead frame as an HH:MM:SS:FF
// value. playhead_timecode_buf is persistent (never stack/temp): clay keeps
// the returned slice until draw, so the buffer must outlive build_page, and
// it backs exactly one clay.Text element per frame. If more consumers appear,
// each needs its own buffer.
playhead_timecode_buf: [32]u8

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
	return fmt.bprintf(playhead_timecode_buf[:], "%02d:%02d:%02d:%02d", h, m, s, ff)
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
	sync.atomic_store(&audio_ph_src, 1)
	sync.atomic_store(&audio_ph_catch, 0)
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

// select_clip makes (track_idx,index) the sole timeline selection.
select_clip :: proc(track_idx, index: int) {
	if track_idx < 0 || track_idx >= len(timeline.tracks) {
		return
	}
	if index < 0 || index >= len(timeline.tracks[track_idx].clips) {
		return
	}
	selected_track = track_idx
	selected_index = index
	clear(&selected_set)
	selected_set[timeline.tracks[track_idx].clips[index].clip_id] = true
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
	anchor := f32(playhead.frame - i64(timeline_view_start)) * timeline_zoom
	anchor_frame := timeline_view_start + anchor / max(timeline_zoom, 0.0001)
	new_zoom := clamp(timeline_zoom * factor, TIMELINE_MIN_ZOOM, TIMELINE_MAX_ZOOM)
	if new_zoom != timeline_zoom {
		timeline_view_start = clamp(
			anchor_frame - anchor / max(new_zoom, 0.0001),
			0,
			f32(timeline_duration()),
		)
		timeline_zoom = new_zoom
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
	timeline_zoom = new_zoom
	timeline_view_start = 0
}

// add_text_clip_at inserts a Text generator clip on ctx_menu.target_track at
// the frame captured when the context menu was opened (right-click), one second
// long (shortened to fit its free gap). After insert the new clip becomes the
// timeline selection.
add_text_clip_at :: proc() {if ctx_menu.target_track < 0 ||
	   ctx_menu.target_track >= len(timeline.tracks) {
		return
	}
	idx := add_text_generator_clip(&timeline.tracks[ctx_menu.target_track], ctx_menu.frame)
	audio_note_edit()

	selected_track = ctx_menu.target_track
	selected_index = idx

	// A text clip is defined by its title, so creating one requires a name: open
	// the rename field in "create" mode. If the user commits an empty name (or
	// cancels) the just-inserted clip is removed (see apply_rename and the cancel
	// routing), so "Add > Text Clip" never leaves a nameless clip on the track.
	clip := &timeline.tracks[selected_track].clips[selected_index]
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
		show_ui_notice(
			fmt.aprintf("Could not load subtitles from '%s'", path_basename(path)),
			4000,
		)
		return
	}
	name := strings.clone(path_basename(path))
	idx := add_subtitle_generator_clip(
		&timeline.tracks[ctx_menu.target_track],
		ctx_menu.frame,
		srt_id,
		name,
	)
	audio_note_edit()

	selected_track = ctx_menu.target_track
	selected_index = idx

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
// options sets playback_rate and closes the menu; any other click dismisses the
// menu. Clicks elsewhere in the UI go through the normal input chain and simply
// close the open menu here.
handle_playback_rate_click :: proc(rate_clicked: bool) {
	if rate_clicked {
		playback_rate_open = !playback_rate_open
		return
	}
	if !playback_rate_open {
		return
	}
	if in_playback_rate_menu() {
		playback_rate = rate_from_element()
		playback_rate_open = false
	} else {
		playback_rate_open = false
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
	return playback_rate
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
	playback_stop_frame = project.end_frame
	playback_dir = 1
	playback_boost = 0
	playhead_accumulator = 0
	last_tick_ns = sdl.GetTicksNS()
	audio_was_playing = false
	playhead.playing = true
	preview.playing = true
	if vyper_trace {
		fmt.printf("[pb] area ph=%d stop=%d\n", playhead.frame, playback_stop_frame)
	}
}

// playback_publish records (frame, wall-time) for the audio producer under a
// seqlock: a reader that samples the pair while the UI is mid-publish retries
// instead of reading a torn frame/time mismatch.
playback_publish :: proc(frame: i64, now_ns: sdl.Uint64) {
	sync.atomic_add(&playback_seq, 1)
	sync.atomic_store(&ui_playhead_frame, frame)
	sync.atomic_store(&ui_playhead_ns, i64(now_ns))
	sync.atomic_add(&playback_seq, 1)
}

// playback_read_snapshot returns the last published (frame, wall-time) pair,
// retrying until a consistent one is observed.
playback_read_snapshot :: proc() -> (frame: i64, ns: i64) {
	for {
		s0 := sync.atomic_load(&playback_seq)
		if s0 & 1 != 0 {
			continue
		}
		frame = sync.atomic_load(&ui_playhead_frame)
		ns = sync.atomic_load(&ui_playhead_ns)
		if sync.atomic_load(&playback_seq) == s0 {
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
	if last_tick_ns == 0 {
		last_tick_ns = now_ns
	}
	if playhead.playing {
		// Playback is real-time: consume the true wall delta, never a clamped
		// one. A clamp silently drops the unapplied remainder, which strands the
		// playhead behind the wall clock permanently and desyncs it from the
		// audio producer (which extrapolates this same clock). A long stall
		// therefore jumps the playhead to where it should be, and audio_update's
		// forward-skip resyncs the producer if it had fallen behind.
		// DIAG (temporary): PLAYBACK_MAGIC_MS replaces the measured wall
		// delta so the cadence is perfectly jitter-free (or any fixed rate).
		dt_s :=
			PLAYBACK_MAGIC_MS > 0 ? PLAYBACK_MAGIC_MS / 1000.0 : f64(now_ns - last_tick_ns) / 1_000_000_000
		// The playhead advances +dir frames at effective_playback_rate against
		// the wall clock (rate * jog boost). Audio pacing at non-1x is the
		// producer's stream frequency ratio; audio is muted going backward.
		playhead_accumulator += dt_s * max(0.0, effective_playback_rate())
		playback_fps := timeline_fps()
		catchup := i64(0)
		for playhead_accumulator >= 1.0 / playback_fps {
			playhead.frame += i64(playback_dir)
			catchup += 1
			playhead_accumulator -= 1.0 / playback_fps
		}
		if catchup > 0 {
			sync.atomic_store(&audio_ph_src, 2)
			sync.atomic_store(&audio_ph_catch, catchup)
			if catchup > 1 {
				if vyper_trace {
					fmt.printf(
						"[pb] burst %+d ph=%d dt=%.1fms acc=%.3fs\n",
						i64(playback_dir) * catchup,
						playhead.frame,
						f64(now_ns - last_tick_ns) / 1e6,
						playhead_accumulator,
					)
				}
			}
		}
		// Directional boundary: stop at the run end going forward, at frame 0
		// going backward. Resetting the boost on auto-stop so a later play
		// starts from the selected rate.
		stop_frame := playback_stop_frame
		if stop_frame < 0 {
			stop_frame = timeline_duration()
		}
		at_end :=
			(playback_dir == 1 && playhead.frame >= stop_frame) ||
			(playback_dir == -1 && playhead.frame <= 0)
		if at_end {
			playback_stop_frame = -1
			playback_boost = 0
			playhead.frame = clamp(playhead.frame, 0, max(0, stop_frame - 1))
			playhead.playing = false
			preview.playing = false
			if vyper_trace {
				fmt.printf(
					"[pb] auto-stop dir=%d ph=%d stop=%d\n",
					playback_dir,
					playhead.frame,
					stop_frame,
				)
			}
		}
		// Playback is real-time: the playhead (and with it the audio) runs on
		// the wall clock. Video decode is best-effort on top of that clock.
	}
	last_tick_ns = now_ns
}

// ---------------------------------------------------------------------------

main :: proc() {
	when ODIN_OS == .Windows {
		crash_handler_install()
		win_ffmpeg_versions_diag()
	}
	vyper_trace = os.get_env_alloc("VYPER_TRACE", context.temp_allocator) == "1"
	// DIAG: headless playback-rate override (the GUI dropdown is mouse-only);
	// the audio producer reads playback_rate for its atempo graph and cushion.
	if v := os.get_env_alloc("VYPER_RATE", context.temp_allocator); v != "" {
		playback_rate, _ = strconv.parse_f64(v)
		if vyper_trace {
			fmt.printf("[main] VYPER_RATE -> playback_rate=%.2f\n", playback_rate)
		}
	}
	// libav's INFO chatter (libx264 "using cpu capabilities", decoder open
	// lines) used to go to a silenced ffmpeg subprocess (-loglevel error); it
	// is in-process now, so quiet the library globally to match.
	avutil.log_set_level(.Error)
	if os.get_env_alloc("VYPER_HW_DISABLE", context.temp_allocator) == "1" {
		hw_decode_enabled = false
	}
	if test_path_ok, test_paths := render_test_env(); test_path_ok {
		render_test_run(test_paths)
		return
	}
	if hw_probe, _ := os.lookup_env_alloc("VYPER_HW_PROBE", context.temp_allocator); hw_probe != "" {
		preview_hw_probe_run(hw_probe)
		return
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
	// Headless UI draw-call probe: runs build_page's clay layout for N frames
	// on a synthetic session and tallies per-frame draw calls (per Rectangle/
	// Border command + per glyph) without a display or GPU.
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
	// Enable SDL text input so TEXT_INPUT events (typing) reach the app for the
	// property/number fields and the generic rename text field.
	_ = sdl.StartTextInput(window)

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
	defer if warm_valid {
		clip_decoder_reset(&warm_decoder)
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
		PLAYBACK_MAGIC_MS, _ = strconv.parse_f64(v)
	}
	if v := os.get_env_alloc("VYPER_PLAYBACK_FPS", context.temp_allocator); v != "" {
		PLAYBACK_MAGIC_FPS, _ = strconv.parse_f64(v)
	}
	if PLAYBACK_MAGIC_MS > 0 || PLAYBACK_MAGIC_FPS > 0 {
		if vyper_trace {
			fmt.printf(
				"[pb] DIAG magic clock: magic_ms=%.3f fps_override=%.3f\n",
				PLAYBACK_MAGIC_MS,
				PLAYBACK_MAGIC_FPS,
			)
		}
	}

	// DIAG: env-var autoplay for headless-ish diagnostics — autoloads a file and
	// starts playback after a couple of seconds. Refuses silently-failed imports
	// (bad path, unreadable file, probe failure) instead of opening an empty
	// project that immediately auto-stops without ever playing anything.
	if autoplay := os.get_env_alloc("VYPER_AUTOPLAY", context.temp_allocator); autoplay != "" {
		if vyper_trace {
			fmt.printf("[autoplay] env=\"%s\" step=import\n", autoplay)
		}
		// The asset/clip paths store the passed cstring by reference, so the
		// autoplay path must be owned on the long-lived allocator (assets never
		// free their paths), not the per-frame temp arena.
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
		sdl.Delay(2500)
		if vyper_trace {
			fmt.printf("[autoplay] env=\"%s\" step=play\n", autoplay)
		}
		playhead.playing = true
		preview.playing = true
		playhead_accumulator = 0
		last_tick_ns = sdl.GetTicksNS()
		if sec := os.get_env_alloc("VYPER_PLAY_SEC", context.temp_allocator); sec != "" {
			if v, ok := strconv.parse_f64(sec); ok && v > 0 {
				playback_stop_frame = i64(v * timeline_fps())
				if vyper_trace {
					fmt.printf("[autoplay] VYPER_PLAY_SEC=%.0f -> stop=%d\n", v, playback_stop_frame)
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

		now_ns := sdl.GetTicksNS()
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
					playhead_accumulator,
					sync.atomic_load(&audio_ph_src),
					sync.atomic_load(&audio_ph_catch),
					sync.atomic_load(&audio_prod_frame),
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
