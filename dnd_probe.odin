package main

import "core:c"
import "core:fmt"
import "core:os"
import clay "clay-odin"
import sdl "vendor:sdl3"

// OS file drag-and-drop probe (VYPER_DND_PROBE).
//
// Dragging a file in from the desktop used to do NOTHING: the app polled SDL
// events and handled six of them, none of them the five drop kinds. The feature
// was absent on every platform and nothing failed, because ignoring events is
// not a crash -- which is exactly why it needs a probe rather than a report.
//
// A probe cannot synthesise a cross-process desktop drag, so this covers the
// decisions a drop makes after delivery:
//
//   - which region a point means, against the REAL laid-out panels (a bin box
//     that is in fact hit-testable, dead space that is in fact refused, and the
//     empty timeline that is in fact a valid target), plus the box arithmetic
//     for the states a real layout cannot be put into (zero-area panels, a
//     pre-layout frame, box edges)
//   - what the bin will hold: a text file and a vanished path are refused
//     instead of becoming an empty bin row
//   - the gesture state across BEGIN/POSITION/COMPLETE, so a stale position or
//     a highlight that outlives its gesture cannot leak into the next drag
//
// The placement itself is not probed: it is the same two calls the bin drag
// makes (import_path_to_bin + add_asset_to_timeline) by construction rather
// than by agreement, which is the reason the drop path shares them.

dnd_probe_fail := false

dnd_probe_clay_error :: proc "c" (data: clay.ErrorData) {
}

dnd_probe_check :: proc(cond: bool, msg: string, args: ..any) {
	if !cond {
		dnd_probe_fail = true
		line := fmt.tprintf(msg, ..args)
		fmt.println("[dnd-probe] FAIL", line)
	}
}

// One panel box for the arithmetic cases a laid-out session cannot be put
// into: a pre-layout frame, where every element reports zeroed geometry. The
// degenerate box is the load-bearing one -- a drop can arrive before the first
// build_page, and nothing may answer for an element that does not exist yet.
DND_PROBE_BIN: clay.BoundingBox: {x = 0, y = 0, width = 300, height = 600}
DND_PROBE_ZERO: clay.BoundingBox: {x = 0, y = 0, width = 0, height = 0}

// A degenerate box rejects itself: the bounds are half-open, so `mx >= x` with
// `mx < x + 0` has no solution. That is the property a pre-layout frame depends
// on, and it is arithmetic rather than a guard clause, so a mutation that drops
// a width check here changes nothing and is not one this test needs to catch.
test_drop_box_hit_rejects_zero_area :: proc() {
	dnd_probe_check(!drop_box_hit(0, 0, DND_PROBE_ZERO), "a zero-area box must never accept a drop")
	dnd_probe_check(
		!drop_box_hit(10, 10, clay.BoundingBox{x = 0, y = 0, width = 0, height = 600}),
		"a zero-width box must not accept a drop",
	)
	dnd_probe_check(
		!drop_box_hit(10, 10, clay.BoundingBox{x = 0, y = 0, width = 300, height = 0}),
		"a zero-height box must not accept a drop",
	)
	dnd_probe_check(
		!drop_box_hit(0, 0, DND_PROBE_ZERO),
		"a zero-area box must not accept its own origin",
	)
}

// Half-open on the far edges: the point ON a box's right/bottom edge belongs to
// the neighbour, so a drop at the seam does not land in two zones.
test_drop_box_hit_is_half_open :: proc() {
	dnd_probe_check(drop_box_hit(0, 0, DND_PROBE_BIN), "the box origin is inside")
	dnd_probe_check(!drop_box_hit(300, 100, DND_PROBE_BIN), "the box's right edge belongs to the neighbour")
	dnd_probe_check(!drop_box_hit(100, 600, DND_PROBE_BIN), "the box's bottom edge belongs to the neighbour")
	dnd_probe_check(!drop_box_hit(-1, 100, DND_PROBE_BIN), "a point left of the box is outside")
}

