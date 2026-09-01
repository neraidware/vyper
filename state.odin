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

RULER_HEIGHT :: f32(30)
RULER_TICK_COLOR :: clay.Color{80, 90, 110, 255}
RULER_LABEL_COLOR :: clay.Color{170, 180, 200, 255}
// Timeline navigation: timeline_view_start is the first visible frame (pan),
// timeline_zoom is horizontal pixels per frame, and timeline_view_top is the
// vertical scroll offset over the track rows (so many tracks stay reachable).
timeline_view_start: f32 = 0
timeline_zoom: f32 = 1
timeline_view_top: f32 = 0
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

Media_Kind :: enum { Video, Audio, Image, Other }
Media_Asset :: struct { id: u64, path: cstring, kind: Media_Kind, metadata: string, frame_count: i64 }

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
	path: cstring,
	kind: Media_Kind,
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
// playback_rate scales how fast the playhead advances during playback
// (pretend 1.0 = 1x real time). 1.5/2/2.5/3/3.5/4 speed the playhead up;
// 0 = "Auto" (currently identical to 1x — the rate dropdown's Auto option does
// nothing for now, per spec). Audio pacing at rates != 1.0 is a follow-up.
// playback_rate is the selected playback rate (Nx real time). Defaults to 1x.
playback_rate: f64 = 1.0
// playback_rate_open tracks whether the playback-rate dropdown is shown.
playback_rate_open: bool
// PLAYBACK_RATES are the selectable playback-rate values offered by the rate
// dropdown, in display order (1x first). Iterating this list is what the
// dropdown draws and the click handler resolves against.
PLAYBACK_RATES :: []f64{1, 1.5, 2, 2.5, 3, 3.5, 4}
last_tick_ns: sdl.Uint64
// playback_stop_frame is the exclusive end of the active playback run; -1
// means the whole timeline (timeline_duration). Ctrl+Space sets it to the
// project's render range end so playback stops there.
playback_stop_frame: i64 = -1
// dragging the playhead by its ruler bar/handle scrubs to the pointer's frame.
dragging_playhead: bool
upper_area_height: f32 = 560
resizing_areas: bool
moving_clip: bool
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

// Clip selection (for the clip properties panel). Stored as track/clip indices
// so it isn't invalidated by dynamic-array reallocation; -1 means nothing
// selected.
selected_track: int = -1
selected_index: int = -1

// Transform dragging: moving the selected clip around within the preview.
moving_preview_clip: bool
preview_drag_offset_x: f32
preview_drag_offset_y: f32

// Inline editing of a clip property text field (X or Y). editing_field is 0
// (none), 1 (X) or 2 (Y); edit_chars/edit_len hold the buffer being typed.
editing_field: int
edit_chars: [64]u8
edit_len: int

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
	tex_dirty:           bool,
	texture:             ^sdl.GPUTexture,
	// Per-slot decode frontier, not the global one: the global gate rewinds
	// wrongly after a clip is moved to an earlier point (playhead sits at/below
	// the old purchased frontier, decode is skipped, and the slot freezes on the
	// pre-move content). Each slot only caps how far AHEAD of itself it decodes.
	frontier:            i64,
	have_frontier:       bool,
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
