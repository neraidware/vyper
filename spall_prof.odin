// Spall instrumentation (core:prof/spall), gated behind the NERED_SPALL env
// var. When unset the whole thing is a single cheap branch, so profiling is
// compiled in for every build (development + release) with zero idle cost.
//
// Usage: NERED_SPALL=/path/to/capture.spall ./nered
//
// One shared Context (file writer) is created up front; each thread gets its
// own Spall buffer (thread-local) and names itself so the trace distinguishes
// the render thread from the decode / background-proxy threads. Reinstrument
// hot procs with:
//
//	spall_scope(#procedure)
//
// The scope's end event fires on ANY exit of the enclosing proc (early return
// included) via deferred_in. Because the enable flag is stable for a run, the
// end hook can re-check the same gate instead of threading a per-scope result.
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:prof/spall"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

spall_enabled: bool
spall_ctx:     spall.Context // shared by every thread (read-only after init)
spall_deadline_ns: i64     // capture duration limit (0 = unbounded)

@(thread_local) spall_buffer: spall.Buffer
@(thread_local) spall_buffer_data: [spall.BUFFER_DEFAULT_SIZE]u8
@(thread_local) spall_thread_active: bool

// spall_prof_init opens the capture file when NERED_SPALL is set and arms the
// render thread's buffer. Returns true always (init is best-effort).
spall_prof_init :: proc() -> bool {
	path := os.get_env_alloc("NERED_SPALL", context.temp_allocator)
	if path == "" {
		spall_enabled = false
		return true
	}
	// precise_time=false: timestamps come from CLOCK_MONOTONIC_RAW (ns), so the
	// scale is exactly 1.0 ns/tick. No RDTSC calibration, no startup sleep, and
	// timestamps are real wall-clock-ns comparable across threads.
	ctx, ok := spall.context_create_with_scale(path, false, 1.0)
	if !ok {
		fmt.eprintf("[spall] could not open capture file %q\n", path)
		spall_enabled = false
		return true
	}
	spall_ctx = ctx
	spall_enabled = true
	spall_thread_init("render")
	// Optional capture-duration limit (ms): lets a scripted run take a bounded
	// trace and exit cleanly so the shutdown defers flush the buffers. The
	// render loop calls spall_expired() each frame and breaks when reached.
	if ms := os.get_env_alloc("NERED_SPALL_MS", context.temp_allocator); ms != "" {
		if v, ok := strconv.parse_i64(strings.trim_space(ms)); ok && v > 0 {
			spall_deadline_ns = time.now()._nsec + v * 1_000_000
		}
	}
	return true
}

// spall_expired reports whether the optional capture-duration limit was reached
// (render loop breaks so startup defers flush the trace). Always false when no
// limit was set or profiling is off.
spall_expired :: proc() -> bool {
	if !spall_enabled || spall_deadline_ns == 0 {
		return false
	}
	return time.now()._nsec >= spall_deadline_ns
}

// spall_prof_shutdown flushes the render-thread buffer and closes the file.
// Must run after every worker thread has called spall_thread_term (main already
// defers the worker shutdowns above its own shutdown).
spall_prof_shutdown :: proc() {
	if !spall_enabled {
		return
	}
	spall_thread_term()
	spall.context_destroy(&spall_ctx)
	spall_enabled = false
}

// spall_thread_init arms the calling thread's buffer (worker threads must call
// this at thread start; the render thread gets it from spall_prof_init).
spall_thread_init :: proc(name: string) {
	if !spall_enabled {
		return
	}
	buf, ok := spall.buffer_create(spall_buffer_data[:], u32(sync.current_thread_id()))
	if !ok {
		return
	}
	spall_buffer = buf
	spall_thread_active = true
	spall._buffer_name_thread(&spall_ctx, &spall_buffer, name)
}

// spall_thread_term flushes the calling thread's buffer (must run at thread
// exit so no pending events are lost).
spall_thread_term :: proc() {
	if !spall_enabled || !spall_thread_active {
		return
	}
	spall.buffer_destroy(&spall_ctx, &spall_buffer)
	spall_thread_active = false
}

// spall_scope emits a Begin event and, at the end of the enclosing scope (any
// exit path), the matching End. Never call this from a thread that did not
// spall_thread_init first -- the inactive gate catches that.
@(deferred_in = spall_scope_end)
@(no_instrumentation)
spall_scope :: proc(name: string) -> bool {
	if !spall_enabled || !spall_thread_active {
		return false
	}
	spall._buffer_begin(&spall_ctx, &spall_buffer, name)
	return true
}

@(no_instrumentation)
spall_scope_end :: proc(name: string) {
	if !spall_enabled || !spall_thread_active {
		return
	}
	spall._buffer_end(&spall_ctx, &spall_buffer)
}

// ---------------------------------------------------------------------------
// Full-program instrumentation: every proc call emits a begin/end pair, giving
// the whole call tree. NOTE: in this toolchain, merely DECLARING the
// instrumentation_enter/exit hooks makes the compiler instrument the entire
// program (no -instrument flag needed) -- which would cost the release build a
// guard check on every proc call even with profiling off. So the hooks are
// compiled out by default and only exist when explicitly requested:
//
//	odin build . -define:NERED_INSTRUMENT=true -o:aggressive ...
//	NERED_SPALL=/tmp/x.spall ./nered
//
// Expect a big trace (this toolchain: ~20 MB per second); keep NERED_SPALL_MS
// short. For hot-path work the manual spall_scope markers are enough.
// ---------------------------------------------------------------------------
when #config(NERED_INSTRUMENT, false) {

	@(instrumentation_enter)
	profiler_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		if !spall_enabled || !spall_thread_active {
			return
		}
		spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
	}

	@(instrumentation_exit)
	profiler_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		if !spall_enabled || !spall_thread_active {
			return
		}
		spall._buffer_end(&spall_ctx, &spall_buffer)
	}

}