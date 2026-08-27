package main

import "core:c"
import "core:fmt"
import "core:strings"
import avcodec "vendor/ffmpeg/avcodec"
import avfmt "vendor/ffmpeg/avformat"
import avutil "vendor/ffmpeg/avutil"
import swres "vendor/ffmpeg/swresample"
import sdl "vendor:sdl3"

// AUDIO_CHUNK is the number of output sample-frames decoded in one step.
AUDIO_CHUNK :: 4096
// AUDIO_MAX_CH yields a generous fixed scratch buffer for interleaved S16.
AUDIO_MAX_CH :: 8
// AUDIO_AHEAD_SEC keeps the SDL audio stream this many seconds ahead of the
// playhead so playback stays buffered and glitch-free.
AUDIO_AHEAD_SEC :: 0.15

// Audio_Clip_Decoder decodes one audio stream of a media file and converts it
// to interleaved signed-16 PCM at the stream's native rate/channel count. The
// SDL audio stream handles final rate/channel conversion to the device.
Audio_Clip_Decoder :: struct {
	opened:  bool,
	fmt_ctx: ^avfmt.FormatContext,
	dec_ctx: ^avcodec.CodecContext,
	audio_idx: c.int,
	stream: ^avfmt.Stream,
	swr_ctx: ^swres.Context,

	frame: ^avutil.Frame,
	pkt:   ^avcodec.Packet,

	out_rate: c.int,
	out_channels: c.int,
	// last_ts is the stream timestamp of the last decoded frame.
	last_ts: i64,
	have_last: bool,

	// Interleaved S16 scratch written by swr for one chunk.
	s16: []i16,
}

audio_decoder_reset :: proc(dec: ^Audio_Clip_Decoder) {
	if dec.opened {
		avfmt.close_input(&dec.fmt_ctx)
		avcodec.free_context(&dec.dec_ctx)
		swres.free(&dec.swr_ctx)
		avutil.frame_free(&dec.frame)
		avcodec.packet_free(&dec.pkt)
	}
	if dec.s16 != nil {
		delete(dec.s16)
	}
	dec^ = {}
}

// open_audio_decoder opens the audio stream at stream_index for decoding.
open_audio_decoder :: proc(dec: ^Audio_Clip_Decoder, path: cstring, stream_index: c.int) -> bool {
	audio_decoder_reset(dec)

	fmt_ctx: ^avfmt.FormatContext
	if ret := avfmt.open_input(&fmt_ctx, path, nil, nil); ret < 0 {
		fmt.println("avformat_open_input (audio):", ff_err_str(ret))
		return false
	}
	dec.fmt_ctx = fmt_ctx
	if ret := avfmt.find_stream_info(fmt_ctx, nil); ret < 0 {
		fmt.println("avformat_find_stream_info (audio):", ff_err_str(ret))
		return false
	}
	idx: c.int = -1
	audio_seen := c.int(0)
	for i in 0 ..< int(fmt_ctx.nb_streams) {
		s := fmt_ctx.streams[i]
		if s == nil || s.codecpar == nil {
			continue
		}
		if s.codecpar.codec_type != avutil.MediaType.Audio {
			continue
		}
		if audio_seen == stream_index {
			idx = c.int(i)
			break
		}
		audio_seen += 1
	}
	if idx < 0 {
		fmt.println("audio stream index out of range")
		return false
	}
	stream := fmt_ctx.streams[idx]
	if stream == nil || stream.codecpar == nil || stream.codecpar.codec_type != avutil.MediaType.Audio {
		fmt.println("selected stream is not audio")
		return false
	}
	dec.audio_idx = idx
	dec.stream = stream

	par := stream.codecpar
	codec := avcodec.find_decoder(par.codec_id)
	if codec == nil {
		fmt.println("no decoder for audio codec", avcodec.get_name(par.codec_id))
		return false
	}
	dec_ctx := avcodec.alloc_context3(codec)
	if dec_ctx == nil {
		fmt.println("avcodec_alloc_context3 (audio) failed")
		return false
	}
	dec.dec_ctx = dec_ctx
	if ret := avcodec.parameters_to_context(dec_ctx, par); ret < 0 {
		fmt.println("avcodec_parameters_to_context (audio):", ff_err_str(ret))
		return false
	}
	if ret := avcodec.open2(dec_ctx, codec, nil); ret < 0 {
		fmt.println("avcodec_open2 (audio):", ff_err_str(ret))
		return false
	}

	dec.out_rate = dec_ctx.sample_rate
	dec.out_channels = dec_ctx.ch_layout.nb_channels
	if dec.out_channels < 1 {
		dec.out_channels = 1
	}

	swr_ctx := swres.alloc()
	if swr_ctx == nil {
		fmt.println("swr_alloc failed")
		return false
	}
	dec.swr_ctx = swr_ctx
	if ret := swres.alloc_set_opts2(
		&dec.swr_ctx,
		&dec_ctx.ch_layout, avutil.SampleFormat.S16, dec_ctx.sample_rate,
		&dec_ctx.ch_layout, dec_ctx.sample_fmt, dec_ctx.sample_rate,
		0, nil,
	); ret < 0 {
		fmt.println("swr_alloc_set_opts2:", ff_err_str(ret), dec_ctx.ch_layout.nb_channels, dec_ctx.sample_rate)
		return false
	}
	if ret := swres.init(dec.swr_ctx); ret < 0 {
		fmt.println("swr_init:", ff_err_str(ret))
		return false
	}

	dec.frame = avutil.frame_alloc()
	dec.pkt = avcodec.packet_alloc()
	dec.s16 = make([]i16, AUDIO_CHUNK * AUDIO_MAX_CH)
	dec.opened = true
	fmt.printf("audio %dch @ %d Hz -> S16\n", dec.out_channels, dec.out_rate)
	return true
}

