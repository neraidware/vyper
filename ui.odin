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
					padding = clay.PaddingAll(PANEL_PADDING),
					childAlignment = {x = .Center, y = .Center},
					layoutDirection = .LeftToRight,
					childGap = SECTION_GAP,
				},
				backgroundColor = EDITOR_BG,
				cornerRadius = clay.CornerRadiusAll(RADIUS_CONTAINER),
			}) {
				if clay.UI(clay.ID("MediaBin"))({
					layout = {
						// Left-most column: file-manager grid of imported media,
						// with an import button on top. Media can be dragged
						// from here onto the timeline (see mediabin.odin).
						sizing = {width = clay.SizingGrow({min = MEDIA_BIN_MIN_W, max = MEDIA_BIN_MAX_W}), height = clay.SizingGrow({})},
						padding = clay.PaddingAll(PANEL_PADDING),
						childGap = CARD_GAP,
						layoutDirection = .TopToBottom,
					},
					backgroundColor = BUTTON,
					border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
					cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
				}) {
					media_bin_header()
					media_bin_grid()
				}
				if clay.UI(clay.ID("LeftPanel"))({
					layout = {
						// Sidebar: grows with the window but stays a sidebar
						// (bounded min/max) so it neither cramps a narrow window
						// nor stretches absurdly wide on a large display.
						sizing = {width = clay.SizingGrow({min = 260, max = 380}), height = clay.SizingGrow({})},
						layoutDirection = .TopToBottom,
						childGap = SECTION_GAP,
					},
					clip = {vertical = true},
				}) {
					if clay.UI(clay.ID("ProjectInfo"))({
						layout = {
							sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
							padding = clay.PaddingAll(PANEL_PADDING),
							childGap = CARD_GAP,
							layoutDirection = .TopToBottom,
						},
						backgroundColor = BUTTON,
						border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
						cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
					}) {
						clay.Text("Project", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_SMALL})
						clay.Text(fmt.aprintf("Name: %s", project.name), clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA})
						clay.Text(fmt.aprintf("Resolution: %dx%d", project.width, project.height), clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA})
						fps_label := "auto"
						if project.frame_rate > 0 {
							fps_label = fmt.aprintf("%g fps", project.frame_rate)
						}
						clay.Text(fmt.aprintf("FPS: %s", fps_label), clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA})
					}
					if len(file_info_text) > 0 {
						if clay.UI(clay.ID("FileInfo"))({
							layout = {
								sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
								padding = clay.PaddingAll(PANEL_PADDING),
								childGap = CARD_GAP,
								layoutDirection = .TopToBottom,
							},
							backgroundColor = BUTTON,
							border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
							cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
						}) {
							for line in strings.split_lines(file_info_text) {
								clay.Text(line, clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL})
							}
						}
					}
				}
				if clay.UI(clay.ID("PreviewColumn"))({
					layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, layoutDirection = .TopToBottom},
					border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
					cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
				}) {
					if len(timeline.tracks) == 0 {
						if clay.UI(clay.ID("ProjectSettings"))({
							layout = {
								sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
								padding = clay.PaddingAll(PANEL_PADDING),
								childGap = CARD_GAP,
								layoutDirection = .TopToBottom,
							},
							backgroundColor = BUTTON,
							border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
							cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
						}) {
							clay.Text("Project Settings", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_NORMAL})
							if clay.UI(clay.ID("ResolutionGroup"))({
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, childGap = BUTTON_ROW_GAP, layoutDirection = .TopToBottom},
							}) {
								clay.Text("Resolution", clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
							    if clay.UI(clay.ID("ResRow"))({
                                    layout = {
                                        sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
                                        layoutDirection = .LeftToRight,
                                        childGap = BUTTON_ROW_GAP,
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
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, childGap = BUTTON_ROW_GAP, layoutDirection = .TopToBottom},
							}) {
								clay.Text("Frame rate", clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
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
                                        childGap = BUTTON_ROW_GAP,
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
                                        childGap = BUTTON_ROW_GAP,
                                    },
                                }) {
                                    fps_preset_button("Fps48", "48", 48)
                                    fps_preset_button("Fps60", "60", 60)
                                    fps_preset_button("FpsAuto", "Auto", 0)
                                }
							}
						}
					}
					// The preview grows to fill the preview column (bounded below);
					// the decoded 768x432 image scales to fit whatever the widget
					// becomes. preview_canvas derives the on-screen canvas from the
					// widget bounds, so this is responsive on resize with no decode
					// change.
