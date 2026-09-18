package main

import "core:c"
import "base:runtime"
import "core:fmt"
import sdl "vendor:sdl3"

// Async_Decoder runs decode for ONE preview slot on its own dedicated worker
// thread, so a slow keyframe seek for that slot never blocks the render loop
// (which also drives playback_update/audio_update -- see main.odin). There is
// one Async_Decoder per preview slot (async_decoders[slot_idx]), not one
// global instance: previously only the frontmost clip got this treatment and
// every OTHER slot decoded synchronously on the render thread, so an edit
// that shifted several clips at once (a ripple cut moves every downstream
// clip's timeline_start_frame in one go) forced multiple synchronous cold
// seeks back-to-back on the render thread -- a multi-hundred-ms-to-second
// stall that also delayed playback_update/audio_update, which run right
// after update_preview_slots on the same thread, producing a real audio/video
// desync. Giving every slot its own worker removes decode from the render
// thread's blocking path entirely, for every slot, not just the top one.
//
// Protocol (render thread <-> worker), unchanged per-slot from the original
// single-worker design:
//   - Render posts a request with async_post_request(slot_idx, path, preview,
//     frame_base, clip_frame). Each post bumps req_seq. The worker picks up
//     the latest pending request, decodes it, records (res_path, res_frame) +
//     pixels in display_buf, sets res_valid, bumps done_seq. If it drains all
//     requests it waits on cond.
//   - Render consumes a result with async_try_consume(slot_idx, path,
//     clip_frame, out): if the worker finished EXACTLY that request
//     (res_valid && res_frame == clip_frame && res_path == path) it copies
//     the pixels to out and clears res_valid. Else it fails so the caller
//     keeps its last good frame.
//   - async_wait_idle(slot_idx) blocks until that slot's done_seq reaches
//     req_seq; used only by the headless probes, which step the playhead and
//     then immediately assert the slot buffer, so they need the decode
//     deterministically caught up.
//
// Latest-wins per slot: each worker always re-renders the newest posted
// request for ITS slot, so a fast-moving playhead converges to the current
// frame without buffering, independently per layer.
//
// Each worker owns its own Clip_Decoder, separate from the slot's own
// decode_clip_frame_sync decoder (slot.dec in preview_slots): the render
// thread never touches a decoder a worker thread might concurrently be
// seeking with, avoiding races. slot.buffer is written solely by the render
// thread via async_try_consume/async_try_consume_latest. Its decode path
// (vdec_decode) mirrors decode_clip_frame_sync and must keep the
// cache-hit/last_frame guard in lockstep; VYPER_CACHE_PROBE stays at 0
// mismatches for that reason.
//
// Trade-off: MAX_PREVIEW_SLOTS worker threads (and MAX_PREVIEW_SLOTS extra
// Clip_Decoders) are alive whenever the async subsystem is initialized,
// instead of just one. Each is blocked on its condition variable and does
// nothing when its slot has no pending request, so the idle CPU cost is
// negligible -- but this DOES mean up to MAX_PREVIEW_SLOTS decoders (on top
// of the MAX_PREVIEW_SLOTS the slots themselves already hold in slot.dec) can
// have a source file open concurrently, which matters on machines with a
// limited number of concurrent hardware decode sessions. If that becomes a
// real constraint, the fix is to turn this into a small worker POOL (fewer
// threads than slots, each picking up whichever slot's request is pending)
// rather than reducing back to a single front-slot worker.
Async_Decoder :: struct {
	slot_idx: int, // which preview slot this worker serves (for tracing)

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
	req_base:     i64,
	// req_pick_hash fingerprints the proxy file (segment) this request asked to
	// decode through. It rides along and is copied to the result so the consumer
	// can stamp displayed_pick with the SAME file identity it actually served --
	// never the identity of a newer, unconsumed request.
	req_pick_hash: u32,

	// Result side (worker writes, render thread consumes).
	res_valid:   bool,
	res_path:    cstring,
	res_frame:   i64,
	res_pick_hash: u32,
	done_seq:    u64,
	// display_buf/wbuf point into frame_a/frame_b. The worker decodes into
	// wbuf with no lock held, then swaps the two pointers under the mutex so
	// the freshly decoded frame BECOMES display_buf with no full-frame copy;
	// the worker's next fill is whichever buffer the swap displaced. Both the
	// swap and every read of these pointers happen under `mutex`, so no reader
	// can still hold the displaced buffer.
	display_buf: ^[PREVIEW_W * PREVIEW_H * 4]u8,
	frame_a:     [PREVIEW_W * PREVIEW_H * 4]u8,
	frame_b:     [PREVIEW_W * PREVIEW_H * 4]u8,

	// Worker-owned (touched only by the worker thread).
	dec:             Clip_Decoder,
	dec_path:        cstring,
	// dec_preview_buf holds the preview path captured from the latest request
	// for the CURRENT identity; it is stable for the decoder's lifetime.
	dec_preview_buf: [4096]u8,
	wbuf:            ^[PREVIEW_W * PREVIEW_H * 4]u8,
}

