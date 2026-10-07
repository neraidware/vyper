package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import clay "clay-odin"

// ---------------------------------------------------------------------------
// Background proxy builder.
//
// A source's proxy is encoded as independent all-intra SEGMENTS in source-time
// order, so the head of the timeline goes proxy-fast almost immediately while
// the tail still encodes (see proxy.odin's progressive-proxy design). The
// worker's export loop does NOT block the editor: importing footage is supposed
// to be instant, and the render-loop-driven decoders can't pause while the
// encode runs on the calling thread. So the proxy encode runs on this dedicated
// worker, in-process via libx264 (no ffmpeg subprocess; proxy_encode.odin):
//   - the import thread (`proxy_transcode`) enqueues a request and returns at
//     once -- the clip is on the timeline and previews from the ORIGINAL until
//     the opening segment lands (~1s in);
//   - the worker encodes PROXY_SEG_FRAMES-sized segments head-first, each
//     reporting a 0..1 cumulative fraction through the on_frames callback;
//   - encodes are single-threaded into the worker (a shared libav encode
//     context is never written from another thread), so there is no stdout/
//     stderr to attach and nothing that can block on a full pipe;
//   - the user can cancel from the corner status badge; the worker polls the
//     cancel flag every 32 frames and removes ONLY the in-flight segment --
//     completed segments (and their .idx entries) stay usable;
//   - after each segment exits cleanly the worker verifies its frame count and
//     republishes the sidecar .idx so the resolver serves it immediately;
//   - exactly one build runs at a time; a request posted while a build is
//     running is kept as the next job (latest request wins, older are dropped).
//
// `editor_flags.async_import_mode` (state.odin) switches this off for probe/CI runs: those
// assert the proxy exists on disk immediately after import_media returns, so
// they keep the historical synchronous whole-file `proxy_transcode` build.
// ---------------------------------------------------------------------------

// Build_Phase is the worker's coarse state, read by the corner build badge.
Build_Phase :: enum i32 {
	Idle = 0, // nothing to do
	Building = 1, // segment encode in progress (progress 0..1, -1 while estimating)
	Verifying = 2, // frame-count parity check on the finished output
	Done_Ok = 3,
	Done_Fail = 4,
	Done_Cancelled = 5,
}

Proxy_Builder :: struct {
	// worker is the shared thread + wake-channel substrate. The request/result
	// fields below stay owned by this struct because they encode build-job
	// semantics (latest-wins window request, cancel/supersede, phase+progress)
	// that no other worker shares.
	worker: Worker,

	// Request (render thread writes under mutex; a new request overwrites a
	// still-queued one -- latest wins). A request targets a SEGMENT WINDOW
	// [req_seg_lo, req_seg_hi) rather than the whole source: the on-demand
	// scheduler keeps one window live around the playhead, so the worker must
	// be able to build a middle slice without demanding full coverage.
	req_valid:  bool,
	req_src:    [4096]u8, // NUL-terminated source path
	req_frames: i64,
	req_dur_us: i64, // source duration, microseconds (percent denominator)
	req_w:      c.int,
	req_h:       c.int,
	req_seg_lo:  int,
	req_seg_hi:  int,

	// Running job's source + window (worker-owned, so building_for can compare
	// against the request currently being built even after a newer req_src
	// lands, and the scheduler can see how far the in-flight build reaches).
	active_src:  [4096]u8,
	active_seg_lo: int,
	active_seg_hi: int,

	// done_window records the window a finished Done_Ok build covered, so the
	// scheduler can extend from that frontier instead of re-requesting what's
	// already on disk. Cleared by consume_done.
	done_ok:     bool,
	done_seg_lo: int,
	done_seg_hi: int,

	// last_result records the terminal outcome of the most recent job. The
	// scheduler uses it to suppress re-posting a window the user just
	// cancelled or the worker just failed, so a build the playhead still sits
	// on isn't instantly re-queued every frame. It is NOT cleared on consume
	// (the suppression must hold until the playhead leaves that window); a
	// stale cancel/fail only re-asserts when a new identical window would be
	// posted, and a genuinely new window never matches its (lo, hi) pair.
	last_result_phase: Build_Phase,
	last_result_src:   [4096]u8,
	last_result_lo:    int,
	last_result_hi:    int,

	// cancel_pending is set by the user (or shutdown) to abort whatever is
	// current: the running build aborts via its cancel poll, a still-queued
	// request is dropped. Cleared by the worker when the abort completes.
	cancel_pending: bool,

	// req_supersede is set by import_bg_redefine alongside cancel_pending: it
	// tells the worker the cancel is a RETARGET (drop the old target, keep the
	// freshly-posted replacement request) rather than a plain abort. The
	// worker clears it when the cancel is resolved.
	req_supersede: bool,

	// Progress/result (worker writes under mutex; render thread reads).
	phase:    Build_Phase,
	progress: f64, // 0..1 while Building, -1 while estimating
}

