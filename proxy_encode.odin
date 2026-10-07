package main

import "core:c"
import "core:fmt"
import avcodec "vendor/ffmpeg/avcodec"
import avfmt "vendor/ffmpeg/avformat"
import avutil "vendor/ffmpeg/avutil"
import sws "vendor/ffmpeg/swscale"

// In-process proxy encode. All of the libx264/mp4 machinery that import_bg_build
// and proxy_transcode used to reach for through an ffmpeg subprocess lives here,
// so proxying never shells out and probe/CI needs no tooling beyond the vendored
// libs. The settings mirror the old argv exactly -- `-preset ultrafast -tune
// fastdecode -crf 26 -g 1` -- so a proxied frame is the same pixels on either
// path. Encoded frames are counted, not clocked: the proxy's index model is a
// count of frames, so a segment is exactly the decode-dropped frames between
// its start bounds.

Enc_Result :: enum {
	// Requested range was encoded; count is how many frames made it in (may be
	// short when the source EOF'd first -- the caller owns the tolerance).
	Ok,
	// cancelled() returned true mid-encode. The artifact is half-written and
	// the caller must drop it (mirrors the old terminate path).
	Cancelled,
	// Hard libav error. Nothing usable was written; caller removes the file.
	Fail,
}

DecodeStep :: enum {
	Ok,
	Eof,
	Error,
}

encode_decode_step :: proc(
	in_fmt: ^avfmt.FormatContext,
	video_idx: c.int,
	dec: ^avcodec.CodecContext,
	pkt: ^avcodec.Packet,
	frame: ^avutil.Frame,
	hw_pix_fmt: avutil.PixelFormat,
	sw_frame: ^avutil.Frame,
) -> DecodeStep {
	for {
		if ret := avfmt.read_frame(in_fmt, pkt); ret < 0 {
			return ret == avutil.AVERROR_EOF ? .Eof : .Error
		}
		if pkt.stream_index != video_idx {
			avcodec.packet_unref(pkt)
			continue
		}
		if avcodec.send_packet(dec, pkt) < 0 {
			avcodec.packet_unref(pkt)
			continue
		}
		avcodec.packet_unref(pkt)
		for {
			r := avcodec.receive_frame(dec, frame)
			if r == avutil.AVERROR_EAGAIN || r == avutil.AVERROR_EOF {
				break
			}
			if r < 0 {
				fmt.printf("[enc] avcodec_receive_frame error %d\n", r)
				return .Error
			}
			if hw_pix_fmt != .None && avutil.PixelFormat(frame.format) == hw_pix_fmt {
				// Hardware frame: transfer into sw_frame so the sws scale in
				// encode_scale_send sees CPU-accessable pixels, mirroring the
				// playback decoder's decode_one_forward.
				if avutil.hwframe_transfer_data(sw_frame, frame, 0) < 0 {
					return .Error
				}
				_ = avutil.frame_copy_props(sw_frame, frame)
				avutil.frame_unref(frame)
				avutil.frame_move_ref(frame, sw_frame)
			}
			return .Ok
		}
	}
}

