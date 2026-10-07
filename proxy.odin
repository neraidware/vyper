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
// from different folders stay distinct. The naming scheme is unchanged.
//
// The suffix carries NO settings identity, deliberately. A proxy is a pure
// function of (source, encoder settings), so the settings belong in the cache
// KEY rather than in a version number someone has to remember to bump: see
// proxy_settings_hash, which folds them in automatically. A version string here
// was the obvious alternative and it is a trap -- it is a bookkeeping rule that
// is correct only if every future tuning of crf/preset/scale remembers to touch
// a filename, and the day one does not, every proxy already on disk keeps being
// served and the change silently does nothing.
PROXY_SUFFIX := ".vyperproxy.mp4"

// Proxy_Encoder is BOTH halves of the proxy-cache contract in one object: the
// identity that names the cache entry (suffix — proxy_path_for appends it to
// the source stem) and the encode settings that the cache entry was produced
// with (proxy_encode_video reads them from the same instance). The cache key's
// derivation lives with its inputs, so a settings change has one obvious place
// to bump the key (the suffix / a version stamp next to it) instead of
// silently reusing a proxy encoded with different pixels.
Proxy_Encoder :: struct {
	suffix: string, // on-disk cache class, appended to the source stem
	preset: cstring,
	tune:   cstring,
	crf:    cstring,
	gop:    i32, // keyframe gap; 1 = every frame a keyframe (all-intra scrub)
}

// Proxy_Encoder_Choice mirrors Render_Encoder_Choice: hardware encoders are
// tried first and libx264 is the guaranteed fallback. GPU is the default
// because a proxy is a background, all-intra intermediate — exactly the shape
// hardware encode is good at, and it is the path that decides whether the
// timeline can scrub a 4K source on a weak host. No UI yet; VYPER_PROXY_ENCODER
// selects it for probes and for a user whose hardware encoder misbehaves.
//
// PROXY_SUFFIX deliberately does NOT encode the choice. Both encoders produce a
// valid scrubbable proxy from the same source, and a fallback user's artifact
// is otherwise indistinguishable from a cached one — keying the cache by
// encoder would make the fallback permanent (every launch re-encodes under the
// other key) and would invalidate every existing proxy on upgrade for output
// nobody watches. Rate control also differs by encoder (crf vs a derived
// bitrate), so byte-identical output was never part of the contract.
Proxy_Encoder_Choice :: enum u32 {
	CPU,
	GPU,
}
proxy_encoder_choice := Proxy_Encoder_Choice.GPU

// PROXY_HW_BITS_PER_PIXEL sizes a hardware proxy's bitrate from its pixel
// count. Every frame is a keyframe (gop=1), so the usual "bits per second"
// intuition is misleading — what matters is bits per pixel per frame, which is
// why this is a per-pixel constant and the dimensions are multiplied in.
//
// Re-measured at 0.06 (1920x1080 source, half-resolution proxy, VYPER_PROXY_PROBE,
// 3s, artifact size and mean_abs against the decoded source frame):
//
//	0.06 ->  458 KB  mean_abs 1.7   (the old value: the quality complaint)
//	0.10 ->  740 KB  mean_abs 1.3
//	0.12 ->  879 KB  mean_abs 1.2
//	0.15 -> 1084 KB  mean_abs 1.1
//	0.20 -> 1431 KB  mean_abs 1.0
//
// 0.15 is chosen because it is the point where this path reaches the SAME
// quality as the libx264 fallback the encoder settings are tuned for
// (veryfast/crf 22 measures 1044 KB at mean_abs 1.0), at the same file size. The
// two encoders disagreeing on quality is the actual defect — a host that
// silently falls back to CPU should not get a visibly better picture than one
// that stays on the GPU. Past 0.15 the curve is flat (0.20 buys 0.1 mean_abs
// for 32% more bytes), so the extra bits buy nothing you can see while every
// one of them is paid on the decode side of every scrub.
//
// This is the constant that governs quality on any host whose hardware encoder
// works, which is most of them — preset and crf below only steer the fallback.
PROXY_HW_BITS_PER_PIXEL :: 0.15
PROXY_HW_MIN_BITRATE :: 250_000

// proxy_hw_bitrate returns the hardware rate control for a proxy of out_w x
// out_h at fps fps, derived rather than hardcoded so it tracks the proxy's own
// dimensions instead of assuming 768x432.
proxy_hw_bitrate :: proc(out_w, out_h: c.int, fps: f64) -> i64 {
	if out_w <= 0 || out_h <= 0 || fps <= 0 {
		return PROXY_HW_MIN_BITRATE
	}
	br := i64(f64(out_w) * f64(out_h) * fps * PROXY_HW_BITS_PER_PIXEL)
	return max(br, i64(PROXY_HW_MIN_BITRATE))
}

