package main

import "core:c"
import "core:fmt"
import "core:hash"
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

// Proxy artifacts live in a per-user cache directory -- "$XDG_CACHE_HOME/vyper",
// or "$HOME/.cache/vyper" when XDG_CACHE_HOME is unset; on Windows that base is
// "%LOCALAPPDATA%/vyper" (no XDG/dotdir convention there) -- keyed by
// <basename>-<path-hash>, so they never pollute the source folders, survive any
// source relocation (re-hash only when the path changes), and same-named sources
// from different folders stay distinct. The naming scheme is unchanged:
PROXY_SUFFIX := ".vyperproxy.mp4"

// proxy_cache_ready is memoized true once the cache dir is known to exist; the
// mkdir is skipped on the hot read path (proxy_pick_for_frame) but re-attempted
// immediately if any build fails, so a raced/removed dir self-heals.
proxy_cache_ready: bool

// proxy_cache_prefix writes the vyper proxy cache dir into buf (trailing '/'
// included, NUL-terminated), creating it and any missing parents on first use.
// Returns the byte offset just past the prefix, or (0, false) when no home can
// be resolved, no XDG override exists, or the directory cannot be created --
// callers treat any failure as "no proxy available".
proxy_cache_prefix :: proc(buf: []u8) -> (int, bool) {
	home: string
	if v, ok := os.lookup_env_alloc("XDG_CACHE_HOME", context.temp_allocator); ok && v != "" {
		home = v
	} else {
		when ODIN_OS == .Windows {
			// Windows has no XDG convention and no dotdirs: the sanctioned
			// per-user cache root is %LOCALAPPDATA% (AppData\Local). Falling
			// back to ~/.cache would drop proxies where Windows users never
			// look and tools never clean.
			localapp, lok := os.lookup_env_alloc("LOCALAPPDATA", context.temp_allocator)
			if !lok || localapp == "" {
				return 0, false
			}
			home = localapp
		} else {
			h, err := os.user_home_dir(context.temp_allocator)
			if err != os.General_Error.None || h == "" {
				return 0, false
			}
			home = strings.concatenate({h, "/.cache"}, context.temp_allocator)
		}
	}
	rel := "/vyper/"
	n := len(home) + len(rel)
	if n + 1 >= len(buf) {
		return 0, false
	}
	copy(buf[:n], home)
	copy(buf[len(home):n], rel)
	buf[n] = 0
	if !proxy_cache_ready {
		// make_directory_all returns .Exist when the dir already exists (a plain
		// idempotent success for our purpose), so treat it as ready -- otherwise
		// the cache dir ever existing beforehand disables proxying for the whole
		// session until the dir is removed.
		if err := os.make_directory_all(string(cstring(&buf[0])));
		   err == os.General_Error.None || err == os.General_Error.Exist {
			proxy_cache_ready = true
		} else {
			return 0, false
		}
	}
	return n, true
}

// proxy_stem writes the in-cache naming stem for a source video: its basename
// minus the final extension, a '-', then the low 32 bits of FNV-1a over the
// source's (absolute) path in hex, so distinct sources never collide even with
// identical basenames. Returns the updated offset, or (off, false) on overflow.
proxy_stem :: proc(buf: []u8, off: int, src: cstring) -> (int, bool) {
	base := path_basename(src)
	no_ext := base
	if dot := strings.last_index(base, "."); dot > 0 {
		no_ext = base[:dot]
	}
	h := hash.fnv32a(transmute([]byte)string(src))
	if off + len(no_ext) + 9 > len(buf) {
		return off, false
	}
	s := off
	for i in 0 ..< len(no_ext) {
		buf[s] = no_ext[i]
		s += 1
	}
	buf[s] = '-'
	s += 1
	for i in 0 ..< 8 {
		d := u8(h >> u32((7 - i) * 4)) & 0xF
		buf[s] = d < 10 ? u8('0') + d : u8('a') + (d - 10)
		s += 1
	}
	return s, true
}

