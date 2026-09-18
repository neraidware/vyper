package main

import clay "clay-odin"
import "core:c"
import "core:fmt"

// ---------------------------------------------------------------------------
// Clay UI layout tree for the whole app (build_page), plus small display
// helpers used only by it.
//
// Screen structure (top to bottom):
//   AppBar              -- app name, project badge, help "?" toggle.
//   EditorUpperArea     -- Media Bin | Preview (+ transport) | Inspector.
//   Divider handles     -- resizable split between upper area and timeline.
//   EditorLowerArea     -- the timeline (toolbar, ruler, track lanes), or the
//                          empty-state with the Open-file button.
// Floating overlays     -- context menu, help overlay, text-input popup.
//
// The right-hand Inspector stacks three labeled cards -- Project (canvas
// resolution/fps/render range), Clip (the selected clip's properties), Render
// (output path / run) -- so every project and clip setting has one obvious
// home and nothing hides behind the track count.
// ---------------------------------------------------------------------------

// Per-frame text buffers for clay.Text elements. Clay does NOT copy text: it
// keeps the StringSlice until layout/draw later in the same frame, so the
// backing bytes must outlive build_page. Stack-scoped buffers die as soon as
// their enclosing UI block returns -- long before clay reads them -- which
// rendered every dynamic label that fed clay.Text from a local buffer as
// garbage. Every per-frame label has its own persistent buffer here, one per
// text element, never shared between two clay.Text calls.
UI_TEXT_APP_SUMMARY: [512]u8
UI_TEXT_APP_FPS:     [32]u8
UI_TEXT_STATE:       [64]u8
UI_TEXT_RANGE:       [64]u8
UI_TEXT_TRACK:       [256]u8
UI_TEXT_FILE:        [256]u8
UI_TEXT_DUR:         [128]u8
UI_TEXT_IO:          [128]u8
UI_TEXT_X:           [64]u8
UI_TEXT_Y:           [64]u8
UI_TEXT_S:           [64]u8
UI_TEXT_L:           [64]u8
UI_TEXT_R:           [64]u8
UI_TEXT_T:           [64]u8
UI_TEXT_B:           [64]u8
UI_TEXT_OUT:         [128]u8
UI_TEXT_RATE:        [64]u8
UI_TEXT_HINT:        [512]u8

// One label+name buffer per rate for the playback-rate dropdown items. Each
// menu row must keep its own buffer alive until draw (clay keeps the slices),
// and the same buffer can never back two rows -- so sizes match PLAYBACK_RATES.
UI_TEXT_RATE_MENU: [7]struct {
	name:  [64]u8,
	label: [64]u8,
}

