package main

import clay "clay-odin"
import "core:c"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Core data model: project, media, timeline, and all top-level mutable app
// state. Interaction/UI code lives in other files; this is the shared state
// they all read and write.
// ---------------------------------------------------------------------------

// vyper_trace enables the interactive debug traces ([pb]/[tl]/[ui]/[autoplay]).
// Off by default; set VYPER_TRACE=1 to turn on.
vyper_trace: bool = false

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720

PREVIEW_W :: 768
PREVIEW_H :: 432

// Everforest dark medium-contrast palette. Backgrounds climb the bg_dim→bg4
// ladder (raised surfaces get brighter), fg/grey* carry text and borders, and
// the accents are semantic: green for anything active/hovered, blue for
// selection, yellow/orange/red for markers and errors. Hex values are the
// theme's own (palette.md), the alpha-lowered variants stay inline at the draw
// site that needs them.
BACKGROUND :: clay.Color{35, 42, 46, 255} // bg_dim — dimmed window background
EDITOR_BG :: clay.Color{45, 53, 59, 255} // bg0 — default editor background
// TRACK_GUTTER_BG paints the left track-name column (and its ruler header strip)
// so the name gutter reads as a distinct panel from the clip lane area.
TRACK_GUTTER_BG :: clay.Color{52, 63, 68, 255} // bg1 — raised panel
BUTTON :: clay.Color{61, 72, 77, 255} // bg2 — raised control fill
BUTTON_BORDER :: clay.Color{133, 146, 137, 255} // grey1 — UI border
BUTTON_HOVER :: clay.Color{71, 82, 88, 255} // bg3 — hover raises a step
BUTTON_BORDER_HOVER :: clay.Color{167, 192, 128, 255} // green — active accent (hover, focus, held)
SWITCH_TRACK_ON :: clay.Color{66, 80, 71, 255} // bg_green — muted green switch track when active
AUDIO_CLIP :: clay.Color{84, 58, 72, 255} // bg_visual — muted purple clip fill
SELECT_BORDER :: clay.Color{127, 187, 179, 255} // blue — selection
MARKER_COLOR :: clay.Color{219, 188, 127, 255} // yellow — clip markers
// Keyframe diamond fills: neutral by default, light (fg) when selected. The
// selected state lands with the keyframe selection slice. Timeline diamonds
// paint a thin accent ring under the fill (KF_DIAMOND_BORDER_COLOR) so a key
// reads against the row background; the inspector's add-keyframe buttons use
// the plain hollow ring instead.
KF_DIAMOND_FILL :: clay.Color{79, 88, 94, 255} // bg4 — neutral keyframe diamond fill
KF_DIAMOND_FILL_SELECTED :: clay.Color{211, 198, 170, 255} // fg — light when selected
// A control that is present but not currently actionable (e.g. "key all
// modified" with nothing pending). Dimmer than KF_DIAMOND_FILL so it recedes
// without vanishing — the row is still part of the inspector's grammar.
KF_DIAMOND_FILL_DISABLED :: clay.Color{61, 72, 77, 255} // bg2
KF_DIAMOND_BORDER_COLOR :: clay.Color{167, 192, 128, 255} // green — active accent ring (same as hover)
TOOLTIP_BG :: clay.Color{61, 72, 77, 255} // bg2 — popup/tooltip surface
TOOLTIP_TEXT :: clay.Color{211, 198, 170, 255} // fg
RANGE_COLOR :: clay.Color{167, 192, 128, 255} // green — active range chevrons
HANDLE_FILL :: clay.Color{35, 42, 46, 255} // bg_dim — thumb fill inside the blue handle
HANDLE_BORDER :: clay.Color{133, 146, 137, 255} // grey1
TEXT :: clay.Color{211, 198, 170, 255} // fg — warm off-white
TEXT_INPUT_BG :: clay.Color{35, 42, 46, 255} // bg_dim — recessed input, switch-off track
// CMDLINE_PLACEHOLDER dims the command line's remembered-text hint relative to
// the typed text, so an empty prompt reads as "what you last ran" rather than
// an actual command.
CMDLINE_PLACEHOLDER :: clay.Color{133, 146, 137, 255} // grey1 — dimmer than TEXT

RULER_HEIGHT :: f32(30)
RULER_TICK_COLOR :: clay.Color{79, 88, 94, 255} // bg4 — ruler ticks
RULER_LABEL_COLOR :: clay.Color{157, 169, 160, 255} // grey2 — ruler labels
// Timeline navigation: timeline_view.start is the first visible frame (pan),
// timeline_view.zoom is horizontal pixels per frame, and timeline_view.top is the
// Timeline_View is the timeline panel's own scroll/zoom transform: the
// horizontal scroll offset, the horizontal zoom (frames-per-pixel), and the
// vertical scroll offset over the track rows (so many tracks stay reachable).
Timeline_View :: struct {
	start: f32,
	zoom:  f32,
	top:   f32,
}
timeline_view: Timeline_View = {start = 0, zoom = 1, top = 0}
SNAP_PIXELS :: 8 // Snap margin (in screen px) while either toggle is on.
TIMELINE_MIN_ZOOM :: f32(0.001)
TIMELINE_MAX_ZOOM :: f32(16)

// timeline_fps returns the timeline's frame rate (the source video's native
// rate, set at import, unless the project fps has been set explicitly). The
// timeline grid is 1 frame == 1 source frame, so the playhead and the render
// canvas must tick at this rate for 1:1 audio/video.
// Falls back to 60 as a safe default before any media is open.
timeline_fps :: proc() -> f64 {
	if playback.magic_fps > 0 {
		return playback.magic_fps
	}
	if project.frame_rate > 0 {
		return project.frame_rate
	}
	if timeline.frame_rate > 0 {
		return timeline.frame_rate
	}
	return 60
}

// DIAG (temporary): magic playback-clock overrides to isolate whether the
// playhead's wall-clock cadence affects the audible audio rate.
//   VYPER_PLAYBACK_MAGIC_MS  > 0  ignore measured wall delta; advance the
//                               playhead by exactly this many ms per frame tick
//                               (16.6667 = perfect 60fps cadence, zero jitter).
//   VYPER_PLAYBACK_FPS       > 0  override timeline_fps() for the playhead
//                               advance, the mixer's start48/spf mapping, and
//                               the audio producer. 0 = use the imported rate.
// These live in the Playback struct alongside the clock they override. This
// comment keeps the env-var names in one place the writer (system_main_init)
// and readers (timeline_fps, the main loop) can share.
//
// [playback struct below holds magic_ms/magic_fps]

