package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import posix "core:sys/posix"
// ---------------------------------------------------------------------------
// Preview proxies.
//
// While EDITING, the interactive preview decoder can decode a low-resolution,
// all-intra-frame proxy of a clip instead of the original: every frame is a
// keyframe, so a scrub seek decodes exactly one frame instead of re-decoding
// the whole group-of-pictures up to the target, and there is no
// container-reopen cost. The proxy is a preview-only artifact -- the render
// path (render.odin) always decodes the ORIGINAL source so exported output
// keeps full fidelity to the source content.
//
// A proxy is only used when it is verifiably frame-count-equivalent to its
// source AND coexists with it on disk; any doubt falls back to the original,
// so a stale/mismatched proxy can never corrupt the playhead model (which is
// keyed on source frame indices).
// ---------------------------------------------------------------------------

// proxy_suffix is appended to a source's basename to form the proxy path:
// "<source parent>/<base>.neredproxy.mp4".
PROXY_SUFFIX := ".neredproxy.mp4"

// proxy_path_for writes the on-disk proxy path for a source video into `buf`
// (NUL-terminated) and returns a cstring into it. The proxy lives next to the
// source so it moves with it and dies with it. Returns ("", false) if the
// buffer is too small or the source has no directory component.
proxy_path_for :: proc(src: cstring, buf: []u8) -> (cstring, bool) {
	src_str := string(src)
	base := path_basename(src)
	dir_len := len(src_str) - len(base)
	if dir_len < 0 {
		return "", false
	}
	n := dir_len + len(base) + len(PROXY_SUFFIX)
	if n >= len(buf) {
		return "", false
	}
	s := 0
	for i in 0 ..< dir_len {
		buf[s] = src_str[i]
		s += 1
	}
	for i in 0 ..< len(base) {
		buf[s] = base[i]
		s += 1
	}
	for i in 0 ..< len(PROXY_SUFFIX) {
		buf[s] = PROXY_SUFFIX[i]
		s += 1
	}
	buf[s] = 0
	return cstring(&buf[0]), true
}

// proxy_scale computes the proxy's pixel size: the source-fit rect of the
// source's aspect within the PREVIEW bounds, so letterboxing is idempotent
// (a proxied frame reproduces the same filled preview rectangle as decoding
// the original). Returns fitted w,h for ffmpeg's scale filter, or original
// dims if the source aspect is unknown/invalid.
proxy_scale :: proc(src_w, src_h: c.int) -> (w, h: c.int) {
	if src_w <= 0 || src_h <= 0 {
		return PREVIEW_W, PREVIEW_H
	}
	fw, fh, _, _ := source_fit_in_buffer(src_w, src_h, PREVIEW_W, PREVIEW_H)
	return fw, fh
}

// proxy_probe_frame_count returns the number of frames ffprobe attributes to
// the proxy's video stream (for parity checking against the source).
proxy_probe_frame_count :: proc(path: cstring) -> i64 {
	path_string := string(path)
	quoted, _ := strings.replace_all(path_string, "'", "'\\''", context.temp_allocator)
	command := fmt.aprintf("ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 '%s' 2>/dev/null", quoted)
	pipe := posix.popen(strings.clone_to_cstring(command, context.temp_allocator), "r")
	if pipe == nil {
		return -1
	}
	defer posix.pclose(pipe)
	buffer: [64]byte
	if posix.fgets(raw_data(buffer[:]), len(buffer), pipe) == nil {
		return -1
	}
	line_str, _ := strings.clone_from_cstring(cstring(raw_data(buffer[:])), context.temp_allocator)
	line_str = strings.trim_space(line_str)
	v, ok := strconv.parse_i64(line_str)
	if !ok {
		return -1
	}
	return v
}

// proxy_transcode builds (or rebuilds) the all-intra low-res proxy for a source
// video. Returns the proxy path on success (when the produced proxy is
// frame-count-equivalent to the source), or cstring(nil) on any failure or
// parity mismatch. `src_frames` is the source's own frame count.
proxy_transcode :: proc(src: cstring, src_frames: i64, src_w, src_h: c.int, out_buf: []u8) -> cstring {
	if !preview_proxy_enabled {
		return nil
	}
	proxy, ok := proxy_path_for(src, out_buf)
	if !ok {
		return nil
	}
	if hit, _ := proxy_valid_cache_hit(proxy, src_frames); hit {
		return proxy
	}
	w, h := proxy_scale(src_w, src_h)
	src_str := string(src)
	proxy_str := string(proxy)
	q_src, _ := strings.replace_all(src_str, "'", "'\\''", context.temp_allocator)
	q_proxy, _ := strings.replace_all(proxy_str, "'", "'\\''", context.temp_allocator)
	filter := fmt.aprintf("scale=%d:%d", w, h)
	command := fmt.aprintf("ffmpeg -y -i '%s' -an -vf '%s' -c:v libx264 -preset veryfast -tune fastdecode -crf 18 -g 1 -pix_fmt yuv420p '%s' 2>/dev/null",
		q_src, filter, q_proxy)
	// Pop the pipe and drain to force completion; ignore the content.
	pipe := posix.popen(strings.clone_to_cstring(command, context.temp_allocator), "r")
	if pipe == nil {
		return nil
	}
	buffer: [256]byte
	for posix.fgets(raw_data(buffer[:]), len(buffer), pipe) != nil {
	}
	posix.pclose(pipe)
	if ok, _ := proxy_valid_cache_hit(proxy, src_frames); !ok {
		return nil
	}
	return proxy
}

// PROXY_FRAME_TOLERANCE allows the proxy to carry a couple fewer frames than
// the source's ESTIMATED count (duration*fps, which itself overstates real
// decodable frames on odd files). The proxy must at least cover every source
// frame index the decoder can actually produce, not the inflated estimate.
PROXY_FRAME_TOLERANCE :: 2

// proxy_valid_cache_hit checks whether an existing proxy is frame-suffcient
// for the source: it must carry at least (src_frames - tolerance) decodable
// frames so every requested source index can be served. If the proxy is
// missing it returns false; if it is present but too short, the stale proxy is
// removed (it will be rebuilt) and false is returned. The probe result is
// returned alongside so callers can bound decode requests against what the
// proxy can actually serve (proxy clip frames past pf decode into EOF).
proxy_valid_cache_hit :: proc(proxy: cstring, src_frames: i64) -> (bool, i64) {
	if !os.exists(string(proxy)) {
		return false, 0
	}
	pf := proxy_probe_frame_count(proxy)
	if pf < src_frames - PROXY_FRAME_TOLERANCE {
		if pf != -1 {
			os.remove(string(proxy))
		}
		return false, 0
	}
	return true, pf
}

// proxy_pick returns a usable proxy path for a source if one already exists and
// is frame-count-valid; nil otherwise. Never transcodes (that is the import-
// time job via proxy_transcode); merely selects the ready artifact so the
// preview decoder can use it. The verified decodable frame count of the proxy
// is returned alongside it.
proxy_pick :: proc(src: cstring, src_frames: i64, out_buf: []u8) -> (cstring, i64) {
	if !preview_proxy_enabled {
		return nil, 0
	}
	proxy, ok := proxy_path_for(src, out_buf)
	if !ok {
		return nil, 0
	}
	hit, pf := proxy_valid_cache_hit(proxy, src_frames)
	if !hit {
		return nil, 0
	}
	return proxy, pf
}