build_page :: proc(width, height: c.int) -> clay.ClayArray(clay.RenderCommand) {
	clay.SetLayoutDimensions({f32(width), f32(height)})
	clay.BeginLayout()
	DEFAULT_BORDER := clay.BorderOutside(1)

	// App-bar project summary text (project label · resolution · fps). Built
	// into the persistent buffers below so the every-frame labels never
	// allocate and outlive build_page (clay keeps the slices until draw).
	project_label := project.name
	if project_label == "" {
		project_label = "untitled project"
	}
	fps_l := "auto"
	if project.frame_rate > 0 {
		fps_l = fmt.bprintf(UI_TEXT_APP_FPS[:], "%g", project.frame_rate)
	}

	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			layoutDirection = .TopToBottom,
		},
		backgroundColor = BACKGROUND,
	},
	) {
		if clay.UI(clay.ID("AppBar"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(APP_BAR_H)},
				layoutDirection = .LeftToRight,
				childGap = CARD_GAP,
				padding = clay.Padding{left = PANEL_PADDING, right = PANEL_PADDING},
				childAlignment = {x = .Left, y = .Center},
			},
			backgroundColor = EDITOR_BG,
			border = {color = BUTTON_BORDER, width = clay.BorderWidth{bottom = 1}},
		},
		) {
			clay.Text(
				"Vyper",
				clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_HEADING},
			)
			clay.Text(
				"·",
				clay.TextElementConfig{textColor = BUTTON_BORDER, fontSize = FONT_NORMAL},
			)
			clay.Text(
				fmt.bprintf(
					UI_TEXT_APP_SUMMARY[:],
					"%s · %dx%d @ %sfps",
					project_label,
					project.width,
					project.height,
					fps_l,
				),
				clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL},
			)
			if clay.UI(clay.ID("AppSpacer"))(
			{layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}}},
			) {}
			// Help overlay toggle ("?" / F1).
			if clay.UI(clay.ID("HelpButton"))(
			{
				layout = {
					sizing = {
						width = clay.SizingFixed(f32(BUTTON_HEIGHT) + 6),
						height = clay.SizingFixed(BUTTON_HEIGHT),
					},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
				border = {
					color = help_open ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
					width = clay.BorderOutside(help_open ? 2 : 1),
				},
				cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
			},
			) {
				clay.Text(
					"?",
					clay.TextElementConfig {
						textColor = help_open ? BUTTON_BORDER_HOVER : TEXT,
						fontSize = FONT_HEADING,
					},
				)
			}
		}
		if clay.UI(clay.ID("EditorUpperArea"))(
		{
			layout = {
				sizing = {
					width = clay.SizingGrow({}),
					height = clay.SizingFixed(upper_area_height),
				},
				padding = clay.PaddingAll(PANEL_PADDING),
				childAlignment = {x = .Center, y = .Center},
				layoutDirection = .LeftToRight,
				childGap = SECTION_GAP,
			},
			backgroundColor = EDITOR_BG,
			cornerRadius = clay.CornerRadiusAll(RADIUS_CONTAINER),
		},
		) {
			// Column 1: Media Bin.
			if clay.UI(clay.ID("MediaBin"))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow({min = MEDIA_BIN_MIN_W, max = MEDIA_BIN_MAX_W}),
						height = clay.SizingGrow({}),
					},
					padding = clay.PaddingAll(PANEL_PADDING),
					childGap = CARD_GAP,
					layoutDirection = .TopToBottom,
				},
				backgroundColor = BUTTON,
				border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
				cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
			},
			) {
				media_bin_header()
				media_bin_grid()
			}
			// Column 2: Preview with the transport strip beneath it.
			if clay.UI(clay.ID("PreviewColumn"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
					layoutDirection = .TopToBottom,
					childGap = CARD_GAP,
					padding = clay.PaddingAll(CARD_GAP),
				},
				border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
				cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
			},
			) {
				// The preview grows to fill the column (bounded below); the
				// decoded image scales to fit whatever the widget becomes, and
				// preview_canvas derives the on-screen canvas from the widget
				// bounds, so this is responsive on resize.
				if clay.UI(clay.ID("Preview"))(
				{
					layout = {
						sizing = {
							width = clay.SizingGrow({}),
							height = clay.SizingGrow({min = 216}),
						},
					},
					image = {imageData = nil},
				},
				) {}
				// Transport strip: jog / play / rate, then the frame counter.
				if clay.UI(clay.ID("ActionsArea"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
						layoutDirection = .LeftToRight,
						childGap = BUTTON_ROW_GAP,
						childAlignment = {x = .Center, y = .Center},
					},
				},
				) {
					if clay.UI(clay.ID("PlayRow"))(
					{
						layout = {
							sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})},
							layoutDirection = .LeftToRight,
							childAlignment = {x = .Center, y = .Center},
							childGap = BUTTON_ROW_GAP,
						},
					},
					) {
						jog_button("PlayBack", -1)
						if clay.UI(clay.ID("PlayPause"))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(96),
									height = clay.SizingFixed(BUTTON_HEIGHT),
								},
								childAlignment = {x = .Center, y = .Center},
							},
							backgroundColor = BUTTON,
							border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
							cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
						},
						) {
							if playhead.playing {
								clay.Text(
									"Pause",
									clay.TextElementConfig {
										textColor = TEXT,
										fontSize = FONT_NORMAL,
									},
								)
							} else {
								clay.Text(
									"Play",
									clay.TextElementConfig {
										textColor = TEXT,
										fontSize = FONT_NORMAL,
									},
								)
							}
						}
						jog_button("PlayFwd", 1)
						playback_rate_dropdown()
					}
					if clay.UI(clay.ID("TransportSpacer"))(
					{
						layout = {
							sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
						},
					},
					) {}
					clay.Text(
						fmt.bprintf(
							UI_TEXT_STATE[:],
							"%d / %d  ·  %gfps",
							playhead.frame,
							timeline_duration(),
							timeline_fps(),
						),
						clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
					)
				}
			}
			// Column 3: Inspector -- Project / Clip / Render cards. The cards
			// stack in their own scrollport (InspectorContent) with a draggable
			// vertical strip when they outgrow the column.
			if clay.UI(clay.ID("InspectorColumn"))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow({min = INSPECTOR_MIN_W, max = INSPECTOR_MAX_W}),
						height = clay.SizingGrow({}),
					},
					layoutDirection = .LeftToRight,
					childGap = 0,
				},
				backgroundColor = EDITOR_BG,
			},
			) {
				if clay.UI(clay.ID("Inspector"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
						layoutDirection = .TopToBottom,
						childGap = 0,
					},
					clip = {vertical = true, childOffset = {0, -inspector_scroll}},
				},
				) {
					if clay.UI(clay.ID("InspectorContent"))(
					{
						layout = {
							sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
							layoutDirection = .TopToBottom,
							childGap = SECTION_GAP,
						},
					},
					) {
						project_card()
						clip_card()
						render_card()
					}
				}
				v_scrollbar(
					"InspectorV",
					inspector_scroll,
					inspector_content_height(),
					inspector_view_height(),
				)
			}
		}
		if clay.UI(clay.ID("EditorDivider"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(EDITOR_DIVIDER_H)},
				childAlignment = {x = .Center, y = .Center},
			},
		},
		) {
			if clay.UI(clay.ID("DividerHandle"))(
			{
				layout = {sizing = {width = clay.SizingFixed(50), height = clay.SizingFixed(5)}},
				backgroundColor = BUTTON_BORDER,
				cornerRadius = clay.CornerRadiusAll(3),
			},
			) {}
		}
		if clay.UI(clay.ID("EditorLowerArea"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				padding = clay.PaddingAll(PANEL_PADDING),
			},
			backgroundColor = EDITOR_BG,
			cornerRadius = clay.CornerRadiusAll(RADIUS_CONTAINER),
		},
		) {
			if len(timeline.tracks) == 0 {
				// Empty timeline: the import entry point plus its alternatives.
				if clay.UI(clay.ID("EmptyTimeline"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
						layoutDirection = .TopToBottom,
						childGap = CARD_GAP,
						childAlignment = {x = .Center, y = .Center},
					},
				},
				) {
					if clay.UI(clay.ID("OpenFileButton"))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(220),
								height = clay.SizingFixed(56),
							},
							padding = clay.PaddingAll(TIMELINE_PADDING),
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = BUTTON,
						cornerRadius = clay.CornerRadiusAll(RADIUS_CONTAINER),
						border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
					},
					) {
						clay.Text(
							"Open file",
							clay.TextElementConfig {
								textColor = TEXT,
								fontSize = FONT_HEADING,
								textAlignment = .Center,
							},
						)
					}
				}
			} else {
				if clay.UI(clay.ID("ClipTimeline"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
						padding = clay.PaddingAll(TIMELINE_PADDING),
						layoutDirection = .TopToBottom,
						childGap = CARD_GAP,
					},
					backgroundColor = BUTTON,
					cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
					border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
				},
				) {
					// Timeline toolbar: snapping and zoom, always visible above the
					// ruler so the whole timeline is controllable without hunting.
					if clay.UI(clay.ID("TimelineBar"))(
					{
						layout = {
							sizing = {
								width = clay.SizingGrow({}),
								height = clay.SizingFixed(TIMELINE_BAR_H),
							},
							layoutDirection = .LeftToRight,
							childGap = BUTTON_ROW_GAP,
							childAlignment = {x = .Left, y = .Center},
						},
					},
					) {
						if clay.UI(clay.ID("TimelineBarSpacer"))(
						{
							layout = {
								sizing = {
									width = clay.SizingGrow({}),
									height = clay.SizingGrow({}),
								},
							},
						},
						) {}
						bar_caption("Zoom:")
						tool_button("TimelineZoomOut", "−")
						tool_button("TimelineZoomFit", "Fit")
						tool_button("TimelineZoomIn", "+")
					}
					// Timing ruler bar: mirrors the track rows' left gutter so its
					// x-origin (frame 0) aligns exactly with the clip lanes.
					if clay.UI(clay.ID("RulerRow"))(
					{
						layout = {
							sizing = {
								width = clay.SizingGrow({}),
								height = clay.SizingFixed(RULER_HEIGHT),
							},
							layoutDirection = .LeftToRight,
							childGap = SECTION_GAP,
						},
					},
					) {
						if clay.UI(clay.ID("RulerGutter"))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(GUTTER_WIDTH),
									height = clay.SizingGrow({}),
								},
							},
							backgroundColor = TRACK_GUTTER_BG,
						},
						) {
							// Playhead time viewer: the timecode badge sits in the
							// empty top-left corner above the track-name gutters and
							// before the ruler. Clicking it opens numeric navigation
							// (begin_playhead_time_edit) to jump the playhead.
							if clay.UI(clay.ID("PlayheadTime"))(
							{
								layout = {
									sizing = {
										width = clay.SizingGrow({}),
										height = clay.SizingGrow({}),
									},
									childAlignment = {x = .Center, y = .Center},
								},
								backgroundColor = clay.Hovered() ? BUTTON_HOVER : TRACK_GUTTER_BG,
							},
							) {
								clay.Text(
									playhead_timecode(),
									clay.TextElementConfig {
										textColor = TEXT,
										fontSize = FONT_SMALL,
										textAlignment = .Center,
									},
								)
							}
						}
						if clay.UI(clay.ID("Ruler"))(
						{
							layout = {
								sizing = {
									width = clay.SizingGrow({}),
									height = clay.SizingGrow({}),
								},
							},
							backgroundColor = EDITOR_BG,
							border = {color = BUTTON_BORDER, width = DEFAULT_BORDER},
							cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
						},
						) {}
					}
					// The track list lives in its own scroll viewport. TrackArea
					// holds the scrollable lanes (TracksSection) plus the vertical
					// scrollbar strip, so the scroll geometry is one clean unit
					// beside the fixed ruler strip above it.
					if clay.UI(clay.ID("TrackArea"))(
					{
						layout = {
							sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
							layoutDirection = .LeftToRight,
							childGap = 0,
						},
					},
					) {
						if clay.UI(clay.ID("TracksSection"))(
						{
							layout = {
								sizing = {
									width = clay.SizingGrow({}),
									height = clay.SizingGrow({}),
								},
								layoutDirection = .TopToBottom,
								childGap = 0,
							},
							clip = {vertical = true, childOffset = {0, -timeline_view_top}},
						},
						) {
							sync_track_order()
							for r := 0; r <= len(timeline.track_order); r += 1 {
								// Insert gap above each track: the "Add track"
								// button is limited to the gutter column, and the
								// strip's remaining space carries the track's
								// point-marker triangles (drawn by
								// draw_clip_markers). gap/add-track IDs are
								// keyed by ORDER position r (insert_track uses
								// the position to place the new row).
								gap_id := clay.ID("TrackGap", u32(r))
								button_id := clay.ID("AddTrack", u32(r))
								button_hovered := clay.PointerOver(button_id)
								if clay.UI(gap_id)(
								{
									layout = {
										sizing = {
											width = clay.SizingGrow({}),
											height = clay.SizingFixed(TRACK_GAP_H),
										},
										layoutDirection = .LeftToRight,
										childGap = 0,
									},
								},
								) {
									if clay.UI(button_id)(
									{
										layout = {
											sizing = {
												width = clay.SizingFixed(GUTTER_WIDTH),
												height = clay.SizingGrow({}),
											},
											childAlignment = {x = .Center, y = .Center},
										},
										backgroundColor = button_hovered ? clay.Color{58, 81, 93, 255} : EDITOR_BG,
										cornerRadius = clay.CornerRadiusAll(3),
									},
									) {
										if button_hovered {
											clay.Text(
												"+ Add track",
												clay.TextElementConfig {
													textColor = BUTTON_BORDER_HOVER,
													fontSize = FONT_NORMAL,
												},
											)
										}
									}
								}
							if r >= len(timeline.track_order) {
								break
							}
							ti := timeline.track_order[r]
							track := &timeline.tracks[ti]
							if clay.UI(clay.ID("TrackRow", u32(ti)))(
							{
								layout = {
									sizing = {
										width = clay.SizingGrow({}),
										height = clay.SizingFixed(TRACK_ROW_H),
									},
									layoutDirection = .LeftToRight,
									childGap = SECTION_GAP,
								},
							},
							) {
								if clay.UI(clay.ID("TrackName", u32(ti)))(
								{
									layout = {
										sizing = {
											width = clay.SizingFixed(GUTTER_WIDTH),
											height = clay.SizingGrow({}),
										},
										layoutDirection = .TopToBottom,
										childGap = 4,
										childAlignment = {x = .Left, y = .Top},
									},
									backgroundColor = TRACK_GUTTER_BG,
								},
								) {
									clay.Text(
										track.name,
										clay.TextElementConfig {
											textColor = TEXT,
											fontSize = FONT_HEADING,
										},
									)
									if clay.UI(clay.ID("TrackButtons", u32(ti)))(
									{
										layout = {
											sizing = {
												width = clay.SizingGrow({}),
												height = clay.SizingFit({}),
											},
											layoutDirection = .LeftToRight,
											childGap = 4,
										},
									},
									) {
										if clay.UI(clay.ID("DuplicateTrack", u32(ti)))(
										{
											layout = {
												sizing = {
													width = clay.SizingFixed(30),
													height = clay.SizingFixed(34),
												},
												childAlignment = {x = .Center, y = .Center},
											},
											backgroundColor = clay.PointerOver(clay.ID("DuplicateTrack", u32(ti))) ? BUTTON_HOVER : BUTTON,
											border = {
												color = clay.PointerOver(clay.ID("DuplicateTrack", u32(ti))) ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
												width = clay.BorderOutside(1),
											},
											cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
										},
										) {
											// Duplicate glyph is drawn as an embedded icon overlay.
										}
										if clay.UI(clay.ID("RemoveTrack", u32(ti)))(
										{
											layout = {
												sizing = {
													width = clay.SizingFixed(30),
													height = clay.SizingFixed(34),
												},
												childAlignment = {x = .Center, y = .Center},
											},
											backgroundColor = clay.PointerOver(clay.ID("RemoveTrack", u32(ti))) ? BUTTON_HOVER : BUTTON,
											border = {
												color = clay.PointerOver(clay.ID("RemoveTrack", u32(ti))) ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
												width = clay.BorderOutside(1),
											},
											cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
										},
										) {
											// Remove glyph is drawn as an embedded icon overlay.
										}
									}
								}
								if clay.UI(clay.ID("ClipsSection", u32(ti)))(
								{
									layout = {
										sizing = {
											width = clay.SizingGrow({}),
											height = clay.SizingGrow({}),
										},
										layoutDirection = .LeftToRight,
									},
									backgroundColor = EDITOR_BG,
									clip = {
										horizontal = true,
										vertical = true,
										childOffset = {
											-timeline_view_start * timeline_zoom,
											0,
										},
									},
								},
								) {
									clips_content_x: f32 = 0
									for timeline_clip, index in track.clips {
										target_x :=
											f32(timeline_clip.timeline_start_frame) *
											timeline_zoom
										if target_x > clips_content_x {
											spacer_w := target_x - clips_content_x
											clips_content_x = target_x
											clay.UI(
												clay.ID(
													"ClipOffset",
													u32(ti * 1000 + index),
												),
											)(
												{
													layout = {
														sizing = {
															width = clay.SizingFixed(spacer_w),
															height = clay.SizingGrow({}),
														},
													},
												},
											)
										}
										clip_width :=
											f32(max(timeline_clip.source_length_frames, 1)) *
											timeline_zoom
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
										if ti == selected_track &&
										   index == selected_index {
											clip_border = SELECT_BORDER
											clip_border_w = 3
										} else if is_clip_selected(ti, index) {
											if timeline_clip.link_id != 0 {
												clip_border = MARKER_COLOR
											} else {
												clip_border = SELECT_BORDER
											}
											clip_border_w = 3
										}
										next_touches :=
											index + 1 < len(track.clips) &&
											track.clips[index + 1].timeline_start_frame ==
												clip_timeline_end(timeline_clip)
										bw := clip_border_w
										border := clay.BorderWidth {
											left   = bw,
											top    = bw,
											bottom = bw,
										}
										border.right = next_touches ? 0 : bw
										if clay.UI(
											clay.ID(
												"TimelineClip",
												u32(ti * 1000 + index),
											),
										)(
											{
												layout = {
													sizing = {
														width = clay.SizingFixed(clip_width),
														height = clay.SizingFixed(
															CLIP_TILE_HEIGHT,
														),
													},
													padding = clay.PaddingAll(CARD_GAP),
												},
												backgroundColor = clip_color,
												cornerRadius = clay.CornerRadiusAll(
													RADIUS_WIDGET,
												),
												border = {color = clip_border, width = border},
											},
										) {
											clay.Text(
												clip_label,
												clay.TextElementConfig {
													textColor = TEXT,
													fontSize = FONT_HEADING,
												},
											)
										}
										clips_content_x += clip_width
									}
								}
							}
						}
						}
					}
					// Bottom bar: the snap toggles that used to live in the top
					// toolbar, now under the tracks so the top bar stays zoom-only.
					if clay.UI(clay.ID("TimelineBottomBar"))(
					{
						layout = {
							sizing = {
								width = clay.SizingGrow({}),
								height = clay.SizingFixed(TIMELINE_BAR_H),
							},
							layoutDirection = .LeftToRight,
							childGap = BUTTON_ROW_GAP,
							childAlignment = {x = .Left, y = .Center},
						},
					},
					) {
						settings_icon_button("SnapClipToPh", snap_clips_to_playhead)
						settings_icon_button("SnapPhToClip", snap_playhead_to_clips)
					}
				}
			}
		}
	}
	draw_context_menu()
	draw_help_overlay(width, height)
	draw_text_input_popup(width, height)

	return clay.EndLayout(0)
}

