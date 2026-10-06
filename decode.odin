package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import avcodec "vendor/ffmpeg/avcodec"
import avfmt "vendor/ffmpeg/avformat"
import avutil "vendor/ffmpeg/avutil"
import sws "vendor/ffmpeg/swscale"

// Clip_Decoder wraps one open FFmpeg input + decoder + scaler. It keeps the
// source file open across calls so sequential playback decodes forward without
// re-seeking; a jump to a non-consecutive frame triggers a keyframe seek.
//
// CRITICAL INVARIANT — READ BEFORE TOUCHING last_frame/have_last:
//
//   last_frame is supposed to mirror WHERE THE PHYSICAL FFMPEG DECODER IS
//   PARKED, not merely "the newest frame index somebody rendered". The H.264
//   decoder is inherently sequential: after it has produced frame N it will
//   produce N+1 next from the exact in-file position it stopped at. The only
//   way to read an earlier frame is a seek (avformat.seek_frame + flush).
//
//   The forward fast-path in decode_source_frame relies on this: it only
//   decodes "the next frame" when frame_idx == last_frame + 1, ASSUMING the
//   physical decoder is currently parked at last_frame. If you ever set
//   last_frame to a value that is AHEAD of the physical decoder position, the
//   next forward request will decode from the true (behind) position but LABEL
//   the result with the requested (ahead) index — wrong pixels served and
//   cached under a shifted key. That is exactly the classic bug where, at a
//   flush (no-gap) clip boundary, a stable wrong image plays whose content
//   belongs to an earlier/deleted clip region and only "fixes" for a frame
//   or two whenever a re-seek lands.
//
//   RULES:
//     * Only advance last_frame to a frame the decoder ACTUALLY produced
//       (forward decode or a seek that landed on it).
//     * A cache hit that does NOT reposition the decoder must therefore NOT
//       advance last_frame past the decoder's true position. See the guard in
//       decode_clip_frame_sync.
//     * If you add a new write to last_frame/have_last, prove the physical
//       decoder is consistent with it, or reuse the guard below.
//
// TODO(per TODO.md): promote this to a per-asset decoder cache with a bounded
// rolling frame pool once real-time multi-track composition lands.
Clip_Decoder :: struct {
	opened:      bool,
	path:        cstring,
	// preview_path is the actual file opened by open_clip_decoder (the proxy
	// when one exists and is parity-valid, or `path` itself when no proxy is
	// present). `path` is always the SOURCE path and used as the identity key
	// for the no-reopen guard in decode_clip_frame_sync. preview_path is never
	// used as an identity -- it is purely the decode target. preview_path_buf
	// owns the bytes so the decoder survives the caller's stack going away.
	preview_path:      cstring,
	preview_path_buf:  [4096]u8,
	// opened_path is the PHYSICAL file the format context actually has open --
	// the proxy (possibly one segment of a segmented proxy) or the source. A
	// segmented proxy serves each source frame from a different file, so the
	// reopen guard must compare against what is REALLY open, not just the
	// source identity in `path`.
	opened_path:       cstring,
	opened_path_buf:   [4096]u8,
	// frame_base is the SOURCE index this file's frame 0 corresponds to: 0 for
	// the source or a whole-file proxy, k*PROXY_SEG_FRAMES for a proxy segment.
	// Requests carry SOURCE indices; they are translated to file-local before
	// seeking/caching in decode_clip_frame_sync / vdec_decode.
	frame_base:        i64,
	fmt_ctx:     ^avfmt.FormatContext,
	dec_ctx:     ^avcodec.CodecContext,
	video_idx:   c.int,
	stream:      ^avfmt.Stream,
	sws_ctx:     ^sws.Context,
	src_w, src_h: c.int,
	fps_num:     c.int,
	fps_den:     c.int,
	// Decoder owns these allocations.
	frame:       ^avutil.Frame,
	// hold caches the most recently decoded frame whose PTS is still at/below
	// the seek target, so the forward decode loop can hand back the LAST frame
	// at/before the target instead of the first one past it (exact for VFR and
	// for any rate-mapping one-frame overshoot).
	hold:        ^avutil.Frame,
	pkt:         ^avcodec.Packet,
	// Hardware decode state: hw_pix_fmt != .None when the codec opened with a
	// hardware device context. Each delivered hw frame is transferred to
	// sw_frame (in scale_decoded_frame) before touching the existing RGBA sws
	// path. sw_frame is a PERSISTENT transfer destination: it keeps its buffer
	// between frames so av_hwframe_transfer_data reuses it instead of taking
	// its allocate-a-fresh-sw-frame path on every frame.
	hw_pix_fmt:  avutil.PixelFormat,
	hw_device:   ^avutil.BufferRef,
	sw_frame:    ^avutil.Frame,
	// dst is the fixed-size RGBA console buffer written by sws. dst honors the
	// source aspect ratio (the source is fit, not stretched, into PREVIEW_W x
	// PREVIEW_H) and fit_ox/fit_oy are the letterbox offsets in buffer pixels.
	dst:          [4][^]u8,
	dst_linesize: [4]c.int,
	dst_w, dst_h: c.int,
	fit_ox, fit_oy: c.int,
	// Render-path decode crop: which sub-rect of the decoded FRAME fills the
	// clip's on-canvas region. Set by the render worker before open; the zero
	// value (crop_fw/crop_fh <= 0) decodes the full frame like every other
	// consumer. crop_f* are fractions of the frame (0..1); crop_px_* resolve
	// them to integer source pixels once src_w/src_h are known; crop_dst_*
	// are the region's integer placement into the full-box blit (output px);
	// crop_full_* the clip's full box. crop_dropped records that the frame
	// format is not in the x-crop plane-offset table, so the decode ran
	// uncropped and render_blit keeps its sampling path.
	crop_fx0, crop_fy0, crop_fw, crop_fh: f32,
	crop_px_x, crop_px_y, crop_px_w, crop_px_h: c.int,
	crop_dst_x, crop_dst_y, crop_dst_w, crop_dst_h: c.int,
	crop_full_w, crop_full_h: c.int,
	crop_dropped:           bool,
	// last_frame is the index of the source frame the physical FFmpeg decoder
	// is CURRENTLY parked on (see the struct invariant above). A request for
	// last_frame+1 decodes forward in place; anything else forces a re-seek.
	// MUST track the physical decoder position — never over-claim it.
	// NOTE: physically the decoder parks at FILE-LOCAL index (frame_idx -
	// frame_base); last_frame stores the LOCAL index so forward steps are one
	// frame unit apart regardless of which segment is open.
	last_frame:   i64,
	// have_last reports whether last_frame is valid (decoder has produced at
	// least one frame since the last reset/seek). Mirrors last_frame's rule.
	// seek_count is diagnostic only, never read by the decode logic. It exists so
	// a probe can assert that serving a request did NOT re-seek — which is
	// otherwise unobservable, since a re-seek to the same frame lands on the same
	// frame and leaves every visible field identical. Without it, "we no longer
	// seek on every held frame" is a claim about performance with no way to test
	// it, and the AV1 reference-frame failures it caused were invisible for the
	// same reason.
	seek_count:  i64,
	have_last:    bool,
	// PTS (stream time base) of the most recently produced frame; used by the
	// frame-check probe to verify the seek path lands on the requested index.
	last_emitted_ts: c.int64_t,
	// decoded_ahead counts frames received since the last seek, so a
	// forward request knows it only needs to pull the next frame.
	decoded_ahead: i64,
	// EOF-tail queue. When the demuxer reports EOF, the decoder's reorder
	// buffer (B-frame display delay) still holds the last frames of the
	// stream; they only surface after avcodec_send_packet NULL + drain. The
	// drain moves them here, one per decode_one_forward call, so the tail is
	// never silently dropped. eof_drained latches that the flush ran (a
	// second send NULL is rejected by avcodec). Dynamic: the reorder depth is
	// decoder-version-dependent, unbounded by has_b_frames alone, and this is
	// a cold path at stream end -- grow-only is honest here.
	eof_tail:     [dynamic]^avutil.Frame,
	eof_tail_pos: int,
	eof_drained:  bool,
	// Bounded RAM cache of decoded frames (RGBA, tightly packed). Keeps the
	// decoded frame data resident in memory and avoids re-decoding recent
	// frames when the playhead moves back a little. Evicts the LEAST
	// RECENTLY TOUCHED entry on write once at capacity (see cache_clock).
	// NOTE: the cache key is a frame index, UNRELATED to last_frame. A cache
	// hit returns pixels WITHOUT moving the physical decoder — which is why
	// cache hits must use the last_frame guard, never a blind assignment.
	cache:         [dynamic]Frame_Cache_Entry,
	// cache_clock is a per-decoder monotonic counter, incremented on every
	// cache_find hit and cache_store touch, and stamped onto the touched
	// entry's last_touch. This is what makes eviction genuinely
	// least-recently-used: comparing last_touch values orders entries by
	// recency. A plain "times used" counter that only ever increments (the
	// previous design) is NOT LRU -- an entry visited many times early in a
	// session accumulates a use-count that can never be beaten by later
	// entries (which all start at 1), so it squats in the cache forever even
	// after becoming irrelevant, silently degrading the cache over a long
	// session despite comments elsewhere claiming LRU/oldest-evicted
	// behavior.
	cache_clock:   u64,
}

