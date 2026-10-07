package main

import sdl "vendor:sdl3"
import "core:c"
import "core:encoding/cbor"
import "core:fmt"
import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// Action log: record the raw input of a session to a binary file and replay it.
//
//	VYPER_ACTION_RECORD=/tmp/session.vya  ./vyper project.vyproj
//	VYPER_ACTION_REPLAY=/tmp/session.vya  ./vyper
//
// Why this exists: a bug that only appears after a specific run of scrubbing
// and playback cannot be pinned down by re-describing the session in prose. The
// timing of the hand is part of what the audio producer sees, so "scrub a bit,
// then play" does not reproduce -- the pointer sat at a different pixel and the
// frame durations differed. This records what the hand actually did and hands
// it back.
//
// What is recorded is RAW INPUT, not resolved commands: the pointer state each
// frame plus the key/wheel/drop events. Replay pushes them through the SAME
// dispatch (dispatch_sdl_event) and the same per-frame pointer snapshot the
// live app reads, so a replayed session runs the code a user runs. Recording
// resolved commands instead would be immune to layout and timing, but it would
// no longer be the user's actions.
//
// FORMAT (little-endian, versioned):
//
//	magic    [7]u8  "VYPRACT"
//	version  u32    ACTION_LOG_VERSION
//	then records to end of file, each: kind u32, payload_len u32, payload bytes
//
//	SNAPSHOT  CBOR Project_File -- the session at recording start. Replay
//	          restores this instead of loading a project, so a replay does not
//	          depend on the file on disk still being what it was.
//	KEY       keycode, mods, flags (ACTION_KEY_*)
//	TEXT      UTF-8 bytes, no NUL
//	WHEEL     x, y, mouse_x, mouse_y, direction
//	DROP      SDL drop kind, x, y, UTF-8 payload
//	QUIT      empty
//	MOUSE     x, y, button bits
//	FRAME_END dt_ns, frame index, window w, window h
//
// MOUSE and FRAME_END bracket the frame: MOUSE sits where read_mouse_input
// sits, FRAME_END carries the pacing replay sleeps to so the producer sees the
// recorded wall-clock spacing.
//
// Events the app ignores (motion, window, focus, device) are neither written
// nor counted: they are not app behaviour, so dropping them changes nothing.
// Every event type dispatch_sdl_event DOES act on has a kind above, which is
// the set that would have to change before this format needed a new one.
// ---------------------------------------------------------------------------

ACTION_LOG_MAGIC :: "VYPRACT"
ACTION_LOG_VERSION :: 1

// Record kinds. The enum is the format's single source of truth; they are
// stored as u32 and never renumbered.
Action_Log_Kind :: enum u32 {
	SNAPSHOT  = 0,
	KEY       = 1,
	TEXT      = 2,
	WHEEL     = 3,
	DROP      = 4,
	QUIT      = 5,
	MOUSE     = 6,
	FRAME_END = 7,
}

// A record kind off the end of the enum means the log was written by a build
// with more event kinds than this one knows how to replay.
ACTION_LOG_KIND_MAX :: u32(Action_Log_Kind.FRAME_END)

// The pointer snapshot is six independent held states; a bitfield is the whole
// record, and it is what the drag gestures are made of -- "button held plus a
// position" -- so nothing else about a drag has to be recorded.
ACTION_MOUSE_LEFT   :: 1 << 0
ACTION_MOUSE_RIGHT  :: 1 << 1
ACTION_MOUSE_MIDDLE :: 1 << 2
ACTION_MOD_ALT      :: 1 << 3
ACTION_MOD_SHIFT    :: 1 << 4
ACTION_MOD_CTRL     :: 1 << 5

ACTION_KEY_DOWN   :: 1 << 0
ACTION_KEY_REPEAT :: 1 << 1

// Records are assembled whole in one scratch buffer and then appended, so a
// record can never straddle two staging flushes. 1 KiB is far above any record
// the app can produce; the text and drop asserts below are what turn "far
// above" into a fact.
ACTION_RECORD_MAX     :: 1024
ACTION_WRITE_STAGING  :: 64 * 1024
ACTION_FILE_MAX_BYTES :: 512 << 20

// ---------------------------------------------------------------------------
// Little-endian primitives
// ---------------------------------------------------------------------------

