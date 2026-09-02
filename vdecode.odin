package main

import "core:c"
import "base:runtime"
import sdl "vendor:sdl3"

// Async_Decoder runs decode from the FRONTMOST video clip on a dedicated worker
// thread so that a slow keyframe seek never blocks the render loop (which also
// feeds audio). The worker is the only user of its Clip_Decoder; the render
// thread only copies a finished RGBA frame out of display_buf under the mutex.
//
// Protocol (render thread <-> worker):
//   - Render posts a request with async_post_request(path, preview, clip_frame).
//     Each post bumps req_seq. The worker picks up the latest pending request,
//     decodes it, records (res_path, res_frame) + pixels in display_buf, sets
//     res_valid, bumps done_seq. If it drains all requests it waits on cond.
//   - Render consumes a result with async_try_consume(path, clip_frame, out):
//     if the worker finished EXACTLY that request (res_valid && res_frame ==
//     clip_frame && res_path == path) it copies the pixels to out and clears
//     res_valid. Else it fails so the caller keeps its last good frame.
//   - async_wait_idle() blocks until done_seq reaches req_seq; used only by the
//     headless probes, which step the playhead and then immediately assert the
//     slot buffer, so they need the decode deterministically caught up.
//
// Latest-wins: the worker always re-renders the newest posted request, so a
// fast-moving playhead converges to the current frame without buffering.
//
// The worker is a SEPARATE decoder from the per-slot decode_clip_frame_sync
// decoders; it is only used for the foreground clip and does not touch the slot
// structs (slot.buffer is written solely by the render thread via
// async_try_consume). Its decode path (vdec_decode) mirrors decode_clip_frame_sync
// and must keep the cache-hit/last_frame guard in lockstep; NERED_CACHE_PROBE
// stays at 0 mismatches for that reason.
Async_Decoder :: struct {
	thread: ^sdl.Thread,
	mutex:  ^sdl.Mutex,
	cond:   ^sdl.Condition,

	stop:  bool,
	reset: bool,

	// Request side (render thread posts, worker reads).
	req_valid:    bool,
	req_path:     cstring,
	req_frame:    i64,
	req_seq:      u64,
	req_preview:  cstring,
	req_preview_buf: [4096]u8,

	// Result side (worker writes, render thread consumes).
	res_valid:   bool,
	res_path:    cstring,
	res_frame:   i64,
	done_seq:    u64,
	display_buf: [PREVIEW_W * PREVIEW_H * 4]u8,

	// Worker-owned (touched only by the worker thread).
	dec:             Clip_Decoder,
	dec_path:        cstring,
	// dec_preview_buf holds the preview path captured from the latest request
	// for the CURRENT identity; it is stable for the decoder's lifetime.
	dec_preview_buf: [4096]u8,
	wbuf:            [PREVIEW_W * PREVIEW_H * 4]u8,
}

async_decoder: Async_Decoder

// async_live_mode selects how the preview consumes the async worker's result.
// Live (GUI) mode is non-blocking: keep the last good frame until the worker
// lands the current one. Probe/test mode waits (async_wait_idle) so the
// playhead steps are deterministic and the sync-contract probes stay valid.
async_live_mode := true

// vdec_decode performs one decode (worker thread). It may open the decoder for
// a new path, serves from the RAM frame cache, and on success fills
// ad.wbuf (worker-private). `preview` is the optional low-res all-intra proxy
// path the preview path would use (nil decodes the source). WARNING: this is
// the ASYNC mirror of decode_clip_frame_sync (same persistent-decoder +
// cache-hit guard). If you change the cache-hit/last_frame logic in one, update
// the other to match, then re-run NERED_CACHE_PROBE (0 mismatches).
vdec_decode :: proc(ad: ^Async_Decoder, path: cstring, preview: cstring, frame_idx: i64) -> bool {
	if !ad.dec.opened || ad.dec_path != path {
		decoder_set_preview_path(&ad.dec, preview)
		if !open_clip_decoder(&ad.dec, path) {
			ad.dec_path = path
			return false
		}
		ad.dec_path = path
	}
	if cached := cache_find(&ad.dec, frame_idx); cached != nil {
		copy(ad.wbuf[:], cached)
		// Same guard as decode_clip_frame_sync: a cache hit must not advance
		// last_frame past the decoder's real physical position, or a later
		// forward request decodes wrong content under a shifted key.
		if !ad.dec.have_last || frame_idx <= ad.dec.last_frame {
			ad.dec.last_frame = frame_idx
			ad.dec.have_last = true
		}
		return true
	}
	if !decode_source_frame(&ad.dec, frame_idx) {
		return false
	}
	decode_into_buffer(&ad.dec, ad.wbuf[:], PREVIEW_W, PREVIEW_H)
	cache_store(&ad.dec, frame_idx, ad.wbuf[:])
	return true
}

