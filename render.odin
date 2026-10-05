package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:sort"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import avcodec "vendor/ffmpeg/avcodec"
import avfmt "vendor/ffmpeg/avformat"
import avutil "vendor/ffmpeg/avutil"
import sws "vendor/ffmpeg/swscale"
import yuvconv "vendor/yuv"
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
// RENDER_VIDEO_PRESET is the libx264 speed/quality preset. Left unset, libx264
// defaults to "medium"; "fast" is the quality-preserving step down (measured on
// a 30s 1080p60 clip: medium 14.2s, fast 12.2s, faster 9.4s, veryfast 6.2s).
RENDER_VIDEO_PRESET :: "fast"
Render_Default_Path :: "render.mp4"

// Render_Output is the export target state: the overwrite policy, the output
// path chosen with the save dialog (fixed buffer, written by the SDL callback,
// read on the main thread when starting a render), and the scratch used by
// render_resolve_output_path (used at most once per render start, so a single
// shared buffer is fine).
Render_Output :: struct {
	overwrite: bool,
	path_buf:  [4096]u8,
	path_len:  int,
	path_set:  bool, // default path is filled in at startup
	resolve_scratch: [4096]u8,
}
render_output: Render_Output = {path_set = true}

// render_encoder_ui.choice picks the export video encoder family: .GPU is the
// default -- it tries the first hardware H.264 encoder that actually opens on
// this machine and ends with libx264 as the guaranteed fallback, because a
// GPU choice must never fail the render just because the device is absent.
// .CPU is explicitly libx264 ("High quality"), for when the user wants
// x264's better compression efficiency per bit. Hardware encoders trade
// quality for speed; the choice is explicit, never implicit.
Render_Encoder_Choice :: enum u32 {
	CPU,
	GPU,
}
Render_Encoder_UI :: struct {
	choice:     Render_Encoder_Choice,
	menu_open:  bool, // the export-encoder dropdown ("GPU" / "CPU" readout)
}
render_encoder_ui: Render_Encoder_UI = {choice = .GPU}

// The per-platform hardware encoder candidate order lives in hw_encode.odin,
// shared with the proxy encoder so both paths agree on what "hardware first"
// means. Each candidate is only accepted when a real open succeeds; libx264 is
// always the last resort.

// app_window is the SDL window handle, owned by the main thread (window
// creation in main.odin, size reads here and in textinput.odin).
app_window: ^sdl.Window

// render_resolve_output_path returns the path a fresh render should write (the
// plain target when overwrite is on or the file doesn't exist yet, else
// <dir>/<base>_<n><ext> for the first n whose name is free) unless the name
// cap is somehow exhausted, in which case it falls back to the raw target.
render_resolve_output_path :: proc() -> string {
	target := render_out_path()
	if render_output.overwrite || !os.exists(target) {
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
		name := fmt.bprintf(render_output.resolve_scratch[:], "%s%s_%d%s", target[:dir_end], base, n, ext)
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

Render_Status :: enum {
	Idle,
	Rendering,
	Done,
	Failed,
	Cancelled,
}

// Render_Progress is the only state shared with the worker thread. Single-writer
// handoff, no mutex: the worker writes status/error/frames_done and the main
// thread writes frames_total; status is the release/acquire gate, so the error
// buffer and counters are settled before a reader sees the state that consumes
// them (UI reading .Failed sees a fully-written error string, render_start
// reading .Rendering sees a settled frames_total).
Render_Progress :: struct {
	status:       u32, // atomic
	frames_done:  i64, // atomic
	frames_total: i64, // atomic
	error:        [256]u8,
}
render_progress: Render_Progress

// RENDER_LIVE_PUBLISH_NS is how often the composite hands a frame to the live
// preview sink. The preview during an export is a PROGRESS display, not the
// 60 fps editing surface: publishing every composite frame would pay a
// full-canvas conversion (NV12->RGBA at 1080p is ~2 ms) for pixels nobody sees
// at that rate. 100 ms puts ~10 frames a second on screen for ~2% of the
// composite thread, which is the point of a progress view.
RENDER_LIVE_PUBLISH_NS :: 100 * time.Millisecond

// Render_Live is the preview sink's window onto the export in progress: the
// composed frame the worker just finished, for the UI to display instead of
// the timeline preview.
//
// One buffer, not a ring, and that is a decision rather than an oversight. A
// second writer-side buffer would need a reader handshake to stay race-free
// (the composite would have to know the UI had finished with it), and with a
// publish interval the composite never waits on the UI anyway -- so the
// handshake would buy nothing. Overflow policy: DROP. When the UI has not
// drained the previous frame the composite skips publishing and keeps
// encoding; the UI goes on showing the older COMPLETE frame. The producer is
// never stalled by the consumer (AGENTS §1), which is the whole reason the
// preview cannot become the thing that slows an export down.
//
// Handoff: `ready` is the only shared word. The composite copies bytes, writes
// `frame`, then release-stores ready=true; the consumer's acquire-load pairs with
// that store, so every byte in buf is settled before it reads them. The
// consumer's clear is the CLAIM and it is held for the whole copy out
// (render_live_drain): clearing before the copy would let the composite refill
// buf in the middle of it, which is a torn frame rather than a stale one.
Render_Live :: struct {
	// buf is SESSION HEAP (AGENTS §1), sized to the job canvas and reused across
	// runs, which is why it is not carved from the job arena with the encode
	// ring: that arena dies with the worker, and this buffer is the one piece of
	// the preview that outlives it.
	buf:       []u8,
	ready:     bool, // atomic: buf holds a frame the UI has not taken yet
	frame:     i64,  // timeline frame in buf; written before ready is published
	w, h:      c.int,
	// nv12_rgba converts the GPU path's NV12 canvas into buf. The CPU path hands
	// the composite's RGBA canvas straight across; the GPU path (default, since
	// gpu_nv12_enabled) leaves eslot.canvas untouched for this frame, so without
	// this the preview would show the ring slot's previous use of it -- a real
	// but stale frame. Worker-only: created by render_live_begin before the
	// worker starts, freed when the run ends. A context is freed by whoever made
	// it, and nobody else here has one.
	nv12_rgba: ^sws.Context,
	last_ns:   i64, // worker-only: last publish instant
	// shown says the UI has drawn at least one frame from this mailbox, which
	// is what lets the composite start publishing (see render_live_publish).
	// Atomic like ready: written by the UI thread, read by the worker.
	shown:     bool, // atomic
}
render_live: Render_Live

// render_live_begin sizes the mailbox for a job. UI thread, before the worker
// starts: the buffer outlives the run, so it is allocated from the app
// allocator here rather than from the job arena inside the worker. Allocates
// only when the dimensions change, so a re-render at the same size reuses it.
render_live_begin :: proc(w, h: c.int) {
	if w <= 0 || h <= 0 {
		return
	}
	n := int(w) * int(h) * 4
	if render_live.buf == nil || len(render_live.buf) != n {
		if render_live.buf != nil {
			delete(render_live.buf)
		}
		render_live.buf = make([]u8, n)
	}
	if render_live.w != w || render_live.h != h {
		render_live_destroy_ctx()
		render_live.nv12_rgba = sws.getContext(
			w,
			h,
			avutil.PixelFormat.NV12,
			w,
			h,
			avutil.PixelFormat.RGBA,
			sws.Flags{.Bilinear},
			nil,
			nil,
			nil,
		)
		render_live.w, render_live.h = w, h
	}
	// Reset the handoff. `shown` matters here: it gates publishing until the UI
	// has drawn one frame, so a fresh run must earn that again -- a run must not
	// inherit the previous run's "already on screen" state, or it publishes into
	// a mailbox nobody is draining.
	sync.atomic_store(&render_live.ready, false)
	sync.atomic_store(&render_live.shown, false)
	render_live.last_ns = 0
}

render_live_destroy_ctx :: proc() {
	if render_live.nv12_rgba != nil {
		sws.freeContext(render_live.nv12_rgba)
		render_live.nv12_rgba = nil
	}
}

// render_live_end closes the mailbox when the run reaches a terminal state. The
// preview goes back to the timeline rather than freezing on the last export
// frame: the run is over, the user is editing again, and a stale finished render
// sitting where the clips should be is worse than none. The texture is kept --
// it is the sink's resource, and recreating it per run would be churn.
render_live_end :: proc() {
	sync.atomic_store(&render_live.ready, false)
	render_live_destroy_ctx()
}

// render_live_teardown frees the session-heap buffer at shutdown.
render_live_teardown :: proc() {
	render_live_destroy_ctx()
	if render_live.buf != nil {
		delete(render_live.buf)
		render_live.buf = nil
	}
}

// render_live_publish offers the composite's finished frame to the UI. Worker
// thread. `nv12` is the packed NV12 canvas when the GPU conversion produced one
// (the encoder consumes that instead of the RGBA canvas, which is then stale
// for this frame); nil means the RGBA canvas is the real one.
//
// Returns without touching buf when the mailbox still holds an undrained frame,
// when the publish interval has not elapsed, or when no frame has been consumed
// to draw yet. That last one is a usability gate, not a memory one: a mailbox
// filled before the UI's first draw would be shown as the render's opening
// frame with no visible progress, which reads as a hung export.
render_live_publish :: proc(rgba: []u8, nv12: []u8, frame: i64) {
	live := &render_live
	if live.buf == nil || live.w <= 0 || live.h <= 0 {
		return
	}
	if !sync.atomic_load(&live.shown) {
		return
	}
	if sync.atomic_load(&live.ready) {
		return  // drop: the UI still has the previous frame
	}
	now := time.now()._nsec
	if live.last_ns != 0 && now - live.last_ns < i64(RENDER_LIVE_PUBLISH_NS) {
		return
	}
	if nv12 != nil {
		if live.nv12_rgba == nil {
			return
		}
		// NV12 is TWO planes, not one packed image: full-resolution luma, then
		// byte-interleaved U,V starting at w*h with a row pitch of w (the whole
		// width, because the chroma samples share each row). swscale reads
		// srcSlice[1] unconditionally, so a one-entry array hands it whatever
		// followed it on the stack -- which is a segfault, not wrong pixels.
		// Layout matches yuv_ref_rgba_to_nv12, the byte-exact reference.
		src: [2][^]u8 = {raw_data(nv12), raw_data(nv12[int(live.w) * int(live.h):])}
		src_ls: [4]c.int = {live.w, live.w, 0, 0}
		dst: [1][^]u8 = {raw_data(live.buf)}
		dst_ls: [4]c.int = {live.w * 4, 0, 0, 0}
		if sws.scale(
			live.nv12_rgba,
			cast([^][^]u8)&src,
			cast([^]c.int)&src_ls,
			0,
			live.h,
			cast([^][^]u8)&dst,
			cast([^]c.int)&dst_ls,
		) <= 0 {
			return  // refuse to publish rather than show a half-converted frame
		}
	} else {
		copy(live.buf, rgba)
	}
	live.last_ns = now
	live.frame = frame
	// Release: everything written above is visible to the UI's acquire load.
	sync.atomic_store(&live.ready, true)
}

// render_live_drain copies the mailbox into the caller's buffer for this UI tick
// and returns the frame it copied, or ok=false when nothing was published.
//
// The claim is HELD for the copy. Claim-then-return-the-pointer would let the
// composite refill buf while the caller is still reading it -- a torn frame,
// which is worse than a stale one because nothing in the pixels says which half
// is from when. The caller owns `dst` and nothing writes it after this returns,
// so releasing the claim as the last step is the whole synchronization.
render_live_drain :: proc(dst: []u8) -> (frame: i64, w, h: c.int, ok: bool) {
	live := &render_live
	if live.buf == nil {
		return 0, 0, 0, false
	}
	// Exchange, not load-then-store: the clear IS the claim, and load-then-store
	// lets two consumers both see the frame set and both copy it out.
	if !sync.atomic_exchange(&live.ready, false) {
		return 0, 0, 0, false
	}
	// Read the descriptor BEFORE the copy: it is stable only while the claim is
	// held, and holding it is this proc's whole job.
	frame, w, h = live.frame, live.w, live.h
	n := min(len(dst), len(live.buf))
	copy(dst[:n], live.buf[:n])
	return frame, w, h, true
}

// Render_Meter is the render-status UI readout: the status line scratch, the
// FPS meter's EWMA window (the worker writes frames_done atomically; the UI
// samples from render_progress here each tick; a bare instant per UI tick
// would jitter with the 16 ms frame cadence), and the FPS text buffer. Only
// the UI thread touches the window.
RENDER_FPS_WINDOW_S :: 0.25
Render_Meter :: struct {
	status_buf: [256]u8,
	fps_wnd: struct {
		prev_ns:   i64,
		prev_done: i64,
		fps:       f64,
	},
	fps_buf: [32]u8,
}
render_meter: Render_Meter

render_status :: proc() -> Render_Status {
	return Render_Status(sync.atomic_load(&render_progress.status))
}

// render_fps_text samples the meter and returns a " · N fps" suffix ("" until
// the first window has completed frames). done < prev_done means a new render
// run reset frames_done to 0, which (re)anchors the window.
render_fps_text :: proc(done: i64) -> string {
	wnd := &render_meter.fps_wnd
	now := i64(monotonic_ns())
	if wnd.prev_ns == 0 || done < wnd.prev_done {
		wnd.prev_ns = now
		wnd.prev_done = done
		wnd.fps = 0
		return ""
	}
	dt := f64(now - wnd.prev_ns) / 1e9
	if dt >= RENDER_FPS_WINDOW_S {
		if done > wnd.prev_done {
			inst := f64(done - wnd.prev_done) / dt
			wnd.fps = wnd.fps == 0 ? inst : 0.5 * wnd.fps + 0.5 * inst
		}
		wnd.prev_ns = now
		wnd.prev_done = done
	}
	if wnd.fps <= 0 {
		return ""
	}
	text := fmt.bprintf(render_meter.fps_buf[:], " · %.1f fps", wnd.fps)
	return string(text)
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
		text := fmt.bprintf(render_meter.status_buf[:], "Rendering %d / %d (%d%%)%s", done, total, pct, render_fps_text(done))
		return string(text)
	case .Done:
		return "Render complete"
	case .Failed:
		text := fmt.bprintf(render_meter.status_buf[:], "Failed: %s", cstring(&render_progress.error[0]))
		return string(text)
	case .Cancelled:
		return "Render cancelled"
	}
	return ""
}

render_output_name :: proc() -> string {
	if render_output.path_len == 0 {
		return "No output path"
	}
	return path_basename(cstring(&render_output.path_buf[0]))
}

// ---------------------------------------------------------------------------
// Timeline snapshot taken on the main thread when a render starts, so the
// worker never touches live timeline state.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Keyed geometry in the render worker (S6).
//
// A video/image clip whose transform/scale/crop properties carry keyframes is
// EXPORTED ANIMATED: the worker decodes at a stage sized to the range's max
// scale once, then per frame samples the seven properties at the timeline
// frame and region-copies the matching sub-rect of the stage (the mapping is
// 1:1 — the box scales linearly with `scale`, so the animated box is a
// centered crop of the max-scale stage with no resampling). Clips with no
// geometry keys keep the old baked path untouched.
// ---------------------------------------------------------------------------

KF_RENDER_MAX_KEYS :: 64

Render_Geom_Prop :: enum u8 {
	Trans_X,
	Trans_Y,
	Scale,
	Crop_L,
	Crop_R,
	Crop_T,
	Crop_B,
	// Opacity rides the same lane machinery as the geometry props even though
	// it is not geometry: it has a resting field plus an optional keyframe
	// track, so it needs the same "a write goes wherever the sampler reads"
	// routing (clip_geom.odin), the same pending-bit bookkeeping, and the same
	// per-lane Key button. It groups with no section, exactly like Scale.
	//
	// Opacity was the last lane that fit geom_modified's u8 bitmask; Zoom and Pan
	// took it past eight, so that field is u16 now.
	Opacity,
	// Zoom and Pan are the CONTENT window, as distinct from Crop.
	//
	// Crop stays the underlying model — four insets naming a window in the source
	// — and Zoom/Pan are modifiers applied to that window before it becomes a
	// source rect. What they replace is the Alt+wheel and Alt+middle gestures,
	// which used to FAKE a window change by writing seven fields across three
	// properties (four crop lanes plus Scale plus both transforms) to hold the box
	// still. That compensation is the hack: it has to be kept in step by hand, and
	// it is why those gestures needed their own probe.
	//
	// Zoom is UNIFORM across both axes by necessity, not taste: it scales the
	// window about its center, so per-axis factors would change the box's aspect
	// ratio — which contradicts the invariant the gesture has always had, that the
	// visible box never moves or resizes. Pan is per-axis because sliding a window
	// within a source does not distort it.
	//
	// Consumed at the source-window stage, BEFORE the box is placed, not as a
	// post-transform pass over rendered pixels. That ordering is load-bearing for
	// the export: crop_src_rect picks an INTEGER rect inside the decoded stage and
	// the display box maps to it 1:1, which is what lets a keyed clip region-copy
	// per frame with no resampling. A post-transform zoom would destroy the 1:1
	// mapping and force a resample every frame.
	Zoom,
	Pan_X,
	Pan_Y,
	_COUNT,
}

// render_geom_short_name is the inspector's abbreviated label for a lane, used by
// the pending-lane summary row.
//
// It is a switch, not a positional table beside render_geom_name, and that is the
// whole point: the positional version had eight entries for an eleven-lane enum,
// so it read past the end of the literal whenever enough lanes were pending at
// once — a segfault from formatting a garbage string pointer, reachable only
// after enough geometry edits to light up the high lanes. A switch against the
// enum cannot drift: adding a lane is a compile error here, not an out-of-bounds
// read three frames later.
render_geom_short_name :: proc(p: Render_Geom_Prop) -> string {
	switch p {
	case .Trans_X:
		return "X"
	case .Trans_Y:
		return "Y"
	case .Scale:
		return "Scale"
	case .Crop_L:
		return "L"
	case .Crop_R:
		return "R"
	case .Crop_T:
		return "T"
	case .Crop_B:
		return "B"
	case .Opacity:
		return "Opac"
	case .Zoom:
		return "Zoom"
	case .Pan_X:
		return "PanX"
	case .Pan_Y:
		return "PanY"
	case ._COUNT:
		unreachable()
	}
	return ""
}

render_geom_name :: proc(p: Render_Geom_Prop) -> string {
	switch p {
	case .Trans_X:
		return "transform.x"
	case .Trans_Y:
		return "transform.y"
	case .Scale:
		return "scale"
	case .Crop_L:
		return "crop.l"
	case .Crop_R:
		return "crop.r"
	case .Crop_T:
		return "crop.t"
	case .Crop_B:
		return "crop.b"
	case .Opacity:
		return "opacity"
	case .Zoom:
		return "zoom"
	case .Pan_X:
		return "pan.x"
	case .Pan_Y:
		return "pan.y"
	case ._COUNT:
		unreachable()
	}
	return ""
}

// Kf_Geom_Section groups the geometry lanes that animate as one multi-lane
// property: a packed section key (mask != 0) lives on the section's own track
// ("crop", "transform"), while per-lane scalar keys live on the individual
// property tracks. Section and lanes are two migration forms of ONE animation
// and never coexist (kf_unwrap_section / kf_fold_lanes in keyframes.odin).
//
// The lanes are the ACTUAL geometry property variables (Render_Geom_Prop), not
// string literals: the property variable IS the lane's identity and its track
// name comes from render_geom_name. A lane's packed index is its position
// within `lanes` (section-relative), so the mask bits and the [KF_PACK_MAX]f32
// payload stay keyed per section, independent of the global enum ordering.
Kf_Geom_Section :: struct {
	name:  string,
	lanes: []Render_Geom_Prop,
}

kf_geom_sections :: []Kf_Geom_Section {
	{
		name  = "crop",
		lanes = []Render_Geom_Prop{.Crop_L, .Crop_R, .Crop_T, .Crop_B},
	},
	{
		name  = "transform",
		lanes = []Render_Geom_Prop{.Trans_X, .Trans_Y},
	},
}

// kf_lane_name is a section lane's keyframe TRACK name — the consumer's
// property label, resolved from the property variable. The generic store
// consults this (never the property enum directly) so it stays name-agnostic.
kf_lane_name :: proc(lane: Render_Geom_Prop) -> string {
	return render_geom_name(lane)
}

// ---------------------------------------------------------------------------
// Geometry keyframe policy: sections, packed groups, lane<->property mapping.
//
// The store (keyframes.odin) knows only opaque named tracks plus the packed
// [KF_PACK_MAX]f32 payload. Everything about WHICH geometry properties group
// into one packed section — and what a lane track name means — lives here with
// Render_Geom_Prop, the owner of that mapping.
//
// A section key (mask != 0) lives on a track named after the SECTION itself
// ("crop", "transform"); a scalar key lives on one LANE track ("crop.l"). The
// section and its lanes are two migration forms of ONE animation and never
// coexist: keying a whole section folds any keyed lanes into packed form
// (kf_geom_fold_lanes), keying an individual lane unwraps a packed section
// into per-lane tracks first (kf_geom_unwrap_section). Both migrations are
// value-exact — same knots, same lane values, same interpolation: a packed
// knot only ever carries the lanes that have a breakpoint at that frame, so
// each lane's curve (and the section knot the fold sets) is its own.
// ---------------------------------------------------------------------------

kf_geom_section_index :: proc(name: string) -> (index: int, ok: bool) {
	defs := kf_geom_sections
	for i in 0 ..< len(defs) {
		if defs[i].name == name {
			return i, true
		}
	}
	return 0, false
}

// kf_geom_full_mask is the mask that keys every lane of section `sec` — the
// whole-group key shape. Section names come from kf_geom_sections verbatim, so
// an unknown name is an invariant error.
kf_geom_full_mask :: proc(sec: string) -> u8 {
	sec_index, ok := kf_geom_section_index(sec)
	assert(ok, "kf_geom_full_mask: name is not a section")
	defs := kf_geom_sections
	def := defs[sec_index]
	mask: u8 = 0
	for li in 0 ..< len(def.lanes) {
		mask |= 1 << uint(li)
	}
	return mask
}

// kf_geom_section_for_lane maps a scalar LANE name to its (section index, lane
// index); a plain property (gain, scale) that groups with nothing misses.
kf_geom_section_for_lane :: proc(name: string) -> (sec_index, lane_index: int, ok: bool) {
	defs := kf_geom_sections
	for s in 0 ..< len(defs) {
		for li in 0 ..< len(defs[s].lanes) {
			if kf_lane_name(defs[s].lanes[li]) == name {
				return s, li, true
			}
		}
	}
	return 0, 0, false
}

// kf_geom_unwrap_section fans a packed section track out to per-lane scalar
// tracks — "you keyed an individual lane, so the group has to give way." Each
// packed key becomes one scalar key per lane its mask keys (on that lane's OWN
// track at the same frame), then the section track is dropped. Value-exact: the
// per-lane scalar animation reproduces the packed one knot-for-knot. Caller
// owns the structure bump. Paired invariant: a lane and its packed section
// never coexist.
kf_geom_unwrap_section :: proc(clip: ^Clip, sec: string) {
	sec_index, ok := kf_geom_section_index(sec)
	assert(ok, "kf_geom_unwrap_section: name is not a section")
	si := kf_track_index(clip^, sec)
	if si < 0 {
		return
	}
	defs := kf_geom_sections
	def := defs[sec_index]
	trk := session_trk_view(clip.keyframe_tracks, si); src_keys := trk.keys
	li: int = 0
	for lane_prop in def.lanes {
		lane_name := kf_lane_name(lane_prop)
		assert(
			kf_track_index(clip^, lane_name) < 0,
			fmt.tprintf("lane %q coexists with its packed section %q", lane_name, sec),
		)
		session_trk_push(&clip.keyframe_tracks, Kf_Track {name = session_str_intern(lane_name)})
		lane := session_trk_view_mut(&clip.keyframe_tracks, clip.keyframe_tracks.n-1)
		v := session_kf_view(src_keys)
		session_kf_reserve(&lane.keys, src_keys.n)
		for i in 0 ..< src_keys.n {
			k := v[i]
			if vval, covered := kf_lane_value(k, li); covered {
				session_kf_push(&lane.keys, Keyframe{frame_off=k.frame_off, value=vval, interp=k.interp})
			}
		}
		li += 1
	}
	// Section keys stay live until all scalar lanes have been built. Return
	// exclusive key slots only; a shared source range remains with its peer.
	keys := session_trk_view(clip.keyframe_tracks, si)^.keys
	if !keys.shared {
		session_kf_release(keys)
	}
	session_trk_erase(&clip.keyframe_tracks, si)
}

// kf_geom_any_lane_tracked reports whether any lane of `def` owns a live track.
kf_geom_any_lane_tracked :: proc(clip: ^Clip, def: Kf_Geom_Section) -> bool {
	for lane_prop in def.lanes {
		if kf_track_index(clip^, kf_lane_name(lane_prop)) >= 0 {
			return true
		}
	}
	return false
}

// kf_geom_fold_lanes migrates scalar lane tracks BACK to the packed section form
// — the reverse of kf_geom_unwrap_section, run when a grouped key lands on top
// of keyed lanes. The union of every lane's key frames (plus the new set frame)
// becomes section knots; each knot keys ONLY the lanes that have a breakpoint
// there (their own key on that frame), and the set knot keys ALL lanes with the
// new group values. Because a lane never appears in a knot where it lacks its
// own breakpoint, its packed curve is exactly its scalar curve — the fold is
// value-exact: adding a whole-crop key over keyed lanes reproduces the per-lane
// animation everywhere the new key doesn't land, and unwrap (the reverse
// migration) lands back on the same per-lane tracks.
kf_geom_fold_lanes :: proc(
	clip: ^Clip,
	sec_index: int,
	set_frame: i32,
	set_lanes: [KF_PACK_MAX]f32,
	full_mask: u8,
) {
	defs := kf_geom_sections
	def := defs[sec_index]
	frames := make([dynamic]i32, 0, 8)
	defer delete(frames)
	for lane_prop in def.lanes {
		if ti := kf_track_index(clip^, kf_lane_name(lane_prop)); ti >= 0 {
			track_keys := session_trk_view(clip.keyframe_tracks, ti).keys
			assert(track_keys.n > 0, "an empty lane track is a store invariant violation")
			v := session_kf_view(track_keys)
			for i in 0 ..< track_keys.n {
				k := v[i]
				append(&frames, k.frame_off)
			}
		}
	}
	append(&frames, set_frame)
	sort.quick_sort(frames[:])
	packed: [KF_PACK_MAX]f32
	for i := 0; i < len(frames); i += 1 {
		if i > 0 && frames[i] == frames[i-1] {
			continue // dedupe: one knot per unique frame
		}
		fk := frames[i]
		knot_mask: u8 = 0
		for li in 0 ..< len(def.lanes) {
			packed[li] = 0
			if fk == set_frame {
				packed[li] = set_lanes[li]
				knot_mask |= 1 << uint(li)
				continue
			}
			if ti := kf_track_index(clip^, kf_lane_name(def.lanes[li])); ti >= 0 {
				// A lane is in this knot only at its OWN key frames; a knot on
				// someone else's frame must not break its curve.
				track_keys := session_trk_view(clip.keyframe_tracks, ti).keys
				v := session_kf_view(track_keys)
				for i in 0 ..< track_keys.n {
					ck := v[i]
					if ck.frame_off == fk {
						packed[li] = ck.value.(f32)
						knot_mask |= 1 << uint(li)
						break
					}
				}
			}
		}
		assert(knot_mask != 0, "a fold knot must key at least one lane")
		kf_set_packed_key(clip, def.name, fk, packed, knot_mask)
	}
	// The section now owns the animation; drop the lane tracks (which must
	// hold only keys — folding never leaves an authority behind).
	for lane_prop in def.lanes {
		if ti := kf_track_index(clip^, kf_lane_name(lane_prop)); ti >= 0 {
			tr := session_trk_view_mut(&clip.keyframe_tracks, ti)
			assert(tr.keys.n > 0, "folding dropped a keyed lane")
			// name is a pool handle; only the keys array is owned.
			if !tr.keys.shared {
				session_kf_release(tr.keys)
			}
			session_trk_erase(&clip.keyframe_tracks, ti)
		}
	}
}

// kf_geom_set_packed records a section key on `sec` at frame_off — the grouped
// producer (whole-crop / whole-transform keyframe). `lanes` is [lane]value,
// `mask` selects which lanes the key carries (a group key uses the section's
// full mask). Section and lanes are mutually exclusive forms: if any lane track
// already holds keys they are folded into the packed form first
// (kf_geom_fold_lanes), then the key lands.
kf_geom_set_packed :: proc(clip: ^Clip, sec: string, frame_off: i32, lanes: [KF_PACK_MAX]f32, mask: u8) {
	sec_index, ok := kf_geom_section_index(sec)
	assert(ok, "kf_geom_set_packed: name is not a section")
	defs := kf_geom_sections
	def := defs[sec_index]
	full_mask := kf_geom_full_mask(sec)
	assert(mask != 0 && mask & full_mask == mask, "kf_geom_set_packed: mask keys lanes outside the section")
	kf_bump_structure()
	if kf_geom_any_lane_tracked(clip, def) {
		kf_geom_fold_lanes(clip, sec_index, frame_off, lanes, full_mask)
		return
	}
	kf_set_packed_key(clip, sec, frame_off, lanes, mask)
}

// kf_geom_set_packed_lane_key records ONE lane's value at frame_off on the
// section's PACKED track, leaving the group packed. Returns false when there is
// no packed section to write into (a non-lane name, or a section that is already
// unwrapped), so the caller can fall back to kf_geom_set_lane_key and keep the
// behavior it had.
//
// This exists because "extend the animation that is already there" and "give
// this property its own track" are two different requests that both arrive as a
// lane write, and only the second one should rewrite the section's shape.
// Auto-key is the first: the toggle says "record my edits on the timeline", and
// a user who keyed their crop as one whole-crop section must not find it split
// into four per-lane tracks because they dragged one edge. The inspector's
// per-lane Key button and a typed value are the second, and those still unwrap
// (kf_geom_set_lane_key).
//
// mask carries only this lane's bit, which is the form the sampler is built for:
// kf_sample_packed_lane skips knots that do not cover a lane, so the other lanes
// keep their own curves and simply interpolate through this frame instead of
// gaining a breakpoint they were never given.
//
// A key already ON the frame is merged into rather than replaced: the
// same-frame path in kf_set_packed_key overwrites mask and value wholesale, so
// calling it here would drop the other lanes' values from a full-mask knot the
// user placed themselves.
kf_geom_set_packed_lane_key :: proc(clip: ^Clip, name: string, frame_off: i32, value: f32) -> bool {
	sec_index, li, is_lane := kf_geom_section_for_lane(name)
	if !is_lane {
		return false
	}
	defs := kf_geom_sections
	sec := defs[sec_index].name
	si := kf_track_index(clip^, sec)
	if si < 0 {
		return false
	}
	tr := session_trk_view_mut(&clip.keyframe_tracks, si)
	bit := u8(1) << uint(li)
	session_kf_make_unique(&tr.keys)
	v := session_kf_view_mut(tr.keys)
	for i in 0 ..< tr.keys.n {
		k := &v[i]
		if k.frame_off != frame_off {
			continue
		}
		switch &v in k.value {
		case [KF_PACK_MAX]f32:
			v[li] = value
			k.mask |= bit
			kf_bump_structure()
			return true
		case f32:
			// A scalar key on a section track would mean the two forms
			// coexist, which kf_geom_sample_lane asserts against. Assert
			// here rather than rewrite it: a silent conversion would hide
			// the writer that produced it.
			assert(false, "kf_geom_set_packed_lane_key: scalar key on a packed section track")
		}
	}
	payload: [KF_PACK_MAX]f32
	payload[li] = value
	kf_set_packed_key(clip, sec, frame_off, payload, bit)
	kf_bump_structure()
	return true
}

// kf_geom_set_lane_key records a scalar key on `name` at frame_off for ANY
// geometry property name. When `name` is a LANE of a section that is currently
// packed, the group gives way FIRST: fan the section out to per-lane tracks,
// then write. ("You keyed an individual value, so the array unwraps.") A plain
// property (scale, or any non-lane name) lands as an ordinary scalar key.
kf_geom_set_lane_key :: proc(clip: ^Clip, name: string, frame_off: i32, value: f32) {
	if sec_index, _, is_lane := kf_geom_section_for_lane(name); is_lane {
		defs := kf_geom_sections
		sec := defs[sec_index].name
		if kf_track_index(clip^, sec) >= 0 {
			kf_geom_unwrap_section(clip, sec)
		}
	}
	kf_set_key(clip, name, frame_off, value)
}

// kf_geom_set_value edits ONE scalar's value at frame_off. On a packed section
// the section unwraps first and the edit lands on lane 0 (the readout's
// displayed lane) — the rule that any individual-value edit makes the group give
// way. A non-section name lands as an ordinary scalar edit.
kf_geom_set_value :: proc(clip: ^Clip, name: string, frame_off: i32, value: f32) {
	if sec_index, ok := kf_geom_section_index(name); ok {
		if kf_track_index(clip^, name) < 0 {
			return
		}
		kf_geom_unwrap_section(clip, name)
		defs := kf_geom_sections
		kf_set_key(clip, kf_lane_name(defs[sec_index].lanes[0]), frame_off, value)
		return
	}
	kf_set_key(clip, name, frame_off, value)
}

// kf_geom_sample_lane evaluates geometry property track `name` at a TIMELINE
// frame, relative to the clip start. When `name` is a LANE of a section that
// lives in packed form, the packed section track is sampled for that lane
// instead of the (absent) lane track; any other name (scale, gain) samples its
// own track.
kf_geom_sample_lane :: proc(clip: ^Clip, name: string, timeline_frame: i64, base: f32) -> (f32, bool) {
	sec_index, li, is_lane := kf_geom_section_for_lane(name)
	if is_lane {
		defs := kf_geom_sections
		if si := kf_track_index(clip^, defs[sec_index].name); si >= 0 {
			assert(kf_track_index(clip^, name) < 0, "a lane must be absent while its section is packed")
			return kf_sample_packed_lane(
				&session_trk_view(clip.keyframe_tracks, si)^,
				i32(timeline_frame - clip.timeline_start_frame),
				li,
				base,
			)
		}
	}
	return kf_sample_for(clip, name, timeline_frame, base)
}

// kf_geom_fill_snapshot copies geometry property `name`'s track into `dst` up
// to its cap, returning (copied, total). When `name` is a LANE of a section
// whose track lives in packed form, the section is unpacked here — each section
// key expands to a scalar key carrying `name`'s lane value (keys whose mask
// doesn't cover the lane are skipped), so the cross-thread seam stays
// packed-free.
kf_geom_fill_snapshot :: proc(clip: ^Clip, name: string, dst: []Keyframe) -> (n, total: int) {
	sec_index, li, is_lane := kf_geom_section_for_lane(name)
	if is_lane {
		defs := kf_geom_sections
		sec := defs[sec_index].name
		si := kf_track_index(clip^, sec)
		if si >= 0 {
			assert(kf_track_index(clip^, name) < 0, "a lane must be absent while its section is packed")
			track_keys := session_trk_view(clip.keyframe_tracks, si).keys
			v := session_kf_view(track_keys)
			for i in 0 ..< track_keys.n {
				k := v[i]
				if _, covered := kf_lane_value(k, li); covered {
					total += 1
				}
			}
			n = min(total, len(dst))
			di := 0
			for i in 0 ..< track_keys.n {
				k := v[i]
				if value, covered := kf_lane_value(k, li); covered {
					if di < n {
						dst[di] = Keyframe {frame_off = k.frame_off, value = value, interp = k.interp}
						di += 1
					}
				}
			}
			return
		}
	}
	return kf_fill_snapshot(clip, name, dst)
}

// Render_Kf_Flat is one geometry property's key track copied FLAT onto a
// Render_Geom_Snap. Filled on the UI thread at render_start; the worker owns it
// for the job and never touches the live timeline (kf_fill_snapshot).
Render_Kf_Flat :: struct {
	keys: [KF_RENDER_MAX_KEYS]Keyframe,
	n:    int,
}

// Render_Geom_Snap is ONE clip's geometry as it crosses the UI->worker thread
// boundary: the resting values, every lane's flattened key track, and the flags
// derived from them. EVERY visual source carries one, filled by the single proc
// below.
//
// Why this is a type and not a convention. The snapshot used to be hand-written
// per clip kind: Render_Video_Src got geom_base + kf_geom + geom_keyed, while
// Render_Text_Src and Render_Sub_Src got three loose resting `f32`s each. Text
// therefore exported its RESTING transform for the whole clip — the animation
// previewed correctly and never crossed the thread hop — and the same three
// omissions took text opacity with them, since no text field existed to lose.
// Nothing in the type system could catch that: a missing animation is the
// absence of a field, and an absent field is indistinguishable from an
// intentional one.
//
// As a field it is no longer optional. A new clip kind gets its geometry
// animation by having a Render_Geom_Snap, and cannot "forget" it, because there
// is nothing to forget — the data rides along whether the consumer reads it or
// not. That is what makes the preview/export split structural instead of a
// discipline problem, and it is why the parity probe's per-lane check could
// honestly claim the two sinks cannot disagree.
//
// Immutable for the life of the job. The worker must never read the live clip,
// and a base that changed under it would make the same frame evaluate
// differently on its second call.
Render_Geom_Snap :: struct {
	// base is the clip's RESTING geometry and opacity — what a lane samples
	// against where no covering key applies, and the same shape the preview
	// latch holds.
	base: Geom_Sample,
	// keys is every Render_Geom_Prop lane's key track, flattened. Indexed by the
	// enum, so a lane added to Render_Geom_Prop is carried here with no second
	// list to extend.
	keys: [int(Render_Geom_Prop._COUNT)]Render_Kf_Flat,
	// keyed is "some lane has keys", and it is what routes a source onto the
	// per-frame animated path instead of the baked one.
	keyed: bool,
	// scale_keyed and opacity_keyed are the two lanes that change a DECISION
	// made once at setup rather than a per-frame rect: a keyed scale needs a
	// stage sized for its maximum (or a re-baked text raster), and a keyed
	// opacity means canvas-zeroing must treat the clip as possibly translucent.
	// Kept explicit because "some lane is keyed" cannot answer either question.
	scale_keyed:   bool,
	opacity_keyed: bool,
}

// geom_snap_eval is the carrier's one read path: the value of every lane at
// clip-relative `off`. The flat counterpart of the preview's geom_sample_clip,
// and the only way a worker composite should learn a clip's geometry.
geom_snap_eval :: proc(snap: ^Render_Geom_Snap, off: i32) -> Geom_Sample {
	return geom_sample_flat(snap.base, &snap.keys, off)
}

// geom_snap_offset is the clip-relative frame a source composites at. One place
// so a consumer cannot sample at the wrong origin against a base that is
// already clip-relative.
geom_snap_offset :: proc(snap: ^Render_Geom_Snap, timeline_start_frame, timeline_frame: i64) -> i32 {
	return i32(timeline_frame - timeline_start_frame)
}

// render_geom_snap_fill snapshots `clip` into `snap`. The ONE writer: every
// visual source is filled through this, so no clip kind can take a different (or
// narrower) route across the boundary.
//
// The lane loop is the enum, not a hand-listed set of properties, so a lane
// added to Render_Geom_Prop is carried across automatically.
//
// crop lanes are NOT cleared here. A text clip has no source frame to crop (its
// raster is sized to the ink), so crop must read 0 for it — but that is a
// statement about how a text clip DRAWS, not about what its keys say, so it
// belongs with the text consumer (geom_clear_crop) rather than being baked into
// the shared carrier where it would silently zero a video clip's crop.
render_geom_snap_fill :: proc(snap: ^Render_Geom_Snap, clip: ^Clip) {
	snap^ = {}
	snap.base = geom_sample_resting(clip)
	for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
		p := Render_Geom_Prop(pi)
		slot := &snap.keys[int(p)]
		slot.n, _ = kf_geom_fill_snapshot(clip, render_geom_name(p), slot.keys[:])
		if slot.n > 0 {
			snap.keyed = true
			switch p {
			case .Scale:
				snap.scale_keyed = true
			case .Opacity:
				snap.opacity_keyed = true
			case .Trans_X, .Trans_Y, .Crop_L, .Crop_R, .Crop_T, .Crop_B, .Zoom, .Pan_X, .Pan_Y, ._COUNT:
			}
		}
	}
}