// Action_Cursor writes primitives into a fixed record scratch. The scratch is
// held BY VALUE: a `^[ACTION_RECORD_MAX]u8` field would be nil, and every record
// would then be assembled through a wild pointer.
Action_Cursor :: struct {
	buf: [ACTION_RECORD_MAX]u8,
	n:   int,
}

cursor_u32 :: proc (c: ^Action_Cursor, v: u32) {
	assert(c.n + 4 <= ACTION_RECORD_MAX, "action log: record overflow")
	b := c.buf[c.n:]
	b[0] = u8(v)
	b[1] = u8(v >> 8)
	b[2] = u8(v >> 16)
	b[3] = u8(v >> 24)
	c.n += 4
}

cursor_u64 :: proc (c: ^Action_Cursor, v: u64) {
	cursor_u32(c, u32(v))
	cursor_u32(c, u32(v >> 32))
}

// cursor_f32 stores the bit pattern, not a decimal rendering: the reader must
// get back the exact pointer position that produced the frame, not a number
// that looks like it.
cursor_f32 :: proc (c: ^Action_Cursor, v: f32) {
	cursor_u32(c, transmute(u32)v)
}

cursor_bytes :: proc (c: ^Action_Cursor, p: []u8) {
	assert(c.n + len(p) <= ACTION_RECORD_MAX, "action log: record overflow")
	copy(c.buf[c.n:c.n + len(p)], p)
	c.n += len(p)
}

// Action_Rd is the read-side mirror: every read reports whether it had the
// bytes, because a truncated log is a corrupt input to this build, not an
// invariant of the program.
Action_Rd :: struct {
	data: []u8,
	pos:  int,
}

rd_u8 :: proc (r: ^Action_Rd) -> (u8, bool) {
	if r.pos >= len(r.data) {
		return 0, false
	}
	v := r.data[r.pos]
	r.pos += 1
	return v, true
}

rd_u32 :: proc (r: ^Action_Rd) -> (u32, bool) {
	if r.pos + 4 > len(r.data) {
		return 0, false
	}
	b := r.data[r.pos:]
	v := u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
	r.pos += 4
	return v, true
}

rd_u64 :: proc (r: ^Action_Rd) -> (u64, bool) {
	lo, got_lo := rd_u32(r)
	if !got_lo {
		return 0, false
	}
	hi, got_hi := rd_u32(r)
	if !got_hi {
		return 0, false
	}
	return u64(lo) | u64(hi) << 32, true
}

rd_f32 :: proc (r: ^Action_Rd) -> (f32, bool) {
	v, ok := rd_u32(r)
	return transmute(f32)v, ok
}

// The live window size. The log stores it per frame and the player checks every
// frame against it: a pointer position in the log is a pixel in the recorded
// layout, and at a different size each one addresses a different widget, so the
// log is simply wrong for that run. It lives here rather than as a parameter
// because the frame loop already calls read_mouse_input, and the probes that
// simulate the loop call handle_sdl_events with no size of their own.
action_win: struct {
	w, h: c.int,
}

action_log_window :: proc(width, height: c.int) {
	action_win.w = width
	action_win.h = height
}

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

// Action_Recorder batches records into one staging block, so recording costs a
// write per 64 KiB rather than one per event. f == nil means "not recording",
// which is what makes the zero value safe to call against unconditionally --
// action_rec is a global and the record procs are reached from the event loop.
Action_Recorder :: struct {
	f:       ^os.File,
	staging: [ACTION_WRITE_STAGING]u8,
	used:    int,
	frames:  u64,
	name:    string,
	broken:  bool,
}

action_rec: Action_Recorder

action_rec_flush :: proc() {
	rec := &action_rec
	if rec.used == 0 || rec.broken {
		return
	}
	// A short write that is not an error still has to be finished, or the log
	// silently loses its middle and replays as a shorter session.
	rest := rec.staging[:rec.used]
	for len(rest) > 0 {
		n, err := os.write(rec.f, rest)
		if err != nil || n <= 0 {
			fmt.eprintf(
				"action log: write to '%s' failed with %d bytes buffered: %v\n",
				rec.name,
				rec.used,
				err,
			)
			rec.broken = true
			return
		}
		rest = rest[n:]
	}
	rec.used = 0
}