// ---------------------------------------------------------------------------
// Inspector cards (column 3).
// ---------------------------------------------------------------------------

// card_open opens a shared card chrome: a titled panel that returns whether its
// body should be drawn. Title stays the same size/color across all cards so
// the inspector reads consistently.
card_open :: proc(id_name: string, title: string) -> bool {
	if clay.UI(clay.ID(id_name))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			padding = clay.PaddingAll(PANEL_PADDING),
			childGap = CARD_GAP,
			layoutDirection = .TopToBottom,
		},
		backgroundColor = BUTTON,
		border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
		cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
	},
	) {
		clay.Text(
			title,
			clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_SMALL},
		)
		return true
	}
	return false
}

// panel_caption is the small grey label above a group of controls in a card.
panel_caption :: proc(label: string) {
	clay.Text(label, clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
}

// prop_field renders one editable labelled value box (X/Y/Scale/crop). focused
// highlights the border while that field is being edited.
prop_field :: proc(id_name: string, label, value: string, focused: bool) {
	if clay.UI(clay.ID(id_name))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(FIELD_H)},
			layoutDirection = .LeftToRight,
			childGap = 6,
			padding = clay.PaddingAll(6),
			childAlignment = {x = .Left, y = .Center},
		},
		backgroundColor = BUTTON,
		border = {
			color = focused ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = clay.BorderOutside(focused ? 2 : 1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {
		clay.Text(
			label,
			clay.TextElementConfig {
				textColor = focused ? BUTTON_BORDER_HOVER : TEXT,
				fontSize = FONT_SMALL,
			},
		)
		clay.Text(value, clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA})
	}
}