// audio_to_stream_ts converts a timeline position (seconds) to the audio
// stream's time base.
audio_to_stream_ts :: proc(dec: ^Audio_Clip_Decoder, seconds: f64) -> c.int64_t {
	s := seconds
	if s < 0 {
		s = 0
	}
	return avutil.rescale_q(
		c.int64_t(s * 1_000_000),
		avutil.Rational{num = 1, den = 1_000_000},
		dec.stream.time_base,
	)
}

// seek_audio seeks the input to (at or before) the given timeline seconds.
seek_audio :: proc(dec: ^Audio_Clip_Decoder, seconds: f64) -> bool {
	ts := audio_to_stream_ts(dec, seconds)
	if ret := avfmt.seek_frame(dec.fmt_ctx, dec.audio_idx, ts, avfmt.SeekFlags{.Backward}); ret < 0 {
		fmt.println("av_seek_frame (audio):", ff_err_str(ret))
		return false
	}
	avcodec.flush_buffers(dec.dec_ctx)
	dec.have_last = false
	return true
}

// decode_audio_chunk decodes up to AUDIO_CHUNK output sample-frames starting at
// the given timeline seconds. Returns the number of frames written to dec.s16
// (interleaved S16, dec.out_channels per frame), or 0 on failure/EOF. The
// decoder stays sequential; requesting a position behind the last decode
// triggers a re-seek.
decode_audio_chunk :: proc(dec: ^Audio_Clip_Decoder, at_seconds: f64) -> int {
	if !dec.opened {
		return 0
	}
	target_ts := audio_to_stream_ts(dec, at_seconds)
	if dec.have_last && target_ts < dec.last_ts {
		if !seek_audio(dec, at_seconds) {
			return 0
		}
	}
	out_planes: [1][^]u8
	out_count := c.int(AUDIO_CHUNK)
	produced := 0
	for produced < int(AUDIO_CHUNK) {
		ret := avfmt.read_frame(dec.fmt_ctx, dec.pkt)
		if ret < 0 {
			break
		}
		if dec.pkt.stream_index != dec.audio_idx {
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
				return produced
			}
			in_planes: [8][^]u8
			for i in 0..<8 {
				in_planes[i] = dec.frame.data[i]
			}
			out_planes[0] = ([^]u8)(raw_data(dec.s16))[produced * int(dec.out_channels) * size_of(i16):]
			n := swres.convert(
				dec.swr_ctx,
				&out_planes[0], out_count - c.int(produced),
				&in_planes[0], dec.frame.nb_samples,
			)
			frame_ts_at_decode := dec.frame.best_effort_timestamp
			avutil.frame_unref(dec.frame)
			if n <= 0 {
				return produced
			}
			dec.last_ts = frame_ts_at_decode
			dec.have_last = true
			produced += int(n)
			if produced >= int(AUDIO_CHUNK) {
				break
			}
		}
		if produced >= int(AUDIO_CHUNK) {
			break
		}
	}
	return produced
}

