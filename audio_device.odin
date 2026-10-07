// audio_device.odin is the miniaudio output boundary: the playback device, the
// lock-free bridge ring the producer thread writes, and the real-time data
// callback that drains it. The engine above (audio.odin) never touches miniaudio
// or the bridge directly -- it pushes finished 48 kHz stereo S16 frames and asks
// how deep the queue is. That boundary is why the port is auditable: with SDL's
// AudioStream gone, audio.odin contains no sdl.*Audio* call at all, and swapping
// the backend again would only change this file.
//
// The shape is dictated by one hard constraint: miniaudio's data callback runs
// on its own high-priority audio thread. It may not allocate, lock, syscall, or
// print. Everything it touches is therefore either preallocated here or owned
// exclusively by the callback itself.
// ---------------------------------------------------------------------------

package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import ma "vendor:miniaudio"

// The mix bus format. Every clip is resampled to this on the way in
// (open_audio_decoder_resampled), so it outlives individual clips.
AUDIO_BUS_RATE     :: 48000
AUDIO_BUS_CHANNELS :: 2
AUDIO_BUS_FORMAT   :: ma.format.s16
AUDIO_BUS_FRAME_BYTES :: AUDIO_BUS_CHANNELS * 2 // s16

// AUDIO_BRIDGE_FRAMES is the bridge ring's depth in bus sample-frames. It is a
// power of two because ma_pcm_rb derives its subbuffer layout by halving, and
// it is deliberately deeper than the AUDIO_CUSHION_SEC queue ceiling the
// producer throttles against: if the ring were exactly one cushion there would
// be no write room left at the cap and every push past it would fail rather
// than simply block the producer. 32768 frames is ~0.68 s, i.e. ~2.7x the
// cushion, so the cap check stays the only thing that decides when to stop
// feeding.
// AUDIO_DEVICE_PERIOD_MS and AUDIO_DEVICE_PERIOD_COUNT are what we ASK the
// backend for. The device's own playback.internalPeriodSizeInFrames is not
// reported back: on PulseAudio it reads 1440 while the callback is measured at
// exactly 480 frames (verified by counting callbacks and frames), so logging it
// would state a period the audio thread never actually sees.
AUDIO_DEVICE_PERIOD_MS :: 10
AUDIO_DEVICE_PERIOD_COUNT :: 3

AUDIO_BRIDGE_FRAMES :: 32768

// audio_bridge_storage is the ring's backing store, allocated once, statically,
// and handed to ma_pcm_rb_init so the ring never touches the heap. This is the
// whole point of pre-sizing it: the producer pushes on a hot path and the
// callback must never be the thing that calls malloc.
audio_bridge_storage: [AUDIO_BRIDGE_FRAMES * AUDIO_BUS_CHANNELS]i16

// AUDIO_CUSHION_SEC is how far ahead of the playhead the producer keeps the
// device, and the queue-fill ceiling. On the producer thread this absorbs the
// whole UI frame cost; only stalls longer than this resync.
AUDIO_CUSHION_SEC :: 0.25