Project :: struct {
	name:        string,
	width:       c.int,
	height:      c.int,
	// Project frame rate. 0 = auto: use the first imported media's native rate.
	// An explicit value overrides the source rate for the timeline grid, the
	// playhead cadence, the audio producer, and the render output.
	frame_rate:  f64,
	// Render range: the frames that would actually be exported. Set with the
	// I (start) / O (end) hotkeys. -1 = unset; when both are unset the whole
	// project is the render range. Setting both to the same frame clears it.
	start_frame: i64,
	end_frame:   i64,
	// info_text is the media-file info line shown in the project panel.
	info_text: string,
	// resolution_locked becomes true the moment the project resolution is set
	// explicitly (a preset button or the orientation toggle) or inferred from
	// the first imported file. Once locked, importing more media never resizes
	// the canvas.
	resolution_locked: bool,
}
project: Project = {
	name        = "Untitled Project",
	width       = 1920,
	height      = 1080,
	frame_rate  = 0,
	start_frame = -1,
	end_frame   = -1,
}

Media_Kind :: enum {
	Video,
	Audio,
	Image,
	Other,
	Empty,
	Text,
	Subtitles,
}

// Generator_Kind marks clips that synthesize their output programmatically
// instead of decoding a backing media file (a "generator"). .None = a regular
// file-backed clip.
Generator_Kind :: enum {
	None,
	Text,
	Subtitles,
}

// Thumbnail size for the media bin grid. Decoded once at import (frame 0 of the
// source, downsclaled from PREVIEW_W x PREVIEW_H into these dims, letterboxed)
// and uploaded to a per-asset GPU texture on first render.
THUMB_W :: 160
THUMB_H :: 90

Media_Asset :: struct {
	id:              u64,
	path:            cstring,
	kind:            Media_Kind,
	metadata:        string,
	frame_count:     i64,
	// dur_us is the source duration in microseconds, captured at import so the
	// on-demand proxy scheduler can derive fps (frame_count / duration) without
	// re-probing the file every time the playhead crosses a segment boundary.
	dur_us:          i64,
	// Native source pixel size (video clips land on the timeline at native
	// scale, and the aspect drives fitting).
	src_w:           c.int,
	src_h:           c.int,
	// audio_streams is the number of audio tracks this media would create when
	// dropped (each stream becomes its own timeline clip on its own lane).
	audio_streams:   c.int,
	// audio_frames is the clip length for the audio stream(s), derived from the
	// duration at import (never shorter than the video frame count).
	audio_frames:    i64,
	// is_image marks a still-image source. A still has a single decodable frame
	// but is placed on the timeline with a one-second length (like every other
	// import's default), so its frames map to source frame 0 for the whole
	// span; see Clip.is_still.
	is_image:        bool,
	// src_hw latches whether THIS source file opens with a hardware decoder on
	// this machine (hw_pix_fmt != .None). Stable per asset: the S5 original-rate
	// pick must gate on the SOURCE's capability, never on whichever file a slot
	// decoder happens to have open right now -- a self-referential gate there
	// (pick <- hw-pix-fmt-of-current-open <- pick) flips every frame on machines
	// where source (sw) and proxy (hw) differ in hw support, reopening both
	// decoders in a loop (render-thread stalls -> playhead bursts -> audio
	// forward-skips). Probed lazily once by asset_source_hw.
	src_hw:          bool,
	src_hw_known:    bool,
	// srt_id is the session srt-cache id for a .Subtitles asset (the srt text
	// lives in the immortal append-only cache). -1 for non-subtitle assets; a
	// drop of the asset derives its timeline clip length from frame_count.
	srt_id:          int,
	// Thumbnail: CPU RGBA + lazily-created GPU texture (uploaded by the render
	// loop once; thumb_tex_dirty set at import).
	thumb_buf:       [THUMB_W * THUMB_H * 4]u8,
	has_thumb:       bool,
	thumb_tex:       ^sdl.GPUTexture,
	thumb_tex_dirty: bool,
}

// Clip_Marker is a point marker embedded in a clip (e.g. an imported chapter
// marker): source_frame is the position within the source media, label a
// human-readable name. Markers move/split with the clip.
Clip_Marker :: struct {
	source_frame: i64,
	label:        string,
}

Clip :: struct {
	// clip_id is a stable identity assigned once at clip creation (import, or
	// the new half produced by a split) via new_clip_id() -- never touched by
	// moving/dragging/resizing the clip. asset_id+timeline_start_frame is NOT
	// a valid identity key: timeline_start_frame is exactly the field a drag
	// mutates continuously, so any code that captures that pair and looks it
	// up again on a later frame is holding a key that's already gone stale.
	clip_id:              u64,
	asset_id:             u64,
	// link_id groups the clips that came from one imported media file (its
	// video clip plus one clip per audio stream). Spent on selection (selecting
	// one selects all), cuts (all covering members split together), moves (the
	// group drags as a unit) and raw deletes. Splits keep the left halves in the
	// original group and mint a fresh link_id for the right halves. 0 = not
	// linked (generator clips, single-stream media, duplicated-track copies).
	link_id:              u64,
	path:                 cstring,
	// name is the clip's editable label. For a Text generator clip it is the
	// title that will be rendered; for file-backed clips it's a display name.
	name:                 string,
	kind:                 Media_Kind,
	// is_still marks a clip whose source is a single still image: every timeline
	// frame in the clip maps to the source's one frame (frame 0), so the image
	// holds across the clip's length instead of the decoder seeking past EOF.
	is_still:             bool,
	// generator identifies this clip as a generator (programmatic output).
	// .None for ordinary file-backed clips; .Text for the text generator;
	// .Subtitles for the subtitle (.srt) generator.
	generator:            Generator_Kind,
	// srt_id is the index into srt_cache for a .Subtitles generator clip (the
	// parsed .srt backing this clip); -1/ignored for other clip kinds. The
	// cache is session-scoped and append-only, so this index stays valid for
	// the clip's lifetime without any ownership/freeing on the clip.
	srt_id:               int,
	stream_index:         c.int,
	// gain: output level of the clip's audio, in decibels (0.0 = unity). Rides
	// the per-clip audio snapshot through the mix; applies to any media kind,
	// only audible for Audio clips.
	gain:                 f32,
	source_start_frame:   i64,
	source_length_frames: i64,
	timeline_start_frame: i64,
	// Native source pixel size (0 = unknown). The clip image is drawn keeping
	// this aspect inside its transform box instead of stretching to the canvas,
	// so a video imported into a differently-shaped project is letterboxed.
	source_w:             c.int,
	source_h:             c.int,
	// Transform: center of the clip's image within the project canvas, in
	// project-resolution pixels. Default (width/2, height/2) centers the clip so
	// it fills the preview at scale 1.
	transform_x:          f32,
	transform_y:          f32,
	// Scale: uniform (aspect-locked) factor that resizes the on-screen bounding
	// box relative to the project canvas, independent of crop.
	scale:                f32,
	// Crop: per-edge trim insets, normalized fractions (0..1) of the scale box.
	// Trimming edits the box edges (revealing background behind the clip) while
	// keeping the source's zoom constant, distinct from scale.
	crop_l:               f32,
	crop_r:               f32,
	crop_t:               f32,
	crop_b:               f32,
	// Opacity: global alpha this clip composites with, 0..1 (1 = fully opaque).
	// A resting field like scale/gain, not a geometry lane -- it changes how the
	// clip is blended, not where it sits. Read directly by preview and render.
	opacity:              f32,
	// Markers embedded in the clip (chapter markers, etc.), source-relative.
	markers:              [dynamic]Clip_Marker,
	// keyframe_tracks: the generic keyframe store (keyframes.odin) — opaque,
	// name-addressed (frame_off, value) series. The system never interprets a
	// track's name; consumers mint tracks named by their own property path.
	// Sorted tracks, each sorted by frame_off (clip-relative). nil = no keys.
	keyframe_tracks:      [dynamic]Kf_Track,
	// geom_modified: a bitmask over Render_Geom_Prop marking geometry lanes
	// edited WITHOUT a keyframe, i.e. sitting in the resting field. The
	// inspector's "keyframe all modified" button keys exactly this set. Set by
	// clip_geom_set (clip_geom.odin) on the resting-write path, cleared when the
	// lane is keyed.
	//
	// Session-only, and deliberately NOT serialized: it describes the user's
	// in-flight intent, not the clip. A reload with nothing pending is the
	// correct state for a project that was saved with its edits already baked
	// into resting values, and persisting it would report pending keys for
	// edits the user made long ago and never intended to animate. A clip that
	// needs keys gets them from the button; the file stays a description of
	// the timeline, not of the session.
	geom_modified:        u8,
}