// async_decoders holds one worker per preview slot, indexed by slot_idx
// (0 ..< MAX_PREVIEW_SLOTS). All decode routed through update_preview_slots
// goes through async_decoders[slot_idx] rather than a single shared instance.
async_decoders: [MAX_PREVIEW_SLOTS]Async_Decoder

// async_live_mode selects how the preview consumes each worker's result.
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
// the other to match, then re-run VYPER_CACHE_PROBE (0 mismatches).
vdec_decode :: proc(ad: ^Async_Decoder, path: cstring, preview: cstring, frame_base: i64, frame_idx: i64) -> bool {
	spall_scope(#procedure)
	frame_local := frame_idx - frame_base
	want := path
	if preview != nil && preview != path {
		want = preview
	}
	if !ad.dec.opened || ad.dec_path != path || string(ad.dec.opened_path) != string(want) {
		if vyper_trace {
			fmt.printf(
				"[vdec s=%d] REOPEN src_f=%d want=%q opened=%v opened_path=%q preview=%q\n",
				ad.slot_idx,
				frame_idx + frame_base,
				string(want),
				ad.dec.opened,
				ad.dec.opened_path != nil ? string(ad.dec.opened_path) : "",
				preview != nil ? string(preview) : "<nil>",
			)
		}
		decoder_set_preview(&ad.dec, preview, frame_base)
		if !open_clip_decoder(&ad.dec, path) {
			ad.dec_path = path
			return false
		}
		ad.dec_path = path
	}
	if cached := cache_find(&ad.dec, frame_local); cached != nil {
		copy(ad.wbuf[:], cached)
		// Same guard as decode_clip_frame_sync: a cache hit must not advance
		// last_frame past the decoder's real physical position, or a later
		// forward request decodes wrong content under a shifted key.
		if !ad.dec.have_last || frame_local <= ad.dec.last_frame {
			ad.dec.last_frame = frame_local
			ad.dec.have_last = true
		}
		return true
	}
	if !decode_source_frame(&ad.dec, frame_local) {
		return false
	}
	decode_into_buffer(&ad.dec, ad.wbuf[:], PREVIEW_W, PREVIEW_H)
	cache_store(&ad.dec, frame_local, ad.wbuf[:])
	return true
}

vdec_worker :: proc "c" (data: rawptr) -> c.int {
	context = runtime.default_context()
	ad := (^Async_Decoder)(data)
	spall_thread_init("vdecode")
	defer spall_thread_term()
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
		req_base := ad.req_base
		// The pick hash must be captured while the request is still the current
		// one (the render thread may post a newer request immediately after).
		req_pick_hash := ad.req_pick_hash
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

		ok := vdec_decode(ad, req_path, req_preview, req_base, req_frame)

		sdl.LockMutex(ad.mutex)
		if ok {
			// Publish by swapping the fill/display pointers rather than copying
			// the whole frame: the just-decoded buffer becomes display_buf and
			// the old display buffer becomes the next fill target.
			ad.wbuf, ad.display_buf = ad.display_buf, ad.wbuf
			ad.res_valid = true
			ad.res_path = req_path
			ad.res_frame = req_frame
			ad.res_pick_hash = req_pick_hash
		}
		ad.done_seq += 1
		sdl.UnlockMutex(ad.mutex)
	}
	clip_decoder_reset(&ad.dec)
	ad.dec_path = ""
	return 0
}

// async_dec_init spawns one worker thread per preview slot.
async_dec_init :: proc() {
	for i in 0 ..< MAX_PREVIEW_SLOTS {
		ad := &async_decoders[i]
		ad.slot_idx = i
		ad.mutex = sdl.CreateMutex()
		ad.cond = sdl.CreateCondition()
		// Point the fill/display pair at the backing buffers BEFORE the worker
		// starts; the worker and every consumer assume both are non-nil.
		ad.wbuf = &ad.frame_a
		ad.display_buf = &ad.frame_b
		ad.thread = sdl.CreateThread(vdec_worker, "vdecode", ad)
	}
}