if clay.UI(clay.ID("Preview"))({
						layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({min = 216})}},
						image = {imageData = nil},
					}) {
					}
					if clay.UI(clay.ID("ActionsArea"))({
						// Hug the button row so the preview gets all remaining height
						// instead of splitting it with an empty grow region.
						layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, childAlignment = {x = .Center, y = .Bottom}},
					}) {
						if clay.UI(clay.ID("PlayRow"))({
							layout = {
								sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})},
								layoutDirection = .LeftToRight,
								childAlignment = {x = .Center, y = .Center},
								childGap = BUTTON_ROW_GAP,
							},
						}) {
							jog_button("PlayBack", -1)
							if clay.UI(clay.ID("PlayPause"))({
								layout = {sizing = {width = clay.SizingFixed(96), height = clay.SizingFixed(BUTTON_HEIGHT)}, childAlignment = {x = .Center, y = .Center}},
								backgroundColor = BUTTON,
								border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
								cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
							}) {
								if playhead.playing {
									clay.Text("Pause", clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL})
								} else {
									clay.Text("Play", clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL})
								}
							}
							jog_button("PlayFwd", 1)
							playback_rate_dropdown()
						}
					}
				}
				if clay.UI(clay.ID("ClipProperties"))({
					layout = {
						// Bounded-right panel so it never cramps the preview column on
						// a very wide window, while still growing from a sensible base.
						sizing = {width = clay.SizingGrow({min = 240, max = 340}), height = clay.SizingGrow({})},
						padding = clay.PaddingAll(PANEL_PADDING),
						childGap = CARD_GAP,
						layoutDirection = .TopToBottom,
					},
					backgroundColor = BUTTON,
					border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
					cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
				}) {
					clay.Text("Clip Properties", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_SMALL})
					if tr, cl, ok := selected_clip(); ok {
						clay.Text(fmt.aprintf("Track: %s", tr.name), clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA})
						clay.Text(fmt.aprintf("File: %s", path_basename(cl.path)), clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA})
						if cl.kind != .Audio {
							x_val := fmt.aprintf("%.0f", cl.transform_x)
							if editing_field == 1 {
								x_val = string(edit_chars[:edit_len])
							}
							if clay.UI(clay.ID("PropFieldX"))({
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, padding = clay.PaddingAll(CARD_GAP)},
								backgroundColor = BUTTON,
								border = {color = editing_field == 1 ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = DEFAULT_BORDER},
								cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
							}) {
								clay.Text(fmt.aprintf("X: %s", x_val), clay.TextElementConfig{textColor = editing_field == 1 ? BUTTON_BORDER_HOVER : TEXT, fontSize = FONT_DATA})
							}
							y_val := fmt.aprintf("%.0f", cl.transform_y)
							if editing_field == 2 {
								y_val = string(edit_chars[:edit_len])
							}
							if clay.UI(clay.ID("PropFieldY"))({
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, padding = clay.PaddingAll(CARD_GAP)},
								backgroundColor = BUTTON,
								border = {color = editing_field == 2 ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = DEFAULT_BORDER},
								cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
							}) {
								clay.Text(fmt.aprintf("Y: %s", y_val), clay.TextElementConfig{textColor = editing_field == 2 ? BUTTON_BORDER_HOVER : TEXT, fontSize = FONT_DATA})
							}
							scl_val := fmt.aprintf("%.2f", cl.scale)
							if editing_field == 3 {
								scl_val = string(edit_chars[:edit_len])
							}
							if clay.UI(clay.ID("PropFieldS"))({
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, padding = clay.PaddingAll(CARD_GAP)},
								backgroundColor = BUTTON,
								border = {color = editing_field == 3 ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = DEFAULT_BORDER},
								cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
							}) {
								clay.Text(fmt.aprintf("Scale: %s", scl_val), clay.TextElementConfig{textColor = editing_field == 3 ? BUTTON_BORDER_HOVER : TEXT, fontSize = FONT_DATA})
							}
							clay.Text(fmt.aprintf("Crop: L %.0f%% R %.0f%% T %.0f%% B %.0f%%", cl.crop_l * 100, cl.crop_r * 100, cl.crop_t * 100, cl.crop_b * 100), clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
						}
                    } else {
					    clay.Text("No clip selected", clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL})
				    }
			    }
			    if clay.UI(clay.ID("RenderPanel"))({
				    layout = {
					    layoutDirection = .TopToBottom,
					    sizing = {width = clay.SizingGrow({min = 180, max = 240}), height = clay.SizingGrow({})},
					    padding = clay.PaddingAll(PANEL_PADDING),
					    childGap = CARD_GAP,
				    },
				    backgroundColor = BUTTON,
				    border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
				    cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
			    }) {
				    clay.Text("Render", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_SMALL})
				    if clay.UI(clay.ID("RenderButtonsRow"))({
					    layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, layoutDirection = .LeftToRight, childGap = CARD_GAP},
				    }) {
					    if clay.UI(clay.ID("RenderPickButton"))({
						    layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(BUTTON_HEIGHT)}, childAlignment = {x = .Center, y = .Center}},
						    backgroundColor = BUTTON,
						    border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
						    cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
					    }) {
						    clay.Text("Pick file path", clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
					    }
					    if clay.UI(clay.ID("RenderRunButton"))({
						    layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(BUTTON_HEIGHT)}, childAlignment = {x = .Center, y = .Center}},
						    backgroundColor = BUTTON,
						    border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
						    cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
					    }) {
						    label := render_is_busy() ? "Rendering..." : "Render"
						    clay.Text(label, clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
					    }
					    if render_is_busy() {
						    if clay.UI(clay.ID("RenderCancelButton"))({
							    layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(BUTTON_HEIGHT)}, childAlignment = {x = .Center, y = .Center}},
							    backgroundColor = BUTTON,
							    border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
							    cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
						    }) {
							    clay.Text("Cancel", clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
						    }
					    }
				    }
				    clay.Text(fmt.aprintf("Output: %s", render_output_name()), clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
				    clay.Text(render_status_text(), clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
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
				layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, padding = clay.PaddingAll(PANEL_PADDING)},
				backgroundColor = EDITOR_BG,
				cornerRadius = clay.CornerRadiusAll(RADIUS_CONTAINER),
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
								padding = clay.PaddingAll(TIMELINE_PADDING),
								childAlignment = {x = .Center, y = .Center},
							},
							backgroundColor = BUTTON,
							cornerRadius = clay.CornerRadiusAll(RADIUS_CONTAINER),
							border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
						}) {
							clay.Text("Open file", clay.TextElementConfig{textColor = TEXT, fontSize = FONT_HEADING, textAlignment = .Center})
						}
					}
				} else {
					if clay.UI(clay.ID("ClipTimeline"))({
						layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, padding = clay.PaddingAll(TIMELINE_PADDING), layoutDirection = .TopToBottom, childGap = CARD_GAP},
						backgroundColor = BUTTON,
						cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
						border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
						clip = {vertical = true},
					}) {
						// Timeline ruler bar: a frame/time strip at the top that
						// mirrors the track rows' left gutter so its x-origin
						// (frame 0) aligns exactly with the clip lanes.
						if clay.UI(clay.ID("RulerRow"))({
							layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(RULER_HEIGHT)}, layoutDirection = .LeftToRight, childGap = SECTION_GAP},
						}) {
							if clay.UI(clay.ID("RulerGutter"))({
								layout = {sizing = {width = clay.SizingFixed(GUTTER_WIDTH), height = clay.SizingGrow({})}, layoutDirection = .LeftToRight, childGap = 6, childAlignment = {x = .Left, y = .Center}},
								backgroundColor = TRACK_GUTTER_BG,
							}) {
								timeline_snap_button("SnapClipToPh", snap_clips_to_playhead)
								timeline_snap_button("SnapPhToClip", snap_playhead_to_clips)
							}
							if clay.UI(clay.ID("Ruler"))({
								layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}},
								backgroundColor = EDITOR_BG,
								border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
								cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
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
									layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(TRACK_GAP_H)}, childAlignment = {x = .Left, y = .Center}, padding = clay.Padding{left = 4}},
									backgroundColor = gap_hovered ? clay.Color{36, 60, 84, 255} : EDITOR_BG,
									cornerRadius = clay.CornerRadiusAll(3),
								}) {
									if gap_hovered {
										clay.Text("+ Add track", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_NORMAL})
									}
								}
								if track_idx >= len(timeline.tracks) {
									break
								}
								track := &timeline.tracks[track_idx]
								if clay.UI(clay.ID("TrackRow", u32(track_idx)))({
									layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, layoutDirection = .LeftToRight, childGap = SECTION_GAP},
								}) {
									if clay.UI(clay.ID("TrackName", u32(track_idx)))({
										layout = {sizing = {width = clay.SizingFixed(GUTTER_WIDTH), height = clay.SizingGrow({})}, layoutDirection = .TopToBottom, childGap = 4, childAlignment = {x = .Left, y = .Top}},
										backgroundColor = TRACK_GUTTER_BG,
									}) {
										clay.Text(track.name, clay.TextElementConfig{textColor = TEXT, fontSize = FONT_HEADING})
										if clay.UI(clay.ID("TrackButtons", u32(track_idx)))({
											layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, layoutDirection = .LeftToRight, childGap = 4},
										}) {
											if clay.UI(clay.ID("DuplicateTrack", u32(track_idx)))({
												layout = {sizing = {width = clay.SizingFixed(30), height = clay.SizingFixed(34)}, childAlignment = {x = .Center, y = .Center}},
												backgroundColor = clay.PointerOver(clay.ID("DuplicateTrack", u32(track_idx))) ? BUTTON_HOVER : BUTTON,
												border = {color = clay.PointerOver(clay.ID("DuplicateTrack", u32(track_idx))) ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(1)},
												cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
											}) {
												// Duplicate glyph is drawn as an embedded icon overlay.
											}
											if clay.UI(clay.ID("RemoveTrack", u32(track_idx)))({
												layout = {sizing = {width = clay.SizingFixed(30), height = clay.SizingFixed(34)}, childAlignment = {x = .Center, y = .Center}},
												backgroundColor = clay.PointerOver(clay.ID("RemoveTrack", u32(track_idx))) ? BUTTON_HOVER : BUTTON,
												border = {color = clay.PointerOver(clay.ID("RemoveTrack", u32(track_idx))) ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(1)},
												cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
											}) {
											// Remove glyph is drawn as an embedded icon overlay.
										}
									}
									}
									if clay.UI(clay.ID("ClipsSection", u32(track_idx)))({
										layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, layoutDirection = .LeftToRight},
										backgroundColor = EDITOR_BG,
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
										    clip_label := timeline_clip.name
										    if timeline_clip.kind == .Audio {
											    clip_color = AUDIO_CLIP
											    if clip_label == "" {
												    clip_label = "Audio"
											    }
										    } else if clip_label == "" {
											    clip_label = "Clip"
										    }
if is_clip_selected(track_idx, index) {
										    // Selected linked clips (video + audio moving as one unit)
										    // outline yellow so the group is distinct from a lone clip.
										    clip_border = BUTTON_BORDER_HOVER
										    clip_border_w = 3
										    if timeline_clip.link_id != 0 {
											    clip_border = MARKER_COLOR
										    }
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
										        layout = {sizing = {width = clay.SizingFixed(clip_width), height = clay.SizingFixed(CLIP_TILE_HEIGHT)}, padding = clay.PaddingAll(CARD_GAP)},
										        backgroundColor = clip_color,
										        cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
										        border = {color = clip_border, width = border},
									        }) {
										        clay.Text(clip_label, clay.TextElementConfig{textColor = TEXT, fontSize = FONT_HEADING})
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
	draw_context_menu()
	draw_text_input_popup(width, height)

	return clay.EndLayout(0)
}

