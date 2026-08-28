package main

import "core:c"
import clay "clay-odin"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Core data model: project, media, timeline, and all top-level mutable app
// state. Interaction/UI code lives in other files; this is the shared state
// they all read and write.
// ---------------------------------------------------------------------------

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720

PREVIEW_W :: 768
PREVIEW_H :: 432

BACKGROUND :: clay.Color{10, 11, 14, 255}
EDITOR_BG :: clay.Color{15, 17, 21, 255}
BUTTON :: clay.Color{20, 22, 27, 255}
BUTTON_BORDER :: clay.Color{27, 48, 76, 255}
BUTTON_HOVER :: clay.Color{15, 18, 25, 255}
BUTTON_BORDER_HOVER :: clay.Color{64, 170, 194, 255}
AUDIO_CLIP :: clay.Color{58, 44, 66, 255}
SELECT_BORDER :: clay.Color{120, 220, 120, 255}
MARKER_COLOR :: clay.Color{255, 205, 70, 255}
TOOLTIP_BG :: clay.Color{28, 35, 45, 255}
TOOLTIP_TEXT :: clay.Color{240, 244, 248, 255}
RANGE_COLOR :: clay.Color{130, 220, 150, 255}
HANDLE_FILL :: clay.Color{30, 30, 30, 255}
HANDLE_BORDER :: clay.Color{200, 200, 200, 255}
TEXT :: clay.Color{255, 255, 255, 255}

RULER_HEIGHT :: f32(30)
RULER_TICK_COLOR :: clay.Color{80, 90, 110, 255}
RULER_LABEL_COLOR :: clay.Color{170, 180, 200, 255}
// Timeline navigation: timeline_view_start is the first visible frame (pan),
// timeline_zoom is horizontal pixels per frame.
timeline_view_start: f32 = 0
timeline_zoom: f32 = 1
TIMELINE_MIN_ZOOM :: f32(0.05)
TIMELINE_MAX_ZOOM :: f32(16)

// timeline_fps returns the timeline's frame rate (the source video's native
// rate, set at import). The timeline grid is 1 frame == 1 source frame, so the
// playhead and the render canvas must tick at this rate for 1:1 audio/video.
// Falls back to 60 as a safe default before any media is open.
timeline_fps :: proc() -> f64 {
	if timeline.frame_rate > 0 {
		return timeline.frame_rate
	}
	return 60
}

Project :: struct {
	name: string,
	width: c.int,
	height: c.int,
	// Render range: the frames that would actually be exported. Set with the
	// I (start) / O (end) hotkeys. -1 = unset; when both are unset the whole
	// project is the render range. Setting both to the same frame clears it.
	start_frame: i64,
	end_frame: i64,
}
project: Project = {name = "Untitled Project", width = 1920, height = 1080, start_frame = -1, end_frame = -1}
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
last_tick_ns: sdl.Uint64
// dragging the playhead by its ruler bar/handle scrubs to the pointer's frame.
dragging_playhead: bool
upper_area_height: f32 = 560
resizing_areas: bool
moving_clip: bool
clip_drag_offset: f32
drag_clip: ^Clip

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
	asset_id:            u64,
	path:                cstring,
	timeline_start_frame: i64,
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
}

preview_slots: [MAX_PREVIEW_SLOTS]Preview_Slot

// preview_frontier is the highest timeline frame whose pixels were actually
// decoded into a preview slot. The playhead is capped at frontier + 2 during
// playback so the pipeline can never fall behind itself (which would force
// frame re-seeks and collapse the loop); the audio producer in turn chases the
// playhead, so the whole preview runs at whatever pace decode sustains.
preview_frontier: i64
ui_playhead_frame: i64 // published playhead frame for the audio producer (atomic)

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