Track :: struct {
	name:  string,
	clips: [dynamic]Clip,
}
Playback_Mode :: enum {
	Stopped,
	Playing,
	Paused,
	Seeking,
}
Timeline :: struct {
	// tracks holds every track in creation/append order -- STORAGE only. The
	// on-screen stacking order (which row is above which, which clip the preview
	// considers topmost) lives in track_order, a top-to-bottom list of indices
	// into tracks. Ordering is never inferrable from array position: a track
	// can be moved/duplicated/reordered without touching tracks, so clip
	// references (selection.track, drag targets, lane math) key on the STORAGE
	// index and are stable across reordering.
	tracks:         [dynamic]Track,
	track_order:    [dynamic]int,
	playhead_frame: i64,
	playback:       Playback_Mode,
	frame_rate:     f64,
}
timeline: Timeline
Playhead :: struct {
	frame:   i64,
	playing: bool,
}
playhead: Playhead

// Playback groups the playback-clock machinery that used to be a pile of loose
// globals: the cadence accumulator, rate/direction/boost selection, the scrub
// decimator, the DIAG magic-clock overrides, and the UI→producer playhead/device
// clock snapshot (ui_* + seq, dev_*) with its seqlock. One owner, one home.
Playback :: struct {
	// magic_ms / magic_fps: DIAG (temporary) overrides; see the env-var doc at
	// their former decl site (VYPER_PLAYBACK_MAGIC_MS / VYPER_PLAYBACK_FPS).
	magic_ms:      f64,
	magic_fps:     f64,
	// accumulator: wall-clock fraction of a frame not yet moved into the
	// playhead (frame cadence at float speed, kept in f64 across ticks).
	accumulator:   f64,
	last_tick_ns:  sdl.Uint64,
	// rate is the selected playback rate (Nx real time). Defaults to 1x.
	// rate_open tracks whether the playback-rate dropdown is shown.
	rate:          f64,
	rate_open:     bool,
	// dir: playback direction, +1 forward, -1 backward. Set by the forward/
	// backward jog controls (and h/l keys); playback advances the playhead by
	// +dir each step.
	dir:           int,
	// boost: temporary speed boost accumulated by repeatedly pressing the
	// forward/backward jog control while already playing in that direction.
	// Effective rate = rate * (1 + boost). Reset to 0 on pause.
	boost:         int,
	// stop_frame is the exclusive end of the active playback run; -1 means the
	// whole timeline (timeline_duration). Ctrl+Space sets it to the project's
	// render range end so playback stops there.
	stop_frame:    i64,
	// scrub_tick counts update_preview_slots calls during a playhead scrub
	// (SCRUB_DECIMATION throttling); see the constant's comment.
	scrub_tick:    i32,
	// ------------------------------------------------------------------
	// Playhead clock snapshot published by the UI thread for the audio
	// producer. The producer must not read playhead.frame directly (cross-thread
	// data race) and must not treat the last published value as frozen: a
	// blocking swapchain acquire can hold the render loop for a second while the
	// sound device keeps consuming, so a frozen frame would starve the producer
	// and a value that free-runs on the device would lock a permanent offset
	// after the stall. Publishing (frame, wall-time) together lets the producer
	// extrapolate the playhead on its own, from the same monotonic clock the UI
	// uses, across any UI update gap. Guarded by the seqlock seq so the pair is
	// never read torn; non-explicit Odin atomics are sequentially consistent.
	ui_frame:      i64, // atomic, guarded by seq
	ui_ns:         i64, // atomic, monotonic_ns() when ui_frame was current
	seq:           u64, // atomic seqlock: odd while publishing
	// dev_frame is the content frame the sound device has actually consumed
	// (everything the producer pushed minus what is still queued); published
	// every feed pass so the preview HUD can show the audio clock next to the
	// video one. dev_at_ns is the monotonic_ns() that belonged to the same feed
	// pass, so a reader can extrapolate the device position to its own "now" and
	// compare against the extrapolated playhead at the same instant -- the
	// stepped publish alone would show a full frame of phantom skew
	// (dev != playhead.frame).
	dev_frame:     i64,
	dev_at_ns:     i64,
}

