package main

import "core:c"
import "core:fmt"
import "core:os"
import "base:runtime"
import "core:strings"
import "core:time"
import clay "clay-odin"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Background proxy builder.
//
// A source's proxy is encoded as independent all-intra SEGMENTS in source-time
// order, so the head of the timeline goes proxy-fast almost immediately while
// the tail still encodes (see proxy.odin's progressive-proxy design). The
// worker's export loop does NOT block the editor: importing footage is supposed
// to be instant, and the render-loop-driven decoders can't pause while ffmpeg
// runs on the calling thread. So the proxy encode runs on this dedicated worker:
//   - the import thread (`proxy_transcode`) enqueues a request and returns at
//     once -- the clip is on the timeline and previews from the ORIGINAL until
//     the opening segment lands (~1s in);
//   - the worker encodes PROXY_SEG_FRAMES-sized segments head-first, each
//     writing to its own `-progress` file, polling every 50ms and publishing a
//     0..1 cumulative fraction;
//   - ffmpeg's stdout/stderr are attached to nothing (`nil` handles = shut
//     down) and the noise flags are dropped, so nothing can block on a full
//     pipe;
//   - the user can cancel from the modal progress overlay; the worker
//     terminates ffmpeg and removes ONLY the in-flight segment -- completed
//     segments (and their .idx entries) stay usable;
//   - after each segment exits cleanly the worker verifies its frame count and
//     republishes the sidecar .idx so the resolver serves it immediately;
//   - exactly one build runs at a time; a request posted while a build is
//     running is kept as the next job (latest request wins, older are dropped).
//
// `async_import_mode` (state.odin) switches this off for probe/CI runs: those
// assert the proxy exists on disk immediately after import_media returns, so
// they keep the historical synchronous whole-file `proxy_transcode` build.
// ---------------------------------------------------------------------------

// Build_Phase is the worker's coarse state, read by the modal progress overlay.
Build_Phase :: enum i32 {
	Idle = 0, // nothing to do
	Building = 1, // ffmpeg is encoding (progress 0..1, -1 while estimating)
	Verifying = 2, // frame-count parity check on the finished output
	Done_Ok = 3,
	Done_Fail = 4,
	Done_Cancelled = 5,
}

Proxy_Builder :: struct {
	thread: ^sdl.Thread,
	mutex:  ^sdl.Mutex,
	cond:   ^sdl.Condition,
	stop:   bool,

	// Request (render thread writes under mutex; a new request overwrites a
	// still-queued one -- latest wins).
	req_valid: bool,
	req_src:   [4096]u8, // NUL-terminated source path
	req_frames: i64,
	req_dur_us: i64, // source duration, microseconds (percent denominator)
	req_w:      c.int,
	req_h:      c.int,

	// Running job's source (worker-owned, so building_for can compare against
	// the request currently being built even after a newer req_src lands).
	active_src: [4096]u8,

	// cancel_pending is set by the user (or shutdown) to abort whatever is
	// current: the running build terminates ffmpeg, a still-queued request is
	// dropped. Cleared by the worker when the abort completes.
	cancel_pending: bool,

	// Progress/result (worker writes under mutex; render thread reads).
	phase:    Build_Phase,
	progress: f64, // 0..1 while Building, -1 while estimating
}

import_builder: Proxy_Builder

// import_bg_request enqueues a proxy build for `src`. Safe to call with a
// build already running (it becomes the next job). `dur_us` is the source
// duration in microseconds, used to turn ffmpeg's out_time into a percentage.
import_bg_request :: proc(src: cstring, frames: i64, dur_us: i64, w, h: c.int) {
	ib := &import_builder
	if ib.thread == nil {
		return
	}
	sdl.LockMutex(ib.mutex)
	src_s := string(src)
	n := min(len(src_s), len(ib.req_src) - 1)
	copy(ib.req_src[:n], src_s[:n])
	ib.req_src[n] = 0
	ib.req_frames = frames
	ib.req_dur_us = max(dur_us, 1)
	ib.req_w = w
	ib.req_h = h
	ib.req_valid = true
	sdl.SignalCondition(ib.cond)
	sdl.UnlockMutex(ib.mutex)
}