action_rec_write :: proc (p: []u8) {
	rec := &action_rec
	if rec.f == nil || rec.broken {
		return
	}
	// One record is at most ACTION_RECORD_MAX, far below the staging block, so
	// a single flush always leaves room.
	if len(rec.staging) - rec.used < len(p) {
		action_rec_flush()
		if rec.broken {
			return
		}
	}
	assert(len(p) <= len(rec.staging), "action log: record larger than the staging block")
	copy(rec.staging[rec.used:], p)
	rec.used += len(p)
}

action_rec_emit :: proc (kind: Action_Log_Kind, payload: []u8) {
	c: Action_Cursor
	cursor_u32(&c, u32(kind))
	cursor_u32(&c, u32(len(payload)))
	action_rec_write(c.buf[:c.n])
	action_rec_write(payload)
}

// ---------------------------------------------------------------------------
// Writer: the app's own event set
// ---------------------------------------------------------------------------

// action_record_event records exactly the events dispatch_sdl_event acts on.
// Both switches must stay in step: a case added there and not here is an
// action the log silently loses, which is the one failure this format cannot
// have.
action_record_event :: proc(event: ^sdl.Event) {
	rec := &action_rec
	if rec.f == nil || rec.broken {
		return
	}
	#partial switch event.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		action_rec_emit(.QUIT, {})
	case .KEY_DOWN, .KEY_UP:
		c: Action_Cursor
		cursor_u32(&c, u32(event.key.key))
		// Keymod is a distinct bit_set over a Uint16, so the raw bits are read
		// through it rather than converted: the flag arithmetic the dispatch
		// does (`LSHIFT in mods`) is the only thing that has to survive, and
		// the bits are what it reads.
		cursor_u32(&c, u32(transmute(u16)event.key.mod))
		flags := u32(0)
		if event.key.down {
			flags |= ACTION_KEY_DOWN
		}
		if event.key.repeat {
			flags |= ACTION_KEY_REPEAT
		}
		cursor_u32(&c, flags)
		action_rec_emit(.KEY, c.buf[:c.n])
	case .TEXT_INPUT:
		text := string(event.text.text)
		assert(len(text) <= ACTION_RECORD_MAX - 8, "action log: text input too long to record")
		action_rec_emit(.TEXT, transmute([]u8)text)
	case .MOUSE_WHEEL:
		c: Action_Cursor
		cursor_f32(&c, event.wheel.x)
		cursor_f32(&c, event.wheel.y)
		// handle_mouse_wheel picks its scroll zone from the pointer position
		// the wheel arrived at, so the deltas alone would not say which zone
		// the wheel belonged to.
		cursor_f32(&c, event.wheel.mouse_x)
		cursor_f32(&c, event.wheel.mouse_y)
		cursor_u32(&c, u32(event.wheel.direction))
		action_rec_emit(.WHEEL, c.buf[:c.n])
	case .DROP_BEGIN, .DROP_POSITION, .DROP_FILE, .DROP_COMPLETE, .DROP_TEXT:
		c: Action_Cursor
		cursor_u32(&c, u32(event.type))
		cursor_f32(&c, event.drop.x)
		cursor_f32(&c, event.drop.y)
		// DROP_BEGIN and DROP_COMPLETE carry no data pointer at all, and
		// DROP_TEXT's is empty during a file drag. nil is therefore a zero
		// length, not a value the reader has to recognise.
		if event.drop.data != nil {
			data := string(event.drop.data)
			assert(len(data) <= ACTION_RECORD_MAX - 16, "action log: drop payload too long to record")
			cursor_bytes(&c, transmute([]u8)data)
		}
		action_rec_emit(.DROP, c.buf[:c.n])
	}
}

action_mouse_bits :: proc (inp: Mouse_Input) -> u32 {
	b := u32(0)
	if inp.left {
		b |= ACTION_MOUSE_LEFT
	}
	if inp.right {
		b |= ACTION_MOUSE_RIGHT
	}
	if inp.middle {
		b |= ACTION_MOUSE_MIDDLE
	}
	if inp.alt {
		b |= ACTION_MOD_ALT
	}
	if inp.shift {
		b |= ACTION_MOD_SHIFT
	}
	if inp.ctrl {
		b |= ACTION_MOD_CTRL
	}
	return b
}

action_record_mouse :: proc(inp: Mouse_Input) {
	rec := &action_rec
	if rec.f == nil || rec.broken {
		return
	}
	c: Action_Cursor
	cursor_f32(&c, inp.x)
	cursor_f32(&c, inp.y)
	cursor_u32(&c, action_mouse_bits(inp))
	action_rec_emit(.MOUSE, c.buf[:c.n])
}

