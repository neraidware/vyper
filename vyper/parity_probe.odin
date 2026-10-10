package vyper

// ---------------------------------------------------------------------------
// Preview/export parity probe.
//
//   VYPER_PARITY_PROBE="in.vyproj|out.mp4"    check a real project file
//   VYPER_PARITY_FIXTURE="still|clip|out.mp4"  build the discriminating fixture
//
// Two invariants, because "the export matches the preview" is two claims and
// checking only one of them is how a broken project passed:
//
//  1. FRAME RATE. The export must run at the rate the frame grid is defined on
//     (project_fps), so frame N denotes the same instant in the file and on the
//     canvas. The worker used to take its rate from the FIRST VIDEO SOURCE
//     instead, which is a different question -- "what rate does this file have"
//     -- and the two agree only when that source is the grid-defining one. A
//     still image is the case that broke it: an image demuxer reports an
//     arbitrary avg_frame_rate, so a project whose first video clip was a still
//     exported at the still's rate. Everything the user could name as
//     "different" follows from that one number -- keyed values, positions and
//     clip lengths all land on a different output frame when the whole timeline
//     is retimed.
//
//  2. RESOLVED POSE. For every output frame and every visible visual clip, the
//     two evaluators must agree on scale, transform, crop, opacity and the
//     rounded destination box. This is the check that FALSIFIED a suspected
//     keyframe-offset bug: both samplers convert a timeline frame to the
//     clip-relative offset internally (keyframe_geom_sample_lane -> keyframe_sample_for),
//     so they agree, and the probe reporting agreement is what said so.
//
// The fixture mode exists because a gate needs a project that reliably breaks
// the rate chain. It imports a still FIRST (so it is videos[0]) and a video at
// a different rate second (so the grid rate comes from the video), then ASSERTS
// the still's own rate still differs from the grid. If a future ffmpeg makes
// image streams report the grid rate, that assertion fails loudly: the fixture
// has lost its teeth, and passing it would mean nothing.
//
// Exit 0 = both invariants hold, 1 = a parity failure (the report IS the
// finding), 2 = usage, 3 = the fixture, load, or export itself failed.
// ---------------------------------------------------------------------------

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:sync"
import "core:strings"
import "core:time"
import avutil "vendor/ffmpeg/avutil"
import sdl "vendor:sdl3"

