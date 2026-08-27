package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import posix "core:sys/posix"
import clay "clay-odin"
import sdl "vendor:sdl3"
import stb "vendor:stb/truetype"

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
HANDLE_FILL :: clay.Color{30, 30, 30, 255}
HANDLE_BORDER :: clay.Color{200, 200, 200, 255}
TEXT :: clay.Color{255, 255, 255, 255}

Project :: struct {
	name: string,
	width: c.int,
	height: c.int,
}
project: Project = {name = "Untitled Project", width = 1920, height = 1080}
file_info_text: string

Media_Kind :: enum { Video, Audio, Image, Other }
Media_Asset :: struct { id: u64, path: cstring, kind: Media_Kind, metadata: string, frame_count: i64 }
Clip :: struct {
	asset_id: u64,
	path: cstring,
	kind: Media_Kind,
	stream_index: c.int,
	source_start_frame: i64,
	source_length_frames: i64,
	timeline_start_frame: i64,
	layer: i32,
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
}
clip_timeline_end :: proc(clip: Clip) -> i64 { return clip.timeline_start_frame + clip.source_length_frames }

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
edit_begin :: proc(field: int, value: f32) {
	editing_field = field
	text := field == 3 ? fmt.aprintf("%.2f", value) : fmt.aprintf("%.0f", value)
	edit_len = min(len(text), len(edit_chars))
	copy(edit_chars[:edit_len], text[:edit_len])
}

edit_cancel :: proc() {
	editing_field = 0
	edit_len = 0
}

edit_commit :: proc() {
	defer edit_cancel()
	if sel, ok := transformable_selected(); ok {
		value, ok := strconv.parse_f32(string(edit_chars[:edit_len]))
		if !ok {
			return
		}
		if editing_field == 1 {
			sel.transform_x = value
		} else if editing_field == 2 {
			sel.transform_y = value
		} else if editing_field == 3 {
			sel.scale = max(value, 0.01)
		}
	}
}

edit_append :: proc(ch: u8) {
	if edit_len < len(edit_chars) {
		edit_chars[edit_len] = ch
		edit_len += 1
	}
}

edit_backspace :: proc() {
	if edit_len > 0 {
		edit_len -= 1
	}
}

// selected_clip returns the currently selected track+clip and true, or
// (nil, nil, false) when nothing is selected.
selected_clip :: proc() -> (^Track, ^Clip, bool) {
	if selected_track >= 0 && selected_track < len(timeline.tracks) {
		tr := &timeline.tracks[selected_track]
		if selected_index >= 0 && selected_index < len(tr.clips) {
			return tr, &tr.clips[selected_index], true
		}
	}
	return nil, nil, false
}

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
	dec:                 Clip_Decoder,
	buffer:              [PREVIEW_W * PREVIEW_H * 4]u8,
	tex_dirty:           bool,
	texture:             ^sdl.GPUTexture,
}

preview_slots: [MAX_PREVIEW_SLOTS]Preview_Slot

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

RectVertexUniforms :: struct {
	bounds: [4]f32,
	viewport: [2]f32,
	_padding: [2]f32,
}

RectFragmentUniforms :: struct {
	color: [4]f32,
	shape: [4]f32,
}

TextVertexUniforms :: struct {
	bounds:   [4]f32,
	viewport: [2]f32,
	_padding: [2]f32,
	uv:       [4]f32,
}

TextFragmentUniforms :: struct {
	color: [4]f32,
}

Font_Atlas :: struct {
	texture: ^sdl.GPUTexture,
	sampler: ^sdl.GPUSampler,
	chars:   [95]stb.bakedchar,
}

GPU_Renderer :: struct {
	device: ^sdl.GPUDevice,
	pipeline: ^sdl.GPUGraphicsPipeline,
	text_pipeline: ^sdl.GPUGraphicsPipeline,
	preview_pipeline: ^sdl.GPUGraphicsPipeline,
	font: Font_Atlas,
	preview_textures: [MAX_PREVIEW_SLOTS]^sdl.GPUTexture,
	preview_sampler: ^sdl.GPUSampler,
	viewport: [2]f32,
}

rounded_rect_vertex_spirv := #load("shaders/rounded_rect.vert.spv")
rounded_rect_fragment_spirv := #load("shaders/rounded_rect.frag.spv")
text_vertex_spirv := #load("shaders/text.vert.spv")
text_fragment_spirv := #load("shaders/text.frag.spv")
preview_fragment_spirv := #load("shaders/preview.frag.spv")
font_data: []byte

load_font_data :: proc() -> bool {
	path := string(system_monospace_font())
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil || len(data) == 0 {
		fmt.println("Could not load font:", path)
		return false
	}
	font_data = data
	return true
}

system_font_path: [1024]byte

system_monospace_font :: proc() -> cstring {
	// Ask Fontconfig for configured monospace family instead of hard-coding font.
	pipe := posix.popen("fc-match -f '%{file}' monospace", "r")
	if pipe != nil {
		posix.fgets(raw_data(system_font_path[:]), len(system_font_path), pipe)
		posix.pclose(pipe)
		for i in 0..<len(system_font_path) {
			if system_font_path[i] == '\n' {
				system_font_path[i] = 0
				break
			}
		}
		if system_font_path[0] != 0 {
			return cstring(raw_data(system_font_path[:]))
		}
	}
	return "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
}

probe_media :: proc(path: cstring) -> string {
	path_string := string(path)
	quoted_path, _ := strings.replace_all(path_string, "'", "'\\''", context.temp_allocator)
	command := fmt.aprintf("ffprobe -v error -show_entries format=format_name,duration,size:stream=codec_name,nb_frames,avg_frame_rate -of default=noprint_wrappers=1 '%s' 2>/dev/null", quoted_path)
	pipe := posix.popen(strings.clone_to_cstring(command, context.temp_allocator), "r")
	if pipe == nil {
		return "Length: unavailable\nFormat: unavailable\nCodecs: unavailable\nSize: unavailable"
	}
	buffer: [4096]byte
	output := ""
	for posix.fgets(raw_data(buffer[:]), len(buffer), pipe) != nil {
		line, _ := strings.clone_from_cstring(cstring(raw_data(buffer[:])), context.temp_allocator)
		output = fmt.aprintf("%s%s", output, line)
	}
	posix.pclose(pipe)
	return strings.trim_space(output)
}

media_frame_count :: proc(metadata: string) -> i64 {
	duration: f64
	frame_rate: f64
	for line in strings.split_lines(metadata) {
		if strings.has_prefix(line, "nb_frames=") {
			value, ok := strconv.parse_i64(line[len("nb_frames="):])
			if ok {
				return value
			}
		}
		if strings.has_prefix(line, "duration=") {
			duration, _ = strconv.parse_f64(line[len("duration="):])
		}
		if strings.has_prefix(line, "avg_frame_rate=") {
			rate := line[len("avg_frame_rate="):]
			parts := strings.split(rate, "/")
			if len(parts) == 2 {
				numerator, nok := strconv.parse_f64(parts[0])
				denominator, dok := strconv.parse_f64(parts[1])
				if nok && dok && denominator > 0 {
					frame_rate = numerator / denominator
				}
			}
		}
	}
	if duration > 0 && frame_rate > 0 {
		return i64(duration * frame_rate)
	}
	return 1
}

// project_preview_size returns the preview element's width/height so its aspect
// matches the project resolution, fitting within the fixed operational
// PREVIEW_W x PREVIEW_H bounds (no distortion; non-matching aspects letterbox).
project_preview_size :: proc() -> (w, h: f32) {
	aspect := f32(project.width) / f32(project.height)
	pw := f32(PREVIEW_W)
	ph := f32(PREVIEW_H)
	if aspect >= 1 {
		w = pw
		h = pw / aspect
		if h > ph {
			h = ph
			w = ph * aspect
		}
	} else {
		h = ph
		w = ph * aspect
		if w > pw {
			w = pw
			h = pw / aspect
		}
	}
	return
}

// path_basename returns everything after the last '/' (or the whole string).
path_basename :: proc(path: cstring) -> string {
	p := string(path)
	for i := len(p) - 1; i >= 0; i -= 1 {
		if p[i] == '/' {
			return p[i + 1:]
		}
	}
	return p
}

_next_asset_id: u64

// next_asset_id hands out a stable, unique id for a media bin entry.
next_asset_id :: proc() -> u64 {
	_next_asset_id += 1
	return _next_asset_id
}

