package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------
// VYPER_CACHE_PROBE="<file>|<step>|<back>|<count>": adversarial cache-desync
// check on ONE persistent decoder.
//
// The lost-region bug at a flush (no-gap) boundary comes from decode_clip_frame_sync's
// cache-hit path advancing last_frame past the physical decoder position, so a later
// forward request decodes from the wrong spot but labels the frame with an index from
// the future. This probe forces the exact sequence on a single persistent decoder and
// compares every served buffer against ground truth (in-order forward decode).
//
// Sequence per iteration i:
//   a) request  target = base + i*step            (seek far ahead, caches it)
//   b) request  back   = base + i*step - back     (non-consecutive, not cached -> seek back)
//      -- NOW cache holds `target` but the physical decoder is parked at `back`
//   c) request  target again                      (CACHE HIT: old code sets last=target)
//   d) request  target+1   (forward fast-path: old code decodes from physical `back+1`, labels target+1)
// Ground truth for key k is the hash of the k-th in-order decoded frame.
// ---------------------------------------------------------------------------
cache_probe_run :: proc(v: string) {
	preview_proxy_enabled = false // ground truth vs the original decode path
	parts := strings.split(v, "|")
	if len(parts) < 4 {
		fmt.println("cache-probe: need VYPER_CACHE_PROBE=\"<file>|<step>|<back>|<count>\"")
		os.exit(2)
	}
	file := parts[0]
	step := i64(1)
	if sv, ok := strconv.parse_i64(parts[1]); ok {
		step = sv
	}
	back := i64(1)
	if sv, ok := strconv.parse_i64(parts[2]); ok {
		back = sv
	}
	count := i64(3)
	if sv, ok := strconv.parse_i64(parts[3]); ok {
		count = sv
	}

	buf: [4096]u8
	n := 0
	for n < len(file) && n < len(buf) - 1 {
		buf[n] = u8(file[n])
		n += 1
	}
	buf[n] = 0
	path := cstring(&buf[0])
	max_key := i64(0)
	for i in 0 ..< count {
		target := i64(48) + i * step
		if target + 4 > max_key {
			max_key = target + 4
		}
	}

	// Ground truth: in-order decode every frame 0..max_key, hash each.
	clear(&probe_hashes)
	seq: Clip_Decoder
	if !open_clip_decoder(&seq, path) {
		fmt.println("cache-probe: open (ground truth) failed")
		os.exit(2)
	}
	for fi in i64(0) ..= max_key {
		if !decode_source_frame(&seq, fi) {
			fmt.printf("cache-probe: ground-truth decode stopped at %d\n", fi)
			break
		}
		decode_into_buffer(&seq, probe_hash_buf[:], PREVIEW_W, PREVIEW_H)
		append(&probe_hashes, fnv64(probe_hash_buf[:]))
	}
	clip_decoder_reset(&seq)

	// Fresh persistent decoder exercising the cache path (decode_clip_frame_sync).
	pc: Clip_Decoder
	if !open_clip_decoder(&pc, path) {
		fmt.println("cache-probe: open (suspect) failed")
		os.exit(2)
	}
	bad := 0
	checked := 0
	for i := i64(0); i < count; i += 1 {
		target := i64(48) + i * step
		backf := target - back
		if backf < 0 {
			backf = 0
		}
		// a) far-ahead request (seek + cache).
		if !decode_clip_frame_sync(&pc, path, target, probe_hash_buf[:]) {
			fmt.printf("  iter %d: step-target %d decode failed\n", i, target)
			continue
		}
		// b) jump back (seek, not cached at first).
		if !decode_clip_frame_sync(&pc, path, backf, probe_hash_buf[:]) {
			fmt.printf("  iter %d: back %d decode failed\n", i, backf)
			continue
		}
		// c) re-request target (cache hit path — old code advanced last_frame here).
		if !decode_clip_frame_sync(&pc, path, target, probe_hash_buf[:]) {
			fmt.printf("  iter %d: cache-hit target %d decode failed\n", i, target)
			continue
		}
		// d) forward request target+1 — the desync surface.
		next := target + 1
		if int(next) >= len(probe_hashes) {
			break
		}
		checked += 1
		if !decode_clip_frame_sync(&pc, path, next, probe_hash_buf[:]) {
			fmt.printf("  iter %d: next %d decode failed\n", i, next)
			continue
		}
		got := fnv64(probe_hash_buf[:])
		want := probe_hashes[next]
		if got != want {
			bad += 1
			fmt.printf("  MISMATCH target=%d back=%d next=%d got=%016x want=%016x last=%d\n",
				target, backf, next, got, want, pc.last_frame)
		} else {
			fmt.printf("  ok       target=%d back=%d next=%d last=%d\n",
				target, backf, next, pc.last_frame)
		}
	}
	fmt.printf("[cache-probe] checked=%d mismatches=%d (step=%d back=%d count=%d)\n",
		checked, bad, step, back, count)
	clip_decoder_reset(&pc)
	os.exit(bad == 0 ? 0 : 1)
}