playback: Playback = {
	rate      = 1.0,
	dir       = 1,
	stop_frame = -1,
}
// PLAYBACK_RATES are the selectable playback-rate values offered by the rate
// dropdown, in display order (1x first). Iterating this list is what the
// dropdown draws and the click handler resolves against.
PLAYBACK_RATES :: []f64{1, 1.5, 2, 2.5, 3, 3.5, 4}
// Editor_Flags are editor-wide mode toggles that gate whole subsystems.
Editor_Flags :: struct {
	// help_open shows the always-available keyboard-shortcut overlay ("?" button
	// or F1). Closed by ESC / a click outside / toggling it again.
	help_open: bool,
	// preview_proxy_enabled gates the editing-time proxy: when true (normal
	// editing), the live preview decodes low-res all-intra proxies for fluid
	// scrubbing. Probes set it false so headless ground-truth checks exercise
	// the ORIGINAL decode path (proxy pixels are lossy by design and would show
	// up as spurious diffs).
	preview_proxy_enabled: bool,
	// async_import_mode gates the background proxy builder (import_bg.odin):
	// live editing (default) enqueues proxy encodes on a worker with progress +
	// cancel so importing never blocks; probes switch it off to keep the
	// synchronous build so the proxy exists on disk the moment import_media
	// returns (the proxy-probe asserts that exactly).
	async_import_mode: bool,
	// Timeline-gutter snap toggles: dragging a clip onto the playhead snaps it
	// there; scrubbing the playhead onto a clip's start/end snaps it to the
	// edge. Both default on.
	snap_clips_to_playhead: bool,
	snap_playhead_to_clips: bool,
	// Auto-keyframing for the timeline bottom bar. When on, editing a property
	// that ALREADY has keyframes writes a key at the playhead instead of (or in
	// addition to) the resting value; properties nobody has keyed yet keep
	// their resting-edit behavior.
	auto_keyframe: bool,
	// snap_center_to_canvas makes a clip dragged/scaled in the preview snap to
	// the project canvas center when its center comes within the snap margin.
	snap_center_to_canvas: bool,
}
editor_flags: Editor_Flags = {
	preview_proxy_enabled = true,
	async_import_mode     = true,
	snap_clips_to_playhead = true,
	snap_playhead_to_clips = true,
	auto_keyframe          = true,
	snap_center_to_canvas  = true,
}

// active_interaction tracks which pointer gesture is active. Exactly one at a
// time; .None means idle.  Replaces the old pile of mutually-exclusive booleans
// so the compiler enforces one-active-at-a-time via the type system.
active_interaction: Interaction
// Scrub decimation: while active_interaction == .Playhead_Scrub, exact-frame
// preview decodes run on every SCRUB_DECIMATION-th update (playback.scrub_tick counts
// update_preview_slots calls during a drag) instead of on every mousemove. The
// last decoded frame stays on-screen between throttled decodes; releasing the
// drag lifts the throttle so the final position decodes exactly once.
SCRUB_DECIMATION :: 4
// Playhead_Scrub_State is the ruler-scrub gesture's payload: whether the drag
// actually moved the playhead. The scrub itself never touches the audio engine
// (a seek there is a full re-provision -- see the release case in
// interaction.odin), so this is what the release commits, and a press with no
// motion commits nothing.
Playhead_Scrub_State :: struct {
	moved: bool,
}
playhead_scrub: Playhead_Scrub_State
// DRAG_LANE_DWELL_FRAMES is how many consecutive frames the pointer must rest
// in a different lane than the dragged clip's source before a vertical drop is
// staged (ghost shown, drop committed on release). A fast horizontal flick
// often skitters across a lane boundary for a frame or two; staging the ghost
// instantly froze the source clip mid-stroke, detaching it from the cursor
// before it touched its neighbor. The dwell makes a deliberate drop (move + hold)
// still work while a quick cross-lane wobble reads as part of the same-track drag.
DRAG_LANE_DWELL_FRAMES :: 4

// Panel_Layout is the editor's top/bottom panel divider: how tall the UPPER
// (timeline/canvas) area is, in pixels, before the lower (track list) area
// starts. Dragging the divider edits it (see .Panel_Resize).
Panel_Layout :: struct {
	upper_area_height: f32,
}
panel_layout: Panel_Layout = {upper_area_height = 560}

// Clip_Resize_State is the whole clip-duration-edge gesture: which edge is
// grabbable (edge 0 = left trim/extend head, 1 = right trim/extend tail),
// whether the gesture actually resized (an edge CLICK with no drag commits no
// undo node), and the two lazily-created SDL cursors the edge shows (the
// horizontal-resize one while dragging/hovering an edge; the arrow is
// explicitly restored the rest of the time -- SDL doesn't reliably reset to the
// default pointer from SetCursor(nil)).
Clip_Resize_State :: struct {
	edge:          int,
	moved:         bool,
	resize_cursor: ^sdl.Cursor,
	arrow_cursor:  ^sdl.Cursor,
}
clip_resize: Clip_Resize_State = {edge = -1}

// Clip_Move_State is the whole clip-drag gesture (moving a timeline clip along
// its track or onto another, plus linked-group drags): the clip being dragged,
// the (track, index) it was grabbed from and the track its ghost currently
// hovers (-1 = none; vertical drags are staged as a ghost until release,
// horizontal drags keep live-move behavior on the source track), the ghost's
// staged start frame, the lane-dwell staging counter, the stall tracer, and
// the linked-group snapshot (delta + per-member original geometry).
Clip_Move_State :: struct {
	// offset: pointer offset within the clip at grab (the clip's start tracks
	// the cursor minus this).
	offset:       f32,
	clip:         ^Clip,
	source_track: int,
	source_index: int,
	hover_track:  int,
	ghost_start:  i64,
	// lane_dwell counts how many consecutive frames the pointer has rested in a
	// different lane than the dragged clip's source before a vertical drop is
	// staged (see DRAG_LANE_DWELL_FRAMES).
	lane_dwell:   u32,
	// trace_last_*: last cursor-target frame and clip start seen by the
	// .Clip_Move handler, used by the VYPER_TRACE stall line.
	trace_last_target: i64,
	trace_last_start:  i64,
	// group_delta is the group's mouse-driven horizontal offset while a LINKED
	// group is staged on another track; group_orig snapshots the original
	// (track, start, length) of every linked clip (see Drag_Group_Orig).
	group_delta:  i64,
	group_orig:   [dynamic]Drag_Group_Orig,
}
clip_move: Clip_Move_State = {
	source_track = -1,
	source_index = -1,
	hover_track  = -1,
	trace_last_target = -1,
	trace_last_start  = -1,
}

// Track_Drag_State is the whole track-reorder gesture: dragging a whole track
// row onto an insert gap (the "New track" button strips between rows). idx is
// the STORAGE index grabbed; hover_row is the VISUAL gap position
// (0..=len(track_order)).
Track_Drag_State :: struct {
	idx:       int,
	hover_row: int,
}
track_drag: Track_Drag_State = {idx = -1, hover_row = -1}

// clip_move.group_orig snapshots the original (track, start, length) of every clip
// sharing the dragged/resized clip's link_id, so a linked-group edit applies one
// shared delta to all members (each clamped to its own lane). Invariant: when
// non-empty its FIRST entry is the anchor clip (the one the user grabbed).
Drag_Group_Orig :: struct {
	clip_id: u64,
	track:   int,
	start:   i64,
	length:  i64,
}