// Debug-only. A probe is test scaffolding: it exists to prove something to
// `scripts/gate.sh`, never to run in a shipped binary, so a release build
// does not contain it. The entry point is gated the same way in main.odin.
when ODIN_DEBUG {

	parity_probe_fail := false
	parity_probe_hard_fail := false

	parity_probe_failf :: proc(msg: string, args: ..any) {
		parity_probe_fail = true
		fmt.println("[parity-probe] FAIL:", fmt.tprintf(msg, ..args))
	}

	// PARITY_PROBE_LANES is the property set under test, one name per lane. Bounded
	// by hand rather than by Render_Geom_Prop._COUNT because box_w/box_h are
	// derived columns with no Render_Geom_Prop of their own, and a probe that
	// allocated per frame to stay in sync would be the wrong trade. The array the
	// frame comparison fills is one wider: index PARITY_PROBE_LANES carries box_h.
	PARITY_PROBE_LANES :: 11

	parity_probe_lane_names := [PARITY_PROBE_LANES]string {
		"scale",
		"trans_x",
		"trans_y",
		"opacity",
		"crop_l",
		"crop_r",
		"crop_t",
		"crop_b",
		"box_x",
		"box_y",
		"box_w",
	}

	// parity_eps is the pose comparison tolerance. Both sides are f32 through a
	// shared evaluator, so bit equality is too strict a bar; 1e-4 in project units
	// is a ten-thousandth of a pixel at 1080p, far below anything visible, while
	// still catching a lane sampled one keyframe off.
	parity_eps :: f32(1e-4)

	// parity_probe_report prints one failing frame: the lane names with their
	// preview-minus-export deltas. Deltas rather than both values because the
	// question a reader has is "how far apart", and the magnitude is what
	// distinguishes a rounding wobble from a whole wrong keyframe.
	//
	// The lane text is assembled in a fixed array and joined once, not appended
	// into a byte buffer: fmt.bprintf returns a string, so growing one buffer
	// across lanes would allocate per lane on a per-frame path.
	parity_probe_report :: proc(clip: ^Clip, timeline_frame, off: i64, diffs: [PARITY_PROBE_LANES + 1]f32) {
		// The aprintf strings ride the frame arena, which the probe's os.exit
		// never reaches a free for -- same reason render_test_run does not free its
		// own scratch. Nothing here outlives the call that prints them.
		parts: [PARITY_PROBE_LANES + 1]string
		n := 0
		for lane in 0 ..< PARITY_PROBE_LANES + 1 {
			d := diffs[lane]
			if abs(d) <= parity_eps {
				continue
			}
			name := "box_h"
			if lane < PARITY_PROBE_LANES {
				name = parity_probe_lane_names[lane]
			}
			parts[n] = fmt.aprintf("%s %+.4f", name, d)
			n += 1
		}
		if n == 0 {
			return
		}
		parity_probe_fail = true
		fmt.println(
			"[parity-probe] FAIL clip",
			clip_name(clip),
			"frame",
			timeline_frame,
			"(clip-relative off",
			off,
			")",
			strings.join(parts[:n], "; "),
		)
	}

	// parity_probe_lanes cross-checks the two evaluators on a clip's LANE VALUES,
	// for ANY clip kind.
	//
	// This is the check that would have caught the text-keyframe defect, and it is
	// deliberately scoped to the Render_Geom_Snap carrier rather than to a clip
	// kind. It used to live inside parity_probe_frame, which took a
	// ^Render_Video_Src -- so the text and subtitle paths, which reached the worker
	// carrying only their resting transform, were never compared against anything.
	// A parity check that can only see the path that was already wired correctly
	// is not a parity check.
	//
	// Box pixels stay in parity_probe_frame because they are genuinely video-shaped
	// (a text clip's box comes from its raster's measured ink, not from source_w/h),
	// but the VALUES are what both sinks must agree on, and those are kind-agnostic.
	parity_probe_lanes :: proc(clip: ^Clip, snap: ^Render_Geom_Snap, timeline_frame: i64) {
		pv := geom_sample_clip(clip, timeline_frame)
		off := geom_snap_offset(snap, clip.timeline_start_frame, timeline_frame)
		ev := geom_snap_eval(snap, off)
		diffs: [PARITY_PROBE_LANES + 1]f32
		diffs[0] = pv[int(Render_Geom_Prop.Scale)] - ev[int(Render_Geom_Prop.Scale)]
		diffs[1] = pv[int(Render_Geom_Prop.Trans_X)] - ev[int(Render_Geom_Prop.Trans_X)]
		diffs[2] = pv[int(Render_Geom_Prop.Trans_Y)] - ev[int(Render_Geom_Prop.Trans_Y)]
		diffs[3] = pv[int(Render_Geom_Prop.Opacity)] - ev[int(Render_Geom_Prop.Opacity)]
		diffs[4] = pv[int(Render_Geom_Prop.Crop_L)] - ev[int(Render_Geom_Prop.Crop_L)]
		diffs[5] = pv[int(Render_Geom_Prop.Crop_R)] - ev[int(Render_Geom_Prop.Crop_R)]
		diffs[6] = pv[int(Render_Geom_Prop.Crop_T)] - ev[int(Render_Geom_Prop.Crop_T)]
		diffs[7] = pv[int(Render_Geom_Prop.Crop_B)] - ev[int(Render_Geom_Prop.Crop_B)]
		// The box columns belong to parity_probe_frame, which owns the box math;
		// zero here so they read as "not checked" rather than as a pass.
		diffs[8] = 0
		diffs[9] = 0
		diffs[10] = 0
		parity_probe_report(clip, timeline_frame, i64(off), diffs)
	}

	// parity_probe_frame compares one output frame's BOX across the two evaluators.
	//
	// Preview side: geom_sample_clip(clip, timeline_frame) -- the absolute frame,
	// the live clip, the live evaluator.
	// Export side: geom_sample_flat over the flat snapshot the worker was handed,
	// at the clip-relative offset -- the exact basis render_kf_geom_rect uses.
	//
	// The box lanes compare rounded output pixels, because that is what each side
	// composites: the worker draws ox/oy/rw/rh, the preview hands the GPU a quad
	// derived from the same edges. Lane VALUES are checked by parity_probe_lanes,
	// which every clip kind goes through.
	parity_probe_frame :: proc(clip: ^Clip, v: ^Render_Video_Src, timeline_frame: i64, pw, ph: f32) {
		pv := geom_sample_clip(clip, timeline_frame)
		off := geom_snap_offset(&v.geom, v.timeline_start_frame, timeline_frame)
		ev := geom_snap_eval(&v.geom, off)
		cw_e, ch_e := full_box_dims(v.source_w, v.source_h, ev[int(Render_Geom_Prop.Scale)], pw, ph)
		el, et, er, eb := cropped_box_edges(
			ev[int(Render_Geom_Prop.Trans_X)],
			ev[int(Render_Geom_Prop.Trans_Y)],
			cw_e,
			ch_e,
			ev[int(Render_Geom_Prop.Crop_L)],
			ev[int(Render_Geom_Prop.Crop_R)],
			ev[int(Render_Geom_Prop.Crop_T)],
			ev[int(Render_Geom_Prop.Crop_B)],
		)
		cw_p, ch_p := full_box_dims(
			clip.source_w,
			clip.source_h,
			pv[int(Render_Geom_Prop.Scale)],
			pw,
			ph,
		)
		pl, pt, pr, pb := cropped_box_edges(
			pv[int(Render_Geom_Prop.Trans_X)],
			pv[int(Render_Geom_Prop.Trans_Y)],
			cw_p,
			ch_p,
			pv[int(Render_Geom_Prop.Crop_L)],
			pv[int(Render_Geom_Prop.Crop_R)],
			pv[int(Render_Geom_Prop.Crop_T)],
			pv[int(Render_Geom_Prop.Crop_B)],
		)
		// The preview rounds its origin the same way the worker's setup does
		// (render.odin: v.ox = c.int(l + 0.5)).
		diffs: [PARITY_PROBE_LANES + 1]f32
		diffs[0] = pv[int(Render_Geom_Prop.Scale)] - ev[int(Render_Geom_Prop.Scale)]
		diffs[1] = pv[int(Render_Geom_Prop.Trans_X)] - ev[int(Render_Geom_Prop.Trans_X)]
		diffs[2] = pv[int(Render_Geom_Prop.Trans_Y)] - ev[int(Render_Geom_Prop.Trans_Y)]
		diffs[3] = pv[int(Render_Geom_Prop.Opacity)] - ev[int(Render_Geom_Prop.Opacity)]
		diffs[4] = pv[int(Render_Geom_Prop.Crop_L)] - ev[int(Render_Geom_Prop.Crop_L)]
		diffs[5] = pv[int(Render_Geom_Prop.Crop_R)] - ev[int(Render_Geom_Prop.Crop_R)]
		diffs[6] = pv[int(Render_Geom_Prop.Crop_T)] - ev[int(Render_Geom_Prop.Crop_T)]
		diffs[7] = pv[int(Render_Geom_Prop.Crop_B)] - ev[int(Render_Geom_Prop.Crop_B)]
		diffs[8] = f32(c.int(math.round(pl))) - f32(c.int(math.round(el)))
		diffs[9] = f32(c.int(math.round(pt))) - f32(c.int(math.round(et)))
		diffs[10] = f32(px_extent(pr - pl)) - f32(px_extent(er - el))
		// box_h is derived from the same edges with no Render_Geom_Prop of its own,
		// so it takes the one lane past the name table.
		diffs[PARITY_PROBE_LANES] = f32(px_extent(pb - pt)) - f32(px_extent(eb - et))
		parity_probe_report(clip, timeline_frame, i64(off), diffs)
	}

	// parity_probe_check_rate asserts the export rate against the grid rate, from
	// three sides: the job snapshot, the exact container rational, and the rate the
	// playhead itself advances at. It also prints the rate the first video SOURCE
	// reports, because that is the value the old chain used and seeing it differ is
	// what makes the report legible.
	parity_probe_check_rate :: proc() {
		grid := project_fps()
		fmt.println(
			"[parity-probe] rates: grid(project_fps)",
			grid,
			"playback(timeline_fps)",
			timeline_fps(),
			"job",
			render_job.fps,
			"job_rational",
			render_job.fps_num,
			"/",
			render_job.fps_den,
		)
		// A playback DIAG override in the environment would make timeline_fps()
		// disagree with the grid by design, which is not a parity failure but does
		// invalidate the comparison this probe is making. Say so instead of
		// reporting a mismatch nobody can act on.
		if playback.magic_fps > 0 {
			fmt.println(
				"[parity-probe] NOTE: VYPER_PLAYBACK_FPS is set (",
				playback.magic_fps,
				"); comparing the job against the grid rate only",
			)
		}
		if math.abs(render_job.fps - grid) > 1e-9 {
			parity_probe_failf(
				"export rate %f is not the grid rate %f -- the output is retimed against the preview",
				render_job.fps,
				grid,
			)
		}
		if render_job.fps > 0 && math.abs(render_job.fps - timeline_fps()) > 1e-9 &&
		   playback.magic_fps <= 0 {
			parity_probe_failf(
				"export rate %f does not match the playback rate %f",
				render_job.fps,
				timeline_fps(),
			)
		}
		exp_num, exp_den := fps_rational(grid)
		if render_job.fps_num != exp_num || render_job.fps_den != exp_den {
			parity_probe_failf(
				"container time base %d/%d is not the exact rational for %f (%d/%d)",
				render_job.fps_num,
				render_job.fps_den,
				grid,
				exp_num,
				exp_den,
			)
		}
		// What the old chain used, read through the same probe the importer used, so
		// the report shows the competing value rather than only asserting the chosen
		// one. Read from the file, not from dec: the worker closes the decoder and
		// zeroes those fields before the export completes, so a post-export read of
		// them reports 0/0 for every source, stills included.
		if len(render_job.videos) > 0 {
			v0 := &render_job.videos[0]
			path := strings.clone_to_cstring(string(v0.path))
			sp := probe_streams(path)
			delete(path)
			if sp.has_video && sp.video_fps_den != 0 {
				src := f64(sp.video_fps_num) / f64(sp.video_fps_den)
				fmt.println(
					"[parity-probe] first video source reports",
					src,
					"fps (still:",
					v0.is_still,
					") -- the rate the old chain used instead of the grid rate",
				)
			} else {
				fmt.println("[parity-probe] first video source reported no rate")
			}
		}
		// The user-visible consequence, stated as the duration the file will have:
		// it must be the frame count over the grid rate, or every clip length,
		// keyed value and position in the output denotes a different moment than
		// it does on the canvas.
		secs := f64(render_job.nframes) / grid
		fmt.println(
			"[parity-probe] output duration:",
			secs,
			"s for",
			render_job.nframes,
			"frames at",
			grid,
			"fps",
		)
	}

	// parity_probe_frame_content counts pixels whose colour channels are not
	// black. Alpha is deliberately not counted: an opaque black frame must read as
	// empty, or every frame looks like content.
	parity_probe_frame_content :: proc(buf: []u8) -> int {
		n := 0
		i := 0
		for i + 3 < len(buf) {
			if buf[i] > 8 || buf[i + 1] > 8 || buf[i + 2] > 8 {
				n += 1
			}
			i += 4
		}
		return n
	}

	// Parity_Probe_Drain is what the drain loop measured about the export it stood
	// in for. A struct rather than a pile of out-params because the caller wants all
	// three together, and a black export is a claim that needs its evidence
	// attached: WHICH frames were delivered, and how many of them had content.
	Parity_Probe_Drain :: struct {
		frames_drained:  int, // successful render_live_drain calls
		frames_with_content: int,
		last_nonblack:   int,
		last_frame:      i64, // timeline frame in the last drained buffer
		pixels:          int,
	}

	// parity_probe_check_output_rate asserts the rate in the FILE, not the rate in
	// the job struct.
	//
	// This distinction is not pedantry: it is the difference between a regression
	// test and a test that cannot fail. The job snapshot is written by render_start
	// before the worker starts, so asserting on it only proves render_start
	// resolved a rate -- the worker could then mux at a completely different one
	// and the assertion would still pass. It did. Restoring the old
	// source-derived chain in the worker left this probe green while the file came
	// out at the still's 25 fps instead of the grid's 30. The only thing that can
	// speak for what shipped is the container, so ask the container -- through the
	// same libavformat probe the importer uses, so this check exercises the app's
	// own demux path rather than a second opinion from the ffmpeg CLI.
	parity_probe_check_output_rate :: proc(out_path: string, grid: f64) {
		path := strings.clone_to_cstring(out_path)
		defer delete(path)
		sp := probe_streams(path)
		if !sp.has_video {
			parity_probe_failf("%s has no video stream to check", out_path)
			return
		}
		if sp.video_fps_den <= 0 {
			parity_probe_failf("%s reports no frame rate (%d/%d)", out_path, sp.video_fps_num, sp.video_fps_den)
			return
		}
		exp_num, exp_den := fps_rational(grid)
		fmt.println(
			"[parity-probe] output file reports",
			sp.video_fps_num,
			"/",
			sp.video_fps_den,
			"= expected",
			exp_num,
			"/",
			exp_den,
		)
		if sp.video_fps_num != exp_num || sp.video_fps_den != exp_den {
			parity_probe_failf(
				"%s is muxed at %d/%d but the frame grid is %f (%d/%d) -- the file is retimed against the preview",
				out_path,
				sp.video_fps_num,
				sp.video_fps_den,
				grid,
				exp_num,
				exp_den,
			)
		}
	}

	// parity_probe_check_nonblack reports whether the export actually put pixels on
	// the canvas. A project can be structurally perfect and still export nothing (a
	// layer at opacity 0, a clip with no video), and "the export is black" is an
	// outcome the user should never have to discover by opening the file: it is
	// either wrong or it is intended, and the probe cannot tell which, so it
	// reports the measurement and leaves the judgement to the run.
	parity_probe_check_nonblack :: proc(d: Parity_Probe_Drain) {
		// A sample, not a census: the live view is a throttled mailbox of the
		// composite, so it holds far fewer frames than the export encodes and its
		// count says nothing about the file's frame count. The encoded file is the
		// authority on that (scripts/gate.sh parity ffprobes it); this line only
		// reports what the mailbox happened to deliver.
		fmt.println(
			"[parity-probe] live frames sampled:",
			d.frames_drained,
			"(last was timeline frame",
			d.last_frame,
			");",
			d.frames_with_content,
			"had content; that frame:",
			d.last_nonblack,
			"of",
			d.pixels,
			"pixels non-black",
		)
		if d.frames_drained == 0 {
			fmt.println("[parity-probe] NOTE: the live mailbox delivered no frames at all")
			return
		}
		if d.frames_with_content == 0 {
			fmt.println(
				"[parity-probe] NOTE: no delivered frame had any content -- every visual clip is transparent, empty or off-canvas",
			)
		}
	}

	// parity_probe_live_visuals flattens the live timeline's visual clips in
	// track_order walk order -- the same order render_start snapshots them in, so
	// index i here is render_job.videos[i] there. Caller owns the slice.
	// Parity_Rate_Case is one row of the rate resolver's ledger: the rate a project
	// asks for, and the exact container fraction it must become.
	Parity_Rate_Case :: struct {
		fps:   f64,
		num:   c.int,
		den:   c.int,
	}

	// parity_probe_check_rate_resolver pins the mapping the whole export rests on,
	// row by row, including the NTSC rates and the inputs that must be REJECTED.
	//
	// The end-to-end fixture proves the still-first collision is fixed. It cannot
	// reach these rows: it exercises one rate through one container, and it cannot
	// ask for a NaN through a project file at all. A resolver that quietly dropped
	// the NTSC branch, or started accepting a negative rate, would leave every
	// end-to-end check green -- so the table is checked directly.
	parity_probe_check_rate_resolver :: proc() {
		accept: []Parity_Rate_Case = {
			{12, 12, 1},
			{25, 25, 1},
			{30, 30, 1},
			{60, 60, 1},
			// NTSC keeps its 1001 denominator. Rounding 23.976 to 24/1 makes the
			// export 0.1% long -- a frame lost roughly every 40 seconds -- which is
			// the kind of error nobody sees until they compare durations.
			{23.976, 24000, 1001},
			{29.97, 30000, 1001},
			{59.94, 60000, 1001},
		}
		for c in accept {
			if !project_rate_ok(c.fps) {
				parity_probe_failf("rate %f was rejected but is a valid rate", c.fps)
				continue
			}
			n, d := fps_rational(c.fps)
			if n != c.num || d != c.den {
				parity_probe_failf("rate %f became %d/%d, expected %d/%d", c.fps, n, d, c.num, c.den)
			}
		}
		// Every input that must NOT reach the rational mapper: zero and negative are
		// "no rate", and NaN/Inf are what a corrupt CBOR float decodes to. Each has to
		// come back false so project_fps falls through to the timeline rate and then
		// to 60 -- a defined outcome, never a division by zero or a NaN frame count.
		// Built by bit pattern, not by dividing: 0.0/0.0 is a trap in some
		// configurations and Inf-by-division depends on the FP environment, while
		// these two constants are exactly what a corrupt CBOR float decodes to on
		// any target.
		NAN_BITS := transmute(f64)u64(0x7ff8000000000000)
		POS_INF_BITS := transmute(f64)u64(0x7ff0000000000000)
		NEG_INF_BITS := transmute(f64)u64(0xfff0000000000000)
		reject: []f64 = {0, -0.0, -1, -29.97, NAN_BITS, POS_INF_BITS, NEG_INF_BITS}
		for r in reject {
			if project_rate_ok(r) {
				parity_probe_failf("rate %f was accepted but is not a usable rate", r)
			}
		}
		fmt.println("[parity-probe] rate resolver: 7 rates mapped, 7 invalid rates rejected")
	}

	// parity_probe_check_sample_clock pins Sample_Pos, the position currency the
	// audio engine now uses everywhere.
	//
	// Each property below is one a PLAUSIBLE regression actually breaks. The first
	// attempt at this probe asserted "exact over a long span" and passed a mutation
	// back to the float form, because the float form's error is per-call (+/-1) and
	// not cumulative -- a pure function of `frames` drifts nowhere. What the float
	// form really breaks is AGREEMENT: adjacent positions stop being exactly one
	// frame apart, which is what a fifo indexed by position quietly depends on.
	parity_probe_check_sample_clock :: proc() {
		rates := []f64{12, 24, 25, 30, 48, 50, 60, 23.976, 29.97, 59.94}

		// 1. Content position is EXACTLY the timeline boundary plus the pinned source
		//    offset -- for every frame, at every rate, from every clip offset. That
		//    decomposition IS the property: the two terms are different kinds of
		//    quantity (one follows the project rate, one is pinned to the file), and
		//    the float form this replaced added them first and truncated once, so it
		//    lost a sample wherever the sum straddled an integer.
		//
		//    Stated as a window sum it cannot be exact -- floor((f+K)x) - floor(fx)
		//    is floor(Kx) or floor(Kx)+1 by construction -- which is why this is
		//    checked against the boundary directly instead.
		for rate in rates {
			saved := project.frame_rate
			project.frame_rate = rate
			rnum, rden := fps_rational(rate)
			for start_s in ([]i64{0, 1, 7, 30, 441, 1000, 2731}) {
				offset := audio_source_start_sample(start_s, rate)
				bad := 0
				for f: i64 = 0; f < 20000; f += 1 {
					got := audio_content_sample(f, start_s, rate)
					want := sample_pos_from_frames(f, i64(rnum), i64(rden)) + offset
					if got != want {
						bad += 1
						if bad == 1 {
							parity_probe_failf(
								"rate %f start_s %d: frame %d resolved to %d, want %d (boundary %d + offset %d)",
								rate, start_s, f, got, want,
								sample_pos_from_frames(f, i64(rnum), i64(rden)), offset,
							)
						}
					}
				}
			}
			project.frame_rate = saved
		}

		// 2. The pinned source term does not move when the project rate does. This is
		//    the f0b721b bug's shape (a clip silently re-pointing into the file's
		//    silent head after a rate change), stated as an invariant so it cannot
		//    come back through a different arithmetic.
		for start_s in ([]i64{35, 441, 2731}) {
			saved := project.frame_rate
			project.frame_rate = 12
			at12 := audio_source_start_sample(start_s, 48000)
			project.frame_rate = 60
			at60 := audio_source_start_sample(start_s, 48000)
			project.frame_rate = saved
			if at12 != at60 {
				parity_probe_failf(
					"start_s %d moved with the project rate: %d at 12fps, %d at 60fps",
					start_s, at12, at60,
				)
			}
		}

		// 3. Boundary differences telescope: summing them equals the boundary. Both
		//    mixers derive spf this way and accumulate, so a floor that moved between
		//    two calls would drift here rather than at either call.
		for rate in rates {
			num, den := fps_rational(rate)
			rn, rd := i64(num), i64(den)
			sum: Sample_Pos = 0
			frames := (90 * rn / rd) * 2 + 1
			for f in 0 ..< frames {
				a := sample_pos_from_frames(f, rn, rd)
				b := sample_pos_from_frames(f + 1, rn, rd)
				if b <= a {
					parity_probe_failf("rate %f: frame %d did not advance (%d -> %d)", rate, f, a, b)
					break
				}
				sum += b - a
			}
			if want := sample_pos_from_frames(frames, rn, rd); sum != want {
				parity_probe_failf(
					"rate %f: %d differences summed to %d, want %d", rate, frames, sum, want,
				)
			}
		}

		// 4. The 29.97 alternation, named rather than left implicit. 1601/1602 is the
		//    whole reason the mixers use boundary differences instead of a rounded
		//    constant, so losing the 1001 denominator must fail here.
		alt := sample_pos_from_frames(1, 30000, 1001) - sample_pos_from_frames(0, 30000, 1001)
		if alt != 1601 {
			parity_probe_failf("29.97 fps: first frame is %d samples, expected 1601", alt)
		}
		// And the source term keeps it: a clip authored at 29.97 starts 1601/1602
		// samples per source-frame, not 1600.
		if got := audio_source_start_sample(1001, 29.97) - audio_source_start_sample(1000, 29.97); got != 1601 {
			parity_probe_failf("29.97 source term: advanced %d per frame, expected 1601", got)
		}

		// 5. decoder_pts_sample is in the same units as audio_content_sample. For a
		//    stream whose time base divides the bus rate the round trip is exact, so
		//    a bus position must survive PTS -> position -> PTS unchanged; this is
		//    the comparison the mixer makes every frame between a demand and a fifo
		//    base, and it is where the two float round-trips used to disagree by one.
		for pos in ([]Sample_Pos{0, 1, 479, 48000, 48001, 96000, 123457, 48000 * 60}) {
			pts := avutil.rescale_q(c.int64_t(pos), avutil.Rational{num = 1, den = AUDIO_BUS_RATE}, avutil.Rational{num = 1, den = AUDIO_BUS_RATE})
			if back := decoder_pts_sample(pts, avutil.Rational{num = 1, den = AUDIO_BUS_RATE}); back != pos {
				parity_probe_failf("pts round trip: %d -> %d -> %d", pos, pts, back)
			}
		}
		// 7. Where a frame is a WHOLE number of samples, EVERY frame is that many.
		//    23.976 is the case that matters: 48000*1001/24000 is exactly 2002, and
		//    the float form evaluates the first frame as 2001.9999999999998 -- so it
		//    loses a sample at the very start of a 23.976 project and wanders from
		//    there. Derived from the rate alone, so it is not circular.
		for rate in rates {
			num, den := fps_rational(rate)
			scaled := AUDIO_BUS_RATE * i64(den)
			if scaled % i64(num) != 0 {
				continue // non-integral samples-per-frame (29.97, 59.94): covered by 4
			}
			spf := scaled / i64(num)
			for f: i64 = 0; f < 5000; f += 1 {
				a := sample_pos_from_frames(f, i64(num), i64(den))
				b := sample_pos_from_frames(f + 1, i64(num), i64(den))
				if b - a != spf {
					parity_probe_failf(
						"rate %f: frame %d advanced %d samples, want exactly %d (the whole samples-per-frame)",
						rate, f, b - a, spf,
					)
					break
				}
			}
		}

		// 8. The inverse agrees with the forward function, and it is what lets the
		//    fixed-block mixer resolve a content position at an arbitrary bus sample.
		//    Checked both ways, because an inverse that is merely self-consistent is
		//    still wrong: it has to agree with the boundaries the mixers already use.
		for rate in rates {
			saved := project.frame_rate
			project.frame_rate = rate
			rnum, rden := fps_rational(rate)
			for f: i64 = 0; f < 3000; f += 1 {
				at_boundary := timeline_frame_at_sample(sample_pos_from_frames(f, i64(rnum), i64(rden)))
				if at_boundary != f {
					parity_probe_failf("rate %f: frame %d boundary resolved back to %d", rate, f, at_boundary)
					break
				}
				// One sample before the next boundary is still this frame.
				next_b := sample_pos_from_frames(f + 1, i64(rnum), i64(rden))
				if next_b > sample_pos_from_frames(f, i64(rnum), i64(rden)) + 1 {
					just_before := timeline_frame_at_sample(next_b - 1)
					if just_before != f {
						parity_probe_failf(
							"rate %f: sample %d (one before frame %d) resolved to frame %d",
							rate, next_b - 1, f + 1, just_before,
						)
						break
					}
				}
			}
			// And the round trip that matters to the mixer: for any bus sample inside
			// a frame, the content position is that frame's boundary plus the offset
			// within it. Exact, or the mix is off by a sample mid-block.
			for start_s in ([]i64{0, 441, 2731}) {
				offset := audio_source_start_sample(start_s, rate)
				for f: i64 = 0; f < 500; f += 1 {
					b0 := sample_pos_from_frames(f, i64(rnum), i64(rden))
					b1 := sample_pos_from_frames(f + 1, i64(rnum), i64(rden))
					for p in (b0 ..< b1) {
						back := timeline_frame_at_sample(p)
						want := sample_pos_from_frames(back, i64(rnum), i64(rden)) + (p - b0)
						if back != f || want != p {
							parity_probe_failf(
								"rate %f: sample %d in frame %d resolved to frame %d",
								rate, p, f, back,
							)
							f = 500
							break
						}
					}
				}
			}
			project.frame_rate = saved
		}


		fmt.println("[parity-probe] sample clock: whole-second + whole-frame ground truth, adjacent-frame exactness, pinned source term, telescoping boundaries, 1601/1602, pts units")
	}

	// parity_probe_exit is the probe's exit, and it is not a bare os.exit.
	//
	// The export brings up real resources that outlive the check: the GPU resampler
	// singleton and, headless, the SDL video subsystem behind it. main unwinds those
	// with `defer sdl.Quit()`, but os.exit skips every defer -- which is how the
	// first parity_valgrind run reported 607 bytes definitely lost through
	// gpu_resample_create, from a path no earlier gate reached. Release the GPU
	// objects BEFORE the subsystem, as SDL requires, then exit. gpu_nv12_probe does
	// the same teardown by hand for the same reason.
	parity_probe_exit :: proc(code: int) {
		gpu_resample_release()
		sdl.Quit()
		os.exit(code)
	}

	// parity_probe_live_visuals collects the live clips behind the job's sources in
	// job order, one slice per job array, so an index into the result lines up with
	// an index into render_job.videos / .texts / .subs.
	//
	// The classification is render_clip_sink — the same proc render_start walked
	// with — not a second statement of "which array does this kind go in". Two
	// hand-written classifications that happen to agree produce a probe that
	// compares the wrong clip to the wrong snapshot and reports nothing wrong.
	parity_probe_live_visuals :: proc(
		videos, texts, subs: ^[dynamic]^Clip,
	) {
		sync_track_order()
		for w := 0; w < len(timeline.track_order); w += 1 {
			tr := &timeline.tracks[timeline.track_order[w]]
			for i := 0; i < len(tr.clips); i += 1 {
				clip := &tr.clips[i]
				sink, ok := render_clip_sink(clip)
				if !ok {
					continue
				}
				switch sink {
				case .Video:
					append(videos, clip)
				case .Text:
					append(texts, clip)
				case .Sub:
					append(subs, clip)
				}
			}
		}
	}

	parity_probe_dump_state :: proc() {
		fmt.println(
			"[parity-probe] loaded",
			project.width,
			"x",
			project.height,
			"@",
			project_fps(),
			"fps, duration",
			timeline_duration(),
			"frames",
		)
		for a in media_bin.assets {
			fmt.println(
				"[parity-probe] asset",
				a.id,
				string(a.path),
				"kind",
				a.kind,
				"is_image",
				a.is_image,
				"frames",
				a.frame_count,
				"src",
				a.src_w,
				"x",
				a.src_h,
			)
		}
		for w := 0; w < len(timeline.track_order); w += 1 {
			tr := &timeline.tracks[timeline.track_order[w]]
			for i := 0; i < len(tr.clips); i += 1 {
				clip := &tr.clips[i]
				fmt.println(
					"[parity-probe] clip",
					clip_name(clip),
					"kind",
					clip.kind,
					"tstart",
					clip.timeline_start_frame,
					"len",
					clip.source_length_frames,
					"src",
					clip.source_w,
					"x",
					clip.source_h,
					"scale",
					clip.scale,
					"at",
					clip.transform_x,
					",",
					clip.transform_y,
					"opacity",
					clip.opacity,
					"keyframe_tracks",
					clip.keyframe_tracks.n,
				)
			}
		}
	}

	// parity_probe_compare walks every exported frame and cross-checks the two
	// evaluators through their own product entry points -- no reimplementation of
	// either, since a hand-copied formula would agree with itself by construction
	// and prove nothing.
	parity_probe_compare :: proc() {
		vis_v, vis_t, vis_s: [dynamic]^Clip
		parity_probe_live_visuals(&vis_v, &vis_t, &vis_s)
		// Caller owns the slices (stated on the proc), so the caller frees them. They
		// are dynamic arrays of POINTERS into the timeline's clip storage, so
		// deleting them releases the index arrays only -- no clip is touched.
		defer delete(vis_v)
		defer delete(vis_t)
		defer delete(vis_s)
		pw := f32(render_job.width)
		ph := f32(render_job.height)
		compared := 0
		// Every source's lane VALUES are compared, for every clip kind: this is the
		// check that used to cover only video, which is why a text clip could carry
		// no animation across the thread hop without anything going red.
		assert(
			len(vis_v) == len(render_job.videos) &&
				len(vis_t) == len(render_job.texts) &&
				len(vis_s) == len(render_job.subs),
			"parity probe: live clip walk and the job's source arrays disagree in length",
		)
		for frame := render_job.start; frame <= render_job.end; frame += 1 {
			for vi in 0 ..< len(render_job.videos) {
				v := &render_job.videos[vi]
				if !clip_visible_at(frame, v.timeline_start_frame, v.source_length_frames) {
					continue
				}
				compared += 1
				parity_probe_lanes(vis_v[vi], &v.geom, frame)
				parity_probe_frame(vis_v[vi], v, frame, pw, ph)
			}
			for ti in 0 ..< len(render_job.texts) {
				t := &render_job.texts[ti]
				if !clip_visible_at(frame, t.timeline_start_frame, t.source_length_frames) {
					continue
				}
				compared += 1
				parity_probe_lanes(vis_t[ti], &t.geom, frame)
			}
			for si in 0 ..< len(render_job.subs) {
				s := &render_job.subs[si]
				if !clip_visible_at(frame, s.timeline_start_frame, s.source_length_frames) {
					continue
				}
				compared += 1
				parity_probe_lanes(vis_s[si], &s.geom, frame)
			}
		}
		fmt.println(
			"[parity-probe] compared",
			compared,
			"clip-frames across",
			render_job.nframes,
			"output frames",
		)
	}

	// parity_probe_drain_until_done stands in for the UI thread until the export
	// reaches a terminal state: render_start sized the live mailbox and the worker
	// publishes into it, so somebody has to drain it or the worker only ever hits
	// the DROP overflow policy. Same reason render_test_run drains.
	//
	// Its own proc so the readback buffer's lifetime is bounded here: the caller
	// os.exit's on the way out, which would leave a defer in that scope
	// unreachable, and a probe that leaks its scratch on the way to os.exit is a
	// probe that trains the reader to ignore the ownership rules.
	parity_probe_drain_until_done :: proc(buf: []u8) -> Parity_Probe_Drain {
		d: Parity_Probe_Drain
		d.pixels = len(buf) / 4
		// Stand in for the UI thread's half of the handoff: render_live_publish
		// refuses to publish until a consumer has drawn at least one frame (the
		// `shown` flag, which gpu_draw.odin:2040 sets after its first draw). Without
		// this the worker never publishes a single frame and every measurement below
		// describes a mailbox nobody ever wrote to.
		sync.atomic_store(&render_live.shown, true)
		for render_is_busy() {
			_, _, _, ok := render_live_drain(buf)
			if ok {
				// Only a delivered frame says anything about content. The old
				// version read buf unconditionally after the loop, which reported
				// the last FAILED drain -- an untouched buffer -- as "the export is
				// black" on a file with pictures in it.
				d.frames_drained += 1
				n := parity_probe_frame_content(buf)
				d.last_nonblack = n
				if n > 0 {
					d.frames_with_content += 1
				}
			}
			time.sleep(20 * time.Millisecond)
		}
		poll_completed_thread()
		// One last drain: the loop can exit on the same poll where the final frame
		// was published, and that frame is the one worth seeing.
		f, _, _, ok := render_live_drain(buf)
		if ok {
			d.frames_drained += 1
			n := parity_probe_frame_content(buf)
			d.last_nonblack = n
			if n > 0 {
				d.frames_with_content += 1
			}
			d.last_frame = f
		}
		return d
	}

	// parity_probe_export starts the real export and runs both invariant checks.
	// Returns the process exit code.
	parity_probe_export :: proc(out_path: string) -> int {
		render_set_out_path(out_path)
		render_start()
		if render_status() != .Rendering {
			fmt.println("[parity-probe] FAIL: render did not start:", render_status_text())
			return 3
		}
		fmt.println(
			"[parity-probe] job",
			render_job.width,
			"x",
			render_job.height,
			"frames",
			render_job.nframes,
			"[",
			render_job.start,
			",",
			render_job.end,
			"] videos",
			len(render_job.videos),
			"texts",
			len(render_job.texts),
			"subs",
			len(render_job.subs),
		)
		for &v in render_job.videos {
			keys := 0
			for p in 0 ..< int(Render_Geom_Prop._COUNT) {
				keys += v.geom.keys[p].n
			}
			fmt.println(
				"[parity-probe] snapshot",
				string(v.path),
				"tstart",
				v.timeline_start_frame,
				"len",
				v.source_length_frames,
				"still",
				v.is_still,
				"stage",
				v.fw,
				"x",
				v.fh,
				"box",
				v.ox,
				",",
				v.oy,
				v.rw,
				"x",
				v.rh,
				"keyed",
				v.geom.keyed,
				"scale_keyed",
				v.geom.scale_keyed,
				"opacity_keyed",
				v.geom.opacity_keyed,
				"stage_scale",
				v.stage_scale,
				"keyframe_keys",
				keys,
				"base_scale",
				v.geom.base[int(Render_Geom_Prop.Scale)],
				"base_opacity",
				v.geom.base[int(Render_Geom_Prop.Opacity)],
			)
		}
		// Text and subtitle sources carry the same carrier, so they are dumped in the
		// same terms. A keyed flag reading false on a text clip whose preview
		// animates is exactly the signature of the animation not crossing the thread
		// hop, so it has to be visible here rather than inferable.
		for &t in render_job.texts {
			keys := 0
			for p in 0 ..< int(Render_Geom_Prop._COUNT) {
				keys += t.geom.keys[p].n
			}
			fmt.println(
				"[parity-probe] snapshot text",
				t.name,
				"tstart",
				t.timeline_start_frame,
				"len",
				t.source_length_frames,
				"keyed",
				t.geom.keyed,
				"scale_keyed",
				t.geom.scale_keyed,
				"opacity_keyed",
				t.geom.opacity_keyed,
				"keyframe_keys",
				keys,
				"base_scale",
				t.geom.base[int(Render_Geom_Prop.Scale)],
				"base_opacity",
				t.geom.base[int(Render_Geom_Prop.Opacity)],
			)
		}
		for &s in render_job.subs {
			keys := 0
			for p in 0 ..< int(Render_Geom_Prop._COUNT) {
				keys += s.geom.keys[p].n
			}
			fmt.println(
				"[parity-probe] snapshot sub",
				s.srt_id,
				"tstart",
				s.timeline_start_frame,
				"len",
				s.source_length_frames,
				"keyed",
				s.geom.keyed,
				"scale_keyed",
				s.geom.scale_keyed,
				"opacity_keyed",
				s.geom.opacity_keyed,
				"keyframe_keys",
				keys,
				"base_scale",
				s.geom.base[int(Render_Geom_Prop.Scale)],
				"base_opacity",
				s.geom.base[int(Render_Geom_Prop.Opacity)],
			)
		}
		grid := project_fps()
		parity_probe_check_rate_resolver()
		parity_probe_check_sample_clock()
		parity_probe_check_rate()
		parity_probe_compare()
		// Caller-owned readback: the drain proc used to allocate and return this,
		// which handed back a buffer its own defer had already freed. The caller
		// allocates so the free happens in a scope that can still reach it.
		buf := make([]u8, int(render_live.w) * int(render_live.h) * 4)
		defer delete(buf)
		drain := parity_probe_drain_until_done(buf)
		parity_probe_check_nonblack(drain)
		if render_status() == .Done {
			parity_probe_check_output_rate(out_path, grid)
		}
		fmt.println("[parity-probe] export status:", render_status_text())
		fmt.println("[parity-probe] keyed frames:", render_keyed_frames)
		fmt.println("[parity-probe] out:", out_path)
		if render_status() != .Done {
			return 3
		}
		if parity_probe_hard_fail {
			return 3
		}
		return parity_probe_fail ? 1 : 0
	}

	// parity_probe_run checks a project file the user already has.
	parity_probe_run :: proc(in_path, out_path: string) {
		if in_path == "" || out_path == "" {
			fmt.println("parity-probe: need VYPER_PARITY_PROBE=\"<in.vyproj>|<out.mp4>\"")
			parity_probe_exit(2)
		}
		if perr := project_file_open(in_path); perr != "" {
			fmt.println("[parity-probe] FAIL:", perr)
			parity_probe_exit(3)
		}
		parity_probe_dump_state()
		parity_probe_exit(parity_probe_export(out_path))
	}

	// parity_probe_build_fixture constructs the project that used to break the rate
	// chain: a still imported FIRST, so it is the first video source, and a video at
	// a different rate imported second, so the grid rate comes from the video.
	//
	// The still is given a keyframe and pushed off frame 0 as well, so the pose
	// comparison runs over a clip whose keyframes sit at a non-zero offset -- the
	// shape that made the sampler-offset hypothesis worth testing in the first
	// place.
	parity_probe_build_fixture :: proc(still_c, clip_c: cstring, out_path: string) {
		import_media(still_c)
		import_media(clip_c)
		if len(media_bin.assets) < 2 {
			fmt.println("[parity-probe] FAIL: fixture imports did not produce two assets")
			parity_probe_exit(3)
		}
		grid := project_fps()
		// Precondition, asserted rather than assumed: the fixture only discriminates
		// while the still's OWN reported rate differs from the grid. A future ffmpeg
		// that made image streams report a sane rate would leave this fixture unable
		// to catch the bug it exists to catch, and a gate that quietly stops testing
		// anything is worse than no gate.
		still_probe := probe_streams(still_c)
		if still_probe.has_video && still_probe.video_fps_num > 0 {
			src := f64(still_probe.video_fps_num) / f64(still_probe.video_fps_den)
			fmt.println("[parity-probe] fixture: still reports", src, "fps, grid is", grid, "fps")
			if math.abs(src - grid) < 0.001 {
				parity_probe_hard_fail = true
				fmt.println(
					"[parity-probe] FAIL: the fixture no longer discriminates -- the still reports the grid rate, so a source-derived export rate would pass. Pick a fixture whose first source rate differs.",
				)
			}
		} else {
			parity_probe_hard_fail = true
			fmt.println("[parity-probe] FAIL: the still probed as a non-video source; fixture is void")
		}
		// sync_track_order first: the edit loop below walks track_order, and an
		// unsynced order is exactly the stale-global read the export path was just
		// fixed for -- it silently iterated nothing.
		sync_track_order()
		// Push the video clip off frame 0 and key its scale, so the pose comparison
		// covers a late-starting keyed clip rather than only frame-0 geometry.
		for ti in timeline.track_order {
			for &clip in timeline.tracks[ti].clips {
				if clip.kind != .Video && clip.kind != .Image {
					continue
				}
				if clip.is_still {
					continue
				}
				clip.timeline_start_frame = 5
				keyframe_set_key(&clip, "scale", 0, 1.0)
				keyframe_set_key(&clip, "scale", 10, 0.5)
			}
		}
		// A KEYED TEXT CLIP on its own track, spanning frames the video does not, so
		// the lane comparison covers the clip kind that used to reach the worker
		// carrying only its resting pose.
		//
		// Without this the widened parity check would have nothing to say about text:
		// the fixture held no text clip, so a text source that lost every keyframe
		// on the way to the worker would still have passed. That is precisely how the
		// defect shipped — the check existed and was pointed at a path that worked.
		// Keying transform as a whole SECTION (not per-lane) is deliberate: it is the
		// packed form, the one a user's own "keyframe transform" press mints, and the
		// form the export's snapshot is most likely to mishandle.
		parity_probe_add_keyed_text()
		// Set the range so the job covers the keyed clip's whole span.
		project.start_frame = -1
		project.end_frame = -1
		parity_probe_dump_state()
		parity_probe_exit(parity_probe_export(out_path))
	}

	// parity_probe_add_keyed_text places one text clip with a keyed transform and a
	// keyed opacity on a fresh top track.
	//
	// Fresh track rather than an existing one so the fixture's text cannot land
	// UNDER a video clip and be invisible in the output — a text that composites to
	// nothing still has its lanes compared, but a fixture that only passed because
	// the pixels were covered would be a weaker test than it looks.
	//
	// The keys use a whole-transform section plus a per-lane opacity, so both
	// storage forms are in the snapshot: a packed section (mask != 0, which
	// keyframe_geom_fill_snapshot has to unpack per lane) and a scalar lane.
	parity_probe_add_keyed_text :: proc() {
		// sync_track_order FIRST: it is what turns track_order into a permutation of
		// the existing tracks, and injecting into a not-yet-synced order duplicates an
		// index -- which drops a track from the export walk entirely and looks like a
		// compositing bug rather than the stale-global read it is.
		sync_track_order()
		append(&timeline.tracks, Track{name = "parity-text"})
		nt := len(timeline.tracks) - 1
		// Injected ABOVE every existing track so the text paints last and is never
		// hidden behind a video: a text whose pixels are covered still has its lanes
		// compared, but the fixture reads weaker than it is if the text is invisible.
		inject_at_elem(&timeline.track_order, 0, nt)
		append(&timeline.tracks[nt].clips, Clip {
			clip_id = new_clip_id(),
			name = session_str_intern("KEYEDTEXT"),
			kind = .Text,
			generator = .Text,
			timeline_start_frame = 12,
			source_length_frames = 20,
			scale = 1,
			opacity = 1,
			transform_x = 40,
			transform_y = 60,
			// Nominal tight ink dims at font 48; setup_text_job rasterizes the name
			// and blits the measured rect, so these only have to be positive.
			source_w = 320,
			source_h = 96,
		})
		clip := &timeline.tracks[nt].clips[0]
		// transform as a section, which is the form a user's own "keyframe
		// transform" press mints: one track owning both axes as separate lanes.
		transform_start: [KF_GEOM_GROUP_MAX]f32
		transform_start[0] = 40
		transform_start[1] = 60
		keyframe_geom_set_group_value(clip, "transform", 0, transform_start)
		transform_end: [KF_GEOM_GROUP_MAX]f32
		transform_end[0] = 200
		transform_end[1] = 140
		keyframe_geom_set_group_value(clip, "transform", 19, transform_end)
		// opacity as its own scalar lane, so both storage forms are in the snapshot.
		keyframe_geom_set_lane_key(clip, render_geom_name(Render_Geom_Prop.Opacity), 0, 1.0)
		keyframe_geom_set_lane_key(clip, render_geom_name(Render_Geom_Prop.Opacity), 19, 0.25)
		// scale keyed as well, because scale is the one lane that is BAKED into the
		// text raster rather than applied per frame: it drives text_job_rescale, which
		// allocates a new raster and frees the stale one every frame the scale moves.
		// That is the only per-frame alloc/free the text path has, so it is the part
		// that most needs a gate -- and parity_valgrind only sees it if the fixture
		// animates scale. A fixture keying only transform would leave the re-bake
		// path entirely unexercised while still reporting a clean memcheck.
		keyframe_geom_set_lane_key(clip, render_geom_name(Render_Geom_Prop.Scale), 0, 1.0)
		keyframe_geom_set_lane_key(clip, render_geom_name(Render_Geom_Prop.Scale), 19, 1.8)
		sync_track_order()
	}

	parity_probe_env :: proc() {
		// The SDL control run, kept rather than removed: scripts/gate.sh
		// parity_valgrind measures this and subtracts it, because SDL's video
		// subsystem does not return all of its own memory on Init+Quit. Measured
		// bare, with nothing of ours running: 120 bytes definitely lost in 2 blocks
		// and 2,440 indirectly -- MORE than a full parity export leaks (72 / 535).
		// So the export path's own contribution is zero and the remainder is SDL's,
		// established by running the control rather than by deciding it looks like
		// third-party noise. Disable with VYPER_PARITY_SDL_CONTROL=0.
		if v, _ := os.lookup_env_alloc("VYPER_PARITY_SDL_CONTROL", context.temp_allocator); v == "1" {
			if !sdl.Init(sdl.INIT_VIDEO) {
				fmt.println("[parity-probe] SDL_Init(VIDEO) failed:", sdl.GetError())
				parity_probe_exit(3)
			}
			sdl.Quit()
			fmt.println("[parity-probe] control: SDL_Init(VIDEO) + SDL_Quit done")
			parity_probe_exit(0)
		}
		if v, _ := os.lookup_env_alloc("VYPER_PARITY_FIXTURE", context.allocator); v != "" {
			parts := strings.split(v, "|")
			defer delete(parts)
			if len(parts) < 3 {
				fmt.println("parity-probe: need VYPER_PARITY_FIXTURE=\"<still>|<clip>|<out.mp4>\"")
				parity_probe_exit(2)
			}
			// Text clips rasterize through font_state.data and this probe returns
			// before main's load_font_data, so a fixture with a text clip would read
			// out of bounds. Same reason render_test_run loads it.
			if !load_font_data() {
				fmt.println("[parity-probe] FAIL: could not load font data")
				parity_probe_exit(3)
			}
			// The clones are freed by this proc's normal return; the fixture body
			// cannot hold them itself, because it ends in os.exit and the compiler is
			// right to call that defer unreachable.
			// VYPER_ENC, with the same spelling and the same default as
			// render_test_run — two harnesses reaching the same switch by different
			// routes is how they drift. It exists for the memory gate: this box has no
			// hardware encoder, so every export walks h264_nvenc, h264_vaapi,
			// h264_qsv and h264_amf before reaching libx264, and each failed open is a
			// dlopen plus a device enumeration. Under memcheck that is minutes of
			// work whose result is always "no device", paid once per run.
			if oc, ok := os.lookup_env_alloc("VYPER_ENC", context.allocator); ok && oc != "" {
				if oc == "GPU" {
					render_encoder_ui.choice = .GPU
				} else {
					render_encoder_ui.choice = .CPU
				}
			}
			still_c := strings.clone_to_cstring(parts[0])
			clip_c := strings.clone_to_cstring(parts[1])
			parity_probe_build_fixture(still_c, clip_c, parts[2])
			delete(still_c)
			delete(clip_c)
			return
		}
		v, _ := os.lookup_env_alloc("VYPER_PARITY_PROBE", context.allocator)
		if v == "" {
			return
		}
		parts := strings.split(v, "|")
		defer delete(parts)
		res: [2]string
		if len(parts) >= 2 {
			res[0] = parts[0]
			res[1] = parts[1]
		}
		if !load_font_data() {
			fmt.println("[parity-probe] FAIL: could not load font data")
			parity_probe_exit(3)
		}
		parity_probe_run(res[0], res[1])
	}

}