// import_media loads a media file: probes it, adds a Media_Asset (reference) to
// the bin, and auto-creates the timeline tracks/clips that reference it.
import_media :: proc(path: cstring) {
	file_info_text = probe_media(path)
	frame_count := media_frame_count(file_info_text)
	probe := probe_streams(path)
	audio_frames := i64(probe.duration_sec * timeline.frame_rate)
	if audio_frames < frame_count {
		audio_frames = frame_count
	}

	asset_id := next_asset_id()
	append(&media_assets, Media_Asset{
		id = asset_id,
		path = path,
		kind = probe.has_video ? .Video : (probe.has_audio ? .Audio : .Other),
		metadata = file_info_text,
		frame_count = frame_count,
	})

	clear(&timeline.tracks)
	track_n := 1
	if probe.has_video {
		track := Track{name = fmt.aprintf("Track %d", track_n)}
		append(&track.clips, Clip{
			asset_id = asset_id,
			path = path,
			kind = .Video,
			stream_index = 0,
			source_start_frame = 0,
			source_length_frames = frame_count,
			timeline_start_frame = 0,
			transform_x = f32(project.width) / 2,
			transform_y = f32(project.height) / 2,
			scale = 1,
			crop_l = 0,
			crop_r = 0,
			crop_t = 0,
			crop_b = 0,
		})
		append(&timeline.tracks, track)
		track_n += 1
	}
	for a := 0; a < probe.audio_streams; a += 1 {
		track := Track{name = fmt.aprintf("Track %d", track_n)}
		append(&track.clips, Clip{
			asset_id = asset_id,
			path = path,
			kind = .Audio,
			stream_index = c.int(a),
			source_start_frame = 0,
			source_length_frames = audio_frames,
			timeline_start_frame = 0,
		})
		append(&timeline.tracks, track)
		track_n += 1
	}

	timeline.playhead_frame = 0
	playhead.frame = 0
	playhead.playing = false
	playhead_accumulator = 0
	preview.playing = false
	last_decoded_playhead = -1
	async_dec_reset()
	last_requested_playhead = -1
	audio_reset_for_load()
}

timeline_frame_at :: proc(frame: i64) -> Timeline_Frame {
	for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
		candidate_track := &timeline.tracks[track_idx]
		for i := 0; i < len(candidate_track.clips); i += 1 {
			candidate := &candidate_track.clips[i]
			if candidate.kind != .Video {
				continue
			}
			if frame >= candidate.timeline_start_frame && frame < candidate.timeline_start_frame + candidate.source_length_frames {
				return {active_clip = candidate, clip_frame = candidate.source_start_frame + frame - candidate.timeline_start_frame}
			}
		}
	}
	return {}
}

// update_preview_slots walks every video clip covering the current playhead and
// ensures each has a Preview_Slot with its frame decoded (using the slot's RAM
// frame cache). Slots are reassigned by index each frame; when a slot's clip
// identity changes its decoder is reset and reopened. Returns true if any
// frame changed (caller re-uploads textures).
update_preview_slots :: proc() -> bool {
	changed := false
	next_slot := 0
	for track_idx := 0; track_idx < len(timeline.tracks) && next_slot < MAX_PREVIEW_SLOTS; track_idx += 1 {
		track := &timeline.tracks[track_idx]
		for i := 0; i < len(track.clips) && next_slot < MAX_PREVIEW_SLOTS; i += 1 {
			clip := &track.clips[i]
			if clip.kind != .Video {
				continue
			}
			frame := playhead.frame
			if frame < clip.timeline_start_frame || frame >= clip.timeline_start_frame + clip.source_length_frames {
				continue
			}
			slot := &preview_slots[next_slot]
			next_slot += 1
			if !slot.in_use || slot.asset_id != clip.asset_id || slot.timeline_start_frame != clip.timeline_start_frame {
				if slot.in_use {
					clip_decoder_reset(&slot.dec)
				}
				slot^ = {}
				slot.in_use = true
				slot.asset_id = clip.asset_id
				slot.path = clip.path
				slot.timeline_start_frame = clip.timeline_start_frame
				slot.tex_dirty = true
			}
			slot.transform_x = clip.transform_x
			slot.transform_y = clip.transform_y
			slot.scale = clip.scale
			slot.crop_l = clip.crop_l
			slot.crop_r = clip.crop_r
			slot.crop_t = clip.crop_t
			slot.crop_b = clip.crop_b
			clip_frame := clip.source_start_frame + frame - clip.timeline_start_frame
			if decode_clip_frame_sync(&slot.dec, slot.path, clip_frame, slot.buffer[:]) {
				slot.tex_dirty = true
				changed = true
			}
		}
	}
	for i := next_slot; i < MAX_PREVIEW_SLOTS; i += 1 {
		if preview_slots[i].in_use {
			clip_decoder_reset(&preview_slots[i].dec)
			preview_slots[i].in_use = false
		}
	}
	return changed
}

// find_preview_slot returns the slot and Clip* for a given clip identity
// (asset_id + timeline_start_frame), or (nil, nil, false).
find_preview_slot :: proc(asset_id: u64, timeline_start_frame: i64) -> (^Preview_Slot, ^Clip, bool) {
	for i := 0; i < len(timeline.tracks); i += 1 {
		track := &timeline.tracks[i]
		for j := 0; j < len(track.clips); j += 1 {
			clip := &track.clips[j]
			if clip.asset_id == asset_id && clip.timeline_start_frame == timeline_start_frame {
				for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
					if preview_slots[s].in_use && preview_slots[s].asset_id == asset_id && preview_slots[s].timeline_start_frame == timeline_start_frame {
						return &preview_slots[s], clip, true
					}
				}
			}
		}
	}
	return nil, nil, false
}

open_file_picker :: proc() -> cstring {
	return portal_open_file_picker()
}

measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	user_data: rawptr,
) -> clay.Dimensions {
	// Temporary font metrics keep layout independent from renderer resources.
	return {width = f32(text.length) * f32(config.fontSize) * 0.55, height = f32(config.fontSize)}
}

clay_error :: proc "c" (data: clay.ErrorData) {
}

