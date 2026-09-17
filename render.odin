package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import avcodec "vendor/ffmpeg/avcodec"
import avfmt "vendor/ffmpeg/avformat"
import avutil "vendor/ffmpeg/avutil"
import sws "vendor/ffmpeg/swscale"
import sdl "vendor:sdl3"
import stb "vendor:stb/truetype"

// ---------------------------------------------------------------------------
// Video export: composite the timeline (as shown in the preview) and encode it
// as MP4/H.264 + AAC with the vendored FFmpeg. Rendering runs on a worker
// thread (UI stays responsive) against a snapshot of the timeline; worker and
// main thread only touch render_progress, through atomic handoff — no mutex.
// ---------------------------------------------------------------------------

RENDER_FPS :: 60
RENDER_AUDIO_RATE :: 48000
// MAX_AUDIO_FRAME_SAMPLES caps the per-canvas-frame audio mix at the lowest
// practical timeline rate (12 fps -> 4000 samples), leaving headroom for
// step-downs above that.
MAX_AUDIO_FRAME_SAMPLES :: 4096
// AAC encodes in fixed 1024-sample frames.
AAC_FRAME_SIZE :: 1024
Render_Default_Path :: "render.mp4"

// render_overwrite_out: when off (default) a render points itself at a free
// <name>_<n>.<ext> instead of clobbering an existing file of the same name.
render_overwrite_out: bool

// resolve_out_scratch holds the resolved path; used at most once per render
// start, so a single shared buffer is fine.
resolve_out_scratch: [4096]u8

// render_resolve_output_path returns the path a fresh render should write (the
// plain target when overwrite is on or the file doesn't exist yet, else
// <dir>/<base>_<n><ext> for the first n whose name is free) unless the name
// cap is somehow exhausted, in which case it falls back to the raw target.
render_resolve_output_path :: proc() -> string {
	target := render_out_path()
	if render_overwrite_out || !os.exists(target) {
		return target
	}
	dir_end := 0
	for i := len(target) - 1; i >= 0; i -= 1 {
		if target[i] == '/' {
			dir_end = i + 1
			break
		}
	}
	stem := target[dir_end:]
	base, ext := stem, ""
	if dot := strings.last_index(stem, "."); dot > 0 {
		base, ext = stem[:dot], stem[dot:]
	}
	for n := 1; n < 1_000_000; n += 1 {
		name := fmt.bprintf(resolve_out_scratch[:], "%s%s_%d%s", target[:dir_end], base, n, ext)
		if !os.exists(name) {
			return name
		}
	}
	return target
}

// render_videos_dir resolves the user's videos directory into `buf` (no
// trailing slash): $XDG_VIDEOS_DIR when set, else $HOME/Videos. Returns ""
// when the home directory is not resolvable, letting the caller fall back.
render_videos_dir :: proc(buf: []u8) -> string {
	home, home_ok := os.user_home_dir(context.temp_allocator)
	if home_ok != os.General_Error.None {
		return ""
	}
	videos := os.get_env("XDG_VIDEOS_DIR", context.temp_allocator)
	if videos == "" {
		// Format into the CALLER's buf, not a local array: a string returned
		// from this proc must stay valid after the stack frame is gone, and a
		// local array here does not (see render_default_output_path, which
		// passes its own dir_buf through for exactly this reason).
		videos = fmt.bprintf(buf, "%s/Videos", home)
	}
	return strings.trim_suffix(videos, "/")
}

// render_default_output_path computes the startup render path into `buf`:
// <XDG videos dir>/render.mp4 ($HOME/Videos fallback), or the cwd-relative
// render.mp4 when no home dir is resolvable.
render_default_output_path :: proc(buf: []u8) -> string {
	dir_buf: [512]u8
	dir := render_videos_dir(dir_buf[:])
	if dir == "" {
		return string(Render_Default_Path)
	}
	return fmt.bprintf(buf, "%s/render.mp4", dir)
}

// Output path chosen with the save dialog (fixed buffer, written by the SDL
// callback, read on the main thread when starting a render).
render_out_path_buf: [4096]u8
render_out_path_len: int
render_out_path_set: bool = true // default path is filled in at startup

app_window: ^sdl.Window

Render_Status :: enum {
	Idle,
	Rendering,
	Done,
	Failed,
	Cancelled,
}

// render_progress is the only state shared with the worker thread. Single-writer
// handoff, no mutex: the worker writes status/error/frames_done and the main
// thread writes frames_total; status is the release/acquire gate, so the error
// buffer and counters are settled before a reader sees the state that consumes
// them (UI reading .Failed sees a fully-written error string, render_start
// reading .Rendering sees a settled frames_total).
render_progress: struct {
	status:       u32, // atomic
	frames_done:  i64, // atomic
	frames_total: i64, // atomic
	error:        [256]u8,
}

// status_text_buf is render_status_text's fixed scratch; the UI formats into it
// and hands it to clay in the same frame, so a single shared buffer is fine.
status_text_buf: [256]u8

render_status :: proc() -> Render_Status {
	return Render_Status(sync.atomic_load(&render_progress.status))
}

render_status_text :: proc() -> string {
	status := Render_Status(sync.atomic_load(&render_progress.status))
	switch status {
	case .Idle:
		return "Ready"
	case .Rendering:
		total := sync.atomic_load(&render_progress.frames_total)
		done := sync.atomic_load(&render_progress.frames_done)
		if total <= 0 {
			return "Rendering..."
		}
		pct := i64(100) * done / total
		text := fmt.bprintf(status_text_buf[:], "Rendering %lld / %lld (%d%%)", done, total, pct)
		return string(text)
	case .Done:
		return "Render complete"
	case .Failed:
		text := fmt.bprintf(status_text_buf[:], "Failed: %s", cstring(&render_progress.error[0]))
		return string(text)
	case .Cancelled:
		return "Render cancelled"
	}
	return ""
}

render_output_name :: proc() -> string {
	if render_out_path_len == 0 {
		return "No output path"
	}
	return path_basename(cstring(&render_out_path_buf[0]))
}

// ---------------------------------------------------------------------------
// Timeline snapshot taken on the main thread when a render starts, so the
// worker never touches live timeline state.
// ---------------------------------------------------------------------------

Render_Video_Src :: struct {
	path:                 cstring, // owned copy, freed by the worker
	stream_index:         c.int,
	source_start_frame:   i64,
	source_length_frames: i64,
	timeline_start_frame: i64,
	transform_x:          f32,
	transform_y:          f32,
	scale:                f32,
	crop_l:               f32,
	crop_r:               f32,
	crop_t:               f32,
	crop_b:               f32,
	source_w:             c.int,
	source_h:             c.int,
	// Compositing state (computed once at open).
	dec:                  Clip_Decoder,
	rw, rh:               c.int, // display (cropped box) rect size in output pixels
	ox, oy:               c.int, // rounded top-left offset on the canvas
	fw, fh:               c.int, // full (pre-crop) box size the frame decodes into
	blit:                 []u8, // fw*fh*4 scaled frame
}

// Render_Text_Src snapshots a .Text generator clip for the worker. It carries
// the title plus the transform math needed to place it at output resolution:
// box = text (source_w x source_h, in text px) * scale * (out_w / PREVIEW_W).
Render_Text_Src :: struct {
	name:                 string, // owned copy, freed by the worker
	timeline_start_frame: i64,
	source_length_frames: i64,
	transform_x:          f32, // top-left anchor
	transform_y:          f32,
	scale:                f32,
	source_w:             c.int, // text_w (tight ink width, text px)
	source_h:             c.int, // text_h (tight ink height, text px)
}

// The render worker rasterizes text with its own font + scratch so it never
// races the UI thread's shared text_clip_font/text_clip_scratch globals (the
// preview thread can be compositing a text slot while the worker renders).
render_text_font: stb.fontinfo
render_text_font_init: bool

// Render_Text_Job is a text clip's per-render precomputed raster + box, built
// once in render_worker_run so each frame just blits it. Baking the clip's
// scale into the raster (font = 48*clip_scale, clip_scale reset to 1) keeps the
// output crisp and consistent with the preview; blit_scale is the clip's baked
// scale (=1) so the box falls out of the tight dims times the uniform factor.
Render_Text_Job :: struct {
	raster:         []u8,
	bw:             int, // raster row stride
	ox, oy, ow, oh: int, // tight ink rect in raster
	blit_scale:     f32,
}

// text_scratch: worker needs its own dynamic scratch for baked fonts (the
// shared 8192 text_clip_scratch / render_text_scratch are too small once the
// font grows to 48*scale). Sized per setup via text_scratch_size_for.
render_text_setup_scratch: []u8

// setup_text_job rasterizes a text clip at the baked font matching its snapshot.
// source_w/source_h are the BASE tight dims (font 48, scale-independent) and
// scale is the multiplier, so the raster is rendered at font = 48*scale to keep
// the output crisp (consistent with the preview). The raster therefore carries
// the scale, and blit_scale is 1 so the box = tight_dims * uniform_factor (no
// double-scaling). Returns the job or leaves raster empty on failure (caller
// deletes raster via cleanup).
setup_text_job :: proc(over: ^Render_Text_Job, t: Render_Text_Src) {
	over^ = {}
	if t.name == "" || t.source_w <= 0 || t.source_h <= 0 {
		return
	}
	font_px := f32(TEXT_CLIP_FONT_PIXELS) * t.scale
	bw, bh := text_buf_size_for(t.name, &render_text_font, &render_text_font_init, font_px)
	buf := make([]u8, bw * bh * 4)
	if len(render_text_setup_scratch) < text_scratch_size_for(font_px) {
		delete(render_text_setup_scratch)
		render_text_setup_scratch = make([]u8, text_scratch_size_for(font_px))
	}
	ox, oy, ow, oh := rasterize_title_into_buffer(
		t.name,
		buf,
		bw,
		bh,
		&render_text_font,
		&render_text_font_init,
		render_text_setup_scratch,
		font_px,
	)
	if ow <= 0 || oh <= 0 {
		delete(buf)
		return
	}
	over.raster = buf
	over.bw = bw
	over.ox, over.oy, over.ow, over.oh = ox, oy, ow, oh
	over.blit_scale = 1
}

