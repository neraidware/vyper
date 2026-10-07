package main

import clay "../vyper/clay-odin"
import "core:fmt"
import "core:c"

measure_text :: proc "c" (text: clay.StringSlice, config: ^clay.TextElementConfig, userData: rawptr) -> clay.Dimensions {
	return {width = 100, height = 20}
}

clay_error :: proc "c" (errorData: clay.ErrorData) {
	_ = errorData
}

main :: proc() {
	BAY := u64(64 * 1024 * 1024)
	memory := make([^]u8, BAY)
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(c.size_t(BAY), memory),
		{1280, 720},
		{handler = clay_error},
	)
	clay.SetMeasureTextFunction(measure_text, nil)
	clay.SetLayoutDimensions({1280, 720})
	clay.BeginLayout()

	TRACK_ROW_H := clay.SizingFixed(54)
	TRACK_GAP_H := clay.SizingFixed(20)
	GUTTER_WIDTH := clay.SizingFixed(140)

	if clay.UI(clay.ID("Parent"))(
	{
		layout = {
			sizing = {clay.SizingGrow({}), clay.SizingFixed(150)},
			layoutDirection = .TopToBottom,
			childGap = 8,
			padding = clay.PaddingAll(4),
		},
	},
	) {
		if clay.UI(clay.ID("Toolbar"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(40)},
				layoutDirection = .LeftToRight,
			},
		},
		) {
			if clay.UI(clay.ID("Btn"))(
			{
				layout = {sizing = {width = clay.SizingFixed(60), height = clay.SizingGrow({})}},
				backgroundColor = clay.Color{200, 0, 0, 255},
			},
			) {}
		}
		if clay.UI(clay.ID("TrackArea"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				layoutDirection = .LeftToRight,
			},
		},
		) {
			if clay.UI(clay.ID("TracksSection"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
					layoutDirection = .TopToBottom,
					childGap = 0,
				},
				clip = {vertical = true, childOffset = {0, 0}},
			},
			) {
				for i in 0 ..< 6 {
					if clay.UI(clay.ID("TrackGap", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow({}), height = TRACK_GAP_H},
							layoutDirection = .LeftToRight,
							childGap = 0,
						},
					},
					) {
						if clay.UI(clay.ID("AddTrack", u32(i)))(
						{
							layout = {
								sizing = {width = GUTTER_WIDTH, height = clay.SizingGrow({})},
							},
							backgroundColor = clay.Color{40, 40, 40, 255},
						},
						) {}
					}
					if clay.UI(clay.ID("TrackRow", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow({}), height = TRACK_ROW_H},
							layoutDirection = .LeftToRight,
							childGap = 8,
						},
					},
					) {
						if clay.UI(clay.ID("TrackName", u32(i)))(
						{
							layout = {
								sizing = {width = GUTTER_WIDTH, height = clay.SizingGrow({})},
							},
							backgroundColor = clay.Color{60, 60, 60, 255},
						},
						) {
							clay.Text("track", clay.TextElementConfig {textColor = clay.Color{255, 255, 255, 255}, fontSize = 14})
						}
						if clay.UI(clay.ID("ClipsSection", u32(i)))(
						{
							layout = {
								sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
								layoutDirection = .LeftToRight,
							},
							backgroundColor = clay.Color{90, 90, 90, 255},
							clip = {horizontal = true, vertical = true, childOffset = {0, 0}},
						},
						) {
							for c in 0 ..< 12 {
								if clay.UI(clay.ID("TimelineClip", u32(i * 1000 + c)))(
								{
									layout = {
										sizing = {width = clay.SizingFixed(120), height = clay.SizingGrow({})},
										layoutDirection = .LeftToRight,
									},
									backgroundColor = clay.Color{30, 90, 200, 255},
								},
								) {}
							}
						}
					}
				}
			}
		}
	}
	commands := clay.EndLayout(0)
	R, B, T := 0, 0, 0
	for i in 0 ..< commands.length {
		c2 := clay.RenderCommandArray_Get(&commands, i)
		#partial switch c2.commandType {
		case .Rectangle:
			R += 1
		case .Border:
			B += 1
		case .Text:
			T += 1
		}
	}
	fmt.printf("[micro] total=%d rect=%d border=%d text=%d\n", commands.length, R, B, T)
}