// async_dec_shutdown stops every worker and frees its resources.
async_dec_shutdown :: proc() {
	// Signal all workers to stop before joining any of them, so shutdown time
	// is roughly one wakeup latency total rather than MAX_PREVIEW_SLOTS of them
	// serialized.
	for i in 0 ..< MAX_PREVIEW_SLOTS {
		ad := &async_decoders[i]
		if ad.thread == nil {
			continue
		}
		sdl.LockMutex(ad.mutex)
		ad.stop = true
		sdl.SignalCondition(ad.cond)
		sdl.UnlockMutex(ad.mutex)
	}
	for i in 0 ..< MAX_PREVIEW_SLOTS {
		ad := &async_decoders[i]
		if ad.thread == nil {
			continue
		}
		sdl.WaitThread(ad.thread, nil)
		sdl.DestroyCondition(ad.cond)
		sdl.DestroyMutex(ad.mutex)
		ad.thread = nil
	}
}

// async_dec_reset_slot tells ONE slot's worker to drop its decoder and cached
// frames. Safe to call even if that worker is not running. Also clears any
// posted request and stale result so old pixels are never consumed.
async_dec_reset_slot :: proc(slot_idx: int) {
	ad := &async_decoders[slot_idx]
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

// async_dec_reset tells EVERY worker to drop its decoder and cached frames
// (e.g. ahead of importing a new file, or any full timeline invalidation).
// Kept as the zero-arg entry point so existing "reset everything" call sites
// (media.odin's post-import teardown) don't need to know about individual
// slots.
async_dec_reset :: proc() {
	for i in 0 ..< MAX_PREVIEW_SLOTS {
		async_dec_reset_slot(i)
	}
}

// async_post_request asks slot_idx's worker to decode the given clip frame of
// `path` as soon as it is free. `preview` is the preview-path proxy to decode
// through (nil decodes the source) and `frame_base` is its source-frame base
// (see decode.odin's Clip_Decoder.frame_base). Non-blocking. That slot's
// worker always converges to the most recent request posted to it.
async_post_request :: proc(slot_idx: int, path: cstring, preview: cstring, frame_base: i64, clip_frame: i64) {
	ad := &async_decoders[slot_idx]
	if ad.thread == nil {
		return
	}
	sdl.LockMutex(ad.mutex)
	ad.req_path = path
	ad.req_frame = clip_frame
	ad.req_base = frame_base
	// Fingerprint the proxy file this request will decode through. The consumer
	// reads it back with the result so displayed_pick matches the served frame.
	ad.req_pick_hash = pick_hash_u32(preview)
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

// async_try_consume copies slot_idx's worker's decoded frame into `out` if and
// only if it is the result for EXACTLY (path, clip_frame). Returns false if
// the worker has not produced that exact frame yet (caller keeps its last
// good frame) or if a stale result for a different request is present.
async_try_consume :: proc(slot_idx: int, path: cstring, clip_frame: i64, out: []u8) -> bool {
	ad := &async_decoders[slot_idx]
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

// async_try_consume_latest copies slot_idx's worker's most recently completed
// frame into `out` even when it does not match the requested clip_frame,
// returning the decoded frame. Used while scrubbing/playing: the frontier
// races ahead of the worker, so exact-consume would only ever succeed on
// release; this shows the newest completed decode so the preview chases the
// pointer in real time. Only honored when the result belongs to the same
// source path. Returns false when no completed result is present yet (caller
// keeps its last good frame).
async_try_consume_latest :: proc(slot_idx: int, path: cstring, clip_frame: i64, out: []u8) -> (bool, i64, u32) {
	ad := &async_decoders[slot_idx]
	if ad.thread == nil {
		return false, clip_frame, 0
	}
	sdl.LockMutex(ad.mutex)
	defer sdl.UnlockMutex(ad.mutex)
	if !ad.res_valid || ad.res_path != path {
		return false, clip_frame, 0
	}
	copy(out, ad.display_buf[:])
	frame := ad.res_frame
	pick := ad.res_pick_hash
	ad.res_valid = false
	return true, frame, pick
}

// async_has_worker reports whether slot_idx's async worker is initialized
// (render thread should fall back to synchronous decode for that slot when it
// is not, e.g. probes that never call async_dec_init).
async_has_worker :: proc(slot_idx: int) -> bool {
	return async_decoders[slot_idx].thread != nil
}

// async_wait_idle blocks until every request posted to slot_idx's worker has
// been decoded. Used ONLY by the headless probes (and tests) that step the
// playhead then immediately assert the slot buffer: it makes that slot's
// async decode deterministic.
async_wait_idle :: proc(slot_idx: int) {
	ad := &async_decoders[slot_idx]
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
