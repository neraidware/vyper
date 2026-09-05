package main

import "core:c"
import "core:math"
import clay "clay-odin"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Media bin: grid geometry, drag-to-timeline drop computation, and the custom
// GPU draws (bin thumbnails + the per-lane drop ghost).
//
// The bin grid itself is laid out by ui.odin; this file measures cells and
// draws over them, and turns a bin-item drag into concrete timeline lanes --
// one lane per media stream (a video lane plus one lane per audio stream).
// Each lane is placed against the overlap rules of its target track, and a
// lane that does not exist yet becomes a new track appended at the bottom.
// ---------------------------------------------------------------------------

// media_bin_cols resolves the current column count of the grid from the
// measured bin width (previous frame's layout; defaults to 2 before the first
// frame). Cell geometry lives in layout.odin (MEDIA_CELL_W etc.).
media_bin_cols :: proc() -> int {
	mb := clay.GetElementData(clay.ID("MediaBin")).boundingBox
	if mb.width <= 0 {
		return 2
	}
	w := mb.width - f32(PANEL_PADDING) * 2
	cols := int((w + CARD_GAP) / (MEDIA_CELL_W + CARD_GAP))
	return clamp(cols, 1, 3)
}

// media_bin_row_height is the vertical span of one grid row (thumb area +
// label + cell padding + row gap).
media_bin_row_height :: proc() -> f32 {
	return MEDIA_THUMB_H + MEDIA_LABEL_H + MEDIA_ITEM_PAD * 2 + CARD_GAP
}

// media_bin_max_scroll is the largest usable vertical scroll offset for the
// bin's manual clip scroll, so media_bin_scroll never lets the grid drift
// above its first cell or below its last. 0 when the grid fits (or empty).
media_bin_max_scroll :: proc() -> f32 {
	mb := clay.GetElementData(clay.ID("MediaBin")).boundingBox
	if mb.width <= 0 || len(media_assets) == 0 {
		return 0
	}
	cols := media_bin_cols()
	rows := (len(media_assets) + cols - 1) / cols
	content := f32(rows) * media_bin_row_height()
	// Approximate the header ("Media Bin" label + Import button row) so the
	// viewport height the grid scrolls within is roughly the panel's body.
	header := f32(BUTTON_HEIGHT) + f32(FONT_SMALL) + CARD_GAP * 3
	view := mb.height - f32(PANEL_PADDING) * 2 - header
	return max(content - view, 0)
}

// media_bin_item_at returns the index of the bin cell under the pointer, or -1.
media_bin_item_at :: proc(mx, my: f32) -> int {
	for i in 0 ..< len(media_assets) {
		if clay.PointerOver(clay.ID("MediaItem", u32(i))) {
			return i
		}
	}
	return -1
}

// compute_media_drop_lanes computes the concrete lanes a drop of `asset` on
// `target_track` at `frame` would occupy: a video lane first (when the asset
// has video), then one audio lane per audio stream, each on target_track + s.
// Every lane lands on the SAME frame (the anchor lane's clamped placement),
// mirroring add_asset_to_timeline: an import must never desync its own streams.
// A lane that already exists is only eligible if it can host that exact frame;
// otherwise the whole drop is marked blocked (refused on release) -- never a
// silent per-lane clamp.
compute_media_drop_lanes :: proc(asset: ^Media_Asset, target_track: int, frame: i64, lanes: ^[dynamic]Media_Lane) {
	clear(lanes)
	if asset == nil {
		return
	}
	n_lanes := int(asset.audio_streams)
	if asset.kind == .Video {
		n_lanes += 1
	}
	if n_lanes <= 0 {
		return
	}
	base := max(target_track, 0)
	anchor_len := asset.frame_count
	if asset.kind != .Video {
		anchor_len = asset.audio_frames
	}
	anchor_placed := max(frame, 0)
	if base < len(timeline.tracks) {
		anchor_placed = clip_place_in_track(&timeline.tracks[base], -1, anchor_len, anchor_placed)
	}
	blocked := false
	for offset in 1 ..< n_lanes {
		lane := base + offset
		if lane < len(timeline.tracks) && lane_blocked(&timeline.tracks[lane], anchor_placed, asset.audio_frames) {
			blocked = true
		}
	}
	for offset in 0 ..< n_lanes {
		lane := base + offset
		is_video := asset.kind == .Video && offset == 0
		lane_len := is_video ? asset.frame_count : asset.audio_frames
		created := lane >= len(timeline.tracks)
		append(lanes, Media_Lane{
			track_idx = lane,
			created = created,
			placed = anchor_placed,
			blocked = blocked,
			clip_len = lane_len,
			kind = is_video ? .Video : .Audio,
			stream_index = c.int(offset - (asset.kind == .Video ? 1 : 0)),
			video_thumb_id = asset.id,
			has_video_thumb = is_video && asset.has_thumb,
		})
	}
}