// proxy_path_for writes the on-disk whole-proxy path for a source video into
// `buf` (NUL-terminated): "<cache>/<base>-<hash>.vyperproxy.mp4". Returns
// ("", false) if the buffer is too small or the cache dir is unusable.
proxy_path_for :: proc(src: cstring, buf: []u8) -> (cstring, bool) {
	off, ok := proxy_cache_prefix(buf)
	if !ok {
		return "", false
	}
	s, stok := proxy_stem(buf, off, src)
	if !stok {
		return "", false
	}
	if s + len(PROXY_SUFFIX) + 1 > len(buf) {
		return "", false
	}
	copy(buf[s:s + len(PROXY_SUFFIX)], PROXY_SUFFIX)
	s += len(PROXY_SUFFIX)
	buf[s] = 0
	return cstring(&buf[0]), true
}

// proxy_scale computes the proxy's pixel size: the source-fit rect of the
// source's aspect within the PREVIEW bounds, so letterboxing is idempotent
// (a proxied frame reproduces the same filled preview rectangle as decoding
// the original). Returns fitted w,h for the proxy encoder's sws scale, or
// original dims if the source aspect is unknown/invalid.
proxy_scale :: proc(src_w, src_h: c.int) -> (w, h: c.int) {
	if src_w <= 0 || src_h <= 0 {
		return PREVIEW_W, PREVIEW_H
	}
	fw, fh, _, _ := source_fit_in_buffer(src_w, src_h, PREVIEW_W, PREVIEW_H)
	// yuv420p requires even width and height; an odd fitted dim (common for
	// portrait sources, e.g. fit width 243) would make the encode reject the
	// buffer and leave a 0-byte proxy. Snap to even so transcoding always
	// succeeds.
	fw = c.int((fw / 2) * 2)
	fh = c.int((fh / 2) * 2)
	return fw, fh
}

// proxy_probe_frame_count returns the number of frames the proxy's video stream
// holds (for parity checking against the source). In-process now: the container
// packet scan (first_video_packet_count) is the exact equivalent of the old
// `ffprobe -count_packets`, with no subprocess. Returns -1 when the file can't
// be scanned.
proxy_probe_frame_count :: proc(path: cstring) -> i64 {
	return probe_video_packet_count(path)
}