// Frame_Cache_Entry is one cached decoded RGBA frame plus a recency stamp
// (see Clip_Decoder.cache_clock) for true LRU eviction. Pixel data lives in a
// separate heap buffer so the header stays small (no 1.3MB by-value copies).
Frame_Cache_Entry :: struct {
	frame:      i64,
	last_touch: u64,
	data:       []u8,
}

frame_cache_clear :: proc(dec: ^Clip_Decoder) {
	for &e in dec.cache {
		delete(e.data)
	}
	// delete, NOT clear: Odin's clear empties a dynamic array but KEEPS its
	// backing store, and the only caller (clip_decoder_reset) then wipes the
	// struct with `dec^ = {}`, which drops the pointer on the floor. clear here
	// leaked the cache's whole capacity on every reset -- 271 bytes per decoded
	// clip, reported by render_valgrind as a lost block in cache_store.
	delete(dec.cache)
}

ff_err_str :: proc(code: c.int) -> string {
	buf: [avutil.AV_ERROR_MAX_STRING_SIZE]c.char
	avutil.strerror(code, &buf[0], size_of(buf))
	return strings.clone_from_cstring(cstring(&buf[0]), context.temp_allocator)
}

// hw_decode_enabled gates hardware decode globally; disabled by default --
// empirically VAAPI decode+transfer here is ~4x slower than 4-threaded
// software decode (7.7ms/f vs 1.9ms/f producer), so the GPU path is opted in
// via VYPER_HW_ENABLE=1 where it wins (weak CPU/strong GPU).
// `VYPER_HW_ENABLE=1` forces the hardware path; the hw probe (VYPER_HW_PROBE)
// toggles both to verify they produce identical pixels.
hw_decode_enabled: bool = false

// find_hw_decoder returns the decoder to use for a codec id, preferring one with
// hardware configs. find_decoder() returns the FIRST registered decoder for the
// id, which for AV1 is libdav1d (software-only, no hw configs); the native "av1"
// decoder carries the vaapi/cuda configs but registered later. The by-name
// lookup (avcodec's canonical lowercase name) is what the CLI picks for hwaccel.
// Falls back to the plain find_decoder() result, since that is correct for
// h264/vp9/etc. and the fallback is the old behavior.
find_hw_decoder :: proc(codec_id: avcodec.CodecID) -> ^avcodec.Codec {
	if !hw_decode_enabled {
		// Software mode: the plain id lookup (libdav1d for AV1) is fast and
		// correct; the native decoder is only needed to reach hw configs.
		return avcodec.find_decoder(codec_id)
	}
	codec := avcodec.find_decoder(codec_id)
	if codec != nil {
		for i: c.int = 0; ; i += 1 {
			cfg := avcodec.get_hw_config(codec, i)
			if cfg == nil {
				break
			}
			if .HW_Device_Ctx in cfg.methods {
				return codec
			}
		}
	}
	if better := avcodec.find_decoder_by_name(avcodec.get_name(codec_id)); better != nil {
		return better
	}
	return codec
}

// asset_source_hw returns whether THIS asset's SOURCE file opens with a
// hardware decoder on this machine, probing once and latching the answer for
// the session. Its consumer is the S5 original-rate pick: during forward
// playback, serve the source instead of the proxy only when the source itself
// is hw-backed. The gate must NOT read the hw state of whatever file is
// currently open in a slot's decoder -- picking the source opens it, which
// changes its hw_pix_fmt, which flips the gate, which reopens the proxy, and
// so on, reopening both decoders every frame wherever source and proxy differ
// in hw support (e.g. a source VAAPI declines + a proxy it accepts). A stable
// per-asset latch breaks the feedback loop.
asset_source_hw :: proc(a: ^Media_Asset) -> bool {
	if a.src_hw_known {
		return a.src_hw
	}
	a.src_hw_known = true
	if a.path == nil {
		return false
	}
	probe: Clip_Decoder
	defer clip_decoder_reset(&probe)
	if !open_clip_decoder(&probe, a.path) {
		return false
	}
	a.src_hw = probe.hw_pix_fmt != .None
	return a.src_hw
}

// clip_decoder_release_ffmpeg frees every ffmpeg-owned resource a decoder holds
// and NULLs each pointer, so calling it twice is safe.
//
// Split out of clip_decoder_reset and deliberately NOT gated on `dec.opened`:
// that flag means "usable", not "acquired", and open_clip_decoder_ex can fail
// AFTER allocating the format context, the codec context, the scaler and the
// destination image. Gating on `opened` meant every one of those early-return
// paths leaked the lot -- the ownership model claimed they were released
// because the caller defers a reset, while the reset itself skipped them.
//
// The frees are pointer tests, not a flag, because the pointers are the thing
// actually owned. `dst` is the one that was simply missing: avutil.image_alloc
// gave the decoder its RGBA destination buffer and nothing ever freed it, which
// is the 1.3 MB per thumbnail the render_valgrind gate reported.
clip_decoder_release_ffmpeg :: proc(dec: ^Clip_Decoder) {
	if dec.fmt_ctx != nil {
		avfmt.close_input(&dec.fmt_ctx)
	}
	if dec.dec_ctx != nil {
		avcodec.free_context(&dec.dec_ctx)
	}
	if dec.sws_ctx != nil {
		sws.freeContext(dec.sws_ctx)
		dec.sws_ctx = nil
	}
	if dec.dst[0] != nil {
		avutil.freep(&dec.dst[0])
		dec.dst[0] = nil
	}
	if dec.frame != nil {
		avutil.frame_free(&dec.frame)
	}
	if dec.hold != nil {
		avutil.frame_free(&dec.hold)
	}
	if dec.pkt != nil {
		avcodec.packet_free(&dec.pkt)
	}
	if dec.sw_frame != nil {
		avutil.frame_free(&dec.sw_frame)
	}
	if dec.hw_device != nil {
		avutil.buffer_unref(&dec.hw_device)
	}
}

clip_decoder_reset :: proc(dec: ^Clip_Decoder) {
	if vyper_trace {
		fmt.printf("[dec] RESET cache_len=%d opened=%v\n", len(dec.cache), dec.opened)
	}
	clip_decoder_release_ffmpeg(dec)
	frame_cache_clear(dec)
	// Drop any EOF-tail frames parked by decode_one_forward. Each is a cloned
	// avutil.Frame owning its buffer; frame_free the shell, then the slice.
	for &f in dec.eof_tail {
		avutil.frame_free(&f)
	}
	delete(dec.eof_tail)
	// Wipe fully: neither path nor preview_path survives a reset. Callers that
	// want a proxy re-supply it via decoder_set_preview before the next
	// decode; every caller that leaves preview_path nil decodes the source
	// (probes, ground-truth checks, render), preserving test symmetry.
	dec^ = {}
}

FRAME_CACHE_CAPACITY :: 24

// cache_find returns cached RGBA data for a frame, or nil.
// IMPORTANT: a cache hit returns pixels WITHOUT moving the physical FFmpeg
// decoder. That is the whole subtlety behind the last_frame guard in
// decode_clip_frame_sync: the cache can legitimately hold a frame the decoder
// has already played past, so finding pixels for frame_idx says NOTHING about
// where the decoder is parked. Do not use a hit to reposition last_frame.
cache_find :: proc(dec: ^Clip_Decoder, frame_idx: i64) -> []u8 {
	for i := 0; i < len(dec.cache); i += 1 {
		if dec.cache[i].frame == frame_idx {
			dec.cache_clock += 1
			dec.cache[i].last_touch = dec.cache_clock
			return dec.cache[i].data
		}
	}
	return nil
}

// cache_store inserts/updates a cached frame, evicting the LEAST RECENTLY
// TOUCHED entry (freeing its buffer, well, reusing it) when at capacity.
cache_store :: proc(dec: ^Clip_Decoder, frame_idx: i64, data: []u8) {
	if frame_idx < 0 {
		return
	}
	dec.cache_clock += 1
	for i := 0; i < len(dec.cache); i += 1 {
		if dec.cache[i].frame == frame_idx {
			copy(dec.cache[i].data, data)
			dec.cache[i].last_touch = dec.cache_clock
			return
		}
	}
	if len(dec.cache) < FRAME_CACHE_CAPACITY {
		buf := make([]u8, PREVIEW_W * PREVIEW_H * 4)
		copy(buf, data)
		append(&dec.cache, Frame_Cache_Entry{frame = frame_idx, last_touch = dec.cache_clock, data = buf})
		return
	}
	// Evict the least recently touched entry, reusing its buffer.
	evict := 0
	oldest := dec.cache[0].last_touch
	for i := 1; i < len(dec.cache); i += 1 {
		if dec.cache[i].last_touch < oldest {
			oldest = dec.cache[i].last_touch
			evict = i
		}
	}
	copy(dec.cache[evict].data, data)
	dec.cache[evict].frame = frame_idx
	dec.cache[evict].last_touch = dec.cache_clock
}

// open_clip_decoder opens the file's best video stream for interactive preview,
// fitting it letterbox-style into the fixed PREVIEW_W x PREVIEW_H buffer.
open_clip_decoder :: proc(dec: ^Clip_Decoder, path: cstring) -> bool {
	return open_clip_decoder_ex(dec, path, -1, PREVIEW_W, PREVIEW_H, true)
}

