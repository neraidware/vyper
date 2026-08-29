package main

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import avcodec "vendor/ffmpeg/avcodec"
import avfmt "vendor/ffmpeg/avformat"
import avutil "vendor/ffmpeg/avutil"
import swres "vendor/ffmpeg/swresample"
import sdl "vendor:sdl3"

// AUDIO_CHUNK is the number of output sample-frames decoded in one step.
AUDIO_CHUNK :: 4096
// AUDIO_MAX_CH yields a generous fixed scratch buffer for interleaved S16.
AUDIO_MAX_CH :: 8

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

// open_audio_decoder opens the audio stream at stream_index for decoding,
// converting to S16 PCM at the stream's native rate/channel count (playback).
open_audio_decoder :: proc(dec: ^Audio_Clip_Decoder, path: cstring, stream_index: c.int) -> bool {
	return open_audio_decoder_resampled(dec, path, stream_index, -1, -1)
}

// open_audio_decoder_resampled opens the audio stream at stream_index and
// converts it to interleaved S16 PCM at the given output rate/channels. A
// non-positive rate falls back to the stream's native rate (and channels).
// Rendering uses this to get a fixed 48 kHz stereo mix bus.
open_audio_decoder_resampled :: proc(dec: ^Audio_Clip_Decoder, path: cstring, stream_index: c.int, out_rate, out_channels: c.int) -> bool {
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
	if out_rate > 0 {
		dec.out_rate = out_rate
	}
	if out_channels > 0 {
		dec.out_channels = out_channels
	}

	swr_ctx := swres.alloc()
	if swr_ctx == nil {
		fmt.println("swr_alloc failed")
		return false
	}
	dec.swr_ctx = swr_ctx
	out_layout: avutil.ChannelLayout
	avutil.channel_layout_default(&out_layout, dec.out_channels)
	if ret := swres.alloc_set_opts2(
		&dec.swr_ctx,
		// Output: interleaved S16 at the target rate/channel count.
		&out_layout,
		avutil.SampleFormat.S16, dec.out_rate,
		// Input: the stream's native format.
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
	dbg_first := !dec.have_last
	if dec.have_last && target_ts < dec.last_ts {
		if audio_dbg_budget > 0 {
			fmt.printf("[adbg] re-seek back: asked=%.3fs last_pts=%.3fs delta=%+.3fs\n", at_seconds, f64(avutil.rescale_q(dec.last_ts, dec.stream.time_base, avutil.Rational{num = 1, den = 1_000_000})) / 1e6)
			audio_dbg_budget -= 1
		}
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
			if dbg_first && audio_dbg_budget > 0 {
				pts_sec := f64(avutil.rescale_q(frame_ts_at_decode, dec.stream.time_base, avutil.Rational{num = 1, den = 1_000_000})) / 1e6
				fmt.printf("[adbg] first frame after seek: asked=%.3fs pts=%.3fs delta=%+.3fs\n", at_seconds, pts_sec, pts_sec - at_seconds)
				audio_dbg_budget -= 1
			}
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
// Audio player: every audio clip covering the playhead is decoded at 48 kHz
// stereo S16 and downmixed per timeline frame, mirroring the rendered mix bus
// (render.odin). One decoder + forward-only fifo per clip (a snapshot of the
// timeline taken at provision, so the producer thread never touches live clip
// memory). The mixer runs on its own producer thread, driven by a wall-clock
// anchor the UI refreshes every frame; the SDL stream therefore keeps playing
// through UI stalls (AV1 decode hiccups no longer starve it) and the playhead
// cannot fall out of sync with what the device actually outputs.
// ---------------------------------------------------------------------------

audio_device: sdl.AudioDeviceID
audio_device_spec: sdl.AudioSpec
audio_device_ready: bool

audio_stream: ^sdl.AudioStream

// AUDIO_CUSHION_SEC is how far ahead of the playhead the producer keeps the
// device, and the queue-fill ceiling. On the producer thread this absorbs the
// whole UI frame cost; only stalls longer than this resync.
AUDIO_CUSHION_SEC :: 0.12

// MAX_PLAY_AUDIO bounds simultaneous playback decoders (one per audio clip).
MAX_PLAY_AUDIO :: 32

// Play_Src is one audio clip's 48 kHz stereo S16 decoder + content-relative
// fifo. The clip is snapshotted at provision (start_s/start_a/len_a/path) so
// playback is independent of later timeline edits.
Play_Src :: struct {
	start_a:      i64, // clip.timeline_start_frame at provision
	start_s:      i64, // clip.source_start_frame at provision
	len_a:        i64, // clip.source_length_frames at provision
	path:         cstring, // cloned at provision, freed on reset
	stream_index: c.int,
	dec:          Audio_Clip_Decoder,
	fifo:         [dynamic]f32, // content-relative stereo f32 at 48 kHz
	first48:      i64,          // content 48 kHz sample of fifo[0]
	have48:       i64,          // content 48 kHz samples produced so far
}

play_srcs: [MAX_PLAY_AUDIO]Play_Src
play_src_count: int
// audio_play_frame is the next timeline frame for the producer to mix/feed.
audio_play_frame: i64

// Producer thread control. The UI thread writes the anchor + bumps resync_evt;
// the producer owns all decoder/fifo state.
audio_producer_thread: ^thread.Thread
audio_stop_flag: bool  // shutdown request (atomic)
audio_done_flag: bool  // producer exited (atomic)
audio_run_flag: bool   // false pauses the device and frees sources (atomic)
audio_resync_evt: i64  // bump forces clear + re-provision at the anchor (atomic)
audio_anchor_frame: i64 // playhead frame the UI last seeded for a resync (atomic)
audio_anchor_now: i64   // sdl.GetTicksNS() when that frame was seeded (atomic)

// audio_prod_frame is the producer's current content frame, published for the
// UI's drift check (atomic).
audio_prod_frame: i64

audio_was_playing: bool
audio_last_ui_frame: i64
audio_report_tick: u64
audio_report_frame: i64
audio_report_queued: c.int
audio_pcm_dump: ^os.File = nil
audio_pcm_dump_path: string = ""

audio_pcm_dump_open :: proc() {
	if audio_pcm_dump != nil || os.get_env_alloc("NERED_PCMDUMP", context.temp_allocator) == "" {
		return
	}
	path := os.get_env_alloc("NERED_PCMDUMP", context.temp_allocator)
	f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Read_Write_All)
	if err == nil {
		audio_pcm_dump = f
		audio_pcm_dump_path = path
		fmt.printf("[audio] pcm dump -> %s\n", path)
	}
}
audio_dbg_budget: int
// audio_timeline_mtx serializes clip-array mutations (import/split) against the
// producer's timeline snapshot read during audio_provision.
audio_timeline_mtx: sync.Mutex

audio_src_reset :: proc(s: ^Play_Src) {
	if s.dec.opened {
		audio_decoder_reset(&s.dec)
	}
	if s.fifo != nil {
		delete(s.fifo)
		s.fifo = nil
	}
	if s.path != nil {
		mem.delete_cstring(s.path)
		s.path = nil
	}
	s^ = {}
}

// audio_reset_play is producer-thread only: frees all decoders/fifos.
audio_reset_play :: proc() {
	for i in 0 ..< MAX_PLAY_AUDIO {
		audio_src_reset(&play_srcs[i])
	}
	play_src_count = 0
	audio_play_frame = 0
}

// audio_note_edit tells the producer the clip set or playhead changed out of
// band (split, delete, clip move, fps change) so it re-seeks at the playhead.
audio_note_edit :: proc() {
	if !audio_device_ready {
		return
	}
	audio_seek(playhead.frame)
}

// audio_provision (re)opens a decoder for every audio clip, seeked so that
// play_frame is its content origin. Producer-thread only; snapshots the clip
// geometry so the mix never reads live timeline memory.
audio_provision :: proc(play_frame: i64) {
	audio_reset_play()
	audio_play_frame = play_frame
	sync.atomic_store(&audio_prod_frame, play_frame)
	audio_dbg_budget = 8
	fps := timeline_fps()
	sync.mutex_lock(&audio_timeline_mtx)
	defer sync.mutex_unlock(&audio_timeline_mtx)
	for tr in 0 ..< len(timeline.tracks) {
		track := &timeline.tracks[tr]
		for c in 0 ..< len(track.clips) {
			if play_src_count >= MAX_PLAY_AUDIO {
				return
			}
			clip := &track.clips[c]
			if clip.kind != .Audio {
				continue
			}
			seek_frame := max(play_frame, clip.timeline_start_frame)
			content_sec := f64(seek_frame - clip.timeline_start_frame + clip.source_start_frame) / fps
			s := &play_srcs[play_src_count]
			s.start_a = clip.timeline_start_frame
			s.start_s = clip.source_start_frame
			s.len_a = clip.source_length_frames
			s.path = strings.clone_to_cstring(string(clip.path))
			s.stream_index = clip.stream_index
			if !open_audio_decoder_resampled(&s.dec, s.path, s.stream_index, 48000, 2) {
				audio_src_reset(s)
				continue
			}
			if !seek_audio(&s.dec, content_sec) {
				audio_src_reset(s)
				continue
			}
			s.first48 = i64(content_sec * 48000)
			s.have48 = s.first48
			play_src_count += 1
		}
	}
}

// audio_src_pull decodes forward until the fifo covers up_to48 content samples.
audio_src_pull :: proc(s: ^Play_Src, up_to48: i64) {
	for s.have48 < up_to48 {
		n := decode_audio_chunk(&s.dec, f64(s.have48) / 48000.0)
		if n <= 0 {
			break
		}
		for j in 0 ..< n {
			append(&s.fifo, f32(s.dec.s16[j * 2 + 0]) / 32768.0)
			append(&s.fifo, f32(s.dec.s16[j * 2 + 1]) / 32768.0)
		}
		s.have48 += i64(n)
	}
}

// audio_mix_frame zeros mix[0..spf*2) and sums every covering clip's window,
// exactly like the render loop (render.odin render_worker_run). Pure snapshot
// math (start_a/start_s/len_a) so the producer thread never reads live clips.
// The consumed fifo head is trimmed each frame so playback memory stays flat.
audio_mix_frame :: proc(mix: []f32, frame: i64, spf: int) {
	for i in 0 ..< len(mix) {
		mix[i] = 0
	}
	fps := timeline_fps()
	for k in 0 ..< play_src_count {
		s := &play_srcs[k]
		if !s.dec.opened {
			continue
		}
		if frame < s.start_a || frame >= s.start_a + s.len_a {
			continue
		}
		start48 := i64(f64(frame - s.start_a + s.start_s) * 48000.0 / fps)
		if start48 < s.first48 {
			continue
		}
		audio_src_pull(s, start48 + i64(spf))
		if s.have48 < start48 + i64(spf) {
			continue
		}
		base := int(start48 - s.first48)
		for f in 0 ..< spf {
			mix[f * 2 + 0] += s.fifo[(base + f) * 2 + 0]
			mix[f * 2 + 1] += s.fifo[(base + f) * 2 + 1]
		}
		// Drop everything up to and including this frame from the fifo.
		consumed := base + spf
		if consumed > 0 {
			remain := len(s.fifo) - consumed
			if remain > 0 {
				mem.copy(raw_data(s.fifo[0:]), raw_data(s.fifo[consumed:]), remain * size_of(f32))
			}
			resize(&s.fifo, remain)
			s.first48 += i64(consumed)
		}
	}
}

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
	// Fixed 48 kHz stereo S16 source; every clip is resampled to this bus, so
	// the stream outlives individual clips (all clip PCM is downmixed into it).
	src_spec := sdl.AudioSpec{format = .S16, channels = 2, freq = 48000}
	audio_stream = sdl.CreateAudioStream(&src_spec, &device_spec)
	if audio_stream == nil {
		fmt.println("CreateAudioStream failed:", sdl.GetError())
		sdl.CloseAudioDevice(dev)
		audio_device_ready = false
		return false
	}
	if !sdl.BindAudioStream(audio_device, audio_stream) {
		fmt.println("BindAudioStream failed:", sdl.GetError())
		audio_device_ready = false
		return false
	}
	fmt.printf("audio device ready (%d Hz, %dch, fmt %d)\n", device_spec.freq, device_spec.channels, device_spec.format)
	sdl.PauseAudioDevice(dev)
	sync.atomic_store(&audio_stop_flag, false)
	sync.atomic_store(&audio_done_flag, false)
	sync.atomic_store(&audio_run_flag, false)
	sync.atomic_store(&audio_resync_evt, 0)
	audio_producer_thread = thread.create(audio_producer_proc)
	if audio_producer_thread == nil {
		fmt.println("could not start audio producer thread")
		return true
	}
	thread.start(audio_producer_thread)
	return true
}

audio_shutdown :: proc() {
	if audio_producer_thread != nil {
		sync.atomic_store(&audio_stop_flag, true)
		for !sync.atomic_load(&audio_done_flag) {
			sdl.Delay(1)
		}
		thread.destroy(audio_producer_thread)
		audio_producer_thread = nil
	}
	audio_reset_play()
	if audio_stream != nil {
		sdl.DestroyAudioStream(audio_stream)
		audio_stream = nil
	}
	if audio_device_ready {
		sdl.CloseAudioDevice(audio_device)
		audio_device_ready = false
	}
}

// audio_reset_for_load asks the producer to pause and drop all audio state when
// a new file is imported (import_media also stops playback).
audio_reset_for_load :: proc() {
	sync.atomic_store(&audio_run_flag, false)
}

// audio_src_covers_frame reports whether any provisioned clip covers timeline
// frame f, i.e. the producer has valid content to play there.
audio_src_covers_frame :: proc(f: i64) -> bool {
	for k in 0 ..< play_src_count {
		s := &play_srcs[k]
		if s.dec.opened && f >= s.start_a && f < s.start_a + s.len_a {
			return true
		}
	}
	return false
}

// audio_producer_feed mixes whole timeline frames up to a target derived from
// the sound device's own consumption: everything pushed minus what is still in
// the stream queue is what the device has actually played, and that position
// advances at the hardware clock. The producer keeps it ~AUDIO_CUSHION_SEC
// ahead, on the queue ceiling, so processing rate can never differ from the
// device's reproduction rate.
audio_producer_feed :: proc() {
	if !audio_device_ready || audio_stream == nil {
		return
	}
	audio_pcm_dump_open()
	fps := timeline_fps()
	spf := int(MAX_AUDIO_FRAME_SAMPLES)
	if fps > 0 {
		spf = min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(48000.0 / fps + 0.5)))
	}
	max_queue := c.int(f64(48000) * AUDIO_CUSHION_SEC * 2 * 2)
	cushion_frames := i64(AUDIO_CUSHION_SEC * f64(fps) + 1)
	queued_frames := i64(sdl.GetAudioStreamQueued(audio_stream)) / i64(spf * 2 * 2)
	dev_pos := audio_play_frame - queued_frames
	sync.atomic_store(&audio_dev_frame, dev_pos)
	target := dev_pos + cushion_frames
	if target <= audio_play_frame {
		return
	}
	mix: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
	pcm: [MAX_AUDIO_FRAME_SAMPLES * 2]i16
	for audio_play_frame < target {
		if sdl.GetAudioStreamQueued(audio_stream) >= max_queue {
			break
		}
		if !audio_src_covers_frame(audio_play_frame) {
			break
		}
		audio_mix_frame(mix[:], audio_play_frame, spf)
		for f in 0 ..< spf {
			l := mix[f * 2 + 0] * 32767.0
			r := mix[f * 2 + 1] * 32767.0
			pcm[f * 2 + 0] = i16(clamp(l, -32768.0, 32767.0))
			pcm[f * 2 + 1] = i16(clamp(r, -32768.0, 32767.0))
		}
		sdl.PutAudioStreamData(audio_stream, raw_data(pcm[:]), c.int(spf * 2 * 2))
		if audio_pcm_dump != nil {
			dump_bytes := mem.slice_ptr(cast([^]u8)raw_data(pcm[:]), spf * 2 * 2)
			if _, werr := os.write(audio_pcm_dump, dump_bytes); werr != nil {
				os.close(audio_pcm_dump)
				audio_pcm_dump = nil
			}
		}
		audio_play_frame += 1
	}
	sync.atomic_store(&audio_prod_frame, audio_play_frame)
}