// import_bg_building_for reports whether a proxy build is in flight (or queued)
// for `src`. proxy_pick_for_frame uses it to refuse latching a half-written whole
// proxy while segmentation is being established: validating a partial file
// against the source's frame count would delete it while ffmpeg is still
// writing (a lost artifact + a removed artifact from under its open handle).
import_bg_building_for :: proc(src: string) -> bool {
	ib := &import_builder
	sdl.LockMutex(ib.mutex)
	defer sdl.UnlockMutex(ib.mutex)
	if ib.phase == .Building || ib.phase == .Verifying {
		if strings.compare(string(cstring(&ib.active_src[0])), src) == 0 {
			return true
		}
	}
	return ib.req_valid && strings.compare(string(cstring(&ib.req_src[0])), src) == 0
}

// import_bg_cancel aborts the current proxy job (running or queued). The worker
// picks it up on its next poll and, if ffmpeg was running, terminates it and
// deletes the partial proxy.
import_bg_cancel :: proc() {
	ib := &import_builder
	if ib.thread == nil {
		return
	}
	sdl.LockMutex(ib.mutex)
	ib.cancel_pending = true
	sdl.SignalCondition(ib.cond)
	sdl.UnlockMutex(ib.mutex)
}

// import_bg_active reports whether the modal progress overlay should show (a
// build is running or one is queued).
import_bg_active :: proc() -> bool {
	ib := &import_builder
	sdl.LockMutex(ib.mutex)
	defer sdl.UnlockMutex(ib.mutex)
	return ib.phase == .Building || ib.phase == .Verifying || ib.req_valid
}

// box_contains is a point-in-rect test for manual (non-clay) hit-testing, e.g.
// the cancel button of the background-import modal.
box_contains :: proc(b: clay.BoundingBox, x, y: f32) -> bool {
	if b.width <= 0 || b.height <= 0 {
		return false
	}
	return x >= b.x && x < b.x + b.width && y >= b.y && y < b.y + b.height
}

// import_bg_status snapshots the builder for the modal overlay. `src` points
// into the builder's own buffers (stable until the next request/claim).
import_bg_status :: proc() -> (active: bool, frac: f64, phase: Build_Phase, src: cstring) {
	ib := &import_builder
	sdl.LockMutex(ib.mutex)
	defer sdl.UnlockMutex(ib.mutex)
	active = ib.phase == .Building || ib.phase == .Verifying || ib.req_valid
	frac = ib.progress
	phase = ib.phase
	if ib.phase == .Building || ib.phase == .Verifying {
		src = cstring(&ib.active_src[0])
	} else {
		src = cstring(&ib.req_src[0])
	}
	return
}

// import_bg_consume_done clears a finished job's terminal phase so the overlay
// closes and the worker can start the next queued request.
import_bg_consume_done :: proc() {
	ib := &import_builder
	sdl.LockMutex(ib.mutex)
	defer sdl.UnlockMutex(ib.mutex)
	#partial switch ib.phase {
	case .Done_Ok, .Done_Fail, .Done_Cancelled:
		ib.phase = .Idle
	case:
		// still running or idle -- nothing to consume
	}
}

import_bg_init :: proc() {
	ib := &import_builder
	ib.mutex = sdl.CreateMutex()
	ib.cond = sdl.CreateCondition()
	ib.phase = .Idle
	ib.progress = -1
	ib.thread = sdl.CreateThread(import_bg_worker, "import_bg", ib)
}

// import_bg_shutdown stops the worker and frees its resources. A build in
// flight is cancelled (ffmpeg terminated, partial proxy removed) rather than
// waited out.
import_bg_shutdown :: proc() {
	ib := &import_builder
	if ib.thread == nil {
		return
	}
	sdl.LockMutex(ib.mutex)
	ib.cancel_pending = true
	ib.stop = true
	sdl.SignalCondition(ib.cond)
	sdl.UnlockMutex(ib.mutex)
	sdl.WaitThread(ib.thread, nil)
	sdl.DestroyCondition(ib.cond)
	sdl.DestroyMutex(ib.mutex)
	ib.thread = nil
}