// footage_video_stream returns the first video stream whose disposition is not
// an attached picture (embedded cover art), or -1 when a file carries only
// cover art. Covers demux as AVStreams that some demuxers never register as
// real streams — seeking them is a crash — and they hold no playable frames.
footage_video_stream :: proc(fmt_ctx: ^avfmt.FormatContext) -> c.int {
	for i in 0 ..< int(fmt_ctx.nb_streams) {
		s := fmt_ctx.streams[i]
		if s == nil || s.codecpar == nil {
			continue
		}
		if s.codecpar.codec_type != avutil.MediaType.Video {
			continue
		}
		if .Attached_Pic in s.disposition {
			continue
		}
		return c.int(i)
	}
	return -1
}

// open_clip_decoder_ex opens a video stream (stream_index >= 0 selects the
// stream_index-th video stream, -1 picks the best one) and scales every decoded
// frame into a dst_w x dst_h RGBA buffer. When fit is true the source is
// letterboxed (aspect-preserving) inside dst (preview path); otherwise the full
// source is scaled to exactly dst (render path, where dst already matches the
// clip's on-canvas display size).
open_clip_decoder_ex :: proc(dec: ^Clip_Decoder, path: cstring, stream_index: c.int, dst_w, dst_h: c.int, fit: bool) -> bool {
	// The caller may have pre-resolved dec.preview_path to a proxy for THIS
	// open (decoder_set_preview set it before calling here). The reopen below
	// discards decoder state wholesale, which would wipe that target and make
	// every reopen at a segment boundary fall back to the source -- the
	// "preview flips to the original and stays there" bug. preview_path/frame_base
	// are the decode TARGET (re-supplied by the caller every open), not decoder
	// state, so carry them across the reset and restore them before choosing
	// the physical file. A nil/empty preview_path means decode the source.
	//
	// dec.preview_path points INTO dec.preview_path_buf, which the reset wipes,
	// so stage the bytes in a local buffer first -- restoring from the aliased
	// cstring would copy the zeroed buffer back out (an empty open path).
	preview_buf: [4096]u8
	preview_len := 0
	have_preview := dec.preview_path != nil && string(dec.preview_path) != "" && string(dec.preview_path) != string(path)
	if have_preview {
		src_s := string(dec.preview_path)
		preview_len = min(len(src_s), len(preview_buf) - 1)
		copy(preview_buf[:preview_len], src_s[:preview_len])
		preview_buf[preview_len] = 0
	}
	// The render worker's decode crop is also a decode TARGET (caller-owned,
	// re-supplied every open), not decoder state: carry it across the reset so
	// a reopen keeps cropping instead of silently decoding the full box again.
	crop_fx0, crop_fy0, crop_fw, crop_fh := dec.crop_fx0, dec.crop_fy0, dec.crop_fw, dec.crop_fh
	crop_dst_x, crop_dst_y, crop_dst_w, crop_dst_h := dec.crop_dst_x, dec.crop_dst_y, dec.crop_dst_w, dec.crop_dst_h
	crop_full_w, crop_full_h := dec.crop_full_w, dec.crop_full_h
	saved_base := dec.frame_base
	if dec.opened {
		clip_decoder_reset(dec)
	}
	// Unwind on every failure return below. This proc acquires the format
	// context, the codec context, the scaler, the destination image and two
	// frames in sequence, and each step after the first can fail; without this
	// the caller's deferred reset was the only unwind, and the reset skipped a
	// decoder that never reached `opened`. Deferred rather than written at each
	// return: there are seven, and the ones added later are exactly the ones
	// that would leak. Cancelled on success (below) because a live decoder must
	// survive this proc returning.
	opened_ok := false
	defer if !opened_ok {
		clip_decoder_release_ffmpeg(dec)
	}

	// Which physical file to open. For the PREVIEW path (fit=true) the caller
	// may have pre-resolved dec.preview_path to a low-res all-intra proxy for
	// fast scrubbing; when set, open that instead of the source. The render
	// path (fit=false) and every direct caller that leaves preview_path == path
	// (probes, ground-truth checks) always decode the ORIGINAL so fidelity and
	// test symmetry are preserved.
	open_path := path
	if fit && have_preview {
		// clip_decoder_reset above wiped preview_path; restore the caller's
		// decode target so the open (and the reopen guard's identity compare)
		// sees the file this decoder is supposed to be serving.
		copy(dec.preview_path_buf[:preview_len], preview_buf[:preview_len])
		dec.preview_path_buf[preview_len] = 0
		dec.preview_path = cstring(&dec.preview_path_buf[0])
		open_path = dec.preview_path
	} else if fit && dec.preview_path != "" && dec.preview_path != path {
		open_path = dec.preview_path
	}
	dec.frame_base = saved_base
	dec.crop_fx0, dec.crop_fy0, dec.crop_fw, dec.crop_fh = crop_fx0, crop_fy0, crop_fw, crop_fh
	dec.crop_dst_x, dec.crop_dst_y, dec.crop_dst_w, dec.crop_dst_h = crop_dst_x, crop_dst_y, crop_dst_w, crop_dst_h
	dec.crop_full_w, dec.crop_full_h = crop_full_w, crop_full_h

	fmt_ctx: ^avfmt.FormatContext
	if ret := avfmt.open_input(&fmt_ctx, open_path, nil, nil); ret < 0 {
		fmt.println("avformat_open_input:", ff_err_str(ret))
		return false
	}
	dec.fmt_ctx = fmt_ctx
	if ret := avfmt.find_stream_info(fmt_ctx, nil); ret < 0 {
		fmt.println("avformat_find_stream_info:", ff_err_str(ret))
		return false
	}
	idx: c.int = -1
	if stream_index >= 0 {
		// Count video streams until the requested index is reached. Attached
		// pictures (embedded cover art) are metadata, not footage — an Ogg/Opus
		// file carrying one demuxes its cover into an AVStream that is no real
		// Ogg stream, and seeking it aborts the demuxer.
		seen := c.int(0)
		for i in 0 ..< int(fmt_ctx.nb_streams) {
			s := fmt_ctx.streams[i]
			if s == nil || s.codecpar == nil {
				continue
			}
			if s.codecpar.codec_type != avutil.MediaType.Video {
				continue
			}
			if .Attached_Pic in s.disposition {
				continue
			}
			if seen == stream_index {
				idx = c.int(i)
				break
			}
			seen += 1
		}
	}
	if idx < 0 {
		idx = avfmt.find_best_stream(fmt_ctx, .Video, -1, -1, nil, 0)
		if idx >= 0 && .Attached_Pic in fmt_ctx.streams[idx].disposition {
			idx = footage_video_stream(fmt_ctx)
		}
	}
	if idx < 0 {
		fmt.println("no video stream:", ff_err_str(idx))
		return false
	}
	dec.video_idx = idx
	dec.stream = fmt_ctx.streams[idx]

	par := dec.stream.codecpar
	codec := find_hw_decoder(par.codec_id)
	if codec == nil {
		fmt.println("no decoder for codec", avcodec.get_name(par.codec_id))
		return false
	}
	dec_ctx := avcodec.alloc_context3(codec)
	if dec_ctx == nil {
		fmt.println("avcodec_alloc_context3 failed")
		return false
	}
	dec.dec_ctx = dec_ctx
	if ret := avcodec.parameters_to_context(dec_ctx, par); ret < 0 {
		fmt.println("avcodec_parameters_to_context:", ff_err_str(ret))
		return false
	}
	// Hardware decode: pick the codec's first HW_Device_Ctx config, create the
	// device, and attach it to the codec context. The decoder then negotiates
	// hardware frames automatically (its default get_format path). A deviceless
	// run (no driver/device) falls back to pure software: hw_pix_fmt stays
	// .None and the rest of the file is byte-identical to the old path.
		hw_pix_fmt: avutil.PixelFormat = .None
	if !hw_decode_enabled {
		// Probe comparison: pure software path.
		dec.hw_pix_fmt = hw_pix_fmt
	} else {
		for i: c.int = 0; ; i += 1 {
			cfg := avcodec.get_hw_config(codec, i)
			if cfg == nil {
				break
			}
			if .HW_Device_Ctx not_in cfg.methods {
				continue
			}
			// h264's hw config list leads with NVIDIA's CUDA entry. On a host
			// without libcuda the device-create probe fails in a way libav logs at
			// ERROR ("Cannot load libcuda.so.1", "Could not dynamically load
			// CUDA") even though the absence is expected and handled below (we
			// continue to the next config). Suppress all avutil logging for the
			// brief duration of the create call — no other avutil logging can
			// fire during this single-threaded probe window.
			probe_level := avutil.log_get_level()
			avutil.log_set_level(.Quiet)
			dev_ref: ^avutil.BufferRef
			create_ok := avutil.hwdevice_ctx_create(&dev_ref, cfg.device_type, nil, nil, 0)
			avutil.log_set_level(probe_level)
			if create_ok != 0 {
				// Driver/device absent (e.g. CUDA with no libcuda): try the next
				// hw config before falling back to software.
				continue
			}
			hw_pix_fmt = cfg.pix_fmt
			dec.hw_device = dev_ref
			dec_ctx.hw_device_ctx = avutil.buffer_ref(dev_ref)
			dec.sw_frame = avutil.frame_alloc()
			fmt.printf("decoded %s via %s hw output %d\n",
				avcodec.get_name(par.codec_id),
				avutil.hwdevice_get_type_name(cfg.device_type),
				c.int(hw_pix_fmt))
			break
		}
		dec.hw_pix_fmt = hw_pix_fmt
	}
	if hw_pix_fmt == .None {
		// Software decoder defaults to a single thread; frame threading splits
		// the decode across cores. Hardware decoders must not thread the codec.
		// 4 is the practical ceiling: decoded-frame threading flattens after
		// ~3 threads at 1080p, more threads only adds dispatch overhead.
		dec_ctx.thread_count = 4
	}
	if ret := avcodec.open2(dec_ctx, codec, nil); ret < 0 {
		fmt.println("avcodec_open2:", ff_err_str(ret))
		return false
	}
	// For software decode the sws source format is the native codec pix_fmt and
	// the scaler can be built up front. For hardware decode the transferred sw
	// frame's format is only known after the first frame (VAAPI -> NV12, etc.),
	// so sws is built lazily in scale_decoded_frame from the actual frame.
	dec.src_w = dec_ctx.width
	dec.src_h = dec_ctx.height

	// Render-path decode crop: resolve the worker's requested sub-rect (see
	// dec.crop_f*) to source pixels, then size dst to the on-canvas region.
	// The buffer allocation stays FULL box below so the crop-dropped fallback
	// (uncropable frame format) has room; dec.dst_w/h select which part the
	// scale writes and decode_into_buffer copies into the full-box blit.
	have_crop := dec.crop_fw > 0 && dec.crop_fh > 0
	dec.crop_px_x, dec.crop_px_y, dec.crop_px_w, dec.crop_px_h = 0, 0, 0, 0
	dec.crop_dropped = false
	if have_crop {
		// Software decode knows its frame format here: formats outside the
		// x-crop plane-offset table decode the full box and render_blit
		// samples it (see src_crop_plane_offsets). Hardware decode defers the
		// same check to scale_decoded_frame, where the transferred frame's
		// format first appears (VAAPI -> NV12, etc. are all in the table).
		if hw_pix_fmt == .None {
			if _, _, _, croppable := src_crop_plane_offsets(dec_ctx.pix_fmt, 0); !croppable {
				have_crop = false
				dec.crop_dropped = true
			}
		}
	}
	if have_crop {
		dec.crop_px_x, dec.crop_px_y, dec.crop_px_w, dec.crop_px_h = dec_crop_px(dec, dec.src_w, dec.src_h)
	}

	// Fit the source into the fixed preview buffer preserving its aspect, so a
	// video whose aspect differs from the project's canvas is letterboxed
	// instead of stretched. Render path (fit=false) uses the exact dst dims.
	if fit {
		dec.dst_w, dec.dst_h, dec.fit_ox, dec.fit_oy = source_fit_in_buffer(dec.src_w, dec.src_h, dst_w, dst_h)
	} else if have_crop {
		// dst is the on-canvas region, placed into the full-box blit at
		// crop_dst_x/y by decode_into_buffer. render_blit direct-copies the
		// same region back out — see Render_Video_Src.crop_px_w.
		dec.dst_w = dec.crop_dst_w
		dec.dst_h = dec.crop_dst_h
		dec.fit_ox = dec.crop_dst_x
		dec.fit_oy = dec.crop_dst_y
		if vyper_trace {
			fmt.printf("[dec] crop-render src(%d,%d %dx%d) dst %dx%d @ (%d,%d)\n",
				dec.crop_px_x, dec.crop_px_y, dec.crop_px_w, dec.crop_px_h,
				dec.dst_w, dec.dst_h, dec.fit_ox, dec.fit_oy)
		}
	} else {
		dec.dst_w = dst_w
		dec.dst_h = dst_h
		dec.fit_ox = 0
		dec.fit_oy = 0
	}

	// Prefer the stream's r_frame_rate for index<->PTS mapping: it is the true
	// constant frame rate for CFR content, whereas avg_frame_rate is a nominal
	// container average that is frequently truncated/miscalculated (e.g. a
	// 60fps file reporting 302/5 => 60.4). Using the exact rate keeps
	// frames_to_stream_ts from drifting, which is what returned wrong source
	// frames on scrub for odd files. r_frame_rate can be the max rate on true
	// VFR, so only accept it when it looks constant; otherwise fall back to avg.
	fps := dec.stream.r_frame_rate
	if fps.num <= 0 || fps.den <= 0 {
		fps = dec.stream.avg_frame_rate
	}
	if fps.num <= 0 || fps.den <= 0 {
		fps = {25, 1}
	}
	dec.fps_num = fps.num
	dec.fps_den = fps.den

	if hw_pix_fmt == .None {
		// The sws source window is the crop region itself when cropping:
		// scale_decoded_frame hands sws the advanced plane pointers plus a
		// slice from row 0 of that window (0 + crop_h == ctx height, which is
		// the FFmpeg-9-valid "start of frame" slice), so the ctx dims must
		// match the cropped extents or sws would scale past the source.
		sw, sh := dec.src_w, dec.src_h
		if have_crop {
			sw, sh = dec.crop_px_w, dec.crop_px_h
		}
		dec.sws_ctx = sws.getContext(
			sw, sh, dec_ctx.pix_fmt,
			dec.dst_w, dec.dst_h, avutil.PixelFormat.RGBA,
			sws.Flags{.Bilinear}, nil, nil, nil,
		)
		if dec.sws_ctx == nil {
			fmt.println("sws_getContext failed")
			return false
		}
	}
	// Allocate the FULL box even when cropping: the crop-dropped fallback
	// (uncropable frame format) decodes the whole frame and needs the space.
	alloc_w, alloc_h := dec.dst_w, dec.dst_h
	if have_crop {
		alloc_w, alloc_h = dec.crop_full_w, dec.crop_full_h
	}
	if avutil.image_alloc(&dec.dst[0], &dec.dst_linesize[0], alloc_w, alloc_h, avutil.PixelFormat.RGBA, 1) < 0 {
		fmt.println("av_image_alloc failed")
		return false
	}
	dec.frame = avutil.frame_alloc()
	dec.hold = avutil.frame_alloc()
	dec.pkt = avcodec.packet_alloc()
	dec.opened = true
	// Everything is acquired; the deferred unwind above must not run, or it
	// would free the decoder this call is handing back.
	opened_ok = true
	ops := string(open_path)
	on := min(len(ops), len(dec.opened_path_buf) - 1)
	copy(dec.opened_path_buf[:on], ops[:on])
	dec.opened_path_buf[on] = 0
	dec.opened_path = cstring(&dec.opened_path_buf[0])
	fmt.printf("decoded %dx%d (%dx%d) @ %d/%d fps\n", dec.src_w, dec.src_h, dec.dst_w, dec.dst_h, dec.fps_num, dec.fps_den)
	return true
}