// The same routing, against the layout the app really produces. This is what
// catches a drop zone wired to an element id the UI does not have: every
// synthetic box above would still pass while a real drop on the bin landed on
// nothing. build_page runs without a display or GPU.
test_drop_zone_live_layout :: proc() {
	_ = build_page(WINDOW_WIDTH, WINDOW_HEIGHT)

	bin := media_bin_box()
	dnd_probe_check(
		bin.width > 0 && bin.height > 0,
		"the media bin panel reported no area after layout (%gx%g)",
		bin.width,
		bin.height,
	)
	bin_mid := clay.BoundingBox{x = bin.x + bin.width / 2, y = bin.y + bin.height / 2}
	dnd_probe_check(
		drop_zone_at(bin_mid.x, bin_mid.y) == .Media_Bin,
		"the middle of the laid-out bin must accept files, got %v",
		drop_zone_at(bin_mid.x, bin_mid.y),
	)

	empty := clay.GetElementData(clay.ID("EmptyTimeline")).boundingBox
	dnd_probe_check(
		empty.width > 0 && empty.height > 0,
		"the empty-timeline drop area reported no area after layout (%gx%g)",
		empty.width,
		empty.height,
	)
	empty_mid := clay.BoundingBox{x = empty.x + empty.width / 2, y = empty.y + empty.height / 2}
	// With no tracks, a drop over the empty timeline IS the append target -- the
	// same lane timeline_drop_target returns to a bin drag released here.
	dnd_probe_check(
		timeline_drop_target(empty_mid.x, empty_mid.y) >= 0,
		"the empty timeline must be a valid drop lane, got %d",
		timeline_drop_target(empty_mid.x, empty_mid.y),
	)
	dnd_probe_check(
		drop_zone_at(empty_mid.x, empty_mid.y) == .Timeline,
		"a drop on the empty timeline must place, got %v",
		drop_zone_at(empty_mid.x, empty_mid.y),
	)

	// The preview sits above both panels; nothing there accepts files.
	dnd_probe_check(
		drop_zone_at(f32(WINDOW_WIDTH) / 2, f32(WINDOW_HEIGHT) / 4) == .None,
		"the preview area must refuse files, got %v",
		drop_zone_at(f32(WINDOW_WIDTH) / 2, f32(WINDOW_HEIGHT) / 4),
	)

	// The property the whole feature is specified by, swept over the window:
	// a point that a bin drag would place on the timeline MUST also accept an OS
	// drop, and a point it would refuse MUST also refuse one. Both directions
	// matter -- the first version of drop_zone_at tested the timeline PANEL's
	// box, so it refused every drop on an empty timeline that the bin drag
	// accepts, and both of these counts would have shown it.
	// Every 4th pixel: enough to sweep every panel edge and every lane row, and
	// the bin/timeline boundary is at least a pixel wide, so no seam is stepped
	// over entirely.
	GRID_STEP :: 4
	places, refusals := 0, 0
	for gy in 0 ..< WINDOW_HEIGHT {
		for gx in 0 ..< WINDOW_WIDTH {
			if gx % GRID_STEP != 0 || gy % GRID_STEP != 0 {
				continue
			}
			px, py := f32(gx), f32(gy)
			bin_accepts := drop_box_hit(px, py, bin)
			lane_valid := timeline_drop_target(px, py) >= 0
			zone := drop_zone_at(px, py)
			if zone == .Timeline {
				places += 1
			}
			if zone == .None {
				refusals += 1
			}
			if !bin_accepts {
				dnd_probe_check(
					(zone == .Timeline) == lane_valid,
					"at %g,%g the bin drag lane says %v but an OS drop says %v",
					px,
					py,
					lane_valid,
					zone,
				)
			}
		}
	}
	dnd_probe_check(places > 0, "no point on the window accepted a timeline drop")
	dnd_probe_check(refusals > 0, "no point on the window refused a drop")
}