// action_record_frame_end closes the frame with its measured duration. The
// duration is the whole frame period, not the gap between two interior
// now_ns samples, so a replay's pacing includes the render and present time
// the recording spent there.
action_record_frame_end :: proc(dt_ns: u64) {
	rec := &action_rec
	if rec.f == nil || rec.broken {
		return
	}
	c: Action_Cursor
	cursor_u64(&c, dt_ns)
	cursor_u64(&c, rec.frames)
	cursor_u32(&c, u32(action_win.w))
	cursor_u32(&c, u32(action_win.h))
	action_rec_emit(.FRAME_END, c.buf[:c.n])
	rec.frames += 1
}

action_rec_open :: proc(path: string) {
	f, err := os.open(path, {.Write, .Create, .Trunc})
	if err != nil {
		fmt.eprintf("action log: cannot write '%s': %v\n", path, err)
		return
	}
	// The path came off the temp arena, which the frame loop frees every frame,
	// so the recorder keeps its own copy: it has to still name the file in the
	// close message.
	action_rec = Action_Recorder{f = f, name = strings.clone(path)}
	c: Action_Cursor
	magic: string = ACTION_LOG_MAGIC
	cursor_bytes(&c, transmute([]u8)magic)
	cursor_u32(&c, ACTION_LOG_VERSION)
	action_rec_write(c.buf[:c.n])
	fmt.printf("[action-log] recording -> %s\n", path)
}

// action_rec_snapshot puts the loaded session in the log as its first record,
// using the same encode project_file_save uses. Replay restores this instead of
// loading a project, so the log replays against the session it recorded rather
// than against whatever is on disk when it is played back.
//
// It is a separate call from action_rec_open because the session is not loaded
// when the file opens: the argv loop runs first, and VYPER_AUTOPLAY imports
// after that.
action_rec_snapshot :: proc() {
	pf := project_to_file()
	defer project_file_free_containers(&pf)
	data, err := cbor.marshal(pf, cbor.ENCODE_FULLY_DETERMINISTIC)
	if err != nil {
		fmt.eprintf("action log: cannot encode the project snapshot: %v\n", err)
		return
	}
	defer delete(data)
	action_rec_emit(.SNAPSHOT, data)
}

action_rec_close :: proc() {
	rec := &action_rec
	if rec.f == nil {
		return
	}
	action_rec_flush()
	name := rec.name
	frames := rec.frames
	broken := rec.broken
	cerr := os.close(rec.f)
	rec.f = nil
	rec.used = 0
	// Every message below still names the file, so the copy is released after
	// them, not before.
	if broken {
		fmt.eprintf("action log: '%s' is incomplete after %d frames\n", name, frames)
		delete(rec.name)
		rec.name = ""
		return
	}
	if cerr != nil {
		fmt.eprintf("action log: closing '%s' failed: %v\n", name, cerr)
		delete(rec.name)
		rec.name = ""
		return
	}
	fmt.printf("[action-log] recorded %d frames -> %s\n", frames, name)
	delete(rec.name)
	rec.name = ""
}

// ---------------------------------------------------------------------------
// Player
// ---------------------------------------------------------------------------

// Action_Player holds the whole log for the session. A user's session is small
// (a minute at 60 fps is well under a megabyte of records), and holding it
// whole is what lets a truncated record be detected instead of half-parsed.
Action_Player :: struct {
	rd:       Action_Rd,
	mouse:    Mouse_Input,
	mouse_ok: bool,
	deadline: u64,
	frame:    u64,
	active:   bool,
	failed:   bool,
	// The window a replay adopts the recorded size on. Borrowed from main, which
	// owns it and outlives the loop; nil in a headless probe, where the caller
	// has already set the size to the recorded one.
	win: ^sdl.Window,
	// Whether the recorded size has been applied to `win` yet. The window size a
	// launch comes up with is not stable -- the same binary measured 671x716 and
	// 951x1028 on different runs of the same session -- so a replay that simply
	// refused to run at a different size would be refused most of the time. The
	// log carries the size precisely so the replay can become that size.
	sized: bool,
	// SDL hands dispatch a C string for text and drop payloads and reads it
	// during the call. The log's bytes are not NUL-terminated and belong to a
	// buffer that outlives the call, so both are copied into one of these and
	// used only while dispatch runs.
	text_buf: [ACTION_RECORD_MAX + 1]u8,
	drop_buf: [ACTION_RECORD_MAX + 1]u8,
}