// Render_Sub_Src snapshots a .Subtitles generator clip (kind .Text) for the
// worker. The srt cues are read from the immortal, session-scoped srt_cache by
// id (never mutated after parse, so the worker can share them without a copy);
// per-frame the active cue is looked up (binary search) and its text blitted.
// The anchor is the CURRENT box's center at render time ("the user dragged the
// text to"), recomputed from the snapshot's transform+source_w/h; each cue
// change re-centers the new box on that anchor, matching the preview.
Render_Sub_Src :: struct {
	srt_id:               int,
	fps:                  f32, // project rate, cues resolve to frames at this
	timeline_start_frame: i64,
	source_start_frame:   i64,
	source_length_frames: i64,
	transform_x:          f32, // current top-left anchor (project coords)
	transform_y:          f32,
	scale:                f32,
	source_w:             c.int, // current cue's base ink dims (font 48)
	source_h:             c.int,
	// Worker-computed at setup: the fixed box center each cue stays centered on.
	anchor_x:             f32,
	anchor_y:             f32,
}

// Render_Sub_Cue is the worker's raster cache for one subtitle clip's ACTIVE
// cue (keyspace is per clip). Cues play forward in population order during a
// render, so a single slot per clip has a perfect hit rate between boundaries.
Render_Sub_Cue :: struct {
	cue_idx:        int,
	raster:         []u8, // baked-font (48*scale) RGBA raster
	bw:             int, // raster row stride
	bh:             int, // raster height
	ox, oy, ow, oh: int, // tight ink rect in the raster
}

// rasterize_subtitle_cue builds the baked-font raster for one cue's text
// (multi-line, worker's own font/scratch). Returns with raster empty on no ink.
rasterize_subtitle_cue :: proc(j: ^Render_Sub_Cue, text: string, scale: f32) {
	j^ = {}
	lines := strings.split(text, "\n")
	defer delete(lines)
	if len(lines) == 0 || (len(lines) == 1 && strings.trim_space(lines[0]) == "") {
		return
	}
	font_px := f32(TEXT_CLIP_FONT_PIXELS) * scale
	bw, bh := text_buf_size_for_lines(lines, &render_text_font, &render_text_font_init, font_px)
	if bw <= 0 || bh <= 0 {
		return
	}
	buf := make([]u8, bw * bh * 4)
	if len(render_text_setup_scratch) < text_scratch_size_for(font_px) {
		delete(render_text_setup_scratch)
		render_text_setup_scratch = make([]u8, text_scratch_size_for(font_px))
	}
	ox, oy, ow, oh := rasterize_lines_into_buffer(
		lines,
		buf,
		bw,
		bh,
		&render_text_font,
		&render_text_font_init,
		render_text_setup_scratch,
		font_px,
		context.allocator,
	)
	if vyper_trace || os.get_env_alloc("VYPER_SUB_RENDER_TRACE", context.temp_allocator) != "" {
		fmt.printf(
			"[sub-raster] len=%d scale=%.1f bw=%d bh=%d ink=%d,%d,%d,%d\n",
			len(text),
			scale,
			bw,
			bh,
			ox,
			oy,
			ow,
			oh,
		)
	}
	if ow <= 0 || oh <= 0 {
		delete(buf)
		return
	}
	j.raster = buf
	j.bw = bw
	j.bh = bh
	j.ox, j.oy, j.ow, j.oh = ox, oy, ow, oh
}

Render_Audio_Src :: struct {
	path:                 cstring,
	stream_index:         c.int,
	timeline_start_frame: i64,
	source_start_frame:   i64,
	source_length_frames: i64,
	dec:                  Audio_Clip_Decoder, // 48 kHz stereo S16
	fifo:                 Audio_Ring, // converted stereo f32, content-relative
	first48:              i64, // content 48 kHz frame of fifo's head
	have48:               i64, // content frames produced so far (next un-produced)
}

render_job_videos: []Render_Video_Src
render_job_audios: []Render_Audio_Src
render_job_texts: []Render_Text_Src
render_job_subs: []Render_Sub_Src
render_job_out_path: cstring
render_job_width: c.int
render_job_height: c.int
render_job_start: i64
render_job_end: i64 // inclusive
render_job_nframes: i64

// clip_full_box_dims works on ^Clip; mirrored here for snapshot structs.
render_full_box_dims :: proc(sw0, sh0: c.int, out_w, out_h: f32) -> (f32, f32) {
	if sw0 > 0 && sh0 > 0 {
		src_ar := f32(sw0) / f32(sh0)
		box_ar := out_w / out_h
		if src_ar > box_ar {
			return out_w, out_w / src_ar
		}
		return out_h * src_ar, out_h
	}
	return out_w, out_h
}

// render_display_rect returns the clip's visible rect in project (output)
// pixels, honoring source aspect (letterbox) and crop insets.
render_display_rect :: proc(src: ^Render_Video_Src, PW, PH: c.int) -> (l, t, r, b: f32) {
	cw, ch := render_full_box_dims(
		src.source_w,
		src.source_h,
		f32(PW) * src.scale,
		f32(PH) * src.scale,
	)
	l = src.transform_x - cw / 2 + src.crop_l * cw
	r = src.transform_x + cw / 2 - src.crop_r * cw
	t = src.transform_y - ch / 2 + src.crop_t * ch
	b = src.transform_y + ch / 2 - src.crop_b * ch
	return
}

// ---------------------------------------------------------------------------
// Encoder + muxer.
// ---------------------------------------------------------------------------

Render_Enc :: struct {
	fmt_ctx:         ^avfmt.FormatContext,
	vstream:         ^avfmt.Stream,
	vcodec_ctx:      ^avcodec.CodecContext,
	astream:         ^avfmt.Stream,
	acodec_ctx:      ^avcodec.CodecContext,
	sws_rgb_yuv:     ^sws.Context,
	yuv_data:        [4][^]u8,
	yuv_linesize:    [4]c.int,
	yuv_avail:       bool,
	audio_frame:     ^avutil.Frame,
	audio_plane:     bool,
	vpkt:            ^avcodec.Packet,
	apkt:            ^avcodec.Packet,
	// Pending audio holds the largest push (MAX_AUDIO_FRAME_SAMPLES*2 stereo
	// samples) plus the sub-AAC residue a flush leaves behind; a 4096-cap
	// alone overflowed whenever residue + chunk crossed it (bounds trap at
	// every 30 fps render).
	audio_pending:   [MAX_AUDIO_FRAME_SAMPLES * 2 + AAC_FRAME_SIZE * 2]f32,
	audio_pending_n: int,
	audio_sent:      i64, // total 48k samples pushed so far (pts basis)
}

enc_cleanup :: proc(e: ^Render_Enc) {
	if e.acodec_ctx != nil {
		avcodec.free_context(&e.acodec_ctx)
	}
	if e.vcodec_ctx != nil {
		avcodec.free_context(&e.vcodec_ctx)
	}
	if e.audio_frame != nil {
		if e.audio_plane && e.audio_frame.data[0] != nil {
			avutil.freep(&e.audio_frame.data[0])
		}
		avutil.frame_free(&e.audio_frame)
	}
	if e.vpkt != nil {
		avcodec.packet_free(&e.vpkt)
	}
	if e.apkt != nil {
		avcodec.packet_free(&e.apkt)
	}
	if e.sws_rgb_yuv != nil {
		sws.freeContext(e.sws_rgb_yuv)
	}
	if e.yuv_avail {
		avutil.freep(&e.yuv_data[0])
	}
	if e.fmt_ctx != nil {
		avfmt.free_context(e.fmt_ctx)
	}
	e^ = {}
}

// enc_write_packets drains an encoder's output packets into the muxer,
// rescaling timestamps from the codec time base to the stream time base.
enc_drain :: proc(
	e: ^Render_Enc,
	ctx: ^avcodec.CodecContext,
	stream: ^avfmt.Stream,
	pkt: ^avcodec.Packet,
) -> bool {
	for avcodec.receive_packet(ctx, pkt) >= 0 {
		pkt.stream_index = stream.index
		pkt.pts = avutil.rescale_q(pkt.pts, ctx.time_base, stream.time_base)
		pkt.dts = avutil.rescale_q(pkt.dts, ctx.time_base, stream.time_base)
		pkt.duration = avutil.rescale_q(pkt.duration, ctx.time_base, stream.time_base)
		if ret := avfmt.interleaved_write_frame(e.fmt_ctx, pkt); ret < 0 {
			fmt.println("interleaved_write_frame:", ff_err_str(ret))
			avcodec.packet_unref(pkt)
			return false
		}
		avcodec.packet_unref(pkt)
	}
	return true
}

// enc_open_video configures the H.264 encoder and its mux stream.
enc_open_video :: proc(e: ^Render_Enc, width, height: c.int, fps_num, fps_den: c.int) -> bool {
	codec := avcodec.find_encoder_by_name("libx264")
	if codec == nil {
		fmt.println("no libx264 encoder")
		return false
	}
	ctx := avcodec.alloc_context3(codec)
	if ctx == nil {
		fmt.println("avcodec_alloc_context3 (h264) failed")
		return false
	}
	e.vcodec_ctx = ctx
	ctx.width = width
	ctx.height = height
	// The output canvas ticks the source/timeline frame rate, not a fixed 60,
	// so the rendered video and its audio track stay 1:1 with the source.
	ctx.time_base = avutil.Rational {
		num = fps_den,
		den = fps_num,
	}
	ctx.framerate = avutil.Rational {
		num = fps_num,
		den = fps_den,
	}
	ctx.pix_fmt = .YUV420P
	ctx.gop_size = 120
	ctx.max_b_frames = 2
	ctx.bit_rate = 8_000_000
	if ret := avcodec.open2(ctx, codec, nil); ret < 0 {
		fmt.println("avcodec_open2 (h264):", ff_err_str(ret))
		return false
	}
	stream := avfmt.new_stream(e.fmt_ctx, codec)
	if stream == nil {
		fmt.println("avformat_new_stream (video) failed")
		return false
	}
	e.vstream = stream
	stream.time_base = ctx.time_base
	if ret := avcodec.parameters_from_context(stream.codecpar, ctx); ret < 0 {
		fmt.println("avcodec_parameters_from_context:", ff_err_str(ret))
		return false
	}
	stream.codecpar.width = width
	stream.codecpar.height = height

	e.sws_rgb_yuv = sws.getContext(
		width,
		height,
		avutil.PixelFormat.RGBA,
		width,
		height,
		avutil.PixelFormat.YUV420P,
		sws.Flags{.Bilinear},
		nil,
		nil,
		nil,
	)
	if e.sws_rgb_yuv == nil {
		fmt.println("sws_getContext (rgb->yuv) failed")
		return false
	}
	if avutil.image_alloc(
		   &e.yuv_data[0],
		   &e.yuv_linesize[0],
		   width,
		   height,
		   avutil.PixelFormat.YUV420P,
		   32,
	   ) <
	   0 {
		fmt.println("av_image_alloc (yuv) failed")
		return false
	}
	e.yuv_avail = true
	e.vpkt = avcodec.packet_alloc()
	return true
}

