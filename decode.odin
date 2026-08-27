package main

import "core:c"
import "core:fmt"
import "core:strings"
import avcodec "vendor/ffmpeg/avcodec"
import avfmt "vendor/ffmpeg/avformat"
import avutil "vendor/ffmpeg/avutil"
import sws "vendor/ffmpeg/swscale"

// Clip_Decoder wraps one open FFmpeg input + decoder + scaler. It keeps the
// source file open across calls so sequential playback decodes forward without
// re-seeking; a jump to a non-consecutive frame triggers a keyframe seek.
//
// TODO(per TODO.md): promote this to a per-asset decoder cache with a bounded
// rolling frame pool once real-time multi-track composition lands.
Clip_Decoder :: struct {
	opened:      bool,
	fmt_ctx:     ^avfmt.FormatContext,
	dec_ctx:     ^avcodec.CodecContext,
	video_idx:   c.int,
	stream:      ^avfmt.Stream,
	sws_ctx:     ^sws.Context,
	src_w, src_h: c.int,
	fps_num:     c.int,
	fps_den:     c.int,
	// Decoder owns these allocations.
	frame:       ^avutil.Frame,
	pkt:         ^avcodec.Packet,
	// dst is the fixed-size RGBA console buffer written by sws.
	dst:          [4][^]u8,
	dst_linesize: [4]c.int,
	dst_w, dst_h: c.int,
	// Index of the source frame last handed out. Requests for
	// last_frame+1 continue forward; anything else re-seeks.
	last_frame:   i64,
	have_last:    bool,
	// decoded_ahead counts frames received since the last seek, so a
	// forward request knows it only needs to pull the next frame.
	decoded_ahead: i64,
	// Bounded RAM cache of decoded frames (RGBA, tightly packed). Keeps the
	// decoded frame data resident in memory and avoids re-decoding recent
	// frames when the playhead moves back a little. Evicts oldest on write.
	cache:         [dynamic]Frame_Cache_Entry,
}

// Frame_Cache_Entry is one cached decoded RGBA frame plus a use counter for
// simple MRU eviction. Pixel data lives in a separate heap buffer so the
// header stays small (no 1.3MB by-value copies).
Frame_Cache_Entry :: struct {
	frame:  i64,
	uses:   u64,
	data:   []u8,
}

frame_cache_clear :: proc(dec: ^Clip_Decoder) {
	for &e in dec.cache {
		delete(e.data)
	}
	clear(&dec.cache)
}

ff_err_str :: proc(code: c.int) -> string {
	buf: [avutil.AV_ERROR_MAX_STRING_SIZE]c.char
	avutil.strerror(code, &buf[0], size_of(buf))
	return strings.clone_from_cstring(cstring(&buf[0]), context.temp_allocator)
}

clip_decoder_reset :: proc(dec: ^Clip_Decoder) {
	if dec.opened {
		avfmt.close_input(&dec.fmt_ctx)
		avcodec.free_context(&dec.dec_ctx)
		sws.freeContext(dec.sws_ctx)
		avutil.frame_free(&dec.frame)
		avcodec.packet_free(&dec.pkt)
	}
	frame_cache_clear(dec)
	dec^ = {}
}

FRAME_CACHE_CAPACITY :: 24

// cache_find returns the cached RGBA data for a frame, or nil.
cache_find :: proc(dec: ^Clip_Decoder, frame_idx: i64) -> []u8 {
	for i := 0; i < len(dec.cache); i += 1 {
		if dec.cache[i].frame == frame_idx {
			dec.cache[i].uses += 1
			return dec.cache[i].data
		}
	}
	return nil
}

// cache_store inserts/updates a cached frame, evicting the least-used entry
// (freeing its buffer) when at capacity.
cache_store :: proc(dec: ^Clip_Decoder, frame_idx: i64, data: []u8) {
	if frame_idx < 0 {
		return
	}
	for i := 0; i < len(dec.cache); i += 1 {
		if dec.cache[i].frame == frame_idx {
			copy(dec.cache[i].data, data)
			dec.cache[i].uses += 1
			return
		}
	}
	if len(dec.cache) < FRAME_CACHE_CAPACITY {
		buf := make([]u8, PREVIEW_W * PREVIEW_H * 4)
		copy(buf, data)
		append(&dec.cache, Frame_Cache_Entry{frame = frame_idx, uses = 1, data = buf})
		return
	}
	// Evict least recently used, reusing its buffer.
	evict := 0
	lowest := dec.cache[0].uses
	for i := 1; i < len(dec.cache); i += 1 {
		if dec.cache[i].uses < lowest {
			lowest = dec.cache[i].uses
			evict = i
		}
	}
	copy(dec.cache[evict].data, data)
	dec.cache[evict].frame = frame_idx
	dec.cache[evict].uses = 1
}

