package vyper

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

// AUDIO_CHUNK is the number of output sample-frames decoded in one step: the point at
// which decode_audio_chunk stops STARTING new decoder frames. It is not a size limit.
// A frame that begins under it is converted whole, so a chunk can exceed it by up to
// one frame (FLAC blocks are 4608 samples).
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
	when ODIN_DEBUG {
		if audio_rpt.trace {
			fmt.printf("audio %dch @ %d Hz -> S16\n", dec.out_channels, dec.out_rate)
		}
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
	// The resampler buffers input it had no room to convert (and, when resampling,
	// its filter history). flush_buffers resets only the codec, so without this the
	// samples decoded BEFORE the seek come out of swr after it, labelled with the
	// seek's position: the audio the listener just heard, played again at the new
	// point. close+init discards all of it and keeps the configured options.
	swres.close(dec.swr_ctx)
	if ret := swres.init(dec.swr_ctx); ret < 0 {
		fmt.println("swr_init after seek:", ff_err_str(ret))
		return false
	}
	dec.have_last = false
	dec.have_cursor = false
	return true
}

// audio_decoder_reserve makes dec.s16 hold at least `need` more sample-frames after
// the first `produced`, and returns the room available from there. Grow-only: the
// buffer reaches the largest frame the stream carries and then never reallocates,
// so steady-state decoding allocates nothing. `need` is swres_get_out_samples, an
// upper bound that includes input the resampler is already holding.
audio_decoder_reserve :: proc(dec: ^Audio_Clip_Decoder, produced, need: int) -> int {
	assert(need >= 0, "audio_decoder_reserve: swr_get_out_samples failed on a configured context")
	ch := int(dec.out_channels)
	want := (produced + need) * ch
	if want > len(dec.s16) {
		grown := make([]i16, want)
		copy(grown, dec.s16[:produced * ch])
		delete(dec.s16)
		dec.s16 = grown
	}
	return len(dec.s16) / ch - produced
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
			// The output buffer is sized to the frame, not the frame to the buffer.
			// swres_convert converts only what the room holds and keeps the rest as
			// internal delay, with no error: with a 4096-sample buffer, FLAC's
			// 4608-sample blocks converted 4096 on every call and the delay grew
			// 512, 1024, ... 4096 without ever draining. Each chunk then lagged its own
			// position label by a widening margin, so the fifo held audio from an
			// earlier position than it was labelled with -- which no position counter
			// can see, because each is derived from the label. A resampled source hit
			// the same thing whenever its last frame straddled the buffer end.
			room := audio_decoder_reserve(dec, produced, int(swres.get_out_samples(dec.swr_ctx, dec.frame.nb_samples)))
			out_planes[0] = ([^]u8)(raw_data(dec.s16))[produced * int(dec.out_channels) * size_of(i16):]
			n := swres.convert(
				dec.swr_ctx,
				&out_planes[0], c.int(room),
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
	when ODIN_DEBUG {
		if audio_rpt.trace {
			fmt.printf(
				"[tr dec] seq=%v asked=%.3fs produced=%d first_ts=%v last_ts=%v\n",
				sequential, at_seconds, produced, dec.first_ts, dec.last_ts,
			)
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

// MAX_WINDOW_MAPS bounds how many segment mappings one source contributes to a
// queued-window comparison. A source's segments are disjoint and in timeline
// order, so only the ones overlapping the window matter, and the window is the
// device cushion wide -- a few stretches, not the 256 a source can hold. Past
// the cap the comparison gives up and reports the window touched, which is the
// answer an overflow used to get for everything: an extra re-feed, never wrong
// audio.
MAX_WINDOW_MAPS :: 8

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
ring_cap :: proc "contextless" (r: ^Audio_Ring) -> int {
	return len(r.buf) / 2
}

// ring_len returns how many sample-frames are currently buffered.
ring_len:: proc "contextless" (r: ^Audio_Ring) -> int {
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
 ring_at:: proc "contextless"(r: ^Audio_Ring, idx: int) -> (l, rr: f32) {
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
// timeline (start_a/len_a) and where its content starts in the source (start_s).
//
// len_a is the TIMELINE length, which is NOT the source length for a time-stretched
// clip. The old comment here said "len_a is both the timeline length and the source
// length (clips are not time-stretched)" -- true when written, false the moment clip
// speed existed, and every span computation inherited it. So a segment's source range
// is now [start_s, start_s + len_a*speed), where `speed` is the owning source's clip
// tempo. At 1.0 that reduces to the old behaviour exactly, which is why nothing
// regressed when this changed.
Play_Seg :: struct {
	start_a: i64, // timeline_start_frame
	start_s: i64, // source_start_frame
	// start_s_rate pins the rate start_s is counted against; see
	// audio_source_start_sec. Kept in frames (not pre-converted to seconds) so
	// the contiguity checks that compare start_s across segments stay in one
	// space.
	start_s_rate: f64,
	// len_a is the TIMELINE length in frames -- see the note above. Not the content
	// length; those differ for a stretched clip.
	len_a:   i64,
	// A segment's tempo is independent clip state, captured with its timeline and
	// source anchors so a reconcile can detect a rate edit even when its source
	// sample at the playhead happens to be unchanged (notably at clip start).
	speed: f64,
	// gain is the segment's latched copy of the committed gain snapshot (static
	// dB + keyed curve), taken once at provision from the geometry slab. Rides
	// the per-segment snapshot (not per-source) because a split makes adjacent
	// segments of one source independently adjustable. The mix re-evaluates it
	// per frame through audio_gain_linear, so automation animates live without
	// the producer ever reading live timeline state.
	gain: Audio_Gain_Snapshot,
	pitch: Audio_Pitch_Snapshot,
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
	// reanchor_ns is when this source was last re-anchored, and reanchor_have48
	// is what have48 was then. Together they bound re-seeking (see
	// audio_src_seek_anchor). Producer thread only.
	reanchor_ns:     i64,
	reanchor_have48: i64,
	reanchor_at:     f64,
	// reanchor_pulled counts decoder output since the last re-anchor. It separates
	// "sought and did not get" from "sought and nobody has asked yet".
	reanchor_pulled: int,

	// decoded / decoded_origin / decoded_n: REMOVED.
	//
	// The clip's PCM addressed by absolute content sample, so that scrubbing was
	// an array index at any speed in any direction with no seek and no state. The
	// design was right and it was never wired up: nothing read it, because the
	// mixer reads `fifo` through first48/have48 instead.
	//
	// It is recorded here because it is the answer to the next "why does a
	// backward scrub cost a seek". The window is the reason. Filling `decoded`
	// turns position into an index and removes the seek entirely -- that is a
	// real option, not a dead end, and deleting the fields without this note
	// would throw away the analysis with the code.

	// TEMPO. A clip whose speed is not 1.0 does not present its content to the mix
	// at one content sample per output sample, so it cannot be read out of `fifo` by
	// index -- the content that belongs at timeline position P arrives S times later.
	// Hence a SECOND ring, filled by a streaming pump through this source's own
	// atempo graph, holding OUTPUT samples at 1:1 with the timeline. The mix indexes
	// that one instead, and `first48`/`have48` keep meaning content, so every
	// existing piece of positioning logic is untouched.
	//
	// A source at speed 1.0 never touches any of this: no graph is built, no pump
	// runs, no second ring is filled. That is deliberate rather than an optimisation
	// -- it means the whole feature is provably INERT until a clip is actually
	// stretched, so the parity, 600 s drift and stall gates keep proving the engine
	// they were written for.
	//
	// The two paths do not duplicate the mixing: mix_src_block takes a ring POINTER,
	// so choosing which ring to read is passing a different pointer, not a second
	// copy of the loop.
	tempo:      Atempo_Graph,
	out_ring:   Audio_Ring, // post-atempo output, 1:1 with the timeline
	out_first:  i64,        // output sample index of out_ring's head
	speed:      f64,        // clip tempo; 1.0 means the path above is used unchanged
	// pitch is the clip's semitone offset and pitch_ratio its frequency ratio.
	// SEPARATE from speed, and applied by a different pair of filters: pitch moves
	// frequency and preserves duration, tempo moves duration and preserves pitch.
	// Nothing else in the engine touches either -- a clip that is not pitched is not
	// transposed, and stretching a clip does not change its pitch.
	pitch:      f32,
	pitch_ratio: f64,
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
	// touched_window is true when the frames the device queue still holds play
	// different content after this edit than they did before, on any source. That,
	// and not the reopen count, is what decides whether the QUEUE has to be
	// dropped: a decoder can be reused while the already-mixed audio sitting in
	// the queue is wrong.
	touched_window: bool,
}

// Play_Src_Snap is one provisioned source as it was BEFORE the new geometry was
// folded in. Snapshotting first is what makes the decision possible at all: pass 1
// of provisioning overwrites seg_count in place, so without this the old segment
// list is gone by the time anything could ask whether the decoder still fits.
Play_Src_Snap :: struct {
	had_decoder:   bool,
	old_content:   i64, // content 48 kHz sample the decoder was anchored for, -1 if none
	old_speed:     f64,
	old_pitch_ratio: f64,
	action:        Reconcile_Action,
	touched_window: bool,
	// old_map is the pre-edit content mapping clipped to the queued window: what
	// the audio in the device queue was actually mixed from. old_map_ok is false
	// when it did not fit MAX_WINDOW_MAPS, which downgrades the comparison to the
	// conservative answer.
	old_map:   [MAX_WINDOW_MAPS]Window_Map,
	old_map_n: int,
	old_map_ok: bool,
	// graph_changed is a committed speed or pitch edit on this source. It moves
	// no content on its own (pitch does not) but it changes every future output
	// sample, so queued audio mixed by the old graph is stale.
	graph_changed: bool,
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
		audio_content_sample_at_speed(
			seek_frame - seg.start_a,
			seg.start_s,
			seg.start_s_rate,
			seg.speed,
		),
	)
}

// Window_Map is one stretch of a source's content mapping, clipped to the frames
// the device queue still holds. Only the four fields the mapping is made of are
// kept: a reconcile compares the pre-edit geometry against the post-edit one, and
// copying whole segments would mean carrying gain curves and pitch snapshots
// nobody in that comparison reads (Play_Src is ~668 KB per source).
Window_Map :: struct {
	lo, hi:  i64, // frame range, half-open, clipped to the window
	start_a: i64, // timeline_start_frame of the segment it came from
	start_s: i64, // source_start_frame
	start_s_rate: f64,
	speed:   f64,
}

// window_map_content_at mirrors play_src_content_at for a clipped mapping: the
// content sample a decoder has to sit at to play timeline frame f.
window_map_content_at :: proc(m: ^Window_Map, f: i64) -> i64 {
	return i64(
		audio_content_sample_at_speed(
			max(f, m.start_a) - m.start_a, m.start_s, m.start_s_rate, m.speed,
		),
	)
}

// play_src_window_maps clips s's segments to [from,to) into out and returns how
// many stretches that took, ok=false if they did not fit. Caller falls back to
// treating the window as touched when it does not.
play_src_window_maps :: proc(s: ^Play_Src, from, to: i64, out: []Window_Map) -> (int, bool) {
	n := 0
	if to <= from {
		return 0, true
	}
	for i in 0 ..< s.seg_count {
		sg := &s.seg[i]
		if sg.start_a >= to {
			// Segments are in timeline order, so everything after starts later.
			break
		}
		lo := max(from, sg.start_a)
		hi := min(to, sg.start_a + sg.len_a)
		if lo >= hi {
			continue
		}
		// The invariant the merge below relies on to walk the window once.
		assert(
			n == 0 || lo >= out[n - 1].hi,
			"play_src_window_maps: one source has overlapping segments",
		)
		if n == len(out) {
			return n, false
		}
		out[n] = Window_Map {
			lo            = lo,
			hi            = hi,
			start_a       = sg.start_a,
			start_s       = sg.start_s,
			start_s_rate  = sg.start_s_rate,
			speed         = sg.speed,
		}
		n += 1
	}
	return n, true
}

// play_src_window_maps_differ reports whether the queued window plays different
// content before and after an edit. That, and not the reopen count, is what
// decides whether the audio already sitting in the device queue has to be
// re-fed: a decoder can be perfectly reusable while the mixed audio in front of
// it is wrong.
//
// Deliberately NOT "does a segment overlap the window". Trimming the far end of a
// clip the playhead sits inside overlaps the window before and after while
// changing nothing under it, and clearing the queue for that is an audible hiccup
// on an edit the user cannot otherwise hear -- the exact case the reconcile
// exists to make free. The mapping is what the queue is made of, so that is what
// gets compared. Both lists are sorted and disjoint, so one walk of the window
// settles it, and comparing the two ends of each shared stretch is enough: a
// segment maps frames to content linearly, so agreeing at both ends means
// agreeing throughout.
play_src_window_maps_differ :: proc(
	old: []Window_Map, old_n: int,
	new: []Window_Map, new_n: int,
	from, to: i64,
) -> bool {
	oi, ni := 0, 0
	for f := from; f < to; {
		for oi < old_n && old[oi].hi <= f {
			oi += 1
		}
		for ni < new_n && new[ni].hi <= f {
			ni += 1
		}
		has_old := oi < old_n && old[oi].lo <= f
		has_new := ni < new_n && new[ni].lo <= f
		if !has_old && !has_new {
			// The producer runs ahead of the content, so the window routinely
			// reaches past the end of BOTH geometries. Silence to silence is not a
			// change; skip to the next stretch either side has.
			next := to
			if oi < old_n {
				next = min(next, old[oi].lo)
			}
			if ni < new_n {
				next = min(next, new[ni].lo)
			}
			assert(next > f, "play_src_window_maps_differ: window walk made no progress")
			f = next
			continue
		}
		if !has_old || !has_new {
			// One side is silent where the other plays: content moved there.
			return true
		}
		end := min(min(old[oi].hi, new[ni].hi), to)
		assert(end > f, "play_src_window_maps_differ: window walk made no progress")
		if window_map_content_at(&old[oi], f) != window_map_content_at(&new[ni], f) ||
		   window_map_content_at(&old[oi], end - 1) !=
		       window_map_content_at(&new[ni], end - 1) {
			return true
		}
		f = end
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
	// force_seek_resync tags explicit playhead navigation. Its generation is
	// consumed with resync so a seek inside the normal producer cushion still
	// re-anchors sources and clears already-queued audio (atomic).
	force_seek_resync: i64,
	// scrub_active marks the interval where the UI pointer, not device clock,
	// owns playhead position. Producer-side anomaly checks ignore that requested
	// mismatch and resume checking when release commits the final seek.
	scrub_active: bool,
	// scrub_playhead is the playhead frame as the pointer sees it, published on
	// EVERY drag move rather than through audio_seek's coalescing — the producer
	// reads it to aim and to decide when it has fallen behind (atomic).
	scrub_playhead: i64,
	// scrub_rate is the drag's velocity in timeline-frames per real second, divided
	// by fps -- the rate the crossed frames play at. Written by the UI thread on every
	// scrub move, read by the producer. Only consulted while scrub_active.
	scrub_rate: f64,
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

// last_seek_evt is the force_seek_resync generation the producer has already acted
// on. Producer-thread only, no atomic: one writer, and it just has to not act on
// the same seek twice.
last_seek_evt: i64 = 0

// last_scrub_active is the previous feed's scrub_active. Its falling/rising edge
// is how the producer knows a drag STARTED, which is the one moment pre-scrub
// backlog is unambiguously stale and can be dropped. Producer-thread only.
last_scrub_active: bool = false

// last_scrub_pointer is the pointer position as the producer last saw it.
//
// Backward motion has to be judged against the POINTER'S OWN previous position.
// Judging it against audio_src.next_frame -- the render cursor -- is wrong now
// that a scrub renders ahead of the pointer on purpose: the producer is
// legitimately past the pointer for most of a drag, so every forward move looks
// like "the pointer went back", and clearing on that wiped the ring mid-gesture.
// A drag that hears nothing is exactly that loop.
last_scrub_pointer: i64 = 0

// scrub_read_pos is the SCRUB content read position in bus samples, fractional.
// It is the scrub equivalent of audio_src.next_frame, and deliberately separate
// from it: the playback cursor must not be dragged around by a drag, and the
// drag needs a position that is not restricted to whole frames.
//
// scrub_read_step is how many content samples to advance per output sample, so
// it is the compression factor: 1.0 is real time, 4.0 plays the crossed range
// in a quarter of the time. Re-pointing is an assignment to scrub_read_pos,
// which is what makes jumping instant and free.
scrub_read_pos: f64 = 0
scrub_read_step: f64 = 1.0


// SCRUB_REPOINT_SLACK_FRAMES is how far the producer may fall behind a STOPPED
// pointer before the remaining backlog is dropped. It is a little over a device
// period of content, so ordinary jitter while a drag is in flight never trips it
// -- only a genuine "hand stopped, engine still catching up" does.
SCRUB_REPOINT_SLACK_FRAMES :: 8

//
// SCRUB_ANTIALIAS is the one-pole coefficient floor for the scrub read filter.
//
// Reading ahead by `step` samples per output sample decimates: whatever content
// sat above the new Nyquist (bus rate / 2 / step) folds back down as audible
// grit. Interpolation does not remove that, which is why the scrub stays harsh
// even though the truncation error is gone -- and why playback, which never
// decimates, is clean.
//
// A one-pole lowpass ahead of the read is enough to knock the folded energy
// down. It is not a brickwall: this is a preview path where latency and CPU
// matter, and a steep filter would smear transients and add group delay for an
// artifact that only lasts as long as the drag does.
scrub_lowpass_z: f32 = 0
scrub_lowpass_x: [AUDIO_BUS_CHANNELS]f32

// scrub_step_for turns the drag's published rate into the resampling step.
//
// scrub_rate is ALREADY frames of content per frame of output: the UI divides
// velocity (frames per second) by fps before publishing it, precisely so the
// producer does not have to know the frame rate. Dividing by fps a second time
// here collapsed every real drag to a step of 1.0 -- a drag moving 8 frames per
// 60 Hz tick publishes 8.3, which became 0.138 and was then floored to 1.0, so
// every scrub ran at exactly real time and the resampler never engaged.
//
// The floor is kept for a genuine reason, not to hide this: a hand slower than
// real time must still play every sample at natural speed rather than running
// the content backwards.
//
// scrub_reanchor_at points every covering decoder at `frame` and decodes forward
// from it.
//
// Re-pointing the producer WITHOUT this is what made "scrub backwards, then
// forwards" dead for seconds. The producer moved but the decoders did not, so
// each subsequent frame found the fifo head sitting far ahead of the demand,
// which is the condition audio_mix_frame re-anchors on -- so it issued a seek
// per frame. A seek costs milliseconds; a drag is milliseconds.
//
// It is shared by both re-points (backward motion and stopped-behind) because
// they have the same obligation and only one of them used to have it.
scrub_reanchor_at :: proc(frame: i64) {
	scrub_fps := timeline_fps()
	for k in 0 ..< audio_src.count {
		sg := &audio_src.slots[k]
		if !sg.dec.opened {
			continue
		}
		seg := play_src_seg_at(sg, frame)
		if seg == nil {
			continue
		}
		// A position BEFORE this segment's start maps to negative content time.
		// Seeking there always fails, the fifo stays where it was, the "am I ahead
		// of the pointer" test stays true, and the producer re-seeks every pass --
		// the observed constant "asked=-1.000s" spin. There is nothing to decode
		// for this source at this frame, so there is nothing to ask it for.
		if frame < seg.start_a {
			continue
		}
		need48 := max(0, i64(
			audio_content_sample_at_speed(
				frame - seg.start_a,
				seg.start_s,
				seg.start_s_rate,
				sg.speed,
			),
		))
		if sg.have48 - need48 < SCRUB_DECODE_LOOKAHEAD_48 {
			_ = audio_src_seek_anchor(
				sg,
				f64(need48) / f64(AUDIO_BUS_RATE),
				audio_frame_boundary48(frame-seg.start_a, scrub_fps),
			)
		}
	}
}

scrub_step_for :: proc(rate: f64, fps: f64) -> f64 {
	return max(1.0, rate)
}

// last_scrub_target is the playhead as the producer last saw it. Comparing the
// playhead to ITSELF is what separates a seek from a healthy fill: the producer
// sits a cushion ahead by design, so only the playhead's own motion says whether
// the user asked for something.
last_scrub_target: i64 = 0


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
	// scrub_stale_max is the worst AUDIBLE staleness seen during a scrub: at a scrub
	// move, the frames already committed to the device for a position the pointer has
	// left. Every scrub fault the producer-side gates cannot see is this number.
	//
	// The scrub gates assert audio_src.next_frame follows the playhead, which is the
	// producer's CURSOR. What a listener hears is what the device has already been
	// handed, and those are two different queues. A producer that aims perfectly at a
	// pointer that has moved 40 frames is still correct, and still 40 frames of audio
	// for the old position are already in the device. That gap is the complaint.
	// live_block_nonzero is 1 when the callback's last rendered block contained any
	// non-zero sample. A stall must leave it 0: silence is the honest answer when
	// nothing is decoded, and anything else is audio from before the stall.
	// fed_peak is the amplitude (x1000) of the last block the producer pushed, so a
	// probe can tell "the pipe carried audio" from "the pipe carried zeros".
	fed_peak: i64,
	// sim_heard is 1 once the simulated device has played any non-zero sample. It
	// is the answer to "did anything come out", which is not the same question as
	// "did the producer push".
	sim_heard: i64,
	scrub_stale_max:    i64,
	scrub_stale_sum:    i64,
	scrub_stale_n:      i64,
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
	skip_nocov:   u64,
	// reanchor_blocked counts re-anchors refused because the previous one for
	// that source made no progress. Non-zero means a decoder is failing to follow
	// a seek, which used to present as the producer spinning with an empty queue.
	reanchor_blocked: u64, // feed() exits because no clip covers the next frame
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
	// TEMPORARY probe hook. last_fed_content is the CONTENT sample the most
	// recent fed block was mixed from, published every feed pass. The probe zeroes
	// it and then triggers a seek, so the next value it reads is the content the
	// device was actually handed for that seek. End-state inspection cannot
	// establish this: a producer that rewound correctly and one that kept the old
	// position both go on to advance forward, and both look healthy afterwards.
	// Set to a negative value to ARM it: the next fed block latches its content
	// sample here and every block after that leaves it alone. Zeroing it and then
	// reading it later returns the LAST block fed, which is useless -- the producer
	// advances forward correctly, so a late sample cannot tell a rewind that
	// happened from one that did not. Arming is what makes the value mean "the
	// first thing the device was handed after the event under test".
	last_fed_content:   i64,
	last_fed_content_armed: bool,
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

// VYPER_DECDUMP is the one file diagnostic NOT defaulted on in a debug build,
// and the reason is volume rather than taste. This dumps every SOURCE's decoded
// PCM pre-mix, so it writes at (sources x 192 KB/s): a 25-track project fills
// /tmp at ~4.8 MB/s, about 17 GB an hour. The mixed-output dump below is one
// stream and is on by default. Set VYPER_DECDUMP=<path> when a decode bug needs
// the per-source view and you have the disk for it.
audio_dec_dump_open :: proc() {
// Debug-only (see the volume note above): not in a release binary.
when ODIN_DEBUG {
		if audio_dump.dec != nil {
			return
		}
		path, has := os.lookup_env_alloc("VYPER_DECDUMP", context.temp_allocator)
		if !has || path == "" {
			return
		}
		f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Read_Write_All)
		if err == nil {
			audio_dump.dec = f
			fmt.printf("[audio] dec dump -> %s\n", path)
		}
}
}

// The mixed-output dump: ONE stream (48 kHz stereo s16 = 192 KB/s, ~690 MB an
// hour), so it defaults on in a debug build and lands under the temp dir.
audio_pcm_dump_open :: proc() {
// Debug-only: the mixed-output dump is a debug tool, absent from a release binary.
when ODIN_DEBUG {
		if audio_dump.pcm != nil {
			return
		}
		path_buf: [1024]u8
		path := diag_path("VYPER_PCMDUMP", "mix.pcm", path_buf[:])
		if path == "" {
			return
		}
		f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Read_Write_All)
		if err == nil {
			audio_dump.pcm = f
			audio_dump.pcm_path = path
			fmt.printf("[audio] pcm dump -> %s\n", path)
		}
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
	g.n, total = keyframe_fill_snapshot(clip, "gain", g.keys[:])
	return
}

// audio_gain_linear evaluates a committed gain snapshot to a LINEAR amplitude
// multiplier at clip-relative frame `rel`. Thin wrapper over keyframe_gain_linear so
// both mixers evaluate the same shape the same way.
audio_gain_linear :: proc "contextless" (g: ^Audio_Gain_Snapshot, rel: i32) -> f32 {
	return keyframe_gain_linear(g.keys[:g.n], rel, g.db)
}

// Audio_Pitch_Snapshot is a clip's pitch, committed: a static semitone offset plus
// its keyframe track.
//
// It is deliberately the SAME SHAPE as Audio_Gain_Snapshot, and for the same reason
// the two mixers agree about gain: the producer never reads live clips, so a track
// the producer does not know about is a track that silently does nothing. One shape,
// one path, one snapshot -- so pitch cannot drift out of step with the property it is
// modelled on.
Audio_Pitch_Snapshot :: struct {
	semitones: f32,
	keys:      [GAIN_KF_MAX_KEYS]Keyframe,
	n:         int,
}

// audio_pitch_snapshot_from_clip snapshots a clip's pitch track into the shared
// shape. Mirrors audio_gain_snapshot_from_clip exactly, including returning the
// track's REAL key count so the caller can log truncation.
audio_pitch_snapshot_from_clip :: proc(clip: ^Clip) -> (p: Audio_Pitch_Snapshot, total: int) {
	p.semitones = clip.pitch
	p.n, total = keyframe_fill_snapshot(clip, "pitch", p.keys[:])
	return
}

// audio_pitch_semitones evaluates a committed pitch snapshot at clip-relative frame
// `rel`.
//
// The one place it deliberately DIFFERS from the gain path: gain converts dB to a
// linear multiplier, because amplitude is a multiplier. Pitch is NOT a multiplier --
// it is a frequency ratio -- so it is returned in SEMITONES and converted to a ratio
// once, where the ratio is actually needed (the shifter's resample factor). Converting
// here would bake a unit into the snapshot and make the key values unreadable, which
// is the mistake the dB comment on keyframe_gain_linear warns about in the other direction.
audio_pitch_semitones :: proc(p: ^Audio_Pitch_Snapshot, rel: i32) -> f32 {
	if p.n == 0 {
		return p.semitones
	}
	v, _ := keyframe_sample_keys(p.keys[:p.n], rel, p.semitones)
	return v
}

// semitones_to_ratio converts a semitone offset to the frequency ratio a pitch shifter
// needs: 2^(n/12). The exponent is divided by 12 because an octave is 12 semitones,
// and the base is 2 because pitch is a ratio, not a multiplier -- so +12 is exactly
// one octave up, not 12x.
semitones_to_ratio :: proc(semitones: f32) -> f64 {
	return math.pow(2.0, f64(semitones) / 12.0)
}

// CLIP_PITCH_MIN / CLIP_PITCH_MAX bound a clip's pitch offset.
//
// Asymmetric on purpose. Downward is limited because every semitone DOWN is more
// octave division in the shifter's resampler, and the lower it goes the more content
// has to be discarded to do it -- so the floor is where quality is still acceptable,
// not a round number. Upward is far more generous because shifting up is nearly free:
// it needs resampling, not division.
//
// These are ASSERTED at the point of use rather than clamped, for the same reason
// clip_speed asserts: a clamp would silently play a pitch the user did not ask for.
CLIP_PITCH_MIN :: -24.0
CLIP_PITCH_MAX :: 12.0

// clip_pitch_at_playhead is the pitch the inspector should DISPLAY for `clip`: the
// keyed semitone value where its pitch track is active at the playhead, else the
// static clip.pitch.
//
// It exists because the gain row was the one holdout and so disagreed with what
// playback was doing -- the readout sampled the resting field while playback used the
// keyed curve. Without the mirror, a pitch automation would look inert in the
// inspector while audible, which is the same class of bug and would be found the same
// expensive way.
clip_pitch_at_playhead :: proc(clip: ^Clip) -> f32 {
	f := playhead.frame
	rel := i32(f - clip.timeline_start_frame)
	p, _ := audio_pitch_snapshot_from_clip(clip)
	return audio_pitch_semitones(&p, rel)
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
	// timeline_len is source_len divided by speed -- how long the clip OCCUPIES.
	// Carried separately because the two are different numbers for a stretched clip,
	// and every span computation was previously reading source_len for both. See
	// clip_timeline_length.
	timeline_len:   i64,
	// source_rate pins the rate source_start is counted against, carried with
	// the clip so the producer converts it without reading live timeline state
	// (see audio_source_start_sec).
	source_rate:   f64,
	stream_index:  c.int,
	// speed is the clip's tempo, snapshotted here for the same reason gain is: the
	// producer never reads live clips, so a tempo the producer does not know about is
	// a tempo it will play at 1.0 and report no error for.
	speed:         f64,
	// pitch is the clip's semitone offset, snapshotted for the same reason gain and
	// speed are: the producer never reads live clips.
	pitch:         Audio_Pitch_Snapshot,
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
	// keyframe_trunc_logged logs once when a gain keyframe track is capped.
	keyframe_trunc_logged: bool,
	// pitch_kf_trunc_logged is the same for pitch. Separate flag rather than a shared
	// one, because sharing them would mean a long gain track silences the pitch
	// warning forever -- the second cap would look already-reported.
	pitch_kf_trunc_logged: bool,
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
	if s.tempo.graph != nil {
		atempo_graph_destroy(&s.tempo)
	}
	ring_destroy(&s.fifo)
	ring_destroy(&s.out_ring)
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
			chip.timeline_len = clip_timeline_length(clip)
			chip.stream_index = clip.stream_index
			// clip_speed owns the 0-means-1.0 default, so a clip that never had its
			// speed touched snapshots as 1.0 rather than 0.
			chip.speed = clip_speed(clip)
			// Snapshot the clip's gain (static dB + its keyframe track) into the
			// shared committed shape. keyframe_fill_snapshot renders the name; the
			// geometry commit is UI-thread so reading the live clip is safe.
			g, total := audio_gain_snapshot_from_clip(clip)
			pitch_snap, pitch_total := audio_pitch_snapshot_from_clip(clip)
			chip.gain = g
			chip.pitch = pitch_snap
			if pitch_total > GAIN_KF_MAX_KEYS && !audio_geom_state.pitch_kf_trunc_logged {
				fmt.printf("[audio] pitch keyframe track exceeds GAIN_KF_MAX_KEYS=%d; keeping the first %d keys\n", GAIN_KF_MAX_KEYS, pitch_total)
				audio_geom_state.pitch_kf_trunc_logged = true
			}
			if g.n > 0 && total > GAIN_KF_MAX_KEYS && !audio_geom_state.keyframe_trunc_logged {
				fmt.printf("[audio] gain keyframe track exceeds GAIN_KF_MAX_KEYS=%d; keeping the first %d keys\n", GAIN_KF_MAX_KEYS, g.n)
				audio_geom_state.keyframe_trunc_logged = true
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
	audio_seek(playhead.frame, false)
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
// exactly (same path/stream, same clip speed and pitch, contiguous with its last
// segment in both timeline and source), or nil when chip must start a new group.
// A split produces the contiguous case; everything else keeps a forward-only fifo
// correct.
//
// SPEED AND PITCH ARE PART OF "EXACTLY", and leaving them out is the bug this
// comment exists for. A group owns ONE atempo graph, snapshotted from the first
// chip that created it, so folding a differently-tempoed chip into it mixes that
// clip through the WRONG tempo factor: a 0.5x clip plays at 1x, a 1x clip plays at
// 0.5x. That is audible as a clip that does not match its picture, and -- because
// WSOLA running at a factor it was not built for is exactly a time-stretcher
// hunting for match points it cannot find -- as audio that repeats.
//
// Contiguity alone found this pair, because two adjacent clips cut from the same
// file ARE contiguous in both timeline and source. Nothing about the geometry
// distinguishes them; only the tempo does.
//
// Measured on the user's own ~/sallyface.vyproj (85 audio clips on 5 of 7 tracks):
// loading it with the audio device up tripped the downstream assertion
//
//	audio_build_groups: one atempo graph cannot serve segments with different clip speed/pitch
//
// which is this function's decision arriving too late. The assertion was RIGHT and
// the grouping was wrong; the fix belongs here, where the choice is made.
audio_provision_find_group :: proc(
	slot: ^Audio_Geom_Slot,
	chip: ^Audio_Geom_Chip,
	reclaim: ^[MAX_PLAY_AUDIO]bool,
	want_speed: f64,
	want_pitch_ratio: f64,
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
		if g.speed != want_speed || g.pitch_ratio != want_pitch_ratio {
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
		// NOT the tempo test above, and the asymmetry is the point.
		//
		// The continue-loop check exists because two chips of DIFFERENT tempo must never
		// end up as segments of ONE group: a group has a single atempo graph, so that
		// mixes one clip at another's factor -- the bug this whole change is about.
		//
		// Reclaiming a slot is not that. It hands the LIVE DECODER to the new group, and
		// a decoder is tempo-agnostic: it turns content samples into content samples and
		// knows nothing about speed. The tempo lives on the GROUP, and audio_build_groups
		// rebuilds the graph for the new one (destroy the filter, drop the derived ring,
		// restamp speed) on the very next lines.
		//
		// Testing tempo here too was a real regression I introduced and then measured
		// away: with it, a speed OR PITCH edit stopped matching the continuing group,
		// built a fresh one with no decoder, and went down the Open path -- so every
		// tempo edit cost a file open plus a seek instead of a filter rebuild, and the
		// clip-tempo probe's `sought > 0` assertion failed against a correct engine.
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
		// Computed before the group search because the search now REQUIRES them: the
		// tempo is part of what makes a group continuable, not a property read off
		// the winner afterwards.
		want_speed := chip.speed
		if want_speed == 0 {
			want_speed = 1.0
		}
		want_pitch := audio_pitch_semitones(&chip.pitch, 0)
		want_pitch_ratio := semitones_to_ratio(want_pitch)
		if want_pitch_ratio <= 0 {
			want_pitch_ratio = 1.0
		}
		g := audio_provision_find_group(slot, chip, reclaim, want_speed, want_pitch_ratio)
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
			// Snapshotted, not defaulted: a source whose speed was never set must read
			// as 1.0 or it would take the stretched path with a speed of 0.
			g.speed = chip.speed
			if g.speed == 0 {
				g.speed = 1.0
			}
			// Pitch as a FREQUENCY RATIO, evaluated once here rather than per frame:
			// it is a clip property like the tempo, and the ratio is what the graph's
			// asetrate stage needs.
			g.pitch = audio_pitch_semitones(&chip.pitch, 0)
			g.pitch_ratio = semitones_to_ratio(g.pitch)
			if g.pitch_ratio <= 0 {
				g.pitch_ratio = 1.0
			}
			g.out_first = 0
			if g.tempo.graph != nil {
				atempo_graph_destroy(&g.tempo)
			}
			ring_destroy(&g.out_ring)
			audio_src.count += 1
		}
		if g.seg_count > 0 {
			// Now a consequence of audio_provision_find_group's contract rather than a
			// hope: a group is only continuable when its tempo matches, so a chip
			// already in a group must match it. Kept because it is the invariant that
			// makes "one graph per group" true, and it is the assertion that named the
			// ~/sallyface.vyproj grouping bug.
			assert(
				g.speed == want_speed && g.pitch_ratio == want_pitch_ratio,
				"audio_build_groups: one atempo graph cannot serve segments with different clip speed/pitch",
			)
		}
		if g.speed != want_speed || g.pitch_ratio != want_pitch_ratio {
			// Tempo/pitch are graph state, unlike gain. Invalidate post-graph output;
			// keep decoded content and let the reconcile anchor it at the playhead.
			if g.tempo.graph != nil {
				atempo_graph_destroy(&g.tempo)
			}
			ring_drop(&g.out_ring, ring_len(&g.out_ring))
			g.out_first = 0
		}
		g.speed = want_speed
		g.pitch = want_pitch
		g.pitch_ratio = want_pitch_ratio
		if g.seg_count >= MAX_PLAY_SEGMENTS {
			continue
		}
		g.seg[g.seg_count] = Play_Seg{
			start_a      = chip.timeline_start,
			start_s      = chip.source_start,
			start_s_rate = chip.source_rate,
			// The TIMELINE length, not the content length. These were the same number
			// before clips could be time-stretched, and treating them as interchangeable
			// is what made a 2x clip play at 1x.
			len_a        = chip.timeline_len,
			speed        = want_speed,
			gain         = chip.gain,
			pitch        = chip.pitch,
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
		content_sample := audio_content_sample_at_speed(
			seek_frame-seg.start_a, seg.start_s, seg.start_s_rate, seg.speed,
		)
		content_sec := f64(content_sample) / f64(AUDIO_BUS_RATE)
		output_sample := audio_frame_boundary48(seek_frame - seg.start_a, fps)
		switch snap[r].action {
		case .Keep:
			// Nothing to do. The decoder is anchored to the right content and its
			// fifo is content-relative, so both remain correct as they are -- in
			// particular the audio already sitting in that fifo must NOT be dropped,
			// because it is the audio for exactly the position we are keeping.
		case .Seek:
			if !audio_src_seek_anchor(s, content_sec, output_sample) {
				audio_src_reset(s)
				continue
			}
		case .Open:
			if !audio_src_open(s, content_sec, output_sample) {
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

// audio_rate_scale is how much TIMELINE the transport rate graph holds per second
// of device audio. At 1x the graph is nil and output frames are bus frames, so the
// scale is 1; above 1x each output frame covers more than one timeline frame's worth
// of content, so the cushion has to be measured in the same units. Named because
// audio_reconcile_is_seeked has to compute the same tolerance the feed loop uses,
// and a second copy of that arithmetic is how the two drift apart.
// audio_want_rate is the rate the mix should be time-stretched to.
//
// A scrub is NOT a rate for this graph. It used to be: atempo was built at the drag's
// velocity so the crossed frames could be consumed at the speed the pointer crossed
// them. That is now done by skipping content instead (see the fill loop), and building
// a graph for it is actively wrong -- atempo time-compresses, so every scrub pitched
// the audio up by the drag rate, and every change in that rate rebuilt the WSOLA
// graph, which is the 810-rebuild storm the rate quantisation was added to damp.
//
// So a scrub asks for 1x: no graph, no rebuild, no pitch shift. Playback's own rate
// (a clip deliberately slowed or sped up) still needs atempo and still gets it.
audio_want_rate :: proc() -> f64 {
	if sync.atomic_load(&audio_prod.scrub_active) {
		return 1.0
	}
	return max(1.0, playback.rate)
}

audio_rate_scale :: proc() -> f64 {
	if audio_atempo.graph == nil {
		return 1.0
	}
	return audio_want_rate()
}

// audio_reconcile_is_seeked reports whether serving `play_frame` is a PLAYHEAD
// MOVE rather than a geometry edit.
//
// The question cannot be answered by comparing the requested anchor against
// anything remembered, which is the mistake this replaces. The anchor is a
// REQUEST, not a position: during ordinary forward playback nothing seeks, so the
// requested anchor sits still while the sources play forward hundreds of frames
// past it. Measured on the user's own trace: the anchor read 57 while the playhead
// ran 198 -> 203 and the producer sat at 218, and a scrub back to frame 57 asked
// for an anchor that already read 57. Comparing request-against-request reported
// "the playhead did not move", so all 25 sources were kept, the queue was not
// dropped, next_frame was not rewound, and 161 frames of pre-scrub audio played on.
//
// So compare the request against where the sources ACTUALLY are. That is a fact
// about the engine's own state, it cannot be fooled by a repeated or stale
// request, and it is the same quantity the reconcile has to move.
//
// The cushion is the tolerance because that is the normal steady-state gap: the
// producer deliberately sits AUDIO_CUSHION_SEC ahead of the audible position so a
// hiccup cannot starve the device, so "where the playhead is" and "where the
// producer is" differ by exactly that much while everything is healthy. A playhead
// move puts them further apart than the cushion can explain. Explicit navigation
// bypasses this inference: a deliberate scrub release inside the cushion is still a
// seek, and its old queued audio is precisely what must not survive the release.
audio_reconcile_is_seeked :: proc(
	play_frame: i64,
	fps: f64,
	rate_sc: f64,
	force_seek: bool = false,
) -> bool {
	if force_seek {
		return true
	}
	if audio_src.count == 0 {
		// Nothing to move. The first provision of a run lands wherever it is asked
		// to, and there is no decoder to have drifted.
		return false
	}
	cushion := i64(AUDIO_CUSHION_SEC * f64(fps) * rate_sc + 1)
	return abs(play_frame - audio_src.next_frame) > cushion
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
//
// `seeked` states that the PLAYHEAD moved, which no amount of comparing the
// geometry can reveal -- see audio_reconcile_is_seeked. On a seek every decoder must re-anchor
// at the new position and the queue must go, whatever the segments say.
audio_reconcile :: proc(play_frame: i64, seeked: bool = false) -> Reconcile_Report {
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
		snap[i].old_speed = src.speed
		snap[i].old_pitch_ratio = src.pitch_ratio
		// The queued window's mapping has to be read while the old segment list
		// still exists -- seg_count is zeroed on the next line.
		snap[i].old_map_n, snap[i].old_map_ok =
			play_src_window_maps(src, play_frame, queued_to, snap[i].old_map[:])
		src.seg_count = 0
		// Offered back to the builder: this slot's decoder is a candidate to keep,
		// and it has to be the slot the new segments land in for that to happen.
		reclaim[i] = true
	}
	audio_build_groups(slot, &reclaim)

	new_map: [MAX_WINDOW_MAPS]Window_Map
	for i in 0 ..< audio_src.count {
		src := &audio_src.slots[i]
		// The segments the edit ADDS invalidate queued audio too, not just the
		// ones it removed, so the decision compares old mapping against new.
		new_n, new_ok := play_src_window_maps(src, play_frame, queued_to, new_map[:])
		snap[i].graph_changed =
			src.speed != snap[i].old_speed || src.pitch_ratio != snap[i].old_pitch_ratio
		if snap[i].old_map_ok && new_ok {
			snap[i].touched_window = play_src_window_maps_differ(
				snap[i].old_map[:],
				snap[i].old_map_n,
				new_map[:],
				new_n,
				play_frame,
				queued_to,
			)
			// Queued audio was mixed by the OLD graph, so a rate edit reaching
			// into the window invalidates it even where the content under it is
			// identical: pitch moves every output sample without moving content.
			if snap[i].graph_changed && (snap[i].old_map_n > 0 || new_n > 0) {
				snap[i].touched_window = true
			}
		} else {
			// Too many stretches to compare exactly; the conservative answer is
			// the one this predicate used to give for every edit.
			snap[i].touched_window = true
		}
		if seeked {
			// The playhead moved, so the queue holds audio for a position the user
			// has left. That is true whether or not any segment covers the window:
			// the queued frames are already mixed, and no mapping comparison can
			// see that they were mixed for somewhere else.
			snap[i].touched_window = true
		}
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
		} else if seeked {
			// A playhead move, so every decoder is aimed at content the user has
			// navigated away from. This is not reachable from the mapping
			// comparison above: old_content and new_content are both evaluated at
			// play_frame, so on a pure seek they are equal by construction and
			// every source would be Kept at the old position -- the right timing
			// with the wrong sound.
			snap[i].action = .Seek
			rep.sought += 1
		} else if snap[i].graph_changed {
			// The same content sample can be under the playhead at clip frame zero
			// while speed/pitch still changes the graph and every future output sample.
			// Force one anchor so its derived ring and filter are rebuilt at the new
			// committed properties.
			snap[i].action = .Seek
			rep.sought += 1
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
// audio_src_pump_tempo fills s's OUTPUT ring from s's content ring, through the
// source's own atempo graph, until at least `want_out` output samples are available.
//
// This is the whole of per-clip tempo. The relationship it maintains:
//
//     a timeline frame is spf output samples
//     a clip at speed S consumes spf * S content samples to fill it
//     atempo's tempo factor is 1/S (its `tempo=` is an output-length multiplier,
//     the inverse of the transport's rate -- measured to within a percent)
//
// FFmpeg's atempo owns its initial WSOLA context: it zero-pads the leading half-window,
// buffers real input, then emits overlap-add from input sample zero. Do not add a
// second, guessed lookahead discard here; it removes genuine clip content and the
// interpolated table was never authoritative between its four measured rates.
audio_src_pump_tempo :: proc(s: ^Play_Src, want_out: i64) {
	// A graph is needed if EITHER the tempo or the pitch is off-identity, so the test
	// cannot be `speed == 1.0`: a clip pitched at rate 1.0 still needs the graph.
	if s.speed == 1.0 && s.pitch_ratio == 1.0 {
		return
	}
	if s.tempo.graph == nil {
		// tempo IS the speed multiplier: atempo's `tempo=` shortens the output above
		// 1.0, so out/in = 1/tempo, and a clip at speed S needs out/in = 1/S -- which
		// means tempo = S, not 1/S.
		//
		// The previous version passed 1.0/s.speed and every stretched clip played at
		// the INVERSE of its speed. The gate did not catch it because the probe only
		// asserted that a stretched render DIFFERS from an unstretched one, and an
		// inverted render differs just as loudly as a correct one. That is the second
		// broken thing this branch exists to fix, and it is the same shape as every
		// other measurement mistake in this work: something that proved a thing was
		// happening, never that it was happening correctly.
		atempo_rate_set(&s.tempo, s.speed, s.pitch_ratio)
		if s.tempo.graph == nil {
			return
		}
	}

	// Chunk staging: bounded, so a long fill does not need a large stack buffer.
	CHUNK :: 2048
	stage: [CHUNK * 2]f32

	for i64(ring_len(&s.out_ring)) < want_out {
		// Pump from the CONTENT FIFO, not directly from the decoder. Provisioning
		// has already decoded and trimmed the opening content into that fifo; reading
		// straight from dec.s16 skipped those samples and made every stretched clip
		// start at a later packet boundary.
		if ring_len(&s.fifo) < CHUNK {
			audio_src_pull(s, s.first48 + i64(CHUNK))
		}
		got := min(CHUNK, ring_len(&s.fifo))
		if got == 0 {
			break
		}
		for i in 0 ..< got {
			left, right := ring_at(&s.fifo, i)
			stage[i * 2 + 0] = left
			stage[i * 2 + 1] = right
		}
		ring_drop(&s.fifo, got)
		s.first48 += i64(got)
		atempo_process(&s.tempo, stage[:], got)
		if s.tempo.out_n == 0 {
			continue
		}
		// Converted and pushed in bounded SLICES, not one buffer sized to out_n.
		//
		// out_n is not bounded by CHUNK: atempo's factor is 1/speed, so a clip at
		// speed 4 emits FOUR output frames per input frame and a 2048-frame push
		// produces 8192. A single CHUNK-sized staging buffer therefore overflowed the
		// stack on exactly the fast clips the feature exists for, after the graph had
		// built successfully -- so it crashed on use rather than degrading.
		i16_out: [CHUNK * 2]i16
		emitted := 0
		for emitted < s.tempo.out_n {
			take := min(CHUNK, s.tempo.out_n - emitted)
			for i in 0 ..< take * 2 {
				v := s.tempo.out_buf[emitted * 2 + i]
				i16_out[i] = clamp(i16(v * 32767.0), -32768, 32767)
			}
			ring_push_pcm(&s.out_ring, i16_out[:take * 2], take)
			emitted += take
		}
	}
}

audio_src_pull :: proc(s: ^Play_Src, up_to48: i64) {
	for s.have48 < up_to48 {
		n := decode_audio_chunk(&s.dec, -1.0)
		if n <= 0 {
			break
		}
		audio_src_append(s, n)
		s.have48 += i64(n)
	}

	// Everything this produced is the answer to whatever re-anchor was last
	// asked, so it is what lets a later re-anchor be distinguished from a spin.
	s.reanchor_pulled += int(s.have48 - s.reanchor_have48)

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

audio_src_open :: proc(s: ^Play_Src, content_sec: f64, output_sample: i64) -> bool {
	if !open_audio_decoder_resampled(&s.dec, s.path, s.stream_index, 48000, 2) {
		return false
	}
	return audio_src_seek_anchor(s, content_sec, output_sample)
}

// audio_src_seek_anchor (re)seeks s's decoder to content second `content_sec`
// with AUDIO_SEEK_PREROLL_SEC of headroom and refills the fifo, relabeling its
// base to the decoder's real landing PTS. An AAC seek can land tens of ms after
// the asked position; labeling the fifo with the asked time would compound that
// offset every frame and drift the content against the playhead (reads as
// half-speed), while not seeking early enough leaves the segment head silent.
audio_src_seek_anchor :: proc(s: ^Play_Src, content_sec: f64, output_sample: i64) -> bool {
	//
	// A re-anchor that does not advance the decoder must not be repeatable.
	//
	// The mixer re-anchors when its fifo head is ahead of, or behind, the frame
	// being mixed, and a scrub re-anchors on the pointer. Both are conditions a
	// decoder that cannot satisfy keeps re-reporting -- so if a seek leaves have48
	// where it was, the next pass sees the same condition and seeks again, and the
	// producer spins in seeks instead of decoding. That is not a slow path, it is a
	// loop: nothing is decoded, nothing is queued, and the ring stays empty.
	//
	// Measured on a real project as a decoder asked for a constant -1.000s offset
	// over and over while fed stayed frozen at one value and the queue stayed at
	// zero. Reading it as "lag" cost a lot of time; it was a spin.
	//
	// The escape is to require PROGRESS: re-anchoring the same source again is only
	// allowed once the previous one actually moved the decode position, or after a
	// cooldown. That converts an unbounded loop into a decode attempt, which either
	// works or reports why it cannot.
	//
	// The bound is on REPEATING THE SAME ASK, not on seeking twice. A different
	// content position is a different request and always goes through -- blocking
	// those broke the first-frame path, because a fresh provision legitimately
	// anchors twice and have48 has not moved in between.
	now := i64(monotonic_ns())
	repeating := s.reanchor_have48 == s.have48 && abs(content_sec - s.reanchor_at) < 1e-6
	scrubbing := sync.atomic_load(&audio_prod.scrub_active)
	//
	// Refusing is WORSE than retrying, and measuring it said so: bound purely on
	// "the previous seek did not move have48", it refused 2340 re-anchors in one
	// backward-then-forward drag and every refusal is a `continue` in the mixer, so
	// the drag went silent. have48 only grows when the decoder is PULLED, so a
	// perfectly good seek looks like a failed one until somebody asks for the
	// audio -- which is exactly when a re-anchor is wanted.
	//
	// So the bound is not on seeking at all. It is on seeking the same position
	// with nothing PULLED in between, which is the actual spin: re-anchor, refuse
	// to decode, re-anchor.
	if scrubbing &&
	   s.reanchor_ns != 0 &&
	   repeating &&
	   s.reanchor_pulled == 0 &&
	   now - s.reanchor_ns < AUDIO_REANCHOR_COOLDOWN_NS {
		audio_rpt.reanchor_blocked += 1
		return false
	}
	s.reanchor_ns = now
	s.reanchor_have48 = s.have48
	s.reanchor_at = content_sec

	// A decoder seek invalidates both the content fifo and its derived tempo output.
	// Keep the first output sample anchored to the timeline position that requested
	// the seek; zeroing this on an interior scrub would replay sought content from the
	// clip's beginning. atempo_reset keeps this source's speed/pitch snapshot.
	ring_drop(&s.fifo, ring_len(&s.fifo))
	ring_drop(&s.out_ring, ring_len(&s.out_ring))
	s.out_first = output_sample
	atempo_reset(&s.tempo)
	// One proc for the opening, shared with the export. This used to clamp the
	// preroll seek to zero and then take whatever the decoder landed on, which
	// silently dropped the first frame of the first clip.
	want := i64(content_sec * f64(s.dec.out_rate))
	n := decode_from_content(&s.dec, want)
	if n <= 0 {
		return false
	}
	// Label the fifo at the decoder's REAL landing PTS, not at the request, and keep
	// the preroll in it. Both halves of that are load-bearing.
	//
	// Labelling at the request would be the obvious "fix" for a fifo read short of its
	// demand, and it is wrong twice over: it moves content the tempo graph still needs,
	// and it was measured. A first attempt discarded the preroll and appended only from
	// the request; the clip-alignment probe then moved a 0.25x clip's opening click by
	// 880 output samples, because the WSOLA graph that clip reads through had lost the
	// input it primes itself with.
	//
	// Keeping the preroll is not what let the producer play half a second late. The
	// fifo was left too SHORT: audio_mix_frame reads start48 = max(demand48, s.first48),
	// so a fifo labelled early is only usable once have48 reaches the demand, and that
	// was left to the per-frame pull to achieve -- one frame per tick, and only while
	// the mixer had budget. Measured: a seek to frame 56 left the fifo labelled at
	// content 20800 with a demand of 44800, so the mixer read it as a hole, zeroed the
	// output, and every state assertion -- next_frame rewound, queue dropped, decoder
	// re-anchored -- passed while the audio was half a second out.
	//
	// So the preroll stays AND the request is covered here, in the same call. One seek
	// therefore leaves the fifo able to serve the frame that asked for it.
	s.first48 = i64(decoder_pts_sample(s.dec.first_ts, s.dec.stream.time_base))
	s.have48 = s.first48 + i64(n)
	audio_src_dump_dec(s, n)
	audio_src_append(s, n)
	// One mixer frame past the request, which is the most any single frame can ask for.
	audio_src_pull(s, want + i64(MAX_AUDIO_FRAME_SAMPLES))
	return true
}

// db_to_linear converts a decibel level to an amplitude multiplier: +6 dB
// doubles the amplitude, -20 dB is 1/10. Odin's math.pow overloads f32
// (pow_f32), keeping this an f32-only call.
 db_to_linear:: proc "contextless"(db: f32) -> f32 {
	return math.pow(10, db / 20)
}

// keyframe_gain_linear evaluates a gain keyframe track — authored in dB, the unit the
// inspector shows — to a LINEAR amplitude multiplier at clip-relative frame
// `rel`. `base_dB` is the clip's static level (also dB) and rules where the
// track has no key yet (empty, or before the first key); past the last key the
// track holds its final dB, so a fade that ends sustains its end level instead
// of snapping back to the clip's static gain. Both the playback mixer and the
// export mixer go through here, so a key's dB value can never again be mistaken
// for the multiplier itself (a -40 dB key is 0.01, not -40).
 keyframe_gain_linear:: proc "contextless"(keys: []Keyframe, rel: i32, base_dB: f32) -> f32 {
	if len(keys) == 0 {
		return db_to_linear(base_dB)
	}
	db, _ := keyframe_sample_keys(keys, rel, base_dB)
	return db_to_linear(db)
}

// play_seg_gain_linear is a segment's linear amplitude multiplier at its
// clip-relative frame `rel`. Thin wrapper over the shared snapshot evaluator so
// playback and export resolve the same committed shape identically; extracted
// so the unit conversion is testable off the decode path (keyframe_probe), not
// just observable as "playback starts loud".
play_seg_gain_linear:: proc "contextless" (seg: ^Play_Seg, rel: i32) -> f32 {
	return audio_gain_linear(&seg.gain, rel)
}

// clip_gain_db_at_playhead is the gain the inspector should DISPLAY for `clip`:
// the keyed dB value where its gain track is active at the playhead, else the
// static cl.gain. It mirrors every geometry lane, whose readout samples the
// keyed curve (clip_geom_get) rather than showing the resting field — the gain
// row was the one holdout and so disagreed with what playback was doing.
clip_gain_db_at_playhead :: proc(clip: ^Clip) -> f32 {
	if v, active := keyframe_sample_for(clip, "gain", playhead.frame, clip.gain); active {
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
// Mix_Src is what a source looks like to the mixer: a fifo of decoded content
// samples, the content position of that fifo's head, and the clip's span on the
// bus. It is deliberately NOT a struct -- both sinks' sources (Play_Src and
// Render_Audio_Src) already carry these fields, and copying them into a third
// struct per block would be the duplication this is meant to remove.
//
// Everything a source needs in order to be mixed is here: where its content
// starts, how far it reaches, where its buffer begins and ends, and the pull that
// refills it. The two sinks differ only in HOW they refill and in how they express
// a position -- playback has a frame index, the export an absolute Sample_Pos --
// and both of those are resolved by the caller before the block reaches
// mix_src_block. What is left is arithmetic that must not exist twice.
mix_src_block:: proc "contextless" (
	fifo: ^Audio_Ring,
	first48: i64,
	have48: i64,
	content: i64,
	want: int,
	g: f32,
	out: []f32,
	off: int,
	// frac is the sub-sample part of `content`. Reading nearest-neighbour at a
	// fractional offset is decimation without a filter, which is the rest of the
	// "poppy": the step lands on whichever sample happens to be there, and the
	// error against the true signal is full-scale rather than the small offset
	// it should be. Linear interpolation across `frac` reduces that error to
	// first order and is what makes a resampled read sound smooth.
	//
	// Defaulted, so every other caller -- including the export -- is untouched
	// and keeps its exact integer reads.
	frac: f32 = 0.0,
) -> (mixed: bool) {
	if want <= 0 {
		return false
	}
	base := int(content - first48)
	if base < 0 {
		// The fifo head is PAST the content this block asks for. The caller has
		// already decided what to do about it (the export counts it, playback clamps
		// its demand forward); this is the backstop that keeps the index arithmetic
		// honest, because reading a negative ring index would return whatever happens
		// to be in the buffer rather than an error.
		return false
	}
	if frac == 0.0 {
		for f in 0 ..< want {
			l, r := ring_at(fifo, base + f)
			o := (off + f) * 2
			out[o + 0] += l * g
			out[o + 1] += r * g
		}
		return true
	}
	for f in 0 ..< want {
		l, r := ring_at(fifo, base + f)
		ln, rn := ring_at(fifo, base + f + 1)
		o := (off + f) * 2
		out[o + 0] += (l + (ln - l) * frac) * g
		out[o + 1] += (r + (rn - r) * frac) * g
	}
	return true
}

//
// sample_offset shifts the CONTENT read position by a fraction of a frame, in
// bus samples. It is what makes a scrub able to play faster than 1x: the caller
// advances the read position by more than one frame per output period, and the
// mix follows it.
//
// It is deliberately stateless. atempo, the obvious tool for this, buffers ahead
// and cannot be re-pointed without a rebuild plus a re-prime, which is why every
// attempt to scrub through it either went silent or aborted the process inside
// libavfilter. Reading at an offset has no state to lose: re-pointing is just a
// different number.
//
// The cost is the honest one for this primitive: pitch rises with speed, because
// it is resampling and not time-stretching. That is what a jog wheel and every
// video editor's audio scrub sound like. Losing pitch fidelity is the price of
// being able to jump instantly, and it is a better price than silence.
audio_mix_frame :: proc(mix: []f32, frame: i64, spf: int, sample_offset: f64 = 0.0) -> bool {
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
		// Content position, scaled by the clip's tempo. At 1.0 this is exactly the old
		// call -- the helper short-circuits -- so the unstretched path is untouched.
		demand48 := i64(
			audio_content_sample_at_speed(frame - seg.start_a, seg.start_s, seg.start_s_rate, s.speed),
		)
		// The offset lands in the content sample domain, so it is applied after the
		// timeline->content mapping and scales with whatever that mapping produced.
		// Flooring to a sample is the resampling step: reading ahead of the nominal
		// position is exactly what plays the crossed range faster than real time.
		frac := f32(0.0)
		if sample_offset != 0.0 {
			frac = f32(sample_offset - f64(int(sample_offset)))
			demand48 += i64(sample_offset)
		}
		stretched := s.speed != 1.0 || s.pitch_ratio != 1.0
		start48 := demand48
		if !stretched {
			// The raw fifo sits somewhere other than where this frame needs samples.
			// Both distances are re-anchored with a seek, because a decode only
			// substitutes when it is cheaper. The tempo path does not use this head:
			// its decoded FIFO feeds WSOLA, and that graph's output ring is the timeline
			// position authority while lookahead content is buffered.
			head_ahead := s.first48 - demand48 > i64(spf)
			head_behind := demand48 - s.have48 > AUDIO_FORWARD_DECODE_MAX_48
			if head_ahead || head_behind {
				content_sec := f64(demand48) / f64(AUDIO_BUS_RATE)
				output_sample := audio_frame_boundary48(frame-seg.start_a, fps)
				if !audio_src_seek_anchor(s, content_sec, output_sample) {
					continue
				}
			}
			// A seek lands on the decoder's real PTS, which the demuxer's slack can put
			// a sample or two either side of the demand. Mix from the fifo head when it
			// landed ahead, so the base is never before the head.
			if s.first48 > demand48 {
				audio_rpt.head_clamped += 1
				audio_rpt.head_clamp_max = max(audio_rpt.head_clamp_max, s.first48-demand48)
			}
			start48 = max(demand48, s.first48)
			audio_src_pull(s, start48+i64(spf))
			if s.have48 < start48+i64(spf) {
				// The fifo cannot cover this frame. Silence for the span, and mark the
				// level -- the export's render_mix_block does exactly this, and a
				// resume after a hole is an edge a listener hears even though no clip
				// changed.
				continue
			}
		}
		// A STRETCHED clip reads from its own post-atempo ring instead, and consumes
		// S times the content to fill the same number of output samples. That is the
		// entire difference between the two paths: which ring, and how fast content
		// flows. The mixing arithmetic below is shared -- mix_src_block takes a ring
		// POINTER -- so this is a choice of argument, not a second implementation.
		//
		// speed == 1.0 takes neither branch and runs the code exactly as before,
		// which is what keeps the feature inert until a clip is stretched.
		base := 0
		mix_ring := &s.fifo
		mix_first := s.first48
		mix_have := s.have48
		mix_demand := start48
		if stretched {
			mix_ring = &s.out_ring
			mix_first = s.out_first
			mix_have = s.out_first + i64(ring_len(&s.out_ring))
			// Map this timeline frame to the clip-relative OUTPUT domain. Usually that
			// equals out_first; after a seek it can be ahead (drop the skipped ring
			// range) or behind (re-anchor decoder/filter instead of replaying a later
			// output sample as though it were this frame).
			mix_demand = audio_frame_boundary48(frame-seg.start_a, fps)
			if mix_demand < mix_first {
				content_sec := f64(demand48) / f64(AUDIO_BUS_RATE)
				if !audio_src_seek_anchor(s, content_sec, mix_demand) {
					continue
				}
				mix_first = s.out_first
				mix_have = mix_first + i64(ring_len(mix_ring))
			}
			need := mix_demand + i64(spf)
			audio_src_pump_tempo(s, need - mix_first)
			mix_have = mix_first + i64(ring_len(mix_ring))
			if mix_have < need {
				// The graph cannot cover this frame -- the clip ran out of content, or
				// the decoder has not kept pace. Silence for the span, same as the
				// content path, so a stretched clip fails like any other source rather
				// than quietly playing at the wrong length.
				continue
			}
			base = int(mix_demand - mix_first)
		} else {
			base = int(start48 - s.first48)
		}
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
		// One mixing loop for both sinks (mix_src_block). `base` and the shortfall
		// checks above are the playback half; the export has its own, and the arithmetic
		// that used to be copy-pasted between them now exists once.
		//
		// No automatic ramp at a clip edge -- a cut is a cut. There was a declick here
		// and it was this engine's SECOND fade mechanism: gain is already automated per
		// sample through the clip's keyframe envelope, so an edge ramp was an implicit
		// fade on every edit whether the user wanted one or not. The two mechanisms
		// disagreed at ~2.5e-3 in a clip's final fade, because the ramp normalised
		// against the CALLER'S CHUNK LENGTH. An authored fade is expressed through the
		// envelope; the engine's job is that what you cut is what you hear.
		sample_off := int(blk_lo - frame_lo)
		if mix_src_block(
			mix_ring,
			mix_first,
			mix_have,
			mix_demand + i64(sample_off),
			want,
			g,
			mix[:],
			sample_off,
			frac,
		) {
			delivered = true
		}
		when ODIN_DEBUG {
			if audio_rpt.trace {
				fmt.printf(
					"[tr mix] fr=%d k=%d seg0=%d start48=%d have48=%d fifo=%d del=%v\n",
					frame, k, seg.start_a, start48, s.have48, ring_len(&s.fifo), delivered,
				)
			}
		}
		// Drop everything up to and including this frame from the fifo. O(1):
		// see ring_drop -- this used to be a mem.copy shifting the remaining
		// buffered content down to index 0 plus a resize, on every mixed frame,
		// per source, on the real-time producer thread.
		consumed := base + spf
		if consumed > 0 {
			if s.speed != 1.0 || s.pitch_ratio != 1.0 {
				// The graph path consumes OUTPUT samples, and the content
				// position follows from the speed rather than being tracked
				// separately: content = output * speed. So one counter, not two.
				ring_drop(&s.out_ring, consumed)
				s.out_first += i64(consumed)
			} else {
				ring_drop(&s.fifo, consumed)
				s.first48 += i64(consumed)
			}
		}
	}
	return delivered
}

audio_init :: proc() -> bool {
	// Read the log toggles BEFORE opening the device: the device announces its
	// negotiated shape under trace, and the old order had that print fire before
	// trace was ever set, so it had never printed once.
	// The periodic audio log has a period rather than being a flag, so it takes a
	// number; the default is 2s. Below 50ms it would print faster than a terminal
	// shows, which is not more information, it is less.
	// The periodic audio log has a period rather than being a flag, so it takes a
	// number; the default is 2s. Below 50ms it would print faster than a terminal
	// shows, which is not more information, it is less.
	when ODIN_DEBUG {
		audio_rpt.log_ms = i64(diag_interval("VYPER_AUDIO_LOG", 2000))
		audio_rpt.log_full = diag_flag("VYPER_AUDIO_FULL")
	}
	when ODIN_DEBUG {
		audio_rpt.trace = diag_flag("VYPER_AUDIO_TRACE")
	}
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
	sync.atomic_store(&audio_prod.force_seek_resync, 0)
	sync.atomic_store(&audio_prod.scrub_active, false)
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


// repro_baseline is the previous pass's producer position, and the presence flag that
// says whether there IS one. Package scope because a diagnostic that had to thread its
// state through audio_producer_feed's signature would not have been written.
repro_last_prod:  i64 = 0
repro_last_ph:    i64 = 0
repro_last_resync: i64 = 0
repro_have_prod: bool = false
repro_repeats:   i64 = 0
repro_jumps:     i64 = 0
repro_desyncs:   i64 = 0
repro_scrub_stales: i64 = 0

// repro_report is the audio reproduction engine's trace: one structured line per feed
// pass, plus an explicit ANOMALY line for each of the three faults the reported symptom
// is made of.
//
// It lives here, at the end of the pass, rather than in the UI thread for one reason: the
// producer is the only thing that knows where the AUDIO is. The playhead is a readout of
// the device clock, so a fault that moves the producer without moving the playhead -- or
// the reverse -- is invisible from the UI side, and that asymmetry is exactly what
// "repeating but the playhead looks fine" is.
//
// Every counter is cumulative so a long run can be summarised by its totals rather than
// by counting lines.
repro_report :: proc(fps: f64, dev_pos: i64) {
	// next_frame, NOT audio_prod.prod_frame, is the position this detector must watch.
	// prod_frame is only republished on a provision or a reconcile, so it is flat
	// across a hundred ordinary feed passes -- which means a per-tick jump is
	// invisible in it. Measured while building this: injecting next_frame += 200
	// produced a DESYNC line and NO JUMP line, because prod_frame had not moved at all.
	//
	// Safe to read next_frame here because this runs on the producer thread, at the
	// end of that same pass -- the same thread and the same tick that just advanced it.
	prod := audio_src.next_frame
	dev := sync.atomic_load(&playback.dev_frame)
	dev_resync := sync.atomic_load(&playback.dev_resync)
	resync := sync.atomic_load(&audio_prod.resync)
	queued := audio_device_queued()
	sources := audio_src.count
	playing := sync.atomic_load(&audio_prod.run)
	scrubbing := sync.atomic_load(&audio_prod.scrub_active)

	if !repro_have_prod {
		// First pass: establish the baseline and say so. Without this the very first
		// tick reports a jump of whatever the previous run left behind, which is how a
		// diagnostic talks you into a bug that is not there.
		repro_have_prod = true
		repro_last_prod = prod
		repro_last_ph = playhead.frame
		repro_last_resync = resync
		fmt.printf(
			"[repro] BASELINE next=%d ph=%d published_prod=%d dev=%d resync=%d sources=%d queued=%d running=%t (anomaly counting starts now)\n",
			prod, playhead.frame, sync.atomic_load(&audio_prod.prod_frame), dev, resync, sources, queued, playing,
		)
		return
	}
	delta := prod - repro_last_prod
	repro_last_prod = prod
	ph_delta := playhead.frame - repro_last_ph
	repro_last_ph = playhead.frame
	resync_delta := resync - repro_last_resync
	repro_last_resync = resync

	fmt.printf(
		"[repro] next=%d (d%+d) ph=%d (d%+d) published_prod=%d dev=%d dev_resync=%d resync=%d (r%+d) srcs=%d q=%d fed=%d run=%t scrub=%t clear_req=%t avail=%d nocov=%d skipfull=%d\n",
		prod, delta, playhead.frame, ph_delta,
		sync.atomic_load(&audio_prod.prod_frame), dev, dev_resync, resync,
		resync_delta,
		sources, queued, audio_rpt.total_fed_frames, playing, scrubbing,
		sync.atomic_load(&audio_dev.clear_req),
		audio_device_available(),
		audio_rpt.skip_nocov,
		audio_rpt.skip_full,
	)

	// REPEAT: the producer fed content that was already played. That is only a
	// fault if it happened twice, so it is counted against a window rather than
	// against the last block. One repeat at startup is a decoder landing slightly
	// late, which is expected; a repeat every pass is a cursor that is not moving
	// and is the signature of a wedged producer.
	cushion_frames := i64(AUDIO_CUSHION_SEC * f64(fps) + 1)
	unasked := -delta - (-ph_delta) - cushion_frames
	if playing && !scrubbing && resync_delta == 0 && delta < -REPRO_REPEAT_SLACK_FRAMES &&
	   unasked > REPRO_REPEAT_SLACK_FRAMES {
		repro_repeats += 1
		fmt.printf(
			"[repro] ANOMALY REPEAT #%d: producer %d -> %d (%d frames back) while playhead moved %+d; %d frames re-fed beyond the %d frame cushion\n",
			repro_repeats, prod - delta, prod, -delta, ph_delta, unasked, cushion_frames,
		)
	}
	// JUMP: a large advance with no user action behind it. Read against the
	// [repro] CAUSE line the forward-skip branch prints when IT is the cause; if no
	// CAUSE line precedes the jump, the advance came from the fill loop and the next
	// thing to ask is why the queue emptied.
	if playing && !scrubbing && resync_delta == 0 && delta >= REPRO_JUMP_FRAMES {
		repro_jumps += 1
		fmt.printf(
			"[repro] ANOMALY JUMP #%d: producer advanced %d -> %d (+%d frames, %.2f s) in one pass\n",
			repro_jumps, prod - delta, prod, delta, f64(delta) / max(f64(fps), 1),
		)
	}
	// DESYNC: the playhead and the device clock disagree. Reported only when the
	// reading is CURRENT (dev_resync == resync), because a stale dev_frame is a known
	// and intended state for a few ms after every seek -- reporting that as desync
	// would bury the real thing in noise.
	if playing && !scrubbing && dev_resync == resync {
		if gap := playhead.frame - dev; gap > REPRO_DESYNC_FRAMES || -gap > REPRO_DESYNC_FRAMES {
			repro_desyncs += 1
			fmt.printf(
				"[repro] ANOMALY DESYNC #%d: playhead %d vs device %d (%+d frames, %+.3f s), reading is CURRENT\n",
				repro_desyncs, playhead.frame, dev, gap, f64(gap) / max(f64(fps), 1),
			)
		}
	}

	// SCRUB STALENESS. The measure every other detector above is switched off for.
	//
	// REPEAT, JUMP and DESYNC are all gated !scrubbing, so during the one interaction
	// where the listener is moving through content faster than any queue can be
	// rewritten, the engine reports nothing at all. The scrub gates do not fill the
	// gap: they assert audio_src.next_frame, the producer's cursor, which is a
	// different queue from the one the listener hears.
	//
	// So the number that describes the complaint is the distance between the frame the
	// UI is showing and the frame the device is actually rendering: that many frames
	// of audio for a position the pointer has already left are committed and cannot be
	// recalled. Read from dev_frame, which is the device's own consumption position --
	// the same clock the listener is synchronised to, not the pointer's intent.
	if playing && scrubbing && dev_resync == resync {
		stale := playhead.frame - dev
		if stale < 0 {
			stale = -stale
		}
		audio_rpt.scrub_stale_max = max(audio_rpt.scrub_stale_max, stale)
		audio_rpt.scrub_stale_sum += stale
		audio_rpt.scrub_stale_n += 1
		if stale > REPRO_DESYNC_FRAMES {
			repro_scrub_stales += 1
			fmt.printf(
				"[repro] ANOMALY SCRUB STALE #%d: UI shows %d, device is rendering %d -- %d frames (%.2f s) of audio already committed for a position the pointer has left\n",
				repro_scrub_stales, playhead.frame, dev, stale, f64(stale) / max(f64(fps), 1),
			)
		}
	}
}

// repro_summary prints the totals and resets the counters, so a run can be summarised
// without keeping the whole trace. Called by the probe harness at the end of a run.
repro_summary :: proc() {
	audio_rpt.scrub_stale_max = 0
	audio_rpt.scrub_stale_sum = 0
	audio_rpt.scrub_stale_n = 0
	mean := i64(0)
	if audio_rpt.scrub_stale_n > 0 {
		mean = audio_rpt.scrub_stale_sum / audio_rpt.scrub_stale_n
	}
	fmt.printf(
		"[repro] SUMMARY repeats=%d jumps=%d desyncs=%d scrub_stale=%d (max %d mean %d frames over %d scrub passes) over %d frames fed\n",
		repro_repeats, repro_jumps, repro_desyncs, repro_scrub_stales,
		audio_rpt.scrub_stale_max, mean, audio_rpt.scrub_stale_n,
		audio_rpt.total_fed_frames,
	)
	repro_repeats, repro_jumps, repro_desyncs = 0, 0, 0
	repro_scrub_stales = 0
	repro_have_prod = false
	repro_last_ph = 0
	repro_last_resync = 0
}

// SCRUB_CUSHION_FRAMES is how far ahead of the playhead the producer aims while
// the pointer owns it. Deliberately a few frames, not AUDIO_CUSHION_SEC: the drag
// cushion only has to absorb producer jitter, because the audible position is
// supposed to BE the playhead during a scrub. Sized in frames because a scrub is
// about frames, and a time-based cushion would grow with both rate and clip rate.
SCRUB_CUSHION_FRAMES :: 4

// SCRUB_REANCHOR_SLACK_FRAMES is how far the playhead may fall behind the producer
// before it re-anchors. Slack absorbs the pointer's own jitter so a hand that
// wobbles a pixel does not re-seek every decoder; past it, the producer is mixing
// audio the listener has already scrolled past.
SCRUB_REANCHOR_SLACK_FRAMES :: 8

// SCRUB_MIN_RATE / SCRUB_MAX_RATE bound the varispeed rate a scrub can ask for. The
// floor keeps atempo's tempo positive and the graph moving when the pointer is nearly
// still; the ceiling is past the point where time-stretched audio stops being
// intelligible and becomes a artifact. Both are about the drag, not the content.
// SCRUB_MIN_RATE is the floor on the scrub rate. It is 1.0 -- normal speed --
// not because a slow drag should sound fast, but because dropping to a near-stop
// was measured as the distortion: the rate slammed between the floor and the
// ceiling on every stop-start, each change rebuilding the atempo graph (810
// rebuilds, 175% of the drag lost or repeated). A floor at 1.0 keeps the rate in a
// narrow band the graph can track without rebuilding on every pause.
SCRUB_MIN_RATE :: 1.0
//
// SCRUB_MAX_RATE bounds how far the scrub read may run ahead.
//
// It used to be 100, on the reasoning that faster is better. It is not: the read
// decimates, and past a certain ratio every sample skipped folds back as alias,
// which is why the audio was popping specifically when zoomed out -- zoomed out,
// one pixel spans many frames, the frame velocity spikes, and the rate pinned to
// the ceiling. At 100:1 the content being skipped is 99% of the signal.
//
// The cap therefore has to be set by what the read path can do cleanly, not by
// how fast the hand went. 8x is the point where the one-pole ahead of the read
// still has an octave of margin before the fold-back becomes the loudest thing
// in the signal. Beyond that, scrubbing further is not "faster", it is noisier,
// and a pointer crossing a large span at once simply gets less audio.
SCRUB_MAX_RATE :: 8.0

// audio_producer_feed mixes whole timeline frames up to a target derived from
// the sound device's own consumption: everything pushed minus what is still in
// the stream queue is what the device has actually played, and that position
// advances at the hardware clock. The producer keeps it ~AUDIO_CUSHION_SEC
// ahead, on the queue ceiling, so processing rate can never differ from the
// device's reproduction rate.
audio_device_audible_sample :: proc(
	next_input_sample: Sample_Pos,
	queued_output_frames: i64,
	transport_rate: f64,
	graph: ^Atempo_Graph,
	pending_content_samples: i64,
) -> Sample_Pos {
	// A missing graph means raw 1x samples are queued even if a requested graph build
	// failed. Never scale their queue as if atempo had transformed them.
	effective_rate := 1.0
	if graph.graph != nil {
		assert(graph.rate == transport_rate, "audio_device_audible_sample: graph rate differs from transport")
		effective_rate = graph.rate
	}
	queued_content := f64(queued_output_frames) * effective_rate
	pending_from_graph := f64(atempo_pending_input_samples(graph))
	pending_content := f64(pending_content_samples)
	assert(pending_from_graph == pending_content, "audio_device_audible_sample: pending count changed")
	buffered := i64(queued_content + pending_content + 0.5)
	return Sample_Pos(max(0, i64(next_input_sample)-buffered))
}

// ---------------------------------------------------------------------------
// Feed phases. audio_producer_feed was one 849-line proc doing seven unrelated
// jobs -- device gating, rate reconciliation, decoder trimming, position
// publishing, gain folding, scrub cursor management, mixing and metering. These
// are those phases, each with one job and one name. Nothing here changed
// behaviour; the split is so a reader can hold one phase at a time.
// ---------------------------------------------------------------------------

// producer_device_ready reports whether this feed pass may run at all.
//
// audio_device_clear cannot touch the ring itself -- the read cursor belongs to
// the callback -- so it raises a flag the callback honours on its next pass, one
// device period later. A pass that filled the ring inside that window replaced
// audio that was meant to be discarded with a mix built for the NEW position, and
// the seek came out wrong.
//
// The wait is bounded, because unbounded is a deadlock rather than a lag: if the
// callback is never driven the flag never clears and the producer returns early
// on every pass forever. Measured on a scrub as fed frozen at 52000 with
// run=true and q=0. Past the bound the producer stops waiting on a thread that
// may not be running; the ring reset still lands on the callback next pull, so no
// stale audio is played either way.

producer_device_ready :: proc() -> bool {
	if !audio_device_ready() {
		return false
	}
	// HOLD OFF UNTIL A PENDING CLEAR HAS LANDED.
	//
	// audio_device_clear cannot touch the ring itself -- the read cursor belongs to
	// the callback -- so it raises a flag the callback honours on its next pass, one
	// device period (~10 ms) later. Refilling in that window is what makes a seek
	// come out wrong: the producer fills to a cushion, the callback then resets it,
	// and the audio that was supposed to be discarded is replaced by a mix made for
	// the NEW position. Measured on a backward scrub to frame 36 as dev=62 against
	// a playhead of 36, with the playhead unable to advance and appearing to snap
	// forward on release.
	//
	// A pass skipped here also keeps dev_frame from claiming an audible position
	// that has not been heard: audio_device_queued reports 0 while a clear is
	// pending, so any position derived from it would be fiction.
	if audio_device_clear_pending() {
		if audio_device_clear_stuck(
			sync.atomic_load(&audio_dev.clear_asked_ns),
			i64(monotonic_ns()),
		) {
			// The ring reset still happens on the callback's next pull, so no stale
			// audio is played. The producer just stops waiting on a thread that may
			// not be running.
			sync.atomic_store(&audio_dev.clear_req, false)
		} else {
			return false
		}
	}
	return true
}

// producer_sync_rate rebuilds or retunes the atempo graph when the transport's
// playback rate changes, then re-anchors the sources to the audible frame.
//
// Lazily, only on a change: the producer runs every ~2 ms and a graph rebuild
// costs a few ms.
//
// A drag never reaches this path. The graph time-compresses, and a scrub is
// already covering R periods of content per period of output by skipping, so
// running both would stretch the samples that survived the skip as well -- the
// pitch shift this exists to remove.

producer_sync_rate :: proc(fps: f64, want_ratio: f64) {
	// Playback-rate: rebuild the atempo graph so the mix is time-stretched
	// (pitch preserved) instead of the device resampling it (pitch shifts).
	// Applied lazily — only when the rate changes — because the producer runs
	// every ~2ms, and rebuilding a filter graph is cheap (a few ms) but not
	// free per feed.
	// A drag does not time-stretch, so it can never justify building or retuning
	// the atempo graph. Treating scrub_rate as a target here rebuilt the graph on
	// every frame of a drag, cleared the ring while it did, back-anchored the
	// destination to the device, and left the pointer's frames undelivered -- and
	// that is the reason a feed with a 30-frame sweep ahead mixed nothing.
	want_ratio := audio_want_rate()
	if audio_atempo.rate != want_ratio || (audio_atempo.graph == nil) != (want_ratio == 1.0) {
		// Capture audible position using OLD graph rate and old queue before either is
		// destroyed. The new graph's sample counters cannot account for output already
		// queued at the old rate, so that PCM must be cleared as part of this discrete
		// graph change; then sources reconcile at the exact audible frame.
		old_rate := audio_atempo.graph != nil ? audio_atempo.rate : 1.0
		old_pending := atempo_pending_input_samples(&audio_atempo)
		old_input_sample := Sample_Pos(audio_frame_boundary48(audio_src.next_frame, fps))
		audible_before_change := audio_device_audible_sample(
			old_input_sample,
			audio_device_queued(),
			old_rate,
			&audio_atempo,
			old_pending,
		)
		fps_num, fps_den := fps_rational(fps)
		anchor := frame_at_sample(audible_before_change, i64(fps_num), i64(fps_den))
		// The graph is built for the rate it will actually run at, which sizes every
		// atempo ring for that rate. libavfilter asserts read_size <= ring on each
		// pull, so such a graph cannot be retuned upward at all -- it aborts the
		// process at af_atempo.c:445. A drag's rate changes on every pointer
		// movement, so a scrub needs a graph that is safe to retune, and only
		// atempo_graph_build_fixed produces one.
		//
		// The clear and re-anchor below still happen on every rate change: the PCM
		// already queued was stretched at the OLD rate, so it is wrong the moment
		// the rate moves. What matters is that the teardown does not.
		//
		// PLAYBACK needs the resync: it just changed the pitch of the whole
		// timeline, so what is queued is now wrong and the sources have to be
		// re-anchored to the audible frame.
		//
		// A SCRUB does not. Its queued PCM is already final -- rendered and handed
		// over -- and retuning the graph does not invalidate it. Doing the playback
		// resync anyway was fatal: a drag's velocity changes on every pointer
		// movement, so this ran constantly, and each pass cleared the ring and reset
		// the render cursor to the audible anchor. The producer could never get two
		// pushes in before being wiped, which is a scrub that hears NOTHING.
		if sync.atomic_load(&audio_prod.scrub_active) {
			// Build it for the rate it will actually run at, and never retune it.
			atempo_rate_set(&audio_atempo, want_ratio)
		} else {
			// Playback always REBUILDS on a rate change rather than retuning.
			// The retune path looks cheaper, but af_atempo re-sizes its ring
			// whenever the tempo option moves, so an upward retune can abort the
			// process. Rebuilding at the new rate cannot.
			atempo_rate_set(&audio_atempo, want_ratio)
		}
		//
		// PLAYBACK needs the resync: it just changed the pitch of the whole
		// timeline, so what is queued is now wrong and the sources have to be
		// re-anchored to the audible frame.
		//
		// A SCRUB does not. Its queued PCM is already final -- rendered and
		// handed over -- and retuning the graph does not invalidate it; it only
		// changes what the graph emits from here on. Doing the playback resync
		// anyway was fatal: a drag's velocity changes on every pointer movement,
		// so this ran constantly, and each pass cleared the ring and reset the
		// render cursor to the audible anchor. The producer could never get two
		// pushes in before being wiped, which is a scrub that hears NOTHING.
		if sync.atomic_load(&audio_prod.scrub_active) {
			audio_rpt.rate_rebuilt += 1
		} else {
			audio_device_clear()
			audio_reconcile(anchor, true)
			audio_src.next_frame = anchor
			sync.atomic_store(&audio_prod.prod_frame, anchor)
			audio_rpt.rate_rebuilt += 1
		}
	}
}

// producer_trim_decoders handles a forward skip: the playhead raced ahead of the
// producer. Fifos are trimmed and the cursor advanced in place -- no reopen, no
// reloop, no audible repeat -- because the decoders are forward-only and simply
// keep decoding from the new position.
//
// This is the only place the engine advances next_frame without decoding, so it
// is the only candidate for an audible jump. The CAUSE line names it so a
// downstream ANOMALY JUMP report can be read against its cause.

producer_trim_decoders :: proc(fps: f64, spf: int) {
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
		when ODIN_DEBUG {
			if repro_trace {
				// This is the ONLY place in the engine that advances next_frame without a
				// decode, so it is the only candidate for an audible jump. Naming it here
				// means a `[repro] ANOMALY JUMP` line further down can be read against the
				// cause instead of leaving the two to be correlated by hand.
				fmt.printf(
					"[repro] CAUSE jump_frame %d -> %d (+%d) trimmed %d samples, cleared the queue\n",
					audio_src.next_frame, jmp, jmp - audio_src.next_frame, delta48,
				)
			}
		}
		audio_src.next_frame = jmp
		audio_device_clear()
		atempo_reset(&audio_atempo) // graph window holds pre-jump samples otherwise
		sync.atomic_store(&audio_prod.jump_frame, 0)
	}
}

// producer_publish_dev_position computes the device's audible timeline position
// and publishes it. This is where the DEVICE, not the playhead, becomes the
// clock: content fed is contiguous from one origin, so a producer stall costs the
// listener a gap and never an offset, and there is no second clock to disagree.
//
// dev_resync carries the generation the position was computed under. A seek
// bumps `resync` and the producer adopts it on the next pass, so for a few ms
// after every seek dev_frame still describes the OLD position. Without the
// generation the playhead cannot tell that from a current reading, and a backward
// scrub gets overwritten by the previous run's position on the very next tick --
// which is the playhead refusing to move back.

producer_publish_dev_position :: proc(fps: f64, want_ratio: f64) -> i64 {
	pending_content_samples := atempo_pending_input_samples(&audio_atempo)
	// dev_pos is audible content position: input accepted by atempo, less content
	// represented by the device queue, LESS input still held inside WSOLA. Without the
	// second subtraction the graph's startup lookahead advances the playhead while the
	// device has not heard those samples yet -- exactly the sample-origin offset the
	// bus-alignment gate checks at each supported rate.
	next_input_sample := Sample_Pos(audio_frame_boundary48(audio_src.next_frame, fps))
	audible_sample := audio_device_audible_sample(
		next_input_sample,
		audio_device_queued(),
		want_ratio,
		&audio_atempo,
		pending_content_samples,
	)
	fps_num, fps_den := fps_rational(fps)
	dev_pos := frame_at_sample(audible_sample, i64(fps_num), i64(fps_den))
	// dev_frame is the device's consumed timeline position with both output-queue
	// duration and graph-held input accounted for. dev_at_ns is only its meter age stamp.
	sync.atomic_store(&playback.dev_at_ns, i64(monotonic_ns()))
	sync.atomic_store(&playback.dev_frame, dev_pos)
	// The generation this position was computed under. A seek bumps `resync` and
	// the producer adopts it on its next pass, so for a few ms after every seek
	// dev_frame still describes the OLD position. Without the generation the
	// playhead cannot tell that apart from a current reading, and a backward
	// scrub gets overwritten by the previous run's position on the very next
	// tick -- which is the playhead refusing to move back.
	sync.atomic_store(&playback.dev_resync, sync.atomic_load(&audio_prod.resync))
	// Anomaly report LAST, so it sees the positions this pass just published rather
	// than the ones it was about to publish.
	when ODIN_DEBUG {
		if repro_trace {
			repro_report(fps, dev_pos)
		}
	}
	return dev_pos
}

// producer_fold_gain folds live gain edits (knob drag) into the provisioned
// segments before mixing. The epoch check is cheap; the fold only runs when the
// UI has published a change since the last one. No seek, so a knob drag is
// audible within the cushion instead of reopening every decoder per move.

producer_fold_gain :: proc() {
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
}


// producer_resolve_target decides which timeline position this feed pass fills
// toward, and does the cursor work that decision implies. It returns the frame
// the fill loop must not pass, and whether that is the DEVICE position
// (playback) or the POINTER position (a drag).
//
//   Playback fills to dev_pos + cushion. The device drains at 1x, so the cushion
//   is what stops an ordinary producer hiccup from being audible.
//
//   A drag fills to the POINTER, no cushion past it. The device position is where
//   the pipe has GOT TO, and during a drag the pipe is by definition far behind
//   the hand -- 1000 frames on the sweep -- so filling toward it means the loop
//   never consumes the range at all. That is how an 800-frame drag could come
//   out at 1x. A cushion past the pointer would instead queue audio for a position
//   the hand has not reached.
//
// Two cursor corrections live here, both about the pointer having moved relative
// to what the producer last acted on: a backward move invalidates everything
// queued, so the read head rewinds and the decoders re-anchor; and a pointer that
// has STOPPED with the producer behind it has no crossed range left to honour, so
// the pointer wins and the backlog goes.

producer_resolve_target :: proc(dev_pos: i64, cushion_frames: i64) -> (i64, bool) {
	ph := dev_pos
	target := ph + cushion_frames
	// During a drag the range to consume is the playhead's, not the device's.
	//
	// The device position is where the pipe has got to, and during a drag the pipe
	// is by definition far behind the hand -- 1000 frames on the sweep. Filling
	// toward it means the loop never runs toward the pointer at all, which is how a
	// 800-frame drag could still come out at 1x: the producer was dutifully keeping
	// the pipe topped up from where it already was, and never consumed the range.
	scrubbing_marker := sync.atomic_load(&audio_prod.scrub_active)
	// A SEEK drops the ring and re-anchors on the playhead. A drag does not.
	//
	// Data already handed to the device cannot be recalled -- that is what a pipe
	// is -- but the producer can stop sending, so a playhead that has moved off by
	// more than a seek's worth means everything queued is audio for a position the
	// user has left. Measured in audio_backward_scrub: playhead 600, producer still
	// feeding toward 15, because a full ring of old audio had to drain first.
	// Clearing on a drag is the opposite mistake: every frame the pointer swept is
	// content the listener asked to hear, and dropping it is why scrubbing used to
	// sound like it was skipping.
	//
	// The two are told apart by scrub_active, never by distance. A fast drag moves
	// further per frame than a small seek does, so a distance test cleared on every
	// tick of a 1000-frame sweep and produced 60 ticks of silence. It is also never
	// measured against dev_pos, which is derived from what has been fed and so can
	// never disagree with the producer -- it could never reveal a seek at all.
	playhead_moved := abs(playhead.frame - last_scrub_target) > AUDIO_DEVICE_SEEK_FRAMES
	last_scrub_target = playhead.frame
	if !sync.atomic_load(&audio_prod.scrub_active) && playhead_moved {
		audio_device_clear()
		audio_src.next_frame = playhead.frame
	}
	// A scrub is the one mode where the listener is looking AT the playhead, so the
	// producer aims AT IT rather than at the device. Filling to dev_pos + 0.25s is
	// right for playback -- that cushion is what keeps a producer stall from being
	// audible -- but during a drag it means the audio is a quarter second ahead of the
	// frame under the pointer, which is the sound of the drag not being followed at
	// all. A small cushion is kept instead: it is only jitter protection now, and the
	// audible position has to stay within a few frames of the playhead to track it.
	scrubbing := sync.atomic_load(&audio_prod.scrub_active)
	if !scrubbing {
		// Falling edge of the drag. Without this the next drag reads a stale
		// "already started" and skips its own seeding.
		last_scrub_active = false
	}
	if scrubbing {
		// Aim AT the pointer, not a cushion past it. The producer mixes forward from
		// wherever it got to, and the drag's extent is the gap between that and here
		// -- so every frame the pointer swept over gets mixed and queued. A cushion
		// past the pointer would mean queueing audio for a position the hand has not
		// reached yet, which is content nobody asked to hear.
		//
		scrub_ph := sync.atomic_load(&audio_prod.scrub_playhead)
		//
		// Drag START. Everything queued was mixed for the position the pointer was
		// on before the hand touched it, so the backlog is stale the moment the drag
		// begins and the read position has to be placed on the pointer.
		//
		// This is the single gesture detector. It used to be a second one keyed on
		// the resync generation, which only logged; two detectors for one event is
		// how the seeding went missing during a later consolidation.
		if !last_scrub_active {
			if audio_rpt.trace {
				fmt.printf(
					"[audio] SCRUB START: %d frames (%.0f ms) of pre-scrub audio already committed\n",
					audio_device_queued(),
					f64(audio_device_queued()) * 1000.0 / f64(AUDIO_BUS_RATE),
				)
			}
			audio_device_clear()
			audio_src.next_frame = scrub_ph
			last_scrub_pointer = scrub_ph
			scrub_read_pos = f64(audio_frame_boundary48(scrub_ph, timeline_fps()))
			scrub_read_step = scrub_step_for(
				sync.atomic_load(&audio_prod.scrub_rate),
				timeline_fps(),
			)
		}
		// A drag backwards: rewind the read head to the pointer so the frames between
		// here and there get played rather than the fill loop sitting on a target it
		// has already passed.
		//
		// Backward means the POINTER moved back. That, and only that, invalidates
		// queued audio: the stretch between here and where it was describes audio
		// the hand has left. A pointer that merely has not caught up to the render
		// cursor is normal -- that is the producer working ahead through the range
		// it was asked for -- and must not drop anything.
		pointer_moved := scrub_ph != last_scrub_pointer
		if scrub_ph < last_scrub_pointer {
			audio_device_clear()
			audio_src.next_frame = scrub_ph
			scrub_read_pos = f64(audio_frame_boundary48(scrub_ph, timeline_fps()))
			scrub_reanchor_at(scrub_ph)
		}
		//
		// A pointer that has STOPPED, with the producer behind it, is the case that
		// was missing. Only backward motion re-pointed, so a forward jump followed
		// by a stop left the producer grinding through the entire crossed range at
		// real time from a stale position -- measured as frame 20816 rendering while
		// the pointer sat still at 153379, 132k frames of backlog the listener never
		// asked to hear.
		//
		// Once the hand has stopped there is no crossed range left to honour: the
		// range was crossed, and what is still queued past the pointer is backlog
		// from catching up. Playing it is the "37 minutes of audio" behaviour, so
		// the pointer wins and the backlog is dropped.
		//
		// Only while stationary AND behind. A pointer that merely has not caught up
		// to the render cursor is the producer working ahead through a range it was
		// asked for, which is correct and must not be dropped.
		//
		// Why "behind" only: an ahead re-point oscillates. A feed at step 8
		// overshoots the target by up to 8 frames, which re-triggers an ahead
		// branch, which re-points, which overshoots again -- a held pointer ended
		// 16 frames out. Overshoot is the defect; clamping scrub_read_pos to the
		// target is its fix, and it is not done yet.
		//
		if !pointer_moved && scrub_ph - audio_src.next_frame > SCRUB_REPOINT_SLACK_FRAMES {
			audio_device_clear()
			audio_src.next_frame = scrub_ph
			scrub_read_pos = f64(audio_frame_boundary48(scrub_ph, timeline_fps()))
		}
		// Re-point AGAIN, unconditionally, before the next pass compares against it.
		//
		// This was written only in the drag-START block, so for the rest of the
		// gesture last_scrub_pointer stayed pinned at the frame the hand touched down
		// on, and every comparison below was against that. pointer_moved then meant
		// "the pointer differs from where the drag started", not "the pointer moved
		// this pass" -- so after the first motion it read true on EVERY subsequent
		// pass, and the stationary-behind branch below, which needs !pointer_moved,
		// could never fire during a real gesture. That branch is the only thing that
		// re-points a producer which has fallen behind and stopped.
		//
		// Measured on the user's run: pointer parked at 154, producer pinned at 15 for
		// 1200 consecutive frames, fed frozen at 40000, ring EMPTY (q=0, avail=32768),
		// nocov=0, skipfull=0 -- a live producer with nothing to mix, because every
		// path that would have moved it forward was gated behind this.
		//
		// It means what the branches above say: the pointer position the producer
		// last acted on. Updated on every scrub pass, before the early returns below,
		// so a pass that returns early still records the pointer.
		last_scrub_pointer = scrub_ph
		last_scrub_active = true
		//
		// The step follows the pointer's MOTION. Recomputing it every pass meant
		// that the instant the hand stopped, velocity went to zero, the step was
		// floored to 1.0, and the very backlog that needed draining at speed
		// switched to real time -- 16x slower exactly when the rate mattered. The
		// last moving rate is held instead.
		if pointer_moved {
			scrub_read_step = scrub_step_for(
				sync.atomic_load(&audio_prod.scrub_rate),
				timeline_fps(),
			)
		}
		// One frame PAST the pointer, and this is the line that decides whether a
		// backward scrub is audible at all. Aiming exactly AT it makes the fill
		// loop's condition `next_frame < target` false -- the rewind above has just
		// made them equal -- so the loop never runs and the drag is silent.
		//
		// This block also duplicates the one above it, which set the same target
		// and was silently overwritten by it. Two blocks aiming the same producer
		// at the same playhead is how that went unnoticed.
		target = scrub_ph + 1
	}
	if scrubbing {
		scrub_ph := sync.atomic_load(&audio_prod.scrub_playhead)
		skew := audio_src.next_frame - scrub_ph
		// The producer can run PAST the pointer, and nothing else fixes that in
		// time: the UI's seek is coalesced to one outstanding request, so a fast
		// drag outruns it and the producer stays ahead of the playhead with audio
		// queued for frames the listener left a moment ago. The producer owns
		// next_frame, so it re-anchors itself here -- reusing the reconcile a
		// release already uses, which is the "not too complicated" part: no new
		// decoder path, no new ring primitive, and the seek-landing gates already
		// cover what it produces.
		//
		// Backward only. The forward case (producer fell behind) was measured
		// skipping frames that had never been fed -- 19.7% of a drag, six re-anchors
		// throwing away 19200 samples. With varispeed the producer already tracks a
		// forward drag, so there is nothing to catch up to. The backward case only
		// rewinds audio that was already fed, so it costs no samples.
		//
		// audio_reconcile folds the geometry into the live decoders IN PLACE and
		// returns a report nobody needs here, so the result is ignored -- but the
		// call is not a no-op, and removing it as "dead" broke both the held-pointer
		// and the follow gates.
		if skew > SCRUB_REANCHOR_SLACK_FRAMES {
			audio_reconcile(scrub_ph, true)
			}
	}
	return target, scrubbing
}

audio_producer_feed :: proc() {
	feed_t0 := monotonic_ns()
	defer audio_rpt.feed_us += u64(monotonic_ns() - feed_t0)
	if !producer_device_ready() {
		return
	}
	fps := timeline_fps()
	want_ratio := audio_want_rate()
	producer_sync_rate(fps, want_ratio)
	audio_pcm_dump_open()
	audio_dec_dump_open()
	// Nominal spf: used only for queue-depth bookkeeping and to size the fixed
	// scratch buffers. The exact per-frame count is computed inside the loop
	// below, because an fps that does not evenly divide 48000 (23.976/29.97) would
	// otherwise accumulate a steady drift against the playhead.
	spf := int(MAX_AUDIO_FRAME_SAMPLES)
	if fps > 0 {
		spf = min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(48000.0 / fps + 0.5)))
	}
	producer_trim_decoders(fps, spf)
	max_queue := i64(f64(AUDIO_BUS_RATE) * AUDIO_CUSHION_SEC)
	// A quarter of the cushion: deep enough that an ordinary producer hiccup does
	// not trip it, shallow enough to catch a real stall before the device runs dry.
	queue_floor := max_queue / 4
	// If graph construction failed, raw mixing is the active path and the effective
	// rate is 1.0. Otherwise the output queue and the graph's internal window both
	// hold content time that has not reached the device yet.
	rate_sc := audio_rate_scale()
	cushion_frames := i64(AUDIO_CUSHION_SEC * f64(fps) * rate_sc + 1)
	dev_pos := producer_publish_dev_position(fps, want_ratio)
	producer_fold_gain()
	ph := dev_pos
	target, scrubbing := producer_resolve_target(dev_pos, cushion_frames)
	if target <= audio_src.next_frame {
		return
	}
	mix: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
	// Sized from ATEMPO_OUT_CAP, not MAX_AUDIO_FRAME_SAMPLES: with atempo active
	// the block length is the graph's output, not the content frame. Asserted
	// below so a future change to the cap cannot turn this into a silent stack
	// overflow of up to 4x.
	pcm: [ATEMPO_OUT_CAP * 2]i16
	if sync.atomic_load(&audio_prod.scrub_active) {
		scrub_ph := sync.atomic_load(&audio_prod.scrub_playhead)
		if abs(scrub_ph - audio_src.next_frame) > 1 && audio_device_queued() > 0 {
			audio_device_clear()
		}
	}
	scrub_target_samples := f64(audio_frame_boundary48(target, fps))
	for {
		if scrubbing {
			if scrub_read_pos >= scrub_target_samples {
				break
			}
		} else if audio_src.next_frame >= target {
			break
		}
		// Backpressure. The ring is a pipe, and a pipe with no cap is a memory
		// leak with a decoder attached: the producer fills as fast as it can
		// decode, so a playhead that teleports becomes seconds of buffered audio
		// that plays out long after the hand has moved on. Measured on a 1000-frame
		// sweep with the cap lifted for drags: 360800 frames queued -- 7.5 seconds.
		//
		// The cap is unconditional, drags included. The right amount to have queued
		// is the same during a drag as during playback: whatever the device has not
		// taken yet. Lifting it was the mistake, not the fix.
		//
		// A scrub is explicitly "render the crossed range as fast as possible", so
		// the only admissible throttle is the ring's own capacity, which
		// audio_device_available checks before every push. Playback keeps the
		// cushion; a scrub fills until the ring says stop.
		if !scrubbing && audio_device_queued() >= max_queue {
			audio_rpt.skip_full += 1
			break
		}
		//
		// Playback reads the frame the cursor is on. A scrub reads wherever its
		// fractional read position has got to, which is how the content plays
		// faster than real time: the position advances by more than one frame
		// per period, so the crossed range is traversed at speed instead of being
		// walked one frame at a time.
		mix_frame := audio_src.next_frame
		if scrubbing {
			mix_frame = i64(scrub_read_pos * f64(fps) / f64(AUDIO_BUS_RATE))
			if mix_frame < 0 {
				mix_frame = 0
			}
		}
		if !audio_src_covers_frame(mix_frame) {
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
		content_start := audio_frame_boundary48(mix_frame, fps)
		if fps > 0 {
			b0 := audio_frame_boundary48(mix_frame, fps)
			b1 := audio_frame_boundary48(mix_frame + 1, fps)
			cur_spf = min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(b1 - b0)))
		}
		//
		// A scrub reads the content at its own position rather than at the frame
		// boundary. scrub_read_pos is where in the content this period should come
		// from; the difference from the nominal frame start is the resampling step.
		// At step 1.0 that difference is zero and this is exactly the old path.
		scrub_sample_offset := 0.0
		if scrubbing {
			scrub_sample_offset = scrub_read_pos - f64(audio_frame_boundary48(mix_frame, fps))
			//
			// Track the read speed. At step 1 the read is contiguous and the filter
			// sits open, so a slow or stopped drag is untouched and sounds exactly
			// like playback. The faster the read, the further down the corner comes,
			// which is where the aliased energy is.
			cutoff := f32(AUDIO_BUS_RATE) / (2.0 * f32(scrub_read_step))
			// Clamp below Nyquist and above a floor that keeps it from fully
			// muting, so an extreme step does not turn scrubbing into a low rumble.
			cutoff = clamp(cutoff, 400.0, f32(AUDIO_BUS_RATE) * 0.45)
			// One-pole: z = exp(-2*pi*fc/fs). Written out rather than calling exp
			// per period, since it is constant between speed changes.
			scrub_lowpass_z = f32(math.exp(-2.0 * f64(cutoff) / f64(AUDIO_BUS_RATE) * 3.14159265358979))
		} else {
			scrub_lowpass_z = 0
		}
		mix_t0 := monotonic_ns()
		if !audio_mix_frame(mix[:], mix_frame, cur_spf, scrub_sample_offset) {
			sync.atomic_add(&audio_rpt.silence_holes, 1)
		}
		audio_rpt.mix_us += u64(monotonic_ns() - mix_t0)
		// Playback-rate: atempo stretches mixed content to cur_spf/rate output
		// samples with pitch preserved. Inactive graph (rate 1.0) feeds the mix
		// through verbatim, identical to the pre-atempo path.
		//
		// Anti-alias ahead of the decimating read. One-pole, per channel, state
		// kept across periods so the corner does not restart at every block.
		if scrubbing && scrub_lowpass_z < 1.0 {
			for i in 0 ..< cur_spf {
				for ch in 0 ..< AUDIO_BUS_CHANNELS {
					idx := i * AUDIO_BUS_CHANNELS + ch
					scrub_lowpass_x[ch] += (mix[idx] - scrub_lowpass_x[ch]) * (1.0 - scrub_lowpass_z)
					mix[idx] = scrub_lowpass_x[ch]
				}
			}
		}
		push_frames := cur_spf
		src := mix[:]

		// Scrubbing runs the mix through atempo at the DRAG's rate, so the crossed
		// frames are consumed at the speed the pointer crossed them. The scrub
		// device then plays the time-stretched output at 1x with nothing left over:
		// a 2.4x drag asks for 2.4x worth of audio, atempo hands back 1x worth, and
		// the device keeps up. That is "faster scrub = consume samples faster" --
		// the rate is the drag's, and no sample is left unconsumed.
		// A scrub never goes through this graph, even when one exists for the
		// transport's own rate. The graph time-compresses, and a scrub is already
		// covering R periods of content per period of output by skipping; running both
		// would stretch the samples that survived the skip as well, which is the pitch
		// shift this path exists to remove. Per-CLIP tempo is a different graph and is
		// applied inside audio_mix_frame, where it belongs.
		if !scrubbing && audio_atempo.graph != nil {
			// Let atempo buffer real input until its first overlap-add is ready.
			// Feeding synthetic silence first advances the graph's own timeline; the
			// old prime/discard path then threw away real opening samples and made the
			// bus's first transient late by rate-dependent amounts.
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
			//
			// One device, always. The scrub path used to branch to a second miniaudio
			// device so the playback queue would not be disturbed mid-drag; that split
			// only existed because atempo needed to hand back a whole period's worth
			// for every period it consumed, and the two queues had to be kept apart to
			// do it. Skipping content has no such constraint -- it emits exactly one
			// period, which is what the device wants anyway -- so the second device,
			// and the branch that chose between them, are both gone.
			if i64(push_frames) > audio_device_available() {
				audio_rpt.skip_full += 1

				break
			}
			audio_device_push(pcm[:], push_frames)
			audio_rpt.total_fed_frames += u64(push_frames)

			// Whether the block just pushed contained any signal. The device callback no
			// longer renders, so this is where "did anything actually play" is answered
			// from -- reading a peak is how a probe tells real audio from a correctly
			// positioned mix of nothing.
			peak := f32(0)
			for f in 0 ..< push_frames {
				lv := max(abs(src[f * 2 + 0]), abs(src[f * 2 + 1]))
				if lv > peak {
					peak = lv
				}
			}
			sync.atomic_store(&audio_rpt.fed_peak, i64(f64(peak) * 1000.0))
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
		// Always advance by one mixed frame. The producer's loop already mixes every
	// frame between where it got to and `target` (target = playhead + 1), so the
	// intermediates of a jump are mixed one per pass instead of being skipped.
	// Skipping them is what made a scrub poppy: it played one period at the
	// destination and discarded the positions the hand actually crossed, and the
	// queue cap then hid the dropped range.
	advance := i64(1)
		if scrubbing {
			// Content samples consumed per output sample: this is the compression
			// factor. It is what lets a drag outrun the device clock without
			// dropping a sample, and because the position is a plain number,
			// moving it somewhere else costs nothing.
			scrub_read_pos += f64(cur_spf) * scrub_read_step
			// The decoder cursor tracks the read position. The mixer already
			// consumed and dropped everything up to it, so this is continuity,
			// not a second advance.
			audio_src.next_frame = i64(scrub_read_pos * f64(fps) / f64(AUDIO_BUS_RATE))
		} else {
			audio_src.next_frame += advance
		}
		when ODIN_DEBUG {
			if audio_rpt.trace {
				fmt.printf(
					"[tr feed] fr=%d devpos=%d target=%d q=%db ph=%d prod=%d dev=%d mix=%.2fs\n",
					audio_src.next_frame - 1, dev_pos, target, qnow, ph, audio_src.next_frame, playback.dev_frame, f64(monotonic_ns() - feed_t0) / 1e9,
				)
			}
		}
		if sync.atomic_load(&audio_rpt.last_fed_content_armed) {
			sync.atomic_store(&audio_rpt.last_fed_content, content_start)
			sync.atomic_store(&audio_rpt.last_fed_content_armed, false)
		}
		when ODIN_DEBUG {
			if play_trace {
				// What the device was just handed, in the two numbers that decide
				// whether it is the right sound: the CONTENT sample range this block
				// came from, and its level. A playhead at 0 with the engine feeding
				// content 500000 is the bug this line exists to make visible.
				peak: i32 = 0
				for s in pcm[:out_bytes / 2] {
					v := i32(s)
					if v < 0 {
						v = -v
					}
					if v > peak {
						peak = v
					}
				}
				fmt.printf(
					"[prod] fed fr=%d content=[%d,%d) peak=%.3f q=%d devpos=%d target=%d prod=%d dev=%d ph=%d\n",
					audio_src.next_frame - 1,
					content_start,
					content_start + i64(push_frames),
					f64(peak) / 32768.0,
					qnow,
					dev_pos,
					target,
					audio_src.next_frame,
					playback.dev_frame,
					playhead.frame,
				)
			}
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
	device_active := false
	when ODIN_DEBUG {
		if audio_rpt.trace {
			fmt.println("[audio] producer thread up")
		}
	}
	audio_rpt.thread_start_ns = monotonic_ns()
	last_report := u64(0)
	for !sync.atomic_load(&audio_prod.stop) {
		if sync.atomic_load(&audio_prod.run) {
			evt := sync.atomic_load(&audio_prod.resync)
			if evt != last_evt || !had_evt {
				force_evt := sync.atomic_load(&audio_prod.force_seek_resync)
				force_seek := force_evt > last_evt && force_evt <= evt
				last_evt = evt
				open_start := monotonic_ns()
				anchor := sync.atomic_load(&audio_prod.anchor_frame)
				seeked := audio_reconcile_is_seeked(
					anchor,
					timeline_fps(),
					audio_rate_scale(),
					force_seek,
				)
				if had_evt {
					// An EDIT or a SEEK: reconcile, so every decoder whose content
					// position did not move keeps running. This is the path that
					// used to cost a full re-provision -- clearing the queue and
					// reopening every decoder -- for a single clip move or trim.
					// A seek pays the same reconcile but re-anchors everything,
					// because the playhead is what moved.
					rep := audio_reconcile(anchor, seeked)
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
					//
					// It is wrong during a drag for a different and simpler reason:
					// those frames are not stale, they are DELIVERED. Every frame in
					// the queue is audio for a range the playhead has already swept,
					// and the rule during a scrub is that the range the playhead moved
					// gets played. So the drag's own coalesced seeks -- one per
					// adoption, several per gesture -- must not discard it, or the
					// gesture plays a fraction of the material the hand crossed and
					// the sound stops matching the motion.
					//
					// The decoders still re-anchor: the pointer is somewhere new and
					// has to decode from there. Only the DISCARD goes.
					scrub_drag := sync.atomic_load(&audio_prod.scrub_active)
					if rep.touched_window && !scrub_drag {
						audio_device_clear()
						audio_rpt.queue_clears += 1
					}
					when ODIN_DEBUG {
						if play_trace {
							fmt.printf(
								"[prod] reconcile done kept=%d sought=%d opened=%d dropped=%d touched=%t next_frame=%d queued=%d\n",
								rep.kept,
								rep.sought,
								rep.opened,
								rep.dropped,
								rep.touched_window,
								audio_src.next_frame,
								audio_device_queued(),
							)
						}
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
				when ODIN_DEBUG {
					if play_trace {
				fmt.printf(
					"[prod] resync evt=%d anchor=%d forced=%t seeked=%t run=true  next_frame=%d dev=%d\n",
					evt,
					anchor,
					force_seek,
					seeked,
					audio_src.next_frame,
					sync.atomic_load(&playback.dev_frame),
				)
			}
				}
				had_evt = true
				audio_device_set_active(true)
				device_active = true
				// Provisioning reopens every decoder synchronously -- hundreds
				// of ms once several sources are open. Video runs on the wall
				// clock the whole time, so the playhead has moved past the
				// anchor that was sampled before the open. Anchor to the stale
				// frame and the offset never closes: the queue ceiling caps how
				// far ahead the producer may fill, so once both clocks advance
				// at realtime the lag is frozen in (measurably ~the provision
				// duration, which is exactly why a manual seek clears it).
				// Skip forward to where playback actually is instead.
				//
				// `dev_frame` must be CURRENT for this to be safe. On a BACKWARD seek
				// it is not: the producer has just been rewound to the new anchor,
				// while dev_frame still names the position playback was at BEFORE the
				// seek, because the producer only republishes it on the next feed
				// pass. That stale value is LARGER than the rewound next_frame, so
				// this guard read it as "the producer fell behind, skip to it" and
				// jumped straight back to the old position -- silently undoing every
				// backward seek in the same pass that correctly handled it. Measured:
				// seek to frame 15, reconcile correctly re-anchored all four sources
				// to next_frame=15, and the next feed mixed frame 31.
				//
				// dev_resync is what distinguishes the two: it is published beside
				// dev_frame carrying the generation that value was computed under, so
				// a reading from before this seek is detectable instead of being
				// acted on. The slow-provision case this guard exists for still
				// works, because there the producer published dev_frame itself for
				// the current generation.
				if dev_resync := sync.atomic_load(&playback.dev_resync); dev_resync ==
				    sync.atomic_load(&audio_prod.resync) {
					if hop := sync.atomic_load(&playback.dev_frame); hop > audio_src.next_frame {
						sync.atomic_store(&audio_prod.jump_frame, hop)
					}
				}
				when ODIN_DEBUG {
					if audio_rpt.trace {
						fmt.printf("[audio] re-provisioned %d srcs at frame %d in %.1f ms\n", audio_src.count, sync.atomic_load(&audio_prod.anchor_frame), f64(monotonic_ns()-open_start)/1e6)
					}
				}
			}
			if !device_active {
				audio_device_set_active(true)
				device_active = true
			}
			audio_producer_feed()
			if audio_rpt.log_ms > 0 {
				if now := monotonic_ns(); now - last_report >= u64(audio_rpt.log_ms) * 1_000_000 {
					elapsed := f64(now - audio_rpt.tick) / 1e9
				delta := audio_src.next_frame - audio_rpt.frame
				queued := audio_device_queued()
				fps := timeline_fps()
				// The published device frame already subtracts both queued output and
				// atempo's internal holdback; recomputing from the queue alone reports
				// the playhead ahead by WSOLA's startup window.
				cursor := sync.atomic_load(&playback.dev_frame)
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
				when ODIN_DEBUG {
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
							fmt.printf("[src %d] %s segs=%d dec=%t in=%dHz/%dch out=%dHz/%dch first48=%d have48=%d fifo=%dfr out_ring=%dfr out_first=%d decoded=%dfr/%dch speed=%.3f pitch=%.3f wsola=%t mix_at=%d(into %t) cov=%t\n",
								k, s.path, s.seg_count, s.dec.opened,
								s.dec.input_rate, s.dec.input_channels, s.dec.out_rate, s.dec.out_channels,
								s.first48, s.have48, ring_len(&s.fifo),
								ring_len(&s.out_ring), s.out_first,
								s.dec.decoded_frames, s.dec.decoded_chunks,
								s.speed, s.pitch_ratio,
								s.tempo.graph != nil,
								at, in_fifo, covered)
						}
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
			// Stop device output but retain warm decoders and source FIFOs. Reopening
			// several media streams on every play press was the 500ms startup delay;
			// a later playhead anchor reconciles/seeks these retained sources instead.
			if device_active {
				audio_device_set_active(false)
				audio_device_clear()
				atempo_reset(&audio_atempo)
				device_active = false
			}
			// Geometry imports and scrubs can happen while stopped. Warm/re-anchor
			// sources on this worker while the device gate stays closed, so playback
			// starts from current geometry instead of waiting for all decoders on press.
			evt := sync.atomic_load(&audio_prod.resync)
			if evt != last_evt {
				force_evt := sync.atomic_load(&audio_prod.force_seek_resync)
				force_seek := force_evt > last_evt && force_evt <= evt
				last_evt = evt
				anchor := sync.atomic_load(&audio_prod.anchor_frame)
				seeked := audio_reconcile_is_seeked(
					anchor,
					timeline_fps(),
					audio_rate_scale(),
					force_seek,
				)
				if had_evt {
					rep := audio_reconcile(anchor, seeked)
					audio_rpt.reconciles += 1
					audio_rpt.dec_kept += u64(rep.kept)
					audio_rpt.dec_seek += u64(rep.sought)
					audio_rpt.dec_open += u64(rep.opened)
					audio_rpt.dec_drop += u64(rep.dropped)
					if rep.touched_window {
						audio_device_clear()
						audio_rpt.queue_clears += 1
					}
					when ODIN_DEBUG {
						if play_trace {
							fmt.printf(
								"[prod] reconcile(stopped) forced=%t kept=%d sought=%d opened=%d dropped=%d touched=%t next_frame=%d\n",
								force_seek,
								rep.kept,
								rep.sought,
								rep.opened,
								rep.dropped,
								rep.touched_window,
								audio_src.next_frame,
							)
						}
					}
				} else {
					audio_rpt.provisions += 1
					audio_device_clear()
					audio_provision(anchor)
					when ODIN_DEBUG {
						if play_trace {
							fmt.printf(
								"[prod] provision at=%d srcs=%d next_frame=%d\n",
								anchor,
								audio_src.count,
								audio_src.next_frame,
							)
						}
					}
				}
				had_evt = true
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
	//
	// A SCRUB is the exception, and it is the whole point of scrubbing audio: the
	// transport is usually stopped while the pointer is dragging, and a stopped
	// transport mutes the producer -- so scrubbing a stopped project was silent no
	// matter what the producer was aiming at. Dragging is the user asking to hear
	// the timeline, so the producer runs for the duration of the gesture and is
	// released again on release. Idle (not dragging, not playing) stays silent, so
	// this does not turn a parked playhead into a running stream.
	scrubbing := active_interaction == .Playhead_Scrub
	if (!playhead.playing && !scrubbing) || playback.dir == -1 {
		sync.atomic_store(&audio_prod.run, false)
		audio_prod.was_playing = false
		audio_prod.last_ui_frame = playhead.frame
		return
	}
	if !audio_prod.was_playing {
		audio_prod.was_playing = true
		sync.atomic_store(&audio_prod.run, true)
		when ODIN_DEBUG {
			if play_trace {
				fmt.printf(
					"[ui]  run edge: starting producer at playhead=%d\n",
					playhead.frame,
				)
			}
		}
		audio_seek(playhead.frame)
		audio_prod.last_ui_frame = playhead.frame
		return
	}
	fwd := playhead.frame - audio_prod.last_ui_frame
	audio_prod.last_ui_frame = playhead.frame
	when ODIN_DEBUG {
		if play_trace {
			fmt.printf(
				"[ui]  audio_update ph=%d fwd=%+d last=%d prod=%d anchor=%d run=%t\n",
				playhead.frame,
				fwd,
				audio_prod.last_ui_frame,
				sync.atomic_load(&audio_prod.prod_frame),
				sync.atomic_load(&audio_prod.anchor_frame),
				sync.atomic_load(&audio_prod.run),
			)
		}
	}
	if fwd > 3 || fwd < -1 {
		when ODIN_DEBUG {
			if audio_rpt.trace {
				fmt.printf("[ph] t=%.2fs ph=%d fwd=%+d (last_ui=%d) -> jump/health check\n",
					f64(monotonic_ns()-audio_rpt.thread_start_ns)/1e9,
					playhead.frame, fwd, audio_prod.last_ui_frame)
			}
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
		when ODIN_DEBUG {
			if audio_rpt.trace {
				fmt.printf("[ph] self-heal: playing but 0 audio sources at ph=%d -> re-seed\n", playhead.frame)
			}
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
		when ODIN_DEBUG {
			if audio_rpt.trace {
				fmt.printf("[ph] t=%.2fs ph=%d prod=%d anchor=%d -> %s reseek (fwd=%+d, phsrc=%s catch=%d)\n",
					f64(now-audio_rpt.thread_start_ns)/1e9,
					playhead.frame, prod, sync.atomic_load(&audio_prod.anchor_frame), reason, fwd, src_name, catch)
			}
		}
		audio_seek(playhead.frame)
	// There is no forward-skip branch here, and its absence is the point of the
	// clock inversion. It guarded "the producer fell behind, so jump it forward",
	// but the playhead is now READ FROM the device and dev_pos subtracts both
	// queued output and graph-held input, so the guard reduces to
	//
	//     -queued_frames - graph_pending_frames > cushion
	//
	// which is unsatisfiable -- both terms are non-negative. The playhead cannot
	// outrun what the producer has already fed, by construction.
	//
	// It was the LAST way the engine could silently move the playhead during
	// playback. A producer stall now costs the listener a gap and nothing else.
	}
}

// audio_seek requests a new producer anchor. Explicit playhead navigation forces
// decoder re-anchoring by default, even inside the normal cushion; geometry-only
// reconciliation and in-drag scrub samples pass false. UI thread only.
audio_seek :: proc(frame: i64, force_reanchor: bool = true) {
	// resync has one writer (the UI thread). Publish anchor and intent before the
	// generation so producer cannot observe request without its reason.
	prev_evt := sync.atomic_load(&audio_prod.resync)
	evt := prev_evt + 1
	sync.atomic_store(&audio_prod.anchor_frame, frame)
	sync.atomic_store(&audio_prod.anchor_now, i64(monotonic_ns()))
	if force_reanchor {
		sync.atomic_store(&audio_prod.force_seek_resync, evt)
	}
	when ODIN_DEBUG {
		if audio_rpt.trace {
			fmt.printf("[tr seek] to=%d force=%t\n", frame, force_reanchor)
		}
	}
	when ODIN_DEBUG {
		if play_trace {
			// A forced seek is the moment a scrub release hands the playhead back to
			// the device. The listener has already HEARD everything up to the device
			// position below, so that number and the queued depth are what make a
			// later repeat legible: resuming below the heard position is the repeat,
			// and neither is knowable from a clears counter.
			fmt.printf(
				"[ui]  audio_seek to=%d force=%t (playhead=%d prod=%d resync %d->%d; device already heard %d, %d frames queued, %d clears acked)\n",
				frame,
				force_reanchor,
				playhead.frame,
				sync.atomic_load(&audio_prod.prod_frame),
				prev_evt,
				evt,
				sync.atomic_load(&playback.dev_frame),
				audio_device_queued(),
				audio_device_clears(),
			)
		}
	}
	sync.atomic_store(&audio_prod.resync, evt)
}


// ---------------------------------------------------------------------------
// The output path, inverted.
//
// This replaces the arrangement where the producer mixed whole timeline frames,
// decided when they were due, and pushed them into a FIFO the device drained
// whenever it got round to it. Output position was a SIDE EFFECT of when the
// producer thread happened to run -- published afterwards as dev_frame and
// reconciled against the playhead afterwards. Nothing in that chain was anchored
// to the playhead, which is why the audio never quite did what the hand did.
//
// Now: the playhead is the input. The device callback reads it, mixes the
// timeline at that position from already-decoded samples, writes, and advances
// the playhead by exactly what it wrote. The callback is the only thread that
// knows when, so it is the only thread that decides "now".
//
// The producer's remaining job is keeping DECODED samples ahead of the playhead.
// That has no timing constraint at all, so it can sit as far ahead as it likes
// and cannot starve anything: there is no queue of mixed audio left to starve.

// Audio_Live_Src, Audio_Live, audio_live_publish, audio_live_follow_playhead:
// REMOVED with the callback-side renderer they existed for. The callback no
// longer mixes, so there was no second view to publish. Worth noting what went
// with it: a struct written on the producer thread and read on the callback
// thread, whose publish was the only thing making the two agree on where
// playback was.
