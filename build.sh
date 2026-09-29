#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "==> Compiling shaders"

for shader in \
    shaders/rounded_rect.vert \
    shaders/rounded_rect.frag \
    shaders/quad.vert \
    shaders/text.frag \
    shaders/blit_box.frag \
    shaders/blit_lod.frag \
    shaders/nv12_luma.frag \
    shaders/nv12_chroma.frag
do
    # Skip a shader whose SPIR-V is already newer than its source. Recompiling
    # unconditionally would bump the .spv mtime on every build, and
    # require_fresh_binary rightly treats a fresh .spv as "the binary is stale" --
    # so building the valgrind binary would knock ./vyper out of date even
    # though no shader had changed.
    if [ "$shader.spv" -nt "$shader" ]; then
        continue
    fi
    glslangValidator -V "$shader" -o "$shader.spv"
done

echo "==> Building C dependencies"

clang -c -O2 \
    -o vendor/nanosvg/nanosvg.o \
    vendor/nanosvg/nanosvg.c

mkdir -p clay-odin/linux

clang -c -O2 \
    -o clay-odin/linux/clay.o \
    vendor/clay.c

ar rcs \
    clay-odin/linux/clay.a \
    clay-odin/linux/clay.o

echo "==> Checking Odin"

odin check . \
    -strict-style \
    -vet-using-param \
    -vet-using-stmt

echo "==> Building Vyper"

# The output name and the microarch are overridable so the memory gate can
# build a Valgrind-compatible binary out of the same flags instead of
# duplicating them (AGENTS.md §10: flags live here, not in someone's head).
OUT="${VYPER_OUT:-vyper}"
# -microarch:native lets LLVM emit AVX-512, which Valgrind's VEX cannot
# decode: the binary dies with SIGILL in math_big::initialize_constants during
# __$startup_runtime, BEFORE main. Valgrind then reports "0 definitely lost"
# for a process that allocated nothing, and the memory gate passes while
# measuring nothing. Setting VYPER_MICROARCH= (empty) drops to the baseline
# x86-64 target Valgrind does understand; -o:aggressive is not arch-specific
# and stays.
MICROARCH=(-microarch:native)
if [ "${VYPER_MICROARCH-native}" != "native" ]; then
	MICROARCH=()
fi

# The release build omits frame pointers, so memcheck cannot unwind Odin frames:
# every allocation trace came back as "calloc <- runtime::heap_allocator_proc
# <- ??? <- ???", which names the defect site no better than no trace at all.
# -debug supplies frame pointers and symbols, so a leak points at the proc that
# allocated it. Set alongside VYPER_MICROARCH= by the memory gate; -debug and
# -o:aggressive are mutually exclusive, so the optimization level follows.
OPT=(-o:aggressive)
if [ "${VYPER_DEBUG-0}" != "0" ]; then
	OPT=(-debug)
fi

# mold cuts link time noticeably on this binary, but it is not installed on
# every host and its absence must not fail the build: the linker choice is
# purely a speed decision, so fall back to the toolchain default (gold/bfd).
# Detected rather than hardcoded so the fast path is kept wherever it exists.
MOLD_FLAG=""
if command -v mold >/dev/null 2>&1; then
	MOLD_FLAG="-fuse-ld=mold"
fi

odin build . \
    -out:"$OUT" \
    "${MICROARCH[@]}" \
    "${OPT[@]}" \
    -no-bounds-check \
    -extra-linker-flags:"$MOLD_FLAG -lavcodec -lavformat -lavutil -lswresample -lswscale -lgio-2.0 -lglib-2.0"

echo "==> Done: ./$OUT"