open_clip_decoder :: proc(dec: ^Clip_Decoder, path: cstring) -> bool {
	if dec.opened {
		clip_decoder_reset(dec)
	}
	dec.dst_w = PREVIEW_W
	dec.dst_h = PREVIEW_H

	fmt_ctx: ^avfmt.FormatContext
	if ret := avfmt.open_input(&fmt_ctx, path, nil, nil); ret < 0 {
		fmt.println("avformat_open_input:", ff_err_str(ret))
		return false
	}
	dec.fmt_ctx = fmt_ctx
	if ret := avfmt.find_stream_info(fmt_ctx, nil); ret < 0 {
		fmt.println("avformat_find_stream_info:", ff_err_str(ret))
		return false
	}
	idx := avfmt.find_best_stream(fmt_ctx, .Video, -1, -1, nil, 0)
	if idx < 0 {
		fmt.println("no video stream:", ff_err_str(idx))
		return false
	}
	dec.video_idx = idx
	dec.stream = fmt_ctx.streams[idx]

	par := dec.stream.codecpar
	codec := avcodec.find_decoder(par.codec_id)
	if codec == nil {
		fmt.println("no decoder for codec", avcodec.get_name(par.codec_id))
		return false
	}
	dec_ctx := avcodec.alloc_context3(codec)
	if dec_ctx == nil {
		fmt.println("avcodec_alloc_context3 failed")
		return false
	}
	dec.dec_ctx = dec_ctx
	if ret := avcodec.parameters_to_context(dec_ctx, par); ret < 0 {
		fmt.println("avcodec_parameters_to_context:", ff_err_str(ret))
		return false
	}
	if ret := avcodec.open2(dec_ctx, codec, nil); ret < 0 {
		fmt.println("avcodec_open2:", ff_err_str(ret))
		return false
	}
	dec.src_w = dec_ctx.width
	dec.src_h = dec_ctx.height

	fps := dec.stream.avg_frame_rate
	if fps.num <= 0 || fps.den <= 0 {
		fps = dec.stream.r_frame_rate
	}
	if fps.num <= 0 || fps.den <= 0 {
		fps = {25, 1}
	}
	dec.fps_num = fps.num
	dec.fps_den = fps.den

	dec.sws_ctx = sws.getContext(
		dec.src_w, dec.src_h, dec_ctx.pix_fmt,
		dec.dst_w, dec.dst_h, avutil.PixelFormat.RGBA,
		sws.Flags{.Bilinear}, nil, nil, nil,
	)
	if dec.sws_ctx == nil {
		fmt.println("sws_getContext failed")
		return false
	}
	if avutil.image_alloc(&dec.dst[0], &dec.dst_linesize[0], dec.dst_w, dec.dst_h, avutil.PixelFormat.RGBA, 1) < 0 {
		fmt.println("av_image_alloc failed")
		return false
	}
	dec.frame = avutil.frame_alloc()
	dec.pkt = avcodec.packet_alloc()
	dec.opened = true
	fmt.printf("decoded %dx%d (%dx%d) @ %d/%d fps\n", dec.src_w, dec.src_h, dec.dst_w, dec.dst_h, dec.fps_num, dec.fps_den)
	return true
}

// seek_to_source_frame seeks the input to the keyframe at/before the given
// source frame index so a subsequent forward decode reaches the target.
seek_to_source_frame :: proc(dec: ^Clip_Decoder, frame_idx: i64) -> bool {
	// Convert frame index to a timestamp in the stream time base.
	ts := frames_to_stream_ts(dec, frame_idx)
	// Seek just before the target keyframe boundary.
	if ret := avfmt.seek_frame(dec.fmt_ctx, dec.video_idx, ts, avfmt.SeekFlags{.Backward}); ret < 0 {
		fmt.println("av_seek_frame:", ff_err_str(ret))
		return false
	}
	avcodec.flush_buffers(dec.dec_ctx)
	dec.decoded_ahead = 0
	return true
}

// frames_to_stream_ts converts a frame index to the stream time base using the
// source average frame rate.
frames_to_stream_ts :: proc(dec: ^Clip_Decoder, frame_idx: i64) -> c.int64_t {
	return avutil.rescale_q(
		c.int64_t(frame_idx),
		avutil.Rational{num = dec.fps_den, den = dec.fps_num},
		dec.stream.time_base,
	)
}