// Audio_Device is the miniaudio output side: the context that owns the backend,
// the opened device, the bridge ring the producer writes, and the resampler
// that converts the 48 kHz bus to whatever rate the hardware actually runs.
//
// Ownership split, which is the whole design:
//   - producer thread OWNS writes into rb, and nothing else. It never moves the
//     read cursor and never resets the ring (see audio_device_clear).
//   - the callback OWINS the read cursor, the resampler, and the ring reset.
//   - the atomics below are the only handoff, all one-way and single-writer.
Audio_Device :: struct {
	ctx:      ma.context_type,
	device:   ma.device,
	rb:       ma.pcm_rb,
	// sim is a SIMULATED device for the headless stall probe, checked before the
	// real ring in every entry point below. It exists because the one claim the
	// audio-master design cannot demonstrate any other way is what happens when the
	// PRODUCER stalls: the listener should get a gap and no subsequent offset. That
	// cannot be provoked from outside, because SIGSTOP freezes the device callback
	// too (it is in-process), so freezing everything is not a producer-only stall.
	//
	// So the device is simulated and the probe runs in REAL time, draining the
	// simulation at exactly the bus rate. The producer under test is then the real
	// one, unmodified, with its wall-clock coupling behaving correctly -- and a
	// "stall" is just the probe declining to call audio_update, which is precisely
	// the condition under test.
	sim: struct {
		on:      bool,
		written: i64, // frames pushed
		read:    i64, // frames the simulated device has consumed
		cap:     i64,
		underruns: u64,
	},
	rs:       ma.resampler,
	ready:    bool,
	started:  bool,
	rb_ready: bool,
	// rate/channels are what the backend actually negotiated. They can differ
	// from the bus (AUDIO_BUS_RATE); the resampler bridges the two when they do.
	rate:     u32,
	channels: u32,
	// resampling is false when the device runs at the bus rate, which is the
	// common case and takes a direct copy instead of a filter.
	resampling: bool,
	// active is the transport gate, written by the producer thread. The device
	// itself stays started for the process lifetime: see audio_device_data for
	// why stopping it per transport change is the wrong lever.
	active: bool,
	// clear_req asks the callback to drop the queue and the resampler history.
	// The producer cannot do this itself without racing the consumer -- see
	// audio_device_clear.
	clear_req: bool,
	underruns: u64,
	// clears counts ring resets actually performed by the callback, i.e. clear
	// requests that reached the consumer rather than just being asked for.
	clears: u64,
}
audio_dev: Audio_Device

// audio_bridge_frames_to_bytes converts bus frames to bytes. Only needed for the
// preallocation assert below; the queue accounting is done in frames, not bytes.
audio_bridge_bytes :: proc(frames: int) -> int {
	return frames * AUDIO_BUS_FRAME_BYTES
}

// audio_device_data is miniaudio's data callback, on its own real-time thread.
//
// Real-time rules observed here, deliberately and not incidentally: no
// allocation, no mutex (ma_pcm_rb's read path is lock-free SPSC -- verified in
// the vendored source, zero locks or atomics in ma_pcm_rb_read/write), no
// syscall, no print, no unbounded work. The only shared state is the ring, the
// resampler (private to this thread between invocations), and three atomics.
//
// miniaudio pre-silences pOutput unless noPreSilencedOutputBuffer is set, so
// every early return below is already silence -- an underrun is silence, not
// stale audio.
audio_device_data :: proc "c" (pDevice: ^ma.device, pOutput, pInput: rawptr, frameCount: u32) {
	if !audio_dev.rb_ready {
		return
	}
	// A pending clear is honoured here, on the consumer side, because that is the
	// only thread allowed to move the read cursor. The producer asking for it is
	// the whole reason this is a flag and not a direct call.
	if sync.atomic_load(&audio_dev.clear_req) {
		ma.pcm_rb_reset(&audio_dev.rb)
		sync.atomic_add(&audio_dev.clears, 1)
		if audio_dev.resampling {
			ma.resampler_reset(&audio_dev.rs)
		}
		sync.atomic_store(&audio_dev.clear_req, false)
	}
	// Transport stopped: drain and discard rather than let a stale cushion play
	// out as a burst when the gate reopens. This is what PauseAudioDevice used to
	// do, except the device never had to be torn down and re-opened to get it.
	if !sync.atomic_load(&audio_dev.active) {
		avail: u32 = ma.pcm_rb_available_read(&audio_dev.rb)
		buf: rawptr
		if avail > 0 && ma.pcm_rb_acquire_read(&audio_dev.rb, &avail, &buf) == ma.result.SUCCESS {
			ma.pcm_rb_commit_read(&audio_dev.rb, avail)
		}
		return
	}
	// Both halves of this callback have to cross the ring's wrap, and both have to
	// loop rather than trust one grant:
	//
	//   - ma_pcm_rb_acquire_{read,write} clamp the grant to the CONTIGUOUS room
	//     before the ring's end, not to the free/queued total.
	//   - committing exactly to the ring end wraps that cursor back to 0, so the
	//     next acquire sees a fresh full-width window and the remainder lands.
	//
	// A single acquire per period therefore drops ~1 period of audio every time a
	// cursor passes the wrap -- measured once per ring lap (0.68 s at 32768 frames),
	// which is a click at the wrap and a silent drain on the write side. Looping is
	// what makes the block and the period atomic across the wrap.
	if audio_dev.resampling {
		audio_device_pull_resampled(pOutput, frameCount)
		return
	}
	out := mem.slice_ptr(cast([^]i16)pOutput, int(frameCount) * AUDIO_BUS_CHANNELS)
	filled := 0
	for filled < int(frameCount) {
		avail: u32 = u32(int(frameCount) - filled)
		buf: rawptr
		if ma.pcm_rb_acquire_read(&audio_dev.rb, &avail, &buf) != ma.result.SUCCESS || avail == 0 {
			break
		}
		n := min(int(frameCount) - filled, int(avail))
		samples := n * AUDIO_BUS_CHANNELS
		ob := filled * AUDIO_BUS_CHANNELS
		copy(out[ob:ob+samples], mem.slice_ptr(cast([^]i16)buf, samples)[:samples])
		ma.pcm_rb_commit_read(&audio_dev.rb, u32(n))
		filled += n
	}
	// The ring could not cover the whole period. The tail of pOutput stays
	// pre-silenced, so this is a dropout, not stale audio. Counted because a steady
	// climb is the producer failing to keep the cushion topped up, while an
	// occasional one is just the transport starting or a seek landing.
	if filled < int(frameCount) {
		sync.atomic_add(&audio_dev.underruns, 1)
	}
}

