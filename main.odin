package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import clay "clay-odin"
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
		if nered_trace {
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
	preview_frontier = playhead.frame
	audio_was_playing = false
	playhead.playing = true
	preview.playing = true
	if nered_trace {
		fmt.printf("[pb] toggle playing=%v ph=%d dir=%d\n", playhead.playing, playhead.frame, playback_dir)
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
		preview_frontier = playhead.frame
		audio_was_playing = false
		playhead.playing = true
		preview.playing = true
		if nered_trace {
			fmt.printf("[pb] jog start dir=%d ph=%d\n", dir, playhead.frame)
		}
		return
	}
	// Already playing.
	if playback_dir == dir {
		playback_boost += 1
		if nered_trace {
			fmt.printf("[pb] jog boost dir=%d boost=%d eff=%.2fx\n", dir, playback_boost, effective_playback_rate())
		}
	} else {
		playback_dir = dir
		playback_boost = 0
		if nered_trace {
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
	if resizing_clip {
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
	thumb_id := clay.ID(fmt.aprintf("%sSbThumb", tag))
	strip_id := clay.ID(fmt.aprintf("%sScrollbar", tag))
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
scroll_drag_update :: proc(tag: string, down: bool, my: f32, drag: ^bool, grab: ^f32, scroll: ^f32, content_h, view_h: f32) {
	if !drag^ {
		return
	}
	if !down {
		drag^ = false
		return
	}
	strip := clay.GetElementData(clay.ID(fmt.aprintf("%sScrollbar", tag))).boundingBox
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
		if clip.name != "" {
			delete(clip.name)
		}
		clip.name = strings.clone(name)
	}
}

// handle_ctx_option dispatches a click on a context-menu entry. Selecting
// Add > Text Clip creates a Text generator clip on the right-clicked track at
// the pointer's frame; the clip-action rows (Rename/Duplicate/Delete/Link)
// act on the clip that was right-clicked (ctx_menu.target_clip_*), which is
// selected first so every later action sees the same selection.
handle_ctx_option :: proc() {
	ct := ctx_menu.target_clip_track
	ci := ctx_menu.target_clip_index
	if clay.PointerOver(clay.ID("CtxTextClip")) {
		add_text_clip_at()
	} else if clay.PointerOver(clay.ID("CtxSubtitleClip")) {
		add_subtitle_clip_at()
	} else if ct >= 0 && ct < len(timeline.tracks) && ci >= 0 && ci < len(timeline.tracks[ct].clips) {
		select_clip(ct, ci)
		if clay.PointerOver(clay.ID("CtxRename")) {
			begin_clip_rename()
		} else if clay.PointerOver(clay.ID("CtxDuplicate")) {
			new_i := duplicate_clip(ct, ci)
			// Select the fresh copy so the user immediately sees what appeared.
			select_clip(ct, new_i)
		} else if clay.PointerOver(clay.ID("CtxDelete")) {
			delete_clip_at(ct, ci)
		} else if clay.PointerOver(clay.ID("CtxLink")) {
			toggle_links_for_selection()
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
		timeline_view_start = clamp(anchor_frame - anchor / max(new_zoom, 0.0001), 0, f32(timeline_duration()))
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
	new_zoom := clamp(ruler.width / f32(max(timeline_duration(), 1)), TIMELINE_MIN_ZOOM, TIMELINE_MAX_ZOOM)
	timeline_zoom = new_zoom
	timeline_view_start = 0
}

// add_text_clip_at inserts a Text generator clip on ctx_menu.target_track at
// the frame captured when the context menu was opened (right-click), one second
// long (shortened to fit its free gap). After insert the new clip becomes the
// timeline selection.
add_text_clip_at :: proc() {	if ctx_menu.target_track < 0 || ctx_menu.target_track >= len(timeline.tracks) {
		return
	}
	sync.mutex_lock(&audio_timeline_mtx)
	idx := add_text_generator_clip(&timeline.tracks[ctx_menu.target_track], ctx_menu.frame)
	sync.mutex_unlock(&audio_timeline_mtx)
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
		show_ui_notice(fmt.aprintf("Could not load subtitles from '%s'", path_basename(path)), 4000)
		return
	}
	name := strings.clone(path_basename(path))
	sync.mutex_lock(&audio_timeline_mtx)
	idx := add_subtitle_generator_clip(&timeline.tracks[ctx_menu.target_track], ctx_menu.frame, srt_id, name)
	sync.mutex_unlock(&audio_timeline_mtx)
	audio_note_edit()

	selected_track = ctx_menu.target_track
	selected_index = idx
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

// add_subtitle_clip_from_path loads the .srt at `path` and places a Subtitle
// generator clip on track 0 at `at_frame`, selecting it. Returns true when a
// clip was created; a message and no clip on parse failure.
add_subtitle_clip_from_path :: proc(path: cstring, at_frame: i64) -> bool {
	if len(timeline.tracks) == 0 {
		return false
	}
	srt_id := srt_load(path)
	if srt_id < 0 {
		show_ui_notice(fmt.aprintf("Could not load subtitles from '%s'", path_basename(path)), 4000)
		return false
	}
	name := strings.clone(path_basename(path))
	sync.mutex_lock(&audio_timeline_mtx)
	track := 0
	idx := add_subtitle_generator_clip(&timeline.tracks[track], at_frame, srt_id, name)
	sync.mutex_unlock(&audio_timeline_mtx)
	audio_note_edit()
	selected_track = track
	selected_index = idx
	return true
}

// pointer_over_context_menu reports whether the cursor is over the context menu
// proper or its "Add >" submenu (both are part of the same transient UI).
pointer_over_context_menu :: proc() -> bool {
	if clay.PointerOver(clay.ID("CtxMenu")) {
		return true
	}
	return pointer_over_submenu()
}

// pointer_over_submenu reports whether the cursor is over any submenu item.
pointer_over_submenu :: proc() -> bool {
	return clay.PointerOver(clay.ID("CtxTextClip")) || clay.PointerOver(clay.ID("CtxSubtitleClip"))
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
		if clay.PointerOver(clay.ID(playback_rate_name(rate))) {
			return true
		}
	}
	return false
}

// rate_from_element returns the playback rate whose dropdown option is under
// the pointer (the selection just made). Only valid inside an open menu.
rate_from_element :: proc() -> f64 {
	for rate in PLAYBACK_RATES {
		if clay.PointerOver(clay.ID(playback_rate_name(rate))) {
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
	preview_frontier = playhead.frame
	audio_was_playing = false
	playhead.playing = true
	preview.playing = true
	if nered_trace {
		fmt.printf("[pb] area ph=%d stop=%d\n", playhead.frame, playback_stop_frame)
	}
}
// ---------------------------------------------------------------------------

main :: proc() {
	when ODIN_OS == .Windows {
		crash_handler_install()
	}
	nered_trace = os.get_env_alloc("NERED_TRACE", context.temp_allocator) == "1"
	if test_path_ok, test_paths := render_test_env(); test_path_ok {
		render_test_run(test_paths)
		return
	}
	if fp, _ := os.lookup_env_alloc("NERED_FRAME_PROBE", context.temp_allocator); fp != "" {
		preview_framecheck_run(fp)
		return
	}
	if probe_path_ok, probe_paths := preview_probe_env(); probe_path_ok {
		// These probes step the playhead through update_preview_slots, which
		// routes the foreground clip through the async worker. Start it in
		// probe mode (deterministic: every step waits for the decode) and tear
		// it down before asserting.
		async_live_mode = false
		async_dec_init()
		defer async_dec_shutdown()
		preview_probe_run(probe_paths)
		return
	}
	if bp, _ := os.lookup_env_alloc("NERED_BOUNDARY_PROBE", context.temp_allocator); bp != "" {
		async_live_mode = false
		async_dec_init()
		defer async_dec_shutdown()
		boundary_probe_run(bp)
		return
	}
	if cp, _ := os.lookup_env_alloc("NERED_CACHE_PROBE", context.temp_allocator); cp != "" {
		cache_probe_run(cp)
		return
	}
	if tp, _ := os.lookup_env_alloc("NERED_TRANSFORM_PROBE", context.temp_allocator); tp != "" {
		transform_probe_run(tp)
		return
	}
	if xp, _ := os.lookup_env_alloc("NERED_PROXY_PROBE", context.temp_allocator); xp != "" {
		proxy_probe_run(xp)
		return
	}
	if xb, _ := os.lookup_env_alloc("NERED_PROXY_BG_TEST", context.temp_allocator); xb != "" {
		proxy_bg_probe_run(xb)
		return
	}
	if !load_font_data() {
		return
	}
	if !sdl.Init(sdl.INIT_VIDEO | sdl.INIT_AUDIO) {
		fmt.println("SDL initialization failed")
		return
	}
	defer sdl.Quit()

	window := sdl.CreateWindow("nered", WINDOW_WIDTH, WINDOW_HEIGHT, {.RESIZABLE, .VULKAN})
	if window == nil {
		fmt.println("Could not create nered window")
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
	defer sdl.ReleaseGPUGraphicsPipeline(device, renderer.pipeline)
	defer sdl.ReleaseGPUGraphicsPipeline(device, renderer.text_pipeline)
	defer sdl.ReleaseGPUGraphicsPipeline(device, renderer.preview_pipeline)
	defer sdl.ReleaseGPUTexture(device, renderer.font.texture)
	defer sdl.ReleaseGPUSampler(device, renderer.font.sampler)
	defer release_preview_textures(device, renderer.preview_textures[:])
	defer release_slot_owned_textures(device)
	defer sdl.ReleaseGPUSampler(device, renderer.preview_sampler)
	defer for id in Icon_Id {
		if renderer.icon_textures[id] != nil {
			sdl.ReleaseGPUTexture(device, renderer.icon_textures[id])
		}
	}
	// Media-bin thumbnails own per-asset GPU textures; free them at shutdown.
	defer release_media_asset_textures(device)
	initial_upload := sdl.AcquireGPUCommandBuffer(device)
	if initial_upload == nil || !upload_font_atlas(&renderer, initial_upload) || !upload_icons(&renderer, initial_upload) || !sdl.SubmitGPUCommandBuffer(initial_upload) {
		fmt.println("Could not upload font atlas:", sdl.GetError())
		return
	}

	audio_init()
	defer audio_shutdown()
	async_dec_init()
	defer async_dec_shutdown()
	import_bg_init()
	defer import_bg_shutdown()
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
	if v := os.get_env_alloc("NERED_PLAYBACK_MAGIC_MS", context.temp_allocator); v != "" {
		PLAYBACK_MAGIC_MS, _ = strconv.parse_f64(v)
	}
	if v := os.get_env_alloc("NERED_PLAYBACK_FPS", context.temp_allocator); v != "" {
		PLAYBACK_MAGIC_FPS, _ = strconv.parse_f64(v)
	}
	if PLAYBACK_MAGIC_MS > 0 || PLAYBACK_MAGIC_FPS > 0 {
		if nered_trace {
			fmt.printf("[pb] DIAG magic clock: magic_ms=%.3f fps_override=%.3f\n", PLAYBACK_MAGIC_MS, PLAYBACK_MAGIC_FPS)
		}
	}

	// DIAG: env-var autoplay for headless-ish diagnostics — autoloads a file and
	// starts playback after a couple of seconds. Refuses silently-failed imports
	// (bad path, unreadable file, probe failure) instead of opening an empty
	// project that immediately auto-stops without ever playing anything.
	if autoplay := os.get_env_alloc("NERED_AUTOPLAY", context.temp_allocator); autoplay != "" {
		if nered_trace {
			fmt.printf("[autoplay] env=\"%s\" step=import\n", autoplay)
		}
		import_media(strings.clone_to_cstring(autoplay, context.temp_allocator))
		if nered_trace {
			fmt.printf("[autoplay] env=\"%s\" imported tracks=%d step=delay\n", autoplay, len(timeline.tracks))
		}
		if len(timeline.tracks) == 0 {
			if nered_trace {
				fmt.printf("[autoplay] FATAL: NERED_AUTOPLAY=\"%s\" imported nothing (no audio track)\n", autoplay)
			}
			os.exit(1)
		}
		sdl.Delay(2500)
		if nered_trace {
			fmt.printf("[autoplay] env=\"%s\" step=play\n", autoplay)
		}
		playhead.playing = true
		preview.playing = true
		playhead_accumulator = 0
		preview_frontier = playhead.frame
		last_tick_ns = sdl.GetTicksNS()
		audio_note_edit()
	}

	running := true
	was_mouse_down := false
	was_right_down := false
	ui_report_tick := u64(0)
	ui_frame_count := 0
	ui_dec_us := i64(0)
	for running {
		clear_expired_ui_notice()
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				running = false
			case .KEY_DOWN:
				if ti.active {
					mods := sdl.GetModState()
					shift := sdl.KeymodFlag.LSHIFT in mods || sdl.KeymodFlag.RSHIFT in mods
					ctrl := sdl.KeymodFlag.LCTRL in mods || sdl.KeymodFlag.RCTRL in mods
					r := text_input_handle_key(event.key.key, shift, ctrl)
					if r == .Commit {
						apply_rename()
					} else if r == .Cancel {
						if ti.is_create {
							// Aborted a clip-create dialog: drop the clip that was
							// temporarily inserted so no nameless clip remains.
							delete_selected_clip_raw()
							ti.is_create = false
						}
					}
				} else if editing_field != 0 {
					switch event.key.key {
					case sdl.K_BACKSPACE:
						edit_backspace()
					case sdl.K_RETURN, sdl.K_RETURN2:
						edit_commit()
					case sdl.K_ESCAPE:
						edit_cancel()
					}
				} else if event.key.key == sdl.K_ESCAPE && !event.key.repeat {
					escape_dismiss()
				} else if !event.key.repeat {
					switch event.key.key {
					case sdl.K_F1:
						// Always-available shortcut reference.
						help_open = !help_open
					case sdl.K_SPACE:
						mods := sdl.GetModState()
						if sdl.KeymodFlag.LCTRL in mods || sdl.KeymodFlag.RCTRL in mods {
							play_project_area()
						} else {
							toggle_playback()
						}
					case sdl.K_H:
						// Jog backward (mirrors the backward button).
						jog_playback(-1)
					case sdl.K_L:
						// Jog forward (mirrors the forward button).
						jog_playback(1)
					case sdl.K_S:
						split_clip_at_playhead()
					case sdl.K_R:
						// Ctrl+R renames the selected clip.
						mods := sdl.GetModState()
						if sdl.KeymodFlag.LCTRL in mods || sdl.KeymodFlag.RCTRL in mods {
							begin_clip_rename()
						}
					case sdl.K_U:
						// Toggle link state across the selection: a lone clip
						// unlinks its group; several Shift+clicked clips join into
						// one link group (or all split apart when already linked).
						toggle_links_for_selection()
					case sdl.K_BACKSPACE:
						// Delete the selected clip's timeline area and close the
						// gap (ripple). A linked clip rips the WHOLE group: every
						// member's own span on its own track, so a ripple cut
						// never leaves the partner clip behind (rippling only the
						// selected member's region would strand the rest).
						if tr, clip, ok := selected_clip(); ok {
							if clip.link_id != 0 {
								ripple_delete_linked_group(clip.link_id)
							} else {
								ripple_delete_region(clip.timeline_start_frame, clip.source_length_frames)
							}
						}
					case sdl.K_DELETE:
						// Delete the clip raw, nothing else.
						delete_selected_clip_raw()
					case sdl.K_I:
						// Set the render-range start at the playhead; collapsing the
						// range to a single frame clears it.
						project.start_frame = playhead.frame
						if project.end_frame == playhead.frame {
							project.start_frame = -1
							project.end_frame = -1
						}
					case sdl.K_O:
						project.end_frame = playhead.frame
						if project.start_frame == playhead.frame {
							project.start_frame = -1
							project.end_frame = -1
						}
					}
				}
			case .TEXT_INPUT:
				if ti.active {
					text_input_insert(string(event.text.text))
				} else if editing_field != 0 {
					for ch in string(event.text.text) {
						// Only accept printable ASCII that makes sense in a number.
						if ch >= '0' && ch <= '9' || ch == '-' || ch == '.' {
							edit_append(u8(ch))
						}
					}
				}
			case .MOUSE_WHEEL:
				// Scroll over the inspector column scrolls its card stack when
				// the cards outgrow the viewport.
				ic := clay.GetElementData(clay.ID("InspectorColumn")).boundingBox
				if ic.height > 0 && event.wheel.mouse_x >= ic.x && event.wheel.mouse_x <= ic.x + ic.width &&
					event.wheel.mouse_y >= ic.y && event.wheel.mouse_y <= ic.y + ic.height {
					if event.wheel.y != 0 {
						inspector_scroll = clamp(inspector_scroll - f32(event.wheel.y) * TIMELINE_SCROLL_STEP, 0, inspector_max_scroll())
						break
					}
				}
				// Scroll over the media bin scrolls its thumbnail grid (manual
				// clip scroll, like the tracks section).
				mb := clay.GetElementData(clay.ID("MediaBin")).boundingBox
				if mb.width > 0 && event.wheel.mouse_x >= mb.x && event.wheel.mouse_x <= mb.x + mb.width &&
					event.wheel.mouse_y >= mb.y && event.wheel.mouse_y <= mb.y + mb.height {
					if len(media_assets) > 0 && event.wheel.y != 0 {
						media_bin_scroll = clamp(media_bin_scroll - f32(event.wheel.y) * MEDIA_BIN_SCROLL_STEP, 0, media_bin_max_scroll())
						break
					}
				}
				// Vertical wheel over the track LANES (and the scrollbar strip
				// beside them) scrolls the track list, exactly like the media
				// bin. The ruler strip above still zooms on wheel.
				ta := clay.GetElementData(clay.ID("TrackArea")).boundingBox
				if ta.height > 0 && event.wheel.mouse_x >= ta.x && event.wheel.mouse_x <= ta.x + ta.width &&
					event.wheel.mouse_y >= ta.y && event.wheel.mouse_y <= ta.y + ta.height {
					if event.wheel.y != 0 {
						timeline_view_top = clamp(timeline_view_top - f32(event.wheel.y) * TIMELINE_SCROLL_STEP, 0, timeline_tracks_max_top())
						break
					}
				}
				// Scroll over the timeline zooms horizontally, anchored at the playhead.
				tlb := clay.GetElementData(clay.ID("ClipTimeline")).boundingBox
				if len(timeline.tracks) > 0 && event.wheel.mouse_x >= tlb.x && event.wheel.mouse_x <= tlb.x + tlb.width &&
					event.wheel.mouse_y >= tlb.y && event.wheel.mouse_y <= tlb.y + tlb.height {
					if event.wheel.y != 0 {
						ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
						anchor := f32(playhead.frame - i64(timeline_view_start)) * timeline_zoom
						anchor_frame := timeline_view_start + anchor / timeline_zoom
						new_zoom := clamp(timeline_zoom * (1 + 0.1 * event.wheel.y), TIMELINE_MIN_ZOOM, TIMELINE_MAX_ZOOM)
						if new_zoom != timeline_zoom {
							timeline_view_start = anchor_frame - anchor / new_zoom
							timeline_view_start = clamp(timeline_view_start, 0, f32(timeline_duration()))
							timeline_zoom = new_zoom
						}
					}
					break
				}
				// Scroll over the preview zooms the camera, keeping the point under
				// the cursor fixed.
				pb := clay.GetElementData(clay.ID("Preview")).boundingBox
				if event.wheel.mouse_x >= pb.x && event.wheel.mouse_x <= pb.x + pb.width &&
					event.wheel.mouse_y >= pb.y && event.wheel.mouse_y <= pb.y + pb.height {
					if event.wheel.y != 0 {
						canvas := preview_canvas(pb)
						mx_c := event.wheel.mouse_x - (canvas.x + canvas.width / 2)
						my_c := event.wheel.mouse_y - (canvas.y + canvas.height / 2)
						old_zoom := preview_cam_zoom
						new_zoom := clamp(old_zoom * (1 + 0.1 * event.wheel.y), PREVIEW_CAM_MIN_ZOOM, PREVIEW_CAM_MAX_ZOOM)
						if new_zoom != old_zoom {
							preview_cam_ox = mx_c - (mx_c - preview_cam_ox) * (new_zoom / old_zoom)
							preview_cam_oy = my_c - (my_c - preview_cam_oy) * (new_zoom / old_zoom)
							preview_cam_zoom = new_zoom
						}
					}
				}
			}
		}

		// A close/quit event sets running=false inside the poll loop above. If we
		// fall through into the render+present, the blocking GPU swapchain acquire
		// (WaitAndAcquireGPUSwapchainTexture) never returns once the window is
		// going away, so the loop would never re-check running and the process
		// would hang instead of exiting. Break now so the deferred shutdown runs.
		if !running {
			break
		}

		width, height: c.int
		sdl.GetWindowSize(window, &width, &height)
		mouse_x, mouse_y: f32
		mouse_buttons := sdl.GetMouseState(&mouse_x, &mouse_y)
		mouse_down := sdl.MouseButtonFlag.LEFT in mouse_buttons
		right_down := sdl.MouseButtonFlag.RIGHT in mouse_buttons
		middle_down := sdl.MouseButtonFlag.MIDDLE in mouse_buttons
		mods := sdl.GetModState()
		alt_down := sdl.KeymodFlag.LALT in mods || sdl.KeymodFlag.RALT in mods
		shift_down := sdl.KeymodFlag.LSHIFT in mods || sdl.KeymodFlag.RSHIFT in mods

		// Middle-button drag over the preview pans the camera (limited to ±one
		// preview axis from the origin via clamp_preview_camera at render time).
		if middle_down && clay.PointerOver(clay.ID("Preview")) {
			if panning_preview {
				preview_cam_ox += mouse_x - pan_last_x
				preview_cam_oy += mouse_y - pan_last_y
			}
			panning_preview = true
			pan_last_x = mouse_x
			pan_last_y = mouse_y
		} else if panning_preview {
			panning_preview = false
		}
		// Middle-drag over the timeline pans it: horizontally along the frames,
		// vertically across the track rows (when they overflow the view). The
		// hit test is a raw box check on the panel's bounding box rather than
		// clay's PointerOver so panning never depends on the pointer-over flag
		// machinery.
		tltl := clay.GetElementData(clay.ID("ClipTimeline")).boundingBox
		if middle_down && len(timeline.tracks) > 0 && tltl.width > 0 &&
			mouse_x >= tltl.x && mouse_x <= tltl.x + tltl.width &&
			mouse_y >= tltl.y && mouse_y <= tltl.y + tltl.height {
			if panning_timeline {
				timeline_view_start -= (mouse_x - timeline_pan_last_x) / timeline_zoom
				timeline_view_start = clamp(timeline_view_start, 0, f32(timeline_duration()))
				// Inverted vertical drag (grab-the-content convention): dragging
				// down moves content down ("scroll down" pushes tracks up, the
				// "hand tool" feel), so the view offset moves opposite the pointer.
				timeline_view_top -= mouse_y - timeline_pan_last_y
				// Clamp to the row area that overflows the visible tracks box.
				timeline_view_top = clamp(timeline_view_top, 0, timeline_tracks_max_top())
			}
			panning_timeline = true
			timeline_pan_last_x = mouse_x
			timeline_pan_last_y = mouse_y
		} else if panning_timeline {
			panning_timeline = false
		}
		// Vertical scrollbar drags: the thumb position maps directly onto the
		// container's scroll value, using the same geometry that draws the
		// thumb. Active for both scrollable columns (timeline lanes, inspector
		// cards); each ends the moment the button lifts.
		scroll_drag_update("TimelineV", mouse_down, mouse_y, &timeline_scroll_dragging, &timeline_scroll_grab, &timeline_view_top, timeline_tracks_content_height(), timeline_tracks_content_height() - timeline_tracks_max_top())
		scroll_drag_update("InspectorV", mouse_down, mouse_y, &inspector_scroll_dragging, &inspector_scroll_grab, &inspector_scroll, inspector_content_height(), inspector_view_height())
		clay.SetPointerState({mouse_x, mouse_y}, mouse_down)

		commands := build_page(width, height)
		if len(timeline.tracks) > 0 {
			timeline_view_top = clamp(timeline_view_top, 0, timeline_tracks_max_top())
		}
		inspector_scroll = clamp(inspector_scroll, 0, inspector_max_scroll())
		if mouse_down && !was_mouse_down && import_bg_active() && box_contains(import_cancel_box, mouse_x, mouse_y) {
			import_bg_cancel()
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("BinImportButton")) {
			if path := open_file_picker(); path != nil {
				if is_srt_pick(path) {
					add_subtitle_clip_from_path(path, timeline_duration())
				} else {
					import_media_to_bin(path)
				}
			}
		} else if mouse_down && !was_mouse_down && len(media_assets) > 0 && media_bin_item_at(mouse_x, mouse_y) >= 0 {
			// Pressing a bin cell selects the media and starts the drag-to-timeline
			// gesture (ghost while down, committed on release over a lane).
			begin_media_drag(media_bin_item_at(mouse_x, mouse_y), mouse_x, mouse_y)
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("OpenFileButton")) {
			if path := open_file_picker(); path != nil {
				if is_srt_pick(path) {
					// Subtitle pick: straight to a generator clip (can't probe a
					// text file as media).
					add_subtitle_clip_from_path(path, timeline_duration())
				} else {
					// Classic Open File flow: probe the file and drop it straight
					// onto the timeline (appended at the end), keeping its bin
					// entry. A bin-only import forced an extra pick-and-drag step
					// the old direct-load behavior didn't have.
					if asset_id := import_media_to_bin(path); asset_id != 0 {
						add_asset_to_timeline(asset_id, 0, timeline_duration())
					}
				}
			}
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("Res720")) {
			set_project_resolution(1280, 720)
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("Res1080")) {
			set_project_resolution(1920, 1080)
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("Res4K")) {
			set_project_resolution(3840, 2160)
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("ResAuto")) {
			set_project_resolution_auto()
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("OrientVertical")) {
			set_project_orientation(!(project.height > project.width))
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("SnapCenter")) {
			snap_center_to_canvas = !snap_center_to_canvas
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("Fps24")) {
			set_project_fps(24)
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("Fps25")) {
			set_project_fps(25)
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("Fps30")) {
			set_project_fps(30)
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("Fps48")) {
			set_project_fps(48)
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("Fps60")) {
			set_project_fps(60)
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("FpsAuto")) {
			set_project_fps(0)
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("PropRename")) {
			begin_clip_rename()
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("TimelineZoomIn")) {
			timeline_zoom_about_playhead(1.5)
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("TimelineZoomOut")) {
			timeline_zoom_about_playhead(1 / 1.5)
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("TimelineZoomFit")) {
			timeline_zoom_fit()
		} else if clay.PointerOver(clay.ID("DividerHandle")) && mouse_down {
			resizing_areas = true
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("RenderPickButton")) {
			render_pick_output_path()
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("RenderRunButton")) {
			render_start()
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("RenderCancelButton")) {
			render_cancel()
		} else if mouse_down && !was_mouse_down && len(timeline.tracks) > 0 && clay.PointerOver(clay.ID("Ruler")) {
			// Clicking the timeline ruler starts a scrub (drag to seek).
			dragging_playhead = true
		} else if mouse_down && !was_mouse_down {
			// A click handled here either inserts a track via a "+" gap or
			// duplicates an existing track via its name-button, or starts dragging
			// the selected clip within the preview, so no clip drag begins.
			handled := false
			// If a property field is being typed in and the user clicks away from
			// it, commit the pending value first.
			if editing_field != 0 {
				if !edit_field_over() {
					edit_commit()
				}
			}
			// Scrollbars: pressing the thumb starts a drag; pressing anywhere
			// else on the strip jumps the thumb to the cursor. One stack per
			// scrollable column (timeline lanes, inspector cards).
			if !handled {
				if scroll_press("TimelineV", mouse_y, &timeline_scroll_dragging, &timeline_scroll_grab) {
					handled = true
				} else if scroll_press("InspectorV", mouse_y, &inspector_scroll_dragging, &inspector_scroll_grab) {
					handled = true
				}
			}
			// Clicking an X/Y/Scale/crop property field focuses it for typing.
			if sel, ok := transformable_selected(); ok {
				if clay.PointerOver(clay.ID("PropFieldX")) {
					edit_begin(1, sel.transform_x)
					handled = true
				} else if clay.PointerOver(clay.ID("PropFieldY")) {
					edit_begin(2, sel.transform_y)
					handled = true
				} else if clay.PointerOver(clay.ID("PropFieldS")) {
					edit_begin(3, sel.scale)
					handled = true
				} else if clay.PointerOver(clay.ID("PropCropL")) {
					edit_begin(4, sel.crop_l * 100)
					handled = true
				} else if clay.PointerOver(clay.ID("PropCropR")) {
					edit_begin(5, sel.crop_r * 100)
					handled = true
				} else if clay.PointerOver(clay.ID("PropCropT")) {
					edit_begin(6, sel.crop_t * 100)
					handled = true
				} else if clay.PointerOver(clay.ID("PropCropB")) {
					edit_begin(7, sel.crop_b * 100)
					handled = true
				}
			}
			// Grab one of the selected clip's resize/crop handles. Takes
			// precedence over moving the clip. Default drag scales; holding Alt
			// crops.
			if !handled && clay.PointerOver(clay.ID("Preview")) {
				if sel, ok := transformable_selected(); ok {
					pb := clay.GetElementData(clay.ID("Preview")).boundingBox
					canvas := preview_canvas(pb)
					ib := clip_image_bounds(canvas, sel)
					if h := preview_handle_at(ib, mouse_x, mouse_y); h >= 0 {
						begin_handle_drag(sel, canvas, h, mouse_x, mouse_y, alt_down && sel.kind != .Text)
						handled = true
					}
				}
			}
			// Dragging the selected clip inside the preview moves its transform.
			if !handled {
				if sel, ok := transformable_selected(); ok && clay.PointerOver(clay.ID("Preview")) {
					pb := clay.GetElementData(clay.ID("Preview")).boundingBox
					canvas := preview_canvas(pb)
					ib := clip_image_bounds(canvas, sel)
					if mouse_x >= ib.x && mouse_x <= ib.x + ib.width && mouse_y >= ib.y && mouse_y <= ib.y + ib.height {
						// Offset between the click and the clip's center, in project coords.
						// Unclamped so a grab near an off-canvas clip still offsets correctly.
						pcx, pcy := pixel_to_project_unclamped(canvas, mouse_x, mouse_y)
						preview_drag_offset_x = pcx - sel.transform_x
						preview_drag_offset_y = pcy - sel.transform_y
						moving_preview_clip = true
					handled = true
				}
			}
			}
			if !handled {
				if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("SnapClipToPh")) {
					snap_clips_to_playhead = !snap_clips_to_playhead
					handled = true
				} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("SnapPhToClip")) {
					snap_playhead_to_clips = !snap_playhead_to_clips
					handled = true
				}
			}
			if !handled {
			for i := 0; i <= len(timeline.tracks); i += 1 {
				if clay.PointerOver(clay.ID("TrackGap", u32(i))) {
					insert_track(i)
					handled = true
					break
				}
			}
			}
			if !handled {
				for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
					if clay.PointerOver(clay.ID("DuplicateTrack", u32(track_idx))) {
						duplicate_track(track_idx)
						handled = true
						break
					}
				}
			}
			if !handled {
				for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
					if clay.PointerOver(clay.ID("RemoveTrack", u32(track_idx))) {
						remove_track(track_idx)
						handled = true
						break
					}
				}
			}
			if !handled {
				// Resizing the selected clip's duration: grab its left/right edge.
				// Takes precedence over selecting/dragging a clip, and only the
				// currently-selected clip can be resized.
				if sel_tr, sel_cl, ok := selected_clip(); ok {
					for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
						track := &timeline.tracks[track_idx]
						for index := 0; index < len(track.clips); index += 1 {
							if &track.clips[index] != sel_cl {
								continue
							}
							if edge := timeline_resize_edge_at(track_idx, index, mouse_x, mouse_y); edge >= 0 {
									selected_track = track_idx
									selected_index = index
									resizing_clip = true
									resize_edge = edge
									capture_link_group(&track.clips[index], track_idx)
									handled = true
									break
								}
						}
						if resizing_clip {
							break
						}
					}
				}
			}
			if !handled {
			// Find which (if any) clip the pointer is over and start dragging it.
			for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
				track := &timeline.tracks[track_idx]
				for index := 0; index < len(track.clips); index += 1 {
					if clay.PointerOver(clay.ID("TimelineClip", u32(track_idx * 1000 + index))) {
						selected_track = track_idx
						selected_index = index
						if shift_down {
							// Shift+click toggles the clip into/out of the
							// multi-selection (for U linking) without dragging.
							cid := track.clips[index].clip_id
							if cid in selected_set {
								delete_key(&selected_set, cid)
							} else {
								selected_set[cid] = true
							}
							handled = true
							break
						}
						// Plain click = single selection: drop any earlier
						// Shift+clicked extras and grab the clip.
						clear(&selected_set)
						drag_group_delta = 0
						drag_clip = &track.clips[index]
						drag_source_track = track_idx
						drag_source_index = index
						drag_hover_track = track_idx
						moving_clip = true
						clip_drag_offset = mouse_x - clay.GetElementData(clay.ID("TimelineClip", u32(track_idx * 1000 + index))).boundingBox.x
						capture_link_group(drag_clip, track_idx)
						break
					}
				}
				if moving_clip || handled {
					break
				}
			}
			}
		}
		if !mouse_down {
			if dragging_media_from_bin {
				// Releasing a bin drag commits the media (creates tracks as
				// needed); releasing nowhere cancels it.
				end_media_drag(mouse_x, mouse_y)
			}
			resizing_areas = false
			if moving_clip {
				// Commit a vertical drop if the ghost hovers another track;
				// horizontal drags already applied their new start live.
				if drag_hover_track != drag_source_track && drag_hover_track >= 0 && drag_source_track >= 0 {
					if len(drag_group_orig) > 1 {
						move_linked_group(drag_hover_track - drag_source_track)
					} else {
						move_clip_to_track(drag_source_track, drag_source_index, drag_hover_track, drag_ghost_start)
					}
				}
			}
			moving_clip = false
			moving_preview_clip = false
			dragging_handle = -1
			handle_kind = .None
			drag_clip = nil
			drag_source_track = -1
			drag_source_index = -1
			drag_hover_track = -1
			drag_group_delta = 0
			clear(&drag_group_orig)
			dragging_playhead = false
			resizing_clip = false
			resize_edge = -1
		} else if dragging_media_from_bin {
			// A bin drag in flight: recompute the hovered lane + ghost each frame.
			update_media_drag_lanes(mouse_x, mouse_y)
		} else if dragging_handle >= 0 {
			if sel, ok := transformable_selected(); ok {
				pb := clay.GetElementData(clay.ID("Preview")).boundingBox
				canvas := preview_canvas(pb)
				update_handle_drag(sel, canvas, mouse_x, mouse_y, shift_down)
			}
		} else if resizing_areas {
			upper_area_height = mouse_y - 8
			// Keep a lower-bound that scales with the window so a short window
			// never lets the upper and lower areas collide (the old hardcoded
			// 460/180 bounds collapsed on windows shorter than ~640px).
			min_h := min(460.0, f32(height) * 0.35)
			max_h := max(min_h, f32(height) - 140)
			upper_area_height = clamp(upper_area_height, min_h, max_h)
		} else if moving_preview_clip {
			if sel, ok := transformable_selected(); ok {
				pb := clay.GetElementData(clay.ID("Preview")).boundingBox
				// Freeze at the preview widget's edge once the cursor leaves it:
				// otherwise free-move in unclamped project coords, so a cropped
				// clip can slide fully off-canvas like an uncropped one.
				if mouse_x >= pb.x && mouse_x <= pb.x + pb.width && mouse_y >= pb.y && mouse_y <= pb.y + pb.height {
					canvas := preview_canvas(pb)
					pcx, pcy := pixel_to_project_unclamped(canvas, mouse_x, mouse_y)
					sel.transform_x = pcx - preview_drag_offset_x
					sel.transform_y = pcy - preview_drag_offset_y
					// 5px snap margin (in rendered preview pixels): to the canvas
					// center when near it, and/or to the canvas borders (edge
					// snap runs regardless, so a centered clip still snaps).
					snap_center(sel, snap_margin(canvas, 5))
					snap_transform(sel, snap_margin(canvas, 5))
				}
			}
		} else if resizing_clip {
			if selected_track >= 0 && selected_index >= 0 && selected_track < len(timeline.tracks) && selected_index < len(timeline.tracks[selected_track].clips) {
				track_start := clay.GetElementData(clay.ID("ClipsSection", 0)).boundingBox.x
				frame := max(f32(0), (mouse_x - track_start) / timeline_zoom + timeline_view_start)
				sync.mutex_lock(&audio_timeline_mtx)
				if resize_edge == 0 {
					if len(drag_group_orig) > 0 {
						// Linked group: shift every member's head by the same delta.
						resize_group_left(&timeline.tracks[selected_track], selected_index, i64(frame))
					} else {
						resize_clip_left(&timeline.tracks[selected_track], selected_index, i64(frame))
					}
				} else if resize_edge == 1 {
					if len(drag_group_orig) > 0 {
						// Linked group: move every member's tail by the same delta.
						resize_group_right(&timeline.tracks[selected_track], selected_index, i64(frame))
					} else {
						resize_clip_right(&timeline.tracks[selected_track], selected_index, i64(frame))
					}
				}
				sync.mutex_unlock(&audio_timeline_mtx)
				audio_note_edit()
			}
		} else if moving_clip {
			if drag_clip != nil {
				clip_x := mouse_x - clip_drag_offset
				track_start := clay.GetElementData(clay.ID("ClipsSection", 0)).boundingBox.x
				frame := (clip_x - track_start) / timeline_zoom + timeline_view_start
				frame = max(frame, 0)
				// Clip→playhead toggle: latch the drag target onto the playhead
				// once it comes within the pixel snap margin. Applied to the
				// whole linked group, since every member follows the anchor.
				if snap_clips_to_playhead {
					frame = f32(snap_to_playhead(i64(max(frame, 0))))
				}
				// Determine which track lane the pointer hovers: that decides
				// whether this is a horizontal move (same track) or a vertical
				// drop staged on another track (ghost until release).
				hover := drag_source_track
				for ti := 0; ti < len(timeline.tracks); ti += 1 {
					lane := clay.GetElementData(clay.ID("ClipsSection", u32(ti))).boundingBox
					if lane.width > 0 && mouse_y >= lane.y && mouse_y <= lane.y + lane.height {
						hover = ti
						break
					}
				}
				sync.mutex_lock(&audio_timeline_mtx)
				if hover == drag_source_track {
					drag_hover_track = hover
					if len(drag_group_orig) > 1 {
						// Linked group: the whole unit shifts by deltas every
						// member can honor exactly -- the anchor never moves into
						// a slot a partner can't reach. It sticks at the last
						// feasible position when the mouse keeps dragging past a
						// blocked slot.
						delta := i64(max(frame, 0)) - drag_group_orig[0].start
						if group_delta_feasible(delta) {
							if drag_clip.timeline_start_frame != drag_group_orig[0].start + delta {
								if nered_trace {
									fmt.printf("[tl] drag group link=%d (%d clips) delta=%d\n", drag_clip.link_id, len(drag_group_orig), delta)
								}
								drag_clip.timeline_start_frame = drag_group_orig[0].start + delta
							}
							apply_group_drag_to_members(delta)
						}
					} else {
						// Horizontal move: keep the live-follow behavior but clamp so
						// the clip can never overlap a neighbor on this track.
						new_start := clip_slide_in_track(&timeline.tracks[drag_source_track], drag_source_index, drag_clip.source_length_frames, i64(max(frame, 0)), drag_clip.timeline_start_frame)
						if drag_clip.timeline_start_frame != new_start {
							if nered_trace {
								fmt.printf("[tl] drag clip src=%s len=%d start=%d -> %d\n",
									drag_clip.path, drag_clip.source_length_frames,
									drag_clip.timeline_start_frame, new_start)
							}
							drag_clip.timeline_start_frame = new_start
						}
					}
				} else {
					// Vertical: clamp to nearest valid slot on the hovered track
					// and show it as a ghost (committed on release). Linked
					// groups slide the whole unit with the mouse's horizontal
					// offset (drag_group_delta) on every member's lane.
					drag_hover_track = hover
					drag_ghost_start = clip_place_in_track(&timeline.tracks[hover], -1, drag_clip.source_length_frames, i64(max(frame, 0)))
					if len(drag_group_orig) > 1 {
						drag_group_delta = i64(max(frame, 0)) - drag_group_orig[0].start
					}
				}
				sync.mutex_unlock(&audio_timeline_mtx)
				audio_note_edit()
			}
		} else if dragging_playhead {
			// Scrub the playhead to the pointer's frame along the ruler bar.
			ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
			frame := i64((mouse_x - ruler.x) / timeline_zoom + timeline_view_start)
			frame = max(frame, 0)
			// Clamp to the last REAL frame of the timeline. timeline_duration()
			// is the exclusive content end, so frame == timeline_duration() is a
			// sheet empty slot past every clip; letting the playhead sit there
			// rendered (and scrubbed) a void after the last clip. The playhead
			// must stop at the final content frame; dragging further right pins
			// it there.
			frame = clamp(frame, 0, max(0, timeline_duration() - 1))
			// Playhead→clip toggle: when a clip's start or end is within the
			// snap margin, pin the scrubbed playhead onto that exact edge.
			if snap_playhead_to_clips {
				frame = snap_playhead_to_clip_edge(frame)
			}
			if playhead.frame != frame {
				if nered_trace {
					fmt.printf("[pb] scrub ph=%d (was %d) playing=%v\n", frame, playhead.frame, playhead.playing)
				}
			}
			playhead.frame = frame
			preview_frontier = frame
			// A playhead jump must anchor audio to the new position immediately:
			// otherwise the producer keeps decoding from the pre-scrub position
			// and the sound lags the video until its far-forward guard trips.
			audio_seek(frame)
			sync.atomic_store(&audio_ph_src, 1)
			sync.atomic_store(&audio_ph_catch, 0)
			// And the preview: drop every slot's decode frontier so the exact
			// playhead frame is requested (the forward-clamp would otherwise walk
			// the image toward the new position one frame per update).
			for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
				if preview_slots[s].in_use {
					preview_slots[s].have_frontier = false
				}
			}
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("PlayPause")) {
			toggle_playback()
		}
		// Jog controls: backward/forward around play (and h/l keys), handled
		// independently of the chain above since they're distinct elements.
		if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("PlayBack")) {
			jog_playback(-1)
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("PlayFwd")) {
			jog_playback(1)
		}
		// Playback-rate dropdown: clicking the rate button toggles the menu;
		// clicking a menu option selects that rate and closes it. Any other new
		// click while open dismisses the menu without changing the rate.
		was_click := mouse_down && !was_mouse_down
		rate_clicked := was_click && clay.PointerOver(clay.ID("PlayRateButton"))
		if was_click {
			handle_playback_rate_click(rate_clicked)
		}
		// Help overlay: the "?" button toggles it; any other click outside the
		// panel dismisses it.
		if was_click {
			if clay.PointerOver(clay.ID("HelpButton")) {
				help_open = !help_open
			} else if help_open && !clay.PointerOver(clay.ID("HelpPanel")) {
				help_open = false
			}
		}
		// Right-click: a clip gets a clip menu; empty space gets the track menu.
		// Any fresh left-click or a new right-click that lands elsewhere closes
		// an open menu first.
		if right_down && !was_right_down {
			if ct, ci := clip_under_pointer(); ct >= 0 {
				open_clip_context_menu(mouse_x, mouse_y, ct, ci)
			} else if track := timeline_track_hit_test(mouse_x, mouse_y); track >= 0 {
				open_track_context_menu(mouse_x, mouse_y, track)
			} else {
				close_context_menu()
			}
		} else if was_click && ctx_menu.open {
			if pointer_over_context_menu() {
				handle_ctx_option()
			} else {
				close_context_menu()
			}
		}
		// Submenu flyout follows the cursor: show while hovering the "Add >"
		// row or the submenu itself, hide while hovering neither.
		if ctx_menu.open {
			ctx_menu.submenu = pointer_over_context_menu() && (clay.PointerOver(clay.ID("CtxAdd")) || pointer_over_submenu())
		}
		update_timeline_cursor(mouse_x, mouse_y)
		was_mouse_down = mouse_down
		was_right_down = right_down
		now_ns := sdl.GetTicksNS()
		if last_tick_ns == 0 {
			last_tick_ns = now_ns
		}
		if playhead.playing {
			// DIAG (temporary): PLAYBACK_MAGIC_MS replaces the measured wall
			// delta so the cadence is perfectly jitter-free (or any fixed rate).
			dt_s := PLAYBACK_MAGIC_MS > 0 ? PLAYBACK_MAGIC_MS / 1000.0 : f64(now_ns - last_tick_ns) / 1_000_000_000
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
					if nered_trace {
						fmt.printf("[pb] burst %+d ph=%d dt=%.1fms acc=%.3fs\n", i64(playback_dir) * catchup, playhead.frame, f64(now_ns-last_tick_ns)/1e6, playhead_accumulator)
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
			at_end := (playback_dir == 1 && playhead.frame >= stop_frame) || (playback_dir == -1 && playhead.frame <= 0)
			if at_end {
				playback_stop_frame = -1
				playback_boost = 0
				playhead.frame = clamp(playhead.frame, 0, max(0, stop_frame - 1))
				playhead.playing = false
				preview.playing = false
				if nered_trace {
					fmt.printf("[pb] auto-stop dir=%d ph=%d stop=%d\n", playback_dir, playhead.frame, stop_frame)
				}
			}
			// Playback is real-time: the playhead (and with it the audio) runs on
			// the wall clock. Video decode is best-effort on top of that clock.
		}
		last_tick_ns = now_ns
		sync.atomic_store(&ui_playhead_frame, playhead.frame)
		audio_update()
		poll_completed_thread()
		import_bg_consume_done()
		ui_frame_count += 1
		if ui_report_tick == 0 {
			ui_report_tick = now_ns
		} else if now_ns - ui_report_tick >= 2_000_000_000 {
			if nered_trace {
				elapsed := f64(now_ns - ui_report_tick) / 1e9
				fmt.printf("[ui] fps=%.1f dec_ms=%.1f playhead=%d frontier=%d gap=%d acc=%.3fs src=%d catch=%d prod=%d\n",
					f64(ui_frame_count) / elapsed,
					f64(ui_dec_us) / 1000.0 / f64(ui_frame_count),
					playhead.frame, preview_frontier, playhead.frame - preview_frontier,
					playhead_accumulator, sync.atomic_load(&audio_ph_src), sync.atomic_load(&audio_ph_catch), sync.atomic_load(&audio_prod_frame))
			}
			ui_report_tick = now_ns
			ui_frame_count = 0
			ui_dec_us = 0
		}
		renderer.viewport = {f32(width), f32(height)}
		command_buffer := sdl.AcquireGPUCommandBuffer(device)
		if command_buffer == nil {
			continue
		}
		dec_t0 := sdl.GetTicksNS()
		changed := update_preview_slots()
		ui_dec_us += i64(sdl.GetTicksNS() - dec_t0)
		any_frame := false
		for i in 0..<MAX_PREVIEW_SLOTS {
			slot := &preview_slots[i]
			if !slot.in_use {
				continue
			}
			if slot.is_text {
				// Text slots own a tightly-sized texture (full estimated buffer
				// bw x bh, stored in text_tex_w/h). update_preview_slots sets
				// text_recreate whenever it re-rasterizes (which is whenever the
				// buffer size could change), so recreate on that flag + first use.
				if slot.texture == nil || slot.text_recreate {
					if slot.texture != nil {
						sdl.ReleaseGPUTexture(device, slot.texture)
					}
					slot.texture = create_text_texture(device, slot.text_tex_w, slot.text_tex_h)
				}
				slot.text_recreate = false
			} else if slot.texture == nil {
				slot.texture = renderer.preview_textures[i]
			}
			if slot.tex_dirty || changed {
				upload_preview_slot(&renderer, command_buffer, slot)
			}
			// in_use only means the slot is claimed by some clip; it says
			// nothing about whether THIS slot has actually decoded a frame
			// for its CURRENT identity yet. Right after a clip_id change
			// (anchor_shifted in update_preview_slots), in_use stays true
			// but has_frame is deliberately false until a fresh decode
			// lands -- gating on in_use here painted whatever was still
			// sitting in the GPU texture from the PREVIOUS clip that owned
			// this slot for every frame the new decode took, which is
			// exactly the "old clip's image fighting the new one" bug.
			if slot.has_frame {
				any_frame = true
			}
		}
		preview_has_frame = any_frame
		// Free text textures orphaned by slot reassignment/invalidation earlier
		// this frame (they have no device in the preview state, so they wait
		// here where the device is).
		drain_pending_text_releases(device)
		// Upload decoded media-bin thumbnails (once per asset, after import).
		for &a in media_assets {
			upload_asset_thumbnail(&renderer, command_buffer, &a)
		}
		swapchain_texture: ^sdl.GPUTexture
		pixel_width, pixel_height: sdl.Uint32
		if !sdl.WaitAndAcquireGPUSwapchainTexture(command_buffer, window, &swapchain_texture, &pixel_width, &pixel_height) || swapchain_texture == nil {
			_ = sdl.CancelGPUCommandBuffer(command_buffer)
			continue
		}
		renderer.viewport = {f32(pixel_width), f32(pixel_height)}
		color_target := sdl.GPUColorTargetInfo{
			texture = swapchain_texture,
			clear_color = sdl.FColor{10.0 / 255, 11.0 / 255, 14.0 / 255, 1},
			load_op = .CLEAR, store_op = .STORE,
		}
		pass := sdl.BeginGPURenderPass(command_buffer, &color_target, 1, nil)
		if pass != nil {
			render_clay(&renderer, command_buffer, pass, commands)
			draw_text_input_caret(&renderer, command_buffer, pass)
			draw_clip_markers(&renderer, command_buffer, pass)
			draw_timeline_resize_focus(&renderer, command_buffer, pass)
			draw_drag_ghost(&renderer, command_buffer, pass)
			draw_media_bin_thumbnails(&renderer, command_buffer, pass)
			draw_ui_icons(&renderer, command_buffer, pass)
			draw_media_drag_ghost(&renderer, command_buffer, pass)
			if len(timeline.tracks) > 0 {
				draw_timeline_ruler(&renderer, command_buffer, pass)
				draw_render_range(&renderer, command_buffer, pass)
			}
			if preview_has_frame {
				preview_bounds := clay.GetElementData(clay.ID("Preview")).boundingBox
				draw_preview(&renderer, command_buffer, pass, preview_bounds)
				draw_preview_hud(&renderer, command_buffer, pass, preview_bounds)
			}
			draw_ui_notice(&renderer, command_buffer, pass, f32(width), f32(height))
			draw_import_progress(&renderer, command_buffer, pass, f32(width), f32(height))
			sdl.EndGPURenderPass(pass)
		}
		if !sdl.SubmitGPUCommandBuffer(command_buffer) {
			fmt.println("Could not submit GPU command buffer:", sdl.GetError())
		}
	}
}
