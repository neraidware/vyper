package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:sync"

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
	if vertical && project.height < project.width || !vertical && project.width < project.height {
		project.width, project.height = project.height, project.width
	}
	resolution_locked = true
}

// probe_video_size returns the first video stream's pixel dimensions, or
// ok=false if the file has no video stream / ffprobe fails.
probe_video_size :: proc(path: cstring) -> (w, h: c.int, ok: bool) {
	out, code, okin := run_capture(
		{
			"ffprobe",
			"-v",
			"error",
			"-select_streams",
			"v:0",
			"-show_entries",
			"stream=width,height",
			"-of",
			"csv=p=0",
			string(path),
		},
	)
	defer delete(out)
	if !okin || code != 0 {
		return 0, 0, false
	}
	line := strings.trim_space(out)
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
	out, _, okin := run_capture(
		{
			"ffprobe",
			"-v",
			"error",
			"-show_entries",
			"format=format_name,duration,size:stream=codec_name,nb_frames,avg_frame_rate",
			"-of",
			"default=noprint_wrappers=1",
			string(path),
		},
	)
	if !okin {
		return "Length: unavailable\nFormat: unavailable\nCodecs: unavailable\nSize: unavailable"
	}
	// Ignore the exit code explicitly: ffprobe can return non-zero on files it
	// can partially inspect but still rejects at the end; we want whatever it
	// printed. Clone into an owned string (the captured buffer is freed).
	result := strings.clone(strings.trim_space(out))
	delete(out)
	return result
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

// find_asset returns the media-bin entry with the given id, or nil. The
// returned pointer is only valid until the next append to media_assets (the
// dynamic array can reallocate); callers that hold it across time must
// re-resolve by id each frame (the drag code does exactly that).
find_asset :: proc(asset_id: u64) -> ^Media_Asset {
	for &a in media_assets {
		if a.id == asset_id {
			return &a
		}
	}
	return nil
}

// downscale_rgba box-filters a tightly-packed RGBA image into dst (dst must be
// dw*dh*4 bytes). Used to shrink the PREVIEW decode into the bin thumbnail.
downscale_rgba :: proc(src: []u8, sw, sh: int, dst: []u8, dw, dh: int) {
	if dw <= 0 || dh <= 0 || len(src) < sw * sh * 4 || len(dst) < dw * dh * 4 {
		return
	}
	for y in 0 ..< dh {
		sy0 := y * sh / dh
		sy1 := (y + 1) * sh / dh
		for x in 0 ..< dw {
			sx0 := x * sw / dw
			sx1 := (x + 1) * sw / dw
			r, g, b, a, n := 0, 0, 0, 0, 0
			for sy in sy0 ..< sy1 {
				for sx in sx0 ..< sx1 {
					o := (sy * sw + sx) * 4
					r += int(src[o + 0])
					g += int(src[o + 1])
					b += int(src[o + 2])
					a += int(src[o + 3])
					n += 1
				}
			}
			if n == 0 {
				continue
			}
			o := (y * dw + x) * 4
			dst[o + 0] = u8(r / n)
			dst[o + 1] = u8(g / n)
			dst[o + 2] = u8(b / n)
			dst[o + 3] = u8(a / n)
		}
	}
}

// decode_asset_thumbnail decodes frame 0 of the asset into its tiny CPU
// thumbnail buffer (via the fixed PREVIEW decode, box-downscaled). Non-fatal:
// an asset without a decodable frame (e.g. audio-only) simply keeps
// has_thumb = false and gets a placeholder in the bin.
decode_asset_thumbnail :: proc(asset: ^Media_Asset) {
	if asset.kind != .Video && asset.kind != .Image {
		return
	}
	scratch := make([]u8, PREVIEW_W * PREVIEW_H * 4, context.temp_allocator)
	dec: Clip_Decoder
	defer clip_decoder_reset(&dec)
	if decode_clip_frame_sync(&dec, asset.path, 0, scratch) {
		downscale_rgba(scratch, PREVIEW_W, PREVIEW_H, asset.thumb_buf[:], THUMB_W, THUMB_H)
		asset.has_thumb = true
		asset.thumb_tex_dirty = true
	}
}

// import_media_to_bin probes a media file and adds it to the media bin as a
// Media_Asset (thumbnail + proxy built, no timeline change). Returns the new
// asset's id, or 0 if the file could not be probed.
import_media_to_bin :: proc(path: cstring) -> u64 {
	// One bin entry per file path: importing a file that's already in the bin
	// is a no-op returning the existing asset's id, so re-imports don't stack
	// duplicate rows (the open-file flow also places the asset on the timeline,
	// which still happens with the returned id).
	for &a in media_assets {
		if strings.compare(string(a.path), string(path)) == 0 {
			return a.id
		}
	}
	file_info_text = probe_media(path)
	frame_count := media_frame_count(file_info_text)
	probe := probe_streams(path)
	if probe.has_video && probe.video_fps_num > 0 {
		timeline.frame_rate = f64(probe.video_fps_num) / f64(probe.video_fps_den)
	}
	// NOTE: audio has no fps of its own; size against the timeline clock
	// (timeline_fps falls back to 60 before any video import).
	audio_frames := i64(probe.duration_sec * timeline_fps())
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

	asset_id := next_asset_id()
	append(
		&media_assets,
		Media_Asset {
			id = asset_id,
			path = path,
			kind = probe.has_video ? .Video : (probe.has_audio ? .Audio : .Other),
			metadata = file_info_text,
			frame_count = frame_count,
			src_w = src_w,
			src_h = src_h,
			audio_streams = c.int(probe.audio_streams),
			audio_frames = audio_frames,
			thumb_tex_dirty = true,
		},
	)
	decode_asset_thumbnail(&media_assets[len(media_assets) - 1])

	// Editing-time preview can decode a low-res all-intra proxy of a video for
	// fluid scrubbing instead of re-decoding whole groups-of-pictures from the
	// original. Build it now, at import, so the preview is ready immediately;
	// the render pass always uses the original (fidelity). Non-fatal: a video
	// with no proxy just previews from the source.
	if probe.has_video {
		proxy_buf: [4096]u8
		_ = proxy_transcode(
			path,
			frame_count,
			src_w,
			src_h,
			i64(probe.duration_sec * 1_000_000),
			proxy_buf[:],
		)
	}
	return asset_id
}

// import_srt_to_bin loads a .srt into the media bin as a .Subtitles asset (no
// timeline change: the clip appears only when the user drags the asset onto the
// timeline, like any other bin media). One bin entry per path; re-importing the
// same subtitle yields the existing asset's id. Returns 0 when the file cannot
// be parsed as SRT.
import_srt_to_bin :: proc(path: cstring) -> u64 {
	for &a in media_assets {
		if strings.compare(string(a.path), string(path)) == 0 {
			return a.id
		}
	}
	srt_id := srt_load(path)
	if srt_id < 0 {
		show_ui_notice(
			fmt.aprintf("Could not load subtitles from '%s'", path_basename(path)),
			4000,
		)
		return 0
	}
	one_sec := i64(math.round(timeline_fps()))
	length := max(one_sec, cue_frame(srt_duration_ms(srt_source(srt_id)), f32(timeline_fps())))
	asset_id := next_asset_id()
	append(
		&media_assets,
		Media_Asset {
			id = asset_id,
			path = path,
			kind = .Subtitles,
			metadata = strings.clone(path_basename(path)),
			frame_count = length,
			audio_frames = length,
			srt_id = srt_id,
			thumb_tex_dirty = true,
		},
	)
	show_ui_notice(fmt.aprintf("Subtitles '%s' added to the media bin", path_basename(path)), 2000)
	return asset_id
}

// add_asset_to_timeline places one clip per stream of an imported asset onto
// the timeline, starting at track `target_track`: a video clip on lane 0, then
// one audio clip per audio stream on the lanes below (lane = target_track + s).
// Missing lanes append new tracks at the bottom ("media with more tracks than
// available creates them"). Every lane clamps placement to the nearest
// non-overlapping slot for its own clips. Returns the placed start frame of the
// first stream's clip.
add_asset_to_timeline :: proc(asset_id: u64, target_track: int, start_frame: i64) -> i64 {
	asset := find_asset(asset_id)
	if asset == nil {
		return start_frame
	}
	n_lanes := int(asset.audio_streams)
	if asset.kind == .Video {
		n_lanes += 1
	}
	if asset.kind == .Subtitles {
		n_lanes = 1
	}
	if n_lanes <= 0 {
		return start_frame
	}
	base := max(target_track, 0)

	// Aligned placement: every lane (video + each audio stream) lands on the SAME
	// frame so an import never desyncs its own streams. The first lane anchors the
	// placement; an existing partner lane that cannot host that exact frame
	// refuses the whole drop rather than silently clamp to a different frame.
	anchor_len := asset.frame_count
	if asset.kind != .Video {
		anchor_len = asset.audio_frames
	}
	anchor_placed := max(start_frame, 0)
	if base < len(timeline.tracks) {
		anchor_placed = clip_place_in_track(&timeline.tracks[base], -1, anchor_len, anchor_placed)
	}
	for offset in 1 ..< n_lanes {
		lane := base + offset
		if lane < len(timeline.tracks) &&
		   lane_blocked(&timeline.tracks[lane], anchor_placed, asset.audio_frames) {
			return start_frame
		}
	}
	// One import that lands on several lanes ships one link group: the video
	// clip plus one clip per audio stream are cut/moved/selected/deleted as a
	// unit, so a video edit never leaves its audio behind.
	link := new_clip_id()
	first_placed := anchor_placed
	for offset in 0 ..< n_lanes {
		is_video := asset.kind == .Video && offset == 0
		is_sub := asset.kind == .Subtitles && offset == 0
		lane_len := is_video ? asset.frame_count : asset.audio_frames
		lane := base + offset
		for len(timeline.tracks) <= lane {
			append(&timeline.tracks, Track{name = next_track_name()})
		}
		track := &timeline.tracks[lane]
		if is_sub && len(track.clips) > 0 {
			// Clamp the subtitle's authored span to the placement gap, matching
			// add_subtitle_generator_clip so a dropped subtitle never overlaps
			// the next clip on the track.
			gaps := clip_track_gaps(track, -1)
			defer delete(gaps)
			if gi := gap_for_start(gaps[:], anchor_placed); gi >= 0 {
				hi := gaps[gi][1]
				if anchor_placed + lane_len > hi {
					lane_len = max(hi - anchor_placed, 1)
				}
			}
		}
		placed := anchor_placed
		clip := Clip {
			clip_id              = new_clip_id(),
			link_id              = link,
			asset_id             = asset.id,
			path                 = is_sub ? nil : asset.path,
			name                 = is_sub ? strings.clone(path_basename(asset.path)) : "",
			kind                 = is_video ? .Video : (is_sub ? .Text : .Audio),
			generator            = is_sub ? .Subtitles : .None,
			srt_id               = is_sub ? asset.srt_id : -1,
			stream_index         = is_sub ? c.int(-1) : c.int(offset - (asset.kind == .Video ? 1 : 0)),
			source_start_frame   = 0,
			source_length_frames = lane_len,
			timeline_start_frame = placed,
		}
		if is_video {
			// Import at native size: 1 source pixel maps to 1 project-canvas
			// pixel, so a clip bigger than the canvas arrives oversized (here,
			// wider than the project) and the user transforms it themselves.
			clip.source_w = asset.src_w
			clip.source_h = asset.src_h
			clip.transform_x = f32(project.width) / 2
			clip.transform_y = f32(project.height) / 2
			native_scale: f32 = 1
			if asset.src_w > 0 && f32(project.width) > 0 {
				native_scale = f32(asset.src_w) / f32(project.width)
			}
			clip.scale = native_scale
			// OBS hybrid MP4 recordings embed chapter markers as a text stream;
			// surface them on the video clip as embedded clip markers.
			clip.markers = import_obs_chapters(asset.path)
		} else if is_sub {
			// Subtitle generator clip sits centered on the project canvas at
			// native scale, exactly like add_subtitle_generator_clip sets it.
			clip.transform_x = f32(project.width) / 2
			clip.transform_y = f32(project.height) / 2
			clip.scale = 1
		}
		append(&track.clips, clip)
		// Keep the track's clips sorted ascending by timeline start.
		for j := len(track.clips) - 1;
		    j > 0 && track.clips[j].timeline_start_frame < track.clips[j - 1].timeline_start_frame;
		    j -= 1 {
			track.clips[j], track.clips[j - 1] = track.clips[j - 1], track.clips[j]
		}
		if offset == 0 {
			first_placed = placed
		} else if placed < first_placed {
			first_placed = placed
		}
	}

	// Post-edit: point the playhead at the placed content, select ONLY the newly
	// added clips, and tear down stale decode/playback state like every other
	// timeline edit. A previous selection must not survive the import or the old
	// clip keeps its border next to the fresh one.
	timeline.playhead_frame = first_placed
	playhead.frame = first_placed
	playhead.playing = false
	playhead_accumulator = 0
	preview.playing = false
	last_decoded_playhead = -1
	last_requested_playhead = -1
	async_dec_reset()
	if warm_valid {
		clip_decoder_reset(&warm_decoder)
		warm_valid = false
		warm_clip_id = 0
	}
	audio_reset_for_load()
	invalidate_preview_slots()
	audio_note_edit()
	clear(&selected_set)
	selected_track = -1
	selected_index = -1
	want_kind := Media_Kind.Video
	#partial switch asset.kind {
	case .Audio:
		want_kind = .Audio
	case .Subtitles:
		want_kind = .Text
	}
	for ti in 0 ..< len(timeline.tracks) {
		for ci in 0 ..< len(timeline.tracks[ti].clips) {
			c := &timeline.tracks[ti].clips[ci]
			if c.asset_id == asset_id &&
			   c.kind == want_kind &&
			   c.timeline_start_frame == anchor_placed {
				selected_track = ti
				selected_index = ci
			}
		}
	}
	return first_placed
}