// enc_open_audio configures the AAC encoder + FIFO staging. Returns false if no
// audio is available (caller may proceed with video-only output).
enc_open_audio :: proc(e: ^Render_Enc) -> bool {
	codec := avcodec.find_encoder_by_name("aac")
	if codec == nil {
		fmt.println("no aac encoder")
		return false
	}
	ctx := avcodec.alloc_context3(codec)
	if ctx == nil {
		fmt.println("avcodec_alloc_context3 (aac) failed")
		return false
	}
	e.acodec_ctx = ctx
	ctx.sample_rate = RENDER_AUDIO_RATE
	ctx.sample_fmt = .FltP
	avutil.channel_layout_default(&ctx.ch_layout, 2)
	ctx.bit_rate = 192_000
	ctx.time_base = avutil.Rational {
		num = 1,
		den = RENDER_AUDIO_RATE,
	}
	if ret := avcodec.open2(ctx, codec, nil); ret < 0 {
		fmt.println("avcodec_open2 (aac):", ff_err_str(ret))
		return false
	}
	stream := avfmt.new_stream(e.fmt_ctx, codec)
	if stream == nil {
		fmt.println("avformat_new_stream (audio) failed")
		return false
	}
	e.astream = stream
	stream.time_base = ctx.time_base
	if ret := avcodec.parameters_from_context(stream.codecpar, ctx); ret < 0 {
		fmt.println("avcodec_parameters_from_context:", ff_err_str(ret))
		return false
	}
	e.apkt = avcodec.packet_alloc()
	e.audio_frame = avutil.frame_alloc()
	if e.audio_frame == nil {
		fmt.println("av_frame_alloc (audio) failed")
		return false
	}
	f := e.audio_frame
	f.format = c.int(avutil.SampleFormat.FltP)
	f.sample_rate = RENDER_AUDIO_RATE
	avutil.channel_layout_default(&f.ch_layout, 2)
	if avutil.samples_alloc(
		   &f.data[0],
		   &f.linesize[0],
		   2,
		   AAC_FRAME_SIZE,
		   avutil.SampleFormat.FltP,
		   0,
	   ) <
	   0 {
		fmt.println("av_samples_alloc (audio) failed")
		return false
	}
	e.audio_plane = true
	return true
}

render_open_output :: proc(
	e: ^Render_Enc,
	path: cstring,
	width, height: c.int,
	with_audio: bool,
	fps_num, fps_den: c.int,
) -> bool {
	if ret := avfmt.alloc_output_context2(&e.fmt_ctx, nil, nil, path); ret < 0 {
		// Fall back to guessing the format by name.
		if ret2 := avfmt.alloc_output_context2(&e.fmt_ctx, nil, cstring("mp4"), path); ret2 < 0 {
			fmt.println("avformat_alloc_output_context2:", ff_err_str(ret2))
			return false
		}
	}
	if ret := avfmt.open2(&e.fmt_ctx.pb, path, avfmt.IOFlags{.Write}, nil, nil); ret < 0 {
		fmt.println("avio_open2:", ff_err_str(ret))
		return false
	}
	if !enc_open_video(e, width, height, fps_num, fps_den) {
		return false
	}
	if with_audio && !enc_open_audio(e) {
		return false
	}
	if ret := avfmt.write_header(e.fmt_ctx, nil); ret < 0 {
		fmt.println("avformat_write_header:", ff_err_str(ret))
		return false
	}
	return true
}

rend_enc_video_frame :: proc(
	e: ^Render_Enc,
	rgb: []u8,
	width, height: c.int,
	frame_index: i64,
) -> bool {
	slice: [1][^]u8 = {raw_data(rgb)}
	ls: [4]c.int = {width * 4, 0, 0, 0}
	sws.scale(
		e.sws_rgb_yuv,
		cast([^][^]u8)&slice[0],
		cast([^]c.int)&ls[0],
		0,
		height,
		cast([^][^]u8)&e.yuv_data[0],
		cast([^]c.int)&e.yuv_linesize[0],
	)
	frame := avutil.frame_alloc()
	if frame == nil {
		return false
	}
	defer avutil.frame_free(&frame)
	frame.format = c.int(avutil.PixelFormat.YUV420P)
	frame.width = width
	frame.height = height
	for i in 0 ..< 4 {
		frame.data[i] = e.yuv_data[i]
		frame.linesize[i] = e.yuv_linesize[i]
	}
	frame.pts = frame_index
	if ret := avcodec.send_frame(e.vcodec_ctx, frame); ret < 0 {
		fmt.println("avcodec_send_frame (video):", ff_err_str(ret))
		return false
	}
	return enc_drain(e, e.vcodec_ctx, e.vstream, e.vpkt)
}

// enc_push_audio_stereo stages an interleaved stereo chunk and flushes full AAC
// frames to the encoder.
rend_enc_push_audio :: proc(e: ^Render_Enc, mix: []f32) -> bool {
	// Copy into pending, converting zeros already in place.
	for s in mix {
		e.audio_pending[e.audio_pending_n] = s
		e.audio_pending_n += 1
	}
	ok := true
	for e.audio_pending_n >= AAC_FRAME_SIZE * 2 {
		// De-interleave the first 1024 stereo frames into the planar frame.
		f := e.audio_frame
		L := ([^]f32)(f.data[0])
		R := ([^]f32)(f.data[1])
		for i in 0 ..< AAC_FRAME_SIZE {
			L[i] = e.audio_pending[i * 2 + 0]
			R[i] = e.audio_pending[i * 2 + 1]
		}
		f.nb_samples = AAC_FRAME_SIZE
		f.pts = e.audio_sent
		e.audio_sent += AAC_FRAME_SIZE
		if ret := avcodec.send_frame(e.acodec_ctx, f); ret < 0 {
			fmt.println("avcodec_send_frame (audio):", ff_err_str(ret))
			ok = false
			break
		}
		if !enc_drain(e, e.acodec_ctx, e.astream, e.apkt) {
			ok = false
		}
		// Shift the remainder to the front.
		rem := e.audio_pending_n - AAC_FRAME_SIZE * 2
		if rem > 0 {
			mem.copy(&e.audio_pending[0], &e.audio_pending[AAC_FRAME_SIZE * 2], size_of(f32) * rem)
		}
		e.audio_pending_n = rem
	}
	return ok
}

// ---------------------------------------------------------------------------
// Audio source pull (forward-only decode, 48 kHz stereo f32).
// ---------------------------------------------------------------------------

render_audio_pull :: proc(a: ^Render_Audio_Src, up_to48: i64) {
	for a.have48 < up_to48 {
		// Sequential continue (-1): render_audio_open already seeked to the
		// content anchor, and re-targeting via have48 every chunk can look like
		// a backward move against the resampled last_ts, triggering a backward
		// re-seek that re-decodes and duplicates audio (stutter/desync in the
		// rendered file). Same forward-only rule playback uses.
		n := decode_audio_chunk(&a.dec, -1.0)
		if n <= 0 {
			break
		}
		ring_push_pcm(&a.fifo, a.dec.s16[:n * 2], n)
		a.have48 += i64(n)
	}
}

render_audio_open :: proc(a: ^Render_Audio_Src, render_start: i64, fps: f64) -> bool {
	overlap_start := max(a.timeline_start_frame, render_start)
	content_sec := f64(overlap_start - a.timeline_start_frame + a.source_start_frame) / fps
	if !open_audio_decoder_resampled(&a.dec, a.path, a.stream_index, RENDER_AUDIO_RATE, 2) {
		return false
	}
	if !seek_audio(&a.dec, content_sec) {
		return false
	}
	// Align the fifo base to the decoder's real landing PTS, not the asked
	// position: an AAC seek can land tens of ms off, and labeling the fifo with
	// the asked time compounds that offset over the whole render. Same fix
	// playback applied (audio.odin audio_provision).
	n := decode_audio_chunk(&a.dec, content_sec)
	if n <= 0 {
		return false
	}
	src := &a.dec
	real_sec :=
		f64(
			avutil.rescale_q(
				src.first_ts,
				src.stream.time_base,
				avutil.Rational{num = 1, den = 1_000_000},
			),
		) /
		1e6
	a.first48 = i64(real_sec * f64(RENDER_AUDIO_RATE))
	a.have48 = a.first48 + i64(n)
	ring_push_pcm(&a.fifo, a.dec.s16[:n * 2], n)
	return true
}

// ---------------------------------------------------------------------------
// Main worker.
// ---------------------------------------------------------------------------

render_worker_thread: ^thread.Thread

render_worker :: proc(t: ^thread.Thread) {
	render_worker_run()
}

