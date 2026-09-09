package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
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
		// clip previews from the ORIGINAL until the opening segment lands.
		// proxy_pick_for_frame refuses to latch a half-written artifact while
		// a build is in flight (see import_bg_building_for).
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

// ---------------------------------------------------------------------------
// Progressive (segmented) proxies.
//
// A proxy no longer has to be one monolithic file trained in a single blocking
// full-length pass: the background builder encodes it as independent all-intra
// segments in SOURCE-TIME ORDER (a few seconds of footage each), so the first
// segment lands almost immediately after import and every frame inside a
// completed segment decodes as fast as a whole-file proxy. Segments the user
// has not reached yet fall back to the source until their segment lands --
// exactly how Premiere/Resolve/Kdenlive previews behave. A completed build is
// just the full segment set.
//
// Layout (all next to the source, named after the whole-proxy naming scheme):
//   <src>.neredproxy.mp4      legacy WHOLE proxy (pre-segment builds / the
//                             synchronous probe path) -- still served as a
//                             fast path when present and no segmentation exists
//   <src>.neredproxy.segNNNN.mp4   segment N, covering source frames
//                             [N*seg_frames, (N+1)*seg_frames)
//   <src>.neredproxy.idx       text index: "seg_frames <n>" then "k <count>"
//                             per COMPLETED segment k (count = frames inside)
// ---------------------------------------------------------------------------

// PROXY_SEG_FRAMES is how many SOURCE frames each proxy segment covers (30s at
// the project's typical 30fps). Bigger segments amortize per-encode overhead
// and index churn; smaller ones make the head of the timeline usable sooner.
PROXY_SEG_FRAMES :: i64(900)

// proxy_segment_path_for writes the segment-<k> proxy path into buf (NUL
// terminated) and returns a cstring into it, or ("", false) on overflow.
proxy_segment_path_for :: proc(src: cstring, k: int, buf: []u8) -> (cstring, bool) {
	src_str := string(src)
	base := path_basename(src)
	dir_len := len(src_str) - len(base)
	fixed := ".neredproxy.seg"
	tail := ".mp4"
	n := dir_len + len(base) + len(fixed) + 4 + len(tail)
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
	for i in 0 ..< len(fixed) {
		buf[s] = fixed[i]
		s += 1
	}
	buf[s + 0] = u8('0' + (k / 1000) % 10)
	buf[s + 1] = u8('0' + (k / 100) % 10)
	buf[s + 2] = u8('0' + (k / 10) % 10)
	buf[s + 3] = u8('0' + (k / 1) % 10)
	s += 4
	for i in 0 ..< len(tail) {
		buf[s] = tail[i]
		s += 1
	}
	buf[s] = 0
	return cstring(&buf[0]), true
}

// proxy_idx_path_for writes the segment index path into buf (NUL terminated).
proxy_idx_path_for :: proc(src: cstring, buf: []u8) -> (cstring, bool) {
	src_str := string(src)
	base := path_basename(src)
	dir_len := len(src_str) - len(base)
	fixed := ".neredproxy.idx"
	n := dir_len + len(base) + len(fixed)
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
	for i in 0 ..< len(fixed) {
		buf[s] = fixed[i]
		s += 1
	}
	buf[s] = 0
	return cstring(&buf[0]), true
}

// proxy_seg_for_frame returns the segment index that covers source frame.
proxy_seg_for_frame :: proc(frame: i64) -> int {
	if frame < 0 {
		return 0
	}
	return int(frame / PROXY_SEG_FRAMES)
}

// proxy_seg_count returns how many segments (at PROXY_SEG_FRAMES each) fully
// cover `frames` source frames.
proxy_seg_count :: proc(frames: i64) -> int {
	if frames <= 0 {
		return 0
	}
	return int((frames + PROXY_SEG_FRAMES - 1) / PROXY_SEG_FRAMES)
}

// Proxy_Idx is the parsed form of a .idx file: the segment size plus one frame
// count per COMPLETED segment (count==0 means "segment never built"). Only
// segments 0..len(segs)-1 exist; segment k covers [k*seg_frames, ...).
Proxy_Idx :: struct {
	seg_frames: i64,
	segs:       [dynamic]i64,
}

