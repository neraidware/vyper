package main

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import avcodec "vendor/ffmpeg/avcodec"
import avfmt "vendor/ffmpeg/avformat"
import avutil "vendor/ffmpeg/avutil"
import sws "vendor/ffmpeg/swscale"
import sdl "vendor:sdl3"

// ---------------------------------------------------------------------------
// Video export: composite the timeline (as shown in the preview) and encode it
// as MP4/H.264 + AAC with the vendored FFmpeg. Rendering runs on a worker
// thread (UI stays responsive) against a snapshot of the timeline; the main
// thread only reads the progress state through a mutex.
// ---------------------------------------------------------------------------

RENDER_FPS :: 60
RENDER_AUDIO_RATE :: 48000
// Audio frames per output video frame: 48000/60 = 800.
AUDIO_PER_VIDEO :: 800
// AAC encodes in fixed 1024-sample frames.
AAC_FRAME_SIZE :: 1024
Render_Default_Path :: "render.mp4"

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

// render_progress is the only state shared with the worker thread; every field
// is guarded by job_mutex.
render_progress: struct {
	job_mutex:  sync.Mutex,
	status:     Render_Status,
	frames_done: i64,
	frames_total: i64,
	error:      [256]u8,
	guarding_thread: ^thread.Thread,
}

render_status :: proc() -> Render_Status {
	sync.mutex_lock(&render_progress.job_mutex)
	defer sync.mutex_unlock(&render_progress.job_mutex)
	return render_progress.status
}