render_worker_run :: proc() {
	// Whole-job arena: every allocation the worker makes — blit buffers, canvas,
	// text/subtitle rasters, the setup scratch, audio fifos — carves from this
	// one block. A render is a finite, single-threaded pass, so nothing needs
	// freeing until the arena dies at the end; the ffmpeg decoder context memory
	// is the exception (reset below). The snapshot arrays (render_job_*) were
	// allocated on the main thread and are freed there.
	job_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&job_arena)
	context.allocator = mem.dynamic_arena_allocator(&job_arena)

	set_status(.Rendering, "")
	fail := false
	e := Render_Enc{}
	err_msg := ""
	defer {
		enc_cleanup(&e)
		for &v in render_job_videos {
			clip_decoder_reset(&v.dec)
		}
		for &a in render_job_audios {
			if a.dec.opened {
				audio_decoder_reset(&a.dec)
			}
		}
		mem.dynamic_arena_destroy(&job_arena)
		render_text_setup_scratch = nil
		status := fail ? Render_Status.Failed : (cancelled() ? .Cancelled : .Done)
		if fail && len(err_msg) > 0 {
			set_status(.Failed, err_msg)
		} else {
			set_status(status, "")
		}
	}

	// Prepare compositing state for each video source.
	for i in 0 ..< len(render_job_videos) {
		v := &render_job_videos[i]
		l, t, r, b := render_display_rect(v, render_job_width, render_job_height)
		v.rw = max(1, c.int(r - l + 0.5))
		v.rh = max(1, c.int(b - t + 0.5))
		v.ox = c.int(l + 0.5)
		v.oy = c.int(t + 0.5)
		// Decode the frame at the full (pre-crop) box size so the cropped
		// region can be sampled out of it (render_blit).
		cw, ch := render_full_box_dims(
			v.source_w,
			v.source_h,
			f32(render_job_width) * v.scale,
			f32(render_job_height) * v.scale,
		)
		v.fw = max(1, c.int(cw + 0.5))
		v.fh = max(1, c.int(ch + 0.5))
		v.blit = make([]u8, int(v.fw) * int(v.fh) * 4)
		if !open_clip_decoder_ex(&v.dec, v.path, v.stream_index, v.fw, v.fh, false) {
			err_msg = "failed to open video source"
			fail = true
			return
		}
	}

	// The output frame rate: an explicit project fps wins; otherwise it comes
	// from the first video source so the timeline frame grid (which is the
	// source's own frame indices) renders 1:1 with both the video and the 48 kHz
	// audio bus.
	rfps_num, rfps_den := c.int(60), c.int(1)
	if project.frame_rate > 0 {
		rfps_num, rfps_den = 0, 1
	} else if len(render_job_videos) > 0 {
		rfps_num = render_job_videos[0].dec.fps_num
		rfps_den = render_job_videos[0].dec.fps_den
		if rfps_num <= 0 || rfps_den <= 0 {
			rfps_num, rfps_den = 60, 1
		}
	}
	rfps := f64(rfps_num) / f64(rfps_den)
	if project.frame_rate > 0 {
		rfps = project.frame_rate
		rfps_num, rfps_den = c.int(rfps), 1
		if math.abs(rfps - 23.976) < 0.001 {
			rfps_num, rfps_den = 24000, 1001
		} else if math.abs(rfps - 29.97) < 0.001 {
			rfps_num, rfps_den = 30000, 1001
		} else if math.abs(rfps - 59.94) < 0.001 {
			rfps_num, rfps_den = 60000, 1001
		}
	}
	spf := int(MAX_AUDIO_FRAME_SAMPLES)
	if rfps > 0 {
		spf = min(MAX_AUDIO_FRAME_SAMPLES, max(0, int(math.round(48000.0 / rfps))))
	}

	has_audio := len(render_job_audios) > 0
	if has_audio {
		for i in 0 ..< len(render_job_audios) {
			a := &render_job_audios[i]
			if !render_audio_open(a, render_job_start, rfps) {
				a.dec.opened = false
			}
		}
	}

	if !render_open_output(
		&e,
		render_job_out_path,
		render_job_width,
		render_job_height,
		has_audio,
		rfps_num,
		rfps_den,
	) {
		err_msg = "failed to open output"
		fail = true
		return
	}
	if e.acodec_ctx == nil {
		has_audio = false
	}

	canvas := make([]u8, int(render_job_width) * int(render_job_height) * 4)
	// canvas + all per-clip rasters live in the job arena (job_arena above),
	// freed wholesale when the worker unwinds — no per-buffer deletes.

	// Text compositing: each text clip gets a precomputed raster (baked font)
	// + blit box built once below, then alpha-blitted on the canvas each frame.
	// Built before the frame loop (titles + transforms are static for a job).
	text_jobs := make([]Render_Text_Job, max(len(render_job_texts), 1))
	for i in 0 ..< len(render_job_texts) {
		setup_text_job(&text_jobs[i], render_job_texts[i])
	}

	// Subtitle compositing: per-clip anchor (the box center to keep fixed across
	// cue changes) + a one-slot active-cue raster cache. Cues play forward in
	// population order, so a single slot per clip is a near-perfect LRU.
	sub_cues := make([]Render_Sub_Cue, max(len(render_job_subs), 1))
	sub_factor := f32(render_job_width) / f32(PREVIEW_W)
	for i in 0 ..< len(render_job_subs) {
		s := &render_job_subs[i]
		if s.source_w > 0 && s.source_h > 0 {
			s.anchor_x = s.transform_x + f32(s.source_w) * s.scale * sub_factor / 2
			s.anchor_y = s.transform_y + f32(s.source_h) * s.scale * sub_factor / 2
		} else {
			s.anchor_x = f32(render_job_width) / 2
			s.anchor_y = f32(render_job_height) / 2
		}
	}

	for frame_idx in 0 ..< render_job_nframes {
		if poll_cancel() {
			return
		}
		timeline_frame := render_job_start + frame_idx
		// Composite all video clips covering this frame (bottom track first so
		// the top track paints last, matching the preview).
		mem.zero(raw_data(canvas), len(canvas))
		for i := len(render_job_videos) - 1; i >= 0; i -= 1 {
			v := &render_job_videos[i]
			if timeline_frame < v.timeline_start_frame ||
			   timeline_frame >= v.timeline_start_frame + v.source_length_frames {
				continue
			}
			src_frame := v.source_start_frame + timeline_frame - v.timeline_start_frame
			if !decode_source_frame(&v.dec, src_frame) {
				continue
			}
			decode_into_buffer(&v.dec, v.blit, v.fw, v.fh)
			render_blit(canvas, render_job_width, render_job_height, v)
		}
		// Composite all text clips covering this frame (after the decodable
		// clips, alpha-blended on top, matching the preview layering).
		for i := 0; i < len(render_job_texts); i += 1 {
			t := &render_job_texts[i]
			if timeline_frame < t.timeline_start_frame ||
			   timeline_frame >= t.timeline_start_frame + t.source_length_frames {
				continue
			}
			if t.name == "" {
				continue
			}
			j := &text_jobs[i]
			if j.raster == nil || j.ow <= 0 || j.oh <= 0 {
				continue
			}
			render_text_blit(
				canvas,
				render_job_width,
				render_job_height,
				j.raster,
				j.bw,
				j.ox,
				j.oy,
				j.ow,
				j.oh,
				t.transform_x,
				t.transform_y,
				j.blit_scale,
			)
		}
		// Composite subtitle-generator clips last (on top of everything else —
		// the natural subtitle layering; matches the preview, where the topmost
		// text/bottom-most slot order puts subtitles above the decoded faces).
		for i in 0 ..< len(render_job_subs) {
			s := &render_job_subs[i]
			if timeline_frame < s.timeline_start_frame ||
			   timeline_frame >= s.timeline_start_frame + s.source_length_frames {
				continue
			}
			src := srt_source(s.srt_id)
			if src == nil {
				continue
			}
			rel := timeline_frame - s.timeline_start_frame
			ci := srt_cue_lookup(src.cues[:], rel + s.source_start_frame, s.fps)
			if ci < 0 {
				continue
			}
			jc := &sub_cues[i]
			if jc.raster == nil || jc.cue_idx != ci {
				if jc.raster != nil {
					delete(jc.raster)
				}
				rasterize_subtitle_cue(jc, src.cues[ci].text, s.scale)
				jc.cue_idx = ci
				if jc.raster == nil {
					continue
				}
			}
			// Blit the ink sub-rect horizontally over the FULL galley height,
			// anchored like the preview slot: x centered on the box center, y
			// on the box BOTTOM. The box is ink-width x galley-height, so the
			// text stays centered while the galley bottom (a font-metric line)
			// keeps the last line's baseline fixed when the cue gains
			// descenders or a line — matching preview_state.odin.
			w := f32(jc.ow) * sub_factor
			h := f32(jc.bh) * sub_factor
			bottom := s.anchor_y + f32(s.source_h) * s.scale * sub_factor / 2
			if vyper_trace ||
			   os.get_env_alloc("VYPER_SUB_RENDER_TRACE", context.temp_allocator) != "" {
				fmt.printf(
					"[sub-blit] cue=%d ox=%d oy=%d ow=%d oh=%d bw=%d bh=%d w=%.0f h=%.0f x0=%.0f y0=%.0f anchor=(%.0f,%.0f) src=%dx%d\n",
					ci,
					jc.ox,
					jc.oy,
					jc.ow,
					jc.oh,
					jc.bw,
					jc.bh,
					w,
					h,
					s.anchor_x - w / 2,
					bottom - h,
					s.anchor_x,
					s.anchor_y,
					s.source_w,
					s.source_h,
				)
			}
			render_text_blit(
				canvas,
				render_job_width,
				render_job_height,
				jc.raster,
				jc.bw,
				jc.ox,
				0,
				jc.ow,
				jc.bh,
				s.anchor_x - w / 2,
				bottom - h,
				1,
			)
		}
		if !rend_enc_video_frame(&e, canvas, render_job_width, render_job_height, frame_idx) {
			err_msg = "video encoding failed"
			fail = true
			return
		}

		if has_audio && spf > 0 {
			mix: [MAX_AUDIO_FRAME_SAMPLES * 2]f32
			// Exact per-frame sample count: difference of consecutive 48 kHz
			// frame boundaries, not a fixed rounded 48000/fps. For fps that
			// don't evenly divide 48000 (23.976/29.97/59.94) this alternates
			// (e.g. 1601/1602 at 29.97) and averages to the true rate, so the
			// rendered audio length matches the video instead of drifting.
			cur_spf := spf
			if rfps > 0 {
				b0 := audio_frame_boundary48(timeline_frame, rfps)
				b1 := audio_frame_boundary48(timeline_frame + 1, rfps)
				cur_spf = min(MAX_AUDIO_FRAME_SAMPLES, max(1, int(b1 - b0)))
			}
			for aa in 0 ..< len(render_job_audios) {
				a := &render_job_audios[aa]
				if !a.dec.opened {
					continue
				}
				if timeline_frame < a.timeline_start_frame ||
				   timeline_frame >= a.timeline_start_frame + a.source_length_frames {
					continue
				}
				start48 := i64(
					f64(timeline_frame - a.timeline_start_frame + a.source_start_frame) *
					f64(RENDER_AUDIO_RATE) /
					rfps,
				)
				render_audio_pull(a, start48 + i64(cur_spf))
				if start48 < a.first48 || a.have48 < start48 + i64(cur_spf) {
					continue
				}
				base := int(start48 - a.first48)
				for s in 0 ..< cur_spf {
					l, r := ring_at(&a.fifo, base + s)
					mix[s * 2 + 0] += l
					mix[s * 2 + 1] += r
				}
				// Trim the consumed fifo head so decode stays forward-only and
				// long renders don't accumulate the whole clip in memory
				// (mirrors playback's per-frame trim). O(1) head move, not a
				// per-frame mem.copy of the whole queue.
				drop := base + cur_spf
				if drop > 0 {
					a.first48 += i64(drop)
					ring_drop(&a.fifo, drop)
				}
			}
			if !rend_enc_push_audio(&e, mix[:cur_spf * 2]) {
				err_msg = "audio encoding failed"
				fail = true
				return
			}
		}

		sync.atomic_store(&render_progress.frames_done, frame_idx + 1)
	}

	// Flush encoders.
	avcodec.send_frame(e.vcodec_ctx, nil)
	if !enc_drain(&e, e.vcodec_ctx, e.vstream, e.vpkt) {
		fail = true
		err_msg = "video flush failed"
		return
	}
	if has_audio {
		avcodec.send_frame(e.acodec_ctx, nil)
		if !enc_drain(&e, e.acodec_ctx, e.astream, e.apkt) {
			fail = true
			err_msg = "audio flush failed"
			return
		}
	}
	if ret := avfmt.write_trailer(e.fmt_ctx); ret < 0 {
		fmt.println("avformat_write_trailer:", ff_err_str(ret))
		fail = true
		err_msg = "finalizing file failed"
		return
	}
}