// audio_device_pull_resampled fills one output period through the resampler,
// looping over the ring's wrap the same way the direct path does. Sizing each
// resampler call to the output frames still owed is what keeps the period from
// stretching: feeding the whole contiguous chunk when the period is smaller is how
// a resampling path turns a 10 ms period into a 40 ms one.
audio_device_pull_resampled :: proc "c" (pOutput: rawptr, frameCount: u32) {
	produced := 0
	for produced < int(frameCount) {
		need: u64
		if ma.resampler_get_required_input_frame_count(
			&audio_dev.rs,
			u64(int(frameCount) - produced),
			&need,
		) != ma.result.SUCCESS {
			break
		}
		// Bound the request by what the ring can actually hold as one contiguous
		// window: acquiring more than available and then resampling only part of
		// it would leave the cursor un-committed at the wrap and desync. AUDIO_BRIDGE_FRAMES
		// is the ring's total capacity, so min() against it plus the commit-loop
		// below keeps every acquire satisfiable.
		avail: u32 = u32(min(need, u64(AUDIO_BRIDGE_FRAMES)))
		buf: rawptr
		if ma.pcm_rb_acquire_read(&audio_dev.rb, &avail, &buf) != ma.result.SUCCESS || avail == 0 {
			break
		}
		in_frames := u64(avail)
		out_frames := u64(int(frameCount) - produced)
		if ma.resampler_process_pcm_frames(
			&audio_dev.rs,
			buf,
			&in_frames,
			cast(^u8)(uintptr(pOutput) + uintptr(produced * AUDIO_BUS_FRAME_BYTES)),
			&out_frames,
		) != ma.result.SUCCESS {
			break
		}
		// Commit what the resampler took, not what it was offered: it legitimately
		// consumes less at the tail of a rate change.
		ma.pcm_rb_commit_read(&audio_dev.rb, u32(in_frames))
		produced += int(out_frames)
		if in_frames == 0 && out_frames == 0 {
			break // no forward progress; do not spin the audio thread
		}
	}
	if produced < int(frameCount) {
		sync.atomic_add(&audio_dev.underruns, 1)
	}
}