// seek_to_source_frame seeks the input to the keyframe at/before the given
// source frame index so a subsequent forward decode reaches the target.
seek_to_source_frame :: proc(dec: ^Clip_Decoder, frame_idx: i64) -> bool {
	// Convert frame index to a timestamp in the stream time base.
	ts := frames_to_stream_ts(dec, frame_idx)
	// Seek just before the target keyframe boundary.
	if ret := avfmt.seek_frame(dec.fmt_ctx, dec.video_idx, ts, avfmt.SeekFlags{.Backward}); ret < 0 {
		fmt.println("av_seek_frame:", ff_err_str(ret))
		return false
	}
	avcodec.flush_buffers(dec.dec_ctx)
	dec.seek_count += 1
	dec.decoded_ahead = 0
	// A seek repositions the decoder; any EOF-tail frames parked by
	// decode_one_forward belong to the OLD position and must not be served
	// for a new scrub target. Drop them and allow a fresh EOF drain.
	for &f in dec.eof_tail {
		avutil.frame_free(&f)
	}
	clear(&dec.eof_tail)
	dec.eof_tail_pos = 0
	dec.eof_drained = false
	return true
}

// frames_to_stream_ts converts a frame index to the stream time base using the
// source average frame rate.
frames_to_stream_ts :: proc(dec: ^Clip_Decoder, frame_idx: i64) -> c.int64_t {
	return avutil.rescale_q(
		c.int64_t(frame_idx),
		avutil.Rational{num = dec.fps_den, den = dec.fps_num},
		dec.stream.time_base,
	)
}