// Import_UI_State is the async-import dialog's UI state: the Proxy_Builder
// driving the background segment encode, plus the cancel button's hit box
// (filled each frame the dialog draws). Both live together because the cancel
// box only matters for the dialog this builder feeds.
Import_UI_State :: struct {
	builder:  Proxy_Builder,
	cancel_box: clay.BoundingBox,
}
import_ui: Import_UI_State

// import_bg_may_encode is the builder's admission check, and the ONE place that
// decides whether a source is worth an H.264 proxy at all.
//
// A STILL IMAGE IS NOT A SOURCE. It probes as a one-frame mjpeg video stream --
// verified with ffprobe: codec_type=video, codec_name=mjpeg, r_frame_rate=25/1,
// nb_frames=N/A -- so every "does this have video?" test upstream says yes and
// hands us a .jpg to encode. A still needs no proxy: it is one frame, decoded
// directly, and the proxy path would only ever make it worse.
//
// It was worse than wasteful. With no frame to send, the encode loop reached its
// trailing drain having fed the encoder nothing, and h264_vaapi dereferenced
// surface state that only exists after the first real frame: SIGSEGV inside
// libavcodec, on the import worker. Reproduced exactly (same two log lines, same
// signal) before this check existed.
//
// `frames <= 0` is refused for the same reason and is not image-specific: with no
// frames there is nothing to encode, and the drain below would fault.
//
// The caller-facing side of the same fact is `clip.is_still`, which
// import_media_to_bin already sets and proxy_maybe_post_build already has in
// hand -- it is checked HERE rather than there so this stays the single admission
// point, and no future caller can post a source the encoder will crash on.
import_bg_may_encode :: proc(src: cstring, frames: i64, dur_us: i64) -> bool {
	if media_is_image(src) {
		when ODIN_DEBUG {
			if vyper_trace {
				fmt.printf("[bg] refused a still image: %q needs no proxy\n", string(src))
			}
		}
		return false
	}
	if frames <= 0 || dur_us <= 0 {
		when ODIN_DEBUG {
			if vyper_trace {
				fmt.printf(
					"[bg] refused %q: frames=%d dur=%dus, nothing to encode\n",
					string(src),
					frames,
					dur_us,
				)
			}
		}
		return false
	}
	return true
}

// import_bg_request enqueues a proxy build of the SEGMENT WINDOW
// [seg_lo, seg_hi) of `src` (half-open; seg_lo..seg_hi-1). Safe to call with a
// build already running (it becomes the next job). A request for a window that
// is already fully built is a cheap no-op (the worker's reuse path skips it),
// so the scheduler can re-anchor the window every time the playhead moves
// without caring what's on disk. `dur_us` names the source duration for the
// failed-build log; the progress fraction is frame-based (encoder callback).
import_bg_request :: proc(
	src: cstring,
	frames: i64,
	dur_us: i64,
	w, h: c.int,
	seg_lo, seg_hi: int,
) {
	ib := &import_ui.builder
	if !import_bg_may_encode(src, frames, dur_us) {
		return
	}
	if ib.worker.thread == nil {
		return
	}
	sync.mutex_lock(&ib.worker.mutex)
	src_s := string(src)
	n := min(len(src_s), len(ib.req_src) - 1)
	copy(ib.req_src[:n], src_s[:n])
	ib.req_src[n] = 0
	ib.req_frames = frames
	ib.req_dur_us = max(dur_us, 1)
	ib.req_w = w
	ib.req_h = h
	ib.req_seg_lo = seg_lo
	ib.req_seg_hi = seg_hi
	ib.req_valid = true
	worker_wake(&ib.worker)
	sync.mutex_unlock(&ib.worker.mutex)
}

