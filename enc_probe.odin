package main

import "core:fmt"
import "core:strings"
import avcodec "vendor/ffmpeg/avcodec"
import avfmt "vendor/ffmpeg/avformat"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	// VYPER_ENC_PROBE="<cpu.mp4>|<gpu.mp4>": export encoder-path verification.
	//
	// Renders a small synthetic clip (gradient frames) through the real encoder
	// stack twice: once with the CPU choice (libx264) and once with the GPU choice
	// (hardware encoder first, libx264 fallback). Asserts each produced file
	// decodes through the software Clip_Decoder path, and reports which encoder
	// the GPU choice actually opened (h264_vaapi on this machine, a named hw
	// encoder elsewhere, or libx264 on a deviceless host). Each run ends in
	// enc_cleanup so the hw device/frames refs get released.
	ENC_PROBE_W :: 320
	ENC_PROBE_H :: 180
	ENC_PROBE_FRAMES :: 16

	enc_probe_frame_buf: [ENC_PROBE_W * ENC_PROBE_H * 4]u8
	enc_probe_dec_buf:   [PREVIEW_W * PREVIEW_H * 4]u8
	enc_probe_path_buf:  [4096]u8

	enc_probe_run :: proc(v: string) -> int {
		parts := strings.split(v, "|")
		if len(parts) < 2 {
			fmt.println(`[enc-probe] need VYPER_ENC_PROBE="<cpu.mp4>|<gpu.mp4>"`)
			return 2
		}
		cpu_name, gpu_name: [64]u8
		cpu_n, gpu_n: int
		cpu_ok := enc_probe_render(parts[0], .CPU, &cpu_name, &cpu_n)
		gpu_ok := enc_probe_render(parts[1], .GPU, &gpu_name, &gpu_n)
		fmt.printf("enc: cpu=%s gpu=%s\n", string(cpu_name[:cpu_n]), string(gpu_name[:gpu_n]))

		// Both files must decode through our own software path -- that's the file
		// being actually usable, not just written.
		hw_decode_enabled = false
		cpu_dec: Clip_Decoder
		gpu_dec: Clip_Decoder
		defer clip_decoder_reset(&cpu_dec)
		defer clip_decoder_reset(&gpu_dec)
		ok_cpu := cpu_ok && decode_clip_frame_sync(&cpu_dec, _cstring(parts[0]), 0, enc_probe_dec_buf[:])
		ok_gpu := gpu_ok && decode_clip_frame_sync(&gpu_dec, _cstring(parts[1]), 0, enc_probe_dec_buf[:])

		fmt.printf(
			"[enc-probe] cpu_encode=%v gpu_encode=%v cpu_decode=%v gpu_decode=%v\n",
			cpu_ok, gpu_ok, ok_cpu, ok_gpu,
		)
		return (cpu_ok && gpu_ok && ok_cpu && ok_gpu) ? 0 : 1
	}

	// enc_probe_render encodes ENC_PROBE_FRAMES gradient frames through the given
	// encoder choice into path. The opened encoder's registered name is copied
	// into out_name (the Render_Enc's own buffer is zeroed by enc_cleanup, so a
	// view of it would dangle after this returns).
	enc_probe_render :: proc(
		path: string,
		choice: Render_Encoder_Choice,
		out_name: ^[64]u8,
		out_n: ^int,
	) -> (ok: bool) {
		path_buf: [4096]u8
		n := 0
		for n < len(path) && n < len(path_buf) - 1 {
			path_buf[n] = path[n]
			n += 1
		}
		path_buf[n] = 0

		render_encoder_ui.choice = choice
		e: Render_Enc
		defer enc_cleanup(&e)
		if !render_open_output(&e, cstring(&path_buf[0]), ENC_PROBE_W, ENC_PROBE_H, false, 30, 1) {
			fmt.println("[enc-probe] render_open_output failed for", path)
			return false
		}
		for i in 0 ..< ENC_PROBE_FRAMES {
			enc_probe_fill(i, ENC_PROBE_W, ENC_PROBE_H)
			if !rend_enc_video_frame(&e, enc_probe_frame_buf[:], ENC_PROBE_W, ENC_PROBE_H, cast(i64)i) {
				fmt.println("[enc-probe] frame", i, "encode failed for", path)
				return false
			}
		}
		avcodec.send_frame(e.vcodec_ctx, nil)
		if !enc_drain(&e, e.vcodec_ctx, e.vstream, e.vpkt) {
			fmt.println("[enc-probe] flush failed for", path)
			return false
		}
		if ret := avfmt.write_trailer(e.fmt_ctx); ret < 0 {
			fmt.println("[enc-probe] write_trailer:", ff_err_str(ret))
			return false
		}
		copy(out_name^[:], e.enc_name[:e.enc_name_len])
		out_n^ = e.enc_name_len
		return true
	}

	// enc_probe_fill paints a simple moving gradient so consecutive frames differ
	// (a delta-encoding path that catches mistakes in pts/gop wiring).
	enc_probe_fill :: proc(frame, w, h: int) {
		for y in 0 ..< h {
			for x in 0 ..< w {
				i := (y * w + x) * 4
				enc_probe_frame_buf[i + 0] = u8((x * 255) / w)
				enc_probe_frame_buf[i + 1] = u8((y * 255) / h)
				enc_probe_frame_buf[i + 2] = u8((frame * 40) % 256)
				enc_probe_frame_buf[i + 3] = 255
			}
		}
	}

	// _cstring copies into the shared 4096 buffer; the probe's decode calls
	// consume it synchronously, and a later call overwrites the previous value.
	_cstring :: proc(s: string) -> cstring {
		n := 0
		for n < len(s) && n < len(enc_probe_path_buf) - 1 {
			enc_probe_path_buf[n] = s[n]
			n += 1
		}
		enc_probe_path_buf[n] = 0
		return cstring(&enc_probe_path_buf[0])
	}
}
