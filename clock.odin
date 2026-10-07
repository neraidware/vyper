package main

// clock.odin is the app's single time base: one monotonic clock, one epoch, one
// home.
//
// This exists because the time base was sdl.GetTicksNS, which worked only by
// accident of import graph -- every file that timed anything already imported
// SDL for the window. The audio thread was scheduling itself against a
// *windowing* subsystem's tick, and the coupling was invisible: gpu_draw.odin
// loads playback.dev_at_ns (stamped on the producer thread) and subtracts it
// from its own reading to extrapolate the device clock, so the A/V skew HUD was
// only correct as long as every reader and writer shared SDL's epoch. Splitting
// the clock across two sources would have turned that subtraction into garbage
// while leaving both halves individually plausible.

import "core:time"

// NS_PER_MS converts between the two units this codebase mixes: audio schedules
// and the A/V skew maths work in nanoseconds, UI notice deadlines and the cursor
// blink work in milliseconds.
NS_PER_MS :: 1_000_000

// monotonic_ns returns nanoseconds from a monotonic source (CLOCK_MONOTONIC_RAW
// on Linux), which is what sdl.GetTicksNS was used for.
//
// Monotonic, not the wall clock: audio scheduling must not step when NTP
// corrects the system time, and every caller here computes an interval or
// compares two readings rather than asking for a date. The zero point is
// whatever the platform's monotonic clock started at, so the absolute value is
// meaningless and only differences are -- which is all any caller uses. That
// also makes this correct with no init step: a zero epoch still yields a
// monotonic, increasing value.
monotonic_ns :: proc "contextless" () -> u64 {
	return u64(time.duration_nanoseconds(time.tick_diff({}, time.tick_now())))
}

// monotonic_ms is monotonic_ns in milliseconds, for the UI deadlines that were
// written against sdl.GetTicks. Unlike sdl.GetTicks (u32, wraps every ~49 days)
// this does not wrap, so a long-lived session cannot expire a notice early or
// stall the cursor blink.
monotonic_ms :: proc "contextless" () -> u64 {
	return monotonic_ns() / NS_PER_MS
}

// sleep_ms yields the CPU for at least ms milliseconds.
//
// Plain sleep, deliberately NOT time.accurate_sleep: accurate_sleep busy-spins
// the last few milliseconds to hit its deadline, which is right for a frame
// pacer and wrong for the audio producer's poll loops, where it would burn a core
// spinning instead of parking the thread.
sleep_ms :: proc "contextless" (ms: int) {
	time.sleep(time.Duration(ms) * time.Millisecond)
}

// sleep_ns is the sub-millisecond form, for pacing a replay to the frame
// durations a recording measured. Frame periods are tens of milliseconds, so
// rounding them to whole milliseconds would drift a minute-long session by
// seconds.
sleep_ns :: proc "contextless" (ns: u64) {
	if ns == 0 {
		return
	}
	time.sleep(time.Duration(ns))
}
