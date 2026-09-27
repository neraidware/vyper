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
		for src in shaders/blit.vert shaders/blit_box.frag shaders/blit_lod.frag; do
			glslangValidator -V --target-env vulkan1.1 "$src" -o "$src.spv"
		done
	'
}

target_build() {
	target_shaders
	nix develop -c odin build . -debug -vet-style -vet-semicolon -out:vyper
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
	if [ ! -x ./vyper ]; then
		echo "gpu-probe: ./vyper missing, run scripts/gate.sh build first" >&2
		return 1
	fi
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

keyed_export_run() {
	if [ ! -x ./vyper ]; then
		echo "keyed-export: ./vyper missing, run scripts/gate.sh build first" >&2
		return 1
	fi
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
	env $PROBE_ENV timeout 120 ./vyper
}

# The app must still be running when the timeout kills it; 124 is the pass.
target_smoke() {
	timeout 4 ./vyper
	local rc=$?
	if [ $rc -ne 124 ]; then
		echo "smoke: exited $rc, expected 124 (timeout kill of a healthy run)" >&2
		return 1
	fi
	echo "smoke: ok (124)"
}

target_valgrind() {
	local log
	log=$(mktemp)
	env $PROBE_ENV timeout 900 valgrind --leak-check=full \
		--error-exitcode=99 ./vyper >"$log" 2>&1
	local rc=$?

	# Ownership claims this codebase makes, asserted rather than eyeballed.
	# A new leak or a bad free is a regression; the FFmpeg/Odin error contexts
	# are pre-existing and tracked by count, not by exit code.
	local failed=0
	if ! grep -q "definitely lost: 0 bytes in 0 blocks" "$log"; then
		echo "valgrind: memory was definitely lost" >&2
		grep -A6 "definitely lost in loss record" "$log" | head -40 >&2
		failed=1
	fi
	if ! grep -q "indirectly lost: 0 bytes in 0 blocks" "$log"; then
		echo "valgrind: memory was indirectly lost" >&2
		failed=1
	fi
	if grep -qE "Invalid (free|read|write)" "$log"; then
		echo "valgrind: invalid free/read/write" >&2
		grep -B2 -A8 -E "Invalid (free|read|write)" "$log" | head -40 >&2
		failed=1
	fi

	# Report the noise baseline explicitly so a jump in contexts is visible
	# even though it does not fail the gate on its own.
	echo "valgrind: exit=$rc (expected 99: FFmpeg/Odin noise)"
	grep -E "definitely lost|indirectly lost|possibly lost|still reachable" "$log" || true
	grep "$VALGRIND_KNOWN_NOISE" "$log" || true

	if [ $failed -ne 0 ]; then
		echo "valgrind: FAILED — see $log" >&2
		return 1
	fi
	echo "valgrind: ok (no leaks, no invalid access; full log: $log)"
}

target_all() {
	local t
	for t in check build probe gpu_probe keyed_export smoke valgrind; do
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
	gpu_probe) target_gpu_probe ;;
	keyed_export) target_keyed_ab ;;
	smoke) target_smoke ;;
	valgrind) target_valgrind ;;
	all) target_all ;;
	*)
		echo "usage: $SELF [check|shaders|build|bench|probe|gpu_probe|keyed_export|smoke|valgrind|all]" >&2
		return 2
		;;
	esac
}

main "$@"
