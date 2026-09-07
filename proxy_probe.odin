package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

// Large probe buffers live at package scope to avoid stack pressure.
gts, pxs: [3][PREVIEW_W * PREVIEW_H * 4]u8

// ---------------------------------------------------------------------------
// NERED_PROXY_PROBE="<file>": verify the editing-time proxy pipeline end to end.
//
// The regular probes run with preview_proxy_enabled=false so they exercise the
// ORIGINAL decode path (proxy pixels are lossy by design). This probe flips the
// flag back on exactly like the live editor, then checks:
//   1. import_media builds a frame-suffcient proxy on disk;
//   2. proxy_pick resolves it for a live slot;
//   3. decoding through the proxy yields real pixels that approximate the
//      source's content (frame-index mapping + not garbage), at the index that
//      would be requested by a scrub;
//   4. the proxy is cleaned up afterwards so the test never leaves artifacts.
// ---------------------------------------------------------------------------

proxy_probe_run :: proc(v: string) {
	preview_proxy_enabled = true
	// The proxy-probe asserts the proxy exists on disk right after import_media
	// returns, so it needs the historical SYNCHRONOUS build, not the background
	// worker (which would still be transcoding at that point).
	async_import_mode = false
	parts := strings.split(v, "|")
	if len(parts) < 1 {
		fmt.println("proxy-probe: need NERED_PROXY_PROBE=\"<file>\"")
		os.exit(2)
	}
	file := parts[0]
	inp: [4096]u8
	n := 0
	for n < len(file) && n < len(inp) - 1 {
		inp[n] = u8(file[n])
		n += 1
	}
	inp[n] = 0
	path := cstring(&inp[0])

	import_media(path)
	frame_count := media_frame_count(probe_media(path))
	src_w, src_h, _ := probe_video_size(path)

	// 1. Proxy exists on disk.
	pbuf: [4096]u8
	proxy, got_proxy := proxy_path_for(path, pbuf[:])
	if !got_proxy {
		fmt.println("[proxy-probe] FAIL: no proxy path derived")
		os.exit(1)
	}
	if !os.exists(string(proxy)) {
		fmt.println("[proxy-probe] FAIL: import did not create proxy at", string(proxy))
		os.exit(1)
	}

	// 2. proxy_pick resolves it (frame-suffcient check passes).
	picked := proxy_pick(path, frame_count, pbuf[:])
	if picked == nil {
		fmt.println("[proxy-probe] FAIL: proxy_pick rejected the built proxy")
		os.exit(1)
	}

	// 3. Decode probe-style indices through the proxy and compare to the source.
	// Probe three scrub indices: head, middle, and the last frame the source
	// reliably decodes (a couple before the estimated count, since the
	// duration*fps estimate can overshoot the real end-of-stream on odd files).
	f1 := frame_count - 3
	scrub_frames := []i64{0, f1 / 2, f1}
	for i in 0 ..< 3 {
		fi := scrub_frames[i]
		gt: Clip_Decoder
		defer clip_decoder_reset(&gt)
		if !decode_clip_frame_sync(&gt, path, fi, gts[i][:]) {
			fmt.printf("[proxy-probe] FAIL: source decode of frame %d failed\n", fi)
			os.exit(1)
		}
		px: Clip_Decoder
		defer clip_decoder_reset(&px)
		decoder_set_preview_path(&px, proxy)
		if !decode_clip_frame_sync(&px, path, fi, pxs[i][:]) {
			fmt.printf("[proxy-probe] FAIL: proxy decode of frame %d failed\n", fi)
			os.exit(1)
		}
		// Content sanity: the proxy frame must not be blank/garbage, and must
		// approximate the source frame (lossy, so tolerate per-channel error).
		mean_abs, max_abs := buffer_diff_metrics(gts[i][:], pxs[i][:])
		mean_src := buffer_mean(gts[i][:])
		if mean_src < 1.0 {
			fmt.printf("[proxy-probe] FAIL: source frame %d is blank (mean=%.1f)\n", fi, mean_src)
			os.exit(1)
		}
		if mean_abs > 40.0 || max_abs > 255.0 {
			fmt.printf("[proxy-probe] FAIL: frame %d proxy differs too much from source (mean_abs=%.1f max_abs=%d src_mean=%.1f)\n",
				fi, mean_abs, int(max_abs), mean_src)
			os.exit(1)
		}
		fmt.printf("[proxy-probe] frame %d src_mean=%.1f proxy_mean=%.1f mean_abs=%.1f max_abs=%d\n",
			fi, mean_src, buffer_mean(pxs[i][:]), mean_abs, int(max_abs))
	}

	// 4. Cleanup artifact.
	os.remove(string(proxy))
	fmt.println("[proxy-probe] OK: proxy transcoded, picked, decoded, matches source content")
	os.exit(0)
}