// proxy_encoder_use_hw reports whether the proxy path should try hardware
// encoders. The env override exists so the CPU fallback is reachable in a probe
// on a machine that HAS a working hardware encoder — otherwise the fallback
// only ever runs where there is no choice to make.
proxy_encoder_use_hw :: proc() -> bool {
	// No override means "use whatever proxy_encoder_choice says", which is the
	// shipped behavior; only the CPU-forcing override is debug-only.
	when ODIN_DEBUG {
		if override := os.get_env_alloc("VYPER_PROXY_ENCODER", context.temp_allocator); override == "cpu" {
			return false
		}
	}
	return proxy_encoder_choice == .GPU
}

proxy_encoder: Proxy_Encoder = {
	suffix = PROXY_SUFFIX,
	// veryfast, not ultrafast. ultrafast disables most of x264's quality
	// machinery (no deblocking strength tuning, no adaptive quantizer, coarse
	// motion search), so it throws away detail much faster than the bitrate
	// saves — which is the wrong trade once the proxy is also the thing the
	// user is reading. veryfast costs a modest slice of encode time and
	// compresses far more efficiently, so at an equal file size the picture is
	// materially better. The speed that actually matters for playback is below:
	// tune=fastdecode plus gop=1 is what makes a scrub seek instant.
	preset = "veryfast",
	tune   = "fastdecode",
	// 22, down from 26. crf is the single biggest lever on legibility here:
	// at 26 on all-intra, fine detail and text edges were quantised away
	// before they were ever scaled into the preview buffer, which is what made
	// a 1080p source look mushy at 768x432. Paired with veryfast the file
	// growth is bounded, and half-resolution already cut the pixel count ~4x
	// so there is headroom for the bits.
	crf = "22",
	gop = 1,
}

// Proxy_State is the proxy subsystem's module state: memoized cache-dir
// readiness (set true once the dir is known to exist; the mkdir is skipped on
// the hot read path but re-attempted immediately if any build fails, so a
// raced/removed dir self-heals), the picker's single-slot destination cache
// (the resolver entry, shared by proxy_pick_for_frame), and the scheduler's
// look-ahead margin (how much source footage stays proxied ahead of the
// playhead, read each scheduling tick; defaults to PROXY_MARGIN_SECONDS,
// probes/tuning override it via VYPER_PROXY_MARGIN_SECONDS).
Proxy_State :: struct {
	cache_ready: bool,
	resolver:    proxy_resolver_entry,
	sched_margin: f64,
}
proxy_state: Proxy_State = {sched_margin = PROXY_MARGIN_SECONDS}

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
	if !proxy_state.cache_ready {
		// make_directory_all returns .Exist when the dir already exists (a plain
		// idempotent success for our purpose), so treat it as ready -- otherwise
		// the cache dir ever existing beforehand disables proxying for the whole
		// session until the dir is removed.
		if err := os.make_directory_all(string(cstring(&buf[0])));
		   err == os.General_Error.None || err == os.General_Error.Exist {
			proxy_state.cache_ready = true
		} else {
			return 0, false
		}
	}
	return n, true
}

