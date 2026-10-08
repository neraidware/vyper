package vyper

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	// Large probe buffers live at package scope to avoid stack pressure.
	gts, pxs: [3][PREVIEW_W * PREVIEW_H * 4]u8

	// ---------------------------------------------------------------------------
	// VYPER_PROXY_PROBE="<file>": verify the editing-time proxy pipeline end to end.
	//
	// The regular probes run with editor_flags.preview_proxy_enabled=false so they exercise the
	// ORIGINAL decode path (proxy pixels are lossy by design). This probe flips the
	// flag back on exactly like the live editor, then checks:
	//   1. import_media builds a frame-suffcient proxy on disk;
	//   2. proxy_pick_for_frame resolves it for a live slot;
	//   3. decoding through the proxy yields real pixels that approximate the
	//      source's content (frame-index mapping + not garbage), at the index that
	//      would be requested by a scrub;
	//   4. the proxy is cleaned up afterwards so the test never leaves artifacts.
	// ---------------------------------------------------------------------------

	proxy_probe_run :: proc(v: string) {
		editor_flags.preview_proxy_enabled = true
		// The proxy-probe asserts the proxy exists on disk right after import_media
		// returns, so it needs the historical SYNCHRONOUS build, not the background
		// worker (which would still be transcoding at that point).
		editor_flags.async_import_mode = false
		parts := strings.split(v, "|")
		if len(parts) < 1 {
			fmt.println("proxy-probe: need VYPER_PROXY_PROBE=\"<file>\"")
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

		// 1b. The artifact is the size the scale rule asked for. Everything else
		// here compares proxy pixels to source pixels within a lossy tolerance,
		// which a proxy that is merely the WRONG SIZE would still pass: decoded
		// into the same preview buffer, 768x432 and 960x540 are the same
		// rectangle of slightly different sharpness. Asserting the encoded
		// dimensions is the only place the scale rule itself is observable, and a
		// silent fallback to the old cap is exactly the regression worth catching.
		sw, sh, sok := probe_video_size(proxy)
		if !sok {
			fmt.println("[proxy-probe] FAIL: could not read the proxy's video dimensions")
			os.exit(1)
		}
		// Printed unconditionally, on every path, because a failing probe exits via
		// os.exit and never reaches this file's cleanup at the end -- and a leftover
		// artifact is not inert. It sits in the cache under a key derived from the
		// CURRENT settings, so the next run finds it, believes it is a valid hit,
		// and asserts against the previous run's broken proxy instead of building a
		// fresh one. The gate target greps this line out of the log and removes the
		// file whether the probe passed or failed, so one bad run cannot poison the
		// next.
		fmt.printf("[proxy-probe] artifact-path: %s\n", string(proxy))
		src_w, src_h, srcok := probe_video_size(path)
		if !srcok {
			fmt.println("[proxy-probe] FAIL: could not read the source's video dimensions")
			os.exit(1)
		}
		// The expectation is computed HERE, not by asking proxy_scale. Asking the
		// function under test what it ought to return makes the assertion agree
		// with whatever it does -- mutating proxy_scale back to the old 768x432 cap
		// passes this check, which is precisely the regression it exists to catch.
		// Spelling the rule out independently is the whole point: the proxy is half
		// the source, snapped down to even.
		half_w := src_w / 2
		half_h := src_h / 2
		want_w := half_w - half_w % 2
		want_h := half_h - half_h % 2
		if sw != want_w || sh != want_h {
			fmt.printf(
				"[proxy-probe] FAIL: proxy is %dx%d, expected half the source %dx%d -> %dx%d\n",
				sw, sh, src_w, src_h, want_w, want_h,
			)
			os.exit(1)
		}
		// And it must not be the old fixed cap. Redundant with the rule above for
		// a 1080p source (960 != 768), but stated directly because that cap is the
		// specific regression, and a future source size could make the two agree.
		if sw == 768 && sh == 432 {
			fmt.println("[proxy-probe] FAIL: proxy is the old fixed 768x432 cap, not scaled from the source")
			os.exit(1)
		}
		// A proxy must never exceed its source: upscaling costs file size and
		// decode time and adds no information.
		assert(sw <= src_w && sh <= src_h, "proxy must never be larger than the source it came from")
		fmt.printf("[proxy-probe] dims: %dx%d (source %dx%d)\n", sw, sh, src_w, src_h)

		// 2. proxy_pick_for_frame resolves frame 0 (whole proxy path, no .idx):
		// the legacy fast path runs the frame-suffcient check once and latches it.
		picked, _ := proxy_pick_for_frame(path, frame_count, 0, pbuf[:], false)
		if picked == nil {
			fmt.println("[proxy-probe] FAIL: proxy_pick_for_frame rejected the built proxy")
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

		// 4. Report the artifact size, then clean up. Size is the only place the
		//    encoder's rate control is observable: a proxy that comes out wildly
		//    larger than its duration justifies is a rate-control constant that
		//    needs retuning, and nothing else in the pipeline would show it.
		if fh, err := os.open(string(proxy)); err == nil {
			if size, size_err := os.file_size(fh); size_err == nil {
				fmt.printf("[proxy-probe] artifact: %d bytes\n", size)
			}
			os.close(fh)
		}
		os.remove(string(proxy))
		fmt.println("[proxy-probe] OK: proxy transcoded, picked, decoded, matches source content")
		flush_stdout() // os.exit does not flush; see flush_stdout.
		os.exit(0)
	}

	// ---------------------------------------------------------------------------
	// VYPER_PROXY_BG_TEST="<file>[|<cancel_pct>]": exercise the BACKGROUND proxy
	// proxy_bg_verify_complete asserts that a source's segments on disk fully cover
	// the source AND decode frame 0 + the last reachable frame with content that
	// matches the source (same lossy tolerance as proxy_probe_run). Used by the
	// background-proxy probe for both outcomes that leave a complete proxy behind:
	// a finished build, and an at-import cache hit (segments already on disk from a
	// prior session, so no build was ever enqueued).
	// ---------------------------------------------------------------------------
	proxy_bg_verify_complete :: proc(path: cstring, frame_count: i64, keep_cache: bool, ok_label: string) {
		// The head and tail frames must both resolve to a built segment (a
		// fully-built background proxy is the complete segment set -- there is no
		// whole-file artifact to check).
		pbuf0: [4096]u8
		pfirst, _ := proxy_pick_for_frame(path, frame_count, 0, pbuf0[:], false)
		plast_buf: [4096]u8
		plast, _ := proxy_pick_for_frame(path, frame_count, frame_count - 1, plast_buf[:], false)
		if pfirst == nil || plast == nil {
			fmt.println("[proxy-bg-test] FAIL: complete but frames not covered by segments")
			os.exit(1)
		}
		idx: Proxy_Idx
		if !proxy_idx_load(path, &idx) {
			fmt.println("[proxy-bg-test] FAIL: complete but no usable .idx")
			os.exit(1)
		}
		total: i64
		for c in idx.segs {
			total += c
		}
		if total < frame_count - PROXY_FRAME_TOLERANCE {
			fmt.printf("[proxy-bg-test] FAIL: segment frames %d < source %d\n", total, frame_count)
			os.exit(1)
		}
		// Light content check through the segments: decode frame 0 and the last
		// reachable frame via their picked files and compare to the source (lossy,
		// so tolerate per-channel error). The final frame is the most valuable
		// check -- a zero-duration last stts sample makes exactly it unaddressable
		// -- but the duration*fps estimate can overshoot the real end-of-stream on
		// exact-duration synthetic media (see proxy_probe_run's scrub test), in
		// which case the SOURCE also has no frame there. That is an estimator
		// artifact, not a proxy defect, so frame_count-1 is skipped when the source
		// ground truth will not decode.
		check_frames := []i64{0, frame_count - 1}
		if frame_count >= 3 {
			check_frames = []i64{0, frame_count - 3, frame_count - 1}
		}
		check_fbuf: [4096]u8
		for f, i in check_frames {
			pick, pick_base := proxy_pick_for_frame(path, frame_count, f, check_fbuf[:], false)
			if pick == nil {
				fmt.printf("[proxy-bg-test] FAIL: frame %d unresolved\n", f)
				os.exit(1)
			}
			gt, px: Clip_Decoder
			defer clip_decoder_reset(&gt)
			defer clip_decoder_reset(&px)
			gt_ok := decode_clip_frame_sync(&gt, path, f, gts[i][:])
			if !gt_ok {
				if f == frame_count - 1 {
					fmt.printf("[proxy-bg-test] note: frame %d past end-of-stream (est. overshoot), skipping\n", f)
					continue
				}
				fmt.printf("[proxy-bg-test] FAIL: source decode frame %d\n", f)
				os.exit(1)
			}
			decoder_set_preview(&px, pick, pick_base)
			if !decode_clip_frame_sync(&px, path, f, pxs[i][:]) {
				// A proxy is allowed to be SHORT, and this one is: the source has 90 frames
				// and the segment carries 88. That is exactly PROXY_FRAME_TOLERANCE, the
				// engine's own named allowance for an encoder that does not emit its last
				// reorder-buffer frames, and the editor copes by falling back to the source
				// for an under-built edge segment (proxy.odin: the unbuilt tail falls back to
				// source).
				//
				// The probe was asking for frame_count-1 -- the source's LAST frame -- through
				// the proxy, with no tolerance, while the source path just above it HAS one
				// for exactly this case. So the probe demanded of the proxy something the
				// engine never asks of it, and reported FAIL on correct behaviour.
				//
				// Bounded by the tolerance and by proximity to the end, and NOT silent: a skip
				// inside the allowance is normal, a skip outside it is still a failure, and a
				// frame in the middle of the timeline is still checked against the source.
				if f >= frame_count - PROXY_FRAME_TOLERANCE {
					fmt.printf(
						"[proxy-bg-test] note: proxy does not carry frame %d (source has %d, within PROXY_FRAME_TOLERANCE=%d); the editor falls back to the source here\n",
						f, frame_count, PROXY_FRAME_TOLERANCE,
					)
					continue
				}
				fmt.printf("[proxy-bg-test] FAIL: segment decode frame %d via %q\n", f, string(pick))
				os.exit(1)
			}
			mean_abs, _ := buffer_diff_metrics(gts[i][:], pxs[i][:])
			if buffer_mean(gts[i][:]) < 1.0 || mean_abs > 40.0 {
				fmt.printf("[proxy-bg-test] FAIL: frame %d proxy content mismatch (mean_abs=%.1f)\n", f, mean_abs)
				os.exit(1)
			}
		}
		delete(idx.segs)
		if keep_cache {
			// A complete segmented proxy is a cache hit for a re-import: a second
			// proxy_transcode must short-circuit WITHOUT enqueuing a rebuild
			// (mirrors the live flow: re-opening the same file must not re-encode
			// the proxy the previous session already built).
			if !proxy_segments_complete(path, frame_count) {
				fmt.println("[proxy-bg-test] FAIL: complete proxy not recognized as a cache hit")
				os.exit(1)
			}
			xbuf: [4096]u8
			xp := proxy_transcode(path, frame_count, 0, 0, 1, xbuf[:])
			if import_bg_active() {
				fmt.println("[proxy-bg-test] FAIL: re-import enqueued a rebuild over a complete proxy")
				os.exit(1)
			}
			if xp != nil {
				fmt.printf("[proxy-bg-test] re-import: proxy cache hit %q (no rebuild)\n", string(xp))
			} else {
				fmt.println("[proxy-bg-test] re-import: no rebuild enqueued (segments served live)")
			}
			fmt.printf("[proxy-bg-test] OK: %s (cache kept)\n", ok_label)
		} else {
			proxy_cleanup_artifacts(path)
			fmt.printf("[proxy-bg-test] OK: %s\n", ok_label)
		}
		os.exit(0)
	}

	// ---------------------------------------------------------------------------
	// VYPER_PROXY_BG_TEST="<file>[|<cancel_pct>]": exercise the BACKGROUND proxy
	// builder (import_bg.odin) without a window.
	//
	// Imports `file` with editor_flags.async_import_mode=true like the live editor, then polls
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

		editor_flags.preview_proxy_enabled = true
		editor_flags.async_import_mode = true

		parts := strings.split(v, "|")
		if len(parts) < 1 {
			fmt.println("proxy-bg-test: need VYPER_PROXY_BG_TEST=\"<file>[|<cancel_pct>]\"")
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

		// With VYPER_PROXY_BG_KEEP=1 the probe leaves the built segments + .idx in
		// place (default: proxy_cleanup_artifacts like the other probes), so an
		// out-of-band second run can verify the rebuild skip.
		keep_cache := os.get_env_alloc("VYPER_PROXY_BG_KEEP", context.temp_allocator) == "1"

		// Full import: bin + timeline, mirroring the GUI's Open File flow. The
		// proxy build must NOT block this call -- and under the on-demand model
		// import does not enqueue anything at all (proxy_transcode returns nil):
		// the request below drives the worker exactly like proxy_build_schedule
		// would. The probe uses the full-source window [0, seg_total) so the
		// whole-file verification below still holds.
		import_media(path)
		frame_count := media_frame_count(project.info_text)

		// The imported asset carries dur_us/src size (set at import); reuse it so
		// the request matches what the GUI scheduler would compute.
		asset: ^Media_Asset
		if len(media_bin.assets) > 0 {
			asset = &media_bin.assets[len(media_bin.assets) - 1]
		}

		deadline := monotonic_ns() + 300_000_000_000
		last_report := monotonic_ns()
		cancel_sent := false
		reported: int = -1
		for {
			active, frac, phase, _ := import_bg_status()
			now := monotonic_ns()

			// A proxy already complete at import (a prior session's build, cache
			// kept) short-circuits: there is nothing to wait for. Verify the
			// artifacts directly.
			if !active && phase == .Idle && !cancel_sent && cancel_pct < 0 && proxy_segments_complete(path, frame_count) {
				if vyper_trace {
					fmt.printf("[proxy-bg-test] proxy already complete at import; no build needed\n")
				}
				proxy_bg_verify_complete(path, frame_count, keep_cache, "proxy already complete (no rebuild)")
				os.exit(0)
			}

			// First tick with no build in flight for this source: post the on-demand
			// request (a no-op when already complete/queued, so harmless to repeat).
			if !active && phase == .Idle && !cancel_sent {
				if asset == nil || asset.dur_us <= 0 || asset.frame_count <= 0 {
					fmt.println("[proxy-bg-test] FAIL: imported asset missing duration/frames for sizing")
					os.exit(1)
				}
				seg_total := proxy_seg_count(asset.frame_count)
				if vyper_trace {
					fmt.printf("[proxy-bg-test] requesting window [0,%d)\n", seg_total)
				}
				import_bg_request(path, asset.frame_count, asset.dur_us, asset.src_w, asset.src_h, 0, seg_total)
			}

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
				if vyper_trace {
					fmt.printf("[proxy-bg-test] worker finished, verifying on-disk artifacts\n")
				}
				proxy_bg_verify_complete(path, frame_count, keep_cache, "async segmented proxy built and verified")
				os.exit(0)

			case .Done_Cancelled:
				if !cancel_sent {
					fmt.println("[proxy-bg-test] FAIL: done-cancelled without a cancel request")
					os.exit(1)
				}
				// Every segment either is listed + present (completed, kept for
				// reuse) or is absent (never built / dropped in-flight). No orphan
				// partials, no listed-but-missing segments.
				idx2: Proxy_Idx
				has_idx := proxy_idx_load(path, &idx2)
				seg_total := proxy_seg_count(frame_count)
				badk := -1
				for k in 0 ..< seg_total {
					seg_buf: [4096]u8
					seg, ok := proxy_segment_path_for(path, k, seg_buf[:])
					if !ok {
						continue
					}
					listed := has_idx && k < len(idx2.segs) && idx2.segs[k] > 0
					exists := os.exists(string(seg))
					if listed && !exists || !listed && exists {
						badk = k
						break
					}
				}
				if badk >= 0 {
					fmt.printf("[proxy-bg-test] FAIL: segment %d left in inconsistent state after cancel\n", badk)
					os.exit(1)
				}
				if keep_cache {
					// Kept for an out-of-band follow-up run: the completed head
					// segments must be reused by the next build, not re-encoded.
					built: i64 = 0
					if has_idx && len(idx2.segs) > 0 {
						for c in idx2.segs {
							built += c
						}
						fmt.printf("[proxy-bg-test] kept %d completed frames across %d segments\n", built, len(idx2.segs))
					}
					fmt.println("[proxy-bg-test] OK: cancelled, segments kept for reuse (cache kept)")
				} else {
					fmt.println("[proxy-bg-test] OK: cancelled, kept segments consistent")
					proxy_cleanup_artifacts(path)
				}
				delete(idx2.segs)
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

	// ---------------------------------------------------------------------------
	// VYPER_PROXY_PICK_SCAN="<file>": call proxy_pick_for_frame for every source
	// frame with NO decode (fast), and print the frames where the resolved file is
	// not a segment (nil / source). Decouples the picker from the decoder: if the
	// picker serves segments for all frames, the flip lives in the decoder path;
	// if the picker itself flips, the resolver is the bug.
	// ---------------------------------------------------------------------------
	proxy_pick_scan_run :: proc(v: string) {
		editor_flags.preview_proxy_enabled = true
		editor_flags.async_import_mode = true
		parts := strings.split(v, "|")
		if len(parts) < 1 {
			fmt.println("proxy-pick-scan: need VYPER_PROXY_PICK_SCAN=\"<file>\"")
			os.exit(2)
		}
		inp: [4096]u8
		n := 0
		for n < len(parts[0]) && n < len(inp) - 1 {
			inp[n] = u8(parts[0][n])
			n += 1
		}
		inp[n] = 0
		path := cstring(&inp[0])
		import_media(path)
		frame_count := media_frame_count(project.info_text)

		last_seg: int = -1
		buf: [4096]u8
		flips: [dynamic]int
		for f := i64(0); f < frame_count + 4; f += 1 {
			pick, base := proxy_pick_for_frame(path, frame_count, f, buf[:], false)
			seg := -1
			if pick != nil && base > 0 {
				seg = int(base / PROXY_SEG_FRAMES)
			}
			if seg != last_seg {
				fmt.printf(
					"[pick-scan f=%d] -> %s (base=%d k=%d)\n",
					f,
					pick != nil ? string(pick) : "<nil>",
					base,
					seg,
				)
				last_seg = seg
			}
			if pick == nil && seg != last_seg {
				append(&flips, int(f))
			}
		}
		fmt.printf("[pick-scan] done: nil-frames=%v\n", flips)
		os.exit(0)
	}

	// ---------------------------------------------------------------------------
	// VYPER_PROXY_STEP="<file>": reproduce the "preview flips to the original
	// source and stays there" bug on a real file + a complete on-disk cache.
	//
	// Mirrors preview_probe_run's deterministic playhead walk but with the proxy
	// ENABLED (the preview probe forces editor_flags.preview_proxy_enabled=false, so it only
	// ever exercises the source decode path). Each playhead step calls
	// update_preview_slots like the live editor; the probe then reports, for the
	// foreground slot, what proxy_pick_for_frame resolved for that clip frame and
	// which physical file slot.dec actually opened. A persistent source after an
	// initial segment serve is the bug reproduced.
	// ---------------------------------------------------------------------------
	proxy_step_probe_run :: proc(v: string) {
		editor_flags.preview_proxy_enabled = true
		editor_flags.async_import_mode = true
		parts := strings.split(v, "|")
		if len(parts) < 1 {
			fmt.println("proxy-step: need VYPER_PROXY_STEP=\"<file>\"")
			os.exit(2)
		}
		inp: [4096]u8
		n := 0
		for n < len(parts[0]) && n < len(inp) - 1 {
			inp[n] = u8(parts[0][n])
			n += 1
		}
		inp[n] = 0
		path := cstring(&inp[0])
		import_media(path)

		clip: ^Clip = nil
		for t := 0; t < len(timeline.tracks); t += 1 {
			for ci := 0; ci < len(timeline.tracks[t].clips); ci += 1 {
				if timeline.tracks[t].clips[ci].kind == .Video {
					clip = &timeline.tracks[t].clips[ci]
					break
				}
			}
			if clip != nil {
				break
			}
		}
		if clip == nil {
			fmt.println("proxy-step: no video clip on timeline")
			os.exit(1)
		}
		frame_count := clip.source_length_frames
		fmt.println("[proxy-step] imported clip tl=[", clip.timeline_start_frame, ",", clip.timeline_start_frame + frame_count, ") src=[", clip.source_start_frame, ",", clip.source_start_frame + frame_count, ") total_frames =", frame_count)

		source_opens := 0
		seg_opens := 0
		flipped_at := i64(-1)
		last_served_seg: bool
		for f := i64(0); f < frame_count; f += 1 {
			playhead.frame = f
			playhead.playing = false
			update_preview_slots()
			for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
				slot := &preview_slots[s]
				if !slot.in_use {
					continue
				}
				opened_is_seg := slot.dec.opened && slot.dec.opened_path != slot.dec.path
				if slot.dec.opened {
					if opened_is_seg {
						seg_opens += 1
					} else {
						source_opens += 1
					}
				}
				served_seg := opened_is_seg && slot.has_frame
				if served_seg != last_served_seg && f > 0 && served_seg == false && flipped_at < 0 {
					flipped_at = f
				}
				last_served_seg = served_seg
				fmt.printf(
					"[proxy-step f=%d] clip_f=%d has_frame=%v dec_opened=%v dec_path=%v opened_path=%q displayed_pick=%08x\n",
					f,
					slot.source_start_frame + f - slot.timeline_start_frame,
					slot.has_frame,
					slot.dec.opened,
					slot.dec.path != nil ? string(slot.dec.path) : "nil",
					slot.dec.opened_path != nil ? string(slot.dec.opened_path) : "",
					slot.displayed_pick,
				)
			}
		}
		fmt.printf(
			"[proxy-step] done: source_opens=%d seg_opens=%d flipped_at=%d\n",
			source_opens,
			seg_opens,
			flipped_at,
		)
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

	// ---------------------------------------------------------------------------
	// VYPER_IMAGE_PROBE="<file>": a still image is NOT footage.
	//
	// The user reported that importing a .jpg put an AUDIO clip on the timeline, and
	// then the app SEGFAULTED in the proxy encoder. Both are measured here, on the
	// real import path, because both were invisible to every other probe: nothing
	// imported an image, and the crash was in a path with no gate target at all.
	//
	// The crash is the one that matters. A still probes as a one-frame mjpeg VIDEO
	// stream (verified with ffprobe: codec_type=video, codec_name=mjpeg,
	// r_frame_rate=25/1, nb_frames=N/A), so every "is this video?" test says yes and
	// the on-demand proxy scheduler posts a background H.264 build for it. The
	// encoder is then drained having been fed nothing, and h264_vaapi dereferences
	// state that only exists after the first frame. Reproduced exactly, same two log
	// lines and the same SIGSEGV, before any fix.
	//
	// Asserts, in order:
	//   1. the asset is classified Video and flagged is_image;
	//   2. placing it yields a Video clip that is flagged is_still;
	//   3. the background builder REFUSES an image rather than encoding one.
	// ---------------------------------------------------------------------------

	probe_image_path :: proc(v: string) -> cstring {
		inp: [4096]u8
		n := 0
		for n < len(v) && n < len(inp) - 1 {
			inp[n] = v[n]
			n += 1
		}
		inp[n] = 0
		return cstring(&inp[0])
	}

	probe_image_run :: proc(v: string) {
		path := probe_image_path(v)
		if !media_is_image(path) {
			fmt.printf("[image-probe] FAIL: %q is not named like a still image\n", string(path))
			os.exit(1)
		}

		// 1. Asset classification. A jpg is a one-frame video stream, so has_video is
		// true and the kind is right -- but is_image is what every other decision
		// keys off, and it is computed separately, so it is asserted separately.
		asset_id := import_media_to_bin(path)
		if asset_id == 0 {
			fmt.println("[image-probe] FAIL: import_media_to_bin refused the image")
			os.exit(1)
		}
		asset := find_asset(asset_id)
		if asset == nil {
			fmt.println("[image-probe] FAIL: imported asset not found")
			os.exit(1)
		}
		fmt.printf(
			"[image-probe] asset kind=%v is_image=%v frames=%d src=%dx%d dur=%dus\n",
			asset.kind,
			asset.is_image,
			asset.frame_count,
			asset.src_w,
			asset.src_h,
			asset.dur_us,
		)
		if asset.kind != .Video {
			fmt.printf("[image-probe] FAIL: a still image probed as %v, want Video\n", asset.kind)
			os.exit(1)
		}
		if !asset.is_image {
			fmt.println("[image-probe] FAIL: is_image not set for a .jpg")
			os.exit(1)
		}
		// A still has no real frame rate -- mjpeg defaults to 25/1 -- so the clip must
		// not be pinned to it or a one-second image becomes 25 frames of footage.
		if asset.video_fps != 0 {
			fmt.printf(
				"[image-probe] FAIL: still pinned to source fps %v; mjpeg's default rate is not the image's\n",
				asset.video_fps,
			)
			os.exit(1)
		}

		// 2. Placement. add_asset_to_timeline picks the lane count from audio_streams
		// and the kind, so this is where a misclassification becomes an audio clip.
		playhead.frame = 0
		placed := add_asset_to_timeline(asset_id, 0, 0)
		_, clip, found := clip_at_frame(placed)
		if !found || clip == nil {
			fmt.printf("[image-probe] FAIL: no clip on the timeline at placed frame %d\n", placed)
			os.exit(1)
		}
		fmt.printf("[image-probe] placed clip kind=%v is_still=%v at frame %d\n", clip.kind, clip.is_still, placed)
		if clip.kind != .Video {
			fmt.printf("[image-probe] FAIL: a still image placed as a %v clip\n", clip.kind)
			os.exit(1)
		}
		if !clip.is_still {
			fmt.println("[image-probe] FAIL: placed clip is not flagged is_still")
			os.exit(1)
		}

		// 3. The builder refuses it. This is the crash: before the fix this posted a
		// background H.264 build and the process died in h264_vaapi.
		//
		// The wait is the assertion. Reading `building` straight after the post is
		// vacuous -- the worker has not woken yet, so it reads false whether or not a
		// build was accepted, and the probe would pass against the crashing code. The
		// window is generous because the point is that nothing EVER starts, so
		// spinning the full budget is what makes a late start fail too.
		import_bg_init()
		editor_flags.preview_proxy_enabled = true
		editor_flags.async_import_mode = true
		import_bg_request(path, asset.frame_count, asset.dur_us, asset.src_w, asset.src_h, 0, 1)
		settled := false
		for _ in 0 ..< 200 {
			_, _, _, has_request, _, _, _, building, _, _, _, _, _, _, _, _ := import_bg_window()
			if building {
				fmt.println("[image-probe] FAIL: the builder started an encode for a still image")
				break
			}
			if !has_request {
				// Refused outright: no request was ever recorded.
				settled = true
				break
			}
			time.sleep(10 * time.Millisecond)
		}
		import_bg_shutdown()
		if !settled {
			// Reaching here with no refusal and no build means the request sat in the
			// queue for the whole window, which is not what "refuses a still" means.
			fmt.println("[image-probe] FAIL: the builder neither refused nor finished the request")
			os.exit(1)
		}
		fmt.println("[image-probe] ok (still image: Video kind, is_still, no proxy build)")
		os.exit(0)
	}

	// ---------------------------------------------------------------------------
	// VYPER_IMAGE_DECODE_PROBE="<file>": a still image must DECODE, and every
	// timeline frame of it must show that one image.
	//
	// Separate from the classification probe because the two failures are different
	// and the user reported both: a .jpg that "doesn't render at all" is not a
	// classification problem. Classification is right (kind=Video, is_still) and the
	// clip still shows nothing, so the defect is in the decode/draw path and a probe
	// that stops at the asset cannot see it.
	//
	// The thing worth pinning is the HOLD. A still has one source frame, and
	// clip_source_frame maps every timeline frame of the clip to it -- so the decoder
	// is asked for frame 0 once per timeline frame, 60 times over a one-second clip.
	// That is the conform repeat path (decode_source_frame's `frame_idx ==
	// dec.last_frame` branch), and if it re-decodes instead of re-scaling it pays a
	// full seek plus decode per timeline frame, which is a stall proportional to the
	// clip's length.
	// ---------------------------------------------------------------------------

	image_buf: [PREVIEW_W * PREVIEW_H * 4]u8

	probe_image_decode_run :: proc(v: string) {
		path := probe_image_path(v)
		if !media_is_image(path) {
			fmt.printf("[image-dec] FAIL: %q is not named like a still image\n", string(path))
			os.exit(1)
		}
		asset_id := import_media_to_bin(path)
		if asset_id == 0 {
			fmt.println("[image-dec] FAIL: import_media_to_bin refused the image")
			os.exit(1)
		}
		asset := find_asset(asset_id)
		if asset == nil {
			fmt.println("[image-dec] FAIL: imported asset not found")
			os.exit(1)
		}
		playhead.frame = 0
		placed := add_asset_to_timeline(asset_id, 0, 0)
		_, clip, found := clip_at_frame(placed)
		if !found || clip == nil {
			fmt.println("[image-dec] FAIL: no clip placed")
			os.exit(1)
		}

		// Every timeline frame of the clip must map to the SAME source frame. If this
		// is wrong the hold cannot work no matter what the decoder does, so it is the
		// first thing asserted.
		mapped := clip_source_frame(
			clip.source_start_frame,
			clip.timeline_start_frame,
			clip.timeline_start_frame,
			clip.is_still,
			clip.src_fps,
		)
		// The clip's REAL extent, not `placed - timeline_start_frame`: a still is
		// placed at its own start frame, so that difference is 0 and the hold would
		// go untested -- which is the whole point of this probe.
		span := max(1, clip_timeline_length(clip) - 1)
		late := clip_source_frame(
			clip.source_start_frame,
			clip.timeline_start_frame,
			clip.timeline_start_frame + span,
			clip.is_still,
			clip.src_fps,
		)
		fmt.printf(
			"[image-dec] span=%d source frames %d..%d -> %d..%d\n",
			span,
			clip.source_start_frame,
			clip.source_start_frame + span,
			mapped,
			late,
		)
		if mapped != late {
			fmt.println("[image-dec] FAIL: a still does not hold one source frame across its span")
			os.exit(1)
		}

		// Decode the frame the preview would ask for, twice: the second call is the
		// repeat every later timeline frame makes, and it is where a re-decode-per-
		// timeline-frame stall would live.
		dec: Clip_Decoder
		for pass in 0 ..< 2 {
			if !decode_clip_frame_sync(&dec, clip.path, mapped, image_buf[:]) {
				fmt.printf("[image-dec] FAIL: pass %d could not decode source frame %d\n", pass, mapped)
				os.exit(1)
			}
		}

		clip_decoder_release_ffmpeg(&dec)
		// Real pixels, not a decode that "succeeded" into nothing.
		//
		// The bound is the FIT RECT, not the whole buffer: decode_into_buffer places
		// the aspect-preserved decode INSIDE the preview box, so a 1080x1920 portrait
		// lands as 243x432 centred in 768x432 and covers ~32% of it by construction.
		// Asserting the buffer is mostly written would fail every correctly
		// letterboxed portrait. What must hold is that the fit rect carries image
		// content with real dynamic range.
		fit_w, fit_h := i64(dec.dst_w), i64(dec.dst_h)
		ox, oy := i64(dec.fit_ox), i64(dec.fit_oy)
		if fit_w <= 0 || fit_h <= 0 {
			fmt.println("[image-dec] FAIL: decoder reported no fit rect")
			os.exit(1)
		}
		buf_w := i64(PREVIEW_W)
		nonzero, inside := 0, 0
		min_v, max_v: u8 = 255, 0
		for row in 0 ..< fit_h {
			for col in 0 ..< fit_w {
				i := (oy + row) * buf_w + (ox + col)
				if i < 0 || i * 4 + 3 >= i64(len(image_buf)) {
					continue
				}
				inside += 1
				v := image_buf[i * 4]
				if v != 0 {
					nonzero += 1
				}
				min_v = min(min_v, v)
				max_v = max(max_v, v)
			}
		}
		frac := f64(nonzero) / f64(max(inside, 1))
		fmt.printf(
			"[image-dec] fit=%dx%d at (%d,%d) nonzero=%.3f min=%d max=%d (decoded twice, still holds)\n",
			fit_w,
			fit_h,
			ox,
			oy,
			frac,
			min_v,
			max_v,
		)
		if frac < 0.5 {
			fmt.println("[image-dec] FAIL: the fit rect is mostly empty (the image would not render)")
			os.exit(1)
		}
		if max_v - min_v < 32 {
			fmt.println("[image-dec] FAIL: the fit rect is flat (no image content)")
			os.exit(1)
		}
		fmt.println("[image-dec] ok (still decodes to real pixels and holds across its span)")
		os.exit(0)
	}

}