// render_blit copies the clip's scaled frame onto the canvas, clipped to bounds.
// The blit holds the full (pre-crop) frame; crop insets select the visible
// source sub-region that fills the display box (matching the preview's UV crop).
render_blit :: proc(canvas: []u8, draw_w, draw_h: c.int, v: ^Render_Video_Src) {
	top := max(v.oy, 0)
	bottom := min(v.oy + v.rh, draw_h)
	left := max(v.ox, 0)
	right := min(v.ox + v.rw, draw_w)
	if bottom <= top || right <= left {
		return
	}
	if v.crop_l == 0 && v.crop_r == 0 && v.crop_t == 0 && v.crop_b == 0 {
		scol := left - v.ox
		srow := top - v.oy
		rows := bottom - top
		cols := right - left
		for row in 0 ..< rows {
			src := v.blit[uint(srow + row) * uint(v.fw) * 4 + uint(scol) * 4:][:uint(cols) * 4]
			dst := canvas[uint(top + row) * uint(draw_w) * 4 + uint(left) * 4:][:uint(cols) * 4]
			copy(dst, src)
		}
		return
	}
	// Cropped: sample the source sub-region
	// [crop_l*fw, crop_t*fh) -> [(1-crop_r)*fw, (1-crop_b)*fh) and scale it to
	// fill the display box. The source is a 1:1 region-to-box fit after crop
	// (same math as the preview), so artifacts are minimal.
	src_cols := f64(v.fw) * f64(1 - v.crop_l - v.crop_r)
	src_rows := f64(v.fh) * f64(1 - v.crop_t - v.crop_b)
	if src_cols <= 0 || src_rows <= 0 {
		return
	}
	sx0 := f64(v.crop_l) * f64(v.fw)
	sy0 := f64(v.crop_t) * f64(v.fh)
	for row in 0 ..< bottom - top {
		sy := int(sy0 + (f64(top - v.oy + row) + 0.5) * src_rows / f64(v.rh))
		sy = max(0, min(int(v.fh) - 1, sy))
		src_row := v.blit[uint(sy) * uint(v.fw) * 4:]
		for col in 0 ..< right - left {
			sx := int(sx0 + (f64(left - v.ox + col) + 0.5) * src_cols / f64(v.rw))
			sx = max(0, min(int(v.fw) - 1, sx))
			dst := canvas[(uint(top + row) * uint(draw_w) + uint(left + col)) * 4:][:4]
			copy(dst, src_row[uint(sx) * 4:][:4])
		}
	}
}

// render_text_blit alpha-blends a rasterized text clip onto the canvas. text_buf
// holds the title rasterized at the BAKED font (font = 48*clip_scale, and
// clip.scale is reset to 1), so the raster already carries the scale. The tight
// ink rect [ox..ox+ow)x[oy..oy+oh) is scaled to the output box anchored at the
// clip's top-left (tx, ty) in project pixels, matching the preview's text box
// math: a UNIFORM factor bw0 = ow * (out_w/PREVIEW_W) scales both axes (so text
// is never squished by the project's aspect), box = bw0*scale x bh0*scale with
// scale=1 post-bake. bw is the buffer's row stride (the raster's own width).
render_text_blit :: proc(
	canvas: []u8,
	draw_w, draw_h: c.int,
	text_buf: []u8,
	bw: int,
	ox, oy, ow, oh: int,
	tx, ty, scale: f32,
) {
	if ow <= 0 || oh <= 0 {
		return
	}
	factor := f32(draw_w) / f32(PREVIEW_W)
	bw0 := f32(ow) * factor
	bh0 := f32(oh) * factor
	w := bw0 * scale
	h := bh0 * scale
	x0 := tx
	y0 := ty
	if w <= 0 || h <= 0 {
		return
	}
	left := max(c.int(x0), 0)
	top := max(c.int(y0), 0)
	right := min(c.int(x0 + w), draw_w)
	bottom := min(c.int(y0 + h), draw_h)
	if bottom <= top || right <= left {
		return
	}
	for row in 0 ..< bottom - top {
		// Nearest-neighbor source sample within the tight text rect.
		srow := oy + int((f64(top - c.int(y0) + row) + 0.5) * f64(oh) / f64(h))
		srow = max(oy, min(oy + oh - 1, srow))
		src_row := text_buf[uint(srow) * uint(bw) * 4:]
		dst_row := canvas[(uint(top + row) * uint(draw_w) + uint(left)) * 4:]
		for col in 0 ..< right - left {
			scol := ox + int((f64(left - c.int(x0) + col) + 0.5) * f64(ow) / f64(w))
			scol = max(ox, min(ox + ow - 1, scol))
			s := src_row[uint(scol) * 4:]
			d := dst_row[uint(col) * 4:]
			a := int(s[3])
			if a == 0 {
				continue
			}
			ia := 255 - a
			// Straight-alpha blend: out = src*a + dst*(1-a). Glyph is white
			// (255,255,255), so keeping a the same for all channels tints the
			// underlying frame with white by the glyph's coverage.
			for ch in 0 ..< 3 {
				d[ch] = u8((255 * a + int(d[ch]) * ia) / 255)
			}
			d[3] = 255
		}
	}
}

// ---------------------------------------------------------------------------
// Progress plumbing + job startup (main thread).
// ---------------------------------------------------------------------------

set_status :: proc(s: Render_Status, msg: string) {
	i := 0
	for i < len(msg) && i < len(render_progress.error) - 1 {
		render_progress.error[i] = u8(msg[i])
		i += 1
	}
	render_progress.error[i] = 0
	sync.atomic_store(&render_progress.status, u32(s))
}

cancelled :: proc() -> bool {
	return Render_Status(sync.atomic_load(&render_progress.status)) == .Cancelled
}

poll_cancel :: proc() -> bool {
	return cancelled()
}

render_is_busy :: proc() -> bool {
	return Render_Status(sync.atomic_load(&render_progress.status)) == .Rendering
}

render_cancel :: proc() {
	if !render_is_busy() {
		return
	}
	sync.atomic_store(&render_progress.status, u32(Render_Status.Cancelled))
}

render_out_path :: proc() -> string {
	return string(render_out_path_buf[:render_out_path_len])
}

// render_pick_output_path opens the platform save-as dialog (XDG portal on
// Linux, Win32 common dialog on Windows) and stores the chosen path. The Linux
// SDL3 native dialog shells out to zenity, which is broken against current
// zenity (kills the dialog), so we use the portal path the open-file picker
// already uses.
render_pick_output_path :: proc() {
	path := save_file_picker()
	if path == nil {
		return
	}
	src := string(path)
	render_out_path_len = min(len(src), len(render_out_path_buf) - 1)
	for i in 0 ..< render_out_path_len {
		render_out_path_buf[i] = u8(src[i])
	}
	render_out_path_buf[render_out_path_len] = 0
	render_out_path_set = true
}