build_page :: proc(width, height: c.int) -> clay.ClayArray(clay.RenderCommand) {
	clay.SetLayoutDimensions({f32(width), f32(height)})
	clay.BeginLayout()

	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			layoutDirection = .TopToBottom,
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = BACKGROUND,
	}) {
		if clay.UI()({
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				layoutDirection = .TopToBottom,
				childGap = 0,
			},
		}) {
			if clay.UI(clay.ID("EditorUpperArea"))({
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(upper_area_height)},
					padding = clay.PaddingAll(16),
					childAlignment = {x = .Center, y = .Center},
					layoutDirection = .LeftToRight,
					childGap = 24,
				},
				backgroundColor = EDITOR_BG,
				cornerRadius = clay.CornerRadiusAll(10),
			}) {
				if clay.UI(clay.ID("LeftPanel"))({
					layout = {
						sizing = {width = clay.SizingFixed(320), height = clay.SizingGrow({})},
						layoutDirection = .TopToBottom,
						childGap = 16,
					},
				}) {
					if clay.UI(clay.ID("ProjectInfo"))({
						layout = {
							sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
							padding = clay.PaddingAll(16),
							childGap = 8,
							layoutDirection = .TopToBottom,
						},
						backgroundColor = BUTTON,
						border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
						cornerRadius = clay.CornerRadiusAll(8),
					}) {
						clay.Text("Project", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = 13})
						clay.Text(fmt.aprintf("Name: %s", project.name), clay.TextElementConfig{textColor = TEXT, fontSize = 15})
						clay.Text(fmt.aprintf("Resolution: %dx%d", project.width, project.height), clay.TextElementConfig{textColor = TEXT, fontSize = 15})
					}
					if clay.UI(clay.ID("MediaBin"))({
						layout = {
							sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
							padding = clay.PaddingAll(16),
							childGap = 8,
							layoutDirection = .TopToBottom,
						},
						backgroundColor = BUTTON,
						border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
						cornerRadius = clay.CornerRadiusAll(8),
					}) {
						clay.Text("Media Bin", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = 13})
						if len(media_assets) == 0 {
							clay.Text("No media imported", clay.TextElementConfig{textColor = TEXT, fontSize = 14})
						} else {
							for asset in media_assets {
								label := fmt.aprintf("%s  [%s]  %d frames", path_basename(asset.path), kind_name(asset.kind), asset.frame_count)
								clay.Text(label, clay.TextElementConfig{textColor = TEXT, fontSize = 14})
							}
						}
					}
					if len(file_info_text) > 0 {
						if clay.UI(clay.ID("FileInfo"))({
							layout = {
								sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
								padding = clay.PaddingAll(16),
								childGap = 8,
								layoutDirection = .TopToBottom,
							},
							backgroundColor = BUTTON,
							border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
							cornerRadius = clay.CornerRadiusAll(8),
						}) {
							for line in strings.split_lines(file_info_text) {
								clay.Text(line, clay.TextElementConfig{textColor = TEXT, fontSize = 14})
							}
						}
					}
				}
				if clay.UI(clay.ID("PreviewColumn"))({
					layout = {sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})}, layoutDirection = .TopToBottom, childGap = 12},
					border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
					cornerRadius = clay.CornerRadiusAll(6),
				}) {
					pw, ph := project_preview_size()
					if clay.UI(clay.ID("Preview"))({
						layout = {sizing = {width = clay.SizingFixed(pw), height = clay.SizingFixed(ph)}},
						image = {imageData = nil},
					}) {
					}
					if clay.UI(clay.ID("ActionsArea"))({
						layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, childAlignment = {x = .Center, y = .Top}},
					}) {
						if clay.UI(clay.ID("PlayPause"))({
							layout = {sizing = {width = clay.SizingFixed(96), height = clay.SizingFixed(28)}, childAlignment = {x = .Center, y = .Center}},
							backgroundColor = BUTTON,
							border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
							cornerRadius = clay.CornerRadiusAll(4),
						}) {
							if playhead.playing {
								clay.Text("Pause", clay.TextElementConfig{textColor = TEXT, fontSize = 14})
							} else {
								clay.Text("Play", clay.TextElementConfig{textColor = TEXT, fontSize = 14})
							}
						}
					}
				}
				if clay.UI(clay.ID("ClipProperties"))({
					layout = {
						sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
						padding = clay.PaddingAll(16),
						childGap = 8,
						layoutDirection = .TopToBottom,
					},
					backgroundColor = BUTTON,
					border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
					cornerRadius = clay.CornerRadiusAll(8),
				}) {
					clay.Text("Clip Properties", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = 13})
					if tr, cl, ok := selected_clip(); ok {
						clay.Text(fmt.aprintf("Track: %s", tr.name), clay.TextElementConfig{textColor = TEXT, fontSize = 15})
						clay.Text(fmt.aprintf("File: %s", path_basename(cl.path)), clay.TextElementConfig{textColor = TEXT, fontSize = 15})
						if cl.kind != .Audio {
							x_val := fmt.aprintf("%.0f", cl.transform_x)
							if editing_field == 1 {
								x_val = string(edit_chars[:edit_len])
							}
							if clay.UI(clay.ID("PropFieldX"))({
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, padding = clay.PaddingAll(8)},
								backgroundColor = BUTTON,
								border = {color = editing_field == 1 ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(2)},
								cornerRadius = clay.CornerRadiusAll(6),
							}) {
								clay.Text(fmt.aprintf("X: %s", x_val), clay.TextElementConfig{textColor = editing_field == 1 ? BUTTON_BORDER_HOVER : TEXT, fontSize = 15})
							}
							y_val := fmt.aprintf("%.0f", cl.transform_y)
							if editing_field == 2 {
								y_val = string(edit_chars[:edit_len])
							}
							if clay.UI(clay.ID("PropFieldY"))({
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, padding = clay.PaddingAll(8)},
								backgroundColor = BUTTON,
								border = {color = editing_field == 2 ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(2)},
								cornerRadius = clay.CornerRadiusAll(6),
							}) {
								clay.Text(fmt.aprintf("Y: %s", y_val), clay.TextElementConfig{textColor = editing_field == 2 ? BUTTON_BORDER_HOVER : TEXT, fontSize = 15})
							}
							scl_val := fmt.aprintf("%.2f", cl.scale)
							if editing_field == 3 {
								scl_val = string(edit_chars[:edit_len])
							}
							if clay.UI(clay.ID("PropFieldS"))({
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, padding = clay.PaddingAll(8)},
								backgroundColor = BUTTON,
								border = {color = editing_field == 3 ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(2)},
								cornerRadius = clay.CornerRadiusAll(6),
							}) {
								clay.Text(fmt.aprintf("Scale: %s", scl_val), clay.TextElementConfig{textColor = editing_field == 3 ? BUTTON_BORDER_HOVER : TEXT, fontSize = 15})
							}
							clay.Text(fmt.aprintf("Crop: L %.0f%% R %.0f%% T %.0f%% B %.0f%%", cl.crop_l * 100, cl.crop_r * 100, cl.crop_t * 100, cl.crop_b * 100), clay.TextElementConfig{textColor = TEXT, fontSize = 13})
						}
					} else {
						clay.Text("No clip selected", clay.TextElementConfig{textColor = TEXT, fontSize = 14})
					}
				}
			}
			if clay.UI(clay.ID("EditorDivider"))({
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(16)},
					childAlignment = {x = .Center, y = .Center},
				},
			}) {
				if clay.UI(clay.ID("DividerHandle"))({
					layout = {sizing = {width = clay.SizingFixed(50), height = clay.SizingFixed(5)}},
					backgroundColor = BUTTON_BORDER,
					cornerRadius = clay.CornerRadiusAll(3),
				}) {}
			}
			if clay.UI(clay.ID("EditorLowerArea"))({
				layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, padding = clay.PaddingAll(16)},
				backgroundColor = EDITOR_BG,
				cornerRadius = clay.CornerRadiusAll(10),
			}) {
				if len(timeline.tracks) == 0 {
					// Empty timeline: show the import button.
					if clay.UI(clay.ID("EmptyTimeline"))({
						layout = {
							sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
							childAlignment = {x = .Center, y = .Center},
						},
					}) {
						if clay.UI(clay.ID("OpenFileButton"))({
							layout = {
								sizing = {width = clay.SizingFixed(200), height = clay.SizingFixed(56)},
								padding = clay.PaddingAll(12),
								childAlignment = {x = .Center, y = .Center},
							},
							backgroundColor = BUTTON,
							cornerRadius = clay.CornerRadiusAll(10),
							border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
						}) {
							clay.Text("Open file", clay.TextElementConfig{textColor = TEXT, fontSize = 18, textAlignment = .Center})
						}
					}
				} else {
					if clay.UI(clay.ID("ClipTimeline"))({
						layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, padding = clay.PaddingAll(12), layoutDirection = .LeftToRight, childGap = 16},
						backgroundColor = BUTTON,
						cornerRadius = clay.CornerRadiusAll(8),
						border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
					}) {
						if clay.UI(clay.ID("TracksSection"))({
							layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, layoutDirection = .TopToBottom, childGap = 0},
						}) {
							for track_idx := 0; track_idx <= len(timeline.tracks); track_idx += 1 {
								// Gap indent where a new track can be inserted.
								gap_id := clay.ID("TrackGap", u32(track_idx))
								gap_hovered := clay.PointerOver(gap_id)
								if clay.UI(gap_id)({
									layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(18)}, childAlignment = {x = .Left, y = .Center}, padding = clay.Padding{left = 4}},
									backgroundColor = gap_hovered ? clay.Color{36, 60, 84, 255} : EDITOR_BG,
									cornerRadius = clay.CornerRadiusAll(3),
								}) {
									if gap_hovered {
										clay.Text("+ Add track", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = 14})
									}
								}
								if track_idx >= len(timeline.tracks) {
									break
								}
								track := &timeline.tracks[track_idx]
								if clay.UI(clay.ID("TrackRow", u32(track_idx)))({
									layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, layoutDirection = .LeftToRight, childGap = 16},
								}) {
									if clay.UI(clay.ID("TrackName", u32(track_idx)))({
										layout = {sizing = {width = clay.SizingFixed(140), height = clay.SizingFit({})}, layoutDirection = .TopToBottom, childGap = 4, childAlignment = {x = .Left, y = .Top}},
									}) {
										clay.Text(track.name, clay.TextElementConfig{textColor = TEXT, fontSize = 18})
										if clay.UI(clay.ID("DuplicateTrack", u32(track_idx)))({
											layout = {sizing = {width = clay.SizingFixed(30), height = clay.SizingFixed(34)}, childAlignment = {x = .Center, y = .Center}},
											backgroundColor = BUTTON,
											border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
											cornerRadius = clay.CornerRadiusAll(4),
										}) {
											clay.Text("+\nv", clay.TextElementConfig{textColor = TEXT, fontSize = 13})
										}
									}
									if clay.UI(clay.ID("ClipsSection", u32(track_idx)))({
										layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, layoutDirection = .LeftToRight, childGap = 16},
										clip = {horizontal = true, vertical = true},
									}) {
										for timeline_clip, index in track.clips {
											if timeline_clip.timeline_start_frame > 0 {
												if clay.UI(clay.ID("ClipOffset", u32(track_idx * 1000 + index)))({
													layout = {sizing = {width = clay.SizingFixed(f32(timeline_clip.timeline_start_frame)), height = clay.SizingGrow({})}},
												}) {}
											}
											clip_width := f32(max(timeline_clip.source_length_frames, 1))
											clip_color := BUTTON
											clip_border := BUTTON_BORDER
											clip_border_w: u16 = 2
											clip_label := "Clip"
											if timeline_clip.kind == .Audio {
												clip_color = AUDIO_CLIP
												clip_label = "Audio"
											}
											if selected_track == track_idx && selected_index == index {
												clip_border = BUTTON_BORDER_HOVER
												clip_border_w = 3
											}
											if clay.UI(clay.ID("TimelineClip", u32(track_idx * 1000 + index)))({
												layout = {sizing = {width = clay.SizingFixed(clip_width), height = clay.SizingFixed(56)}, padding = clay.PaddingAll(8)},
												backgroundColor = clip_color,
												cornerRadius = clay.CornerRadiusAll(6),
												border = {color = clip_border, width = clay.BorderOutside(clip_border_w)},
											}) {
												clay.Text(clip_label, clay.TextElementConfig{textColor = TEXT, fontSize = 18})
											}
										}
									}
								}
							}
						}
						if clay.UI(clay.ID("Playhead"))({
							layout = {
								sizing = {width = clay.SizingFixed(10), height = clay.SizingFixed(10)},
								childAlignment = {x = .Center, y = .Center},
							},
							backgroundColor = BUTTON_BORDER_HOVER,
							cornerRadius = clay.CornerRadiusAll(5),
							floating = {offset = {f32(playhead.frame), 0}, attachTo = .ElementWithId, parentId = clay.ID("ClipsSection", 0).id, attachment = {element = .CenterTop, parent = .LeftTop}},
						}) {}
						}
					}
				}
			}
		}

	return clay.EndLayout(0)
}

