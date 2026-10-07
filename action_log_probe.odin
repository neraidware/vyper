package main

import clay "clay-odin"
import sdl "vendor:sdl3"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Headless action-log roundtrip probe (VYPER_ACTION_LOG_PROBE=<path.vya>).
//
// The recorder's proof has to be a ROUNDTRIP, not a byte check. A log that
// writes a record nobody can play back is not a slow feature, it is a file
// that silently eats an action, and every failure of that looks like "the repro
// didn't reproduce". So this records a scripted session through the live poll
// path, then replays the file it just wrote through the same
// dispatch_sdl_event, and compares what the app looks like after each phase.
//
// The window size is fixed here for the same reason the recording carries one:
// the pointer coordinates in a log only mean something against the layout they
// were captured with, and the replay asserts on it.

ACTION_LOG_PROBE_WIDTH  :: 1920
ACTION_LOG_PROBE_HEIGHT :: 1600
ACTION_LOG_PROBE_FRAMES :: 6
// Long enough that a replay never has to catch up, short enough not to pad the
// gate's runtime.
ACTION_LOG_PROBE_DT_NS  :: 1_000_000
// A path only, never opened: DROP_POSITION carries the payload and the handler
// ignores it, so this proves the string survives the roundtrip without the probe
// depending on a media file.
DROP_PROBE_PATH :: "/tmp/opencode/live/x.mp4"

// Action_Log_Probe_State is what this probe compares across the two phases.
// Every field is something the scripted events are supposed to move, so a field
// that comes back different names the record that failed to survive.
// The cmdline is copied into a fixed buffer rather than kept as a string view:
// text_input_string() returns a view over ti.buf, which the reset between the
// two phases clears and reallocates, so a kept view reads freed memory.
CMDLINE_PROBE_MAX :: 32

Action_Log_Probe_State :: struct {
	cmdline:         [CMDLINE_PROBE_MAX]u8,
	cmdline_len:     int,
	cmdline_open:    bool,
	space_press:     bool,
	space_release:   bool,
	drop_open:       bool,
	drop_x, drop_y:  f32,
	mouse_x, mouse_y: f32,
	mouse_bits:      u32,
}

action_log_probe_failed := false

action_log_probe_check :: proc(ok: bool, what: string, args: ..any) {
	if ok {
		return
	}
	fmt.eprintf("[action-log-probe] FAIL: ")
	fmt.eprintf(what, ..args)
	fmt.eprintf("\n")
	action_log_probe_failed = true
}

action_log_probe_push_key :: proc(k: sdl.Keycode, mods: sdl.Keymod, down: bool) {
	ev: sdl.Event
	ev.type = down ? .KEY_DOWN : .KEY_UP
	ev.key.key = k
	ev.key.mod = mods
	ev.key.down = down
	ev.key.repeat = false
	action_log_probe_check(sdl.PushEvent(&ev), "SDL_PushEvent failed for key %v", k)
}

// action_log_probe_push_text hands SDL a NUL-terminated copy and returns it.
// SDL_PushEvent copies the event struct but not the string it points at, so the
// bytes have to outlive the push AND the dispatch that reads them on the next
// poll -- which is exactly the span between this call and the free at the end of
// action_log_probe_script. Returning the buffer is what makes that span visible
// instead of leaking it.
action_log_probe_push_text :: proc(text: string) -> cstring {
	buf := strings.clone_to_cstring(text)
	ev: sdl.Event
	ev.type = .TEXT_INPUT
	ev.text.text = buf
	action_log_probe_check(sdl.PushEvent(&ev), "SDL_PushEvent failed for text %q", text)
	return buf
}