// import_bg_redefine retargets the builder to `src`'s window [seg_lo, seg_hi),
// ABANDONING whatever was in flight: a running build for a stale target is
// terminated (its completed segments stay for reuse -- see the builder's
// cancel semantics), and the new request wins. This is the on-demand
// scheduler's "far jump" primitive: scrubbed to a distant region, so do not
// finish encoding the region the playhead just left.
import_bg_redefine :: proc(
	src: cstring,
	frames: i64,
	dur_us: i64,
	w, h: c.int,
	seg_lo, seg_hi: int,
) {
	ib := &import_ui.builder
	if !import_bg_may_encode(src, frames, dur_us) {
		return
	}
	if ib.worker.thread == nil {
		return
	}
	sync.mutex_lock(&ib.worker.mutex)
	src_s := string(src)
	n := min(len(src_s), len(ib.req_src) - 1)
	copy(ib.req_src[:n], src_s[:n])
	ib.req_src[n] = 0
	ib.req_frames = frames
	ib.req_dur_us = max(dur_us, 1)
	ib.req_w = w
	ib.req_h = h
	ib.req_seg_lo = seg_lo
	ib.req_seg_hi = seg_hi
	// Mark that the cancel was issued holding this request: the worker must
	// not drop a freshly-posted target the way it drops a cancelled one.
	ib.req_supersede = true
	ib.cancel_pending = true
	ib.req_valid = true
	worker_wake(&ib.worker)
	sync.mutex_unlock(&ib.worker.mutex)
}

// import_bg_building_for reports whether a proxy build is in flight (or queued)
// for `src`. proxy_pick_for_frame uses it to refuse latching a half-written whole
// proxy while segmentation is being established: validating a partial file
// against the source's frame count would delete it while the worker is still
// writing (a lost artifact + a removed artifact from under its open handle).
import_bg_building_for :: proc(src: string) -> bool {
	ib := &import_ui.builder
	sync.mutex_lock(&ib.worker.mutex)
	defer sync.mutex_unlock(&ib.worker.mutex)
	if ib.phase == .Building || ib.phase == .Verifying {
		if strings.compare(string(cstring(&ib.active_src[0])), src) == 0 {
			return true
		}
	}
	return ib.req_valid && strings.compare(string(cstring(&ib.req_src[0])), src) == 0
}

// import_bg_cancel aborts the current proxy job (running or queued). The worker
// aborts on its next cancel poll and deletes the partial proxy it was on.
import_bg_cancel :: proc() {
	ib := &import_ui.builder
	if ib.worker.thread == nil {
		return
	}
	sync.mutex_lock(&ib.worker.mutex)
	ib.cancel_pending = true
	worker_wake(&ib.worker)
	sync.mutex_unlock(&ib.worker.mutex)
}

// import_bg_active reports whether the corner build badge should show (a build
// is running or one is queued).
import_bg_active :: proc() -> bool {
	ib := &import_ui.builder
	sync.mutex_lock(&ib.worker.mutex)
	defer sync.mutex_unlock(&ib.worker.mutex)
	return ib.phase == .Building || ib.phase == .Verifying || ib.req_valid
}

// box_contains is a point-in-rect test for manual (non-clay) hit-testing, e.g.
// the cancel button of the background-import badge.
box_contains :: proc(b: clay.BoundingBox, x, y: f32) -> bool {
	if b.width <= 0 || b.height <= 0 {
		return false
	}
	return x >= b.x && x < b.x + b.width && y >= b.y && y < b.y + b.height
}