// proxy_settings_hash folds every knob that changes the artifact's BYTES into
// the cache key, chained onto the source-path hash. Returns the same value for
// identical settings and a different one the moment any of them moves, so the
// cache cannot outlive the settings that produced it.
//
// Why this exists rather than a version number in the filename: a proxy is a
// pure function of (source, settings), so the settings ARE part of its identity.
// Spelling that out means the key is correct by construction — tune crf and the
// next lookup misses and rebuilds, with no separate edit to remember. The
// failure mode it removes is silent and expensive: without it, every proxy
// already on disk is still frame-count-valid, so proxy_valid_cache_hit accepts
// it and a quality change appears to do nothing at all.
//
// The encoder CHOICE (GPU vs CPU) is deliberately NOT folded in, continuing the
// reasoning already recorded on Proxy_Encoder: both produce a valid scrubbable
// artifact, and keying on the choice would make the CPU fallback re-encode on
// every launch and would invalidate every existing proxy on upgrade. The
// settings below only steer the libx264 path; a hardware-encoder host simply
// rebuilds once when they change and is stable after.
proxy_settings_hash :: proc(h: u32) -> u32 {
	// Order and separators matter only in that a change must change the value,
	// which every field boundary does. Length-prefixing the cstrings keeps
	// ("crf" = "2") and ("crf" = "22") from colliding.
	sep: [1]u8 = {0}
	acc := hash.fnv32a(transmute([]byte)string(proxy_encoder.preset), h)
	acc = hash.fnv32a(sep[:], acc)
	acc = hash.fnv32a(transmute([]byte)string(proxy_encoder.tune), acc)
	acc = hash.fnv32a(sep[:], acc)
	acc = hash.fnv32a(transmute([]byte)string(proxy_encoder.crf), acc)
	acc = hash.fnv32a(sep[:], acc)
	// gop, the scale divisor, and the hardware bitrate constant as three
	// fixed-width little-endian i32s, hashed rather than formatted: this runs
	// once per cache lookup and a formatter here would allocate for nothing.
	// The bitrate constant earns its place in the key by the same argument as
	// crf — it decides the artifact's bytes, so a host with a working hardware
	// encoder would otherwise keep serving artifacts encoded at the old rate
	// after the constant is retuned. Scaling by 1000 keeps the float's
	// resolution below anything that could be retuned meaningfully.
	hw_scaled := i32(PROXY_HW_BITS_PER_PIXEL * 1000)
	ints: [3]i32 = {proxy_encoder.gop, PROXY_SCALE_DIVISOR, hw_scaled}
	nums: [12]u8
	for i in 0 ..< 3 {
		v := ints[i]
		nums[i * 4 + 0] = u8(v)
		nums[i * 4 + 1] = u8(v >> 8)
		nums[i * 4 + 2] = u8(v >> 16)
		nums[i * 4 + 3] = u8(v >> 24)
	}
	return hash.fnv32a(nums[:], acc)
}

// proxy_stem writes the in-cache naming stem for a source video: its basename
// minus the final extension, a '-', then the low 32 bits of FNV-1a over the
// source's (absolute) path AND the encoder settings, in hex, so distinct
// sources never collide even with identical basenames, and a settings change
// lands on a different artifact instead of reusing the previous one. Returns
// the updated offset, or (off, false) on overflow.
proxy_stem :: proc(buf: []u8, off: int, src: cstring) -> (int, bool) {
	base := path_basename(src)
	no_ext := base
	if dot := strings.last_index(base, "."); dot > 0 {
		no_ext = base[:dot]
	}
	h := hash.fnv32a(transmute([]byte)string(src))
	h = proxy_settings_hash(h)
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
	if s + len(proxy_encoder.suffix) + 1 > len(buf) {
		return "", false
	}
	copy(buf[s:s + len(proxy_encoder.suffix)], proxy_encoder.suffix)
	s += len(proxy_encoder.suffix)
	buf[s] = 0
	return cstring(&buf[0]), true
}

// PROXY_SCALE_DIVISOR is the proxy's linear downscale from the source: 2 means
// half the source width and half its height. A named constant rather than a
// literal because proxy_scale applies it and proxy_settings_hash folds it into
// the cache key — a tuning knob that is not a value cannot be part of an
// identity, and an identity missing it is exactly how a stale proxy gets served.
PROXY_SCALE_DIVISOR :: 2