// Geom_Sample is the evaluated value of every animated geometry property at ONE
// frame — the single shape both sinks consume, indexed by Render_Geom_Prop so a
// property added to the enum is present here without a second hand-written
// list to drift. Preview fills it live from the clip (geom_sample_clip); export
// fills it from the job's flat keyframe snapshot (geom_sample_flat). Both read
// the SAME resting base (clip_geom_resting, which both sides call) and
// the SAME evaluator per source.
//
// The claim this shape used to make but could not keep was that "preview shows
// the animation, export ignores it" cannot happen for one lane without the
// probe's per-lane equals check failing. That held only for the clip kind the
// probe was pointed at: the transport was hand-written per kind, so text and
// subtitle clips carried no keys across the thread hop and the check — which
// took a video pointer — never saw them. Render_Geom_Snap is what makes the
// claim true instead of hopeful: one carrier every source must carry, filled by
// one proc, read through one evaluator, and a parity check scoped to the
// carrier rather than to a clip kind.
Geom_Sample :: [int(Render_Geom_Prop._COUNT)]f32

// geom_sample_clip evaluates every animated geometry property of a LIVE clip at
// a timeline frame. UI-thread only (reads the clip's tracks); this is the one
// evaluator the preview uses, and the flat export sampler mirrors it key for
// key via kf_geom_fill_snapshot.
geom_sample_clip :: proc(clip: ^Clip, timeline_frame: i64) -> Geom_Sample {
	s: Geom_Sample
	for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
		p := Render_Geom_Prop(pi)
		s[pi], _ = kf_geom_sample_lane(clip, render_geom_name(p), timeline_frame, clip_geom_resting(clip, p))
	}
	return s
}

// geom_clear_crop zeroes the CROP lanes of a sample in place, and neutralizes
// zoom. A text clip has no source frame to crop (its raster is already sized to
// the ink), so its window must read as the whole frame even if the clip carries
// crop keys or a keyed zoom.
//
// Zoom is folded in here rather than left alone because it is the same
// statement: crop and zoom both describe a window in a source, so a clip with no
// source has neither. Pan is a pure offset of a window and needs no
// neutralization — with no window to offset, it is read by nothing.
geom_clear_crop :: proc(s: ^Geom_Sample) {
	for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
		switch Render_Geom_Prop(pi) {
		case .Crop_L, .Crop_R, .Crop_T, .Crop_B:
			s[pi] = 0
		case .Zoom:
			s[pi] = 1
		case .Trans_X, .Trans_Y, .Scale, .Opacity, .Pan_X, .Pan_Y, ._COUNT:
		}
	}
}

// geom_sample_resting returns a clip's UNKEYED geometry — the base every lane
// samples against outside its keys, and the base the export snapshots onto the
// job. One proc so the resting set is defined once, next to the evaluators that
// consume it.
geom_sample_resting :: proc(clip: ^Clip) -> Geom_Sample {
	s: Geom_Sample
	for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
		s[pi] = clip_geom_resting(clip, Render_Geom_Prop(pi))
	}
	return s
}

// geom_sample_flat evaluates a geometry snapshot copied flat onto the job (the
// cross-thread form) — the export's counterpart to geom_sample_clip. `base` is
// the clip's resting values for the keys that do not cover `off`; both sides
// therefore rest at the same value. Worker thread.
geom_sample_flat :: proc(base: Geom_Sample, geom: ^[int(Render_Geom_Prop._COUNT)]Render_Kf_Flat, off: i32) -> Geom_Sample {
	s: Geom_Sample
	for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
		s[pi], _ = kf_sample_keys(geom[pi].keys[:geom[pi].n], off, base[pi])
	}
	return s
}

Render_Video_Src :: struct {
	path:                 cstring, // owned copy, freed by the worker
	stream_index:         c.int,
	source_start_frame:   i64,
	// src_fps travels with the offsets so the worker conforms the clip's speed
	// without reading a live Clip; see clip_source_frame.
	src_fps:              f64,
	source_length_frames: i64,
	// is_still marks a single-frame image source; every timeline frame maps to
	// source_start_frame (see media_is_image / Clip.is_still).
	is_still:             bool,
	timeline_start_frame: i64,
	// geom is the clip's geometry and opacity as it crosses the thread boundary:
	// resting base, every lane's flattened key track, and the derived flags.
	// Written by render_geom_snap_fill and read only through geom_snap_eval, so
	// the animated and baked paths sample the same lanes from the same base.
	geom:                Render_Geom_Snap,
	source_w:             c.int,
	source_h:             c.int,
	// opacity is the alpha THIS FRAME composites with. Seeded from
	// geom.base[Opacity] at setup (the static path never changes it) and
	// rewritten every composite frame by render_eval_keyed_geom when the
	// opacity lane is keyed — the same way it rewrites rw/rh/ox/oy. It is
	// deliberately NOT where the resting value lives: the old field served as
	// both base and per-frame value, so a keyed clip's resting alpha was
	// overwritten with the previous frame's sample and any frame outside the
	// key range blended against the last keyed value instead of the resting
	// one (pinned by render_kf_probe case H).
	opacity:              f32,
	// stage_scale is the maximum scale this clip reaches, so a keyed clip's
	// stage is sized once for its whole animation. Worker-owned.
	stage_scale:         f32,
	kres_scratch:        []u8,
	// Compositing state (computed once at open).
	dec:                  Clip_Decoder,
	rw, rh:               c.int, // display (cropped box) rect size in output pixels
	ox, oy:               c.int, // rounded top-left offset on the canvas
	fw, fh:               c.int, // full (pre-crop) box size the frame decodes into
	// Pipeline (P5): the producer decode thread scales frame N into
	// blit_slots[N & 1] while the worker composites frame N-1 out of
	// blit_slots[(N-1) & 1], overlapped via the produced/consumed atomics
	// (render_dec_pipe). Buffer lifetime: job arena, both filled per frame.
	blit_slots:           [2]Render_Blit_Slot, // fw*fh*4 scaled frame each
}

// Render_Blit_Slot is one frame's worth of decode output. The producer writes
// the clip's window + the geometry the worker needs to place it, so the worker
// composite never reads the decoder (v.dec) — decoder structs are single-writer,
// owned by the producer thread alone.
Render_Blit_Slot :: struct {
	blit: []u8, // fw*fh*4 scaled window
	ok:   bool, // decode+scale succeeded this round; worker skips if false
}

// Render_Text_Src snapshots a .Text generator clip for the worker. It carries
// the title plus the transform math needed to place it at output resolution:
// box = text (source_w x source_h, in text px) * scale * (out_w / PREVIEW_W).
//
// Its geometry lives in the shared Render_Geom_Snap like every other visual
// source, so a keyed text clip exports ANIMATED — the same lanes, sampled by
// the same evaluator, from the same resting base as a video clip's. This struct
// used to carry `transform_x`/`transform_y`/`scale` as plain resting copies,
// which meant the animation stopped at the UI thread and the worker drew the
// text at one pose for the whole clip.
Render_Text_Src :: struct {
	name:                 string, // owned copy, freed by the worker
	timeline_start_frame: i64,
	source_length_frames: i64,
	geom:                 Render_Geom_Snap,
	source_w:             c.int, // text_w (tight ink width, text px)
	source_h:             c.int, // text_h (tight ink height, text px)

	// Which entry of the worker's text_jobs array rasterizes this clip. Text
	// shares one track-ordered list with video now (Render_Visual), so a text's
	// position in that list is not its job index; recording the raster job
	// explicitly keeps the two from being conflated.
	job_idx: int,
}

// Render_Visual is one entry of the track-ordered visual stack: either a
// snapshotted source or a text clip, in the order the user sees them. It stores
// BORROWING pointers, not copies: the decoder opens each source and fills its
// blit slots AFTER this list is built, so a copy taken during the walk would
// composite an empty slot forever. The pointees are owned by Render_Job.videos
// and .texts, which are fixed in size once the walk ends, and are freed there.
//
// It exists because video and text used to be snapshotted into two parallel
// arrays and composited in two SEPARATE passes, which meant export drew every
// text above every video no matter where the user put it -- the preview
// interleaves them by track position, so a text clip on a lower track previewed
// UNDER the video and exported OVER it. One list walked once removes the second
// ordering authority instead of trying to keep two of them in agreement.
//
// Subtitles are deliberately NOT in here. They are pinned above everything in
// both preview and export, because a burned-in subtitle hidden behind a video is
// unreadable; that decision lives with the subs pass, not with track order.
Render_Visual :: union {
	^Render_Video_Src,
	^Render_Text_Src,
}

// Render_Text_Font is the render worker's private text rasterization state. The
// render worker rasterizes text with its own font + scratch so it never races
// the UI thread's shared text_clip_state globals (the preview
// thread can be compositing a text slot while the worker renders). setup_scratch
// is the worker's own dynamic scratch for baked fonts (the shared fixed
// 8192-glyph buffers are too small once the font grows to 48*scale); sized per
// setup via text_scratch_size_for.
Render_Text_Font :: struct {
	font:       stb.fontinfo,
	init:       bool,
	setup_scratch: []u8,
}
render_text_font: Render_Text_Font

// Render_Text_Job is a text clip's rasterized ink, baked at the scale the clip
// was last drawn at. Baking scale into the raster (font = 48*scale) is what
// keeps the output crisp, and it means the raster is CACHED STATE rather than a
// sampled value — so an animated scale has to re-bake it, exactly as the
// preview re-bakes on its text_font_px change.
//
// No blit_scale: the box comes from the clip's BASE dims through the shared
// text_box_dims with the sampled scale (render_text_blit), so the ink carrying
// the scale and the box applying it cannot drift into a double-scaling.
Render_Text_Job :: struct {
	raster:         []u8,
	bw:             int, // raster row stride
	ox, oy, ow, oh: int, // tight ink rect in raster
	// font_px is the baked font size, i.e. the scale this raster's RESOLUTION
	// corresponds to. The per-frame gate compares the sampled scale's font
	// against it to decide whether a re-bake is owed.
	font_px: f32,
}

// setup_text_job rasterizes a text clip at `scale` (the multiplier baked into
// the baked font = 48*scale). source_w/source_h are the BASE tight dims (font
// 48, scale-independent).
//
// `rebake` says whether the existing raster may be kept: it is false only when
// the job is already baked at this exact font, so the common unkeyed case
// rasterizes once for the whole render. Returns with raster empty on failure.
//
// The caller owns the previous raster; this proc does not free it, because a
// re-bake happens with the old ink still needed for the frame in flight. See
// text_job_rescale.
setup_text_job :: proc(over: ^Render_Text_Job, t: Render_Text_Src, scale: f32, rebake: bool) {
	if !rebake && over.raster != nil {
		return
	}
	font_px := text_font_px_for(scale)
	if t.name == "" || t.source_w <= 0 || t.source_h <= 0 {
		over^ = {}
		return
	}
	bw, bh := text_buf_size_for(t.name, &render_text_font.font, &render_text_font.init, font_px)
	if bw <= 0 || bh <= 0 {
		over^ = {}
		return
	}
	buf := make([]u8, bw * bh * 4)
	scratch := text_buf_ensure(&render_text_font.setup_scratch, text_scratch_size_for(font_px))
	ox, oy, ow, oh := rasterize_title_into_buffer(
		t.name,
		buf,
		bw,
		bh,
		&render_text_font.font,
		&render_text_font.init,
		scratch,
		font_px,
	)
	if ow <= 0 || oh <= 0 {
		delete(buf)
		over^ = {}
		return
	}
	over.raster = buf
	over.bw = bw
	over.ox, over.oy, over.ow, over.oh = ox, oy, ow, oh
	over.font_px = font_px
}

// text_job_rescale re-bakes a text job when the clip's scale this frame no
// longer matches the resolution its raster was drawn at, and frees the stale
// raster. Returns true when it re-baked.
//
// This is the one place the animated path is NOT just a sampled value: scale is
// baked into the raster's resolution, so unlike transform (a placement the blit
// takes per frame) it cannot be applied by rescaling. The preview has the same
// constraint and solves it the same way, by re-rasterizing when the baked font
// changes (preview_state.odin's text_font_px gate) — so both sinks converge on
// the same ink for the same scale.
text_job_rescale :: proc(j: ^Render_Text_Job, t: Render_Text_Src, scale: f32) -> bool {
	if !text_font_needs_rebake(j.font_px, scale) {
		return false
	}
	// The old raster stays valid until the new one lands, and setup_text_job
	// overwrites the fields, so hold it and free after: an allocation-free
	// failure path would otherwise leak the previous bake.
	stale := j.raster
	setup_text_job(j, t, scale, true)
	if j.raster == nil {
		// Nothing usable came back. Restore the old bake rather than dropping
		// the clip's text for the rest of the render (setup cleared the fields).
		j.raster = stale
		return false
	}
	delete(stale)
	return true
}

