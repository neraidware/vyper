package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// VYPER_PROXY_SCHED_TEST="<file>": headless regression for the on-demand proxy
// scheduler (proxy.odin proxy_build_schedule) driving the background builder
// exactly like the GUI frame loop does -- import_bg_consume_done then
// proxy_build_schedule each tick -- with the margin shrunk to ~2s so a 120s
// source exercises windowed builds, far-jump redefine, and cancel suppression
// without encoding hours of footage.
//
// Script (med120 = 3600 frames / 120s / 4 segments @ PROXY_SEG_FRAMES):
//   S1  playhead 0      -> initial window [0,1)            -> Done_Ok
//   S2  playhead 901    -> frontier extension [1,2)        -> Building (don't wait)
//   S3  playhead 2700   -> far jump past the in-flight [1,2)
//                         -> REDEFINE [3,4); worker aborts the stale build
//   S4  cancel during that build -> Done_Cancelled; scheduler must NOT re-post
//                         [3,4) while the playhead sits on it (suppression)
//   S5  playhead 1800   -> back inside the [1,3) gap -> suppression lifted,
//                         request [2,3) -> Done_Ok; verify on-disk coverage
//                         = segments {0,1,2}, segment 3 absent
// ---------------------------------------------------------------------------

sched_probe_fail := false

sched_probe_check :: proc(cond: bool, msg: string, args: ..any) {
	if !cond {
		sched_probe_fail = true
		fmt.println("[sched-probe] FAIL", fmt.tprintf(msg, ..args))
	}
}

// sched_frame runs one GUI frame's worth of the proxy pipeline: consume any
// finished job, then let the scheduler look at the playhead.
sched_frame :: proc() {
	import_bg_consume_done()
	proxy_build_schedule()
}

// sched_pump advances the worker for up to deadline, running one scheduler
// frame per tick so the request/consume lifecycle behaves like the live app.
sched_wait_done :: proc(what: string) -> bool {
	deadline := sdl.GetTicksNS() + 120_000_000_000
	for sdl.GetTicksNS() < deadline {
		sched_frame()
		_, _, phase, _ := import_bg_status()
		if phase == .Done_Ok {
			return true
		}
		if phase == .Done_Cancelled || phase == .Done_Fail {
			fmt.printf("[sched-probe] %s ended %v unexpectedly\n", what, phase)
			return false
		}
		time.sleep(20 * time.Millisecond)
	}
	fmt.printf("[sched-probe] %s timed out\n", what)
	return false
}



sched_window_done :: proc() -> (src: cstring, lo, hi: int, ok: bool) {
	_, _, _, _, _, _, _, _, src, lo, hi, ok, _, _, _, _ = import_bg_window()
	return
}

// sched_window_req returns just the pending-request snapshot.
sched_window_req :: proc() -> (src: cstring, lo, hi: int, has_req: bool) {
	src, lo, hi, has_req, _, _, _, _, _, _, _, _, _, _, _, _ = import_bg_window()
	return
}

// sched_window_building_win returns whether the worker is actively building for
// this source in exactly [want_lo, want_hi).
sched_building_win :: proc(want_lo, want_hi: int) -> bool {
	_, _, _, _, a_src, a_lo, a_hi, building, _, _, _, _, _, _, _, _ := import_bg_window()
	return building && a_lo == want_lo && a_hi == want_hi
}

