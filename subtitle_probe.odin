package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// Headless subtitle-export probe (NERED_SUB_RENDER_PROBE="<out.mp4>").
//
// Builds a subtitle generator clip (multi-line cues, including one long line)
// on a deterministic track, then:
//   1. runs the PREVIEW path (update_subtitle_slot) at increasing baked-font
//      scales, which is where text raster buffers are sized off font_px and a
//      mis-estimate shows up as an OOM/segfault on the UI thread; and
//   2. exports the project TWICE at a larger scale so every worker-owned
//      global (font, setup scratch, per-job dynamic arena, cue raster cache)
//      is re-exercised across job teardown.
// Exits 0 only when every stage survives and both renders report .Done. Stages
// print before they run so a crash names its stage. Requires load_font_data().
// ---------------------------------------------------------------------------

subtitle_render_probe_run :: proc(out: string) {
	timeline.frame_rate = 30
	project.width = 640
	project.height = 360
	project.start_frame = -1
	project.end_frame = -1

	src_id := subtitle_probe_srt()
	append(&timeline.tracks, Track{id = 1, layer = 0, name = strings.clone("probe subtitles")})
	add_subtitle_generator_clip(&timeline.tracks[0], 0, src_id, strings.clone("probe.srt"))
	clip := &timeline.tracks[0].clips[0]

	// Preview path at growing scales (the rendered font is 48*scale, so the
	// raster buffer and per-glyph scratch grow with it).
	for scale in ([4]f32{1, 3, 6, 10}) {
		clip.scale = scale
		slot := new(Preview_Slot)
		for frame in i64(0) ..< clip.source_length_frames {
			// Mirror the app's frame loop: rasterize_lines_into_buffer backs its
			// per-line buffers with context.temp_allocator, and the UI thread
			// free-alls the temp arena once per frame (main.odin). The probe must
			// do the same or frame-scoped temp allocations accumulate and the
			// arena grow/free churn the crash path rides never happens.
			mem.free_all(context.temp_allocator)
			fmt.printf("[sub-probe] preview scale=%.0f frame=%d\n", scale, frame)
			update_subtitle_slot(slot, clip, frame)
		}
		if slot.text_buf != nil {
			delete(slot.text_buf)
		}
		if slot.text_base_buf != nil {
			delete(slot.text_base_buf)
		}
		if slot.text_scratch != nil {
			delete(slot.text_scratch)
		}
	}

	// Export path at a baked font well past the preview default.
	clip.scale = 4.0
	render_set_out_path(out)
	for pass in 0 ..< 2 {
		fmt.printf("[sub-probe] render pass=%d\n", pass)
		render_start()
		for render_is_busy() {
			time.sleep(50 * time.Millisecond)
		}
		poll_completed_thread()
		st := render_status_text()
		fmt.printf("[sub-probe] pass=%d status=%s\n", pass, st)
		if render_status() != .Done {
			fmt.println("[sub-probe] FAILED: render did not complete")
			os.exit(1)
		}
	}
	fmt.println("[sub-probe] all stages complete")
	os.exit(0)
}

// subtitle_probe_srt appends an inline Srt_Source to the session cache and
// returns its (stable) cache index.
subtitle_probe_srt :: proc() -> int {
	src := Srt_Source{path = strings.clone("probe:inline")}
	append(&src.cues, Srt_Cue{start_ms = 0, end_ms = 1000, text = "Hello nered\nsecond line, wider"})
	append(&src.cues, Srt_Cue{start_ms = 1000, end_ms = 1400, text = strings.repeat("longsubtitleline.", 40)})
	append(&src.cues, Srt_Cue{start_ms = 1400, end_ms = 3000, text = "final cue"})
	append(&srt_cache, src)
	return len(srt_cache) - 1
}