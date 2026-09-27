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

// Encoder candidate order per platform, most platform-appropriate first (probed
// in order; each is only accepted when a real open succeeds — see
// enc_open_video). libx264 is appended as the universal last resort.
ENC_CANDIDATES_LINUX := []cstring{"h264_nvenc", "h264_vaapi", "h264_qsv", "h264_amf"}
ENC_CANDIDATES_MACOS := []cstring{"h264_videotoolbox"}
ENC_CANDIDATES_WINDOWS := []cstring{"h264_nvenc", "h264_qsv", "h264_amf"}

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
	_COUNT,
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
	src_keys := clip.keyframe_tracks[si].keys
	li: int = 0
	for lane_prop in def.lanes {
		lane_name := kf_lane_name(lane_prop)
		assert(
			kf_track_index(clip^, lane_name) < 0,
			fmt.tprintf("lane %q coexists with its packed section %q", lane_name, sec),
		)
		append(&clip.keyframe_tracks, Kf_Track {name = strings.clone(lane_name)})
		lane := &clip.keyframe_tracks[len(clip.keyframe_tracks) - 1]
		lane.keys = make([dynamic]Keyframe, 0, len(src_keys))
		for k in src_keys {
			if v, covered := kf_lane_value(k, li); covered {
				append(&lane.keys, Keyframe {frame_off = k.frame_off, value = v, interp = k.interp})
			}
		}
		li += 1
	}
	// The section track is freed only after all fans read src_keys.
	name := clip.keyframe_tracks[si].name
	keys := clip.keyframe_tracks[si].keys
	delete(name)
	if keys != nil {
		delete(keys)
	}
	ordered_remove(&clip.keyframe_tracks, si)
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
			assert(len(clip.keyframe_tracks[ti].keys) > 0, "an empty lane track is a store invariant violation")
			for k in clip.keyframe_tracks[ti].keys {
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
				for &ck in clip.keyframe_tracks[ti].keys {
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
			tr := &clip.keyframe_tracks[ti]
			assert(len(tr.keys) > 0, "folding dropped a keyed lane")
			delete(tr.name)
			delete(tr.keys)
			ordered_remove(&clip.keyframe_tracks, ti)
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
				&clip.keyframe_tracks[si],
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
			for k in clip.keyframe_tracks[si].keys {
				if _, covered := kf_lane_value(k, li); covered {
					total += 1
				}
			}
			n = min(total, len(dst))
			di := 0
			for k in clip.keyframe_tracks[si].keys {
				if v, covered := kf_lane_value(k, li); covered {
					if di < n {
						dst[di] = Keyframe {frame_off = k.frame_off, value = v, interp = k.interp}
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
// Render_Video_Src. Filled on the UI thread at render_start; the worker owns
// it for the job and never touches the live timeline (kf_fill_snapshot).
Render_Kf_Flat :: struct {
	keys: [KF_RENDER_MAX_KEYS]Keyframe,
	n:    int,
}

Render_Video_Src :: struct {
	path:                 cstring, // owned copy, freed by the worker
	stream_index:         c.int,
	source_start_frame:   i64,
	source_length_frames: i64,
	// is_still marks a single-frame image source; every timeline frame maps to
	// source_start_frame (see media_is_image / Clip.is_still).
	is_still:             bool,
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
	// Keyed geometry (S6): when any of the 7 geometry properties is keyed,
	// geom_keyed routes the worker through per-frame evaluation and stage
	// sub-rect blitting. kf_geom is the UI-thread snapshot; keys ride with the
	// job (fixed arrays, no extra ownership). blit_sx/sy are the per-frame src
	// origin into the stage slot, recomputed by render_eval_keyed_geom each
	// composite frame (worker-owned; the producer ignores them).
	geom_keyed:          bool,
	scale_keyed:         bool,
	stage_scale:         f32,
	kf_geom:             [int(Render_Geom_Prop._COUNT)]Render_Kf_Flat,
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
	// Crop-inset resample (P4): crop_l/r/t/b select a source sub-rect of the
	// full-box blit that fills the display box. That resample is one RGBA→RGBA
	// sws.scale into a fixed scratch (SIMD bilinear), not a per-pixel scalar
	// loop. ctx is worker-owned, built at setup, freed via sws.freeContext;
	// scratch lives in the job arena (v.rw*v.rh*4).
	crop_ctx:             ^sws.Context,
	crop_scratch:         []u8,
	crop_sx, crop_sy:     c.int, // quantized source sub-rect origin (in blit px)
	crop_sw, crop_sh:     c.int, // sws source dims (== ctx src dims)
}

// Render_Blit_Slot is one frame's worth of decode output. The producer writes
// the full box + the geometry the worker needs to place it (crop region + dst),
// so the worker composite never reads the decoder (v.dec) — decoder structs are
// single-writer, owned by the producer thread alone.
Render_Blit_Slot :: struct {
	blit:   []u8, // fw*fh*4 scaled frame (crop region placed at fit_ox/oy)
	ok:     bool, // decode+scale succeeded this round; worker skips if false
	crop_w: c.int, // dec.crop_px_w the producer resolved (0 = no render crop)
	crop_h: c.int, // dec.crop_px_h
	fit_ox: c.int, // dec.fit_ox (dst placement inside the box)
	fit_oy: c.int, // dec.fit_oy
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
	bw, bh := text_buf_size_for(t.name, &render_text_font.font, &render_text_font.init, font_px)
	buf := make([]u8, bw * bh * 4)
	if len(render_text_font.setup_scratch) < text_scratch_size_for(font_px) {
		delete(render_text_font.setup_scratch)
		render_text_font.setup_scratch = make([]u8, text_scratch_size_for(font_px))
	}
	ox, oy, ow, oh := rasterize_title_into_buffer(
		t.name,
		buf,
		bw,
		bh,
		&render_text_font.font,
		&render_text_font.init,
		render_text_font.setup_scratch,
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
	bw, bh := text_buf_size_for_lines(lines, &render_text_font.font, &render_text_font.init, font_px)
	if bw <= 0 || bh <= 0 {
		return
	}
	buf := make([]u8, bw * bh * 4)
	if len(render_text_font.setup_scratch) < text_scratch_size_for(font_px) {
		delete(render_text_font.setup_scratch)
		render_text_font.setup_scratch = make([]u8, text_scratch_size_for(font_px))
	}
	ox, oy, ow, oh := rasterize_lines_into_buffer(
		lines,
		buf,
		bw,
		bh,
		&render_text_font.font,
		&render_text_font.init,
		render_text_font.setup_scratch,
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

// Render_Job is the timeline snapshot taken on the main thread when a render
// starts, so the worker never touches live timeline state: one slab per source
// kind plus the output geometry/range it renders.
Render_Job :: struct {
	videos:   []Render_Video_Src,
	audios:   []Render_Audio_Src,
	texts:    []Render_Text_Src,
	subs:     []Render_Sub_Src,
	out_path: cstring,
	width:    c.int,
	height:   c.int,
	start:    i64,
	end:      i64, // inclusive
	nframes:  i64,
}
render_job: Render_Job

// clip_full_box_dims works on ^Clip; mirrored here for snapshot structs.
// Source-relative: scale 1 is the clip's native pixel size in output pixels;
// a clip with a known source size never stretches (uniform both axes). With an
// unknown source size it falls back to the canvas box (stretch-to-fill).
render_full_box_dims :: proc(sw0, sh0: c.int, scale, pw, ph: f32) -> (f32, f32) {
	if sw0 > 0 && sh0 > 0 {
		return f32(sw0) * scale, f32(sh0) * scale
	}
	return pw * scale, ph * scale
}

// render_display_rect returns the clip's visible rect in project (output)
// pixels, honoring source aspect (letterbox) and crop insets.
render_display_rect :: proc(src: ^Render_Video_Src, PW, PH: c.int) -> (l, t, r, b: f32) {
	cw, ch := render_full_box_dims(
		src.source_w,
		src.source_h,
		src.scale,
		f32(PW),
		f32(PH),
	)
	l = src.transform_x - cw / 2 + src.crop_l * cw
	r = src.transform_x + cw / 2 - src.crop_r * cw
	t = src.transform_y - ch / 2 + src.crop_t * ch
	b = src.transform_y + ch / 2 - src.crop_b * ch
	return
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
	base_tx, base_ty, base_s, base_cl, base_cr, base_ct, base_cb: f32,
	draw_w, draw_h: c.int,
	source_w, source_h, stage_w, stage_h: c.int,
) -> (
	tx, ty, s, cl, cr, ct, cb: f32,
	ox, oy, rw, rh, srcx, srcy, srcw, srch: c.int,
) {
	tx, _ = kf_sample_keys(geom[int(Render_Geom_Prop.Trans_X)].keys[:geom[int(Render_Geom_Prop.Trans_X)].n], off, base_tx)
	ty, _ = kf_sample_keys(geom[int(Render_Geom_Prop.Trans_Y)].keys[:geom[int(Render_Geom_Prop.Trans_Y)].n], off, base_ty)
	s, _ = kf_sample_keys(geom[int(Render_Geom_Prop.Scale)].keys[:geom[int(Render_Geom_Prop.Scale)].n], off, base_s)
	cl, _ = kf_sample_keys(geom[int(Render_Geom_Prop.Crop_L)].keys[:geom[int(Render_Geom_Prop.Crop_L)].n], off, base_cl)
	cr, _ = kf_sample_keys(geom[int(Render_Geom_Prop.Crop_R)].keys[:geom[int(Render_Geom_Prop.Crop_R)].n], off, base_cr)
	ct, _ = kf_sample_keys(geom[int(Render_Geom_Prop.Crop_T)].keys[:geom[int(Render_Geom_Prop.Crop_T)].n], off, base_ct)
	cb, _ = kf_sample_keys(geom[int(Render_Geom_Prop.Crop_B)].keys[:geom[int(Render_Geom_Prop.Crop_B)].n], off, base_cb)
	cw, ch := render_full_box_dims(source_w, source_h, s, f32(draw_w), f32(draw_h))
	l := tx - cw / 2 + cl * cw
	r := tx + cw / 2 - cr * cw
	t := ty - ch / 2 + ct * ch
	b := ty + ch / 2 - cb * ch
	ox = c.int(math.round(l))
	oy = c.int(math.round(t))
	rw = max(1, c.int(r - l + 0.5))
	rh = max(1, c.int(b - t + 0.5))
	srcx = clamp(c.int(cl * f32(stage_w) + 0.5), 0, stage_w - 1)
	srcy = clamp(c.int(ct * f32(stage_h) + 0.5), 0, stage_h - 1)
	srcw = clamp(c.int(f32(stage_w) * (1.0 - cl - cr) + 0.5), 1, stage_w - srcx)
	srch = clamp(c.int(f32(stage_h) * (1.0 - ct - cb) + 0.5), 1, stage_h - srcy)
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
// with libx264 as the guaranteed last resort.
enc_encoder_candidates :: proc() -> (names: [dynamic]cstring) {
	if render_encoder_ui.choice == .CPU {
		append(&names, "libx264")
		return
	}
	when ODIN_OS == .Linux {
		for n in ENC_CANDIDATES_LINUX {
			append(&names, n)
		}
	} else when ODIN_OS == .Darwin {
		for n in ENC_CANDIDATES_MACOS {
			append(&names, n)
		}
	} else when ODIN_OS == .Windows {
		for n in ENC_CANDIDATES_WINDOWS {
			append(&names, n)
		}
	}
	append(&names, "libx264")
	return
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
enc_hw_upload_open :: proc(
	e: ^Render_Enc,
	ctx: ^avcodec.CodecContext,
	codec: ^avcodec.Codec,
	width, height: c.int,
) -> bool {
	for i: c.int = 0; ; i += 1 {
		cfg := avcodec.get_hw_config(codec, i)
		if cfg == nil {
			break
		}
		if .HW_Frames_Ctx not_in cfg.methods && .HW_Device_Ctx not_in cfg.methods {
			continue
		}
		// A config whose pixel format isn't a real format is a sw-input hint,
		// not a hw-upload target (the sw branch handles those).
		if cfg.pix_fmt == .None {
			continue
		}
		// A driver/device absence is expected and handled (we move on) but
		// libav logs it at ERROR; suppress logging for the probe window, same
		// as the decode probe does.
		probe_level := avutil.log_get_level()
		avutil.log_set_level(.Quiet)
		dev_ref: ^avutil.BufferRef
		dev_ok := avutil.hwdevice_ctx_create(&dev_ref, cfg.device_type, nil, nil, 0)
		if dev_ok != 0 && cfg.device_type == .Vaapi {
			dev_ok = avutil.hwdevice_ctx_create(&dev_ref, cfg.device_type, "/dev/dri/renderD128", nil, 0)
		}
		avutil.log_set_level(probe_level)
		if dev_ok != 0 {
			continue
		}
		frames_ref := avutil.hwframe_ctx_alloc(dev_ref)
		if frames_ref == nil {
			avutil.buffer_unref(&dev_ref)
			continue
		}
		frm := (^HwFramesContext)(frames_ref.data)
		frm.format = cfg.pix_fmt
		frm.sw_format = .NV12
		frm.width = width
		frm.height = height
		if ret := avutil.hwframe_ctx_init(frames_ref); ret < 0 {
			avutil.buffer_unref(&frames_ref)
			avutil.buffer_unref(&dev_ref)
			continue
		}
		ctx.hw_device_ctx = avutil.buffer_ref(dev_ref)
		ctx.hw_frames_ctx = avutil.buffer_ref(frames_ref)
		ctx.pix_fmt = cfg.pix_fmt
		if ret := avcodec.open2(ctx, codec, nil); ret < 0 {
			// ctx owns the refs avcodec_free_context will release; free only
			// our own duplicates. Unref'ing ctx's here and again later is a
			// double-free crash.
			avutil.buffer_unref(&frames_ref)
			avutil.buffer_unref(&dev_ref)
			continue
		}
		e.enc_hw_device = dev_ref
		e.enc_hw_frames = frames_ref
		e.enc_hw_upload = true
		return true
	}
	return false
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
	frame := avutil.frame_alloc()
	if frame == nil {
		return false
	}
	defer avutil.frame_free(&frame)
	frame.format = c.int(e.enc_sw_pix_fmt)
	frame.width = width
	frame.height = height
	for i in 0 ..< 4 {
		frame.data[i] = e.yuv_data[i]
		frame.linesize[i] = e.yuv_linesize[i]
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
		// must stay alive until the send returns — the proc-scoped defer
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

// Render_Enc_Slot is one entry of the encode ring.
RENDER_ENC_SLOTS :: 4
Render_Enc_Slot :: struct {
	canvas: []u8,
	mix:    []f32,
	spf:    int,
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
	// Sub-split of enc_video_ns for the hw-upload path probe: how much is CPU
	// RGB->NV12 sws, how much is the sw->hw surface transfer, and how much is
	// send+drain (encoder wait).
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
			if timeline_frame < v.timeline_start_frame ||
			   timeline_frame >= v.timeline_start_frame + v.source_length_frames {
				continue
			}
			// Fully off-canvas clips were never opened (v.fw == 0 in setup).
			if v.fw <= 0 {
				continue
			}
			slot := &v.blit_slots[slot_idx]
			// A still image has one source frame; map every timeline frame in
			// its span to it so the image holds instead of seeking past EOF.
			src_frame := v.source_start_frame
			if !v.is_still {
				src_frame += timeline_frame - v.timeline_start_frame
			}
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
			// Publish the crop geometry the worker's render_blit needs; the
			// resolution is decoder-side (can change on the first hardware
			// frame when the crop is dropped), so it rides out with the data.
			slot.crop_w = v.dec.crop_px_w
			slot.crop_h = v.dec.crop_px_h
			slot.fit_ox = v.dec.fit_ox
			slot.fit_oy = v.dec.fit_oy
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
	if !rend_enc_video_frame(e, slot.canvas, render_job.width, render_job.height, fi) {
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
		enc_cleanup(&e)
		for &v in render_job.videos {
			if v.crop_ctx != nil {
				sws.freeContext(v.crop_ctx)
				v.crop_ctx = nil
			}
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
			fmt.printf("[frame-time]   decode(producer)=%.2fms/f (codec=%.2fms/f scale=%.2fms/f)\n",
				f64(render_pipe.dec_ns) / 1e6 / f64(frames),
				f64(render_pipe.dec_codec_ns) / 1e6 / f64(frames),
				f64(render_pipe.dec_scale_ns) / 1e6 / f64(frames))
		}
	}

	// Prepare compositing state for each video source.
	for i in 0 ..< len(render_job.videos) {
		v := &render_job.videos[i]
		if v.geom_keyed {
			// S6 animated path: decode ONCE at a stage sized to the max scale
			// this clip reaches (resting or keyed), then per frame the
			// composite samples the seven properties and region-copies the
			// matching sub-rect of the stage (linear in `scale`, so the box is
			// a centered crop of the stage — lossless, no per-frame decode).
			// A keyed clip can move anywhere on the canvas, so it is never
			// fw-zeroed, and neither the visibility crop (the WHOLE stage must
			// be present every frame) nor the static crop resampler is built.
			stage_scale := v.scale
			for k in v.kf_geom[int(Render_Geom_Prop.Scale)].keys[:v.kf_geom[int(Render_Geom_Prop.Scale)].n] {
				if k.value.(f32) > stage_scale {
					stage_scale = k.value.(f32)
				}
			}
			v.stage_scale = max(stage_scale, 0.0001)
			scw, sch := render_full_box_dims(
				v.source_w,
				v.source_h,
				v.stage_scale,
				f32(render_job.width),
				f32(render_job.height),
			)
			v.fw = max(1, c.int(scw + 0.5))
			v.fh = max(1, c.int(sch + 0.5))
			// Seed the display rect with the resting pose; the composite
			// recomputes it per frame before every blit.
			l, t, r, b := render_display_rect(v, render_job.width, render_job.height)
			v.rw = max(1, c.int(r - l + 0.5))
			v.rh = max(1, c.int(b - t + 0.5))
			v.ox = c.int(l + 0.5)
			v.oy = c.int(t + 0.5)
			for &slot in &v.blit_slots {
				slot.blit = make([]u8, int(v.fw) * int(v.fh) * 4)
			}
			if v.scale_keyed {
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
		l, t, r, b := render_display_rect(v, render_job.width, render_job.height)
		v.rw = max(1, c.int(r - l + 0.5))
		v.rh = max(1, c.int(b - t + 0.5))
		v.ox = c.int(l + 0.5)
		v.oy = c.int(t + 0.5)
		// Decode the frame at the full (pre-crop) box size so the cropped
		// region can be sampled out of it (render_blit).
		cw, ch := render_full_box_dims(
			v.source_w,
			v.source_h,
			v.scale,
			f32(render_job.width),
			f32(render_job.height),
		)
		v.fw = max(1, c.int(cw + 0.5))
		v.fh = max(1, c.int(ch + 0.5))
		// Fully off-canvas: never drawn, so no decode at all. The frame loop
		// skips v.fw <= 0 before touching the decoder.
		if c.int(r) <= 0 || c.int(l) >= render_job.width ||
		   c.int(b) <= 0 || c.int(t) >= render_job.height {
			v.fw = 0
			v.fh = 0
			continue
		}
		// Visible rect = canvas-clipped display rect. Decode and sws-scale
		// only this region (render.odin perf brief P3) so resample work tracks
		// the pixels that are actually drawn; the region maps 1:1 to itself
		// because the box is the full frame at uniform scale. Each blit slot
		// stays the full box size so the decoder's crop-dropped fallback and
		// the uncrop paths keep working, and the crop lives in v.dec (cleared
		// by the decoder's reset when zero).
		vis_left := max(0, c.int(l + 0.5))
		vis_top := max(0, c.int(t + 0.5))
		vis_right := min(render_job.width, c.int(r + 0.5))
		vis_bottom := min(render_job.height, c.int(b + 0.5))
		box_left := v.transform_x - cw / 2
		box_top := v.transform_y - ch / 2
		box_ox := c.int(box_left + 0.5)
		box_oy := c.int(box_top + 0.5)
		visible_covers_box := vis_left <= box_ox && vis_top <= box_oy &&
			vis_right >= box_ox + v.fw && vis_bottom >= box_oy + v.fh
		if vis_right > vis_left && vis_bottom > vis_top && !visible_covers_box {
			v.dec.crop_fx0 = (f32(vis_left) - box_left) / cw
			v.dec.crop_fy0 = (f32(vis_top) - box_top) / ch
			v.dec.crop_fw = (f32(vis_right) - box_left) / cw - v.dec.crop_fx0
			v.dec.crop_fh = (f32(vis_bottom) - box_top) / ch - v.dec.crop_fy0
			v.dec.crop_dst_x = vis_left - box_ox
			v.dec.crop_dst_y = vis_top - box_oy
			v.dec.crop_dst_w = vis_right - vis_left
			v.dec.crop_dst_h = vis_bottom - vis_top
			v.dec.crop_full_w = v.fw
			v.dec.crop_full_h = v.fh
		}
		for &slot in &v.blit_slots {
			slot.blit = make([]u8, int(v.fw) * int(v.fh) * 4)
		}
		// P4: build the crop-inset resampler once. crop insets select a source
		// sub-rect of the full-box blit that fills the display box (rw x rh).
		// The near-identity crop is one SIMD bilinear sws.scale into a fixed
		// scratch, replacing the old per-pixel nearest-neighbor loop. Source
		// rect is quantized to whole blit pixels; bilinear filtering makes the
		// sub-pixel remainder a quality improvement, not a bug.
		if v.crop_l != 0 || v.crop_r != 0 || v.crop_t != 0 || v.crop_b != 0 {
			sx := int(f64(v.crop_l) * f64(v.fw) + 0.5)
			sy := int(f64(v.crop_t) * f64(v.fh) + 0.5)
			sw := int(f64(v.fw) * f64(1 - v.crop_l - v.crop_r) + 0.5)
			sh := int(f64(v.fh) * f64(1 - v.crop_t - v.crop_b) + 0.5)
			sx = clamp(sx, 0, int(v.fw) - 1)
			sy = clamp(sy, 0, int(v.fh) - 1)
			sw = clamp(sw, 1, int(v.fw) - sx)
			sh = clamp(sh, 1, int(v.fh) - sy)
			v.crop_sx, v.crop_sy, v.crop_sw, v.crop_sh = c.int(sx), c.int(sy), c.int(sw), c.int(sh)
			v.crop_ctx = sws.getContext(
				c.int(sw), c.int(sh), avutil.PixelFormat.RGBA,
				v.rw, v.rh, avutil.PixelFormat.RGBA,
				sws.Flags{.Bilinear}, nil, nil, nil,
			)
			if v.crop_ctx != nil {
				v.crop_scratch = make([]u8, int(v.rw) * int(v.rh) * 4)
			}
		}
		if !open_clip_decoder_ex(&v.dec, v.path, v.stream_index, v.fw, v.fh, false) {
			err_msg = "failed to open video source"
			fail = true
			return
		}
	}

	// A full-cover layout needs no zero fill: every canvas pixel is
	// overwritten by an opaque blit on every frame, so mem.zero in the frame
	// loop is dead work. Only clips whose range encloses the whole render
	// range are counted — a clip absent on some frame leaves stale pixels
	// behind, which is exactly why the zero exists. A geometry-keyed clip
	// ALSO defeats it: its rect moves every frame, so a stale pose could
	// leak where it was.
	any_keyed := false
	for &v in render_job.videos {
		if v.geom_keyed {
			any_keyed = true
			break
		}
	}
	skip_canvas_zero :=
		len(render_job.videos) > 0 &&
		!any_keyed &&
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

	// The output frame rate: an explicit project fps wins; otherwise it comes
	// from the first video source so the timeline frame grid (which is the
	// source's own frame indices) renders 1:1 with both the video and the 48 kHz
	// audio bus.
	rfps_num, rfps_den := c.int(60), c.int(1)
	if project.frame_rate > 0 {
		rfps_num, rfps_den = 0, 1
	} else if len(render_job.videos) > 0 {
		rfps_num = render_job.videos[0].dec.fps_num
		rfps_den = render_job.videos[0].dec.fps_den
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

	has_audio := len(render_job.audios) > 0
	if has_audio {
		for i in 0 ..< len(render_job.audios) {
			a := &render_job.audios[i]
			if !render_audio_open(a, render_job.start, rfps) {
				a.dec.opened = false
			}
		}
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
	for i in 0 ..< RENDER_ENC_SLOTS {
		render_pipe.enc_slots[i].canvas = make([]u8, int(render_job.width) * int(render_job.height) * 4)
		render_pipe.enc_slots[i].mix = make([]f32, MAX_AUDIO_FRAME_SAMPLES * 2)
	}
	render_pipe.enc_stop, render_pipe.enc_produced, render_pipe.enc_consumed = false, 0, 0
	render_pipe.enc_has_audio = has_audio
	render_pipe.enc_fail, render_pipe.enc_err_len = false, 0
	render_pipe.enc_video_ns, render_pipe.enc_audio_ns = 0, 0
	render_pipe.enc_sws_ns, render_pipe.enc_upload_ns, render_pipe.enc_send_ns, render_pipe.enc_drain_ns = 0, 0, 0, 0
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

	// Text compositing: each text clip gets a precomputed raster (baked font)
	// + blit box built once below, then alpha-blitted on the canvas each frame.
	// Built before the frame loop (titles + transforms are static for a job).
	text_jobs := make([]Render_Text_Job, max(len(render_job.texts), 1))
	for i in 0 ..< len(render_job.texts) {
		setup_text_job(&text_jobs[i], render_job.texts[i])
	}

	// Subtitle compositing: per-clip anchor (the box center to keep fixed across
	// cue changes) + a one-slot active-cue raster cache. Cues play forward in
	// population order, so a single slot per clip is a near-perfect LRU.
	sub_cues := make([]Render_Sub_Cue, max(len(render_job.subs), 1))
	sub_factor := f32(render_job.width) / f32(PREVIEW_W)
	for i in 0 ..< len(render_job.subs) {
		s := &render_job.subs[i]
		if s.source_w > 0 && s.source_h > 0 {
			s.anchor_x = s.transform_x + f32(s.source_w) * s.scale * sub_factor / 2
			s.anchor_y = s.transform_y + f32(s.source_h) * s.scale * sub_factor / 2
		} else {
			s.anchor_x = f32(render_job.width) / 2
			s.anchor_y = f32(render_job.height) / 2
		}
	}

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
		if !skip_canvas_zero {
			mem.zero(raw_data(eslot.canvas), len(eslot.canvas))
		}
		for i := len(render_job.videos) - 1; i >= 0; i -= 1 {
			v := &render_job.videos[i]
			if timeline_frame < v.timeline_start_frame ||
			   timeline_frame >= v.timeline_start_frame + v.source_length_frames {
				continue
			}
			// Fully off-canvas clips were never opened (v.fw == 0 in setup).
			if v.fw <= 0 {
				continue
			}
			slot := &v.blit_slots[slot_idx]
			if !slot.ok {
				continue
			}
			if v.geom_keyed {
				render_eval_keyed_geom(v, timeline_frame, slot, eslot.canvas)
			} else {
				render_blit(eslot.canvas, render_job.width, render_job.height, v, slot)
			}
		}
		// Composite all text clips covering this frame (after the decodable
		// clips, alpha-blended on top, matching the preview layering).
		for i := 0; i < len(render_job.texts); i += 1 {
			t := &render_job.texts[i]
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
				eslot.canvas,
				render_job.width,
				render_job.height,
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
		for i in 0 ..< len(render_job.subs) {
			s := &render_job.subs[i]
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
				eslot.canvas,
				render_job.width,
				render_job.height,
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
		if split_timing {
			now := time.now()._nsec
			composite_ns += now - loop_start
			loop_start = now
		}

		eslot.spf = 0
		if has_audio && spf > 0 {
			mix := eslot.mix
			mem.zero(raw_data(mix), len(mix) * size_of(f32))
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
			for aa in 0 ..< len(render_job.audios) {
				a := &render_job.audios[aa]
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
			// Publish the mixed PCM for the encoder thread; it owns the AAC
			// encoder + muxer, so no encode call happens here anymore.
			eslot.spf = cur_spf
		}
		if split_timing {
			audio_ns += time.now()._nsec - loop_start
		}

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
render_blit_region :: proc(canvas: []u8, draw_w, draw_h: c.int, src_buf: []u8, src_stride, srcx, srcy, ox, oy, rw, rh: c.int) {
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
		copy(dst, src)
	}
}

// render_eval_keyed_geom samples a keyed clip's animated geometry at
// `timeline_frame`, updates its blit rect fields, and composites it from the
// max-scale stage slot. Returns true when the clip occupied (or attempted)
// this frame; false means it was fully off-canvas and the composite skips it.
// Worker thread: v.rw/rh/ox/oy are worker-owned and rewritten every frame.
render_eval_keyed_geom :: proc(
	v: ^Render_Video_Src,
	timeline_frame: i64,
	slot: ^Render_Blit_Slot,
	canvas: []u8,
) -> bool {
	off := i32(timeline_frame - v.timeline_start_frame)
	_, _, _, _, _, _, _, ox, oy, rw, rh, srcx, srcy, srcw, srch :=
		render_kf_geom_rect(
			&v.kf_geom,
			off,
			v.transform_x, v.transform_y, v.scale,
			v.crop_l, v.crop_r, v.crop_t, v.crop_b,
			render_job.width, render_job.height,
			v.source_w, v.source_h, v.fw, v.fh,
		)
	v.rw, v.rh, v.ox, v.oy = rw, rh, ox, oy
	if ox >= render_job.width || oy >= render_job.height ||
	   ox + rw <= 0 || oy + rh <= 0 {
		return false
	}
	if v.scale_keyed {
		// Animated scale: the box is a resample of the whole frame (the stage
		// was decoded at max scale), so resample the crop sub-rect of the
		// stage down to the display rect.
		ctx := sws.getContext(
			srcw, srch, avutil.PixelFormat.RGBA,
			rw, rh, avutil.PixelFormat.RGBA,
			sws.Flags{.Bilinear}, nil, nil, nil,
		)
		if ctx == nil {
			return true
		}
		defer sws.freeContext(ctx)
		src_ptr := cast([^]u8)(uintptr(raw_data(slot.blit)) + uintptr((int(srcy) * int(v.fw) + int(srcx)) * 4))
		dst_ptr := raw_data(v.kres_scratch)
		sln: [1][^]u8 = {src_ptr}
		ls:  [4]c.int = {c.int(v.fw) * 4, 0, 0, 0}
		dln: [4]c.int = {c.int(rw) * 4, 0, 0, 0}
		dsln: [1][^]u8 = {dst_ptr}
		if sws.scale(
			ctx,
			cast([^][^]u8)&sln[0],
			cast([^]c.int)&ls[0],
			0, srch,
			cast([^][^]u8)&dsln[0],
			cast([^]c.int)&dln[0],
		) < 0 {
			return true
		}
		render_blit_region(canvas, render_job.width, render_job.height, v.kres_scratch, rw, 0, 0, ox, oy, rw, rh)
		return true
	}
	// Scale fixed: the stage is already the box, so the crop sub-rect pixels
	// equal the display pixels — one lossless region copy.
	render_blit_region(canvas, render_job.width, render_job.height, slot.blit, v.fw, srcx, srcy, ox, oy, rw, rh)
	return true
}

// render_blit copies the clip's scaled frame onto the canvas, clipped to bounds.
// The slot holds the full (pre-crop) frame plus the crop geometry the producer
// resolved; crop insets select the visible
// source sub-region that fills the display box (matching the preview's UV crop).
render_blit :: proc(canvas: []u8, draw_w, draw_h: c.int, v: ^Render_Video_Src, slot: ^Render_Blit_Slot) {
	top := max(v.oy, 0)
	bottom := min(v.oy + v.rh, draw_h)
	left := max(v.ox, 0)
	right := min(v.ox + v.rw, draw_w)
	if bottom <= top || right <= left {
		return
	}
	if slot.crop_w > 0 && slot.crop_h > 0 {
		// Render-path P3: the decoder already scaled only the visible region
		// into the full box at fit_ox/oy (see Render_Video_Src setup), so this
		// is a straight region copy — no sampling, matching the sws bilinear
		// crop 1:1 on the region.
		scol := slot.fit_ox
		srow := slot.fit_oy
		rows := bottom - top
		cols := right - left
		for row in 0 ..< rows {
			src := slot.blit[uint(srow + row) * uint(v.fw) * 4 + uint(scol) * 4:][:uint(cols) * 4]
			dst := canvas[uint(top + row) * uint(draw_w) * 4 + uint(left) * 4:][:uint(cols) * 4]
			copy(dst, src)
		}
		return
	}
	if v.crop_l == 0 && v.crop_r == 0 && v.crop_t == 0 && v.crop_b == 0 {
		scol := left - v.ox
		srow := top - v.oy
		rows := bottom - top
		cols := right - left
		for row in 0 ..< rows {
			src := slot.blit[uint(srow + row) * uint(v.fw) * 4 + uint(scol) * 4:][:uint(cols) * 4]
			dst := canvas[uint(top + row) * uint(draw_w) * 4 + uint(left) * 4:][:uint(cols) * 4]
			copy(dst, src)
		}
		return
	}
	// Cropped (P4): crop insets select source sub-rect
	// [crop_sx, crop_sy) -> [crop_sx+crop_sw, crop_sy+crop_sh) of the full-box
	// blit, scaled to fill the display box. One SIMD bilinear sws.scale into
	// the fixed scratch replaces the old per-pixel nearest-neighbor sampler;
	// bilinear order is the intended quality upgrade. The dst is the canvas-
	// clipped intersection copied out of the full display-box scratch.
	if v.crop_ctx == nil {
		// Degenerate crop: insets collapse the region (clip invisible).
		return
	}
	src_ptr := cast([^]u8)(uintptr(raw_data(slot.blit)) +
		uintptr((int(v.crop_sy) * int(v.fw) + int(v.crop_sx)) * 4))
	dst_ptr := raw_data(v.crop_scratch)
	sln: [1][^]u8 = {src_ptr}
	ls:  [4]c.int = {c.int(v.fw) * 4, 0, 0, 0}
	dln: [4]c.int = {c.int(v.rw) * 4, 0, 0, 0}
	dsln: [1][^]u8 = {dst_ptr}
	if ret := sws.scale(
		v.crop_ctx,
		cast([^][^]u8)&sln[0],
		cast([^]c.int)&ls[0],
		0, v.crop_sh,
		cast([^][^]u8)&dsln[0],
		cast([^]c.int)&dln[0],
	); ret < 0 {
		return
	}
	scol := left - v.ox
	srow := top - v.oy
	rows := bottom - top
	cols := right - left
	for row in 0 ..< rows {
		src := v.crop_scratch[uint(srow + row) * uint(v.rw) * 4 + uint(scol) * 4:][:uint(cols) * 4]
		dst := canvas[uint(top + row) * uint(draw_w) * 4 + uint(left) * 4:][:uint(cols) * 4]
		copy(dst, src)
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
						is_still = clip.is_still,
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
				// S6: snapshot the seven geometry key tracks flat so the
				// worker can evaluate them per frame (UI thread, safe to read
				// the live clip). geom_keyed routes through the animated path.
				src := &cls[len(cls) - 1]
				for pi in 0 ..< int(Render_Geom_Prop._COUNT) {
					p := Render_Geom_Prop(pi)
					slot := &src.kf_geom[int(p)]
					slot.n, _ = kf_geom_fill_snapshot(clip, render_geom_name(p), slot.keys[:])
					if slot.n > 0 {
						src.geom_keyed = true
						if p == Render_Geom_Prop.Scale {
							src.scale_keyed = true
						}
					}
				}
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
	delete(render_job.videos)
	delete(render_job.audios)
	delete(render_job.texts)
	if render_job.subs != nil {
		delete(render_job.subs)
	}
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
