package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import clay "clay-odin"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Entry point: window/device/pipeline setup, the SDL event loop (input
// dispatch, drag-state machine, playback tick), and the per-frame render.
// ---------------------------------------------------------------------------

main :: proc() {
	if test_path_ok, test_paths := render_test_env(); test_path_ok {
		render_test_run(test_paths)
		return
	}
	if !load_font_data() {
		return
	}
	if !sdl.Init(sdl.INIT_VIDEO | sdl.INIT_AUDIO) {
		fmt.println("SDL initialization failed")
		return
	}
	defer sdl.Quit()

	window := sdl.CreateWindow("nered", WINDOW_WIDTH, WINDOW_HEIGHT, {.RESIZABLE, .VULKAN})
	if window == nil {
		fmt.println("Could not create nered window")
		return
	}
	defer sdl.DestroyWindow(window)
	app_window = window

	device := sdl.CreateGPUDevice({.SPIRV}, true, "vulkan")
	if device == nil {
		fmt.println("Could not create SDL GPU device")
		return
	}
	defer sdl.DestroyGPUDevice(device)
	if !sdl.ClaimWindowForGPUDevice(device, window) {
		fmt.println("Could not claim window for SDL GPU device")
		return
	}
	defer sdl.ReleaseWindowFromGPUDevice(device, window)
	format := sdl.GetGPUSwapchainTextureFormat(device, window)
	if format == .INVALID {
		fmt.println("Could not get GPU swapchain format")
		return
	}
	if !sdl.SetGPUSwapchainParameters(device, window, .SDR, .VSYNC) {
		fmt.println("Could not configure GPU swapchain")
		return
	}
	renderer, ok := create_gpu_renderer(device, format, WINDOW_WIDTH, WINDOW_HEIGHT)
	if !ok {
		fmt.println("Could not create rounded rectangle GPU pipeline")
		return
	}
	defer sdl.ReleaseGPUGraphicsPipeline(device, renderer.pipeline)
	defer sdl.ReleaseGPUGraphicsPipeline(device, renderer.text_pipeline)
	defer sdl.ReleaseGPUGraphicsPipeline(device, renderer.preview_pipeline)
	defer sdl.ReleaseGPUTexture(device, renderer.font.texture)
	defer sdl.ReleaseGPUSampler(device, renderer.font.sampler)
	defer release_preview_textures(device, renderer.preview_textures[:])
	defer sdl.ReleaseGPUSampler(device, renderer.preview_sampler)
	initial_upload := sdl.AcquireGPUCommandBuffer(device)
	if initial_upload == nil || !upload_font_atlas(&renderer, initial_upload) || !sdl.SubmitGPUCommandBuffer(initial_upload) {
		fmt.println("Could not upload font atlas:", sdl.GetError())
		return
	}

	audio_init()
	defer audio_shutdown()
	async_dec_init()
	defer async_dec_shutdown()
	render_init()

	memory := make([^]u8, clay.MinMemorySize())
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(c.size_t(clay.MinMemorySize()), memory),
		{WINDOW_WIDTH, WINDOW_HEIGHT},
		{handler = clay_error},
	)
	clay.SetMeasureTextFunction(measure_text, nil)

	// DIAG: env-var autoplay for headless-ish diagnostics — autoloads a file and
	// starts playback after a couple of seconds. Removed after diagnosis.
	if autoplay := os.get_env_buf([]u8{}, "NERED_AUTOPLAY"); autoplay != "" {
		import_media(strings.clone_to_cstring(autoplay, context.temp_allocator))
		sdl.Delay(2500)
		playhead.playing = true
		preview.playing = true
		playhead_accumulator = 0
		preview_frontier = playhead.frame
		last_tick_ns = sdl.GetTicksNS()
		audio_note_edit()
	}

	running := true
	was_mouse_down := false
	ui_report_tick := u64(0)
	ui_frame_count := 0
	ui_dec_us := i64(0)
	for running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				running = false
			case .KEY_DOWN:
				if editing_field != 0 {
					switch event.key.key {
					case sdl.K_BACKSPACE:
						edit_backspace()
					case sdl.K_RETURN, sdl.K_RETURN2:
						edit_commit()
					case sdl.K_ESCAPE:
						edit_cancel()
					}
				} else if !event.key.repeat {
					switch event.key.key {
					case sdl.K_S:
						split_clip_at_playhead()
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
				if editing_field != 0 {
					for ch in string(event.text.text) {
						// Only accept printable ASCII that makes sense in a number.
						if ch >= '0' && ch <= '9' || ch == '-' || ch == '.' {
							edit_append(u8(ch))
						}
					}
				}
			case .MOUSE_WHEEL:
				// Scroll over the timeline zooms horizontally, anchored at the cursor.
				tlb := clay.GetElementData(clay.ID("ClipTimeline")).boundingBox
				if len(timeline.tracks) > 0 && event.wheel.mouse_x >= tlb.x && event.wheel.mouse_x <= tlb.x + tlb.width &&
					event.wheel.mouse_y >= tlb.y && event.wheel.mouse_y <= tlb.y + tlb.height {
					if event.wheel.y != 0 {
						ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
						anchor := event.wheel.mouse_x - ruler.x
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
							preview_cam_ox = mx_c - (mx_c - preview_cam_ox) * (new_zoom / old_zoom)
							preview_cam_oy = my_c - (my_c - preview_cam_oy) * (new_zoom / old_zoom)
							preview_cam_zoom = new_zoom
						}
					}
				}
			}
		}

		width, height: c.int
		sdl.GetWindowSize(window, &width, &height)
		mouse_x, mouse_y: f32
		mouse_buttons := sdl.GetMouseState(&mouse_x, &mouse_y)
		mouse_down := sdl.MouseButtonFlag.LEFT in mouse_buttons
		middle_down := sdl.MouseButtonFlag.MIDDLE in mouse_buttons
		mods := sdl.GetModState()
		alt_down := sdl.KeymodFlag.LALT in mods || sdl.KeymodFlag.RALT in mods

		// Middle-button drag over the preview pans the camera (limited to ±one
		// preview axis from the origin via clamp_preview_camera at render time).
		if middle_down && clay.PointerOver(clay.ID("Preview")) {
			if panning_preview {
				preview_cam_ox += mouse_x - pan_last_x
				preview_cam_oy += mouse_y - pan_last_y
			}
			panning_preview = true
			pan_last_x = mouse_x
			pan_last_y = mouse_y
		} else if panning_preview {
			panning_preview = false
		}
		// Middle-drag over the timeline pans it horizontally, Blender-style.
		if middle_down && len(timeline.tracks) > 0 && clay.PointerOver(clay.ID("ClipTimeline")) {
			if panning_timeline {
				timeline_view_start -= (mouse_x - timeline_pan_last_x) / timeline_zoom
				timeline_view_start = clamp(timeline_view_start, 0, f32(timeline_duration()))
			}
			panning_timeline = true
			timeline_pan_last_x = mouse_x
		} else if panning_timeline {
			panning_timeline = false
		}
		clay.SetPointerState({mouse_x, mouse_y}, mouse_down)

		commands := build_page(width, height)
		if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("OpenFileButton")) {
			if path := open_file_picker(); path != nil {
				import_media(path)
			}
		} else if mouse_down && !was_mouse_down && len(timeline.tracks) == 0 && clay.PointerOver(clay.ID("Res720")) {
			set_project_resolution(1280, 720)
		} else if mouse_down && !was_mouse_down && len(timeline.tracks) == 0 && clay.PointerOver(clay.ID("Res1080")) {
			set_project_resolution(1920, 1080)
		} else if mouse_down && !was_mouse_down && len(timeline.tracks) == 0 && clay.PointerOver(clay.ID("Res4K")) {
			set_project_resolution(3840, 2160)
		} else if mouse_down && !was_mouse_down && len(timeline.tracks) == 0 && clay.PointerOver(clay.ID("OrientToggle")) {
			toggle_project_orientation()
		} else if clay.PointerOver(clay.ID("DividerHandle")) && mouse_down {
			resizing_areas = true
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("RenderPickButton")) {
			render_pick_output_path()
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("RenderRunButton")) {
			render_start()
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("RenderCancelButton")) {
			render_cancel()
		} else if mouse_down && !was_mouse_down && len(timeline.tracks) > 0 && clay.PointerOver(clay.ID("Ruler")) {
			// Clicking the timeline ruler starts a scrub (drag to seek).
			dragging_playhead = true
		} else if mouse_down && !was_mouse_down {
			// A click handled here either inserts a track via a "+" gap or
			// duplicates an existing track via its name-button, or starts dragging
			// the selected clip within the preview, so no clip drag begins.
			handled := false
			// If a property field is being typed in and the user clicks away from
			// it, commit the pending value first.
			if editing_field != 0 {
				still_on_field := (editing_field == 1 && clay.PointerOver(clay.ID("PropFieldX"))) || (editing_field == 2 && clay.PointerOver(clay.ID("PropFieldY"))) || (editing_field == 3 && clay.PointerOver(clay.ID("PropFieldS")))
				if !still_on_field {
					edit_commit()
				}
			}
			// Clicking an X/Y property field focuses it for typing.
			if sel, ok := transformable_selected(); ok {
				if clay.PointerOver(clay.ID("PropFieldX")) {
					edit_begin(1, sel.transform_x)
					handled = true
				} else if clay.PointerOver(clay.ID("PropFieldY")) {
					edit_begin(2, sel.transform_y)
					handled = true
				} else if clay.PointerOver(clay.ID("PropFieldS")) {
					edit_begin(3, sel.scale)
					handled = true
				}
			}
			// Grab one of the selected clip's resize/crop handles. Takes
			// precedence over moving the clip. Default drag scales; holding Alt
			// crops.
			if !handled && clay.PointerOver(clay.ID("Preview")) {
				if sel, ok := transformable_selected(); ok {
					pb := clay.GetElementData(clay.ID("Preview")).boundingBox
					canvas := preview_canvas(pb)
					ib := clip_image_bounds(canvas, sel)
					if h := preview_handle_at(ib, mouse_x, mouse_y); h >= 0 {
						begin_handle_drag(sel, canvas, h, mouse_x, mouse_y, alt_down)
						handled = true
					}
				}
			}
			// Dragging the selected clip inside the preview moves its transform.
			if !handled {
				if sel, ok := transformable_selected(); ok && clay.PointerOver(clay.ID("Preview")) {
					pb := clay.GetElementData(clay.ID("Preview")).boundingBox
					canvas := preview_canvas(pb)
					ib := clip_image_bounds(canvas, sel)
					if mouse_x >= ib.x && mouse_x <= ib.x + ib.width && mouse_y >= ib.y && mouse_y <= ib.y + ib.height {
						// Offset between the click and the clip's center, in project coords.
						// Unclamped so a grab near an off-canvas clip still offsets correctly.
						pcx, pcy := pixel_to_project_unclamped(canvas, mouse_x, mouse_y)
						preview_drag_offset_x = pcx - sel.transform_x
						preview_drag_offset_y = pcy - sel.transform_y
						moving_preview_clip = true
					handled = true
				}
			}
			}
			if !handled {
			for i := 0; i <= len(timeline.tracks); i += 1 {
				if clay.PointerOver(clay.ID("TrackGap", u32(i))) {
					insert_track(i)
					handled = true
					break
				}
			}
			}
			if !handled {
				for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
					if clay.PointerOver(clay.ID("DuplicateTrack", u32(track_idx))) {
						duplicate_track(track_idx)
						handled = true
						break
					}
				}
			}
			if !handled {
			// Find which (if any) clip the pointer is over and start dragging it.
			for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
				track := &timeline.tracks[track_idx]
				for index := 0; index < len(track.clips); index += 1 {
					if clay.PointerOver(clay.ID("TimelineClip", u32(track_idx * 1000 + index))) {
						selected_track = track_idx
						selected_index = index
						drag_clip = &track.clips[index]
						moving_clip = true
						clip_drag_offset = mouse_x - clay.GetElementData(clay.ID("TimelineClip", u32(track_idx * 1000 + index))).boundingBox.x
						break
					}
				}
				if moving_clip {
					break
				}
			}
			}
		}
		if !mouse_down {
			resizing_areas = false
			moving_clip = false
			moving_preview_clip = false
			dragging_handle = -1
			handle_kind = .None
			drag_clip = nil
			dragging_playhead = false
		} else if dragging_handle >= 0 {
			if sel, ok := transformable_selected(); ok {
				pb := clay.GetElementData(clay.ID("Preview")).boundingBox
				canvas := preview_canvas(pb)
				update_handle_drag(sel, canvas, mouse_x, mouse_y)
			}
		} else if resizing_areas {
			upper_area_height = mouse_y - 8
			if upper_area_height < 460 {
				upper_area_height = 460
			}
			if upper_area_height > f32(height - 180) {
				upper_area_height = f32(height - 180)
			}
		} else if moving_preview_clip {
			if sel, ok := transformable_selected(); ok {
				pb := clay.GetElementData(clay.ID("Preview")).boundingBox
				// Freeze at the preview widget's edge once the cursor leaves it:
				// otherwise free-move in unclamped project coords, so a cropped
				// clip can slide fully off-canvas like an uncropped one.
				if mouse_x >= pb.x && mouse_x <= pb.x + pb.width && mouse_y >= pb.y && mouse_y <= pb.y + pb.height {
					canvas := preview_canvas(pb)
					pcx, pcy := pixel_to_project_unclamped(canvas, mouse_x, mouse_y)
					sel.transform_x = pcx - preview_drag_offset_x
					sel.transform_y = pcy - preview_drag_offset_y
					// 5px snap margin (in rendered preview pixels) to the preview borders.
					snap_transform(sel, snap_margin(canvas, 5))
				}
			}
		} else if moving_clip {
			if drag_clip != nil {
				clip_x := mouse_x - clip_drag_offset
				track_start := clay.GetElementData(clay.ID("ClipsSection", 0)).boundingBox.x
				frame := (clip_x - track_start) / timeline_zoom + timeline_view_start
				sync.mutex_lock(&audio_timeline_mtx)
				drag_clip.timeline_start_frame = i64(clamp(frame, 0, f32(timeline_duration())))
				sync.mutex_unlock(&audio_timeline_mtx)
				audio_note_edit()
			}
		} else if dragging_playhead {
			// Scrub the playhead to the pointer's frame along the ruler bar.
			ruler := clay.GetElementData(clay.ID("Ruler")).boundingBox
			frame := i64((mouse_x - ruler.x) / timeline_zoom + timeline_view_start)
			frame = max(frame, 0)
			frame = min(frame, timeline_duration())
			playhead.frame = frame
			preview_frontier = frame
		} else if mouse_down && !was_mouse_down && clay.PointerOver(clay.ID("PlayPause")) {
			playhead.playing = !playhead.playing
			preview.playing = playhead.playing
			preview_frontier = playhead.frame
		}
		was_mouse_down = mouse_down
		now_ns := sdl.GetTicksNS()
		if last_tick_ns == 0 {
			last_tick_ns = now_ns
		}
		if playhead.playing {
			playhead_accumulator += f64(now_ns - last_tick_ns) / 1_000_000_000
			playback_fps := timeline_fps()
			for playhead_accumulator >= 1.0 / playback_fps {
				playhead.frame += 1
				playhead_accumulator -= 1.0 / playback_fps
			}
			if timeline_frame_at(playhead.frame).active_clip == nil {
				playhead.playing = false
				preview.playing = false
			}
			// Playback is real-time: the playhead (and with it the audio) runs on
			// the wall clock. Video decode is best-effort on top of that clock.
		}
		last_tick_ns = now_ns
		sync.atomic_store(&ui_playhead_frame, playhead.frame)
		_ = timeline_frame_at(playhead.frame)
		audio_update()
		poll_completed_thread()
		ui_frame_count += 1
		if ui_report_tick == 0 {
			ui_report_tick = now_ns
		} else if now_ns - ui_report_tick >= 2_000_000_000 {
			elapsed := f64(now_ns - ui_report_tick) / 1e9
			fmt.printf("[ui] fps=%.1f dec_ms=%.1f playhead=%d frontier=%d gap=%d\n",
				f64(ui_frame_count) / elapsed,
				f64(ui_dec_us) / 1000.0 / f64(ui_frame_count),
				playhead.frame, preview_frontier, playhead.frame - preview_frontier)
			ui_report_tick = now_ns
			ui_frame_count = 0
			ui_dec_us = 0
		}
		renderer.viewport = {f32(width), f32(height)}
		command_buffer := sdl.AcquireGPUCommandBuffer(device)
		if command_buffer == nil {
			continue
		}
		dec_t0 := sdl.GetTicksNS()
		changed := update_preview_slots()
		ui_dec_us += i64(sdl.GetTicksNS() - dec_t0)
		any_frame := false
		for i in 0..<MAX_PREVIEW_SLOTS {
			slot := &preview_slots[i]
			if !slot.in_use {
				continue
			}
			any_frame = true
			if slot.texture == nil {
				slot.texture = renderer.preview_textures[i]
			}
			if slot.tex_dirty || changed {
				upload_preview_slot(&renderer, command_buffer, slot)
			}
		}
		preview_has_frame = any_frame
		swapchain_texture: ^sdl.GPUTexture
		pixel_width, pixel_height: sdl.Uint32
		if !sdl.WaitAndAcquireGPUSwapchainTexture(command_buffer, window, &swapchain_texture, &pixel_width, &pixel_height) || swapchain_texture == nil {
			_ = sdl.CancelGPUCommandBuffer(command_buffer)
			continue
		}
		renderer.viewport = {f32(pixel_width), f32(pixel_height)}
		color_target := sdl.GPUColorTargetInfo{
			texture = swapchain_texture,
			clear_color = sdl.FColor{10.0 / 255, 11.0 / 255, 14.0 / 255, 1},
			load_op = .CLEAR, store_op = .STORE,
		}
		pass := sdl.BeginGPURenderPass(command_buffer, &color_target, 1, nil)
		if pass != nil {
			render_clay(&renderer, command_buffer, pass, commands)
			draw_clip_markers(&renderer, command_buffer, pass)
			if len(timeline.tracks) > 0 {
				draw_timeline_ruler(&renderer, command_buffer, pass)
				draw_render_range(&renderer, command_buffer, pass)
			}
			if preview_has_frame {
				preview_bounds := clay.GetElementData(clay.ID("Preview")).boundingBox
				draw_preview(&renderer, command_buffer, pass, preview_bounds)
				draw_preview_hud(&renderer, command_buffer, pass, preview_bounds)
			}
			sdl.EndGPURenderPass(pass)
		}
		if !sdl.SubmitGPUCommandBuffer(command_buffer) {
			fmt.println("Could not submit GPU command buffer:", sdl.GetError())
		}
	}
}
