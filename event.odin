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
			if ti.active {
				// Modifiers come off the event, never sdl.GetModState(): the
				// event snapshots what was held at key-down, the global state
				// is sampled at handling time. They diverge whenever the main
				// thread stalls long enough for events to queue and the user
				// releases or changes a modifier before the queue drains.
				mods := event.key.mod
				shift := sdl.KeymodFlag.LSHIFT in mods || sdl.KeymodFlag.RSHIFT in mods
				ctrl := sdl.KeymodFlag.LCTRL in mods || sdl.KeymodFlag.RCTRL in mods
				// Cmdline match navigation: Tab/arrows move the highlighted
				// row; handled here so the generic text field stays generic.
				if ti.input_type == TI_CMDLINE {
					switch event.key.key {
					case sdl.K_TAB:
						cmdline_match_navigate(shift ? -1 : 1)
						continue
					case sdl.K_UP:
						cmdline_match_navigate(-1)
						continue
					case sdl.K_DOWN:
						cmdline_match_navigate(1)
						continue
					}
				}
				// Finder navigation: Tab/Up/Down move the highlight, Enter
				// descends into the selected directory or opens the selected
				// file — Enter never commits the field (the finder stays open
				// across a descend), so it is handled before the generic
				// commit path. In Save mode the field is a name, so Enter saves
				// that name; the row only picks "commit" over "descend". Esc
				// still cancels through the text field.
				if ti.input_type == TI_FINDER {
					switch event.key.key {
					case sdl.K_TAB:
						finder_navigate(shift ? -1 : 1)
						continue
					case sdl.K_UP:
						finder_navigate(-1)
						continue
					case sdl.K_DOWN:
						finder_navigate(1)
						continue
					case sdl.K_RETURN, sdl.K_RETURN2:
						finder_refresh()
						finder_enter()
						continue
					}
				}
				r := text_input_handle_key(event.key.key, shift, ctrl)
				if r == .Commit {
					if ti.input_type == TI_PLAYHEAD {
						apply_playhead_time()
					} else if ti.input_type == TI_CMDLINE {
						// Rewrites the buffer to `open <highlighted>` when a
						// match row is selected, so the normal command path
						// opens that file; otherwise leaves typed text alone.
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
			} else if edit_state.field != .None {
				switch event.key.key {
				case sdl.K_BACKSPACE:
					edit_backspace()
				case sdl.K_RETURN, sdl.K_RETURN2:
					edit_commit()
				case sdl.K_ESCAPE:
					edit_cancel()
				}
			} else if event.key.key == sdl.K_ESCAPE && !event.key.repeat {
				escape_dismiss()
			} else {
				// Continuous actions run on auto-repeat as well as on the
				// initial press, which is what makes holding a key jog. This
				// branch is reached only when no field owns the key, so a jog
				// can never fire while the user is typing.
				//
				// key_repeat is true only for a DOWN of a key that was already
				// down — the OS auto-repeat event — so this does not double up
				// with the one-shot press handled by the switch below.
				if key_repeat(sdl.K_H) {
					jog_playback(-1)
				}
				if key_repeat(sdl.K_L) {
					jog_playback(1)
				}
				if !event.key.repeat {
					// Every modifier test in this block reads event.key.mod, never
					// sdl.GetModState(). The event snapshots what was held at
					// key-down; the global state is sampled when the event is
					// handled. They diverge whenever the main thread stalls long
					// enough for input to queue and the user changes a modifier
				// before the queue drains — which fires the wrong action, or
				// none. A Shift released in between used to lose the ":"
				// opener outright (the "prompt never opens" symptom).
				switch action_for(event.key.key, event.key.mod) {
				case .None:
				case .Open_Command_Line:
					// Opens empty; the keypress's own text echo is dropped by
					// the suppressor in the TEXT_INPUT branch below.
					text_input_begin("", TI_CMDLINE, 0)
					ti.swallow_char = CMDLINE_OPENER[0]
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
					// Toggle link state across the selection: a lone clip
					// unlinks its group; several Shift+clicked clips join into
					// one link group (or all split apart when already linked).
					toggle_links_for_selection()
				case .Delete_At_Playhead:
					if !delete_selected_keyframe() {
						// Delete the selected clip's timeline area and close the
						// gap (ripple). A linked clip rips the WHOLE group: every
						// member's own span on its own track, so a ripple cut
						// never leaves the partner clip behind (rippling only the
						// selected member's region would strand the rest).
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
					// Set the render-range start at the playhead; collapsing the
					// range to a single frame clears it.
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
				}
			}
			}
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
				swallow := ti.swallow_char
				ti.swallow_char = 0
				if !(swallow != 0 && len(text) > 0 && text[0] == swallow) {
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