// import_bg_worker owns the ffmpeg build loop (see the module comment).
import_bg_worker :: proc "c" (data: rawptr) -> c.int {
	context = runtime.default_context()
	ib := (^Proxy_Builder)(data)
	spall_thread_init("import_bg")
	defer spall_thread_term()
	for {
		sdl.LockMutex(ib.mutex)
		busy := ib.phase == .Building || ib.phase == .Verifying
		for !ib.stop && !ib.req_valid && !ib.cancel_pending && !busy {
			sdl.WaitCondition(ib.cond, ib.mutex)
			busy = ib.phase == .Building || ib.phase == .Verifying
		}
		if ib.stop {
			sdl.UnlockMutex(ib.mutex)
			break
		}
		// A cancel with no running build drops the queued request outright.
		if ib.cancel_pending && !busy && ib.req_valid {
			ib.cancel_pending = false
			ib.req_valid = false
			ib.phase = .Done_Cancelled
			sdl.UnlockMutex(ib.mutex)
			continue
		}
		if ib.req_valid && !busy {
			n := 0
			for n < len(ib.active_src) - 1 && ib.req_src[n] != 0 {
				ib.active_src[n] = ib.req_src[n]
				n += 1
			}
			ib.active_src[n] = 0
			frames := ib.req_frames
			dur_us := ib.req_dur_us
			w := ib.req_w
			h := ib.req_h
			ib.req_valid = false
			ib.phase = .Building
			ib.progress = -1
			sdl.UnlockMutex(ib.mutex)

			import_bg_build(ib, cstring(&ib.active_src[0]), frames, dur_us, w, h)
			continue
		}
		// Cancel pending while a build runs: the build loop polls it (it may
		// legitimately be mid-encode on this same thread right now), so just
		// re-wait.
		sdl.UnlockMutex(ib.mutex)
	}
	return 0
}