// project_card is the "Project" inspector card: canvas resolution presets,
// orientation, frame rate, and the render range. These controls are always
// reachable (not gated behind an empty timeline).
project_card :: proc() {
	if !card_open("ProjectCard", "Project") {
		return
	}
	panel_caption("Resolution")
	if clay.UI(clay.ID("InfoResRow"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
		},
	},
	) {
		res_auto_button()
		res_preset_button("Res720", "720p", 1280, 720)
		res_preset_button("Res1080", "1080p", 1920, 1080)
		res_preset_button("Res4K", "4K", 3840, 2160)
	}
	if clay.UI(clay.ID("InfoOrientRow"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
		},
	},
	) {
		switch_toggle("OrientVertical", "Portrait canvas", project.height > project.width)
	}
	panel_caption("Frame rate")
	if clay.UI(clay.ID("FpsRow1"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
		},
	},
	) {
		fps_preset_button("Fps24", "24", 24)
		fps_preset_button("Fps25", "25", 25)
		fps_preset_button("Fps30", "30", 30)
	}
	if clay.UI(clay.ID("FpsRow2"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
		},
	},
	) {
		fps_preset_button("Fps48", "48", 48)
		fps_preset_button("Fps60", "60", 60)
		fps_preset_button("FpsAuto", "Auto", 0)
	}
	panel_caption("Render range")
	if project.start_frame >= 0 &&
	   project.end_frame >= 0 &&
	   project.end_frame > project.start_frame {
		range_buf := UI_TEXT_RANGE[:]
		clay.Text(
			fmt.bprintf(range_buf[:], "%d – %d", project.start_frame, project.end_frame),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
		)
	} else {
		clay.Text("full timeline", clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA})
	}
}

// clip_label_text returns the display name for a clip (its own name, falling
// back to the file base name).
clip_label_text :: proc(cl: Clip) -> string {
	if cl.name != "" {
		return cl.name
	}
	if cl.path != "" {
		return path_basename(cl.path)
	}
	return "Clip"
}

// clip_card is the "Clip" inspector card: the selected clip's identity,
// timing, and transform. Fields click-to-edit; crop values are per-box
// percentages.
clip_card :: proc() {
	if !card_open("ClipCard", "Clip") {
		return
	}
	if tr, cl, ok := selected_clip(); !ok {
		clay.Text(
			"No clip selected",
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL},
		)
		return
	} else {
		if cl.kind != .Audio {
			if clay.UI(clay.ID("NameRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
					layoutDirection = .LeftToRight,
					childGap = BUTTON_ROW_GAP,
					childAlignment = {x = .Left, y = .Center},
				},
			},
			) {
				if clay.UI(clay.ID("NameValue"))(
				{
					layout = {
						sizing = {
							width = clay.SizingGrow({}),
							height = clay.SizingFixed(BUTTON_HEIGHT),
						},
						padding = clay.Padding{left = 8, right = 8},
						childAlignment = {x = .Left, y = .Center},
					},
					backgroundColor = EDITOR_BG,
					cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
				},
				) {
					clay.Text(
						clip_label_text(cl^),
						clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL},
					)
				}
				if clay.UI(clay.ID("PropRename"))(
				{
					layout = {
						sizing = {
							width = clay.SizingFit({}),
							height = clay.SizingFixed(BUTTON_HEIGHT),
						},
						padding = clay.Padding{left = 8, right = 8},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
					border = {
						color = clay.Hovered() ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
						width = clay.BorderOutside(1),
					},
					cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
				},
				) {
					clay.Text(
						"Rename",
						clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
					)
				}
			}
		}
		// Inspector clip-card readouts, rebuilt every frame. Clay does NOT copy
		// text at the call — it keeps the slice until draw — so every element
		// must own its own buffer: one per line, never a shared buffer rewritten
		// between clay.Text calls.
		track_buf := UI_TEXT_TRACK[:]
		file_buf := UI_TEXT_FILE[:]
		dur_buf := UI_TEXT_DUR[:]
		clay.Text(
			fmt.bprintf(track_buf[:], "Track: %s", tr.name),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
		)
		clay.Text(
			fmt.bprintf(file_buf[:], "File: %s", path_basename(cl.path)),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
		)
		clay.Text(
			fmt.bprintf(dur_buf[:], "Duration: %d frames", cl.source_length_frames),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
		)
		if cl.kind != .Audio {
			io_buf := UI_TEXT_IO[:]
			clay.Text(
				fmt.bprintf(
					io_buf[:],
					"In: %d   Out: %d",
					cl.source_start_frame,
					cl.source_start_frame + cl.source_length_frames,
				),
				clay.TextElementConfig{textColor = TEXT, fontSize = FONT_DATA},
			)
			x_buf := UI_TEXT_X[:]
			x_val := fmt.bprintf(x_buf[:], "%.0f", cl.transform_x)
			if editing_field == .X {
				x_val = string(edit_chars[:edit_len])
			}
			prop_field("PropFieldX", "X", x_val, editing_field == .X)
			y_buf := UI_TEXT_Y[:]
			y_val := fmt.bprintf(y_buf[:], "%.0f", cl.transform_y)
			if editing_field == .Y {
				y_val = string(edit_chars[:edit_len])
			}
			prop_field("PropFieldY", "Y", y_val, editing_field == .Y)
			s_buf := UI_TEXT_S[:]
			scl_val := fmt.bprintf(s_buf[:], "%.2f", cl.scale)
			if editing_field == .Scale {
				scl_val = string(edit_chars[:edit_len])
			}
			prop_field("PropFieldS", "Scale", scl_val, editing_field == .Scale)
			// Canvas-center snap belongs with the transform settings it governs.
			if clay.UI(clay.ID("SnapRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
					layoutDirection = .LeftToRight,
					childGap = BUTTON_ROW_GAP,
					childAlignment = {x = .Left, y = .Center},
				},
			},
			) {
				switch_toggle("SnapCenter", "Snap center", snap_center_to_canvas)
			}
			panel_caption("Crop (percent of box)")
			l_buf := UI_TEXT_L[:]
			l_val := fmt.bprintf(l_buf[:], "%.0f%%", cl.crop_l * 100)
			if editing_field == .Crop_L {
				l_val = string(edit_chars[:edit_len])
			}
			r_buf := UI_TEXT_R[:]
			r_val := fmt.bprintf(r_buf[:], "%.0f%%", cl.crop_r * 100)
			if editing_field == .Crop_R {
				r_val = string(edit_chars[:edit_len])
			}
			t_buf := UI_TEXT_T[:]
			t_val := fmt.bprintf(t_buf[:], "%.0f%%", cl.crop_t * 100)
			if editing_field == .Crop_T {
				t_val = string(edit_chars[:edit_len])
			}
			b_buf := UI_TEXT_B[:]
			b_val := fmt.bprintf(b_buf[:], "%.0f%%", cl.crop_b * 100)
			if editing_field == .Crop_B {
				b_val = string(edit_chars[:edit_len])
			}
			if clay.UI(clay.ID("CropRowTop"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
					layoutDirection = .LeftToRight,
					childGap = BUTTON_ROW_GAP,
				},
			},
			) {
				prop_field("PropCropL", "L", l_val, editing_field == .Crop_L)
				prop_field("PropCropR", "R", r_val, editing_field == .Crop_R)
			}
			if clay.UI(clay.ID("CropRowBot"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
					layoutDirection = .LeftToRight,
					childGap = BUTTON_ROW_GAP,
				},
			},
			) {
				prop_field("PropCropT", "T", t_val, editing_field == .Crop_T)
				prop_field("PropCropB", "B", b_val, editing_field == .Crop_B)
			}
		}
	}
}

