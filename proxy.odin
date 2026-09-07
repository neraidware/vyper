package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"
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
	// yuv420p requires even width and height; an odd fitted dim (common for
	// portrait sources, e.g. fit width 243) makes ffmpeg fail and leave a
	// 0-byte proxy. Snap to even so transcoding always succeeds.
	fw = c.int((fw / 2) * 2)
	fh = c.int((fh / 2) * 2)
	return fw, fh
}

// proxy_probe_frame_count returns the number of frames ffprobe attributes to
// the proxy's video stream (for parity checking against the source).
proxy_probe_frame_count :: proc(path: cstring) -> i64 {
	out, code, okin := run_capture({
		"ffprobe", "-v", "error", "-select_streams", "v:0",
		"-count_packets", "-show_entries", "stream=nb_read_packets",
		"-of", "csv=p=0",
		string(path),
	})
	defer delete(out)
	if !okin || code != 0 {
		return -1
	}
	v, ok := strconv.parse_i64(strings.trim_space(out))
	if !ok {
		return -1
	}
	return v
}

// proxy_encode_threads picks how many ffmpeg threads a proxy encode may use: at
// most half the logical cores. A full-resolution libx264 encode of a long
// source saturates every core (decode + encode), starving the SDL loop and
// making the editor look frozen while the background builder runs. Half leaves
// the interactive side air; the wall-clock cost is small (frame decode is the
// bottleneck, not x264).
proxy_encode_threads :: proc() -> string {
	threads := sdl.GetNumLogicalCPUCores()
	if threads > 0 {
		threads = max(threads / 2, 2)
	}
	return fmt.aprintf("%d", threads)
}

// proxy_transcode builds (or rebuilds) the all-intra low-res proxy for a source
// video. In live editing (async_import_mode) it enqueues the build on the
// background worker and returns immediately -- `src_dur_us` (the source
// duration) becomes the progress denominator -- so importing never blocks on
// the transcode; the proxy appears once the worker finishes + verifies it. In
// probe/CI mode (async_import_mode=false) it keeps the historical synchronous
// build so the proxy exists on disk when import returns. Returns the proxy path
// when one is ready right now (fast disk-cache hit, or the sync build), or
// cstring(nil) when the build is deferred (async) or failed. `src_frames` is the
// source's own frame count.
proxy_transcode :: proc(src: cstring, src_frames: i64, src_w, src_h: c.int, src_dur_us: i64, out_buf: []u8) -> cstring {
	if !preview_proxy_enabled {
		return nil
	}
	proxy, ok := proxy_path_for(src, out_buf)
	if !ok {
		return nil
	}
	if proxy_valid_cache_hit(proxy, src_frames) {
		return proxy
	}
	if async_import_mode {
		// Defer the encode to the worker: import returns immediately and the
		// clip previews from the ORIGINAL until the proxy lands. proxy_pick
		// refuses a half-written proxy while this is in flight (see
		// import_bg_building_for).
		import_bg_request(src, src_frames, src_dur_us, src_w, src_h)
		return nil
	}
	// Synchronous build (probe/CI determinism). Encode settings must stay in
	// lockstep with import_bg_build's background argv.
	w, h := proxy_scale(src_w, src_h)
	filter := fmt.aprintf("scale=%d:%d", w, h)
	threads := proxy_encode_threads()
	defer delete(threads)
	// Run ffmpeg with an argv (no shell), capturing (and discarding) its output.
	run_capture({
		"ffmpeg",
		"-y",
		"-i", string(src),
		"-an",
		"-vf", filter,
		"-c:v", "libx264",
		"-preset", "ultrafast",
		"-tune", "fastdecode",
		"-crf", "26",
		"-g", "1",
		"-threads", threads,
		"-pix_fmt", "yuv420p",
		string(proxy),
	})
	if !proxy_valid_cache_hit(proxy, src_frames) {
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
// removed (it will be rebuilt) and false is returned.
proxy_valid_cache_hit :: proc(proxy: cstring, src_frames: i64) -> bool {
	if !os.exists(string(proxy)) {
		return false
	}
	pf := proxy_probe_frame_count(proxy)
	if pf < src_frames - PROXY_FRAME_TOLERANCE {
		// A corrupt/empty proxy (ffprobe returns -1) must be removed too, or
		// it lingers forever and proxy_pick keeps declining it while proxy_transcode
		// never rebuilds (the 0-byte portrait case). Remove any invalid artifact.
		os.remove(string(proxy))
		return false
	}
	return true
}

// proxy_pick returns a usable proxy path for a source if one already exists and
// is frame-count-valid; nil otherwise. Never transcodes (that is the import-
// time job via proxy_transcode); merely selects the ready artifact so the
// preview decoder can use it.
proxy_pick :: proc(src: cstring, src_frames: i64, out_buf: []u8) -> cstring {
	if !preview_proxy_enabled {
		return nil
	}
	// A proxy build is in flight for this source: the file on disk is partial.
	// Never validate (file size/count check) it -- the parity check would
	// conclude "too short" and delete the artifact from under ffmpeg.
	if import_bg_building_for(string(src)) {
		return nil
	}
	proxy, ok := proxy_path_for(src, out_buf)
	if !ok {
		return nil
	}
	if !proxy_valid_cache_hit(proxy, src_frames) {
		return nil
	}
	return proxy
}