// decode_one_forward pulls exactly one decoded video frame. Returns true when a
// frame was produced. Uses dec.video_idx and skips other packets.
decode_one_forward :: proc(dec: ^Clip_Decoder) -> bool {
	for {
		// EOF-tail entry: after the demuxer hit EOF the decoder's reorder
		// buffer still held the stream's last frames; serve them one per call
		// before admitting there is nothing left. last_emitted_ts / have_last
		// advance normally because these frames ARE the remainder of the
		// stream in order.
		if dec.eof_tail_pos < len(dec.eof_tail) {
			f := dec.eof_tail[dec.eof_tail_pos]
			dec.eof_tail_pos += 1
			// frame_replace gives dec.frame its OWN reference (src is not
			// emptied), so dec.frame stays valid while the clone remains
			// owned by eof_tail and is freed exactly once at reset/seek.
			if r := avutil.frame_replace(dec.frame, f); r < 0 {
				return false
			}
			dec.decoded_ahead += 1
			return true
		}
		ret := avfmt.read_frame(dec.fmt_ctx, dec.pkt)
		if ret < 0 {
			// Demux EOF: the decoder may still hold reordering-buffer frames
			// (B-frame delay) that only an explicit flush drains. Callers
			// that decode forward to the very end of a stream would otherwise
			// silently lose the last max_b_frames frames. Flush once and park
			// the drained frames for the loop above to serve in order.
			if !dec.eof_drained {
				dec.eof_drained = true
				if r := avcodec.send_packet(dec.dec_ctx, nil); r < 0 {
					return false
				}
				for {
					r := avcodec.receive_frame(dec.dec_ctx, dec.frame)
					if r == avutil.AVERROR_EAGAIN || r == avutil.AVERROR_EOF {
						break
					}
					if r < 0 {
						return false
					}
					c := avutil.frame_clone(dec.frame)
					if c == nil {
						return false
					}
					append(&dec.eof_tail, c)
				}
				continue
			}
			return false
		}
		if dec.pkt.stream_index != c.int(dec.video_idx) {
			avcodec.packet_unref(dec.pkt)
			continue
		}
		if r := avcodec.send_packet(dec.dec_ctx, dec.pkt); r < 0 {
			avcodec.packet_unref(dec.pkt)
			continue
		}
		avcodec.packet_unref(dec.pkt)
		for {
			r := avcodec.receive_frame(dec.dec_ctx, dec.frame)
			if r == avutil.AVERROR_EAGAIN || r == avutil.AVERROR_EOF {
				break
			}
			if r < 0 {
				return false
			}
			// A hardware frame is left in dec.frame here; the transfer to the
			// persistent sw_frame happens once, in scale_decoded_frame. Doing it
			// there (rather than here) keeps sw_frame's buffer alive between
			// frames, so av_hwframe_transfer_data takes its reuse path. The old
			// code moved sw_frame into dec.frame every frame, which emptied
			// sw_frame and made the next transfer allocate a fresh full-size
			// software frame (plus free the previous) on every decoded frame --
			// the entire hardware-decode penalty.
			dec.decoded_ahead += 1
			return true
		}
	}
}

// FORWARD_STREAM_MAX_SEC bounds how far ahead a forward request may be served
// by streaming decode in place before falling back to a keyframe seek. Below
// this gap streaming never costs more than the seek it replaces -- the keyframe
// before the target is no closer than the decoder's current position, so it
// would re-decode the same frames from the start -- and it keeps the decoder in
// its sequential fast mode instead of re-seeking on every displayed frame
// whenever the playhead outruns the decoder (any rate above 1x, or a transient
// lag). Beyond it (a far scrub or jump) the keyframe is genuinely closer.
FORWARD_STREAM_MAX_SEC :: 1

// decode_forward_to_target decodes forward from the decoder's current physical
// position until the emitted frame's PTS reaches the target for frame_idx, then
// leaves the delivered frame scaled in dec.dst. Stops at the LAST frame whose
// PTS is at/below the target, so a one-frame overshoot (VFR, rate mapping) still
// delivers the frame occupying the target's play position. Does NOT seek; the
// caller positions the decoder first (streamed forward or after a seek).
// Termination compares PTS directly against the target -- never a PTS->index
// back conversion through an assumed frame rate, which drifted on odd files.
decode_forward_to_target :: proc(dec: ^Clip_Decoder, frame_idx: i64) -> bool {
	target := frames_to_stream_ts(dec, frame_idx)
	held := false
	for {
		if !decode_one_forward(dec) {
			return false
		}
		pts := dec.frame.best_effort_timestamp
		if pts >= target {
			// Current frame reaches/exceeds the target. Deliver it when it is
			// exactly the target (normal CFR) or when nothing earlier was held;
			// otherwise the held frame (last pts < target) is the requested one.
			if pts != target && held {
				_ = avutil.frame_replace(dec.frame, dec.hold)
			}
			dec.last_frame = frame_idx
			dec.have_last = true
			dec.last_emitted_ts = dec.frame.best_effort_timestamp
			return scale_decoded_frame(dec)
		}
		// Frame is before the target: remember it as the last acceptable one.
		_ = avutil.frame_replace(dec.hold, dec.frame)
		held = true
	}
}

// decode_source_frame decodes the given source frame index into the decoder's
// internal RGBA dst buffer. Returns true on success. The caller may read it via
// decode_into_buffer() after a successful call. Consecutive forward requests
// decode the next frame in place; a small forward gap streams forward in place
// (no seek); everything else (backward jump, cold decoder, far forward jump)
// re-seeks to the keyframe before the target and decodes forward from there.
decode_source_frame :: proc(dec: ^Clip_Decoder, frame_idx: i64) -> bool {
	if !dec.opened {
		return false
	}
	// The frame asked for IS the frame already decoded. This is the DOMINANT path
	// under conform, not a rare one: any project faster than its source asks for
	// the same source frame repeatedly (a 60fps timeline over 12fps content asks
	// for frame 0 five times, then frame 1 five times).
	//
	// It has to be handled explicitly. Before conform a repeat was rare enough to
	// fall through harmlessly; it fell through to the seek branch, because gap==0
	// is neither last+1 nor in (1, max_gap], so every repeat paid a full
	// seek + flush + decode-from-keyframe. On AV1 that destroys the reference
	// frames the next unit needs, which is where
	//
	//	Missing reference frame needed for show_existing_frame
	//	Failed to parse temporal unit
	//
	// came from: libdav1d asked for a reference the flush had thrown away. So the
	// symptom was not slow playback, it was a decoder failing on every held frame.
	//
	// dec.frame already holds the right pixels and dec.last_frame already says
	// which frame they are, so there is nothing to do but re-run the scale step —
	// the caller reads dec.frame into its buffer either way.
	if dec.have_last && frame_idx == dec.last_frame {
		return scale_decoded_frame(dec)
	}
	// Consecutive forward request: just decode the next frame in place.
	// SAFE ONLY because dec.last_frame mirrors the physical decoder position
	// (struct invariant). If last_frame were over-claimed by a caller, this
	// would decode the true-next pixel but label it frame_idx -> wrong content.
	if dec.have_last && frame_idx == dec.last_frame + 1 {
		if !decode_one_forward(dec) {
			return false
		}
		dec.last_frame = frame_idx
		dec.have_last = true
		dec.last_emitted_ts = dec.frame.best_effort_timestamp
		return scale_decoded_frame(dec)
	}
	// Forward streaming: the request is ahead by more than one frame. Keep
	// decoding forward in place rather than seeking, while the gap is small
	// enough that streaming cannot cost more than the keyframe re-decode it
	// replaces (see FORWARD_STREAM_MAX_SEC). This is the path playback takes
	// whenever the playhead outruns the decoder by >1 frame; without it every
	// such frame paid avformat seek + flush + decode-from-keyframe.
	if dec.have_last {
		gap := frame_idx - dec.last_frame
		max_gap := i64(dec.fps_num / dec.fps_den) * FORWARD_STREAM_MAX_SEC
		if gap > 1 && gap <= max_gap {
			return decode_forward_to_target(dec, frame_idx)
		}
	}
	// Backward jump, cold decoder, or a forward jump beyond the streaming
	// bound: seek to the keyframe before the target, then decode forward.
	//
	// A COLD DECODER ASKING FOR FRAME 0 MUST NOT SEEK. It is already positioned
	// there, so the seek buys nothing -- and on a single-packet source it costs
	// the only packet. A still image is the case that proves it: one mjpeg frame,
	// and avformat_seek_frame to ts 0 with BACKWARD lands past it, so the read
	// that follows returns EOF and the decode fails outright. Measured on a
	// 1080x1920 jpg: `decode_clip_frame_sync` returned false for source frame 0,
	// which is why a still image imported and placed correctly and then rendered
	// nothing at all.
	//
	// This is not an image special case. Any source whose first frame is asked for
	// on a fresh decoder was being seeked to where it already was.
	cold_at_origin := !dec.have_last && frame_idx <= 0
	if !cold_at_origin && !seek_to_source_frame(dec, frame_idx) {
		return false
	}
	return decode_forward_to_target(dec, frame_idx)
}

