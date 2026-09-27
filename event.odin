package main

import clay "clay-odin"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// SDL event handling: keyboard shortcuts, text input routing, and mouse-wheel
// scroll zones. Runs every frame before the mouse-position handling; the raw
// pointer state itself is read by interaction.odin's read_mouse_input.
// ---------------------------------------------------------------------------

// handle_sdl_events drains the SDL event queue: window close, keyboard (text
// fields, then app shortcuts), text input, and wheel scrolling per widget.
// Sets *running = false on a quit/close event. Nothing here depends on the
// current mouse position.
//
// This is the app's ONLY SDL poll site, which is what makes kbd.drain a
// meaningful scope: one call empties the queue, so anything that needs to know
// whether two events arrived in the same burst of input compares drain ids.
handle_sdl_events :: proc(running: ^bool) {
	kbd_begin_drain()
	event: sdl.Event
	for sdl.PollEvent(&event) {
		#partial switch event.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			running^ = false
		case .KEY_UP:
			// The app had no key-up path at all, so "is this key down" was
			// unanswerable and hold-to-repeat could not be told apart from a
			// fresh press. Recorded here and consumed by nobody else: a key
			// release has no meaning to the UI or to the fields.
			kbd_note_key(event.key.key, false)
		case .KEY_DOWN:
			kbd_note_key(event.key.key, true)
			route_key_down(event.key.key, event.key.mod, event.key.repeat)
		case .TEXT_INPUT:
			if ti.active {
				text := string(event.text.text)
				// Drop the swallowed CHARACTER, not merely the next event. A
				// text event always consumes the swallow (one-shot), so a ":"
				// keypress that produced no echo can't leave a pending swallow
				// behind to eat the user's next real keystroke. Matching the
				// character is also what keeps "open C:/foo" working: a ":"
				// typed into an open prompt is data (a Windows drive path),
				// not another opener.
				//
				// The drain check is what makes that true rather than
				// accidental. Without it a swallow armed by an opener that
				// produced no echo stayed armed indefinitely, and the first
				// ":" the user typed as DATA — in `open C:/foo`, a later
				// keystroke, not the opener's echo — was silently eaten. A
				// same-drain text event is the echo; a later one is real input.
				swallow := ti.swallow_char
				same_drain := ti.swallow_drain == kbd.drain
				ti.swallow_char = 0
				if !(swallow != 0 && same_drain && len(text) > 0 && text[0] == swallow) {
					text_input_insert(text)
				}
			} else if edit_state.field != .None {
				for ch in string(event.text.text) {
					// Only accept printable ASCII that makes sense in a number.
					if ch >= '0' && ch <= '9' || ch == '-' || ch == '.' {
						edit_append(u8(ch))
					}
				}
			}
		case .MOUSE_WHEEL:
			// Wheel over the file finder moves its selection (like the cmdline
			// match list): up = earlier rows, down = later.
			fc := clay.GetElementData(clay.ID("FinderColumn")).boundingBox
			if fc.width > 0 && event.wheel.mouse_x >= fc.x && event.wheel.mouse_x <= fc.x + fc.width &&
				event.wheel.mouse_y >= fc.y && event.wheel.mouse_y <= fc.y + fc.height {
				if event.wheel.y != 0 {
					finder_navigate(-int(event.wheel.y))
					break
				}
			}
			// Scroll over the media bin scrolls its active view: the thumbnail
			// grid in the Media Bin view, the undo tree in the Undo Tree view.
			mb := clay.GetElementData(clay.ID("MediaBin")).boundingBox
			if mb.width > 0 && event.wheel.mouse_x >= mb.x && event.wheel.mouse_x <= mb.x + mb.width &&
				event.wheel.mouse_y >= mb.y && event.wheel.mouse_y <= mb.y + mb.height {
				if event.wheel.y != 0 {
					if panel_views.media_bin_view == .Undo {
						undo_hist.view_scroll = clamp(
							undo_hist.view_scroll - f32(event.wheel.y) * TIMELINE_SCROLL_STEP,
							0,
							undo_view_max_scroll(),
						)
					} else if len(media_bin.assets) > 0 {
						panel_views.media_bin_scroll = clamp(panel_views.media_bin_scroll - f32(event.wheel.y) * MEDIA_BIN_SCROLL_STEP, 0, media_bin_max_scroll())
					}
					break
				}
			}
			// Scroll over the inspector column scrolls its card stack when
			// the cards outgrow the viewport.
			ic := clay.GetElementData(clay.ID("InspectorColumn")).boundingBox
			if ic.height > 0 && event.wheel.mouse_x >= ic.x && event.wheel.mouse_x <= ic.x + ic.width &&
				event.wheel.mouse_y >= ic.y && event.wheel.mouse_y <= ic.y + ic.height {
				if event.wheel.y != 0 {
					scrollbars.inspector.offset = clamp(scrollbars.inspector.offset - f32(event.wheel.y) * TIMELINE_SCROLL_STEP, 0, inspector_max_scroll())
					break
				}
			}
			// Vertical wheel over the track LANES (and the scrollbar strip
			// beside them) scrolls the track list, exactly like the media
			// bin. The ruler strip above still zooms on wheel.
			ta := clay.GetElementData(clay.ID("TrackArea")).boundingBox
			if ta.height > 0 && event.wheel.mouse_x >= ta.x && event.wheel.mouse_x <= ta.x + ta.width &&
				event.wheel.mouse_y >= ta.y && event.wheel.mouse_y <= ta.y + ta.height {
				if event.wheel.y != 0 {
					timeline_view.top = clamp(timeline_view.top - f32(event.wheel.y) * TIMELINE_SCROLL_STEP, 0, timeline_tracks_max_top())
					break
				}
			}
			// Scroll over the timeline zooms horizontally, anchored at the playhead.
			tlb := clay.GetElementData(clay.ID("ClipTimeline")).boundingBox
			if len(timeline.tracks) > 0 && event.wheel.mouse_x >= tlb.x && event.wheel.mouse_x <= tlb.x + tlb.width &&
				event.wheel.mouse_y >= tlb.y && event.wheel.mouse_y <= tlb.y + tlb.height {
				if event.wheel.y != 0 {
					ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
					anchor := f32(playhead.frame - i64(timeline_view.start)) * timeline_view.zoom
					anchor_frame := timeline_view.start + anchor / timeline_view.zoom
					new_zoom := clamp(timeline_view.zoom * (1 + 0.1 * event.wheel.y), TIMELINE_MIN_ZOOM, TIMELINE_MAX_ZOOM)
					if new_zoom != timeline_view.zoom {
						timeline_view.start = anchor_frame - anchor / new_zoom
						timeline_view.start = clamp(timeline_view.start, 0, f32(timeline_duration()))
						timeline_view.zoom = new_zoom
					}
				}
				break
			}
			// Alt+Scroll over the preview crop-zooms the selected clip: the clip's
			// source window magnifies about the box center while the visible box
			// stays put, committed as one "Zoom clip" undo node per wheel event.
			pb := clay.GetElementData(clay.ID("Preview")).boundingBox
			if event.wheel.mouse_x >= pb.x && event.wheel.mouse_x <= pb.x + pb.width &&
				event.wheel.mouse_y >= pb.y && event.wheel.mouse_y <= pb.y + pb.height {
				if event.wheel.y != 0 {
					// The one deliberate exception to "modifiers off the
					// event": SDL's MouseWheelEvent carries no `mod` field at
					// all (see vendor:sdl3 KeyboardEvent, which has one, and
					// MouseWheelEvent, which does not), so there is nothing to
					// read but the live state. Do not "fix" this to match the
					// key handlers — it is not the same situation.
					mods := sdl.GetModState()
					if sdl.KeymodFlag.LALT in mods || sdl.KeymodFlag.RALT in mods {
						if sel, ok := transformable_selected(); ok && sel.kind != .Text {
							factor := 1 + 0.1 * event.wheel.y
							if crop_viewport_zoom(sel, factor, false) {
								undo_begin()
								crop_viewport_zoom(sel, factor, true)
								undo_push(.Transform, "Zoom clip")
							}
							break
						}
					}
					// Scroll over the preview zooms the camera, keeping the point under
					// the cursor fixed.
					canvas := preview_canvas(pb)
					mx_c := event.wheel.mouse_x - (canvas.x + canvas.width / 2)
					my_c := event.wheel.mouse_y - (canvas.y + canvas.height / 2)
					old_zoom := preview_cam.zoom
					new_zoom := clamp(old_zoom * (1 + 0.1 * event.wheel.y), PREVIEW_CAM_MIN_ZOOM, PREVIEW_CAM_MAX_ZOOM)
					if new_zoom != old_zoom {
						// Zooming steers the camera, so the fit toggle releases.
						preview_cam.fit_to_window = false
						// NOTE: cursor-anchored zoom -- the point under the cursor
					// stays put, so pan (preview_cam.ox|oy) scales by the zoom
					// ratio here and only gets clamped later at render time.
					preview_cam.ox = mx_c - (mx_c - preview_cam.ox) * (new_zoom / old_zoom)
						preview_cam.oy = my_c - (my_c - preview_cam.oy) * (new_zoom / old_zoom)
						preview_cam.zoom = new_zoom
					}
				}
			}
		}
	}
}
// ---------------------------------------------------------------------------
// Key routing: one entry point, ordered owners, one place that says who gets
// a key first.
//
// The order IS the policy, so it is written down once here instead of being
// implied by the nesting depth of an if/else chain:
//
//	1. the text field (ti.active)
//	2. the playhead/number field (edit_state.field)
//	3. the app — global shortcuts and continuous controls
//
// Each owner returns whether it CLAIMED the key, and a claimed key stops
// travelling. That is what makes "the field ate the opener's own echo" a
// property of the structure rather than something a suppressor has to clean up
// afterwards: there is one path to the app layer, and a field is on it.
// ---------------------------------------------------------------------------