// audio_producer_proc is the dedicated playback thread. It owns every decoder
// and the SDL stream, feeding the device asynchronously from the UI loop so UI
// stalls (AV1 decode, layout, uploads) cannot starve the audio output.
audio_producer_proc :: proc(t: ^thread.Thread) {
	if !audio_device_ready || audio_stream == nil {
		sync.atomic_store(&audio_done_flag, true)
		return
	}
	last_evt := i64(0)
	had_evt := false
	fmt.println("[audio] producer thread up")
	last_report := u64(0)
	for !sync.atomic_load(&audio_stop_flag) {
		if sync.atomic_load(&audio_run_flag) {
			evt := sync.atomic_load(&audio_resync_evt)
			if evt != last_evt || !had_evt {
				last_evt = evt
				open_start := sdl.GetTicksNS()
				sdl.ClearAudioStream(audio_stream)
				sdl.FlushAudioStream(audio_stream)
				had_evt = true
				sdl.ResumeAudioDevice(audio_device)
				audio_provision(sync.atomic_load(&audio_anchor_frame))
				fmt.printf("[audio] re-provisioned %d srcs at frame %d in %.1f ms\n", play_src_count, sync.atomic_load(&audio_anchor_frame), f64(sdl.GetTicksNS()-open_start)/1e6)
			}
			audio_producer_feed()
			if now := sdl.GetTicksNS(); now - last_report >= 2_000_000_000 {
				elapsed := f64(now - audio_report_tick) / 1e9
				delta := audio_play_frame - audio_report_frame
				queued_bytes := sdl.GetAudioStreamQueued(audio_stream)
				fps := timeline_fps()
				spf := int(48000.0 / fps + 0.5)
				queued_frames := int(queued_bytes) / (spf * 2 * 2)
				cursor := audio_play_frame - i64(queued_frames)
				pushed_bytes := u64(delta) * u64(spf) * 4
				consumed_bytes := pushed_bytes - u64(queued_bytes - audio_report_queued)
				drain_hz := elapsed > 0 ? f64(consumed_bytes) / 4.0 / elapsed : 0
				fmt.printf("[audio] fps=%.2f ph=%d fed=%d cursor=%d rate=%.1ffps skew=%.2fs drain=%.1fHz q=%.1fkb dev=%dHz/%dch\n",
					fps,
					playhead.frame,
					audio_play_frame, cursor,
					elapsed > 0 ? f64(delta) / elapsed : 0,
					f64(cursor - playhead.frame) / fps,
					drain_hz,
					f64(queued_bytes) / 1024.0,
					audio_device_spec.freq, audio_device_spec.channels)
				audio_report_tick = now
				audio_report_frame = audio_play_frame
				audio_report_queued = queued_bytes
				last_report = now
			}
		} else {
			if had_evt {
				sdl.PauseAudioDevice(audio_device)
				sdl.ClearAudioStream(audio_stream)
				sdl.FlushAudioStream(audio_stream)
				audio_reset_play()
				had_evt = false
			}
			sdl.Delay(4)
			continue
		}
		sdl.Delay(2)
	}
	audio_reset_play()
	if audio_pcm_dump != nil {
		os.close(audio_pcm_dump)
		audio_pcm_dump = nil
	}
	sync.atomic_store(&audio_done_flag, true)
}