// decode_one_forward pulls exactly one decoded video frame. Returns true when a
// frame was produced. Uses dec.video_idx and skips other packets.
decode_one_forward :: proc(dec: ^Clip_Decoder) -> bool {
	for {
		ret := avfmt.read_frame(dec.fmt_ctx, dec.pkt)
		if ret < 0 {
			return false
		}
		if dec.pkt.stream_index != c.int(dec.video_idx) {
			avcodec.packet_unref(dec.pkt)
			continue
		}
		if r := avcodec.send_packet(dec.dec_ctx, dec.pkt); r < 0 {
			avcodec.packet_unref(dec.pkt)
			continue
		}
		avcodec.packet_unref(dec.pkt)
		for {
			r := avcodec.receive_frame(dec.dec_ctx, dec.frame)
			if r == avutil.AVERROR_EAGAIN || r == avutil.AVERROR_EOF {
				break
			}
			if r < 0 {
				return false
			}
			dec.decoded_ahead += 1
			return true
		}
	}
}

// decode_source_frame decodes the given source frame index into the decoder's
// internal RGBA dst buffer. Returns true on success. The caller may read it via
// decode_into_buffer() after a successful call. Forward-sequential requests
// decode the next frame without seeking; anything else re-seeks to the
// keyframe before the target and decodes forward.
decode_source_frame :: proc(dec: ^Clip_Decoder, frame_idx: i64) -> bool {
	if !dec.opened {
		return false
	}
	// Consecutive forward request: just decode the next frame in place.
	if dec.have_last && frame_idx == dec.last_frame + 1 {
		if !decode_one_forward(dec) {
			return false
		}
		dec.last_frame = frame_idx
		dec.have_last = true
		scale_decoded_frame(dec)
		return true
	}
	// Discontiguous: re-seek to the keyframe before the target, then decode
	// forward until a frame at/after the target timestamp is produced.
	if !seek_to_source_frame(dec, frame_idx) {
		return false
	}
	target := frames_to_stream_ts(dec, frame_idx)
	for {
		if !decode_one_forward(dec) {
			return false
		}
		if dec.frame.best_effort_timestamp >= target {
			dec.last_frame = frame_idx
			dec.have_last = true
			scale_decoded_frame(dec)
			return true
		}
	}
}

scale_decoded_frame :: proc(dec: ^Clip_Decoder) {
	sws.scale(
		dec.sws_ctx,
		cast([^][^]u8)&dec.frame.data[0],
		cast([^]c.int)&dec.frame.linesize[0],
		0, dec.frame.height,
		cast([^][^]u8)&dec.dst[0],
		cast([^]c.int)&dec.dst_linesize[0],
	)
	avutil.frame_unref(dec.frame)
}

// frame_data returns a slice of the decoder's RGBA output buffer, row-aligned.
frame_data :: proc(dec: ^Clip_Decoder) -> []u8 {
	stride := dec.dst_linesize[0]
	if stride <= 0 {
		return nil
	}
	return dec.dst[0][:uint(stride) * uint(dec.dst_h)]
}

// decode_into_buffer fills a caller-provided tightly-packed RGBA buffer
// (w*h*4 bytes) with the decoded frame's pixels, stripping any row padding.
decode_into_buffer :: proc(dec: ^Clip_Decoder, out: []u8, w, h: c.int) {
	stride := dec.dst_linesize[0]
	if stride <= 0 {
		return
	}
	row_bytes := int(w) * 4
	for row in 0 ..< int(h) {
		src := dec.dst[0][uint(row) * uint(stride):][:uint(row_bytes)]
		copy(out[uint(row) * uint(row_bytes):][:uint(row_bytes)], src)
	}
	return
}

// Stream_Probe holds the stream layout of an imported media file.
Stream_Probe :: struct {
	video_streams: int,
	audio_streams: int,
	duration_sec:  f64,
	has_video:     bool,
	has_audio:     bool,
}

// probe_streams opens a file in-process with avformat and counts video and
// audio streams and reports duration. Used at import to build video and audio
// timeline tracks without relying on an external ffprobe subprocess.
probe_streams :: proc(path: cstring) -> Stream_Probe {
	probe: Stream_Probe
	fmt_ctx: ^avfmt.FormatContext
	if ret := avfmt.open_input(&fmt_ctx, path, nil, nil); ret < 0 {
		fmt.println("avformat_open_input (probe):", ff_err_str(ret))
		return probe
	}
	defer avfmt.close_input(&fmt_ctx)
	if ret := avfmt.find_stream_info(fmt_ctx, nil); ret < 0 {
		fmt.println("avformat_find_stream_info (probe):", ff_err_str(ret))
		return probe
	}
	probe.duration_sec = f64(fmt_ctx.duration) / 1_000_000
	for i in 0 ..< int(fmt_ctx.nb_streams) {
		stream := fmt_ctx.streams[i]
		if stream == nil {
			continue
		}
		if stream.codecpar == nil {
			continue
		}
		#partial switch stream.codecpar.codec_type {
		case avutil.MediaType.Video:
			probe.video_streams += 1
			probe.has_video = true
		case avutil.MediaType.Audio:
			probe.audio_streams += 1
			probe.has_audio = true
		case:
		}
	}
	return probe
}