// sched_wait_building waits until the worker is actively building [lo, hi).
sched_wait_building :: proc(want_lo, want_hi: int, what: string) -> bool {
	deadline := sdl.GetTicksNS() + 30_000_000_000
	for sdl.GetTicksNS() < deadline {
		if sched_building_win(want_lo, want_hi) {
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	fmt.printf("[sched-probe] %s never building [%d,%d)\n", what, want_lo, want_hi)
	return false
}

// proxy_sched_probe_run is the probe entry: it owns the builder lifecycle
// explicitly (no defer -- os.exit diverges, which the defer checker rejects).
proxy_sched_probe_run :: proc(v: string) {
	import_bg_init()
	ok := proxy_sched_scenario(v)
	import_bg_shutdown()
	if !ok {
		fmt.println("[sched-probe] FAILED")
		os.exit(1)
	}
	fmt.println("[sched-probe] all checks passed")
	os.exit(0)
}

proxy_sched_scenario :: proc(v: string) -> bool {
	file := v

	preview_proxy_enabled = true
	async_import_mode = true
	// 2s margin -> seg_margin 1: every wanted window is the playhead's segment
	// plus one, keeping each build cheap and all transitions visible.
	proxy_sched_margin_seconds = 2

	// Full import (bin + timeline) like the GUI. No proxy work happens at
	// import under async_import_mode; the scheduler below drives everything.
	import_media(cstring(raw_data(file)))

	asset := &media_assets[len(media_assets) - 1]
	if asset == nil || asset.frame_count <= 0 || asset.dur_us <= 0 {
		fmt.println("[sched-probe] FAIL: imported asset missing duration/frames")
		return false
	}
	seg_total := proxy_seg_count(asset.frame_count)
	if seg_total < 4 {
		fmt.printf("[sched-probe] need >= 4 segments for the script, got %d\n", seg_total)
		return false
	}
	path_len := len(string(asset.path))
	if path_len >= 4096 {
		fmt.println("[sched-probe] FAIL: asset path too long")
		return false
	}
	src_buf: [4096]u8
	copy(src_buf[:], string(asset.path))
	src := cstring(&src_buf[0])

	// S1: head request.
	playhead.frame = 0
	sched_frame()
	r_src, r_lo, r_hi, has_req := sched_window_req()
	sched_probe_check(has_req, "S1: no request posted for playhead 0")
	if has_req {
		sched_probe_check(
			strings.compare(string(r_src), string(src)) == 0 && r_lo == 0 && r_hi == 1,
			"S1: expected [0,1) for %q, got [%d,%d)",
			string(r_src),
			r_lo,
			r_hi,
		)
	}
	sched_probe_check(sched_wait_done("S1 build [0,1)"), "S1 build failed")
	_, d_lo, d_hi, d_ok := sched_window_done()
	sched_probe_check(d_ok && d_lo == 0 && d_hi == 1, "S1: done window [0,1), got [%d,%d) ok=%v", d_lo, d_hi, d_ok)
	fmt.println("[sched-probe] S1 ok: initial window built")

	// S2: frontier extension to [1,2) -- verify the tick posts it, then let the
	// worker grab it and go busy (we abort it in S3 mid-flight).
	playhead.frame = 901
	sched_frame()
	r_src, _, r_hi, has_req = sched_window_req()
	sched_probe_check(
		has_req && strings.compare(string(r_src), string(src)) == 0 && r_hi == 2,
		"S2: expected an extend to hi=2, got hi=%d",
		r_hi,
	)
	sched_probe_check(sched_wait_building(1, 2, "S2 busy"), "S2 never went busy")
	fmt.println("[sched-probe] S2 ok: frontier extension queued and building [1,2)")

	// S3: far jump past the in-flight window. The active build is [1,2), the
	// playhead now wants [3,4) -- that is a redefine (abort now, build here).
	// The retarget posts a request; the worker must end up ACTIVELY building
	// [3,4) (the stale [1,2) build gets abandoned).
	playhead.frame = 2700
	sched_frame()
	r_src, _, r_hi, has_req = sched_window_req()
	sched_probe_check(
		has_req && strings.compare(string(r_src), string(src)) == 0 && r_hi == 4,
		"S3: expected retarget to hi=4, got hi=%d",
		r_hi,
	)
	sched_probe_check(sched_wait_building(3, 4, "S3 retarget"), "S3 never started [3,4)")
	fmt.println("[sched-probe] S3 ok: far jump aborted [1,2) and started [3,4)")

	// S3b: cancel while [3,4) is building; expect Done_Cancelled, not Done_Ok.
	import_bg_cancel()
	if sched_wait_done("S3b cancelled build") {
		sched_probe_check(false, "S3b: cancel should NOT finish ok")
	}
	fmt.println("[sched-probe] S3b ok: in-flight build cancelled after redefine")

	// S4: suppression -- same playhead, same wanted window [3,4); the scheduler
	// must NOT re-post it while the playhead sits on it (cancel would be a
	// no-op otherwise). Drive several ticks and assert nothing is requested.
	playhead.frame = 2700
	for i in 0 ..< 20 {
		sched_frame()
		_, _, _, has_req = sched_window_req()
		sched_probe_check(!has_req, "S4: re-posted the cancelled window on tick %d", i)
		time.sleep(10 * time.Millisecond)
	}
	fmt.println("[sched-probe] S4 ok: cancelled window suppressed")

	// S5: playhead into the [1,3) gap (segment 2). wanted [2,3) differs from
	// the cancelled [3,4) -> suppression lifts, request resumes, build completes.
	playhead.frame = 1800
	sched_frame()
	r_src, r_lo, r_hi, has_req = sched_window_req()
	sched_probe_check(
		has_req && strings.compare(string(r_src), string(src)) == 0 && r_lo == 2 && r_hi == 3,
		"S5: expected [2,3), got [%d,%d)",
		r_lo,
		r_hi,
	)
	sched_probe_check(sched_wait_done("S5 build [2,3)"), "S5 build failed")
	_, d_lo, d_hi, d_ok = sched_window_done()
	sched_probe_check(d_ok && d_lo == 2 && d_hi == 3, "S5: done window [2,3), got [%d,%d) ok=%v", d_lo, d_hi, d_ok)
	fmt.println("[sched-probe] S5 ok: gap window built after suppression lifted")

	// On-disk final state: segments 0,1,2 present and listed, segment 3 absent
	// (its build was cancelled mid-flight) -> NOT a complete proxy.
	idx: Proxy_Idx
	has_idx := proxy_idx_load(src, &idx)
	total: i64
	for c in idx.segs {
		total += c
	}
	frames_covered: i64 = 2700  // segments 0..2 -> 900*3; segment 3 build was cancelled
	sched_probe_check(has_idx && total >= frames_covered - PROXY_FRAME_TOLERANCE,
		"S6: expected ~%d frames on disk, got %d",
		frames_covered,
		total)
	sched_seg_present := proc(s: cstring, k: int) -> bool {
		sb: [4096]u8
		p, _ := proxy_segment_path_for(s, k, sb[:])
		return p != nil && os.exists(string(p))
	}
	sched_probe_check(sched_seg_present(src, 0) && sched_seg_present(src, 1) && sched_seg_present(src, 2),
		"S6: segments 0..2 should exist on disk")
	sched_probe_check(!sched_seg_present(src, 3), "S6: cancelled segment 3 must not exist")
	sched_probe_check(!proxy_segments_complete(src, asset.frame_count),
		"S6: a gap proxy must NOT read as complete")
	fmt.println("[sched-probe] S6 ok: on-disk coverage matches the script (0-2 kept, 3 absent)")

	delete(idx.segs)
	proxy_cleanup_artifacts(src)
	return !sched_probe_fail
}