// audio_device_init opens the default playback device and stands up the bridge.
// Returns false if no backend could be opened; audio_init treats that as
// non-fatal (the app runs silent, as it did with SDL).
audio_device_init :: proc() -> bool {
	// An empty backend list is miniaudio's own default: it enumerates every backend
	// compiled into the library, in its own priority order, with null last. That is
	// strictly better than naming them here -- WASAPI on Windows, CoreAudio on
	// macOS, PulseAudio/ALSA/JACK on Linux -- and a hand-written list would have
	// been a portability regression the moment this ran anywhere but this machine.
	// Null last is what keeps the queue accounting below testable headlessly.
	ctx_cfg := ma.context_config_init()
	res := ma.context_init(nil, 0, &ctx_cfg, &audio_dev.ctx)
	if res != ma.result.SUCCESS {
		fmt.println("miniaudio context_init failed:", ma.result_description(res))
		return false
	}
	// Ask for the bus format explicitly. The backend may still hand back
	// something else; we read back what it actually negotiated rather than
	// assuming, and the resampler is built for the difference.
	cfg := ma.device_config_init(ma.device_type.playback)
	cfg.playback.format = AUDIO_BUS_FORMAT
	cfg.playback.channels = AUDIO_BUS_CHANNELS
	cfg.sampleRate = AUDIO_BUS_RATE
	cfg.periodSizeInMilliseconds = AUDIO_DEVICE_PERIOD_MS
	cfg.periods = AUDIO_DEVICE_PERIOD_COUNT
	cfg.dataCallback = audio_device_data
	res = ma.device_init(&audio_dev.ctx, &cfg, &audio_dev.device)
	if res != ma.result.SUCCESS {
		fmt.println("miniaudio device_init failed:", ma.result_description(res))
		ma.context_uninit(&audio_dev.ctx)
		return false
	}
	audio_dev.rate = audio_dev.device.sampleRate
	audio_dev.channels = audio_dev.device.playback.channels
	// Assert the negotiated shape rather than handling the alternative silently:
	// the ring, the resampler, and the callback's i16 copy are all written
	// against 48 kHz stereo s16. A device that ignored the request would hand the
	// callback f32 and the producer's s16 bus would be reinterpreted as float
	// noise -- exactly the silent-wrong-three-subsystems-later failure. miniaudio
	// does honour the request on every backend here; this says so out loud.
	assert(
		audio_dev.rate > 0 &&
		audio_dev.channels == AUDIO_BUS_CHANNELS &&
		audio_dev.device.playback.playback_format == AUDIO_BUS_FORMAT,
		"miniaudio negotiated an unexpected playback shape",
	)
	audio_dev.resampling = audio_dev.rate != AUDIO_BUS_RATE
	// Bridge ring: preallocated, s16, 48 kHz-domain, lock-free SPSC.
	res = ma.pcm_rb_init(
		AUDIO_BUS_FORMAT,
		AUDIO_BUS_CHANNELS,
		AUDIO_BRIDGE_FRAMES,
		raw_data(audio_bridge_storage[:]),
		nil,
		&audio_dev.rb,
	)
	if res != ma.result.SUCCESS {
		fmt.println("miniaudio pcm_rb_init failed:", ma.result_description(res))
		ma.device_uninit(&audio_dev.device)
		ma.context_uninit(&audio_dev.ctx)
		return false
	}
	audio_dev.rb_ready = true
	if audio_dev.resampling {
		// Linear, not moog: this sits on the output path at ~1:1 (48 kHz bus to
		// whatever the card negotiated), where the resampler's job is to move the
		// sample grid, not to act as a filter. A 0.2% ratio change is not where
		// resampler character is audible, and linear keeps the callback's cost
		// proportional to the period instead of to the filter order.
		rs_cfg := ma.resampler_config_init(
			AUDIO_BUS_FORMAT,
			AUDIO_BUS_CHANNELS,
			AUDIO_BUS_RATE,
			audio_dev.rate,
			ma.resample_algorithm.linear,
		)
		res = ma.resampler_init(&rs_cfg, nil, &audio_dev.rs)
		if res != ma.result.SUCCESS {
			fmt.println("miniaudio resampler_init failed:", ma.result_description(res))
			ma.pcm_rb_uninit(&audio_dev.rb)
			audio_dev.rb_ready = false
			ma.device_uninit(&audio_dev.device)
			ma.context_uninit(&audio_dev.ctx)
			return false
		}
	}
	res = ma.device_start(&audio_dev.device)
	if res != ma.result.SUCCESS {
		fmt.println("miniaudio device_start failed:", ma.result_description(res))
		if audio_dev.resampling {
			ma.resampler_uninit(&audio_dev.rs, nil)
		}
		ma.pcm_rb_uninit(&audio_dev.rb)
		audio_dev.rb_ready = false
		ma.device_uninit(&audio_dev.device)
		ma.context_uninit(&audio_dev.ctx)
		return false
	}
	audio_dev.started = true
	audio_dev.ready = true
	when ODIN_DEBUG {
		if audio_rpt.trace {
			fmt.printf(
				"miniaudio device ready (%d Hz, %dch, %d-bit, period %d ms, resampling=%t, backend=%s)\n",
				audio_dev.rate,
				audio_dev.channels,
				audio_device_bits(),
				AUDIO_DEVICE_PERIOD_MS,
				audio_dev.resampling,
				ma.get_backend_name(audio_dev.device.pContext.backend),
			)
		}
	}
	return true
}