// audio_update is called by the main loop. It drives the producer by refreshing
// the playhead anchor every frame and requesting a re-seek on play start/stop
// and genuine leaps (backward, or forward beyond the audio cushion). Steady
// playback needs no work here: the producer runs on its own clock.
audio_update :: proc() {
	if !audio_device_ready {
		return
	}
	if !playhead.playing {
		sync.atomic_store(&audio_run_flag, false)
		audio_was_playing = false
		audio_last_ui_frame = playhead.frame
		return
	}
	if !audio_was_playing {
		audio_was_playing = true
		sync.atomic_store(&audio_run_flag, true)
		audio_seek(playhead.frame)
		audio_last_ui_frame = playhead.frame
		return
	}
	fwd := playhead.frame - audio_last_ui_frame
	audio_last_ui_frame = playhead.frame
	// A resync seeds the anchor and then the producer spends ~10 ms opening
	// decoders, during which its published position is the seed, not the advanced
	// one. Coalesce any re-check within 50 ms of a seed so that window can't
	// re-trigger a storm.
	now := sdl.GetTicksNS()
	last_seed := u64(sync.atomic_load(&audio_anchor_now))
	if now - last_seed < 50_000_000 {
		return
	}
	// The producer runs on its own clock from the last provision anchor, so
	// steady playback needs no per-frame work here. Resync only on:
	//  - backward moves (the forward-only queue can't rewind), and
	//  - the producer falling a cushion behind the playhead (its decode cannot
	//    keep real time, or the playhead raced ahead).
	// A producer running ahead of a stalled UI is left alone: its content
	// already matches where the playhead is about to land.
	fps := timeline_fps()
	prod := sync.atomic_load(&audio_prod_frame)
	if fwd < 0 || playhead.frame > prod + i64(AUDIO_CUSHION_SEC * fps + 3) {
		audio_seek(playhead.frame)
	}
}

// audio_seek re-anchors the producer at the given frame and requests a clear +
// re-provision. UI thread only.
audio_seek :: proc(frame: i64) {
	sync.atomic_store(&audio_anchor_frame, frame)
	sync.atomic_store(&audio_anchor_now, i64(sdl.GetTicksNS()))
	sync.atomic_add(&audio_resync_evt, 1)
}