// ---------------------------------------------------------------------------
// Audio player: SDL3 device + stream fed with decoded S16 PCM.
// ---------------------------------------------------------------------------

audio_device: sdl.AudioDeviceID
audio_device_spec: sdl.AudioSpec
audio_device_ready: bool

audio_stream: ^sdl.AudioStream
audio_decoder: Audio_Clip_Decoder
audio_path: cstring
audio_stream_index: c.int
audio_pushed_sec: f64
audio_was_playing: bool

audio_init :: proc() -> bool {
	spec := sdl.AudioSpec{format = .S16, channels = 2, freq = 48000}
	dev := sdl.OpenAudioDevice(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec)
	if dev == 0 {
		fmt.println("OpenAudioDevice failed:", sdl.GetError())
		return false
	}
	device_spec: sdl.AudioSpec
	sample_frames: c.int
	if !sdl.GetAudioDeviceFormat(dev, &device_spec, &sample_frames) {
		fmt.println("GetAudioDeviceFormat failed:", sdl.GetError())
		sdl.CloseAudioDevice(dev)
		return false
	}
	audio_device = dev
	audio_device_spec = device_spec
	audio_device_ready = true
	fmt.printf("audio device ready (%d Hz, %dch, fmt %d)\n", device_spec.freq, device_spec.channels, device_spec.format)
	sdl.PauseAudioDevice(dev)
	return true
}

audio_shutdown :: proc() {
	if audio_stream != nil {
		sdl.DestroyAudioStream(audio_stream)
		audio_stream = nil
	}
	audio_decoder_reset(&audio_decoder)
	if audio_device_ready {
		sdl.CloseAudioDevice(audio_device)
		audio_device_ready = false
	}
}

// timeline_audio_clip_at returns the first audio clip covering the given
// timeline frame, or nil.
timeline_audio_clip_at :: proc(frame: i64) -> ^Clip {
	for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
		track := &timeline.tracks[track_idx]
		for i := 0; i < len(track.clips); i += 1 {
			clip := &track.clips[i]
			if clip.kind != .Audio {
				continue
			}
			if frame >= clip.timeline_start_frame && frame < clip.timeline_start_frame + clip.source_length_frames {
				return clip
			}
		}
	}
	return nil
}

// audio_content_sec returns the position inside a clip's source (in seconds)
// for the given timeline frame, i.e. timeline position minus the clip's own
// start. This is what the audio decoder seeks/feeds by, so moving a clip on
// the timeline shifts when its content plays instead of seeking into the file
// by absolute timeline time.
audio_content_sec :: proc(clip: ^Clip, frame: i64) -> f64 {
	if clip == nil {
		return 0
	}
	return f64(frame - clip.timeline_start_frame) / 60.0
}

// audio_sync_decoder ensures the decoder+stream are bound to the active audio
// clip and seeked to the given content seconds. Returns false if no audio is
// active.
audio_sync_decoder :: proc(clip: ^Clip, content_sec: f64) -> bool {
	if clip == nil {
		return false
	}
	if audio_path != clip.path || audio_stream_index != clip.stream_index || !audio_decoder.opened {
		// (Re)open the decoder for this clip's audio stream.
		if !open_audio_decoder(&audio_decoder, clip.path, clip.stream_index) {
			return false
		}
		audio_path = clip.path
		audio_stream_index = clip.stream_index
		// Recreate the SDL stream configured for this clip's output format.
		if audio_stream != nil {
			sdl.DestroyAudioStream(audio_stream)
			audio_stream = nil
		}
		src_spec := sdl.AudioSpec{format = .S16, channels = c.int(audio_decoder.out_channels), freq = audio_decoder.out_rate}
		audio_stream = sdl.CreateAudioStream(&src_spec, &audio_device_spec)
		if audio_stream == nil {
			fmt.println("CreateAudioStream failed:", sdl.GetError())
			return false
		}
		if !sdl.BindAudioStream(audio_device, audio_stream) {
			fmt.println("BindAudioStream failed:", sdl.GetError())
			return false
		}
		if !seek_audio(&audio_decoder, content_sec) {
			return false
		}
		audio_pushed_sec = content_sec
	}
	return true
}