// Media-bin drag state: dragging a bin asset onto the timeline, showing a
// ghost of every lane the media would occupy (one per stream). Distinct from
// clip dragging (timeline clips being moved around).
Media_Lane :: struct {
	// Lane the stream would land on (target_track + stream ordinal).
	track_idx:       int,
	// created is true when the lane does not exist yet (a new track that a
	// drop would append).
	created:         bool,
	// placed is the clamped non-overlapping start frame for this lane.
	placed:          i64,
	// blocked marks an import drop whose ALIGNED anchor frame overlaps existing
	// content on this lane: the whole drop is refused, so the lane never gets a
	// clamped position that would desync the media's streams.
	blocked:         bool,
	clip_len:        i64,
	kind:            Media_Kind,
	stream_index:    c.int,
	video_thumb_id:  u64, // asset id whose thumbnail paints the video lane
	has_video_thumb: bool,
}
// Media_Drag is the media-bin-to-timeline drag gesture: dragging a bin asset
// onto the timeline, showing a ghost of every lane the media would occupy (one
// per stream). Distinct from clip dragging (timeline clips being moved around).
Media_Drag :: struct {
	asset_id:    u64,
	asset_index: int, // index into media_bin.assets; -1 = none
	lanes:       [dynamic]Media_Lane,
	target:      int, // hovered track index; -1 = none
	frame:       i64,
	pick_dx:     f32, // pointer offset within the drag tile at grab
	pick_dy:     f32,
	// Current pointer while the drag is in flight (the cursor-following drag
	// tile needs the live position; the draw pass runs after the event
	// handling).
	mx:          f32,
	my:          f32,
	// trace_once: one-shot [md] ghost geometry dump per drag.
	trace_once:  bool,
}
media_drag: Media_Drag = {asset_index = -1, target = -1, trace_once = true}

// View separators: the bottom-of-panel tab rows pick which sub-view each panel
// shows. The media bin switches between the thumbnail grid and the undo tree;
// the inspector switches between its three property cards.
MediaBin_View :: enum { Bin, Undo }
Inspector_View :: enum { Clip, Project, Render }

// Panel_Views is the per-panel sub-view state: which tab each panel shows and
// the media-bin grid's vertical scroll offset (manual childOffset scroll, the
// same pattern TracksSection uses).
Panel_Views :: struct {
	media_bin_scroll: f32,
	media_bin_view:   MediaBin_View,
	inspector_view:   Inspector_View,
}
panel_views: Panel_Views = {media_bin_view = .Bin, inspector_view = .Clip}
MEDIA_BIN_SCROLL_STEP :: 44
TIMELINE_SCROLL_STEP :: 44 // Wheel scroll per notch over the track lanes.

// Selection is what the editor is currently focused on: the media-bin item
// highlighted in the thumbnail grid (asset), and the clip selected in the
// timeline (track/index into the storage arrays — indices, not pointers, so
// dynamic-array reallocation can't dangle them; -1 means nothing selected).
// set holds extra clip ids added with Shift+click (the anchor clip stays
// tracked by track/index); used to link/unlink a deliberate multi-clip set
// with U.
Selection :: struct {
	asset_id:  u64, // media-bin item; 0 = none
	track:     int, // -1 = no timeline clip selected
	index:     int, // -1 = no timeline clip selected
	extra_set: map[u64]bool,
}
selection: Selection

// Keyframe selection (S3): one keyframe on the live timeline, resolved by
// indices (not pointers) so dynamic-array reallocations can't dangle it. It is
// MUTUALLY EXCLUSIVE with the clip selection above — selecting a keyframe
// clears selection.track/.index/.extra_set, and every clip-selection path
// clears this. Indices go stale the moment the structure moves, so every
// resolve re-bounds-checks against the live tree; a stale selection reads as
// "nothing selected" (kf_selected) rather than aliasing a burned slot.
Keyframe_Selection :: struct {
	active:     bool,
	track_idx:  int, // storage track index
	clip_index: int, // clip within that track
	lane:       int, // into the clip's keyframe_tracks
	key:        int, // into the lane's keys
	gen:        u32, // kf_view.structure_gen when the selection was made
}
kf_sel: Keyframe_Selection // zero value = nothing selected

// Kf_View is the keyframe selection's UI companion state: the interpolation
// dropdown toggle (one flag — a single key is selected at a time, same
// toggle/select/dismiss shape as the export-encoder dropdown) and the
// structure generation counter below.
Kf_View :: struct {
	interp_menu_open: bool,
	// structure_gen increments whenever a keyframe SEQUENCE can shift: a key
	// inserted or deleted (kf_set_key/kf_del_key) or a lane remapped
	// (split/trim). Index-based keyframe selections record the gen they were
	// made under and refuse to resolve once it drifts — a deleted key's slot
	// can silently be reused by the next key, so without the gen a stale
	// selection would alias a key that slid into the old index (AGENTS: never
	// let an old handle alias a reused slot). On gen mismatch kf_selected
	// reports "nothing selected", and the user re-picks the diamond.
	structure_gen:   u32,
}
kf_view: Kf_View

// Preview_Move is the preview-transform drag (dragging the selected clip
// around within the preview canvas): the pre-gesture offset of the clip's
// center, so each pointer delta translates from a fixed reference instead of
// accumulating float error.
Preview_Move :: struct {
	// Pointer offset from the drag grab point to the clip's center. The clip's
	// center follows the cursor minus this, so grabbing a clip off-center keeps
	// that grip instead of snapping the center to the cursor.
	start_offset_x: f32,
	start_offset_y: f32,
}
// preview_move acts as the gesture payload for .Preview_Move; the current
// translation is tracked in the clip's own transform, not here.
preview_move: Preview_Move

// Edit_Field names which clip property a text-edit session targets. .None
// means no field is being edited; chars/len below hold the buffer typed.
Edit_Field :: enum {
	None,
	X,
	Y,
	Scale,
	Crop_L,
	Crop_R,
	Crop_T,
	Crop_B,
	Gain,
	Opacity,  // clip opacity, edited as a percent
	Kf_Value, // selected keyframe's value (Clip inspector keyframe readout)
}

// Edit_State is the in-progress property text edit (typing a numeric value
// into a clip inspector field). field names which property; chars/len hold the
// typed buffer. Committing parses chars into the field's value; cancelling
// clears it.
Edit_State :: struct {
	field: Edit_Field,
	chars: [64]u8,
	len:   int,
}
edit_state: Edit_State