// settings_button renders the shared preset control: a fixed-height button that
// stays held (highlighted border + label) when active reports true. This is
// used for both mutually-exclusive presets (resolution/fps, where only the
// matching one is held) and standalone toggles (orientation, held on its own).
settings_button :: proc(name: string, label: string, active: bool) {
	if clay.UI(clay.ID(name))({
		layout = {sizing = {width = clay.SizingFit({}), height = clay.SizingFixed(BUTTON_HEIGHT)}, padding = clay.Padding{left = BUTTON_H_PAD, right = BUTTON_H_PAD}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = BUTTON,
		border = {color = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(active ? 2 : 1)},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	}) {
		clay.Text(label, clay.TextElementConfig{textColor = active ? BUTTON_BORDER_HOVER : TEXT, fontSize = FONT_NORMAL})
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

// timeline_snap_button renders one of the two snap toggles living in the
// track-gutter strip above the track names, to the left of the ruler. Held
// (highlighted border) while its snap behavior is active; the icon is an
// embedded overlay (draw_ui_icons), so this element only claims button visuals.
timeline_snap_button :: proc(name: string, active: bool) {
	if clay.UI(clay.ID(name))({
		layout = {sizing = {width = clay.SizingFixed(26), height = clay.SizingFixed(26)}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = BUTTON,
		border = {color = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(active ? 2 : 1)},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	}) {
	}
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
	if clay.UI(clay.ID("PlayRateButton"))({
		layout = {sizing = {width = clay.SizingFixed(64), height = clay.SizingFixed(BUTTON_HEIGHT)}, padding = clay.Padding{left = 8, right = 8}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = BUTTON,
		border = {color = playback_rate_open ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = rate_border},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	}) {
		clay.Text(playback_rate_label(playback_rate), clay.TextElementConfig{textColor = playback_rate_open ? BUTTON_BORDER_HOVER : TEXT, fontSize = FONT_NORMAL})
	}
	if playback_rate_open {
		// A proper floating dropdown: the menu overlays the UI anchored just
		// below the rate button instead of expanding the surrounding layout.
		if clay.UI(clay.ID("PlayRateMenu"))({
			layout = {
				sizing = {width = clay.SizingFixed(64), height = clay.SizingFit({})},
				layoutDirection = .TopToBottom,
				childGap = 2,
				padding = clay.PaddingAll(4),
			},
			backgroundColor = BUTTON,
			border = {color = BUTTON_BORDER, width = rate_border},
			cornerRadius = clay.CornerRadiusAll(4),
			floating = {
				offset = {0, 4},
				parentId = clay.ID("PlayRateButton").id,
				zIndex = 1000,
				attachment = {element = .LeftTop, parent = .LeftBottom},
				attachTo = .ElementWithId,
				pointerCaptureMode = .Capture,
				clipTo = .None,
			},
		}) {
			for rate in PLAYBACK_RATES {
				settings_button(playback_rate_name(rate), playback_rate_label(rate), playback_rate == rate)
			}
		}
	}
}

// jog_button renders a forward/backward jog control around the play button. It
// is held (highlighted) while playing in that direction; the label shows the
// temporary speed boost when active. dir is +1 (forward) or -1 (backward).
jog_button :: proc(name: string, dir: int) {
	active := playhead.playing && playback_dir == dir
	if clay.UI(clay.ID(name))({
		layout = {sizing = {width = clay.SizingFixed(56), height = clay.SizingFixed(BUTTON_HEIGHT)}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = BUTTON,
		border = {color = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(active ? 2 : 1)},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	}) {
		// The skip glyph is drawn as an embedded icon over this element.
	}
}

// ctx_option renders one row (option) of the floating timeline context menu.
ctx_option :: proc(id_name: string, label: string) {
	ctx_border := clay.BorderOutside(1)
	if clay.UI(clay.ID(id_name))({
		layout = {sizing = {width = clay.SizingFixed(180), height = clay.SizingFixed(BUTTON_HEIGHT)}, padding = clay.Padding{left = BUTTON_H_PAD, right = BUTTON_H_PAD}, childAlignment = {x = .Left, y = .Center}},
		backgroundColor = BUTTON,
		border = {color = BUTTON_BORDER, width = ctx_border},
		cornerRadius = clay.CornerRadiusAll(0),
	}) {
		clay.Text(label, clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL})
	}
}

// ctx_add_row renders the "Add >" row that opens the submenu when hovered (or
// clicked). Held while the submenu is showing.
ctx_add_row :: proc() {
	ctx_border := clay.BorderOutside(1)
	if clay.UI(clay.ID("CtxAdd"))({
		layout = {sizing = {width = clay.SizingFixed(180), height = clay.SizingFixed(BUTTON_HEIGHT)}, padding = clay.Padding{left = BUTTON_H_PAD}, childAlignment = {x = .Left, y = .Center}},
		backgroundColor = BUTTON,
		border = {color = ctx_menu.submenu ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = ctx_border},
		cornerRadius = clay.CornerRadiusAll(0),
	}) {
		clay.Text("Add", clay.TextElementConfig{textColor = ctx_menu.submenu ? BUTTON_BORDER_HOVER : TEXT, fontSize = FONT_NORMAL})
		if clay.UI(clay.ID("CtxAddChevron"))({
			layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(BUTTON_HEIGHT)}, childAlignment = {x = .Right, y = .Center}},
		}) {
			clay.Text(">", clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL})
		}
	}
}

// draw_context_menu renders the right-click menu over the timeline as a
// floating overlay anchored at the pointer. The "Add >" row expands a flyout
// submenu (attached right of it) listing the clip kinds. Menu item clicks are
// dispatched by the main loop (handle_ctx_option).
draw_context_menu :: proc() {
	if !ctx_menu.open {
		return
	}
	ctx_border := clay.BorderOutside(1)
	if clay.UI(clay.ID("CtxMenu"))({
		layout = {sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})}, layoutDirection = .TopToBottom, childGap = 1, padding = clay.PaddingAll(2)},
		backgroundColor = BUTTON,
		border = {color = BUTTON_BORDER, width = ctx_border},
		cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
		floating = {
			offset = {ctx_menu.x, ctx_menu.y},
			zIndex = 2000,
			attachTo = .Root,
			pointerCaptureMode = .Capture,
		},
	}) {
		ctx_add_row()
	}
	// Flyout submenu to the right of the "Add >" row, shown while hovered.
	if ctx_menu.submenu {
		if clay.UI(clay.ID("CtxSubmenu"))({
			layout = {sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})}, layoutDirection = .TopToBottom, childGap = 1, padding = clay.PaddingAll(2)},
			backgroundColor = BUTTON,
			border = {color = BUTTON_BORDER, width = ctx_border},
			cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
			floating = {
				parentId = clay.ID("CtxAdd").id,
				zIndex = 2001,
				attachment = {element = .LeftTop, parent = .RightTop},
				attachTo = .ElementWithId,
				clipTo = .None,
			},
		}) {
			ctx_option("CtxTextClip", "Text Clip")
		}
	}
}