action_play: Action_Player

action_replaying :: proc "contextless" () -> bool {
	return action_play.active
}

action_play_free :: proc() {
	delete(action_play.rd.data)
	action_play = Action_Player{}
}

// action_play_fail ends the replay. It is not recoverable: the log cannot be
// read past the current point, and carrying on would run a session missing the
// rest of its input -- the silent wrong answer the log exists to rule out.
action_play_fail :: proc(reason: string, running: ^bool) {
	play := &action_play
	fmt.eprintf(
		"action log: %s at byte %d of %d after %d frames -- stopping\n",
		reason,
		play.rd.pos,
		len(play.rd.data),
		play.frame,
	)
	play.failed = true
	play.active = false
	running^ = false
}

// action_play_restore_snapshot makes the recorded session live. The decode
// lands on the temp arena exactly as project_file_open does, because
// session_rebuild clones everything it keeps and the frame loop's free_all
// reclaims the rest.
action_play_restore_snapshot :: proc(bytes: []u8) -> bool {
	pf: Project_File
	uerr := cbor.unmarshal_from_bytes(bytes, &pf, cbor.Decoder_Flags{}, context.temp_allocator)
	if uerr != nil {
		fmt.eprintf("action log: project snapshot is not valid CBOR: %v\n", uerr)
		return false
	}
	session_teardown()
	session_rebuild(&pf)
	return true
}

// action_play_next reads one record. The kind comes back as u32 rather than the
// enum: a log written by a build that has more kinds than this one reads is a
// value outside the enum, and casting it before checking would hand the caller
// an invalid enum to switch on. ok covers only the read; the kind is validated
// by the caller, which can say WHY a kind is unusable.
action_play_next :: proc() -> (u32, []u8, bool) {
	rd := &action_play.rd
	kind, got_kind := rd_u32(rd)
	if !got_kind {
		return 0, nil, false
	}
	plen, got_len := rd_u32(rd)
	if !got_len || rd.pos + int(plen) > len(rd.data) {
		return 0, nil, false
	}
	payload := rd.data[rd.pos:rd.pos + int(plen)]
	rd.pos += int(plen)
	return kind, payload, true
}

action_play_open :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintf("action log: cannot read '%s': %v\n", path, err)
		return false
	}
	if len(data) > ACTION_FILE_MAX_BYTES {
		fmt.eprintf(
			"action log: '%s' is %d bytes, over the %d byte limit\n",
			path,
			len(data),
			ACTION_FILE_MAX_BYTES,
		)
		delete(data)
		return false
	}
	play := &action_play
	play.rd = Action_Rd{data = data}

	r: Action_Rd = {data = data}
	for ch in ACTION_LOG_MAGIC {
		got, ok := rd_u8(&r)
		if !ok || got != u8(ch) {
			fmt.eprintf("action log: '%s' is not an action log\n", path)
			action_play_free()
			return false
		}
	}
	ver, ok := rd_u32(&r)
	if !ok {
		fmt.eprintf("action log: '%s' is truncated in its header\n", path)
		action_play_free()
		return false
	}
	if ver != ACTION_LOG_VERSION {
		fmt.eprintf(
			"action log: '%s' is version %d, this build reads version %d\n",
			path,
			ver,
			ACTION_LOG_VERSION,
		)
		action_play_free()
		return false
	}
	play.rd.pos = r.pos

	// The snapshot is consumed here, before a single event is dispatched:
	// replaying input into a session the log itself carries is the whole
	// reason the snapshot is in the file.
	kind, payload, have := action_play_next()
	if !have || kind != u32(Action_Log_Kind.SNAPSHOT) {
		fmt.eprintf("action log: '%s' has no project snapshot as its first record\n", path)
		action_play_free()
		return false
	}
	if !action_play_restore_snapshot(payload) {
		action_play_free()
		return false
	}
	play.active = true
	play.deadline = monotonic_ns()
	fmt.printf("[action-log] replaying %s: %d tracks restored\n", path, len(timeline.tracks))
	return true
}

// action_replay_mouse_input is the frame's pointer snapshot. Without a MOUSE
// record the frame would silently reuse the previous frame's pointer, which
// reads as a stuck cursor rather than a broken log.
action_replay_mouse_input :: proc() -> Mouse_Input {
	assert(action_play.mouse_ok, "action log: replayed frame carries no MOUSE record")
	return action_play.mouse
}