// Returns the owned payload for the caller to free after the dispatch. Same
// lifetime as push_text's: SDL copies the event, not the string, and
// handle_file_drop_event must not free it either (see dnd.odin).
action_log_probe_push_drop :: proc(
	kind: sdl.EventType,
	x, y: f32,
	path: string,
) -> cstring {
	ev: sdl.Event
	ev.type = kind
	ev.drop.x = x
	ev.drop.y = y
	owned: cstring = nil
	if path != "" {
		owned = strings.clone_to_cstring(path)
		ev.drop.data = owned
	}
	action_log_probe_check(sdl.PushEvent(&ev), "SDL_PushEvent failed for drop %v", kind)
	return owned
}

action_log_probe_push_wheel :: proc(x, y: f32) {
	ev: sdl.Event
	ev.type = .MOUSE_WHEEL
	ev.wheel.x = 0
	ev.wheel.y = y
	// handle_mouse_wheel picks its scroll zone from the pointer the wheel
	// arrived at, which is the field this record has to survive.
	ev.wheel.mouse_x = x
	ev.wheel.mouse_y = 0
	ev.wheel.direction = .NORMAL
	action_log_probe_check(sdl.PushEvent(&ev), "SDL_PushEvent failed for wheel")
}

// action_log_probe_observe samples everything the scripted events should have
// moved. The key edges are drain-scoped, so this has to run right after the
// dispatch that produced them.
action_log_probe_observe :: proc(st: ^Action_Log_Probe_State) {
	mouse := action_replaying() ? action_replay_mouse_input() : read_mouse_input()
	cmdline := text_input_string()
	st^ = Action_Log_Probe_State {
		cmdline_open  = ti.active,
		space_press   = key_press(sdl.K_SPACE),
		space_release = key_release(sdl.K_SPACE),
		drop_open     = file_drag.active,
		drop_x        = file_drag.mx,
		drop_y        = file_drag.my,
		mouse_x       = mouse.x,
		mouse_y       = mouse.y,
		mouse_bits    = action_mouse_bits(mouse),
	}
	st.cmdline_len = min(len(cmdline), CMDLINE_PROBE_MAX - 1)
	copy(st.cmdline[:st.cmdline_len], cmdline[:st.cmdline_len])
}

action_log_probe_equal :: proc(got, want: ^Action_Log_Probe_State, frame: int) {
	action_log_probe_check(
		got.cmdline_len == want.cmdline_len &&
			mem.compare(got.cmdline[:got.cmdline_len], want.cmdline[:want.cmdline_len]) == 0,
		"frame %d: cmdline %q, want %q",
		frame,
		got.cmdline[:got.cmdline_len],
		want.cmdline[:want.cmdline_len],
	)
	action_log_probe_check(
		got.cmdline_open == want.cmdline_open,
		"frame %d: cmdline_open %v, want %v",
		frame,
		got.cmdline_open,
		want.cmdline_open,
	)
	action_log_probe_check(
		got.space_press == want.space_press,
		"frame %d: space_press %v, want %v",
		frame,
		got.space_press,
		want.space_press,
	)
	action_log_probe_check(
		got.space_release == want.space_release,
		"frame %d: space_release %v, want %v",
		frame,
		got.space_release,
		want.space_release,
	)
	action_log_probe_check(
		got.drop_open == want.drop_open,
		"frame %d: drop_open %v, want %v",
		frame,
		got.drop_open,
		want.drop_open,
	)
	action_log_probe_check(
		got.drop_x == want.drop_x && got.drop_y == want.drop_y,
		"frame %d: drop at %v,%v, want %v,%v",
		frame,
		got.drop_x,
		got.drop_y,
		want.drop_x,
		want.drop_y,
	)
	action_log_probe_check(
		got.mouse_x == want.mouse_x &&
			got.mouse_y == want.mouse_y &&
			got.mouse_bits == want.mouse_bits,
		"frame %d: mouse %v,%v bits %#x, want %v,%v bits %#x",
		frame,
		got.mouse_x,
		got.mouse_y,
		got.mouse_bits,
		want.mouse_x,
		want.mouse_y,
		want.mouse_bits,
	)
}