// render_start snapshots the timeline and launches the worker thread.
render_start :: proc() {
	if render_is_busy() {
		return
	}
	if !render_out_path_set || render_out_path_len == 0 {
		set_status(.Failed, "pick an output file path first")
		return
	}
	// A rerender must not silently overwrite an earlier export: unless the
	// toggle is on, point at a free <name>_<n>.<ext> (also updates the UI name).
	resolved := render_resolve_output_path()
	if resolved != render_out_path() {
		render_set_out_path(resolved)
	}
	// Clean up a finished previous run.
	poll_completed_thread()

	// Render range.
	start_frame := project.start_frame
	end_frame := project.end_frame
	if start_frame < 0 {
		start_frame = 0
	}
	if end_frame < 0 {
		end_frame = timeline_duration()
	}
	if end_frame <= start_frame {
		set_status(.Failed, "render range is empty")
		return
	}
	// Snapshots: walk the visual stack order (top to bottom) so the
	// compositing arrays inherit the user-facing priority. Audio is
	// order-independent but tracks follow the visual layout.
	cls := [dynamic]Render_Video_Src{}
	auds := [dynamic]Render_Audio_Src{}
	txts := [dynamic]Render_Text_Src{}
	subs := [dynamic]Render_Sub_Src{}
	sync_track_order()
	for w := 0; w < len(timeline.track_order); w += 1 {
		ti := timeline.track_order[w]
		tr := &timeline.tracks[ti]
		for i := 0; i < len(tr.clips); i += 1 {
			clip := &tr.clips[i]
			switch clip.kind {
			case .Video, .Image:
				append(
					&cls,
					Render_Video_Src {
						path = strings.clone_to_cstring(string(clip.path)),
						stream_index = clip.stream_index,
						source_start_frame = clip.source_start_frame,
						source_length_frames = clip.source_length_frames,
						timeline_start_frame = clip.timeline_start_frame,
						transform_x = clip.transform_x,
						transform_y = clip.transform_y,
						scale = clip.scale,
						crop_l = clip.crop_l,
						crop_r = clip.crop_r,
						crop_t = clip.crop_t,
						crop_b = clip.crop_b,
						source_w = clip.source_w,
						source_h = clip.source_h,
					},
				)
			case .Audio:
				append(
					&auds,
					Render_Audio_Src {
						path = strings.clone_to_cstring(string(clip.path)),
						stream_index = clip.stream_index,
						timeline_start_frame = clip.timeline_start_frame,
						source_start_frame = clip.source_start_frame,
						source_length_frames = clip.source_length_frames,
					},
				)
			case .Other:
			// no renderable content in this clip
			case .Empty:
			// no renderable content in this clip (placeholder for text later)
			case .Text:
				if clip.generator == .Subtitles {
					append(
						&subs,
						Render_Sub_Src {
							srt_id = clip.srt_id,
							fps = f32(timeline_fps()),
							timeline_start_frame = clip.timeline_start_frame,
							source_start_frame = clip.source_start_frame,
							source_length_frames = clip.source_length_frames,
							transform_x = clip.transform_x,
							transform_y = clip.transform_y,
							scale = clip.scale,
							source_w = clip.source_w,
							source_h = clip.source_h,
						},
					)
				} else {
					append(
						&txts,
						Render_Text_Src {
							name = strings.clone(clip.name),
							timeline_start_frame = clip.timeline_start_frame,
							source_length_frames = clip.source_length_frames,
							transform_x = clip.transform_x,
							transform_y = clip.transform_y,
							scale = clip.scale,
							source_w = clip.source_w,
							source_h = clip.source_h,
						},
					)
				}
			case .Subtitles:
				// subtitle assets drop as .Text/.Subtitles generator clips (the
				// .Subtitles clip kind is never placed on the timeline)
				if clip.generator == .Subtitles {
					append(
						&subs,
						Render_Sub_Src {
							srt_id = clip.srt_id,
							fps = f32(timeline_fps()),
							timeline_start_frame = clip.timeline_start_frame,
							source_start_frame = clip.source_start_frame,
							source_length_frames = clip.source_length_frames,
							transform_x = clip.transform_x,
							transform_y = clip.transform_y,
							scale = clip.scale,
							source_w = clip.source_w,
							source_h = clip.source_h,
						},
					)
				}
			}
		}
	}
	render_job_videos = cls[:]
	render_job_audios = auds[:]
	render_job_texts = txts[:]
	render_job_subs = subs[:]
	render_job_width = project.width
	render_job_height = project.height
	render_job_start = start_frame
	render_job_end = end_frame - 1
	render_job_nframes = end_frame - start_frame
	render_job_out_path = strings.clone_to_cstring(render_out_path())

	// Even output dimensions for yuv420p.
	if render_job_width % 2 != 0 {
		render_job_width += 1
	}
	if render_job_height % 2 != 0 {
		render_job_height += 1
	}

	// Publish job bounds, then status: the release store on status orders the
	// counter stores, so the worker's reader can never see .Rendering with stale
	// frames_total.
	sync.atomic_store(&render_progress.frames_done, 0)
	sync.atomic_store(&render_progress.frames_total, render_job_nframes)
	sync.atomic_store(&render_progress.status, u32(Render_Status.Rendering))

	render_worker_thread = thread.create(render_worker)
	if render_worker_thread == nil {
		set_status(.Failed, "could not start render thread")
		render_free_workbook()
		return
	}
	thread.start(render_worker_thread)
}

// poll_completed_thread joins+destroys the worker once its status is terminal,
// then releases the main-thread snapshot (render_free_workbook). Runs every UI
// frame, but only does work on the finish transition.
poll_completed_thread :: proc() {
	if !render_is_busy() && render_worker_thread != nil {
		thread.destroy(render_worker_thread)
		render_worker_thread = nil
		render_free_workbook()
	}
}

// render_free_workbook releases the snapshot arrays + cloned strings that
// render_start built on the main thread. The worker never touches them after it
// returns (its job arena died with it), so this is always main-thread-only.
render_free_workbook :: proc() {
	for &v in render_job_videos {
		if v.path != nil {
			mem.delete_cstring(v.path)
		}
	}
	for &a in render_job_audios {
		if a.path != nil {
			mem.delete_cstring(a.path)
		}
		ring_destroy(&a.fifo)
	}
	for &t in render_job_texts {
		if t.name != "" {
			delete(t.name)
			t.name = ""
		}
	}
	delete(render_job_videos)
	delete(render_job_audios)
	delete(render_job_texts)
	if render_job_subs != nil {
		delete(render_job_subs)
	}
	render_job_videos = nil
	render_job_audios = nil
	render_job_texts = nil
	render_job_subs = nil
	if render_job_out_path != nil {
		mem.delete_cstring(render_job_out_path)
		render_job_out_path = nil
	}
}

// init: default output name so Render works without picking a path.
render_init :: proc() {
	init_buf: [512]u8
	def := render_default_output_path(init_buf[:])
	render_out_path_len = len(def)
	for i in 0 ..< len(def) {
		render_out_path_buf[i] = u8(def[i])
	}
	render_out_path_buf[render_out_path_len] = 0
	render_out_path_set = true
}

render_set_out_path :: proc(s: string) {
	i := 0
	for i < len(s) && i < len(render_out_path_buf) - 1 {
		render_out_path_buf[i] = u8(s[i])
		i += 1
	}
	render_out_path_buf[i] = 0
	render_out_path_len = i
	render_out_path_set = true
}

// ---------------------------------------------------------------------------
// Headless end-to-end render test (VYPER_RENDER_TEST="in.mp4|out.mp4").
// ---------------------------------------------------------------------------

test_input_buf: [4096]u8
test_output_buf: [4096]u8

render_test_env :: proc() -> (bool, [2]string) {
	v, _ := os.lookup_env_alloc("VYPER_RENDER_TEST", context.allocator)
	if v == "" {
		return false, [2]string{}
	}
	parts := strings.split(v, "|")
	res: [2]string
	if len(parts) >= 2 {
		res[0] = parts[0]
		res[1] = parts[1]
	}
	return true, res
}

render_test_run :: proc(paths: [2]string) {
	if len(paths[0]) == 0 || len(paths[1]) == 0 {
		fmt.println("render-test: need VYPER_RENDER_TEST=\"<in>|<out>\"")
		os.exit(2)
	}
	n := 0
	for n < len(paths[0]) && n < len(test_input_buf) - 1 {
		test_input_buf[n] = u8(paths[0][n])
		n += 1
	}
	test_input_buf[n] = 0
	import_media(cstring(&test_input_buf[0]))
	if len(timeline.tracks) > 0 && len(timeline.tracks[0].clips) > 0 {
		vclip := &timeline.tracks[0].clips[0]
		fmt.println("render-test clip markers:", len(vclip.markers))
		// VYPER_CROP="l,r,t,b" applies a crop to the first clip so the render
		// output's crop behavior can be verified headlessly.
		if cv, cv_ok := os.lookup_env_alloc("VYPER_CROP", context.allocator); cv_ok && cv != "" {
			parts := strings.split(cv, ",")
			if len(parts) == 4 {
				vals := [4]f64{}
				for i in 0 ..< 4 {
					vals[i], _ = strconv.parse_f64(parts[i])
				}
				vclip.crop_l = f32(vals[0])
				vclip.crop_r = f32(vals[1])
				vclip.crop_t = f32(vals[2])
				vclip.crop_b = f32(vals[3])
			}
		}
	}
	render_set_out_path(paths[1])
	render_overwrite_out = true // the test must write exactly the requested path
	render_start()
	for render_is_busy() {
		time.sleep(50 * time.Millisecond)
	}
	poll_completed_thread()
	st := render_status_text()
	fmt.println("render-test status:", st)
	os.exit(render_status() == .Done ? 0 : 1)
}

// ---------------------------------------------------------------------------
// Headless preview-decode probe (VYPER_PREVIEW_PROBE="in.mp4|split_at").
// Reproduces the split -> delete-one-half -> other-half-shifts-back edit (the
// "moved back" bug) and dumps, per requested frame, what clip_frame the slot
// computed, what the RAM cache keyed, and how the slot's decoded RGBA buffer
// compares against a fresh ground-truth decode of the SAME clip_frame. If the
// probe shows a mismatch, stale/cached content is reaching the buffer; if every
// probe frame matches ground truth but the user still sees the old clip, the
// leak is in a later stage (texture upload / draw), not decode.
// ---------------------------------------------------------------------------

probe_input_buf: [4096]u8
max_slot_idx_used: int
probe_gtbuf: [PREVIEW_W * PREVIEW_H * 4]u8

preview_probe_env :: proc() -> (bool, [2]string) {
	v, _ := os.lookup_env_alloc("VYPER_PREVIEW_PROBE", context.allocator)
	if v == "" {
		return false, [2]string{}
	}
	parts := strings.split(v, "|")
	res: [2]string
	if len(parts) >= 2 {
		res[0] = parts[0]
		res[1] = parts[1]
	}
	return true, res
}

pixel_diff :: proc(a, b: []u8) -> (diff_count: int, max_delta: int) {
	n := len(a)
	if n > len(b) {
		n = len(b)
	}
	for i := 0; i < n; i += 1 {
		d := int(a[i]) - int(b[i])
		if d < 0 {
			d = -d
		}
		if d > 0 {
			diff_count += 1
			if d > max_delta {
				max_delta = d
			}
		}
	}
	return
}

// probe_ground_truth decodes clip_frame from path with a fresh decoder and
// returns how many bytes differ from got, plus the largest per-byte delta.
// Kept as one proc so the probe loop stays short (the decode.odin/render.odin
// macro-heavy status bar file trips Odin's statement parser when new local
// declarations are interleaved with multi-line calls).
probe_ground_truth :: proc(
	path: cstring,
	clip_frame: i64,
	got: []u8,
) -> (
	diffs: int,
	max_delta: int,
	ok: bool,
) {
	gt: Clip_Decoder
	if !open_clip_decoder(&gt, path) {
		return 0, 0, false
	}
	defer clip_decoder_reset(&gt)
	if !decode_clip_frame_sync(&gt, path, clip_frame, probe_gtbuf[:]) {
		return 0, 0, false
	}
	diffs, max_delta = pixel_diff(got, probe_gtbuf[:])
	return diffs, max_delta, true
}