// proxy_idx_load parses a source's .idx file into `idx`. Returns false when no
// usable index exists (no file, unparseable, or seg size mismatch).
proxy_idx_load :: proc(src: cstring, idx: ^Proxy_Idx) -> bool {
	idx_path_buf: [4096]u8
	idx_path, ok := proxy_idx_path_for(src, idx_path_buf[:])
	if !ok || !os.exists(string(idx_path)) {
		return false
	}
	data, err := os.read_entire_file_from_path(string(idx_path), context.temp_allocator)
	if err != nil || len(data) == 0 {
		return false
	}
	idx^ = {}
	sf: i64
	got_header := false
	for line in strings.split_lines(string(data), context.temp_allocator) {
		if !got_header {
			if strings.has_prefix(line, "seg_frames ") {
				if v, pok := strconv.parse_i64(line[len("seg_frames "):]); pok && v > 0 {
					sf = v
					got_header = true
					idx.seg_frames = v
				}
			}
			continue
		}
		// "<k> <count>"
		sp := strings.index_byte(line, ' ')
		if sp < 0 {
			continue
		}
		ki, kok := strconv.parse_int(line[:sp])
		ci, cok := strconv.parse_i64(line[sp + 1:])
		if !kok || !cok || ci < 0 {
			continue
		}
		for len(idx.segs) <= ki {
			append(&idx.segs, 0)
		}
		idx.segs[ki] = ci
	}
	if !got_header {
		return false
	}
	return true
}

// proxy_idx_store writes `idx` for a source (called by the background builder
// after each completed segment, on its worker thread -- the single writer).
proxy_idx_store :: proc(src: cstring, idx: ^Proxy_Idx) {
	buf: [4096]u8
	idx_path, ok := proxy_idx_path_for(src, buf[:])
	if !ok {
		return
	}
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	fmt.sbprintf(&sb, "seg_frames %d\n", idx.seg_frames)
	for k in 0 ..< len(idx.segs) {
		fmt.sbprintf(&sb, "%d %d\n", k, idx.segs[k])
	}
	// Best-effort: the segments themselves remain the source of truth, and a
	// partial/crashing write only costs a re-scan when a missing entry is hit.
	_ = os.write_entire_file(string(idx_path), sb.buf[:])
}

// proxy_resolver_entry is the single-slot destination cache kept between decodes
// so a scrub does not re-probe the on-disk index (and never re-runs ffprobe)
// for the actively scrubbed file. One slot is enough: the playhead is in ONE
// clip at a time, and a slow crossfade opens both slots over the same source.
// The whole_proxy leg preserves old monolithic artifacts (and the synchronous
// probe builds) as a fast path.
proxy_resolver_entry :: struct {
	src:         [4096]u8,
	idx:         Proxy_Idx,
	idx_valid:   bool,
	// idx_mtime is the modification time of the .idx on-disk file at the last
	// full read. The picker re-reads the index ONLY when this mtime changes,
	// so playback ahead of the build no longer re-reads + re-parses the file
	// every render frame just because the playhead sits in unbuilt territory.
	idx_mtime:   time.Time,
	whole_proxy: [4096]u8,
	whole_valid: bool,
}

proxy_resolver_cache: proxy_resolver_entry