// import_media loads a media file into the bin AND auto-places it at the top of
// the timeline at frame 0 (legacy behavior kept for the probe/test/autoplay
// paths). The interactive flow (bin "Import" button / empty-timeline "Open
// file") calls import_media_to_bin alone so the user drags media onto tracks
// themselves.
import_media :: proc(path: cstring) {
	id := import_media_to_bin(path)
	if id != 0 {
		add_asset_to_timeline(id, 0, 0)
	}
}

open_file_picker :: proc() -> cstring {
	when ODIN_OS == .Windows {
		return win32_open_file_picker()
	} else {
		return portal_open_file_picker()
	}
}

// open_srt_picker opens a subtitle (.srt)-only file dialog (subtitle-generator
// creation) and returns the chosen path, or nil on cancel.
open_srt_picker :: proc() -> cstring {
	when ODIN_OS == .Windows {
		return win32_open_srt_picker()
	} else {
		return portal_open_srt_picker()
	}
}

// save_file_picker opens a save-as dialog (render output) and returns the chosen
// path (or nil on cancel). Linux uses the XDG portal SaveFile; Windows uses the
// Win32 common save dialog.
save_file_picker :: proc() -> cstring {
	when ODIN_OS == .Windows {
		return win32_save_file_picker()
	} else {
		return portal_save_file_picker()
	}
}