preview_probe_run :: proc(paths: [2]string) {
	preview_proxy_enabled = false // ground truth vs the original decode path
	if len(paths[0]) == 0 {
		fmt.println("preview-probe: need VYPER_PREVIEW_PROBE=\"<in>|<split_at>\"")
		os.exit(2)
	}
	split_at: i64 = 120
	if len(paths[1]) > 0 {
		if sv, ok := strconv.parse_i64(paths[1]); ok {
			split_at = sv
		}
	}
	n := 0
	for n < len(paths[0]) && n < len(probe_input_buf) - 1 {
		probe_input_buf[n] = u8(paths[0][n])
		n += 1
	}
	probe_input_buf[n] = 0
	import_media(cstring(&probe_input_buf[0]))

	total_frames := i64(0)
	for t := 0; t < len(timeline.tracks); t += 1 {
		for ci := 0; ci < len(timeline.tracks[t].clips); ci += 1 {
			c := timeline.tracks[t].clips[ci]
			if c.kind == .Video {
				total_frames = c.source_length_frames
			}
		}
	}
	fmt.println("[probe] imported total_frames =", total_frames)

	playhead.frame = split_at
	// The probe bypasses the UI: split_clip_at_playhead now only splits the
	// currently selected clip, so select track 0's first clip first.
	selected_track = 0
	selected_index = 0
	split_clip_at_playhead()
	fmt.println("[probe] after split at", split_at, "tracks:")
	for t := 0; t < len(timeline.tracks); t += 1 {
		for ci := 0; ci < len(timeline.tracks[t].clips); ci += 1 {
			c := timeline.tracks[t].clips[ci]
			fmt.printf(
				"  track=%d clip tl=[%d,%d) src=[%d,%d) len=%d\n",
				t,
				c.timeline_start_frame,
				c.timeline_start_frame + c.source_length_frames,
				c.source_start_frame,
				c.source_start_frame + c.source_length_frames,
				c.source_length_frames,
			)
		}
	}

	ripple_delete_region(0, split_at)
	fmt.println("[probe] after ripple_delete_region(0,", split_at, ")")
	for t := 0; t < len(timeline.tracks); t += 1 {
		for ci := 0; ci < len(timeline.tracks[t].clips); ci += 1 {
			c := timeline.tracks[t].clips[ci]
			fmt.printf(
				"  track=%d clip tl=[%d,%d) src=[%d,%d) len=%d\n",
				t,
				c.timeline_start_frame,
				c.timeline_start_frame + c.source_length_frames,
				c.source_start_frame,
				c.source_start_frame + c.source_length_frames,
				c.source_length_frames,
			)
		}
	}

	// A linked split fans out to the audio member, so the ripple region then
	// rips the same span from every track and both lanes must keep matching
	// source offsets. This is the A/V-glue invariant after a ripple cut: a
	// mismatch means one lane advanced its source by the wrong amount (the
	// head-trim bug). Report it, then rebuild the scene the way the DRAG path
	// does it: split, delete the left half raw, drag the right half back with
	// clip_slide_in_track (gap-preserving move).
	fmt.printf(
		"[probe] AUDIO_DESYNC_CHECK: video_clip src_start=%d, audio_clip src_start=%d (should match for A/V glue)\n",
		timeline.tracks[0].clips[0].source_start_frame,
		timeline.tracks[1].clips[0].source_start_frame,
	)

	// Rebuild: fresh import, split, raw-delete left half, slide right half back.
	track0 := &timeline.tracks[0]
	clear(&track0.clips)
	track1 := &timeline.tracks[1]
	clear(&track1.clips)
	import_media(cstring(&probe_input_buf[0]))
	playhead.frame = split_at
	selected_track = 0
	selected_index = 0
	split_clip_at_playhead()
	// Raw delete of the LEFT half (clip[0]) leaves a gap; right half stays put.
	selected_track = 0
	selected_index = 0
	delete_selected_clip_raw()
	fmt.println("[probe] after raw-delete left, before drag-back:")
	for t := 0; t < len(timeline.tracks); t += 1 {
		for ci := 0; ci < len(timeline.tracks[t].clips); ci += 1 {
			c := timeline.tracks[t].clips[ci]
			fmt.printf(
				"  track=%d clip tl=[%d,%d) src=[%d,%d) len=%d\n",
				t,
				c.timeline_start_frame,
				c.timeline_start_frame + c.source_length_frames,
				c.source_start_frame,
				c.source_start_frame + c.source_length_frames,
				c.source_length_frames,
			)
		}
	}
	// Drag the right-half clip back to tl=0 on track 0 (gap-close move).
	slide_to := clip_slide_in_track(
		&timeline.tracks[0],
		0,
		timeline.tracks[0].clips[0].source_length_frames,
		0,
		timeline.tracks[0].clips[0].timeline_start_frame,
	)
	timeline.tracks[0].clips[0].timeline_start_frame = slide_to
	fmt.printf("[probe] slide right-half back -> tl=%d\n", slide_to)
	for t := 0; t < len(timeline.tracks); t += 1 {
		for ci := 0; ci < len(timeline.tracks[t].clips); ci += 1 {
			c := timeline.tracks[t].clips[ci]
			fmt.printf(
				"  track=%d clip tl=[%d,%d) src=[%d,%d) len=%d\n",
				t,
				c.timeline_start_frame,
				c.timeline_start_frame + c.source_length_frames,
				c.source_start_frame,
				c.source_start_frame + c.source_length_frames,
				c.source_length_frames,
			)
		}
	}

	// Header for the trace below (mirrors the re-enabled [vf] gate).
	fmt.println(
		"[probe] frame playhead_playing req clip_frame last_frame have_last cache_keys has_frame  |  pixel_diff(ground_truth)",
	)
	max_slot_idx_used = 1
	total_frames_run := int(total_frames + 4)
	for f := 0; f < total_frames_run; f += 1 {
		// Interleave paused and playing to exercise both the exact-request path
		// (paused) and the dropped-frame playback path (playing).
		playhead.frame = i64(f)
		playhead.playing = false
		update_preview_slots()
		for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
			slot := &preview_slots[s]
			if !slot.in_use {
				continue
			}
			fmt.printf(
				"  [probe paused f=%d] asset=%d tl=%d src=%d clip_frame=%d last=%d have_last=%v keys={",
				f,
				slot.asset_id,
				slot.timeline_start_frame,
				slot.source_start_frame,
				slot.source_start_frame + i64(f) - slot.timeline_start_frame,
				slot.dec.last_frame,
				slot.dec.have_last,
			)
			for ci := 0; ci < len(slot.dec.cache); ci += 1 {
				if ci > 0 {
					fmt.print(",")
				}
				fmt.print(slot.dec.cache[ci].frame)
			}
			fmt.printf("} has_frame=%v\n", slot.has_frame)
		}
		if max_slot_idx_used > 0 {
			playhead.playing = true
			update_preview_slots()
			for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
				slot := &preview_slots[s]
				if !slot.in_use {
					continue
				}
				expected := slot.source_start_frame + i64(f) - slot.timeline_start_frame
				diffs, maxd, gt_ok := probe_ground_truth(slot.path, expected, slot.buffer[:])
				fmt.printf(
					"  [probe play f=%d] clip_frame=%d last=%d have_last=%v has_frame=%v gt_served=%v pixel_diff=%d max_delta=%d\n",
					f,
					expected,
					slot.dec.last_frame,
					slot.dec.have_last,
					slot.has_frame,
					gt_ok,
					diffs,
					maxd,
				)
			}
		}
	}
	os.exit(0)
}

// ---------------------------------------------------------------------------
// VYPER_BOUNDARY_PROBE="<file>|<split1>|<split2>": reproduce the exact reported
// scene — import, split at split1, split at split2, raw-delete the middle clip,
// drag the tail back to sit flush against the left clip — then step the playhead
// across the boundary, pixel-comparing every displayed slot buffer against
// ground truth. The generic preview probe deletes the LEFT half (single clip, no
// crossing); this one keeps the left clip so the playhead genuinely moves from
// clip A into the dragged-back tail.
// ---------------------------------------------------------------------------

boundary_probe_print_clips :: proc() {
	for t := 0; t < len(timeline.tracks); t += 1 {
		for ci := 0; ci < len(timeline.tracks[t].clips); ci += 1 {
			c := timeline.tracks[t].clips[ci]
			fmt.printf(
				"  track=%d clip tl=[%d,%d) src=[%d,%d) len=%d\n",
				t,
				c.timeline_start_frame,
				c.timeline_start_frame + c.source_length_frames,
				c.source_start_frame,
				c.source_start_frame + c.source_length_frames,
				c.source_length_frames,
			)
		}
	}
}

