#!/usr/bin/env bash
# Gate targets for AGENTS.md §10: every build/profiling invocation lives here,
# so nobody has to remember a flag combination (or type it by hand and get it
# subtly wrong). Run from the repo root: scripts/gate.sh <target>.
set -uo pipefail

# Absolute path to this script, so target_all can re-invoke sibling targets
# regardless of how it was called or what the cwd is.
SELF=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")

# Shared toolchain resolution, the same fragment build.sh sources. Sourced, not
# executed, so it only defines resolve_odin_root.
. "$(dirname -- "$SELF")/toolchain.sh"

# The probe entry point. Headless: simulates the frame loop and runs the
# layout/geometry/ownership asserts, then exits.
PROBE_ENV="VYPER_UI_PROBE=1"

# Valgrind's exit code reflects FFmpeg and the Odin runtime, which report errors
# this program does not own. The invariant that matters is the one the memory
# model in AGENTS.md §1 actually claims, so the target asserts THAT instead of
# propagating a number that is always 99.
VALGRIND_KNOWN_NOISE="ERROR SUMMARY"

# The vendored FFmpeg bindings in vendor/ffmpeg/ are hand-maintained mirrors of
# the FFmpeg structs, so they only agree with the FFmpeg actually linked at
# runtime if the two were written against the same version. When they drift,
# nothing fails at link time: the app reads fields from the wrong offsets, which
# surfaces far away as a nonsense swscale dimension or a wild pointer.
#
# This has already cost two debugging sessions, so the fallback path below
# checks the one field that pins the layout rather than trusting a version
# number (libavformat major 60 exists on both sides of the break, so a version
# comparison does not discriminate). offsetof(AVFormatContext, chapters) == 80
# is the exact invariant: it moves as soon as the struct gains or loses a
# pointer, which is how the bindings fall out of sync.
FFMPEG_ABI_OFFSET=80
FFMPEG_ABI_CHECKED=""

require_ffmpeg_abi() {
	[ -n "$FFMPEG_ABI_CHECKED" ] && return "$FFMPEG_ABI_CHECKED"
	local dir probe got
	dir=$(mktemp -d)
	cat > "$dir/abi.c" <<-'EOF'
		#include <stdio.h>
		#include <stddef.h>
		#include <libavformat/avformat.h>
		int main(void){ printf("%zu\n", offsetof(AVFormatContext, chapters)); return 0; }
	EOF
	probe="$dir/abi"
	if cc -o "$probe" "$dir/abi.c" -lavformat >/dev/null 2>&1; then
		got=$("$probe" 2>/dev/null)
	fi
	rm -rf "$dir"
	if [ "${got:-}" != "$FFMPEG_ABI_OFFSET" ]; then
		echo "gate: host FFmpeg struct layout does not match vendor/ffmpeg bindings" >&2
		echo "gate:   offsetof(AVFormatContext, chapters) = ${got:-<probe failed>}, bindings require ${FFMPEG_ABI_OFFSET}" >&2
		echo "gate:   run these through the nix devshell instead" >&2
		FFMPEG_ABI_CHECKED=1
		return 1
	fi
	FFMPEG_ABI_CHECKED=0
	return 0
}

# Runs a command inside the nix devshell when nix is available, and on the host
# toolchain otherwise. Both branches pass the SAME command and flags, so the
# flags stay defined in exactly one place; only the provenance of the binaries
# differs. Without this, a host lacking /nix could not run a single gate.
dev() {
	if command -v nix >/dev/null 2>&1; then
		dev "$@"
	else
		require_ffmpeg_abi || return 1
		# Every odin invocation in this script goes through here, so this is the
		# one place the compiler's own tree has to be resolvable. A stale
		# ODIN_ROOT exported by a previous install otherwise fails every target
		# with "Invalid ODIN_ROOT, directory does not exist" — an error that
		# names a missing directory, not the compiler mismatch behind it. Same
		# function build.sh uses, so the two cannot drift.
		resolve_odin_root || return 1
		"$@"
	fi
}

target_check() {
	# -debug is load-bearing, not a preference. `odin check` does not compile a
	# `when ODIN_DEBUG` branch unless -debug is passed, so without it this
	# validates the RELEASE view and reports clean while the build we actually
	# produce by default is unverified -- a deliberate error inside
	# `when ODIN_DEBUG` type-checks fine here. Measured, not assumed.
	dev odin check . -debug -strict-style -vet-using-param -vet-using-stmt
}