// timeline_drop_target returns the track whose clip lane the pointer is over
// (an existing lane), or, when the pointer hangs in the empty region below the
// last lane, the append target len(timeline.tracks) -- tracks that don't exist
// yet but a drop there would create (the ghost paints them as ghost tracks).
// Returns 0 when the timeline is empty and the pointer is over the
// empty-timeline area (a drop there creates the media's tracks). -1 = not over
// any lane.
timeline_drop_target :: proc(mx, my: f32) -> int {
	for ti in 0 ..< len(timeline.tracks) {
		lane := clay.GetElementData(clay.ID("ClipsSection", u32(ti))).boundingBox
		if lane.width > 0 && my >= lane.y && my <= lane.y + lane.height {
			return ti
		}
	}
	// Below the last existing lane: an append would create the media's tracks
	// there. The pointer must stay within the lane region horizontally so the
	// dead space around a short ruler doesn't spawn ghost tracks.
	if len(timeline.tracks) > 0 {
		last := clay.GetElementData(clay.ID("ClipsSection", u32(len(timeline.tracks) - 1))).boundingBox
		if last.width > 0 && my >= last.y + last.height && mx >= last.x && mx <= last.x + last.width {
			return len(timeline.tracks)
		}
	}
	if len(timeline.tracks) == 0 {
		empty := clay.GetElementData(clay.ID("EmptyTimeline")).boundingBox
		if empty.width > 0 && mx >= empty.x && mx <= empty.x + empty.width && my >= empty.y && my <= empty.y + empty.height {
			return 0
		}
	}
	return -1
}

// timeline_frame_from_x converts a pointer x into a timeline frame for a drop
// (the frame a clip would start at if placed where the pointer is).
timeline_frame_from_x :: proc(mx: f32) -> i64 {
	if len(timeline.tracks) > 0 {
		start := clay.GetElementData(clay.ID("ClipsSection", 0)).boundingBox.x
		if start > 0 {
			return max(0, i64((mx - start) / timeline_zoom + timeline_view_start))
		}
	}
	empty := clay.GetElementData(clay.ID("EmptyTimeline")).boundingBox
	if empty.width > 0 {
		return max(0, i64((mx - empty.x) / timeline_zoom + timeline_view_start))
	}
	return 0
}

// lane_box_for returns the on-screen box of a drop lane: the real clip lane
// for existing tracks, or a synthesized box below the last lane (respectively
// the empty-timeline body) for a lane whose track would be created.
lane_box_for :: proc(lane: Media_Lane) -> clay.BoundingBox {
	if !lane.created && lane.track_idx >= 0 && lane.track_idx < len(timeline.tracks) {
		return clay.GetElementData(clay.ID("ClipsSection", u32(lane.track_idx))).boundingBox
	}
	x0: f32
	y0: f32
	w: f32
	if len(timeline.tracks) > 0 {
		last := clay.GetElementData(clay.ID("ClipsSection", u32(len(timeline.tracks) - 1))).boundingBox
		if last.width > 0 {
			x0 = last.x
			w = last.width
			// An appended track renders as its own leading insert gap + row, so
			// the first created lane sits one TRACK_GAP_H below the last row and
			// consecutive created rows pitch by CLIP_TILE_HEIGHT + TRACK_GAP_H.
			below := lane.track_idx - len(timeline.tracks)
			y0 = last.y + last.height + TRACK_GAP_H + f32(below) * (CLIP_TILE_HEIGHT + TRACK_GAP_H)
		}
	}
	if w <= 0 {
		empty := clay.GetElementData(clay.ID("EmptyTimeline")).boundingBox
		if empty.width <= 0 {
			return {}
		}
		x0 = empty.x + f32(TIMELINE_PADDING)
		w = empty.width - f32(TIMELINE_PADDING) * 2
		y0 = empty.y + f32(TIMELINE_PADDING) + RULER_HEIGHT + f32(lane.track_idx) * (CLIP_TILE_HEIGHT + TRACK_GAP_H)
	}
	return {x = x0, y = y0, width = w, height = CLIP_TILE_HEIGHT}
}