// import_bg_status snapshots the builder for the corner build badge. `src`
// points into the builder's own buffers (stable until the next request/claim).
import_bg_status :: proc() -> (active: bool, frac: f64, phase: Build_Phase, src: cstring) {
	ib := &import_ui.builder
	sync.mutex_lock(&ib.worker.mutex)
	defer sync.mutex_unlock(&ib.worker.mutex)
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

// import_bg_consume_done clears a finished job's terminal phase so the corner
// badge closes, the overlay logic advances, and the worker can start the next
// queued request. The done_window is NOT cleared here: the scheduler reads it
// to avoid re-requesting a window the worker just built ("playhead hasn't left
// it, nothing to encode"). last_result is likewise left alone -- the scheduler
// uses it to suppress re-posting a window the user just cancelled or the worker
// just failed until the playhead moves on. The worker clears both when it
// claims the NEXT request.
import_bg_consume_done :: proc() {
	ib := &import_ui.builder
	sync.mutex_lock(&ib.worker.mutex)
	defer sync.mutex_unlock(&ib.worker.mutex)
	#partial switch ib.phase {
	case .Done_Ok, .Done_Fail, .Done_Cancelled:
		ib.phase = .Idle
	case:
		// still running or idle -- nothing to consume
	}
}

import_bg_set_done_window :: proc(ib: ^Proxy_Builder, ok: bool, seg_lo, seg_hi: int) {
	sync.mutex_lock(&ib.worker.mutex)
	ib.done_ok = ok
	ib.done_seg_lo = seg_lo
	ib.done_seg_hi = seg_hi
	sync.mutex_unlock(&ib.worker.mutex)
}

// import_bg_window snapshots the builder's current in-flight target for the
// on-demand scheduler: what src is active/queued, its window, whether a build
// is actually running, and the last completed window. The scheduler uses it to
// dedupe (extend, don't re-post an identical request) and to retarget
// (redefine) when the playhead leaves the window.
import_bg_window :: proc() -> (
	req_src: cstring,
	req_seg_lo, req_seg_hi: int,
	has_request: bool,
	active_src: cstring,
	active_seg_lo, active_seg_hi: int,
	building: bool,
	done_src: cstring,
	done_seg_lo, done_seg_hi: int,
	done_ok: bool,
	last_result_phase: Build_Phase,
	last_result_src: cstring,
	last_result_lo, last_result_hi: int,
) {
	ib := &import_ui.builder
	sync.mutex_lock(&ib.worker.mutex)
	defer sync.mutex_unlock(&ib.worker.mutex)
	req_src = cstring(&ib.req_src[0])
	req_seg_lo, req_seg_hi = ib.req_seg_lo, ib.req_seg_hi
	has_request = ib.req_valid
	active_src = cstring(&ib.active_src[0])
	active_seg_lo, active_seg_hi = ib.active_seg_lo, ib.active_seg_hi
	building = ib.phase == .Building || ib.phase == .Verifying
	done_src = cstring(&ib.active_src[0])
	done_seg_lo, done_seg_hi, done_ok = ib.done_seg_lo, ib.done_seg_hi, ib.done_ok
	last_result_phase = ib.last_result_phase
	last_result_src = cstring(&ib.last_result_src[0])
	last_result_lo, last_result_hi = ib.last_result_lo, ib.last_result_hi
	return
}

import_bg_init :: proc() {
	ib := &import_ui.builder
	ib.phase = .Idle
	ib.progress = -1
	worker_start(&ib.worker, import_bg_worker, ib)
}

// import_bg_shutdown stops the worker and frees its resources. A build in
// flight is cancelled (in-flight encode aborted, partial proxy removed) rather
// than waited out.
import_bg_shutdown :: proc() {
	ib := &import_ui.builder
	if ib.worker.thread == nil {
		return
	}
	sync.mutex_lock(&ib.worker.mutex)
	ib.cancel_pending = true
	worker_wake(&ib.worker)
	sync.mutex_unlock(&ib.worker.mutex)
	worker_request_stop(&ib.worker)
	worker_join(&ib.worker)
}

