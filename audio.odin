package main

import "core:c"
import "core:fmt"
import "core:math"
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

// AUDIO_CHUNK is the number of output sample-frames decoded in one step.
AUDIO_CHUNK :: 4096
// AUDIO_MAX_CH yields a generous fixed scratch buffer for interleaved S16.
AUDIO_MAX_CH :: 8

// Audio_Clip_Decoder decodes one audio stream of a media file and converts it
// to interleaved signed-16 PCM at the stream's native rate/channel count. The
// miniaudio device handles final rate/channel conversion to the hardware.
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
	// cursor_ts is the content position of the NEXT sample this decoder will emit,
	// and have_cursor says whether it is known yet. It is invalidated by a seek
	// (flush_buffers makes the next frame's position unknowable until it is read)
	// and re-established from that frame.
	//
	// This exists because a seek lands on a PACKET BOUNDARY, not on the position
	// asked for: seeking to 0 in a file whose first packet is pts=-1024 carrying
	// skip_samples=1024 measures first_ts=1024, so content samples 0..1023 are
	// unreachable by asking for 0. Every consumer that took the decoder's landing
	// point at face value therefore began 1024 samples (21.3ms) late -- the export
	// on every clip, playback on the first. See audio_probe_priming_trace.
	cursor_ts: i64,
	have_cursor: bool,

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
	if out_rate > 0 {
		dec.out_rate = out_rate
	}
	if out_channels > 0 {
		dec.out_channels = out_channels
	}
	// Keep the output channel count within the fixed [AUDIO_MAX_CH] scratch
	// contract so decode_audio_chunk's interleaved S16 write never overflows
	// (swr below is configured with this clamped count).
	if dec.out_channels < 1 {
		dec.out_channels = 1
	} else if dec.out_channels > AUDIO_MAX_CH {
		dec.out_channels = AUDIO_MAX_CH
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
	// Size the interleaved S16 scratch by the actual channel count (not a fixed
	// 8ch cap). out_channels was clamped to AUDIO_MAX_CH before swr setup, so a
	// >8ch file decodes into a buffer sized for what swr writes.
	dec.s16 = make([]i16, AUDIO_CHUNK * dec.out_channels)
	dec.opened = true
	if audio_rpt.trace {
		fmt.printf("audio %dch @ %d Hz -> S16\n", dec.out_channels, dec.out_rate)
	}
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
// decode_from_content decodes so that the returned chunk BEGINS exactly at
// `content_sample`, a sample position in the decoder's output rate.
//
// This is the one place a clip's opening is established, because getting it
// wrong is silent and costs a visible amount of audio: a seek lands on a PACKET
// BOUNDARY, not on the position asked for. Measured on the AAC fixture (see
// audio_probe_priming_trace): seeking to 0 lands at 1024, so content samples
// 0..1023 are unreachable by asking for 0 -- and that is what the export was
// logging as "preroll could not cover it" while mixing a gap into the file at
// every cut, while playback silently dropped the first frame of the first clip.
//
// Two halves, and both are needed:
//
//   - Seek BEFORE the ask, by the preroll, and NEVER clamp to zero. Clamping is
//     what made this unrecoverable: for content 0 it pins the seek to 0, which
//     lands after content 0, and the samples in between are gone rather than
//     merely mislabelled. A file whose muxer wrote an encoder delay has a
//     negative-pts first packet precisely so this seek is possible.
//   - Then let decode_audio_chunk TRIM to the ask. Seeking early can land before
//     the target (the usual case, and harmless) or at it.
//
// Returns the number of output samples, 0 on failure.
decode_from_content :: proc(dec: ^Audio_Clip_Decoder, content_sample: i64) -> int {
	sec := f64(content_sample) / f64(dec.out_rate)
	// Seek ONLY to skip ahead. Near the start of the stream there is nothing to
	// skip to, and a freshly opened decoder already sits at the beginning -- which
	// is the only position from which content 0 is reachable at all.
	//
	// It is tempting to seek to (sec - preroll) unconditionally and let ffmpeg
	// clamp it, and that was the bug: with the preroll clamped to zero the seek
	// for content 0 pinned to 0 and landed a packet LATE, putting content 0
	// behind the playhead. Seeking genuinely negative is worse, not better --
	// measured, seeking to -0.5s lands at +2048 rather than at the file's first
	// packet (-1024), because there is no index entry below it. So the early case
	// takes no seek, and the late case overshoots by the preroll as before.
	if sec > AUDIO_SEEK_PREROLL_SEC {
		if !seek_audio(dec, sec - AUDIO_SEEK_PREROLL_SEC) {
			return 0
		}
	}
	return decode_audio_chunk(dec, sec)
}

seek_audio :: proc(dec: ^Audio_Clip_Decoder, seconds: f64) -> bool {
	ts := audio_to_stream_ts(dec, seconds)
	if ret := avfmt.seek_frame(dec.fmt_ctx, dec.audio_idx, ts, avfmt.SeekFlags{.Backward}); ret < 0 {
		fmt.println("av_seek_frame (audio):", ff_err_str(ret))
		return false
	}
	avcodec.flush_buffers(dec.dec_ctx)
	dec.have_last = false
	dec.have_cursor = false
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
	target_ts := i64(0)
	// How many output samples must be discarded before this chunk begins at
	// at_seconds. See decode_from_content for why a seek cannot be trusted to
	// land where it was asked to. Zero in sequential mode, which is the only
	// mode where the decoder's own position is authoritative.
	skip := 0
	if !sequential {
		target_ts = i64(audio_to_stream_ts(dec, at_seconds))
		if dec.have_last && target_ts < dec.last_ts {
			last_sec := f64(avutil.rescale_q(dec.last_ts, dec.stream.time_base, avutil.Rational{num = 1, den = 1_000_000})) / 1e6
			if audio_rpt.trace && audio_rpt.dbg_budget > 0 {
				fmt.printf("[adbg] re-seek back: asked=%.3fs last_pts=%.3fs delta=%+.3fs\n", at_seconds, last_sec, at_seconds - last_sec)
				audio_rpt.dbg_budget -= 1
			}
			// Overshoot backward by the preroll and let the trim below land on the
			// ask, exactly as decode_from_content does. Seeking straight to at_seconds
			// lands a packet late, which reads as "the target is in the past" and
			// silently drops the audio in between.
			if !seek_audio(dec, at_seconds - AUDIO_SEEK_PREROLL_SEC) {
				return 0
			}
			dec.have_cursor = false
			skip = 0
		}
	}
	if !sequential && dec.have_cursor {
		skip = int(dec.cursor_ts - target_ts)
		if skip < 0 {
			skip = 0
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
			if frame_ts_at_decode == avutil.AV_NOPTS_VALUE {
				// A frame with no position cannot advance a cursor and cannot be
				// trimmed against one. Sequential decoding is the only mode in which
				// that is acceptable, and there `skip` is 0, so relabelling keeps
				// working; asking for a position is not something we can honour.
				assert(
					sequential,
					"decode_audio_chunk: unpositioned frame while seeking to a specific sample",
				)
				frame_ts_at_decode = dec.cursor_ts
			}
			// `pos` is the absolute content position of the output sample this frame
			// is about to write, so the cursor stays a single number across the
			// whole chunk whether or not a trim is in play.
			pos := dec.cursor_ts
			if !dec.have_cursor {
				pos = frame_ts_at_decode
				dec.cursor_ts = pos
				dec.have_cursor = true
				// The seek landed at the frame, not at the ask, so the trim can only
				// be sized now that the landing point is known. This is the case
				// that matters: measured, seeking to 0 lands at 1024.
				if !sequential {
					skip = int(pos - target_ts)
					if skip < 0 {
						skip = 0
					}
				}
			}
			// Trim the OUTPUT, not the input. The resampler has already been fed
			// this frame and its filter state has to stay continuous, so the padding
			// is dropped by sliding the freshly converted tail back over it. Only
			// the first chunk after a seek can have skip > 0.
			dropped := 0
			if skip > 0 && n > 0 {
				dropped = min(skip, int(n))
				ch := int(dec.out_channels)
				bsz := size_of(i16)
				tail := int(n) - dropped
				if tail > 0 {
					mem.copy(
						raw_data(dec.s16)[produced * ch * bsz:],
						raw_data(dec.s16)[(produced + dropped) * ch * bsz:],
						tail * ch * bsz,
					)
				}
				n -= c.int(dropped)
				skip -= dropped
			}
			// The kept samples begin after whatever was dropped, so that -- not the
			// frame's own timestamp -- is where the fifo has to be labelled from.
			kept_start := pos + i64(dropped)
			if !dec.have_first {
				dec.first_ts = kept_start
				dec.have_first = true
			}
			avutil.frame_unref(dec.frame)
			if n <= 0 {
				if dropped > 0 {
					// The trim consumed this entire frame -- which is the common
					// case, because a seek lands one packet late and that packet is
					// exactly what had to go. Returning here would report "no audio"
					// for a decoder that has plenty, so pull the next frame instead.
					continue
				}
				return produced
			}
			dec.last_ts = frame_ts_at_decode
			dec.have_last = true
			dec.cursor_ts = pos + i64(int(n))
			if audio_rpt.trace && dbg_first && audio_rpt.dbg_budget > 0 {
				pts_sec := f64(avutil.rescale_q(frame_ts_at_decode, dec.stream.time_base, avutil.Rational{num = 1, den = 1_000_000})) / 1e6
				fmt.printf("[adbg] first frame after seek: asked=%.3fs pts=%.3fs delta=%+.3fs\n", at_seconds, pts_sec, pts_sec - at_seconds)
				audio_rpt.dbg_budget -= 1
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
	if audio_rpt.trace {
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
// anchor the UI refreshes every frame; the device therefore keeps playing
// through UI stalls (AV1 decode hiccups no longer starve it) and the playhead
// cannot fall out of sync with what the device actually outputs.
// ---------------------------------------------------------------------------

// audio_atempo is the pitch-preserving playback-rate graph
// (abuffer->atempo*->aformat->abuffersink) owned by the producer thread. It
// used to hang off the device struct, but it is not the device's business: the
// device always runs at 1.0, and the rate is applied as time-stretch on the mix
// rather than by resampling. It belongs to whoever produces the mix. Rebuilt on
// rate change, jump, and provision (the graph's internal window would otherwise
// leak pre-jump samples). rate == 1.0 leaves the graph nil and bypasses it
// entirely.
//
// The output device itself is not here: it lives behind a narrow push/query
// interface in audio_device.odin, so nothing in the engine knows what backs it.
audio_atempo: Atempo_Graph

// MAX_PLAY_AUDIO bounds simultaneous playback decoders. One decoder serves a
// whole source stream (every contiguous split segment shares it), so this
// bounds STREAMS, not clips.
MAX_PLAY_AUDIO :: 32

// MAX_PLAY_SEGMENTS bounds the timeline segments one decoder serves. A run that
// exceeds it starts a second decoder rather than growing the array.
MAX_PLAY_SEGMENTS :: 256

// AUDIO_SEEK_PREROLL_SEC seeks a clip's decoder this far BEFORE its content
// origin. av_seek_frame(.Backward) on this container lands the first decoded
// frame up to ~0.1s AFTER the requested time (measured: AAC/MP4 priming +
// edit-list slack, +0.076..+0.112s across segments). The mixer treats samples
// before the landing PTS as a hole, so without a preroll every split opened
// with ~0.1s of silence. Preroll must exceed the demuxer's late-landing slack;
// the fifo base stays at the real landing PTS (audio_mix_frame trims the
// extra), so the preroll content is skipped, not duplicated or shifted.
AUDIO_SEEK_PREROLL_SEC :: 0.5

// AUDIO_FORWARD_DECODE_MAX_SEC bounds how much SKIPPED audio a forward playhead
// move may buy by DECODING THROUGH it rather than seeking. Past this bound the
// skipped content costs more producer-thread time than a seek, and a producer
// that blocks is a producer that underruns the device: measured on a 10000
// frame jump over 166s of 3x FLAC, decoding through took 5.2s inside one
// audio_mix_frame and cost 540 device underruns. The content behind the jump is
// never played, so paying to decode it is pure loss. Sized where the two are
// comparable -- FLAC decodes ~160x realtime here (~6ms per source per second
// of audio), and a seek costs one preroll decode plus the seek itself -- so the
// worst case added to a mixed frame stays in the tens of milliseconds. Mirrors
// FORWARD_STREAM_MAX_SEC on the video side, which streams instead of seeks only
// inside the same bound. Gaps under it keep decoding in place: a seek there
// would cost more than the decode it replaces.
AUDIO_FORWARD_DECODE_MAX_SEC :: 1.0

// The same bound in sample-frames, which is what the mixer compares against.
// Kept as its own name so the fifo arithmetic below reads in samples without
// a seconds-to-samples conversion repeated at the call site.
AUDIO_FORWARD_DECODE_MAX_48 :: i64(AUDIO_FORWARD_DECODE_MAX_SEC * 48000.0)

// Audio_Ring is a growable circular buffer of interleaved stereo f32
// sample-frames. It replaces a plain [dynamic]f32 drained by shifting the
// remaining content down to index 0 on every consume: that pattern is O(n)
// in however much is currently buffered, on EVERY mixed frame, on the
// real-time audio producer thread, for every active source -- exactly the
// place a wasted memmove is least affordable. Here, dropping consumed
// samples (ring_drop) is O(1): it only moves `head`/`count`, never the
// buffered samples. Growth (ring_reserve) is doubling and therefore rare and
// amortized; it's the only O(n) operation left, and it only runs when a
// source's buffered depth reaches a new high-water mark, not every frame.
// ---------------------------------------------------------------------------
// Declick: fade a source's contribution in and out at its own edges.
//
// This lives here, with the rest of the audio engine, because BOTH sinks mix and
// both must agree: the export (render_mix_block) and playback (audio_mix_frame).
// It was written for the export alone and the preview mixer never called it, so
// the same edit -- a clip moved, a fade applied -- produced a ramped boundary in
// the export and a hard step in playback. That is one rule stated once and applied
// on one side, which is the same defect shape as the text blend Active 26 removed.
//
// A click is a STEP, and what removes it is spreading the step over enough samples
// No automatic edge ramp exists here, and that is the design: a cut is a cut.
//
// There WAS one -- a raised-cosine declick of AUDIO_DECLICK_SAMPLES at every
// source's contribution edges -- and it was this engine's second fade mechanism.
// Gain is already automated per sample through the clip's keyframe envelope, so
// the ramp was an IMPLICIT fade applied to every edit whether the user wanted one
// or not, and an authored fade could not be told from an automatic one. Two
// mechanisms for one job is where two mechanisms disagree: they did, at ~2.5e-3
// in a clip's final fade, because the ramp was normalised against the caller's
// chunk length and playback chunks by frame while the export chunks by block.
//
// A step at a cut is a real discontinuity and can be heard. That is what an
// authored fade is for, and the envelope already expresses one. The engine's job
// is that what you cut is what you hear.
// ---------------------------------------------------------------------------

Audio_Ring :: struct {
	buf:   [dynamic]f32, // backing storage; len(buf)/2 == capacity in sample-frames
	head:  int,          // sample-frame index of the oldest buffered sample
	count: int,          // number of valid sample-frames currently buffered
}

// ring_cap returns the ring's current capacity in sample-frames (0 if the
// backing buffer has never been allocated).
ring_cap :: proc(r: ^Audio_Ring) -> int {
	return len(r.buf) / 2
}

// ring_len returns how many sample-frames are currently buffered.
ring_len :: proc(r: ^Audio_Ring) -> int {
	return r.count
}

// ring_reserve grows the backing buffer, if needed, to hold `extra` more
// sample-frames than are currently buffered. Doubling growth amortizes the
// cost across many pushes. Existing content is copied out UNWRAPPED into the
// fresh buffer starting at index 0 (head resets to 0); this only happens on
// a new high-water mark, never on a routine push once warmed up.
ring_reserve :: proc(r: ^Audio_Ring, extra: int) {
	need := r.count + extra
	cap_now := ring_cap(r)
	if need <= cap_now {
		return
	}
	new_cap := max(cap_now * 2, need, 256)
	new_buf := make([dynamic]f32, new_cap * 2)
	for i in 0 ..< r.count {
		src := (r.head + i) % cap_now
		new_buf[i * 2 + 0] = r.buf[src * 2 + 0]
		new_buf[i * 2 + 1] = r.buf[src * 2 + 1]
	}
	if r.buf != nil {
		delete(r.buf)
	}
	r.buf = new_buf
	r.head = 0
}

// ring_push_pcm converts and appends `n` stereo sample-frames from
// interleaved i16 PCM (`pcm[i*2+0]`/`pcm[i*2+1]`, i in 0..<n) to the tail of
// the ring, growing the backing buffer first if needed. O(n) to write the
// NEW samples in -- unavoidable, every fill path pays this -- but existing
// buffered content is never touched, unlike appending one sample at a time
// via a plain dynamic array (repeated length-check/grow overhead per
// sample instead of one reservation for the whole chunk).
ring_push_pcm :: proc(r: ^Audio_Ring, pcm: []i16, n: int) {
	if n <= 0 {
		return
	}
	ring_reserve(r, n)
	cap_now := ring_cap(r)
	tail := (r.head + r.count) % cap_now
	for i in 0 ..< n {
		dst := (tail + i) % cap_now
		r.buf[dst * 2 + 0] = f32(pcm[i * 2 + 0]) / 32768.0
		r.buf[dst * 2 + 1] = f32(pcm[i * 2 + 1]) / 32768.0
	}
	r.count += n
}

// ring_at returns the stereo sample-frame at logical offset `idx` from the
// current head (idx 0 = oldest buffered sample). Caller must ensure
// 0 <= idx < ring_len(r).
ring_at :: proc(r: ^Audio_Ring, idx: int) -> (l, rr: f32) {
	cap_now := ring_cap(r)
	pos := (r.head + idx) % cap_now
	return r.buf[pos * 2 + 0], r.buf[pos * 2 + 1]
}

// ring_drop discards the oldest `n` sample-frames (clamped to what's
// buffered). O(1): only head/count bookkeeping moves.
ring_drop :: proc(r: ^Audio_Ring, n: int) {
	if n <= 0 {
		return
	}
	drop := min(n, r.count)
	cap_now := ring_cap(r)
	if cap_now > 0 {
		r.head = (r.head + drop) % cap_now
	}
	r.count -= drop
}

// ring_destroy frees the backing buffer and zeroes the ring.
ring_destroy :: proc(r: ^Audio_Ring) {
	if r.buf != nil {
		delete(r.buf)
	}
	r^ = {}
}

// Play_Seg is one timeline segment of a source stream: where it sits on the
// timeline (start_a/len_a) and where its content starts in the source
// (start_s). len_a is both the timeline length and the source length (clips are
// not time-stretched), so a segment's source range is [start_s, start_s+len_a).
Play_Seg :: struct {
	start_a: i64, // timeline_start_frame
	start_s: i64, // source_start_frame
	// start_s_rate pins the rate start_s is counted against; see
	// audio_source_start_sec. Kept in frames (not pre-converted to seconds) so
	// the contiguity checks that compare start_s across segments stay in one
	// space.
	start_s_rate: f64,
	len_a:   i64, // source_length_frames
	// gain is the segment's latched copy of the committed gain snapshot (static
	// dB + keyed curve), taken once at provision from the geometry slab. Rides
	// the per-segment snapshot (not per-source) because a split makes adjacent
	// segments of one source independently adjustable. The mix re-evaluates it
	// per frame through audio_gain_linear, so automation animates live without
	// the producer ever reading live timeline state.
	gain: Audio_Gain_Snapshot,
}

// Play_Src is one source stream's 48 kHz stereo S16 decoder + content-relative
// fifo, shared by every contiguous segment of that stream. Splits are
// contiguous in both timeline and source, so a single forward-only decoder
// plays straight through them with no per-segment reopen/seek — the old
// one-decoder-per-clip model re-seeked at every split (opening a ~0.1s silence
// hole at each boundary) and capped playback at MAX_PLAY_AUDIO CLIPS, silently
// dropping whole tracks once a few linked tracks were split a few times. The
// segment set is snapshotted at provision so playback never reads live clips.
Play_Src :: struct {
	path:         cstring, // cloned at provision, freed on reset
	stream_index: c.int,
	dec:          Audio_Clip_Decoder,
	fifo:  Audio_Ring, // content-relative stereo f32 at 48 kHz
	first48: i64,       // content 48 kHz sample of fifo's head
	have48:  i64,       // content 48 kHz samples produced so far
	seg:          [MAX_PLAY_SEGMENTS]Play_Seg, // in timeline order
	seg_count:    int,
}

// Reconcile_Action is what a reconcile decided to do with one source's decoder.
// A closed set of three, so the switch is exhaustive and a fourth case cannot be
// added without the compiler noticing every site that handles the existing ones.
Reconcile_Action :: enum {
	// Keep: the decoder is still anchored to the right content, so it and its
	// content-relative fifo carry on untouched. The overwhelmingly common case
	// for an edit that lands away from what is playing.
	Keep,
	// Seek: same stream, but the content position moved, so re-anchor the
	// existing decoder. Cheaper than Open by the cost of the file open, and the
	// common case when the playhead is inside the clip that moved.
	Seek,
	// Open: a stream the producer does not have a decoder for at all.
	Open,
}

// Reconcile_Report is what one reconcile did, per run. Read for the report line
// and by the probe; the counts are the only honest answer to "is this thing
// actually helping", because a design that is supposed to avoid reopens and
// quietly reopens anyway looks exactly like one that works until it doesn't.
Reconcile_Report :: struct {
	kept, sought, opened, dropped: int,
	// touched_window is true when any source's segments -- old or new -- overlap
	// the frames the device queue still holds. That, and not the reopen count, is
	// what decides whether the QUEUE has to be dropped: a decoder can be reused
	// while the already-mixed audio sitting in the queue is wrong.
	touched_window: bool,
}

// Play_Src_Snap is one provisioned source as it was BEFORE the new geometry was
// folded in. Snapshotting first is what makes the decision possible at all: pass 1
// of provisioning overwrites seg_count in place, so without this the old segment
// list is gone by the time anything could ask whether the decoder still fits.
Play_Src_Snap :: struct {
	had_decoder:   bool,
	old_content:   i64, // content 48 kHz sample the decoder was anchored for, -1 if none
	action:        Reconcile_Action,
	touched_window: bool,
}

// play_src_content_at is the 48 kHz CONTENT sample a decoder must sit at to play
// timeline frame f, given the segment that covers it.
//
// This is the number a reconcile compares, and comparing it is the whole design:
// a decoder is a forward-only stream over content positions, so it remains valid
// exactly when this value is unchanged. Everything else about a source -- where
// its segments start and end in the timeline, how long they are, their gains -- is
// metadata the mix re-reads every frame, so changing any of it costs nothing as
// long as the content the decoder is sitting on has not moved.
play_src_content_at :: proc(seg: ^Play_Seg, f: i64) -> i64 {
	if seg == nil {
		return -1
	}
	seek_frame := max(f, seg.start_a)
	return i64(
		audio_content_sec(seek_frame - seg.start_a, seg.start_s, seg.start_s_rate, timeline_fps()) *
			48000.0,
	)
}

// play_src_touches_window reports whether any of s's segments overlap the frames
// the device queue still holds. The queue covers roughly [playhead, next_frame],
// so a segment inside it means already-mixed audio that this edit invalidates --
// a decoder may be perfectly reusable while the queue in front of it is wrong.
play_src_touches_window :: proc(s: ^Play_Src, from, to: i64) -> bool {
	for i in 0 ..< s.seg_count {
		sg := &s.seg[i]
		if sg.start_a < to && sg.start_a + sg.len_a > from {
			return true
		}
	}
	return false
}

// Audio_Sources is the producer's live decoder set: one slot per source
// stream (bounded by MAX_PLAY_AUDIO), the live count, and a one-shot overflow
// log so silent clip-drop on that path is never invisible.
Audio_Sources :: struct {
	slots:      [MAX_PLAY_AUDIO]Play_Src,
	count:      int,
	overflow:   bool,
	// next_frame is the next timeline frame for the producer to mix/feed.
	next_frame: i64,
}
audio_src: Audio_Sources

// Audio_Producer is the producer-thread control/clock state. The UI thread
// writes the anchor fields + bumps resync_evt; the producer owns all
// decoder/fifo state. All *_flag / *_evt / anchor / prod_frame fields are
// atomics.
Audio_Producer :: struct {
	thread:   ^thread.Thread,
	stop:     bool, // shutdown request (atomic)
	done:     bool, // producer exited (atomic)
	run:      bool, // false pauses the device and frees sources (atomic)
	resync:   i64, // bump forces clear + re-provision at the anchor (atomic)
	// anchor_frame is the playhead frame the UI last seeded for a resync
	// (atomic); anchor_now is monotonic_ns() when that frame was seeded.
	anchor_frame: i64,
	anchor_now:   i64,
	// prod_frame is the producer's current content frame, published for the
	// UI's drift check (atomic).
	prod_frame: i64,
	// jump_frame is a forward-only skip target (0 = none). The UI sets it when
	// the playhead outruns the audio producer; the producer trims its fifos and
	// advances in place instead of tearing the decoder down and relooping.
	jump_frame: i64,
	// src_count_ui is a UI-readable atomic mirror of the producer's current
	// source count. The UI uses it to self-heal the producer: if audio is
	// playing but NO sources are provisioned while the timeline has audio
	// covering the playhead, the engine is silently dead — force a
	// re-provision rather than play muted for the rest of the run.
	// (A transient open/seek failure in audio_provision can otherwise drop the
	// only clip and never recover.)
	//
	// provisioning is true while a provision is in flight (producer thread).
	// A provision zeroes the count during its run, so the self-heal must NOT
	// fire on that transient zero — that turns every slow re-open into a
	// re-provision storm (see audio_update). The self-heal may only trip once a
	// provision has COMPLETED with zero surviving sources.
	src_count_ui: i64,
	provisioning: bool,
	was_playing:  bool,
	last_ui_frame: i64,
}
audio_prod: Audio_Producer
// Audio_Report is the A/V telemetry block: per-report counters reset each
// interval, the monotonic totals that never clear, the last-report snapshot
// values, and the env-driven log toggles. Producer thread accumulates most of
// it; the UI reads it for the drift panel.
Audio_Report :: struct {
	// Last-report snapshot (read for the on-screen meters).
	tick:         u64,
	frame:        i64,
	queued:       i64, // bus sample-frames in the device bridge at last report
	holes:        i64,
	fed:          u64, // total_fed_frames at last report (for true bus rate)
	// head_clamped counts, and head_clamp_max records the largest, the times the
	// mixer's `demand48 = max(demand48, s.first48)` had to move a frame's demand
	// FORWARD to meet a decoder that had landed ahead of it.
	//
	// This used to be invisible, and it is not a neutral safety net: mixing from
	// the head instead of from the position the timeline asked for shifts that
	// frame's whole content, silently, with nothing counting it. Measured at
	// 30000/1001: playback mixed a 1601-sample frame from 1786 samples past where
	// the frame began, which is a content shift nobody would ever hear about.
	// A count is the minimum; the fix is to stop needing it.
	head_clamped:   i64,
	head_clamp_max: i64,
	// Monotonic totals, never cleared by reseeds.
	total_fed_frames: u64,
	// playhead-writer labels for the drift diagnostics: ph_src is the last
	// writer of playhead.frame (1=mouse scrub, 2=auto catch-up burst); ph_catch
	// is the frames jumped in the last auto catch-up burst (atomic on writer
	// side).
	ph_src:   i64,
	ph_catch: i64,
	// Per-report feed/mix statistics (producer thread only, reset at each
	// report).
	push:         u64, // pushes into the device bridge ring
	skip_full:    u64, // feed() exits because the ring hit max_queue
	skip_nocov:   u64, // feed() exits because no clip covers the next frame
	rate_rebuilt: u64, // rate-graph (re)builds that re-anchored to the playhead
	// provisions counts full re-provisions on the producer thread: every one
	// clears the device queue and reopens EVERY decoder synchronously, so this
	// is the cost of telling the engine "the timeline changed". A burst of
	// edits that produces one provision per edit is the audio-restart storm.
	provisions: u64,
	// reconciles counts edits folded into the live decoder set instead of
	// re-provisioning it, with what each one did: dec_kept decoders were left
	// running because their content position had not moved, dec_seek were
	// re-anchored, dec_open were opened, dec_drop released. provisions counts the
	// from-zero opens. A design meant to avoid reopens that quietly reopens anyway
	// is indistinguishable from one that works until it does not, which is why
	// these are on the report line rather than in a comment.
	reconciles: u64,
	dec_kept:   u64,
	dec_seek:   u64,
	dec_open:   u64,
	dec_drop:   u64,
	// queue_clears counts reconciles that had to drop the device queue, i.e. the
	// ones a user hears as a gap. It is deliberately separate from dec_open: a
	// reconcile can keep every decoder and still have to clear, because the queue
	// holds audio mixed for the old geometry.
	queue_clears: u64,
	// slots_new counts slots allocated FRESH during a build, i.e. groups that did
	// not land in a slot already holding a decoder for that stream. It is the
	// direct measure of the reclaim path, and the reason it exists: a reconcile
	// that keeps a decoder is only really keeping it if the new segments landed in
	// the slot that decoder is in. Building into a fresh slot instead leaves the
	// real one empty and dropped, which reports as an Open for every source and
	// looks from the outside exactly like the re-provision it replaced.
	slots_new:   u64,
	mix_us:       u64, // time spent inside audio_mix_frame (decode + resample + mix)
	feed_us:      u64, // time spent in audio_producer_feed outside mix
	min_q:        i64, // smallest queue depth (frames) seen in the window
	// starve_ticks counts producer passes that found the device queue below a
	// quarter of the cushion while playing, and starve_frames sums how far below.
	// This is the invariant the whole audio-master design rests on: if the queue
	// never starves and nothing re-anchors, the offset between the content FED and
	// the content HEARD is zero forever -- not small, not bounded, zero.
	//
	// It was unmeasurable, because a starvation was silently REPAIRED: the wedge
	// watchdog drops the backlog and the forward-skip re-anchors the producer to
	// the extrapolated playhead. Those repairs are why the engine needs a skew
	// alarm at all, and they are what lets a drift bug survive -- the symptom stops
	// and the pressure to find its cause goes with it. Counting FIRST, before
	// changing any behaviour, is what says whether the invariant already holds.
	starve_ticks:  u64,
	starve_frames: i64,
	// queue_established latches once the device queue has reached the full cushion,
	// i.e. the producer has genuinely caught up. Starvation before that is the
	// startup fill, not a stall.
	queue_established: bool,
	max_q:        i64, // largest queue depth (frames) seen in the window
	// Log/env toggles. VYPER_AUDIO_LOG=ms overrides the report interval
	// (default 1000 ms); VYPER_AUDIO_FULL=1 adds per-source fifo lines and
	// playhead-jump logging.
	log_ms:    i64,
	log_full:  bool,
	trace:     bool,
	thread_start_ns: u64,
	// silence_holes counts fed frames that were silence while a clip covered
	// them (decode/seek holes, producer thread accumulates it).
	silence_holes: i64,
	dbg_budget:    int,
}
audio_rpt: Audio_Report
// Audio_Dump is the DIAG output-file state: the streamed PCM firehose and the
// headless decode dump (dec.s16, pre-mix). Both nil until their env vars open
// them; headless-only on the decode side.
Audio_Dump :: struct {
	pcm:     ^os.File,
	pcm_path: string,
	dec:     ^os.File, // dumps dec.s16 immediately after decode_audio_chunk (pre-mix)
}
audio_dump: Audio_Dump

audio_dec_dump_open :: proc() {
	if audio_dump.dec != nil || os.get_env_alloc("VYPER_DECDUMP", context.temp_allocator) == "" {
		return
	}
	path := os.get_env_alloc("VYPER_DECDUMP", context.temp_allocator)
	f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Read_Write_All)
	if err == nil {
		audio_dump.dec = f
		fmt.printf("[audio] dec dump -> %s\n", path)
	}
}

audio_pcm_dump_open :: proc() {
	if audio_dump.pcm != nil || os.get_env_alloc("VYPER_PCMDUMP", context.temp_allocator) == "" {
		return
	}
	path := os.get_env_alloc("VYPER_PCMDUMP", context.temp_allocator)
	f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Read_Write_All)
	if err == nil {
		audio_dump.pcm = f
		audio_dump.pcm_path = path
		fmt.printf("[audio] pcm dump -> %s\n", path)
	}
}
// The producer never touches live timeline memory. The UI thread publishes the
// audio clip geometry into a double-buffered slab (audio_geometry_commit on
// every edit); the producer reads whichever slot is active, lock-free. Both
// slots are fixed arrays with permanent addresses, so a swap is a single atomic
// index store and the publisher never frees memory the producer may still be
// reading. Paths are packed into a per-slot byte arena instead of inlined in
// each chip (a chip here is ~50 bytes of metadata plus the flat gain keyframe
// snapshot, so the bound is memory-proportional rather than KBs per clip), and
// it sits far above any real project.
AUDIO_GEOM_MAX_CLIPS :: 4096
AUDIO_GEOM_PATH_ARENA :: 1 << 20 // bytes of packed path data per slot
// GAIN_KF_MAX_KEYS caps a chip/segment's copied gain keyframe track. The audio
// producer owns its snapshot (it must never read the live timeline), so a
// keyed gain track is copied here flat. A track past the cap keeps its first
// keys and logs once — truncation is silent data loss otherwise.
GAIN_KF_MAX_KEYS :: 64

// Audio_Gain_Snapshot is the ONE committed form of a clip's gain: the static
// level in dB plus a flat copy of its "gain" keyframe track (n = 0 = static).
// The committed geometry slab stores it, the playback producer latches a copy
// of it when it provisions a segment, and the export job carries a copy of it
// for the render's frozen view. All three read the same shape and evaluate it
// through audio_gain_linear, so a key's dB value can never again be mistaken
// for a linear multiplier on one path but not the other — the duplication that
// let playback honor a keyed gain while the export applied none.
Audio_Gain_Snapshot :: struct {
	db:   f32,
	keys: [GAIN_KF_MAX_KEYS]Keyframe,
	n:    int,
}

// audio_gain_snapshot_from_clip snapshots a clip's gain track into the shared
// shape. `total` is the track's real key count (may exceed the cap); callers
// log truncation when total > GAIN_KF_MAX_KEYS. UI-thread only (reads the live
// clip); the snapshot is what crosses to the worker threads.
audio_gain_snapshot_from_clip :: proc(clip: ^Clip) -> (g: Audio_Gain_Snapshot, total: int) {
	g.db = clip.gain
	g.n, total = kf_fill_snapshot(clip, "gain", g.keys[:])
	return
}

// audio_gain_linear evaluates a committed gain snapshot to a LINEAR amplitude
// multiplier at clip-relative frame `rel`. Thin wrapper over kf_gain_linear so
// both mixers evaluate the same shape the same way.
audio_gain_linear :: proc(g: ^Audio_Gain_Snapshot, rel: i32) -> f32 {
	return kf_gain_linear(g.keys[:g.n], rel, g.db)
}

// AUDIO_GEOM_SLOTS is how many geometry slots exist. Three, not two, and the
// reason is the READER'S HOLD TIME: the producer does not read the slab for a
// moment, it reads it for a whole provision (every decoder reopened, tens of
// ms) while the UI rewrites the slab on every edit. With two slots, two commits
// inside one provision wrap the index around and the second lands on the slot
// the provision is still reading. The writer skips the published slot AND the
// one the reader has claimed, so with one reader three slots always leave one
// free -- no waiting, no torn read.
AUDIO_GEOM_SLOTS :: 3
// AUDIO_GEOM_NO_SLOT is the "no reader" claim value (u32, so it cannot collide
// with a slot index).
AUDIO_GEOM_NO_SLOT :: u32(0xFFFFFFFF)

Audio_Geom_Chip :: struct {
	timeline_start: i64,
	source_start:   i64,
	source_len:     i64,
	// source_rate pins the rate source_start is counted against, carried with
	// the clip so the producer converts it without reading live timeline state
	// (see audio_source_start_sec).
	source_rate:   f64,
	stream_index:  c.int,
	gain:          Audio_Gain_Snapshot,
	path_off:      int, // offset into Audio_Geom_Slot.paths
	path_len:      int,
}

Audio_Geom_Slot :: struct {
	n:         int,
	path_used: int,
	paths:     [AUDIO_GEOM_PATH_ARENA]u8,
	chip:      [AUDIO_GEOM_MAX_CLIPS]Audio_Geom_Chip,
}

// Audio_Geom is the geometry slab + its handshake: the slots, the atomic index
// of the active slot, the producer's claim on the slot it holds, the gain epoch
// pair that lets the producer
// fold gain changes in place, and the two one-shot overflow logs.
Audio_Geom :: struct {
	// slots are the fixed-address buffers; idx is the atomically-swapped
	// active slot. reader is the slot the producer currently holds (or
	// NO_SLOT): the writer must not start filling it. Only the producer claims
	// or releases; the UI only reads it to choose a slot, and publishes idx so
	// the next claim lands on a slot nobody is in.
	//
	// gain_epoch counts published gain changes (UI bumps it after
	// a commit whose clips' gains differ from the previous slot); the producer
	// compares it against gain_folded_epoch (producer-thread only) and folds
	// the new gains into its provisioned segments in place. A gain-knob drag
	// during playback must be audible within the cushion; a seek per knob move
	// would reopen every decoder (~16 ms each) and chop the stream on every
	// nudge. gain_epoch is published AFTER the slot index swap.
	slots:      [AUDIO_GEOM_SLOTS]Audio_Geom_Slot,
	idx:        u32, // atomic: active slot
	reader:     u32, // atomic: slot the producer holds, or AUDIO_GEOM_NO_SLOT
	gain_epoch: u64,
	gain_folded_epoch: u64,
	// overflow logs once when the timeline holds more audio clips (or more
	// path bytes) than a fixed slab can carry, so the dropped tail is visible.
	overflow:   bool,
	// kf_trunc_logged logs once when a gain keyframe track is capped.
	kf_trunc_logged: bool,
}
audio_geom_state: Audio_Geom

// audio_chip_path resolves a chip's path from its slot's packed arena.
audio_chip_path :: proc(slot: ^Audio_Geom_Slot, chip: ^Audio_Geom_Chip) -> string {
	return string(slot.paths[chip.path_off : chip.path_off + chip.path_len])
}

audio_src_reset :: proc(s: ^Play_Src) {
	if s.dec.opened {
		audio_decoder_reset(&s.dec)
	}
	ring_destroy(&s.fifo)
	if s.path != nil {
		mem.delete_cstring(s.path)
		s.path = nil
	}
	s^ = {}
}

// audio_reset_play is producer-thread only: frees all decoders/fifos.
audio_reset_play :: proc() {
	for i in 0 ..< MAX_PLAY_AUDIO {
		audio_src_reset(&audio_src.slots[i])
	}
	audio_src.count = 0
	sync.atomic_store(&audio_prod.src_count_ui, 0)
	audio_src.next_frame = 0
}

// audio_geom_acquire claims a slot to read for as long as the caller needs and
// returns it. The claim is what stops audio_geometry_commit from filling the
// slot under the reader; pair every acquire with audio_geom_release (defer it).
//
// Order matters and is the whole protocol: take idx first, then publish the
// claim. The reverse order would let a commit that starts in between pick the
// very slot this call is about to read -- the reader would announce its claim
// for a slot the writer has already begun overwriting.
audio_geom_acquire :: proc() -> ^Audio_Geom_Slot {
	i := sync.atomic_load(&audio_geom_state.idx)
	sync.atomic_store(&audio_geom_state.reader, i)
	return &audio_geom_state.slots[i]
}

// audio_geom_release drops the claim so the writer may reuse the slot.
audio_geom_release :: proc() {
	sync.atomic_store(&audio_geom_state.reader, AUDIO_GEOM_NO_SLOT)
}

// audio_geom_write_slot picks the slot the UI may fill: neither the published
// one (a reader that just loaded idx is reading it) nor the one the producer
// holds. Three slots, at most two excluded, so this never has to wait.
audio_geom_write_slot :: proc() -> int {
	pub := int(sync.atomic_load(&audio_geom_state.idx))
	held := int(sync.atomic_load(&audio_geom_state.reader))
	for i in 0 ..< AUDIO_GEOM_SLOTS {
		if i != pub && i != held {
			return i
		}
	}
	// Unreachable: pub and held exclude at most two of three slots. Asserted
	// rather than returned as a valid index, because falling through would
	// overwrite the published slot and corrupt a live reader.
	assert(false, "audio_geom_write_slot: no free slot")
	return pub
}

// audio_geometry_commit re-mirrors the audio clip geometry from the timeline
// into the inactive slab slot and publishes it. UI-thread only (the timeline's
// single writer). Rebuilding the whole chip array per edit is cheap — the
// timeline holds tens of clips, not millions.
audio_geometry_commit :: proc() {
	write := audio_geom_write_slot()
	slot := &audio_geom_state.slots[write]
	slot.n = 0
	slot.path_used = 0
	read := int(sync.atomic_load(&audio_geom_state.idx))
	gains_moved := false
	for tr in 0 ..< len(timeline.tracks) {
		for c in 0 ..< len(timeline.tracks[tr].clips) {
			clip := &timeline.tracks[tr].clips[c]
			if clip.kind != .Audio {
				continue
			}
			path := string(clip.path)
			if slot.n >= AUDIO_GEOM_MAX_CLIPS || slot.path_used + len(path) > AUDIO_GEOM_PATH_ARENA {
				if !audio_geom_state.overflow {
					fmt.printf("[audio] geometry truncated (max %d clips / %d path bytes); later timeline clips are muted\n", AUDIO_GEOM_MAX_CLIPS, AUDIO_GEOM_PATH_ARENA)
					audio_geom_state.overflow = true
				}
				sync.atomic_store(&audio_geom_state.idx, u32(write))
				return
			}
			// Gain-change detection compares against the same-index chip of the
			// previously published slot. Both slots are rebuilt every commit by
			// the same track/clip iteration, so while the clip set is static
			// (the gain knob drag case) the indexes correspond exactly; when a
			// structural edit shifts them, the producer's audio_seek re-provision
			// re-reads gains afresh anyway, so a false missed bump is harmless.
			if !gains_moved && slot.n < audio_geom_state.slots[read].n && audio_geom_state.slots[read].chip[slot.n].gain.db != clip.gain {
				gains_moved = true
			}
			chip := &slot.chip[slot.n]
			chip.timeline_start = clip.timeline_start_frame
			chip.source_start = clip.source_start_frame
			chip.source_rate = clip.audio_src_rate
			chip.source_len = clip.source_length_frames
			chip.stream_index = clip.stream_index
			// Snapshot the clip's gain (static dB + its keyframe track) into the
			// shared committed shape. kf_fill_snapshot renders the name; the
			// geometry commit is UI-thread so reading the live clip is safe.
			g, total := audio_gain_snapshot_from_clip(clip)
			chip.gain = g
			if g.n > 0 && total > GAIN_KF_MAX_KEYS && !audio_geom_state.kf_trunc_logged {
				fmt.printf("[audio] gain keyframe track exceeds GAIN_KF_MAX_KEYS=%d; keeping the first %d keys\n", GAIN_KF_MAX_KEYS, g.n)
				audio_geom_state.kf_trunc_logged = true
			}
			chip.path_off = slot.path_used
			chip.path_len = len(path)
			mem.copy(raw_data(slot.paths[slot.path_used:]), raw_data(path), len(path))
			slot.path_used += len(path)
			slot.n += 1
		}
	}
	sync.atomic_store(&audio_geom_state.idx, u32(write))
	// Publish the epoch only after the slot index, so the producer never folds
	// new-gains metadata against the old slot it might still read.
	if gains_moved {
		sync.atomic_store(&audio_geom_state.gain_epoch, sync.atomic_load(&audio_geom_state.gain_epoch) + 1)
	}
}

// audio_gain_fold copies the published clip gains into the provisioned
// segments in place, matching each chip to its segment by path/stream and the
// timeline-span key the chip was provisioned with (audio_provision's
// Play_Seg{start_a, start_s, len_a} == {timeline_start, source_start,
// source_len}). Producer-thread only; neither decoders nor the playhead move,
// so a live gain drag is audible within the cushion with no reopen storm.
// Segments whose key no chip matches (rare: a provision from a stale slot
// right after a structural edit) keep the earlier gain; the governing audio_seek
// re-provisions them.
audio_gain_fold :: proc(slot: ^Audio_Geom_Slot) {
	for ci in 0 ..< slot.n {
		chip := &slot.chip[ci]
		path := audio_chip_path(slot, chip)
		for k in 0 ..< audio_src.count {
			s := &audio_src.slots[k]
			if s.seg_count == 0 || s.stream_index != chip.stream_index || string(s.path) != path {
				continue
			}
			for si in 0 ..< s.seg_count {
				seg := &s.seg[si]
				if seg.start_a == chip.timeline_start && seg.start_s == chip.source_start && seg.len_a == chip.source_len {
					// Fold the new static level in place. The keyed curve is
					// unchanged by a gain-knob drag, so only the base moves here;
					// a structural/keyed change routes through re-provision.
					seg.gain.db = chip.gain.db
					break
				}
			}
		}
	}
}

// audio_note_edit tells the producer the clip set or playhead changed out of
// band (split, delete, clip move, fps change) so it re-seeks at the playhead.
// The geometry commit runs first so the producer's next provision reads the
// new state.
audio_note_edit :: proc() {
	audio_geometry_commit()
	if !audio_device_ready() {
		return
	}
	audio_seek(playhead.frame)
}

// play_src_seg_at returns the segment of s covering timeline frame f, or nil.
// Segments of one source are non-overlapping in timeline order (an overlapping
// or reordered run is given its own Play_Src at provision).
play_src_seg_at :: proc(s: ^Play_Src, f: i64) -> ^Play_Seg {
	for i in 0 ..< s.seg_count {
		sg := &s.seg[i]
		if f >= sg.start_a && f < sg.start_a + sg.len_a {
			return sg
		}
	}
	return nil
}

// play_src_first_seg_at returns the first segment of s ending after frame f
// (the one whose content the decoder should be anchored to), or nil if the
// whole stream is behind the playhead.
play_src_first_seg_at :: proc(s: ^Play_Src, f: i64) -> ^Play_Seg {
	for i in 0 ..< s.seg_count {
		sg := &s.seg[i]
		if f < sg.start_a + sg.len_a {
			return sg
		}
	}
	return nil
}

// audio_provision_find_group returns the existing group that chip continues
// exactly (same path/stream, contiguous with its last segment in both timeline
// and source), or nil when chip must start a new group. A split produces the
// contiguous case; everything else keeps a forward-only fifo correct.
audio_provision_find_group :: proc(
	slot: ^Audio_Geom_Slot,
	chip: ^Audio_Geom_Chip,
	reclaim: ^[MAX_PLAY_AUDIO]bool,
) -> ^Play_Src {
	chip_path := audio_chip_path(slot, chip)
	// First: continue a group this pass has already started. A split's second half
	// lands here, which is what keeps a linked group on ONE forward-only decoder.
	for k in 0 ..< audio_src.count {
		g := &audio_src.slots[k]
		if g.seg_count == 0 || g.stream_index != chip.stream_index {
			continue
		}
		if string(g.path) != chip_path {
			continue
		}
		last := &g.seg[g.seg_count - 1]
		if last.start_a + last.len_a == chip.timeline_start &&
		   last.start_s + last.len_a == chip.source_start {
			return g
		}
	}
	// Second: reclaim a slot this pass emptied that already holds a live decoder
	// for this stream.
	//
	// This is load-bearing, and its absence is invisible until measured. A
	// reconcile clears every seg_count before rebuilding, so the loop above --
	// which requires seg_count > 0 -- cannot match anything, and the group is built
	// in a FRESH slot at the end. The slot holding the real decoder is then left
	// empty and dropped, and the stream that was already open gets opened again.
	// The reconcile then reports Open for every source and looks, from the outside,
	// exactly like the re-provision it replaced. Only one group per stream may
	// claim a reclaimed slot; a second non-contiguous group needs its own decoder.
	for k in 0 ..< audio_src.count {
		if !reclaim[k] {
			continue
		}
		g := &audio_src.slots[k]
		if g.path == nil || g.stream_index != chip.stream_index {
			continue
		}
		if string(g.path) != chip_path {
			continue
		}
		reclaim[k] = false
		return g
	}
	return nil
}

// audio_build_groups folds the committed chips into one group per contiguous run
// of a source stream, APPENDING into audio_src.slots and growing audio_src.count.
// Every split of a linked group lands in one group, so a project with N tracks and
// any number of splits needs N decoders.
//
// It opens nothing, seeks nothing, and resets nothing: it is the metadata half,
// split out of audio_provision precisely so a reconcile can run it over a live
// decoder set and decide afterwards what to keep. Callers must leave every slot's
// seg_count at 0 on entry.
//
// A slot's decoder, fifo and cloned path are left alone -- that is the point.
audio_build_groups :: proc(slot: ^Audio_Geom_Slot, reclaim: ^[MAX_PLAY_AUDIO]bool) {
	for i in 0 ..< slot.n {
		chip := &slot.chip[i]
		g := audio_provision_find_group(slot, chip, reclaim)
		if g == nil {
			if audio_src.count >= MAX_PLAY_AUDIO {
				if !audio_src.overflow {
					fmt.printf(
						"[audio] provision: %d source streams exceed MAX_PLAY_AUDIO=%d; later clips are muted\n",
						audio_src.count + 1,
						MAX_PLAY_AUDIO,
					)
					audio_src.overflow = true
				}
				continue
			}
			audio_rpt.slots_new += 1
			g = &audio_src.slots[audio_src.count]
			if g.path != nil {
				// Defensive: cloning a path over a live one would leak the
				// cstring. A slot past the provisioned range cannot be in this
				// state, so this should be unreachable -- which is why it is an
				// assert on the invariant rather than a silent overwrite.
				assert(g.path == nil, "fresh group slot already owns a path")
			}
			g.path = strings.clone_to_cstring(audio_chip_path(slot, chip))
			g.stream_index = chip.stream_index
			audio_src.count += 1
		}
		if g.seg_count >= MAX_PLAY_SEGMENTS {
			continue
		}
		g.seg[g.seg_count] = Play_Seg{
			start_a      = chip.timeline_start,
			start_s      = chip.source_start,
			start_s_rate = chip.source_rate,
			len_a        = chip.source_len,
			gain         = chip.gain,
		}
		g.seg_count += 1
	}
}

// audio_anchor_sources resolves every group in audio_src.slots according to
// snap[slot].action -- keep, seek or open -- then compacts out the groups with
// nothing left to play. Producer-thread only.
//
// Compaction happens after every decision is made, so the decisions can be indexed
// by the slot the snapshot was taken from; the decoder and fifo travel with the
// struct when a slot moves.
audio_anchor_sources :: proc(play_frame: i64, fps: f64, snap: ^[MAX_PLAY_AUDIO]Play_Src_Snap) {
	w := 0
	for r in 0 ..< audio_src.count {
		s := &audio_src.slots[r]
		seg := play_src_first_seg_at(s, play_frame)
		if seg == nil {
			// The whole stream is behind the playhead: no future content.
			audio_src_reset(s)
			continue
		}
		seek_frame := max(play_frame, seg.start_a)
		content_sec := audio_content_sec(seek_frame - seg.start_a, seg.start_s, seg.start_s_rate, fps)
		switch snap[r].action {
		case .Keep:
			// Nothing to do. The decoder is anchored to the right content and its
			// fifo is content-relative, so both remain correct as they are -- in
			// particular the audio already sitting in that fifo must NOT be dropped,
			// because it is the audio for exactly the position we are keeping.
		case .Seek:
			if !audio_src_seek_anchor(s, content_sec) {
				audio_src_reset(s)
				continue
			}
		case .Open:
			if !audio_src_open(s, content_sec) {
				audio_src_reset(s)
				continue
			}
		}
		if w != r {
			audio_src.slots[w] = audio_src.slots[r]
			audio_src.slots[r] = {}
		}
		w += 1
	}
	audio_src.count = w
	sync.atomic_store(&audio_prod.src_count_ui, i64(audio_src.count))
}

// audio_provision opens one decoder per source stream from scratch, anchored so
// play_frame is covered by that stream's first segment at or after it. This is
// the from-zero path, for a seek or a fresh start: it throws away every decoder
// and pays for all of them, which is correct when there is no reason to believe
// any of them is still aimed at the right content.
//
// For an EDIT use audio_reconcile, which reaches the same end state while keeping
// every decoder whose content position did not move.
//
// Producer-thread only; reads the committed double-buffered geometry slab instead
// of live timeline memory, so it never waits on the UI thread's edits.
audio_provision :: proc(play_frame: i64) {
	sync.atomic_store(&audio_prod.provisioning, true)
	defer sync.atomic_store(&audio_prod.provisioning, false)
	atempo_reset(&audio_atempo) // graph window may hold pre-provision samples
	audio_dec_dump_open()
	audio_reset_play()
	audio_src.next_frame = play_frame
	sync.atomic_store(&audio_prod.prod_frame, play_frame)
	audio_rpt.dbg_budget = 8
	fps := timeline_fps()
	// Held for the WHOLE provision: this is the long read the three-slot scheme
	// exists for. Released on every exit below.
	slot := audio_geom_acquire()
	defer audio_geom_release()
	// audio_reset_play cleared every slot, so there is nothing to reclaim.
	no_reclaim: [MAX_PLAY_AUDIO]bool
	audio_build_groups(slot, &no_reclaim)
	snap: [MAX_PLAY_AUDIO]Play_Src_Snap
	for i in 0 ..< audio_src.count {
		snap[i] = {action = .Open}
	}
	audio_anchor_sources(play_frame, fps, &snap)
}

// audio_reconcile folds a new geometry into the LIVE decoder set, keeping every
// decoder whose content position is unchanged and re-anchoring only what moved.
// Producer-thread only, on the resync generation.
//
// This is the answer to the cost audio_note_edit used to pay: a clip move or trim
// went through audio_seek, which cleared the device queue and re-provisioned, and
// re-provisioning reopens EVERY decoder synchronously -- its own comment prices
// that at hundreds of milliseconds once several streams are open, all of it on the
// path between the user finishing a drag and hearing the result. Gain had already
// been given this treatment (gain_epoch / audio_gain_fold); edits had not.
//
// The decision is one comparison per source. A decoder is a forward-only stream
// over content positions, so it stays valid exactly when the content position it
// sits at is the same one it was anchored to. When it is, the decoder, its fifo
// and the audio already in that fifo are all still correct, and nothing is opened,
// sought, or dropped.
//
// Returns what it did. The caller uses touched_window to decide about the device
// queue -- see the note there, because that is the half of a resync a user hears.
audio_reconcile :: proc(play_frame: i64) -> Reconcile_Report {
	rep: Reconcile_Report
	sync.atomic_store(&audio_prod.provisioning, true)
	defer sync.atomic_store(&audio_prod.provisioning, false)
	audio_rpt.dbg_budget = 8
	fps := timeline_fps()
	slot := audio_geom_acquire()
	defer audio_geom_release()

	// Snapshot each decoder's anchor BEFORE the segment lists are rebuilt.
	queued_to := audio_src.next_frame
	snap: [MAX_PLAY_AUDIO]Play_Src_Snap
	reclaim: [MAX_PLAY_AUDIO]bool
	for i in 0 ..< audio_src.count {
		src := &audio_src.slots[i]
		snap[i].had_decoder = src.dec.opened
		snap[i].old_content = play_src_content_at(play_src_first_seg_at(src, play_frame), play_frame)
		snap[i].touched_window = play_src_touches_window(src, play_frame, queued_to)
		src.seg_count = 0
		// Offered back to the builder: this slot's decoder is a candidate to keep,
		// and it has to be the slot the new segments land in for that to happen.
		reclaim[i] = true
	}
	audio_build_groups(slot, &reclaim)

	for i in 0 ..< audio_src.count {
		src := &audio_src.slots[i]
		// The segments the edit ADDS invalidate queued audio too, not just the
		// ones it removed.
		snap[i].touched_window =
			snap[i].touched_window || play_src_touches_window(src, play_frame, queued_to)
		rep.touched_window = rep.touched_window || snap[i].touched_window
		if src.seg_count == 0 {
			// This stream is gone from the geometry. Drop its decoder -- it is
			// holding a file open for nothing -- but keep the count honest.
			if snap[i].had_decoder {
				audio_src_reset(src)
				rep.dropped += 1
			}
			continue
		}
		new_content := play_src_content_at(play_src_first_seg_at(src, play_frame), play_frame)
		if new_content < 0 {
			// Segments exist but none covers or follows the playhead, so this
			// source has no future content and its decoder is holding a file open
			// for nothing. Dropped HERE rather than left to the anchor pass with a
			// meaningless action, so that every branch below assigns an action the
			// anchor pass will actually carry out.
			audio_src_reset(src)
			rep.dropped += 1
			continue
		}
		if !snap[i].had_decoder {
			// A stream this pass created: its slot index is past the ones snapshotted,
			// so had_decoder is false and there is no decoder to keep or seek.
			snap[i].action = .Open
			rep.opened += 1
		} else if new_content == snap[i].old_content {
			snap[i].action = .Keep
			rep.kept += 1
		} else {
			snap[i].action = .Seek
			rep.sought += 1
		}
	}

	// The rate graph's window holds samples mixed for the PREVIOUS geometry. It
	// is only stale if something was re-anchored; when every decoder was kept the
	// samples in it are the samples the kept decoders just produced.
	if rep.sought > 0 || rep.opened > 0 {
		atempo_reset(&audio_atempo)
	}
	audio_anchor_sources(play_frame, fps, &snap)

	// The queue is the audible half of a resync. If it held audio this edit
	// invalidated, those frames have to be re-fed, and the producer has to rewind
	// to the playhead rather than carry on from next_frame -- otherwise it would
	// skip exactly the range that was just thrown away.
	if rep.touched_window {
		audio_src.next_frame = play_frame
		sync.atomic_store(&audio_prod.prod_frame, play_frame)
	}
	return rep
}

// audio_src_append converts n interleaved S16 frames from dec.s16 into
// stereo f32 and appends them to the source fifo.
// audio_src_dump_dec writes dec.s16 to VYPER_DECDUMP verbatim (stereo S16)
// between the decoder and the fifo/mix, so the decode stage can be validated
// in isolation against the source PCM.
audio_src_dump_dec :: proc(s: ^Play_Src, n: int) {
	if s == nil || n <= 0 {
		return
	}
	ff := audio_dump.dec
	if ff == nil {
		return
	}
	bytes := mem.slice_ptr(cast([^]u8)raw_data(s.dec.s16[:]), n * 2 * 2)
	nw, werr := os.write(ff, bytes)
	if werr != nil || nw != len(bytes) {
		fmt.printf("[audio] dec dump write err=%s n=%d/%d\n", werr, nw, len(bytes))
		os.close(ff)
		audio_dump.dec = nil
	}
}
// audio_src_append converts+enqueues the n newly-decoded stereo sample-frames
// in s.dec.s16 to the tail of s.fifo in one bulk operation (see
// ring_push_pcm), instead of two per-sample append() calls in a loop -- each
// append() pays a length-check/possible-growth branch; reserving once for the
// whole chunk avoids that per-sample overhead on the real-time producer
// thread.
audio_src_append :: proc(s: ^Play_Src, n: int) {
	ring_push_pcm(&s.fifo, s.dec.s16[:n * 2], n)
}

// audio_src_pull decodes forward until the fifo covers up_to48 content samples.
// The decoder continues sequentially from wherever it is; re-anchoring happens
// via audio_provision (fresh group) or audio_src_seek_anchor (a jump that
// advanced past content still needed).
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

// audio_src_open opens s's decoder and anchors it at content second
// `content_sec` (see audio_src_seek_anchor). Returns false on open/seek failure
// so the caller can drop the group.
// decoder_pts_sample converts a decoded frame's PTS into a bus Sample_Pos.
//
// Rescaled straight from the stream's own time base into 1/48000, so it is exact
// integer arithmetic. It replaces `i64(real_sec * 48000)` where real_sec was
// microseconds-as-f64 divided by 1e6 -- and that is not a cosmetic change: the
// fifo base it produces is compared against a demand that is now computed in
// exact samples (audio_content_sample), so the two had to be brought onto the
// same arithmetic or an off-by-one that moves with position reappears at the
// comparison instead of at the conversion. Pinned by parity_probe property 5.
decoder_pts_sample :: proc(ts: c.int64_t, time_base: avutil.Rational) -> Sample_Pos {
	return Sample_Pos(
		avutil.rescale_q(ts, time_base, avutil.Rational{num = 1, den = AUDIO_BUS_RATE}),
	)
}

audio_src_open :: proc(s: ^Play_Src, content_sec: f64) -> bool {
	if !open_audio_decoder_resampled(&s.dec, s.path, s.stream_index, 48000, 2) {
		return false
	}
	return audio_src_seek_anchor(s, content_sec)
}

// audio_src_seek_anchor (re)seeks s's decoder to content second `content_sec`
// with AUDIO_SEEK_PREROLL_SEC of headroom and refills the fifo, relabeling its
// base to the decoder's real landing PTS. An AAC seek can land tens of ms after
// the asked position; labeling the fifo with the asked time would compound that
// offset every frame and drift the content against the playhead (reads as
// half-speed), while not seeking early enough leaves the segment head silent.
audio_src_seek_anchor :: proc(s: ^Play_Src, content_sec: f64) -> bool {
	// One proc for the opening, shared with the export. This used to clamp the
	// preroll seek to zero and then take whatever the decoder landed on, which
	// silently dropped the first frame of the first clip.
	n := decode_from_content(&s.dec, i64(content_sec * f64(s.dec.out_rate)))
	if n <= 0 {
		return false
	}
	s.first48 = i64(decoder_pts_sample(s.dec.first_ts, s.dec.stream.time_base))
	s.have48 = s.first48 + i64(n)
	audio_src_dump_dec(s, n)
	audio_src_append(s, n)
	return true
}

// db_to_linear converts a decibel level to an amplitude multiplier: +6 dB
// doubles the amplitude, -20 dB is 1/10. Odin's math.pow overloads f32
// (pow_f32), keeping this an f32-only call.
db_to_linear :: proc(db: f32) -> f32 {
	return math.pow(10, db / 20)
}

// kf_gain_linear evaluates a gain keyframe track — authored in dB, the unit the
// inspector shows — to a LINEAR amplitude multiplier at clip-relative frame
// `rel`. `base_dB` is the clip's static level (also dB) and rules where the
// track has no key yet (empty, or before the first key); past the last key the
// track holds its final dB, so a fade that ends sustains its end level instead
// of snapping back to the clip's static gain. Both the playback mixer and the
// export mixer go through here, so a key's dB value can never again be mistaken
// for the multiplier itself (a -40 dB key is 0.01, not -40).
kf_gain_linear :: proc(keys: []Keyframe, rel: i32, base_dB: f32) -> f32 {
	if len(keys) == 0 {
		return db_to_linear(base_dB)
	}
	db, _ := kf_sample_keys(keys, rel, base_dB)
	return db_to_linear(db)
}

// play_seg_gain_linear is a segment's linear amplitude multiplier at its
// clip-relative frame `rel`. Thin wrapper over the shared snapshot evaluator so
// playback and export resolve the same committed shape identically; extracted
// so the unit conversion is testable off the decode path (keyframe_probe), not
// just observable as "playback starts loud".
play_seg_gain_linear :: proc(seg: ^Play_Seg, rel: i32) -> f32 {
	return audio_gain_linear(&seg.gain, rel)
}

// clip_gain_db_at_playhead is the gain the inspector should DISPLAY for `clip`:
// the keyed dB value where its gain track is active at the playhead, else the
// static cl.gain. It mirrors every geometry lane, whose readout samples the
// keyed curve (clip_geom_get) rather than showing the resting field — the gain
// row was the one holdout and so disagreed with what playback was doing.
clip_gain_db_at_playhead :: proc(clip: ^Clip) -> f32 {
	if v, active := kf_sample_for(clip, "gain", playhead.frame, clip.gain); active {
		return v
	}
	return clip.gain
}

// audio_frame_boundary48 returns the 48kHz sample index at which timeline frame
// `frame` begins, relative to the start of the timeline (frame 0). Used to derive
// the true per-frame sample count as a difference of boundaries, instead of a
// single rounded 48000/fps constant that drifts over time whenever fps doesn't
// evenly divide 48000.
//
// Takes the rate rather than reading project_fps() because the render path
// passes the job's rate and the probes pass a fixture's; both must be able to
// place a boundary at a rate that is not the live project's. The arithmetic is
// sample_pos_from_frames -- integer, against the exact num/den -- and not
// `i64(frame * 48000.0 / fps)`, which loses a sample on the first frame of a
// 23.976 project (see parity_probe property 7).
audio_frame_boundary48 :: proc(frame: i64, fps: f64) -> i64 {
	num, den := fps_rational(fps)
	return i64(sample_pos_from_frames(frame, i64(num), i64(den)))
}

// audio_mix_frame zeros mix[0..spf*2) and sums every covering segment's window,
// exactly like the render loop (render.odin render_worker_run). Pure snapshot
// math (segment start_a/start_s/len_a) so the producer thread never reads live
// clips. The consumed fifo head is trimmed each frame so playback memory stays
// flat. Returns true if any covering segment actually delivered samples into
// mix (false means the frame was fed to the device as silence while a segment
// covered it — a decode/seek hole).
audio_mix_frame :: proc(mix: []f32, frame: i64, spf: int) -> bool {
	for i in 0 ..< len(mix) {
		mix[i] = 0
	}
	delivered := false
	fps := timeline_fps()
	for k in 0 ..< audio_src.count {
		s := &audio_src.slots[k]
		if !s.dec.opened {
			continue
		}
		seg := play_src_seg_at(s, frame)
		if seg == nil {
			continue
		}
		demand48 := i64(audio_content_sample(frame - seg.start_a, seg.start_s, seg.start_s_rate))
		// The fifo sits somewhere other than where this frame needs samples.
		// Both distances are re-anchored with a seek, because a decode only
		// substitutes when it is cheaper:
		//   head ahead  -- a forward jump advanced past content still needed;
		//                  feeding silence here is the only other option.
		//   head behind -- the demand is past what the decoder holds. Under
		//                  AUDIO_FORWARD_DECODE_MAX_SEC, decoding the gap in
		//                  place is cheaper than a seek. Over it, the gap is
		//                  content nobody will ever play and decoding through
		//                  blocks the producer long enough to underrun the
		//                  device, so the jump is sought instead.
		head_ahead := s.first48 - demand48 > i64(spf)
		head_behind := demand48 - s.have48 > AUDIO_FORWARD_DECODE_MAX_48
		if head_ahead || head_behind {
			content_sec := audio_content_sec(frame - seg.start_a, seg.start_s, seg.start_s_rate, fps)
			if !audio_src_seek_anchor(s, content_sec) {
				continue
			}
		}
		// A seek lands on the decoder's real PTS, which the demuxer's slack
		// can put a sample or two either side of the demand. Mix from the fifo
		// head when it landed ahead, so the base is never before the head.
		if s.first48 > demand48 {
			// See Audio_Report.head_clamped. Recorded rather than merely tolerated:
			// this is the frame whose content the timeline asked to be somewhere
			// else, and today nothing but this counter says so.
			audio_rpt.head_clamped += 1
			audio_rpt.head_clamp_max =
				max(audio_rpt.head_clamp_max, s.first48 - demand48)
		}
		demand48 = max(demand48, s.first48)
		start48 := demand48
		audio_src_pull(s, start48 + i64(spf))
		if s.have48 < start48 + i64(spf) {
			// The fifo cannot cover this frame. Silence for the span, and mark the
			// level -- the export's render_mix_block does exactly this, and a
			// resume after a hole is an edge a listener hears even though no clip
			// changed.
			continue
		}
		base := int(start48 - s.first48)
		// Per-segment gain folded in as one multiply per sample; the ring
		// already covers this frame (checked above), so gain is the only new
		// term here. A keyed segment re-evaluates its curve at the frame-
		// relative position each frame (from its own snapshot — the producer
		// never reads the live timeline), so automation animates audibly.
		g := play_seg_gain_linear(seg, i32(frame - seg.start_a))
		frame_lo := audio_frame_boundary48(frame, fps)
		frame_hi := audio_frame_boundary48(frame + 1, fps)
		seg_lo := audio_frame_boundary48(seg.start_a, fps)
		seg_hi := audio_frame_boundary48(seg.start_a + seg.len_a, fps)
		blk_lo := max(frame_lo, seg_lo)
		blk_hi := min(frame_hi, seg_hi)
		want := int(blk_hi - blk_lo)
		if want <= 0 {
			continue
		}
		sample_off := int(blk_lo - frame_lo)
		for f in 0 ..< want {
			l, r := ring_at(&s.fifo, base + sample_off + f)
			// No automatic ramp at a clip edge. A cut is a cut.
			//
			// There was a declick here, and it was this engine's second fade
			// mechanism: gain is already automated per sample through the clip's
			// keyframe envelope, so an edge ramp was an IMPLICIT fade applied to every
			// edit whether the user wanted one or not. Two mechanisms for one job is
			// the shape where the two disagree -- and they did, at ~2.5e-3 in a clip's
			// final fade, because the ramp was normalised against the caller's chunk
			// length and playback chunks by frame while the export chunks by block.
			//
			// A step at a cut is a real discontinuity and can be heard; that is what
			// an authored fade is for, and the envelope is already there to express
			// one. The engine's job is that what you cut is what you hear.
			d := g
			off := (sample_off + f) * 2
			mix[off + 0] += l * d
			mix[off + 1] += r * d
		}
		delivered = true
		if audio_rpt.trace {
			fmt.printf(
				"[tr mix] fr=%d k=%d seg0=%d start48=%d have48=%d fifo=%d del=%v\n",
				frame, k, seg.start_a, start48, s.have48, ring_len(&s.fifo), delivered,
			)
		}
		// Drop everything up to and including this frame from the fifo. O(1):
		// see ring_drop -- this used to be a mem.copy shifting the remaining
		// buffered content down to index 0 plus a resize, on every mixed frame,
		// per source, on the real-time producer thread.
		consumed := base + spf
		if consumed > 0 {
			ring_drop(&s.fifo, consumed)
			s.first48 += i64(consumed)
		}
	}
	return delivered
}

audio_init :: proc() -> bool {
	// Read the log toggles BEFORE opening the device: the device announces its
	// negotiated shape under trace, and the old order had that print fire before
	// trace was ever set, so it had never printed once.
	if interval := os.get_env_alloc("VYPER_AUDIO_LOG", context.temp_allocator); interval != "" {
		v, ok := strconv.parse_i64(interval)
		if ok && v >= 50 {
			audio_rpt.log_ms = v
		}
	}
	audio_rpt.log_full = os.get_env_alloc("VYPER_AUDIO_FULL", context.temp_allocator) == "1"
	audio_rpt.trace = os.get_env_alloc("VYPER_AUDIO_TRACE", context.temp_allocator) == "1"
	// The device, the bridge ring, and the resampler live in audio_device.odin
	// behind a narrow interface; this only decides whether playback is possible at
	// all. Failure is not fatal (the app runs silent), which is exactly what
	// SDL's failure path produced.
	audio_device_init()
	// Starts closed: the device runs, the gate does not, so nothing plays until the
	// transport opens it. The old code paused the device here for the same reason,
	// at the cost of a stop/start cycle on every play.
	audio_device_set_active(false)
	sync.atomic_store(&audio_geom_state.reader, AUDIO_GEOM_NO_SLOT)
	sync.atomic_store(&audio_prod.stop, false)
	sync.atomic_store(&audio_prod.done, false)
	sync.atomic_store(&audio_prod.run, false)
	sync.atomic_store(&audio_prod.resync, 0)
	audio_prod.thread = thread.create(audio_producer_proc)
	if audio_prod.thread == nil {
		fmt.println("could not start audio producer thread")
		return true
	}
	thread.start(audio_prod.thread)
	return true
}

audio_shutdown :: proc() {
	if audio_prod.thread != nil {
		sync.atomic_store(&audio_prod.stop, true)
		for !sync.atomic_load(&audio_prod.done) {
			sleep_ms(1)
		}
		thread.destroy(audio_prod.thread)
		audio_prod.thread = nil
	}
	audio_reset_play()
	// The producer thread is joined by now, so nothing else is writing the ring.
	atempo_graph_destroy(&audio_atempo)
	audio_device_shutdown()
}

// audio_reset_for_load asks the producer to pause and drop all audio state when
// a new file is imported (import_media also stops playback).
audio_reset_for_load :: proc() {
	sync.atomic_store(&audio_prod.run, false)
	// The producer is not reading the slab right now, and `reader`'s zero value
	// is slot 0 -- which would look like a permanent claim on it and cost the
	// writer one of its three slots forever. Start from the honest value.
	sync.atomic_store(&audio_geom_state.reader, AUDIO_GEOM_NO_SLOT)
}

// audio_src_covers_frame reports whether any provisioned segment covers
// timeline frame f, i.e. the producer has valid content to play there.
audio_src_covers_frame :: proc(f: i64) -> bool {
	for k in 0 ..< audio_src.count {
		s := &audio_src.slots[k]
		if s.dec.opened && play_src_seg_at(s, f) != nil {
			return true
		}
	}
	return false
}

// timeline_has_audio_at reports whether the CURRENT timeline has an audio clip
// covering frame f. UI-thread only; the timeline is its single writer, so this
// reads the live clips directly. Used by the self-heal in audio_update to
// detect "playing but the producer has no sources even though the timeline
// still expects audio here" — the signal that the engine silently died and
// must be re-seeded.
timeline_has_audio_at :: proc(f: i64) -> bool {
	for tr in 0 ..< len(timeline.tracks) {
		track := &timeline.tracks[tr]
		for c in 0 ..< len(track.clips) {
			clip := &track.clips[c]
			if clip.kind == .Audio && clip_visible_at(f, clip.timeline_start_frame, clip.source_length_frames) {
				return true
			}
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
	feed_t0 := monotonic_ns()
	defer audio_rpt.feed_us += u64(monotonic_ns() - feed_t0)
	if !audio_device_ready() {
		return
	}
	// Playback-rate: rebuild the atempo graph so the mix is time-stretched
	// (pitch preserved) instead of the device resampling it (pitch shifts).
	// Applied lazily — only when the rate changes — because the producer runs
	// every ~2ms, and rebuilding a filter graph is cheap (a few ms) but not
	// free per feed.
	want_ratio := max(1.0, playback.rate)
	if atempo_rate_set(&audio_atempo, want_ratio) {
		// The playhead and the device both kept running while the graph was
		// being built, so audio_src.next_frame is stale by the build duration (which
		// scales with the playhead once the rate is live: a ~150ms build at 4x
		// strands content ~0.6s behind) and the queued stream holds samples
		// mixed at the previous rate. Re-anchor to the live playhead: the
		// forward-skip below clears the stale queue, trims the fifos and jumps
		// the mix position to where playback actually is. Without this the
		// born deficit never closes — the queue cap throttles prod to the
		// device's drain rate, which equals the playhead's rate, and the
		// prod-keyed forward-skip in audio_update can't see the audible
		// position that is behind.
		sync.atomic_store(&audio_prod.jump_frame, sync.atomic_load(&playback.dev_frame))
		audio_rpt.rate_rebuilt += 1
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
	if jmp := sync.atomic_load(&audio_prod.jump_frame); jmp > audio_src.next_frame {
		delta48 := i64(0)
		if fps > 0 {
			delta48 = max(0, audio_frame_boundary48(jmp, fps) - audio_frame_boundary48(audio_src.next_frame, fps))
		} else {
			delta_frames := max(0, jmp - audio_src.next_frame)
			delta48 = delta_frames * i64(spf)
		}
		for k in 0 ..< audio_src.count {
			s := &audio_src.slots[k]
			if !s.dec.opened || s.fifo.buf == nil || delta48 <= 0 {
				continue
			}
			drop := int(min(delta48, i64(ring_len(&s.fifo))))
			if drop > 0 {
				s.first48 += i64(drop)
				ring_drop(&s.fifo, drop)
			}
		}
		audio_src.next_frame = jmp
		audio_device_clear()
		atempo_reset(&audio_atempo) // graph window holds pre-jump samples otherwise
		sync.atomic_store(&audio_prod.jump_frame, 0)
	}
	max_queue := i64(f64(AUDIO_BUS_RATE) * AUDIO_CUSHION_SEC)
	// A quarter of the cushion: deep enough that an ordinary producer hiccup does
	// not trip it, shallow enough to catch a real stall before the device runs dry.
	queue_floor := max_queue / 4
	cushion_frames := i64(AUDIO_CUSHION_SEC * f64(fps) * want_ratio + 1)
	// The device consumes 48k stream-samples/sec regardless of rate: atempo
	// compresses content to spf/rate output samples per frame, so queued bytes
	// represent content/rate worth — scale back up to content-frame depth so
	// dev_pos stays honest at every rate.
	rate_sc := max(1.0, want_ratio)
	queued_frames := i64(f64(audio_device_queued()) * rate_sc / f64(spf))
	dev_pos := audio_src.next_frame - queued_frames
	// dev_frame is the device's consumed position and needs no wall-clock stamp: it is
	// fed minus queued, both exact integers in bus samples. dev_at_ns is retained
	// only as the meter's age stamp.
	sync.atomic_store(&playback.dev_at_ns, i64(monotonic_ns()))
	sync.atomic_store(&playback.dev_frame, dev_pos)
	// Fold live gain edits (knob drag) into provisioned segments before mixing.
	// The epoch check is cheap; folding only runs when the UI published a gain
	// change since the last fold. No seek, so the drag is audible within the
	// cushion instead of reopening every decoder per knob move.
	if sync.atomic_load(&audio_geom_state.gain_epoch) != audio_geom_state.gain_folded_epoch {
		gslot := audio_geom_acquire()
		audio_gain_fold(gslot)
		audio_geom_release()
		audio_geom_state.gain_folded_epoch = sync.atomic_load(&audio_geom_state.gain_epoch)
	}
	// Pin the queue to the playhead, extrapolated from the UI's published clock
	// snapshot across any UI update gap (the render loop can block for a second
	// on the swapchain acquire while the device keeps consuming). Freezing at
	// the last published frame would starve the producer during a stall; driving
	// off dev_pos (the device's own consumption clock) free-runs past a stalled
	// playhead and locks a permanent offset after the stall. Extrapolating the
	// same wall clock the UI uses keeps audio glued to where the playhead really
	// is. dev_pos is kept only as the telemetry/health signal stored above.
	// The device is the clock. The producer fills to CUSHION samples AHEAD OF WHAT
	// THE DEVICE HAS CONSUMED, not ahead of a wall-clock guess at where the playhead
	// ought to be. That closes the loop exactly: dev_pos is fed minus queued, so
	// filling to dev_pos + cushion leaves the queue at the cushion, which is a fixed
	// point.
	//
	// It also makes drift structurally impossible rather than merely small. Content
	// fed is contiguous from the same origin whatever happens upstream, so a producer
	// stall costs the listener a GAP and never an offset: the device drains, dev_pos
	// advances with it, the playhead follows, and when the producer resumes it feeds
	// on from where it left off. There is no second clock to disagree with.
	ph := dev_pos
	target := ph + cushion_frames
	// Wedge watchdog: at the queue cap, prod is throttled to the device drain
	// rate — exactly the playhead's rate — so any deficit born while the device
	// kept running and prod didn't (a producer block, e.g. the atempo graph
	// rebuild at a rate change the playhead ran through) can never close on its
	// own, and the prod-keyed forward-skip in audio_update can't see the
	// audible position that is behind. When the queue is full yet prod is still
	// short of target beyond the skew tolerance, drop the backlog: audible snaps
	// to prod, the fill loop re-fills against the true target, and dev lands
	// back on the playhead. Self-limiting — after the heal prod sits at target,
	// so the condition stops.
	// There is no wedge watchdog here any more, and it is worth saying why it could
	// not have worked even before the clock inversion. Its condition was
	//   queued_samples >= max_queue   AND   next_frame < target - AUDIO_AUDIBLE_SKEW_TOL*fps
	// and with target = dev_pos + cushion and dev_pos = next_frame - queued that
	// second clause is `cushion_frames - queued_frames > 0.1*fps`. At a full queue
	// queued_frames is exactly the cushion minus one, so the difference is 1 frame
	// against a 6-frame bar at 60fps -- and the two clauses are in different units
	// besides (samples against frames). It measured heal=0 for every run.
	//
	// It existed to drop the backlog when a full queue left the producer short,
	// which SHIFTED THE PLAYHEAD -- the same class of silent position change the
	// clock inversion removed. It is deleted rather than fixed: with the device as
	// the clock there is no backlog to drop, because the producer's target IS the
	// device position.
	if target <= audio_src.next_frame {
		return
	}
	mix: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
	// Sized from ATEMPO_OUT_CAP, not MAX_AUDIO_FRAME_SAMPLES: with atempo active
	// the block length is the graph's output, not the content frame. Asserted
	// below so a future change to the cap cannot turn this into a silent stack
	// overflow of up to 4x.
	pcm: [ATEMPO_OUT_CAP * 2]i16
	for audio_src.next_frame < target {
		if audio_device_queued() >= max_queue {
			audio_rpt.skip_full += 1
			break
		}
		if !audio_src_covers_frame(audio_src.next_frame) {
			audio_rpt.skip_nocov += 1
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
			b0 := audio_frame_boundary48(audio_src.next_frame, fps)
			b1 := audio_frame_boundary48(audio_src.next_frame + 1, fps)
			cur_spf = min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(b1 - b0)))
		}
		mix_t0 := monotonic_ns()
		if !audio_mix_frame(mix[:], audio_src.next_frame, cur_spf) {
			sync.atomic_add(&audio_rpt.silence_holes, 1)
		}
		audio_rpt.mix_us += u64(monotonic_ns() - mix_t0)
		// Playback-rate: atempo stretches mixed content to cur_spf/rate output
		// samples with pitch preserved. Inactive graph (rate 1.0) feeds the mix
		// through verbatim, identical to the pre-atempo path.
		push_frames := cur_spf
		src := mix[:]
		if audio_atempo.graph != nil {
			atempo_process(&audio_atempo, mix[:], cur_spf)
			push_frames = audio_atempo.out_n
			src = audio_atempo.out_buf[:]
		}
		assert(
			push_frames <= ATEMPO_OUT_CAP,
			"producer: mixed block exceeds the conversion buffer",
		)
		for f in 0 ..< push_frames {
			l := src[f * 2 + 0] * 32767.0
			r := src[f * 2 + 1] * 32767.0
			pcm[f * 2 + 0] = i16(clamp(l, -32768.0, 32767.0))
			pcm[f * 2 + 1] = i16(clamp(r, -32768.0, 32767.0))
		}
		out_bytes := push_frames * AUDIO_BUS_FRAME_BYTES
		if out_bytes > 0 {
			// The push below asserts on a short write, so the ring has to be able
			// to take the WHOLE block before one is attempted. The cushion check at
			// the top of this loop cannot guarantee that. audio_device_queued()
			// reports 0 while a clear is pending -- deliberately, so the producer
			// does not stall on audio that is about to be discarded -- but the
			// callback has not run yet to honour that clear, so the ring is still
			// physically full. For that window (one period, ~10ms) the logical
			// queue and the physical room disagree, and only the physical room
			// decides whether a write lands. Read it directly instead of inferring
			// it from a counter that is deliberately lying.
			//
			// Free space can only grow between here and the write: this thread is
			// the only writer and the callback only drains. So a passing check
			// here stays true through the push, which is what makes checking once
			// enough rather than re-checking inside the write loop.
			//
			// Deferring is free: next_frame advances after the push, so leaving
			// here re-mixes this frame on the next pass. It is not a drop.
			if i64(push_frames) > audio_device_available() {
				audio_rpt.skip_full += 1
				break
			}
			audio_device_push(pcm[:], push_frames)
			audio_rpt.total_fed_frames += u64(push_frames)
		}
		audio_rpt.push += 1
		qnow := audio_device_queued()
		// Counted only once the transport is ESTABLISHED. Before the first fill the
		// queue is legitimately empty -- the producer is still seeking and decoding
		// the opening of the first clip -- and counting that would report a permanent
		// one-off starvation on every single run, which is exactly the kind of noise
		// that stops anyone reading the counter. Measured on ~/sallyface.vyproj: one
		// such tick at startup, then zero for the rest of the run.
		if qnow >= max_queue {
			audio_rpt.queue_established = true
		}
		if playhead.playing && audio_rpt.queue_established && qnow < queue_floor {
			audio_rpt.starve_ticks += 1
			audio_rpt.starve_frames += queue_floor - qnow
		}
		audio_rpt.min_q = min(audio_rpt.min_q, qnow)
		audio_rpt.max_q = max(audio_rpt.max_q, qnow)
		if audio_dump.pcm != nil {
			dump_bytes := mem.slice_ptr(cast([^]u8)raw_data(pcm[:]), out_bytes)
			if _, werr := os.write(audio_dump.pcm, dump_bytes); werr != nil {
				os.close(audio_dump.pcm)
				audio_dump.pcm = nil
			}
		}
		audio_src.next_frame += 1
		if audio_rpt.trace {
			fmt.printf(
				"[tr feed] fr=%d devpos=%d target=%d q=%db ph=%d prod=%d dev=%d mix=%.2fs\n",
				audio_src.next_frame - 1, dev_pos, target, qnow, ph, audio_src.next_frame, playback.dev_frame, f64(monotonic_ns() - feed_t0) / 1e9,
			)
		}
	}
	sync.atomic_store(&audio_prod.prod_frame, audio_src.next_frame)
}

// audio_producer_proc is the dedicated playback thread. It owns every decoder
// and the atempo graph, feeding the device asynchronously from the UI loop so UI
// stalls (AV1 decode, layout, uploads) cannot starve the audio output.
audio_producer_proc :: proc(t: ^thread.Thread) {
	if !audio_device_ready() {
		sync.atomic_store(&audio_prod.done, true)
		return
	}
	last_evt := i64(0)
	had_evt := false
	if audio_rpt.trace {
		fmt.println("[audio] producer thread up")
	}
	audio_rpt.thread_start_ns = monotonic_ns()
	last_report := u64(0)
	for !sync.atomic_load(&audio_prod.stop) {
		if sync.atomic_load(&audio_prod.run) {
			evt := sync.atomic_load(&audio_prod.resync)
			if evt != last_evt || !had_evt {
				last_evt = evt
				open_start := monotonic_ns()
				anchor := sync.atomic_load(&audio_prod.anchor_frame)
				if had_evt {
					// An EDIT: reconcile, so every decoder whose content position did
					// not move keeps running. This is the path that used to cost a
					// full re-provision -- clearing the queue and reopening every
					// decoder -- for a single clip move or trim.
					rep := audio_reconcile(anchor)
					audio_rpt.reconciles += 1
					audio_rpt.dec_kept += u64(rep.kept)
					audio_rpt.dec_seek += u64(rep.sought)
					audio_rpt.dec_open += u64(rep.opened)
					audio_rpt.dec_drop += u64(rep.dropped)
					// The queue is the half of a resync a user actually hears, and
					// dropping it is what a re-provision used to do
					// unconditionally. It is only wrong when the edit invalidated
					// audio already mixed into it -- which the reconcile knows,
					// because it compared the segments on both sides of the change
					// against the range the queue covers.
					if rep.touched_window {
						audio_device_clear()
						audio_rpt.queue_clears += 1
					}
				} else {
					// First event of the run: nothing exists to reconcile, so this
					// is the from-zero provision.
					audio_rpt.provisions += 1
					// Drop the queue and the resampler history together, then open
					// the gate. The gate, not a device stop/start, is what starts
					// and stops output: the device runs for the process lifetime.
					audio_device_clear()
					audio_provision(anchor)
				}
				had_evt = true
				audio_device_set_active(true)
				// Provisioning reopens every decoder synchronously -- hundreds
				// of ms once several sources are open. Video runs on the wall
				// clock the whole time, so the playhead has moved past the
				// anchor that was sampled before the open. Anchor to the stale
				// frame and the offset never closes: the queue ceiling caps how
				// far ahead the producer may fill, so once both clocks advance
				// at realtime the lag is frozen in (measurably ~the provision
				// duration, which is exactly why a manual seek clears it).
				// Skip forward to where playback actually is instead.
				if hop := sync.atomic_load(&playback.dev_frame); hop > audio_src.next_frame {
					sync.atomic_store(&audio_prod.jump_frame, hop)
				}
				if audio_rpt.trace {
					fmt.printf("[audio] re-provisioned %d srcs at frame %d in %.1f ms\n", audio_src.count, sync.atomic_load(&audio_prod.anchor_frame), f64(monotonic_ns()-open_start)/1e6)
				}
			}
			audio_producer_feed()
			if audio_rpt.log_ms > 0 {
				if now := monotonic_ns(); now - last_report >= u64(audio_rpt.log_ms) * 1_000_000 {
					elapsed := f64(now - audio_rpt.tick) / 1e9
				delta := audio_src.next_frame - audio_rpt.frame
				queued := audio_device_queued()
				fps := timeline_fps()
				spf := int(48000.0 / fps + 0.5)
				rate_sc := max(1.0, playback.rate)
				queued_frames := int(f64(queued) * rate_sc / f64(spf))
				cursor := audio_src.next_frame - i64(queued_frames)
				rate_fps := elapsed > 0 && delta >= 0 ? f64(delta) / elapsed : 0
				queued_delta := f64(queued - audio_rpt.queued)
				// What the device actually pulled is the fed delta minus the
				// queue delta; in frames, so no bytes-per-frame factor is needed.
				consumed_frames := f64(audio_rpt.total_fed_frames - audio_rpt.fed) - queued_delta
				drain_hz := elapsed > 0 && consumed_frames > 0 ? consumed_frames / elapsed : 0
				dev_hz := elapsed > 0 ? consumed_frames / elapsed : 0
				// Bus rate, NOT the negotiated device rate: consumed_frames counts
				// 48 kHz bus frames that miniaudio resamples on the way out, so
				// dividing by the device rate reads ~1.09x on a 44.1 kHz card and
				// trips the SLOW/FAST warning for a device that is exactly on pace.
				dev_ratio := dev_hz / f64(AUDIO_BUS_RATE)
				max_queue := i64(f64(AUDIO_BUS_RATE) * AUDIO_CUSHION_SEC)
				holes := sync.atomic_load(&audio_rpt.silence_holes)
				holes_delta := holes - audio_rpt.holes
				resync := sync.atomic_load(&audio_prod.resync)
				anchor := sync.atomic_load(&audio_prod.anchor_frame)
				cover := audio_src_covers_frame(playhead.frame)
				avail := audio_device_available()
				pace := "ok"
				if elapsed > 1.0 {
					if dev_ratio < 0.9 {
						pace = "SLOW"
					} else if dev_ratio > 1.1 {
						pace = "FAST"
					}
				}
				q_min := min(audio_rpt.min_q, queued)
				q_max := max(audio_rpt.max_q, queued)
				fmt.printf("[audio] t=%.2fs ph=%d(%.3fs,playing=%t,src=%s,catch=%d) anchor=%d prod=%d fed=%d curs=%d skew=%+.3fs rate=%.2ffps drain=%.0fHz pace=%s(dev=%.0fHz %.2fx) q=%dfr/%dfr(min=%dfr,max=%dfr,avail=%dfr) feed(push=%d,full=%d,nocov=%d,mix=%.1fms,work=%.1fms) cov=%d holes=%+d(total %d) starve=%d(+%.1fms) resync=%d rec=%d(k%d/s%d/o%d/d%d) dev=%dHz/%dch/%dbit under=%d clr=%d heal=%d\n",
					f64(now-audio_rpt.thread_start_ns)/1e9,
					playhead.frame, f64(playhead.frame)/fps, playhead.playing,
					sync.atomic_load(&audio_rpt.ph_src) == 1 ? "mouse" : sync.atomic_load(&audio_rpt.ph_src) == 2 ? "auto" : "?",
					sync.atomic_load(&audio_rpt.ph_catch),
					anchor, sync.atomic_load(&audio_prod.prod_frame), audio_src.next_frame, cursor,
					f64(cursor-playhead.frame)/fps,
					rate_fps,
					drain_hz,
					pace, dev_hz, dev_ratio,
					queued, max_queue,
					q_min, q_max, avail,
					audio_rpt.push, audio_rpt.skip_full, audio_rpt.skip_nocov,
					f64(audio_rpt.mix_us)/1e6, f64(audio_rpt.feed_us)/1e6,
					cover ? 1 : 0,
					holes_delta, holes,
					audio_rpt.starve_ticks,
					f64(audio_rpt.starve_frames) / f64(AUDIO_BUS_RATE) * 1000,
					resync,
					audio_rpt.reconciles,
					audio_rpt.dec_kept,
					audio_rpt.dec_seek,
					audio_rpt.dec_open,
					audio_rpt.dec_drop,
					audio_device_rate(), audio_device_channels(), audio_device_bits(),
					audio_device_underruns(), audio_device_clears(), 0)
				if audio_rpt.log_full {
					for k in 0 ..< audio_src.count {
						s := &audio_src.slots[k]
						at := i64(-1)
						covered := false
						in_fifo := false
						if seg := play_src_seg_at(s, audio_src.next_frame); seg != nil {
							covered = true
							at = i64(audio_content_sec(audio_src.next_frame - seg.start_a, seg.start_s, seg.start_s_rate, fps) * 48000.0)
							in_fifo = at >= s.first48 && at < s.have48
						}
						fmt.printf("[src %d] %s segs=%d dec=%t in=%dHz/%dch out=%dHz/%dch first48=%d have48=%d fifo=%dfr decoded=%dfr/%dch mix_at=%d(into %t) cov=%t\n",
							k, s.path, s.seg_count, s.dec.opened,
							s.dec.input_rate, s.dec.input_channels, s.dec.out_rate, s.dec.out_channels,
							s.first48, s.have48, ring_len(&s.fifo),
							s.dec.decoded_frames, s.dec.decoded_chunks,
							at, in_fifo, covered)
					}
				}
				audio_rpt.queue_established = false
				audio_rpt.tick = now
				audio_rpt.frame = audio_src.next_frame
				audio_rpt.queued = queued
				audio_rpt.holes = holes
				audio_rpt.fed = audio_rpt.total_fed_frames
				audio_rpt.push = 0
				audio_rpt.skip_full = 0
				audio_rpt.skip_nocov = 0
				audio_rpt.mix_us = 0
				audio_rpt.feed_us = 0
				audio_rpt.min_q = queued
				audio_rpt.max_q = queued
				last_report = now
				}
			}
		} else {
			if had_evt {
				audio_device_set_active(false)
				audio_device_clear()
				audio_reset_play()
				had_evt = false
			}
			sleep_ms(4)
			continue
		}
		sleep_ms(2)
	}
	audio_reset_play()
	if audio_dump.pcm != nil {
		os.close(audio_dump.pcm)
		audio_dump.pcm = nil
	}
	if audio_dump.dec != nil {
		os.close(audio_dump.dec)
		audio_dump.dec = nil
	}
	sync.atomic_store(&audio_prod.done, true)
}

// audio_update is called by the main loop. It drives the producer by refreshing
// the playhead anchor every frame and requesting a re-seek on play start/stop
// and genuine leaps (backward, or forward beyond the audio cushion). Steady
// playback needs no work here: the producer runs on its own clock.
audio_update :: proc() {
	if !audio_device_ready() {
		return
	}
	// Backward playback runs video only: the audio producer/decoders/stream are
	// forward-only, so while playback.dir is -1 treat audio as paused (muted).
	// audio_prod.was_playing is cleared so a later flip to forward re-seeks cleanly.
	if !playhead.playing || playback.dir == -1 {
		sync.atomic_store(&audio_prod.run, false)
		audio_prod.was_playing = false
		audio_prod.last_ui_frame = playhead.frame
		return
	}
	if !audio_prod.was_playing {
		audio_prod.was_playing = true
		sync.atomic_store(&audio_prod.run, true)
		audio_seek(playhead.frame)
		audio_prod.last_ui_frame = playhead.frame
		return
	}
	fwd := playhead.frame - audio_prod.last_ui_frame
	audio_prod.last_ui_frame = playhead.frame
	if fwd > 3 || fwd < -1 {
		if audio_rpt.trace {
			fmt.printf("[ph] t=%.2fs ph=%d fwd=%+d (last_ui=%d) -> jump/health check\n",
				f64(monotonic_ns()-audio_rpt.thread_start_ns)/1e9,
				playhead.frame, fwd, audio_prod.last_ui_frame)
		}
	}
	// A resync clears the stream, reopens every decoder (~16 ms) and then must
	// refill a full cushion at device rate before it can race ahead again.
	// Coalesce re-checks well past that recovery window so the forward-gap guard
	// below cannot re-trigger a self-sustaining reseed loop.
	now := monotonic_ns()
	last_seed := u64(sync.atomic_load(&audio_prod.anchor_now))
	if now - last_seed < 200_000_000 {
		return
	}
	// Self-heal: the producer can silently go deaf if a provision drops every
	// audio source (a transient open/seek failure on the only covering clip) and
	// nothing ever re-provisions it — the playhead keeps advancing and video
	// keeps playing but the device drains and stays muted. If we're playing, the
	// producer has zero sources, yet the current timeline still has audio
	// covering the playhead, force a re-seed. Coalesced above so a healthy
	// producer (which always has >=1 source) never hits this.
	//
	// audio_prod.provisioning guards the transient zero: a provision that is STILL
	// RUNNING has count==0 by construction, but the producer is alive and about
	// to repopulate the sources. Firing here re-anchors mid-provision, bumps
	// the resync evt, and the producer clears the stream and re-provisions from
	// scratch every 200 ms — a self-sustaining re-open storm on slow files
	// (5 FLAC decoders, ~300 ms total). Only a COMPLETED provision with zero
	// survivors is a genuinely dead engine.
	if sync.atomic_load(&audio_prod.src_count_ui) == 0 && !sync.atomic_load(&audio_prod.provisioning) && timeline_has_audio_at(playhead.frame) {
		if audio_rpt.trace {
			fmt.printf("[ph] self-heal: playing but 0 audio sources at ph=%d -> re-seed\n", playhead.frame)
		}
		audio_seek(playhead.frame)
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
	prod := sync.atomic_load(&audio_prod.prod_frame)
	if fwd < 0 {
		reason := "backward"
		src := sync.atomic_load(&audio_rpt.ph_src)
		catch := sync.atomic_load(&audio_rpt.ph_catch)
		src_name := src == 1 ? "mouse" : src == 2 ? "auto" : "?"
		if audio_rpt.trace {
			fmt.printf("[ph] t=%.2fs ph=%d prod=%d anchor=%d -> %s reseek (fwd=%+d, phsrc=%s catch=%d)\n",
				f64(now-audio_rpt.thread_start_ns)/1e9,
				playhead.frame, prod, sync.atomic_load(&audio_prod.anchor_frame), reason, fwd, src_name, catch)
		}
		audio_seek(playhead.frame)
	// There is no forward-skip branch here any more, and its absence is the point of
	// the clock inversion rather than a simplification.
	//
	// It guarded `playhead.frame > prod + cushion + 6` -- "the producer fell behind,
	// so jump it forward". But the playhead is now READ FROM the device, and
	// dev_pos = next_frame - queued, so that guard reduces to
	//
	//     -queued_frames > cushion + 6
	//
	// which is unsatisfiable: queued_frames is a non-negative count. The playhead
	// cannot outrun what the producer has already fed, by construction, so the branch
	// was unreachable -- measured resync=4 at startup, constant since.
	//
	// It was also the LAST way the engine could silently move the playhead during
	// playback. A producer stall now costs the listener a gap and nothing else: the
	// device drains, dev_pos advances with it, the playhead follows, and the producer
	// resumes feeding on from where it stopped. That is what the branch was trying to
	// buy, except it bought it by shifting position.
	}
}

// audio_seek re-anchors the producer at the given frame and requests a clear +
// re-provision. UI thread only.
audio_seek :: proc(frame: i64) {
	if audio_rpt.trace {
		fmt.printf("[tr seek] to=%d\n", frame)
	}
	sync.atomic_store(&audio_prod.anchor_frame, frame)
	sync.atomic_store(&audio_prod.anchor_now, i64(monotonic_ns()))
	sync.atomic_add(&audio_prod.resync, 1)
}