// begin_media_drag arms a bin-item drag: selects the asset and, from the
// current pointer position, computes the lanes + ghost.
begin_media_drag :: proc(asset_index: int, mx, my: f32) {
	if asset_index < 0 || asset_index >= len(media_assets) {
		return
	}
	asset := &media_assets[asset_index]
	selected_asset_id = asset.id
	dragging_media_from_bin = true
	media_drag_asset_id = asset.id
	media_drag_asset_index = asset_index
	item := clay.GetElementData(clay.ID("MediaItem", u32(asset_index))).boundingBox
	media_drag_pick_dx = mx - item.x
	media_drag_pick_dy = my - item.y
	media_drag_mx = mx
	media_drag_my = my
	update_media_drag_lanes(mx, my)
}

// update_media_drag_lanes recomputes the drop target + ghost lanes while a bin
// drag is in flight (called every mouse-move while down).
update_media_drag_lanes :: proc(mx, my: f32) {
	if !dragging_media_from_bin {
		return
	}
	media_drag_mx = mx
	media_drag_my = my
	target := timeline_drop_target(mx, my)
	media_drag_target = target
	if target < 0 {
		clear(&media_drag_lanes)
		return
	}
	asset := find_asset(media_drag_asset_id)
	if asset == nil {
		clear(&media_drag_lanes)
		return
	}
	media_drag_frame = timeline_frame_from_x(mx)
	compute_media_drop_lanes(asset, target, media_drag_frame, &media_drag_lanes)
}

// end_media_drag finishes a bin drag: when released over a valid lane, adds
// the media to the timeline (creating tracks as needed), then clears all drag
// state. Releasing nowhere just cancels the drag (the asset stays in the bin).
end_media_drag :: proc(mx, my: f32) {
	target := timeline_drop_target(mx, my)
	if target >= 0 {
		add_asset_to_timeline(media_drag_asset_id, target, timeline_frame_from_x(mx))
	}
	dragging_media_from_bin = false
	media_drag_asset_id = 0
	media_drag_asset_index = -1
	media_drag_target = -1
	clear(&media_drag_lanes)
}

// media_kind_color is the placeholder fill for a bin cell with no thumbnail
// (audio, unprobeable files), and the ghost fill for non-video lanes.
media_kind_color :: proc(kind: Media_Kind) -> clay.Color {
	#partial switch kind {
	case .Audio:
		return AUDIO_CLIP
	case .Video:
		return clay.Color{52, 66, 84, 255} // muted blue for a video without a thumb
	case:
		return BUTTON
	}
}

// draw_tex_quad draws a textured quad (full preview pipeline path) for the bin
// thumbnails and the drag ghost.
draw_tex_quad :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, bounds: clay.BoundingBox, texture: ^sdl.GPUTexture, uv: [4]f32) {
	if renderer.preview_pipeline == nil || texture == nil {
		return
	}
	vertex_uniforms := TextVertexUniforms{
		bounds = {bounds.x, bounds.y, bounds.width, bounds.height},
		viewport = renderer.viewport,
		_padding = {},
		uv = uv,
	}
	sdl.BindGPUGraphicsPipeline(pass, renderer.preview_pipeline)
	binding := sdl.GPUTextureSamplerBinding{texture = texture, sampler = renderer.preview_sampler}
	sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
	sdl.PushGPUVertexUniformData(command_buffer, 0, &vertex_uniforms, sdl.Uint32(size_of(vertex_uniforms)))
	sdl.DrawGPUPrimitives(pass, 6, 1, 0, 0)
}

// thumb_box_for returns the on-screen box the bin draw paints the asset's
// thumbnail into (the "MediaItemThumb" cell region laid out by ui.odin).
thumb_box_for :: proc(asset_index: int) -> clay.BoundingBox {
	return clay.GetElementData(clay.ID("MediaItemThumb", u32(asset_index))).boundingBox
}

// draw_media_bin_thumbnails paints every bin cell's thumbnail area over the
// laid-out grid: the asset's texture for files with a decoded thumb, else a
// kind-colored placeholder.
draw_media_bin_thumbnails :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass) {
	for i in 0 ..< len(media_assets) {
		asset := &media_assets[i]
		box := thumb_box_for(i)
		if box.width <= 0 || box.height <= 0 {
			continue
		}
		if asset.has_thumb && asset.thumb_tex != nil {
			draw_tex_quad(renderer, command_buffer, pass, box, asset.thumb_tex, {0, 0, 1, 1})
		} else {
			render_sdf_rect(renderer, command_buffer, pass, box, media_kind_color(asset.kind), 4, 1)
		}
	}
}