// render_card is the "Render" inspector card: pick an output path, start/cancel
// an export, and show progress.
render_card :: proc() {
	if !card_open("RenderCard", "Render") {
		return
	}
	if clay.UI(clay.ID("RenderButtonsRow"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = CARD_GAP,
		},
	},
	) {
		if clay.UI(clay.ID("RenderPickButton"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(BUTTON_HEIGHT)},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = BUTTON,
			border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
			cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
		},
		) {
			clay.Text(
				"Pick file path",
				clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
			)
		}
		if clay.UI(clay.ID("RenderRunButton"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(BUTTON_HEIGHT)},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = BUTTON,
			border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
			cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
		},
		) {
			label := render_is_busy() ? "Rendering..." : "Render"
			clay.Text(label, clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL})
		}
		if render_is_busy() {
			if clay.UI(clay.ID("RenderCancelButton"))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow({}),
						height = clay.SizingFixed(BUTTON_HEIGHT),
					},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = BUTTON,
				border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
				cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
			},
			) {
				clay.Text(
					"Cancel",
					clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
				)
			}
		}
	}
	out_buf := UI_TEXT_OUT[:]
	clay.Text(
		fmt.bprintf(out_buf[:], "Output: %s", render_output_name()),
		clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL, wrapMode = .Words},
	)
	switch_toggle("RenderOverwrite", "Overwrite existing output", render_overwrite_out)
	clay.Text(
		render_status_text(),
		clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL, wrapMode = .Words},
	)
}

// ---------------------------------------------------------------------------
// Shared controls.
// ---------------------------------------------------------------------------

// bar_caption is the little grey label between tool groups in the timeline bar.
bar_caption :: proc(label: string) {
	clay.Text(
		label,
		clay.TextElementConfig {
			textColor = BUTTON_BORDER,
			fontSize = FONT_SMALL,
			textAlignment = .Center,
		},
	)
}

// tool_button renders a small square-ish timeline-bar button with a text label.
tool_button :: proc(name: string, label: string) {
	if clay.UI(clay.ID(name))(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(label == "Fit" ? 38 : 30),
				height = clay.SizingFixed(BUTTON_HEIGHT),
			},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
		border = {
			color = clay.Hovered() ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = clay.BorderOutside(1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {
		clay.Text(
			label,
			clay.TextElementConfig {
				textColor = TEXT,
				fontSize = FONT_NORMAL,
				textAlignment = .Center,
			},
		)
	}
}

// v_scrollbar renders a vertical scrollbar strip for a scrollable container,
// derived from the container's scroll position plus its data/measured content
// and viewport heights (scrollbar_geometry). The strip only appears when the
// content overflows; the thumb's size and position mirror the exact geometry
// that dragging produces, so what's drawn is always what dragging yields (press
// = jump, hold = drag; main.odin routes both).
v_scrollbar :: proc(tag: string, scroll, content_h, view_h: f32) {
	max_top, thumb_h, travel := scrollbar_geometry(content_h, view_h)
	if thumb_h <= 0 || travel <= 0 {
		return
	}
	// Clay hashes id strings immediately, so one fixed stack buffer rebuilt for
	// each id is safe (no retention, no per-frame alloc).
	id_buf: [64]u8
	thumb_top := scroll / max_top * travel
	if clay.UI(clay.ID(fmt.bprintf(id_buf[:], "%sScrollbar", tag)))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(TSCROLLBAR_W), height = clay.SizingGrow({})},
			layoutDirection = .TopToBottom,
			childGap = 0,
		},
		backgroundColor = TRACK_GUTTER_BG,
	},
	) {
		if clay.UI(clay.ID(fmt.bprintf(id_buf[:], "%sSbPad", tag)))(
		{layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(thumb_top)}}},
		) {}
		if clay.UI(clay.ID(fmt.bprintf(id_buf[:], "%sSbThumb", tag)))(
		{
			layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(thumb_h)}},
			backgroundColor = clay.PointerOver(clay.ID(fmt.bprintf(id_buf[:], "%sSbThumb", tag))) ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			cornerRadius = clay.CornerRadiusAll(4),
		},
		) {}
	}
}