boundary_probe_run :: proc(v: string) {
	preview_proxy_enabled = false // ground truth vs the original decode path
	parts := strings.split(v, "|")
	if len(parts) < 2 {
		fmt.println("boundary-probe: need VYPER_BOUNDARY_PROBE=\"<file>|<split1>[|<split2>]\"")
		os.exit(2)
	}
	file := parts[0]
	s1: i64 = 68
	if sv, ok := strconv.parse_i64(parts[1]); ok {
		s1 = sv
	}
	s2: i64 = 184
	if sv, ok := strconv.parse_i64(parts[2]); ok {
		s2 = sv
	}
	total_frames := i64(s2 + 400)
	inp: [4096]u8
	n := 0
	for n < len(file) && n < len(inp) - 1 {
		inp[n] = u8(file[n])
		n += 1
	}
	inp[n] = 0
	path := cstring(&inp[0])
	import_media(path)

	// Split 1 at s1 on clip 0 (tl [0,total) src [0,total)).
	selected_track = 0
	selected_index = 0
	playhead.frame = s1
	split_clip_at_playhead()
	// Split 2 at s2 on clip index 1 (the [s1,total) half).
	selected_track = 0
	selected_index = 1
	playhead.frame = s2
	split_clip_at_playhead()
	fmt.println("[bprobe] after splits at", s1, s2)
	boundary_probe_print_clips()
	// Raw-delete the middle [s1,s2) clip.
	selected_track = 0
	selected_index = 1
	delete_selected_clip_raw()
	// Drag the tail back flush: nearest valid non-overlapping start near s1.
	track := &timeline.tracks[0]
	last := len(track.clips) - 1
	slide_to := clip_slide_in_track(
		track,
		last,
		track.clips[last].source_length_frames,
		s1,
		track.clips[last].timeline_start_frame,
	)
	track.clips[last].timeline_start_frame = slide_to
	fmt.println("[bprobe] after raw-delete middle + drag tail back")
	boundary_probe_print_clips()

	fmt.println(
		"[bprobe] stepped play (playing=true, pixel-vs-ground-truth): tl/src cf last has_frame | diff maxd",
	)
	for ph := i64(0); ph < total_frames; ph += 1 {
		playhead.frame = ph
		playhead.playing = true
		update_preview_slots()
		for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
			slot := &preview_slots[s]
			if !slot.in_use {
				continue
			}
			expected := slot.source_start_frame + playhead.frame - slot.timeline_start_frame
			diffs, maxd, gt_ok := probe_ground_truth(slot.path, expected, slot.buffer[:])
			fmt.printf(
				"[bprobe ph=%d] tl=%d src=%d cf=%d last=%d hv=%v hf=%v gt=%v diff=%d maxd=%d\n",
				playhead.frame,
				slot.timeline_start_frame,
				slot.source_start_frame,
				expected,
				slot.dec.last_frame,
				slot.dec.have_last,
				slot.has_frame,
				gt_ok,
				diffs,
				maxd,
			)
		}
	}

	// Live-cadence pass: the playhead runs ahead of decode (dropped-frame
	// preview). Burst THROUGH the boundary and keep going, exactly like
	// real-time playback where decode trails the playhead. Every displayed
	// buffer is compared to ground truth: in probe mode the worker is drained
	// after each step, so the posted playhead frame is what lands in the slot.
	fmt.println(
		"[bprobe] live dropped-frame cadence (decode trails playhead, burst across boundary)",
	)
	invalidate_preview_slots()
	ph: i64 = 40
	for step_i in 0 ..< 30 {
		playhead.frame = ph
		playhead.playing = true
		update_preview_slots()
		for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
			slot := &preview_slots[s]
			if !slot.in_use {
				continue
			}
			shown := slot.source_start_frame + playhead.frame - slot.timeline_start_frame
			diffs, maxd, gt_ok := probe_ground_truth(slot.path, shown, slot.buffer[:])
			fmt.printf(
				"[bprobe live ph=%d] shown_cf=%d tl=%d src=%d has_frame=%v last=%d | gt=%v diff=%d maxd=%d\n",
				ph,
				shown,
				slot.timeline_start_frame,
				slot.source_start_frame,
				slot.has_frame,
				slot.dec.last_frame,
				gt_ok,
				diffs,
				maxd,
			)
		}
		if step_i == 7 {
			ph += 10 // burst 61 -> 71: crosses the 68 boundary in a single tick
		} else if ph < 100 {
			ph += 3
		} else {
			ph += 1
		}
	}

	// Replay pass: prime the tail's source frames in the decoder's RAM cache
	// (first playthrough), then REPLAY from the head. Cache writes during the
	// head replay can leave a tail frame receivable as a cache hit while the
	// decoder is still physically parked inside clip A — at the boundary a hit
	// for src184 does not reposition, so the very next forward request believes
	// it can continue from "184" and decodes src68 (DELETE clip's region) while
	// labeling it the tail's frame.
	fmt.println("[bprobe] replay pass: prime tail cache, scrub to head, cross again")
	invalidate_preview_slots()
	for ph := i64(0); ph < 220; ph += 1 {
		playhead.frame = ph
		playhead.playing = true
		update_preview_slots()
	}
	// Scrubbing back to the head costs only cache hits (paused: exact request).
	playhead.playing = false
	playhead.frame = 63
	update_preview_slots()
	fmt.printf("[bprobe replay] scrubbed to 63, crossing:= cache keys =")
	for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
		if preview_slots[s].in_use {
			for ci := 0; ci < len(preview_slots[s].dec.cache); ci += 1 {
				fmt.printf(" %d", preview_slots[s].dec.cache[ci].frame)
			}
		}
	}
	fmt.print("\n")
	for ph := i64(63); ph < 80; ph += 1 {
		playhead.frame = ph
		playhead.playing = true
		update_preview_slots()
		for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
			slot := &preview_slots[s]
			if !slot.in_use {
				continue
			}
			expected := slot.source_start_frame + ph - slot.timeline_start_frame
			diffs, maxd, gt_ok := probe_ground_truth(slot.path, expected, slot.buffer[:])
			fmt.printf(
				"[bprobe replay ph=%d] cf=%d tl=%d src=%d last=%d hv=%v has_frame=%v | gt=%v diff=%d maxd=%d\n",
				ph,
				expected,
				slot.timeline_start_frame,
				slot.source_start_frame,
				slot.dec.last_frame,
				slot.dec.have_last,
				slot.has_frame,
				gt_ok,
				diffs,
				maxd,
			)
		}
	}
	os.exit(0)
}

// ---------------------------------------------------------------------------
// VYPER_FRAME_PROBE="<file>|<start>-<end>|<stride>": ground-truth frame check.
//
// The preview probe's pixel_diff compares two decodes that use the SAME seek
// logic, so a systematic seek bug (wrong frame delivered, offset the same way
// both times) is invisible to it. This probe breaks that symmetry: it first
// decodes every frame 0..end IN ORDER (forward path, never seeks), hashing each
// PREVIEW-buffer, then requests each frame in [start,end) the way
// decode_clip_frame_sync does (seek path) and compares hashes. Any mismatch is
// decode returning the wrong source frame for the requested index.
// ---------------------------------------------------------------------------

probe_hash_buf: [PREVIEW_W * PREVIEW_H * 4]u8
probe_hash_gt: [PREVIEW_W * PREVIEW_H * 4]u8
probe_hashes: [dynamic]u64

fnv64 :: proc(data: []u8) -> u64 {
	h := u64(0xcbf29ce484222325)
	prime := u64(0x100000001b3)
	for b in data {
		h = (h ~ u64(b)) * prime
	}
	return h
}

probe_hash_decode_sync :: proc(path: cstring, clip_frame: i64) -> (u64, bool) {
	pc: Clip_Decoder
	defer clip_decoder_reset(&pc)
	if !open_clip_decoder(&pc, path) {
		return 0, false
	}
	if !decode_clip_frame_sync(&pc, path, clip_frame, probe_hash_gt[:]) {
		return 0, false
	}
	return fnv64(probe_hash_gt[:]), true
}

preview_framecheck_run :: proc(v: string) {
	preview_proxy_enabled = false // ground truth vs the original decode path
	parts := strings.split(v, "|")
	if len(parts) < 3 {
		fmt.println("frame-probe: need VYPER_FRAME_PROBE=\"<file>|<start>-<end>|<stride>\"")
		os.exit(2)
	}
	file := parts[0]
	range_s := parts[1]
	stride_st, ok_stride := strconv.parse_i64(parts[2])
	if !ok_stride || stride_st < 1 {
		stride_st = 1
	}
	rb := strings.split(range_s, "-")
	if len(rb) != 2 {
		fmt.println("frame-probe: bad range", range_s)
		os.exit(2)
	}
	f0, ok0 := strconv.parse_i64(rb[0])
	f1, ok1 := strconv.parse_i64(rb[1])
	if !ok0 || !ok1 || f0 < 0 || f1 < f0 {
		fmt.println("frame-probe: bad range", range_s)
		os.exit(2)
	}

	inp: [4096]u8
	n := 0
	for n < len(file) && n < len(inp) - 1 {
		inp[n] = u8(file[n])
		n += 1
	}
	inp[n] = 0
	path := cstring(&inp[0])

	// Pass 1: decode every frame in order and hash each PREVIEW buffer.
	seq: Clip_Decoder
	if !open_clip_decoder(&seq, path) {
		fmt.println("frame-probe: open failed")
		os.exit(2)
	}
	clear(&probe_hashes)
	for fi := i64(0); fi <= f1; fi += 1 {
		if !decode_source_frame(&seq, fi) {
			fmt.printf("frame-probe: decode stopped at %d\n", fi)
			break
		}
		decode_into_buffer(&seq, probe_hash_buf[:], PREVIEW_W, PREVIEW_H)
		append(&probe_hashes, fnv64(probe_hash_buf[:]))
	}
	clip_decoder_reset(&seq)

	bad := 0
	checked := 0
	buf: [4096]u8
	n = 0
	for n < len(file) && n < len(buf) - 1 {
		buf[n] = u8(file[n])
		n += 1
	}
	buf[n] = 0
	fmt.println("[frame-probe] seq_count =", len(probe_hashes))
	probe_t0: time.Time
	max_ms: f64
	slow_cnt := 0
	for fi := f0; fi <= f1 && fi < i64(len(probe_hashes)); fi += stride_st {
		probe_t0 = time.now()
		h, ok := probe_hash_decode_sync(path, fi)
		ms := time.duration_milliseconds(time.since(probe_t0))
		if ms > max_ms {
			max_ms = ms
		}
		checked += 1
		if ms > 50 {
			slow_cnt += 1
			if slow_cnt <= 40 {
				fmt.printf("  SLOW frame=%5d elapsed_ms=%.0f ok=%v\n", fi, ms, ok)
			}
		}
		if !ok {
			fmt.printf("  frame %5d: decode failed\n", fi)
			continue
		}
		if h != probe_hashes[fi] {
			bad += 1
			if bad <= 40 {
				fmt.printf("  MISMATCH frame=%5d sync=%016x seq=%016x\n", fi, h, probe_hashes[fi])
			}
		}
	}
	fmt.printf(
		"[frame-probe] checked=%d mismatches=%d slow(>50ms)=%d max_ms=%.0f%s\n",
		checked,
		bad,
		slow_cnt,
		max_ms,
		bad > 40 ? " (rest suppressed)" : "",
	)
	os.exit(bad == 0 ? 0 : 1)
}