route_key_down :: proc(key: sdl.Keycode, mods: sdl.Keymod, repeat: bool) -> bool {
	if field_claims_key(key, mods) {
		return true
	}
	if edit_field_claims_key(key) {
		return true
	}
	return app_claims_key(key, mods, repeat)
}

// field_claims_key handles a key while a text field has focus.
//
// It claims EVERY key, not merely the ones it acts on. That is the
// pre-existing behaviour and it is preserved deliberately: the old if/else had
// no exit from this branch, so with the prompt open a shortcut key such as "u"
// did nothing instead of falling through to toggle links. Letting unhandled
// keys reach the app is arguably the better behaviour, but it is a behaviour
// CHANGE, and this pass is a refactor — it is a one-line edit here once
// someone decides they want it.
field_claims_key :: proc(key: sdl.Keycode, mods: sdl.Keymod) -> bool {
	if !ti.active {
		return false
	}
	// Modifiers come off the event, never sdl.GetModState(): the event
	// snapshots what was held at key-down, the global state is sampled at
	// handling time. They diverge whenever the main thread stalls long enough
	// for events to queue and the user releases or changes a modifier before
	// the queue drains.
	shift := sdl.KeymodFlag.LSHIFT in mods || sdl.KeymodFlag.RSHIFT in mods
	ctrl := sdl.KeymodFlag.LCTRL in mods || sdl.KeymodFlag.RCTRL in mods
	// Cmdline match navigation: Tab/arrows move the highlighted row; handled
	// here so the generic text field stays generic.
	if ti.input_type == TI_CMDLINE {
		switch key {
		case sdl.K_TAB:
			cmdline_match_navigate(shift ? -1 : 1)
			return true
		case sdl.K_UP:
			cmdline_match_navigate(-1)
			return true
		case sdl.K_DOWN:
			cmdline_match_navigate(1)
			return true
		}
	}
	// Finder navigation: Tab/Up/Down move the highlight, Enter descends into
	// the selected directory or opens the selected file — Enter never commits
	// the field (the finder stays open across a descend), so it is handled
	// before the generic commit path. In Save mode the field is a name, so
	// Enter saves that name; the row only picks "commit" over "descend". Esc
	// still cancels through the text field.
	if ti.input_type == TI_FINDER {
		switch key {
		case sdl.K_TAB:
			finder_navigate(shift ? -1 : 1)
			return true
		case sdl.K_UP:
			finder_navigate(-1)
			return true
		case sdl.K_DOWN:
			finder_navigate(1)
			return true
		case sdl.K_RETURN, sdl.K_RETURN2:
			finder_refresh()
			finder_enter()
			return true
		}
	}
	r := text_input_handle_key(key, shift, ctrl)
	if r == .Commit {
		if ti.input_type == TI_PLAYHEAD {
			apply_playhead_time()
		} else if ti.input_type == TI_CMDLINE {
			// Rewrites the buffer to `open <highlighted>` when a match row is
			// selected, so the normal command path opens that file; otherwise
			// leaves typed text alone.
			cmdline_match_apply_selection()
			apply_command()
		} else {
			apply_rename()
		}
	} else if r == .Cancel {
		if ti.input_type == TI_FINDER {
			// Esc dismissed the finder's filter field.
			finder_close()
		} else if ti.is_create {
			// Aborted a clip-create dialog: drop the clip that was
			// temporarily inserted so no nameless clip remains.
			delete_selected_clip_raw()
			ti.is_create = false
		}
	}
	return true
}