// settings_button renders the shared preset control: a fixed-height button that
// stays held (highlighted border + label) when active reports true. This is
// used for both mutually-exclusive presets (resolution/fps, where only the
// matching one is held) and standalone toggles (orientation, held on its own).
settings_button :: proc(name: string, label: string, active: bool) {
	if clay.UI(clay.ID(name))(
	{
		layout = {
			sizing = {width = clay.SizingFit({}), height = clay.SizingFixed(BUTTON_HEIGHT)},
			padding = clay.Padding{left = BUTTON_H_PAD, right = BUTTON_H_PAD},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = BUTTON,
		border = {
			color = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = clay.BorderOutside(active ? 2 : 1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {
		clay.Text(
			label,
			clay.TextElementConfig {
				textColor = active ? BUTTON_BORDER_HOVER : TEXT,
				fontSize = FONT_NORMAL,
			},
		)
	}
}

// res_preset_button renders a resolution preset, held when it matches the
// project's current (orientation-aware) resolution.
res_preset_button :: proc(name: string, label: string, w, h: c.int) {
	active :=
		(project.width == w && project.height == h) || (project.width == h && project.height == w)
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

// switch_toggle is the shared binary control. Only the switch track owns the
// semantic ID used by input handling; the label and surrounding row are
// passive. That means clicking the text never toggles the setting -- the track
// is the only hit target. Icon rows reuse the label slot (drawn right-aligned
// up against the pill by draw_ui_icons). The row sizes to its content rather
// than growing: the control never stretches into extra space it doesn't own,
// so a toggle stays the size of its label plus its pill wherever it sits.
// switch_toggle is the shared binary control. Only the switch track owns the
// semantic ID used by input handling; the label and surrounding row are
// passive. That means clicking the text never toggles the setting -- the track
// is the only hit target. The row sizes to its content rather than growing:
// the control never stretches into extra space it doesn't own.
switch_toggle :: proc(name, label: string, active: bool) {
	row_buf: [64]u8
	label_buf: [64]u8
	knob_buf: [64]u8
	row_id := fmt.bprintf(row_buf[:], "%sSwitchRow", name)
	label_id := fmt.bprintf(label_buf[:], "%sSwitchLabel", name)
	knob_id := fmt.bprintf(knob_buf[:], "%sSwitchKnob", name)

	if clay.UI(clay.ID(row_id))(
	{
		layout = {
			sizing = {width = clay.SizingFit({}), height = clay.SizingFixed(SWITCH_H + 4)},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
			childAlignment = {x = .Left, y = .Center},
		},
	},
	) {
		if clay.UI(clay.ID(label_id))(
		{
			layout = {
				sizing = {width = clay.SizingFit({}), height = clay.SizingGrow({})},
				childAlignment = {x = .Left, y = .Center},
			},
		},
		) {
			clay.Text(
				label,
				clay.TextElementConfig{textColor = active ? TEXT : BUTTON_BORDER, fontSize = FONT_NORMAL},
			)
		}

		// The semantic ID deliberately belongs only to the switch itself. The
		// label is a sibling, so pointer/click hit testing cannot reach `name`
		// when the user clicks the text.
		if clay.UI(clay.ID(name))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(SWITCH_W), height = clay.SizingFixed(SWITCH_H)},
				padding = clay.PaddingAll(3),
				childAlignment = {x = active ? .Right : .Left, y = .Center},
			},
			backgroundColor = active ? SWITCH_TRACK_ON : TEXT_INPUT_BG,
			border = {color = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(1)},
			cornerRadius = clay.CornerRadiusAll(SWITCH_H / 2),
		},
		) {
			if clay.UI(clay.ID(knob_id))(
			{
				layout = {sizing = {width = clay.SizingFixed(SWITCH_KNOB), height = clay.SizingFixed(SWITCH_KNOB)}},
				backgroundColor = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
				cornerRadius = clay.CornerRadiusAll(SWITCH_KNOB / 2),
			},
			) {}
		}
	}
}

// settings_icon_button is a square toggle whose content is an icon, drawn into
// its center by draw_ui_icons (the element id IS the toggle name). Held states
// mirror settings_button -- border + a bg_blue fill -- so the bar's icon
// toggles read as the same control family as the text preset pills.
ICON_BUTTON_SIZE :: 26
settings_icon_button :: proc(name: string, active: bool) {
	if clay.UI(clay.ID(name))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(ICON_BUTTON_SIZE), height = clay.SizingFixed(ICON_BUTTON_SIZE)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = active ? clay.Color{58, 81, 93, 255} : BUTTON,
		border = {
			color = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = clay.BorderOutside(active ? 2 : 1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {}
}

// fps_preset_button renders a frame-rate preset, held when it matches the
// project's current fps (0 = auto).
fps_preset_button :: proc(name: string, label: string, fps: f64) {
	settings_button(name, label, project.frame_rate == fps)
}

// playback_rate_label returns the display text for a playback rate value:
// "Auto" for 0, otherwise "<rate>x". Formatted into the caller's fixed buffer
// so the per-frame dropdown labels never allocate.
playback_rate_label :: proc(rate: f64, buf: []u8) -> string {
	if rate <= 0 {
		return "Auto"
	}
	if rate == f64(int(rate)) {
		return fmt.bprintf(buf, "%dx", int(rate))
	}
	return fmt.bprintf(buf, "%.1fx", rate)
}

// playback_rate_name returns the unique element id string for a rate value
// (used both to render its button and to hit-test it on click). Rates are
// encoded by tenths: 1.5 -> "PlayRate15", 2 -> "PlayRate20", 0 -> "Auto".
// Formatted into the caller's fixed buffer (clay hashes ids immediately, so
// the buffer may be stack-local).
playback_rate_name :: proc(rate: f64, buf: []u8) -> string {
	if rate <= 0 {
		return "PlayRateAuto"
	}
	return fmt.bprintf(buf, "PlayRate%d", int(rate * 10))
}

// playback_rate_dropdown renders the rate selector beside the play button. The
// collapsed control is a button showing the current rate; clicking it toggles a
// small menu of the available rates that drops below it. Picking one sets
// playback_rate and closes the menu. Auto (0) is offered but currently behaves
// as 1x.
playback_rate_dropdown :: proc() {
	rate_border := clay.BorderOutside(1)
	if clay.UI(clay.ID("PlayRateButton"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(64), height = clay.SizingFixed(BUTTON_HEIGHT)},
			padding = clay.Padding{left = 8, right = 8},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = BUTTON,
		border = {
			color = playback_rate_open ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = rate_border,
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {
		rate_lbl := UI_TEXT_RATE[:]
		clay.Text(
			playback_rate_label(playback_rate, rate_lbl[:]),
			clay.TextElementConfig {
				textColor = playback_rate_open ? BUTTON_BORDER_HOVER : TEXT,
				fontSize = FONT_NORMAL,
			},
		)
	}
	if playback_rate_open {
		// A proper floating dropdown: the menu overlays the UI anchored just
		// below the rate button instead of expanding the surrounding layout.
		if clay.UI(clay.ID("PlayRateMenu"))(
		{
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
		},
		) {
			for rate, i in PLAYBACK_RATES {
				assert(i < len(UI_TEXT_RATE_MENU))
				settings_button(
					playback_rate_name(rate, UI_TEXT_RATE_MENU[i].name[:]),
					playback_rate_label(rate, UI_TEXT_RATE_MENU[i].label[:]),
					playback_rate == rate,
				)
			}
		}
	}
}

// jog_button renders a forward/backward jog control around the play button. It
// is held (highlighted) while playing in that direction; the label shows the
// temporary speed boost when active. dir is +1 (forward) or -1 (backward).
jog_button :: proc(name: string, dir: int) {
	active := playhead.playing && playback_dir == dir
	if clay.UI(clay.ID(name))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(56), height = clay.SizingFixed(BUTTON_HEIGHT)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = BUTTON,
		border = {
			color = active ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
			width = clay.BorderOutside(active ? 2 : 1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
	},
	) {
		// The skip glyph is drawn as an embedded icon over this element.
	}
}

// ---------------------------------------------------------------------------
// Floating context menu.
// ---------------------------------------------------------------------------

// CONTEXT_MENU_W is one option row's width. The menu box adds a 1px border and
// 2px padding on every side, so its outer right edge sits at CONTEXT_MENU_W + 6
// from the anchor, and the first row's top edge at CONTEXT_MENU_PAD + 1 from the
// anchor's y. CONTEXT_MENU_EDGE folds those two constants into the flyout's
// offset so it lands flush against the menu with no seam for the cursor.
CONTEXT_MENU_W :: 180
CONTEXT_MENU_PAD :: 2
CONTEXT_MENU_EDGE :: CONTEXT_MENU_PAD + 1 // border + padding to the first row

// CTX_SUBMENU_GRACE is how many frames the "Add >" flyout stays open after the
// cursor leaves its hover zone (the Add row + the flyout + the seam between
// them). It absorbs the one-frame clay-geometry/pointer lag on mount, so the
// flyout can't flap shut under a moving cursor that is still on its way into
// it.
CTX_SUBMENU_GRACE :: 6

// ctx_point_in reports whether (x, y) is inside a rect.
ctx_point_in :: proc(x, y: f32, r: clay.BoundingBox) -> bool {
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

// ctx_add_row_zone is the hover band of the "Add >" row EXTENDED across the
// seam flush to the flyout's left edge, so a cursor sliding from the row into
// the flyout is always inside the open zone — no dead columns between the two
// boxes for the keep-open test to trip on.
ctx_add_row_zone :: proc() -> clay.BoundingBox {
	flyout_left := ctx_menu.x + CONTEXT_MENU_W + 2 * CONTEXT_MENU_EDGE
	return clay.BoundingBox {
		x = ctx_menu.x + CONTEXT_MENU_EDGE,
		y = ctx_menu.y + CONTEXT_MENU_EDGE,
		width = flyout_left - (ctx_menu.x + CONTEXT_MENU_EDGE) + 1,
		height = BUTTON_HEIGHT,
	}
}

// ctx_flyout_rect returns the flyout's box from last frame's layout (zero when
// the flyout is not mounted — callers gate on ctx_menu.submenu).
ctx_flyout_rect :: proc() -> clay.BoundingBox {
	return clay.GetElementData(clay.ID("CtxSubmenu")).boundingBox
}

// ctx_popup_hover reports whether the cursor is inside the floating popup: the
// menu box or, when it is mounted, the Add flyout box. Geometry-based against
// the last frame's rects rather than clay.PointerOver, so tests work the frame
// an element first mounts and never carry clay's one-frame hover lag.
ctx_popup_hover :: proc(x, y: f32) -> bool {
	if ctx_point_in(x, y, clay.GetElementData(clay.ID("CtxMenu")).boundingBox) {
		return true
	}
	if ctx_menu.submenu {
		return ctx_point_in(x, y, ctx_flyout_rect())
	}
	return false
}

// CTX_ROW_GAP is the 1px gutter between context-menu rows (draw_context_menu's
// childGap). It is part of the row geometry, so click/hover tests that resolve
// a row from the container box must agree with it.
CTX_ROW_GAP :: 1

// ctx_row_rect is row `index` within a context-menu container box: the rows
// stack at BUTTON_HEIGHT tall with CTX_ROW_GAP gutters, inset left/right/top
// by CONTEXT_MENU_EDGE (border + padding), exactly as draw_context_menu lays
// them out.
ctx_row_rect :: proc(box: clay.BoundingBox, index: int) -> clay.BoundingBox {
	return clay.BoundingBox {
		x = box.x + CONTEXT_MENU_EDGE,
		y = box.y + CONTEXT_MENU_EDGE + f32(index) * (BUTTON_HEIGHT + CTX_ROW_GAP),
		width = CONTEXT_MENU_W,
		height = BUTTON_HEIGHT,
	}
}

// ctx_row_hit returns the index of the menu row under (x, y) within `box`, or
// -1. The 1px row gutters resolve to the row BELOW them (so a click on a seam
// still acts on the row under it).
ctx_row_hit :: proc(x, y: f32, box: clay.BoundingBox) -> int {
	if ctx_point_in(x, y, box) == false {
		return -1
	}
	at_y := y - (box.y + CONTEXT_MENU_EDGE)
	if at_y < 0 {
		return -1
	}
	i := int(at_y / (BUTTON_HEIGHT + CTX_ROW_GAP))
	if i < 0 || i > 7 {
		return -1
	}
	if ctx_point_in(x, y, ctx_row_rect(box, i)) == false &&
	   at_y - f32(i) * (BUTTON_HEIGHT + CTX_ROW_GAP) >= BUTTON_HEIGHT {
		// Cursor in the gutter between row i and i+1: fold it down to i+1 when
		// that row exists and is under the cursor.
		if i + 1 <= 7 && ctx_point_in(x, y, ctx_row_rect(box, i + 1)) {
			return i + 1
		}
		return -1
	}
	return i
}

// ctx_option renders one row (option) of the floating timeline context menu.
// Rows are borderless and highlight as a solid band on hover so the menu reads
// as one widget, not a grid of cells.
ctx_option :: proc(id_name: string, label: string) {
	hover := clay.PointerOver(clay.ID(id_name))
	if clay.UI(clay.ID(id_name))(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(CONTEXT_MENU_W),
				height = clay.SizingFixed(BUTTON_HEIGHT),
			},
			padding = clay.Padding{left = BUTTON_H_PAD, right = BUTTON_H_PAD},
			childAlignment = {x = .Left, y = .Center},
		},
		backgroundColor = hover ? BUTTON_HOVER : BUTTON,
		cornerRadius = clay.CornerRadiusAll(0),
	},
	) {
		clay.Text(
			label,
			clay.TextElementConfig {
				textColor = hover ? BUTTON_BORDER_HOVER : TEXT,
				fontSize = FONT_NORMAL,
			},
		)
	}
}

// ctx_add_row renders the "Add >" row that opens the submenu when hovered (or
// clicked). It is highlighted while hovered AND while the submenu is showing
// (so the parent row stays lit while the cursor sits in the flyout).
ctx_add_row :: proc() {
	hover := clay.PointerOver(clay.ID("CtxAdd")) || ctx_menu.submenu
	if clay.UI(clay.ID("CtxAdd"))(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(CONTEXT_MENU_W),
				height = clay.SizingFixed(BUTTON_HEIGHT),
			},
			padding = clay.Padding{left = BUTTON_H_PAD},
			childAlignment = {x = .Left, y = .Center},
		},
		backgroundColor = hover ? BUTTON_HOVER : BUTTON,
		cornerRadius = clay.CornerRadiusAll(0),
	},
	) {
		clay.Text(
			"Add",
			clay.TextElementConfig {
				textColor = hover ? BUTTON_BORDER_HOVER : TEXT,
				fontSize = FONT_NORMAL,
			},
		)
		if clay.UI(clay.ID("CtxAddChevron"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(BUTTON_HEIGHT)},
				childAlignment = {x = .Right, y = .Center},
			},
		},
		) {
			clay.Text(
				">",
				clay.TextElementConfig {
					textColor = hover ? BUTTON_BORDER_HOVER : TEXT,
					fontSize = FONT_NORMAL,
				},
			)
		}
	}
}