# Shader compilation is a build step, not a thing you remember to do by hand.
# The SPVs are #load-ed into the binary at compile time, so editing a .frag and
# rebuilding without recompiling it silently keeps the OLD shader and the run
# reports the previous shader's results as if they were the new one. That is not
# hypothetical: it happened here, and it produced a measurement that was
# confidently wrong. Anything that builds the binary compiles shaders first.
target_shaders() {
	dev sh -c '
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
			shaders/blit_lod.frag \
			shaders/nv12_luma.frag \
			shaders/nv12_chroma.frag
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

# The flags live in build.sh and ONLY in build.sh: the sysroot and the extra
# -l list are what make the binary link against the SYSTEM ffmpeg/SDL3/glib
# rather than a toolchain's own bundled sysroot. Re-declaring them here is
# exactly the "type the flags by hand instead of fixing the script" failure
# AGENTS.md §10 exists to prevent, and it fails at the LINK step, a long way
# from the cause. build.sh also compiles the vendored C and the SPIR-V, so
# delegating is the one place that can be right.
target_build() {
	./build.sh
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

# The memory gate cannot run ./vyper. -microarch:native lets LLVM emit AVX-512,
# which VEX cannot decode, so the binary dies with SIGILL in
# math_big::initialize_constants during __$startup_runtime -- before main, having
# allocated nothing. Memcheck then dutifully reports "definitely lost: 0 bytes in
# 0 blocks" and the gate passes while measuring nothing.
#
# So the memory gate gets its own binary at the baseline x86-64 target, built
# from the same flags via build.sh (AGENTS.md §10: flags live in the script).
# Name the output as VYPER_OUT rather than hardcoding a second odin invocation.
#
# The mode is named explicitly rather than left to build.sh's default. Debug is
# now that default, but this gate NEEDS frame pointers and symbols to unwind --
# an optimized build omits frame pointers, so every allocation trace comes back
# as "calloc <- runtime::heap_allocator_proc <- ??? <- ???", which names the
# defect site no better than no trace at all. Naming it means a later flip of the
# default cannot quietly downgrade the memory gate into one that reads nothing.
VALGRIND_BIN=./vyper-valgrind

build_valgrind_binary() {
	VYPER_OUT=vyper-valgrind VYPER_MICROARCH= ./build.sh debug
}

# Same freshness contract as require_fresh_binary, with one deliberate
# difference: this one BUILDS on demand. require_fresh_binary refuses, because an
# automatic rebuild of ./vyper would hide "I meant to measure the previous
# build". Here the opposite is true -- the baseline binary has different flags,
# so a missing or stale one is not a measurement anybody could have meant to
# make, and failing would just mean the gate never runs again.
require_fresh_valgrind_binary() {
	local target_name=$1
	if [ ! -x "$VALGRIND_BIN" ]; then
		echo "$target_name: $VALGRIND_BIN missing -- building baseline binary for memcheck" >&2
		build_valgrind_binary >/dev/null || return 1
		return 0
	fi
	local stale
	stale=$(find . -maxdepth 1 -name '*.odin' -newer "$VALGRIND_BIN" -print -quit)
	if [ -z "$stale" ]; then
		stale=$(find shaders -name '*.spv' -newer "$VALGRIND_BIN" -print -quit)
	fi
	if [ -n "$stale" ]; then
		echo "$target_name: $VALGRIND_BIN is older than $stale -- rebuilding" >&2
		build_valgrind_binary >/dev/null || return 1
	fi
}

# swscale/resample microbenchmarks. Separate package (swsbench) so it can link
# the vendored FFmpeg without dragging in the whole app; it exists to keep
# claims about scaler cost measured rather than remembered.
target_bench() {
	# The script runs without `set -e`, so a failed build would otherwise fall
	# through to executing the previous binary and reporting stale numbers as
	# current — which is worse than no benchmark, because it looks like data.
	if ! dev odin build swsbench -out:bin_swsbench \
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
PROXY_DIR=target/proxy_probe
PROXY_SRC="$PROXY_DIR/src.mp4"

keyed_export_run() {
	require_fresh_binary keyed-export || return 1
	mkdir -p "$KEYED_DIR"

	# testsrc2 is deterministic and full of fine detail, which is the point:
	# a minifying resample of a smooth gradient hides aliasing that a
	# high-frequency source exposes. Regenerated only when absent because the
	# content is deterministic, so a cached copy is the same clip.
	if [ ! -s "$KEYED_SRC" ]; then
		if ! dev ffmpeg -y -f lavfi -i \
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
	dev ffmpeg -hide_banner -i "$1" -i "$2" -lavfi psnr -f null - 2>&1 \
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
	require_fresh_valgrind_binary render-valgrind || return 1
	mkdir -p "$ZORDER_DIR" target/valgrind
	local log=target/valgrind/render.log
	env $PROBE_ENV \
		VYPER_RENDER_TEST="$KEYED_SRC|$ZORDER_DIR/above_valgrind.mp4" \
		VYPER_ZORDER=above \
		timeout 900 valgrind --leak-check=full \
		--error-exitcode=99 "$VALGRIND_BIN" >"$log" 2>&1
	valgrind_assert "$log" render-valgrind 'render-test zorder:'
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

# The keyframe store/evaluator regression check (keyframe_probe.odin). Like the
# transform probe it was reachable only by setting VYPER_KEYFRAME_PROBE by hand,
# so nothing ran it -- and it is the only check on the remap helpers
# (kf_trim_head/kf_trim_tail: slice-1 re-relativization, packed sections,
# interpolation-mode preservation) that both split paths run. The probe exits
# 0/1 itself.
target_keyframe_probe() {
	require_fresh_binary keyframe-probe || return 1
	VYPER_KEYFRAME_PROBE=1 timeout 120 ./vyper
}

target_render_kf_probe() {
	require_fresh_binary render-kf-probe || return 1
	VYPER_RENDER_KF_PROBE=1 timeout 120 ./vyper
}

# The audio engine regression check (audio_probe.odin). It has no gate target
# either, so nothing ran it: it is the only check on the geometry-slab handoff
# between the UI thread and the producer, on segment geometry after edits, and on
# the per-source gain fold. It needs a media file, which the target synthesizes
# deterministically (lavfi testsrc2 + sine) so it never depends on a fixture
# someone has to supply. The probe exits 0/1 itself and skips the parts that
# need an audio device when there is none.
target_audio_probe() {
	require_fresh_binary audio-probe || return 1
	mkdir -p target/audio_probe
	local src=target/audio_probe/src.mp4
	if [ ! -s "$src" ]; then
		# Stream 0 is a 440 Hz tone; stream 1 is a CONSTANT signal, which the
		# declick case needs: a click is a step, and a step's size at the boundary
		# depends on the signal's phase there. A sine happens to sit near a zero
		# crossing at the cut, so an unramped cut measured as a third of the
		# amplitude and the check passed with the declick deleted outright. DC has
		# no phase, so the step is the full amplitude every time.
		if ! dev ffmpeg -y -f lavfi -i \
			"testsrc2=size=640x360:rate=30:duration=10" \
			-f lavfi -i "sine=frequency=440:sample_rate=48000:duration=10" \
			-f lavfi -i "aevalsrc=0.5:s=48000:d=10" \
			-map 0:v -map 1:a -map 2:a \
			-c:v libx264 -pix_fmt yuv420p -crf 20 -c:a aac -shortest "$src" >/dev/null 2>&1
		then
			echo "audio-probe: could not synthesize the source clip" >&2
			return 1
		fi
	fi
	VYPER_AUDIO_PROBE="$src|4|2" timeout 600 ./vyper || return 1
	# The forward-jump death, in its own process: it needs a clean timeline, and
	# it is the only check covering a jump larger than the forward-decode bound
	# (the mixer must seek there, not decode the skipped audio through).
	VYPER_AUDIO_JUMP_PROBE="$src" timeout 600 ./vyper
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

# Gesture-routing check (geom_key_probe.odin): an Alt+wheel / Alt+drag edit on
# a clip whose geometry is already keyed must land where the clip is READ.
# The gestures used to write the resting fields directly while every other
# geometry path funneled through kf_auto_key, so on a keyed clip the edit
# landed where the sampler never looks — the box did not move under the
# pointer while the inspector value did, and the clip jumped when the playhead
# left the keyed span. transform_probe covers the gesture MATHS; this covers
# where the result goes, which no other target exercised.
target_geom_key_probe() {
	require_fresh_binary geom-key-probe || return 1
	VYPER_GEOM_KEY_PROBE=1 timeout 120 ./vyper
}

# The memory gate for geom_key_probe. The probe builds and tears down clip
# keyframe tracks by hand -- dropping packed sections, unwrapping them into
# per-lane tracks and releasing session key ranges -- so it is exactly the kind
# of code the ownership claims in AGENTS.md cannot check by compiling, and it
# is the one path that exercises kf_geom_unwrap_section from a pending-partial
# state that no other target reaches. Same four invariants as target_valgrind.
target_geom_key_valgrind() {
	require_fresh_valgrind_binary geom-key-valgrind || return 1
	mkdir -p target/valgrind
	local log=target/valgrind/geom_key.log
	VYPER_GEOM_KEY_PROBE=1 timeout 900 valgrind --leak-check=full \
		--error-exitcode=99 "$VALGRIND_BIN" >"$log" 2>&1
	local rc=$?
	echo "geom-key-valgrind: exit=$rc (expected 99: FFmpeg/Odin noise)"
	valgrind_assert "$log" geom-key-valgrind '\[geom-key-probe\] OK:'
}

# The undo probe's memory gate. Same argument as geom_key_valgrind above, and
# it is the ONLY gate that measures the undo probe's heap traffic: target_valgrind
# runs the UI probe, and the undo probe is where the keyframe-capture lifecycle
# lives (cloned track names per selected key, re-armed every press, released on
# release). The drag path there allocates a name per key per gesture and is
# SUPPOSED to drop them while keeping the list's buffer -- kf_snaps_drop vs a bare
# clear. A bare clear is invisible to the UI probe (which never multi-drags) and
# would have shown up here as one lost track-name string per key per drag, so this
# target is the only thing standing between that and a slow per-drag leak.
target_undo_valgrind() {
	require_fresh_valgrind_binary undo-valgrind || return 1
	mkdir -p target/valgrind
	local log=target/valgrind/undo.log
	VYPER_UNDO_PROBE=1 timeout 900 valgrind --leak-check=full \
		--error-exitcode=99 "$VALGRIND_BIN" >"$log" 2>&1
	local rc=$?
	echo "undo-valgrind: exit=$rc (expected 99: FFmpeg/Odin noise)"
	valgrind_assert "$log" undo-valgrind '\[undo-probe\] PASS'
}

# The live-preview handoff check (render_live_probe.odin). The composed-frame
# mailbox is the one place where the export's worker thread and the UI thread
# write the same bytes, so a mistake there is a data race rather than a wrong
# pixel -- which is exactly the class the pixel-comparing gates cannot see. It
# pins the frame actually handed over, the DROP overflow policy (an undrained
# mailbox must not be overwritten), the usability gate, and the publish
# interval.
# The held-frame decode path (conform). A project faster than its source asks for
# the same source frame repeatedly, and serving a repeat must not re-seek: a seek
# flushes the decoder, which on AV1 destroys the reference frames the next unit
# needs. Synthesized rather than reusing a checked-in clip so the walk is
# deterministic; 30fps testsrc2 conformed into 60fps holds every frame twice, which
# is exactly the shape that used to fail.
target_decode_repeat() {
	require_fresh_binary decode-repeat || return 1
	local dir=target/decode_repeat
	mkdir -p "$dir"
	local src="$dir/src.mp4"
	if [ ! -s "$src" ]; then
		dev ffmpeg -y -f lavfi -i "testsrc2=size=640x360:rate=30:duration=3" \
			-c:v libx264 -pix_fmt yuv420p -crf 18 "$src" >/dev/null 2>&1 || {
			echo "decode-repeat: could not synthesize the source clip" >&2
			return 1
		}
	fi
	local proj=${1:-60} srcfps=${2:-30}
	env $PROBE_ENV VYPER_DECODE_REPEAT_PROBE="$src|$proj|$srcfps" timeout 120 ./vyper
}

target_render_live_probe() {
	require_fresh_binary render-live-probe || return 1
	VYPER_RENDER_LIVE_PROBE=1 timeout 120 ./vyper
}

# The memory gate for render_live_probe. Same argument as geom_key_valgrind
# above: the mailbox buffer is session heap that OUTLIVES the run and is reused
# across runs, so a resize or a teardown that dropped it is invisible to the
# compiler and only shows up here. Same four invariants as target_valgrind.
target_render_live_valgrind() {
	require_fresh_valgrind_binary render-live-valgrind || return 1
	mkdir -p target/valgrind
	local log=target/valgrind/render_live.log
	VYPER_RENDER_LIVE_PROBE=1 timeout 900 valgrind --leak-check=full \
		--error-exitcode=99 "$VALGRIND_BIN" >"$log" 2>&1
	local rc=$?
	echo "render-live-valgrind: exit=$rc (expected 99: FFmpeg/Odin noise)"
	valgrind_assert "$log" render-live-valgrind '\[render-live-probe\] ok'
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

# The session string pool check (session_str_probe.odin). Clip names and marker
# labels moved from heap strings to offset+length handles into one session block
# (TODO.md Active 19), which trades a compiler-checked ownership chain for a
# handle the compiler cannot check. The probe stands in for it: intern/view
# round-trip, rename isolation across a copy, dedupe, the zero handle, offset
# stability under growth, and reset. Exits 0/1.
target_session_str_probe() {
	require_fresh_binary session-str-probe || return 1
	VYPER_SESSION_STR_PROBE=1 timeout 120 ./vyper
}

# The session keyframe store check (session_kf_probe.odin). Clip keyframe keys
# move out of per-track owned arrays into one session-owned store addressed by
# range, with a copy-on-write bit so a Clip copy can be a struct copy
# (TODO.md Active 19). Unlike the string pool this store RELOCATES a range when
# it cannot grow in place, so the probe is about what movement breaks: in-place
# growth across many inserts, sharing resolved on write and only on write,
# freeing actually reusing space (the reason it is an allocator and not a bump
# pointer), one relocation copying keys intact, and a reset leaving every handle
# out of bounds. Exits 0/1.
target_session_kf_probe() {
	require_fresh_binary session-kf-probe || return 1
	VYPER_SESSION_KF_PROBE=1 timeout 120 ./vyper
}

# The session track-row arena check (session_tracks_probe.odin). It pins bounded
# reuse and both COW layers: track rows first, then their key ranges.
target_session_trk_probe() {
	require_fresh_binary session-trk-probe || return 1
	VYPER_SESSION_TRK_PROBE=1 timeout 120 ./vyper
}

target_session_marker_probe() {
	require_fresh_binary session-marker-probe || return 1
	VYPER_SESSION_MARKER_PROBE=1 timeout 120 ./vyper
}

# The OS file-drag-and-drop probe (dnd_probe.odin). Dragging a file in from the
# desktop used to do NOTHING at all: the app polled SDL events and handled six
# of them, none of them the five drop kinds, so the feature was absent on every
# platform and nothing failed. Ignoring events is not a crash, which is why the
# probe covers the decisions a drop makes -- zone routing, the import gate, and
# the gesture state -- rather than the delivery a headless run cannot perform.
target_dnd_probe() {
	require_fresh_binary dnd-probe || return 1
	VYPER_DND_PROBE=1 timeout 120 ./vyper
}

# The action log's gate. A byte check would pass for a record that survives the
# file but not the replay, so this is a roundtrip: the probe records a scripted
# session, reopens the file it wrote, and compares the app state across the two
# phases, then cuts 6 bytes off the log and requires the replay to refuse it.
target_action_log() {
	require_fresh_binary action-log || return 1
	mkdir -p target/action-log
	VYPER_ACTION_LOG_PROBE=target/action-log/roundtrip.vya timeout 120 ./vyper
}

# The memory gate for dnd_probe: the drop path takes an SDL-owned C string for
# each dropped file and hands it to the bin, which clones what it keeps. So the
# app owns nothing here -- SDL's SDL_FreeTemporaryMemory list owns the event
# buffer and frees it at the next pump -- and the probe covers the handoff from
# both ends: the commit it makes and the clone it makes (import_path_to_bin's
# refusal branch plus the refusal of a path SDL would have delivered). Same four
# invariants as target_valgrind.
target_dnd_valgrind() {
	require_fresh_valgrind_binary dnd-valgrind || return 1
	mkdir -p target/valgrind
	local log=target/valgrind/dnd.log
	VYPER_DND_PROBE=1 timeout 900 valgrind --leak-check=full \
		--error-exitcode=99 "$VALGRIND_BIN" >"$log" 2>&1
	local rc=$?
	echo "dnd-valgrind: exit=$rc (expected 99: FFmpeg/Odin noise)"
	valgrind_assert "$log" dnd-valgrind '\[dnd-probe\] all checks passed'
}

# The memory gate for the action log. It is the one feature that opens a file,
# reads a whole log into memory, keeps it for the session, and hands buffers
# across a boundary in both directions -- the CBOR snapshot goes out to the
# writer, and the log's own bytes back into SDL's event structs. Those are
# exactly the handoffs the four invariants exist for. The probe deliberately
# leaks the pushed SDL strings (SDL_PushEvent copies the event but not the
# string), so the gate is about the log's own ownership, which is what the two
# records and the reader are.
target_action_log_valgrind() {
	require_fresh_valgrind_binary action-log-valgrind || return 1
	mkdir -p target/valgrind
	local log=target/valgrind/action-log.log
	VYPER_ACTION_LOG_PROBE=target/valgrind/action-log-roundtrip.vya timeout 900 valgrind \
		--leak-check=full --error-exitcode=99 "$VALGRIND_BIN" >"$log" 2>&1
	local rc=$?
	echo "action-log-valgrind: exit=$rc (expected 99: FFmpeg/Odin noise)"
	valgrind_assert "$log" action-log-valgrind '\[action-log-probe\] ok'
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

# The GPU half of the same claim. Once preview and export share the
	# conversion, keyed_export's 1.0x anchor is blind to it (PSNR=inf by
	# construction), so the only thing standing between the shader and a silent
	# colour shift is this byte comparison. It is three-way -- swscale, the CPU
	# reference, and the GPU shaders must all agree on every byte of the frame
	# -- and it is proven red on drift: RY off by one turns it red.
	target_gpu_nv12() {
		require_fresh_binary gpu-nv12 || return 1
		local out
		out=$(VYPER_GPU_NV12_PROBE=1 timeout 300 ./vyper 2>&1)
		local code=$?
		if [ $code -ne 0 ]; then
			echo "$out" | grep -v '^gpu-nv12: adapter' | tail -8 >&2
			return 1
		fi
		echo "$out" | grep -c ' ok$'
		echo "gpu-nv12: ok"
	}

# The composite contract for the GPU canvas: the per-clip draws must
	# reproduce render_blit_region's z-order, clipping, and offset placement
	# exactly, or replacing the CPU composite shifts the exported pixels.
	# Proven red both ways: a dropped z-order op fails, and the mask mechanism
	# would also catch a reorder that loses an over-write.
	target_gpu_composite() {
		require_fresh_binary gpu-composite || return 1
		local out
		out=$(VYPER_GPU_COMPOSITE_PROBE=1 timeout 300 ./vyper 2>&1)
		local code=$?
		if [ $code -ne 0 ]; then
			echo "$out" | grep -v '^gpu-composite: adapter' | tail -6 >&2
			return 1
		fi
		echo "$out" | grep -q 'mismatches = 0' && echo "$out" | tail -1
	}

# Code footprint: which Odin procs are the biggest, most branchy, deepest.
# Advisory measurement, not a pass/fail gate (a big function is not a bug), so
# it is intentionally not a member of `all`. There is no Odin complexity
# linter in the toolchain, so scripts/footprint.py is the instrument; running
# it by hand is what AGENTS.md 10 forbids.
target_footprint() {
	DIR="$(dirname -- "$SELF")"; python3 "$DIR/footprint.py" --top "${2:-20}"
}

# Fractional opacity must actually composite over the layer below it, on the
# CPU export path (blend_row) and the GPU one (blit_box alpha + over blend).
# gpu_composite only pins the opacity=1 end of the same contract.
target_opacity() {
	require_fresh_binary opacity || return 1
	local out
	out=$(VYPER_RENDER_OPACITY_PROBE=1 timeout 300 ./vyper 2>&1)
	local code=$?
	if [ $code -ne 0 ]; then
		echo "$out" | tail -6 >&2
		return 1
	fi
	echo "$out" | tail -1
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
	local log=$1 label=$2 ran_marker=${3:-}
	local failed=0
	# Non-vacuity first. A run that died before doing any work satisfies all
	# four invariants below trivially -- a process that allocated nothing loses
	# nothing -- so without this check the gate can report "ok" while measuring
	# nothing, which is the one failure mode that makes every other check
	# worthless. The probe's own success line is the proof the work happened;
	# the SIGILL case is named because that is how it happened here.
	if [ -n "$ran_marker" ] && ! grep -q "$ran_marker" "$log"; then
		echo "$label: probe never reported success (marker '$ran_marker') -- vacuous pass" >&2
		echo "$label: tail of log:" >&2
		tail -20 "$log" >&2
		failed=1
	fi
	if grep -q "Unrecognised instruction" "$log"; then
		echo "$label: memcheck died on an instruction VEX cannot decode -- vacuous pass" >&2
		grep -A4 "Unrecognised instruction" "$log" | head -12 >&2
		failed=1
	fi
	# A probe that reported FAILURES and still satisfies its success marker has told
	# us the marker is wrong, not that the run was clean. undo_valgrind did exactly
	# that for as long as the probe was red: the marker was the early informational
	# "[undo-probe] ok: count=...", which is printed before any assertion runs. Every
	# probe in this tree writes failures as "FAIL:" or "N failure(s)", so this is the
	# one check that makes a success marker mean something.
	if grep -qE '\] FAIL:|failure\(s\)' "$log"; then
		echo "$label: the probe reported failures but the success marker was present -- marker is wrong or vacuous" >&2
		grep -E '\] FAIL:|failure\(s\)' "$log" | head -10 >&2
		failed=1
	fi
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
	require_fresh_valgrind_binary valgrind || return 1
	mkdir -p target/valgrind
	local log=target/valgrind/probe.log
	env $PROBE_ENV timeout 900 valgrind --leak-check=full \
		--error-exitcode=99 "$VALGRIND_BIN" >"$log" 2>&1
	local rc=$?
	echo "valgrind: exit=$rc (expected 99: FFmpeg/Odin noise)"
	valgrind_assert "$log" valgrind '\[ui-probe\]'
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

export_bench_dir=target/export_bench

# S1: opt-in export benchmark. NOT a member of `all`, and that is the whole
# design decision: this measures, it does not gate. A perf target in the suite
# fails the day the machine is busy, and a benchmark that cries wolf gets
# ignored, which costs more than having no benchmark. Every OTHER target here
# answers "is it correct"; this one answers "what does it cost", and those want
# opposite failure behaviour.
#
# The shapes are the ones the reported regression was sensitive to. A keyed
# animation's cost is set by the PEAK scale, not the frames on screen, so the
# stage column is reported next to the timings -- without it, ms/frame for
# 1->2 and 1->3 look like the same kind of number and invite a wrong comparison.
export_bench_run() {
	local shape=$1
	shift
	local log="$export_bench_dir/$shape.log"
	local out="$export_bench_dir/$shape.mp4"
	mkdir -p "$export_bench_dir"
	local t0 t1
	t0=$(date +%s%N)
	env $PROBE_ENV \
		VYPER_RENDER_TEST="$KEYED_SRC|$out" \
		VYPER_FRAME_TIME=1 \
		"$@" \
		timeout 900 ./vyper >"$log" 2>&1
	local rc=$?
	t1=$(date +%s%N)
	if [ $rc -ne 0 ]; then
		echo "export-bench: $shape run failed (rc=$rc); see $log" >&2
		return 1
	fi
	# A run that produced no clip is not a fast run, it is a broken one. Read
	# the numbers out of the log rather than timing the shell: the log is what
	# the composite actually reported, and a silent field means the shape did
	# not take the path it claims to.
	#
	# There is deliberately no "resample" column. S1c composited keyed frames
	# straight into the GPU canvas, so render_eval_keyed_geom returns before
	# the separate resample call and comp_resample_ns stays 0 for every shape
	# -- the cost moved into the composite walk. A column that is structurally
	# always zero is a lie with a number in it, so the columns are the ones
	# that still move: producer total and its stage-scaling component (which is
	# what grows with the animation peak) plus the composite walk.
	local wall producer pscale composite stage frames hash
	wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", (b-a)/1e9}')
	producer=$(sed -n 's/.*decode(producer)=\([0-9.]*\)ms.*/\1/p' "$log" | tail -1)
	pscale=$(sed -n 's/.*decode(producer)=[0-9.]*ms\/f (codec=[0-9.]*ms\/f scale=\([0-9.]*\)ms.*/\1/p' "$log" | tail -1)
	composite=$(sed -n 's/.*videoenc=[0-9.]*% ([^,]*, \([0-9.]*\)ms\/f).*/\1/p' "$log" | tail -1)
	stage=$(sed -n 's/.*render-test max stage: \([0-9]*\) *x *\([0-9]*\).*/\1x\2/p' "$log" | tail -1)
	frames=$(sed -n 's/.*render-test max stage:.*frames: \([0-9]*\).*/\1/p' "$log" | tail -1)
	hash=$(md5sum "$out" 2>/dev/null | cut -d' ' -f1)
	if [ -z "$producer" ] || [ -z "$stage" ] || [ -z "$hash" ] || [ -z "$composite" ]; then
		echo "export-bench: $shape produced no usable numbers; see $log" >&2
		return 1
	fi
	printf '%-16s wall=%-6s producer=%-6s scale=%-6s composite=%-6s stage=%-11s frames=%-4s %s\n' \
		"$shape" "$wall" "$producer" "${pscale:-?}" "$composite" "$stage" "$frames" "$hash"
}

target_export_bench() {
	require_fresh_binary export-bench || return 1
	if [ ! -s "$KEYED_SRC" ]; then
		echo "export-bench: no source clip; run keyed_export once first" >&2
		return 1
	fi
	echo "shape            wall    producer scale   composite stage        frames md5"
	# 90-frame source; peaks land mid-clip so the constant-scale and
	# off-canvas arms differ from the animated ones in stage, not just in time.
	export_bench_run scale_1_to_2   VYPER_KEYED_SCALE="0:1.0,45:2.0,89:2.0" || return 1
	export_bench_run scale_1_to_3   VYPER_KEYED_SCALE="0:1.0,45:3.0,89:3.0" || return 1
	export_bench_run scale_reversed VYPER_KEYED_SCALE="0:2.0,45:1.0,89:1.0" || return 1
	export_bench_run scale_constant VYPER_KEYED_SCALE="0:2.0,45:2.0,89:2.0" || return 1
	export_bench_run transform_only VYPER_TX="60,40,1.0" || return 1
	export_bench_run crop_only     VYPER_CROP="0.1,0.1,0.1,0.1" || return 1
	export_bench_run off_canvas    VYPER_TX="-3000,0,1.0" || return 1
}

# image_probe proves a STILL IMAGE is not treated as footage. It exists because
# the user imported a .jpg and the app SEGFAULTED: a still probes as a one-frame
# mjpeg video stream, so every "is this video?" test says yes and the on-demand
# scheduler posted a background H.264 build for it. The encode loop then reached
# its trailing drain having fed the encoder nothing, and h264_vaapi dereferenced
# surface state that only exists after the first real frame -- SIGSEGV inside
# libavcodec, on the import worker, with no gate target anywhere on that path.
#
# The fixture is synthesized, so it is the same file every run and costs nothing.
# image_decode_probe proves a still image DECODES, and holds across its span.
# Separate from image_probe because the two failures are different and the user
# reported both: a .jpg that "renders nothing" is not a classification problem.
# The clip classified correctly (kind=Video, is_still) and still showed nothing,
# because the decode failed -- and a decode that always fails is ALSO the stall:
# slot.has_frame never becomes true, so preview_state re-posts a decode on every
# single frame, forever.
#
# The defect was a cold decoder SEEKING to frame 0. A fresh decoder is already
# there, so the seek bought nothing -- and on a single-packet source it cost the
# only packet: avformat_seek_frame to ts 0 with BACKWARD lands past it and the
# read that follows returns EOF. JPEG's demuxer does this; PNG's does not, which
# is why a .jpg failed and a .png did not.
#
# The fixture is synthesized. Both a PORTRAIT and a LANDSCAPE still are checked,
# because they exercise different letterboxing (243x432 centred in 768x432 vs
# 768x432 filling it) and a portrait-only fixture would pass a fit-rect bug that
# a landscape one exposes.
# silent_playback proves a project with NO AUDIO PLAYBACK AT ALL still plays.
#
# Forward playback is device-master: the playhead is a readout of the sound device's
# consumed position. That needs something consuming the stream. With no audio clip
# covering the playhead there is nothing, and the chain has no clock anywhere in it:
# audio_producer_feed breaks out of its fill loop on the first uncovered frame, so
# next_frame never advances, so dev_frame -- published from next_frame, never from a
# timer -- never advances, and the playhead sits on its starting frame for the whole
# run. A STALL, not a freeze-with-sound: `playing` stays true and the frame never moves.
#
# Measured before the fix (VYPER_AUTOPLAY on a video with no audio track), identical
# at HEAD, so not a regression from the scrub work:
#
#	[ui]  ph=0 dev=0 ... current=true playing=true -> ph=0
#
# for every tick of the run.
#
# This also covers the wall-clock path's OTHER user: BACKWARD playback has always
# needed the wall clock for the same reason (audio is muted going backward). That code
# was inline in playback_update and is now the shared playback_wall_clock_advance, so a
# copy of the accumulator, the catch-up counter, the boundary stop and the boost reset
# exists once and both callers get it.
#
# The fixture is a real video with NO audio track -- the whole point is that
# audio_streams == 0, and a fixture that quietly had an audio lane would test nothing.
target_silent_playback() {
	require_fresh_binary silent-playback || return 1
	mkdir -p "$PROXY_DIR"
	local src="$PROXY_DIR/silent.mp4"
	if [ ! -s "$src" ]; then
		dev ffmpeg -y -f lavfi -i "testsrc2=size=640x360:rate=30:duration=3" \
			-c:v libx264 -pix_fmt yuv420p -an "$src" >/dev/null 2>&1 || {
			echo "silent-playback: could not synthesize the silent fixture" >&2
			return 1
		}
	fi
	# Asserted on the fixture, not assumed: -an is what makes this the test it is.
	if ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$src" 2>/dev/null \
		| grep -q audio
	then
		echo "silent-playback: fixture has an audio track, so it would test nothing" >&2
		return 1
	fi
	# Exit status is deliberately ignored. The bug's most obvious symptom is that the
	# run NEVER ENDS -- a pinned playhead cannot reach the end of the clip, so it
	# cannot auto-stop, so the process is still going when the timeout takes it and
	# reports 124. Gating on the status would catch the stall for the wrong reason
	# ("the run errored") and would also fail this target on any unrelated crash.
	# The playhead's furthest reach is the assertion.
	local out
	out=$(VYPER_AUTOPLAY="$PWD/$src" VYPER_PLAY_TRACE=1 timeout 120 ./vyper 2>&1 || true)
	# The furthest frame the playhead reached. Zero is the bug: before the fix it
	# never left its starting frame.
	local max_ph
	max_ph=$(echo "$out" | sed -n 's/^\[ui\]  ph=\([0-9-]*\) .*/\1/p' \
		| sort -n | tail -1)
	if [ -z "$max_ph" ]; then
		echo "silent-playback: no playhead trace lines -- the probe never ran" >&2
		return 1
	fi
	echo "silent-playback: playhead reached frame ${max_ph} with no audio track"
	# Reported either way, because "the run never finished" is independent evidence of
	# the same stall: a playhead that advances reaches the clip end and auto-stops.
	if [ "$max_ph" -le 0 ]; then
		echo "$out" | grep -E '^\[ui\]  ph=' | tail -5 >&2
		echo "silent-playback: FAILED -- the playhead never advanced (the no-audio stall)" >&2
		return 1
	fi
	echo "silent-playback: ok (no audio track still plays, on the wall clock)"
}

# group_isolation: adjacent same-file audio clips at different clip speeds must each
# be mixed by a tempo graph built for their OWN speed. Found by fuzzing the user's own
# ~/sallyface.vyproj, where loading it tripped
#
#	audio_build_groups: one atempo graph cannot serve segments with different clip speed/pitch
#
# because two clips cut from the same file are contiguous in both timeline and source,
# which was every condition the grouping checked. The second was folded into the first's
# group and mixed at the first clip's tempo -- a 0.5x clip playing at 1x, which is
# audible as a clip that does not match its picture.
#
# The probe is sharp in BOTH directions: its first two clips are both 1.0x and
# contiguous, so they MUST share a decoder. A "different speeds never share" assertion
# would pass a fix that simply refuses to continue any group, breaking every ordinary
# multi-clip timeline.
# fuzz drives RANDOMISED actions over a REAL project through the same entry points the
# frame loop uses -- clay pointer state, interaction_click_dispatch, interaction_move,
# interaction_release, playback_update, interaction_post_build -- and asserts the
# invariants that must hold at every tick (playhead in range, transforms finite,
# selection addressable) plus the two that are the reported symptom: a release that
# moves the playhead FORWARD, and a tick that moves it further than the pointer asked.
#
# Takes a project path, so it is NOT in `all`: it needs a real session (the user runs
# it on their own). This is the tool that found the audio grouping bug, and its first
# two versions were themselves broken in ways worth recording:
#
#   - it reported 600 clean iterations while arming ZERO scrubs, because it picked
#     scrub targets from the whole 359k-frame timeline and every one of them mapped off
#     the visible ruler. It now draws targets from the visible span, and it FAILS when
#     any action counter is zero -- a run that reached nothing is a broken harness, not
#     a clean one.
#   - it cancelled every drag, because it passed a zeroed mouse input to
#     interaction_post_build while the gesture was in flight, which reads as "no button
#     held". Interaction now gets the same input the move did.
#   - it never touched the audio engine, because probes dispatch before main()'s
#     audio_init: no device, so audio_producer_proc returned on its first line. It now
#     calls audio_init itself, and FAILS if the project has audio clips and the producer
#     never held a source.
target_fuzz() {
	require_fresh_binary fuzz || return 1
	local proj=${1:?}
	local iters=${2:-200}
	local seed=${3:-1}
	local log=target/valgrind
	mkdir -p "$log"
	local out="$log/fuzz-$seed.log"
	# stderr is kept, because the failures SDL reports and does not stop for -- the
	# out-of-bounds scissor, for one -- arrive there and nowhere else.
	if ! VYPER_FUZZ="$proj|$iters|$seed" timeout 1800 ./vyper >"$out" 2>&1; then
		grep -E '^\[fuzz\]' "$out" >&2
		echo "fuzz: FAILED on $proj (seed $seed) -- see $out" >&2
		return 1
	fi
	grep -E '^\[fuzz\] (loaded|clips by kind|[0-9]+ iterations|ok)' "$out"
	# The gate's half of the contract: SDL's assertions are the class of bug this
	# harness exists to surface, and the probe cannot see them.
	if grep -qE 'Assertion failure|runtime assertion' "$out"; then
		grep -E 'Assertion failure|runtime assertion' "$out" | head -5 >&2
		echo "fuzz: FAILED -- an assertion fired during the run" >&2
		return 1
	fi
	echo "fuzz: ok ($iters iterations, seed $seed)"
}

target_audio_group_isolation() {
	require_fresh_binary audio-group-isolation || return 1
	local src=target/mixparity/tempo_clicks_125ms.wav
	mkdir -p target/mixparity
	if [ ! -s "$src" ]; then
		target_audio_clip_tempo_alignment || return 1
	fi
	local out
	if ! out=$(VYPER_AUDIO_GROUP_ISOLATION="$PWD/$src" timeout 300 ./vyper 2>&1); then
		echo "$out" | grep -E '^\[ap\] group-isolation' >&2
		echo "audio-group-isolation: FAILED -- see the [ap] group-isolation lines above" >&2
		return 1
	fi
	echo "$out" | grep -E '^\[ap\] group-isolation'
	echo "audio-group-isolation: ok (each clip is mixed by a graph built for its own speed)"
}

# proxy_bg: the BACKGROUND segmented proxy builder, end to end -- enqueue, build the
# segments, serve a frame out of one, compare it against the same frame decoded from the
# source, then re-import and require the complete proxy to be recognised as a cache hit
# without enqueuing a rebuild.
#
# It had no gate target, which is why it was red for as long as it was. The failure was
# the probe's own: it asked the proxy for the source's LAST frame through a segment that
# carries PROXY_FRAME_TOLERANCE fewer frames, with no tolerance, while the source path
# immediately above it HAS one for exactly that case. Measured on a 90-frame 1080p source:
# the segment holds 88, and the editor copes by falling back to the source for an
# under-built edge segment.
target_proxy_bg() {
	require_fresh_binary proxy-bg || return 1
	local src=target/keyed_export/src.mp4
	if [ ! -s "$src" ]; then
		echo "proxy-bg: missing fixture $src" >&2
		return 1
	fi
	local out
	if ! out=$(VYPER_PROXY_BG_TEST="$PWD/$src" timeout 1800 ./vyper 2>&1); then
		echo "$out" | grep -E '^\[proxy-bg-test\]' >&2
		echo "proxy-bg: FAILED -- see the [proxy-bg-test] lines above" >&2
		return 1
	fi
	echo "$out" | grep -E '^\[proxy-bg-test\]'
	echo "proxy-bg: ok (segments build, serve, match the source, and re-import as a cache hit)"
}

target_image_decode_probe() {
	require_fresh_binary image-decode-probe || return 1
	mkdir -p "$PROXY_DIR"
	local rc=0
	local spec
	for spec in "still.jpg:1080x1920:-q:v 3" "wide.jpg:1920x1080:-q:v 3" "still.png:800x600:"; do
		local name="${spec%%:*}"
		local rest="${spec#*:}"
		local size="${rest%%:*}"
		local extra="${rest#*:}"
		local src="$PROXY_DIR/$name"
		if [ ! -s "$src" ]; then
			# shellcheck disable=SC2086
			dev ffmpeg -y -f lavfi -i "testsrc2=size=$size:rate=1" \
				-frames:v 1 $extra "$src" >/dev/null 2>&1 || {
				echo "image-decode-probe: could not synthesize $name" >&2
				return 1
			}
		fi
		local out
		if ! out=$(VYPER_IMAGE_DECODE_PROBE="$PWD/$src" timeout 300 ./vyper 2>&1); then
			echo "$out" | grep -E '^\[image-dec\]' >&2
			echo "image-decode-probe: FAILED for $name" >&2
			rc=1
			continue
		fi
		echo "$out" | grep -E '^\[image-dec\] fit='
	done
	[ "$rc" -eq 0 ] || return 1
	echo "image-decode-probe: ok (portrait/landscape stills decode to real pixels and hold)"
}

target_image_probe() {
	require_fresh_binary image-probe || return 1
	mkdir -p "$PROXY_DIR"
	local src="$PROXY_DIR/still.jpg"
	if [ ! -s "$src" ]; then
		dev ffmpeg -y -f lavfi -i "testsrc2=size=1080x1920:rate=1" \
			-frames:v 1 -q:v 3 "$src" >/dev/null 2>&1 || {
			echo "image-probe: could not synthesize the still fixture" >&2
			return 1
		}
	fi
	local out
	if ! out=$(VYPER_IMAGE_PROBE="$PWD/$src" timeout 300 ./vyper 2>&1); then
		echo "$out" >&2
		echo "image-probe: FAILED -- see the [image-probe] lines above" >&2
		return 1
	fi
	echo "$out" | grep -E '^\[image-probe\]'
	echo "image-probe: ok (a still image is Video+is_still and is never proxy-encoded)"
}

target_proxy_probe() {
	require_fresh_binary proxy-probe || return 1
	mkdir -p "$PROXY_DIR"
	# Its own synthesized source rather than $KEYED_SRC, because this probe
	# asserts the proxy's ENCODED DIMENSIONS and a 1080p source is what makes
	# half-resolution distinguishable from the 768x432 cap it replaced (at
	# smaller sizes both round to the same even number and the check would pass
	# for the wrong reason). Deterministic, so a cached copy is the same clip.
	if [ ! -s "$PROXY_SRC" ]; then
		if ! dev ffmpeg -y -f lavfi -i \
			"testsrc2=size=1920x1080:rate=30:duration=3" \
			-c:v libx264 -pix_fmt yuv420p -crf 18 "$PROXY_SRC" >/dev/null 2>&1
		then
			echo "proxy-probe: could not synthesize the source clip" >&2
			return 1
		fi
	fi
	# NOT $PROBE_ENV: that adds VYPER_UI_PROBE, which runs the ui probe first
	# and needs a media file this target does not have. The proxy probe is
	# standalone and supplies its own source.
	env VYPER_PROXY_PROBE="$PROXY_SRC" \
		timeout 900 ./vyper >"$PROXY_DIR/proxy.log" 2>&1
	local rc=$?
	# Remove the artifact the probe built, on EVERY path. A failing probe exits
	# through os.exit, which never reaches the probe's own cleanup, and a
	# leftover proxy is not inert: it sits in the cache under a key derived from
	# the CURRENT settings, so the next run treats it as a valid hit and asserts
	# against the previous run's broken artifact instead of rebuilding. One
	# failed run would otherwise poison every run after it.
	local built
	built=$(sed -n 's/^\[proxy-probe\] artifact-path: //p' "$PROXY_DIR/proxy.log" | head -1)
	if [ -n "$built" ] && [ -f "$built" ]; then
		rm -f "$built"
	fi
	tail -4 "$PROXY_DIR/proxy.log"
	# The probe deletes its artifact on the way out, so its own dimension
	# assertion is the coverage; this gate exists so the target is reachable
	# from `all` at all rather than only by hand.
	if [ $rc -ne 0 ]; then
		echo "proxy-probe: FAILED (exit $rc)" >&2
		return 1
	fi
	grep -q '^\[proxy-probe\] OK' "$PROXY_DIR/proxy.log" || {
		echo "proxy-probe: no OK line in log" >&2
		return 1
	}
}

# Preview/export parity (parity_probe.odin).
#
# The export used to take its frame rate from the FIRST VIDEO SOURCE rather than
# from the rate the frame grid is defined on. The two coincide only when that
# source is the grid-defining one, so a project whose first video clip was a
# still exported at the image demuxer's arbitrary rate (25/1 for a PNG here)
# while the timeline played at 12 -- one number retiming every keyed value,
# position and clip length, and a file whose duration did not match the preview
# by a factor of 2.08. Nothing caught it: the export path had no test that
# compared a rate against anything.
#
# The fixture is built to collide by construction -- a still imported FIRST so it
# is videos[0], then a 30 fps clip so the grid rate comes from the video. The
# probe asserts the precondition (the still's own reported rate must still
# differ from the grid's) rather than assuming it, because a future ffmpeg that
# made image streams report a sane rate would leave this gate unable to detect
# the bug and passing it would mean nothing.
#
# Verified to fail on the pre-fix chain: exit 1, "is muxed at 25/1 but the frame
# grid is 30". Also covers the rate resolver's own table -- the NTSC rationals
# and the seven invalid inputs that must be rejected -- which no end-to-end path
# can reach.
PARITY_DIR=target/parity
AUDIT_DIR=target/audio_audit
AUDIO_RATE_DIR=target/audio_rate

# The fixture media target_parity synthesizes, factored out because the valgrind
# twin needs the same two files and must not re-derive them (an ffmpeg build
# under valgrind would measure ffmpeg).
parity_fixture() {
	mkdir -p "$PARITY_DIR"
	# A PNG, because a still is the source whose reported rate is an artifact of
	# the image demuxer rather than of anything the user chose. Regenerated only
	# when absent, like the other fixtures: both are deterministic.
	if [ ! -s "$PARITY_DIR/still.png" ]; then
		if ! dev ffmpeg -y -f lavfi -i "color=c=red:s=320x240" \
			-frames:v 1 "$PARITY_DIR/still.png" >/dev/null 2>&1
		then
			echo "parity: could not synthesize the still" >&2
			return 1
		fi
	fi
	if [ ! -s "$PARITY_DIR/clip.webm" ]; then
		if ! dev ffmpeg -y -f lavfi -i \
			"testsrc=s=320x240:rate=30:duration=2" \
			-c:v libvpx -an "$PARITY_DIR/clip.webm" >/dev/null 2>&1
		then
			echo "parity: could not synthesize the 30 fps clip" >&2
			return 1
		fi
	fi
}

target_parity() {
	require_fresh_binary parity || return 1
	parity_fixture || return 1

	local log="$PARITY_DIR/parity.log"
	VYPER_PARITY_FIXTURE="$PARITY_DIR/still.png|$PARITY_DIR/clip.webm|$PARITY_DIR/out.mp4" \
		timeout 600 ./vyper >"$log" 2>&1
	local rc=$?
	grep -E '^\[parity-probe\]' "$log" || true
	if [ $rc -ne 0 ]; then
		echo "parity: FAILED (exit $rc) -- full log in $log" >&2
		return 1
	fi
	# The probe exits 0/1 on its own contract, but what it measured is a
	# container, so assert the file independently: it fails differently than the
	# probe does if the probe itself ever stops checking.
	local got
	got=$(dev ffprobe -v error -select_streams v:0 -show_entries \
		stream=r_frame_rate -of csv=p=0 "$PARITY_DIR/out.mp4")
	if [ "$got" != "30/1" ]; then
		echo "parity: $PARITY_DIR/out.mp4 is $got, expected 30/1" >&2
		return 1
	fi
	echo "parity: OK (export muxed at $got, matching the 30 fps grid)"
}

# The audio-rate-change regression check (audio_rate_probe.odin). It needs no
# fixture from disk: the probe synthesizes its own WAV (digital silence for the
# first 1.2s, a loud tone after) and builds the project, because the property
# under test is a relationship between a rate and a source offset -- an
# off-the-shelf clip either has a non-zero offset or does not.
#
# The defect: an audio clip's source offset was divided by the CURRENT project
# rate, so switching a 12fps project to 60fps moved it from 2.5s into the file
# to 0.5s -- into the silent head, i.e. silence. The probe asserts the offset is
# invariant across 12/24/30/60/120 fps, AND runs a negative control that unpins
# the clip and requires it to go silent, so the fixture cannot stop
# discriminating while still passing.
target_audio_rate() {
	require_fresh_binary audio-rate || return 1
	mkdir -p "$AUDIO_RATE_DIR"
	local wav="$AUDIO_RATE_DIR/fixture.wav"
	local out="$AUDIO_RATE_DIR/out.mp4"
	local log="$AUDIO_RATE_DIR/audio_rate.log"
	VYPER_AUDIO_RATE_FIXTURE="$wav|$out" timeout 600 ./vyper >"$log" 2>&1
	local rc=$?
	grep -E '^\[ar-probe\]' "$log" || true
	if [ $rc -ne 0 ]; then
		echo "audio-rate: FAILED (exit $rc) -- full log in $log" >&2
		return 1
	fi
	# Assert the EXPORTED file independently. The probe reads the pin off the
	# clip, so it cannot see a render-path regression: breaking
	# Render_Audio_Src.source_start_rate leaves the probe passing while the muxed
	# file goes silent. Measured -65 dB that way, against -7.8 dB here. Only
	# this check catches it.
	local mean
	mean=$(dev ffmpeg -hide_banner -nostats -ss 0.05 -to 0.35 -i "$out" \
		-af volumedetect -f null - 2>&1 | sed -n 's/.*mean_volume: \(-*[0-9.]*\) dB/\1/p')
	if [ -z "$mean" ]; then
		echo "audio-rate: could not measure $out" >&2
		return 1
	fi
	# -30 dB is far below the fixture's tone (-7.8 dB) and far above the
	# silence the defect produced (-65 dB), so this fails loudly either way.
	if awk "BEGIN{exit !($mean > -30)}"; then
		echo "audio-rate: OK (export carries the tone at $mean dB mean after a 12->60fps change)"
	else
		echo "audio-rate: $out is $mean dB mean, expected louder than -30 dB" >&2
		echo "audio-rate: the export read the wrong part of the source file" >&2
		return 1
	fi
}

# The memory gate for the parity probe. The probe is the one path that builds a
# timeline from nothing and then runs a real export inside the same process, so
# it is exactly the shape that orphans a buffer the shipped code never touches:
# the imports populate the session heap, the walk allocates per-clip snapshots,
# and the drain loop owns a readback buffer whose lifetime had to be moved into
# the caller to stop a use-after-free. Same four invariants as target_valgrind,
# plus the probe's own success line as the non-vacuity marker -- a run that died
# early would lose nothing and pass vacuously.
# parity_valgrind: what this target asserts, and the one number it tolerates.
#
# History, because the first version of this comment was wrong in a way the
# measurement contradicted. The claim was that the memory gate found a shipped
# leak -- the GPU resampler singleton the export worker creates had no
# success-path teardown. The teardown gap is real (create() releases everything
# again on each of its four FAILURE returns; nothing released it after a
# completed export) and gpu_resample_release now exists, because SDL requires
# GPU objects released before the video subsystem goes down. But deleting that
# call changes the leak totals by ZERO bytes. It was not what the number was
# measuring, and a comment claiming otherwise would be the same lie in reverse:
# naming a fix for a leak the fix does not close.
#
# What the number WAS measuring was the probe's own exit. The export worker calls
# sdl.Init(VIDEO); the probe ended in os.exit, which skips main's
# `defer sdl.Quit()`, so 471 bytes were definitely lost before the exit was given
# a teardown. The real app already pairs Init with Quit -- this was a probe-exit
# bug, not a shipped one.
#
# So the target asserts three things that are ours, plus one named bound:
#   - no invalid free/read/write (this is what caught the probe's own
#     use-after-free while it was being written);
#   - non-vacuity: a probe that died early would satisfy every bound for free;
#   - the SDL Init+Quit control is 0/0, proving the exit's teardown is complete
#     on the calling thread -- a leak there is ours and unconditional;
#   - the probe's definitely-lost stays inside the residue below, so a new leak
#     of any size still fails the gate.
#
# The residue is 72 bytes in 1 block from the sdl.Init(VIDEO) at
# render_gpu.odin:142, which the export WORKER THREAD issues; SDL's per-thread
# video state is orphaned when that thread exits and no later release call can
# reach it. One block per process, not per export. The control is run here
# rather than quoted from a comment: an earlier "SDL alone leaks 120 bytes"
# baseline was measured against a stale binary that never ran the control at
# all, which is precisely how a wrong baseline gets believed.
PARITY_SDL_WORKER_TLS_BYTES=72 # measured; see above
PARITY_SDL_WORKER_TLS_SLACK=64 # headroom for SDL version drift

# Echo "<definitely_lost_bytes> <indirectly_lost_bytes>" from a valgrind log.
valgrind_lost_bytes() {
	local log=$1
	local direct indirect
	direct=$(grep -oE 'definitely lost: [0-9,]+ bytes' "$log" | tail -1 | grep -oE '[0-9,]+' | tr -d ,)
	indirect=$(grep -oE 'indirectly lost: [0-9,]+ bytes' "$log" | tail -1 | grep -oE '[0-9,]+' | tr -d ,)
	echo "${direct:-0} ${indirect:-0}"
}

target_parity_valgrind() {
	require_fresh_valgrind_binary parity-valgrind || return 1
	parity_fixture || return 1
	mkdir -p target/valgrind
	local log=target/valgrind/parity.log
	local ctl=target/valgrind/parity_sdl_control.log

	VYPER_PARITY_SDL_CONTROL=1 timeout 300 valgrind --leak-check=full \
		--error-exitcode=99 "$VALGRIND_BIN" >"$ctl" 2>&1
	local ctl_rc=$?
	echo "parity-valgrind: SDL control exit=$ctl_rc (expected 99)"
	grep -q '\[parity-probe\] control: SDL_Init' "$ctl" || {
		echo "parity-valgrind: SDL control never ran -- baseline unknown" >&2
		return 1
	}

	VYPER_PARITY_FIXTURE="$PARITY_DIR/still.png|$PARITY_DIR/clip.webm|$PARITY_DIR/out_valgrind.mp4" \
		timeout 900 valgrind --leak-check=full \
		--error-exitcode=99 "$VALGRIND_BIN" >"$log" 2>&1
	local rc=$?
	echo "parity-valgrind: exit=$rc (expected 99: FFmpeg/Odin noise)"

	# Same non-vacuity rule as valgrind_assert: a probe that died before doing any
	# work would satisfy every leak bound below for free.
	if ! grep -q 'output file reports' "$log"; then
		echo "parity-valgrind: probe never reported success -- vacuous pass" >&2
		tail -20 "$log" >&2
		return 1
	fi
	if grep -q "Unrecognised instruction" "$log"; then
		echo "parity-valgrind: memcheck died on an instruction VEX cannot decode -- vacuous pass" >&2
		return 1
	fi
	# An invalid access is never SDL's business, and this is the invariant that
	# caught the probe's own use-after-free while it was being written.
	if grep -qE "Invalid (free|read|write)" "$log"; then
		echo "parity-valgrind: invalid free/read/write" >&2
		grep -B2 -A8 -E "Invalid (free|read|write)" "$log" | head -40 >&2
		return 1
	fi

	local got ctl_bytes
	got=$(valgrind_lost_bytes "$log")
	ctl_bytes=$(valgrind_lost_bytes "$ctl")
	echo "parity-valgrind: probe lost/indirectly $(echo "$got" | tr ' ' '/') bytes; SDL Init+Quit control $(echo "$ctl_bytes" | tr ' ' '/') bytes; worker-thread residue allowance $((PARITY_SDL_WORKER_TLS_BYTES + PARITY_SDL_WORKER_TLS_SLACK))"

	local d i cd ci failed=0
	d=$(echo "$got" | cut -d' ' -f1)
	i=$(echo "$got" | cut -d' ' -f2)
	cd_=$(echo "$ctl_bytes" | cut -d' ' -f1)
	ci=$(echo "$ctl_bytes" | cut -d' ' -f2)
	# The control must be clean. It runs Init+Quit and the GPU release on the
	# calling thread, so a leak here is ours and unconditional.
	if [ "$cd_" != "0" ] || [ "$ci" != "0" ]; then
		echo "parity-valgrind: SDL control leaked $cd_/$ci bytes -- the release pairing on the calling thread is incomplete" >&2
		failed=1
	fi
	if [ "$d" -gt $((PARITY_SDL_WORKER_TLS_BYTES + PARITY_SDL_WORKER_TLS_SLACK)) ]; then
		echo "parity-valgrind: $d bytes definitely lost, allowance $((PARITY_SDL_WORKER_TLS_BYTES + PARITY_SDL_WORKER_TLS_SLACK)) -- more than the worker-thread SDL residue, so something of ours leaked" >&2
		failed=1
	fi
	[ $failed -ne 0 ] && return 1
	echo "parity-valgrind: ok (no invalid access; SDL control clean; definitely-lost within the worker-thread residue; full log: $log)"
}

# The audio engine's own acceptance measurement (TODO.md Active 22).
#
# Every other audio gate builds its OWN fixture — audio_probe, audio_rate_probe
# and atempo_probe all synthesize a WAV and construct a timeline. That is right
# for a regression suite and useless for the defect this section exists to close:
# the 133 mid-clip dropouts were measured on a real 12-source / 5-audio-track
# project with splits, and no synthetic timeline reproduces them. So the one
# number that decides whether the audio rework is done had no way to be
# re-measured after the fact. Same shape as the text-keyframe bug: a defect real
# workloads hit that the suite structurally cannot see.
#
# This target exports a real project and counts digital-silence runs in the
# RESULT, cross-referencing each one against the source recording so a run the
# source genuinely contains is not counted as a dropout. That cross-reference is
# the whole point: the recording is a screen capture of a mostly-silent room, so
# a naive silence count reports its own silence as engine dropouts.
#
# AUDIT_PROJECT selects the project; it SKIPs (not fails) when absent, since the
# file is machine-local and this must never break `all` on a box without it.
target_audio_export_audit() {
	require_fresh_binary audio-audit || return 1
	local proj=${AUDIT_PROJECT:-$HOME/sallyface.vyproj}
	if [ ! -s "$proj" ]; then
		echo "audio-audit: SKIP (no project at $proj -- set AUDIT_PROJECT)"
		return 0
	fi
	local dir="$AUDIT_DIR"
	mkdir -p "$dir"
	env VYPER_PROJECT_EXPORT="$proj|$dir/out.mp4" timeout 900 ./vyper >"$dir/export.log" 2>&1
	if ! grep -q "project-export status: Render complete" "$dir/export.log"; then
		echo "audio-audit: export did not complete -- see $dir/export.log" >&2
		tail -5 "$dir/export.log" >&2
		return 1
	fi
	ffmpeg -v error -i "$dir/out.mp4" -map 0:a -ac 1 -ar 48000 -f s16le "$dir/out.raw" -y || return 1
	# The grid comes from the app's own log line, not from the sample count.
	local grid
	grid=$(sed -n 's/^project-export: grid rate \([0-9.]*\).*/\1/p' "$dir/export.log" | head -1)
	if [ -z "$grid" ]; then
		echo "audio-audit: could not read the grid rate from the export log" >&2
		return 1
	fi
	python3 scripts/audio_silence_audit.py "$proj" "$dir/out.raw" "$dir/out.mp4" "$grid" || return 1
}

# atempo_probe. It has an entry point and it passes, but it was wired into
# NEITHER gate.sh NOR `all` until now -- so playback rate changes were verified by
# hand, once, and `all` could not catch a regression in the pitch-preserving path.
# Every other audio target here synthesizes its own fixture, so this costs nothing
# but a few seconds of CPU.
target_atempo_probe() {
	require_fresh_binary atempo-probe || return 1
	VYPER_ATEMPO_PROBE=ALL timeout 600 ./vyper 2>&1 | tail -1
}

# audio_mix_parity drives the playback mixer and the export mixer over the same
# timeline span and compares them sample for sample. It runs against TWO fixtures,
# because the interesting part is the DIFFERENCE between them:
#
#   wav  -- uncompressed, no encoder delay. Both mixers must be BIT-IDENTICAL.
#           This is the regression guard for the mixing arithmetic itself.
#   aac  -- encoder-delayed. This one CURRENTLY FAILS, and it fails because
#           neither sink can supply content 0 (see TODO.md Active 30 S4).
#
# It is a gate target rather than a case inside audio_probe precisely because of
# that: a red line inside `all` gets disabled, and a check nobody runs proves
# nothing. Run it to see the state; do not wire it into `all` until it is green.
target_audio_mix_parity() {
	require_fresh_binary audio-mix-parity || return 1
	local wav=target/mixparity/src.wav
	local aac=target/audio_probe/src.mp4
	local rc=0
	if [ ! -s "$wav" ]; then
		echo "audio-mix-parity: synthesizing the no-encoder-delay fixture" >&2
		mkdir -p target/mixparity
		ffmpeg -v error -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=10" \
			-ac 2 -c:a pcm_s16le "$wav" -y || return 1
	fi
	if [ ! -s "$aac" ]; then
		echo "audio-mix-parity: no AAC fixture at $aac -- run scripts/gate.sh audio_probe first" >&2
		return 1
	fi
	# The green half: identical arithmetic, no codec delay in the way.
	VYPER_AUDIO_MIX_PARITY="$PWD/$wav" timeout 600 ./vyper 2>&1 | tail -2
	[ ${PIPESTATUS[0]} -ne 0 ] && rc=1
	# The red half: the encoder-delay case. Reported, not swallowed, and not
	# allowed to hide the green half's verdict by running second.
	VYPER_AUDIO_MIX_PARITY="$PWD/$aac" timeout 600 ./vyper 2>&1 | tail -2
	[ ${PIPESTATUS[0]} -ne 0 ] && rc=1
	if [ $rc -ne 0 ]; then
		echo "audio-mix-parity: FAILED (known; TODO.md Active 30 S4)" >&2
		return 1
	fi
	echo "audio-mix-parity: ok"
}

# audio_drift_parity is the LONG version of audio_mix_parity: it runs both mixers
# continuously over a span long enough for an ACCUMULATED position error to show,
# at a fractional frame rate as well as an exact one.
#
# It covers the two holes Active 30 S6b/S6c named. Every rate measured until now
# was 60 or 30 EXACTLY, where a mixer that rounds per frame instead of per position
# is indistinguishable from one that does not -- at 30000/1001 a frame is 1601 or
# 1602 samples, alternating forever, so per-frame rounding drifts without ever
# showing a single-frame error. And nothing ran longer than 30 s, which is too
# short for drift to accumulate past a frame boundary.
#
# The fixture is generated rather than committed: a multi-minute AAC file is
# megabytes of binary for a test that only needs it to be long and 48 kHz.
target_audio_drift_parity() {
	require_fresh_binary audio-drift-parity || return 1
	local wav=target/mixparity/long.wav
	local aac=target/mixparity/long.m4a
	local src=$aac
	local secs=600
	local rc=0
	mkdir -p target/mixparity
	if [ ! -s "$wav" ] || [ ! -s "$aac" ]; then
		echo "audio-drift-parity: synthesizing a ${secs}s fixture" >&2
		# 5% longer than the span under test. A clip that claims exactly the whole
		# source is asking for the encoder's padding: AAC's tail is not decodable
		# content, so the last ~21ms is a shortfall rather than audio, and a
		# shortfall is not what this probe is measuring.
		local fixture_secs=$(awk "BEGIN{print $secs * 1.05}")
		ffmpeg -v error -f lavfi -i "anoisesrc=color=white:sample_rate=48000:duration=$fixture_secs:amplitude=0.5:seed=7" \
			-ac 2 -c:a pcm_s16le "$wav" -y || return 1
		ffmpeg -v error -i "$wav" -c:a aac -b:a 128k "$aac" -y || return 1
	fi
	# Broadband noise, deliberately. A pure tone -- 997 Hz was the first choice --
	# is coprime with 60, 30000/1001 and 48000, so a rounded boundary does show as
	# phase error, but it has a 48.1-sample period at 48 kHz, which makes
	# cross-correlation ambiguous: every shift differing by a period correlates
	# just as well, so the "best shift" cannot localise anything within ~48
	# samples. Chasing that produced a confident number that meant nothing.
	#
	# Noise has no period, so the correlation has one peak. It also exposes
	# rounding MORE sharply than a tone: a boundary rounded by one sample moves
	# every sample after it against uncorrelated noise, which is the largest
	# possible error rather than a phase wobble that partly cancels.
	for spec in "600|60" "600|29.97" "600|30"; do
		printf '[gate] drift %ss at %s fps\n' "${spec%%|*}" "${spec##*|}"
		VYPER_AUDIO_DRIFT_PARITY="$PWD/$src|${spec%%|*}|${spec##*|}" timeout 1800 ./vyper 2>&1 | tail -2
		[ ${PIPESTATUS[0]} -ne 0 ] && rc=1
	done
	if [ $rc -ne 0 ]; then
		echo "audio-drift-parity: FAILED" >&2
		return 1
	fi
	echo "audio-drift-parity: ok"
}

# audio_stall_gap is the only probe that exercises the TRANSPORT rather than the
# mixers, and it exists to demonstrate the claim the audio-master design rests on:
# a producer stall costs the listener a GAP and no subsequent offset.
#
# It cannot be provoked from outside. SIGSTOP freezes the device callback too --
# it is in-process -- so freezing the process is not a producer-only stall. So the
# device is SIMULATED (a software ring behind audio_device_push/_queued/
# _available/_clear) and the probe runs in real time, draining the simulation at
# exactly the bus rate. The producer under test is the real one, and a "stall" is
# the probe declining to call it, which is the condition being claimed about.
#
# Asserted every tick outside the stall: dev_pos == fed - queued; and on EVERY tick,
# including the stall: the resync count does not move. That last one is the whole
# claim -- a resync re-anchors, and a re-anchor is a silent shift of the playhead,
# which is the single thing this design cannot tolerate. The probe also requires
# that the device actually ran dry and that the queue climbed back to the cushion,
# so it cannot pass by doing nothing.
target_audio_stall_gap() {
	require_fresh_binary audio-stall-gap || return 1
	local src=target/mixparity/long.m4a
	if [ ! -s "$src" ]; then
		echo "audio-stall-gap: no fixture at $src -- run scripts/gate.sh audio_drift_parity first" >&2
		return 1
	fi
	VYPER_AUDIO_STALL_GAP="$PWD/$src|900" timeout 300 ./vyper 2>&1 | tail -2
	local rc=${PIPESTATUS[0]}
	if [ $rc -ne 0 ]; then
		echo "audio-stall-gap: FAILED -- a stall did not produce a clean gap" >&2
		return 1
	fi
	echo "audio-stall-gap: ok"
}

# audio_node_latency pins the two delays in the audio graph. It is a gate target
# because both upcoming features depend on them -- clip stretching and audio
# scrubbing are SEEKS, and a delay is a seek that lands late -- and because a
# libavfilter or FFmpeg bump can move either number without anything else noticing.
#
# swr is read from the resampler's own API, with a 1:1 passthrough as the control
# that makes the number believable. atempo is measured by ACCOUNTING
# (pushed/rate - produced), which needs no waveform, no threshold and no window, and
# is remeasured and compared for repeatability.
#
# The two methods that do NOT work are recorded in the probe, because they are the
# obvious ones: impulse correlation cannot locate anything in WSOLA output (which is
# reassembled from overlapping segments, not shifted), and energy onset quantises to
# its own analysis window. Both produced confident numbers that meant nothing.
target_audio_node_latency() {
	require_fresh_binary audio-node-latency || return 1
	VYPER_AUDIO_NODE_LATENCY=1 timeout 900 ./vyper 2>&1 | tail -6
	local rc=${PIPESTATUS[0]}
	if [ $rc -ne 0 ]; then
		echo "audio-node-latency: FAILED" >&2
		return 1
	fi
	echo "audio-node-latency: ok"
}

# audio_scrub_exact proves a SEEK lands on the content sample the timeline says belongs
# there, unstretched and stretched.
#
# Scrubbing is the one gesture that is pure seeking, so it is where a position mapping is
# easiest to get wrong and hardest to notice: a clip a few hundred samples out still
# sounds like itself, and the only symptom is the playhead and the audio disagreeing.
# Nothing else in the audio suite would catch it.
#
# Three assertions, because a position bug can hide in any one of them:
#   - the mapping audio_content_sample_at_speed, against the closed form, at several
#     speeds and with a NON-ZERO source offset (the two errors are additive, and the
#     offset is where the second one hides);
#   - MONOTONICITY across the whole range, since a mapping that ever goes backwards lets a
#     forward seek replay audio the playhead has already passed;
#   - the ROUND TRIP, which needs the speed AND the source offset divided back out.
target_audio_scrub_exact() {
	require_fresh_binary audio-scrub-exact || return 1
	VYPER_AUDIO_SCRUB_EXACT=1 timeout 600 ./vyper
	local rc=$?
	if [ $rc -ne 0 ]; then
		echo "audio-scrub-exact: FAILED -- see the [ap] scrub lines above" >&2
		return 1
	fi
	echo "audio-scrub-exact: ok (seek lands on the timeline's content sample)"
}

# audio_clip_stretch proves the STRETCH gesture's invariant: changing a clip's speed must
# not move the clip on the timeline.
#
# Arithmetic on a Clip, against the same accessor the renderer reads. It cannot be checked
# by eye: the clip looks like it stays put WHILE dragging, because the gesture recomputes
# the duration from the value captured at press -- so the drift, if the arithmetic were
# wrong, would only show up after release.
#
# The check is deliberately two-sided. A stretch that changed NOTHING would also pass a
# "span stayed put" assertion, so the probe also asserts the content length actually
# follows the speed, and that an out-of-range speed clamps rather than asserts.
target_audio_clip_stretch() {
	require_fresh_binary audio-clip-stretch || return 1
	VYPER_AUDIO_CLIP_STRETCH=1 timeout 300 ./vyper
	local rc=$?
	if [ $rc -ne 0 ]; then
		echo "audio-clip-stretch: FAILED -- see the [ap] stretch lines above" >&2
		return 1
	fi
	echo "audio-clip-stretch: ok (timeline span fixed at every speed)"
}

# audio_backward_scrub proves a PLAYHEAD MOVE reaches the AUDIO, which is a different
# question from whether the playhead line moves. The user-facing report was "I can move
# the playhead, playback just isn't set to it" -- two pieces of state (playhead.frame,
# and the producer's position plus its decoder anchors) that can disagree.
#
# A MEMBER OF `all`. It pins the regression this replaces: audio_seek and a geometry edit
# share one resync counter, so routing seeks through the reconcile silently redefined
# them, and a seek is invisible to a comparison of the geometry before and after because
# a seek changes neither.
target_audio_backward_scrub() {
	require_fresh_binary audio-backward-scrub || return 1
	local src=target/mixparity/tempo_clicks_125ms.wav
	mkdir -p target/mixparity
	if [ ! -s "$src" ]; then
		target_audio_clip_tempo_alignment || return 1
	fi
	local out
	if ! out=$(VYPER_AUDIO_BACKWARD_SCRUB="$PWD/$src" timeout 300 ./vyper 2>&1); then
		echo "$out" >&2
		echo "audio-backward-scrub: FAILED -- see the [ap] scrub lines above" >&2
		return 1
	fi
	echo "$out" | grep -E '^\[ap\] scrub'
	echo "audio-backward-scrub: ok (playhead move rewinds the producer, drops the queue, re-anchors the decoder)"
}

# audio_seek_landing proves WHERE a seek lands, by content, on the playback producer
# path. Every other seek check reads state (next_frame rewound, queue dropped,
# decoder re-anchored) or renders through the export mixer, and all of them passed
# while the producer emitted audio half a second off: the fifo was labelled at the
# decoder's preroll landing and left too short to cover the demand, so the mixer
# read it as a hole and zeroed the output. This one mixes the playback path and
# compares the first transient against the export mixer's, on the click fixture.
target_audio_seek_landing() {
	require_fresh_binary audio-seek-landing || return 1
	local src=target/mixparity/tempo_clicks_125ms.wav
	mkdir -p target/mixparity
	if [ ! -s "$src" ]; then
		target_audio_clip_tempo_alignment || return 1
	fi
	local out
	if ! out=$(VYPER_AUDIO_SEEK_LANDING="$PWD/$src" timeout 300 ./vyper 2>&1); then
		echo "$out" >&2
		echo "audio-seek-landing: FAILED -- see the [ap] seek-landing lines above" >&2
		return 1
	fi
	echo "$out" | grep -E '^\[ap\] seek-landing'
	echo "audio-seek-landing: ok (every seek lands on the requested content sample)"
}

# audio_clip_tempo proves the clip TEMPO property changes DURATION and leaves pitch
# alone, across the whole buildable speed range 0.25x .. 4.0x.
#
# A MEMBER OF `all`, because the measurement is finally sound. Three earlier versions
# read numbers out of the playback mixer and every one was fooled:
#
#  - Pulse density on a click track is confounded, because WSOLA reaches its factor by
#    REPEATING and DISCARDING segments, which moves transient density for reasons that
#    are not the speed. It read 1.01x at 0.5 and 1.35x at 3.0 while getting 1.5 exactly
#    right -- right in the middle and wrong at both ends is not a measurement.
#  - Counting decoded content, and reading content_used, are both swamped by the pump's
#    chunked read-ahead and report ~1.0x at EVERY speed. A gate that passes for the
#    wrong reason is worse than no gate.
#  - Raw output sample counts are worse still: the producer PREFILLS its rings, so at
#    speed 0.25 an 8 s window returned 1113600 samples -- 23.2 s of audio from a span
#    that asked for 8 s. The prefetch is correct behaviour; it is simply not a clock.
#
# What it measures instead, with nothing confounded:
#
#  - THE DSP, on an isolated graph. Push N1 then N2 frames and difference:
#
#        factor = (out(N2) - out(N1)) / (N2 - N1)   ==   1/speed
#
#    The DIFFERENCE is what makes it exact. A single run's out/in is biased low by a
#    fixed number of output samples still held inside WSOLA -- the graph's actual
#    lookahead -- and reading it as a ratio made every speed look 1-2% slow. That
#    bias is the same constant at every speed, so differencing divides it out without
#    needing a model of graph holdback.
#
#  - THE GEOMETRY, as arithmetic on a Clip: timeline span == content / speed.
target_audio_clip_tempo() {
	require_fresh_binary audio-clip-tempo || return 1
	VYPER_AUDIO_CLIP_TEMPO=1 timeout 1800 ./vyper
	local rc=$?
	if [ $rc -ne 0 ]; then
		echo "audio-clip-tempo: FAILED -- see the [ap] tempo lines above" >&2
		return 1
	fi
	echo "audio-clip-tempo: ok (isolated factor exact, clip geometry exact)"
}

# audio_clip_tempo_alignment proves the ACTUAL clip pump preserves content zero through
# decoder FIFO -> atempo -> output ring, both at clip start and after an interior seek.
# The synthetic PCM fixture has 10 ms pulses every 125 ms, including source sample zero;
# the 0.5 s timeline seek maps to a pulse boundary at every tested speed. This catches
# skipped FIFO heads, stale output rings, and any tempo lookahead discard independently
# of the isolated graph-factor test.
target_audio_clip_tempo_alignment() {
	require_fresh_binary audio-clip-tempo-alignment || return 1
	local src=target/mixparity/tempo_clicks_125ms.wav
	mkdir -p target/mixparity
	if [ ! -s "$src" ]; then
		ffmpeg -v error -f lavfi \
			-i "aevalsrc='cos(2*PI*440*t)*lt(mod(t\\,0.125)\\,0.01)':s=48000:d=12" \
			-ac 2 -c:a pcm_s16le "$src" -y || return 1
	fi
	for speed in 0.25 0.5 0.75 1.5 2.0 3.0 4.0; do
		local out
		if ! out=$(VYPER_AUDIO_CLIP_TEMPO_ALIGNMENT="$PWD/$src|$speed" timeout 600 ./vyper 2>&1); then
			echo "$out" >&2
			echo "audio-clip-tempo-alignment: FAILED at speed $speed" >&2
			return 1
		fi
		echo "$out" | grep -E '^\[ap\] clip-alignment'
	done
	local out
	if ! out=$(VYPER_AUDIO_CLIP_TEMPO_EDIT="$PWD/$src" timeout 600 ./vyper 2>&1); then
		echo "$out" >&2
		echo "audio-clip-tempo-alignment: FAILED on active 1x -> 2x edit" >&2
		return 1
	fi
	echo "$out" | grep -E '^\[ap\] clip-edit-alignment'
	echo "audio-clip-tempo-alignment: ok (opening, interior seek, and active speed/pitch edits preserve content origin)"
}

# Valgrind the actual per-clip tempo pump, including its content FIFO, filter graph,
# output ring, reset path and probe buffers. This is the allocation/release gate for the
# newly exercised seek path; parity_valgrind is a separate export target.
target_audio_clip_tempo_alignment_valgrind() {
	require_fresh_valgrind_binary audio-clip-tempo-alignment-valgrind || return 1
	local src=target/mixparity/tempo_clicks_125ms.wav
	if [ ! -s "$src" ]; then
		target_audio_clip_tempo_alignment || return 1
	fi
	mkdir -p target/valgrind
	local log=target/valgrind/audio_clip_tempo_alignment.log
	env VYPER_AUDIO_CLIP_TEMPO_ALIGNMENT="$PWD/$src|2.0" timeout 1200 valgrind \
		--leak-check=full --error-exitcode=99 "$VALGRIND_BIN" >"$log" 2>&1
	valgrind_assert "$log" audio-clip-tempo-alignment-valgrind '\[ap\] clip-alignment ok'
	local edit_log=target/valgrind/audio_clip_tempo_edit_alignment.log
	env VYPER_AUDIO_CLIP_TEMPO_EDIT="$PWD/$src" timeout 1200 valgrind \
		--leak-check=full --error-exitcode=99 "$VALGRIND_BIN" >"$edit_log" 2>&1
	valgrind_assert "$edit_log" audio-clip-tempo-edit-alignment-valgrind '\[ap\] clip-edit-alignment ok'
}

# Bus atempo must preserve input sample zero. FFmpeg pads its initial WSOLA
# half-window internally; synthetic-silence priming advances that timeline and
# discards genuine opening audio. The probe feeds real input immediately and
# verifies the first transient at each supported transport rate.
target_audio_bus_prime() {
	require_fresh_binary audio-bus-prime || return 1
	local failed=0
	for r in 0.25 0.5 0.75 1.5 2.0 3.0 4.0; do
		local out line
		if ! out=$(VYPER_AUDIO_BUS_PRIME=$r timeout 300 ./vyper 2>&1); then
			echo "audio-bus-prime: FAILED to run at rate $r" >&2
			echo "$out" | tail -8 >&2
			failed=1
			continue
		fi
		line=$(printf '%s\n' "$out" | grep -F "first transient at output sample" | head -1 || true)
		if [[ "$line" != *"sample 0 (want 0)"* ]]; then
			echo "audio-bus-prime: FAILED at rate $r: ${line:-no alignment result}" >&2
			echo "$out" | tail -8 >&2
			failed=1
		else
			echo "  rate $r: origin aligned; device clock accounts for WSOLA holdback"
		fi
	done
	if [ "$failed" -ne 0 ]; then
		return 1
	fi
	echo "audio-bus-prime: ok (sample origin and device clock conserved at all tested rates)"
}

# audio_bus_rate_transition changes transport speed while the simulated hardware device
# drains real producer output. Rebuilding atempo changes its queue's time scale, so the
# producer must capture audible position BEFORE destroying the old graph, clear old-rate
# PCM, reconcile sources there, then continue with the new graph. A stale-queue
# reinterpretation would jump the playhead or schedule mixed-rate audio.
target_audio_bus_rate_transition() {
	require_fresh_binary audio-bus-rate-transition || return 1
	local src=target/mixparity/long.m4a
	if [ ! -s "$src" ]; then
		echo "audio-bus-rate-transition: no fixture at $src -- run scripts/gate.sh audio_drift_parity first" >&2
		return 1
	fi
	VYPER_AUDIO_BUS_RATE_TRANSITION="$PWD/$src" timeout 600 ./vyper
	local rc=$?
	if [ $rc -ne 0 ]; then
		echo "audio-bus-rate-transition: FAILED -- see the [ap] rate-transition lines above" >&2
		return 1
	fi
	echo "audio-bus-rate-transition: ok (audible frame monotonic through rate changes)"
}

# audio_clip_pitch proves the pitch property SHIFTS frequency WITHOUT changing
# duration -- which is the whole distinction between pitch and tempo, and therefore
# between the two clip properties.
#
# Two assertions, separately, because a property that got them backwards would pass
# either one alone:
#
#   - LENGTH must be EXACTLY unchanged. A pitched clip occupies the same timeline as the
#     same clip unpitched. This is what stops a pitch control behaving like a speed
#     control, and it is exact rather than approximate.
#   - FREQUENCY must move by 2^(n/12). Counted by zero crossings, which is exact for a
#     pure tone and needs no FFT.
#
# The frequency tolerance is 5% because a one-octave shift is arithmetically exact
# (asetrate 96000 then aresample 48000 is 2:1) and the residual is the resampler's
# filter plus the windowing of the crossing count. Measured 2.0284 against 2.0.
target_audio_clip_pitch() {
	require_fresh_binary audio-clip-pitch || return 1
	local src=target/mixparity/tone.m4a
	if [ ! -s "$src" ]; then
		echo "audio-clip-pitch: synthesising a tone fixture" >&2
		mkdir -p target/mixparity
		ffmpeg -v error -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=30" \
			-ac 2 -c:a aac -b:a 128k "$src" -y || return 1
	fi
	local rc=0
	for semi in 12 -12 7 -5; do
		VYPER_AUDIO_CLIP_PITCH="$PWD/$src|$semi" timeout 300 ./vyper >/dev/null 2>&1
		[ $? -ne 0 ] && { echo "audio-clip-pitch: FAILED at $semi semitones" >&2; rc=1; }
	done
	if [ $rc -ne 0 ]; then
		return 1
	fi
	echo "audio-clip-pitch: ok (frequency shifts, length never changes)"
}

target_all() {
	local t
	# render_valgrind was deliberately excluded here while it failed on two
	# pre-existing export/import-path leaks. Both are fixed (the encoder had no
	# teardown call at all, and the decoder never freed its destination image),
	# so it is now a member: the leaks it exists to catch were all reachable
	# from the export path, which no other target in this list executes.
	#
	# audio_probe and keyframe_probe were reachable but absent here, so a
	# regression either caught was invisible to `all` -- including the forward-
	# jump case, which fails if a jump decodes the audio it skipped instead of
	# seeking. Both degrade to SKIP rather than fail when no audio device is
	# present, so they cost a synthetic fixture on a headless box.
	for t in check build probe transform_probe geom_key_probe render_kf_probe render_live_probe timeline_probe session_str_probe session_kf_probe session_trk_probe session_marker_probe dnd_probe action_log parity audio_rate image_probe image_decode_probe silent_playback audio_group_isolation audio_probe audio_mix_parity audio_drift_parity audio_stall_gap audio_node_latency audio_bus_prime audio_bus_rate_transition audio_scrub_exact audio_backward_scrub audio_seek_landing audio_clip_stretch audio_clip_tempo audio_clip_tempo_alignment audio_clip_tempo_alignment_valgrind audio_clip_pitch atempo_probe keyframe_probe yuv_exact gpu_nv12 gpu_composite opacity gpu_probe keyed_export zorder subtitle_probe proxy_probe smoke valgrind geom_key_valgrind undo_valgrind render_valgrind render_live_valgrind dnd_valgrind action_log_valgrind parity_valgrind; do
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
	keyframe_probe) target_keyframe_probe ;;
	render_kf_probe) target_render_kf_probe ;;
	audio_probe) target_audio_probe ;;
	geom_key_probe) target_geom_key_probe ;;
	geom_key_valgrind) target_geom_key_valgrind ;;
	render_live_probe) target_render_live_probe ;;
	decode_repeat) target_decode_repeat ;;
	render_live_valgrind) target_render_live_valgrind ;;
	undo_valgrind) target_undo_valgrind ;;
	timeline_probe) target_timeline_probe ;;
	session_str_probe) target_session_str_probe ;;
	session_kf_probe) target_session_kf_probe ;;
	session_trk_probe) target_session_trk_probe ;;
	session_marker_probe) target_session_marker_probe ;;
	dnd_probe) target_dnd_probe ;;
	action_log) target_action_log ;;
	parity) target_parity ;;
	audio_rate) target_audio_rate ;;
	audio_export_audit) target_audio_export_audit ;;
	audio_mix_parity) target_audio_mix_parity ;;
	audio_drift_parity) target_audio_drift_parity ;;
	audio_stall_gap) target_audio_stall_gap ;;
	audio_node_latency) target_audio_node_latency ;;
	audio_clip_tempo) target_audio_clip_tempo ;;
	audio_clip_tempo_alignment) target_audio_clip_tempo_alignment ;;
	audio_clip_tempo_alignment_valgrind) target_audio_clip_tempo_alignment_valgrind ;;
	audio_clip_stretch) target_audio_clip_stretch ;;
	audio_scrub_exact) target_audio_scrub_exact ;;
	audio_backward_scrub) target_audio_backward_scrub ;;
	audio_seek_landing) target_audio_seek_landing ;;
	audio_bus_prime) target_audio_bus_prime ;;
	audio_bus_rate_transition) target_audio_bus_rate_transition ;;
	audio_clip_pitch) target_audio_clip_pitch ;;
	atempo_probe) target_atempo_probe ;;
	dnd_valgrind) target_dnd_valgrind ;;
	action_log_valgrind) target_action_log_valgrind ;;
	parity_valgrind) target_parity_valgrind ;;
	yuv_exact) target_yuv_exact ;;
	gpu_nv12) target_gpu_nv12 ;;
	gpu_composite) target_gpu_composite ;;
	opacity) target_opacity ;;
	gpu_probe) target_gpu_probe ;;
	keyed_export) target_keyed_ab ;;
	zorder) target_zorder ;;
	render_valgrind) target_render_valgrind ;;
	subtitle_probe) target_subtitle_probe ;;
	proxy_probe) target_proxy_probe ;;
	image_probe) target_image_probe ;;
	image_decode_probe) target_image_decode_probe ;;
	proxy_bg) target_proxy_bg ;;
	audio_group_isolation) target_audio_group_isolation ;;
	fuzz) shift; target_fuzz "$@" ;;
	silent_playback) target_silent_playback ;;
	smoke) target_smoke ;;
	footprint) target_footprint "${2:-20}" ;;
	valgrind) target_valgrind ;;
	export_bench) target_export_bench ;;
	all) target_all ;;
	*)
		echo "usage: $SELF [check|shaders|build|bench|probe|transform_probe|session_str_probe|session_kf_probe|session_trk_probe|session_marker_probe|geom_key_probe|render_kf_probe|geom_key_valgrind|undo_valgrind|timeline_probe|dnd_probe|action_log|action_log_valgrind|dnd_valgrind|parity_valgrind|keyframe_probe|image_probe|image_decode_probe|proxy_bg|silent_playback|fuzz <project.vyproj> [iters] [seed]|audio_group_isolation|audio_probe|audio_export_audit|atempo_probe|audio_drift_parity|audio_stall_gap|audio_node_latency|audio_clip_tempo|audio_clip_tempo_alignment|audio_clip_tempo_alignment_valgrind|audio_bus_prime|audio_bus_rate_transition|audio_clip_pitch|audio_clip_stretch|audio_scrub_exact|audio_backward_scrub|audio_seek_landing|yuv_exact|gpu_nv12|gpu_composite|opacity|gpu_probe|keyed_export|zorder|parity|subtitle_probe|proxy_probe|render_valgrind|smoke|valgrind|export_bench|footprint|all]" >&2
		return 2
		;;
	esac
}

main "$@"