// kind_name returns a short label for a media kind (bin display).
kind_name :: proc(kind: Media_Kind) -> string {
#partial switch kind {
case .Video:
	return "video"
case .Audio:
	return "audio"
case .Image:
	return "image"
case:
	return "other"
}
}

// next_track_name returns "Track N" with N one greater than the largest "Track N"
// number already present, so names stay unique.
next_track_name :: proc() -> string {
	next := len(timeline.tracks) + 1
	for existing in timeline.tracks {
		if len(existing.name) > len("Track ") {
			n, ok := strconv.parse_int(existing.name[len("Track "):], 10)
			if ok && n >= next {
				next = n + 1
			}
		}
	}
	return fmt.aprintf("Track %d", next)
}

// insert_track inserts a new empty track at the given index (0-based) in the
// timeline track list — e.g. between existing tracks.
insert_track :: proc(index: int) {
	track := Track{name = next_track_name()}
	inject_at_elem(&timeline.tracks, index, track)
}

// duplicate_track inserts a copy of the track at index directly below the
// original (index + 1), deep-copying every clip into a new dynamic array so the
// two tracks are fully independent.
duplicate_track :: proc(index: int) {
	src := &timeline.tracks[index]
	new_track := Track{
		name = next_track_name(),
		layer = src.layer,
		clips = make([dynamic]Clip, 0, len(src.clips)),
	}
	for c in src.clips {
		append(&new_track.clips, c)
	}
	inject_at_elem(&timeline.tracks, index + 1, new_track)
}

render_clay :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, commands: clay.ClayArray(clay.RenderCommand)) {
	array := commands
	for i in 0..<commands.length {
		command := clay.RenderCommandArray_Get(&array, i)
		bounds := command.boundingBox

		#partial switch command.commandType {
		case .Rectangle:
			config := command.renderData.rectangle
			color := config.backgroundColor
			if command.id == clay.ID("OpenFileButton").id && clay.PointerOver(clay.ID("OpenFileButton")) {
				color = BUTTON_HOVER
			}
			render_sdf_rect(renderer, command_buffer, pass, bounds, color, config.cornerRadius.topLeft, 0)
		case .Border:
			config := command.renderData.border
			color := config.color
			if command.id == clay.ID("OpenFileButton").id && clay.PointerOver(clay.ID("OpenFileButton")) {
				color = BUTTON_BORDER_HOVER
			}
			render_sdf_rect(renderer, command_buffer, pass, bounds, color, config.cornerRadius.topLeft, f32(config.width.left))
		case .Text:
			render_text(renderer, command_buffer, pass, bounds, command.renderData.text)
		}
	}
}

render_text :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, bounds: clay.BoundingBox, text: clay.TextRenderData) {
	if renderer.font.texture == nil || renderer.text_pipeline == nil {
		return
	}

	// Clay's text command gives us the laid-out origin. stb's baked quad uses a
	// baseline origin, so start one font height below that origin.
	scale := f32(text.fontSize) / 32.0
	x: f32 = 0
	baseline: f32 = 32
	line_height := f32(text.lineHeight)
	if line_height <= 0 {
		line_height = f32(text.fontSize)
	}
	sdl.BindGPUGraphicsPipeline(pass, renderer.text_pipeline)
	binding := sdl.GPUTextureSamplerBinding{texture = renderer.font.texture, sampler = renderer.font.sampler}
	sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
	for i in 0..<text.stringContents.length {
		code := u8(text.stringContents.chars[i])
		if code == '\n' {
			x = 0
			baseline += line_height / scale
			continue
		}
		if code < 32 || code > 126 {
			continue
		}
		quad: stb.aligned_quad
		stb.GetBakedQuad(&renderer.font.chars[0], 512, 512, c.int(code - 32), &x, &baseline, &quad, false)
		quad_bounds := clay.BoundingBox{x = bounds.x + quad.x0 * scale, y = bounds.y + quad.y0 * scale, width = (quad.x1 - quad.x0) * scale, height = (quad.y1 - quad.y0) * scale}
		vertex_uniforms := TextVertexUniforms{
			bounds = {quad_bounds.x, quad_bounds.y, quad_bounds.width, quad_bounds.height},
			viewport = renderer.viewport,
			_padding = {},
			uv = {quad.s0, quad.t0, quad.s1, quad.t1},
		}
		color := text.textColor
		fragment_uniforms := TextFragmentUniforms{color = {f32(color[0]) / 255, f32(color[1]) / 255, f32(color[2]) / 255, f32(color[3]) / 255}}
		sdl.PushGPUVertexUniformData(command_buffer, 0, &vertex_uniforms, sdl.Uint32(size_of(vertex_uniforms)))
		sdl.PushGPUFragmentUniformData(command_buffer, 0, &fragment_uniforms, sdl.Uint32(size_of(fragment_uniforms)))
		sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
		x += f32(text.letterSpacing) / scale
	}
}

render_sdf_rect :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, bounds: clay.BoundingBox, color: clay.Color, radius, border: f32) {
	vertex_uniforms := RectVertexUniforms{
		bounds = {bounds.x, bounds.y, bounds.width, bounds.height},
		viewport = renderer.viewport,
	}
	fragment_uniforms := RectFragmentUniforms{
		color = {f32(color[0]) / 255, f32(color[1]) / 255, f32(color[2]) / 255, f32(color[3]) / 255},
		shape = {bounds.width, bounds.height, radius, border},
	}
	sdl.PushGPUVertexUniformData(command_buffer, 0, &vertex_uniforms, sdl.Uint32(size_of(vertex_uniforms)))
	sdl.PushGPUFragmentUniformData(command_buffer, 0, &fragment_uniforms, sdl.Uint32(size_of(fragment_uniforms)))
	sdl.BindGPUGraphicsPipeline(pass, renderer.pipeline)
	sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
}

// upload_preview_slot copies tightly-packed RGBA pixels into a slot's GPU
// texture using a transfer buffer + copy pass on the given command buffer.
upload_preview_slot :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, slot: ^Preview_Slot) {
	if slot.texture == nil {
		return
	}
	transfer := sdl.CreateGPUTransferBuffer(renderer.device, sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = PREVIEW_W * PREVIEW_H * 4})
	if transfer == nil {
		return
	}
	defer sdl.ReleaseGPUTransferBuffer(renderer.device, transfer)
	mapped := sdl.MapGPUTransferBuffer(renderer.device, transfer, false)
	if mapped == nil {
		return
	}
	dst := ([^]u8)(mapped)[:PREVIEW_W * PREVIEW_H * 4]
	copy(dst, slot.buffer[:])
	sdl.UnmapGPUTransferBuffer(renderer.device, transfer)
	copy_pass := sdl.BeginGPUCopyPass(command_buffer)
	source := sdl.GPUTextureTransferInfo{transfer_buffer = transfer, pixels_per_row = PREVIEW_W, rows_per_layer = PREVIEW_H}
	destination := sdl.GPUTextureRegion{texture = slot.texture, w = PREVIEW_W, h = PREVIEW_H, d = 1}
	sdl.UploadToGPUTexture(copy_pass, source, destination, false)
	sdl.EndGPUCopyPass(copy_pass)
	slot.tex_dirty = false
}