// draw_text_input_popup renders the generic modal text-input dialog as a
// floating overlay centered in the window when the text field is active. It is a
// deliberately plain panel holding a raw input field; typing/selection/caret are
// handled by the textinput module and drawn by draw_text_input_caret.
draw_text_input_popup :: proc(width, height: c.int) {
	if !ti.active {
		return
	}
	// Responsive: the popup is at most 460px wide but never wider than 80% of
	// the window, and its height fits its content. Positioned centered
	// horizontally, roughly a third from the top.
	pw := min(f32(460), f32(width) * 0.8)
	px := (f32(width) - pw) / 2
	py := f32(height) * 0.3
	title := "Edit Text"
	if ti.input_type == TI_RENAME {
		title = "Rename Clip"
	}
	if clay.UI(clay.ID("TextInputPopup"))({
		layout = {sizing = {width = clay.SizingFixed(pw), height = clay.SizingFit({})}, layoutDirection = .TopToBottom, childGap = BUTTON_ROW_GAP, padding = clay.PaddingAll(PANEL_PADDING), childAlignment = {x = .Left, y = .Top}},
		backgroundColor = BUTTON,
		border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
		cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
		floating = {
			offset = {px, py},
			zIndex = 3000,
			attachTo = .Root,
			pointerCaptureMode = .Capture,
		},
	}) {
		clay.Text(strings.concatenate({title, " — Enter to confirm, Esc to cancel"}), clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
		if clay.UI(clay.ID("TextInputField"))({
			layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(34)}, padding = clay.Padding{left = CARD_GAP, right = CARD_GAP}, childAlignment = {x = .Left, y = .Center}},
			backgroundColor = TEXT_INPUT_BG,
			border = {color = BUTTON_BORDER_HOVER, width = clay.BorderOutside(1)},
			cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
		}) {
			if len(ti.buf) > 0 {
				clay.Text(text_input_string(), clay.TextElementConfig{textColor = TEXT, fontSize = TEXT_INPUT_FONT})
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
    case .Empty:
	    return "empty"
    case .Text:
	    return "text"
    case:
	    return "other"
    }
}

// ---------------------------------------------------------------------------
// Media bin panel: header (title + Import button) and the scrollable,
// file-manager-style thumbnail grid. Grid cells are drawn over in gpu_draw /
// mediabin.odin (thumbs via MediaItemThumb<i>); selection + drag start are
// wired in main.odin.
// ---------------------------------------------------------------------------

// media_bin_header renders the "Media Bin" title and the Import button.
media_bin_header :: proc() {
	if clay.UI(clay.ID("MediaBinHeader"))({
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
			childAlignment = {x = .Center, y = .Center},
		},
	}) {
		clay.Text("Media Bin", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_SMALL})
		if clay.UI(clay.ID("BinImportButton"))({
			layout = {
				sizing = {width = clay.SizingFixed(f32(BUTTON_HEIGHT) * 2), height = clay.SizingFixed(f32(BUTTON_HEIGHT))},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
			border = {color = clay.Hovered() ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(1)},
			cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
		}) {
			clay.Text("Import", clay.TextElementConfig{textColor = clay.Hovered() ? BUTTON_BORDER_HOVER : TEXT, fontSize = FONT_NORMAL})
		}
	}
}