// edit_field_claims_key handles the inline playhead/number field. Unlike the
// text field it does NOT swallow the keyboard: it takes three keys and passes
// the rest down to the app, so a shortcut still works while the playhead is
// being typed into. That asymmetry is pre-existing and intentional — a number
// field is a single digit you nudge, not a document you type into.
edit_field_claims_key :: proc(key: sdl.Keycode) -> bool {
	// sdl.Keycode is a distinct integer, not an enum, so this switch has
	// neither a `default` clause (that is a `when` construct in Odin) nor
	// `#partial` (that needs an enum): an unmatched key just falls out. Hence
	// the flag — the switch alone cannot report whether it matched.
	claimed := false
	switch key {
	case sdl.K_BACKSPACE:
		edit_backspace()
		claimed = true
	case sdl.K_RETURN, sdl.K_RETURN2:
		edit_commit()
		claimed = true
	case sdl.K_ESCAPE:
		edit_cancel()
		claimed = true
	}
	return claimed
}

// app_claims_key is the last owner: global shortcuts plus the continuous
// controls. Reached only when no field took the key.
app_claims_key :: proc(key: sdl.Keycode, mods: sdl.Keymod, repeat: bool) -> bool {
	if key == sdl.K_ESCAPE && !repeat {
		escape_dismiss()
		return true
	}
	claimed := false
	// Continuous actions run on the initial press AND on auto-repeat, which is
	// what makes shuttle work: a tap nudges one step, holding it keeps
	// nudging. key_down_now covers both halves — key_press alone would move
	// only on the tap, key_repeat alone only while held.
	if key_down_now(sdl.K_H) {
		jog_playback(-1)
		claimed = true
	}
	if key_down_now(sdl.K_L) {
		jog_playback(1)
		claimed = true
	}
	// A bound action fires on the initial press only. Gating on the event's
	// repeat flag rather than on key_press() keeps this identical to the
	// pre-router code; the two agree for a real key press, and the event flag
	// is what the old branch tested.
	if repeat {
		return claimed
	}
	act := action_for(key, mods)
	if act == .None {
		return claimed
	}
	dispatch_action(act)
	return true
}