// release_preview_textures releases a renderer's per-slot preview textures.
release_preview_textures :: proc(device: ^sdl.GPUDevice, texs: []^sdl.GPUTexture) {
	for t in texs {
		sdl.ReleaseGPUTexture(device, t)
	}
}

// preview_canvas returns the pixel-space rect of the project canvas fitted
// (letterboxed, aspect preserved) inside the given preview bounds. The project
// resolution maps linearly onto this rect: project (0..W, 0..H) -> rect.
preview_canvas :: proc(bounds: clay.BoundingBox) -> clay.BoundingBox {
	pw := f32(project.width)
	ph := f32(project.height)
	if pw <= 0 || ph <= 0 {
		pw = f32(PREVIEW_W)
		ph = f32(PREVIEW_H)
	}
	scale: f32
	if bounds.width > 0 && bounds.height > 0 {
		scale = min(bounds.width / pw, bounds.height / ph)
	} else {
		scale = 1
	}
	w := pw * scale
	h := ph * scale
	return {
		x = bounds.x + (bounds.width - w) / 2,
		y = bounds.y + (bounds.height - h) / 2,
		width = w,
		height = h,
	}
}

// clamp_preview_camera keeps the pan within one preview axis of the origin and
// the zoom within its min/max range.
clamp_preview_camera :: proc(canvas: clay.BoundingBox) {
	preview_cam_zoom = clamp(preview_cam_zoom, PREVIEW_CAM_MIN_ZOOM, PREVIEW_CAM_MAX_ZOOM)
	preview_cam_ox = clamp(preview_cam_ox, -canvas.width, canvas.width)
	preview_cam_oy = clamp(preview_cam_oy, -canvas.height, canvas.height)
}

// preview_view applies the camera (pan + zoom, centered on the base canvas) to
// produce the on-screen canvas rect used for drawing and hit-testing.
preview_view :: proc(canvas: clay.BoundingBox) -> clay.BoundingBox {
	clamp_preview_camera(canvas)
	w := canvas.width * preview_cam_zoom
	h := canvas.height * preview_cam_zoom
	cx := canvas.x + canvas.width / 2 + preview_cam_ox
	cy := canvas.y + canvas.height / 2 + preview_cam_oy
	return {x = cx - w / 2, y = cy - h / 2, width = w, height = h}
}

// project_to_pixel converts a point in project-resolution coordinates to pixels
// within the (camera-transformed) canvas rect.
project_to_pixel :: proc(canvas: clay.BoundingBox, px, py: f32) -> (f32, f32) {
	v := preview_view(canvas)
	cx := v.x + (px / f32(project.width)) * v.width
	cy := v.y + (py / f32(project.height)) * v.height
	return cx, cy
}

// pixel_to_project converts a pixel position within the (camera-transformed)
// canvas rect back to project-resolution coordinates, clamped to the project
// bounds.
pixel_to_project :: proc(canvas: clay.BoundingBox, x, y: f32) -> (f32, f32) {
	v := preview_view(canvas)
	px := (x - v.x) / v.width * f32(project.width)
	py := (y - v.y) / v.height * f32(project.height)
	px = clamp(px, 0, f32(project.width))
	py = clamp(py, 0, f32(project.height))
	return px, py
}

// pixel_to_project_unclamped is pixel_to_project without the clamp, used for
// handle-drag math that must permit the pointer to leave the project bounds.
pixel_to_project_unclamped :: proc(canvas: clay.BoundingBox, x, y: f32) -> (f32, f32) {
	v := preview_view(canvas)
	px := (x - v.x) / v.width * f32(project.width)
	py := (y - v.y) / v.height * f32(project.height)
	return px, py
}

// snap_margin converts a desired snap margin in rendered (preview) pixels into
// project-resolution units for the current viewport scale.
snap_margin :: proc(canvas: clay.BoundingBox, preview_px: f32) -> f32 {
	v := preview_view(canvas)
	if v.width <= 0 || v.height <= 0 {
		return preview_px
	}
	return preview_px * f32(project.width) / v.width
}

// snap_transform snaps the clip's visible (cropped) box edges to the project
// canvas borders when they come within the given margin (project units). Force
// insets are normalized, so the visible half-extent from the center is
// (0.5 - crop) * (project axis) * scale.
snap_transform :: proc(clip: ^Clip, margin: f32) {
	PW := f32(project.width)
	PH := f32(project.height)
	d_l := (0.5 - clip.crop_l) * PW * clip.scale
	d_r := (0.5 - clip.crop_r) * PW * clip.scale
	left := clip.transform_x - d_l
	right := clip.transform_x + d_r
	// Left edge to x=0, otherwise right edge to x=project.width.
	if abs(left) <= margin {
		clip.transform_x = d_l
	} else if abs(right - PW) <= margin {
		clip.transform_x = PW - d_r
	}
	d_t := (0.5 - clip.crop_t) * PH * clip.scale
	d_b := (0.5 - clip.crop_b) * PH * clip.scale
	top := clip.transform_y - d_t
	bottom := clip.transform_y + d_b
	// Top edge to y=0, otherwise bottom edge to y=project.height.
	if abs(top) <= margin {
		clip.transform_y = d_t
	} else if abs(bottom - PH) <= margin {
		clip.transform_y = PH - d_b
	}
}

// clip_image_bounds returns the pixel-space rect the clip occupies in the
// preview: the crop-adjusted (visible) box. Crop insets are normalized
// fractions (0..1) of the scale box, so the visible box is the scale box
// anchored at its top-left corner and trimmed by the per-edge crop insets. The
// opposite edge stays fixed when cropping a single edge (crop is per-edge, not
// centered). The cropped source fills it, so it matches the output.
clip_image_bounds :: proc(canvas: clay.BoundingBox, clip: ^Clip) -> clay.BoundingBox {
	v := preview_view(canvas)
	cx, cy := project_to_pixel(canvas, clip.transform_x, clip.transform_y)
	sw := v.width * clip.scale
	sh := v.height * clip.scale
	x := cx - sw / 2 + clip.crop_l * sw
	y := cy - sh / 2 + clip.crop_t * sh
	return {x = x, y = y, width = sw * (1 - clip.crop_l - clip.crop_r), height = sh * (1 - clip.crop_t - clip.crop_b)}
}

// transformable_clip reports whether the clip currently selected is one with a
// (video/image) transform that can be previewed/moved.
transformable_selected :: proc() -> (^Clip, bool) {
	_, cl, ok := selected_clip()
	if !ok || cl.kind == .Audio {
		return nil, false
	}
	return cl, true
}

// preview_handles returns the 8 resize/crop handle rects around a clip's box in
// screen pixels: 0 TL, 1 T, 2 TR, 3 R, 4 BR, 5 B, 6 BL, 7 L.
preview_handles :: proc(b: clay.BoundingBox) -> [8]clay.BoundingBox {
	cx := b.x + b.width / 2
	cy := b.y + b.height / 2
	s := PREVIEW_HANDLE_SIZE
	return {
		{x = b.x - s / 2, y = b.y - s / 2, width = s, height = s},
		{x = cx - s / 2, y = b.y - s / 2, width = s, height = s},
		{x = b.x + b.width - s / 2, y = b.y - s / 2, width = s, height = s},
		{x = b.x + b.width - s / 2, y = cy - s / 2, width = s, height = s},
		{x = b.x + b.width - s / 2, y = b.y + b.height - s / 2, width = s, height = s},
		{x = cx - s / 2, y = b.y + b.height - s / 2, width = s, height = s},
		{x = b.x - s / 2, y = b.y + b.height - s / 2, width = s, height = s},
		{x = b.x - s / 2, y = cy - s / 2, width = s, height = s},
	}
}

// preview_handle_at returns the index of the handle rect containing the point,
// or -1.
preview_handle_at :: proc(b: clay.BoundingBox, mx, my: f32) -> int {
	handles := preview_handles(b)
	for i in 0 ..< 8 {
		h := handles[i]
		if mx >= h.x && mx <= h.x + h.width && my >= h.y && my <= h.y + h.height {
			return i
		}
	}
	return -1
}