// import_bg_worker owns the in-process proxy build loop (see the module comment).
import_bg_worker :: proc(worker: ^Worker) {
	ib := (^Proxy_Builder)(worker.owner)
	spall_thread_init("import_bg")
	defer spall_thread_term()
	for {
		sync.mutex_lock(&ib.worker.mutex)
		busy := ib.phase == .Building || ib.phase == .Verifying
		for !worker.stop && !ib.req_valid && !ib.cancel_pending && !busy {
			sync.cond_wait(&ib.worker.cond, &ib.worker.mutex)
			busy = ib.phase == .Building || ib.phase == .Verifying
		}
		if worker.stop {
			sync.mutex_unlock(&ib.worker.mutex)
			break
		}
		// A cancel with no running build drops the queued request outright --
		// UNLESS the cancel is a redefine (req_supersede), in which case the
		// freshly-posted replacement target wins and only the stale request
		// semantics are abandoned.
		if ib.cancel_pending && !busy && ib.req_valid {
			if ib.req_supersede {
				ib.cancel_pending = false
				ib.req_supersede = false
			} else {
				ib.cancel_pending = false
				ib.req_valid = false
				ib.phase = .Done_Cancelled
				// Record the dropped request as the last result so the scheduler
				// does not immediately re-request the exact window the user
				// just cancelled while it still sits on the playhead.
				ib.last_result_phase = .Done_Cancelled
				ib.last_result_src = ib.req_src
				ib.last_result_lo = ib.req_seg_lo
				ib.last_result_hi = ib.req_seg_hi
				sync.mutex_unlock(&ib.worker.mutex)
				continue
			}
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
			seg_lo := ib.req_seg_lo
			seg_hi := ib.req_seg_hi
			ib.active_seg_lo = seg_lo
			ib.active_seg_hi = seg_hi
			ib.done_ok = false
			ib.req_valid = false
			ib.phase = .Building
			ib.progress = -1
			sync.mutex_unlock(&ib.worker.mutex)

			import_bg_build(ib, cstring(&ib.active_src[0]), frames, dur_us, w, h, seg_lo, seg_hi)
			continue
		}
		// Cancel pending while a build runs: the build loop polls it (it may
		// legitimately be mid-encode on this same thread right now), so just
		// re-wait.
		sync.mutex_unlock(&ib.worker.mutex)
	}
}

// Bg_Encode_Progress carries the window-relative progress accumulator for the
// in-process segment encoder's per-frame callback. The worker thread is its
// single writer; import_bg_build reads it after each segment.
Bg_Encode_Progress :: struct {
	ib:   ^Proxy_Builder,
	completed_frames: i64,
	frames: i64,
	last_frac: f64,
}

bg_encode_on_frames :: proc(ud: rawptr, frames_done: int) {
	env := cast(^Bg_Encode_Progress)ud
	frac := clamp(f64(env.completed_frames + i64(frames_done)) / f64(env.frames), 0, 1)
	if frac > env.last_frac {
		import_bg_set_progress(env.ib, frac)
		env.last_frac = frac
	}
}

