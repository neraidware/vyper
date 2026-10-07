package main

import clay "clay-odin"
import sdl "vendor:sdl3"
import "core:fmt"
import "core:math"
import "core:os"
import "core:c"
import "core:strconv"
import "core:strings"
import "core:sync"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	// Randomised action harness over a REAL project. Everything goes through the same
	// entry points the frame loop uses -- clay pointer state, interaction_click_dispatch,
	// interaction_move, interaction_release, playback_update, interaction_post_build --
	// because a harness that pokes state directly tests a state the app never enters,
	// which is how the probes in this repo went wrong four times before Active 37.
	//
	// The point is not to assert a feature. It is to reach states a person would not
	// deliberately build -- scrub backwards while playing, at a zoom where the ruler maps
	// most of a long timeline off-screen, immediately after an edit, at the last frame --
	// and then assert the invariants that must hold at EVERY tick regardless of what the
	// user did:
	//
	//   - the playhead is inside the timeline (a negative or absurd frame is the shape a
	//     bad drag or a bad seek takes, and it is visible as a frozen or blank editor);
	//   - the playhead and the view transform are finite;
	//   - selection indices address a track/clip that exists;
	//   - the track and clip counts never move backwards except through undo.
	//
	// It cannot assert the absence of an SDL assertion, because SDL writes to stderr and
	// keeps going. The GATE does that: it greps this probe's output for "Assertion
	// failure", which is how the user found the scissor bug -- a rect exceeding the render
	// target, reported twice, with no visible symptom at all.
	//
	// VYPER_FUZZ="<project.vyproj>|<iters>|<seed>"
	//
	// Deterministic in the seed, so a finding is a command someone else can run.

	Fuzz_State :: struct {
		seed:  u64,
		rng:   u64,
		iters: int,
		// Tracks the high-water mark of edits seen, so a count that SHRINKS is only
		// legal immediately after an undo.
		last_tracks: int,
		last_clips:  int,
		// Action counters. A fuzz run that reaches nothing reports zero failures just as
		// loudly as a clean one, so the harness has to prove it EXERCISED the paths, not
		// merely survive them. A run where scrubs_armed is zero is a broken harness.
		armed:    int,
		moved:    int,
		plays:    int,
		jogs:     int,
		zooms:    int,
		selects:  int,
		undos:    int,
		speeds:   int,
		// The largest jump the playhead made in ONE tick during a drag, and the
		// largest the pointer asked for. A scrub that moves the playhead further than
		// the pointer asked is the "jumping everywhere" symptom, and this is where it
		// becomes a number instead of a vibe.
		max_jump:      i64,
		max_asked:     i64,
		// How often a release moved the playhead FORWARD, and by how much at worst.
		// This is the reported symptom verbatim ("jumps forward when I let go").
		release_snaps:    int,
		max_release_snap: i64,
		playing_ticks:    int,
		// The producer's own view of whether audio was live, so a run over a project
		// with audio cannot quietly pass without ever provisioning a source.
		saw_audio_src: bool,
	}

	// fuzz_next is a splitmix64: a fixed, named PRNG rather than whatever the runtime
	// hands us, because a failing iteration has to be replayable from its seed alone.
	fuzz_next :: proc(f: ^Fuzz_State) -> u64 {
		f.rng += 0x9E3779B97F4A7C15
		z := f.rng
		z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
		z = (z ~ (z >> 27)) * 0x94D049BB133111EB
		return z ~ (z >> 31)
	}

	fuzz_range :: proc(f: ^Fuzz_State, lo, hi: i64) -> i64 {
		if hi <= lo {
			return lo
		}
		return lo + i64(fuzz_next(f) % u64(hi - lo))
	}

	// FUZZ_VIEW_W / FUZZ_VIEW_H are the viewport the harness lays out at. The clay arena
	// and every build_page call must agree on them: brought up at WINDOW_WIDTH x
	// WINDOW_HEIGHT while build_page was called at 1920 x 1600, the layout disagreed with
	// itself about where the ruler is, which is a plausible way to make every press miss
	// it and silently arm nothing.
	FUZZ_VIEW_W :: 1920
	FUZZ_VIEW_H :: 1600

	// fuzz_inp is the mouse state the CURRENT action is holding, and it is what
	// interaction_post_build is handed. It has to be the same input interaction_move got:
	// passing a zeroed input while a gesture is in flight reads as "no button held", and
	// the post-build step cancels the gesture before the next move sees it. That is what
	// the first version did, and it is why `armed` was non-zero while `moved` was exactly
	// zero -- the press armed the scrub and the very next tick cancelled it.
	fuzz_inp: Mouse_Input

	// fuzz_tick runs ONE frame of the real loop, in the real order. The order is the
	// thing under test: a scrub writes the playhead in interaction_post_build and
	// playback_update reads the device clock immediately after, so a harness that runs
	// them in the other order cannot see the disagreement that made the playhead
	// undraggable.
	fuzz_tick :: proc() {
		_, _ = interaction_post_build(fuzz_inp, false, false, FUZZ_VIEW_H)
		playback_update(sdl.Uint64(monotonic_ns()))
		audio_update()
	}

	fuzz_finite :: proc(v: f64) -> bool {
		return !(math.is_nan(v) || math.is_inf(v))
	}

	// fuzz_check_invariants asserts what must hold at every tick. Returns a message
	// describing the first violation, or "" when the tick is clean.
	fuzz_check_invariants :: proc(f: ^Fuzz_State, step: int, action: string) -> string {
		dur := timeline_duration()
		if playhead.frame < -1 {
			return fmt.aprintf(
				"step %d (%s): playhead.frame=%d is negative (timeline is %d frames)",
				step, action, playhead.frame, dur,
			)
		}
		// +2 frames of slack: a drag is allowed to land on the frame AFTER the end when
		// it is clamped there, and the auto-stop clamps to stop_frame-1.
		if dur > 0 && playhead.frame > dur + 2 {
			return fmt.aprintf(
				"step %d (%s): playhead.frame=%d is %d frames past the %d-frame timeline",
				step, action, playhead.frame, playhead.frame - dur, dur,
			)
		}
		if !fuzz_finite(f64(playhead.frame)) {
			return fmt.aprintf("step %d (%s): playhead.frame is not finite", step, action)
		}
		if !fuzz_finite(f64(timeline_view.zoom)) || timeline_view.zoom <= 0 {
			return fmt.aprintf(
				"step %d (%s): timeline_view.zoom=%v (must be finite and > 0)",
				step, action, timeline_view.zoom,
			)
		}
		if !fuzz_finite(f64(timeline_view.start)) {
			return fmt.aprintf(
				"step %d (%s): timeline_view.start=%v is not finite",
				step, action, timeline_view.start,
			)
		}
		// Selection must address something that exists, or a later action dereferences it.
		if selection.track >= len(timeline.tracks) || selection.track < -1 {
			return fmt.aprintf(
				"step %d (%s): selection.track=%d with %d tracks",
				step, action, selection.track, len(timeline.tracks),
			)
		}
		if selection.track >= 0 && selection.track < len(timeline.tracks) {
			tr := &timeline.tracks[selection.track]
			if selection.index >= len(tr.clips) || selection.index < -1 {
				return fmt.aprintf(
					"step %d (%s): selection.index=%d with %d clips on track %d",
					step, action, selection.index, len(tr.clips), selection.track,
				)
			}
		}
		// Counts only ever grow, except straight after an undo.
		clips := 0
		for tr in timeline.tracks {
			clips += len(tr.clips)
		}
		if clips > f.last_clips || len(timeline.tracks) > f.last_tracks {
			f.last_clips, f.last_tracks = clips, len(timeline.tracks)
		}
		return ""
	}

	// visible_frame_span is how many frames the ruler can currently show. Every scrub
	// target is drawn from this, never from timeline_duration().
	visible_frame_span :: proc() -> i64 {
		ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
		if ruler.width <= 0 || timeline_view.zoom <= 0 {
			return 1
		}
		return max(1, i64(f64(ruler.width) / f64(timeline_view.zoom)))
	}

	fuzz_px_for_frame :: proc(frame: i64) -> f32 {
		ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
		return ruler.x + (f32(frame) - timeline_view.start) * timeline_view.zoom
	}

	// fuzz_scrub runs a whole press/drag/drag/release gesture on the ruler, the gesture
	// the user reported most, and the one with the most state behind it: the playhead is
	// written by the pointer while the device clock is republished every tick.
	fuzz_scrub :: proc(f: ^Fuzz_State, frame: i64, steps: int) {
		ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
		if ruler.width <= 0 || timeline_view.zoom <= 0 {
			return
		}
		ry := ruler.y + ruler.height * 0.5
		dur := max(0, timeline_duration())
		// The press has to land ON the ruler, and the ruler only shows the frames the
		// current zoom maps into it. Choosing a target from the whole timeline is what
		// made the first version of this harness arm NOTHING on a 359k-frame project:
		// every candidate frame mapped far off the right edge, the press missed, and the
		// run reported zero failures while exercising no scrub at all.
		visible := i64(f64(ruler.width) / f64(timeline_view.zoom))
		lo := i64(timeline_view.start)
		hi := lo + max(1, visible)
		lo = clamp(lo, 0, dur)
		hi = clamp(hi, lo + 1, dur + 1)
		start := clamp(frame, lo, hi - 1)
		x0 := fuzz_px_for_frame(start)
		if x0 < ruler.x || x0 > ruler.x + ruler.width {
			return
		}
		fuzz_inp = Mouse_Input{x0, ry, true, false, false, false, false, false}
		clay.SetPointerState({x0, ry}, true)
		interaction_click_dispatch(
				Mouse_Input{x0, ry, true, false, false, false, false, false},
			false,
		)
		if active_interaction != .Playhead_Scrub {
			clay.SetPointerState({x0, ry}, false)
			return
		}
		f.armed += 1
		before := playhead.frame
		fuzz_tick()
		at := start
		for _ in 0 ..< steps {
			// Each drag step can be a big jump in EITHER direction, including past the
			// ends, which is what the clamp and the boundary stop have to survive.
			at = clamp(at + fuzz_range(f, -drag_step(), drag_step()), 0, max(0, timeline_duration() + 30))
			x := fuzz_px_for_frame(at)
			fuzz_inp = Mouse_Input{x, ry, true, false, false, false, false, false}
			clay.SetPointerState({x, ry}, true)
			interaction_move(
				Mouse_Input{x, ry, true, false, false, false, false, false},
				true,
				1600,
			)
			fuzz_tick()
			asked := abs(at - before)
			if playhead.frame != before {
				f.moved += 1
			}
			if playhead.playing {
				f.playing_ticks += 1
			}
			// "Jumping everywhere" as a number: how far the playhead moved in one tick
			// MINUS how far the pointer asked it to move. Positive means something with
			// authority to move the playhead overruled the pointer, which is the defect
			// the device-clock guards exist to prevent.
			//
			// It has to be measured BEFORE `before` is advanced, and against the pointer's
			// own request rather than an absolute jump size -- a legitimate fast drag moves
			// the playhead a long way, and only the DIFFERENCE from what was asked for is
			// wrong.
			if over := abs(playhead.frame - before) - asked; over > f.max_jump {
				f.max_jump = over
			}
			before = playhead.frame
		}
		x := fuzz_px_for_frame(at)
		// Buttons up for the release and for every tick after it, so the post-build step
		// sees a finished gesture rather than a held one.
		fuzz_inp = Mouse_Input{x, ry, false, false, false, false, false, false}
		clay.SetPointerState({x, ry}, false)
		pre_release := playhead.frame
		interaction_release(Mouse_Input{x, ry, false, false, false, false, false, false})
		active_interaction = .None
		fuzz_tick()
		// The user's reported symptom exactly: the playhead jumping FORWARD once the
		// gesture ends. Counted separately because it is the one that reads as a bug to a
		// person -- a drag that looks fine and then snaps when you let go.
		if over := playhead.frame - pre_release; over > 0 {
			f.release_snaps += 1
			if over > f.max_release_snap {
				f.max_release_snap = over
			}
		}
	}

	// drag_step is how far ONE drag tick may travel, in frames. It is bounded by the
	// VISIBLE span rather than the whole timeline, so a drag stays a drag at any zoom: a
	// step sized to the timeline is off-screen in one click at a low zoom, which is how a
	// scrub stops being a scrub.
	drag_step :: proc() -> i64 {
		ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
		visible := i64(f64(max(1.0, ruler.width)) / f64(max(0.0001, f64(timeline_view.zoom))))
		return max(2, visible / 6)
	}

	// fuzz_playback toggles the transport, which is the other half of the state machine:
	// run/stop changes what the producer reconciles and whether the device clock is
	// consulted at all.
	fuzz_playback :: proc(f: ^Fuzz_State) {
		f.plays += 1
		if playhead.playing {
			playhead.playing = false
			preview.playing = false
			audio_prod.was_playing = false
		} else {
			playback.dir = 1
			playhead.playing = true
			preview.playing = true
			sync.atomic_store(&playback.dev_frame, playhead.frame)
			sync.atomic_store(&playback.dev_resync, sync.atomic_load(&audio_prod.resync))
		}
		fuzz_tick()
		fuzz_tick()
	}

	// fuzz_jog flips the transport direction, which takes the OTHER playback_update
	// branch: backward has no device clock and runs on the wall clock instead.
	fuzz_jog :: proc(f: ^Fuzz_State) {
		f.jogs += 1
		playback.dir = -1 if fuzz_next(f) & 1 == 1 else 1
		playhead.playing = true
		preview.playing = true
		sync.atomic_store(&playback.dev_frame, playhead.frame)
		sync.atomic_store(&playback.dev_resync, sync.atomic_load(&audio_prod.resync))
		fuzz_tick()
		fuzz_tick()
		playback.dir = 1
	}

	// fuzz_zoom moves the view transform across its whole range. Zoom is what decides
	// whether a frame is on screen, and a frame the pointer cannot name is a frame a drag
	// cannot reach -- so zoom and scrub are exercised together on purpose.
	fuzz_zoom :: proc(f: ^Fuzz_State) {
		f.zooms += 1
		z := f64(fuzz_range(f, 1, 4000)) / 1000.0
		timeline_view.zoom = f32(max(0.0001, z))
		// Keep the view inside the timeline so later px_for_frame calls stay meaningful.
		span := i64(f64(WINDOW_WIDTH) / f64(timeline_view.zoom))
		dur := max(1, timeline_duration())
		if span < dur {
			timeline_view.start = f32(fuzz_next(f) % u64(dur - span + 1))
		} else {
			timeline_view.start = 0
		}
		build_page(FUZZ_VIEW_W, FUZZ_VIEW_H)
		fuzz_tick()
	}

	// fuzz_select picks a real clip, so later actions that use the selection have
	// something to act on rather than the -1/-1 empty case.
	fuzz_select :: proc(f: ^Fuzz_State) {
		if len(timeline.tracks) == 0 {
			return
		}
		f.selects += 1
		ti := int(fuzz_range(f, 0, i64(len(timeline.tracks))))
		tr := &timeline.tracks[ti]
		if len(tr.clips) == 0 {
			selection.track, selection.index = ti, -1
			return
		}
		selection.track = ti
		selection.index = int(fuzz_range(f, 0, i64(len(tr.clips))))
		sync_track_order()
		fuzz_tick()
	}

	// fuzz_undo walks the undo stack, which is the only legal way the track/clip counts
	// shrink. Exercised because a bad undo is a dangling pointer in every later action.
	fuzz_undo :: proc(f: ^Fuzz_State) {
		f.undos += 1
		undo_redo()
		fuzz_tick()
		fuzz_tick()
	}

	// fuzz_rate picks a transport rate, including the sub-1x values the UI does not offer
	// but VYPER_RATE can set -- the clamp at audio.odin's want_ratio means those are not
	// honoured, and reaching them here is deliberate rather than accidental.
	fuzz_rate :: proc(f: ^Fuzz_State) {
		rates := []f64{1, 1.5, 2, 4, 0.5, 0.75}
		playback.rate = rates[int(fuzz_next(f) % u64(len(rates)))]
		fuzz_tick()
		fuzz_tick()
	}

	// fuzz_clip_speed retimes the selected clip, which forces the reconcile to rebuild a
	// tempo graph and re-anchor content mid-playback -- the path Active 36 built and the
	// one with the most arithmetic in it.
	fuzz_clip_speed :: proc(f: ^Fuzz_State) {
		if selection.track < 0 || selection.track >= len(timeline.tracks) {
			return
		}
		tr := &timeline.tracks[selection.track]
		if selection.index < 0 || selection.index >= len(tr.clips) {
			return
		}
		f.speeds += 1
		speeds := []f64{1, 0.5, 0.25, 1.5, 2, 4}
		s := speeds[int(fuzz_next(f) % u64(len(speeds)))]
		tr.clips[selection.index].speed = s
		audio_geometry_commit()
		fuzz_tick()
		fuzz_tick()
	}

	fuzz_probe_run :: proc(v: string) {
		parts := strings.split(v, "|")
		if len(parts) < 1 {
			fmt.println("fuzz: need VYPER_FUZZ=\"<project.vyproj>|<iters>|<seed>\"")
			os.exit(2)
		}
		path := strings.trim_space(parts[0])
		iters := 400
		if len(parts) >= 2 {
			if n, ok2 := strconv.parse_int(strings.trim_space(parts[1])); ok2 && n > 0 {
				iters = int(n)
			}
		}
		seed: u64 = 0x5A17
		if len(parts) >= 3 {
			if n, ok2 := strconv.parse_u64(strings.trim_space(parts[2])); ok2 {
				seed = n
			}
		}

		// Clay first. Every VYPER_* probe is dispatched BEFORE main()'s clay.Initialize,
		// so anything that calls build_page has to bring its own layout up -- build_page
		// reaches Clay_SetLayoutDimensions and segfaults without this. Measured: the first
		// version of this harness died in Clay_SetLayoutDimensions on iteration 0, which
		// is the harness's bug and not the app's.
		clay_fuzz_error :: proc "c" (data: clay.ErrorData) {}
		CLAY_ARENA_BYTES :: 64 * 1024 * 1024
		clay_memory := make([^]u8, CLAY_ARENA_BYTES)
		clay.Initialize(
			clay.CreateArenaWithCapacityAndMemory(c.size_t(CLAY_ARENA_BYTES), clay_memory),
			{FUZZ_VIEW_W, FUZZ_VIEW_H},
			{handler = clay_fuzz_error},
		)
		clay.SetMeasureTextFunction(measure_probe, nil)

		// Audio up BEFORE the project loads, and for the same reason as Clay: this probe
		// is dispatched before main()'s audio_init, so without it there is no device, the
		// producer thread returns immediately (audio_producer_proc's first line), and
		// NOTHING in the audio engine is ever reached. Measured: the project carries 85
		// audio clips on 5 of its 7 tracks and the producer held no source for the whole
		// run -- which would have made "no audio bugs found" a statement about a harness
		// that never played audio.
		// The audio engine's anomaly detector runs alongside the randomised actions, so a
		// REPEAT / JUMP / DESYNC caused by scrubbing -- the reported trigger -- is named at
		// the tick it happens instead of having to be inferred afterwards. Read here because
		// probes dispatch before main() sets it.
		repro_trace = os.get_env_alloc("VYPER_REPRO_TRACE", context.temp_allocator) == "1"
		if repro_trace {
			fmt.println("[fuzz] repro trace ON -- REPEAT/JUMP/DESYNC will be reported by the producer thread")
		}

		audio_up := audio_init()
		have_device := audio_device_ready()
		if have_device {
			fmt.println("[fuzz] audio device up -- the producer thread runs, audio is in scope")
		} else {
			fmt.println(
				"[fuzz] NO AUDIO DEVICE -- the transport and the draw code are in scope, the audio engine is NOT (this machine has no output device)",
			)
		}

		if err := project_file_open(path); err != "" {
			fmt.printf("[fuzz] FAIL: project load: %s\n", err)
			os.exit(1)
		}
		clips := 0
		for tr in timeline.tracks {
			clips += len(tr.clips)
		}
		fmt.printf(
			"[fuzz] loaded %q: %d tracks, %d clips, %d frames, %.2f fps\n",
			path,
			len(timeline.tracks),
			clips,
			timeline_duration(),
			timeline_fps(),
		)
		// What KIND each track is, and whether there is audio at all. A run over a
		// video-only project exercises the transport and the draw code and never touches
		// the audio engine, so "no audio bugs found" would mean nothing. Printed so that
		// claim can be checked rather than assumed.
		n_audio, n_video, n_text, n_sub := 0, 0, 0, 0
		for ti in 0 ..< len(timeline.tracks) {
			n := len(timeline.tracks[ti].clips)
			for ci in 0 ..< n {
				#partial switch timeline.tracks[ti].clips[ci].kind {
				case .Audio:
					n_audio += 1
				case .Video:
					n_video += 1
				case .Text:
					n_text += 1
				case .Subtitles:
					n_sub += 1
				}
			}
		}
		tracks_with_audio := 0
		for ti in 0 ..< len(timeline.tracks) {
			n := len(timeline.tracks[ti].clips)
			for ci in 0 ..< n {
				if timeline.tracks[ti].clips[ci].kind == .Audio {
					tracks_with_audio += 1
					break
				}
			}
		}
		fmt.printf(
			"[fuzz] clips by kind: audio=%d video=%d text=%d subtitles=%d; tracks carrying audio=%d/%d\n",
			n_audio,
			n_video,
			n_text,
			n_sub,
			tracks_with_audio,
			len(timeline.tracks),
		)
		has_audio := n_audio > 0
		if len(timeline.tracks) == 0 {
			fmt.println("[fuzz] FAIL: project loaded with no tracks -- nothing to exercise")
			os.exit(1)
		}

		editor_flags.snap_playhead_to_clips = false
		playhead.playing = false
		fuzz_inp = Mouse_Input{0, 0, false, false, false, false, false, false}
		build_page(FUZZ_VIEW_W, FUZZ_VIEW_H)

		f: Fuzz_State
		f.seed = seed
		// Seed the PRNG FROM the seed, so iteration 1 differs between seeds.
		f.rng = seed * 0x2545F4914F6CDD1D
		f.last_tracks = len(timeline.tracks)
		f.last_clips = clips

		// Weighted toward scrubbing and transport, because that is where the reported
		// faults live (playhead vs device clock). The edit actions are rarer because
		// they change the timeline out from under everything else.
		actions := []string{
			"scrub", "scrub", "scrub", "scrub", "scrub_back",
			"play", "jog", "zoom", "select",
			"undo", "rate", "speed",
		}

		failures := 0
		for step in 0 ..< iters {
			name := actions[int(fuzz_next(&f) % u64(len(actions)))]
			switch name {
			case "scrub":
				// Forward-biased, and deliberately landing past the end sometimes.
				fuzz_scrub(&f, fuzz_range(&f, 0, max(1, visible_frame_span())), int(fuzz_range(&f, 1, 12)))
			case "scrub_back":
				fuzz_scrub(&f, fuzz_range(&f, 0, max(1, visible_frame_span())), int(fuzz_range(&f, 1, 8)))
				// And again immediately, playing: the state the user reported.
				if step % 3 == 0 {
					fuzz_playback(&f)
					fuzz_scrub(&f, fuzz_range(&f, 0, max(1, visible_frame_span())), int(fuzz_range(&f, 2, 10)))
				}
			case "play":
				fuzz_playback(&f)
			case "jog":
				fuzz_jog(&f)
			case "zoom":
				fuzz_zoom(&f)
			case "select":
				fuzz_select(&f)
			case "undo":
				fuzz_undo(&f)
			case "rate":
				fuzz_rate(&f)
			case "speed":
				fuzz_clip_speed(&f)
			}
			fuzz_tick()
			if sync.atomic_load(&audio_prod.prod_frame) != 0 || audio_src.count > 0 {
				f.saw_audio_src = true
			}
			if msg := fuzz_check_invariants(&f, step, name); msg != "" {
				fmt.printf("[fuzz] FAIL: %s\n", msg)
				failures += 1
				// Keep going: the FIRST violation is the interesting one, but a later
				// one may be the same defect seen from another action, and stopping
				// would hide that.
				if failures >= 8 {
					break
				}
			}
		}
		fmt.printf(
			"[fuzz] %d iterations seed=%d: armed=%d moved=%d plays=%d jogs=%d zooms=%d selects=%d undos=%d speeds=%d playing_ticks=%d over_pointer=%d release_snaps=%d max_release_snap=%d\n",
			iters, seed,
			f.armed, f.moved, f.plays, f.jogs, f.zooms, f.selects, f.undos, f.speeds,
			f.playing_ticks, f.max_jump, f.release_snaps, f.max_release_snap,
		)
		if failures > 0 {
			os.exit(1)
		}
		// A RUN THAT REACHED NOTHING IS A FAILURE, not a pass. Every counter below is a
		// path the harness exists to reach; a zero means the harness is broken (a press
		// that no longer arms the scrub, a renamed entry point, a layout that moved the
		// ruler) and every other number in this run is then vacuous. This check is the
		// reason the earlier clean runs could be trusted: they were clean AND they moved.
		if f.armed == 0 {
			fmt.println("[fuzz] FAIL: no scrub ever armed -- the ruler press path is unreachable, so this run proves nothing")
			os.exit(1)
		}
		if f.moved == 0 {
			fmt.println("[fuzz] FAIL: no scrub ever moved the playhead")
			os.exit(1)
		}
		if f.plays == 0 || f.jogs == 0 {
			fmt.println("[fuzz] FAIL: transport actions never ran (plays/jogs)")
			os.exit(1)
		}
		if f.playing_ticks == 0 {
			fmt.println("[fuzz] FAIL: no tick ran while playing -- the device-clock path was never exercised")
			os.exit(1)
		}
		if repro_trace {
			repro_summary()
		}
		if has_audio && have_device && !f.saw_audio_src {
			fmt.println(
				"[fuzz] FAIL: the project has audio clips but the producer never held a source -- the audio path was never exercised, so this run proves nothing about it",
			)
			os.exit(1)
		}
		// A release that moves the playhead forward is the reported defect, so it is a
		// failure here and not a number to look at. dcee40b fixed it for one clip; this is
		// the check that says it is still fixed on a 103-clip project.
		if f.max_release_snap > 0 {
			fmt.printf(
				"[fuzz] FAIL: %d release(s) moved the playhead FORWARD, worst +%d frames\n",
				f.release_snaps,
				f.max_release_snap,
			)
			os.exit(1)
		}
		if f.max_jump > 0 {
			fmt.printf(
				"[fuzz] FAIL: the playhead moved %d frames further than the pointer asked, mid-drag\n",
				f.max_jump,
			)
			os.exit(1)
		}
		fmt.println("[fuzz] ok (playhead in range, transforms finite, selection addressable, paths exercised)")
		os.exit(0)
	}
}