// audio_device_shutdown stops and tears everything down. The producer thread must
// already be joined: it writes into the ring, and freeing the ring underneath it
// is the same class of bug as freeing a buffer another thread is mid-read on.
audio_device_shutdown :: proc() {
	if !audio_dev.ready && !audio_dev.rb_ready {
		return
	}
	if audio_dev.started {
		ma.device_stop(&audio_dev.device)
		audio_dev.started = false
	}
	if audio_dev.rb_ready {
		ma.pcm_rb_uninit(&audio_dev.rb)
		audio_dev.rb_ready = false
	}
	if audio_dev.resampling {
		ma.resampler_uninit(&audio_dev.rs, nil)
		audio_dev.resampling = false
	}
	if audio_dev.ready {
		ma.device_uninit(&audio_dev.device)
		audio_dev.ready = false
	}
	ma.context_uninit(&audio_dev.ctx)
}

// audio_device_ready reports whether a device is open and the bridge is live.
audio_device_ready :: proc() -> bool {
	// The simulated device counts as ready even though no miniaudio ring exists:
	// otherwise the producer returns before feeding and the stall probe passes
	// VACUOUSLY -- it observes a gap because nothing was ever fed. Which is exactly
	// what the first run of that probe did, and reported success.
	if audio_dev.sim.on {
		return true
	}
	return audio_dev.ready && audio_dev.rb_ready
}

// audio_device_set_active opens or closes the transport gate. It does NOT stop
// the device: ma_device_stop/ma_device_start reopens the backend stream, which
// costs far more than the gate and is audible as a gap on every transport
// change. The callback keeps running and emitting silence instead.
audio_device_set_active :: proc(on: bool) {
	sync.atomic_store(&audio_dev.active, on)
}

// audio_device_push hands finished bus frames to the bridge. Producer thread
// only. Partial writes are normal and not an error: the ring is deeper than the
// queue ceiling precisely so the producer throttles on the ceiling rather than
// discovering a full ring here.
audio_device_push :: proc(pcm: []i16, frames: int) {
	if audio_dev.sim.on {
		if frames <= 0 {
			return
		}
		assert(
			audio_dev.sim.written + i64(frames) <= audio_dev.sim.cap,
			"simulated device ring overflow: the producer is not throttling to the cushion",
		)
		audio_dev.sim.written += i64(frames)
		return
	}
	if !audio_dev.rb_ready || frames <= 0 {
		return
	}
	// A short write is not a recoverable condition, it is a desync: the caller
	// advances its own playhead cursor by `frames` regardless of what landed, so a
	// partial write loses audio silently and the queue accounting stops matching
	// the ring. The producer throttles against AUDIO_CUSHION_SEC (12000 frames)
	// against a 32768-frame ring, so there is always room for a whole block.
	assert(
		audio_ring_write(pcm, frames) == frames,
		"audio_device_push: ring could not take a whole block; producer cursor would desync",
	)
}

