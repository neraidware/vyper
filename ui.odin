package main

import "core:c"
import "core:fmt"
import "core:strings"
import clay "clay-odin"

// ---------------------------------------------------------------------------
// Clay UI layout tree for the whole app (build_page), plus small display
// helpers used only by it.
// ---------------------------------------------------------------------------

build_page :: proc(width, height: c.int) -> clay.ClayArray(clay.RenderCommand) {
	clay.SetLayoutDimensions({f32(width), f32(height)})
	clay.BeginLayout()
    DEFAULT_BORDER := clay.BorderOutside(1)

	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			layoutDirection = .TopToBottom,
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = BACKGROUND,
	}) {
		if clay.UI()({
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				layoutDirection = .TopToBottom,
				childGap = 0,
			},
		}) {
			if clay.UI(clay.ID("EditorUpperArea"))({
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(upper_area_height)},
					padding = clay.PaddingAll(16),
					childAlignment = {x = .Center, y = .Center},
					layoutDirection = .LeftToRight,
					childGap = 24,
				},
				backgroundColor = EDITOR_BG,
				cornerRadius = clay.CornerRadiusAll(10),
			}) {
				if clay.UI(clay.ID("LeftPanel"))({
					layout = {
						sizing = {width = clay.SizingFixed(320), height = clay.SizingGrow({})},
						layoutDirection = .TopToBottom,
						childGap = 16,
					},
					clip = {vertical = true},
				}) {
					if clay.UI(clay.ID("ProjectInfo"))({
						layout = {
							sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
							padding = clay.PaddingAll(16),
							childGap = 8,
							layoutDirection = .TopToBottom,
						},
						backgroundColor = BUTTON,
						border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
						cornerRadius = clay.CornerRadiusAll(8),
					}) {
						clay.Text("Project", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = 13})
						clay.Text(fmt.aprintf("Name: %s", project.name), clay.TextElementConfig{textColor = TEXT, fontSize = 15})
						clay.Text(fmt.aprintf("Resolution: %dx%d", project.width, project.height), clay.TextElementConfig{textColor = TEXT, fontSize = 15})
						fps_label := "auto"
						if project.frame_rate > 0 {
							fps_label = fmt.aprintf("%g fps", project.frame_rate)
						}
						clay.Text(fmt.aprintf("FPS: %s", fps_label), clay.TextElementConfig{textColor = TEXT, fontSize = 15})
					}
					if clay.UI(clay.ID("MediaBin"))({
						layout = {
							sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
							padding = clay.PaddingAll(16),
							childGap = 8,
							layoutDirection = .TopToBottom,
						},
						backgroundColor = BUTTON,
						border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
						cornerRadius = clay.CornerRadiusAll(8),
					}) {
						clay.Text("Media Bin", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = 13})
						if len(media_assets) == 0 {
							clay.Text("No media imported", clay.TextElementConfig{textColor = TEXT, fontSize = 14})
						} else {
							for asset in media_assets {
								label := fmt.aprintf("%s  [%s]  %d frames", path_basename(asset.path), kind_name(asset.kind), asset.frame_count)
								clay.Text(label, clay.TextElementConfig{textColor = TEXT, fontSize = 14})
							}
						}
					}
					if len(file_info_text) > 0 {
						if clay.UI(clay.ID("FileInfo"))({
							layout = {
								sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
								padding = clay.PaddingAll(16),
								childGap = 8,
								layoutDirection = .TopToBottom,
							},
							backgroundColor = BUTTON,
							border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
							cornerRadius = clay.CornerRadiusAll(8),
						}) {
							for line in strings.split_lines(file_info_text) {
								clay.Text(line, clay.TextElementConfig{textColor = TEXT, fontSize = 14})
							}
						}
					}
				}
				if clay.UI(clay.ID("PreviewColumn"))({
					layout = {sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})}, layoutDirection = .TopToBottom},
					border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
					cornerRadius = clay.CornerRadiusAll(6),
				}) {
					if len(timeline.tracks) == 0 {
						if clay.UI(clay.ID("ProjectSettings"))({
							layout = {
								sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
								padding = clay.PaddingAll(16),
								childGap = 14,
								layoutDirection = .TopToBottom,
							},
							backgroundColor = BUTTON,
							border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
							cornerRadius = clay.CornerRadiusAll(8),
						}) {
							clay.Text("Project Settings", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = 14})
							if clay.UI(clay.ID("ResolutionGroup"))({
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, childGap = 6, layoutDirection = .TopToBottom},
							}) {
								clay.Text("Resolution", clay.TextElementConfig{textColor = TEXT, fontSize = 13})
							    if clay.UI(clay.ID("ResRow"))({
                                    layout = {
                                        sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
                                        layoutDirection = .LeftToRight,
                                        childGap = 6,
                                    },
                                }) {
                                    res_auto_button()
                                    res_preset_button("Res720", "720p", 1280, 720)
                                    res_preset_button("Res1080", "1080p", 1920, 1080)
                                    res_preset_button("Res4K", "4K", 3840, 2160)
                                    vertical_toggle_button("OrientVertical", "Vertical")
                                }
							}
							if clay.UI(clay.ID("FrameRateGroup"))({
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, childGap = 6, layoutDirection = .TopToBottom},
							}) {
								clay.Text("Frame rate", clay.TextElementConfig{textColor = TEXT, fontSize = 13})
								// Instead of this:
                                // if settings_row("FpsRow1") {
                                //     fps_preset_button("Fps24", "24", 24)
                                //     fps_preset_button("Fps25", "25", 25)
                                //     fps_preset_button("Fps30", "30", 30)
                                // }

                                if clay.UI(clay.ID("FpsRow1"))({
                                    layout = {
                                        sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
                                        layoutDirection = .LeftToRight,
                                        childGap = 6,
                                    },
                                }) {
                                    fps_preset_button("Fps24", "24", 24)
                                    fps_preset_button("Fps25", "25", 25)
                                    fps_preset_button("Fps30", "30", 30)
                                }

                                if clay.UI(clay.ID("FpsRow2"))({
                                    layout = {
                                        sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
                                        layoutDirection = .LeftToRight,
                                        childGap = 6,
                                    },
                                }) {
                                    fps_preset_button("Fps48", "48", 48)
                                    fps_preset_button("Fps60", "60", 60)
                                    fps_preset_button("FpsAuto", "Auto", 0)
                                }
							}
						}
					}
					pw, ph := project_preview_size()
					if clay.UI(clay.ID("Preview"))({
						layout = {sizing = {width = clay.SizingFixed(pw), height = clay.SizingFixed(ph)}},
						image = {imageData = nil},
					}) {
					}
					if clay.UI(clay.ID("ActionsArea"))({
						layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, childAlignment = {x = .Center, y = .Top}},
					}) {
						if clay.UI(clay.ID("PlayRow"))({
							layout = {
								sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})},
								layoutDirection = .LeftToRight,
								childAlignment = {x = .Center, y = .Center},
								childGap = 6,
							},
						}) {
							if clay.UI(clay.ID("PlayPause"))({
								layout = {sizing = {width = clay.SizingFixed(96), height = clay.SizingFixed(28)}, childAlignment = {x = .Center, y = .Center}},
								backgroundColor = BUTTON,
								border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
								cornerRadius = clay.CornerRadiusAll(4),
							}) {
								if playhead.playing {
									clay.Text("Pause", clay.TextElementConfig{textColor = TEXT, fontSize = 14})
								} else {
									clay.Text("Play", clay.TextElementConfig{textColor = TEXT, fontSize = 14})
								}
							}
							playback_rate_dropdown()
						}
					}
				}
				if clay.UI(clay.ID("ClipProperties"))({
					layout = {
						sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
						padding = clay.PaddingAll(16),
						childGap = 8,
						layoutDirection = .TopToBottom,
					},
					backgroundColor = BUTTON,
					border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
					cornerRadius = clay.CornerRadiusAll(8),
				}) {
					clay.Text("Clip Properties", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = 13})
					if tr, cl, ok := selected_clip(); ok {
						clay.Text(fmt.aprintf("Track: %s", tr.name), clay.TextElementConfig{textColor = TEXT, fontSize = 15})
						clay.Text(fmt.aprintf("File: %s", path_basename(cl.path)), clay.TextElementConfig{textColor = TEXT, fontSize = 15})
						if cl.kind != .Audio {
							x_val := fmt.aprintf("%.0f", cl.transform_x)
							if editing_field == 1 {
								x_val = string(edit_chars[:edit_len])
							}
							if clay.UI(clay.ID("PropFieldX"))({
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, padding = clay.PaddingAll(8)},
								backgroundColor = BUTTON,
								border = {color = editing_field == 1 ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = DEFAULT_BORDER},
								cornerRadius = clay.CornerRadiusAll(6),
							}) {
								clay.Text(fmt.aprintf("X: %s", x_val), clay.TextElementConfig{textColor = editing_field == 1 ? BUTTON_BORDER_HOVER : TEXT, fontSize = 15})
							}
							y_val := fmt.aprintf("%.0f", cl.transform_y)
							if editing_field == 2 {
								y_val = string(edit_chars[:edit_len])
							}
							if clay.UI(clay.ID("PropFieldY"))({
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, padding = clay.PaddingAll(8)},
								backgroundColor = BUTTON,
								border = {color = editing_field == 2 ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = DEFAULT_BORDER},
								cornerRadius = clay.CornerRadiusAll(6),
							}) {
								clay.Text(fmt.aprintf("Y: %s", y_val), clay.TextElementConfig{textColor = editing_field == 2 ? BUTTON_BORDER_HOVER : TEXT, fontSize = 15})
							}
							scl_val := fmt.aprintf("%.2f", cl.scale)
							if editing_field == 3 {
								scl_val = string(edit_chars[:edit_len])
							}
							if clay.UI(clay.ID("PropFieldS"))({
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, padding = clay.PaddingAll(8)},
								backgroundColor = BUTTON,
								border = {color = editing_field == 3 ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = DEFAULT_BORDER},
								cornerRadius = clay.CornerRadiusAll(6),
							}) {
								clay.Text(fmt.aprintf("Scale: %s", scl_val), clay.TextElementConfig{textColor = editing_field == 3 ? BUTTON_BORDER_HOVER : TEXT, fontSize = 15})
							}
							clay.Text(fmt.aprintf("Crop: L %.0f%% R %.0f%% T %.0f%% B %.0f%%", cl.crop_l * 100, cl.crop_r * 100, cl.crop_t * 100, cl.crop_b * 100), clay.TextElementConfig{textColor = TEXT, fontSize = 13})
						}
                    } else {
					    clay.Text("No clip selected", clay.TextElementConfig{textColor = TEXT, fontSize = 14})
				    }
				    if clay.UI(clay.ID("RenderPanel"))({
					    layout = {
						    layoutDirection = .TopToBottom,
						    sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
						    padding = clay.PaddingAll(16),
						    childGap = 8,
					    },
					    backgroundColor = BUTTON,
					    border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
					    cornerRadius = clay.CornerRadiusAll(8),
				    }) {
					    clay.Text("Render", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = 13})
					    if clay.UI(clay.ID("RenderButtonsRow"))({
						    layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, layoutDirection = .LeftToRight, childGap = 8},
					    }) {
						    if clay.UI(clay.ID("RenderPickButton"))({
							    layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(30)}, childAlignment = {x = .Center, y = .Center}},
							    backgroundColor = BUTTON,
							    border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
							    cornerRadius = clay.CornerRadiusAll(4),
						    }) {
							    clay.Text("Pick file path", clay.TextElementConfig{textColor = TEXT, fontSize = 13})
						    }
						    if clay.UI(clay.ID("RenderRunButton"))({
							    layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(30)}, childAlignment = {x = .Center, y = .Center}},
							    backgroundColor = BUTTON,
							    border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
							    cornerRadius = clay.CornerRadiusAll(4),
						    }) {
							    label := render_is_busy() ? "Rendering..." : "Render"
							    clay.Text(label, clay.TextElementConfig{textColor = TEXT, fontSize = 13})
						    }
						    if render_is_busy() {
							    if clay.UI(clay.ID("RenderCancelButton"))({
								    layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(30)}, childAlignment = {x = .Center, y = .Center}},
								    backgroundColor = BUTTON,
								    border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
								    cornerRadius = clay.CornerRadiusAll(4),
							    }) {
								    clay.Text("Cancel", clay.TextElementConfig{textColor = TEXT, fontSize = 13})
							    }
						    }
					    }
					    clay.Text(fmt.aprintf("Output: %s", render_output_name()), clay.TextElementConfig{textColor = TEXT, fontSize = 13})
					    clay.Text(render_status_text(), clay.TextElementConfig{textColor = TEXT, fontSize = 13})
				    }
			    }
			}
			if clay.UI(clay.ID("EditorDivider"))({
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(16)},
					childAlignment = {x = .Center, y = .Center},
				},
			}) {
				if clay.UI(clay.ID("DividerHandle"))({
					layout = {sizing = {width = clay.SizingFixed(50), height = clay.SizingFixed(5)}},
					backgroundColor = BUTTON_BORDER,
					cornerRadius = clay.CornerRadiusAll(3),
				}) {}
			}
			if clay.UI(clay.ID("EditorLowerArea"))({
				layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, padding = clay.PaddingAll(16)},
				backgroundColor = EDITOR_BG,
				cornerRadius = clay.CornerRadiusAll(10),
			}) {
				if len(timeline.tracks) == 0 {
					// Empty timeline: show the import button.
					if clay.UI(clay.ID("EmptyTimeline"))({
						layout = {
							sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
							childAlignment = {x = .Center, y = .Center},
						},
					}) {
						if clay.UI(clay.ID("OpenFileButton"))({
							layout = {
								sizing = {width = clay.SizingFixed(200), height = clay.SizingFixed(56)},
								padding = clay.PaddingAll(12),
								childAlignment = {x = .Center, y = .Center},
							},
							backgroundColor = BUTTON,
							cornerRadius = clay.CornerRadiusAll(10),
							border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
						}) {
							clay.Text("Open file", clay.TextElementConfig{textColor = TEXT, fontSize = 18, textAlignment = .Center})
						}
					}
				} else {
					if clay.UI(clay.ID("ClipTimeline"))({
						layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, padding = clay.PaddingAll(12), layoutDirection = .TopToBottom, childGap = 8},
						backgroundColor = BUTTON,
						cornerRadius = clay.CornerRadiusAll(8),
						border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
						clip = {vertical = true},
					}) {
						// Timeline ruler bar: a frame/time strip at the top that
						// mirrors the track rows' left gutter so its x-origin
						// (frame 0) aligns exactly with the clip lanes.
						if clay.UI(clay.ID("RulerRow"))({
							layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(RULER_HEIGHT)}, layoutDirection = .LeftToRight, childGap = 16},
						}) {
							if clay.UI(clay.ID("RulerGutter"))({
								layout = {sizing = {width = clay.SizingFixed(140), height = clay.SizingGrow({})}},
							}) {}
							if clay.UI(clay.ID("Ruler"))({
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}},
								backgroundColor = EDITOR_BG,
								border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
								cornerRadius = clay.CornerRadiusAll(4),
							}) {}
						}
						if clay.UI(clay.ID("TracksSection"))({
							layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, layoutDirection = .TopToBottom, childGap = 0},
							clip = {vertical = true, childOffset = {0, -timeline_view_top}},
						}) {
							for track_idx := 0; track_idx <= len(timeline.tracks); track_idx += 1 {
								// Gap indent where a new track can be inserted.
								gap_id := clay.ID("TrackGap", u32(track_idx))
								gap_hovered := clay.PointerOver(gap_id)
								if clay.UI(gap_id)({
									layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(18)}, childAlignment = {x = .Left, y = .Center}, padding = clay.Padding{left = 4}},
									backgroundColor = gap_hovered ? clay.Color{36, 60, 84, 255} : EDITOR_BG,
									cornerRadius = clay.CornerRadiusAll(3),
								}) {
									if gap_hovered {
										clay.Text("+ Add track", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = 14})
									}
								}
								if track_idx >= len(timeline.tracks) {
									break
								}
								track := &timeline.tracks[track_idx]
								if clay.UI(clay.ID("TrackRow", u32(track_idx)))({
									layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, layoutDirection = .LeftToRight, childGap = 16},
								}) {
									if clay.UI(clay.ID("TrackName", u32(track_idx)))({
										layout = {sizing = {width = clay.SizingFixed(140), height = clay.SizingFit({})}, layoutDirection = .TopToBottom, childGap = 4, childAlignment = {x = .Left, y = .Top}},
									}) {
										clay.Text(track.name, clay.TextElementConfig{textColor = TEXT, fontSize = 18})
										if clay.UI(clay.ID("DuplicateTrack", u32(track_idx)))({
											layout = {sizing = {width = clay.SizingFixed(30), height = clay.SizingFixed(34)}, childAlignment = {x = .Center, y = .Center}},
											backgroundColor = BUTTON,
											border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
											cornerRadius = clay.CornerRadiusAll(4),
										}) {
											clay.Text("+\nv", clay.TextElementConfig{textColor = TEXT, fontSize = 13})
										}
									}
									if clay.UI(clay.ID("ClipsSection", u32(track_idx)))({
										layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, layoutDirection = .LeftToRight},
										clip = {horizontal = true, vertical = true, childOffset = {-timeline_view_start * timeline_zoom, 0}},
									}) {
										clips_content_x: f32 = 0
                                        for timeline_clip, index in track.clips {
										    // Each clip is laid out at its true timeline frame position
										    // (start_frame pixels from the row's origin at frame 0); the
										    // ClipsSection's childOffset translates the whole row by
										    // -view_start*zoom so panning slides every clip together and
										    // clips starting before the view go off the left edge instead
										    // of pinning to it.
										    // A running x keeps real gaps between clips exactly one
										    // spacer wide, so multi-clip tracks don't drift right as
										    // later clips each add another full start-frame spacer.
										    target_x := f32(timeline_clip.timeline_start_frame) * timeline_zoom
										    if target_x > clips_content_x {
											    spacer_w := target_x - clips_content_x
											    clips_content_x = target_x
											    clay.UI(clay.ID("ClipOffset", u32(track_idx * 1000 + index)))({
												    layout = {sizing = {width = clay.SizingFixed(spacer_w), height = clay.SizingGrow({})}},
											    })
										    }
										    clip_width := f32(max(timeline_clip.source_length_frames, 1)) * timeline_zoom
										    clip_color := BUTTON
										    clip_border := BUTTON_BORDER
										    clip_border_w: u16 = 2
										    clip_label := "Clip"
										    if timeline_clip.kind == .Audio {
											    clip_color = AUDIO_CLIP
											    clip_label = "Audio"
										    }
										    if selected_track == track_idx && selected_index == index {
											    clip_border = BUTTON_BORDER_HOVER
											    clip_border_w = 3
										    }
										    // Adjacent clips keep their corner radius but drop the
										    // shared border where this clip's end touches the next
										    // clip's start exactly; the neighbor's left border stays as
										    // a thin divider line at the intersection.
										    next_touches := index + 1 < len(track.clips) && track.clips[index + 1].timeline_start_frame == clip_timeline_end(timeline_clip)
										    bw := clip_border_w
										    border := clay.BorderWidth{left = bw, top = bw, bottom = bw}
										    border.right = next_touches ? 0 : bw
                                            if clay.UI(clay.ID("TimelineClip", u32(track_idx * 1000 + index)))({
										        layout = {sizing = {width = clay.SizingFixed(clip_width), height = clay.SizingFixed(56)}, padding = clay.PaddingAll(8)},
										        backgroundColor = clip_color,
										        cornerRadius = clay.CornerRadiusAll(6),
										        border = {color = clip_border, width = border},
									        }) {
										        clay.Text(clip_label, clay.TextElementConfig{textColor = TEXT, fontSize = 18})
									        }
										    clips_content_x += clip_width
										}
									}
								}
							}
						}
					}
				}
			}
		}
	}

	return clay.EndLayout(0)
}