// action_log_probe_script pushes one frame's worth of input. The key pairs go
// down and up inside a single frame on purpose: that leaves kbd.held clear
// afterwards, so the replay phase meets the same held state the record phase
// did and its replayed KEY_DOWN reads as a fresh press, not an auto-repeat.
action_log_probe_script :: proc(frame: int, mouse: Mouse_Input) {
	// Pushed strings live from the push until the dispatch below has read them,
	// then go. Collecting them here keeps that span in one place instead of
	// leaking per frame.
	owned: [2]cstring
	owned_n := 0
	running := true
	switch frame {
	case 0:
		// Modifiers have to survive: mods_have is the only thing between a
		// recorded Ctrl+Space and a binding that never fires.
		action_log_probe_push_key(sdl.K_SPACE, sdl.Keymod{sdl.KeymodFlag.LCTRL}, true)
		action_log_probe_push_key(sdl.K_SPACE, sdl.Keymod{sdl.KeymodFlag.LCTRL}, false)
	case 1:
		// On a US layout ":" is Shift+";", which is the opener the app's
		// K_SEMICOLON branch exists for.
		action_log_probe_push_key(sdl.K_SEMICOLON, sdl.Keymod{sdl.KeymodFlag.LSHIFT}, true)
		action_log_probe_push_key(sdl.K_SEMICOLON, sdl.Keymod{sdl.KeymodFlag.LSHIFT}, false)
	case 2:
		owned[owned_n] = action_log_probe_push_text("ab")
		owned_n += 1
	case 3:
		action_log_probe_push_drop(.DROP_BEGIN, 0, 0, "")
		owned[owned_n] = action_log_probe_push_drop(.DROP_POSITION, 640, 480, DROP_PROBE_PATH)
		owned_n += 1
	case 4:
		action_log_probe_push_drop(.DROP_COMPLETE, 0, 0, "")
	case 5:
		action_log_probe_push_wheel(640, 100)
	}
	handle_sdl_events(&running)
	for buf in owned[:owned_n] {
		delete(buf)
	}
	action_record_mouse(mouse)
	action_record_frame_end(ACTION_LOG_PROBE_DT_NS)
}

action_log_probe_frame_mouse :: proc(frame: int) -> Mouse_Input {
	// A distinct position per frame, so a replay that replayed the PREVIOUS
	// frame's pointer differs rather than coincidentally matching.
	base := f32(frame) * 37
	return Mouse_Input {
		x     = 100 + base,
		y     = 200 + base,
		left  = frame % 2 == 1,
		shift = frame % 3 == 0,
	}
}

// action_log_probe_reset puts the observable state back to what the record
// phase started from. Without this the comparison below is really comparing two
// different sessions, and the replayed opener key would be swallowed by a
// command line the record phase left open.
action_log_probe_reset :: proc() {
	text_input_cancel()
	ti.active = false
	file_drag = {}
	kbd = {}
}

action_log_probe_clay_error :: proc "c" (data: clay.ErrorData) {
}

action_log_probe_init_clay :: proc() {
	// build_page routes the wheel and the drop zones off the laid-out geometry,
	// and clay has no arena or dimensions until it is initialized -- asking for
	// layout without this dereferences null inside Clay_SetLayoutDimensions.
	CLAY_ARENA_BYTES :: 64 * 1024 * 1024
	memory := make([^]u8, CLAY_ARENA_BYTES)
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(c.size_t(CLAY_ARENA_BYTES), memory),
		{ACTION_LOG_PROBE_WIDTH, ACTION_LOG_PROBE_HEIGHT},
		{handler = action_log_probe_clay_error},
	)
	clay.SetMeasureTextFunction(measure_probe, nil)
}

