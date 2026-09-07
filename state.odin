package main

import "core:c"
import clay "clay-odin"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Core data model: project, media, timeline, and all top-level mutable app
// state. Interaction/UI code lives in other files; this is the shared state
// they all read and write.
// ---------------------------------------------------------------------------

// nered_trace enables the interactive debug traces ([pb]/[tl]/[ui]/[autoplay]).
// Off by default; set NERED_TRACE=1 to turn on.
nered_trace: bool = false

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720

PREVIEW_W :: 768
PREVIEW_H :: 432

BACKGROUND :: clay.Color{31, 31, 40, 255}          // sumi ink
EDITOR_BG :: clay.Color{36, 36, 46, 255}
// TRACK_GUTTER_BG paints the left track-name column (and its ruler header strip)
// so the name gutter reads as a distinct panel from the clip lane area.
TRACK_GUTTER_BG :: clay.Color{46, 49, 62, 255}
BUTTON :: clay.Color{42, 42, 55, 255}
BUTTON_BORDER :: clay.Color{84, 82, 105, 255}
BUTTON_HOVER :: clay.Color{50, 50, 65, 255}
BUTTON_BORDER_HOVER :: clay.Color{126, 180, 198, 255} // wave blue
AUDIO_CLIP :: clay.Color{76, 58, 78, 255}
SELECT_BORDER :: clay.Color{152, 187, 108, 255}      // spring green
MARKER_COLOR :: clay.Color{226, 190, 101, 255}        // carp yellow
TOOLTIP_BG :: clay.Color{43, 43, 53, 255}
TOOLTIP_TEXT :: clay.Color{220, 215, 198, 255}
RANGE_COLOR :: clay.Color{139, 173, 109, 255}
HANDLE_FILL :: clay.Color{24, 24, 32, 255}
HANDLE_BORDER :: clay.Color{115, 115, 125, 255}
TEXT :: clay.Color{220, 215, 198, 255}
TEXT_INPUT_BG :: clay.Color{15, 17, 22, 255}

RULER_HEIGHT :: f32(30)
RULER_TICK_COLOR :: clay.Color{80, 90, 110, 255}
RULER_LABEL_COLOR :: clay.Color{170, 180, 200, 255}
// Timeline navigation: timeline_view_start is the first visible frame (pan),
// timeline_zoom is horizontal pixels per frame, and timeline_view_top is the
// vertical scroll offset over the track rows (so many tracks stay reachable).
timeline_view_start: f32 = 0
timeline_zoom: f32 = 1
timeline_view_top: f32 = 0

// Snap toggles for the timeline-gutter buttons: dragging a clip onto the
// playhead snaps it there; scrubbing the playhead onto a clip's start/end
// snaps it to the edge. Both default on.
snap_clips_to_playhead: bool = true
snap_playhead_to_clips: bool = true
// snap_center_to_canvas makes a clip dragged/scaled in the preview snap to the
// project canvas center when its visible center comes within the snap margin.
// Defaults on, like the other snap toggles; driven by the "Center" toggle in the
// project info panel.
snap_center_to_canvas: bool = true
SNAP_PIXELS :: 8 // Snap margin (in screen px) while either toggle is on.
TIMELINE_MIN_ZOOM :: f32(0.01)
TIMELINE_MAX_ZOOM :: f32(16)

