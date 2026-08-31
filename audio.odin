package main

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
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
	// first_ts is the stream timestamp of the first output frame of the most
	// recent decode_audio_chunk call, used to relabel the fifo base after a seek.
	first_ts: i64,
	have_first: bool,

	// Interleaved S16 scratch written by swr for one chunk.
	s16: []i16,

	// Native stream rate/channels (before resample) plus cumulative decode
	// counts since open, for telemetry.
	input_rate: c.int,
	input_channels: c.int,
	decoded_frames: i64,
	decoded_chunks: i64,
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
	dec.input_rate = dec_ctx.sample_rate
	dec.input_channels = dec_ctx.ch_layout.nb_channels
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

// decode_audio_chunk decodes up to AUDIO_CHUNK output sample-frames. A
// non-negative at_seconds seeks/checks the requested position (used at
// provision and for genuine backward moves); at_seconds < 0 continues
// sequentially from the decoder's current position with no re-seek, because
// the fifo labels exactly match the produced frames and requesting the fifo
// tail would otherwise look like a backward move mid-frame. Returns the number
// of frames written to dec.s16 (interleaved S16, dec.out_channels per frame),
// or 0 on failure/EOF.
decode_audio_chunk :: proc(dec: ^Audio_Clip_Decoder, at_seconds: f64) -> int {
	if !dec.opened {
		return 0
	}
	dec.have_first = false
	sequential := at_seconds < 0
	dbg_first := !dec.have_last
	if !sequential {
		target_ts := audio_to_stream_ts(dec, at_seconds)
		if dec.have_last && target_ts < dec.last_ts {
			last_sec := f64(avutil.rescale_q(dec.last_ts, dec.stream.time_base, avutil.Rational{num = 1, den = 1_000_000})) / 1e6
			if audio_dbg_budget > 0 {
				fmt.printf("[adbg] re-seek back: asked=%.3fs last_pts=%.3fs delta=%+.3fs\n", at_seconds, last_sec, at_seconds - last_sec)
				audio_dbg_budget -= 1
			}
			if !seek_audio(dec, at_seconds) {
				return 0
			}
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
			if !dec.have_first {
				dec.first_ts = frame_ts_at_decode
				dec.have_first = true
			}
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
	if produced > 0 {
		dec.decoded_frames += i64(produced)
		dec.decoded_chunks += 1
	}
	if audio_trace {
		fmt.printf(
			"[tr dec] seq=%v asked=%.3fs produced=%d first_ts=%v last_ts=%v\n",
			sequential, at_seconds, produced, dec.first_ts, dec.last_ts,
		)
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
AUDIO_CUSHION_SEC :: 0.25

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

// audio_jump_frame is a forward-only skip target (0 = none). The UI sets it when
// the playhead outruns the audio producer; the producer trims its fifos and
// advances in place instead of tearing the decoder down and relooping.
audio_jump_frame: i64

audio_was_playing: bool
audio_last_ui_frame: i64
audio_report_tick: u64
audio_report_frame: i64
audio_report_queued: c.int
audio_report_holes: i64
audio_report_fed: u64  // audio_total_fed_bytes at last report (for true device-rate)
audio_total_fed_bytes: u64 // monotonic bytes pushed to the device, never cleared by reseeds
audio_ph_src: i64   // last writer of playhead.frame: 1=mouse scrub, 2=auto catch-up burst
audio_ph_catch: i64 // frames jumped in the last auto catch-up burst (atomic on writer side)

// Per-report feed/mix statistics (producer thread only, reset at each report).
audio_rpt_push: u64       // pushes into the SDL stream
audio_rpt_skip_full: u64  // feed() exits because the stream hit max_queue
audio_rpt_skip_nocov: u64 // feed() exits because no clip covers the next frame
audio_rpt_mix_us: u64     // time spent inside audio_mix_frame (decode + resample + mix)
audio_rpt_feed_us: u64    // time spent in audio_producer_feed outside mix
audio_rpt_min_q: i64      // smallest queued bytes seen in the window
audio_rpt_max_q: i64      // largest queued bytes seen in the window
audio_pcm_dump: ^os.File = nil
audio_pcm_dump_path: string = ""
audio_dec_dump: ^os.File = nil // DIAG: headless-only, dumps dec.s16 immediately after decode_audio_chunk (pre-mix)

audio_dec_dump_open :: proc() {
	if audio_dec_dump != nil || os.get_env_alloc("NERED_DECDUMP", context.temp_allocator) == "" {
		return
	}
	path := os.get_env_alloc("NERED_DECDUMP", context.temp_allocator)
	f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Read_Write_All)
	if err == nil {
		audio_dec_dump = f
		fmt.printf("[audio] dec dump -> %s\n", path)
	}
}

// A/V telemetry. NERED_AUDIO_LOG=ms overrides the report interval (default
// 1000 ms); NERED_AUDIO_FULL=1 adds per-source fifo lines and playhead-jump
// logging. audio_silence_holes counts fed frames that were silence while a
// clip covered them (decode/seek holes, producer thread accumulates it).
audio_log_ms: i64 = 1000
audio_log_full: bool = false
audio_trace: bool = false
audio_thread_start_ns: u64
audio_silence_holes: i64

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
	audio_dec_dump_open()
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
			// Align the fifo base to the decoder's real landing PTS, not the
			// asked position. An AAC seek can land tens of ms off; labeling the
			// fifo with the asked time compounds that offset every frame and the
			// content drifts against the playhead (reads as half-speed).
			n := decode_audio_chunk(&s.dec, content_sec)
			if n <= 0 {
				audio_src_reset(s)
				continue
			}
real_sec := f64(avutil.rescale_q(s.dec.first_ts, s.dec.stream.time_base, avutil.Rational{num = 1, den = 1_000_000})) / 1e6
		s.first48 = i64(real_sec * 48000)
		s.have48 = s.first48 + i64(n)
		audio_src_dump_dec(s, n)
		audio_src_append(s, n)
			play_src_count += 1
		}
	}
}

