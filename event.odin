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
handle_sdl_events :: proc(running: ^bool) {
	event: sdl.Event
	for sdl.PollEvent(&event) {
		#partial switch event.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			running^ = false
		case .KEY_DOWN:
			if ti.active {
				mods := sdl.GetModState()
				shift := sdl.KeymodFlag.LSHIFT in mods || sdl.KeymodFlag.RSHIFT in mods
				ctrl := sdl.KeymodFlag.LCTRL in mods || sdl.KeymodFlag.RCTRL in mods
				r := text_input_handle_key(event.key.key, shift, ctrl)
				if r == .Commit {
					if ti.input_type == TI_PLAYHEAD {
						apply_playhead_time()
					} else {
						apply_rename()
					}
				} else if r == .Cancel {
					if ti.is_create {
						// Aborted a clip-create dialog: drop the clip that was
						// temporarily inserted so no nameless clip remains.
						delete_selected_clip_raw()
						ti.is_create = false
					}
				}
			} else if editing_field != .None {
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
			} else if !event.key.repeat {
				switch event.key.key {
				case sdl.K_F1:
					// Always-available shortcut reference.
					help_open = !help_open
				case sdl.K_Z:
					mods := sdl.GetModState()
					if sdl.KeymodFlag.LCTRL in mods || sdl.KeymodFlag.RCTRL in mods {
						if sdl.KeymodFlag.LSHIFT in mods || sdl.KeymodFlag.RSHIFT in mods {
							undo_redo()
						} else {
							undo_undo()
						}
					}
				case sdl.K_Y:
					mods := sdl.GetModState()
					if sdl.KeymodFlag.LCTRL in mods || sdl.KeymodFlag.RCTRL in mods {
						undo_redo()
					}
				case sdl.K_SPACE:
					mods := sdl.GetModState()
					if sdl.KeymodFlag.LCTRL in mods || sdl.KeymodFlag.RCTRL in mods {
						play_project_area()
					} else {
						toggle_playback()
					}
				case sdl.K_H:
					// Jog backward (mirrors the backward button).
					jog_playback(-1)
				case sdl.K_L:
					// Jog forward (mirrors the forward button).
					jog_playback(1)
				case sdl.K_S:
					split_clip_at_playhead()
				case sdl.K_R:
					// Ctrl+R renames the selected clip.
					mods := sdl.GetModState()
					if sdl.KeymodFlag.LCTRL in mods || sdl.KeymodFlag.RCTRL in mods {
						begin_clip_rename()
					}
				case sdl.K_U:
					// Toggle link state across the selection: a lone clip
					// unlinks its group; several Shift+clicked clips join into
					// one link group (or all split apart when already linked).
					toggle_links_for_selection()
				case sdl.K_BACKSPACE:
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
				case sdl.K_DELETE:
					// Delete the clip raw, nothing else.
					delete_selected_clip_raw()
				case sdl.K_I:
					// Set the render-range start at the playhead; collapsing the
					// range to a single frame clears it.
					project.start_frame = playhead.frame
					if project.end_frame == playhead.frame {
						project.start_frame = -1
						project.end_frame = -1
					}
				case sdl.K_O:
					project.end_frame = playhead.frame
					if project.start_frame == playhead.frame {
						project.start_frame = -1
						project.end_frame = -1
					}
				}
			}
		case .TEXT_INPUT:
			if ti.active {
				text_input_insert(string(event.text.text))
			} else if editing_field != .None {
				for ch in string(event.text.text) {
					// Only accept printable ASCII that makes sense in a number.
					if ch >= '0' && ch <= '9' || ch == '-' || ch == '.' {
						edit_append(u8(ch))
					}
				}
			}
		case .MOUSE_WHEEL:
			// Scroll over the media bin scrolls its active view: the thumbnail
			// grid in the Media Bin view, the undo tree in the Undo Tree view.
			mb := clay.GetElementData(clay.ID("MediaBin")).boundingBox
			if mb.width > 0 && event.wheel.mouse_x >= mb.x && event.wheel.mouse_x <= mb.x + mb.width &&
				event.wheel.mouse_y >= mb.y && event.wheel.mouse_y <= mb.y + mb.height {
				if event.wheel.y != 0 {
					if media_bin_view == .Undo {
						undo_hist.view_scroll = clamp(
							undo_hist.view_scroll - f32(event.wheel.y) * TIMELINE_SCROLL_STEP,
							0,
							undo_view_max_scroll(),
						)
					} else if len(media_assets) > 0 {
						media_bin_scroll = clamp(media_bin_scroll - f32(event.wheel.y) * MEDIA_BIN_SCROLL_STEP, 0, media_bin_max_scroll())
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
					inspector_scroll = clamp(inspector_scroll - f32(event.wheel.y) * TIMELINE_SCROLL_STEP, 0, inspector_max_scroll())
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
					timeline_view_top = clamp(timeline_view_top - f32(event.wheel.y) * TIMELINE_SCROLL_STEP, 0, timeline_tracks_max_top())
					break
				}
			}
			// Scroll over the timeline zooms horizontally, anchored at the playhead.
			tlb := clay.GetElementData(clay.ID("ClipTimeline")).boundingBox
			if len(timeline.tracks) > 0 && event.wheel.mouse_x >= tlb.x && event.wheel.mouse_x <= tlb.x + tlb.width &&
				event.wheel.mouse_y >= tlb.y && event.wheel.mouse_y <= tlb.y + tlb.height {
				if event.wheel.y != 0 {
					ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
					anchor := f32(playhead.frame - i64(timeline_view_start)) * timeline_zoom
					anchor_frame := timeline_view_start + anchor / timeline_zoom
					new_zoom := clamp(timeline_zoom * (1 + 0.1 * event.wheel.y), TIMELINE_MIN_ZOOM, TIMELINE_MAX_ZOOM)
					if new_zoom != timeline_zoom {
						timeline_view_start = anchor_frame - anchor / new_zoom
						timeline_view_start = clamp(timeline_view_start, 0, f32(timeline_duration()))
						timeline_zoom = new_zoom
					}
				}
				break
			}
			// Scroll over the preview zooms the camera, keeping the point under
			// the cursor fixed.
			pb := clay.GetElementData(clay.ID("Preview")).boundingBox
			if event.wheel.mouse_x >= pb.x && event.wheel.mouse_x <= pb.x + pb.width &&
				event.wheel.mouse_y >= pb.y && event.wheel.mouse_y <= pb.y + pb.height {
				if event.wheel.y != 0 {
					canvas := preview_canvas(pb)
					mx_c := event.wheel.mouse_x - (canvas.x + canvas.width / 2)
					my_c := event.wheel.mouse_y - (canvas.y + canvas.height / 2)
					old_zoom := preview_cam_zoom
					new_zoom := clamp(old_zoom * (1 + 0.1 * event.wheel.y), PREVIEW_CAM_MIN_ZOOM, PREVIEW_CAM_MAX_ZOOM)
					if new_zoom != old_zoom {
						// Zooming steers the camera, so the fit toggle releases.
						preview_fit_to_window = false
						// NOTE: cursor-anchored zoom -- the point under the cursor
					// stays put, so pan (preview_cam_ox|oy) scales by the zoom
					// ratio here and only gets clamped later at render time.
					preview_cam_ox = mx_c - (mx_c - preview_cam_ox) * (new_zoom / old_zoom)
						preview_cam_oy = my_c - (my_c - preview_cam_oy) * (new_zoom / old_zoom)
						preview_cam_zoom = new_zoom
					}
				}
			}
		}
	}
}