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

# mold cuts link time noticeably on this binary, but it is not installed on
# every host and its absence must not fail the build: the linker choice is
# purely a speed decision, so fall back to the toolchain default (gold/bfd).
# Detected rather than hardcoded so the fast path is kept wherever it exists.
MOLD_FLAG=""
if command -v mold >/dev/null 2>&1; then
    MOLD_FLAG="-fuse-ld=mold"
fi

odin build . \
    -out:vyper \
    -microarch:native \
    -o:aggressive \
    -no-bounds-check \
    -extra-linker-flags:"$MOLD_FLAG -lavcodec -lavformat -lavutil -lswresample -lswscale -lgio-2.0 -lglib-2.0"

echo "==> Done: ./vyper"
