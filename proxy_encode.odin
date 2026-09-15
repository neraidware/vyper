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
		if vyper_trace {
			fmt.printf("[enc] avformat_open_input %q: %s\n", string(src), ff_err_str(ret))
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

	codec := avcodec.find_decoder(par.codec_id)
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
	if ret := avcodec.open2(dec, codec, nil); ret < 0 {
		fmt.printf("[enc] avcodec_open2 (decoder): %s\n", ff_err_str(ret))
		return .Fail, 0
	}
	src_w, src_h := dec.width, dec.height

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
			step := encode_decode_step(in_fmt, video_idx, dec, in_pkt, in_frame)
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
	enc_codec := avcodec.find_encoder_by_name("libx264")
	is_x264 := enc_codec != nil
	if enc_codec == nil {
		enc_codec = avcodec.find_encoder(avcodec.CodecID.H264)
	}
	if enc_codec == nil {
		fmt.println("[enc] no H.264 encoder available")
		return .Fail, 0
	}
	enc := avcodec.alloc_context3(enc_codec)
	defer avcodec.free_context(&enc)
	enc.width = out_w
	enc.height = out_h
	enc.pix_fmt = avutil.PixelFormat.YUV420P
	enc.time_base = {num = fps.den, den = fps.num}
	enc.gop_size = 1
	enc.max_b_frames = 0
	enc.thread_count = threads
	if is_x264 {
		// x264-private rate-control/tuning knobs, identical to the old argv.
		avutil.opt_set(enc, "preset", "ultrafast", 0)
		avutil.opt_set(enc, "tune", "fastdecode", 0)
		avutil.opt_set(enc, "crf", "26", 0)
	}
	if ret := avcodec.open2(enc, enc_codec, nil); ret < 0 {
		fmt.printf("[enc] avcodec_open2 (encoder): %s\n", ff_err_str(ret))
		return .Fail, 0
	}

	sws_ctx := sws.getContext(
		src_w, src_h, dec.pix_fmt,
		out_w, out_h, avutil.PixelFormat.YUV420P,
		sws.Flags{.Bilinear}, nil, nil, nil,
	)
	if sws_ctx == nil {
		fmt.println("[enc] sws_getContext failed")
		return .Fail, 0
	}
	defer sws.freeContext(sws_ctx)

	out_frame := avutil.frame_alloc()
	defer avutil.frame_free(&out_frame)
	out_frame.format = c.int(avutil.PixelFormat.YUV420P)
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
			if !encode_scale_send(enc_src, out_frame, sws_ctx, enc, enc_pkt, oc, ost, done) {
				return .Fail, done
			}
			done += 1
			on_frames(ud, int(done))
			continue
		}
		switch encode_decode_step(in_fmt, video_idx, dec, in_pkt, in_frame) {
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
		if !encode_scale_send(in_frame, out_frame, sws_ctx, enc, enc_pkt, oc, ost, done) {
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

// encode_scale_send scales one decoded frame to the proxy's yuv420p buffer,
// encodes it, and muxes all drained packets. Returns false on a hard libav
// error (the caller drops the artifact).
encode_scale_send :: proc(
	src_frame, out_frame: ^avutil.Frame,
	sws_ctx: ^sws.Context,
	enc: ^avcodec.CodecContext,
	enc_pkt: ^avcodec.Packet,
	oc: ^avfmt.FormatContext,
	ost: ^avfmt.Stream,
	done: i64,
) -> bool {
	_ = sws.scale(
		sws_ctx,
		cast([^][^]u8)&src_frame.data[0],
		cast([^]c.int)&src_frame.linesize[0],
		0, src_frame.height,
		cast([^][^]u8)&out_frame.data[0],
		cast([^]c.int)&out_frame.linesize[0],
	)
	out_frame.pts = done
	if send_r := avcodec.send_frame(enc, out_frame); send_r < 0 {
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
	enc_pkt.stream_index = ost.index
	if ret := avfmt.interleaved_write_frame(oc, enc_pkt); ret < 0 {
		fmt.printf("[enc] av_interleaved_write_frame: %s\n", ff_err_str(ret))
	}
}

// flush_encoded_packets drains the encoder's remaining output after the final
// send (or a trailing send_frame(nil)) until EAGAIN/EOF, muxing each packet.
// Returns the resulting running done count (packets flushed do not add to it
// since the frames they carry were already counted when sent).
flush_encoded_packets :: proc(
	enc: ^avcodec.CodecContext,
	enc_pkt: ^avcodec.Packet,
	oc: ^avfmt.FormatContext,
	ost: ^avfmt.Stream,
	enc_tb: avutil.Rational,
	done: i64,
) -> i64 {
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