vdec_worker :: proc "c" (data: rawptr) -> c.int {
	context = runtime.default_context()
	ad := (^Async_Decoder)(data)
	for {
		sdl.LockMutex(ad.mutex)
		for !ad.stop && ad.reset == false && !ad.req_valid {
			sdl.WaitCondition(ad.cond, ad.mutex)
		}
		if ad.stop {
			sdl.UnlockMutex(ad.mutex)
			break
		}
		if ad.reset {
			ad.reset = false
			ad.req_valid = false
			ad.res_valid = false
			// Any posted-but-not-yet-decoded requests were cancelled by the
			// reset; reconcile the sequence counters so async_wait_idle sees the
			// worker idle instead of waiting forever on a dropped request.
			ad.done_seq = ad.req_seq
			sdl.UnlockMutex(ad.mutex)
			clip_decoder_reset(&ad.dec)
			ad.dec_path = ""
			ad.dec_preview_buf = {}
			continue
		}
		req_path := ad.req_path
		req_frame := ad.req_frame
		// Capture the preview path into worker-owned storage before releasing
		// the lock: the render thread may overwrite req_preview_buf with the
		// next request's proxy immediately after posting.
		pv_s := string(ad.req_preview)
		req_preview: cstring = nil
		if len(pv_s) > 0 {
			nbytes := min(len(pv_s), len(ad.dec_preview_buf) - 1)
			copy(ad.dec_preview_buf[:nbytes], pv_s[:nbytes])
			ad.dec_preview_buf[nbytes] = 0
			req_preview = cstring(&ad.dec_preview_buf[0])
		}
		ad.req_valid = false
		sdl.UnlockMutex(ad.mutex)

		ok := vdec_decode(ad, req_path, req_preview, req_frame)

		sdl.LockMutex(ad.mutex)
		if ok {
			copy(ad.display_buf[:], ad.wbuf[:])
			ad.res_valid = true
			ad.res_path = req_path
			ad.res_frame = req_frame
		}
		ad.done_seq += 1
		sdl.UnlockMutex(ad.mutex)
	}
	clip_decoder_reset(&ad.dec)
	ad.dec_path = ""
	return 0
}

async_dec_init :: proc() {
	ad := &async_decoder
	ad.mutex = sdl.CreateMutex()
	ad.cond = sdl.CreateCondition()
	ad.thread = sdl.CreateThread(vdec_worker, "vdecode", ad)
}

// async_dec_shutdown stops the worker and frees its resources.
async_dec_shutdown :: proc() {
	ad := &async_decoder
	if ad.thread == nil {
		return
	}
	sdl.LockMutex(ad.mutex)
	ad.stop = true
	sdl.SignalCondition(ad.cond)
	sdl.UnlockMutex(ad.mutex)
	sdl.WaitThread(ad.thread, nil)
	sdl.DestroyCondition(ad.cond)
	sdl.DestroyMutex(ad.mutex)
	ad.thread = nil
}

// async_dec_reset tells the worker to drop its decoder and cached frames (e.g.
// ahead of importing a new file). Safe to call even if not running. Also clears
// any posted request and stale result so old pixels are never consumed.
async_dec_reset :: proc() {
	ad := &async_decoder
	if ad.thread == nil {
		return
	}
	sdl.LockMutex(ad.mutex)
	ad.reset = true
	ad.req_valid = false
	ad.res_valid = false
	sdl.SignalCondition(ad.cond)
	sdl.UnlockMutex(ad.mutex)
}

// async_post_request asks the worker to decode the given clip frame of `path`
// as soon as it is free. `preview` is the preview-path proxy to decode through
// (nil decodes the source). Non-blocking. The worker always converges to the
// most recent request.
async_post_request :: proc(path: cstring, preview: cstring, clip_frame: i64) {
	ad := &async_decoder
	if ad.thread == nil {
		return
	}
	sdl.LockMutex(ad.mutex)
	ad.req_path = path
	ad.req_frame = clip_frame
	// Copy the preview path into the worker's request staging area so the
	// worker reads a stable snapshot regardless of when the render thread next
	// overwrites it. Source identity (req_path) keeps the (path, frame) key.
	pv_s := string(preview)
	if len(pv_s) > len(ad.req_preview_buf) - 1 {
		pv_s = pv_s[:len(ad.req_preview_buf) - 1]
	}
	ad.req_preview_buf = {}
	copy(ad.req_preview_buf[:len(pv_s)], pv_s)
	ad.req_preview = cstring(&ad.req_preview_buf[0])
	if !ad.req_valid {
		ad.req_valid = true
	}
	ad.req_seq += 1
	sdl.SignalCondition(ad.cond)
	sdl.UnlockMutex(ad.mutex)
}

// async_try_consume copies the worker's decoded frame into `out` if and only if
// it is the result for EXACTLY (path, clip_frame). Returns false if the worker
// has not produced that exact frame yet (caller keeps its last good frame) or
// if a stale result for a different request is present.
async_try_consume :: proc(path: cstring, clip_frame: i64, out: []u8) -> bool {
	ad := &async_decoder
	if ad.thread == nil {
		return false
	}
	sdl.LockMutex(ad.mutex)
	defer sdl.UnlockMutex(ad.mutex)
	if !ad.res_valid || ad.res_path != path || ad.res_frame != clip_frame {
		return false
	}
	copy(out, ad.display_buf[:])
	ad.res_valid = false
	return true
}

// async_has_worker reports whether the async worker is initialized (render
// thread should fall back to synchronous decode when it is not, e.g. probes).
async_has_worker :: proc() -> bool {
	return async_decoder.thread != nil
}

// async_wait_idle blocks until every posted request has been decoded. Used ONLY
// by the headless probes (and tests) that step the playhead then immediately
// assert the slot buffer: it makes the async decode deterministic.
async_wait_idle :: proc() {
	ad := &async_decoder
	if ad.thread == nil {
		return
	}
	for {
		sdl.LockMutex(ad.mutex)
		idle := ad.done_seq >= ad.req_seq
		sdl.UnlockMutex(ad.mutex)
		if idle {
			return
		}
		sdl.Delay(1)
	}
}