// snapshot_text_src builds the worker snapshot for a .Text generator clip.
//
// Like its video counterpart it fills the shared Render_Geom_Snap rather than
// copying the clip's resting fields, so a keyed text clip reaches the worker
// with its animation intact. `job_idx` is the caller's index into the job's
// text array, which is a different ordering from the composite stack.
snapshot_text_src :: proc(clip: ^Clip, job_idx: int) -> Render_Text_Src {
	src := Render_Text_Src {
		// Worker-owned: this crosses a thread hop, and the pool is freed at
		// teardown without draining queued jobs, so it keeps its own copy.
		name = strings.clone(clip_name(clip)),
		timeline_start_frame = clip.timeline_start_frame,
		source_length_frames = clip.source_length_frames,
		source_w = clip.source_w,
		source_h = clip.source_h,
		job_idx = job_idx,
	}
	render_geom_snap_fill(&src.geom, clip)
	return src
}

// Render_Sink is which of the render job's source arrays a clip is snapshotted
// into. A closed set of three, so it is an enum rather than a hand-passed int.
Render_Sink :: enum {
	Video,
	Text,
	Sub,
}

// render_clip_sink classifies a clip for the render walk: which job array holds
// its snapshot, or ok=false when the clip has no renderable content.
//
// This is the ONE authority for that mapping. render_start walks with it, and so
// does the parity probe when it lines the job's arrays back up with the live
// clips — and that pairing is exactly why it cannot be stated twice. A probe
// that re-derived "text clips go in .texts" by walking the kinds itself would
// agree with render_start only by coincidence, and a divergence there compares
// the wrong clip against the wrong snapshot: a parity check that silently stops
// checking anything.
render_clip_sink :: proc(clip: ^Clip) -> (sink: Render_Sink, ok: bool) {
	switch clip.kind {
	case .Video, .Image:
		return .Video, true
	case .Text:
		// A .Text clip is either a burned-in title or a subtitle generator; the
		// generator decides which array, and .Subtitles kind is never placed on
		// the timeline (its assets drop in as .Text).
		if clip.generator == .Subtitles {
			return .Sub, true
		}
		return .Text, true
	case .Audio, .Other, .Empty, .Subtitles:
		// .Audio is snapshotted from the committed geometry slab after the walk,
		// not from the live clips: the same source the playback producer
		// consumes, so playback and export evaluate one gain snapshot. .Other and
		// .Empty carry no renderable content.
		return .Video, false
	}
	return .Video, false
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
	// src_fps travels with the offsets so the worker conforms the clip's speed
	// without reading a live Clip; see clip_source_frame.
	src_fps:              f64,
	source_length_frames: i64,
	// geom is the same shared carrier a video or text clip carries, so a keyed
	// subtitle clip exports animated too. This struct previously copied the
	// three resting transform fields directly and computed a fixed box center
	// from them at setup, which froze a subtitle's keyed motion at one pose.
	geom:                 Render_Geom_Snap,
	source_w:             c.int, // current cue's base ink dims (font 48)
	source_h:             c.int,
}

// sub_box_center is the point a subtitle's cue text stays centered on, in output
// pixels. transform/scale come in already SAMPLED, so the same proc serves an
// unkeyed clip (resting values) and a keyed one (per-frame values) without either
// having its own center math.
//
// Subtitles are NOT on the center pivot and deliberately so: a cue's box grows
// upward around a stable baseline (see update_subtitle_slot), so Trans_X/Y here is
// the cue's top-left and this converts it to the center the blit wants. Text and
// media moved to the center pivot; this path did not, because a center-pivoted
// subtitle would float as its line count changes. Renaming it to say top-left
// would be clearer still -- the name is the only thing here that lies.
//
// A clip with no measured source dims has no box to center, so it falls back to
// the canvas center -- the long-standing behavior for a subtitle whose dims have
// not been measured yet.
sub_box_center :: proc(
	geom: Geom_Sample,
	source_w, source_h: c.int,
	factor: f32,
	canvas_w, canvas_h: c.int,
) -> (x, y: f32) {
	if source_w <= 0 || source_h <= 0 {
		return f32(canvas_w) / 2, f32(canvas_h) / 2
	}
	scale := geom[int(Render_Geom_Prop.Scale)]
	return geom[int(Render_Geom_Prop.Trans_X)] + f32(source_w) * scale * factor / 2,
	       geom[int(Render_Geom_Prop.Trans_Y)] + f32(source_h) * scale * factor / 2
}

// snapshot_sub_src builds the worker snapshot for a subtitle-generator clip.
// One proc for both clip kinds that produce one (`.Text`/`.Subtitles` with a
// .Subtitles generator), so the two cannot drift on what crosses the boundary.
snapshot_sub_src :: proc(clip: ^Clip, fps: f32) -> Render_Sub_Src {
	src := Render_Sub_Src {
		srt_id = clip.srt_id,
		fps = fps,
		timeline_start_frame = clip.timeline_start_frame,
		source_start_frame = clip.source_start_frame,
		source_length_frames = clip.source_length_frames,
		source_w = clip.source_w,
		source_h = clip.source_h,
	}
	render_geom_snap_fill(&src.geom, clip)
	return src
}

// Render_Sub_Cue is the worker's raster cache for one subtitle clip's ACTIVE
// cue (keyspace is per clip). Cues play forward in population order during a
// render, so a single slot per clip has a perfect hit rate between boundaries.
// font_px records the resolution it was baked at, so an animated scale re-bakes
// it rather than rescaling the blit.
Render_Sub_Cue :: struct {
	cue_idx:        int,
	raster:         []u8, // baked-font (48*scale) RGBA raster
	bw:             int, // raster row stride
	bh:             int, // raster height
	ox, oy, ow, oh: int, // tight ink rect in the raster
	font_px:        f32,
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
	font_px := text_font_px_for(scale)
	bw, bh := text_buf_size_for_lines(lines, &render_text_font.font, &render_text_font.init, font_px)
	if bw <= 0 || bh <= 0 {
		return
	}
	buf := make([]u8, bw * bh * 4)
	scratch := text_buf_ensure(&render_text_font.setup_scratch, text_scratch_size_for(font_px))
	ox, oy, ow, oh := rasterize_lines_into_buffer(
		lines,
		buf,
		bw,
		bh,
		&render_text_font.font,
		&render_text_font.init,
		scratch,
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
	// source_start_rate pins the rate source_start_frame is counted against,
	// so the export reads the same part of the file playback does no matter
	// what the project rate is now (see audio_source_start_sec).
	source_start_rate:    f64,
	source_length_frames: i64,
	// gain is the render's FROZEN copy of the clip's committed gain snapshot,
	// taken at render start from the same geometry slab the playback producer
	// reads. Both mixers evaluate this shape through audio_gain_linear, so the
	// export cannot drift from playback (it previously applied no gain at all,
	// so a rendered file ignored the slider and its automation entirely).
	gain:                 Audio_Gain_Snapshot,
	// muted is true when this source contributed nothing to the previous mixed
	// block, or has not contributed yet. It is what makes a resume-after-shortfall
	// fade in rather than appear at full amplitude: the output has a step there
	// whether or not the block boundary is a clip boundary, and without this the
	// only thing that ramps is a clip edge.
	muted:                bool,
	dec:                  Audio_Clip_Decoder, // 48 kHz stereo S16
	fifo:                 Audio_Ring, // converted stereo f32, content-relative
	first48:              i64, // content 48 kHz frame of fifo's head
	have48:               i64, // content frames produced so far (next un-produced)
}

// AUDIO_MIX_BLOCK is the mixer's fixed block, in sample-frames (512 = 10.67ms at
// 48 kHz, and the block size REAPER, Resolve and JUCE hosts all expose as a
// setting).
//
// The point is that the mixer's unit of work is NOT the video grid's. A frame is
// 1601/1602 samples at 29.97 and 400 at 120fps, so a frame-sized mixer cannot
// precompute anything and cannot be fed a fixed-size buffer. Mixing in blocks
// and handing the result to a ring lets the consumer take whatever range its
// frame covers -- including a range that straddles two blocks, which is the
// normal case rather than an edge case.
AUDIO_MIX_BLOCK :: 512

// RENDER_MIX_CUSHION_FRAMES is how far ahead of the consumer the mix producer
// runs, in video frames -- the render's answer to the question playback already
// answers with AUDIO_CUSHION_SEC. The export had none: the composite thread mixed
// whatever the current frame needed, one frame at a time, so a decode that ran
// late dropped that source for the whole frame and the next one started from
// silence. 12 frames is 0.5s at 24fps and 0.1s at 120fps, both far more than
// mixing one AUDIO_MIX_BLOCK of a few sources costs.
RENDER_MIX_CUSHION_FRAMES :: 12

// render_mix_bus_frames is the bus capacity in sample-frames, which IS the
// cushion: the producer keeps the bus full to capacity and stalls when it is
// full, so the depth of the cushion is the depth of the buffer and there is no
// second number to keep in agreement with it. One extra frame so a frame still
// fits when the bus is sitting at exactly the cushion.
render_mix_bus_frames :: proc() -> int {
	return (RENDER_MIX_CUSHION_FRAMES + 1) * MAX_AUDIO_FRAME_SAMPLES
}

// Render_Mix_Bus is the handover from the mix producer to the composite worker:
// single-producer single-consumer, no mutex, no lock, no condvar.
//
// The position lives in exactly one place per side. `write` belongs to the
// producer and `read` to the consumer; each is published with a release store
// and loaded with an acquire load, and the depth is their difference. That is the
// whole point: the previous shape kept an Audio_Ring (head/count) AND a
// Sample_Pos pos/end beside it -- two representations of one position, which is
// the duplicated-state-that-drifts class this repo has paid for seven times, and
// the S2 probe could only avoid testing content because hand-seeding that ring
// meant hand-rolling the fill beside it.
//
// The counters count sample-frames from the job's first frame, so they index the
// buffer modulo its capacity and never need wrapping. A count's bus POSITION is
// start + count, and the consumer converts once, when it computes a frame's
// range.
Render_Mix_Bus :: struct {
	buf:    []f32, // interleaved stereo, frames*2 samples
	frames: int,   // capacity in sample-frames
	write:  i64,   // atomic: sample-frames published by the producer
	read:   i64,   // atomic: sample-frames consumed by the worker
}

render_mix_bus_init :: proc(b: ^Render_Mix_Bus, frames: int) {
	b.buf = make([]f32, frames * 2)
	b.frames = frames
	b.write = 0
	b.read = 0
}

render_mix_bus_destroy :: proc(b: ^Render_Mix_Bus) {
	delete(b.buf)
	b.buf = nil
	b.frames = 0
}

// render_mix_bus_room is producer-side only: only the producer can stall, and
// only the consumer frees room, so this needs no lock even though `read` moves
// underneath it.
render_mix_bus_room :: proc(b: ^Render_Mix_Bus) -> int {
	return b.frames - int(b.write - sync.atomic_load(&b.read))
}

// render_mix_bus_publish copies one mixed block onto the bus and releases it.
// Producer only. Split across the wrap rather than assuming the block is
// contiguous, because a block CAN straddle the end of the buffer.
render_mix_bus_publish :: proc(b: ^Render_Mix_Bus, pcm: []f32, n: int) {
	w := b.write
	off := int(w % i64(b.frames))
	head := min(n, b.frames - off)
	copy(b.buf[off*2:], pcm[:head*2])
	if head < n {
		copy(b.buf, pcm[head*2:n*2])
	}
	// Release: the block above is visible to the consumer's acquire load.
	sync.atomic_store(&b.write, w + i64(n))
}

// render_mix_bus_consume copies the n sample-frames at count `from` and advances
// the consumer. `from` must be the consumer's own position: it walks the bus in
// order and never skips, so a mismatch is a bug in the caller, not a recoverable
// condition -- hence the assert rather than a hole. Returns false only when the
// producer has not published that far yet, which is the one legitimate wait.
render_mix_bus_consume :: proc(b: ^Render_Mix_Bus, from: i64, n: int, out: []f32) -> bool {
	r := b.read
	w := sync.atomic_load(&b.write)
	assert(r == from, "mix bus consumed out of order")
	if w - r < i64(n) {
		return false
	}
	off := int(r % i64(b.frames))
	head := min(n, b.frames - off)
	copy(out[:head*2], b.buf[off*2:(off+head)*2])
	if head < n {
		copy(out[head*2:n*2], b.buf[:(n-head)*2])
	}
	sync.atomic_store(&b.read, r + i64(n))
	return true
}

// Render_Mix is the export's mix bus and the producer's state. Only the mix
// producer touches bus, holes or blocks_mixed after setup: the composite worker
// reads the bus and nothing else, and owns the per-source audio DECODERS not at
// all. Decoders are single-writer, so this split is also what makes it safe for
// the producer to run ahead -- it is the only thread that can decode.
Render_Mix :: struct {
	bus:         Render_Mix_Bus,
	start:       Sample_Pos, // bus position of sample-frame 0
	num, den:    i64,
	// holes counts blocks a source could not fill: a decode that did not keep
	// pace with the block it was asked for. Producer-written, read after the
	// join. It is a SAMPLE-domain count -- the frame-domain counter that shipped
	// alongside complete distortion (`1a38d78`) could not see this class of
	// defect at all.
	holes:        i64,
	blocks_mixed: i64,
}

// render_mix_step mixes as many whole blocks as the bus has room for, up to the
// job's audio span, and returns false once the span is complete.
//
// It does NOT wait. Full bus and finished job are different answers, and only
// the caller knows which one to give: the thread loop turns "full" into a yield,
// and a probe that drives the producer and the consumer alternately turns it into
// "let the consumer have a frame". Collapsing the two is what produced the first
// version of this, where the producer stalled on a full bus inside a step and a
// caller that had not yet consumed anything could never make progress -- the
// probe deadlocked against code that works in the render, because running the
// producer to completion and then consuming is not a sequence the render performs.
render_mix_step :: proc(m: ^Render_Mix, job_end: Sample_Pos) -> bool {
	block: [AUDIO_MIX_BLOCK * 2]f32
	for {
		cur := m.start + Sample_Pos(sync.atomic_load(&m.bus.write))
		if cur >= job_end {
			return false
		}
		room := render_mix_bus_room(&m.bus)
		if room < AUDIO_MIX_BLOCK {
			return true
		}
		n := min(AUDIO_MIX_BLOCK, room, int(job_end - cur))
		render_mix_block(m, block[:], cur, n)
		render_mix_bus_publish(&m.bus, block[:], n)
	}
}

// render_mix_proc is the mix producer thread. It mixes the job's whole audio span
// in fixed AUDIO_MIX_BLOCK blocks, keeping the bus full to its capacity, and exits
// once it has published the last frame -- it never waits on the consumer, so the
// worker's wait for a frame is always bounded by work the producer has already
// been given.
//
// Mixed into a fixed stack block, never an allocation: this is a hot loop and a
// surprise allocation here is the same defect as one per frame in the mixer it
// replaces. The decode path allocates only inside FFmpeg.
render_mix_proc :: proc(m: ^Render_Mix) {
	block: [AUDIO_MIX_BLOCK * 2]f32
	job_end := sample_pos_from_frames(
		render_job.start + render_job.nframes,
		m.num,
		m.den,
	)
	for render_mix_step(m, job_end) {
		// The bus is full: the consumer is the slow one now, which is the whole
		// point of the cushion. Yield rather than sleep -- the wait is one frame of
		// composite work, and a futex round trip here would cost more than the
		// mixing it is waiting for.
		if sync.atomic_load(&render_pipe.mix_stop) {
			return
		}
		thread.yield()
	}
}

render_mix_thread :: proc(t: ^thread.Thread) {
	render_mix_proc(&render_mix)
}

render_mix_block :: proc(m: ^Render_Mix, out: []f32, at: Sample_Pos, n: int) {
	for i in 0 ..< n * 2 {
		out[i] = 0
	}
	m.blocks_mixed += 1
	for &a in render_job.audios {
		if !a.dec.opened {
			continue
		}
		clip_t0 := sample_pos_from_frames(a.timeline_start_frame, m.num, m.den)
		clip_t1 := sample_pos_from_frames(a.timeline_start_frame + a.source_length_frames, m.num, m.den)
		if at + Sample_Pos(n) <= clip_t0 || at >= clip_t1 {
			continue // outside this clip's timeline span
		}
		// Clip the block to the clip's own span: a block that straddles a clip
		// boundary contributes only the part inside it, which is what a
		// per-frame mixer got for free by never straddling anything.
		blk_lo := max(at, clip_t0)
		blk_hi := min(at + Sample_Pos(n), clip_t1)
		content := (blk_lo - clip_t0) +
			audio_source_start_sample(a.source_start_frame, a.source_start_rate)
		want := blk_hi - blk_lo
		render_audio_pull(&a, i64(content + want))
		if a.first48 > i64(content) || a.have48 < i64(content + want) {
			// The fifo cannot cover this block. Silence for the span, counted --
			// and NOT a silent `continue`, because the rest of the block belongs
			// to this source and dropping it would punch a hole shaped like the
			// source list rather than like the shortfall. The source is marked
			// muted so that its return fades in instead of arriving at full level.
			m.holes += 1
			a.muted = true
			continue
		}
		base := int(content - a.first48)
		// Gain automation is keyed in timeline FRAMES, so this is the one thing
		// that still needs a frame index -- resolved once per block, not per
		// sample, and exactly (frame_at_sample).
		rel := i32(frame_at_sample(blk_lo - clip_t0, m.num, m.den) - a.timeline_start_frame)
		g := audio_gain_linear(&a.gain, rel)
		// Where this contribution FADES. Two edges, and they are not the same
		// thing: the clip's own span ends are the edits a listener hears, and a
		// resume after a shortfall is an edge too even though no clip changed.
		// Taking the earlier of the two as the start edge means a block that both
		// resumes and opens a clip gets ONE fade, not two multiplied together.
		fade_from := clip_t0
		if a.muted {
			fade_from = blk_lo
		}
		fade_in := audio_declick_fade_in(blk_lo - fade_from, int(want))
		fade_out := audio_declick_fade_out(clip_t1 - blk_hi, int(want))
		for s in 0 ..< int(want) {
			l, r := ring_at(&a.fifo, base + s)
			off := int(blk_lo - at) * 2
			f := audio_declick_gain(g, s, int(want), fade_in, fade_out)
			out[off + s * 2 + 0] += l * f
			out[off + s * 2 + 1] += r * f
		}
		a.muted = false
		// Drop what this block consumed so the fifo stays forward-only and a long
		// render does not accumulate whole clips.
		drop := base + int(want)
		if drop > 0 {
			a.first48 += i64(drop)
			ring_drop(&a.fifo, drop)
		}
	}
}

// render_mix_init points the bus at the job's rate and its first sample.
// render_mix_depth is how many sample-frames the bus holds right now. Either
// side may call it: depth is the difference of two published counters, so it is a
// reading, not a mutation.
render_mix_depth :: proc(m: ^Render_Mix) -> int {
	return int(sync.atomic_load(&m.bus.write) - sync.atomic_load(&m.bus.read))
}

render_mix_init :: proc(m: ^Render_Mix, num, den: c.int, start: Sample_Pos) {
	m.start = start
	m.num = i64(num)
	m.den = i64(den)
	m.holes = 0
	m.blocks_mixed = 0
	render_mix_bus_init(&m.bus, render_mix_bus_frames())
}

// render_mix_serve_frame hands the consumer the samples for one video frame.
//
// The bus is already filled to the cushion by the producer, so this is a wait
// that normally does not wait: the frame it needs was mixed long before the
// composite got here. The wait is bounded because the producer publishes the
// whole job's span without waiting on the consumer -- so this can only be
// unbounded if the producer was stopped or failed, which is what mix_stop and
// mix_fail are for. Returns the sample-frames written to `out`, or 0 when the
// frame could not be had, which the caller must treat as a hole rather than as
// stale audio.
render_mix_serve_frame :: proc(
	m: ^Render_Mix,
	frame: i64,
	num, den: i64,
	out: []f32,
) -> int {
	b0 := sample_pos_from_frames(frame, num, den)
	b1 := sample_pos_from_frames(frame + 1, num, den)
	n := int(min(b1 - b0, Sample_Pos(MAX_AUDIO_FRAME_SAMPLES)))
	if n <= 0 {
		return 0
	}
	from := i64(b0 - m.start)
	for !render_mix_bus_consume(&m.bus, from, n, out) {
		if sync.atomic_load(&render_pipe.mix_stop) {
			return 0
		}
		thread.yield()
	}
	return n
}

// render_audio_src_from_chip copies one committed geometry chip into the job's
// Render_Audio_Src: identity fields plus the chip's gain snapshot. The export
// reads the SAME committed source playback does (audio_geometry_commit's slab),
// rather than re-deriving gain from the live clip, so a fact the user edits has
// exactly one committed home. Clones path; caller frees the src.
render_audio_src_from_chip :: proc(slot: ^Audio_Geom_Slot, chip: ^Audio_Geom_Chip) -> Render_Audio_Src {
	return Render_Audio_Src {
		path = strings.clone_to_cstring(audio_chip_path(slot, chip)),
		stream_index = chip.stream_index,
		timeline_start_frame = chip.timeline_start,
		source_start_frame = chip.source_start,
		source_start_rate = chip.source_rate,
		source_length_frames = chip.source_len,
		gain = chip.gain,
	}
}

// Render_Job is the timeline snapshot taken on the main thread when a render
// starts, so the worker never touches live timeline state: one slab per source
// kind plus the output geometry/range it renders.
Render_Job :: struct {
	// visuals is the composite ORDER only; videos and texts below own the
	// payloads it borrows.
	visuals:  []Render_Visual,
	videos:   []Render_Video_Src,
	audios:   []Render_Audio_Src,
	texts:    []Render_Text_Src, // owns the cloned clip names
	subs:     []Render_Sub_Src,
	out_path: cstring,
	width:    c.int,
	height:   c.int,
	start:    i64,
	end:      i64, // inclusive
	nframes:  i64,
	// fps is the PROJECT rate the frame grid is defined on (project_fps), and
	// fps_num/fps_den its exact container form. Snapshotted here, on the UI
	// thread, for the same reason the clip arrays are: the worker must not read
	// the project globals to decide what a frame index means.
	//
	// The worker used to re-derive this from the first video source's own rate,
	// which is a DIFFERENT question -- "what rate does this file have" -- and the
	// two answers coincided only when the first source was the grid-defining
	// one. A still image is the case that broke it: an image demuxer reports an
	// arbitrary avg_frame_rate, so a project whose first video clip was a still
	// exported at that image's rate instead of the timeline's, retiming every
	// keyed value, position and clip boundary onto a different output frame.
	fps:      f64,
	fps_num:  c.int,
	fps_den:  c.int,
}
render_job: Render_Job

// render_display_rect returns the clip's visible rect in project (output)
// pixels, honoring source aspect (letterbox) and crop insets.
render_display_rect :: proc(src: ^Render_Video_Src, PW, PH: c.int) -> (l, t, r, b: f32) {
	cw, ch := full_box_dims(
		src.source_w,
		src.source_h,
		src.geom.base[int(Render_Geom_Prop.Scale)],
		f32(PW),
		f32(PH),
	)
	// The shared edges, not a hand-inlined copy of them. Step B moved
	// full_box_dims out but left these four lines behind, so this function was
	// the one place in the export still deriving crop edges on its own -- and
	// the preview has been reading the shared version the whole time, which is
	// precisely the drift B existed to stop. render_kf_geom_rect below was
	// already migrated; this is the static path.
	// The BOX insets — crop only. The window that selects source pixels is the
	// content one (crop_src_rect, below); this is the box, and zoom and pan have no
	// business moving it.
	l0, r0, t0, b0 := geom_box_insets(src.geom.base)
	return cropped_box_edges(
		src.geom.base[int(Render_Geom_Prop.Trans_X)],
		src.geom.base[int(Render_Geom_Prop.Trans_Y)],
		cw,
		ch,
		l0,
		r0,
		t0,
		b0,
	)
}

// render_static_src_geom sizes one static clip's decode buffers (fw/fh, the
// display rect rw/rh/ox/oy) and sets its decoder crop. A fully off-canvas clip
// comes back with fw == 0 and nothing to decode. Pure pixel math on the clip's
// own snapshot -- pinned by VYPER_RENDER_KF_PROBE.
render_static_src_geom :: proc(v: ^Render_Video_Src, canvas_w, canvas_h: c.int) {
	l, t, r, b := render_display_rect(v, canvas_w, canvas_h)
	// Fully off-canvas: never drawn, so no decode at all.
	if c.int(r) <= 0 || c.int(l) >= canvas_w ||
	   c.int(b) <= 0 || c.int(t) >= canvas_h {
		v.fw = 0
		v.fh = 0
		v.rw = 0
		v.rh = 0
	}
	// A clip's box is `source x scale`, which for a scaled-up clip is far
	// larger than anything it draws -- at 27x on a 1920x1082 source it is
	// 53332x30055, and every buffer sized from that box is 6.4 GB to draw the
	// 1920x1082 pixels actually on screen (FFmpeg refuses the size outright,
	// which is how this reached a failed export).
	//
	// So the buffer is the region the clip can actually draw: the crop window
	// (the display rect) clipped to the canvas. The crop insets are already
	// resolved into the display rect by cropped_box_edges, and render_blit
	// copies the buffer 1:1 onto the canvas, so the source region decoded and
	// its mapping are the same as a full box would give -- the only thing
	// gone is the part that was never drawn. There is no threshold and no
	// second path: a clip whose box happens to fit the canvas gets the same
	// numbers it always did, because the window IS the box then.
	win_left := max(l, 0.0)
	win_top := max(t, 0.0)
	win_right := min(r, f32(canvas_w))
	win_bottom := min(b, f32(canvas_h))
	v.ox = c.int(win_left + 0.5)
	v.oy = c.int(win_top + 0.5)
	// Extent from the rounded window edges, then trimmed to the canvas:
	// rounding can push it a pixel past the edge, and a column that is never
	// drawn is not worth decoding or allocating.
	v.rw = max(1, min(px_extent(win_right - win_left), canvas_w - v.ox))
	v.rh = max(1, min(px_extent(win_bottom - win_top), canvas_h - v.oy))
	v.fw = v.rw
	v.fh = v.rh

	// WHICH SOURCE PIXELS the decoder fetches is a CONTENT decision, so it reads
	// the content window -- crop, zoom and pan -- and not the box edges above.
	// The buffer's size and placement stay governed by the BOX (that part is
	// placement, which zoom and pan must not touch), so the content window's
	// pixels are simply scaled to fill it: a 2x zoom fetches half the source and
	// fills the box with it, a pan fetches a different half. That is the whole
	// effect of both properties on the static path.
	//
	// These are SOURCE fractions, which is why they no longer come from the
	// canvas rect the way crop's did: the old form re-derived the window from where
	// the box happened to land, which cannot express a pan at all.
	//
	// crop_dst is 0 because the allocated box IS where the content lands: the
	// decoded region starts at its own origin. crop_full is the window too, so
	// there is no full-box buffer left to be the uncropped fallback.
	wl, wr, wt, wb := geom_content_insets(v.geom.base)
	v.dec.crop_fx0 = wl
	v.dec.crop_fy0 = wt
	v.dec.crop_fw = 1 - wl - wr
	v.dec.crop_fh = 1 - wt - wb
	v.dec.crop_dst_x = 0
	v.dec.crop_dst_y = 0
	v.dec.crop_dst_w = v.fw
	v.dec.crop_dst_h = v.fh
	v.dec.crop_full_w = v.fw
	v.dec.crop_full_h = v.fh
}

// render_kf_geom_rect evaluates a keyed clip's animation at clip offset `off`
// and derives the display rect plus the stage sub-rect. Pure pixel math —
// pinned by VYPER_RENDER_KF_PROBE. stage_w/h is the max-scale decode stage
// (the whole frame); the animated box is a centered fraction of it (both are
// uniform resamples of the same source, and the box width is linear in
// `scale`), and crop insets carve fractions of that. With a fixed scale the
// src sub-rect pixels equal the display pixels — a lossless region copy; with
// animated scale the same sub-rect feeds one sws resample per frame.
render_kf_geom_rect :: proc(
	geom: ^[int(Render_Geom_Prop._COUNT)]Render_Kf_Flat,
	off: i32,
	base: Geom_Sample,
	draw_w, draw_h: c.int,
	source_w, source_h, stage_w, stage_h: c.int,
) -> (
	tx, ty, s, cl, cr, ct, cb, opacity: f32,
	ox, oy, rw, rh, srcx, srcy, srcw, srch: c.int,
) {
	// Sampling every lane through the shared evaluator, so the export's per-frame
	// property values come from the same loop the preview's geom_sample_clip
	// uses — no hand-listed property that can fall out of sync with the enum.
	// Opacity rides the same pass (not a separate one), so the per-frame alpha
	// is resolved in exactly one place alongside the rect it composites into.
	// Returning the values (rather than writing through pointers) keeps this
	// proc free of side effects on the job.
	sampled := geom_sample_flat(base, geom, off)
	tx = sampled[int(Render_Geom_Prop.Trans_X)]
	ty = sampled[int(Render_Geom_Prop.Trans_Y)]
	s = sampled[int(Render_Geom_Prop.Scale)]
	// The BOX insets — crop only. See geom_box_insets: cropped_box_edges reads an
	// inset as a box trim, so handing it the content window would move a panned or
	// offset-crop clip on the keyed path alone.
	cl, cr, ct, cb = geom_box_insets(sampled)
	opacity = sampled[int(Render_Geom_Prop.Opacity)]
	cw, ch := full_box_dims(source_w, source_h, s, f32(draw_w), f32(draw_h))
	// The shared geometry (project_geom.odin), so a crop lands identically in
	// the export and in the preview.
	l, t, r, b := cropped_box_edges(tx, ty, cw, ch, cl, cr, ct, cb)
	ox = c.int(math.round(l))
	oy = c.int(math.round(t))
	rw = px_extent(r - l)
	rh = px_extent(b - t)
	// Which source pixels the crop selects in the STAGED texture (the shared
	// geometry, so this and the CPU sws path below pick the same pixels).
	// The CONTENT window for the source rect, which is the other half of the
	// split: this is where zoom and pan belong. It is computed HERE rather than
	// reusing cl..cb because those are the box insets -- feeding them to
	// crop_src_rect would select the crop window's pixels and silently drop a
	// zoom or a pan on the keyed path only, which is the keyed/static split that
	// has bitten twice (TODO.md Active 24).
	wl, wr2, wt, wb := geom_content_insets(sampled)
	csr := crop_src_rect(int(stage_w), int(stage_h), wl, wr2, wt, wb)
	srcx = c.int(csr.x)
	srcy = c.int(csr.y)
	srcw = c.int(csr.w)
	srch = c.int(csr.h)
	// Never copy past the stage bounds.
	rw = min(rw, stage_w - srcx)
	rh = min(rh, stage_h - srcy)
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
	// VYPER_YUV="1" A/B gate: when set, the RGBA->encoder-input conversion
	// runs through our hand-written SIMD kernels (vendor/yuv, the in-repo
	// replacement for the old libyuv dependency; ~4-5x faster than swscale)
	// instead of swscale. The scratch buffer below is the intermediate NV12
	// plane pair for the planar-YUV420P (libx264) path only — the NV12 path
	// (hardware encoders) writes straight into yuv_data.
	use_fast_yuv:          bool,
	yuv_scratch:       [4][^]u8,
	yuv_scratch_ls:    [4]c.int,
	yuv_scratch_avail: bool,
	audio_frame:     ^avutil.Frame,
	audio_plane:     bool,
	vpkt:            ^avcodec.Packet,
	apkt:            ^avcodec.Packet,
	// Encoder identity, resolved at open: the codec name actually encoding and
	// the pixel format the RGBA canvas is converted into before send. Hardware
	// encoders take NV12 in system memory; hw-upload encoders (VAAPI) get an
	// extra sw->hw transfer into an AVHWFramesContext-backed surface.
	enc_name:        [64]u8,
	enc_name_len:    int,
	enc_sw_pix_fmt:  avutil.PixelFormat,
	enc_hw_upload:   bool,
	enc_hw_device:   ^avutil.BufferRef,
	enc_hw_frames:   ^avutil.BufferRef,
	// Pending audio holds the largest push (MAX_AUDIO_FRAME_SAMPLES*2 stereo
	// samples) plus the sub-AAC residue a flush leaves behind; a 4096-cap
	// alone overflowed whenever residue + chunk crossed it (bounds trap at
	// every 30 fps render).
	audio_pending:   [MAX_AUDIO_FRAME_SAMPLES * 2 + AAC_FRAME_SIZE * 2]f32,
	audio_pending_n: int,
	audio_sent:      i64, // total 48k samples handed to the encoder (pts basis)
	// audio_real counts only the samples the MIX produced, so it excludes the
	// silence the flush pads the tail with. The difference is what the audio track
	// claims as its duration, and it is not a cosmetic number: FFmpeg derives a
	// container's duration from the LONGEST stream, so without this the padded
	// tail makes the file claim more audio than it has and longer than its own
	// video. Counting only the sent samples is what makes the container report the
	// frame grid.
	audio_real:      i64,
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
	if e.enc_hw_device != nil {
		avutil.buffer_unref(&e.enc_hw_device)
	}
	if e.enc_hw_frames != nil {
		avutil.buffer_unref(&e.enc_hw_frames)
	}
	if e.yuv_avail {
		avutil.freep(&e.yuv_data[0])
	}
	if e.yuv_scratch_avail {
		avutil.freep(&e.yuv_scratch[0])
	}
	if e.fmt_ctx != nil {
		// Close the AVIOContext BEFORE freeing the container: avio_closep
		// flushes its buffer and is the only thing that does, and
		// avformat_free_context does not do it for a context avio_open2
		// created (that is the AVFMT_FLAG_CUSTOM_IO case, which this is not).
		// Skipping it loses the tail of the file AND leaks the AVIOContext.
		if e.fmt_ctx.pb != nil {
			avfmt.closep(&e.fmt_ctx.pb)
		}
		// Frees the container and every stream in it, which is what owns
		// e.vstream / e.astream -- freeing those separately would double-free.
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
		// Clamp the audio packet carrying flush padding to the real sample count.
		//
		// This has to be done HERE, on the packet, and not on AVStream.duration
		// afterwards: the mp4 muxer ACCUMULATES packet durations into the track
		// duration and then overwrites AVStream.duration with the result. Setting it
		// afterwards writes to a field the muxer has already recomputed; setting it
		// beforehand does nothing, because packets overwrite it.
		//
		// It matters because a container's duration comes from its LONGEST stream.
		// With every packet claiming a whole 1024-sample AAC frame, the padded tail
		// claimed audio that is not there -- ~/sallyface.vyproj reported 29.781333s
		// of audio against 29.766667s of video, so the file outlasted its own
		// picture by exactly the padding. Before the padding existed the same
		// mismatch pointed the other way and DROPPED 320 real samples, which is
		// worse. This makes the duration exact in both directions.
		if stream == e.astream && e.audio_real > 0 {
			pts_samples := avutil.rescale_q(pkt.pts, stream.time_base, {num = 1, den = 48000})
			// The packet that CONTAINS audio_real, not the one after it: the
			// padding sits inside the last encoded frame, so its PTS is still below
			// the real sample count. Testing pts >= audio_real therefore never fires,
			// which is the version that looked right and clamped nothing.
			if pts_samples + AAC_FRAME_SIZE > e.audio_real {
				pkt.duration = avutil.rescale_q(
					e.audio_real - pts_samples,
					{num = 1, den = 48000},
					stream.time_base,
				)
			}
		}
		if ret := avfmt.interleaved_write_frame(e.fmt_ctx, pkt); ret < 0 {
			fmt.println("interleaved_write_frame:", ff_err_str(ret))
			avcodec.packet_unref(pkt)
			return false
		}
		avcodec.packet_unref(pkt)
	}
	return true
}

// HwFramesContext mirrors the public AVHWFramesContext layout
// (libavutil/hwcontext.h) up through height — the binding keeps the type
// opaque, but the encoder probe must fill format/sw_format/dimensions before
// av_hwframe_ctx_init. Only initial_pool_size.format/.sw_format/width/height
// are written; the rest of the head exists so the written fields land at the
// true offsets (av_class, device_ref, device_ctx, hwctx, free, user_opaque
// precede pool), and the tail pins the ABI.
HwFramesContext :: struct {
	av_class:          rawptr, // const AVClass*
	device_ref:        ^avutil.BufferRef,
	device_ctx:        rawptr, // AVHWDeviceContext* (filled by init)
	hwctx:             rawptr,
	free:              rawptr,
	user_opaque:       rawptr,
	pool:              rawptr, // AVBufferPool*
	initial_pool_size: c.int,
	format:            avutil.PixelFormat,
	sw_format:         avutil.PixelFormat,
	width:             c.int,
	height:            c.int,
	_pad:              [64]u8, // internal union — pin ABI past the writes
}

// enc_encoder_candidates returns the encoder names to try, in order. CPU runs
// libx264 directly; GPU probes the platform's hardware encoders first and ends
// with libx264 as the guaranteed last resort. The candidate list itself is
// shared with the proxy encoder (hw_encode.odin) so the two paths cannot
// disagree about what "try the hardware first" means.
enc_encoder_candidates :: proc() -> [dynamic]cstring {
	return hw_enc_candidate_names(render_encoder_ui.choice == .CPU)
}

// enc_ctx_common fills the encoder context fields shared by every H.264
// encoder (libx264 and hardware alike). libx264-specific options (preset) are
// set by the open path that owns libx264; hardware encoders accept these
// generic fields and ignore what they don't understand.
enc_ctx_common :: proc(ctx: ^avcodec.CodecContext, width, height: c.int, fps_num, fps_den: c.int) {
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
	ctx.gop_size = 120
	ctx.max_b_frames = 2
	ctx.bit_rate = 8_000_000
	// The reference vaapi_encode example pins SAR to 1:1; the default (0:1)
	// trips the SAR validity check path in avcodec_open2 on some builds.
	ctx.sample_aspect_ratio = avutil.Rational {num = 1, den = 1}
	// Thread count 0 = auto-detect. libx264 frames threads across cores; the
	// FFmpeg default is 1 (single-threaded encode) unless opted in explicitly,
	// wasting every core past the first. Hardware encoders ignore it.
	ctx.thread_count = 0
	// Without this flag avcodec_send_frame zeroes frame.duration before the
	// encoder sees it, so libx264 emits pkt.duration=0 and the mp4 muxer sizes
	// the final stts sample (track_duration = last dts + pkt.duration) to zero.
	ctx.flags += {avcodec.CodecFlag.Frame_Duration}
}

// enc_hw_upload_open tries the encoder's hardware-frames path: create the
// device, build a frames context for the codec's hw format with NV12 as the
// software carrier, and open with the ctx receiving hardware surfaces. The
// frame-send path then uploads each sw NV12 frame into a hw surface. Fails
// cleanly (releases everything acquired) when no config opens — the sw-input
// path is tried next.
//
// The device/frames setup is shared with the proxy encoder (hw_encode.odin);
// what stays here is the export-specific part, which is just recording the
// refs so the send path can upload through them.
enc_hw_upload_open :: proc(
	e: ^Render_Enc,
	ctx: ^avcodec.CodecContext,
	codec: ^avcodec.Codec,
	width, height: c.int,
) -> bool {
	ok, dev, frames := hw_enc_open(ctx, codec, width, height)
	if !ok {
		return false
	}
	e.enc_hw_device = dev
	e.enc_hw_frames = frames
	e.enc_hw_upload = true
	return true
}

// enc_convert_finish wires the RGBA -> encoder-input scaler + buffer for the
// chosen software pixel format (the hardware-upload path scales into NV12).
// The source and destination are the same size, so this is a pure colorspace
// conversion with no resampling. The scaler flag is left at Bilinear because
// the cheaper Point path changes the output bytes (swscale still filters at
// 1:1), and the export matrix must stay byte-identical. VYPER_YUV="1"
// swaps this conversion for our SIMD kernels (use_fast_yuv below); that
// path is byte-different by design (different chroma subsample), so it is
// off by default.
enc_convert_finish :: proc(e: ^Render_Enc, width, height: c.int) -> bool {
	e.use_fast_yuv = os.get_env_alloc("VYPER_YUV", context.temp_allocator) == "1"
	e.sws_rgb_yuv = sws.getContext(
		width,
		height,
		avutil.PixelFormat.RGBA,
		width,
		height,
		e.enc_sw_pix_fmt,
		sws.Flags{.Bilinear},
		nil,
		nil,
		nil,
	)
	if e.sws_rgb_yuv == nil {
		fmt.println("sws_getContext (rgb->yuv) failed")
		return false
	}
	if avutil.image_alloc(&e.yuv_data[0], &e.yuv_linesize[0], width, height, e.enc_sw_pix_fmt, 32) < 0 {
		fmt.println("av_image_alloc (yuv) failed")
		return false
	}
	e.yuv_avail = true
	if e.use_fast_yuv && e.enc_sw_pix_fmt == .YUV420P {
		if avutil.image_alloc(&e.yuv_scratch[0], &e.yuv_scratch_ls[0], width, height, avutil.PixelFormat.NV12, 32) < 0 {
			fmt.println("av_image_alloc (yuv scratch) failed")
			return false
		}
		e.yuv_scratch_avail = true
	}
	return true
}

// enc_convert_rgba_fast replaces swscale for the 1:1 RGBA->encoder-input
// conversion with our hand-written SIMD kernels (VYPER_YUV gate). NV12
// (hardware encoders) is one rgba_to_nv12 pass; YUV420P (libx264) chains a
// nv12_to_i420 deinterleave whose chroma samples are unchanged by the plane
// split. Returns false only on an actual kernel failure — the caller falls
// back to swscale then.
enc_convert_rgba_fast :: proc(e: ^Render_Enc, src_rgba: [^]u8, width, height: c.int) -> bool {
	src_stride := c.int(width * 4)
	#partial switch e.enc_sw_pix_fmt {
	case .NV12:
		if !yuvconv.rgba_to_nv12(
			int(width),
			int(height),
			src_rgba,
			int(src_stride),
			e.yuv_data[0],
			int(e.yuv_linesize[0]),
			e.yuv_data[1],
			int(e.yuv_linesize[1]),
		) {
			return false
		}
	case .YUV420P:
		if !yuvconv.rgba_to_nv12(
			int(width),
			int(height),
			src_rgba,
			int(src_stride),
			e.yuv_scratch[0],
			int(e.yuv_scratch_ls[0]),
			e.yuv_scratch[1],
			int(e.yuv_scratch_ls[1]),
		) {
			return false
		}
		yuvconv.nv12_to_i420(
			int(width),
			int(height),
			e.yuv_scratch[0],
			int(e.yuv_scratch_ls[0]),
			e.yuv_scratch[1],
			int(e.yuv_scratch_ls[1]),
			e.yuv_data[0],
			int(e.yuv_linesize[0]),
			e.yuv_data[1],
			int(e.yuv_linesize[1]),
			e.yuv_data[2],
			int(e.yuv_linesize[2]),
		)
	case:
		return false
	}
	return true
}