// draw_context_menu renders the right-click menu over the timeline as a
// floating overlay anchored at the pointer. Over empty space it offers "Add";
// right-clicking ON a clip adds clip actions (Rename/Duplicate/Delete/Link).
// The "Add >" row expands a flyout submenu positioned flush against its right
// edge (CONTEXT_MENU_W + the menu's 2px padding), listing the clip kinds. The
// flyout is a Root-attached overlay drawn at a fixed offset — never attached to
// the per-frame CtxAdd element, whose clay attach pass would lag a frame and
// make the flyout pop/flicker on the frame it appears. Menu item clicks are
// dispatched by the main loop (handle_ctx_option).
draw_context_menu :: proc() {
	if !ctx_menu.open {
		return
	}
	ctx_border := clay.BorderOutside(1)
	if clay.UI(clay.ID("CtxMenu"))(
	{
		layout = {
			sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})},
			layoutDirection = .TopToBottom,
			childGap = CTX_ROW_GAP,
			padding = clay.PaddingAll(CONTEXT_MENU_PAD),
		},
		backgroundColor = BUTTON,
		border = {color = BUTTON_BORDER, width = ctx_border},
		cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
		floating = {
			offset = {ctx_menu.x, ctx_menu.y},
			zIndex = 2000,
			attachTo = .Root,
			pointerCaptureMode = .Capture,
		},
	},
	) {
		ctx_add_row()
		if ctx_menu.target_clip_track >= 0 && ctx_menu.target_clip_track < len(timeline.tracks) {
			// Right-clicked a clip: offer clip-specific actions.
			clipped := &timeline.tracks[ctx_menu.target_clip_track].clips[ctx_menu.target_clip_index]
			ctx_option("CtxRename", "Rename")
			ctx_option("CtxDuplicate", "Duplicate")
			if clipped.link_id != 0 {
				ctx_option("CtxLink", "Unlink")
			} else {
				ctx_option("CtxLink", "Link")
			}
			ctx_option("CtxDelete", "Delete")
		}
	}
	// Flyout submenu to the right of the "Add >" row, shown while hovered.
	if ctx_menu.submenu {
		if clay.UI(clay.ID("CtxSubmenu"))(
		{
			layout = {
				sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})},
				layoutDirection = .TopToBottom,
				childGap = CTX_ROW_GAP,
				padding = clay.PaddingAll(CONTEXT_MENU_PAD),
			},
			backgroundColor = BUTTON,
			border = {color = BUTTON_BORDER, width = ctx_border},
			cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
			floating = {
				offset = {
					ctx_menu.x + CONTEXT_MENU_W + 2 * CONTEXT_MENU_EDGE,
					ctx_menu.y + CONTEXT_MENU_EDGE,
				},
				zIndex = 2001,
				attachTo = .Root,
				clipTo = .None,
			},
		},
		) {
			ctx_option("CtxTextClip", "Text Clip")
			ctx_option("CtxSubtitleClip", "Subtitle Clip (.srt)")
		}
	}
}

// ---------------------------------------------------------------------------
// Help overlay ("?" / F1).
// ---------------------------------------------------------------------------

// Help_Shortcut is one row of the help overlay: the key(s) and what they do.
Help_Shortcut :: struct {
	key:    string,
	action: string,
}