// draw_media_drag_ghost paints the drop preview while dragging a bin asset onto
// the timeline. Two things render, mirroring OS file drag-and-drop:
//   - a cursor-following drag tile (the asset's thumbnail + name) for the whole
//     gesture, so there is always visible feedback while dragging;
//   - one translucent insert tile per lane the media would occupy, at its
//     clamped placed frame, when the pointer hovers a timeline lane (the video
//     lane carries the asset's thumbnail).
// The media is only committed to the timeline on release over a lane
// (end_media_drag); nothing here mutates the timeline.
draw_media_drag_ghost :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass) {
	if !dragging_media_from_bin {
		return
	}
	asset := find_asset(media_drag_asset_id)
	if asset == nil {
		return
	}
	if media_drag_target >= 0 && len(media_drag_lanes) > 0 {
		for lane in media_drag_lanes {
			lane_box := lane_box_for(lane)
			if lane_box.width <= 0 || lane_box.height <= 0 {
				continue
			}
			if lane.created {
				// Ghost track: this lane doesn't exist yet; a drop here would
				// create it. Paint a faint row across the whole lane so the
				// upcoming track is visible as a track (not just a floating
				// tile), with the tile drawn on top below. The name-gutter
				// header is painted too so the row reads as a full track. The
				// scissor is reset to the full window first: an earlier lane in
				// the loop may have left it clamped to its own box, which clips
				// this row (and its gutter header) out of frame.
				sdl.SetGPUScissor(pass, sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)})
				render_sdf_rect(renderer, command_buffer, pass, lane_box, clay.Color{52, 66, 84, 90}, 6, 1)
				rg := clay.GetElementData(clay.ID("RulerGutter")).boundingBox
				if rg.width > 0 {
					header := clay.BoundingBox{x = rg.x, y = lane_box.y, width = rg.width, height = lane_box.height}
					render_sdf_rect(renderer, command_buffer, pass, header, clay.Color{52, 66, 84, 90}, 0, 0)
				}
			}
			b := clay.BoundingBox{
				x = lane_box.x + (f32(lane.placed) - timeline_view_start) * timeline_zoom,
				y = lane_box.y,
				width = f32(lane.clip_len) * timeline_zoom,
				height = lane_box.height,
			}
			sdl.SetGPUScissor(pass, sdl.Rect{c.int(lane_box.x), c.int(lane_box.y), c.int(lane_box.width), c.int(lane_box.height)})
			if lane.blocked {
				// The lane can't host the aligned anchor frame, so the whole drop
				// will be refused on release. Paint it red so the user never has to
				// guess why nothing got placed.
				if lane.kind == .Video && lane.has_video_thumb {
					draw_tex_quad(renderer, command_buffer, pass, b, asset.thumb_tex, {0, 0, 1, 1})
				} else {
					fill := media_kind_color(lane.kind)
					fill[3] = 150
					render_sdf_rect(renderer, command_buffer, pass, b, fill, 6, 0)
				}
				render_sdf_rect(renderer, command_buffer, pass, b, clay.Color{255, 70, 70, 230}, 6, 2)
				continue
			}
			if lane.kind == .Video && lane.has_video_thumb {
				draw_tex_quad(renderer, command_buffer, pass, b, asset.thumb_tex, {0, 0, 1, 1})
				// Ghost veil so an in-flight tile reads as "will be placed", not a
				// live clip.
				render_sdf_rect(renderer, command_buffer, pass, b, clay.Color{255, 255, 255, 90}, 6, 0)
			} else {
				fill := media_kind_color(lane.kind)
				fill[3] = 170
				render_sdf_rect(renderer, command_buffer, pass, b, fill, 6, 0)
				audio_label := "Audio"
				w := f32(len(audio_label)) * f32(FONT_NORMAL) * 0.6
				render_text(renderer, command_buffer, pass, clay.BoundingBox{x = b.x + 6, y = b.y + b.height/2 - f32(FONT_NORMAL) * 0.5, width = w, height = f32(FONT_NORMAL)}, clay.TextRenderData{
					stringContents = clay.StringSlice{length = c.int32_t(len(audio_label)), chars = ([^]c.char)(raw_data(audio_label))},
					textColor = TEXT,
					fontSize = FONT_NORMAL,
					letterSpacing = 1,
					lineHeight = FONT_NORMAL,
				})
			}
			render_sdf_rect(renderer, command_buffer, pass, b, clay.Color{140, 200, 255, 220}, 6, 2)
		}
		sdl.SetGPUScissor(pass, sdl.Rect{0, 0, c.int(renderer.viewport.x), c.int(renderer.viewport.y)})
	}
	draw_media_drag_float(renderer, command_buffer, pass, asset)
}