// audio_ring_write copies a whole block into the ring and returns how many frames
// landed.
//
// The loop is the load-bearing part. ma_pcm_rb_acquire_write clamps its grant to
// the CONTIGUOUS room before the ring's end, and the producer's blocks are one
// video frame each, so once per lap the grant comes back short -- measured at
// exactly 1024 frames on a 16384-frame ring, with 4864 frames free. Writing only
// what one grant allows silently drops the tail: the producer's cursor advances
// past audio the device never received, the queue drains at exactly that rate
// (measured 2.15 s lost per 1035 blocks), and playback starves seconds later with
// no error anywhere.
//
// Retrying inside the same push is the fix, and it works because ma_rb_commit_write
// wraps the write cursor back to 0 when a commit lands exactly on the ring end --
// so the next acquire sees a fresh full-width window and the remainder lands
// immediately. Verified over 982 blocks: 0 short grants, 0 frames lost.
//
// The unrolled ma_pcm_rb_init_ex layout (subbufferCount=2, stride=2*size) looked
// like the tidier answer and does not work: it only avoids the clamp when writer
// and reader sit on different copies, which needs the ring more than half full.
// Measured an identical 115 short grants and 2.15 s lost.
audio_ring_write :: proc(src: []i16, frames: int) -> int {
	written := 0
	for written < frames {
		// In/out parameter: the request must carry the count we want written, or
		// the ring grants zero and the push silently no-ops.
		avail: u32 = u32(frames - written)
		buf: rawptr
		if ma.pcm_rb_acquire_write(&audio_dev.rb, &avail, &buf) != ma.result.SUCCESS || avail == 0 {
			break
		}
		n := min(frames - written, int(avail))
		samples := n * AUDIO_BUS_CHANNELS
		copy(mem.slice_ptr(cast([^]i16)buf, samples)[:samples], src[written * AUDIO_BUS_CHANNELS:(written + n) * AUDIO_BUS_CHANNELS])
		ma.pcm_rb_commit_write(&audio_dev.rb, u32(n))
		written += n
	}
	return written
}

// audio_device_queued is the bus-domain queue depth in sample-frames -- the
// direct successor of SDL_GetAudioStreamQueued, which the SDL docs state counts
// *input* bytes rather than converted output. So this is the same quantity in
// the same units, one division cheaper, with no byte/frame conversion to get
// wrong. A pending clear reads as empty immediately, because the callback may
// not have run yet to honour the flag.
audio_device_queued :: proc() -> i64 {
	if audio_dev.sim.on {
		return audio_dev.sim.written - audio_dev.sim.read
	}
	if !audio_dev.rb_ready || sync.atomic_load(&audio_dev.clear_req) {
		return 0
	}
	return i64(ma.pcm_rb_available_read(&audio_dev.rb))
}

// audio_device_available is the free space left for the producer, in frames.
audio_device_available :: proc() -> i64 {
	if audio_dev.sim.on {
		return audio_dev.sim.cap - (audio_dev.sim.written - audio_dev.sim.read)
	}
	if !audio_dev.rb_ready {
		return 0
	}
	return i64(ma.pcm_rb_available_write(&audio_dev.rb))
}