// scale_decoded_frame scales dec.frame into the decoder's RGBA dst buffer,
// transferring hardware frames to the persistent sw_frame first. Returns false
// if the hardware readback fails, so the caller can treat it as a decode
// failure rather than serving a stale or half-written dst.
scale_decoded_frame :: proc(dec: ^Clip_Decoder) -> bool {
	src := dec.frame
	if dec.hw_pix_fmt != .None && avutil.PixelFormat(dec.frame.format) == dec.hw_pix_fmt {
		// Read the hw surface into the persistent sw_frame. sw_frame retains
		// its buffer across calls, so this is a straight readback with no
		// allocation -- allocating a fresh sw frame per decoded frame was the
		// dominant hardware-decode cost (see decode_one_forward).
		if avutil.hwframe_transfer_data(dec.sw_frame, dec.frame, 0) < 0 {
			return false
		}
		src = dec.sw_frame
	}
	// Hardware decode negotiates the transfer format only now (first frame).
	// Formats outside the x-crop offset table can't be cropped: widen dst to
	// the full box (the allocation was sized for it at open), drop the crop,
	// and let render_blit sample as it always has.
	if dec.crop_px_w > 0 && dec.crop_px_h > 0 && dec.hw_pix_fmt != .None {
		if _, _, _, croppable := src_crop_plane_offsets(avutil.PixelFormat(src.format), 0); !croppable {
			dec.crop_px_x, dec.crop_px_y, dec.crop_px_w, dec.crop_px_h = 0, 0, 0, 0
			dec.crop_dropped = true
			dec.dst_w, dec.dst_h = dec.crop_full_w, dec.crop_full_h
			dec.fit_ox, dec.fit_oy = 0, 0
			if vyper_trace {
				fmt.printf("[dec] crop dropped: %s not in x-crop table\n",
					string(avutil.get_pix_fmt_name(avutil.PixelFormat(src.format))))
			}
		}
	}
	crop_active := dec.crop_px_w > 0 && dec.crop_px_h > 0
	if dec.sws_ctx == nil {
		// Hardware decode negotiated the sw format only now (first frame).
		// Use the frame's own dims/format so crop differences can't drift.
		// The source window is the crop region when cropping (the advanced
		// pointers are the slice, so ctx dims track the region -- see open).
		sw, sh := src.width, src.height
		if crop_active {
			sw, sh = dec.crop_px_w, dec.crop_px_h
		}
		dec.sws_ctx = sws.getContext(
			sw, sh, avutil.PixelFormat(src.format),
			dec.dst_w, dec.dst_h, avutil.PixelFormat.RGBA,
			sws.Flags{.Bilinear}, nil, nil, nil,
		)
		if dec.sws_ctx == nil {
			panic("sws_getContext (hw frame) failed")
		}
	}
	if crop_active {
		// sws_scale has no source-x crop and (in this FFmpeg) no mid-frame
		// vertical slices, so the whole crop is a pointer walk: each plane
		// starts at the crop column + row via src_crop_plane_advance, and the
		// slice handed to sws is the region's full height from its row 0
		// (0 + crop_h == the ctx's source height, a legal "frame start").
		// The format was verified against the table at open (soft) or above.
		planes := src.data
		p0, p1, p2, ok := src_crop_plane_advance(
			avutil.PixelFormat(src.format),
			dec.crop_px_x, dec.crop_px_y,
			src.linesize,
		)
		assert(ok)
		if p0 > 0 {
			planes[0] = cast([^]u8)(uintptr(planes[0]) + uintptr(p0))
		}
		if p1 > 0 {
			planes[1] = cast([^]u8)(uintptr(planes[1]) + uintptr(p1))
		}
		if p2 > 0 {
			planes[2] = cast([^]u8)(uintptr(planes[2]) + uintptr(p2))
		}
		sws.scale(
			dec.sws_ctx,
			cast([^][^]u8)&planes[0],
			cast([^]c.int)&src.linesize[0],
			0, dec.crop_px_h,
			cast([^][^]u8)&dec.dst[0],
			cast([^]c.int)&dec.dst_linesize[0],
		)
	} else {
		sws.scale(
			dec.sws_ctx,
			cast([^][^]u8)&src.data[0],
			cast([^]c.int)&src.linesize[0],
			0, src.height,
			cast([^][^]u8)&dec.dst[0],
			cast([^]c.int)&dec.dst_linesize[0],
		)
	}
	// Unref the decoder's frame (the hw surface for a hw frame) so its buffer
	// can be recycled. sw_frame is deliberately NOT unref'd: keeping its buffer
	// is what makes the next transfer reuse instead of realloc.
	avutil.frame_unref(dec.frame)
	return true
}

// frame_data returns a slice of the decoder's RGBA output buffer, row-aligned.
frame_data :: proc(dec: ^Clip_Decoder) -> []u8 {
	stride := dec.dst_linesize[0]
	if stride <= 0 {
		return nil
	}
	return dec.dst[0][:uint(stride) * uint(dec.dst_h)]
}

// source_fit_in_buffer returns the largest source-aspect rect that fits inside
// buf_w x buf_h, centered (letterboxed): the unscaled content rect and its
// offsets. Used both to pick sws output dims and to map the visible source
// region into the preview texture's UV space.
source_fit_in_buffer :: proc(src_w, src_h, buf_w, buf_h: c.int) -> (fw, fh, ox, oy: c.int) {
	if src_w <= 0 || src_h <= 0 || buf_w <= 0 || buf_h <= 0 {
		return buf_w, buf_h, 0, 0
	}
	// Compare aspects without floating point: src_w/src_h vs buf_w/buf_h.
	if i64(src_w) * i64(buf_h) > i64(src_h) * i64(buf_w) {
		// Source is wider than the buffer: fix the width, derive the height.
		fw = buf_w
		fh = max(1, c.int(i64(buf_w) * i64(src_h) / i64(src_w)))
	} else {
		fh = buf_h
		fw = max(1, c.int(i64(buf_h) * i64(src_w) / i64(src_h)))
	}
	ox = (buf_w - fw) / 2
	oy = (buf_h - fh) / 2
	return
}

// dec_crop_px resolves the decoder's crop fractions (see Clip_Decoder) to
// integer pixels in a `sw x sh` frame. Zero fractions (the zero value) resolve
// to "no crop" (x/y/w/h all zero). The caller derives the frame dims: coded
// dims at open for software decode, the transferred frame's dims for hardware.
dec_crop_px :: proc(dec: ^Clip_Decoder, sw, sh: c.int) -> (x, y, w, h: c.int) {
	if dec.crop_fw <= 0 || dec.crop_fh <= 0 {
		return 0, 0, 0, 0
	}
	x = clamp(c.int(math.round(f64(dec.crop_fx0) * f64(sw))), 0, sw - 1)
	y = clamp(c.int(math.round(f64(dec.crop_fy0) * f64(sh))), 0, sh - 1)
	w = min(max(1, c.int(math.round(f64(dec.crop_fw) * f64(sw)))), sw - x)
	h = min(max(1, c.int(math.round(f64(dec.crop_fh) * f64(sh)))), sh - y)
	return
}

// src_crop_plane_offsets returns the per-plane byte offset a `cx`-pixel left
// crop needs on the sws source planes, for the YUV 4:2:0 / 4:2:2 family the
// decoders here actually produce (and the plainer RGB/gray layouts). The
// vendored sws_scale only crops vertically (srcSliceY/H); a horizontal crop
// must advance each plane's data pointer, and that takes per-format chroma
// geometry. ok=false for any layout the table doesn't cover — the caller then
// decodes the full frame and saves the region only in the destination buffer
// (render_blit's sampling branch), rather than guessing at byte offsets.
src_crop_plane_offsets :: proc(pix_fmt: avutil.PixelFormat, cx: c.int) -> (p0, p1, p2: c.int, ok: bool) {
	#partial switch pix_fmt {
	case .YUV420P, .YUVJ420P:
		// 8-bit planar 4:2:0: 1 byte/sample; chroma subsampled 2x both axes.
		// chroma px at half the columns, so the byte skip is cx/2 (a sample
		// is one byte on the U/V planes).
		return cx, cx / 2, cx / 2, true
	case .YUV420P9LE, .YUV420P9BE, .YUV420P10LE, .YUV420P10BE,
	     .YUV420P12LE, .YUV420P12BE, .YUV420P14LE, .YUV420P14BE,
	     .YUV420P16LE, .YUV420P16BE:
		// 2-byte planar 4:2:0 (9..16 bit): step 2, chroma 4:2:0.
		return 2 * cx, 2 * (cx / 2), 2 * (cx / 2), true
	case .YUV444P, .YUVJ444P:
		// 8-bit planar 4:4:4: no chroma subsampling anywhere.
		return cx, cx, cx, true
	case .NV12, .NV21:
		// Y plane + interleaved UV (2 bytes/chroma pair), 4:2:0 subsampling.
		return cx, 2 * (cx / 2), 0, true
	case .P010LE, .P010BE, .P012LE, .P012BE, .P016LE, .P016BE:
		// 10/12/16-bit 4:2:0, UV interleaved at 4 bytes/chroma pair.
		return 2 * cx, 2 * cx, 0, true
	case .YUYV422, .UYVY422:
		// Single interleaved plane, 2 bytes/pixel, no chroma x subsampling.
		return 2 * cx, 0, 0, true
	case .GRAY8:
		return cx, 0, 0, true
	case:
		return 0, 0, 0, false
	}
}

// src_crop_plane_advance returns the per-plane byte prefix a (cx, cy) source
// crop needs (column offsets from the x table plus cy rows walked down each
// plane's own stride), so the slice handed to sws starts exactly at the crop
// and only the region is scaled. sws_scale in this FFmpeg rejects mid-frame
// vertical slices outright ("Slices start in the middle!" unless srcSliceY is
// the frame start), so the row crop must advance the pointers rather than
// rely on srcSliceY -- unlike the x crop, which sws has no concept of at all.
// cy is snapped even because every format here subsamples chroma vertically
// by 2 on its second/third plane where it exists.
src_crop_plane_advance :: proc(pix_fmt: avutil.PixelFormat, cx, cy: c.int, ls: [8]c.int) -> (p0, p1, p2: c.int, ok: bool) {
	x0, x1, x2, xok := src_crop_plane_offsets(pix_fmt, cx)
	if !xok {
		return 0, 0, 0, false
	}
	cy0 := cy - cy % 2
	p0 = x0 + cy0 * ls[0]
	#partial switch pix_fmt {
	case .YUV420P, .YUVJ420P,
	     .YUV420P9LE, .YUV420P9BE, .YUV420P10LE, .YUV420P10BE,
	     .YUV420P12LE, .YUV420P12BE, .YUV420P14LE, .YUV420P14BE,
	     .YUV420P16LE, .YUV420P16BE,
	     .NV12, .NV21,
	     .P010LE, .P010BE, .P012LE, .P012BE, .P016LE, .P016BE:
		// Chroma (where present) is subsampled 2x vertically: rows come at
		// half rate, so the crop advances them by cy/2 rows.
		p1 = x1 + (cy0 / 2) * ls[1]
		p2 = x2 + (cy0 / 2) * ls[2]
	case .YUYV422, .UYVY422, .GRAY8:
		// Single-plane formats: leave the null trailing planes untouched.
		p1, p2 = 0, 0
	case:
		p1 = x1 + cy0 * ls[1]
		p2 = x2 + cy0 * ls[2]
	}
	return p0, p1, p2, true
}

