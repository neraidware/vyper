package vyper

import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Actions: what a key MEANS, separated from which key produced it.
//
// The shortcut table used to be a `switch event.key.key` inline in the poll
// loop, so answering "what does Ctrl+Space do" meant reading control flow, and
// adding a remappable key meant editing a branch. Here the answer is a row.
//
// This is deliberately NOT a remapping system yet: the table is fixed, there
// is no UI to edit it and nothing persists it. It exists so that the mapping is
// data rather than control flow — which is the thing that has to change first
// before a future editor's keys (word motion, kill/yank) can be bound the same
// way, and before any of it can be remapped without touching a switch.
//
// Continuous controls (jog/shuttle) are deliberately absent: they are rates
// driven by key repeat, not discrete presses, and pretending otherwise would
// put a second, conflicting definition of "held" in the table.
// ---------------------------------------------------------------------------

// Action is the closed set of things a global shortcut can mean. `.None` is
// the zero value so an unresolved key needs no dummy and no parallel bool.
Action :: enum {
	None,
	Open_Command_Line,
	Toggle_Help,
	Undo,
	Redo,
	Toggle_Playback,
	Play_Project_Area,
	Split_At_Playhead,
	Begin_Rename,
	Toggle_Links,
	Delete_At_Playhead,
	Delete_Selection,
	Key_All_Modified,
	Toggle_Auto_Keyframe,
	Set_In_Point,
	Set_Out_Point,
}

Binding :: struct {
	action: Action,
	key:    sdl.Keycode,
	// mods is the set of modifiers that must ALL be held for this binding to
	// match; extra modifiers are ignored. An empty set therefore means "fires
	// whatever else is held" — which is the pre-table behaviour for the
	// unadorned keys, and is load-bearing: see Split_At_Playhead.
	//
	// The combined masks (KMOD_CTRL and friends) come from SDL itself, so a
	// binding matches Ctrl whether the left or right one was pressed.
	mods: sdl.Keymod,
}

// BINDINGS is ordered MOST SPECIFIC FIRST and action_for takes the first match,
// which is what makes an event that satisfies several bindings resolve to the
// more specific one. Two pairs depend on that ordering: Ctrl+Shift+Z (redo)
// must be tested before Ctrl+Z (undo), and Ctrl+Space (play project area)
// before bare Space (transport toggle). Reordering these changes behaviour.
BINDINGS := [?]Binding {
	// Two input layers, deliberately kept apart:
	//
	//   KEYBINDS are raw. Every action resolves from a keycode and the
	//   modifier mask on the event — never from a text event. A keybind has to
	//   be decidable while no field is open, which a text event is not.
	//   TEXT EDITING is IME-capable. SDL's TEXT_INPUT still drives character
	//   entry, so dead keys and CJK input work inside a field.
	//
	// The `:` opener is the clearest case for the first rule, and the reason is
	// mechanical rather than stylistic: with no field open, text_input_cancel
	// has called StopTextInput, and SDL delivers no TEXT_INPUT at all while
	// text input is stopped. A text-driven opener therefore never fires — it
	// was tried, and reverted (97f5267) with the prompt simply not opening.
	//
	// The cost of keeping both layers is one seam: the opener's keypress can
	// echo a ":" into the field it just opened, and SDL's TEXT_INPUT carries no
	// keycode, so that echo cannot be correlated to its keypress — only guessed
	// at. Hence the drain-scoped suppressor in event.odin. It is a heuristic by
	// necessity, not by choice, and it is the only place the two layers touch.
	// Removing it means deriving characters from keycodes too, which drops IME.
	{ .Open_Command_Line, sdl.K_COLON, {} },
	// On a US layout ":" is Shift+";", so SDL reports the base key with the
	// shift modifier rather than a distinct K_COLON keycode. Requiring shift is
	// what keeps a bare ";" from also opening the prompt.
	{ .Open_Command_Line, sdl.K_SEMICOLON, sdl.KMOD_SHIFT },
	{ .Toggle_Help, sdl.K_F1, {} },
	{ .Redo, sdl.K_Z, sdl.KMOD_CTRL | sdl.KMOD_SHIFT },
	{ .Undo, sdl.K_Z, sdl.KMOD_CTRL },
	{ .Redo, sdl.K_Y, sdl.KMOD_CTRL },
	{ .Play_Project_Area, sdl.K_SPACE, sdl.KMOD_CTRL },
	{ .Toggle_Playback, sdl.K_SPACE, {} },
	{ .Begin_Rename, sdl.K_R, sdl.KMOD_CTRL },
	{ .Split_At_Playhead, sdl.K_S, {} },
	{ .Key_All_Modified, sdl.K_A, {} },
	{ .Toggle_Auto_Keyframe, sdl.K_Q, {} },
	{ .Toggle_Links, sdl.K_U, {} },
	{ .Delete_At_Playhead, sdl.K_BACKSPACE, {} },
	{ .Delete_Selection, sdl.K_DELETE, {} },
	{ .Set_In_Point, sdl.K_I, {} },
	{ .Set_Out_Point, sdl.K_O, {} },
}

// action_for resolves a key event to an action, or .None if unbound. Modifiers
// must be the ones the EVENT carried, never sdl.GetModState(): the event
// snapshots what was held at key-down, the global state is sampled at handling
// time, and they diverge whenever the main thread stalls long enough for input
// to queue.
action_for :: proc(key: sdl.Keycode, mods: sdl.Keymod) -> Action {
	for b in BINDINGS {
		if b.key == key && mods_have(mods, b.mods) {
			return b.action
		}
	}
	return .None
}
