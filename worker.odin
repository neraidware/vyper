package main

import "core:sync"
import "core:thread"

// ---------------------------------------------------------------------------
// Worker substrate
//
// Every blocking background worker in the app embeds this. It owns ONLY the
// mechanical pieces that are identical whether the worker decodes a preview
// frame or builds a proxy: the thread handle, the wake channel (mutex +
// condition), and the stop flag. It deliberately owns no request/result state
// -- those differ per worker (a per-slot latest-wins frame request vs a
// cancelable segment build), so each subsystem keeps its own and drives its
// wait predicate directly on the shared mutex/cond.
//
// This is core:thread + core:sync, matching the audio producer and render
// worker. The SDL thread/mutex/condition layer it replaces was a second
// threading stack beside the one the rest of the app already uses.
//
// Lifecycle:
//   worker_start(&w, body, owner)  -- spawn; body runs on the new thread
//   worker_request_stop(&w)        -- lock, set stop, wake (all shutdowns)
//   worker_join(&w)                -- wait for the loop to return, free thread
//
// A Worker contains sync.Mutex/Cond (both #no_copy), so do not copy it after
// start; subsystems hold it in package-level structs, which satisfies that
// automatically. Zero value is valid and needs no init: on non-Windows the
// mutex/cond are futex-backed atomics, on Windows SRWLOCK/CONDITION_VARIABLE,
// all of which are usable as zero.
// ---------------------------------------------------------------------------

Worker :: struct {
	thread: ^thread.Thread,
	mutex:  sync.Mutex,
	cond:   sync.Cond,
	stop:   bool,

	// body is the worker loop, called on the new thread with the Worker
	// itself. owner is the subsystem struct, handed back unchanged so the loop
	// can cast it to its real type; the substrate never interprets it.
	body:  proc(w: ^Worker),
	owner: rawptr,
}

// worker_start launches body on its own thread with the handles stored in w.
// Returns false if the OS refused the thread; callers leave the subsystem's
// thread nil and their existing "worker not running" fallbacks take over.
// w and owner must outlive the worker.
worker_start :: proc(w: ^Worker, body: proc(w: ^Worker), owner: rawptr) -> bool {
	w.body = body
	w.owner = owner
	w.thread = thread.create_and_start_with_data(w, worker_entry)
	return w.thread != nil
}

// worker_entry is the single thread entry point. core:thread carries the
// Worker through its data pointer, so there is no per-worker trampoline.
worker_entry :: proc(data: rawptr) {
	w := (^Worker)(data)
	w.body(w)
}

// worker_wake signals the condition. The caller must already hold w.mutex --
// the same lock its wait predicate reads under -- so a post is lock, mutate,
// wake, unlock.
worker_wake :: proc(w: ^Worker) {
	sync.cond_signal(&w.cond)
}

// worker_request_stop sets stop under the lock and wakes the worker. Every
// shutdown path goes through this so no worker can miss its wakeup and join
// can never hang.
worker_request_stop :: proc(w: ^Worker) {
	sync.mutex_lock(&w.mutex)
	w.stop = true
	sync.cond_signal(&w.cond)
	sync.mutex_unlock(&w.mutex)
}

// worker_join waits for the worker loop to return and frees its thread. Safe
// to call on a Worker that was never started (thread == nil is a no-op).
worker_join :: proc(w: ^Worker) {
	if w.thread != nil {
		thread.destroy(w.thread)
		w.thread = nil
	}
}