// decoder_set_preview_path copies `path` into the decoder's own preview_path_buf
// and points preview_path at it, so the decoder's decode target stays valid
// independent of the caller's stack. Identity (`dec.path`) is untouched -- the
// caller passes the source path normally. Passing nil clears the preview so the
// decoder decodes the source itself (used by the async worker when no proxy is
// ready for the requested file).
decoder_set_preview_path :: proc(dec: ^Clip_Decoder, path: cstring) {
	if path == nil {
		dec.preview_path = nil
		dec.preview_path_buf = {}
		return
	}
	if dec.preview_path != nil && string(dec.preview_path) == string(path) {
		return
	}
	src_s := string(path)
	nbytes := min(len(src_s), len(dec.preview_path_buf) - 1)
	copy(dec.preview_path_buf[:nbytes], src_s[:nbytes])
	dec.preview_path_buf[nbytes] = 0
	dec.preview_path = cstring(&dec.preview_path_buf[0])
}

// decoder_set_preview is the per-frame companion to decoder_set_preview_path:
// it sets the physical decode target AND the source-frame base that target's
// frame 0 corresponds to. A segmented proxy resolves each source frame to a
// DIFFERENT file (segment k covers [k*SEG_FRAMES, ...) with its own 0-based
// timestamps), so the base must travel with every resolution, never just once
// per clip assignment. Base 0 (source / whole-file proxy) is the identity.
decoder_set_preview :: proc(dec: ^Clip_Decoder, path: cstring, frame_base: i64) {
	decoder_set_preview_path(dec, path)
	dec.frame_base = frame_base
}

// decode_into_buffer fills a caller-provided tightly-packed RGBA buffer
// (w*h*4 bytes) with the decoded frame's pixels, stripping any row padding and
// letterboxing (zero-filling) the area outside the fit rect.
decode_into_buffer :: proc(dec: ^Clip_Decoder, out: []u8, w, h: c.int) {
	stride := dec.dst_linesize[0]
	if stride <= 0 {
		return
	}
	// Zero the whole box only for the uncropped path: there the dst may cover
	// just the letterboxed region and the rest of the box is read by
	// render_blit (or shown by the preview). When render-path cropping is
	// active the decode writes every pixel of the visible region and nothing
	// outside it is ever read, so zeroing would be per-frame waste equal to
	// the very box area P3 is trying not to touch.
	cropped := dec.crop_px_w > 0 && dec.crop_px_h > 0
	if !cropped {
		mem.zero(raw_data(out), len(out))
	}
	dw := int(dec.dst_w)
	dh := int(dec.dst_h)
	ox := int(dec.fit_ox)
	oy := int(dec.fit_oy)
	row_bytes := dw * 4
	buf_w := int(w)
	for row in 0 ..< dh {
		src := dec.dst[0][uint(row) * uint(stride):][:uint(row_bytes)]
		dst := out[uint((oy + row) * buf_w + ox) * 4:][:uint(row_bytes)]
		copy(dst, src)
	}
	return
}

// decode_clip_frame_sync decodes the given source frame of `path` into `out`
// (PREVIEW_W x PREVIEW_H RGBA), opening the decoder on first use and using the
// decoder's RAM frame cache to avoid re-decoding. Returns true on success. Used
// by the multi-clip preview compositor (one decoder per clip).
//
// This is a PERSISTENT decoder: dec survives across calls, so dec.last_frame
// reflects the physical FFmpeg position left by the PREVIOUS request. The
// cache-hit branch below is the delicate one — see the guard. A cache hit must
// never advance last_frame past the decoder's real position, or the next
// forward request serves wrong pixels (the flush-boundary bug). If you change
// anything here, re-run: VYPER_CACHE_PROBE and VYPER_FRAME_PROBE must stay at
// 0 mismatches.
decode_clip_frame_sync :: proc(dec: ^Clip_Decoder, path: cstring, frame_idx: i64, out: []u8) -> bool {
	// A proxy segment is keyed by LOCAL index (its stream restarts at 0); the
	// request is always a SOURCE index, so translate before seeking/caching.
	frame_local := frame_idx - dec.frame_base
	want := path
	if dec.preview_path != nil && dec.preview_path != path {
		want = dec.preview_path
	}
	if !dec.opened || dec.path != path || string(dec.opened_path) != string(want) {
		// The reopen's reset lives inside open_clip_decoder_ex (not here): it
		// discards decoder state wholesale -- including the RAM cache, which
		// must not survive a physical-file switch (a cache kept across e.g.
		// into the next proxy segment would let a hit re-claim the forward
		// position while the decoder is parked on a different file) -- but
		// carries dec.preview_path / dec.frame_base across, since those are
		// the caller's resolve-for-THIS-frame decode target, not decoder state.
		if !open_clip_decoder(dec, path) {
			dec.path = path
			return false
		}
		dec.path = path
	}
	if cached := cache_find(dec, frame_local); cached != nil {
		copy(out, cached)
		// Cache hit serves pixel data but must not over-claim the physical
		// decoder's forward position. Advancing last_frame PAST where the
		// decoder actually stopped makes a later last_frame+1 request take the
		// forward fast-path and decode the NEXT frame at the real (behind)
		// position, then cache it under the wrong key: a stable wrong image
		// under a shifted key that only "fixes" when a re-seek lands. Only
		// update last_frame when it would not jump ahead of the decoder's true
		// state (frame_local <= last_frame is safe; it only moves last_frame
		// back or equal, which a later request turns into a clean re-seek).
		if !dec.have_last || frame_local <= dec.last_frame {
			dec.last_frame = frame_local
			dec.have_last = true
		}
		return true
	}
	forward := dec.have_last && frame_local == dec.last_frame + 1
	if !forward && vyper_trace {
		fmt.printf("[dec] SEEK frame=%d (was at %d) -> re-seek decoder\n",
			frame_local, dec.last_frame)
	}
	if !decode_source_frame(dec, frame_local) {
		return false
	}
	decode_into_buffer(dec, out, PREVIEW_W, PREVIEW_H)
	cache_store(dec, frame_local, out)
	if !forward && vyper_trace {
		fmt.printf("[dec] decoded frame=%d keys:", frame_local)
		for ci := 0; ci < len(dec.cache); ci += 1 {
			fmt.printf(" %d", dec.cache[ci].frame)
		}
		fmt.printf("\n")
	}
	return true
}

// Stream_Probe holds the stream layout of an imported media file.
Stream_Probe :: struct {
	video_streams: int,
	audio_streams: int,
	duration_sec:  f64,
	has_video:     bool,
	has_audio:     bool,
	video_fps_num: c.int,
	video_fps_den: c.int,
}

// probe_streams opens a file in-process with avformat and counts video and
// audio streams and reports duration. Used at import to build video and audio
// timeline tracks without relying on an external ffprobe subprocess.
probe_streams :: proc(path: cstring) -> Stream_Probe {
	probe: Stream_Probe
	fmt_ctx: ^avfmt.FormatContext
	if ret := avfmt.open_input(&fmt_ctx, path, nil, nil); ret < 0 {
		fmt.println("avformat_open_input (probe):", ff_err_str(ret))
		return probe
	}
	defer avfmt.close_input(&fmt_ctx)
	if ret := avfmt.find_stream_info(fmt_ctx, nil); ret < 0 {
		fmt.println("avformat_find_stream_info (probe):", ff_err_str(ret))
		return probe
	}
	probe.duration_sec = f64(fmt_ctx.duration) / 1_000_000
	for i in 0 ..< int(fmt_ctx.nb_streams) {
		stream := fmt_ctx.streams[i]
		if stream == nil {
			continue
		}
		if stream.codecpar == nil {
			continue
		}
		#partial switch stream.codecpar.codec_type {
		case avutil.MediaType.Video:
			// Attached pictures (cover art) are metadata, not footage — a pure
			// Opus file demuxes its cover as a fake video stream. Skip them so
			// such files import as audio and never get a video clip that would
			// seek a stream the demuxer doesn't actually own.
			if .Attached_Pic in stream.disposition {
				continue
			}
			probe.video_streams += 1
			probe.has_video = true
			if probe.video_fps_num <= 0 && stream.avg_frame_rate.num > 0 {
				probe.video_fps_num = stream.avg_frame_rate.num
				probe.video_fps_den = stream.avg_frame_rate.den
			}
			if probe.video_fps_num <= 0 && stream.r_frame_rate.num > 0 {
				probe.video_fps_num = stream.r_frame_rate.num
				probe.video_fps_den = stream.r_frame_rate.den
			}
			if probe.video_fps_den <= 0 {
				probe.video_fps_den = 1
			}
		case avutil.MediaType.Audio:
			probe.audio_streams += 1
			probe.has_audio = true
		case:
		}
	}
	return probe
}

