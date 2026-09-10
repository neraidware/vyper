package main

import clay "clay-odin"
import "core:c"
import "core:fmt"
import sdl "vendor:sdl3"

// Every clay element whose zIndex is >= this renders above the preview canvas
// (with the canvas drawn between the two render_clay passes). Flat base UI is
// zIndex 0; the floating overlays -- help overlay (300), playback-rate dropdown
// (1000), context menus (2000/2001), text-input modal (3000) -- all sit above.
OVERLAY_ABOVE_PREVIEW_Z :: 200

// ---------------------------------------------------------------------------
// Per-frame render: preview-slot updates + GPU transfers, then the swapchain
// present of the clay page + all overdraw passes. Owns the frame's command
// buffer and all the continue-on-failure paths (nil command buffer, lost
// swapchain). Returns false when nothing could be presented, so the caller's
// loop continues to the next frame exactly as the original inline code did.
// ---------------------------------------------------------------------------
render_ui_frame :: proc(
	device: ^sdl.GPUDevice,
	window: ^sdl.Window,
	renderer: ^GPU_Renderer,
	commands: clay.ClayArray(clay.RenderCommand),
	width, height: c.int,
	ui_dec_us: ^i64,
) -> bool {
	renderer.viewport = {f32(width), f32(height)}
	command_buffer := sdl.AcquireGPUCommandBuffer(device)
	if command_buffer == nil {
		return false
	}
	dec_t0 := sdl.GetTicksNS()
	update_preview_slots()
	ui_dec_us^ += i64(sdl.GetTicksNS() - dec_t0)
	for i in 0 ..< MAX_PREVIEW_SLOTS {
		slot := &preview_slots[i]
		if !slot.in_use {
			continue
		}
		if slot.is_text {
			// Text slots own a tightly-sized texture (full estimated buffer
			// bw x bh, stored in text_tex_w/h). update_preview_slots sets
			// text_recreate whenever it re-rasterizes (which is whenever the
			// buffer size could change), so recreate on that flag + first use.
			// A slot between subtitle cues has no ink yet (text_tex_w/h == 0
			// until the first cue renders) — skip creation so a freshly
			// reassigned slot never asks SDL for a 0x0 texture.
			if slot.texture == nil || slot.text_recreate {
				if slot.texture != nil {
					sdl.ReleaseGPUTexture(device, slot.texture)
					slot.texture = nil
				}
				if slot.text_tex_w > 0 && slot.text_tex_h > 0 {
					slot.texture = create_text_texture(device, slot.text_tex_w, slot.text_tex_h)
				}
			}
			slot.text_recreate = false
		} else if slot.texture == nil {
			slot.texture = renderer.preview_textures[i]
		}
		// Upload only the slots whose pixels actually changed this frame. The
		// re-upload is a full-frame GPU transfer (up to ~4MB per slot), and
		// every upload allocates + maps a transfer buffer — a blanket
		// "changed" upload dragged all 8 slots through that even when their
		// frame never moved (background slots holding a stale-but-correct
		// face). idempotent: tex_dirty is cleared by upload_preview_slot.
		if slot.tex_dirty {
			upload_preview_slot(renderer, command_buffer, slot)
		}
		// in_use only means the slot is claimed by some clip; it says
		// nothing about whether THIS slot has actually decoded a frame
		// for its CURRENT identity yet. Right after a clip_id change
		// (anchor_shifted in update_preview_slots), in_use stays true
		// but has_frame is deliberately false until a fresh decode
		// lands -- gating on in_use here painted whatever was still
		// sitting in the GPU texture from the PREVIOUS clip that owned
		// this slot for every frame the new decode took, which is
		// exactly the "old clip's image fighting the new one" bug.
	}
	// Free text textures orphaned by slot reassignment/invalidation earlier
	// this frame (they have no device in the preview state, so they wait
	// here where the device is).
	drain_pending_text_releases(device)
	// Upload decoded media-bin thumbnails (once per asset, after import).
	for &a in media_assets {
		upload_asset_thumbnail(renderer, command_buffer, &a)
	}
	swapchain_texture: ^sdl.GPUTexture
	pixel_width, pixel_height: sdl.Uint32
	if !sdl.WaitAndAcquireGPUSwapchainTexture(
		   command_buffer,
		   window,
		   &swapchain_texture,
		   &pixel_width,
		   &pixel_height,
	   ) ||
	   swapchain_texture == nil {
		_ = sdl.CancelGPUCommandBuffer(command_buffer)
		return false
	}
	renderer.viewport = {f32(pixel_width), f32(pixel_height)}
	color_target := sdl.GPUColorTargetInfo {
		texture     = swapchain_texture,
		clear_color = sdl.FColor{10.0 / 255, 11.0 / 255, 14.0 / 255, 1},
		load_op     = .CLEAR,
		store_op    = .STORE,
	}
	pass := sdl.BeginGPURenderPass(command_buffer, &color_target, 1, nil)
	if pass != nil {
		// The preview canvas must never overpaint a floating overlay: the
		// popups/dropdown/menus are drawn as a separate clay pass AFTER
		// draw_preview (it is the highest-z clay below which everything
		// floats above the canvas). The scissor stack resets between the
		// two passes, which is fine — floating overlays (attachTo Root,
		// clipTo None) emit no scissor commands of their own.
		render_clay(renderer, command_buffer, pass, commands, 0, OVERLAY_ABOVE_PREVIEW_Z)
		// The preview canvas always renders: the black canvas + any selection
		// border/HUD paint even when no clip covers the playhead yet, and the
		// per-clip content inside draw_preview self-gates on each slot's
		// has_frame/texture.
		preview_bounds := clay.GetElementData(clay.ID("Preview")).boundingBox
		draw_preview(renderer, command_buffer, pass, preview_bounds)
		draw_preview_hud(renderer, command_buffer, pass, preview_bounds)
		render_clay(renderer, command_buffer, pass, commands, OVERLAY_ABOVE_PREVIEW_Z, max(i16))
		draw_text_input_caret(renderer, command_buffer, pass)
		draw_clip_markers(renderer, command_buffer, pass)
		draw_timeline_resize_focus(renderer, command_buffer, pass)
		draw_drag_ghost(renderer, command_buffer, pass)
		draw_media_bin_thumbnails(renderer, command_buffer, pass)
		draw_ui_icons(renderer, command_buffer, pass)
		draw_media_drag_ghost(renderer, command_buffer, pass)
		if len(timeline.tracks) > 0 {
			draw_timeline_ruler(renderer, command_buffer, pass)
			draw_render_range(renderer, command_buffer, pass)
		}
		draw_ui_notice(renderer, command_buffer, pass, f32(width), f32(height))
		draw_import_progress(renderer, command_buffer, pass, f32(width), f32(height))
		sdl.EndGPURenderPass(pass)
	}
	if !sdl.SubmitGPUCommandBuffer(command_buffer) {
		fmt.println("Could not submit GPU command buffer:", sdl.GetError())
	}
	return true
}