// begin_handle_drag captures the state needed to scale/crop the selected clip
// from a handle drag. crop=true makes the drag adjust the source crop instead
// of the scale.
begin_handle_drag :: proc(clip: ^Clip, canvas: clay.BoundingBox, handle: int, mx, my: f32, crop: bool) {
	dragging_handle = handle
	handle_kind = crop ? .Crop : .Scale
	handle_start_mx = mx
	handle_start_my = my
	handle_start_scale = clip.scale
	handle_start_crop_l = clip.crop_l
	handle_start_crop_r = clip.crop_r
	handle_start_crop_t = clip.crop_t
	handle_start_crop_b = clip.crop_b
	cx, cy := project_to_pixel(canvas, clip.transform_x, clip.transform_y)
	handle_start_center_x = cx
	handle_start_center_y = cy
	handle_start_tx = clip.transform_x
	handle_start_ty = clip.transform_y
	ib := clip_image_bounds(canvas, clip)
	handle_start_box_w = ib.width
	handle_start_box_h = ib.height
}

// update_handle_drag applies the current pointer to the active handle drag,
// scaling the clip (default) or trimming its source crop (crop mode). Scaling
// pins the handle opposite the one being dragged: the opposite edge/corner
// stays fixed while the dragged handle tracks the pointer.
update_handle_drag :: proc(clip: ^Clip, canvas: clay.BoundingBox, mx, my: f32) {
	if dragging_handle < 0 || clip == nil {
		return
	}
	cx := handle_start_center_x
	cy := handle_start_center_y
	bw := handle_start_box_w
	bh := handle_start_box_h

	switch handle_kind {
	case .None:
		return
	case .Scale:
		// Uniform (aspect-locked) scale, independent of crop. The visible
		// (cropped) box scales by a uniform factor k about the pinned opposite
		// visible edge/corner while crop fractions stay constant. The new
		// transform is derived by anchoring the pinned visible edge with its
		// scaled offset (0.5 - crop)*axis*new_scale, so scaling after a crop is
		// stable. All in project units with the pointer unclamped.
		PW := f32(project.width)
		PH := f32(project.height)
		scale0 := handle_start_scale
		cl := handle_start_crop_l
		cr := handle_start_crop_r
		ct := handle_start_crop_t
		cb := handle_start_crop_b
		dl0 := (0.5 - cl) * PW * scale0
		dr0 := (0.5 - cr) * PW * scale0
		dt0 := (0.5 - ct) * PH * scale0
		db0 := (0.5 - cb) * PH * scale0
		vl0 := handle_start_tx - dl0
		vr0 := handle_start_tx + dr0
		vt0 := handle_start_ty - dt0
		vb0 := handle_start_ty + db0
		w0 := (1 - cl - cr) * PW * scale0
		h0 := (1 - ct - cb) * PH * scale0
		pmx, pmy := pixel_to_project_unclamped(canvas, mx, my)

		k: f32 = 1
		switch dragging_handle {
		case 1: // top: pin bottom
			k = (vb0 - pmy) / h0
		case 5: // bottom: pin top
			k = (pmy - vt0) / h0
		case 7: // left: pin right
			k = (vr0 - pmx) / w0
		case 3: // right: pin left
			k = (pmx - vl0) / w0
		case 0, 2, 4, 6: // corners: pin opposite corner, dominant axis
			kx: f32 = 1
			ky: f32 = 1
			switch dragging_handle {
			case 0: // TL pins BR
				kx = (vr0 - pmx) / w0
				ky = (vb0 - pmy) / h0
			case 2: // TR pins BL
				kx = (pmx - vl0) / w0
				ky = (vb0 - pmy) / h0
			case 4: // BR pins TL
				kx = (pmx - vl0) / w0
				ky = (pmy - vt0) / h0
			case 6: // BL pins TR
				kx = (vr0 - pmx) / w0
				ky = (pmy - vt0) / h0
			}
			if abs(handle_start_my-cy)/bh > abs(handle_start_mx-cx)/bw {
				k = ky
			} else {
				k = kx
			}
		}

		k = max(k, 0.01)
		s := scale0 * k
		dl := (0.5 - cl) * PW * s
		dr := (0.5 - cr) * PW * s
		dt := (0.5 - ct) * PH * s
		db := (0.5 - cb) * PH * s
		tx := handle_start_tx
		ty := handle_start_ty
		switch dragging_handle {
		case 1: // top pins bottom
			ty = vb0 - db
		case 5: // bottom pins top
			ty = vt0 + dt
		case 7: // left pins right
			tx = vr0 - dr
		case 3: // right pins left
			tx = vl0 + dl
		case 0: // TL pins BR
			tx = vr0 - dr
			ty = vb0 - db
		case 2: // TR pins BL
			tx = vl0 + dl
			ty = vb0 - db
		case 4: // BR pins TL
			tx = vl0 + dl
			ty = vt0 + dt
		case 6: // BL pins TR
			tx = vr0 - dr
			ty = vt0 + dt
		}

		clip.scale = clamp(s, 0.05, 100.0)
		clip.transform_x = tx
		clip.transform_y = ty
		// Snap the resulting visible box edges to the project borders.
		snap_transform(clip, snap_margin(canvas, 5))
	case .Crop:
		// Crop trims the visible box: dragging one edge moves that edge (and the
		// adjacent edges for a corner) while the opposite visible edge stays
		// fixed, revealing background. Insets are stored as normalized fractions
		// of the scale box, and the scale/transform are not touched, so cropping
		// only crops. Trim-only: each edge can only move toward the opposite edge.
		PW := f32(project.width)
		PH := f32(project.height)
		scale0 := handle_start_scale
		out_w := PW * scale0
		out_h := PH * scale0
		OX_L := handle_start_tx - out_w / 2
		OX_R := handle_start_tx + out_w / 2
		OX_T := handle_start_ty - out_h / 2
		OX_B := handle_start_ty + out_h / 2
		cl := handle_start_crop_l
		cr := handle_start_crop_r
		ct := handle_start_crop_t
		cb := handle_start_crop_b
		vl0 := OX_L + cl * out_w
		vr0 := OX_R - cr * out_w
		vt0 := OX_T + ct * out_h
		vb0 := OX_B - cb * out_h
		minsz := f32(0.5)
		pmx, pmy := pixel_to_project_unclamped(canvas, mx, my)
		switch dragging_handle {
		case 1: // top: keep bottom edge fixed
			clip.crop_t = (clamp(pmy, vt0, vb0 - minsz) - OX_T) / out_h
		case 5: // bottom: keep top edge fixed
			clip.crop_b = (OX_B - clamp(pmy, vt0 + minsz, vb0)) / out_h
		case 7: // left: keep right edge fixed
			clip.crop_l = (clamp(pmx, vl0, vr0 - minsz) - OX_L) / out_w
		case 3: // right: keep left edge fixed
			clip.crop_r = (OX_R - clamp(pmx, vl0 + minsz, vr0)) / out_w
		case 0: // TL: keep right+bottom edges fixed
			clip.crop_l = (clamp(pmx, vl0, vr0 - minsz) - OX_L) / out_w
			clip.crop_t = (clamp(pmy, vt0, vb0 - minsz) - OX_T) / out_h
		case 2: // TR: keep left+bottom edges fixed
			clip.crop_r = (OX_R - clamp(pmx, vl0 + minsz, vr0)) / out_w
			clip.crop_t = (clamp(pmy, vt0, vb0 - minsz) - OX_T) / out_h
		case 4: // BR: keep left+top edges fixed
			clip.crop_r = (OX_R - clamp(pmx, vl0 + minsz, vr0)) / out_w
			clip.crop_b = (OX_B - clamp(pmy, vt0 + minsz, vb0)) / out_h
		case 6: // BL: keep right+top edges fixed
			clip.crop_l = (clamp(pmx, vl0, vr0 - minsz) - OX_L) / out_w
			clip.crop_b = (OX_B - clamp(pmy, vt0 + minsz, vb0)) / out_h
		}
	}
}