// proxy_pick_for_frame returns the prebuilt proxy file the preview decoder
// should serve source `frame` of `src` from, or nil to decode the source
// itself. Unlike the old whole-file proxy_pick (one resolution per clip), this
// resolves PER SOURCE FRAME: completed segments are used immediately, uncovered
// ranges revert to the source while their segment is still encoding. Never
// transcodes (import-time job) -- parity was established when the segment/index
// was written and is never re-validated per call. When no segmentation exists,
// falls back to a legacy whole proxy (validated once, latched).
//
// The second return is the file's frame_base: the SOURCE index its frame 0
// corresponds to (0 for a source or whole-file proxy, k*PROXY_SEG_FRAMES for a
// segment). The decoder translates the SOURCE request index by this before
// seeking/caching, since a segment's stream timestamps restart at 0.
proxy_pick_for_frame :: proc(src: cstring, src_frames: i64, frame: i64, out_buf: []u8) -> (cstring, i64) {
	if !preview_proxy_enabled {
		return nil, 0
	}
	// Resolution per frame: source frame -> segment index.
	k := proxy_seg_for_frame(frame)

	rc := &proxy_resolver_cache
	same_src := string(rc.src[:]) == string(src)
	if !same_src {
		if rc.idx_valid {
			delete(rc.idx.segs)
		}
		rc^ = {}
		src_str := string(src)
		n := min(len(src_str), len(rc.src) - 1)
		copy(rc.src[:n], src_str[:n])
		rc.src[n] = 0
	}

	if rc.idx_valid {
		if k < len(rc.idx.segs) && rc.idx.segs[k] > 0 {
			seg, sok := proxy_segment_path_for(src, k, out_buf)
			if sok {
				if !os.exists(string(seg)) {
					// The index claims this segment is built but its file is
					// gone (external removal, or cleanup without an index
					// write). Don't hand the decoder a doomed path that fails
					// reopen every frame and leaves a stale face on screen:
					// fall back to the source; a re-import/rebuild restores it.
					return nil, 0
				}
				return seg, i64(k) * PROXY_SEG_FRAMES
			}
			return nil, 0
		}
		if nered_trace {
			fmt.printf("[pick] seg index %d not covered: len=%d segs=%v\n", k, len(rc.idx.segs), rc.idx.segs)
		}
		// Not covered yet: the on-disk index may have grown since we read it,
		// so fall through and re-consult it when the needed segment might
		// newly exist.
	}

	// (Re)consult the on-disk index when it may have grown past what we know
	// (fresh import, or the worker finished more segments since the last read).
	// The on-disk index is written ONLY by the background builder, so its mtime
	// is a cheap, exact "did any segment complete since my last read?" gate:
	// playback ahead of the build never re-reads/re-parses the file per frame.
	idx_path_buf: [4096]u8
	idx_path, idx_ok := proxy_idx_path_for(src, idx_path_buf[:])
	if idx_ok && (!rc.idx_valid || k >= len(rc.idx.segs)) {
		if info, serr := os.stat(string(idx_path), context.temp_allocator); serr == 0 && info.modification_time != rc.idx_mtime {
			delete(rc.idx.segs)
			rc.idx = {}
			rc.idx_valid = proxy_idx_load(src, &rc.idx)
			rc.idx_mtime = info.modification_time
			if nered_trace {
				fmt.printf("[pick] reloaded idx valid=%v len=%d\n", rc.idx_valid, len(rc.idx.segs))
			}
			if rc.idx_valid && k < len(rc.idx.segs) && rc.idx.segs[k] > 0 {
				seg, sok := proxy_segment_path_for(src, k, out_buf)
				if sok {
					if !os.exists(string(seg)) {
						return nil, 0
					}
					return seg, i64(k) * PROXY_SEG_FRAMES
				}
				return nil, 0
			}
		}
	}

	if rc.idx_valid {
		// Segmented source, frame beyond what is built yet (still encoding, or
		// a cancelled tail): decode the source until the worker closes the gap.
		// Nothing else can serve this frame while segmentation is authoritative.
		return nil, 0
	}

	// No segmentation at all: legacy whole-proxy fast path (old mono builds +
	// the sync probe path). A background build in flight means this source is
	// transitioning to segments -- never latch onto a half-written artifact.
	if import_bg_building_for(string(src)) {
		return nil, 0
	}
	if rc.whole_valid {
		return cstring(&rc.whole_proxy[0]), 0
	}
	if wp, wok := proxy_path_for(src, rc.whole_proxy[:]); wok && os.exists(string(wp)) {
		if proxy_valid_cache_hit(wp, src_frames) {
			rc.whole_valid = true
			return wp, 0
		}
		rc.whole_valid = false
	}
	return nil, 0
}

// proxy_cleanup_artifacts removes every proxy artifact for a source: the legacy
// whole file (if any), the index, and every known segment. Best-effort; used by
// probe cleanup and by a source re-import that must start fresh.
proxy_cleanup_artifacts :: proc(src: cstring) {
	buf: [4096]u8
	if p, ok := proxy_path_for(src, buf[:]); ok {
		os.remove(string(p))
	}
	ibuf: [4096]u8
	idx: Proxy_Idx
	if proxy_idx_load(src, &idx) {
		defer delete(idx.segs)
		seg_buf: [4096]u8
		for k in 0 ..< len(idx.segs) {
			if p, sok := proxy_segment_path_for(src, k, seg_buf[:]); sok {
				os.remove(string(p))
			}
		}
		if ip, iok := proxy_idx_path_for(src, ibuf[:]); iok {
			os.remove(string(ip))
		}
	} else if ip, iok := proxy_idx_path_for(src, ibuf[:]); iok {
		os.remove(string(ip))
	}
	// Drop cache references so a re-import of the same path re-derives state.
	rc := &proxy_resolver_cache
	if string(rc.src[:]) == string(src) {
		if rc.idx_valid {
			delete(rc.idx.segs)
		}
		rc^ = {}
	}
}