// Text_Input is the generic modal string field (used by clip rename, and any
// future string input). UTF-8 safe: cursor/anchor are byte offsets into buf.
// Selection spans [min(cursor,anchor), max(cursor,anchor)]. Enter commits, Esc
// cancels. Copy/cut/paste talk to the system clipboard.
Text_Input :: struct {
	active:     bool,
	buf:        [dynamic]u8,
	cursor:     int,
	anchor:     int,
	input_type: int, // caller discriminator (1 = clip rename)
	target:     u64, // caller target id (clip_id for rename)
	// is_create marks an in-progress text-editing session that is CREATING a
	// clip (rather than renaming an existing one): the clip only survives if a
	// non-empty name is committed. Applies both to renamed (commit) and cancel.
	is_create:  bool,
	// text_pending means a field opened this frame and SDL text input still
	// needs turning on. The enable is deferred to text_input_flush_pending,
	// after the event drain, because activating an IME mid-keypress makes SDL
	// route the keypress being handled through the new IME context — the field
	// opens already containing the character that opened it.
	text_pending: bool,
	// text_on is what SDL was actually told, as opposed to `active`, which is
	// only what the app wants. The two differ for the whole of a field's first
	// frame, and a field that opens and closes inside one drain never has SDL
	// text input turned on at all. Both are needed: `text_on` to avoid stopping
	// text input that was never started, `active` to avoid starting it for a
	// field that is already gone.
	text_on: bool,
}
ti: Text_Input
// TI_RENAME is the input_type value for clip renaming.
TI_RENAME :: 1
// TI_PLAYHEAD is the input_type for the playhead time viewer: the committed
// text is parsed as a timecode/seconds/frames and the playhead is sought there.
TI_PLAYHEAD :: 2
// TI_CMDLINE is the input_type for the vim-style ":" command line. The prompt
// is display-only for now: no commands execute, Enter records the typed text as
// last_command (the placeholder shown while the buffer is empty).
TI_CMDLINE :: 3
// TI_FINDER is the input_type for the in-app fuzzy file finder (`:open` with no
// argument, and the open/import buttons). The field is the finder's filter;
// Enter descends or opens, Esc closes.
TI_FINDER :: 4

Preview_State :: struct {
	buffer:  [PREVIEW_W * PREVIEW_H * 4]u8,
	playing: bool,
	// last_decoded/requested_playhead are the -1-reset decode staleness markers:
	// any timeline edit resets them (alongside the async decoders) so the next
	// frame decode is judged against "nothing decoded" instead of a stale frame.
	last_decoded:   i64,
	last_requested: i64,
}
preview: Preview_State

// Multi-clip compositing: one Preview_Slot per video clip covering the
// playhead. Each slot owns a Clip_Decoder (with its own RAM frame cache), a
// tightly-packed RGBA buffer, and (lazily) a GPU texture. Slots are reassigned
// by index every frame; when the clip identity changes the decoder is reset and
// reopened.
MAX_PREVIEW_SLOTS :: 8

Preview_Slot :: struct {
	in_use:               bool,
	clip_id:              u64,
	asset_id:             u64,
	path:                 cstring,
	timeline_start_frame: i64,
	source_start_frame:   i64,
	transform_x:          f32,
	transform_y:          f32,
	scale:                f32,
	crop_l:               f32,
	crop_r:               f32,
	crop_t:               f32,
	crop_b:               f32,
	opacity:              f32,
	source_w:             c.int,
	source_h:             c.int,
	dec:                  Clip_Decoder,
	buffer:               [PREVIEW_W * PREVIEW_H * 4]u8,
	// text_hash caches the rendered title for a text clip; the text buffer is
	// only re-rasterized (and re-uploaded) when the clip's name changes or the
	// baked font (48*scale) changes. Text clips have no decoder, so dec is
	// unused for them.
	text_hash:            u64,
	text_font_px:         f32,
	// Tight text bounds (buffer pixels) for a rendered text clip; used to size
	// the clip's image box + UV sampling to the text instead of the full canvas.
	// text_x/text_y are the ink's top-left origin in the buffer, so the sampled
	// region matches where the glyphs actually are (avoids clipping the bottom
	// of descenders). Once clip.scale is baked into the raster, the text fills
	// the whole tight buffer, so text_x/text_y are 0 and text_w/text_h equal the
	// buffer size.
	text_x:               int,
	text_y:               int,
	text_w:               int,
	text_h:               int,
	// is_text marks a slot holding a text clip's tight raster (own text_buf +
	// tight texture) rather than a video decode into the fixed buffer.
	is_text:              bool,
	// is_subtitle marks a subtitle-generator text slot, which is PINNED above
	// every other clip instead of taking its depth from the track walk. A
	// burned-in subtitle that a video covers is unreadable, so this is a
	// deliberate exception to track order -- the export compositor pins its subs
	// pass for the same reason. It is a flag and not a `layer` value because
	// `layer` is also the flash overlay's depth (flash_rec.odin) and must keep
	// meaning "where this clip sits in the stack"; the pinned depth is derived
	// at the draw site (preview_draw_key).
	is_subtitle:          bool,
	// text_buf is the RGBA raster for a text slot, dynamically sized to the
	// estimated buffer bw x bh (which fits the baked text at font 48*scale; the
	// tight ink sub-rect is text_x/text_y/text_w/text_h within it. The matching
	// GPU texture is created at that buffer size (text_tex_w x text_tex_h) and
	// is owned by the slot: it must be released when the slot is freed or reused
	// for a non-text clip.
	text_buf:             []u8,
	// text_base_buf is a small transient buffer used to measure the BASE tight
	// ink dims at font 48 (the logical clip.source_w/h, which stay constant per
	// title and are what the handle-drag scale math multiplies against). Kept on
	// the slot so re-measuring on a rename doesn't reallocate every frame.
	text_base_buf:        []u8,
	// text_tex_w/h are the text raster BUFFER dims (bw x bh) at which the slot's
	// GPU texture is created + uploaded.
	text_tex_w:           c.int,
	text_tex_h:           c.int,
	// text_scratch is the per-glyph bitmap scratch for text rasterization,
	// sized for the current baked font (the fixed shared buffers are too
	// small once clip.scale is baked into a larger font).
	text_scratch:         []u8,
	// text_recreate tells the render loop a text slot's texture must be
	// reallocated at text_tex_w x text_tex_h (buffer size changed or the slot
	// just became text). Only the render loop has the GPU device, so it does the
	// release + recreation.
	text_recreate:        bool,
	tex_dirty:            bool,
	texture:              ^sdl.GPUTexture,
	// prime_sync is set when this slot's decoder was handed over ALREADY
	// POSITIONED for the newly-assigned clip's first frame: either by the warm
	// prewarm (its RAM cache holds the new clip's opening frames) or by the
	// same-asset flush boundary (split halves/duplicates -- the preserved
	// decoder stands one frame back from the cut, so the entering clip's first
	// frame is one step forward). Either way the first decode for the fresh
	// identity runs synchronously from the inherited decoder instead of
	// posting to the async worker (which owns its own cold decoder state and
	// would render the freshly-assigned slot dark or wrong-side until its
	// open+seek lands -- the transition flash). The flag is consumed by that
	// prime and never set again; every later frame decodes async as usual.
	prime_sync:           bool,
	// has_frame is false until this slot has decoded a frame for its current
	// clip identity; draw_preview skips slots without it so a reassigned slot
	// never flashes the previous clip's image while the new decoder opens.
	has_frame:            bool,
	// displayed_frame is the SOURCE-frame whose pixels currently sit in
	// slot.buffer (the frame consume_latest landed, which may trail the
	// requested playhead frame during live playback). displayed_pick is the
	// hash of the proxy pick that frame was decoded through. Together they let
	// update_preview_slots skip the frame when nothing moved: same frame AND
	// same proxy file means the screen is already correct, so re-decoding and
	// re-uploading (a ~4MB GPU transfer per slot) is pure waste.
	displayed_frame:      i64,
	displayed_pick:       u32,
	// layer is the slot's position in this frame's cover-set walk (track order,
	// 0 = topmost clip). Slots keep a stable index per clip identity; the
	// composition order must come from layer, NOT the slot index, so draw_preview
	// sorts by it (drawing the lowest layer last = on top).
	layer:                u8,
}