// draw_preview draws the active video clip's frame in the given bounds, placed
// according to the clip's transform (fills the project canvas, centered at its
// x/y), then overlays a selection border around the currently-selected clip's
// image rect. The decode buffer is fixed 16:9 (PREVIEW_W x PREVIEW_H) and is
// sampled with a full UV quad.
draw_preview :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, bounds: clay.BoundingBox) {
	if renderer.preview_pipeline == nil {
		return
	}
	// Clip everything (zoomed content, background, border) to the preview window
	// so zooming/panning behaves like a scrollable viewport.
	scissor := sdl.Rect{c.int(bounds.x), c.int(bounds.y), c.int(bounds.width), c.int(bounds.height)}
	sdl.SetGPUScissor(pass, scissor)
	defer sdl.SetGPUScissor(pass, sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)})

	canvas := preview_canvas(bounds)
	// The composited/canvas area has a completely black background.
	view := preview_view(canvas)
	render_sdf_rect(renderer, command_buffer, pass, view, clay.Color{0, 0, 0, 255}, 0, 0)

	// Paint every clip covering the playhead with the top track on top. Slots
	// are assigned in track order (track 0 = top = slot 0), so draw slots in
	// reverse so the top track's clip is drawn last and appears on top.
	for i := MAX_PREVIEW_SLOTS - 1; i >= 0; i -= 1 {
		slot := &preview_slots[i]
		if !slot.in_use || slot.texture == nil {
			continue
		}
		cb := clip_image_bounds(canvas, &Clip{
			transform_x = slot.transform_x,
			transform_y = slot.transform_y,
			scale = slot.scale,
			crop_l = slot.crop_l,
			crop_r = slot.crop_r,
			crop_t = slot.crop_t,
			crop_b = slot.crop_b,
		})
		// The cropped source sub-rect (normalized UV) equals the crop fractions.
		u0 := slot.crop_l
		u1 := 1 - slot.crop_r
		v0 := slot.crop_t
		v1 := 1 - slot.crop_b
		vertex_uniforms := TextVertexUniforms{
			bounds = {cb.x, cb.y, cb.width, cb.height},
			viewport = renderer.viewport,
			_padding = {},
			uv = {u0, v0, u1, v1},
		}
		sdl.BindGPUGraphicsPipeline(pass, renderer.preview_pipeline)
		binding := sdl.GPUTextureSamplerBinding{texture = slot.texture, sampler = renderer.preview_sampler}
		sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
		sdl.PushGPUVertexUniformData(command_buffer, 0, &vertex_uniforms, sdl.Uint32(size_of(vertex_uniforms)))
		sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
	}
	// Draw a border box around the currently-selected clip's image rect.
	if selected_clip, ok := transformable_selected(); ok {
		sb := clip_image_bounds(canvas, selected_clip)
		render_sdf_rect(renderer, command_buffer, pass, sb, SELECT_BORDER, 0, 3)
		// Draw the resize/crop handles on the box (only when not editing a field).
		for h in preview_handles(sb) {
			render_sdf_rect(renderer, command_buffer, pass, h, HANDLE_FILL, 0, 1)
			render_sdf_rect(renderer, command_buffer, pass, h, HANDLE_BORDER, 0.5, 1)
		}
	}
}

create_gpu_renderer :: proc(device: ^sdl.GPUDevice, format: sdl.GPUTextureFormat, width, height: c.int) -> (GPU_Renderer, bool) {
	vertex_info := sdl.GPUShaderCreateInfo{
		code_size = uint(len(rounded_rect_vertex_spirv)), code = raw_data(rounded_rect_vertex_spirv),
		entrypoint = "main", format = {.SPIRV}, stage = .VERTEX, num_uniform_buffers = 1,
	}
	fragment_info := sdl.GPUShaderCreateInfo{
		code_size = uint(len(rounded_rect_fragment_spirv)), code = raw_data(rounded_rect_fragment_spirv),
		entrypoint = "main", format = {.SPIRV}, stage = .FRAGMENT, num_uniform_buffers = 1,
	}
	vertex_shader := sdl.CreateGPUShader(device, vertex_info)
	fragment_shader := sdl.CreateGPUShader(device, fragment_info)
	if vertex_shader == nil || fragment_shader == nil {
		fmt.println("GPU shader creation failed:", sdl.GetError())
		return {}, false
	}
	defer sdl.ReleaseGPUShader(device, vertex_shader)
	defer sdl.ReleaseGPUShader(device, fragment_shader)
	blend := sdl.GPUColorTargetBlendState{
		src_color_blendfactor = .SRC_ALPHA, dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA, color_blend_op = .ADD,
		src_alpha_blendfactor = .ONE, dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA, alpha_blend_op = .ADD,
		color_write_mask = {.R, .G, .B, .A}, enable_blend = true, enable_color_write_mask = true,
	}
	target := sdl.GPUColorTargetDescription{format = format, blend_state = blend}
	pipeline_info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader = vertex_shader, fragment_shader = fragment_shader,
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE, enable_depth_clip = true},
		multisample_state = {sample_count = ._1},
		target_info = {color_target_descriptions = &target, num_color_targets = 1},
	}
	pipeline := sdl.CreateGPUGraphicsPipeline(device, pipeline_info)
	if pipeline == nil {
		fmt.println("GPU pipeline creation failed:", sdl.GetError())
		return {}, false
	}
	text_vertex_info := sdl.GPUShaderCreateInfo{code_size = uint(len(text_vertex_spirv)), code = raw_data(text_vertex_spirv), entrypoint = "main", format = {.SPIRV}, stage = .VERTEX, num_uniform_buffers = 1}
	text_fragment_info := sdl.GPUShaderCreateInfo{code_size = uint(len(text_fragment_spirv)), code = raw_data(text_fragment_spirv), entrypoint = "main", format = {.SPIRV}, stage = .FRAGMENT, num_samplers = 1, num_uniform_buffers = 1}
	text_vertex_shader := sdl.CreateGPUShader(device, text_vertex_info)
	text_fragment_shader := sdl.CreateGPUShader(device, text_fragment_info)
	if text_vertex_shader == nil || text_fragment_shader == nil {
		fmt.println("Text shader creation failed:", sdl.GetError())
		return {}, false
	}
	defer sdl.ReleaseGPUShader(device, text_vertex_shader)
	defer sdl.ReleaseGPUShader(device, text_fragment_shader)
	text_pipeline_info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader = text_vertex_shader, fragment_shader = text_fragment_shader, primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE, enable_depth_clip = true},
		multisample_state = {sample_count = ._1}, target_info = {color_target_descriptions = &target, num_color_targets = 1},
	}
	text_pipeline := sdl.CreateGPUGraphicsPipeline(device, text_pipeline_info)
	if text_pipeline == nil {
		fmt.println("Text pipeline creation failed:", sdl.GetError())
		return {}, false
	}

	preview_fragment_info := sdl.GPUShaderCreateInfo{code_size = uint(len(preview_fragment_spirv)), code = raw_data(preview_fragment_spirv), entrypoint = "main", format = {.SPIRV}, stage = .FRAGMENT, num_samplers = 1}
	preview_fragment_shader := sdl.CreateGPUShader(device, preview_fragment_info)
	if preview_fragment_shader == nil {
		fmt.println("Preview shader creation failed:", sdl.GetError())
		return {}, false
	}
	defer sdl.ReleaseGPUShader(device, preview_fragment_shader)
	preview_pipeline_info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader = text_vertex_shader, fragment_shader = preview_fragment_shader, primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE, enable_depth_clip = true},
		multisample_state = {sample_count = ._1}, target_info = {color_target_descriptions = &target, num_color_targets = 1},
	}
	preview_pipeline := sdl.CreateGPUGraphicsPipeline(device, preview_pipeline_info)
	if preview_pipeline == nil {
		fmt.println("Preview pipeline creation failed:", sdl.GetError())
		return {}, false
	}

	font: Font_Atlas
	texture := sdl.CreateGPUTexture(device, sdl.GPUTextureCreateInfo{type = .D2, format = .R8_UNORM, usage = {.SAMPLER}, width = 512, height = 512, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1})
	sampler := sdl.CreateGPUSampler(device, sdl.GPUSamplerCreateInfo{min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .NEAREST, address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE, max_lod = 1})
	if texture == nil || sampler == nil {
		fmt.println("Font texture or sampler creation failed:", sdl.GetError())
		return {}, false
	}
	font.texture = texture
	font.sampler = sampler
	preview_textures: [MAX_PREVIEW_SLOTS]^sdl.GPUTexture
	for i in 0 ..< MAX_PREVIEW_SLOTS {
		preview_textures[i] = sdl.CreateGPUTexture(device, sdl.GPUTextureCreateInfo{type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER}, width = PREVIEW_W, height = PREVIEW_H, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1})
		if preview_textures[i] == nil {
			fmt.println("Preview texture creation failed:", sdl.GetError())
			return {}, false
		}
	}
	preview_sampler := sdl.CreateGPUSampler(device, sdl.GPUSamplerCreateInfo{min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .NEAREST, address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE, max_lod = 1})
	if preview_sampler == nil {
		fmt.println("Preview sampler creation failed:", sdl.GetError())
		return {}, false
	}
	return GPU_Renderer{device = device, pipeline = pipeline, text_pipeline = text_pipeline, preview_pipeline = preview_pipeline, font = font, preview_textures = preview_textures, preview_sampler = preview_sampler, viewport = {f32(width), f32(height)}}, true
}