action_replay_key :: proc(running: ^bool, payload: []u8) {
	r: Action_Rd = {data = payload}
	key, ok1 := rd_u32(&r)
	mods, ok2 := rd_u32(&r)
	flags, ok3 := rd_u32(&r)
	if !(ok1 && ok2 && ok3) {
		action_play_fail("short KEY record", running)
		return
	}
	down := flags & ACTION_KEY_DOWN != 0
	event: sdl.Event
	event.type = down ? .KEY_DOWN : .KEY_UP
	event.key.key = sdl.Keycode(key)
	event.key.mod = transmute(sdl.Keymod)u16(mods)
	event.key.down = down
	event.key.repeat = flags & ACTION_KEY_REPEAT != 0
	dispatch_sdl_event(&event, running)
}

action_replay_text :: proc(running: ^bool, payload: []u8) {
	play := &action_play
	assert(len(payload) + 1 <= len(play.text_buf), "action log: TEXT record too long for the replay buffer")
	copy(play.text_buf[:], payload)
	play.text_buf[len(payload)] = 0
	event: sdl.Event
	event.type = .TEXT_INPUT
	event.text.text = cstring(&play.text_buf[0])
	dispatch_sdl_event(&event, running)
}

action_replay_wheel :: proc(running: ^bool, payload: []u8) {
	r: Action_Rd = {data = payload}
	x, ok1 := rd_f32(&r)
	y, ok2 := rd_f32(&r)
	mx, ok3 := rd_f32(&r)
	my, ok4 := rd_f32(&r)
	dir, ok5 := rd_u32(&r)
	if !(ok1 && ok2 && ok3 && ok4 && ok5) {
		action_play_fail("short WHEEL record", running)
		return
	}
	event: sdl.Event
	event.type = .MOUSE_WHEEL
	event.wheel.x = x
	event.wheel.y = y
	event.wheel.mouse_x = mx
	event.wheel.mouse_y = my
	event.wheel.direction = sdl.MouseWheelDirection(dir)
	dispatch_sdl_event(&event, running)
}

action_replay_drop :: proc(running: ^bool, payload: []u8) {
	play := &action_play
	r: Action_Rd = {data = payload}
	kind, ok1 := rd_u32(&r)
	x, ok2 := rd_f32(&r)
	y, ok3 := rd_f32(&r)
	if !(ok1 && ok2 && ok3) {
		action_play_fail("short DROP record", running)
		return
	}
	event: sdl.Event
	event.type = sdl.EventType(kind)
	event.drop.x = x
	event.drop.y = y
	rest := payload[r.pos:]
	if len(rest) > 0 {
		assert(len(rest) + 1 <= len(play.drop_buf), "action log: DROP record too long for the replay buffer")
		copy(play.drop_buf[:], rest)
		play.drop_buf[len(rest)] = 0
		event.drop.data = cstring(&play.drop_buf[0])
	}
	dispatch_sdl_event(&event, running)
}

action_replay_mouse :: proc(payload: []u8) {
	r: Action_Rd = {data = payload}
	x, ok1 := rd_f32(&r)
	y, ok2 := rd_f32(&r)
	bits, ok3 := rd_u32(&r)
	if !(ok1 && ok2 && ok3) {
		return
	}
	m := &action_play.mouse
	m.x = x
	m.y = y
	m.left = bits & ACTION_MOUSE_LEFT != 0
	m.right = bits & ACTION_MOUSE_RIGHT != 0
	m.middle = bits & ACTION_MOUSE_MIDDLE != 0
	m.alt = bits & ACTION_MOD_ALT != 0
	m.shift = bits & ACTION_MOD_SHIFT != 0
	m.ctrl = bits & ACTION_MOD_CTRL != 0
	action_play.mouse_ok = true
}

