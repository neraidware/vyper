package main

import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Keyboard state. The app used to see only KEY_DOWN events, which made "is
// this key currently down" unanswerable and forced every consumer to decide
// what a key repeat means. This is the one place that tracks the down/up
// edges, so consumers ask key_held/key_press/key_release instead of
// interpreting raw events.
//
// The whole app polls SDL from a single place (handle_sdl_events), which drains
// the queue completely. `drain` counts those calls, so "this frame's" and "this
// drain's" are the same thing — an event queued during a stall is handled in
// the same drain as the one before it. Anything that needs to know whether two
// events came from the same burst of input compares drain ids.
// ---------------------------------------------------------------------------

// KEYCODE_SLOTS bounds the key tables. SDL keycodes are dense below SDLK_LAST
// (0x400); the 0x40000xxx values in the enum are scancode-tagged via
// K_SCANCODE_MASK and never appear as a key event's `key` field.
KEYCODE_SLOTS :: 0x400

Kbd_State :: struct {
	// held is the physical truth: down right now, repeats and all.
	held: [KEYCODE_SLOTS]bool,
	// press_edge/repeat mark the DOWN transitions seen in the current drain,
	// split so a consumer can ask for the initial press without re-deriving it
	// from the event's `repeat` flag.
	press_edge:  [KEYCODE_SLOTS]bool,
	repeat:      [KEYCODE_SLOTS]bool,
	release_edge: [KEYCODE_SLOTS]bool,
	// drain increments once per full queue drain.
	drain: u32,
}

// kbd is the app's keyboard state. A fixed global, not a per-frame allocation:
// the ownership matrix puts input state in the session bucket, since it has to
// survive the frame it was read in (a key held across frames is still held).
kbd: Kbd_State

key_slot :: proc(k: sdl.Keycode) -> int {
	i := int(k)
	// A scancode-tagged keycode (K_SCANCODE_MASK set) is not a real key event
	// field; folding it in range keeps the table access in bounds instead of
	// writing past the end on a malformed or future keycode.
	if i < 0 || i >= KEYCODE_SLOTS {
		return -1
	}
	return i
}

key_held :: proc(k: sdl.Keycode) -> bool {
	i := key_slot(k)
	return i >= 0 && kbd.held[i]
}

// key_press reports the initial press only — the first DOWN of a held key, not
// the OS auto-repeat that follows it. This is what an action should trigger on.
key_press :: proc(k: sdl.Keycode) -> bool {
	i := key_slot(k)
	return i >= 0 && kbd.press_edge[i]
}

// key_repeat reports a DOWN that is an auto-repeat, i.e. the key was already
// down. Continuous actions (jog/shuttle) want these; one-shot actions don't.
key_repeat :: proc(k: sdl.Keycode) -> bool {
	i := key_slot(k)
	return i >= 0 && kbd.repeat[i]
}

key_release :: proc(k: sdl.Keycode) -> bool {
	i := key_slot(k)
	return i >= 0 && kbd.release_edge[i]
}

// kbd_note_key applies one key event to the state. Repeat is decided by
// whether the key was already down, not by the event's own flag: the flag is
// absent on some platform paths, and "already down" is the definition of a
// repeat regardless of who reported it.
kbd_note_key :: proc(k: sdl.Keycode, down: bool) {
	i := key_slot(k)
	if i < 0 {
		return
	}
	if down {
		if kbd.held[i] {
			kbd.repeat[i] = true
		} else {
			kbd.press_edge[i] = true
		}
		kbd.held[i] = true
	} else {
		if kbd.held[i] {
			kbd.release_edge[i] = true
		}
		kbd.held[i] = false
	}
}

// kbd_begin_drain clears the per-drain edges. Called once before the poll loop,
// so a key that goes down and up inside one drain still reports both edges
// instead of the up overwriting the down.
kbd_begin_drain :: proc() {
	kbd.press_edge = {}
	kbd.repeat = {}
	kbd.release_edge = {}
	kbd.drain += 1
}

// MOD_PAIRS are the left/right pairs that SDL collapses into a single combined
// mask (KMOD_SHIFT is LSHIFT|RSHIFT), so a binding that "requires shift"
// requires EITHER side, not both.
MOD_PAIRS := [4][2]sdl.Keymod {
	{ sdl.KMOD_LCTRL, sdl.KMOD_RCTRL },
	{ sdl.KMOD_LSHIFT, sdl.KMOD_RSHIFT },
	{ sdl.KMOD_LALT, sdl.KMOD_RALT },
	{ sdl.KMOD_LGUI, sdl.KMOD_RGUI },
}

// mods_have reports whether `got` satisfies the modifiers a binding requires.
// This is NOT a plain bitwise subset test, and the difference is load-bearing:
// SDL's combined masks (KMOD_CTRL, KMOD_SHIFT) are the left and right keys
// OR-ed together to mean "either", so testing `(got & KMOD_CTRL) == KMOD_CTRL`
// would demand the user press BOTH Ctrl keys at once and never match. A plain
// subset test therefore silently disables every modified binding — it compiles,
// and every one of them is simply dead.
//
// Unpaired flags (CapsLock, NumLock) fall through to the plain subset test, so
// a binding can require those exactly.
mods_have :: proc(got: sdl.Keymod, want: sdl.Keymod) -> bool {
	plain := want
	for pair in MOD_PAIRS {
		l, r := pair[0], pair[1]
		required := (plain & l) != nil || (plain & r) != nil
		plain &= ~(l | r)
		if required && (got & l) == nil && (got & r) == nil {
			return false
		}
	}
	return (got & plain) == plain
}