render_status_text :: proc() -> string {
	sync.mutex_lock(&render_progress.job_mutex)
	defer sync.mutex_unlock(&render_progress.job_mutex)
	switch render_progress.status {
	case .Idle:
		return "Ready"
	case .Rendering:
		total := render_progress.frames_total
		done := render_progress.frames_done
		if total <= 0 {
			return "Rendering..."
		}
		pct := i64(100) * done / total
		return fmt.aprintf("Rendering %lld / %lld (%d%%)", done, total, pct)
	case .Done:
		return "Render complete"
	case .Failed:
		return fmt.aprintf("Failed: %s", cstring(&render_progress.error[0]))
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
	path:                cstring, // owned copy, freed by the worker
	stream_index:        c.int,
	source_start_frame:  i64,
	source_length_frames: i64,
	timeline_start_frame: i64,
	transform_x:         f32,
	transform_y:         f32,
	scale:               f32,
	crop_l:              f32,
	crop_r:              f32,
	crop_t:              f32,
	crop_b:              f32,
	source_w:            c.int,
	source_h:            c.int,
	// Compositing state (computed once at open).
	dec:                 Clip_Decoder,
	rw, rh:              c.int, // display rect size in output pixels
	ox, oy:              c.int, // rounded top-left offset on the canvas
	blit:                []u8,  // rw*rh*4 scaled frame
}

Render_Audio_Src :: struct {
	path:                cstring,
	stream_index:        c.int,
	timeline_start_frame: i64,
	source_length_frames: i64,
	dec:                 Audio_Clip_Decoder, // 48 kHz stereo S16
	fifo:                [dynamic]f32,     // converted stereo f32, content-relative
	first48:             i64,              // content 48 kHz frame of fifo[0]
	have48:              i64,              // content frames produced so far (next un-produced)
}

render_job_videos: []Render_Video_Src
render_job_audios: []Render_Audio_Src
render_job_out_path: cstring
render_job_width:  c.int
render_job_height: c.int
render_job_start:  i64
render_job_end:    i64 // inclusive
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
render_display_rect :: proc(
	src: ^Render_Video_Src,
	PW, PH: c.int,
) -> (l, t, r, b: f32) {
	cw, ch := render_full_box_dims(
		src.source_w, src.source_h,
		f32(PW) * src.scale, f32(PH) * src.scale,
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
	fmt_ctx:       ^avfmt.FormatContext,
	vstream:       ^avfmt.Stream,
	vcodec_ctx:    ^avcodec.CodecContext,
	astream:       ^avfmt.Stream,
	acodec_ctx:    ^avcodec.CodecContext,
	sws_rgb_yuv:   ^sws.Context,
	yuv_data:      [4][^]u8,
	yuv_linesize:  [4]c.int,
	yuv_avail:     bool,
	audio_frame:   ^avutil.Frame,
	audio_plane:   bool,
	vpkt:          ^avcodec.Packet,
	apkt:          ^avcodec.Packet,
	audio_pending: [AAC_FRAME_SIZE * 2 * 2]f32,
	audio_pending_n: int,
	audio_sent:    i64, // total 48k samples pushed so far (pts basis)
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
enc_drain :: proc(e: ^Render_Enc, ctx: ^avcodec.CodecContext, stream: ^avfmt.Stream, pkt: ^avcodec.Packet) -> bool {
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
enc_open_video :: proc(e: ^Render_Enc, width, height: c.int) -> bool {
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
	ctx.time_base = avutil.Rational{num = 1, den = RENDER_FPS}
	ctx.framerate = avutil.Rational{num = RENDER_FPS, den = 1}
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
		width, height, avutil.PixelFormat.RGBA,
		width, height, avutil.PixelFormat.YUV420P,
		sws.Flags{.Bilinear}, nil, nil, nil,
	)
	if e.sws_rgb_yuv == nil {
		fmt.println("sws_getContext (rgb->yuv) failed")
		return false
	}
	if avutil.image_alloc(&e.yuv_data[0], &e.yuv_linesize[0], width, height, avutil.PixelFormat.YUV420P, 32) < 0 {
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
	ctx.time_base = avutil.Rational{num = 1, den = RENDER_AUDIO_RATE}
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
	if avutil.samples_alloc(&f.data[0], &f.linesize[0], 2, AAC_FRAME_SIZE, avutil.SampleFormat.FltP, 0) < 0 {
		fmt.println("av_samples_alloc (audio) failed")
		return false
	}
	e.audio_plane = true
	return true
}

render_open_output :: proc(e: ^Render_Enc, path: cstring, width, height: c.int, with_audio: bool) -> bool {
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
	if !enc_open_video(e, width, height) {
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

rend_enc_video_frame :: proc(e: ^Render_Enc, rgb: []u8, width, height: c.int, frame_index: i64) -> bool {
	slice: [1][^]u8 = {raw_data(rgb)}
	ls: [4]c.int = {width * 4, 0, 0, 0}
	sws.scale(
		e.sws_rgb_yuv,
		cast([^][^]u8)&slice[0],
		cast([^]c.int)&ls[0],
		0, height,
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
		// at_seconds growing keeps the underlying decoder from re-seeking.
		n := decode_audio_chunk(&a.dec, f64(a.have48) / f64(RENDER_AUDIO_RATE))
		if n <= 0 {
			break
		}
		for j in 0 ..< n {
			append(&a.fifo, f32(a.dec.s16[j * 2 + 0]) / 32768.0)
			append(&a.fifo, f32(a.dec.s16[j * 2 + 1]) / 32768.0)
		}
		a.have48 += i64(n)
	}
}

render_audio_open :: proc(a: ^Render_Audio_Src, render_start: i64) -> bool {
	overlap_start := max(a.timeline_start_frame, render_start)
	content_sec := f64(overlap_start - a.timeline_start_frame) / f64(RENDER_FPS)
	if !open_audio_decoder_resampled(&a.dec, a.path, a.stream_index, RENDER_AUDIO_RATE, 2) {
		return false
	}
	if !seek_audio(&a.dec, content_sec) {
		return false
	}
	a.first48 = i64(content_sec * f64(RENDER_AUDIO_RATE))
	a.have48 = a.first48
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
	set_status(.Rendering, "")
	fail := false
	e := Render_Enc{}
	err_msg := ""
	defer {
		enc_cleanup(&e)
		for &v in render_job_videos {
			clip_decoder_reset(&v.dec)
			if v.path != nil {
				mem.delete_cstring(v.path)
				v.path = nil
			}
			if v.blit != nil {
				delete(v.blit)
				v.blit = nil
			}
		}
		for &a in render_job_audios {
			if a.dec.opened {
				audio_decoder_reset(&a.dec)
			}
			if a.fifo != nil {
				delete(a.fifo)
				a.fifo = nil
			}
			if a.path != nil {
				mem.delete_cstring(a.path)
				a.path = nil
			}
		}
		delete(render_job_videos)
		delete(render_job_audios)
		render_job_videos = nil
		render_job_audios = nil
		if render_job_out_path != nil {
			mem.delete_cstring(render_job_out_path)
			render_job_out_path = nil
		}
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
		v.blit = make([]u8, int(v.rw) * int(v.rh) * 4)
		if !open_clip_decoder_ex(&v.dec, v.path, v.stream_index, v.rw, v.rh, false) {
			err_msg = "failed to open video source"
			fail = true
			return
		}
	}

	has_audio := len(render_job_audios) > 0
	if has_audio {
		for i in 0 ..< len(render_job_audios) {
			a := &render_job_audios[i]
			if !render_audio_open(a, render_job_start) {
				a.dec.opened = false
			}
		}
	}

	if !render_open_output(&e, render_job_out_path, render_job_width, render_job_height, has_audio) {
		err_msg = "failed to open output"
		fail = true
		return
	}
	if e.acodec_ctx == nil {
		has_audio = false
	}

	canvas := make([]u8, int(render_job_width) * int(render_job_height) * 4)
	defer delete(canvas)

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
			if timeline_frame < v.timeline_start_frame || timeline_frame >= v.timeline_start_frame + v.source_length_frames {
				continue
			}
			src_frame := v.source_start_frame + timeline_frame - v.timeline_start_frame
			if !decode_source_frame(&v.dec, src_frame) {
				continue
			}
			decode_into_buffer(&v.dec, v.blit, v.rw, v.rh)
			render_blit(canvas, render_job_width, render_job_height, v)
		}
		if !rend_enc_video_frame(&e, canvas, render_job_width, render_job_height, frame_idx) {
			err_msg = "video encoding failed"
			fail = true
			return
		}

		if has_audio {
			mix: [AUDIO_PER_VIDEO * 2]f32
			for aa in 0 ..< len(render_job_audios) {
				a := &render_job_audios[aa]
				if !a.dec.opened {
					continue
				}
				if timeline_frame < a.timeline_start_frame || timeline_frame >= a.timeline_start_frame + a.source_length_frames {
					continue
				}
				start48 := (timeline_frame - a.timeline_start_frame) * AUDIO_PER_VIDEO
				render_audio_pull(a, start48 + AUDIO_PER_VIDEO)
				if a.have48 < start48 + AUDIO_PER_VIDEO {
					continue
				}
				base := int(start48 - a.first48)
				for s in 0 ..< AUDIO_PER_VIDEO {
					mix[s * 2 + 0] += a.fifo[base + s * 2 + 0]
					mix[s * 2 + 1] += a.fifo[base + s * 2 + 1]
				}
			}
			if !rend_enc_push_audio(&e, mix[:]) {
				err_msg = "audio encoding failed"
				fail = true
				return
			}
		}

		sync.mutex_lock(&render_progress.job_mutex)
		render_progress.frames_done = frame_idx + 1
		sync.mutex_unlock(&render_progress.job_mutex)
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
render_blit :: proc(canvas: []u8, draw_w, draw_h: c.int, v: ^Render_Video_Src) {
	top := max(v.oy, 0)
	bottom := min(v.oy + v.rh, draw_h)
	left := max(v.ox, 0)
	right := min(v.ox + v.rw, draw_w)
	if bottom <= top || right <= left {
		return
	}
	scol := left - v.ox
	srow := top - v.oy
	rows := bottom - top
	cols := right - left
	for row in 0 ..< rows {
		src := v.blit[uint(srow + row) * uint(v.rw) * 4 + uint(scol) * 4:][:uint(cols) * 4]
		dst := canvas[uint(top + row) * uint(draw_w) * 4 + uint(left) * 4:][:uint(cols) * 4]
		copy(dst, src)
	}
}

// ---------------------------------------------------------------------------
// Progress plumbing + job startup (main thread).
// ---------------------------------------------------------------------------

set_status :: proc(s: Render_Status, msg: string) {
	sync.mutex_lock(&render_progress.job_mutex)
	render_progress.status = s
	i := 0
	for i < len(msg) && i < len(render_progress.error) - 1 {
		render_progress.error[i] = u8(msg[i])
		i += 1
	}
	render_progress.error[i] = 0
	sync.mutex_unlock(&render_progress.job_mutex)
}

cancelled :: proc() -> bool {
	sync.mutex_lock(&render_progress.job_mutex)
	c := render_progress.status == .Cancelled
	sync.mutex_unlock(&render_progress.job_mutex)
	return c
}

poll_cancel :: proc() -> bool {
	return cancelled()
}

render_is_busy :: proc() -> bool {
	sync.mutex_lock(&render_progress.job_mutex)
	busy := render_progress.status == .Rendering
	sync.mutex_unlock(&render_progress.job_mutex)
	return busy
}

render_cancel :: proc() {
	if !render_is_busy() {
		return
	}
	sync.mutex_lock(&render_progress.job_mutex)
	render_progress.status = .Cancelled
	sync.mutex_unlock(&render_progress.job_mutex)
}

render_out_path :: proc() -> string {
	return string(render_out_path_buf[:render_out_path_len])
}

// SDL save-file dialog callback: copies the chosen path into the fixed buffer.
render_save_cb :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	if filelist == nil || filelist[0] == nil {
		return
	}
	src := string(filelist[0])
	render_out_path_len = min(len(src), len(render_out_path_buf) - 1)
	for i in 0 ..< render_out_path_len {
		render_out_path_buf[i] = u8(src[i])
	}
	render_out_path_buf[render_out_path_len] = 0
	render_out_path_set = true
}

render_pick_output_path :: proc() {
	filters := [1]sdl.DialogFileFilter{{name = "MP4 video", pattern = "*.mp4"}}
	sdl.ShowSaveFileDialog(
		render_save_cb, nil, app_window,
		&filters[0], 1,
		cstring(&render_out_path_buf[0]),
	)
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
	// Snapshots.
	cls := [dynamic]Render_Video_Src{}
	auds := [dynamic]Render_Audio_Src{}
	for track_idx := 0; track_idx < len(timeline.tracks); track_idx += 1 {
		tr := &timeline.tracks[track_idx]
		for i := 0; i < len(tr.clips); i += 1 {
			clip := &tr.clips[i]
			switch clip.kind {
			case .Video, .Image:
				append(&cls, Render_Video_Src{
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
				})
case .Audio:
			append(&auds, Render_Audio_Src{
				path = strings.clone_to_cstring(string(clip.path)),
				stream_index = clip.stream_index,
				timeline_start_frame = clip.timeline_start_frame,
				source_length_frames = clip.source_length_frames,
			})
		case .Other:
			// no renderable content in this clip
		}
		}
	}
	render_job_videos = cls[:]
	render_job_audios = auds[:]
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

	sync.mutex_lock(&render_progress.job_mutex)
	render_progress.frames_done = 0
	render_progress.frames_total = render_job_nframes
	render_progress.status = .Rendering
	sync.mutex_unlock(&render_progress.job_mutex)

	render_worker_thread = thread.create(render_worker)
	if render_worker_thread == nil {
		set_status(.Failed, "could not start render thread")
		rising_thread_failed()
		return
	}
	thread.start(render_worker_thread)
}

// poll_completed_thread joins+destroys the worker once its status is terminal.
poll_completed_thread :: proc() {
	if !render_is_busy() && render_worker_thread != nil {
		thread.destroy(render_worker_thread)
		render_worker_thread = nil
	}
}

rising_thread_failed :: proc() {
	// Cleanup snapshot memory if thread creation failed.
	for &v in render_job_videos {
		if v.path != nil {
			mem.delete_cstring(v.path)
		}
	}
	for &a in render_job_audios {
		if a.path != nil {
			mem.delete_cstring(a.path)
		}
	}
	delete(render_job_videos)
	delete(render_job_audios)
	render_job_videos = nil
	render_job_audios = nil
	if render_job_out_path != nil {
		mem.delete_cstring(render_job_out_path)
		render_job_out_path = nil
	}
}

// init: default output name so Render works without picking a path.
render_init :: proc() {
	def := string(Render_Default_Path)
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
// Headless end-to-end render test (NERED_RENDER_TEST="in.mp4|out.mp4").
// ---------------------------------------------------------------------------

test_input_buf: [4096]u8
test_output_buf: [4096]u8

render_test_env :: proc() -> (bool, [2]string) {
	v, _ := os.lookup_env_alloc("NERED_RENDER_TEST", context.allocator)
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
		fmt.println("render-test: need NERED_RENDER_TEST=\"<in>|<out>\"")
		os.exit(2)
	}
	n := 0
	for n < len(paths[0]) && n < len(test_input_buf) - 1 {
		test_input_buf[n] = u8(paths[0][n])
		n += 1
	}
	test_input_buf[n] = 0
	import_media(cstring(&test_input_buf[0]))
	render_set_out_path(paths[1])
	render_start()
	for render_is_busy() {
		time.sleep(50 * time.Millisecond)
	}
	poll_completed_thread()
	st := render_status_text()
	fmt.println("render-test status:", st)
	os.exit(render_status() == .Done ? 0 : 1)
}