// enc_open_one tries a single named encoder and, on success, keeps its context
// plus the RGBA->input conversion. Hardware candidates are accepted only when
// a real open succeeds: an encoder can be registered in the build yet fail to
// open without the device/driver behind it, exactly like the decode probe
// handles. Each attempt gets a fresh context — a failed avcodec_open2 leaves
// context state undefined.
enc_open_one :: proc(
	e: ^Render_Enc,
	name: cstring,
	width, height: c.int,
	fps_num, fps_den: c.int,
) -> bool {
	codec := avcodec.find_encoder_by_name(name)
	if codec == nil {
		return false
	}
	ctx := avcodec.alloc_context3(codec)
	if ctx == nil {
		return false
	}
	enc_ctx_common(ctx, width, height, fps_num, fps_den)
	if name == "libx264" {
		ctx.pix_fmt = .YUV420P
		if ret := avutil.opt_set(ctx.priv_data, "preset", RENDER_VIDEO_PRESET, 0); ret < 0 {
			// A hardcoded, known-valid preset on a known encoder: failing here
			// means the build's libx264 disagrees, and silently running
			// "medium" hides the very slowdown this exists to remove.
			fmt.println("av_opt_set (preset):", ff_err_str(ret))
			avcodec.free_context(&ctx)
			return false
		}
		if ret := avcodec.open2(ctx, codec, nil); ret < 0 {
			fmt.println("avcodec_open2 (h264):", ff_err_str(ret))
			avcodec.free_context(&ctx)
			return false
		}
		e.enc_sw_pix_fmt = .YUV420P
	} else if enc_hw_upload_open(e, ctx, codec, width, height) {
		// The frame-send path scales into NV12 and uploads it (sw carrier).
		e.enc_sw_pix_fmt = .NV12
	} else {
		sw_candidates := [?]avutil.PixelFormat{.NV12, .YUV420P}
		opened := false
		for pix_fmt in sw_candidates {
			fctx := avcodec.alloc_context3(codec)
			if fctx == nil {
				break
			}
			enc_ctx_common(fctx, width, height, fps_num, fps_den)
			fctx.pix_fmt = pix_fmt
			if ret := avcodec.open2(fctx, codec, nil); ret == 0 {
				avcodec.free_context(&ctx)
				ctx = fctx
				e.enc_sw_pix_fmt = pix_fmt
				opened = true
				break
			}
			avcodec.free_context(&fctx)
		}
		if !opened {
			avcodec.free_context(&ctx)
			return false
		}
	}
	e.vcodec_ctx = ctx
	n := 0
	namep := ([^]u8)(name)
	for n < len(e.enc_name) - 1 && namep[n] != 0 {
		e.enc_name[n] = namep[n]
		n += 1
	}
	e.enc_name_len = n
	if !enc_convert_finish(e, width, height) {
		fmt.println("failed to prepare convert path for", string(name))
		return false
	}
	return true
}