// draw_media_drag_float paints the cursor-following drag tile (thumbnail +
// basename pill) for an in-flight media-bin drag. Shown the whole gesture, over
// the bin, the timeline, or empty space, exactly like dragging a file between
// windows. Freed to hover just below the cursor so it never hides the pointer.
draw_media_drag_float :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, asset: ^Media_Asset) {
	if asset == nil {
		return
	}
	tw := f32(96)
	th := tw * 9.0 / 16.0
	if asset.src_w > 0 && asset.src_h > 0 {
		aspect := f32(asset.src_w) / f32(asset.src_h)
		th = tw / aspect
		if th > 68 {
			th = 68
			tw = th * aspect
		}
	}
	tile := clay.BoundingBox{x = media_drag_mx + 12, y = media_drag_my + 16, width = tw, height = th}
	if asset.has_thumb && asset.thumb_tex != nil {
		draw_tex_quad(renderer, command_buffer, pass, tile, asset.thumb_tex, {0, 0, 1, 1})
	} else {
		render_sdf_rect(renderer, command_buffer, pass, tile, media_kind_color(asset.kind), 4, 1)
	}
	render_sdf_rect(renderer, command_buffer, pass, tile, clay.Color{140, 200, 255, 230}, 4, 2)
	name := path_basename(asset.path)
	label_w := f32(len(name)) * f32(FONT_SMALL) * 0.6
	pill := clay.BoundingBox{x = tile.x, y = tile.y + tile.height + 4, width = max(label_w + 8, 40), height = 16}
	render_sdf_rect(renderer, command_buffer, pass, pill, TOOLTIP_BG, 3, 0)
	render_text(renderer, command_buffer, pass, clay.BoundingBox{x = pill.x + 4, y = pill.y + 1, width = pill.width - 8, height = 14}, clay.TextRenderData{
		stringContents = clay.StringSlice{length = c.int32_t(len(name)), chars = ([^]c.char)(raw_data(name))},
		textColor = TOOLTIP_TEXT,
		fontSize = FONT_SMALL,
		letterSpacing = 1,
		lineHeight = FONT_SMALL,
	})
}

// ensure_asset_thumbnail_texture lazily creates the per-asset thumbnail GPU
// texture (owned by the asset; released at shutdown).
ensure_asset_thumbnail_texture :: proc(device: ^sdl.GPUDevice, asset: ^Media_Asset) {
	if asset.thumb_tex == nil {
		asset.thumb_tex = create_text_texture(device, THUMB_W, THUMB_H)
	}
}

// upload_asset_thumbnail uploads the asset's CPU thumbnail into its GPU texture
// (once, on first render after import; the upload must happen outside any
// render pass, on the frame's command buffer).
upload_asset_thumbnail :: proc(renderer: ^GPU_Renderer, command_buffer: ^sdl.GPUCommandBuffer, asset: ^Media_Asset) {
	if asset == nil || !asset.has_thumb || !asset.thumb_tex_dirty {
		return
	}
	ensure_asset_thumbnail_texture(renderer.device, asset)
	if asset.thumb_tex == nil {
		return
	}
	n := THUMB_W * THUMB_H * 4
	transfer := sdl.CreateGPUTransferBuffer(renderer.device, sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = u32(n)})
	if transfer == nil {
		return
	}
	defer sdl.ReleaseGPUTransferBuffer(renderer.device, transfer)
	mapped := sdl.MapGPUTransferBuffer(renderer.device, transfer, false)
	if mapped == nil {
		return
	}
	dst := ([^]u8)(mapped)[:n]
	copy(dst, asset.thumb_buf[:])
	sdl.UnmapGPUTransferBuffer(renderer.device, transfer)
	copy_pass := sdl.BeginGPUCopyPass(command_buffer)
	source := sdl.GPUTextureTransferInfo{transfer_buffer = transfer, pixels_per_row = THUMB_W, rows_per_layer = THUMB_H}
	destination := sdl.GPUTextureRegion{texture = asset.thumb_tex, w = THUMB_W, h = THUMB_H, d = 1}
	sdl.UploadToGPUTexture(copy_pass, source, destination, false)
	sdl.EndGPUCopyPass(copy_pass)
	asset.thumb_tex_dirty = false
}

// release_media_asset_textures frees every asset's owned thumbnail texture at
// shutdown.
release_media_asset_textures :: proc(device: ^sdl.GPUDevice) {
	for &a in media_assets {
		if a.thumb_tex != nil {
			sdl.ReleaseGPUTexture(device, a.thumb_tex)
			a.thumb_tex = nil
		}
	}
}