// proxy_encode_range encodes `encode_count` frames of `src`, starting at source
// frame `start_frame`, into `out_path` at out_w x out_h. Seek + drop is
// count-based (decode forward from the keyframe before start_frame, drop that
// many frames), which is frame-exact under the proxy's index model and matches
// how the old `-ss t0` behaved on CFR content. Derived from the input stream's
// detected rate (r_frame_rate preferred over avg, same as the decoder).
// on_frames is called with the running per-call encoded-frame count for
// -progress-file-style progress; cancelled is polled every 32 frames for the
// worker's cancel flag.
proxy_encode_range :: proc(
	src, out_path: cstring,
	start_frame, encode_count: i64,
	out_w, out_h: c.int,
	threads: c.int,
	ud: rawptr,
	on_frames: proc(ud: rawptr, frames_done: int),
	cancelled: proc(ud: rawptr) -> bool,
) -> (Enc_Result, i64) {
	spall_scope(#procedure)

	in_fmt: ^avfmt.FormatContext
	defer avfmt.close_input(&in_fmt)
	if ret := avfmt.open_input(&in_fmt, src, nil, nil); ret < 0 {
		when ODIN_DEBUG {
			if vyper_trace {
				fmt.printf("[enc] avformat_open_input %q: %s\n", string(src), ff_err_str(ret))
			}
		}
		return .Fail, 0
	}
	if ret := avfmt.find_stream_info(in_fmt, nil); ret < 0 {
		fmt.printf("[enc] avformat_find_stream_info %q: %s\n", string(src), ff_err_str(ret))
		return .Fail, 0
	}
	video_idx := avfmt.find_best_stream(in_fmt, .Video, -1, -1, nil, 0)
	if video_idx < 0 {
		fmt.printf("[enc] no video stream in %q\n", string(src))
		return .Fail, 0
	}
	st := in_fmt.streams[video_idx]
	par := st.codecpar

	codec := find_hw_decoder(par.codec_id)
	if codec == nil {
		fmt.printf("[enc] no decoder for %s\n", avcodec.get_name(par.codec_id))
		return .Fail, 0
	}
	dec := avcodec.alloc_context3(codec)
	defer avcodec.free_context(&dec)
	if ret := avcodec.parameters_to_context(dec, par); ret < 0 {
		fmt.printf("[enc] avcodec_parameters_to_context: %s\n", ff_err_str(ret))
		return .Fail, 0
	}
	// The proxy build decodes the SOURCE (often a fat AV1 recording) while the
	// playback decoders and the audio producer need the same cores. Open the
	// encoder's decoder through the same hardware path the preview uses so the
	// transcode doesn't swallow the CPU the UI and audio are running on; fall
	// back to software when no device is available. hw_pix_fmt/.None means the
	// software path below (encode_decode_step skips the hw->sw transfer).
	hw_pix_fmt: avutil.PixelFormat = .None
	hw_dev: ^avutil.BufferRef
	enc_sw_frame: ^avutil.Frame
	if hw_decode_enabled {
		for i: c.int = 0; ; i += 1 {
			cfg := avcodec.get_hw_config(codec, i)
			if cfg == nil {
				break
			}
			if .HW_Device_Ctx not_in cfg.methods {
				continue
			}
			probe_level := avutil.log_get_level()
			avutil.log_set_level(.Quiet)
			create_ok := avutil.hwdevice_ctx_create(&hw_dev, cfg.device_type, nil, nil, 0)
			avutil.log_set_level(probe_level)
			if create_ok != 0 {
				continue
			}
			hw_pix_fmt = cfg.pix_fmt
			dec.hw_device_ctx = avutil.buffer_ref(hw_dev)
			enc_sw_frame = avutil.frame_alloc()
			when ODIN_DEBUG {
				if vyper_trace {
					fmt.printf("[enc] hw-decode %s via %s\n",
						string(avcodec.get_name(par.codec_id)),
						string(avutil.hwdevice_get_type_name(cfg.device_type)))
				}
			}
			break
		}
	}
	defer if hw_pix_fmt != .None {
		avutil.buffer_unref(&hw_dev)
		if enc_sw_frame != nil {
			avutil.frame_free(&enc_sw_frame)
		}
	}
	if ret := avcodec.open2(dec, codec, nil); ret < 0 {
		fmt.printf("[enc] avcodec_open2 (decoder): %s\n", ff_err_str(ret))
		return .Fail, 0
	}

	fps := st.r_frame_rate
	if fps.num <= 0 || fps.den <= 0 {
		fps = st.avg_frame_rate
	}
	if fps.num <= 0 || fps.den <= 0 {
		fps = {25, 1}
	}

	in_frame := avutil.frame_alloc()
	defer avutil.frame_free(&in_frame)
	in_pkt := avcodec.packet_alloc()
	defer avcodec.packet_free(&in_pkt)

	// Stage the segment's opening frame(s) with the same keyframe-backward seek
	// + PTS walk decode_source_frame uses, so the segment begins on EXACTLY the
	// frame occupying source index start_frame (CFR: the frame whose pts equals
	// the target; VFR: the last frame below when the next one overshoots). The
	// walk is bounded by one GOP -- the seek lands on the keyframe at/before
	// the target -- never by start_frame. staged[] holds at most two frames the
	// encode loop must emit before resuming live decode.
	target_ts := avutil.rescale_q(c.int64_t(start_frame), avutil.Rational{num = fps.den, den = fps.num}, st.time_base)
	if ret := avfmt.seek_frame(in_fmt, video_idx, target_ts, avfmt.SeekFlags{.Backward}); ret < 0 {
		fmt.printf("[enc] av_seek_frame: %s\n", ff_err_str(ret))
		return .Fail, 0
	}
	avcodec.flush_buffers(dec)
	staged: [2]^avutil.Frame
	staged_n := 0
	if start_frame > 0 {
		held := avutil.frame_alloc()
		defer avutil.frame_free(&held)
		have_held := false
		for {
			step := encode_decode_step(in_fmt, video_idx, dec, in_pkt, in_frame, hw_pix_fmt, enc_sw_frame)
			if step != .Ok {
				// A segment cannot begin where the source has no frames.
				return .Fail, 0
			}
			pts := in_frame.best_effort_timestamp
			if pts >= target_ts {
				if pts == target_ts || !have_held {
					// in_frame is (or substitutes for) start_frame.
					staged[staged_n] = in_frame
					staged_n += 1
				} else {
					// Overshot: the held frame owns slot start_frame; the frame
					// already decoded is the one after it.
					staged[0] = held
					staged[1] = in_frame
					staged_n = 2
				}
				break
			}
			if have_held {
				avutil.frame_unref(held)
			}
			_ = avutil.frame_ref(held, in_frame)
			have_held = true
		}
	}

	// --- Encoder ---
	// Hardware encoders first, libx264 as the guaranteed fallback, on the same
	// candidate list the export path uses (hw_encode.odin). A proxy is the case
	// that wants this most: it is the thing standing between an unscrubbable
	// timeline and a usable one, and it is all-intra, which is the shape
	// hardware encode is cheapest on.
	//
	// The two paths differ in rate control rather than in plumbing. libx264
	// keeps the original crf/preset/tune; hardware encoders get a bitrate
	// derived from the proxy's own dimensions, because constant-quality has no
	// single option name across nvenc/vaapi/qsv/amf and inventing one here
	// would be a per-vendor special case for no benefit on a 768x432 preview.
	enc: ^avcodec.CodecContext
	defer if enc != nil {
		avcodec.free_context(&enc)
	}
	enc_sw_pix_fmt := avutil.PixelFormat.YUV420P
	is_x264 := false
	use_hw := false
	enc_codec: ^avcodec.Codec

	names := hw_enc_candidate_names(!proxy_encoder_use_hw())
	opened := false
	for name in names {
		codec := avcodec.find_encoder_by_name(name)
		if codec == nil {
			continue
		}
		ctx := avcodec.alloc_context3(codec)
		if ctx == nil {
			continue
		}
		ctx.width = out_w
		ctx.height = out_h
		ctx.time_base = {num = fps.den, den = fps.num}
		ctx.gop_size = proxy_encoder.gop
		ctx.max_b_frames = 0
		ctx.thread_count = threads
		// Without this flag avcodec_send_frame zeroes frame.duration, so the
		// encoder emits pkt.duration=0 and the mp4 muxer sizes the final stts
		// sample to zero — the last proxy frame becomes unaddressable by pts,
		// which the timeline preview (frame -> pts -> seek) needs. Same defect
		// and fix as the render path.
		ctx.flags += {avcodec.CodecFlag.Frame_Duration}

		if name == "libx264" {
			// x264-private rate-control/tuning knobs, identical to the old argv.
			ctx.pix_fmt = avutil.PixelFormat.YUV420P
			avutil.opt_set(ctx, "preset", proxy_encoder.preset, 0)
			avutil.opt_set(ctx, "tune", proxy_encoder.tune, 0)
			avutil.opt_set(ctx, "crf", proxy_encoder.crf, 0)
			if ret := avcodec.open2(ctx, codec, nil); ret < 0 {
				fmt.printf("[enc] avcodec_open2 (%s): %s\n", string(name), ff_err_str(ret))
				avcodec.free_context(&ctx)
				continue
			}
			enc_sw_pix_fmt = avutil.PixelFormat.YUV420P
			is_x264 = true
		} else {
			ctx.bit_rate = proxy_hw_bitrate(out_w, out_h, f64(fps.num) / f64(fps.den))
			// A hardware encoder is only accepted when a real open succeeds: a
			// name can be registered in this build and still fail without the
			// device behind it, which is the common case on a machine with no
			// hardware encoder at all.
			ok, dev, frames := hw_enc_open(ctx, codec, out_w, out_h)
			if !ok {
				// hw_enc_open releases its own refs on every failure path.
				avcodec.free_context(&ctx)
				continue
			}
			// Drop our copies of the device/frames refs straight away: ctx took
			// its own references in hw_enc_open, and avcodec.free_context
			// releases those with the context. The upload below reads
			// enc.hw_frames_ctx, not these.
			avutil.buffer_unref(&frames)
			avutil.buffer_unref(&dev)
			use_hw = true
			enc_sw_pix_fmt = avutil.PixelFormat.NV12
		}
		enc = ctx
		enc_codec = codec
		opened = true
		break
	}
	if !opened {
		fmt.println("[enc] no H.264 encoder available (hardware and libx264 both failed)")
		return .Fail, 0
	}
	fmt.printf(
		"[enc] proxy encoder: %s%s\n",
		string(enc_codec.name),
		is_x264 ? " (cpu)" : " (hardware)",
	)

	// sws is built lazily from the first decoded frame's actual format: the
	// hw-decode path transfers to a sw frame whose format (NV12, etc.) differs
	// from dec.pix_fmt, and the sw path's dims can differ from the coded size
	// (crop). Mirror the playback decoder's scale_decoded_frame.
	sws_ctx: ^sws.Context
	defer if sws_ctx != nil {
		sws.freeContext(sws_ctx)
	}

	out_frame := avutil.frame_alloc()
	defer avutil.frame_free(&out_frame)
	// The scaler and the encoder must agree on the format. A hardware encoder
	// takes NV12 as its software carrier, so this is the same choice the
	// encoder's frames context declared, not a separate decision.
	out_frame.format = c.int(enc_sw_pix_fmt)
	out_frame.width = out_w
	out_frame.height = out_h
	if avutil.frame_get_buffer(out_frame, 32) < 0 {
		fmt.println("[enc] av_frame_get_buffer failed")
		return .Fail, 0
	}

	// --- Muxer ---
	oc: ^avfmt.FormatContext
	defer avfmt.free_context(oc)
	if ret := avfmt.alloc_output_context2(&oc, nil, "mp4", out_path); ret < 0 {
		fmt.printf("[enc] avformat_alloc_output_context2 %q: %s\n", string(out_path), ff_err_str(ret))
		return .Fail, 0
	}
	if ret := avfmt.open(&oc.pb, out_path, avfmt.IOFlags{.Write}); ret < 0 {
		fmt.printf("[enc] avio_open %q: %s\n", string(out_path), ff_err_str(ret))
		return .Fail, 0
	}
	ost := avfmt.new_stream(oc, enc_codec)
	if ost == nil {
		fmt.println("[enc] avformat_new_stream failed")
		return .Fail, 0
	}
	ost.time_base = enc.time_base
	if ret := avcodec.parameters_from_context(ost.codecpar, enc); ret < 0 {
		fmt.printf("[enc] avcodec_parameters_from_context: %s\n", ff_err_str(ret))
		return .Fail, 0
	}
	ost.codecpar.codec_tag = 0
	if ret := avfmt.write_header(oc, nil); ret < 0 {
		fmt.printf("[enc] avformat_write_header: %s\n", ff_err_str(ret))
		return .Fail, 0
	}

	enc_pkt := avcodec.packet_alloc()
	defer avcodec.packet_free(&enc_pkt)

	done: i64 = 0
	for done < encode_count {
		if done % 32 == 0 && cancelled(ud) {
			return .Cancelled, done
		}
		// Emit any staged opening frames before resuming live decode.
		if staged_n > 0 {
			enc_src := staged[0]
			staged[0], staged[1] = staged[1], nil
			staged_n -= 1
			if !encode_scale_send(
				enc_src, out_frame, &sws_ctx, out_w, out_h, enc_sw_pix_fmt, use_hw, enc, enc_pkt,
				oc, ost, done,
			) {
				return .Fail, done
			}
			done += 1
			on_frames(ud, int(done))
			continue
		}
		switch encode_decode_step(in_fmt, video_idx, dec, in_pkt, in_frame, hw_pix_fmt, enc_sw_frame) {
		case .Error:
			avcodec.packet_unref(enc_pkt)
			return .Fail, done
		case .Eof:
			// Source ran out first: flush and finish; the count carries to the
			// caller's tolerance check.
			done = flush_encoded_packets(enc, enc_pkt, oc, ost, enc.time_base, done)
			if ret := avfmt.write_trailer(oc); ret < 0 {
				return .Fail, done
			}
			avfmt.closep(&oc.pb)
			return .Ok, done
		case .Ok:
		}
		if !encode_scale_send(
			in_frame, out_frame, &sws_ctx, out_w, out_h, enc_sw_pix_fmt, use_hw, enc, enc_pkt,
			oc, ost, done,
		) {
			return .Fail, done
		}
		done += 1
		on_frames(ud, int(done))
	}

	// Flush whatever the encoder still buffered (all-intra makes this a
	// no-op; kept for correctness if settings ever drift).
	done = flush_encoded_packets(enc, enc_pkt, oc, ost, enc.time_base, done)
	if ret := avfmt.write_trailer(oc); ret < 0 {
		fmt.printf("[enc] avformat_write_trailer: %s\n", ff_err_str(ret))
		return .Fail, done
	}
	avfmt.closep(&oc.pb)
	return .Ok, done
}

// encode_scale_send scales one decoded frame to the proxy's encoder-input
// buffer, encodes it, and muxes all drained packets. Returns false on a hard
// libav error (the caller drops the artifact). sws_ctx is built lazily from the
// first frame's real format/dims (hw decode transfers to NV12 etc., which
// dec.pix_fmt doesn't name); `out_w/out_h` are the proxy's fixed output size.
//
// `dst_pix_fmt` is the encoder's software input format — YUV420P for libx264,
// NV12 for a hardware encoder — and must match the format out_frame was
// allocated with, or swscale writes a plane layout the encoder cannot read.
// `use_hw` means hardware encode, and the scaled frame has to make the upload
// into a device surface before the send.
encode_scale_send :: proc(
	src_frame, out_frame: ^avutil.Frame,
	sws_ctx: ^^sws.Context,
	out_w, out_h: c.int,
	dst_pix_fmt: avutil.PixelFormat,
	use_hw: bool,
	enc: ^avcodec.CodecContext,
	enc_pkt: ^avcodec.Packet,
	oc: ^avfmt.FormatContext,
	ost: ^avfmt.Stream,
	done: i64,
) -> bool {
	if sws_ctx^ == nil {
		sws_ctx^ = sws.getContext(
			src_frame.width, src_frame.height, avutil.PixelFormat(src_frame.format),
			out_w, out_h, dst_pix_fmt,
			sws.Flags{.Bilinear}, nil, nil, nil,
		)
		if sws_ctx^ == nil {
			return false
		}
	}
	_ = sws.scale(
		sws_ctx^,
		cast([^][^]u8)&src_frame.data[0],
		cast([^]c.int)&src_frame.linesize[0],
		0, src_frame.height,
		cast([^][^]u8)&out_frame.data[0],
		cast([^]c.int)&out_frame.linesize[0],
	)
	out_frame.pts = done
	out_frame.duration = 1
	to_send := out_frame
	defer if to_send != out_frame {
		avutil.frame_free(&to_send)
	}
	if use_hw {
		// Hardware-surfaces encoder: move the scaled NV12 frame into a device
		// surface before sending. The encoder takes its own references on the
		// surface buffers when it accepts the frame, but our AVFrame wrapper
		// must outlive the send, which the defer above guarantees.
		hw_frame := avutil.frame_alloc()
		if hw_frame == nil {
			return false
		}
		if ret := avutil.hwframe_get_buffer(enc.hw_frames_ctx, hw_frame, 0); ret < 0 {
			avutil.frame_free(&hw_frame)
			fmt.printf("[enc] av_hwframe_get_buffer: %s\n", ff_err_str(ret))
			return false
		}
		if ret := avutil.hwframe_transfer_data(hw_frame, out_frame, 0); ret < 0 {
			avutil.frame_free(&hw_frame)
			fmt.printf("[enc] av_hwframe_transfer_data: %s\n", ff_err_str(ret))
			return false
		}
		hw_frame.pts = out_frame.pts
		hw_frame.duration = out_frame.duration
		to_send = hw_frame
	}
	if send_r := avcodec.send_frame(enc, to_send); send_r < 0 {
		fmt.printf("[enc] avcodec_send_frame: %s\n", ff_err_str(send_r))
		avcodec.packet_unref(enc_pkt)
		return false
	}
	for {
		rc := avcodec.receive_packet(enc, enc_pkt)
		if rc == avutil.AVERROR_EAGAIN || rc == avutil.AVERROR_EOF {
			break
		}
		if rc < 0 {
			fmt.printf("[enc] avcodec_receive_packet error %d\n", rc)
			avcodec.packet_unref(enc_pkt)
			return false
		}
		mux_packet(enc_pkt, oc, ost, enc.time_base)
		avcodec.packet_unref(enc_pkt)
	}
	return true
}

// mux_packet rescales an encoded packet's timestamps into the output stream's
// time base and hands it to the mp4 muxer. interleaved_write_frame owns the
// packet on success, so the caller may unref unconditionally after.
mux_packet :: proc(
	enc_pkt: ^avcodec.Packet,
	oc: ^avfmt.FormatContext,
	ost: ^avfmt.Stream,
	enc_tb: avutil.Rational,
) {
	rescale_q_to_tb :: proc(ts: c.int64_t, from: avutil.Rational, num, den: c.int) -> c.int64_t {
		return avutil.rescale_q(ts, from, avutil.Rational{num = num, den = den})
	}
	enc_pkt.pts = rescale_q_to_tb(enc_pkt.pts, enc_tb, ost.time_base.num, ost.time_base.den)
	enc_pkt.dts = rescale_q_to_tb(enc_pkt.dts, enc_tb, ost.time_base.num, ost.time_base.den)
	// Duration gets the same rescale: without it the final stts sample sizes
	// to the encoder's raw tick (1/256 of a frame period) once libx264 keeps
	// the last frame's duration, so the last proxy frame stays unaddressable.
	enc_pkt.duration = rescale_q_to_tb(enc_pkt.duration, enc_tb, ost.time_base.num, ost.time_base.den)
	enc_pkt.stream_index = ost.index
	if ret := avfmt.interleaved_write_frame(oc, enc_pkt); ret < 0 {
		fmt.printf("[enc] av_interleaved_write_frame: %s\n", ff_err_str(ret))
	}
}

// flush_encoded_packets drains the encoder's remaining output after the final
// send (or a trailing send_frame(nil)) until EAGAIN/EOF, muxing each packet.
// Returns the resulting running done count (packets flushed do not add to it
// since the frames they carry were already counted when sent).
//
// NEVER DRAIN AN ENCODER THAT WAS NEVER FED, which is what `done == 0` means.
//
// send_frame(nil) is the drain signal, and for a hardware encoder it is not a
// no-op on an encoder with no input history: h264_vaapi dereferences surface
// and rate-control state that only exists after the first real frame, and the
// process dies inside libavcodec with no way to catch it. Reproduced on a still
// image, which probes as a one-frame mjpeg video stream, so every "is this
// video?" test says yes and the scheduler posted a background H.264 build for
// it: the encode loop never reached a send, then the EOF branch drained, and
// h264_vaapi segfaulted.
//
// The image guard upstream (import_bg_request refuses a still) is the fix for
// that path; this is the invariant that keeps the crash out of every OTHER way
// of producing zero frames -- a truncated source, a segment whose frames were
// all skipped, a source whose first decode step reports EOF.
flush_encoded_packets :: proc(
	enc: ^avcodec.CodecContext,
	enc_pkt: ^avcodec.Packet,
	oc: ^avfmt.FormatContext,
	ost: ^avfmt.Stream,
	enc_tb: avutil.Rational,
	done: i64,
) -> i64 {
	if done == 0 {
		return 0
	}
	_ = avcodec.send_frame(enc, nil)
	for {
		rc := avcodec.receive_packet(enc, enc_pkt)
		if rc == avutil.AVERROR_EAGAIN || rc == avutil.AVERROR_EOF {
			break
		}
		if rc < 0 {
			break
		}
		mux_packet(enc_pkt, oc, ost, enc_tb)
		avcodec.packet_unref(enc_pkt)
	}
	return done
}