HELP_SHORTCUTS :: []Help_Shortcut {
	{"Space", "Play / pause"},
	{"H / L", "Jog backward / forward"},
	{"I / O", "Set render-range start / end at the playhead"},
	{"S", "Split clip at playhead"},
	{"Ctrl+R", "Rename selected clip"},
	{"U", "Link / unlink selection"},
	{"Backspace", "Delete (ripple) selected clip or group"},
	{"Delete", "Delete selected clip (raw)"},
	{"Esc", "Dismiss menu / dialog"},
	{"F1 / ?", "Toggle this overlay"},
	{"Wheel over ruler/timeline", "Zoom about the playhead"},
	{"Wheel over track lanes", "Scroll the track list"},
	{"Drag timeline scrollbar", "Scroll the track list"},
	{"Middle-drag timeline", "Pan"},
	{"Alt+drag a handle", "Crop the selected box"},
	{"Shift+drag a handle", "Scale from center"},
}

// help_entry renders a single key/action row of the help overlay. The key gets
// the highlight color so the two columns scan as columns.
help_entry :: proc(shortcut: Help_Shortcut) {
	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = CARD_GAP,
			childAlignment = {x = .Left, y = .Center},
		},
	},
	) {
		clay.Text(
			shortcut.key,
			clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_NORMAL},
		)
		clay.Text(
			shortcut.action,
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL},
		)
	}
}

// draw_help_overlay renders the keyboard-shortcut reference as a centered
// floating panel. Dismissed by clicking outside it, by the "?" button, by F1,
// or by Esc.
draw_help_overlay :: proc(width, height: c.int) {
	if !help_open {
		return
	}
	pw := min(f32(560), f32(width) * 0.9)
	px := (f32(width) - pw) / 2
	py := f32(height) * 0.1
	if clay.UI(clay.ID("HelpPanel"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(pw), height = clay.SizingFit({})},
			layoutDirection = .TopToBottom,
			childGap = BUTTON_ROW_GAP,
			padding = clay.PaddingAll(PANEL_PADDING),
			childAlignment = {x = .Left, y = .Top},
		},
		backgroundColor = BUTTON,
		border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
		cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
		floating = {
			offset = {px, py},
			zIndex = 300,
			attachTo = .Root,
			pointerCaptureMode = .Capture,
		},
	},
	) {
		clay.Text(
			"Keyboard Shortcuts",
			clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_HEADING},
		)
		clay.Text(
			"F1 or the ? button toggles this overlay; Esc or a click outside closes it.",
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
		)
		for i := 0; i < len(HELP_SHORTCUTS); i += 2 {
			if clay.UI()(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
					layoutDirection = .LeftToRight,
					childGap = SECTION_GAP,
				},
			},
			) {
				shortcuts := HELP_SHORTCUTS
				help_entry(shortcuts[i])
				if i + 1 < len(shortcuts) {
					help_entry(shortcuts[i + 1])
				}
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Text-input dialog.
// ---------------------------------------------------------------------------

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
	} else if ti.input_type == TI_PLAYHEAD {
		title = "Go to Time"
	}
	if clay.UI(clay.ID("TextInputPopup"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(pw), height = clay.SizingFit({})},
			layoutDirection = .TopToBottom,
			childGap = BUTTON_ROW_GAP,
			padding = clay.PaddingAll(PANEL_PADDING),
			childAlignment = {x = .Left, y = .Top},
		},
		backgroundColor = BUTTON,
		border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
		cornerRadius = clay.CornerRadiusAll(RADIUS_PANEL),
		floating = {
			offset = {px, py},
			zIndex = 3000,
			attachTo = .Root,
			pointerCaptureMode = .Capture,
		},
	},
	) {
		hint_buf := UI_TEXT_HINT[:]
		clay.Text(
			fmt.bprintf(hint_buf[:], "%s — Enter to confirm, Esc to cancel", title),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
		)
		if ti.input_type == TI_PLAYHEAD {
			clay.Text(
				"timecode 1:23:45:06 · seconds 12.5 · frames 1234",
				clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_SMALL},
			)
		}
		if clay.UI(clay.ID("TextInputField"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(34)},
				padding = clay.Padding{left = CARD_GAP, right = CARD_GAP},
				childAlignment = {x = .Left, y = .Center},
			},
			backgroundColor = TEXT_INPUT_BG,
			border = {color = BUTTON_BORDER_HOVER, width = clay.BorderOutside(1)},
			cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
		},
		) {
			if len(ti.buf) > 0 {
				clay.Text(
					text_input_string(),
					clay.TextElementConfig{textColor = TEXT, fontSize = TEXT_INPUT_FONT},
				)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Media bin panel.
// ---------------------------------------------------------------------------

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
	case .Subtitles:
		return "subtitles"
	case:
		return "other"
	}
}

// media_bin_header renders the "Media Bin" title and the Import button.
media_bin_header :: proc() {
	if clay.UI(clay.ID("MediaBinHeader"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap = BUTTON_ROW_GAP,
			childAlignment = {x = .Center, y = .Center},
		},
	},
	) {
		clay.Text(
			"Media Bin",
			clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = FONT_SMALL},
		)
		if clay.UI(clay.ID("BinImportButton"))(
		{
			layout = {
				sizing = {
					width = clay.SizingFixed(f32(BUTTON_HEIGHT) * 2),
					height = clay.SizingFixed(f32(BUTTON_HEIGHT)),
				},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
			border = {
				color = clay.Hovered() ? BUTTON_BORDER_HOVER : BUTTON_BORDER,
				width = clay.BorderOutside(1),
			},
			cornerRadius = clay.CornerRadiusAll(RADIUS_BUTTON),
		},
		) {
			clay.Text(
				"Import",
				clay.TextElementConfig {
					textColor = clay.Hovered() ? BUTTON_BORDER_HOVER : TEXT,
					fontSize = FONT_NORMAL,
				},
			)
		}
	}
}

// media_bin_grid lays out the imported assets as a wrapped thumbnail grid
// inside a manually-scrolled clip (childOffset = -media_bin_scroll, matching
// the TracksSection pattern). Column count derives from the bin width; rows
// wrap once the cells exceed it.
media_bin_grid :: proc() {
	if len(media_assets) == 0 {
		clay.Text(
			"No media imported",
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_NORMAL},
		)
		return
	}
	cols := media_bin_cols()
	total_rows := (len(media_assets) + cols - 1) / cols
	if clay.UI(clay.ID("MediaBinScroll"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			layoutDirection = .TopToBottom,
			childGap = CARD_GAP,
		},
		clip = {vertical = true, childOffset = {0, -media_bin_scroll}},
	},
	) {
		for row in 0 ..< total_rows {
			if clay.UI(clay.ID("MediaRow", u32(row)))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow({}),
						height = clay.SizingFixed(media_bin_row_height()),
					},
					layoutDirection = .LeftToRight,
					childGap = CARD_GAP,
				},
			},
			) {
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
	if clay.UI(clay.ID("MediaItem", u32(index)))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(MEDIA_CELL_W), height = clay.SizingGrow({})},
			padding = clay.PaddingAll(u16(MEDIA_ITEM_PAD)),
			layoutDirection = .TopToBottom,
			childGap = u16(4),
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
		border = {
			color = selected ? SELECT_BORDER : BUTTON_BORDER,
			width = clay.BorderOutside(selected ? 2 : 1),
		},
		cornerRadius = clay.CornerRadiusAll(RADIUS_WIDGET),
	},
	) {
		if !clay.UI(clay.ID("MediaItemThumb", u32(index)))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(MEDIA_THUMB_H)},
			},
			backgroundColor = clay.Color{61, 72, 77, 255},
			cornerRadius = clay.CornerRadiusAll(4),
		},
		) {
		}
		clay.Text(
			path_basename(asset.path),
			clay.TextElementConfig{textColor = TEXT, fontSize = FONT_SMALL},
		)
	}
}