// action_replay_frame_end paces the replay: the deadline advances by the
// recorded frame duration and the frame sleeps until it, so the producer sees
// the recorded wall-clock spacing. A frame that overran its budget leaves the
// deadline where it landed and the next frame catches up, rather than the
// whole session drifting later by every overrun.
action_replay_frame_end :: proc(payload: []u8, running: ^bool) {
	play := &action_play
	r: Action_Rd = {data = payload}
	dt, ok1 := rd_u64(&r)
	index, ok2 := rd_u64(&r)
	w, ok3 := rd_u32(&r)
	h, ok4 := rd_u32(&r)
	if !(ok1 && ok2 && ok3 && ok4) {
		action_play_fail("short FRAME_END record", running)
		return
	}
	// The pointer positions in the log are pixels in the recorded layout, so the
	// replay has to be laid out at the recorded size. The first frame resizes the
	// window to match; every later frame checks that the size still holds, which
	// is where a resize DURING the recording surfaces -- and there is nothing to
	// do about that one, because the log never recorded the user's resize.
	if !play.sized {
		play.sized = true
		if play.win != nil {
			sdl.SetWindowSize(play.win, action_win.w, action_win.h)
		}
	} else if i32(w) != action_win.w || i32(h) != action_win.h {
		msg: [160]u8
		// bprintf returns the formatted string itself (length = written), so the
		// assert message is not the 160-byte buffer with its tail of NULs.
		assert(
			false,
			fmt.bprintf(
				msg[:],
				"action log: replay window %dx%d does not match the recorded %dx%d",
				action_win.w,
				action_win.h,
				i32(w),
				i32(h),
			),
		)
	}
	play.frame = index + 1
	play.deadline += dt
	now := monotonic_ns()
	if play.deadline > now {
		sleep_ns(play.deadline - now)
	}
}

// action_replay_frame consumes the records up to and including this frame's
// FRAME_END. The end of the file exactly on a frame boundary is the recording
// finishing; a file that runs out mid-record is a truncated log.
action_replay_frame :: proc(running: ^bool) {
	play := &action_play
	assert(
		action_win.w > 0 && action_win.h > 0,
		"action log: replay started before the frame loop reported a window size",
	)
	if play.rd.pos >= len(play.rd.data) {
		fmt.printf("[action-log] replayed %d frames\n", play.frame)
		play.active = false
		running^ = false
		return
	}
	for {
		kind_raw, payload, ok := action_play_next()
		if !ok {
			action_play_fail("truncated record", running)
			return
		}
		if kind_raw > ACTION_LOG_KIND_MAX {
			fmt.eprintf(
				"action log: record kind %d at byte %d is unknown to this build (reads through %d) -- stopping\n",
				kind_raw,
				play.rd.pos,
				ACTION_LOG_KIND_MAX,
			)
			play.failed = true
			play.active = false
			running^ = false
			return
		}
		switch Action_Log_Kind(kind_raw) {
		case .KEY:
			action_replay_key(running, payload)
		case .TEXT:
			action_replay_text(running, payload)
		case .WHEEL:
			action_replay_wheel(running, payload)
		case .DROP:
			action_replay_drop(running, payload)
		case .QUIT:
			event: sdl.Event
			event.type = .QUIT
			dispatch_sdl_event(&event, running)
		case .MOUSE:
			action_replay_mouse(payload)
		case .FRAME_END:
			action_replay_frame_end(payload, running)
			return
		case .SNAPSHOT:
			// Only ever first, and action_play_open consumed it.
			action_play_fail("project snapshot appears mid-stream", running)
			return
		}
		if !play.active || !running^ {
			// A QUIT record ran the same path the live quit does.
			return
		}
	}
}

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------

// action_log_capture_session writes the log's project snapshot. Called once the
// session is loaded, so the record is the session the recording starts from and
// not an empty one. A no-op in replay, and a no-op when recording is off.
action_log_capture_session :: proc() {
	if action_rec.f == nil || action_rec.broken {
		return
	}
	action_rec_snapshot()
}

// action_log_startup resolves the two env vars. Recording opens the file;
// replay restores the session from the log instead of loading one. Both run
// before the autoplay block, because replay must own the session before
// autoplay can try to replace it -- and the snapshot, which needs the session
// already loaded, is captured by action_log_capture_session after that block.
// The recorder is closed by the frame loop's exit path, not here.
action_log_startup :: proc(window: ^sdl.Window) {
	if replay := os.get_env_alloc("VYPER_ACTION_REPLAY", context.temp_allocator); replay != "" {
		// Borrowed, not owned: main created the window and outlives the loop.
		action_play.win = window
		if !action_play_open(replay) {
			os.exit(1)
		}
		return
	}
	if record := os.get_env_alloc("VYPER_ACTION_RECORD", context.temp_allocator); record != "" {
		action_rec_open(record)
	}
}