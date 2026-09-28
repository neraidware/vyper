#!/usr/bin/env bash
# Gate targets for AGENTS.md §10: every build/profiling invocation lives here,
# so nobody has to remember a flag combination (or type it by hand and get it
# subtly wrong). Run from the repo root: scripts/gate.sh <target>.
set -uo pipefail

# Absolute path to this script, so target_all can re-invoke sibling targets
# regardless of how it was called or what the cwd is.
SELF=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")

# The probe entry point. Headless: simulates the frame loop and runs the
# layout/geometry/ownership asserts, then exits.
PROBE_ENV="VYPER_UI_PROBE=1"

# Valgrind's exit code reflects FFmpeg and the Odin runtime, which report errors
# this program does not own. The invariant that matters is the one the memory
# model in AGENTS.md §1 actually claims, so the target asserts THAT instead of
# propagating a number that is always 99.
VALGRIND_KNOWN_NOISE="ERROR SUMMARY"

target_check() {
	nix develop -c odin check . -strict-style -vet-using-param -vet-using-stmt
}

# Shader compilation is a build step, not a thing you remember to do by hand.
# The SPVs are #load-ed into the binary at compile time, so editing a .frag and
# rebuilding without recompiling it silently keeps the OLD shader and the run
# reports the previous shader's results as if they were the new one. That is not
# hypothetical: it happened here, and it produced a measurement that was
# confidently wrong. Anything that builds the binary compiles shaders first.
target_shaders() {
	nix develop -c sh -c '
		set -e
		# Every stage the binary #loads, at the same target-env flake.nix uses.
		# All of them are plain Vulkan 1.0 / SPIR-V 1.0: the resample shaders were
		# originally built --target-env vulkan1.1, which raises the SPIR-V version
		# word to 1.3 for an identical instruction stream and would make a Vulkan
		# 1.0 device fail to create the pipeline now that preview binds the same
		# resample shader the export path uses.
		# The completeness check below exists because this list drifted once: it
		# held only the blit trio, so editing preview.frag and running any target
		# measured the OLD SPIR-V and reported it as the new one -- the exact
		# failure the comment above warns about. A new shader that is not listed
		# here fails the build rather than being silently skipped.
		set -- \
			shaders/rounded_rect.vert \
			shaders/rounded_rect.frag \
			shaders/quad.vert \
			shaders/text.frag \
			shaders/blit_box.frag \
			shaders/blit_lod.frag
		for src in "$@"; do
			glslangValidator -V "$src" -o "$src.spv"
		done
		for src in shaders/*.vert shaders/*.frag; do
			found=
			for want in "$@"; do
				if [ "$src" = "$want" ]; then
					found=1
					break
				fi
			done
			if [ -z "$found" ]; then
				echo "target_shaders: $src is not in the list -- add it" >&2
				exit 1
			fi
		done
	'
}

target_build() {
	target_shaders
	nix develop -c odin build . -debug -vet-style -vet-semicolon -out:vyper
}

# Every target that runs ./vyper must call this first.
#
# The stale-SPIR-V hazard above has a twin that is worse, because it is silent:
# these targets do NOT build, they only check that ./vyper exists. Editing a
# source and re-running one therefore measures the PREVIOUS binary and reports
# it as the new one. That is not hypothetical either -- a probe failure here was
# chased as a pre-existing regression and then as a clean pass, when both runs
# were the same stale executable and only a real rebuild told the truth.
#
# Fails loudly rather than rebuilding: an automatic rebuild hides "I meant to
# measure the previous build", and a wrong measurement reported confidently is
# the exact failure this file already exists to prevent.
require_fresh_binary() {
	local target_name=$1
	if [ ! -x ./vyper ]; then
		echo "$target_name: ./vyper missing -- run scripts/gate.sh build" >&2
		return 1
	fi
	# -nt is "newer than": any source or SPIR-V newer than the binary means the
	# binary cannot reflect the tree. Includes the SPVs because a .frag edit
	# changes the binary only after target_shaders + a rebuild.
	local stale
	stale=$(find . -maxdepth 1 -name '*.odin' -newer ./vyper -print -quit)
	if [ -z "$stale" ]; then
		stale=$(find shaders -name '*.spv' -newer ./vyper -print -quit)
	fi
	if [ -n "$stale" ]; then
		echo "$target_name: ./vyper is older than $stale" >&2
		echo "$target_name: this would measure the PREVIOUS binary -- run scripts/gate.sh build" >&2
		return 1
	fi
}

# swscale/resample microbenchmarks. Separate package (swsbench) so it can link
# the vendored FFmpeg without dragging in the whole app; it exists to keep
# claims about scaler cost measured rather than remembered.
target_bench() {
	# The script runs without `set -e`, so a failed build would otherwise fall
	# through to executing the previous binary and reporting stale numbers as
	# current — which is worse than no benchmark, because it looks like data.
	if ! nix develop -c odin build swsbench -out:bin_swsbench \
		-microarch:native -o:aggressive -no-bounds-check; then
		echo "bench: build failed" >&2
		return 1
	fi
	./bin_swsbench
}

# Headless GPU export probe. Separate from target_probe because it exits with
# the probe's own code and needs a real GPU device -- a driver without the
# required capabilities must degrade to the CPU path, not fail the build, so
# the probe reports "falling back to CPU" and the target still passes when
# every case ran. A non-zero exit is a real correctness failure (the 1:1 row is
# not an exact copy, or the numbers did not print at all).
target_gpu_probe() {
	require_fresh_binary gpu-probe || return 1
	VYPER_GPU_PROBE=1 timeout 300 ./vyper
}

# A/B gate for the GPU keyed-resample seam in the real export pipeline.
#
# The resample probe proves the shader matches the kernel in isolation; this
# proves the *seam* does -- crop sub-rect, dst rect, viewport, and the existing
# CPU blit -- through the actual compositor and encoder, which is a different
# code path from the probe and has broken parity before.
#
# The acceptance conditions are deliberately asymmetric:
#   1:1  must be BIT-EXACT. That case is a copy, so any difference is a real
#        defect (a half-texel inset or a wrong viewport would show here) and
#        not a rounding question.
#   0.5x must clear a PSNR floor. Minification legitimately differs in the
#        last LSB: the shader derives its footprint start in float while the
#        kernel works in integers. Equivalent, not identical -- and the target
#        says so rather than pretending the two are the same code.
#
# The control matters more than the threshold. x264 is deterministic, so two
# CPU-pinned runs of the same input are bit-identical; that is what licenses
# reading a GPU-vs-CPU delta as resample difference rather than encoder noise.
# Without that control this gate would be measuring the codec.
KEYED_DIR=target/keyed_export
KEYED_SRC="$KEYED_DIR/src.mp4"
KEYED_MIN_DB=50
ZORDER_DIR=target/zorder
SUB_DIR=target/subtitle_probe

keyed_export_run() {
	require_fresh_binary keyed-export || return 1
	mkdir -p "$KEYED_DIR"

	# testsrc2 is deterministic and full of fine detail, which is the point:
	# a minifying resample of a smooth gradient hides aliasing that a
	# high-frequency source exposes. Regenerated only when absent because the
	# content is deterministic, so a cached copy is the same clip.
	if [ ! -s "$KEYED_SRC" ]; then
		if ! nix develop -c ffmpeg -y -f lavfi -i \
			"testsrc2=size=1920x1080:rate=30:duration=3" \
			-c:v libx264 -pix_fmt yuv420p -crf 18 "$KEYED_SRC" >/dev/null 2>&1
		then
			echo "keyed-export: could not synthesize the source clip" >&2
			return 1
		fi
	fi

	local scale=$1 tag=$2
	shift 2
	env $PROBE_ENV \
		VYPER_RENDER_TEST="$KEYED_SRC|$KEYED_DIR/$tag.mp4" \
		VYPER_KEYED_SCALE="$scale" \
		VYPER_FRAME_TIME=1 \
		"$@" \
		timeout 600 ./vyper >"$KEYED_DIR/$tag.log" 2>&1
}

# Echoes the average PSNR in dB between two clips, or "inf" when identical.
keyed_psnr() {
	nix develop -c ffmpeg -hide_banner -i "$1" -i "$2" -lavfi psnr -f null - 2>&1 \
		| grep -o 'average:[a-z0-9.]*' | tail -1 | cut -d: -f2
}

# True when a PSNR value (possibly "inf") clears a dB floor.
keyed_psnr_ok() {
	local v=$1 floor=$2
	if [ "$v" = "inf" ]; then
		return 0
	fi
	awk -v a="$v" -v b="$floor" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

# Z-order: export must composite in TRACK order, not "all video then all text".
# Three runs of the same source differ only in where a TEXT clip sits:
#   base  - video only
#   below - text on a track UNDER the video  => must be pixel-identical to base
#   above - text on a track OVER the video   => must differ from base
# The "below" arm is the one with teeth: a text clip hidden behind an opaque
# video leaves no trace, so anything else means the compositor drew text on top
# regardless of track (the bug this replaced). "above" guards the other failure,
# a text clip dropped instead of layered. No pixel color is guessed -- only
# equality against the baseline.
zorder_run() {
	local arm=$1
	local zv=""
	[ "$arm" = below ] && zv="VYPER_ZORDER=below"
	[ "$arm" = above ] && zv="VYPER_ZORDER=above"
	env $PROBE_ENV \
		VYPER_RENDER_TEST="$KEYED_SRC|$ZORDER_DIR/$arm.mp4" \
		VYPER_FRAME_TIME=1 \
		$zv \
		timeout 600 ./vyper >"$ZORDER_DIR/$arm.log" 2>&1
}

target_zorder() {
	require_fresh_binary zorder || return 1
	mkdir -p "$ZORDER_DIR"
	local arm
	for arm in base below above; do
		zorder_run "$arm" || {
			echo "zorder: $arm run failed; see $ZORDER_DIR/$arm.log" >&2
			return 1
		}
	done

	local below_psnr above_psnr
	below_psnr=$(keyed_psnr "$ZORDER_DIR/base.mp4" "$ZORDER_DIR/below.mp4")
	above_psnr=$(keyed_psnr "$ZORDER_DIR/base.mp4" "$ZORDER_DIR/above.mp4")
	# Both arms must have produced text, or the comparison proves nothing: a
	# raster that failed to build would make "below" identical for the wrong
	# reason and "above" differ for the wrong one.
	grep -q 'render-test zorder:' "$ZORDER_DIR/below.log" || {
		echo "zorder: below run did not install a text clip" >&2
		return 1
	}
	if [ "$below_psnr" != "inf" ]; then
		echo "zorder: FAIL text UNDER the video is visible (base vs below PSNR $below_psnr, want inf)" >&2
		return 1
	fi
	if [ "$above_psnr" = "inf" ]; then
		echo "zorder: FAIL text OVER the video changed nothing (base vs above PSNR inf)" >&2
		return 1
	fi
	echo "zorder: ok (below=inf hidden under video, above=$above_psnr drawn over it)"
}

# AGENTS.md 9b: the export compositor's ownership model changed (video/text are
# now reached through a union of borrowed pointers into the job's own arrays),
# and that is exactly the kind of claim only valgrind can check. The "above" arm
# is the run that exercises it hardest: every frame walks the union, dereferences
# a borrowed source, and rasterizes a text clip.
target_render_valgrind() {
	require_fresh_binary render-valgrind || return 1
	mkdir -p "$ZORDER_DIR" target/valgrind
	local log=target/valgrind/render.log
	env $PROBE_ENV \
		VYPER_RENDER_TEST="$KEYED_SRC|$ZORDER_DIR/above_valgrind.mp4" \
		VYPER_ZORDER=above \
		timeout 900 valgrind --leak-check=full \
		--error-exitcode=99 ./vyper >"$log" 2>&1
	valgrind_assert "$log" render-valgrind
}

target_keyed_ab() {
	local failed=0
	# 0.5x: the minifying case that is allowed to differ by rounding.
	local spec_half="0:0.5,45:0.5,89:0.5"
	# 1.0x: the copy case that must not differ at all.
	local spec_one="0:1.0,45:1.0,89:1.0"

	# Four runs, written out rather than looped: the scale spec contains the
	# separator a loop would need, and a delimiter collision here would
	# silently export the wrong keyframes instead of failing.
	if ! keyed_export_run "$spec_half" half_gpu; then
		echo "keyed-export: half_gpu run failed; see $KEYED_DIR/half_gpu.log" >&2
		return 1
	fi
	if ! keyed_export_run "$spec_half" half_cpu VYPER_KEYED_GPU=0; then
		echo "keyed-export: half_cpu run failed; see $KEYED_DIR/half_cpu.log" >&2
		return 1
	fi
	if ! keyed_export_run "$spec_one" one_gpu; then
		echo "keyed-export: one_gpu run failed; see $KEYED_DIR/one_gpu.log" >&2
		return 1
	fi
	if ! keyed_export_run "$spec_one" one_cpu VYPER_KEYED_GPU=0; then
		echo "keyed-export: one_cpu run failed; see $KEYED_DIR/one_cpu.log" >&2
		return 1
	fi

	# The GPU run must have actually served the frames. A run that silently
	# fell back to the kernel would otherwise "pass" every pixel comparison
	# below while proving nothing about the GPU -- the same trap the keyed
	# frame counter exists for.
	local gpu_frames fallbacks
	gpu_frames=$(grep -o 'keyed gpu frames: [0-9]*' "$KEYED_DIR/half_gpu.log" | grep -o '[0-9]*$')
	fallbacks=$(grep -o 'cpu fallbacks: [0-9]*' "$KEYED_DIR/half_gpu.log" | grep -o '[0-9]*$')
	if [ "${gpu_frames:-0}" -eq 0 ]; then
		echo "keyed-export: GPU run served 0 keyed frames -- the seam was never exercised" >&2
		failed=1
	fi
	if [ "${fallbacks:-0}" -ne 0 ]; then
		echo "keyed-export: ${fallbacks} GPU failures fell back to the kernel" >&2
		failed=1
	fi
	grep -h 'frame-time] composite=' "$KEYED_DIR/half_gpu.log" "$KEYED_DIR/half_cpu.log" \
		| sed 's/^/keyed-export: /'

	local v
	v=$(keyed_psnr "$KEYED_DIR/one_gpu.mp4" "$KEYED_DIR/one_cpu.mp4")
	echo "keyed-export: 1.0x PSNR = $v (want inf)"
	if [ "$v" != "inf" ]; then
		echo "keyed-export: 1:1 is not bit-exact -- the seam drifts on unscaled frames" >&2
		failed=1
	fi

	v=$(keyed_psnr "$KEYED_DIR/half_gpu.mp4" "$KEYED_DIR/half_cpu.mp4")
	echo "keyed-export: 0.5x PSNR = $v (floor ${KEYED_MIN_DB} dB)"
	if ! keyed_psnr_ok "$v" "$KEYED_MIN_DB"; then
		echo "keyed-export: minifying resample drifted past the floor" >&2
		failed=1
	fi

	if [ $failed -ne 0 ]; then
		echo "keyed-export: FAILED" >&2
		return 1
	fi
	echo "keyed-export: ok"
}

target_probe() {
	require_fresh_binary probe || return 1
	env $PROBE_ENV timeout 120 ./vyper
}

# The preview handle/snap geometry regression check (transform_probe.odin).
# It was reachable only by setting VYPER_TRANSFORM_PROBE by hand, so nothing
# ran it: it is the one probe covering clip_full_box_dims and the crop/edge
# math, which is exactly the geometry project_geom.odin now owns. A regression
# there would have been invisible. The probe exits 0/1 itself.
target_transform_probe() {
	require_fresh_binary transform-probe || return 1
	VYPER_TRANSFORM_PROBE=1 timeout 120 ./vyper
}

# The timeline geometry/semantics regression check (timeline_probe.odin).
# Same problem transform_probe above had: it was reachable only by setting
# VYPER_TL_PROBE by hand, so nothing ran it. It covers cut resolution, drag
# alignment, ripple and -- as of this commit -- the half-open clip visibility
# bound, which is the predicate eleven call sites share and on which an
# off-by-one had already shipped silently in main.odin. The probe exits 0/1.
target_timeline_probe() {
	require_fresh_binary timeline-probe || return 1
	VYPER_TL_PROBE=1 timeout 120 ./vyper
}

# The byte-exact RGBA->NV12 ground truth (yuv_exact.odin) against swscale.
#
# This is the gate S1c's GPU shader cannot exist without. keyed_export's 1.0x
# anchor goes PSNR=inf the moment preview and export share the conversion, so
# from that point it stops being able to see a wrong conversion at all. Here the
# comparison is direct -- reference vs swscale, byte for byte, zero tolerance --
# and it runs the same code the shader will be written against.
#
# Even dimensions only, which is the whole domain: 4:2:0 has no odd chroma grid
# and the target encoders reject odd sizes. The reference asserts that rather
# than approximating, so an odd size is a loud failure, not a quiet one.
target_yuv_exact() {
	require_fresh_binary yuv-exact || return 1
	local n out
	for n in 8 16 32 64 96 128 160 256; do
		out=$(VYPER_YUV_EXACT_PROBE="verify:$n" timeout 300 ./vyper 2>&1) || {
			echo "yuv-exact: probe failed at $n" >&2
			echo "$out" | tail -5 >&2
			return 1
		}
		echo "$out" | grep -q 'mismatches = 0' || {
			echo "yuv-exact: $n -> $out" >&2
			return 1
		}
		echo "yuv-exact: $n ok"
	done
	# flat and vgrad are the two one-axis variants. Requiring them keeps the
	# failure message honest: if only these break, the fault is the horizontal
	# or vertical stage, not the full-frame path.
	for n in 64; do
		for mode in flat vgrad; do
			out=$(VYPER_YUV_EXACT_PROBE="$mode:$n" timeout 300 ./vyper 2>&1) || {
				echo "yuv-exact: $mode:$n probe failed" >&2
				return 1
			}
			echo "$out" | grep -q 'mismatches = 0' || {
				echo "yuv-exact: $mode:$n -> $out" >&2
				return 1
			}
			echo "yuv-exact: $mode:$n ok"
		done
	done
}

# The app must still be running when the timeout kills it; 124 is the pass.
target_smoke() {
	require_fresh_binary smoke || return 1
	timeout 4 ./vyper
	local rc=$?
	if [ $rc -ne 124 ]; then
		echo "smoke: exited $rc, expected 124 (timeout kill of a healthy run)" >&2
		return 1
	fi
	echo "smoke: ok (124)"
}

# The four ownership invariants AGENTS.md 9b actually claims. Valgrind's own
# exit code is always 99 here (FFmpeg and the Odin runtime report errors this
# program does not own), so the exit code is reported, never gated on; what
# gates is the claim. Shared by the probe-wide and render-path runs.
valgrind_assert() {
	local log=$1 label=$2
	local failed=0
	if ! grep -q "definitely lost: 0 bytes in 0 blocks" "$log"; then
		echo "$label: memory was definitely lost" >&2
		grep -A6 "definitely lost in loss record" "$log" | head -40 >&2
		failed=1
	fi
	if ! grep -q "indirectly lost: 0 bytes in 0 blocks" "$log"; then
		echo "$label: memory was indirectly lost" >&2
		failed=1
	fi
	if grep -qE "Invalid (free|read|write)" "$log"; then
		echo "$label: invalid free/read/write" >&2
		grep -B2 -A8 -E "Invalid (free|read|write)" "$log" | head -40 >&2
		failed=1
	fi
	# Report the noise baseline explicitly so a jump in contexts is visible
	# even though it does not fail the gate on its own.
	echo "$label: $(grep -E "definitely lost|indirectly lost" "$log" | tr '\n' ' ')"
	grep "$VALGRIND_KNOWN_NOISE" "$log" || true
	[ $failed -ne 0 ] && return 1
	echo "$label: ok (no leaks, no invalid access; full log: $log)"
}

target_valgrind() {
	require_fresh_binary valgrind || return 1
	mkdir -p target/valgrind
	local log=target/valgrind/probe.log
	env $PROBE_ENV timeout 900 valgrind --leak-check=full \
		--error-exitcode=99 ./vyper >"$log" 2>&1
	local rc=$?
	echo "valgrind: exit=$rc (expected 99: FFmpeg/Odin noise)"
	valgrind_assert "$log" valgrind
}

# The burned-in-subtitle render check (subtitle_probe.odin). It was reachable
# only by setting VYPER_SUB_RENDER_PROBE by hand, so nothing ran it. That
# mattered: a subtitle that stops compositing ABOVE the video, or drifts off
# its anchor between cues, is invisible to every other target here -- keyed_ab
# and zorder use a source with no subtitle clip at all. Draw-order work touches
# exactly the pass this covers, so it has to be a gate rather than a probe
# somebody remembers. The probe asserts and exits 0/1 itself.
target_subtitle_probe() {
	require_fresh_binary subtitle-probe || return 1
	mkdir -p "$SUB_DIR"
	if [ ! -s "$KEYED_SRC" ]; then
		echo "subtitle-probe: needs \$KEYED_SRC; run keyed_export first" >&2
		return 1
	fi
	# NOT $PROBE_ENV: that adds VYPER_UI_PROBE, which runs the ui probe first
	# and needs a media file this target does not have. The sub probe is
	# standalone and builds its own timeline.
	env VYPER_SUB_RENDER_PROBE="$SUB_DIR/subs.mp4" \
		timeout 600 ./vyper >"$SUB_DIR/subs.log" 2>&1
	local rc=$?
	# Assert the probe REACHED its end, not just that the process exited 0.
	# Without this the target is a false green: the binary can bail during
	# startup (no media, no font) and exit 0 having asserted nothing.
	if ! grep -q '\[sub-probe\] all stages complete' "$SUB_DIR/subs.log"; then
		echo "subtitle-probe: FAILED (exit $rc) -- probe did not complete" >&2
		tail -20 "$SUB_DIR/subs.log" >&2
		return 1
	fi
	tail -1 "$SUB_DIR/subs.log"
}

target_all() {
	local t
	# render_valgrind was deliberately excluded here while it failed on two
	# pre-existing export/import-path leaks. Both are fixed (the encoder had no
	# teardown call at all, and the decoder never freed its destination image),
	# so it is now a member: the leaks it exists to catch were all reachable
	# from the export path, which no other target in this list executes.
	for t in check build probe transform_probe timeline_probe yuv_exact gpu_probe keyed_export zorder subtitle_probe smoke valgrind render_valgrind; do
		echo "=== $t ==="
		"$SELF" "$t" || return 1
	done
}

main() {
	case "${1:-all}" in
	check) target_check ;;
	shaders) target_shaders ;;
	build) target_build ;;
	bench) target_bench ;;
	probe) target_probe ;;
	transform_probe) target_transform_probe ;;
	timeline_probe) target_timeline_probe ;;
	yuv_exact) target_yuv_exact ;;
	gpu_probe) target_gpu_probe ;;
	keyed_export) target_keyed_ab ;;
	zorder) target_zorder ;;
	render_valgrind) target_render_valgrind ;;
	subtitle_probe) target_subtitle_probe ;;
	smoke) target_smoke ;;
	valgrind) target_valgrind ;;
	all) target_all ;;
	*)
		echo "usage: $SELF [check|shaders|build|bench|probe|transform_probe|timeline_probe|yuv_exact|gpu_probe|keyed_export|zorder|subtitle_probe|render_valgrind|smoke|valgrind|all]" >&2
		return 2
		;;
	esac
}

main "$@"