// ---------------------------------------------------------------------------
// NERED_PROXY_BG_TEST="<file>[|<cancel_pct>]": exercise the BACKGROUND proxy
// builder (import_bg.odin) without a window.
//
// Imports `file` with async_import_mode=true like the live editor, then polls
// the worker until it either:
//   - verifies a valid proxy (Done_Ok) -> exit 0; or
//   - with <cancel_pct> given (e.g. "30"): issues import_bg_cancel once the
//     reported progress crosses that percent and expects Done_Cancelled with the
//     partial proxy removed -> exit 0.
// Anything else (Done_Fail, timeout, spawn/progress oddity) exits 1.
// ---------------------------------------------------------------------------
proxy_bg_probe_run :: proc(v: string) {
	import_bg_init()
	defer import_bg_shutdown()

	preview_proxy_enabled = true
	async_import_mode = true

	parts := strings.split(v, "|")
	if len(parts) < 1 {
		fmt.println("proxy-bg-test: need NERED_PROXY_BG_TEST=\"<file>[|<cancel_pct>]\"")
		os.exit(2)
	}
	file := parts[0]
	cancel_pct: f64 = -1
	if len(parts) > 1 {
		cancel_pct, _ = strconv.parse_f64(parts[1])
	}

	inp: [4096]u8
	n := 0
	for n < len(file) && n < len(inp) - 1 {
		inp[n] = file[n]
		n += 1
	}
	inp[n] = 0
	path := cstring(&inp[0])

	// Full import: bin + timeline, mirroring the GUI's Open File flow. The
	// proxy build must NOT block this call.
	import_media(path)

	deadline := sdl.GetTicksNS() + 300_000_000_000
	last_report := sdl.GetTicksNS()
	cancel_sent := false
	reported: int = -1
	for {
		active, frac, phase, src := import_bg_status()
		now := sdl.GetTicksNS()

		pct := int(frac * 100)
		if frac >= 0 && pct != reported && now - last_report > 200_000_000 {
			fmt.printf("[proxy-bg-test] progress=%d%% phase=%v\n", pct, phase)
			reported = pct
			last_report = now
		}

		if !cancel_sent && cancel_pct >= 0 && frac >= cancel_pct / 100.0 && phase == .Building {
			fmt.printf("[proxy-bg-test] sending cancel at %d%%\n", pct)
			import_bg_cancel()
			cancel_sent = true
		}

		switch phase {
		case .Done_Ok:
			if nered_trace {
				fmt.printf("[proxy-bg-test] worker finished, verifying on-disk artifact\n")
			}
			pbuf: [4096]u8
			proxy, got := proxy_path_for(path, pbuf[:])
			if !got || !os.exists(string(proxy)) {
				fmt.println("[proxy-bg-test] FAIL: Done_Ok but proxy missing")
				os.exit(1)
			}
			if !proxy_valid_cache_hit(proxy, media_frame_count(file_info_text)) {
				fmt.println("[proxy-bg-test] FAIL: Done_Ok but parity check rejects proxy")
				os.exit(1)
			}
			os.remove(string(proxy))
			fmt.println("[proxy-bg-test] OK: async proxy built and verified")
			os.exit(0)

		case .Done_Cancelled:
			if !cancel_sent {
				fmt.println("[proxy-bg-test] FAIL: done-cancelled without a cancel request")
				os.exit(1)
			}
			pbuf: [4096]u8
			proxy, got := proxy_path_for(path, pbuf[:])
			if got && os.exists(string(proxy)) {
				fmt.println("[proxy-bg-test] FAIL: cancelled but partial proxy left on disk")
				os.exit(1)
			}
			fmt.println("[proxy-bg-test] OK: cancelled, partial proxy cleaned up")
			os.exit(0)

		case .Done_Fail:
			fmt.println("[proxy-bg-test] FAIL: proxy build errored")
			os.exit(1)

		case .Building, .Verifying, .Idle:
		}

		if now > deadline {
			fmt.println("[proxy-bg-test] FAIL: timed out waiting for the background build")
			os.exit(1)
		}
		time.sleep(50 * time.Millisecond)
	}
}

// buffer_diff_metrics computes mean and max |gt - px| per channel (RGBA packed).
buffer_diff_metrics :: proc(gt, px: []u8) -> (mean_abs, max_abs: f64) {
	if len(gt) == 0 || len(gt) != len(px) {
		return 255, 255
	}
	sum: f64
	for i in 0 ..< len(gt) {
		b := f64(px[i])
		a := f64(gt[i])
		d := b - a
		if d < 0 {
			d = -d
		}
		sum += d
		if d > max_abs {
			max_abs = d
		}
	}
	return sum / f64(len(gt)), max_abs
}

// buffer_mean returns the average byte value of a packed RGBA buffer.
buffer_mean :: proc(buf: []u8) -> f64 {
	if len(buf) == 0 {
		return 0
	}
	sum: f64
	for i in 0 ..< len(buf) {
		sum += f64(buf[i])
	}
	return sum / f64(len(buf))
}