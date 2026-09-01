package main

import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import posix "core:sys/posix"

// ---------------------------------------------------------------------------
// Media import: probing files with ffprobe, building Media_Asset/Track/Clip
// entries, and the file-picker entry point.
// ---------------------------------------------------------------------------

// set_project_resolution applies an explicit resolution (preset button) and
// locks the canvas so later imports won't resize it.
set_project_resolution :: proc(w, h: c.int) {
	project.width = w
	project.height = h
	resolution_locked = true
}

// set_project_resolution_auto clears the resolution lock so the next import
// sets the canvas from the file's own dimensions.
set_project_resolution_auto :: proc() {
	resolution_locked = false
}

// set_project_fps applies an explicit project frame rate (preset button). The
// timeline grid, playhead cadence, and audio producer all remap to this rate;
// later imports no longer override it.
set_project_fps :: proc(fps: f64) {
	project.frame_rate = fps
}

// set_project_orientation forces the given canvas orientation (landscape when
// vertical=false, portrait when vertical=true), swapping the dimensions only
// when they already point the other way, and locks the canvas.
set_project_orientation :: proc(vertical: bool) {
	if vertical && project.height < project.width ||
		!vertical && project.width < project.height {
		project.width, project.height = project.height, project.width
	}
	resolution_locked = true
}

// probe_video_size returns the first video stream's pixel dimensions, or
// ok=false if the file has no video stream / ffprobe fails.
probe_video_size :: proc(path: cstring) -> (w, h: c.int, ok: bool) {
	path_string := string(path)
	quoted_path, _ := strings.replace_all(path_string, "'", "'\\''", context.temp_allocator)
	command := fmt.aprintf("ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 '%s' 2>/dev/null", quoted_path)
	pipe := posix.popen(strings.clone_to_cstring(command, context.temp_allocator), "r")
	if pipe == nil {
		return 0, 0, false
	}
	defer posix.pclose(pipe)
	buffer: [256]byte
	if posix.fgets(raw_data(buffer[:]), len(buffer), pipe) == nil {
		return 0, 0, false
	}
	line, _ := strings.clone_from_cstring(cstring(raw_data(buffer[:])), context.temp_allocator)
	line = strings.trim_space(line)
	parts := strings.split(line, ",")
	if len(parts) != 2 {
		return 0, 0, false
	}
	width, wok := strconv.parse_int(parts[0])
	height, hok := strconv.parse_int(parts[1])
	if !wok || !hok || width <= 0 || height <= 0 {
		return 0, 0, false
	}
	return c.int(width), c.int(height), true
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
	if probe.has_video && probe.video_fps_num > 0 {
		timeline.frame_rate = f64(probe.video_fps_num) / f64(probe.video_fps_den)
	}
	audio_frames := i64(probe.duration_sec * timeline.frame_rate)
	if audio_frames < frame_count {
		audio_frames = frame_count
	}

	// Video's own natural pixel size, used to (a) infer the canvas resolution
	// for the very first import and (b) import the clip at native size rather
	// than auto-fitting it to the canvas.
	src_w, src_h: c.int
	if probe.has_video {
		src_w, src_h, _ = probe_video_size(path)
	}

	// If the user hasn't set a resolution/orientation yet, infer the canvas
	// from this (first) file's own video dimensions.
	if !resolution_locked && src_w > 0 {
		project.width = src_w
		project.height = src_h
		resolution_locked = true
	}

	// Import at native size: 1 source pixel maps to 1 project-canvas pixel, so
	// a clip bigger than the canvas arrives oversized (here, wider than the
	// project) and the user transforms it themselves instead of the clip being
	// auto-scaled to fill the canvas.
	native_scale: f32 = 1
	if src_w > 0 && f32(project.width) > 0 {
		native_scale = f32(src_w) / f32(project.width)
	}

	asset_id := next_asset_id()
	append(&media_assets, Media_Asset{
		id = asset_id,
		path = path,
		kind = probe.has_video ? .Video : (probe.has_audio ? .Audio : .Other),
		metadata = file_info_text,
		frame_count = frame_count,
	})

	sync.mutex_lock(&audio_timeline_mtx)
	defer sync.mutex_unlock(&audio_timeline_mtx)
	clear(&timeline.tracks)
	track_n := 1
	if probe.has_video {
		track := Track{name = fmt.aprintf("Track %d", track_n)}
		append(&track.clips, Clip{
			clip_id = new_clip_id(),
			asset_id = asset_id,
			path = path,
			kind = .Video,
			stream_index = 0,
			source_start_frame = 0,
			source_length_frames = frame_count,
			timeline_start_frame = 0,
			source_w = src_w,
			source_h = src_h,
			transform_x = f32(project.width) / 2,
			transform_y = f32(project.height) / 2,
			scale = native_scale,
			crop_l = 0,
			crop_r = 0,
			crop_t = 0,
crop_b = 0,
	})
		// OBS hybrid MP4 recordings embed chapter markers as a text stream;
		// surface them on the video clip as embedded clip markers.
		video_clip := &track.clips[0]
		video_clip.markers = import_obs_chapters(path)
		append(&timeline.tracks, track)
		track_n += 1
	}
	for a := 0; a < probe.audio_streams; a += 1 {
		track := Track{name = fmt.aprintf("Track %d", track_n)}
		append(&track.clips, Clip{
			clip_id = new_clip_id(),
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

open_file_picker :: proc() -> cstring {
	return portal_open_file_picker()
}