// proxy_encode_threads picks how many encode threads an in-process proxy encode
// may use: at most half the logical cores. A full-resolution x264 encode of a
// long source saturates every core (decode + encode), starving the SDL loop and
// making the editor look frozen while the background builder runs. Half leaves
// the interactive side air; the wall-clock cost is small (frame decode is the
// bottleneck, not x264). 0 means "let libav decide".
proxy_encode_threads :: proc() -> c.int {
	threads := sdl.GetNumLogicalCPUCores()
	if threads > 0 {
		threads = max(threads / 2, 2)
	}
	return threads
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
proxy_transcode :: proc(
	src: cstring,
	src_frames: i64,
	src_w, src_h: c.int,
	src_dur_us: i64,
	out_buf: []u8,
) -> cstring {
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
		// Proxy building is ON-DEMAND now (proxy_build_schedule asks the worker
		// for the playhead's window), so import itself enqueues nothing: it
		// returns immediately and the clip previews from the ORIGINAL until the
		// scheduler's request lands. Idempotent on disk -- a re-import of an
		// already-fully-built file is a cheap no-op when the scheduler reaches
		// it. proxy_pick_for_frame refuses to latch a half-written artifact
		// while a build is in flight (see import_bg_building_for).
		return nil
	}
	// Synchronous build (probe/CI determinism). Encode settings must stay in
	// lockstep with import_bg_build's background encode (same in-process
	// libav path, just the whole file in one pass instead of segments).
	w, h := proxy_scale(src_w, src_h)
	result, _ := proxy_encode_range(
		src, proxy,
		0, src_frames,
		w, h,
		proxy_encode_threads(),
		nil,
		proc(ud: rawptr, frames_done: int) {},
		proc(ud: rawptr) -> bool {
			return false
		},
	)
	if result != .Ok {
		return nil
	}
	if !proxy_valid_cache_hit(proxy, src_frames) {
		os.remove(string(proxy))
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
		// A corrupt/empty proxy (frame scan returns -1) must be removed too, or
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
// Layout (all in the per-user proxy cache dir, named after the whole-proxy
// naming scheme):
//   <cache>/<base>-<hash>.vyperproxy.mp4      legacy WHOLE proxy (pre-segment
//                             builds / the synchronous probe path) -- still
//                             served as a fast path when present and no
//                             segmentation exists
//   <cache>/<base>-<hash>.vyperproxy.segNNNN.mp4   segment N, covering source
//                             frames [N*seg_frames, (N+1)*seg_frames)
//   <cache>/<base>-<hash>.vyperproxy.idx      text index: "seg_frames <n>" then
//                             "k <count>" per COMPLETED segment k (count =
//                             frames inside)
// ---------------------------------------------------------------------------

// PROXY_SEG_FRAMES is how many SOURCE frames each proxy segment covers (30s at
// the project's typical 30fps). Bigger segments amortize per-encode overhead
// and index churn; smaller ones make the head of the timeline usable sooner.
PROXY_SEG_FRAMES :: i64(900)

// proxy_segment_path_for writes the segment-<k> proxy path into buf (NUL
// terminated) and returns a cstring into it, or ("", false) on overflow.
proxy_segment_path_for :: proc(src: cstring, k: int, buf: []u8) -> (cstring, bool) {
	off, ok := proxy_cache_prefix(buf)
	if !ok {
		return "", false
	}
	s, stok := proxy_stem(buf, off, src)
	if !stok {
		return "", false
	}
	fixed := ".vyperproxy.seg"
	tail := ".mp4"
	need := s + len(fixed) + 4 + len(tail) + 1
	if need >= len(buf) {
		return "", false
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
	off, ok := proxy_cache_prefix(buf)
	if !ok {
		return "", false
	}
	s, stok := proxy_stem(buf, off, src)
	if !stok {
		return "", false
	}
	fixed := ".vyperproxy.idx"
	if s + len(fixed) + 1 > len(buf) {
		return "", false
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

// ---------------------------------------------------------------------------
// On-demand proxy scheduler.
//
// The background builder builds SEGMENT WINDOWS, and something must decide
// which window the preview actually needs right now. That is this proc, run
// every frame. The policy: keep the segments around and AHEAD of the playhead
// proxied, bounded to PROXY_MARGIN_SECONDS of source footage beyond the
// playhead's current segment. Import no longer enqueues a whole-file build (see
// proxy_transcode) -- the preview would otherwise sit on full-res source decode
// for the entire import while the whole file encoded, which is the modal lag
// this redesign exists to remove. Instead a freshly-imported clip gets proxied
// on demand: when the playhead is on it, the scheduler requests [k..k+margin)
// and the worker builds that window head-first while the playhead sits inside
// the already-built head; playback + scrubbing within the built region is
// proxy-fast, the unbuilt tail falls back to source (same as segmented preview
// behaved before).
//
// Far jumps (a scrub that leaves the current request window entirely) retarget
// the build via import_bg_redefine: the worker aborts its stale window and
// starts the playhead's new region immediately instead of finishing what the
// playhead just left. Playing/scrubbing WITHIN the requested window is a plain
// request (latest-wins), so the worker keeps the head moving while a new tail
// request waits -- no restart churn.
// ---------------------------------------------------------------------------

// PROXY_MARGIN_SECONDS is how much source footage the scheduler keeps proxied
// ahead of the playhead (the "4 minutes of cached media" budget). Tuned to the
// modal-lag case this feature killed: big enough that sustained playback never
// outruns the builder, small enough that a scrub to the end of a long clip
// retargets instead of enqueuing an hour of encodes nobody will watch.
PROXY_MARGIN_SECONDS :: 240

// proxy_sched_margin_seconds is how much source footage the scheduler keeps
// proxied ahead of the playhead, read each scheduling tick. Defaults to
// PROXY_MARGIN_SECONDS; probes/tuning override it (VYPER_PROXY_MARGIN_SECONDS).
proxy_sched_margin_seconds: f64 = PROXY_MARGIN_SECONDS

proxy_build_schedule :: proc() {
	if !async_import_mode || !preview_proxy_enabled {
		return
	}
	// The clip the user is actually looking at is the frontmost non-text video
	// clip UNDER THE PLAYHEAD: same walk preview_state uses to pick its
	// foreground face. A clip in the margin ahead is NOT scheduled -- its proxy
	// is only built when the playhead arrives (preview falls back to source
	// until then, exactly like an under-built edge segment).
	clip := proxy_front_video_under_playhead()
	if clip == nil {
		return
	}
	asset := find_asset(clip.asset_id)
	if asset == nil || asset.frame_count <= 0 || asset.dur_us <= 0 {
		return
	}
	// Source frame under the playhead, then its segment.
	src_frame := clip.source_start_frame + playhead.frame - clip.timeline_start_frame
	if src_frame < 0 {
		src_frame = 0
	}
	src := clip.path
	if src == "" {
		src = asset.path
	}
	if len(src) == 0 {
		return
	}

	// Project the playhead's position forward PROXY_MARGIN_SECONDS of source
	// footage: fps = frame_count / dur. The window is [w_lo, w_hi), where w_lo
	// is the segment the playhead is in RIGHT NOW (its segment is always
	// covered) and w_hi reaches one margin ahead, capped at the source's last
	// segment.
	fps := f64(asset.frame_count) * 1e6 / f64(asset.dur_us)
	seg_total := proxy_seg_count(asset.frame_count)
	seg_margin := max(1, int(proxy_sched_margin_seconds * fps / f64(PROXY_SEG_FRAMES)) + 1)
	k := proxy_seg_for_frame(src_frame)
	if k < 0 {
		k = 0
	}
	if k >= seg_total {
		return
	}
	w_lo := min(k, seg_total - 1)
	w_hi := min(k + seg_margin, seg_total)
	if w_hi <= w_lo {
		return
	}

	// Dedupe against the current request/active/done state. Coverage is
	// INTERVAL-based, not a high-water mark: after a far jump the finished
	// window may sit ahead of a gap (built [0,1) then [3,4), playhead back in
	// the [1,3) gap), so "proxy reaches segment N" does not mean every segment
	// below N is on disk. A pending request / in-flight build / finished window
	// suppresses today's post only when it CONTAINS the whole wanted window.
	req_src, req_lo, req_hi, has_request, active_src, active_lo, active_hi, building, done_src, done_lo, done_hi, done_ok, last_result_phase, last_result_src, last_result_lo, last_result_hi :=
		import_bg_window()

	// Cancel/fail suppression: if the worker just finished (or dropped) the
	// exact window the playhead still wants, respect that the user cancelled it
	// or the build genuinely failed -- re-posting every frame would make cancel
	// a no-op. Suppression lifts the moment the playhead wants a different
	// window (a different (lo, hi) pair never matches).
	if (last_result_phase == .Done_Cancelled || last_result_phase == .Done_Fail) &&
		strings.compare(string(last_result_src), string(src)) == 0 &&
		last_result_lo == w_lo && last_result_hi == w_hi {
		return
	}

	contains := proc(f_src: cstring, f_lo, f_hi: int, t_src: cstring, t_lo, t_hi: int) -> bool {
		if strings.compare(string(f_src), string(t_src)) != 0 {
			return false
		}
		return f_lo <= t_lo && f_hi >= t_hi
	}
	if has_request && contains(req_src, req_lo, req_hi, src, w_lo, w_hi) {
		return
	}
	if building && contains(active_src, active_lo, active_hi, src, w_lo, w_hi) {
		return
	}
	if done_ok && contains(done_src, done_lo, done_hi, src, w_lo, w_hi) {
		return
	}

	// Post. A build in flight for a DIFFERENT source, or for this source with a
	// window lying wholly behind the playhead (a far jump past the in-flight
	// frontier), retargets via import_bg_redefine so the worker aborts the
	// stale window and starts the playhead's region now. Everything else --
	// same-source adjacent/overlapping, an idle builder -- is a plain
	// latest-wins request the worker picks up after its current window.
	jumped := false
	if building {
		if strings.compare(string(active_src), string(src)) != 0 {
			jumped = true
		} else if active_hi < w_lo {
			jumped = true
		}
	}
	if !jumped && has_request && !contains(req_src, req_lo, req_hi, src, w_lo, w_hi) {
		if strings.compare(string(req_src), string(src)) != 0 {
			jumped = true
		} else if req_hi < w_lo {
			jumped = true
		}
	}

	if jumped {
		import_bg_redefine(src, asset.frame_count, asset.dur_us, asset.src_w, asset.src_h, w_lo, w_hi)
	} else {
		import_bg_request(src, asset.frame_count, asset.dur_us, asset.src_w, asset.src_h, w_lo, w_hi)
	}
}

// proxy_front_video_under_playhead returns the frontmost (topmost in track
// order) non-text media clip whose source interval contains the playhead, or
// nil. Mirrors preview_state's front_video_slot selection (first Video/Text
// claim in track order; here Text is skipped -- generators have no proxy).
proxy_front_video_under_playhead :: proc() -> ^Clip {
	sync_track_order()
	for w in 0 ..< len(timeline.track_order) {
		ti := timeline.track_order[w]
		track := &timeline.tracks[ti]
		for i in 0 ..< len(track.clips) {
			clip := &track.clips[i]
			if clip.kind != .Video {
				continue
			}
			if playhead.frame < clip.timeline_start_frame ||
			   playhead.frame >= clip.timeline_start_frame + clip.source_length_frames {
				continue
			}
			return clip
		}
	}
	return nil
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

// proxy_segments_complete reports whether a source's segmented proxy already
// covers the whole source on disk: the index lists every expected segment with
// a sufficient frame count, and each listed segment file actually exists.
// import_media_to_bin consults this BEFORE enqueuing a background rebuild, so
// a fresh session that re-imports the same file as a previous one does not
// re-encode the whole proxy and thereby push the preview back to full-res
// source decode (lag) for the entire build. This is the segmented analog of
// proxy_valid_cache_hit's whole-file check: completion, not "any segment
// exists".
proxy_segments_complete :: proc(src: cstring, src_frames: i64) -> bool {
	idx: Proxy_Idx
	if !proxy_idx_load(src, &idx) {
		return false
	}
	defer delete(idx.segs)
	if idx.seg_frames != PROXY_SEG_FRAMES {
		return false
	}
	// Enough segments must be LISTED to cover the source (with the same
	// tolerance the whole-file path allows), and each must be present on disk.
	built: i64
	for k in 0 ..< len(idx.segs) {
		if idx.segs[k] <= 0 {
			continue
		}
		seg_buf: [4096]u8
		seg, ok := proxy_segment_path_for(src, k, seg_buf[:])
		if !ok || !os.exists(string(seg)) {
			return false
		}
		built += idx.segs[k]
	}
	return built >= src_frames - PROXY_FRAME_TOLERANCE
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

// PROXY_IDX_RECHECK_SEC bounds how often proxy_pick_for_frame re-stats the
// on-disk .idx while the playhead is ahead of the built segments. The builder
// is the only writer, so noticing a new segment a fraction of a second late
// only costs a few frames of source decode -- far cheaper than an os.stat
// syscall on every render frame.
PROXY_IDX_RECHECK_SEC :: 0.25

// proxy_resolver_entry is the single-slot destination cache kept between decodes
// so a scrub does not re-probe the on-disk index (the count is read from the idx sidecar, no re-scan)
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
	// idx_last_check throttles the .idx re-consult (an os.stat syscall) while
	// the playhead sits in unbuilt territory: a stat every frame is a real
	// syscall on the render-loop critical path, so it runs at most once per
	// PROXY_IDX_RECHECK_SEC instead.
	idx_last_check: time.Time,
	whole_proxy: [4096]u8,
	whole_valid: bool,
	// valid_k_ok + valid_k record the last segment index whose on-disk file this
	// picker CONFIRMED exists (os.exists) in this session. The built-segment fast
	// path used to stat the segment file every render frame per slot; a stat is a
	// real syscall on the render-loop critical path. Once a segment has been
	// positively validated AND chosen, it cannot vanish without the decoder's
	// next open also failing, so we only re-stat when the segment index actually
	// changes (boundary cross or index growth). A fresh source reset clears it.
	valid_k_ok:  bool,
	valid_k:     int,
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
proxy_pick_for_frame :: proc(
	src: cstring,
	src_frames: i64,
	frame: i64,
	out_buf: []u8,
	prefer_source: bool,
) -> (
	cstring,
	i64,
) {
	if !preview_proxy_enabled {
		return nil, 0
	}
	spall_scope(#procedure)
	// S5 original-rate preview: during forward playback a hw-backed decoder
	// sustains source fps (deadline: one CPU core of air left on 1080p60),
	// so serve the original instead of the lossy proxy. Scrubbing keeps
	// prefer_source=false so the gop=1 proxy still handles instant seeks.
	if prefer_source {
		return nil, 0
	}
	// Resolution per frame: source frame -> segment index.
	k := proxy_seg_for_frame(frame)

	rc := &proxy_resolver_cache
	// rc.src is a NUL-terminated [4096]u8; string([:]) keeps the full 4096-byte
	// length, so it can never equal a strlen'd cstring and the cache would reset
	// EVERY call (per-frame .idx re-read + stat thrash). Re-derive length via the
	// NUL so the comparison is real.
	same_src := string(cstring(&rc.src[0])) == string(src)
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
				// The index says this segment is built; confirm its file exists
				// ONCE per segment (not every frame). os.exists is a stat syscall
				// on the render-loop critical path -- re-statting the same segment
				// every frame whenever the playhead sits inside it is the core
				// regression from going per-frame. We only re-stat when the
				// segment index changed; a segment we already validated cannot
				// vanish without the decoder's next open also failing.
				if rc.valid_k_ok && rc.valid_k == k {
					return seg, i64(k) * PROXY_SEG_FRAMES
				}
				if !os.exists(string(seg)) {
					// The index claims this segment is built but its file is
					// gone (external removal, or cleanup without an index
					// write). Don't hand the decoder a doomed path that fails
					// reopen every frame and leaves a stale face on screen:
					// fall back to the source; a re-import/rebuild restores it.
					rc.valid_k_ok = false
					return nil, 0
				}
				rc.valid_k_ok = true
				rc.valid_k = k
				return seg, i64(k) * PROXY_SEG_FRAMES
			}
			return nil, 0
		}
		if vyper_trace {
			fmt.printf(
				"[pick] seg index %d not covered: len=%d segs=%v\n",
				k,
				len(rc.idx.segs),
				rc.idx.segs,
			)
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
		// Throttle the stat: while the playhead is ahead of the build this
		// branch is entered every frame, and an os.stat is a syscall (plus a
		// temp-arena File_Info) on the render-loop critical path. First consult
		// of a source is always due; afterwards at most once per interval.
		now := time.now()
		due :=
			!rc.idx_valid ||
			time.duration_seconds(time.since(rc.idx_last_check)) >= PROXY_IDX_RECHECK_SEC
		if due {
			rc.idx_last_check = now
			if info, serr := os.stat(string(idx_path), context.temp_allocator);
			   serr == os.ERROR_NONE && info.modification_time != rc.idx_mtime {
				delete(rc.idx.segs)
				rc.idx = {}
				rc.idx_valid = proxy_idx_load(src, &rc.idx)
				rc.idx_mtime = info.modification_time
				if vyper_trace {
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
	}

	if rc.idx_valid {
		// Segmented source, frame beyond what is built yet (still encoding, or
		// a cancelled tail): decode the source until the worker closes the gap.
		// Nothing else can serve this frame while segmentation is authoritative.
		return nil, 0
	}

	// No segmentation at all: legacy whole-proxy fast path (old mono builds +
	// the sync probe path). The blocked case is ONLY the synchronous build path
	// (probes/CI): there a whole proxy may be half-written by proxy_transcode right
	// now, and latching it would make proxy_valid_cache_hit remove it from under
	// its open handle. In live (async) mode the segmented builder never writes the
	// whole-proxy path -- it only writes segments + the .idx -- so a whole proxy
	// present here is a complete pre-existing artifact, safe to serve through the
	// entire segmented rebuild. Without this, a re-import degrades the preview to
	// full-res source decode (~200ms/frame) for the whole build even when a fine
	// proxy already exists.
	if import_bg_building_for(string(src)) && !async_import_mode {
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
	// Same NUL-terminated compare as proxy_pick_for_frame; rc.src is a [4096]u8.
	if string(cstring(&rc.src[0])) == string(src) {
		if rc.idx_valid {
			delete(rc.idx.segs)
		}
		rc^ = {}
	}
}