// audio_src_append converts n interleaved S16 frames from dec.s16 into
// stereo f32 and appends them to the source fifo.
// audio_src_dump_dec writes dec.s16 to NERED_DECDUMP verbatim (stereo S16)
// between the decoder and the fifo/mix, so the decode stage can be validated
// in isolation against the source PCM.
audio_src_dump_dec :: proc(s: ^Play_Src, n: int) {
	if s == nil || n <= 0 {
		return
	}
	ff := audio_dec_dump
	if ff == nil {
		return
	}
	bytes := mem.slice_ptr(cast([^]u8)raw_data(s.dec.s16[:]), n * 2 * 2)
	nw, werr := os.write(ff, bytes)
	if werr != nil || nw != len(bytes) {
		fmt.printf("[audio] dec dump write err=%s n=%d/%d\n", werr, nw, len(bytes))
		os.close(ff)
		audio_dec_dump = nil
	}
}
audio_src_append :: proc(s: ^Play_Src, n: int) {
	for j in 0 ..< n {
		append(&s.fifo, f32(s.dec.s16[j * 2 + 0]) / 32768.0)
		append(&s.fifo, f32(s.dec.s16[j * 2 + 1]) / 32768.0)
	}
}

// audio_src_pull decodes forward until the fifo covers up_to48 content samples.
// The decoder continues sequentially from wherever it is; re-anchoring happens
// only via audio_provision.
audio_src_pull :: proc(s: ^Play_Src, up_to48: i64) {
	for s.have48 < up_to48 {
		n := decode_audio_chunk(&s.dec, -1.0)
		if n <= 0 {
			break
		}
		audio_src_append(s, n)
		s.have48 += i64(n)
	}
}

// audio_frame_boundary48 returns the exact (fractional, floor-truncated) 48kHz
// sample index at which timeline frame `frame` begins, relative to the start
// of the timeline (frame 0). Used to derive the true per-frame sample count
// as a difference of boundaries, instead of a single rounded 48000/fps
// constant that drifts over time whenever fps doesn't evenly divide 48000.
audio_frame_boundary48 :: proc(frame: i64, fps: f64) -> i64 {
	return i64(f64(frame) * 48000.0 / fps)
}

