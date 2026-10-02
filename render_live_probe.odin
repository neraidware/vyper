package main

// ---------------------------------------------------------------------------
// VYPER_RENDER_LIVE_PROBE=1 — the live-preview handoff (Active 11 S5).
//
// The composed-frame mailbox is the one place where the export's worker thread
// and the UI thread touch the same bytes. Everything else about S5 is a GPU
// upload, and a GPU upload cannot be checked headlessly — but the handoff can,
// and the handoff is where a mistake is a data race rather than a wrong pixel.
//
// What is pinned here:
//   1. A published frame is the frame that was published: same bytes, same
//      timeline frame. A take that returned the previous frame, or a frame from
//      the wrong slot, would show plausible pixels from the wrong moment.
//   2. DROP, the named overflow policy: publishing while the UI has not drained
//      must leave the undrained frame intact, not overwrite it. Overwriting
//      would be a silent stall in the UI thread's view of the export (and the
//      stall would look like the export hanging).
//   3. The mailbox does not start publishing until the UI has drawn one frame
//      (the usability gate in render_live_publish).
//   4. The publish interval: two publishes inside RENDER_LIVE_PUBLISH_NS keep
//      only the first, so the compositor is not paying a full-canvas conversion
//      per frame for pixels nobody sees at that rate.
//
// Case 5 (below) covers the NV12 conversion itself, through the same swscale
// call render_live_publish makes -- not a copy of the layout, but the layout the
// export really ships: two planes, chroma at w*h with a row pitch of w.
// ---------------------------------------------------------------------------

import "core:c"
import "core:fmt"
import "core:os"
import "base:runtime"
import "core:time"
import "core:math"
import avutil "vendor/ffmpeg/avutil"
import sws "vendor/ffmpeg/swscale"
import "core:sync"

render_live_probe_fail := false

render_live_probe_check :: proc(cond: bool, msg: string) {
	if !cond {
		render_live_probe_fail = true
		fmt.println("[render-live-probe] FAIL:", msg)
	}
}

RENDER_LIVE_PROBE_W :: 16
RENDER_LIVE_PROBE_H :: 8

// probe_pattern fills a frame with a value that identifies the frame, so a take
// returning the wrong one is unambiguous rather than "close enough".
probe_pattern :: proc(dst: []u8, frame: i64) {
	for i in 0 ..< len(dst) {
		dst[i] = u8(frame + i64(i))
	}
}