// settings_button renders the shared preset control: a fixed-height button that
// stays held (highlighted border + label) when active reports true. This is
// used for both mutually-exclusive presets (resolution/fps, where only the
// matching one is held) and standalone toggles (orientation, held on its own).
settings_button :: proc(name: string, label: string, active: bool) {
	if clay.UI(clay.ID(name))({
		layout = {sizing = {width = clay.SizingFit({}), height = clay.SizingFixed(28)}, padding = clay.Padding{left = 12, right = 12}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = BUTTON,
		border = {color = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(active ? 2 : 1)},
		cornerRadius = clay.CornerRadiusAll(4),
	}) {
		clay.Text(label, clay.TextElementConfig{textColor = active ? BUTTON_BORDER_HOVER : TEXT, fontSize = 14})
	}
}

// res_preset_button renders a resolution preset, held when it matches the
// project's current (orientation-aware) resolution.
res_preset_button :: proc(name: string, label: string, w, h: c.int) {
	active := (project.width == w && project.height == h) || (project.width == h && project.height == w)
	if !resolution_locked && active {
		// A preset shouldn't look held when the canvas just happens to match it
		// but resolution is still on auto (picked up from the file, not chosen).
		active = false
	}
	settings_button(name, label, active)
}

// res_auto_button is the "Auto" resolution control. It stays held while the
// canvas is unlocked (resolution inferred from the next import).
res_auto_button :: proc() {
	settings_button("ResAuto", "Auto", !resolution_locked)
}

// vertical_toggle_button renders a single persistent toggle for canvas
// orientation: held when the canvas is currently portrait (taller than
// wide), unpressed when landscape. This is a toggle button in the proper
// sense — its own pressed state IS the current orientation — rather than a
// stateless button whose click merely fires a toggle action elsewhere.
vertical_toggle_button :: proc(name: string, label: string) {
	settings_button(name, label, project.height > project.width)
}

// fps_preset_button renders a frame-rate preset, held when it matches the
// project's current fps (0 = auto).
fps_preset_button :: proc(name: string, label: string, fps: f64) {
	settings_button(name, label, project.frame_rate == fps)
}

// playback_rate_label returns the display text for a playback rate value:
// "Auto" for 0, otherwise "<rate>x".
playback_rate_label :: proc(rate: f64) -> string {
	if rate <= 0 {
		return "Auto"
	}
	if rate == f64(int(rate)) {
		return fmt.aprintf("%dx", int(rate))
	}
	return fmt.aprintf("%.1fx", rate)
}

// playback_rate_name returns the unique element id string for a rate value
// (used both to render its button and to hit-test it on click). Rates are
// encoded by tenths: 1.5 -> "PlayRate15", 2 -> "PlayRate20", 0 -> "Auto".
playback_rate_name :: proc(rate: f64) -> string {
	if rate <= 0 {
		return "PlayRateAuto"
	}
	return fmt.aprintf("PlayRate%d", int(rate * 10))
}

// playback_rate_dropdown renders the rate selector beside the play button. The
// collapsed control is a button showing the current rate; clicking it toggles a
// small menu of the available rates that drops below it. Picking one sets
// playback_rate and closes the menu. Auto (0) is offered but currently behaves
// as 1x.
playback_rate_dropdown :: proc() {
	rate_border := clay.BorderOutside(1)
	if clay.UI(clay.ID("PlayRateBox"))({
		layout = {
			sizing = {width = clay.SizingFixed(64), height = clay.SizingFit({})},
			layoutDirection = .TopToBottom,
			childGap = 2,
		},
	}) {
		if clay.UI(clay.ID("PlayRateButton"))({
			layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(28)}, padding = clay.Padding{left = 8, right = 8}, childAlignment = {x = .Center, y = .Center}},
			backgroundColor = BUTTON,
			border = {color = playback_rate_open ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = rate_border},
			cornerRadius = clay.CornerRadiusAll(4),
		}) {
			clay.Text(playback_rate_label(playback_rate), clay.TextElementConfig{textColor = playback_rate_open ? BUTTON_BORDER_HOVER : TEXT, fontSize = 14})
		}
		if playback_rate_open {
			if clay.UI(clay.ID("PlayRateMenu"))({
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
					layoutDirection = .TopToBottom,
					childGap = 2,
					padding = clay.PaddingAll(4),
				},
				backgroundColor = BUTTON,
				border = {color = BUTTON_BORDER, width = rate_border},
				cornerRadius = clay.CornerRadiusAll(4),
			}) {
				for rate in PLAYBACK_RATES {
					settings_button(playback_rate_name(rate), playback_rate_label(rate), playback_rate == rate)
				}
			}
		}
	}
}

// kind_name returns a short label for a media kind (bin display).
kind_name :: proc(kind: Media_Kind) -> string {
    #partial switch kind {
    case .Video:
	    return "video"
    case .Audio:
	    return "audio"
    case .Image:
	    return "image"
    case:
	    return "other"
    }
}