preview_slots: [MAX_PREVIEW_SLOTS]Preview_Slot

// Preview camera: pan (in preview pixels, relative to the base canvas center)
// and zoom. Pan is the image-viewer bound -- the canvas edge may reach the
// panel edge, never cross it -- so the view roams past the canvas into the
// workspace while the canvas always stays reachable (see clamp_preview_camera).
PREVIEW_CAM_MIN_ZOOM :: 0.25
PREVIEW_CAM_MAX_ZOOM :: 8.0
// Preview_Cam is the preview panel's camera: the canvas pan offset (ox/oy in
// canvas space), the zoom, and the in-flight pan gesture's scroll-capture.
// fit_to_window pins the camera to the contain-fit of the canvas in the panel
// (zoom 1, no pan) so the whole frame is always visible — including after a
// panel resize. Panning or zooming clears it (the user took the camera), and
// the toolbar toggle re-arms it and snaps the camera back (preview_fit_reset).
Preview_Cam :: struct {
	ox:   f32,
	oy:   f32,
	zoom: f32,
	// fit_to_window being a Bin_Cam_Mode would overconstrain the enum (rescues
	// and the import flash both read it to decide the drawn transform), so it
	// stays an explicit bool alongside the numeric camera.
	fit_to_window: bool,
	panning:       bool,
	pan_last_x:    f32,
	pan_last_y:    f32,
}
preview_cam: Preview_Cam = {zoom = 1, fit_to_window = true}

// Timeline_Pan is the timeline panel's pan gesture (middle-drag the track
// lanes): whether panning and the last pointer position for the delta.
Timeline_Pan :: struct {
	panning:  bool,
	last_x:   f32,
	last_y:   f32,
}
timeline_pan: Timeline_Pan

// Scrollbar_Volume is the shared scrollbar-drag state for the side panes that
// scroll by manual childOffset (inspector cards, undo viewer): the offset, and
// a drag's starting grab offset while dragging. The timeline has no vertical
// scrollbar — it scrolls by wheel/pan instead.
Scrollbar_Volume :: struct {
	inspector:    Scrollbar,
	undo_view:    Scrollbar,
}
Scrollbar :: struct {
	offset:   f32,
	dragging: bool,
	grab:     f32,
}
scrollbars: Scrollbar_Volume

// Ui_Notice is the transient on-window notice (e.g. "couldn't load
// subtitles"): text owned by the notice path, shown until until (ms) passes.
Ui_Notice :: struct {
	text:  string,
	until: u64,
}
ui_notice: Ui_Notice

// show_ui_notice displays a transient message centered on the window for the
// given duration (ms), replacing any current notice. It COPIES `text`, so the
// caller keeps ownership — a notice outlives the frame it was raised in.
show_ui_notice :: proc(text: string, duration_ms: u64) {
	if len(ui_notice.text) > 0 {
		delete(ui_notice.text)
	}
	ui_notice.text = strings.clone(text)
	ui_notice.until = monotonic_ms() + duration_ms
}

// UI_NOTICE_MAX bounds a formatted notice. Notices are one-line status
// messages; anything longer is a bug in the message, not a real case.
UI_NOTICE_MAX :: 256

// show_ui_noticef is show_ui_notice for a formatted message. The text is built
// in a stack buffer that dies at return, which is what makes this the right
// form for a call site with arguments: show_ui_notice copies, so passing
// fmt.aprintf(...) left the caller owning a heap string it had to remember to
// free — and every such call site leaked it. Here the caller owns nothing.
//
// A message too long for the buffer is truncated; notices are short by
// construction, so this is a backstop, not a case to handle.
show_ui_noticef :: proc(duration_ms: u64, format: string, args: ..any) {
	buf: [UI_NOTICE_MAX]u8
	show_ui_notice(fmt.bprintf(buf[:], format, ..args), duration_ms)
}

// clear_expired_ui_notice frees the notice string once its time is up.
clear_expired_ui_notice :: proc() {
	if len(ui_notice.text) > 0 && monotonic_ms() >= ui_notice.until {
		delete(ui_notice.text)
		ui_notice.text = ""
	}
}

// Resize/crop handles shown around the selected clip's bounding box.
PREVIEW_HANDLE_SIZE :: f32(9)
// Handle spells out the 8 resize/crop handles. Declaration order IS the
// preview_handles render/hit-test index (TL=0 .. L=7), so it must stay put.
Handle :: enum {
	TL,
	T,
	TR,
	R,
	BR,
	B,
	BL,
	L,
}
// Snap margin for handle drags, in rendered preview pixels; snap_margin turns
// it into project units for the current viewport scale.
SNAP_MARGIN_PX :: f32(5)
Handle_Kind :: enum {
	None,
	Scale,
	Crop,
}
// active_interaction discriminates which pointer gesture is running. Exactly
// one interaction is active at any time; this is the tagged difference from
// the old boolean soup, which could drift into multiple-"true" states. Payload
// globals (clip_move.clip, clip_resize.edge, media_drag_*, ...) belong to whichever
// variant is active and are reset when it clears.
Interaction :: enum {
	None,          // no gesture active (playback-only frame, or track-list scroll)
	Panel_Resize,  // dragging the divider to resize the upper/lower areas
	Playhead_Scrub,
	Clip_Resize,   // dragging a clip's duration edge
	Clip_Move,     // dragging a clip along/onto tracks
	Preview_Move,  // dragging a clip's transform in the preview
	Media_Bin_Drag,
	Handle_Drag,   // dragging a preview resize/crop handle
	Track_Drag,    // dragging a whole track onto an insert gap (reorder)
	Gain_Drag,     // dragging an audio clip's gain knob in the inspector
	Opacity_Drag,  // dragging a clip's opacity slider in the inspector
	Keyframe_Move, // dragging a keyframe diamond horizontally in its lane
}