action_log_probe_run :: proc() -> int {
	probe_path := os.get_env_alloc("VYPER_ACTION_LOG_PROBE", context.allocator)
	if probe_path == "" {
		fmt.eprintf("[action-log-probe] set VYPER_ACTION_LOG_PROBE=<path.vya> to the log to write\n")
		return 1
	}
	defer delete(probe_path)
	action_log_window(ACTION_LOG_PROBE_WIDTH, ACTION_LOG_PROBE_HEIGHT)
	// SDL_PushEvent has no queue to push onto until the event subsystem is up,
	// and this probe runs before the window exists, so nothing has brought it
	// up yet.
	action_log_probe_check(sdl.Init(sdl.INIT_EVENTS), "the event queue must come up to drive a session")
	action_log_probe_init_clay()
	build_page(ACTION_LOG_PROBE_WIDTH, ACTION_LOG_PROBE_HEIGHT)

	// RECORD
	action_rec_open(probe_path)
	action_log_probe_check(action_rec.f != nil, "the recorder did not open %q", probe_path)
	action_log_capture_session()
	want: [ACTION_LOG_PROBE_FRAMES]Action_Log_Probe_State
	for frame in 0 ..< ACTION_LOG_PROBE_FRAMES {
		mouse := action_log_probe_frame_mouse(frame)
		action_log_probe_script(frame, mouse)
		got: Action_Log_Probe_State
		action_log_probe_observe(&got)
		// The pointer this frame was handed is the definition of what the MOUSE
		// record holds -- read_mouse_input would answer the headless probe's real
		// cursor, which is not what is being recorded. The write is still checked:
		// the replay reads it back out of the file.
		got.mouse_x = mouse.x
		got.mouse_y = mouse.y
		got.mouse_bits = action_mouse_bits(mouse)
		want[frame] = got
	}
	action_rec_close()
	action_log_probe_check(action_rec.f == nil, "the recorder did not close")

	// REPLAY
	action_log_probe_reset()
	action_log_probe_check(action_play_open(probe_path), "the log %q did not open for replay", probe_path)
	if action_log_probe_failed {
		return 1
	}
	for frame in 0 ..< ACTION_LOG_PROBE_FRAMES {
		running := true
		handle_sdl_events(&running)
		got: Action_Log_Probe_State
		action_log_probe_observe(&got)
		action_log_probe_equal(&got, &want[frame], frame)
	}
	// One more frame to consume the end of the log: a file that ends exactly on a
	// frame boundary is the recording finishing, not a truncation.
	running := true
	handle_sdl_events(&running)
	action_log_probe_check(!action_replaying(), "the replay did not finish at the end of the log")
	action_log_probe_check(!action_play.failed, "a complete log reported a failure")
	action_play_free()

	// TRUNCATION: a log cut mid-record must stop the replay loudly rather than
	// run a session missing its tail.
	full, ferr := os.read_entire_file(probe_path, context.allocator)
	action_log_probe_check(ferr == nil, "could not read the log back: %v", ferr)
	defer delete(full)
	trunc_path: [1024]u8
	truncated := fmt.bprintf(trunc_path[:], "%s.trunc", probe_path)
	defer os.remove(truncated)
	action_log_probe_check(
		os.write_entire_file(truncated, full[:len(full) - 6]) == nil,
		"could not write the truncated log",
	)
	action_log_probe_reset()
	action_log_probe_check(action_play_open(truncated), "the truncated log did not open")
	if action_log_probe_failed {
		return 1
	}
	// The header and the snapshot survive a 6-byte cut, so the replay starts
	// cleanly and then dies on the first record it cannot finish reading.
	for _ in 0 ..< ACTION_LOG_PROBE_FRAMES + 1 {
		if !action_replaying() {
			break
		}
		running := true
		handle_sdl_events(&running)
	}
	action_log_probe_check(!action_replaying(), "a truncated log replayed without stopping")
	action_log_probe_check(action_play.failed, "a truncated log did not report a failure")
	action_play_free()

	if action_log_probe_failed {
		return 1
	}
	fmt.printf(
		"[action-log-probe] ok: %d frames round-tripped, truncation refused\n",
		ACTION_LOG_PROBE_FRAMES,
	)
	return 0
}