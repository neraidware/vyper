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
Clip :: struct { asset_id: u64, path: cstring, kind: Media_Kind, stream_index: c.int, source_start_frame: i64, source_length_frames: i64, timeline_start_frame: i64, layer: i32 }
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
	preview_texture: [2]^sdl.GPUTexture,
	preview_sampler: ^sdl.GPUSampler,
	preview_tex_index: u32,
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

// decode_active_frame is non-blocking: video decode happens on the async
// worker thread (vdecode.odin), so slow keyframe decodes never stall the
// render loop or the audio feed. Each frame the render thread copies out any
// finished RGBA frame and, if the playhead moved, requests the next decode.
// Returns true when a fresh frame was copied out this call (=> upload it).
decode_active_frame :: proc() -> bool {
	ad := &async_decoder
	tf := timeline_frame_at(playhead.frame)
	if tf.active_clip == nil {
		return false
	}
	sdl.LockMutex(ad.mutex)
	new_frame := false
	if ad.display_dirty {
		copy(preview.buffer[:], ad.display_buf[:])
		ad.display_dirty = false
		last_decoded_playhead = playhead.frame
		new_frame = true
	}
	if playhead.frame != last_requested_playhead {
		ad.req_valid = true
		ad.req_path = tf.active_clip.path
		ad.req_clip_frame = tf.clip_frame
		last_requested_playhead = playhead.frame
		sdl.SignalCondition(ad.cond)
	}
	sdl.UnlockMutex(ad.mutex)
	return new_frame
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

// upload_preview_texture copies tightly-packed RGBA pixels into the preview
// GPU texture using a transfer buffer + copy pass on the given command buffer.
upload_preview_texture :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, data: []u8) {
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
	copy(dst, data)
	sdl.UnmapGPUTransferBuffer(renderer.device, transfer)
	copy_pass := sdl.BeginGPUCopyPass(command_buffer)
	source := sdl.GPUTextureTransferInfo{transfer_buffer = transfer, pixels_per_row = PREVIEW_W, rows_per_layer = PREVIEW_H}
	destination := sdl.GPUTextureRegion{texture = renderer.preview_texture[1 - renderer.preview_tex_index], w = PREVIEW_W, h = PREVIEW_H, d = 1}
	sdl.UploadToGPUTexture(copy_pass, source, destination, false)
	sdl.EndGPUCopyPass(copy_pass)
}

// draw_preview draws the composed preview as a textured quad in the given
// bounds, reusing the sampled-texture text pipeline with a full UV quad.
// The decode buffer is fixed 16:9 (PREVIEW_W x PREVIEW_H); it is fitted within
// the bounds preserving aspect so a non-16:9 project resolution letterboxes
// instead of distorting the video.
draw_preview :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, bounds: clay.BoundingBox) {
	if renderer.preview_pipeline == nil || renderer.preview_texture[0] == nil {
		return
	}
	pw := f32(PREVIEW_W)
	ph := f32(PREVIEW_H)
	scale: f32
	if bounds.width > 0 && bounds.height > 0 {
		scale = min(bounds.width / pw, bounds.height / ph)
	} else {
		scale = 1
	}
	w := pw * scale
	h := ph * scale
	x := bounds.x + (bounds.width - w) / 2
	y := bounds.y + (bounds.height - h) / 2
	vertex_uniforms := TextVertexUniforms{
		bounds = {x, y, w, h},
		viewport = renderer.viewport,
		_padding = {},
		uv = {0, 0, 1, 1},
	}
	sdl.BindGPUGraphicsPipeline(pass, renderer.preview_pipeline)
	binding := sdl.GPUTextureSamplerBinding{texture = renderer.preview_texture[renderer.preview_tex_index], sampler = renderer.preview_sampler}
	sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
	sdl.PushGPUVertexUniformData(command_buffer, 0, &vertex_uniforms, sdl.Uint32(size_of(vertex_uniforms)))
	sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
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
	preview_texture0 := sdl.CreateGPUTexture(device, sdl.GPUTextureCreateInfo{type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER}, width = PREVIEW_W, height = PREVIEW_H, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1})
	preview_texture1 := sdl.CreateGPUTexture(device, sdl.GPUTextureCreateInfo{type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER}, width = PREVIEW_W, height = PREVIEW_H, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1})
	preview_sampler := sdl.CreateGPUSampler(device, sdl.GPUSamplerCreateInfo{min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .NEAREST, address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE, max_lod = 1})
	if preview_texture0 == nil || preview_texture1 == nil || preview_sampler == nil {
		fmt.println("Preview texture or sampler creation failed:", sdl.GetError())
		return {}, false
	}
	return GPU_Renderer{device = device, pipeline = pipeline, text_pipeline = text_pipeline, preview_pipeline = preview_pipeline, font = font, preview_texture = {preview_texture0, preview_texture1}, preview_sampler = preview_sampler, viewport = {f32(width), f32(height)}}, true
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
	defer sdl.ReleaseGPUTexture(device, renderer.preview_texture[0])
	defer sdl.ReleaseGPUTexture(device, renderer.preview_texture[1])
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
			}
		}

		width, height: c.int
		sdl.GetWindowSize(window, &width, &height)
		mouse_x, mouse_y: f32
		mouse_buttons := sdl.GetMouseState(&mouse_x, &mouse_y)
		mouse_down := sdl.MouseButtonFlag.LEFT in mouse_buttons
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
			// duplicates an existing track via its name-button, so no clip drag
			// begins. (Both run full width / off the clip lane.)
			handled := false
			for i := 0; i <= len(timeline.tracks); i += 1 {
				if clay.PointerOver(clay.ID("TrackGap", u32(i))) {
					insert_track(i)
					handled = true
					break
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
			drag_clip = nil
		} else if resizing_areas {
			upper_area_height = mouse_y - 8
			if upper_area_height < 460 {
				upper_area_height = 460
			}
			if upper_area_height > f32(height - 180) {
				upper_area_height = f32(height - 180)
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
		preview_visible := decode_active_frame()
		if preview_visible {
			preview_has_frame = true
			upload_preview_texture(&renderer, command_buffer, preview.buffer[:])
			renderer.preview_tex_index = 1 - renderer.preview_tex_index
		}
		preview_visible = preview_visible || preview_has_frame
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
			if preview_visible {
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