// enc_open_video configures the video encoder and its mux stream. It tries the
// encoder candidates (per the export-panel choice) until one opens, then wires
// its stream.
enc_open_video :: proc(e: ^Render_Enc, width, height: c.int, fps_num, fps_den: c.int) -> bool {
	for name in enc_encoder_candidates() {
		if enc_open_one(e, name, width, height, fps_num, fps_den) {
			codec := avcodec.find_encoder_by_name(name)
			stream := avfmt.new_stream(e.fmt_ctx, codec)
			if stream == nil {
				fmt.println("avformat_new_stream (video) failed")
				return false
			}
			e.vstream = stream
			stream.time_base = e.vcodec_ctx.time_base
			if ret := avcodec.parameters_from_context(stream.codecpar, e.vcodec_ctx); ret < 0 {
				fmt.println("avcodec_parameters_from_context:", ff_err_str(ret))
				return false
			}
			stream.codecpar.width = width
			stream.codecpar.height = height
			e.vpkt = avcodec.packet_alloc()
			return true
		}
	}
	fmt.println("no usable H.264 encoder")
	return false
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

rend_enc_send_video :: proc(
	e: ^Render_Enc,
	ydata: ^[4][^]u8,
	ylinesize: ^[4]c.int,
	width, height: c.int,
	frame_index: i64,
) -> bool {
	frame := avutil.frame_alloc()
	if frame == nil {
		return false
	}
	defer avutil.frame_free(&frame)
	frame.format = c.int(e.enc_sw_pix_fmt)
	frame.width = width
	frame.height = height
	for i in 0 ..< 4 {
		frame.data[i] = ydata[i]
		frame.linesize[i] = ylinesize[i]
	}
	frame.pts = frame_index
	// The mp4 muxer sizes the final stts sample from the last packet's
	// duration; libx264 forwards frame.duration as pkt.duration. Without
	// this the last frame gets a zero-length sample and playback truncates
	// the export by one frame.
	frame.duration = 1
	to_send := frame
	defer if to_send != frame {
		avutil.frame_free(&to_send)
	}
	if e.enc_hw_upload {
		// Hardware-surfaces encoder (VAAPI): move the NV12 frame into a hw
		// surface before sending. The encoder holds its own refs on the
		// surface buffers when it accepts the frame, but our AVFrame wrapper
		// must stay alive until the send returns -- the proc-scoped defer
		// below (to_send != frame) frees it once, after the send.
		hw_frame := avutil.frame_alloc()
		if hw_frame == nil {
			return false
		}
		t_up := time.now()._nsec
		if ret := avutil.hwframe_get_buffer(e.vcodec_ctx.hw_frames_ctx, hw_frame, 0); ret < 0 {
			fmt.println("av_hwframe_get_buffer:", ff_err_str(ret))
			return false
		}
		if ret := avutil.hwframe_transfer_data(hw_frame, frame, 0); ret < 0 {
			fmt.println("av_hwframe_transfer_data:", ff_err_str(ret))
			return false
		}
		render_pipe.enc_upload_ns += time.now()._nsec - t_up
		hw_frame.pts = frame_index
		hw_frame.duration = 1
		to_send = hw_frame
	}
	t_send := time.now()._nsec
	if ret := avcodec.send_frame(e.vcodec_ctx, to_send); ret < 0 {
		fmt.println("avcodec_send_frame (video):", ff_err_str(ret))
		return false
	}
	render_pipe.enc_send_ns += time.now()._nsec - t_send
	t_drain := time.now()._nsec
	ok := enc_drain(e, e.vcodec_ctx, e.vstream, e.vpkt)
	render_pipe.enc_drain_ns += time.now()._nsec - t_drain
	return ok
}

// rend_enc_video_frame converts one composited RGBA canvas to the encoder's
// software pixel format (swscale, or the VYPER_YUV SIMD kernels) and sends it.
// This is the CPU conversion path: GPU-composited frames that take a CPU
// convert are read back as RGBA and run through here.
rend_enc_video_frame :: proc(
	e: ^Render_Enc,
	rgb: []u8,
	width, height: c.int,
	frame_index: i64,
) -> bool {
	slice: [1][^]u8 = {raw_data(rgb)}
	ls: [4]c.int = {width * 4, 0, 0, 0}
	t_sws := time.now()._nsec
	converted := false
	if e.use_fast_yuv {
		converted = enc_convert_rgba_fast(e, raw_data(rgb), width, height)
		if !converted {
			fmt.println("fast-yuv conversion failed; falling back to swscale")
		}
	}
	if !converted {
		sws.scale(
			e.sws_rgb_yuv,
			cast([^][^]u8)&slice[0],
			cast([^]c.int)&ls[0],
			0,
			height,
			cast([^][^]u8)&e.yuv_data[0],
			cast([^]c.int)&e.yuv_linesize[0],
		)
	}
	render_pipe.enc_sws_ns += time.now()._nsec - t_sws
	return rend_enc_send_video(e, &e.yuv_data, &e.yuv_linesize, width, height, frame_index)
}

// rend_enc_video_frame_nv12 sends a GPU-converted NV12 frame: the worker
// already produced the packed NV12 bytes (luma plane, then interleaved UV), so
// there is no conversion here at all -- the points are wired straight into the
// AVFrame. Only used when the slot's nv12_ready flag is set, which only happens
// on the GPU-composite + GPU-NV12 + NV12-encoder path.
rend_enc_video_frame_nv12 :: proc(
	e: ^Render_Enc,
	nv12: []u8,
	width, height: c.int,
	frame_index: i64,
) -> bool {
	assert(len(nv12) >= int(width) * int(height) * 3 / 2, "nv12 slot smaller than a full frame")
	data: [4][^]u8 = {
		raw_data(nv12),
		raw_data(nv12[int(width) * int(height):]),
		nil,
		nil,
	}
	ls: [4]c.int = {width, width, 0, 0}
	return rend_enc_send_video(e, &data, &ls, width, height, frame_index)
}

// enc_send_pending_audio sends every WHOLE AAC frame currently staged in
// audio_pending. Split out of rend_enc_push_audio because the tail of the export
// needs the same loop doing a different job -- see render_enc_flush.
enc_send_pending_audio :: proc(e: ^Render_Enc) -> bool {
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

// rend_enc_push_audio stages an interleaved stereo chunk and flushes full AAC
// frames to the encoder.
rend_enc_push_audio :: proc(e: ^Render_Enc, mix: []f32) -> bool {
	e.audio_real += i64(len(mix) / 2)
	// Copy into pending, converting zeros already in place.
	for s in mix {
		e.audio_pending[e.audio_pending_n] = s
		e.audio_pending_n += 1
	}
	return enc_send_pending_audio(e)
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
	// Nothing of this source has reached the mix yet, so its first contribution
	// is a fade-in from silence rather than an arrival at full level. Set here
	// rather than defaulted, because the zero value of Render_Audio_Src has to
	// stay useful and a struct that means "unopened" should not read as
	// "contributed last block".
	a.muted = true
	overlap_start := max(a.timeline_start_frame, render_start)
	if !open_audio_decoder_resampled(&a.dec, a.path, a.stream_index, RENDER_AUDIO_RATE, 2) {
		return false
	}
	// Where this clip's content actually begins, as an exact 48 kHz sample
	// (audio_source_start_sample, the S1 integer path -- no float seconds).
	content := i64(
		audio_source_start_sample(
			a.source_start_frame + (overlap_start - a.timeline_start_frame),
			a.source_start_rate,
		),
	)
	// Preroll: seek EARLY and decode forward, exactly as playback's
	// audio_src_seek_anchor does, and through the same proc -- decode_from_content.
	// Both of them used to clamp that seek to zero, which is what pinned the
	// export a whole packet after every clip's first sample.
	//
	// Seeking to the asked position and then labelling the fifo with wherever the
	// decoder landed fixes the LABEL but not the CONTENT, and the export had only
	// the label. A seek lands on a keyframe, which can be after the ask: the
	// audio_probe fixture lands +43ms late, and that is 43ms of every clip's opening
	// simply absent from the fifo. The mix then asks for content it does not have,
	// `a.first48 > content` is true, and the clip's first block comes out a
	// shortfall -- silent, counted, and audible as a gap at every cut.
	//
	// The label still comes from the decoder's real landing PTS rather than the
	// asked time: labelling with the asked time compounds the seek's error over the
	// whole render (playground's audio_provision fix, same reason).
	n := decode_from_content(&a.dec, content)
	if n <= 0 {
		return false
	}
	src := &a.dec
	a.first48 = i64(decoder_pts_sample(src.first_ts, src.stream.time_base))
	a.have48 = a.first48 + i64(n)
	ring_push_pcm(&a.fifo, a.dec.s16[:n * 2], n)
	// Decode forward until the fifo covers the clip's first content sample plus a
	// block, so the mix's opening request is satisfied from real audio rather than
	// from a hole the preroll was supposed to prevent.
	render_audio_pull(a, content + AUDIO_MIX_BLOCK)

	// Reaching here with the fifo starting past the content means the source cannot
	// supply the clip's beginning at all -- the decoder's first decodable audio is
	// after the clip's first sample. Counted and logged rather than left to become
	// a silent hole per block: the mix will treat every one of those blocks as a
	// shortfall, and the export ends up with a gap at every cut of that clip with
	// nothing in the log to connect the two.
	if a.first48 > content {
		render_pipe.audio_preroll_miss += 1
		if !render_preroll_logged {
			render_preroll_logged = true
			fmt.printf(
				"[render] audio: %s opens %.1fms after its first clip sample; preroll could not cover it\n",
				a.path,
				f64(a.first48 - content) * 1000.0 / f64(RENDER_AUDIO_RATE),
			)
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Main worker.
// ---------------------------------------------------------------------------

// render_mix is the export's mix bus. Worker-owned for the life of the job and
// freed with the job arena, like everything else the worker allocates.
render_mix: Render_Mix

// render_preroll_logged keeps the "decoder opens after its clip's first sample"
// warning to one line per render rather than one per clip: every clip of an
// affected file reports it, and a project with twenty of them should say so once.
render_preroll_logged: bool

// Render_Enc_Slot is one entry of the encode ring.
RENDER_ENC_SLOTS :: 4
Render_Enc_Slot :: struct {
	canvas: []u8,
	mix:    []f32,
	spf:    int,
	// nv12 carries the GPU-composited+GPU-converted frame (w*h luma +
	// w/2*h/2*2 chroma) when the worker's GPU NV12 path is the active convert
	// for this render; nv12_ready tells the encoder to skip its swscale
	// conversion and feed these bytes straight into the encoder. Owned by the
	// same ring slot as canvas, so it lives as long as the consume does.
	nv12:       []u8,
	nv12_ready: bool,
}

// Render_Pipeline is the render's thread + pipeline handoff state: the worker
// thread and the two pipeline threads below it. Everything here is either a
// thread handle or an atomic handoff counter / stop flag; writers and readers
// are documented per field.
Render_Pipeline :: struct {
	// Worker.
	worker: ^thread.Thread,
	// P5 decode pipeline: render_decode owns every video decoder and scales
	// frame N into blit_slots[N & 1] while the worker composites frame N-1 out
	// of blit_slots[(N-1) & 1]. Handoff is two release/acquire counters with a
	// two-slot depth (see render_decode_proc for the slot-reuse bound);
	// cancellation/teardown rides dec_stop. The worker touches no decoder field
	// after this split — decoders are single-writer, producer-owned.
	decode:           ^thread.Thread,
	dec_stop:         bool, // atomic: worker sets, producer polls (also in waits)
	dec_produced:     i64,  // atomic: frames decoded+published by the producer
	dec_consumed:     i64,  // atomic: frames composited by the worker
	dec_ns:           i64, // producer-side wall time: decode + scale + transfer
	dec_codec_ns:     i64, // sub-slice: codec + frame-cache/transfer...
	dec_scale_ns:     i64, // ...versus the scale into the blit slot
	// P6 encode pipeline: render_enc owns the muxer and both encoders after
	// render_open_output. The composite thread fills a RENDER_ENC_SLOTS-deep
	// ring of {canvas, audio mix} slots and publishes enc_produced; the
	// encoder converts/uploads/sends/drains/muxes each slot and publishes
	// enc_consumed. Slot N&(SLOTS-1) is safe to refill once the encoder has
	// finished frame N-SLOTS (consumed >= N-SLOTS+1) — same release/acquire
	// shape as the decode ring. Teardown rides enc_stop; the encoder drains
	// whatever was produced and finalizes only when every frame was produced,
	// so a cancel or early failure leaves a partial, trailerless file exactly
	// as the old inline path did. A canvas per slot is the cost of letting the
	// encoder run ahead of the compositor (SLOTS*w*h*4 bytes: 33 MB at 1080p).
	enc:              ^thread.Thread,
	enc_stop:         bool, // atomic: worker sets at EOF/cancel; encoder polls
	enc_produced:     i64,  // atomic: slots filled by the composite thread
	enc_consumed:     i64,  // atomic: slots encoded by the encoder thread
	enc_has_audio:    bool,
	enc_fail:         bool, // encoder set a failure; worker reports it after join
	enc_err:          [128]u8,
	enc_err_len:      int,
	// Blocking slot handoff (futex-backed semaphores): free counts slots the
	// composite may write, ready counts slots the encoder may read. A
	// spin-yield here starves the encoder's own worker threads and buys
	// nothing — the wait is long (encode outlasts composite), so the threads
	// must actually sleep. The counts are self-balancing across a render:
	// every ready post is matched by one ready wait and every free wait by one
	// free post, including the cancel drain.
	enc_free:          sync.Sema,
	enc_ready:         sync.Sema,
	enc_sema_init:     bool,
	// Encoder-thread timing, written before it exits and read after the join.
	enc_video_ns:      i64,
	enc_audio_ns:      i64,
	// A3 mix producer: render_mix_proc mixes the job's whole audio span in fixed
	// AUDIO_MIX_BLOCK blocks and keeps render_mix.bus full to
	// RENDER_MIX_CUSHION_FRAMES, so the composite thread consumes finished audio
	// instead of mixing whatever the current frame happens to need. Same shape as
	// the decode producer: one atomic stop flag, one thread, joined before the
	// audio decoders it owns are reset. The producer owns the audio decoders
	// outright -- they are single-writer, and after this split the worker touches
	// none of their fields.
	mix:              ^thread.Thread,
	mix_stop:         bool, // atomic: worker sets at EOF/cancel; producer polls
	// mix_faulted is the producer's own panic/stop escape: if it cannot finish
	// the span, the consumer's wait must not become unbounded, and a frame the
	// bus never got is a hole counted rather than a render that hangs.
	mix_faulted:      bool, // atomic: producer set
	mix_ns:           i64, // producer-side wall time: decode + mix
	mix_wait_ns:      i64, // ...of which was stalled waiting for the consumer
	// audio_holes counts video frames the mix bus could not cover, plus the
	// producer's own count of source shortfalls. Read by the render-test summary
	// after the join. Sample-domain by construction: the bus knows in samples, so
	// this counts the thing that actually got dropped rather than a frame-shaped
	// proxy for it.
	audio_holes:       i64,
	// audio_preroll_miss counts clips whose decoder opens AFTER the clip's first
	// sample, so the opening could not be covered by preroll and every block of it
	// is a shortfall. Worker-written, read after the join. In samples, like every
	// other audio number here: a frame-domain count of this is a count of the wrong
	// thing, since the damage is a span of time inside the first frame.
	audio_preroll_miss: i64,
	// Sub-split of enc_video_ns for the hw-upload path probe: how much is CPU
	// RGB->NV12 sws, how much is the sw->hw surface transfer, and how much is
	// send+drain (encoder wait).
	// Sub-split of composite_ns, same rationale as the enc_* counters above:
	// the canvas work is one number today, and the obvious suspect (the GPU
	// resample round trip) is only worth attacking if it is actually where
	// the time goes. comp_* are wall time per frame on the worker thread.
	comp_zero_ns:      i64,
	comp_resample_ns:  i64,
	comp_blit_ns:      i64,
	// Sub-split of comp_resample_ns. The canvas work only removes the
	// DOWNLOAD, so "how much of the round trip is the readback" is the
	// number that decides whether that work is worth doing at all -- the
	// upload and the resample itself are untouched by it.
	res_upload_ns:     i64,
	res_gpu_ns:        i64,
	// res_gpu_ns split again, because "the GPU work" and "waiting for the GPU"
	// are different costs: if WaitForGPUIdle is most of it, this is a pipeline
	// stall and not compute, and the fix is a different thing entirely.
	res_submit_ns:     i64,
	// The CPU kernel's own time, in-app and next to the GPU numbers above.
	// The probe times the same function in isolation and reports ~8x more
	// than it costs here, so only this in-app number settles which resample
	// path is actually cheaper in the shipping configuration.
	cpu_resample_ns:   i64,
	// Call count for cpu_resample_ns. Dividing the total by the run's frame
	// count is only the per-call cost if the resample ran on EVERY frame; if
	// it ran on a subset, the per-frame number is the per-call cost deflated
	// by the ratio, which is a flattering and wrong way to report a kernel.
	cpu_resample_n:    int,
	// Split by geometry. rgba_resample has three very different branches --
	// 1:1 is a memcpy, a downscale is a box average, an upscale is bilinear --
	// and averaging them together reports a number that describes no frame
	// that was ever rendered. A keyed scale animation hits all of them, so
	// cost and count are kept per class.
	cp1_ns, cp1_n:     i64,
	cpd_ns, cpd_n:     i64,
	cpu_ns, cpu_n:     i64,
	comp_nv12_pass_ns, comp_nv12_dl_ns, comp_nv12_wait_ns, comp_nv12_cpy_ns: i64,
	rs1_ns, rs1_n:     i64,
	rsd_ns, rsd_n:     i64,
	rsu_ns, rsu_n:     i64,
	gpu1_ns, gpu1_n:   i64,
	gpud_ns, gpud_n:   i64,
	rect_n:            int,
	rect_min_area:     int,
	rect_max_area:     int,
	rect_w_min:        int,
	rect_w_max:        int,
	out_min_w:         int,
	out_max_w:         int,
	out_min_h:         int,
	out_max_h:         int,
	res_wait_ns:       i64,
	res_download_ns:   i64,
	enc_sws_ns:        i64,
	enc_upload_ns:     i64,
	enc_send_ns:       i64,
	enc_drain_ns:      i64,
	enc_slots:         [RENDER_ENC_SLOTS]Render_Enc_Slot,
	enc_ptr:           ^Render_Enc,
}
render_pipe: Render_Pipeline

render_worker :: proc(t: ^thread.Thread) {
	render_worker_run()
}

// render_decode_proc is the producer half of the P5 decode-ahead pipeline. It
// decodes+scales every covering clip for frame N into that frame's blit slot,
// then publishes produced = N+1 so the worker can composite. It may run up to
// two frames ahead of the worker (the slot depth); the consumed bound below
// keeps it from reusing a slot the worker is still reading — slot N&1 was last
// read by the worker for frame N-2, which is done only once consumed >= N-1.
// The decode path makes no Odin-side allocations (FFmpeg allocates internally),
// so this thread's default allocator is never touched.
render_decode_proc :: proc() {
	for frame_idx in 0 ..< render_job.nframes {
		for sync.atomic_load(&render_pipe.dec_consumed) < frame_idx - 1 {
			if sync.atomic_load(&render_pipe.dec_stop) {
				return
			}
			thread.yield()
		}
		if sync.atomic_load(&render_pipe.dec_stop) {
			return
		}
slot_idx := int(frame_idx & 1)
	timeline_frame := render_job.start + frame_idx
	t_frame := time.now()._nsec
	for i in 0 ..< len(render_job.videos) {
			v := &render_job.videos[i]
			if !clip_visible_at(timeline_frame, v.timeline_start_frame, v.source_length_frames) {
				continue
			}
			// Fully off-canvas clips were never opened (v.fw == 0 in setup).
			if v.fw <= 0 {
				continue
			}
			slot := &v.blit_slots[slot_idx]
			src_frame := clip_source_frame(
				v.source_start_frame,
				v.timeline_start_frame,
				timeline_frame,
				v.is_still,
				v.src_fps,
			)
			t_src := time.now()._nsec
			if !decode_source_frame(&v.dec, src_frame) {
				slot.ok = false
				continue
			}
			render_pipe.dec_codec_ns += time.now()._nsec - t_src
			t_scale := time.now()._nsec
			decode_into_buffer(&v.dec, slot.blit, v.fw, v.fh)
			render_pipe.dec_scale_ns += time.now()._nsec - t_scale
			slot.ok = true
		}
		// Release: the slot writes above are visible to the worker's acquire
		// load of produced before it composites frame frame_idx.
		sync.atomic_store(&render_pipe.dec_produced, frame_idx + 1)
		render_pipe.dec_ns += time.now()._nsec - t_frame
	}
}

render_decode :: proc(t: ^thread.Thread) {
	render_decode_proc()
}

// render_enc_fail_set records an encoder-thread failure for the worker to pick
// up after the join. Encoder-thread only, read by the worker only post-join.
render_enc_fail_set :: proc(msg: string) {
	n := min(len(msg), len(render_pipe.enc_err))
	copy(render_pipe.enc_err[:n], msg[:n])
	render_pipe.enc_err_len = n
	render_pipe.enc_fail = true
}

// render_enc_encode_slot converts+encodes+muxes one composited slot and, if the
// job carries audio, its mixed PCM. Encoder-thread only.
render_enc_encode_slot :: proc(e: ^Render_Enc, fi: i64) {
	slot := &render_pipe.enc_slots[fi & (RENDER_ENC_SLOTS - 1)]
	t0 := time.now()._nsec
	if slot.nv12_ready {
		// GPU composite + GPU NV12: the worker converted this frame on the GPU
		// and packed slot.nv12, so the encoder skips its swscale conversion.
		if !rend_enc_video_frame_nv12(e, slot.nv12, render_job.width, render_job.height, fi) {
			render_enc_fail_set("video encoding failed")
			return
		}
	} else if !rend_enc_video_frame(e, slot.canvas, render_job.width, render_job.height, fi) {
		render_enc_fail_set("video encoding failed")
		return
	}
	render_pipe.enc_video_ns += time.now()._nsec - t0
	if render_pipe.enc_has_audio && slot.spf > 0 {
		t1 := time.now()._nsec
		if !rend_enc_push_audio(e, slot.mix[:slot.spf * 2]) {
			render_enc_fail_set("audio encoding failed")
			return
		}
		render_pipe.enc_audio_ns += time.now()._nsec - t1
	}
}

// render_enc_flush drains the encoders and finalizes the container. Encoder
// thread only, and only when every frame was produced.
render_enc_flush :: proc(e: ^Render_Enc) -> bool {
	avcodec.send_frame(e.vcodec_ctx, nil)
	if !enc_drain(e, e.vcodec_ctx, e.vstream, e.vpkt) {
		render_enc_fail_set("video flush failed")
		return false
	}
	if render_pipe.enc_has_audio {
		// The export's audio has to cover the WHOLE video, and the grid's last
		// frame is almost never a whole number of AAC frames. At 60fps this
		// project's grid is 1786*800 = 1428800 samples, which is 1395 AAC frames
		// plus 320 -- and those 320 were staged in audio_pending and then
		// dropped, because nothing between the last video frame and this flush
		// ever sends a PARTIAL frame. Every export therefore came out 6.7ms short
		// with its audio ending before its video, and the shortfall scaled with
		// the frame rate rather than being a constant.
		//
		// Pad the tail to a frame boundary with silence. Silence is the right
		// filler: it is what a decoder expects past the last real sample, it is
		// inside the coded stream rather than a claim about the timeline, and it
		// costs nothing -- the video track's duration is what defines the file's
		// length, so this closes the audio to the grid instead of inventing time.
		for e.audio_pending_n > 0 && e.audio_pending_n < AAC_FRAME_SIZE * 2 {
			e.audio_pending[e.audio_pending_n] = 0
			e.audio_pending_n += 1
		}
		if !enc_send_pending_audio(e) {
			render_enc_fail_set("sending the padded audio tail failed")
			return false
		}
		avcodec.send_frame(e.acodec_ctx, nil)
		if !enc_drain(e, e.acodec_ctx, e.astream, e.apkt) {
			render_enc_fail_set("audio flush failed")
			return false
		}
	}
	if ret := avfmt.write_trailer(e.fmt_ctx); ret < 0 {
		fmt.println("avformat_write_trailer:", ff_err_str(ret))
		render_enc_fail_set("finalizing file failed")
		return false
	}
	return true
}

// render_enc_proc is the consumer half of the P6 encode pipeline. It reads the
// slot the composite thread published (acquire load of produced), encodes it,
// then publishes consumed. On failure it stops doing work but keeps advancing
// consumed so the composite thread can never stall waiting for a slot; the
// failure is reported to the worker through render_pipe.enc_fail after the join.
render_enc_proc :: proc() {
	e := render_pipe.enc_ptr
	dead := false
	for {
		if sync.atomic_load(&render_pipe.enc_stop) {
			// Consume the ready tokens for the frames the composite posted but
			// we have not taken (each is guaranteed available), drain them, and
			// release their slots so the counts stay balanced. Finalize only a
			// complete render (cancel/early-fail: no trailer).
			for sync.atomic_load(&render_pipe.enc_consumed) < sync.atomic_load(&render_pipe.enc_produced) {
				sync.sema_wait(&render_pipe.enc_ready)
				fi := sync.atomic_load(&render_pipe.enc_consumed)
				if !dead {
					render_enc_encode_slot(e, fi)
					dead = render_pipe.enc_fail
				}
				sync.atomic_store(&render_pipe.enc_consumed, fi + 1)
				sync.sema_post(&render_pipe.enc_free)
			}
			if !dead && sync.atomic_load(&render_pipe.enc_produced) >= render_job.nframes {
				render_enc_flush(e)
			}
			return
		}
		// Wake periodically to re-check stop (a cancel joins this thread).
		if !sync.sema_wait_with_timeout(&render_pipe.enc_ready, 5 * time.Millisecond) {
			continue
		}
		fi := sync.atomic_load(&render_pipe.enc_consumed)
		if !dead {
			render_enc_encode_slot(e, fi)
			dead = render_pipe.enc_fail
		}
		sync.atomic_store(&render_pipe.enc_consumed, fi + 1)
		sync.sema_post(&render_pipe.enc_free)
	}
}

render_enc :: proc(t: ^thread.Thread) {
	render_enc_proc()
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
	// The encoder is a HANDOFF, not arena memory: avformat/avcodec own it behind
	// C pointers, so the job arena cannot free it and `enc_cleanup` must run on
	// every exit -- the success path, every `fail = true` early return, and a
	// panic. It was written and never called, so a render leaked the whole
	// muxer/encoder state (~1.3 MB, all of it still-reachable-but-lost) and the
	// file's AVIO buffer was never flushed. Deferred rather than hand-written at
	// each return: this proc has ~20 of them, and a leak that only happens on the
	// error paths is exactly the kind a manual unwind misses.
	defer enc_cleanup(&e)
	err_msg := ""
	render_pipe.enc = nil
	render_pipe.enc_fail = false
	render_pipe.enc_err_len = 0
	// Per-frame split timing (VYPER_FRAME_TIME="1"): wall time for the
	// composite + audio pull/mix block on this thread vs the video-encode and
	// audio-encode blocks on the encoder thread, printed once at the end. The
	// P6 pipeline runs composite and encode on different threads, so the
	// percentages are now a per-thread CPU split (they sum to combined work,
	// not wall time); the ratio is the signal. Declared in scope before the
	// defer so the report can read them on any exit path.
	split_timing := os.get_env_alloc("VYPER_FRAME_TIME", context.temp_allocator) != ""
	render_split_timing = split_timing
	render_probe_rect = split_timing
	audio_ns, composite_ns, loop_start := i64(0), i64(0), i64(0)
	defer {
		// Stop+join the decode producer BEFORE resetting the decoders: the
		// producer owns them (single-writer), so a reset while it is in a
		// decode call is a use-after-free. destroy() joins, and the producer
		// polls stop in both its waits, so this cannot hang.
		if render_pipe.decode != nil {
			sync.atomic_store(&render_pipe.dec_stop, true)
			thread.destroy(render_pipe.decode)
			render_pipe.decode = nil
		}
		// Stop+join the encode consumer before enc_cleanup: after the handoff
		// the encoder thread owns e (muxer + codecs), so cleanup must follow the
		// join. Its drain-on-stop finalizes the file when every frame was
		// produced.
		sync.atomic_store(&render_pipe.enc_stop, true)
		if render_pipe.enc != nil {
			thread.destroy(render_pipe.enc)
			render_pipe.enc = nil
		}
		render_pipe.enc_ptr = nil
		if render_pipe.enc_fail {
			fail = true
			if render_pipe.enc_err_len > 0 {
				err_msg = string(render_pipe.enc_err[:render_pipe.enc_err_len])
			}
		}
		// Stop+join the mix producer BEFORE the audio decoders are reset: it owns
		// them outright (they are single-writer and the worker no longer touches
		// them), so a reset while it is mid-decode is a use-after-free. It exits on
		// its own once it has published the last frame, so this join is immediate
		// on the normal path and only waits on a cancel.
		if render_pipe.mix != nil {
			sync.atomic_store(&render_pipe.mix_stop, true)
			thread.destroy(render_pipe.mix)
			render_pipe.mix = nil
		}
		render_pipe.audio_holes += render_mix.holes
		render_mix_bus_destroy(&render_mix.bus)
		enc_cleanup(&e)
		for &v in render_job.videos {
			clip_decoder_reset(&v.dec)
		}
		for &a in render_job.audios {
			if a.dec.opened {
				audio_decoder_reset(&a.dec)
			}
		}
		mem.dynamic_arena_destroy(&job_arena)
		render_text_font.setup_scratch = nil
		status := fail ? Render_Status.Failed : (cancelled() ? .Cancelled : .Done)
		if fail && len(err_msg) > 0 {
			set_status(.Failed, err_msg)
		} else if status == .Done && e.enc_name_len > 0 {
			// Report which encoder actually produced the file: a GPU choice may
			// have fallen back to libx264, and the message makes that visible.
			name_buf: [80]u8
			set_status(status, fmt.bprintf(name_buf[:], "export OK (%s)", string(e.enc_name[:e.enc_name_len])))
		} else {
			set_status(status, "")
		}
		if split_timing && (composite_ns + audio_ns + render_pipe.enc_video_ns + render_pipe.enc_audio_ns) > 0 {
			total := f64(composite_ns + audio_ns + render_pipe.enc_video_ns + render_pipe.enc_audio_ns)
			frames := max(1, render_job.nframes)
			fmt.printf(
				"[frame-time] composite=%.2f%% (%gs, %.2fms/f) videoenc=%.2f%% (%gs, %.2fms/f) audio=%.2f%% (%gs, %.2fms/f)\n",
				100 * f64(composite_ns + audio_ns) / total,
				f64(composite_ns + audio_ns) / 1e9,
				f64(composite_ns + audio_ns) / 1e6 / f64(frames),
				100 * f64(render_pipe.enc_video_ns) / total,
				f64(render_pipe.enc_video_ns) / 1e9,
				f64(render_pipe.enc_video_ns) / 1e6 / f64(frames),
				100 * f64(render_pipe.enc_audio_ns) / total,
				f64(render_pipe.enc_audio_ns) / 1e9,
				f64(render_pipe.enc_audio_ns) / 1e6 / f64(frames),
			)
			fmt.printf(
				"[frame-time]   videoenc split: sws=%.2fms/f upload=%.2fms/f send=%.2fms/f drain=%.2fms/f\n",
				f64(render_pipe.enc_sws_ns) / 1e6 / f64(frames),
				f64(render_pipe.enc_upload_ns) / 1e6 / f64(frames),
				f64(render_pipe.enc_send_ns) / 1e6 / f64(frames),
				f64(render_pipe.enc_drain_ns) / 1e6 / f64(frames),
			)
			// comp_blit_ns is the whole visual walk, so the resample is
			// inside it; print the difference so the two lines are not
			// mistaken for independent totals.
			comp_resample := render_pipe.comp_resample_ns
			fmt.printf(
				"[frame-time]   composite split: zero=%.2fms/f walk=%.2fms/f (resample inside=%.2fms/f)\n",
				f64(render_pipe.comp_zero_ns) / 1e6 / f64(frames),
				f64(render_pipe.comp_blit_ns) / 1e6 / f64(frames),
				f64(comp_resample) / 1e6 / f64(frames),
			)
			fmt.printf(
				// The GPU-NV12 conversion split. pass is the two render passes,
				// dl the plane downloads into g.down, wait the GPU idle after
				// submit, and cpy the one sequential copy that lands the already
				// NV12-ordered bytes in the slot. There is no pack stage: the
				// passes write NV12 order directly.
				"[frame-time]   nv12 pass=%.2fms dl=%.2fms wait=%.2fms cpy=%.2fms\n",
				f64(render_pipe.comp_nv12_pass_ns) / 1e6 / f64(frames),
				f64(render_pipe.comp_nv12_dl_ns) / 1e6 / f64(frames),
				f64(render_pipe.comp_nv12_wait_ns) / 1e6 / f64(frames),
				f64(render_pipe.comp_nv12_cpy_ns) / 1e6 / f64(frames),
			)
			fmt.printf(
				// Per geometry, never pooled: the 1:1 class is a memcpy and the
				// downscale class is a box average, and a keyed scale animation
				// produces both in one run. The pooled number describes no
				// frame that was actually rendered, and comparing a pooled CPU
				// figure against a pooled GPU figure hides which side wins.
				"[frame-time]   resample by geometry (CPU | GPU): " +
					"1:1 %.2fms x%d | %.2fms x%d   down %.2fms x%d | %.2fms x%d   up %.2fms x%d | -\n",
				f64(render_pipe.cp1_ns) / 1e6 / f64(max(render_pipe.cp1_n, 1)),
				render_pipe.cp1_n,
				f64(render_pipe.gpu1_ns) / 1e6 / f64(max(render_pipe.gpu1_n, 1)),
				render_pipe.gpu1_n,
				f64(render_pipe.cpd_ns) / 1e6 / f64(max(render_pipe.cpd_n, 1)),
				render_pipe.cpd_n,
				f64(render_pipe.gpud_ns) / 1e6 / f64(max(render_pipe.gpud_n, 1)),
				render_pipe.gpud_n,
				f64(render_pipe.cpu_ns) / 1e6 / f64(max(render_pipe.cpu_n, 1)),
				render_pipe.cpu_n,
			)
			fmt.printf(
				"[frame-time]   CPU resample kernel: %.2fms/call over %d calls (%.2fms/f over %d frames)\n",
				f64(render_pipe.cpu_resample_ns) / 1e6 / f64(max(render_pipe.cpu_resample_n, 1)),
				render_pipe.cpu_resample_n,
				f64(render_pipe.cpu_resample_ns) / 1e6 / f64(frames),
				frames,
			)
			fmt.printf(
				"[keyed-rect] out %dx%d..%dx%d  ",
				render_pipe.out_min_w,
				render_pipe.out_min_h,
				render_pipe.out_max_w,
				render_pipe.out_max_h,
			)
			fmt.printf(
				"[keyed-rect] over %d calls: crop width %d..%d, area %d..%d\n",
				render_pipe.rect_n,
				render_pipe.rect_w_min,
				render_pipe.rect_w_max,
				render_pipe.rect_min_area,
				render_pipe.rect_max_area,
			)
			fmt.printf(
				"[frame-time]   resample split: upload=%.2fms/f record=%.2fms/f submit=%.2fms/f wait=%.2fms/f download=%.2fms/f\n",
				f64(render_pipe.res_upload_ns) / 1e6 / f64(frames),
				f64(render_pipe.res_gpu_ns - render_pipe.res_submit_ns - render_pipe.res_wait_ns) / 1e6 / f64(frames),
				f64(render_pipe.res_submit_ns) / 1e6 / f64(frames),
				f64(render_pipe.res_wait_ns) / 1e6 / f64(frames),
				f64(render_pipe.res_download_ns) / 1e6 / f64(frames),
			)
			fmt.printf("[frame-time]   decode(producer)=%.2fms/f (codec=%.2fms/f scale=%.2fms/f)\n",
				f64(render_pipe.dec_ns) / 1e6 / f64(frames),
				f64(render_pipe.dec_codec_ns) / 1e6 / f64(frames),
				f64(render_pipe.dec_scale_ns) / 1e6 / f64(frames))
		}
	}

	// Prepare compositing state for each video source.
	for i in 0 ..< len(render_job.videos) {
		v := &render_job.videos[i]
		// The static path never rewrites opacity, so seed this frame's alpha
		// from the resting base here; the keyed path overwrites it per frame.
		v.opacity = v.geom.base[int(Render_Geom_Prop.Opacity)]
		if v.geom.keyed {
			// S6 animated path: decode ONCE at a stage sized to the max scale
			// this clip reaches (resting or keyed), then per frame the
			// composite samples the seven properties and region-copies the
			// matching sub-rect of the stage (linear in `scale`, so the box is
			// a centered crop of the stage — lossless, no per-frame decode).
			// A keyed clip can move anywhere on the canvas, so it is never
			// fw-zeroed, and neither the visibility crop (the WHOLE stage must
			// be present every frame) nor the static crop resampler is built.
			stage_scale := v.geom.base[int(Render_Geom_Prop.Scale)]
			for k in v.geom.keys[int(Render_Geom_Prop.Scale)].keys[:v.geom.keys[int(Render_Geom_Prop.Scale)].n] {
				if k.value.(f32) > stage_scale {
					stage_scale = k.value.(f32)
				}
			}
			v.stage_scale = max(stage_scale, 0.0001)
			scw, sch := full_box_dims(
				v.source_w,
				v.source_h,
				v.stage_scale,
				f32(render_job.width),
				f32(render_job.height),
			)
			v.fw = px_extent(scw)
			v.fh = px_extent(sch)
			if v.fw > render_max_stage_w {
				render_max_stage_w = v.fw
			}
			if v.fh > render_max_stage_h {
				render_max_stage_h = v.fh
			}
			// Seed the display rect with the resting pose; the composite
			// recomputes it per frame before every blit.
			l, t, r, b := render_display_rect(v, render_job.width, render_job.height)
			v.rw = px_extent(r - l)
			v.rh = px_extent(b - t)
			v.ox = c.int(l + 0.5)
			v.oy = c.int(t + 0.5)
			for &slot in &v.blit_slots {
				slot.blit = make([]u8, int(v.fw) * int(v.fh) * 4)
			}
			if v.geom.scale_keyed {
				// Per-frame resample scratch: the animated box is at most the
				// full stage, so one stage-sized buffer covers every frame.
				v.kres_scratch = make([]u8, int(v.fw) * int(v.fh) * 4)
			}
			if !open_clip_decoder_ex(&v.dec, v.path, v.stream_index, v.fw, v.fh, false) {
				err_msg = "failed to open video source"
				fail = true
				return
			}
			continue
		}
		render_static_src_geom(v, render_job.width, render_job.height)
		// Fully off-canvas: never drawn, so no decode at all. The frame loop
		// skips v.fw <= 0 before touching the decoder.
		if v.fw <= 0 {
			continue
		}
		// Static clips decode only the region they can draw, so their stage is
		// canvas-sized by construction; recording it anyway keeps the reported
		// max meaningful for a job with no keyed clips at all.
		if v.fw > render_max_stage_w {
			render_max_stage_w = v.fw
		}
		if v.fh > render_max_stage_h {
			render_max_stage_h = v.fh
		}
		for &slot in &v.blit_slots {
			slot.blit = make([]u8, int(v.fw) * int(v.fh) * 4)
		}
		if !open_clip_decoder_ex(&v.dec, v.path, v.stream_index, v.fw, v.fh, false) {
			err_msg = "failed to open video source"
			fail = true
			return
		}
		// A frame format the decoder cannot crop leaves it with no way to
		// honor the window: the fallback decodes the WHOLE source, which would
		// be scaled into the window and draw the entire frame squashed into
		// this clip's slice of the canvas. Drop the clip with the reason rather
		// than render it wrong. Every format these decoders produce is in the
		// crop table, so this is the defensive arm.
		if v.dec.crop_dropped {
			fmt.printf(
				"[render] video source %d omitted: %s cannot be cropped, so it cannot be clipped to the canvas\n",
				i,
				v.path,
			)
			v.fw = 0
			v.fh = 0
			v.rw = 0
			v.rh = 0
		}
	}

	// A full-cover layout needs no zero fill: every canvas pixel is
	// overwritten by an opaque blit on every frame, so mem.zero in the frame
	// loop is dead work. Only clips whose range encloses the whole render
	// range are counted — a clip absent on some frame leaves stale pixels
	// behind, which is exactly why the zero exists. A geometry-keyed clip
	// ALSO defeats it: its rect moves every frame, so a stale pose could
	// leak where it was.
	// A translucent clip is the same class of problem: it does not overwrite
	// what is below, so the canvas must start zeroed for the blend to composite
	// against. Checked statically from the snapshot (opacity is captured at
	// render_start), same shape as any_keyed -- which is why a KEYED opacity
	// lane counts as translucent here: a frame 40 keys in can be translucent
	// even though the resting value snapshotted above reads 1.0, and the zero
	// decision is made once for the whole job, before any frame is evaluated.
	any_keyed := false
	any_translucent := false
	for &v in render_job.videos {
		if v.geom.keyed {
			any_keyed = true
		}
		if v.geom.base[int(Render_Geom_Prop.Opacity)] < 1.0 || v.geom.opacity_keyed {
			any_translucent = true
		}
	}
	skip_canvas_zero :=
		len(render_job.videos) > 0 &&
		!any_keyed &&
		!any_translucent &&
		render_span_cover_canvas(
			render_job.videos,
			render_job.start,
			render_job.nframes,
			render_job.width,
			render_job.height,
		)

	// Start the P5 decode-ahead producer once every decoder is open and its
	// blit slots are allocated. The producer owns all decoders from here on;
	// the composite below reads only the published slots. A fresh default
	// context is fine: the decode path makes no Odin allocations.
	render_pipe.dec_stop, render_pipe.dec_produced, render_pipe.dec_consumed = false, 0, 0
	render_pipe.dec_ns = 0
	render_pipe.dec_codec_ns, render_pipe.dec_scale_ns = 0, 0
	if len(render_job.videos) > 0 {
		render_pipe.decode = thread.create(render_decode)
		if render_pipe.decode == nil {
			err_msg = "could not start decode thread"
			fail = true
			return
		}
		thread.start(render_pipe.decode)
	}

	// The output frame rate is the PROJECT rate the frame grid is defined on,
	// resolved once on the UI thread into the job snapshot (render_job.fps /
	// fps_num / fps_den). The worker reads that snapshot rather than
	// re-deriving a rate of its own, so the muxer's time base, the audio
	// samples-per-frame and the playhead all measure frames against one value:
	// the timeline grid is 1 frame == 1 source frame, and any second opinion
	// about the rate retimes the export against the preview it is supposed to
	// match.
	rfps_num, rfps_den := render_job.fps_num, render_job.fps_den
	rfps := render_job.fps
	mnum, mden := i64(rfps_num), i64(rfps_den)
	spf := int(MAX_AUDIO_FRAME_SAMPLES)
	if rfps > 0 {
		spf = min(MAX_AUDIO_FRAME_SAMPLES, max(0, int(math.round(48000.0 / rfps))))
	}

	has_audio := len(render_job.audios) > 0
	if has_audio {
		// The mix bus starts at the job's first sample, and its capacity IS the
		// cushion (render_mix_bus_frames).
		render_mix_init(
			&render_mix,
			rfps_num,
			rfps_den,
			sample_pos_from_frames(render_job.start, mnum, mden),
		)
		for i in 0 ..< len(render_job.audios) {
			a := &render_job.audios[i]
			if !render_audio_open(a, render_job.start, rfps) {
				a.dec.opened = false
			}
		}
		// Started only once every audio decoder is open: the producer owns them
		// from here, and opening one underneath it would be a use-after-free.
		render_pipe.mix = thread.create(render_mix_thread)
		thread.start(render_pipe.mix)
	}

	if !render_open_output(
		&e,
		render_job.out_path,
		render_job.width,
		render_job.height,
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

	// P6 encode ring: one canvas + one audio-mix buffer per slot, carved from
	// the job arena (freed wholesale when the worker unwinds). Then hand e to
	// the encoder thread; the worker touches no encoder/muxer field after this
	// point (only e.enc_name after the join). Slots + header must exist before
	// the thread starts.
	render_alloc_enc_slots()
	render_reset_pipe_timings(has_audio)
	// One-time semaphore priming: counts are self-balancing across renders, so
	// only the very first job needs the initial SLOTS free tokens.
	if !render_pipe.enc_sema_init {
		sync.sema_post(&render_pipe.enc_free, RENDER_ENC_SLOTS)
		render_pipe.enc_sema_init = true
	}
	render_pipe.enc_ptr = &e
	render_pipe.enc = thread.create(render_enc)
	if render_pipe.enc == nil {
		err_msg = "could not start encode thread"
		fail = true
		return
	}
	thread.start(render_pipe.enc)

	// Text compositing: each text clip gets a raster (baked font) + blit box,
	// then alpha-blitted on the canvas each frame. Baked ONCE here at the
	// clip's RESTING scale, which is all an unkeyed clip ever needs. A clip with
	// a keyed scale lane re-bakes on the frame the sampled scale leaves the
	// baked resolution (text_job_rescale), because the raster's font size IS the
	// scale — it cannot be applied by rescaling the blit.
	text_jobs := make([]Render_Text_Job, max(len(render_job.texts), 1))
	for i in 0 ..< len(render_job.texts) {
		t := &render_job.texts[i]
		base := t.geom.base[int(Render_Geom_Prop.Scale)]
		setup_text_job(&text_jobs[i], t^, base, true)
	}

	// Subtitle compositing: a one-slot active-cue raster cache per clip. Cues
	// play forward in population order, so a single slot per clip is a
	// near-perfect LRU. The box center each cue keeps is recomputed per frame
	// from the sampled geometry (sub_box_center) rather than latched here, so a
	// keyed subtitle tracks its own animation.
	sub_cues := make([]Render_Sub_Cue, max(len(render_job.subs), 1))
	sub_factor := f32(render_job.width) / f32(PREVIEW_W)

	// GPU canvas composite (S1c plumbing, part 1). A video-only job composites
	// the whole visual stack into one GPU canvas and reads it back once per
	// frame --
	//   * dropping the per-keyed upload+readback round trip (the cheap thing
	//     that made S1b's GPU resample worth less than the probe), and
	//   * drawing static 1:1 clips as quads instead of CPU region copies.
	// The CPU canvas is the drop-in fallback. It is selected (not merely the
	// consequence of a failed create) when anything the quad path cannot yet
	// reproduce byte-for-byte would be on the stack: a text clip or a subtitle
	// clip. VYPER_KEYED_GPU=0 pins the CPU composite for the A/B.
	//
	// Static video clips no longer disqualify the GPU path: their buffer is the
	// canvas-clipped window and the blit is a 1:1 copy of it (render_blit), so
	// blit_box reproduces the same pixels.
	gpu_frame_ok := keyed_gpu_enabled && len(render_job.texts) == 0 && len(render_job.subs) == 0
	if gpu_frame_ok && gpu_resample_get() == nil {
		gpu_frame_ok = false
	}
	// GPU RGBA->NV12 (S1c part 2): when the composite is on the GPU AND the
	// encoder's software pixel format is NV12 (the hw-upload/VAAPI path; the
	// NV12 software encoders too), the worker converts the canvas to NV12 on
	// the GPU and the encoder feeds those bytes straight in -- the encoder's
	// swscale conversion just does not run on those frames. Everything else
	// keeps the canvas readback + encoder-side conversion: a CPU composite,
	// a non-NV12 format (libx264's YUV420P), odd dimensions (NV12's half-res
	// chroma plane needs even), or VYPER_GPU_NV12=0. e.enc_sw_pix_fmt is set
	// by render_open_output on this same thread, so reading it here is safe.
	gpu_nv12_for_run :=
		gpu_frame_ok && gpu_nv12_enabled && e.enc_sw_pix_fmt == .NV12 &&
		render_job.width % 2 == 0 && render_job.height % 2 == 0

	for frame_idx in 0 ..< render_job.nframes {
		if poll_cancel() {
			return
		}
		timeline_frame := render_job.start + frame_idx
		// Composite all video clips covering this frame (bottom track first so
		// the top track paints last, matching the preview). With the P5
		// pipeline the decode for this frame is produced ahead on the second
		// thread: wait for it, then read only the published slot (never the
		// decoder). The acquire load on produced pairs with the producer's
		// release store, ordering every slot write before this read.
		if len(render_job.videos) > 0 {
			for sync.atomic_load(&render_pipe.dec_produced) <= frame_idx {
				if poll_cancel() {
					return
				}
				thread.yield()
			}
		}
		// P6 encode back-pressure: wait (blocking) for a free ring slot. The
		// counting semaphore guarantees at most SLOTS frames are outstanding;
		// frame N always maps to slot N&(SLOTS-1) because both sides consume in
		// order. The timeout lets a cancel be observed promptly.
		for !sync.sema_wait_with_timeout(&render_pipe.enc_free, 5 * time.Millisecond) {
			if poll_cancel() {
				return
			}
		}
		if split_timing {
			loop_start = time.now()._nsec
		}
		slot_idx := int(frame_idx & 1)
		eslot := &render_pipe.enc_slots[frame_idx & (RENDER_ENC_SLOTS - 1)]
		eslot.nv12_ready = false
		// The GPU composite begins before the zero fill: its first draw's
		// CLEAR is the background fill, so the mem.zero is the CPU-only path.
		gpu_canvas: GPU_Composite
		gpu_active := false
		t_walk := time.now()._nsec
		if gpu_frame_ok {
			if gc, gc_ok := gpu_composite_begin(gpu_resample_get(), int(render_job.width), int(render_job.height)); gc_ok {
				gpu_canvas = gc
				gpu_active = true
			}
		}
		if !gpu_active && !skip_canvas_zero {
			mem.zero(raw_data(eslot.canvas), len(eslot.canvas))
		}
		zero_done := time.now()._nsec
		render_pipe.comp_zero_ns += zero_done - t_walk
		// One walk over the track-ordered visual stack, back-to-front, so the
		// bottom track paints first and the top track last. Text and video are in
		// the SAME list, so a text clip on a lower track composites under the
		// video above it exactly as the preview does; it is no longer "all video,
		// then all text".
		t_gpu := time.now()._nsec
		for i := len(render_job.visuals) - 1; i >= 0; i -= 1 {
			#partial switch src in render_job.visuals[i] {
			case ^Render_Video_Src:
				if gpu_active && render_gpu_abort {
					continue
				}
				if !clip_visible_at(timeline_frame, src.timeline_start_frame, src.source_length_frames) {
					continue
				}
				// Fully off-canvas clips were never opened (v.fw == 0 in setup).
				if src.fw <= 0 {
					continue
				}
				slot := &src.blit_slots[slot_idx]
				if !slot.ok {
					continue
				}
				gpu_ctx: ^GPU_Composite
				if gpu_active {
					gpu_ctx = &gpu_canvas
				}
				if src.geom.keyed {
					render_eval_keyed_geom(src, timeline_frame, slot, eslot.canvas, gpu_ctx)
				} else {
					render_blit(eslot.canvas, render_job.width, render_job.height, src, slot, gpu_ctx)
				}
			case ^Render_Text_Src:
				t := src
				if !clip_visible_at(timeline_frame, t.timeline_start_frame, t.source_length_frames) {
					continue
				}
				if t.name == "" {
					continue
				}
				j := &text_jobs[t.job_idx]
				// Same carrier, same evaluator as every other visual source, so a
				// keyed text clip's pose comes from its keys rather than the
				// resting fields the snapshot used to copy. A text clip has no
				// source frame to crop, so its crop lanes read 0 here — the same
				// rule the preview applies (geom_clear_crop).
				sg := geom_snap_eval(&t.geom, geom_snap_offset(&t.geom, t.timeline_start_frame, timeline_frame))
				geom_clear_crop(&sg)
				// Scale is baked into the raster's font size, so an animated scale
				// has to re-bake it rather than rescale the blit. Only the
				// scale_keyed clips can reach here with a different scale than
				// the bake, so the gate is free for everyone else.
				if t.geom.scale_keyed {
					text_job_rescale(j, t^, sg[int(Render_Geom_Prop.Scale)])
				}
				if j.raster == nil || j.ow <= 0 || j.oh <= 0 {
					continue
				}
				render_text_blit(
					eslot.canvas,
					render_job.width,
					render_job.height,
					j.raster,
					j.bw,
					j.ox,
					j.oy,
					j.ow,
					j.oh,
					t.source_w,
					t.source_h,
					sg[int(Render_Geom_Prop.Trans_X)],
					sg[int(Render_Geom_Prop.Trans_Y)],
					sg[int(Render_Geom_Prop.Scale)],
					sg[int(Render_Geom_Prop.Opacity)],
				)
			}
		}
		// The GPU composite ends here, before the walk timing lands: the
		// readback is part of the composite. An abort latches a driver-level
		// failure; the remaining video draws were skipped (the guard in the
		// walk) and the run stops below rather than encode a partial frame.
		if gpu_active {
			if gpu_nv12_for_run {
				// GPU NV12: the end proc converts the canvas and reads the two
				// planes back packed; the encoder consumes slot.nv12 and skips
				// swscale. The RGBA readback into eslot.canvas does not happen,
				// and the encoder knows (nv12_ready) not to read that stale
				// canvas.
				if gpu_composite_end_nv12(&gpu_canvas, eslot.nv12) {
					// The full byte-exact chain -- composite AND conversion --
					// is pinned by keyed_export's 1:1 PSNR=inf, which now
					// compares GPU-composite+GPU-NV12 against
					// CPU-composite+swscale.
					eslot.nv12_ready = true
				} else {
					render_gpu_abort = true
				}
			} else if !gpu_composite_end(&gpu_canvas, eslot.canvas) {
				render_gpu_abort = true
			}
		}
		if render_gpu_abort {
			fmt.println("render-gpu: composite failed, aborting export")
			return
		}
		// The whole visual walk, so the per-clip resample time is a SUBSET of
		// this and the printed "blits" is a clean difference. Timing the walk
		// as one span is what makes the split honest: a per-case accumulator
		// placed before a clip's own work cannot contain that work, so
		// subtracting the resample from it goes negative.
		render_pipe.comp_blit_ns += time.now()._nsec - t_gpu
		// Composite subtitle-generator clips last. That is SUBTITLE_PIN_KEY
		// showing up as code: the key is 0, the lowest, and both pipelines draw
		// the lowest key last, so "pinned on top" is the same statement here as
		// in preview_draw_key. The rule is in render_order.odin precisely because
		// it used to be stated twice -- once as this trailing pass, once as the
		// preview's sort key -- and two statements of one rule is how this pair
		// drifted before.
		//
		// The pass stays separate from the stack walk above rather than merging
		// into it. Merging would mean one loop with a per-item branch across two
		// unrelated backends: this one rasterises CPU pixels out of the decode
		// stage, the preview draws a fractional UV quad on the GPU. Only the
		// ORDER is shared, and it is now shared by derivation instead of by two
		// implementations agreeing.
		for i in 0 ..< len(render_job.subs) {
			s := &render_job.subs[i]
			if !clip_visible_at(timeline_frame, s.timeline_start_frame, s.source_length_frames) {
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
			// Sample the same carrier a video or text clip composites from, so a
			// keyed subtitle moves and resizes instead of holding the pose the
			// job snapshot happened to carry.
			sg := geom_snap_eval(&s.geom, geom_snap_offset(&s.geom, s.timeline_start_frame, timeline_frame))
			scale := sg[int(Render_Geom_Prop.Scale)]
			jc := &sub_cues[i]
			// Re-bake when EITHER the cue changed or the clip's scale moved off
			// the resolution this raster was drawn at — scale is baked into the
			// cue's font size, so it cannot be applied by rescaling the blit.
			rebake :=
				jc.raster == nil ||
				jc.cue_idx != ci ||
				text_font_needs_rebake(jc.font_px, scale)
			if rebake {
				if jc.raster != nil {
					delete(jc.raster)
				}
				rasterize_subtitle_cue(jc, src.cues[ci].text, scale)
				jc.cue_idx = ci
				jc.font_px = text_font_px_for(scale)
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
			//
			// The center is recomputed from THIS frame's sampled geometry rather
			// than latched at setup, which is what makes a keyed subtitle track
			// its own animation. For an unkeyed clip the sampled values are the
			// resting ones, so this is exactly the old setup-time anchor.
			anchor_x, anchor_y := sub_box_center(
				sg,
				s.source_w,
				s.source_h,
				sub_factor,
				render_job.width,
				render_job.height,
			)
			// Box from the clip's BASE dims and the sampled scale, the same
			// text_box_dims the preview and the text path use, rather than from the
			// cue raster's measured ink -- so a subtitle's box is the same rectangle
			// on both sides.
			w, h := text_box_dims(s.source_w, s.source_h, scale, f32(render_job.width))
			bottom := anchor_y + h / 2
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
					anchor_x - w / 2,
					bottom - h,
					anchor_x,
					anchor_y,
					s.source_w,
					s.source_h,
					scale,
				)
			}
			render_text_blit(
				eslot.canvas,
				render_job.width,
				render_job.height,
				jc.raster,
				jc.bw,
				jc.ox,
				0,
				jc.ow,
				jc.bh,
				s.source_w,
				s.source_h,
				anchor_x,
				anchor_y,
				scale,
				sg[int(Render_Geom_Prop.Opacity)],
			)
		}
		if split_timing {
			now := time.now()._nsec
			composite_ns += now - loop_start
			loop_start = now
		}

		eslot.spf = 0
		if has_audio && spf > 0 {
			// The frame's bus range, exactly. What fills it is no longer this
			// loop's business: the mixer works in fixed AUDIO_MIX_BLOCK blocks
			// and the bus hands back the samples this frame covers, whether that
			// range is one block, part of three, or three and a bit. So a decode
			// that ran late costs the bus a block's worth of work once, instead
			// of a frame-shaped hole in the output every time it happened.
			cur_spf := render_mix_serve_frame(
				&render_mix,
				timeline_frame,
				mnum,
				mden,
				eslot.mix,
			)
			if cur_spf > 0 {
				eslot.spf = cur_spf
			} else {
				// The bus could not cover this frame. Silence for it -- the
				// alternative is feeding a stale buffer, which is how a hole
				// becomes a burst of the previous frame's audio. The shortfall
				// itself is already counted inside the fill.
				mem.zero(raw_data(eslot.mix), len(eslot.mix) * size_of(f32))
				render_pipe.audio_holes += 1
			}
		}
		if split_timing {
			audio_ns += time.now()._nsec - loop_start
		}

		// Offer the finished frame to the live preview sink. After the
		// composite is complete (so the bytes are final) and before the encoder
		// handoff, so the copy never sits on the encoder's wake-up path. Which
		// canvas is real depends on the run: the GPU NV12 path leaves
		// eslot.canvas holding this ring slot's PREVIOUS frame, so publishing
		// that would show a real but stale image.
		render_live_publish(eslot.canvas, eslot.nv12_ready ? eslot.nv12 : nil, timeline_frame)

		// Release: the canvas + mix writes above are visible to the encoder's
		// acquire load of produced before it encodes frame frame_idx. The ready
		// post wakes it; posting after the store orders the slot writes first.
		sync.atomic_store(&render_pipe.enc_produced, frame_idx + 1)
		sync.sema_post(&render_pipe.enc_ready)
		sync.atomic_store(&render_progress.frames_done, frame_idx + 1)
		if len(render_job.videos) > 0 {
			// Release: this frame's decode slot is no longer being read, so the
			// producer can reuse it (its slot-reuse bound is consumed >= N-1
			// before writing frame N, i.e. this frame's parity slot).
			sync.atomic_store(&render_pipe.dec_consumed, frame_idx + 1)
		}
	}
}

// render_span_cover_canvas reports whether the union of the full-range clips'
// display rects tiles the whole canvas. render_blit copies opaque bytes, so a
// pixel under a rect is fully overwritten; when every pixel is covered on every
// frame the pre-composite mem.zero is dead work and may be skipped. Only clips
// whose timeline range encloses the entire render range count — a clip absent on
// some frame leaves stale pixels behind, which is exactly what the zero exists
// to prevent. Text/subtitle rasters alpha-blend (render_text_blit) and never
// cover opaquely, so they contribute nothing here by construction.
render_span_cover_canvas :: proc(
	videos: []Render_Video_Src,
	start, nframes: i64,
	draw_w, draw_h: c.int,
) -> bool {
	rspan := start + nframes
	spans := make([]struct{a, b: c.int}, len(videos))
	defer delete(spans)
	for row: c.int = 0; row < draw_h; row += 1 {
		n := 0
		for i in 0 ..< len(videos) {
			v := &videos[i]
			if v.fw <= 0 ||
			   v.timeline_start_frame > start ||
			   v.timeline_start_frame + v.source_length_frames < rspan {
				continue
			}
			top := max(v.oy, 0)
			bottom := min(v.oy + v.rh, draw_h)
			if top > row || row >= bottom {
				continue
			}
			left := max(v.ox, 0)
			right := min(v.ox + v.rw, draw_w)
			if right <= left {
				continue
			}
			spans[n] = struct{a, b: c.int}{left, right}
			n += 1
		}
		if n == 0 {
			return false
		}
		for i := 1; i < n; i += 1 {
			key := spans[i]
			j := i - 1
			for j >= 0 && spans[j].a > key.a {
				spans[j + 1] = spans[j]
				j -= 1
			}
			spans[j + 1] = key
		}
		cov: c.int
		for i in 0 ..< n {
			if spans[i].b <= cov {
				continue
			}
			if spans[i].a > cov {
				return false
			}
			cov = spans[i].b
			if cov >= draw_w {
				break
			}
		}
		if cov < draw_w {
			return false
		}
	}
	return true
}

// render_blit_region copies a w x h sub-rect from a flat RGBA framebuffer
// (src_stride = row pixel width) into the canvas at (ox, oy), clipping both
// sides. Pure memcpy rows — used by the keyed geometry path.
render_blit_region :: proc(canvas: []u8, draw_w, draw_h: c.int, src_buf: []u8, src_stride, srcx, srcy, ox, oy, rw, rh: c.int, opacity: f32) {
	top := max(oy, 0)
	bottom := min(oy + rh, draw_h)
	left := max(ox, 0)
	right := min(ox + rw, draw_w)
	if bottom <= top || right <= left {
		return
	}
	rows := bottom - top
	cols := right - left
	srow := srcy + (top - oy)
	scol := srcx + (left - ox)
	for row in 0 ..< rows {
		src := src_buf[uint(srow + row) * uint(src_stride) * 4 + uint(scol) * 4:][:uint(cols) * 4]
		dst := canvas[uint(top + row) * uint(draw_w) * 4 + uint(left) * 4:][:uint(cols) * 4]
		blend_row(dst, src, int(cols), opacity)
	}
}

// render_eval_keyed_geom samples a keyed clip's animated geometry at
// `timeline_frame`, updates its blit rect fields, and composites it from the
// max-scale stage slot. Returns true when the clip occupied (or attempted)
// this frame; false means it was fully off-canvas and the composite skips it.
// Worker thread: v.rw/rh/ox/oy are worker-owned and rewritten every frame.
// gpu, when non-nil, composites the clip into the GPU canvas (draw in
// z-order, no readback); nil keeps the CPU renders below. The geometry is the
// same either way -- one source of the crop/dest rects for both paths.
render_eval_keyed_geom :: proc(
	v: ^Render_Video_Src,
	timeline_frame: i64,
	slot: ^Render_Blit_Slot,
	canvas: []u8,
	gpu: ^GPU_Composite,
) -> bool {
	off := geom_snap_offset(&v.geom, v.timeline_start_frame, timeline_frame)
	_, _, _, _, _, _, _, opacity, ox, oy, rw, rh, srcx, srcy, srcw, srch :=
		render_kf_geom_rect(
			&v.geom.keys,
			off,
			v.geom.base,
			render_job.width, render_job.height,
			v.source_w, v.source_h, v.fw, v.fh,
		)
	// Worker-owned, rewritten every composite frame exactly like the rect
	// above. Clamped here: a key can be dragged past 0..1, and the blend and
	// blit paths below treat the value as a direct alpha multiplier.
	v.rw, v.rh, v.ox, v.oy = rw, rh, ox, oy
	v.opacity = clamp(opacity, 0.0, 1.0)
	if ox >= render_job.width || oy >= render_job.height ||
	   ox + rw <= 0 || oy + rh <= 0 {
		return false
	}
	if gpu != nil {
		// The GPU canvas draws the crop sub-rect of the stage to the dest
		// rect in one pass -- the 1:1 case included, where blit_box's rho=1
		// single-texel fetch is byte-exact. The CPU paths below are all
		// kres_scratch round trips by comparison.
		if !gpu_composite_draw(
			gpu,
			raw_data(slot.blit), len(slot.blit), int(v.fw), int(v.fh),
			int(srcx), int(srcy), int(srcw), int(srch),
			int(ox), int(oy), int(rw), int(rh),
			v.opacity,
		) {
			return false
		}
		render_keyed_frames += 1
		render_keyed_gpu_frames += 1
		return true
	}
	// 1:1 needs no resample, and neither resampler should be asked for one.
	// This is the common case, not an edge case: a keyed scale animation spends
	// most of its frames at or near 1:1, and the keyed_export fixture measures
	// 89 of 90 frames here. The GPU path is the expensive answer to a question
	// nobody asked -- it uploads the whole 8 MB stage and downloads 8 MB back
	// (2.51 ms) to produce what a straight copy produces in 1.21 ms -- and the
	// CPU path is still paying for an intermediate kres_scratch copy that the
	// fixed-scale blit at the bottom of this proc does not need. So route it
	// there: one copy from the decoded stage straight to the canvas, and both
	// resamplers stay out of it.
	//
	// Byte-identical by construction: the 1:1 GPU resample is already gated
	// exact (gpu_probe 1600x900->1600x900 mean=0.00 peak=0), and rgba_resample
	// takes its rgba_copy_rows branch for dst == src, so this drops a
	// resample, not a resample plus a conversion.
	if int(rw) == int(srcw) && int(rh) == int(srch) {
		if render_split_timing {
			render_pipe.cp1_ns += 0
			render_pipe.cp1_n += 1
		}
		render_keyed_frames += 1
		render_blit_region(
			canvas, render_job.width, render_job.height,
			slot.blit, v.fw, srcx, srcy, ox, oy, rw, rh, v.opacity,
		)
		return true
	}
	if v.geom.scale_keyed {
		// Animated scale: the box is a resample of the whole frame (the stage
		// was decoded at max scale), so resample the crop sub-rect of the
		// stage down to the display rect.
		//
		// yuvconv.rgba_resample, not swscale. Building a sws context per frame and
		// running its generic filtered RGBA->RGBA path here cost 15.4 ms/frame
		// on a 1600x900 crop, against 0.17 ms for the same pixels 1:1 -- the
		// source of the "50x slower when scaling" symptom. The in-tree kernel
		// is 1.4 ms on that case (10.8x) and byte-comparable to swscale:
		// exact at 1:1, mean 0.11/255 at 0.5x, mean 1.16/255 at 2x
		// (swsbench's kf_vs_swscale asserts those bounds). It also allocates
		// nothing per frame, so v.kres_scratch is the only buffer needed.
		//
		// The context was never the cost -- sws_getContext/free measured at
		// 0.1-0.2 ms, so reusing one buys nothing and would just be the old
		// path with extra state.
		//
		// GPU first. This replaces only the resample: gpu_resample_into writes
		// the same kres_scratch bytes the kernel would, so the blit below, the
		// z-order, and the off-canvas clipping are all unchanged and the kernel
		// stays a drop-in fallback on the same rect. Any failure returns false
		// having written nothing, so there is no partial frame to unwind.
		if keyed_gpu_enabled {
			if g := gpu_resample_get(); g != nil {
				t_res := time.now()._nsec
				gpu_ok := gpu_resample_into(
					g,
					raw_data(slot.blit), len(slot.blit), int(v.fw), int(v.fh),
					int(srcx), int(srcy), int(srcw), int(srch),
					int(rw), int(rh),
					raw_data(v.kres_scratch), len(v.kres_scratch),
				)
				if render_split_timing {
					// The whole round trip: stage upload, resample, and the
					// download that lands back in kres_scratch. If the
					// download is not the cost, compositing straight to a
					// GPU canvas is not the fix.
					el := time.now()._nsec - t_res
					render_pipe.comp_resample_ns += el
					// Same per-geometry split as the CPU side, so the two are
					// compared frame class to frame class rather than pooled.
					if int(rw) == int(srcw) && int(rh) == int(srch) {
						render_pipe.gpu1_ns += el
						render_pipe.gpu1_n += 1
					} else {
						render_pipe.gpud_ns += el
						render_pipe.gpud_n += 1
					}
				}
				if gpu_ok {
					render_keyed_gpu_frames += 1
					render_keyed_frames += 1
					render_blit_region(
						canvas, render_job.width, render_job.height,
						v.kres_scratch, rw, 0, 0, ox, oy, rw, rh, v.opacity,
					)
					return true
				}
				render_keyed_fallbacks += 1
			}
		}
		if render_split_timing {
			// Track the range, not just the first frame: if the crop moves or
			// shrinks on later frames then the per-frame average below is not
			// comparable to a probe case that resamples a whole stage.
			area := int(srcw) * int(srch)
			if render_pipe.rect_n == 0 {
				render_pipe.rect_min_area, render_pipe.rect_max_area = area, area
			}
			render_pipe.rect_n += 1
			render_pipe.rect_min_area = min(render_pipe.rect_min_area, area)
			render_pipe.rect_max_area = max(render_pipe.rect_max_area, area)
			render_pipe.rect_w_min = min(render_pipe.rect_w_min, int(srcw))
			render_pipe.rect_w_max = max(render_pipe.rect_w_max, int(srcw))
			// The OUTPUT rect is the half that decides which branch
			// rgba_resample takes: 1:1 is a memcpy, anything smaller is the
			// box average. Reporting only the crop hid that difference.
			if render_pipe.rect_n == 1 {
				render_pipe.out_min_w, render_pipe.out_max_w = int(rw), int(rw)
				render_pipe.out_min_h, render_pipe.out_max_h = int(rh), int(rh)
			}
			render_pipe.out_min_w = min(render_pipe.out_min_w, int(rw))
			render_pipe.out_max_w = max(render_pipe.out_max_w, int(rw))
			render_pipe.out_min_h = min(render_pipe.out_min_h, int(rh))
			render_pipe.out_max_h = max(render_pipe.out_max_h, int(rh))
		}
		if render_split_timing && render_probe_rect {
			// The probe resamples the FULL stage, the exporter resamples the
			// crop sub-rect of it. Without this the two CPU numbers cannot be
			// compared, and the GPU one is worse still: it uploads the whole
			// stage whatever the crop is.
			fmt.printf("[keyed-rect] stage=%dx%d crop=%d,%d %dx%d -> out %dx%d\n",
				int(v.fw), int(v.fh), int(srcx), int(srcy), int(srcw), int(srch),
				int(rw), int(rh))
			render_probe_rect = false
		}
		// Which of the kernel's three branches this frame takes. Computed once
		// per call and used for both the CPU and GPU accounting below.
		one_to_one := int(rw) == int(srcw) && int(rh) == int(srch)
		downscaling := int(rw) <= int(srcw) && int(rh) <= int(srch)
		t_cpu := time.now()._nsec
		if !yuvconv.rgba_resample(
			raw_data(slot.blit), int(v.fw) * 4,
			int(srcx), int(srcy), int(srcw), int(srch),
			raw_data(v.kres_scratch), int(rw) * 4,
			int(rw), int(rh),
		) {
			if render_split_timing {
				el := time.now()._nsec - t_cpu
				render_pipe.cpu_resample_ns += el
				render_pipe.cpu_resample_n += 1
				if one_to_one {
					render_pipe.cp1_ns += el
					render_pipe.cp1_n += 1
				} else if downscaling {
					render_pipe.cpd_ns += el
					render_pipe.cpd_n += 1
				} else {
					render_pipe.cpu_ns += el
					render_pipe.cpu_n += 1
				}
			}
			return true
		}
		if render_split_timing {
			el := time.now()._nsec - t_cpu
			render_pipe.cpu_resample_ns += el
			render_pipe.cpu_resample_n += 1
			if one_to_one {
				render_pipe.cp1_ns += el
				render_pipe.cp1_n += 1
			} else if downscaling {
				render_pipe.cpd_ns += el
				render_pipe.cpd_n += 1
			} else {
				render_pipe.cpu_ns += el
				render_pipe.cpu_n += 1
			}
		}
		render_keyed_frames += 1
		render_blit_region(canvas, render_job.width, render_job.height, v.kres_scratch, rw, 0, 0, ox, oy, rw, rh, v.opacity)
		return true
	}
	// Scale fixed: the stage is already the box, so the crop sub-rect pixels
	// equal the display pixels — one lossless region copy.
	render_blit_region(canvas, render_job.width, render_job.height, slot.blit, v.fw, srcx, srcy, ox, oy, rw, rh, v.opacity)
	return true
}

// render_blit copies the clip's scaled frame onto the canvas, clipped to bounds.
// The slot holds the full (pre-crop) frame plus the crop geometry the producer
// resolved; crop insets select the visible
// source sub-region that fills the display box (matching the preview's UV crop).
// gpu, when non-nil, draws the same pixels into the GPU canvas; only reached
// when the job has no crop-scaled static clip (that path keeps sws bilinear),
// so both GPU branches below are 1:1 region copies, byte-exact in the
// composite contract.
// blend_row composites one RGBA row of a layer over the canvas with the layer's
// global opacity. Straight alpha, matching the GPU path's SRC_ALPHA /
// ONE_MINUS_SRC_ALPHA: out = src*a + dst*(1-a) with a = (src_alpha/255)*opacity.
// The float blend rounds like the GPU does, so preview and export agree rather
// than the CPU truncating a step lower than the hardware.
//
// opacity >= 1 stays a raw copy -- every fully-opaque layer takes this path, and
// at a == 1 the blend is exactly src, so the opaque case is untouched.
blend_row :: proc(dst, src: []u8, cols: int, opacity: f32) {
	op := clamp(opacity, 0.0, 1.0)
	if op >= 1.0 {
		copy(dst, src)
		return
	}
	if op <= 0.0 {
		return
	}
	for col in 0 ..< cols {
		s := src[uint(col) * 4:]
		d := dst[uint(col) * 4:]
		a := f32(s[3]) / 255.0 * op
		blend_pixel(d, s, a)
	}
}

// blend_pixel is the straight-alpha composite of ONE pixel: out = src*a +
// dst*(1-a), all four channels, with the alpha channel composited like the
// colour ones. `a` is the effective coverage — the source alpha times whatever
// global opacity the caller resolved.
blend_pixel :: proc(d, s: []u8, a: f32) {
	if a <= 0.0 {
		return
	}
	ia := 1.0 - a
	for ch in 0 ..< 4 {
		d[ch] = u8(math.round(clamp(f32(s[ch]) * a + f32(d[ch]) * ia, 0.0, 255.0)))
	}
}

// blend_pixel_rgb is blend_pixel over the three colour channels only, leaving
// the destination's alpha alone.
//
// The text rasterizer writes white glyphs with the coverage in alpha
// (rasterize_title_into_buffer), and the canvas is opaque, so compositing alpha
// here would compute coverage*coverage into an alpha channel nothing reads —
// and the old inline text blend wrote a hard 255 for the same reason. Sharing
// the COLOUR arithmetic is what matters: it is the part that decides the
// composite, and it is the part that used to exist twice with different
// rounding.
blend_pixel_rgb :: proc(d, s: []u8, a: f32) {
	if a <= 0.0 {
		return
	}
	ia := 1.0 - a
	for ch in 0 ..< 3 {
		d[ch] = u8(math.round(clamp(f32(s[ch]) * a + f32(d[ch]) * ia, 0.0, 255.0)))
	}
}

// render_blit copies a static clip's decoded window onto the canvas, clipped to
// bounds. The window is the region the clip can draw -- the crop window clipped
// to the canvas (render_static_src_geom) -- so it maps 1:1 onto the display
// rect and this is one region copy with no sampling. gpu, when non-nil, draws
// the same pixels into the GPU canvas.
render_blit :: proc(canvas: []u8, draw_w, draw_h: c.int, v: ^Render_Video_Src, slot: ^Render_Blit_Slot, gpu: ^GPU_Composite) {
	top := max(v.oy, 0)
	bottom := min(v.oy + v.rh, draw_h)
	left := max(v.ox, 0)
	right := min(v.ox + v.rw, draw_w)
	if bottom <= top || right <= left {
		return
	}
	rows := bottom - top
	cols := right - left
	if gpu != nil {
		if !gpu_composite_draw(
			gpu,
			raw_data(slot.blit), len(slot.blit), int(v.fw), int(v.fh),
			0, 0, int(cols), int(rows),
			int(left), int(top), int(cols), int(rows),
			v.opacity,
		) {
			return
		}
		return
	}
	for row in 0 ..< rows {
		src := slot.blit[uint(row) * uint(v.fw) * 4:][:uint(cols) * 4]
		dst := canvas[uint(top + row) * uint(draw_w) * 4 + uint(left) * 4:][:uint(cols) * 4]
		blend_row(dst, src, int(cols), v.opacity)
	}
}

// render_text_blit alpha-blends a rasterized text clip onto the canvas. text_buf
// holds the title rasterized at the BAKED font (font = 48*scale, where scale is
// the clip's sampled Scale lane), so the raster's ink already carries it. The tight ink rect [ox..ox+ow)x[oy..oy+oh) is
// scaled to the output box anchored at the clip's top-left (tx, ty) in project
// pixels, matching the preview's text box math: a UNIFORM factor
// bw0 = ow * (out_w/PREVIEW_W) scales both axes (so text is never squished by
// the project's aspect), box = bw0*scale x bh0*scale. bw is the buffer's row
// stride (the raster's own width).
//
// `opacity` is the clip's sampled Opacity lane. It resolves the effective
// coverage here and hands the composite to blend_pixel_rgb, the same colour
// arithmetic blend_row uses for video. This used to carry a private copy of the
// blend — integer alpha, a 3-channel loop, `d[ch] = (255*a + d*ia)/255` — so a
// translucent text clip and a translucent video clip rounded differently and
// neither matched the GPU preview. Two copies of one blend is how they came to
// disagree, and the comment here used to CLAIM they matched without anyone
// checking.
render_text_blit :: proc(
	canvas: []u8,
	draw_w, draw_h: c.int,
	text_buf: []u8,
	bw: int,
	ox, oy, ow, oh: int,
	// base_w/base_h are the clip's BASE ink dims at font 48 (clip.source_w/h).
	// They set the box; ow/oh are the MEASURED ink rect inside this raster and set
	// only the source sampling, so the glyphs land where the box says they should.
	base_w, base_h: c.int,
	// tx, ty are the box CENTER, the same anchor every other source uses:
	// video through cropped_box_edges, subtitles through sub_box_center. Text
	// used to pass Trans_X/Y straight through as a top-left, which made it the
	// only source whose stored transform meant something different from its
	// siblings' -- so a keyframed text transform and a keyframed video transform
	// animated around different points while reading the same two fields.
	//
	// scale is the clip's SAMPLED Scale lane. It multiplies the base dims into the
	// box; it does NOT scale the raster, which is already baked at 48*scale (that
	// is why the job's blit_scale is gone: the ink carries the scale and the box
	// gets it from the base dims, not from a second multiplication).
	tx, ty, scale: f32,
	opacity: f32,
) {
	if ow <= 0 || oh <= 0 {
		return
	}
	// A global alpha of 1 is the common case (every unkeyed, fully-opaque text
	// clip), so it takes the original integer blend below. Anything less scales
	// the glyph's coverage, matching the video path's blend_row and the GPU
	// preview's SRC_ALPHA/ONE_MINUS_SRC_ALPHA so all three sinks agree.
	op := clamp(opacity, 0.0, 1.0)
	if op <= 0.0 {
		return
	}
	// The box comes from the clip's BASE ink dims (source_w/source_h, measured at
	// font 48 and scale-independent) through the shared text_box_dims, exactly as
	// the preview derives it, with the clip's SAMPLED scale. It used to scale
	// this raster's MEASURED ink rect (ow/oh) instead, so the two boxes were
	// different shapes -- preview used the font's metric line box for height,
	// export the tight ink -- and a text clip's box was not the same rectangle on
	// both sides. ow/oh now serve only the source sampling below.
	w, h := text_box_dims(base_w, base_h, scale, f32(draw_w))
	if w <= 0 || h <= 0 {
		return
	}
	x0 := tx - w / 2
	y0 := ty - h / 2
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
			blend_pixel_rgb(d, s, f32(s[3]) / 255.0 * op)
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
	return string(render_output.path_buf[:render_output.path_len])
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
	render_output.path_len = min(len(src), len(render_output.path_buf) - 1)
	for i in 0 ..< render_output.path_len {
		render_output.path_buf[i] = u8(src[i])
	}
	render_output.path_buf[render_output.path_len] = 0
	render_output.path_set = true
}

// render_start snapshots the timeline and launches the worker thread.
// render_keyed_frames counts frames that went through the animated-scale
// (scale_keyed) resample path. VYPER_RENDER_TEST prints it so the keyed probe
// can assert the path was actually taken -- a probe that silently renders
// through the static path and reports a good time is worse than no probe.
render_keyed_frames: int

// render_keyed_gpu_frames counts the animated-scale frames the GPU resampler
// actually served, and render_keyed_fallbacks the ones it handed back. Printed
// beside render_keyed_frames so an A/B cannot silently measure the CPU kernel
// and report it as a GPU number -- which is the failure mode this whole path
// has already produced twice.
render_keyed_gpu_frames: int
render_keyed_fallbacks: int

// render_max_stage_w/h is the largest decode stage any clip was set up with,
// across every clip in the job. The max-keyed-scale stage is what made the
// reported regression pathological: a clip animating to 3x decodes a 5760x3240
// stage and then crops it, so the work is set by the PEAK of the animation and
// not by the frames actually on screen. Reporting only the canvas size hides
// that entirely, which is why the export benchmark (S1) records it per run
// instead of inferring cost from ms/frame.
//
// Worker-written at job setup, read by the render-test summary after
// poll_completed_thread has joined the worker -- the same handoff the
// render_keyed_* counters above already rely on.
render_max_stage_w, render_max_stage_h: c.int

// render_gpu_abort latches a mid-composite GPU failure (a draw or readback
// that fails AFTER the frame began) so the worker stops the export instead of
// encoding a partially-composited frame. Reset per run; only set from
// render_gpu.odin failure paths.
render_gpu_abort := false

// keyed_gpu_enabled is the A/B switch. Default on: the GPU path is the
// intended default and the CPU kernel is the fallback, not the reverse. Set
// VYPER_KEYED_GPU=0 to pin the kernel for a controlled comparison.
keyed_gpu_enabled := true

// gpu_nv12_enabled is the sibling switch for the GPU RGBA->NV12 conversion
// (S1c part 2). Default on, like the composite: the worker converts the GPU
// composite to NV12 on the GPU and the encoder skips swscale. Set
// VYPER_GPU_NV12=0 to keep the canvas readback + encoder-side swscale path --
// the CPU conversion stays the fallback for any job the GPU path cannot serve
// (CPU composite, non-NV12 encoder format), so this knob is a pin, not a
// switch that pills the feature out.
gpu_nv12_enabled := true

// Set once per run by render_worker_run; the per-clip procs below need it to
// decide whether to take the two extra timestamps, so the uninstrumented
// export path pays nothing for the counters.
render_split_timing := false

// One-shot: print the keyed crop geometry once per run, because the resample
// cost is meaningless without knowing how much of the stage it touches.
render_probe_rect := false

render_start :: proc() {
	if render_is_busy() {
		return
	}
	if !render_output.path_set || render_output.path_len == 0 {
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
	render_keyed_frames = 0
	render_keyed_gpu_frames = 0
	render_keyed_fallbacks = 0
	render_gpu_abort = false
	// Read once per run, not per clip: os lookup on a hot path is a needless
	// string compare per frame per clip.
	// The VALUE decides, not its presence. Presence-only parsing made
	// VYPER_KEYED_GPU=1 mean "off", which is the exact opposite of what it
	// reads like -- and the silent part is the problem, since the path is
	// still correct, just slower, so a run that asked for the GPU and got
	// the kernel looks like a measurement instead of a misparse. Only an
	// explicit 0 pins the kernel; anything else, including 1, leaves the GPU
	// on, so the knob cannot be set backwards.
	gpu_setting, gpu_found := os.lookup_env_alloc("VYPER_KEYED_GPU", context.temp_allocator)
	keyed_gpu_enabled = !(gpu_found && gpu_setting == "0")
	if !keyed_gpu_enabled {
		fmt.println("render: VYPER_KEYED_GPU=0 -- pinned to the CPU resample kernel")
	}
	nv12_setting, nv12_found := os.lookup_env_alloc("VYPER_GPU_NV12", context.temp_allocator)
	gpu_nv12_enabled = !(nv12_found && nv12_setting == "0")
	if !gpu_nv12_enabled {
		fmt.println("render: VYPER_GPU_NV12=0 -- pinned to encoder-side swscale")
	}

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
	// Track order, appended in the SAME walk that fills cls/txts, so the
	// compositing order is a property of the snapshot rather than a second thing
	// the compositor has to re-derive. Its entries point into cls/txts, so those
	// two are reserved before the walk: a mid-walk realloc would invalidate every
	// &cls[i] / &txts[i] pointer already recorded in vis. vis itself needs no
	// reserve -- reallocating it moves pointer values, not pointees. The bound is
	// the clips actually walked, and a clip contributes at most one of each.
	vis := [dynamic]Render_Visual{}
	subs := [dynamic]Render_Sub_Src{}
	sync_track_order()
	n_clips := 0
	for ti in timeline.track_order {
		n_clips += len(timeline.tracks[ti].clips)
	}

	// The frame rate is resolved ONCE, here, before anything snapshots it: the
	// subtitle clips built by the walk below copy it into their own struct, and
	// the worker reads it back off the job. Resolving it further down would
	// leave that snapshot reading a zero it never asked for -- the same
	// second-fallback-chain hazard as the worker deriving its own, one step
	// closer to home.
	render_job.fps = project_fps()
	render_job.fps_num, render_job.fps_den = fps_rational(render_job.fps)
	reserve(&cls, n_clips)
	reserve(&txts, n_clips)
	// vis_layers is the stack layer of each entry in vis, recorded during the
	// walk and sorted alongside it by render_order_visuals. Sized from the same
	// bound as vis itself (a clip contributes at most one entry).
	vis_layers: [dynamic]int
	reserve(&vis_layers, n_clips)
	defer delete(vis_layers)
	for w := 0; w < len(timeline.track_order); w += 1 {
		ti := timeline.track_order[w]
		tr := &timeline.tracks[ti]
		// The 1-based stack position: track_order is top-to-bottom rows, the
		// compositor walks it in reverse, so row 0 paints last (on top). Row 0 is
		// therefore layer 1, matching the preview's `layer` (preview_state.odin
		// assigns it from the same walk).
		layer := w + 1
		for i := 0; i < len(tr.clips); i += 1 {
			clip := &tr.clips[i]
			// Which job array a clip lands in is decided by render_clip_sink, the
			// one classifier, so this walk and the parity probe cannot disagree
			// about it.
			sink, ok := render_clip_sink(clip)
			if !ok {
				continue
			}
			switch sink {
			case .Video:
				append(
					&cls,
					Render_Video_Src {
						path = strings.clone_to_cstring(string(clip.path)),
						stream_index = clip.stream_index,
						source_start_frame = clip.source_start_frame,
						src_fps = clip.src_fps,
						source_length_frames = clip.source_length_frames,
						is_still = clip.is_still,
						timeline_start_frame = clip.timeline_start_frame,
						source_w = clip.source_w,
						source_h = clip.source_h,
					},
				)
				// Every visual source snapshots its geometry the same way, so a
				// keyed text clip exports animated exactly as a keyed video clip
				// does. Filling the carrier here — not per-kind — is what stops a
				// clip kind from arriving at the worker with its resting pose only.
				render_geom_snap_fill(&cls[len(cls) - 1].geom, clip)
				// An untagged union is assigned, not compound-constructed: the tag
				// IS the pointed-to type.
				visual: Render_Visual = &cls[len(cls) - 1]
				append(&vis, visual)
				append(&vis_layers, layer)
			case .Text:
				append(&txts, snapshot_text_src(clip, len(txts)))
				visual: Render_Visual = &txts[len(txts) - 1]
				append(&vis, visual)
				append(&vis_layers, layer)
			case .Sub:
				append(&subs, snapshot_sub_src(clip, f32(render_job.fps)))
			}
		}
	}
	// Order the composite stack by the SHARED rule (render_order.odin) rather
	// than by the order this walk happened to append in.
	//
	// The walk appends in track order, so sorting ascending by draw_key is a
	// no-op TODAY — which is exactly why the dependency was invisible and why
	// the export could silently disagree with the preview. It agreed by
	// coincidence: `visuals` order came from the walk's shape, not from the
	// rule, so a change to draw_key reached the preview and not this. Stating it
	// here makes the order a function of the rule instead of the loop.
	//
	// Subtitles are NOT in this list: they are pinned above everything and
	// composited in their own trailing pass (render_worker_run). draw_key is
	// what makes that pinning expressible, and SUBTITLE_PIN_KEY sits below every
	// track layer, so a subtitle's key sorts ahead of every item here.
	//
	// The layer is recorded during the walk rather than read back from the
	// finished list: once the list is sorted, its own positions no longer say
	// which track a clip came from, so deriving the key from them would be
	// circular — the sort would be sorting its own output.
	render_order_visuals(vis[:], vis_layers[:])

	// Audio is snapshotted from the committed geometry slab — the same source
	// the playback producer reads — so export and playback evaluate one gain
	// snapshot. Commit first: a video-only edit since the last audio commit
	// must not leave a stale audio set in the render.
	audio_geometry_commit()
	audio_slot := &audio_geom_state.slots[sync.atomic_load(&audio_geom_state.idx)]
	for ai in 0 ..< audio_slot.n {
		append(&auds, render_audio_src_from_chip(audio_slot, &audio_slot.chip[ai]))
	}
	render_job.visuals = vis[:]
	render_job.videos = cls[:]
	render_job.audios = auds[:]
	render_job.texts = txts[:]
	render_job.subs = subs[:]
	render_job.width = project.width
	render_job.height = project.height
	render_job.start = start_frame
	render_job.end = end_frame - 1
	render_job.nframes = end_frame - start_frame
	render_job.out_path = strings.clone_to_cstring(render_out_path())

	// Even output dimensions for yuv420p.
	if render_job.width % 2 != 0 {
		render_job.width += 1
	}
	if render_job.height % 2 != 0 {
		render_job.height += 1
	}

	// Size the live-preview mailbox to the job canvas BEFORE the worker starts:
	// the buffer is session heap, so it is allocated here on the app allocator
	// rather than from the job arena the worker swaps in.
	render_live_begin(render_job.width, render_job.height)

	// Publish job bounds, then status: the release store on status orders the
	// counter stores, so the worker's reader can never see .Rendering with stale
	// frames_total.
	sync.atomic_store(&render_progress.frames_done, 0)
	sync.atomic_store(&render_progress.frames_total, render_job.nframes)
	sync.atomic_store(&render_progress.status, u32(Render_Status.Rendering))

	render_pipe.worker = thread.create(render_worker)
	if render_pipe.worker == nil {
		set_status(.Failed, "could not start render thread")
		render_free_workbook()
		return
	}
	thread.start(render_pipe.worker)
}

// poll_completed_thread joins+destroys the worker once its status is terminal,
// then releases the main-thread snapshot (render_free_workbook). Runs every UI
// frame, but only does work on the finish transition.
poll_completed_thread :: proc() {
	if !render_is_busy() && render_pipe.worker != nil {
		// Close the live mailbox before freeing the workbook: the worker is gone
		// (destroy joins it), so nothing can publish again, and the buffer stays
		// alive for the next run.
		render_live_end()
		thread.destroy(render_pipe.worker)
		render_pipe.worker = nil
		render_free_workbook()
	}
}

// render_free_workbook releases the snapshot arrays + cloned strings that
// render_start built on the main thread. The worker never touches them after it
// returns (its job arena died with it), so this is always main-thread-only.
render_free_workbook :: proc() {
	for &v in render_job.videos {
		if v.path != nil {
			mem.delete_cstring(v.path)
		}
	}
	for &a in render_job.audios {
		if a.path != nil {
			mem.delete_cstring(a.path)
		}
		ring_destroy(&a.fifo)
	}
	for &t in render_job.texts {
		if t.name != "" {
			delete(t.name)
			t.name = ""
		}
	}
	delete(render_job.visuals)
	delete(render_job.videos)
	delete(render_job.audios)
	delete(render_job.texts)
	if render_job.subs != nil {
		delete(render_job.subs)
	}
	render_job.visuals = nil
	render_job.videos = nil
	render_job.audios = nil
	render_job.texts = nil
	render_job.subs = nil
	if render_job.out_path != nil {
		mem.delete_cstring(render_job.out_path)
		render_job.out_path = nil
	}
}

// init: default output name so Render works without picking a path.
render_init :: proc() {
	init_buf: [512]u8
	def := render_default_output_path(init_buf[:])
	render_output.path_len = len(def)
	for i in 0 ..< len(def) {
		render_output.path_buf[i] = u8(def[i])
	}
	render_output.path_buf[render_output.path_len] = 0
	render_output.path_set = true
}

render_set_out_path :: proc(s: string) {
	i := 0
	for i < len(s) && i < len(render_output.path_buf) - 1 {
		render_output.path_buf[i] = u8(s[i])
		i += 1
	}
	render_output.path_buf[i] = 0
	render_output.path_len = i
	render_output.path_set = true
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
	defer delete(parts)
	res: [2]string
	if len(parts) >= 2 {
		res[0] = parts[0]
		res[1] = parts[1]
	}
	return true, res
}

// render_project_export_env reads VYPER_PROJECT_EXPORT="<project.vyproj>|<out>":
// open a project file and export it unchanged.
//
// The reason this exists: VYPER_RENDER_TEST IMPORTS a media file, so it can
// only ever export a timeline this probe builds itself, and a self-built timeline
// is exactly what cannot show a defect that depends on the real workload. The
// audio engine's 133 mid-clip dropouts were measured on ~/sallyface.vyproj
// (12 video sources, 5 stacked audio tracks, splits) and no synthetic fixture
// reproduces them -- audio_probe, audio_rate_probe and atempo_probe all build
// their own, so the one number that decided whether the audio rework was done
// had no way to be re-measured. That is the same shape as the text-keyframe
// bug: a defect real workloads hit that the suite structurally cannot see.
render_project_export_env :: proc() -> (bool, [2]string) {
	v, _ := os.lookup_env_alloc("VYPER_PROJECT_EXPORT", context.allocator)
	if v == "" {
		return false, [2]string{}
	}
	parts := strings.split(v, "|")
	defer delete(parts)
	res: [2]string
	if len(parts) >= 2 {
		res[0] = parts[0]
		res[1] = parts[1]
	}
	return true, res
}

// render_project_export opens a project and exports it, standing in for the UI
// thread exactly as render_test_run does after its own render_start.
render_project_export :: proc(paths: [2]string) {
	if len(paths[0]) == 0 || len(paths[1]) == 0 {
		fmt.println("project-export: need VYPER_PROJECT_EXPORT=\"<project.vyproj>|<out>\"")
		os.exit(2)
	}
	// Same reason render_test_run loads the font: dispatched before main's
	// load_font_data, so exporting a text clip would read out of bounds.
	if !load_font_data() {
		fmt.println("project-export FAIL: could not load font data")
		os.exit(3)
	}
	if oerr := project_file_open(paths[0]); oerr != "" {
		fmt.println("project-export FAIL:", oerr)
		os.exit(3)
	}
	sync_track_order()
	fmt.println("project-export: opened", paths[0])
	// The grid rate, for the audit script. The project file saves frame_rate 0.0
	// to mean "inherit", so it cannot be read back from the .vyproj, and
	// deriving it from the export's sample count is circular -- the export is
	// short by exactly the tail padding the audit also measures, so a short
	// export reports a slightly-high grid and every frame->source lookup lands
	// late. The app knows its own rate; say it.
	fmt.println(
		"project-export: grid rate",
		project_fps(),
		"start",
		project.start_frame,
		"end",
		project.end_frame,
	)
	render_set_out_path(paths[1])
	render_output.overwrite = true
	render_start()
	// Stand in for the UI thread: clear the "UI drew a frame" gate the live sink
	// publishes against, then drain the mailbox so the publish path executes.
	sync.atomic_store(&render_live.shown, true)
	// A real consumer buffer, because the live mailbox is DROP-on-full: draining
	// into nil would claim frames without ever copying them, and the point of
	// standing in for the UI here is only to keep the worker from stalling on a
	// mailbox nobody reads. Sized after render_start, which is what set the
	// output dims. Job-arena ownership: freed before this returns.
	buf := make([]u8, int(render_live.w) * int(render_live.h) * 4)
	defer delete(buf)
	for render_is_busy() {
		time.sleep(50 * time.Millisecond)
		_, _, _, _ = render_live_drain(buf)
	}
	poll_completed_thread()
	fmt.println("project-export status:", render_status_text())
	st := render_status()
	if st != .Done && st != .Failed {
		fmt.println("project-export FAIL: export did not reach a terminal state")
		os.exit(3)
	}
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
	// Text clips rasterize through font_state.data, and this probe is dispatched
	// before main's load_font_data (main.odin returns here early), so the font has
	// to be loaded here or exporting any text clip reads out of bounds.
	if !load_font_data() {
		fmt.println("render-test FAIL: could not load font data")
		os.exit(3)
	}
	import_media(cstring(&test_input_buf[0]))
	// The imported video's placement and span, captured while vclip is in scope
	// for the VYPER_ZORDER text clip below. The insert there shifts the track
	// slice, so vclip cannot be read after it.
	z_place_x, z_place_y := f32(0), f32(0)
	z_span := i64(0)
	if len(timeline.tracks) > 0 && len(timeline.tracks[0].clips) > 0 {
		vclip := &timeline.tracks[0].clips[0]
		fmt.println("render-test clip markers:", vclip.markers.n)
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
		// VYPER_KEYED_SCALE="0:0.9,30:0.95,60:0.92" installs scale keyframes
		// on the first clip, which is the only thing that makes the worker
		// snapshot src.scale_keyed and route frames through the animated
		// resample path. VYPER_TX cannot reach it: a static transform takes
		// the lossless region-copy path instead.
		if kv, kv_ok := os.lookup_env_alloc("VYPER_KEYED_SCALE", context.allocator); kv_ok && kv != "" {
			for pair in strings.split(kv, ",") {
				kv2 := strings.split(pair, ":")
				if len(kv2) == 2 {
					fo, fo_ok := strconv.parse_f64(kv2[0])
					val, val_ok := strconv.parse_f64(kv2[1])
					if fo_ok && val_ok {
						kf_set_key(vclip, "scale", i32(fo), f32(val))
					}
				}
			}
		}
		// VYPER_TX="x,y,scale" overrides the first clip's transform so the
		// render can be exercised off-canvas / scaled headlessly.
		if tv, tv_ok := os.lookup_env_alloc("VYPER_TX", context.allocator); tv_ok && tv != "" {
			parts := strings.split(tv, ",")
			if len(parts) == 3 {
				vals := [3]f64{}
				for i in 0 ..< 3 {
					vals[i], _ = strconv.parse_f64(parts[i])
				}
				vclip.transform_x = f32(vals[0])
				vclip.transform_y = f32(vals[1])
				vclip.scale = f32(vals[2])
			}
		}
		z_place_x, z_place_y = vclip.transform_x, vclip.transform_y
		z_span = vclip.source_length_frames
	}
	// VYPER_ZORDER=below|above adds a TEXT clip on a track under or over the
	// video so the export's track-order compositing can be checked headlessly;
	// omitting it is the video-only baseline the other two are compared against.
	//
	// The assertion this enables is a strict one that needs no color guessing: a
	// text clip UNDER an opaque video must be completely invisible, so "below"
	// has to come out PIXEL-IDENTICAL to the baseline. The two-pass compositor
	// this replaced drew every text clip over every video regardless of track, so
	// "below" differed from the baseline and the check failed. "above" must
	// differ from the baseline, or the text was dropped rather than layered.
	//
	// Placement uses the video clip's own transform, read BEFORE the track insert
	// because inserting shifts the track slice and would dangle vclip. A Text
	// clip's transform is a TOP-LEFT anchor (unlike media, which is centered), so
	// the video's CENTER puts the text box squarely on top of the video.
	if zv, z_ok := os.lookup_env_alloc("VYPER_ZORDER", context.allocator); z_ok && zv != "" {
		if z_span <= 0 {
			fmt.println("render-test FAIL: VYPER_ZORDER set but no video clip to layer against")
			os.exit(3)
		}
		// sync_track_order FIRST: it is what turns track_order into a permutation
		// of the existing tracks, and injecting into a not-yet-synced (empty or
		// short) order produces a DUPLICATE index, which then drops the video
		// track from the export walk entirely -- a black frame that looks like a
		// compositing bug and is not one.
		sync_track_order()
		append(&timeline.tracks, Track{name = "zorder-text"})
		nt := len(timeline.tracks) - 1
		// track_order is top-to-bottom rows, and the compositor walks it in
		// reverse, so row 0 paints last (on top). Row 0 => text over video;
		// the end => text under it.
		pos := clamp(len(timeline.track_order), 0, len(timeline.track_order))
		if zv == "above" {
			pos = 0
		}
		inject_at_elem(&timeline.track_order, pos, nt)
		append(
			&timeline.tracks[nt].clips,
			Clip {
				clip_id = new_clip_id(),
				name = session_str_intern("ZORDER"),
				kind = .Text,
				generator = .Text,
				timeline_start_frame = 0,
				source_length_frames = z_span,
				// Nominal tight ink dims: setup_text_job only requires them to be
				// positive, then rasterizes the name and blits the real tight rect.
				source_w = 320,
				source_h = 96,
				transform_x = z_place_x,
				transform_y = z_place_y,
				scale = 1,
				opacity = 1,
			},
		)
		fmt.println("render-test zorder:", zv, "text row", pos)
	}
	render_set_out_path(paths[1])
	// VYPER_ENC="GPU" selects the hardware-encoder path (libx264 stays the CPU
	// default); used alongside VYPER_FRAME_TIME to split encoder-architecture
	// timings headlessly.
	if oc, oc_ok := os.lookup_env_alloc("VYPER_ENC", context.allocator); oc_ok && oc != "" {
		if oc == "GPU" {
			render_encoder_ui.choice = .GPU
		} else {
			render_encoder_ui.choice = .CPU
		}
	}
	render_output.overwrite = true // the test must write exactly the requested path
	render_start()
	// Stand in for the UI thread, and only AFTER render_start: render_live_begin
	// clears the "UI has drawn a frame" gate that publishing waits on, exactly as
	// it does for a real run. Without this the publish path never executes
	// headlessly -- including the NV12->RGBA conversion, which is the branch the
	// GPU export actually takes. The first publish always lands (the interval gate
	// is bypassed while last_ns == 0), so the checks below cannot fail merely
	// because the render was shorter than one publish interval.
	sync.atomic_store(&render_live.shown, true)
	// Draining the mailbox here is the other half of standing in for the UI.
	// Without a consumer the first publish fills it and the DROP policy refuses
	// every later frame, so a run would exercise exactly one conversion; with
	// one, the whole publish/take/drop loop runs against the real composite, and
	// the sampled pixels tell us the conversion produced image content rather
	// than a zeroed or mis-strided buffer.
	live_nonblack := false
	live_takes := 0
	// The consumer's own buffer, standing in for the GPU transfer buffer the UI
	// drains into. One allocation for the whole run: a per-frame make is exactly
	// the hot-path allocation AGENTS §1 forbids.
	live_readback := make([]u8, int(render_job.width) * int(render_job.height) * 4)
	for render_is_busy() {
		if _, _, _, live_ok := render_live_drain(live_readback); live_ok {
			live_takes += 1
			for v in live_readback {
				if v != 0 {
					live_nonblack = true
					break
				}
			}
		}
		time.sleep(50 * time.Millisecond)
	}
	delete(live_readback)
	poll_completed_thread()
	st := render_status_text()
	fmt.println("render-test status:", st)
	fmt.println("render-test keyed frames:", render_keyed_frames)
	fmt.println("render-test live preview frames taken:", live_takes)
	if live_takes == 0 {
		fmt.println("render-test FAIL: the live preview sink published no frame")
		os.exit(3)
	}
	if !live_nonblack {
		fmt.println("render-test FAIL: the live preview sink published only black frames")
		os.exit(3)
	}
	// The stage, not the canvas: a clip animating to 3x decodes a 5760x3240
	// stage and crops it, so the peak of the animation sets the cost. Printed
	// as one line so the export benchmark can scrape it per run.
	fmt.println(
		"render-test max stage:",
		render_max_stage_w,
		"x",
		render_max_stage_h,
		"canvas:",
		render_job.width,
		"x",
		render_job.height,
		"frames:",
		render_job.nframes,
	)
	fmt.println(
		"render-test gpu stage uploads:",
		gpu_stage_uploads,
	)
	fmt.println(
		"render-test keyed gpu frames:",
		render_keyed_gpu_frames,
		"cpu fallbacks:",
		render_keyed_fallbacks,
	)
	if _, keyed_req := os.lookup_env_alloc("VYPER_KEYED_SCALE", context.allocator); keyed_req && render_keyed_frames == 0 {
		fmt.println("render-test FAIL: keyed scale requested but no frame took the animated path")
		os.exit(3)
	}
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
	editor_flags.preview_proxy_enabled = false // ground truth vs the original decode path
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
	selection.track = 0
	selection.index = 0
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
	if len(timeline.tracks) < 2 || len(timeline.tracks[1].clips) == 0 {
		fmt.eprintln("preview-probe: needs a video+audio file (the A/V-glue check reads tracks[1])")
		os.exit(2)
	}
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
	selection.track = 0
	selection.index = 0
	split_clip_at_playhead()
	// Raw delete of the LEFT half (clip[0]) leaves a gap; right half stays put.
	selection.track = 0
	selection.index = 0
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
				clip_source_frame(
					slot.source_start_frame,
					slot.timeline_start_frame,
					i64(f),
					false,
					slot.src_fps,
				),
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
				expected := clip_source_frame(
					slot.source_start_frame, slot.timeline_start_frame, i64(f), false, slot.src_fps,
				)
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
	editor_flags.preview_proxy_enabled = false // ground truth vs the original decode path
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
	if len(parts) >= 3 {
		if sv, ok := strconv.parse_i64(parts[2]); ok {
			s2 = sv
		}
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
	selection.track = 0
	selection.index = 0
	playhead.frame = s1
	split_clip_at_playhead()
	// Split 2 at s2 on clip index 1 (the [s1,total) half).
	selection.track = 0
	selection.index = 1
	playhead.frame = s2
	split_clip_at_playhead()
	fmt.println("[bprobe] after splits at", s1, s2)
	boundary_probe_print_clips()
	// Raw-delete the middle [s1,s2) clip.
	selection.track = 0
	selection.index = 1
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
			expected := clip_source_frame(
				slot.source_start_frame, slot.timeline_start_frame, playhead.frame, false, slot.src_fps,
			)
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
			shown := clip_source_frame(
				slot.source_start_frame, slot.timeline_start_frame, playhead.frame, false, slot.src_fps,
			)
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
	for rp := i64(0); rp < 220; rp += 1 {
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
	for rp := i64(63); rp < 80; rp += 1 {
		playhead.frame = ph
		playhead.playing = true
		update_preview_slots()
		for s := 0; s < MAX_PREVIEW_SLOTS; s += 1 {
			slot := &preview_slots[s]
			if !slot.in_use {
				continue
			}
			expected := clip_source_frame(
				slot.source_start_frame, slot.timeline_start_frame, ph, false, slot.src_fps,
			)
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
	editor_flags.preview_proxy_enabled = false // ground truth vs the original decode path
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


// P6 encode ring: one canvas + one audio-mix buffer per slot, carved from the
// job arena (freed wholesale when the worker unwinds).
render_alloc_enc_slots :: proc() {
for i in 0 ..< RENDER_ENC_SLOTS {
	render_pipe.enc_slots[i].canvas = make([]u8, int(render_job.width) * int(render_job.height) * 4)
	// Sized for even dimensions (the GPU NV12 path's precondition); odd
	// jobs never use it -- gpu_nv12_for_run excludes them.
	render_pipe.enc_slots[i].nv12 = make([]u8, int(render_job.width) * int(render_job.height) * 3 / 2)
	render_pipe.enc_slots[i].mix = make([]f32, MAX_AUDIO_FRAME_SAMPLES * 2)
}
}

// Zero every per-run counter and timing accumulator on render_pipe. These are
// pure resets of the global pipeline state, read back by the render-test
// summary after the job, so they are grouped rather than interleaved with the
// encoder hand-off below. has_audio is latched here for the encoder thread.
render_reset_pipe_timings :: proc(has_audio: bool) {
render_pipe.enc_stop, render_pipe.enc_produced, render_pipe.enc_consumed = false, 0, 0
render_pipe.enc_has_audio = has_audio
render_pipe.enc_fail, render_pipe.enc_err_len = false, 0
render_pipe.comp_zero_ns, render_pipe.comp_resample_ns, render_pipe.comp_blit_ns = 0, 0, 0
render_pipe.comp_nv12_pass_ns, render_pipe.comp_nv12_dl_ns, render_pipe.comp_nv12_wait_ns, render_pipe.comp_nv12_cpy_ns = 0, 0, 0, 0
render_pipe.res_upload_ns, render_pipe.res_gpu_ns, render_pipe.res_download_ns = 0, 0, 0
render_pipe.res_submit_ns, render_pipe.res_wait_ns = 0, 0
render_pipe.cpu_resample_ns, render_pipe.cpu_resample_n = 0, 0
render_pipe.cp1_ns, render_pipe.cp1_n = 0, 0
render_pipe.cpd_ns, render_pipe.cpd_n = 0, 0
render_pipe.cpu_ns, render_pipe.cpu_n = 0, 0
render_pipe.rs1_ns, render_pipe.rs1_n = 0, 0
render_pipe.rsd_ns, render_pipe.rsd_n = 0, 0
render_pipe.rsu_ns, render_pipe.rsu_n = 0, 0
render_pipe.gpu1_ns, render_pipe.gpu1_n = 0, 0
render_pipe.gpud_ns, render_pipe.gpud_n = 0, 0
render_pipe.rect_n, render_pipe.rect_w_min, render_pipe.rect_w_max = 0, 1 << 30, 0
render_pipe.out_min_w, render_pipe.out_max_w = 1 << 30, 0
render_pipe.out_min_h, render_pipe.out_max_h = 1 << 30, 0
render_pipe.enc_video_ns, render_pipe.enc_audio_ns = 0, 0
render_pipe.enc_sws_ns, render_pipe.enc_upload_ns, render_pipe.enc_send_ns, render_pipe.enc_drain_ns = 0, 0, 0, 0
}