// audio_resync clears any queued audio and re-positions the decoder at the
// current playhead. Call on play start, seek, and load. Unlike audio_feed, it
// always forces a seek (even if the decoder is already open for this clip),
// so moving the playhead within the same clip re-positions correctly.
audio_resync :: proc() {
	clip := timeline_audio_clip_at(playhead.frame)
	if audio_stream != nil {
		sdl.ClearAudioStream(audio_stream)
		sdl.FlushAudioStream(audio_stream)
	}
	if clip == nil {
		return
	}
	content_sec := audio_content_sec(clip, playhead.frame)
	if !audio_sync_decoder(clip, content_sec) {
		return
	}
	if !seek_audio(&audio_decoder, content_sec) {
		return
	}
	audio_pushed_sec = content_sec
}

// audio_reset_for_load clears all audio state when a new file is imported.
audio_reset_for_load :: proc() {
	if audio_stream != nil {
		sdl.ClearAudioStream(audio_stream)
		sdl.FlushAudioStream(audio_stream)
	}
	audio_decoder_reset(&audio_decoder)
	audio_path = nil
	audio_stream_index = 0
	audio_pushed_sec = 0
	audio_was_playing = false
}

// audio_feed keeps the SDL stream populated with PCM ahead of the playhead.
// Called once per frame while playing.
audio_feed :: proc() {
	if !audio_device_ready {
		return
	}
	clip := timeline_audio_clip_at(playhead.frame)
	if clip == nil {
		return
	}
	if !audio_sync_decoder(clip, audio_content_sec(clip, playhead.frame)) {
		return
	}
	if audio_stream == nil {
		return
	}
	// Backpressure: don't push past ~0.4s of queued audio.
	max_queue := c.int(f64(audio_decoder.out_rate) * 0.4 * f64(audio_decoder.out_channels) * 2.0)
	if sdl.GetAudioStreamQueued(audio_stream) >= max_queue {
		return
	}
	content_sec := audio_content_sec(clip, playhead.frame)
	target := content_sec + AUDIO_AHEAD_SEC
	for audio_pushed_sec < target {
		n := decode_audio_chunk(&audio_decoder, audio_pushed_sec)
		if n <= 0 {
			break
		}
		bytes := n * int(audio_decoder.out_channels) * size_of(i16)
		sdl.PutAudioStreamData(audio_stream, raw_data(audio_decoder.s16[:bytes]), c.int(bytes))
		audio_pushed_sec += f64(n) / f64(audio_decoder.out_rate)
		if sdl.GetAudioStreamQueued(audio_stream) >= max_queue {
			break
		}
	}
}

// Called by the main loop each frame; handles play/pause + resync.
audio_update :: proc() {
	if !audio_device_ready {
		return
	}
	if playhead.playing {
		sdl.ResumeAudioDevice(audio_device)
		if !audio_was_playing {
			audio_was_playing = true
			audio_resync()
			return
		}
		// Catch-up safety if audio fell far behind the playhead. Compare in
		// clip-content space (audio_pushed_sec tracks clip content).
		clip := timeline_audio_clip_at(playhead.frame)
		if clip != nil {
			content_sec := audio_content_sec(clip, playhead.frame)
			if audio_pushed_sec > 0 && content_sec - audio_pushed_sec > 0.35 {
				audio_resync()
				return
			}
			audio_feed()
		} else if audio_stream != nil {
			// Playhead is in a gap between audio clips: stop any queued audio.
			sdl.ClearAudioStream(audio_stream)
			sdl.FlushAudioStream(audio_stream)
			audio_pushed_sec = 0
		}
	} else {
		sdl.PauseAudioDevice(audio_device)
		audio_was_playing = false
	}
}