// import_bg_build transcodes one source to its low-res all-intra proxy,
// encoding it as independent PROXY_SEG_FRAMES-sized segments in SOURCE-TIME
// ORDER so the head of the timeline goes proxy-fast almost immediately while
// the tail still encodes. Each segment's completed + verified frame count is
// written to the sidecar .idx (the single writer for that file); the resolver
// (proxy_pick_for_frame) reads it to serve frames inside finished segments.
// Cancelling keeps every completed segment and only drops the in-flight one.
// The encode settings mirror proxy_transcode's synchronous whole-file build so
// a proxied frame is pixel-identical on either path.
import_bg_build :: proc(ib: ^Proxy_Builder, src: cstring, frames: i64, dur_us: i64, w, h: c.int) {
	spall_scope(#procedure)
	scale_w, scale_h := proxy_scale(w, h)
	filter := fmt.aprintf("scale=%d:%d", scale_w, scale_h)
	threads := proxy_encode_threads()
	defer delete(filter)
	defer delete(threads)

	seg_total := proxy_seg_count(frames)
	fps := f64(frames) * 1e6 / f64(max(dur_us, 1))
	if seg_total <= 0 || fps <= 0 {
		if vyper_trace {
			fmt.printf("[bg] bad segment plan for %q: frames=%d dur_us=%d\n", string(src), frames, dur_us)
		}
		import_bg_set_phase(ib, .Done_Fail)
		return
	}

	idx: Proxy_Idx
	defer delete(idx.segs)
	idx.seg_frames = PROXY_SEG_FRAMES

	// Completed frames so far, as a cumulative fraction of the source: the
	// playhead sees a fully-proxied region equal to `completed*fps` seconds.
	last_frac: f64 = -1
	completed_frames: i64
	for k in 0 ..< seg_total {
		seg_start := i64(k) * PROXY_SEG_FRAMES
		seg_want := min(PROXY_SEG_FRAMES, frames - seg_start)
		if seg_want <= 0 {
			break
		}
		t0_sec := f64(seg_start) / fps

		seg_buf: [4096]u8
		seg, sok := proxy_segment_path_for(src, k, seg_buf[:])
		if !sok {
			import_bg_set_phase(ib, .Done_Fail)
			return
		}
		progress_file := strings.concatenate({string(seg), ".progress"})
		defer delete(progress_file)

		// A cancel between segments keeps everything built so far (the head is
		// still fully usable); only the untouched tail is forgone.
		{
			sdl.LockMutex(ib.mutex)
			pending := ib.cancel_pending
			sdl.UnlockMutex(ib.mutex)
			if pending {
				if vyper_trace {
					fmt.printf("[bg] cancel between segments; keeping %d completed frames\n", completed_frames)
				}
				import_bg_set_phase(ib, .Done_Cancelled)
				import_bg_clear_cancel(ib)
				return
			}
		}

		// A completed segment already on disk (a prior session's build, or a
		// cancelled rebuild that kept the head) is reused as-is rather than
		// re-encoded: the rebuild then only fills the missing tail, and the
		// preview never falls back to full-res source decode for footage the
		// proxy head already covers. Verified by frame count like the fresh
		// encode (a stale/truncated file fails and is re-encoded).
		if os.exists(string(seg)) {
			have := proxy_probe_frame_count(seg)
			tol: i64
			if k == seg_total - 1 {
				tol = PROXY_FRAME_TOLERANCE
			}
			if have >= seg_want - tol {
				for len(idx.segs) <= k {
					append(&idx.segs, 0)
				}
				idx.segs[k] = have
				completed_frames += have
				if nered_trace {
					fmt.printf("[bg] segment %d/%d reused: %d frames\n", k + 1, seg_total, have)
				}
				continue
			}
		}

		t0_str := fmt.aprintf("%.3f", t0_sec)
		want_str := fmt.aprintf("%d", seg_want)
		argv := []string{
			"ffmpeg", "-y",
			"-ss", t0_str,
			"-i", string(src),
			"-an",
			"-vf", filter,
			"-c:v", "libx264",
			"-preset", "ultrafast",
			"-tune", "fastdecode",
			"-crf", "26",
			"-g", "1",
			"-threads", threads,
			"-frames:v", want_str,
			"-pix_fmt", "yuv420p",
			"-progress", progress_file,
			"-nostats", "-loglevel", "error", "-hide_banner",
			string(seg),
		}
		defer delete(t0_str)
		defer delete(want_str)
		rargv, free_path, free_argv := resolve_tool_argv(argv)
		defer if free_argv {
			delete(rargv)
		}
		defer if free_path != "" {
			delete(free_path)
		}

		// No stdout/stderr handles: ffmpeg's log is silenced (-loglevel error)
		// and progress goes to the -progress file, so nothing can block on a
		// full pipe.
		proc_handle, spawn_err := os.process_start({command = rargv, stdout = nil, stderr = nil})
		if spawn_err != nil {
			if vyper_trace {
				fmt.printf("[bg] spawn ffmpeg failed: %v\n", spawn_err)
			}
			os.remove(progress_file)
			os.remove(string(seg))
			import_bg_set_phase(ib, .Done_Fail)
			return
		}

		for {
			// Cancellation wins over encoding: terminate ffmpeg and drop the
			// in-flight segment immediately -- completed segments (and their
			// .idx entries) must never be touched by a cancel.
			sdl.LockMutex(ib.mutex)
			cancelled := ib.cancel_pending
			sdl.UnlockMutex(ib.mutex)
			if cancelled {
				_ = os.process_terminate(proc_handle)
				_, _ = os.process_wait(proc_handle, os.TIMEOUT_INFINITE)
				os.remove(string(seg))
				os.remove(progress_file)
				import_bg_set_phase(ib, .Done_Cancelled)
				import_bg_clear_cancel(ib)
				return
			}

			st, werr := os.process_wait(proc_handle, 0)
			if werr != nil && werr != os.General_Error.Timeout {
				if vyper_trace {
					fmt.printf("[bg] process wait poll failed: %v\n", werr)
				}
				_, _ = os.process_wait(proc_handle, os.TIMEOUT_INFINITE)
				os.remove(string(seg))
				os.remove(progress_file)
				import_bg_set_phase(ib, .Done_Fail)
				return
			}
			if werr == nil && st.exited {
				break
			}

			// Cumulative progress: completed segments + this segment's local
			// frame counter (resets per process), over the source's own count.
			if n := proxy_progress_frames(progress_file); n >= 0 {
				frac := clamp(f64(completed_frames + n) / f64(frames), 0, 1)
				if frac > last_frac {
					import_bg_set_progress(ib, frac)
					last_frac = frac
				}
			}
			time.sleep(50 * time.Millisecond)
		}

		// Clean exit for this segment: it must carry what we asked for (the
		// final segment may legitimately be short when the source's estimated
		// frame count overstates reality -- same PROXY_FRAME_TOLERANCE the
		// whole-file path allows).
		os.remove(progress_file)
		count := proxy_probe_frame_count(seg)
		tol: i64
		if k == seg_total - 1 {
			tol = PROXY_FRAME_TOLERANCE
		}
		if count < seg_want - tol {
			if vyper_trace {
				fmt.printf("[bg] segment %d short: wanted %d frames, got %d\n", k, seg_want, count)
			}
			os.remove(string(seg))
			import_bg_set_phase(ib, .Done_Fail)
			import_bg_set_progress(ib, -1)
			return
		}

		// Register the segment and publish the index so the resolver can start
		// serving it immediately.
		for len(idx.segs) <= k {
			append(&idx.segs, 0)
		}
		idx.segs[k] = count
		proxy_idx_store(src, &idx)
		completed_frames += count
		frac := clamp(f64(completed_frames) / f64(frames), 0, 1)
		if frac > last_frac {
			import_bg_set_progress(ib, frac)
			last_frac = frac
		}
		if vyper_trace {
			fmt.printf("[bg] segment %d/%d done: %d frames -> %.1f%%\n", k + 1, seg_total, count, frac * 100)
		}
	}

	import_bg_set_phase(ib, .Verifying)
	phase: Build_Phase = .Done_Ok
	sum: i64
	for c in idx.segs {
		sum += c
	}
	if sum < frames - PROXY_FRAME_TOLERANCE {
		phase = .Done_Fail
		import_bg_set_progress(ib, -1)
	}
	import_bg_set_phase(ib, phase)
	import_bg_clear_cancel(ib)
	if vyper_trace {
		fmt.printf("[bg] proxy %s -> %v (segments=%d, %d frames)\n", string(src), phase, seg_total, sum)
	}
}

import_bg_set_phase :: proc(ib: ^Proxy_Builder, phase: Build_Phase) {
	sdl.LockMutex(ib.mutex)
	ib.phase = phase
	sdl.UnlockMutex(ib.mutex)
}

import_bg_set_progress :: proc(ib: ^Proxy_Builder, frac: f64) {
	sdl.LockMutex(ib.mutex)
	ib.progress = frac
	sdl.UnlockMutex(ib.mutex)
}

import_bg_clear_cancel :: proc(ib: ^Proxy_Builder) {
	sdl.LockMutex(ib.mutex)
	ib.cancel_pending = false
	sdl.UnlockMutex(ib.mutex)
}

// proxy_progress_frac parses the tail of an ffmpeg `-progress` file into a
// 0..1 fraction of the source duration, or -1 when no usable timestamp is
// present yet (indeterminate). `out_time_us=` is microseconds since ffmpeg 4.4;
// `out_time_ms=` carried the same microsecond units on older builds -- either is
// fine, both are absolute stream time in microseconds.
proxy_progress_frac :: proc(path: string, total_us: i64) -> f64 {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil || len(data) == 0 {
		return -1
	}
	defer delete(data)
	text := string(data)
	us: i64 = -1
	idx := strings.last_index(text, "out_time_us=")
	marker_len := len("out_time_us=")
	if idx < 0 {
		idx = strings.last_index(text, "out_time_ms=")
		marker_len = len("out_time_ms=")
	}
	if idx >= 0 {
		us = proxy_progress_micros(text[idx + marker_len:])
	}
	if us <= 0 {
		return -1
	}
	return clamp(f64(us) / f64(total_us), 0, 1)
}

// proxy_progress_micros parses the leading digits of a progress line value.
proxy_progress_micros :: proc(s: string) -> i64 {
	v: i64
	for i in 0 ..< len(s) {
		c := s[i]
		if c < '0' || c > '9' {
			break
		}
		v = v * 10 + i64(c - '0')
	}
	return v
}

// proxy_progress_frames parses the `frame=` field out of an ffmpeg `-progress`
// file tail: the count of frames encoded so far in the CURRENT process.
// Unlike out_time (whose timestamps depend on whether an input seek rebases
// them), the frame counter always resets to 0 per invocation, so the segment
// builder can derive EXACT cumulative progress as (completed + local) / total.
// Returns -1 when no usable count is present yet.
proxy_progress_frames :: proc(path: string) -> i64 {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil || len(data) == 0 {
		return -1
	}
	defer delete(data)
	text := string(data)
	idx := strings.last_index(text, "frame=")
	marker_len := len("frame=")
	if idx < 0 {
		return -1
	}
	return proxy_progress_micros(text[idx + marker_len:])
}
