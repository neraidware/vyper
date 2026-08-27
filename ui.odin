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
						border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
						cornerRadius = clay.CornerRadiusAll(8),
					}) {
						clay.Text("Project", clay.TextElementConfig{textColor = BUTTON_BORDER_HOVER, fontSize = 13})
						clay.Text(fmt.aprintf("Name: %s", project.name), clay.TextElementConfig{textColor = TEXT, fontSize = 15})
						clay.Text(fmt.aprintf("Resolution: %dx%d", project.width, project.height), clay.TextElementConfig{textColor = TEXT, fontSize = 15})
					}
					if clay.UI(clay.ID("MediaBin"))({
						layout = {
							sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
							padding = clay.PaddingAll(16),
							childGap = 8,
							layoutDirection = .TopToBottom,
						},
						backgroundColor = BUTTON,
						border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
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
							border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
							cornerRadius = clay.CornerRadiusAll(8),
						}) {
							for line in strings.split_lines(file_info_text) {
								clay.Text(line, clay.TextElementConfig{textColor = TEXT, fontSize = 14})
							}
						}
					}
				}
				if clay.UI(clay.ID("PreviewColumn"))({
					layout = {sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})}, layoutDirection = .TopToBottom, childGap = 12},
					border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
					cornerRadius = clay.CornerRadiusAll(6),
				}) {
					pw, ph := project_preview_size()
					if clay.UI(clay.ID("Preview"))({
						layout = {sizing = {width = clay.SizingFixed(pw), height = clay.SizingFixed(ph)}},
						image = {imageData = nil},
					}) {
					}
					if clay.UI(clay.ID("ActionsArea"))({
						layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, childAlignment = {x = .Center, y = .Top}},
					}) {
						if clay.UI(clay.ID("PlayPause"))({
							layout = {sizing = {width = clay.SizingFixed(96), height = clay.SizingFixed(28)}, childAlignment = {x = .Center, y = .Center}},
							backgroundColor = BUTTON,
							border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
							cornerRadius = clay.CornerRadiusAll(4),
						}) {
							if playhead.playing {
								clay.Text("Pause", clay.TextElementConfig{textColor = TEXT, fontSize = 14})
							} else {
								clay.Text("Play", clay.TextElementConfig{textColor = TEXT, fontSize = 14})
							}
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
					border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
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
								border = {color = editing_field == 1 ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(2)},
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
								border = {color = editing_field == 2 ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(2)},
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
								border = {color = editing_field == 3 ? BUTTON_BORDER_HOVER : BUTTON_BORDER, width = clay.BorderOutside(2)},
								cornerRadius = clay.CornerRadiusAll(6),
							}) {
								clay.Text(fmt.aprintf("Scale: %s", scl_val), clay.TextElementConfig{textColor = editing_field == 3 ? BUTTON_BORDER_HOVER : TEXT, fontSize = 15})
							}
							clay.Text(fmt.aprintf("Crop: L %.0f%% R %.0f%% T %.0f%% B %.0f%%", cl.crop_l * 100, cl.crop_r * 100, cl.crop_t * 100, cl.crop_b * 100), clay.TextElementConfig{textColor = TEXT, fontSize = 13})
						}
					} else {
						clay.Text("No clip selected", clay.TextElementConfig{textColor = TEXT, fontSize = 14})
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
							border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
						}) {
							clay.Text("Open file", clay.TextElementConfig{textColor = TEXT, fontSize = 18, textAlignment = .Center})
						}
					}
				} else {
					if clay.UI(clay.ID("ClipTimeline"))({
						layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, padding = clay.PaddingAll(12), layoutDirection = .LeftToRight, childGap = 16},
						backgroundColor = BUTTON,
						cornerRadius = clay.CornerRadiusAll(8),
						border = {color = BUTTON_BORDER, width = clay.BorderOutside(2)},
					}) {
						if clay.UI(clay.ID("TracksSection"))({
							layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, layoutDirection = .TopToBottom, childGap = 0},
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
											border = {color = BUTTON_BORDER, width = clay.BorderOutside(1)},
											cornerRadius = clay.CornerRadiusAll(4),
										}) {
											clay.Text("+\nv", clay.TextElementConfig{textColor = TEXT, fontSize = 13})
										}
									}
									if clay.UI(clay.ID("ClipsSection", u32(track_idx)))({
										layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}, layoutDirection = .LeftToRight, childGap = 16},
										clip = {horizontal = true, vertical = true},
									}) {
										for timeline_clip, index in track.clips {
											if timeline_clip.timeline_start_frame > 0 {
												if clay.UI(clay.ID("ClipOffset", u32(track_idx * 1000 + index)))({
													layout = {sizing = {width = clay.SizingFixed(f32(timeline_clip.timeline_start_frame)), height = clay.SizingGrow({})}},
												}) {}
											}
											clip_width := f32(max(timeline_clip.source_length_frames, 1))
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
											if clay.UI(clay.ID("TimelineClip", u32(track_idx * 1000 + index)))({
												layout = {sizing = {width = clay.SizingFixed(clip_width), height = clay.SizingFixed(56)}, padding = clay.PaddingAll(8)},
												backgroundColor = clip_color,
												cornerRadius = clay.CornerRadiusAll(6),
												border = {color = clip_border, width = clay.BorderOutside(clip_border_w)},
											}) {
												clay.Text(clip_label, clay.TextElementConfig{textColor = TEXT, fontSize = 18})
											}
										}
									}
								}
							}
						}
						if clay.UI(clay.ID("Playhead"))({
							layout = {
								sizing = {width = clay.SizingFixed(10), height = clay.SizingFixed(10)},
								childAlignment = {x = .Center, y = .Center},
							},
							backgroundColor = BUTTON_BORDER_HOVER,
							cornerRadius = clay.CornerRadiusAll(5),
							floating = {offset = {f32(playhead.frame), 0}, attachTo = .ElementWithId, parentId = clay.ID("ClipsSection", 0).id, attachment = {element = .CenterTop, parent = .LeftTop}},
						}) {}
						}
					}
				}
			}
		}

	return clay.EndLayout(0)
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