render_live_probe_run :: proc() -> int {
	// Free anything a previous run left; the probe owns the buffer here the same
	// way the app does at shutdown.
	render_live_teardown()

	// The probe consumes mailbox frames directly, so it plays the UI's part.
	shown_before := sync.atomic_load(&render_live.shown)

	render_live_begin(RENDER_LIVE_PROBE_W, RENDER_LIVE_PROBE_H)
	render_live_probe_check(
		len(render_live.buf) == RENDER_LIVE_PROBE_W * RENDER_LIVE_PROBE_H * 4,
		"begin must size the mailbox to the job canvas",
	)

	// `drained` is the consumer's own buffer, the same role the GPU transfer
	// buffer plays in draw_live_preview: the mailbox is copied OUT, never read in
	// place, because the claim is released as the copy finishes.
	src_a: [RENDER_LIVE_PROBE_W * RENDER_LIVE_PROBE_H * 4]u8
	drained: [RENDER_LIVE_PROBE_W * RENDER_LIVE_PROBE_H * 4]u8

	// 3. Nothing is published before the UI has drawn a frame.
	probe_pattern(src_a[:], 100)
	render_live_publish(src_a[:], nil, 100)
	frame, w, h, ok := render_live_drain(drained[:])
	render_live_probe_check(!ok, "nothing may be published before the UI has drawn a frame")

	// From here the probe stands in for the UI thread: it has drawn.
	sync.atomic_store(&render_live.shown, true)
	render_live_probe_check(
		sync.atomic_load(&render_live.shown) && !shown_before,
		"the consumer's shown flag must be visible to the publisher",
	)

	// 1. A published frame comes back intact.
	render_live_publish(src_a[:], nil, 100)
	frame, w, h, ok = render_live_drain(drained[:])
	render_live_probe_check(ok, "the published frame must be drainable")
	render_live_probe_check(frame == 100, "drain returned the wrong timeline frame")
	render_live_probe_check(
		w == RENDER_LIVE_PROBE_W && h == RENDER_LIVE_PROBE_H,
		"drain must report the job canvas size",
	)
	all_match := true
	for i in 0 ..< len(drained) {
		if drained[i] != src_a[i] {
			all_match = false
			break
		}
	}
	render_live_probe_check(all_match, "the drained bytes are not the published frame")

	// An empty mailbox after a drain: the claim is what makes it single-consumer.
	_, _, _, ok = render_live_drain(drained[:])
	render_live_probe_check(!ok, "a drained mailbox must not hand out the same frame twice")

	// 2. DROP. Publish A, then publish B without taking. B must be dropped and
	// A must survive whole — the UI keeps showing a complete older frame instead
	// of a torn one, and the compositor keeps encoding instead of waiting.
	src_b: [RENDER_LIVE_PROBE_W * RENDER_LIVE_PROBE_H * 4]u8
	probe_pattern(src_b[:], 200)
	// Clear the interval before EACH publish: the drop policy and the publish
	// interval can both refuse a frame, and if the interval is what refuses it
	// then this assertion passes with the drop check deleted.
	render_live.last_ns = 0
	render_live_publish(src_a[:], nil, 100)
	render_live.last_ns = 0
	render_live_publish(src_b[:], nil, 200)
	frame, _, _, ok = render_live_drain(drained[:])
	render_live_probe_check(ok, "the first of two undrained publishes must still be there")
	render_live_probe_check(
		frame == 100,
		"an undrained mailbox must DROP the newer frame, not be overwritten by it",
	)

	// 4. The publish interval, once the mailbox is free again.
	render_live.last_ns = 0
	render_live_publish(src_b[:], nil, 200)
	frame, _, _, ok = render_live_drain(drained[:])
	render_live_probe_check(
		ok && frame == 200,
		"a drained mailbox must accept the next frame",
	)
	// The window runs from the last ACCEPTED publish, not the last attempt, so a
	// burst of skipped attempts does not push the next real frame further out.
	render_live_publish(src_b[:], nil, 300)
	_, _, _, ok = render_live_drain(drained[:])
	render_live_probe_check(!ok, "a publish inside RENDER_LIVE_PUBLISH_NS must be skipped")
	render_live_publish(src_b[:], nil, 350)
	_, _, _, ok = render_live_drain(drained[:])
	render_live_probe_check(!ok, "a skipped publish must not restart the window")
	// One nanosecond past the window, pinned rather than slept on so the gate is
	// exact instead of racing the clock.
	render_live.last_ns = time.now()._nsec - i64(RENDER_LIVE_PUBLISH_NS) - 1
	render_live_publish(src_b[:], nil, 400)
	frame, _, _, ok = render_live_drain(drained[:])
	render_live_probe_check(
		ok && frame == 400,
		"a publish after the interval must land",
	)

	// A run that ends closes the mailbox without freeing the buffer, so the next
	// run reuses it.
	render_live_end()
	render_live_probe_check(
		render_live.buf != nil && len(render_live.buf) == RENDER_LIVE_PROBE_W * RENDER_LIVE_PROBE_H * 4,
		"ending a run must keep the session buffer for the next one",
	)
	render_live_probe_check(
		!sync.atomic_load(&render_live.ready),
		"ending a run must close the mailbox",
	)
	// A resize at the same dimensions must NOT reallocate: the reuse is the
	// point of checking the size first.
	render_live_begin(RENDER_LIVE_PROBE_W, RENDER_LIVE_PROBE_H)
	render_live_probe_check(
		render_live.buf != nil && render_live.w == RENDER_LIVE_PROBE_W,
		"re-sizing to the same canvas must leave the buffer usable",
	)

	render_live_teardown()
	render_live_probe_check(render_live.buf == nil, "teardown must free the session buffer")

	render_live_probe_nv12()

	if render_live_probe_fail {
		fmt.println("[render-live-probe] failed")
		return 1
	}
	fmt.println("[render-live-probe] ok")
	return 0
}