// timeline_fps returns the timeline's frame rate (the source video's native
// rate, set at import, unless the project fps has been set explicitly). The
// timeline grid is 1 frame == 1 source frame, so the playhead and the render
// canvas must tick at this rate for 1:1 audio/video.
// Falls back to 60 as a safe default before any media is open.
timeline_fps :: proc() -> f64 {
	if PLAYBACK_MAGIC_FPS > 0 {
		return PLAYBACK_MAGIC_FPS
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
//   NERED_PLAYBACK_MAGIC_MS  > 0  ignore measured wall delta; advance the
//                               playhead by exactly this many ms per frame tick
//                               (16.6667 = perfect 60fps cadence, zero jitter).
//   NERED_PLAYBACK_FPS       > 0  override timeline_fps() for the playhead
//                               advance, the mixer's start48/spf mapping, and
//                               the audio producer. 0 = use the imported rate.
PLAYBACK_MAGIC_MS: f64 = 0
PLAYBACK_MAGIC_FPS: f64 = 0

Project :: struct {
	name: string,
	width: c.int,
	height: c.int,
	// Project frame rate. 0 = auto: use the first imported media's native rate.
	// An explicit value overrides the source rate for the timeline grid, the
	// playhead cadence, the audio producer, and the render output.
	frame_rate: f64,
	// Render range: the frames that would actually be exported. Set with the
	// I (start) / O (end) hotkeys. -1 = unset; when both are unset the whole
	// project is the render range. Setting both to the same frame clears it.
	start_frame: i64,
	end_frame: i64,
}
project: Project = {name = "Untitled Project", width = 1920, height = 1080, frame_rate = 0, start_frame = -1, end_frame = -1}
file_info_text: string

// resolution_locked becomes true the moment the project resolution is set
// explicitly (a preset button or the orientation toggle) or inferred from the
// first imported file. Once locked, importing more media never resizes the
// canvas.
resolution_locked: bool

Media_Kind :: enum { Video, Audio, Image, Other, Empty, Text }

// Generator_Kind marks clips that synthesize their output programmatically
// instead of decoding a backing media file (a "generator"). .None = a regular
// file-backed clip.
Generator_Kind :: enum { None, Text }

// Thumbnail size for the media bin grid. Decoded once at import (frame 0 of the
// source, downsclaled from PREVIEW_W x PREVIEW_H into these dims, letterboxed)
// and uploaded to a per-asset GPU texture on first render.
THUMB_W :: 160
THUMB_H :: 90

Media_Asset :: struct {
	id: u64,
	path: cstring,
	kind: Media_Kind,
	metadata: string,
	frame_count: i64,
	// Native source pixel size (video clips land on the timeline at native
	// scale, and the aspect drives fitting).
	src_w: c.int,
	src_h: c.int,
	// audio_streams is the number of audio tracks this media would create when
	// dropped (each stream becomes its own timeline clip on its own lane).
	audio_streams: c.int,
	// audio_frames is the clip length for the audio stream(s), derived from the
	// duration at import (never shorter than the video frame count).
	audio_frames: i64,
	// Thumbnail: CPU RGBA + lazily-created GPU texture (uploaded by the render
	// loop once; thumb_tex_dirty set at import).
	thumb_buf:          [THUMB_W * THUMB_H * 4]u8,
	has_thumb:          bool,
	thumb_tex:          ^sdl.GPUTexture,
	thumb_tex_dirty:    bool,
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
	clip_id: u64,
	asset_id: u64,
	// link_id groups the clips that came from one imported media file (its
	// video clip plus one clip per audio stream). Spent on selection (selecting
	// one selects all), cuts (all covering members split together), moves (the
	// group drags as a unit) and raw deletes. Splits keep the left halves in the
	// original group and mint a fresh link_id for the right halves. 0 = not
	// linked (generator clips, single-stream media, duplicated-track copies).
	link_id: u64,
	path: cstring,
	// name is the clip's editable label. For a Text generator clip it is the
	// title that will be rendered; for file-backed clips it's a display name.
	name: string,
	kind: Media_Kind,
	// generator identifies this clip as a generator (programmatic output).
	// .None for ordinary file-backed clips; .Text for the text generator.
	generator: Generator_Kind,
	stream_index: c.int,
	source_start_frame: i64,
	source_length_frames: i64,
	timeline_start_frame: i64,
	layer: i32,
	// Native source pixel size (0 = unknown). The clip image is drawn keeping
	// this aspect inside its transform box instead of stretching to the canvas,
	// so a video imported into a differently-shaped project is letterboxed.
	source_w: c.int,
	source_h: c.int,
	// Transform: center of the clip's image within the project canvas, in
	// project-resolution pixels. Default (width/2, height/2) centers the clip so
	// it fills the preview at scale 1.
	transform_x: f32,
	transform_y: f32,
	// Scale: uniform (aspect-locked) factor that resizes the on-screen bounding
	// box relative to the project canvas, independent of crop.
	scale: f32,
	// Crop: per-edge trim insets, normalized fractions (0..1) of the scale box.
	// Trimming edits the box edges (revealing background behind the clip) while
	// keeping the source's zoom constant, distinct from scale.
	crop_l: f32,
	crop_r: f32,
	crop_t: f32,
	crop_b: f32,
	// Markers embedded in the clip (chapter markers, etc.), source-relative.
	markers: [dynamic]Clip_Marker,
}

Track :: struct {
	id: u64,
	name: string,
	layer: i32,
	clips: [dynamic]Clip,
}
Playback_State :: enum { Stopped, Playing, Paused, Seeking }
Timeline :: struct { tracks: [dynamic]Track, playhead_frame: i64, playback: Playback_State, frame_rate: f64 }
media_assets: [dynamic]Media_Asset
timeline: Timeline
Playhead :: struct {
	frame: i64,
	playing: bool,
}
playhead: Playhead
playhead_accumulator: f64
// playback_rate is the selected playback rate (Nx real time). Defaults to 1x.
playback_rate: f64 = 1.0
// playback_rate_open tracks whether the playback-rate dropdown is shown.
playback_rate_open: bool
// PLAYBACK_RATES are the selectable playback-rate values offered by the rate
// dropdown, in display order (1x first). Iterating this list is what the
// dropdown draws and the click handler resolves against.
PLAYBACK_RATES :: []f64{1, 1.5, 2, 2.5, 3, 3.5, 4}
// preview_proxy_enabled gates the editing-time proxy: when true (normal
// editing), the live preview decodes low-res all-intra proxies for fluid
// scrubbing. Probes set it false so headless ground-truth checks exercise the
// ORIGINAL decode path (proxy pixels are lossy by design and would show up as
// spurious diffs).
preview_proxy_enabled: bool = true

// async_import_mode gates the background proxy builder (import_bg.odin): live
// editing (default) enqueues proxy encodes on a worker with progress + cancel
// so importing never blocks; probes switch it off to keep the synchronous build
// so the proxy exists on disk the moment import_media returns (the proxy-probe
// asserts that exactly).
async_import_mode: bool = true

// playback_dir is the playback direction: +1 forward, -1 backward. Set by the
// forward/backward jog controls (and h/l keys); playback advances the playhead
// by +dir each step.
playback_dir: int = 1
// playback_boost is a temporary speed boost accumulated by repeatedly pressing
// the forward/backward jog control while already playing in that direction.
// Effective playback rate = playback_rate * (1 + playback_boost). Reset to 0 on
// pause so playback returns to the selected rate.
playback_boost: int = 0
last_tick_ns: sdl.Uint64
// playback_stop_frame is the exclusive end of the active playback run; -1
// means the whole timeline (timeline_duration). Ctrl+Space sets it to the
// project's render range end so playback stops there.
playback_stop_frame: i64 = -1
// dragging the playhead by its ruler bar/handle scrubs to the pointer's frame.
dragging_playhead: bool
// Scrub decimation: while dragging_playhead, exact-frame preview decodes run
// on every SCRUB_DECIMATION-th update (scrub_tick counts update_preview_slots
// calls during a drag) instead of on every mousemove. The last decoded frame
// stays on-screen between throttled decodes; releasing the drag lifts the
// throttle so the final position decodes exactly once.
scrub_tick: i32
SCRUB_DECIMATION :: 4
upper_area_height: f32 = 560
resizing_areas: bool
moving_clip: bool
// resizing_clip + resize_edge track a timeline clip duration-edge drag:
// resize_edge 0 = left (trim/extend head), 1 = right (trim/extend tail).
resizing_clip: bool
resize_edge: int = -1
// _timeline_resize_cursor and _timeline_arrow_cursor are lazily-created SDL
// cursors: the horizontal-resize one is shown while dragging/hovering a clip's
// duration edge, and the arrow is explicitly restored the rest of the time
// (SDL doesn't reliably reset to the default pointer from SetCursor(nil)).
_timeline_resize_cursor: ^sdl.Cursor
_timeline_arrow_cursor: ^sdl.Cursor
clip_drag_offset: f32
drag_clip: ^Clip
// Track the clip was grabbed from and the track its ghost currently hovers.
// -1 = none. Vertical drags (hover onto a different track) are staged as a
// ghost until release; horizontal drags keep live-move behavior on the source
// track.
drag_source_track: int = -1
drag_source_index: int = -1
drag_hover_track: int = -1
drag_ghost_start: i64 = 0
// drag_group_delta is the group's mouse-driven horizontal offset while a LINKED
// group is staged on another track (delta = hovered pointer frame - anchor's
// original start). The vertical ghost follows it so the unit keeps sliding with
// the mouse; on release move_linked_group commits members at m.start + delta.
drag_group_delta: i64 = 0
// drag_group_orig snapshots the original (track, start, length) of every clip
// sharing the dragged/resized clip's link_id, so a linked-group edit applies one
// shared delta to all members (each clamped to its own lane). Invariant: when
// non-empty its FIRST entry is the anchor clip (the one the user grabbed).
Drag_Group_Orig :: struct {
	clip_id: u64,
	track:   int,
	start:   i64,
	length:  i64,
}
drag_group_orig: [dynamic]Drag_Group_Orig

// Media-bin drag state: dragging a bin asset onto the timeline, showing a
// ghost of every lane the media would occupy (one per stream). Distinct from
// clip dragging (timeline clips being moved around).
Media_Lane :: struct {
	// Lane the stream would land on (target_track + stream ordinal).
	track_idx: int,
	// created is true when the lane does not exist yet (a new track that a
	// drop would append).
	created: bool,
	// placed is the clamped non-overlapping start frame for this lane.
	placed:        i64,
	// blocked marks an import drop whose ALIGNED anchor frame overlaps existing
	// content on this lane: the whole drop is refused, so the lane never gets a
	// clamped position that would desync the media's streams.
	blocked:       bool,
	clip_len:      i64,
	kind:          Media_Kind,
	stream_index:  c.int,
	video_thumb_id: u64, // asset id whose thumbnail paints the video lane
	has_video_thumb: bool,
}
dragging_media_from_bin: bool
media_drag_asset_id: u64
media_drag_asset_index: int = -1
media_drag_lanes: [dynamic]Media_Lane
media_drag_target: int = -1
media_drag_frame: i64
media_drag_pick_dx: f32
media_drag_pick_dy: f32
// Current pointer while a bin drag is in flight (the cursor-following drag
// tile needs the live position; the draw pass runs after the event handling).
media_drag_mx: f32
media_drag_my: f32
media_drag_trace_once: bool = true // one-shot [md] ghost geometry dump per drag

// Vertical scroll offset of the media-bin grid (manual childOffset scroll, the
// same pattern TracksSection uses) and its vertical wheel stride.
media_bin_scroll: f32 = 0
MEDIA_BIN_SCROLL_STEP :: 44
TIMELINE_SCROLL_STEP :: 44  // Wheel scroll per notch over the track lanes.

// selected_asset_id is the media-bin item currently highlighted. 0 = none.
selected_asset_id: u64 = 0

// Clip selection (for the clip properties panel). Stored as track/clip indices
// so it isn't invalidated by dynamic-array reallocation; -1 means nothing
// selected.
selected_track: int = -1
selected_index: int = -1

// selected_set holds extra clip ids added to the selection with Shift+click
// (the anchor clip stays tracked by selected_track/selected_index). Used to
// link/unlink a deliberate multi-clip set with U.
selected_set: map[u64]bool

// Transform dragging: moving the selected clip around within the preview.
moving_preview_clip: bool
preview_drag_offset_x: f32
preview_drag_offset_y: f32

// Inline editing of a clip property text field (X or Y). editing_field is 0
// (none), 1 (X) or 2 (Y); edit_chars/edit_len hold the buffer being typed.
editing_field: int
edit_chars: [64]u8
edit_len: int

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
}
ti: Text_Input
// TI_RENAME is the input_type value for clip renaming.
TI_RENAME :: 1

Preview_State :: struct {
	buffer: [PREVIEW_W * PREVIEW_H * 4]u8,
	playing: bool,
}
preview: Preview_State
preview_has_frame: bool
last_decoded_playhead: i64
last_requested_playhead: i64

// Multi-clip compositing: one Preview_Slot per video clip covering the
// playhead. Each slot owns a Clip_Decoder (with its own RAM frame cache), a
// tightly-packed RGBA buffer, and (lazily) a GPU texture. Slots are reassigned
// by index every frame; when the clip identity changes the decoder is reset and
// reopened.
MAX_PREVIEW_SLOTS :: 8

Preview_Slot :: struct {
	in_use:              bool,
	clip_id:             u64,
	asset_id:            u64,
	path:                cstring,
	// preview_path is the file the slot's decoder actually opens for LIVE
	// playback: the low-res all-intra proxy when one exists and is
	// frame-count-valid, else the source (`path`). Resolved once at slot
	// assignment (never per-frame) and passed to the decoder by
	// update_preview_slots. Render and probe paths never use it.
	preview_path:        cstring,
	// preview_path_buf owns the storage preview_path points at (proxy paths
	// are built once per assignment, then keep their bytes for the slot's
	// lifetime instead of re-probing the filesystem every frame).
	preview_path_buf:    [4096]u8,
	timeline_start_frame: i64,
	source_start_frame:  i64,
	transform_x:         f32,
	transform_y:         f32,
	scale:               f32,
	crop_l:              f32,
	crop_r:              f32,
	crop_t:              f32,
	crop_b:              f32,
	source_w:            c.int,
	source_h:            c.int,
	dec:                 Clip_Decoder,
	buffer:              [PREVIEW_W * PREVIEW_H * 4]u8,
	// text_hash caches the rendered title for a text clip; the text buffer is
	// only re-rasterized (and re-uploaded) when the clip's name changes or the
	// baked font (48*scale) changes. Text clips have no decoder, so dec is
	// unused for them.
	text_hash:           u64,
	text_font_px:        f32,
	// Tight text bounds (buffer pixels) for a rendered text clip; used to size
	// the clip's image box + UV sampling to the text instead of the full canvas.
	// text_x/text_y are the ink's top-left origin in the buffer, so the sampled
	// region matches where the glyphs actually are (avoids clipping the bottom
	// of descenders). Once clip.scale is baked into the raster, the text fills
	// the whole tight buffer, so text_x/text_y are 0 and text_w/text_h equal the
	// buffer size.
	text_x:              int,
	text_y:              int,
	text_w:              int,
	text_h:              int,
	// is_text marks a slot holding a text clip's tight raster (own text_buf +
	// tight texture) rather than a video decode into the fixed buffer.
	is_text:             bool,
	// text_buf is the RGBA raster for a text slot, dynamically sized to the
	// estimated buffer bw x bh (which fits the baked text at font 48*scale; the
	// tight ink sub-rect is text_x/text_y/text_w/text_h within it. The matching
	// GPU texture is created at that buffer size (text_tex_w x text_tex_h) and
	// is owned by the slot: it must be released when the slot is freed or reused
	// for a non-text clip.
	text_buf:            []u8,
	// text_base_buf is a small transient buffer used to measure the BASE tight
	// ink dims at font 48 (the logical clip.source_w/h, which stay constant per
	// title and are what the handle-drag scale math multiplies against). Kept on
	// the slot so re-measuring on a rename doesn't reallocate every frame.
	text_base_buf:       []u8,
	// text_tex_w/h are the text raster BUFFER dims (bw x bh) at which the slot's
	// GPU texture is created + uploaded.
	text_tex_w:          c.int,
	text_tex_h:          c.int,
	// text_scratch is the per-glyph bitmap scratch for text rasterization,
	// sized for the current baked font (the shared text_clip_scratch is too
	// small once clip.scale is baked into a larger font).
	text_scratch:        []u8,
	// text_recreate tells the render loop a text slot's texture must be
	// reallocated at text_tex_w x text_tex_h (buffer size changed or the slot
	// just became text). Only the render loop has the GPU device, so it does the
	// release + recreation.
	text_recreate:       bool,
	tex_dirty:           bool,
	texture:             ^sdl.GPUTexture,
	// Per-slot decode frontier, not the global one: the global gate rewinds
	// wrongly after a clip is moved to an earlier point (playhead sits at/below
	// the old purchased frontier, decode is skipped, and the slot freezes on the
	// pre-move content). Each slot only caps how far AHEAD of itself it decodes.
	frontier:            i64,
	have_frontier:       bool,
	// prime_from_warm is set when this slot's decoder was handed over by the
	// warm prewarm (its RAM cache already holds the new clip's first frames).
	// On that frame the front slot decodes synchronously from the warm cache
	// instead of posting to the async worker (which only owns a cold decoder
	// and would render the freshly-assigned slot dark until its open+seek
	// lands -- the transition flash). The flag is consumed by that prime and
	// never set again; every later frame decodes async as usual.
	prime_from_warm:     bool,
	// has_frame is false until this slot has decoded a frame for its current
	// clip identity; draw_preview skips slots without it so a reassigned slot
	// never flashes the previous clip's image while the new decoder opens.
	has_frame:           bool,
}

preview_slots: [MAX_PREVIEW_SLOTS]Preview_Slot

// preview_frontier is the highest timeline frame whose pixels were actually
// decoded into a preview slot. During playback the decoder always requests the
// frame right after the frontier (never rewinds), so the image advances
// best-effort at whatever decode sustains while the playhead stays on the wall
// clock.
preview_frontier: i64
ui_playhead_frame: i64 // published playhead frame for the audio producer (atomic)
// audio_dev_frame is the content frame the sound device has actually consumed
// (everything the producer pushed minus what is still queued); published every
// feed pass so the preview HUD can show the audio clock next to the video one.
audio_dev_frame: i64

// Preview camera: pan (in preview pixels, relative to the base canvas center)
// and zoom. Pan/zoom is clamped so the view never travels more than one preview
// axis from the origin, keeping the composited content near the window center.
PREVIEW_CAM_MIN_ZOOM :: 0.25
PREVIEW_CAM_MAX_ZOOM :: 8.0
preview_cam_ox: f32
preview_cam_oy: f32
preview_cam_zoom: f32 = 1.0
panning_preview: bool
pan_last_x: f32
pan_last_y: f32
panning_timeline: bool
timeline_pan_last_x: f32
timeline_pan_last_y: f32

// Resize/crop handles shown around the selected clip's bounding box.
PREVIEW_HANDLE_SIZE :: f32(9)
// Handle indices: 0 TL, 1 T, 2 TR, 3 R, 4 BR, 5 B, 6 BL, 7 L.
Handle_Kind :: enum { None, Scale, Crop }
dragging_handle: int = -1
handle_kind: Handle_Kind = .None
handle_start_mx: f32
handle_start_my: f32
handle_start_scale: f32
handle_start_crop_l: f32
handle_start_crop_r: f32
handle_start_crop_t: f32
handle_start_crop_b: f32
handle_start_box_w: f32
handle_start_box_h: f32
handle_start_center_x: f32
handle_start_center_y: f32
handle_start_tx: f32
handle_start_ty: f32

Timeline_Frame :: struct {
	active_clip: ^Clip,
	clip_frame: i64,
}

// ContextMenu is the right-click menu over the timeline. Only one at a time.
// open + target_track >= 0 means a per-track menu is showing; x/y are the
// screen-space position to anchor the floating popup.
ContextMenu :: struct {
	open:         bool,
	x:            f32,
	y:            f32,
	target_track: int, // -1 = none/between tracks
	frame:        i64, // timeline frame captured at right-click time
	submenu:      bool, // the "Add >" flyout is showing
}
ctx_menu: ContextMenu
