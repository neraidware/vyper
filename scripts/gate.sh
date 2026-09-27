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
	for t in check build probe gpu_probe smoke valgrind; do
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
	smoke) target_smoke ;;
	valgrind) target_valgrind ;;
	all) target_all ;;
	*)
		echo "usage: $SELF [check|shaders|build|bench|probe|gpu_probe|smoke|valgrind|all]" >&2
		return 2
		;;
	esac
}

main "$@"