// 5. The NV12 -> RGBA conversion the GPU export publishes through.
//
// This is the case that cannot be faked with the RGB copy path: the plane count
// and the chroma row pitch are both part of the ABI, and a wrong answer is a
// segfault (one source plane) or wrong colour (half-width chroma pitch). Two
// frames, so the assertions can tell "read something" from "read the right
// thing":
//
//	NEUTRAL: a luma ramp with U=V=128, which swscale must return as a grey ramp
//	         of the same brightness. Pins the luma plane and the slice height.
//	COLOURED: extreme U,V written ONLY into the LAST row of the chroma plane at
//	         offset w*h. If the chroma plane is found at the right offset and
//	         read at the right pitch, only the BOTTOM of the output is
//	         red-dominant. The last row specifically, because swscale
//	         interpolates chroma vertically: a coloured row in the middle
//	         bleeds greyness upwards and the grey assertion would fail for a
//	         reason that has nothing to do with the plane layout.
//	         Reading chroma from offset 0 (the luma plane) tints the top;
//	         reading it at half pitch misses the bottom.
render_live_probe_nv12 :: proc() {
	NV12_PROBE_W :: 64
	NV12_PROBE_H :: 32
	w, h: c.int = NV12_PROBE_W, NV12_PROBE_H

	ctx := sws.getContext(
		w,
		h,
		avutil.PixelFormat.NV12,
		w,
		h,
		avutil.PixelFormat.RGBA,
		sws.Flags{.Bilinear},
		nil,
		nil,
		nil,
	)
	if ctx == nil {
		render_live_probe_check(false, "NV12->RGBA context could not be created")
		return
	}
	defer sws.freeContext(ctx)

	luma := int(w) * int(h)
	nv12 := make([]u8, luma + luma / 2)
	defer delete(nv12)
	for y in 0 ..< int(h) {
		// 16..240 keeps the ramp inside swscale's reproducible range, and off
		// the ends where limited-range vs full-range would disagree.
		luma_val := u8(16 + (y * 224) / (int(h) - 1))
		for x in 0 ..< int(w) {
			nv12[y * int(w) + x] = luma_val
		}
	}
	uv_plane := nv12[luma:]
	for i in 0 ..< len(uv_plane) {
		uv_plane[i] = 128 // neutral chroma
	}
	uv_rows := len(uv_plane) / int(w)
	last_uv_row := (uv_rows - 1) * int(w)
	// w/2 chroma samples per row, U and V byte-interleaved -- not w pairs.
	for i in 0 ..< int(w) / 2 {
		uv_plane[last_uv_row + i * 2 + 0] = 16  // U low  -> red
		uv_plane[last_uv_row + i * 2 + 1] = 240 // V high -> red
	}

	rgba := make([]u8, luma * 4)
	defer delete(rgba)
	src: [2][^]u8 = {raw_data(nv12), raw_data(uv_plane)}
	src_ls: [4]c.int = {w, w, 0, 0}
	dst: [1][^]u8 = {raw_data(rgba)}
	dst_ls: [4]c.int = {w * 4, 0, 0, 0}
	scaled := sws.scale(
		ctx,
		cast([^][^]u8)&src,
		cast([^]c.int)&src_ls,
		0,
		h,
		cast([^][^]u8)&dst,
		cast([^]c.int)&dst_ls,
	)
	render_live_probe_check(scaled == c.int(h), "NV12->RGBA must scale every row")

	top_r, top_g, top_b := probe_chan(rgba, int(w), 4, 2, 0), probe_chan(rgba, int(w), 4, 2, 1), probe_chan(rgba, int(w), 4, 2, 2)
	render_live_probe_check(
		abs(top_r - top_g) <= 3 && abs(top_g - top_b) <= 3,
		"neutral chroma must convert to grey (plane 0 is luma only)",
	)
	render_live_probe_check(
		probe_chan(rgba, int(w), 4, int(h) - 3, 0) > top_r + 40,
		"the luma ramp must survive the conversion top-to-bottom",
	)

	// The chroma written into the LAST chroma plane row must be what the bottom
	// of the output reads -- and nothing above it may be coloured.
	// The LAST output row, not the second-to-last: chroma is interpolated
	// vertically, so the row that samples the coloured chroma row most directly
	// is the last one. Measured (w=64,h=32, Y=16..240, U/V coloured in chroma
	// row 15): rows 0-28 come back as an exact grey ramp and rows 29-31 as
	// 255/231/186, 255/215/81, 255/212/33 -- the tint strengthens toward the
	// coloured row, which is the signature of a correct bilinear chroma read.
	bot_r, bot_g, bot_b := probe_chan(rgba, int(w), 4, int(h) - 1, 0), probe_chan(rgba, int(w), 4, int(h) - 1, 1), probe_chan(rgba, int(w), 4, int(h) - 1, 2)
	render_live_probe_check(
		bot_r > bot_b + 40 && bot_r > bot_g + 40,
		"the last chroma plane row must tint the bottom of the output",
	)
	render_live_probe_check(
		probe_chan(rgba, int(w), 4, int(h) / 2 - 2, 0) <= probe_chan(rgba, int(w), 4, int(h) / 2 - 2, 2) + 40,
		"an untouched chroma plane row must NOT tint the top of the output",
	)
}

// probe_chan reads one RGBA channel at (x, y). Named rather than a closure:
// Odin's proc literals do not capture here, and an explicit w is one argument
// less clever than a capture.
probe_chan :: proc(buf: []u8, w, x, y, ch: int) -> i32 {
	return i32(buf[(y * w + x) * 4 + ch])
}

render_live_probe_env :: proc() -> bool {
	v, ok := os.lookup_env_alloc("VYPER_RENDER_LIVE_PROBE", context.temp_allocator)
	return ok && v == "1"
}