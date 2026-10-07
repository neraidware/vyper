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

	// VYPER_HW_PROBE="<file>|<count>|<stride>": hardware-vs-software decode parity.
	//
	// Opens two Clip_Decoders on the same source -- one hardware (VAAPI/CUDA/...
	// whatever the machine offers), one forced software (hw_decode_enabled=false) --
	// and decodes the same frame index range through decode_clip_frame_sync (seek
	// + scale), interleaved so both paths hit identical frames. Asserts the two
	// paths produce BYTE-IDENTICAL PREVIEW buffers (identical frame indices and
	// scaling) and reports per-frame wall time for each path. Software vs software
	// still passes on a deviceless host, so the probe doubles as a fallback smoke
	// test.
	// Per-frame PREVIEW buffers are shared (not stack locals) so the probe's
	// 1.3MB buffers live in BSS, not on the probe's stack (match render.odin).
	hw_probe_hw_buf: [PREVIEW_W * PREVIEW_H * 4]u8
	hw_probe_sw_buf: [PREVIEW_W * PREVIEW_H * 4]u8

	preview_hw_probe_run :: proc(v: string) {
		// os.exit after the pass so the decoder defers below reach their close.
		os.exit(hw_probe_pass(v))
	}

	hw_probe_pass :: proc(v: string) -> int {
		parts := strings.split(v, "|")
		if len(parts) < 3 {
			fmt.println("hw-probe: need VYPER_HW_PROBE=\"<file>|<count>|<stride>\"")
			os.exit(2)
		}
		file := parts[0]
		count, okc := strconv.parse_i64(parts[1])
		stride_st, ok_s := strconv.parse_i64(parts[2])
		if !okc || count <= 0 || !ok_s || stride_st < 1 {
			fmt.println("hw-probe: bad \"<file>|<count>|<stride>\"")
			os.exit(2)
		}
		inp: [4096]u8
		n := 0
		for n < len(file) && n < len(inp) - 1 {
			inp[n] = u8(file[n])
			n += 1
		}
		inp[n] = 0
		path := cstring(&inp[0])

		hw_dec: Clip_Decoder
		sw_dec: Clip_Decoder
		defer clip_decoder_reset(&hw_dec)
		defer clip_decoder_reset(&sw_dec)

		hw_cnt, sw_cnt: i64
		hw_fail, sw_fail: i64
		mismatches: i64
		hw_ms, sw_ms: f64

		for i := i64(0); i < count; i += stride_st {
			hw_decode_enabled = true
			t0 := time.now()
			ok_hw := decode_clip_frame_sync(&hw_dec, path, i, hw_probe_hw_buf[:])
			hw_ms += f64(time.duration_milliseconds(time.since(t0)))
			hw_decode_enabled = false
			t0 = time.now()
			ok_sw := decode_clip_frame_sync(&sw_dec, path, i, hw_probe_sw_buf[:])
			sw_ms += f64(time.duration_milliseconds(time.since(t0)))
			hw_decode_enabled = true
			if ok_hw {
				hw_cnt += 1
			} else {
				hw_fail += 1
			}
			if ok_sw {
				sw_cnt += 1
			} else {
				sw_fail += 1
			}
			if ok_hw && ok_sw {
				hh := fnv64(hw_probe_hw_buf[:])
				sh := fnv64(hw_probe_sw_buf[:])
				if hh != sh {
					mismatches += 1
					if mismatches <= 10 {
						fmt.printf("  MISMATCH frame=%3d hw=%016x sw=%016x\n", i, hh, sh)
					}
				}
			}
		}
		if mismatches > 10 {
			fmt.println("[hw-probe] ... rest suppressed")
		}
		fmt.printf(
			"[hw-probe] file=%s frames: hw=%d sw=%d stride=%d mismatches=%d\n",
			file, hw_cnt, sw_cnt, stride_st, mismatches,
		)
		fmt.printf(
			"[hw-probe] hw open_failures=%d decoder_ms=%.0f (%.2f ms/frame)\n",
			hw_fail, hw_ms, hw_cnt > 0 ? hw_ms / f64(hw_cnt) : 0,
		)
		fmt.printf(
			"[hw-probe] sw open_failures=%d decoder_ms=%.0f (%.2f ms/frame)\n",
			sw_fail, sw_ms, sw_cnt > 0 ? sw_ms / f64(sw_cnt) : 0,
		)
		return (hw_cnt == sw_cnt && mismatches == 0 && hw_fail == 0 && sw_fail == 0 && hw_cnt > 0) ? 0 : 1
	}
}