// bg_encode_cancelled reports the worker's cancel flag; the encoder drops its
// in-flight artifact and returns .Cancelled when this turns true.
bg_encode_cancelled :: proc(ud: rawptr) -> bool {
	env := cast(^Bg_Encode_Progress)ud
	sync.mutex_lock(&env.ib.worker.mutex)
	pending := env.ib.cancel_pending
	sync.mutex_unlock(&env.ib.worker.mutex)
	return pending
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
//
// A request targets the half-open SEGMENT WINDOW [seg_lo, seg_hi) of the
// source, not the whole file: the on-demand scheduler keeps only the playhead's
// neighbourhood being built. The index is seeded from any existing .idx so
// segments outside the window survive the rewrite, and coverage is verified
// window-relative (a mid-source window is not a failed whole-file build).
import_bg_build :: proc(ib: ^Proxy_Builder, src: cstring, frames: i64, dur_us: i64, w, h: c.int, seg_lo, seg_hi: int) {
	spall_scope(#procedure)
	scale_w, scale_h := proxy_scale(w, h)
	threads := proxy_encode_threads()

	seg_total := proxy_seg_count(frames)
	if seg_total <= 0 {
		when ODIN_DEBUG {
			if vyper_trace {
				fmt.printf("[bg] bad segment plan for %q: frames=%d dur_us=%d\n", string(src), frames, dur_us)
			}
		}
		import_bg_finish(ib, .Done_Fail)
		return
	}
	lo := seg_lo
	hi := seg_hi
	if lo < 0 {
		lo = 0
	}
	if hi > seg_total {
		hi = seg_total
	}
	if hi <= lo {
		when ODIN_DEBUG {
			if vyper_trace {
				fmt.printf("[bg] empty window [%d,%d) for %q\n", lo, hi, string(src))
			}
		}
		import_bg_finish(ib, .Done_Fail)
		return
	}

	// Seed the index from disk so the rewrite below keeps every segment a
	// previous window (or earlier session) completed: a windowed build owns
	// the .idx file's whole lifetime, and dropping out-of-window entries would
	// un-serve footage that's still proxied on disk. A mismatched seg size is
	// a stale index from a different segmentation -- ignore it wholesale.
	idx: Proxy_Idx
	defer delete(idx.segs)
	idx.seg_frames = PROXY_SEG_FRAMES
	if proxy_idx_load(src, &idx) {
		if idx.seg_frames != PROXY_SEG_FRAMES {
			clear(&idx.segs)
		}
	}

	// Progress is a cumulative fraction of the SOURCE (what the playhead can
	// actually play fast), so seed it from segments completed by earlier
	// windows/sessions before this window adds its own. Carried in the encode
	// env because the per-frame progress callback is a plain proc pair (no
	// closure capture in Odin) that walks the env through its ud pointer.
	env := Bg_Encode_Progress{
		ib = ib,
		frames = frames,
		last_frac = -1,
	}
	for k in 0 ..< lo {
		if k < len(idx.segs) {
			env.completed_frames += idx.segs[k]
		}
	}

	for k in lo ..< hi {
		seg_start := i64(k) * PROXY_SEG_FRAMES
		seg_want := min(PROXY_SEG_FRAMES, frames - seg_start)
		if seg_want <= 0 {
			break
		}

		seg_buf: [4096]u8
		seg, sok := proxy_segment_path_for(src, k, seg_buf[:])
		if !sok {
			import_bg_finish(ib, .Done_Fail)
			return
		}

		// A cancel between segments keeps everything built so far (the head is
		// still fully usable); only the untouched tail is forgone.
		{
			sync.mutex_lock(&ib.worker.mutex)
			pending := ib.cancel_pending
			sync.mutex_unlock(&ib.worker.mutex)
			if pending {
				when ODIN_DEBUG {
					if vyper_trace {
						fmt.printf("[bg] cancel between segments; keeping %d completed frames\n", env.completed_frames)
					}
				}
				import_bg_finish(ib, .Done_Cancelled)
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
				env.completed_frames += have
				when ODIN_DEBUG {
					if vyper_trace {
						fmt.printf("[bg] segment %d/%d reused: %d frames\n", k + 1, seg_total, have)
					}
				}
				continue
			}
		}

		// In-process encode of this window's segment (libx264 + mp4 inside
		// libav*, no ffmpeg binary). Progress maps the encoder's running frame
		// count onto the source's cumulative fraction; cancellation is the
		// same flag the old process_terminate read, polled by the encoder.
		encode_result: Enc_Result
		encode_result, _ = proxy_encode_range(
			src,
			seg,
			seg_start, seg_want,
			scale_w, scale_h,
			threads,
			&env,
			bg_encode_on_frames,
			bg_encode_cancelled,
		)
		switch encode_result {
		case .Cancelled:
			// Termination semantics identical to the old kill: cancel removes
			// the in-flight artifact, never a completed segment.
			os.remove(string(seg))
			import_bg_finish(ib, .Done_Cancelled)
			import_bg_clear_cancel(ib)
			return
		case .Fail:
			when ODIN_DEBUG {
				if vyper_trace {
					fmt.printf("[bg] segment %d encode failed for %q\n", k, string(src))
				}
			}
			os.remove(string(seg))
			import_bg_finish(ib, .Done_Fail)
			import_bg_set_progress(ib, -1)
			return
		case .Ok:
		}

		// Verify the written artifact by re-opening it in-process: it must
		// carry what we asked for (the final segment may legitimately be short
		// when the source's estimated frame count overstates reality -- same
		// PROXY_FRAME_TOLERANCE the whole-file path allows).
		count := proxy_probe_frame_count(seg)
		tol: i64
		if k == seg_total - 1 {
			tol = PROXY_FRAME_TOLERANCE
		}
		if count < seg_want - tol {
			when ODIN_DEBUG {
				if vyper_trace {
					fmt.printf("[bg] segment %d short: wanted %d frames, got %d\n", k, seg_want, count)
				}
			}
			os.remove(string(seg))
			import_bg_finish(ib, .Done_Fail)
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
		env.completed_frames += count
		frac := clamp(f64(env.completed_frames) / f64(frames), 0, 1)
		if frac > env.last_frac {
			import_bg_set_progress(ib, frac)
			env.last_frac = frac
		}
		when ODIN_DEBUG {
			if vyper_trace {
				fmt.printf("[bg] segment %d/%d done: %d frames -> %.1f%%\n", k + 1, seg_total, count, frac * 100)
			}
		}
	}

	// Stamp the index even when every segment was reused (no encode ran): the
	// per-segment store above only fires for freshly encoded segments, and a
	// reused-only window would otherwise leave the on-disk idx with whatever
	// PROXY_ENCODER_VERSION (or pre-stamp version, 0) built it. proxy_segments_complete
	// rejects a version mismatch, so a re-import would rebuild forever. This
	// store also re-publishes reused segments that were previously enrolled in
	// a cancelled window.
	proxy_idx_store(src, &idx)

	import_bg_set_phase(ib, .Verifying)
	phase: Build_Phase = .Done_Ok
	// Window-relative completion: a mid-source window must cover ITS window
	// (the whole source is only required when the window is the whole source --
	// that's what proxy_segments_complete checks for re-imports). Frames from
	// segments outside the window are already on disk and seeded in idx; only
	// the window's own frame budget is verified here.
	window_want: i64
	got: i64
	for k in lo ..< hi {
		seg_start := i64(k) * PROXY_SEG_FRAMES
		window_want += min(PROXY_SEG_FRAMES, max(frames - seg_start, 0))
		if k < len(idx.segs) {
			got += idx.segs[k]
		}
	}
	if got < window_want - PROXY_FRAME_TOLERANCE {
		phase = .Done_Fail
		import_bg_set_progress(ib, -1)
	}
	import_bg_finish(ib, phase)
	import_bg_clear_cancel(ib)
	when ODIN_DEBUG {
		if vyper_trace {
			fmt.printf("[bg] proxy %s -> %v (window [%d,%d), %d frames)\n", string(src), phase, lo, hi, got)
		}
	}
	// Record the covered window so the scheduler can extend from this frontier
	// without re-requesting what's on disk. Worker writes, render thread reads
	// under the same mutex import_bg_status uses.
	import_bg_set_done_window(ib, phase == .Done_Ok, lo, hi)
}

import_bg_set_phase :: proc(ib: ^Proxy_Builder, phase: Build_Phase) {
	sync.mutex_lock(&ib.worker.mutex)
	ib.phase = phase
	sync.mutex_unlock(&ib.worker.mutex)
}

// import_bg_finish sets a terminal phase AND records it as last_result so the
// scheduler can suppress re-posting the same window after a cancel/fail.
// Caller must hold no mutex; the record carries the active window (the window
// the worker was actually building -- for a cancel that aborted a build, that's
// what got hit).
import_bg_finish :: proc(ib: ^Proxy_Builder, phase: Build_Phase) {
	sync.mutex_lock(&ib.worker.mutex)
	ib.phase = phase
	ib.last_result_phase = phase
	copy(ib.last_result_src[:], ib.active_src[:])
	ib.last_result_lo = ib.active_seg_lo
	ib.last_result_hi = ib.active_seg_hi
	sync.mutex_unlock(&ib.worker.mutex)
}

import_bg_set_progress :: proc(ib: ^Proxy_Builder, frac: f64) {
	sync.mutex_lock(&ib.worker.mutex)
	ib.progress = frac
	sync.mutex_unlock(&ib.worker.mutex)
}

import_bg_clear_cancel :: proc(ib: ^Proxy_Builder) {
	sync.mutex_lock(&ib.worker.mutex)
	ib.cancel_pending = false
	sync.mutex_unlock(&ib.worker.mutex)
}