// audio_device_clear drops the queued audio AND the resampler's history, the
// pair that SDL's ClearAudioStream + FlushAudioStream did together: after a seek
// or a jump, the resampler still holds pre-jump samples, so a clear that left
// them would bleed the old position into the new one.
//
// It sets a flag instead of touching the ring, because the ring's read cursor
// belongs to the callback. Resetting it from the producer thread would race the
// consumer mid-read -- ma_pcm_rb is deliberately lock-free, so nothing inside it
// would catch that. The cost is that the drop lands within one period (~10 ms),
// which is invisible next to a seek and far cheaper than the race would be.
audio_device_clear :: proc() {
	if audio_dev.sim.on {
		// Both cursors, not just the read one. `written` is a monotonic counter,
		// so moving `read` up to it empties the queue and leaves the ring
		// permanently full -- the next push trips the overflow assert, and a sim
		// device that cannot survive a clear cannot model a seek, which is the
		// one thing every backward-scrub test has to do. Nothing else reads these
		// cursors concurrently: `sim_consume` runs on the probe's own thread, so
		// resetting both is the honest model of "the queue is dropped and the room
		// comes back".
		audio_dev.sim.written = 0
		audio_dev.sim.read = 0
		return
	}
	sync.atomic_store(&audio_dev.clear_req, true)
}

// audio_device_sim_enable swaps the miniaudio ring for a software one of `cap`
// sample-frames, so the headless stall probe can drive the real producer against a
// device whose drain rate it controls exactly. `cap` should be the real ring's
// capacity, not the cushion: the producer throttles to the cushion and must still
// have somewhere to put a whole block.
audio_device_sim_enable :: proc(cap: i64) {
	audio_dev.sim.on = true
	audio_dev.sim.written = 0
	audio_dev.sim.read = 0
	audio_dev.sim.cap = cap
	audio_dev.sim.underruns = 0
}

// audio_device_sim_disable restores the real device.
audio_device_sim_disable :: proc() {
	audio_dev.sim.on = false
}

// audio_device_sim_consume advances the simulated device by `frames`, and counts
// an underrun if it is asked for audio that was never written -- which is what the
// listener hears as silence, and is the GAP the stall is supposed to produce.
audio_device_sim_consume :: proc(frames: i64) {
	if !audio_dev.sim.on {
		return
	}
	want := audio_dev.sim.read + frames
	if want > audio_dev.sim.written {
		audio_dev.sim.underruns += 1
		want = audio_dev.sim.written
	}
	audio_dev.sim.read = want
}

audio_device_sim_underruns :: proc() -> u64 {
	return audio_dev.sim.underruns
}

// audio_device_rate is the rate the backend actually negotiated, which is the
// denominator the drain-rate health check divides by. The bus is 48 kHz
// regardless, so this is not the bus constant.
audio_device_rate :: proc() -> u32 {
	return audio_dev.rate
}

// audio_device_channels is the negotiated channel count.
audio_device_channels :: proc() -> u32 {
	return audio_dev.channels
}

// audio_device_bits is the negotiated sample width, for the telemetry line. The
// engine is fixed at s16 either way, so this only ever describes the device.
audio_device_bits :: proc() -> int {
	switch audio_dev.device.playback.playback_format {
	case .unknown:
		return 0
	case .u8:
		return 8
	case .s16:
		return 16
	case .s24:
		return 24
	case .s32:
		return 32
	case .f32:
		return 32
	}
	return 0
}

// audio_device_clears counts ring resets the callback actually performed.
audio_device_clears :: proc() -> u64 {
	return sync.atomic_load(&audio_dev.clears)
}

// audio_device_clear_pending reports whether a clear has been asked for and not yet
// performed by the callback. The producer must not feed while this is true: it would
// refill a ring the callback is about to reset, so the mix meant for the new position
// gets discarded along with the old, or plays before the reset lands. See
// audio_producer_feed.
audio_device_clear_pending :: proc() -> bool {
	return sync.atomic_load(&audio_dev.clear_req)
}

// audio_device_underruns counts callback periods the ring could not fill. A
// steady climb means the producer is not keeping up with the device; a
// non-zero one-off is a scheduling hiccup. Zero is the healthy state.
audio_device_underruns :: proc() -> u64 {
	return sync.atomic_load(&audio_dev.underruns)
}