// media_bin_grid lays out the imported assets as a wrapped thumbnail grid
// inside a manually-scrolled clip (childOffset = -media_bin_scroll, matching
// the TracksSection pattern). Column count derives from the bin width; rows
// wrap once the cells exceed it.
media_bin_grid :: proc() {
	if len(media_assets) == 0 {
		clay.Text("No media imported", clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL})
		clay.Text("Import, or drop media onto the timeline", clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
		return
	}
	cols := media_bin_cols()
	total_rows := (len(media_assets) + cols - 1) / cols
	if clay.UI(clay.ID("MediaBinScroll"))({
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			layoutDirection = .TopToBottom,
			childGap = CARD_GAP,
		},
		clip = {vertical = true, childOffset = {0, -media_bin_scroll}},
	}) {
		for row in 0 ..< total_rows {
			if clay.UI(clay.ID("MediaRow", u32(row)))({
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(media_bin_row_height())},
					layoutDirection = .LeftToRight,
					childGap = CARD_GAP,
				},
			}) {
				base := row * cols
				for i in base ..< min(base + cols, len(media_assets)) {
					media_bin_item(i)
				}
			}
		}
	}
}

// media_bin_item renders one grid cell: a thumbnail area (drawn over by
// mediabin.odin after layout) plus the asset basename. Selection shows a
// spring-green border.
media_bin_item :: proc(index: int) {
	asset := &media_assets[index]
	selected := asset.id == selected_asset_id
	if clay.UI(clay.ID("MediaItem", u32(index)))({
		layout = {
			sizing = {width = clay.SizingFixed(MEDIA_CELL_W), height = clay.SizingGrow({})},
			padding = clay.PaddingAll(u16(MEDIA_ITEM_PAD)),
			layoutDirection = .TopToBottom,
			childGap = u16(4),
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
		border = {color = selected ? SELECT_BORDER : BUTTON_BORDER, width = clay.BorderOutside(selected ? 2 : 1)},
		cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
	}) {
		if !clay.UI(clay.ID("MediaItemThumb", u32(index)))({
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(MEDIA_THUMB_H)},
			},
			backgroundColor = clay.Color{21, 24, 27, 255},
			cornerRadius = clay.CornerRadiusAll(4),
		}) {
		}
		clay.Text(path_basename(asset.path), clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
	}
}
