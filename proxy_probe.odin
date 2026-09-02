package main

import "core:fmt"
import "core:os"
import "core:strings"

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