// proxy_scale computes the proxy's pixel size: half the source's own
// resolution, in each axis, snapped to even. Returns the w,h for the proxy
// encoder's sws scale, or the source dims if the source is unknown/invalid.
//
// Half rather than a fixed PREVIEW-sized cap because the cap is the dominant
// limit on legibility. At 768x432 a 1080p source was being decimated to 1/4.5
// of its pixels before it was ever seen, and the glyphs and edges that make a
// frame readable were gone before the preview's own downscale had a chance to
// be the lossy step. Halving keeps every source pixel that the eye can resolve
// while still being a real reduction -- a proxy exists so the timeline can
// scrub without decoding 4K, and halving the pixel count is roughly a quarter
// of the decode and encode work, which is the win that actually matters.
//
// The PREVIEW_W/PREVIEW_H framebuffer still bounds the decoded PREVIEW, so
// letterboxing stays idempotent: a proxied frame is scaled into the same fixed
// buffer as the original would be, and the filled rectangle is identical. This
// only changes how much detail survives to be scaled down into it.
//
// Never upscales (a source below the half point keeps its own dims) because
// interpolating a small source up would inflate the file and the decode cost
// while adding no information the original did not have.
proxy_scale :: proc(src_w, src_h: c.int) -> (w, h: c.int) {
	if src_w <= 0 || src_h <= 0 {
		return PREVIEW_W, PREVIEW_H
	}
	hw := src_w / PROXY_SCALE_DIVISOR
	hh := src_h / PROXY_SCALE_DIVISOR
	// yuv420p requires even width and height; an odd half of an odd source
	// dim (e.g. 243 -> 121) would make the encode reject the buffer and leave
	// a 0-byte proxy. Snap down to even so transcoding always succeeds.
	hw = (hw / 2) * 2
	hh = (hh / 2) * 2
	// A source only a few pixels across would floor to 0, which the encoder
	// rejects for the same reason. Hold the minimum at the source's own size.
	if hw <= 0 {
		hw = src_w
	}
	if hh <= 0 {
		hh = src_h
	}
	return hw, hh
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
// video. In live editing (editor_flags.async_import_mode) it enqueues the build on the
// background worker and returns immediately -- `src_dur_us` (the source
// duration) becomes the progress denominator -- so importing never blocks on
// the transcode; the proxy appears once the worker finishes + verifies it. In
// probe/CI mode (editor_flags.async_import_mode=false) it keeps the historical synchronous
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
	if !editor_flags.preview_proxy_enabled {
		return nil
	}
	proxy, ok := proxy_path_for(src, out_buf)
	if !ok {
		return nil
	}
	if proxy_valid_cache_hit(proxy, src_frames) {
		return proxy
	}
	if editor_flags.async_import_mode {
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

// PROXY_ENCODER_VERSION is stamped into proxy .idx files by proxy_idx_store and
// required by proxy_segments_complete, so a proxy built by an older encoder is
// treated as incomplete and rebuilt on the next import instead of serving
// segments with the old behavior. Bump this whenever the encoder settings, the
// muxer path, or the segment layout change in a way that invalidates previously
// written segments. Only the current version is ever served; un-stamped indices
// (written before the stamp existed) read as version 0 and are stale.
PROXY_ENCODER_VERSION :: 1

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

proxy_build_schedule :: proc() {
	if !editor_flags.async_import_mode || !editor_flags.preview_proxy_enabled {
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
	src_frame := clip_source_frame(
		clip.source_start_frame,
		clip.timeline_start_frame,
		playhead.frame,
		clip.is_still,
		clip.src_fps,
	)
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
	seg_margin := max(1, int(proxy_state.sched_margin * fps / f64(PROXY_SEG_FRAMES)) + 1)
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
			if !clip_visible_at(
				playhead.frame,
				clip.timeline_start_frame,
				clip.source_length_frames,
			) {
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
	// enc_ver is the PROXY_ENCODER_VERSION the segments were built with; a
	// mismatch fails proxy_segments_complete and forces a rebuild. 0 when the
	// idx predates the stamp (the parser leaves this untouched and the caller
	// sees 0 != PROXY_ENCODER_VERSION).
	enc_ver: i64,
	segs:    [dynamic]i64,
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
	got_seg_frames := false
	for line in strings.split_lines(string(data), context.temp_allocator) {
		// Header lines may appear in any order before the first entry; enc_ver
		// defaults to 0 when absent (pre-stamp idx) so the caller sees a stale
		// index rather than a usable one.
		if strings.has_prefix(line, "enc_ver ") {
			if v, pok := strconv.parse_i64(line[len("enc_ver "):]); pok && v >= 0 {
				idx.enc_ver = v
			}
			continue
		}
		if !got_seg_frames {
			if strings.has_prefix(line, "seg_frames ") {
				if v, pok := strconv.parse_i64(line[len("seg_frames "):]); pok && v > 0 {
					got_seg_frames = true
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
	if !got_seg_frames {
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
	// A proxy stamped by an older encoder (or before the stamp existed) is not
	// a cache hit: its segments can carry the old encoder's defects (e.g. a
	// zero-duration last-sample tail). Force a rebuild instead of serving it.
	if idx.enc_ver != PROXY_ENCODER_VERSION {
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
	fmt.sbprintf(&sb, "enc_ver %d\n", PROXY_ENCODER_VERSION)
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
	if !editor_flags.preview_proxy_enabled {
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

	rc := &proxy_state.resolver
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
		when ODIN_DEBUG {
			if vyper_trace {
				fmt.printf(
					"[pick] seg index %d not covered: len=%d segs=%v\n",
					k,
					len(rc.idx.segs),
					rc.idx.segs,
				)
			}
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
				when ODIN_DEBUG {
					if vyper_trace {
						fmt.printf("[pick] reloaded idx valid=%v len=%d\n", rc.idx_valid, len(rc.idx.segs))
					}
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
	if import_bg_building_for(string(src)) && !editor_flags.async_import_mode {
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
	rc := &proxy_state.resolver
	// Same NUL-terminated compare as proxy_pick_for_frame; rc.src is a [4096]u8.
	if string(cstring(&rc.src[0])) == string(src) {
		if rc.idx_valid {
			delete(rc.idx.segs)
		}
		rc^ = {}
	}
}