// audio_mix_frame zeros mix[0..spf*2) and sums every covering clip's window,
// exactly like the render loop (render.odin render_worker_run). Pure snapshot
// math (start_a/start_s/len_a) so the producer thread never reads live clips.
// The consumed fifo head is trimmed each frame so playback memory stays flat.
// Returns true if any covering clip actually delivered samples into mix (false
// means the frame was fed to the device as silence while a clip covered it —
// a decode/seek hole).
audio_mix_frame :: proc(mix: []f32, frame: i64, spf: int) -> bool {
	for i in 0 ..< len(mix) {
		mix[i] = 0
	}
	delivered := false
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
		delivered = true
		if audio_trace {
			fmt.printf(
				"[tr mix] fr=%d k=%d start48=%d have48=%d fifo=%d del=%v\n",
				frame, k, start48, s.have48, len(s.fifo), delivered,
			)
		}
		// Drop everything up to and including this frame from the fifo. The fifo
		// is interleaved stereo, so the byte/float offset for `consumed` sample
		// frames is consumed*2 (the forward-skip trim below uses the same rule).
		consumed := base + spf
		if consumed > 0 {
			remain := len(s.fifo) - consumed * 2
			if remain > 0 {
				mem.copy(raw_data(s.fifo[0:]), raw_data(s.fifo[consumed * 2:]), remain * size_of(f32))
			}
			resize(&s.fifo, remain)
			s.first48 += i64(consumed)
		}
	}
	return delivered
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
	if interval := os.get_env_alloc("NERED_AUDIO_LOG", context.temp_allocator); interval != "" {
		v, ok := strconv.parse_i64(interval)
		if ok && v >= 50 {
			audio_log_ms = v
		}
	}
	audio_log_full = os.get_env_alloc("NERED_AUDIO_FULL", context.temp_allocator) != "0"
	audio_trace = os.get_env_alloc("NERED_AUDIO_TRACE", context.temp_allocator) != "0"
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
	feed_t0 := sdl.GetTicksNS()
	defer audio_rpt_feed_us += u64(sdl.GetTicksNS() - feed_t0)
	if !audio_device_ready || audio_stream == nil {
		return
	}
	audio_pcm_dump_open()
	audio_dec_dump_open()
	fps := timeline_fps()
	// Nominal spf: only used for queue-depth bookkeeping (cushion_frames,
	// queued_frames) and to size the fixed mix/pcm scratch buffers. The actual
	// per-frame sample count fed to the device is computed exactly per frame
	// below (audio_frame_boundary48), because fps values that don't evenly
	// divide 48000 (23.976/29.97/59.94) would otherwise accumulate a steady
	// real-time drift between audio and the playhead if every frame pulled a
	// fixed rounded sample count.
	spf := int(MAX_AUDIO_FRAME_SAMPLES)
	if fps > 0 {
		spf = min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(48000.0 / fps + 0.5)))
	}
	// Forward skip: the playhead raced ahead of the producer. Trim fifos and
	// advance in place; the decoder is forward-only so it just keeps decoding
	// from the new position. No reopen, no reloop, no audible repeat.
	if jmp := sync.atomic_load(&audio_jump_frame); jmp > audio_play_frame {
		delta48 := i64(0)
		if fps > 0 {
			delta48 = max(0, audio_frame_boundary48(jmp, fps) - audio_frame_boundary48(audio_play_frame, fps))
		} else {
			delta_frames := max(0, jmp - audio_play_frame)
			delta48 = delta_frames * i64(spf)
		}
		for k in 0 ..< play_src_count {
			s := &play_srcs[k]
			if !s.dec.opened || s.fifo == nil || delta48 <= 0 {
				continue
			}
			drop := int(min(delta48, i64(len(s.fifo)) / 2))
			if drop > 0 {
				s.first48 += i64(drop)
				remain := len(s.fifo) - drop * 2
				if remain > 0 {
					mem.copy(raw_data(s.fifo[0:]), raw_data(s.fifo[drop * 2:]), remain * size_of(f32))
				}
				resize(&s.fifo, remain)
			}
		}
		audio_play_frame = jmp
		sdl.ClearAudioStream(audio_stream)
		sync.atomic_store(&audio_jump_frame, 0)
	}
	max_queue := c.int(f64(48000) * AUDIO_CUSHION_SEC * 2 * 2)
	cushion_frames := i64(AUDIO_CUSHION_SEC * f64(fps) + 1)
	queued_frames := i64(sdl.GetAudioStreamQueued(audio_stream)) / i64(spf * 2 * 2)
	dev_pos := audio_play_frame - queued_frames
	sync.atomic_store(&audio_dev_frame, dev_pos)
	// The producer must pin to the playhead, not the device's own consumption
	// clock: video advances on the wall clock, so audio content has to stay
	// glued to the playhead position too. dev_pos only caps how far ahead the
	// queue may run. target = the nearest of (playhead, device) + cushion.
	ph := sync.atomic_load(&ui_playhead_frame)
	target := max(dev_pos, ph) + cushion_frames
	if target <= audio_play_frame {
		return
	}
	mix: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
	pcm: [MAX_AUDIO_FRAME_SAMPLES * 2]i16
	for audio_play_frame < target {
		if sdl.GetAudioStreamQueued(audio_stream) >= max_queue {
			audio_rpt_skip_full += 1
			break
		}
		if !audio_src_covers_frame(audio_play_frame) {
			audio_rpt_skip_nocov += 1
			break
		}
		// Exact per-frame sample count: the difference between consecutive
		// frame boundaries, not a fixed rounded 48000/fps. For fps that don't
		// evenly divide 48000 this alternates (e.g. 1601/1602 at 29.97) and
		// averages to the true rate with zero long-term drift, instead of the
		// old fixed-spf approach which over/under-fed the device every single
		// frame and caused audio to steadily lag/lead the playhead in preview.
		cur_spf := spf
		if fps > 0 {
			b0 := audio_frame_boundary48(audio_play_frame, fps)
			b1 := audio_frame_boundary48(audio_play_frame + 1, fps)
			cur_spf = min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(b1 - b0)))
		}
		mix_t0 := sdl.GetTicksNS()
		if !audio_mix_frame(mix[:], audio_play_frame, cur_spf) {
			sync.atomic_add(&audio_silence_holes, 1)
		}
		audio_rpt_mix_us += u64(sdl.GetTicksNS() - mix_t0)
		for f in 0 ..< cur_spf {
			l := mix[f * 2 + 0] * 32767.0
			r := mix[f * 2 + 1] * 32767.0
			pcm[f * 2 + 0] = i16(clamp(l, -32768.0, 32767.0))
			pcm[f * 2 + 1] = i16(clamp(r, -32768.0, 32767.0))
		}
		sdl.PutAudioStreamData(audio_stream, raw_data(pcm[:]), c.int(cur_spf * 2 * 2))
		audio_total_fed_bytes += u64(cur_spf * 2 * 2)
		audio_rpt_push += 1
		qnow := i64(sdl.GetAudioStreamQueued(audio_stream))
		audio_rpt_min_q = min(audio_rpt_min_q, qnow)
		audio_rpt_max_q = max(audio_rpt_max_q, qnow)
		if audio_pcm_dump != nil {
			dump_bytes := mem.slice_ptr(cast([^]u8)raw_data(pcm[:]), spf * 2 * 2)
			if _, werr := os.write(audio_pcm_dump, dump_bytes); werr != nil {
				os.close(audio_pcm_dump)
				audio_pcm_dump = nil
			}
		}
		audio_play_frame += 1
		if audio_trace {
			fmt.printf(
				"[tr feed] fr=%d devpos=%d target=%d q=%db ph=%d prod=%d dev=%d mix=%.2fs\n",
				audio_play_frame - 1, dev_pos, target, qnow, sync.atomic_load(&ui_playhead_frame), audio_play_frame, audio_dev_frame, f64(sdl.GetTicksNS() - feed_t0) / 1e9,
			)
		}
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
	audio_thread_start_ns = sdl.GetTicksNS()
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
			if now := sdl.GetTicksNS(); now - last_report >= u64(audio_log_ms) * 1_000_000 {
				elapsed := f64(now - audio_report_tick) / 1e9
				delta := audio_play_frame - audio_report_frame
				queued_bytes := sdl.GetAudioStreamQueued(audio_stream)
				fps := timeline_fps()
				spf := int(48000.0 / fps + 0.5)
				queued_frames := int(queued_bytes) / (spf * 2 * 2)
				cursor := audio_play_frame - i64(queued_frames)
				rate_fps := elapsed > 0 && delta >= 0 ? f64(delta) / elapsed : 0
				queued_delta := f64(i64(queued_bytes) - i64(audio_report_queued))
				consumed_bytes := f64(delta) * f64(spf) * 4.0 - queued_delta
				drain_hz := elapsed > 0 && consumed_bytes > 0 ? consumed_bytes / 4.0 / elapsed : 0
				dev_hz := elapsed > 0 ? (f64(audio_total_fed_bytes - audio_report_fed) - queued_delta) / 4.0 / elapsed : 0
				dev_ratio := audio_device_spec.freq > 0 ? dev_hz / f64(audio_device_spec.freq) : 0
				max_queue := c.int(f64(48000) * AUDIO_CUSHION_SEC * 2 * 2)
				holes := sync.atomic_load(&audio_silence_holes)
				holes_delta := holes - audio_report_holes
				resync := sync.atomic_load(&audio_resync_evt)
				anchor := sync.atomic_load(&audio_anchor_frame)
				cover := audio_src_covers_frame(playhead.frame)
				avail_bytes := sdl.GetAudioStreamAvailable(audio_stream)
				pace := "ok"
				if elapsed > 1.0 {
					if dev_ratio < 0.9 {
						pace = "SLOW"
					} else if dev_ratio > 1.1 {
						pace = "FAST"
					}
				}
				q_min := min(audio_rpt_min_q, i64(queued_bytes))
				q_max := max(audio_rpt_max_q, i64(queued_bytes))
				fmt.printf("[audio] t=%.2fs ph=%d(%.3fs,playing=%t,src=%s,catch=%d) anchor=%d prod=%d fed=%d curs=%d skew=%+.3fs rate=%.2ffps drain=%.0fHz pace=%s(dev=%.0fHz %.2fx) q=%d/%db(%dfr,min=%dq,max=%dq,avail=%db) feed(push=%d,full=%d,nocov=%d,mix=%.1fms,work=%.1fms) cov=%d holes=%+d(total %d) resync=%d dev=%dHz/%dch\n",
					f64(now-audio_thread_start_ns)/1e9,
					playhead.frame, f64(playhead.frame)/fps, playhead.playing,
					sync.atomic_load(&audio_ph_src) == 1 ? "mouse" : sync.atomic_load(&audio_ph_src) == 2 ? "auto" : "?",
					sync.atomic_load(&audio_ph_catch),
					anchor, sync.atomic_load(&audio_prod_frame), audio_play_frame, cursor,
					f64(cursor-playhead.frame)/fps,
					rate_fps,
					drain_hz,
					pace, dev_hz, dev_ratio,
					queued_bytes, max_queue, queued_frames,
					q_min, q_max, avail_bytes,
					audio_rpt_push, audio_rpt_skip_full, audio_rpt_skip_nocov,
					f64(audio_rpt_mix_us)/1e6, f64(audio_rpt_feed_us)/1e6,
					cover ? 1 : 0,
					holes_delta, holes,
					resync,
					audio_device_spec.freq, audio_device_spec.channels)
				if audio_log_full {
					for k in 0 ..< play_src_count {
						s := &play_srcs[k]
						at := i64(-1)
						covered := false
						in_fifo := false
						if audio_play_frame >= s.start_a && audio_play_frame < s.start_a + s.len_a {
							covered = true
							at = i64(f64(audio_play_frame - s.start_a + s.start_s) * 48000.0 / fps)
							in_fifo = at >= s.first48 && at < s.have48
						}
						fmt.printf("[src %d] %s dec=%t in=%dHz/%dch out=%dHz/%dch a=%d s=%d len=%d first48=%d have48=%d fifo=%dfr decoded=%dfr/%dch mix_at=%d(into %t) cov=%t\n",
							k, s.path, s.dec.opened,
							s.dec.input_rate, s.dec.input_channels, s.dec.out_rate, s.dec.out_channels,
							s.start_a, s.start_s, s.len_a,
							s.first48, s.have48, len(s.fifo) / 2,
							s.dec.decoded_frames, s.dec.decoded_chunks,
							at, in_fifo, covered)
					}
				}
				audio_report_tick = now
				audio_report_frame = audio_play_frame
				audio_report_queued = queued_bytes
				audio_report_holes = holes
				audio_report_fed = audio_total_fed_bytes
				audio_rpt_push = 0
				audio_rpt_skip_full = 0
				audio_rpt_skip_nocov = 0
				audio_rpt_mix_us = 0
				audio_rpt_feed_us = 0
				audio_rpt_min_q = i64(queued_bytes)
				audio_rpt_max_q = i64(queued_bytes)
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
	if audio_dec_dump != nil {
		os.close(audio_dec_dump)
		audio_dec_dump = nil
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
	if fwd > 3 || fwd < -1 {
		fmt.printf("[ph] t=%.2fs ph=%d fwd=%+d (last_ui=%d) -> jump/health check\n",
			f64(sdl.GetTicksNS()-audio_thread_start_ns)/1e9,
			playhead.frame, fwd, audio_last_ui_frame)
	}
	// A resync clears the stream, reopens every decoder (~16 ms) and then must
	// refill a full cushion at device rate before it can race ahead again.
	// Coalesce re-checks well past that recovery window so the forward-gap guard
	// below cannot re-trigger a self-sustaining reseed loop.
	now := sdl.GetTicksNS()
	last_seed := u64(sync.atomic_load(&audio_anchor_now))
	if now - last_seed < 200_000_000 {
		return
	}
	// The producer runs on its own clock from the last provision anchor, so
	// steady playback needs no per-frame work here. Resync only on:
	//  - backward moves (the forward-only queue can't rewind), and
	//  - the producer falling ~0.45 s behind the playhead (its decode cannot
	//    keep real time, or the playhead raced ahead).
	// A producer running ahead of a stalled UI is left alone: its content
	// already matches where the playhead is about to land.
	fps := timeline_fps()
	prod := sync.atomic_load(&audio_prod_frame)
	if fwd < 0 {
		reason := "backward"
		src := sync.atomic_load(&audio_ph_src)
		catch := sync.atomic_load(&audio_ph_catch)
		src_name := src == 1 ? "mouse" : src == 2 ? "auto" : "?"
		fmt.printf("[ph] t=%.2fs ph=%d prod=%d anchor=%d -> %s reseek (fwd=%+d, phsrc=%s catch=%d)\n",
			f64(now-audio_thread_start_ns)/1e9,
			playhead.frame, prod, sync.atomic_load(&audio_anchor_frame), reason, fwd, src_name, catch)
		audio_seek(playhead.frame)
	} else if playhead.frame > prod + i64(AUDIO_CUSHION_SEC * fps) + 6 {
		// Producer (or device) fell behind the playhead. Skip forward in place —
		// never reloop, that reads as slowed/stuttering audio against a correct
		// video. The producer trims fifos and continues decoding forward.
		sync.atomic_store(&audio_jump_frame, playhead.frame)
		fmt.printf("[ph] t=%.2fs ph=%d prod=%d -> forward skip to ph (fwd=%+d)\n",
			f64(now-audio_thread_start_ns)/1e9,
			playhead.frame, prod, fwd)
	}
}

// audio_seek re-anchors the producer at the given frame and requests a clear +
// re-provision. UI thread only.
audio_seek :: proc(frame: i64) {
	if audio_trace {
		fmt.printf("[tr seek] to=%d\n", frame)
	}
	sync.atomic_store(&audio_anchor_frame, frame)
	sync.atomic_store(&audio_anchor_now, i64(sdl.GetTicksNS()))
	sync.atomic_add(&audio_resync_evt, 1)
}