// first_video_packet_count scans the container for the first real video
// stream's packet count. This is the in-process equivalent of ffprobe's
// `-count_packets -show_entries stream=nb_read_packets`, and the source of the
// authoritative count the import/proxy verification previously trusted ffprobe
// for. fmt_ctx must already be opened + stream info found. Returns -1 on any
// failure so callers share the same "unprobeable" sentinel the old ffprobe
// path returned.
first_video_packet_count :: proc(fmt_ctx: ^avfmt.FormatContext) -> i64 {
	video_idx := c.int(-1)
	for i in 0 ..< int(fmt_ctx.nb_streams) {
		stream := fmt_ctx.streams[i]
		if stream == nil || stream.codecpar == nil {
			continue
		}
		if stream.codecpar.codec_type != avutil.MediaType.Video || .Attached_Pic in stream.disposition {
			continue
		}
		video_idx = c.int(i)
		break
	}
	if video_idx < 0 {
		return -1
	}
	pkt := avcodec.packet_alloc()
	defer avcodec.packet_free(&pkt)
	count: i64 = 0
	for {
		if avfmt.read_frame(fmt_ctx, pkt) < 0 {
			break
		}
		if pkt.stream_index == video_idx {
			count += 1
		}
		avcodec.packet_unref(pkt)
	}
	if count <= 0 {
		return -1
	}
	return count
}

// probe_video_packet_count opens a file in-process and counts the packets of
// its first real video stream. Replaces the shelled-out
// `ffprobe -count_packets -show_entries stream=nb_read_packets`.
probe_video_packet_count :: proc(path: cstring) -> i64 {
	fmt_ctx: ^avfmt.FormatContext
	if ret := avfmt.open_input(&fmt_ctx, path, nil, nil); ret < 0 {
		return -1
	}
	defer avfmt.close_input(&fmt_ctx)
	if ret := avfmt.find_stream_info(fmt_ctx, nil); ret < 0 {
		return -1
	}
	return first_video_packet_count(fmt_ctx)
}

// probe_video_dimensions returns the first real (non-attached-picture) video
// stream's coded size. Replaces the shelled-out
// `ffprobe -show_entries stream=width,height`.
probe_video_dimensions :: proc(path: cstring) -> (w, h: c.int, ok: bool) {
	fmt_ctx: ^avfmt.FormatContext
	if ret := avfmt.open_input(&fmt_ctx, path, nil, nil); ret < 0 {
		return 0, 0, false
	}
	defer avfmt.close_input(&fmt_ctx)
	if ret := avfmt.find_stream_info(fmt_ctx, nil); ret < 0 {
		return 0, 0, false
	}
	for i in 0 ..< int(fmt_ctx.nb_streams) {
		stream := fmt_ctx.streams[i]
		if stream == nil || stream.codecpar == nil {
			continue
		}
		if stream.codecpar.codec_type != avutil.MediaType.Video || .Attached_Pic in stream.disposition {
			continue
		}
		return c.int(stream.codecpar.width), c.int(stream.codecpar.height), true
	}
	return 0, 0, false
}

// import_obs_chapters reads the chapter markers OBS links (hybrid MP4/MOV) embed
// in QTFF: a 'text' sample-entry track (handler "OBS Chapter Handler") that
// FFmpeg demuxes as a MOV_TEXT subtitle stream, one sample per chapter. Files
// that expose plain FFmpeg chapters (Matroska, MP4 chapter atoms) are also
// imported. Returns the markers in stream order with each source_frame
// converted to the video timeline via the video stream's average frame rate.
import_obs_chapters :: proc(path: cstring) -> [dynamic]Clip_Marker {
	markers := make([dynamic]Clip_Marker)
	fmt_ctx: ^avfmt.FormatContext
	if ret := avfmt.open_input(&fmt_ctx, path, nil, nil); ret < 0 {
		fmt.println("avformat_open_input (chapters):", ff_err_str(ret))
		return markers
	}
	defer avfmt.close_input(&fmt_ctx)
	if ret := avfmt.find_stream_info(fmt_ctx, nil); ret < 0 {
		fmt.println("avformat_find_stream_info (chapters):", ff_err_str(ret))
		return markers
	}
	text_idx := c.int(-1)
	video_idx := c.int(-1)
	for i in 0 ..< int(fmt_ctx.nb_streams) {
		stream := fmt_ctx.streams[i]
		if stream == nil || stream.codecpar == nil {
			continue
		}
		if stream.codecpar.codec_type == avutil.MediaType.Video && video_idx < 0 && !(.Attached_Pic in stream.disposition) {
			// Cover art demuxes as a video stream; never use it as the chapter
			// clock — it has no frames and its rate is meaningless.
			video_idx = c.int(i)
		}
		if stream.codecpar.codec_type != avutil.MediaType.Subtitle {
			continue
		}
		// OBS chapter tracks demux as MOV_TEXT; plain QT 'text' entries as TEXT.
		// Anything else still counts if the demuxer tagged it as OBS's handler.
		is_obs := false
		if entry := avutil.dict_get(stream.metadata, "handler_name", nil, {}); entry != nil && entry.value != nil {
			is_obs = strings.contains(strings.to_lower(string(entry.value)), "obs")
		}
		if text_idx < 0 && (stream.codecpar.codec_id == avcodec.CodecID.MovText || stream.codecpar.codec_id == avcodec.CodecID.Text || is_obs) {
			text_idx = c.int(i)
		}
	}
	if video_idx < 0 {
		return markers
	}
	fps := fmt_ctx.streams[video_idx].avg_frame_rate
	if fps.num <= 0 || fps.den <= 0 {
		fps = fmt_ctx.streams[video_idx].r_frame_rate
	}
	if fps.num <= 0 || fps.den <= 0 {
		fps = avutil.Rational{num = 25, den = 1}
	}
	frame_from_seconds := proc(seconds: f64, fps: avutil.Rational) -> i64 {
		f := i64(seconds * f64(fps.num) / f64(fps.den))
		if f < 0 {
			return 0
		}
		return f
	}
	if text_idx >= 0 {
		import_marker_text_stream(&markers, fmt_ctx, text_idx, fps, frame_from_seconds)
	} else {
		import_marker_chapters(&markers, fmt_ctx, fps, frame_from_seconds)
	}
	return markers
}

// chapter_text_from_sample strips the QTFF text-sample 2-byte big-endian length
// prefix and padding, falling back to the raw packet bytes if the layout
// doesn't match.
chapter_text_from_sample :: proc(data: [^]u8, size: c.int) -> string {
	if size <= 0 {
		return ""
	}
	if size >= 2 {
		ln := int(u16(data[0]) << 8 | u16(data[1]))
		if ln > 0 && 2 + ln <= int(size) {
			return strings.trim_space(string(data[2:][:ln]))
		}
	}
	return strings.trim_space(string(data[:int(size)]))
}

// import_marker_text_stream reads every sample of the OBS chapter subtitle
// track and appends one marker per sample, deduped on source_frame.
import_marker_text_stream :: proc(markers: ^[dynamic]Clip_Marker, fmt_ctx: ^avfmt.FormatContext, text_idx: c.int, fps: avutil.Rational, frame_from_seconds: proc(seconds: f64, fps: avutil.Rational) -> i64) {
	tb := fmt_ctx.streams[text_idx].time_base
	if tb.num <= 0 || tb.den <= 0 {
		return
	}
	// Rewind past any packets already buffered by find_stream_info so we read
	// every text sample from the start.
	if ret := avfmt.seek_frame(fmt_ctx, text_idx, 0, avfmt.SeekFlags{.Backward}); ret < 0 {
		fmt.println("avformat_seek_file (chapters):", ff_err_str(ret))
	}
	pkt := avcodec.packet_alloc()
	if pkt == nil {
		return
	}
	defer avcodec.packet_free(&pkt)
	last_frame := i64(-1)
	for {
		if ret := avfmt.read_frame(fmt_ctx, pkt); ret < 0 {
			break
		}
		if pkt.stream_index != text_idx {
			avcodec.packet_unref(pkt)
			continue
		}
		seconds := f64(pkt.pts) * f64(tb.num) / f64(tb.den)
		frame := frame_from_seconds(seconds, fps)
		name := chapter_text_from_sample(pkt.data, pkt.size)
		if len(name) > 0 && frame != last_frame {
			append(markers, Clip_Marker{source_frame = frame, label = session_str_intern(name)})
			last_frame = frame
		}
		avcodec.packet_unref(pkt)
	}
}

// import_marker_chapters imports markers from a demuxer's native chapter atom
// list (Matroska chapters, MP4/MOV chapter atoms), using each chapter's start
// time and "title" metadata.
import_marker_chapters :: proc(markers: ^[dynamic]Clip_Marker, fmt_ctx: ^avfmt.FormatContext, fps: avutil.Rational, frame_from_seconds: proc(seconds: f64, fps: avutil.Rational) -> i64) {
	if fmt_ctx.nb_chapters == 0 || fmt_ctx.chapters == nil {
		return
	}
	last_frame := i64(-1)
	for i in 0 ..< int(fmt_ctx.nb_chapters) {
		ch := fmt_ctx.chapters[i]
		if ch == nil || ch.start == avutil.AV_NOPTS_VALUE {
			continue
		}
		seconds := f64(ch.start) * f64(ch.time_base.num) / f64(ch.time_base.den)
		frame := frame_from_seconds(seconds, fps)
		name := ""
		if entry := avutil.dict_get(ch.metadata, "title", nil, {}); entry != nil && entry.value != nil {
			name = strings.trim_space(string(entry.value))
		}
		if len(name) > 0 && frame != last_frame {
			append(markers, Clip_Marker{source_frame = frame, label = session_str_intern(name)})
			last_frame = frame
		}
	}
}