upload_font_atlas :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	transfer := sdl.CreateGPUTransferBuffer(renderer.device, sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = 512 * 512})
	if transfer == nil {
		return false
	}
	mapped := sdl.MapGPUTransferBuffer(renderer.device, transfer, false)
	if mapped == nil {
		sdl.ReleaseGPUTransferBuffer(renderer.device, transfer)
		return false
	}
	stb.BakeFontBitmap(raw_data(font_data), 0, 32, cast([^]u8)mapped, 512, 512, 32, 95, &renderer.font.chars[0])
	sdl.UnmapGPUTransferBuffer(renderer.device, transfer)
	copy_pass := sdl.BeginGPUCopyPass(command_buffer)
	source := sdl.GPUTextureTransferInfo{transfer_buffer = transfer, pixels_per_row = 512, rows_per_layer = 512}
	destination := sdl.GPUTextureRegion{texture = renderer.font.texture, w = 512, h = 512, d = 1}
	sdl.UploadToGPUTexture(copy_pass, source, destination, false)
	sdl.EndGPUCopyPass(copy_pass)
	sdl.ReleaseGPUTransferBuffer(renderer.device, transfer)
	return true
}

main :: proc() {
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
	defer sdl.ReleaseGPUSampler(device, renderer.preview_sampler)
	initial_upload := sdl.AcquireGPUCommandBuffer(device)
	if initial_upload == nil || !upload_font_atlas(&renderer, initial_upload) || !sdl.SubmitGPUCommandBuffer(initial_upload) {
		fmt.println("Could not upload font atlas:", sdl.GetError())
		return
	}

	audio_init()
	defer audio_shutdown()
	async_dec_init()
	defer async_dec_shutdown()

	memory := make([^]u8, clay.MinMemorySize())
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(c.size_t(clay.MinMemorySize()), memory),
		{WINDOW_WIDTH, WINDOW_HEIGHT},
		{handler = clay_error},
	)
	clay.SetMeasureTextFunction(measure_text, nil)

	running := true
	was_mouse_down := false
	for running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				running = false
			case .KEY_DOWN:
				if editing_field != 0 {
					switch event.key.key {
					case sdl.K_BACKSPACE:
						edit_backspace()
					case sdl.K_RETURN, sdl.K_RETURN2:
						edit_commit()
					case sdl.K_ESCAPE:
						edit_cancel()
					}
				}
			case .TEXT_INPUT:
				if editing_field != 0 {
					for ch in string(event.text.text) {
						// Only accept printable ASCII that makes sense in a number.
						if ch >= '0' && ch <= '9' || ch == '-' || ch == '.' {
							edit_append(u8(ch))
						}
					}
				}
			case .MOUSE_WHEEL:
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

		width, height: c.int
		sdl.GetWindowSize(window, &width, &height)
		mouse_x, mouse_y: f32
		mouse_buttons := sdl.GetMouseState(&mouse_x, &mouse_y)
		mouse_down := sdl.MouseButtonFlag.LEFT in mouse_buttons
		middle_down := sdl.MouseButtonFlag.MIDDLE in mouse_buttons
		mods := sdl.GetModState()
		alt_down := sdl.KeymodFlag.LALT in mods || sdl.KeymodFlag.RALT in mods

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
		clay.SetPointerState({mouse_x, mouse_y}, mouse_down)

		commands := build_page(width, height)
		if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("OpenFileButton")) {
			if path := open_file_picker(); path != nil {
				import_media(path)
			}
		} else if clay.PointerOver(clay.ID("DividerHandle")) && mouse_down {
			resizing_areas = true
		} else if mouse_down && !was_mouse_down {
			// A click handled here either inserts a track via a "+" gap or
			// duplicates an existing track via its name-button, or starts dragging
			// the selected clip within the preview, so no clip drag begins.
			handled := false
			// If a property field is being typed in and the user clicks away from
			// it, commit the pending value first.
			if editing_field != 0 {
				still_on_field := (editing_field == 1 && clay.PointerOver(clay.ID("PropFieldX"))) || (editing_field == 2 && clay.PointerOver(clay.ID("PropFieldY"))) || (editing_field == 3 && clay.PointerOver(clay.ID("PropFieldS")))
				if !still_on_field {
					edit_commit()
				}
			}
			// Clicking an X/Y property field focuses it for typing.
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
						begin_handle_drag(sel, canvas, h, mouse_x, mouse_y, alt_down)
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
						pcx, pcy := pixel_to_project(canvas, mouse_x, mouse_y)
						preview_drag_offset_x = pcx - sel.transform_x
						preview_drag_offset_y = pcy - sel.transform_y
						moving_preview_clip = true
					handled = true
				}
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
			// Find which (if any) clip the pointer is over and start dragging it.
			for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
				track := &timeline.tracks[track_idx]
				for index := 0; index < len(track.clips); index += 1 {
					if clay.PointerOver(clay.ID("TimelineClip", u32(track_idx * 1000 + index))) {
						selected_track = track_idx
						selected_index = index
						drag_clip = &track.clips[index]
						moving_clip = true
						clip_drag_offset = mouse_x - clay.GetElementData(clay.ID("TimelineClip", u32(track_idx * 1000 + index))).boundingBox.x
						break
					}
				}
				if moving_clip {
					break
				}
			}
			}
		}
		if !mouse_down {
			resizing_areas = false
			moving_clip = false
			moving_preview_clip = false
			dragging_handle = -1
			handle_kind = .None
			drag_clip = nil
		} else if dragging_handle >= 0 {
			if sel, ok := transformable_selected(); ok {
				pb := clay.GetElementData(clay.ID("Preview")).boundingBox
				canvas := preview_canvas(pb)
				update_handle_drag(sel, canvas, mouse_x, mouse_y)
			}
		} else if resizing_areas {
			upper_area_height = mouse_y - 8
			if upper_area_height < 460 {
				upper_area_height = 460
			}
			if upper_area_height > f32(height - 180) {
				upper_area_height = f32(height - 180)
			}
		} else if moving_preview_clip {
			if sel, ok := transformable_selected(); ok {
				pb := clay.GetElementData(clay.ID("Preview")).boundingBox
				canvas := preview_canvas(pb)
				pcx, pcy := pixel_to_project(canvas, mouse_x, mouse_y)
				sel.transform_x = pcx - preview_drag_offset_x
				sel.transform_y = pcy - preview_drag_offset_y
				sel.transform_x = clamp(sel.transform_x, 0, f32(project.width))
				sel.transform_y = clamp(sel.transform_y, 0, f32(project.height))
				// 5px snap margin (in rendered preview pixels) to the preview borders.
				snap_transform(sel, snap_margin(canvas, 5))
			}
		} else if moving_clip {
			if drag_clip != nil {
				clip_x := mouse_x - clip_drag_offset
				track_start := clay.GetElementData(clay.ID("ClipsSection", 0)).boundingBox.x
				drag_clip.timeline_start_frame = i64(max(clip_x - track_start, 0))
			}
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("PlayPause")) {
			playhead.playing = !playhead.playing
			preview.playing = playhead.playing
		}
		was_mouse_down = mouse_down
		now_ns := sdl.GetTicksNS()
		if last_tick_ns == 0 {
			last_tick_ns = now_ns
		}
		if playhead.playing {
			playhead_accumulator += f64(now_ns - last_tick_ns) / 1_000_000_000
			for playhead_accumulator >= 1.0 / 60.0 {
				playhead.frame += 1
				playhead_accumulator -= 1.0 / 60.0
			}
			if timeline_frame_at(playhead.frame).active_clip == nil {
				playhead.playing = false
				preview.playing = false
			}
		}
		last_tick_ns = now_ns
		_ = timeline_frame_at(playhead.frame)
		audio_update()
		renderer.viewport = {f32(width), f32(height)}
		command_buffer := sdl.AcquireGPUCommandBuffer(device)
		if command_buffer == nil {
			continue
		}
		changed := update_preview_slots()
		any_frame := false
		for i in 0..<MAX_PREVIEW_SLOTS {
			slot := &preview_slots[i]
			if !slot.in_use {
				continue
			}
			any_frame = true
			if slot.texture == nil {
				slot.texture = renderer.preview_textures[i]
			}
			if slot.tex_dirty || changed {
				upload_preview_slot(&renderer, command_buffer, slot)
			}
		}
		preview_has_frame = any_frame
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
			if preview_has_frame {
				preview_bounds := clay.GetElementData(clay.ID("Preview")).boundingBox
				draw_preview(&renderer, command_buffer, pass, preview_bounds)
			}
			sdl.EndGPURenderPass(pass)
		}
		if !sdl.SubmitGPUCommandBuffer(command_buffer) {
			fmt.println("Could not submit GPU command buffer:", sdl.GetError())
		}
	}
}