dispatch_action :: proc(act: Action) {
	switch act {
	case .Open_Command_Line:
		// Opens empty; the keypress's own text echo is dropped by the
		// suppressor in the TEXT_INPUT branch. The drain is recorded so the
		// suppression covers this keypress's echo and nothing else.
		text_input_begin("", TI_CMDLINE, 0)
		ti.swallow_char = CMDLINE_OPENER[0]
		ti.swallow_drain = kbd.drain
	case .Toggle_Help:
		// Always-available shortcut reference.
		editor_flags.help_open = !editor_flags.help_open
	case .Undo:
		undo_undo()
	case .Redo:
		undo_redo()
	case .Toggle_Playback:
		toggle_playback()
	case .Play_Project_Area:
		play_project_area()
	case .Begin_Rename:
		begin_clip_rename()
	case .Split_At_Playhead:
		split_clip_at_playhead()
	case .Toggle_Links:
		// Toggle link state across the selection: a lone clip unlinks its
		// group; several Shift+clicked clips join into one link group (or all
		// split apart when already linked).
		toggle_links_for_selection()
	case .Delete_At_Playhead:
		if !delete_selected_keyframe() {
			// Delete the selected clip's timeline area and close the gap
			// (ripple). A linked clip rips the WHOLE group: every member's own
			// span on its own track, so a ripple cut never leaves the partner
			// clip behind (rippling only the selected member's region would
			// strand the rest).
			if tr, clip, ok := selected_clip(); ok {
				if clip.link_id != 0 {
					ripple_delete_linked_group(clip.link_id)
				} else {
					ripple_delete_region(clip.timeline_start_frame, clip.source_length_frames)
				}
			}
		}
	case .Delete_Selection:
		if !delete_selected_keyframe() {
			// Delete the clip raw, nothing else.
			delete_selected_clip_raw()
		}
	case .Set_In_Point:
		// Set the render-range start at the playhead; collapsing the range to
		// a single frame clears it.
		project.start_frame = playhead.frame
		if project.end_frame == playhead.frame {
			project.start_frame = -1
			project.end_frame = -1
		}
	case .Set_Out_Point:
		project.end_frame = playhead.frame
		if project.start_frame == playhead.frame {
			project.start_frame = -1
			project.end_frame = -1
		}
	case .None:
	}
}