// "Decodable or readable media" is one decision, and it is the gate a dropped
// file passes before anything touches the bin.
test_import_gate_refuses_unreadable :: proc() {
	dir := "/tmp/opencode/dnd_probe"
	os.remove_all(dir)
	os.make_directory(dir)

	// import_path_to_bin takes a cstring and a string carries no promise of a
	// trailing NUL, so both fixtures are fixed buffers with a real terminator.
	text_path := fmt.aprintf("%s/notes.txt", dir)
	text_buf: [256]byte
	text_buf[copy(text_buf[:], text_path)] = 0
	text_cstr := transmute(cstring)(&text_buf[0])
	if err := os.write_entire_file(text_path, "not media"); err != nil {
		fmt.eprintf("[dnd-probe] could not seed the text fixture: %v\n", err)
		dnd_probe_fail = true
	}
	delete(text_path)

	missing := fmt.aprintf("%s/gone.mp4", dir)
	missing_buf: [256]byte
	missing_buf[copy(missing_buf[:], missing)] = 0
	missing_cstr := transmute(cstring)(&missing_buf[0])
	delete(missing)

	before := len(media_bin.assets)
	dnd_probe_check(
		import_path_to_bin(text_cstr) == 0,
		"a text file is not media and must not enter the bin",
	)
	dnd_probe_check(
		import_path_to_bin(missing_cstr) == 0,
		"a path that does not exist must not enter the bin",
	)
	dnd_probe_check(
		len(media_bin.assets) == before,
		"a refused drop left %d bin rows behind",
		len(media_bin.assets) - before,
	)
	os.remove_all(dir)
}

// The gesture's own state. has_position is the load-bearing field: a backend
// that never sends DROP_POSITION (the Wayland xdg-foreign path can) must not be
// handed the PREVIOUS drag's coordinates for the release that commits it.
test_drop_event_state :: proc() {
	file_drag = {}

	begin := sdl.Event{}
	begin.type = .DROP_BEGIN
	handle_file_drop_event(begin)
	dnd_probe_check(file_drag.active, "DROP_BEGIN must arm the drag")
	dnd_probe_check(!file_drag.has_position, "DROP_BEGIN must not claim a position")

	// A position from the FIRST drag, dropped on the laid-out bin.
	bin := media_bin_box()
	first := sdl.Event{}
	first.type = .DROP_POSITION
	first.drop.x = bin.x + bin.width / 2
	first.drop.y = bin.y + bin.height / 2
	handle_file_drop_event(first)
	dnd_probe_check(file_drag.has_position, "DROP_POSITION must record a position")
	dnd_probe_check(file_drag.zone == .Media_Bin, "a position over the bin must highlight the bin, got %v", file_drag.zone)
	mx, my := file_drag_point()
	dnd_probe_check(
		mx == first.drop.x && my == first.drop.y,
		"a recorded position must be what a release lands on, got %g,%g",
		mx,
		my,
	)

	// ...must not survive into the next one.
	handle_file_drop_event(begin)
	dnd_probe_check(
		!file_drag.has_position,
		"a second DROP_BEGIN must forget the previous drag's position",
	)
	dnd_probe_check(file_drag.zone == .None, "a bare BEGIN must clear a stale highlight, got %v", file_drag.zone)

	// COMPLETE is the only thing that ends a gesture; without it the highlight
	// would stay lit over the panel after the files were already imported.
	handle_file_drop_event(first)
	done := sdl.Event{}
	done.type = .DROP_COMPLETE
	handle_file_drop_event(done)
	dnd_probe_check(!file_drag.active, "DROP_COMPLETE must disarm the drag")
	dnd_probe_check(
		file_drag == (File_Drag{}),
		"DROP_COMPLETE must clear the whole gesture state, got %+v",
		file_drag,
	)

	// DROP_TEXT is routed here on purpose and must change nothing.
	text := sdl.Event{}
	text.type = .DROP_TEXT
	handle_file_drop_event(text)
	dnd_probe_check(file_drag == (File_Drag{}), "a text drag must not arm a file drag")

	file_drag = {}
}

dnd_probe_run :: proc() {
	// clay must be initialized before any element data is read: drop routing
	// resolves the bin and lane boxes out of the layout, and a GetElementData
	// on an uninitialized context is an invalid read, not a zero box.
	CLAY_ARENA_BYTES :: 64 * 1024 * 1024
	memory := make([^]u8, CLAY_ARENA_BYTES)
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(c.size_t(CLAY_ARENA_BYTES), memory),
		{WINDOW_WIDTH, WINDOW_HEIGHT},
		{handler = dnd_probe_clay_error},
	)
	clay.SetMeasureTextFunction(measure_probe, nil)

	test_drop_box_hit_rejects_zero_area()
	test_drop_box_hit_is_half_open()
	test_drop_zone_live_layout()
	test_import_gate_refuses_unreadable()
	test_drop_event_state()

	if dnd_probe_fail {
		fmt.println("[dnd-probe] FAILED")
		os.exit(1)
	}
	fmt.println("[dnd-probe] all checks passed")
	os.exit(0)
}