// Gain knob constants. Gain is edited in decibels; the knob sweeps the
// REAPER-ish item-volume range and the text field clamps to it on commit.
GAIN_MIN_DB :: -48.0
GAIN_MAX_DB :: 48.0
// Gain knob pointer delta: ctrl held gives fine 0.1 dB per pixel; the default
// drag is coarse, one 1 dB step per 10 px of horizontal travel from the
// gesture's start (threshold-quantized).
GAIN_FINE_DB_PER_PX :: 0.1
GAIN_COARSE_DB_PER_10PX :: 1.0
GAIN_COARSE_PX_PER_STEP :: 10

// Gain_Drag is the live gain-knob drag. The resolved clip pointer stays valid
// because the drag grabs the mouse (selection can't change mid-drag) and clip
// arrays don't grow while dragging.
Gain_Drag :: struct {
	clip:     ^Clip,
	start_x:  f32,
	start_db: f32,
}
gain_drag: Gain_Drag

// Opacity_Drag is the live opacity-slider drag. The slider maps the pointer
// across its own rect (absolute, not a delta from the press point), so the
// gesture's rect is captured here at press and reused for every move -- the
// layout can shift under the pointer, the captured rect cannot. start_op
// decides at release whether the gesture actually changed anything.
Opacity_Drag :: struct {
	clip:     ^Clip,
	start_op: f32,
	rect_x:   f32,
	rect_w:   f32,
}
opacity_drag: Opacity_Drag

// Kf_Move is the keyframe-diamond drag. start_frame captures the selected
// key's frame_off at diamond press, so the release-time compare decides whether
// the gesture actually moved it (a no-move click commits nothing — the
// clip-stutter rule). press_x is the pointer x at press (the drag only engages
// once the cursor travels KF_DRAG_THRESHOLD_PX from it, so a click never moves
// the key); pivot is the frame-space offset between the grabbed key and the
// cursor at press (key_frame - cursor_frame), so grabbing a diamond off-center
// keeps that pivot instead of snapping the key's center to the cursor. All
// meaningful only while active_interaction == .Keyframe_Move.
Kf_Move :: struct {
	start_frame: i32,
	press_x:     f32,
	pivot:       f32,
}
kf_move: Kf_Move

// Kf_Dbl_Click records the previous diamond press so a second press on the SAME
// key (same track, clip, lane, and key frame) within KF_DBL_CLICK_NS reads as a
// double-click: the playhead jumps to that key's frame instead of re-arming a
// move. ns == 0 means "no previous press".
Kf_Dbl_Click :: struct {
	ns:    i64,
	track: int,
	clip:  int,
	lane:  int,
	frame: i32,
}
kf_dbl_click: Kf_Dbl_Click

// Handle_Drag is the preview resize/crop-handle drag. handle is the dragged
// corner (Maybe(nil) = none); kind is Scale vs Crop. Every handle_start_* field
// snapshots the pre-gesture box/crop/center so each pointer delta re-derives
// the box from a fixed reference instead of accumulating float error. tx/ty are
// the pre-gesture transform. corner_snapped latches when a corner (diagonal)
// handle has actually snapped flush onto a canvas corner during THIS drag; the
// freeze gate only engages after a snap has happened, so a box that merely
// STARTS flush (e.g. a full-canvas clip whose corner sits on the canvas corner)
// can still be dragged outward to scale freely.
Handle_Drag :: struct {
	handle:          Maybe(Handle),
	kind:            Handle_Kind,
	start_mx:        f32,
	start_my:        f32,
	start_scale:     f32,
	start_crop_l:    f32,
	start_crop_r:    f32,
	start_crop_t:    f32,
	start_crop_b:    f32,
	start_box_w:     f32,
	start_box_h:     f32,
	start_center_x:  f32,
	start_center_y:  f32,
	start_tx:        f32,
	start_ty:        f32,
	corner_snapped:  bool,
}
handle_drag: Handle_Drag = {kind = .None}

// Crop_Pan drives the Alt+Middle crop-pan gesture (crop_viewport_pan): the
// source window slides inside a stationary visible box. Every start_* field is
// the pre-gesture state the release step compares against to decide between
// committing a "Pan clip" node and discarding a no-move press (undo_cancel).
Crop_Pan :: struct {
	active:       bool,
	last_x:       f32,
	last_y:       f32,
	start_scale:  f32,
	start_x:      f32,
	start_y:      f32,
	start_l:      f32,
	start_r:      f32,
	start_t:      f32,
	start_b:      f32,
}
crop_pan: Crop_Pan

Timeline_Frame :: struct {
	active_clip: ^Clip,
	clip_frame:  i64,
}

// ContextMenu is the right-click menu over the timeline. Only one at a time.
// open + target_track >= 0 means a per-track menu is showing; x/y are the
// screen-space position to anchor the floating popup. When the right-click
// landed ON a clip, target_clip_track/index hold it (else -1) so the menu can
// offer clip-specific actions (rename/duplicate/delete/link).
ContextMenu :: struct {
	open:              bool,
	x:                 f32,
	y:                 f32,
	target_track:      int, // -1 = none/between tracks
	frame:             i64, // timeline frame captured at right-click time
	submenu:           bool, // the "Add >" flyout is showing
	submenu_grace:     u8, // frames to keep the flyout after leaving its zone
	target_clip_track: int, // right-click ON a clip; -1 = empty space
	target_clip_index: int, // index within target_clip_track
}
ctx_menu: ContextMenu

// Track_Context_Menu is the right-click menu over a track's NAME GUTTER. It is
// deliberately a separate transient from the timeline ContextMenu rather than
// another row set inside it: that menu's rows act on the clip and the frame
// under the cursor, this one's act on a whole track. Sharing one popup forced
// the row indices to mean different things depending on what was clicked, and
// the track gutter is a different place on screen with a different hit test.
// Only one of the two is ever open (a right-click opens one or the other).
Track_Context_Menu :: struct {
	open:         bool,
	x:            f32,
	y:            f32,
	target_track: int, // -1 = none
}
track_ctx: Track_Context_Menu
