package main

import "core:c"
import "base:runtime"
import sdl "vendor:sdl3"

// Async_Decoder runs video decode on a dedicated worker thread so that slow
// keyframe decodes never block the render loop (which also feeds audio). The
// worker is the only user of its Clip_Decoder; the render thread only copies
// the finished RGBA frame out of display_buf under the mutex.
//
// Locking: mutex guards every shared field (stop, reset, req_*, display_*).
// The worker never waits on the render thread, so there is no deadlock; it
// just (re)writes display_buf under the lock whenever a decode completes and
// unconditionally re-renders the latest requested frame.
Async_Decoder :: struct {
	thread: ^sdl.Thread,
	mutex:  ^sdl.Mutex,
	cond:   ^sdl.Condition,

	stop:  bool,
	reset: bool,

	req_valid:      bool,
	req_path:       cstring,
	req_clip_frame: i64,

	display_dirty: bool,
	display_buf:   [PREVIEW_W * PREVIEW_H * 4]u8,

	// Worker-owned (touched only by the worker thread).
	dec:     Clip_Decoder,
	dec_path: cstring,
	wbuf:    [PREVIEW_W * PREVIEW_H * 4]u8,
}

async_decoder: Async_Decoder

// vdec_decode performs one decode (worker thread). It may open the decoder for
// a new path, serves from the RAM frame cache, and on success fills
// ad.wbuf (worker-private).
vdec_decode :: proc(ad: ^Async_Decoder, path: cstring, frame_idx: i64) -> bool {
	if !ad.dec.opened || ad.dec_path != path {
		if !open_clip_decoder(&ad.dec, path) {
			ad.dec_path = path
			return false
		}
		ad.dec_path = path
	}
	if cached := cache_find(&ad.dec, frame_idx); cached != nil {
		copy(ad.wbuf[:], cached)
		ad.dec.last_frame = frame_idx
		ad.dec.have_last = true
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
			ad.display_dirty = false
			sdl.UnlockMutex(ad.mutex)
			clip_decoder_reset(&ad.dec)
			ad.dec_path = ""
			continue
		}
		req_path := ad.req_path
		req_frame := ad.req_clip_frame
		ad.req_valid = false
		sdl.UnlockMutex(ad.mutex)

		ok := vdec_decode(ad, req_path, req_frame)

		sdl.LockMutex(ad.mutex)
		if ok {
			copy(ad.display_buf[:], ad.wbuf[:])
			ad.display_dirty = true
		}
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

// async_dec_reset tells the worker to drop its decoder and cached frames ahead
// of importing a new file. Safe to call even if not running.
async_dec_reset :: proc() {
	ad := &async_decoder
	if ad.thread == nil {
		return
	}
	sdl.LockMutex(ad.mutex)
	ad.reset = true
	ad.req_valid = false
	ad.display_dirty = false
	sdl.SignalCondition(ad.cond)
	sdl.UnlockMutex(ad.mutex)
}

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
