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

# clang is a hard requirement twice over: it compiles vendor/*.c below, and it
# is the driver Odin shells out to when it links the executable. Odin's -linker:
# flag only selects between its own backends (default/lld/radlink/mold) and
# cannot name a different driver, so there is no $CC-style override here — gcc
# would compile the two C files and then hand the final link back to a clang
# that is not installed, failing later and further from the cause. Checked up
# front so the error names the program instead of surfacing as Odin's
# "Could not spawn subprocess: No such file or directory".
if ! command -v clang >/dev/null 2>&1; then
    echo "error: clang not found." >&2
    echo "  It builds vendor/*.c AND is the link driver Odin uses." >&2
    echo "  System package:  sudo pacman -S clang    (Debian/Ubuntu: apt install clang)" >&2
    echo "  See .mise.toml for why this one is not provisioned by mise." >&2
    exit 1
fi

# Same freshness rule the shader loop above uses: skip an object already newer
# than its source. These two files never change between Odin-only edits, and
# recompiling them on every build means a worktree with no artifacts looks like
# a build failure when nothing about the C moved. `ar` still runs so the
# archive always matches the object next to it.
if [ ! -f vendor/nanosvg/nanosvg.o ] || [ vendor/nanosvg/nanosvg.c -nt vendor/nanosvg/nanosvg.o ]; then
    clang -c -O2 \
        -o vendor/nanosvg/nanosvg.o \
        vendor/nanosvg/nanosvg.c
fi

mkdir -p clay-odin/linux

if [ ! -f clay-odin/linux/clay.o ] || [ vendor/clay.c -nt clay-odin/linux/clay.o ]; then
    clang -c -O2 \
        -o clay-odin/linux/clay.o \
        vendor/clay.c
fi

ar rcs \
    clay-odin/linux/clay.a \
    clay-odin/linux/clay.o

echo "==> Checking Odin"

# One rule, one place: scripts/toolchain.sh also backs scripts/gate.sh, which
# invokes the compiler independently and was failing on the same stale value.
. scripts/toolchain.sh
resolve_odin_root

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

# --sysroot=/ is the system root, and that is the point: this binary links
# against the SYSTEM ffmpeg/SDL3/glib, so the driver has to resolve them from /
# and not from whatever sysroot the compiler happens to carry. A plain system
# clang already searches there, so the flag is a no-op for it. A compiler
# supplied by a toolchain (mise, conda, vfox) is built around its own bundled
# sysroot and will otherwise fail at "cannot find -lavcodec" — or, worse, with
# -L/usr/lib forced in, link while leaving avformat's transitive deps
# (libswresample.so.7, libavutil.so.61, libvpx.so.12) unresolved, which is a
# build that passes and an executable that dies on the first call into ffmpeg.
# Naming the root the libraries actually live under is the honest form of that
# search path, and it keeps one binary from needing a different invocation
# depending on who installed the compiler.
odin build . \
    -out:"$OUT" \
    "${MICROARCH[@]}" \
    "${OPT[@]}" \
    -no-bounds-check \
    -extra-linker-flags:"$MOLD_FLAG --sysroot=/ -lavcodec -lavformat -lavutil -lswresample -lswscale -lgio-2.0 -lglib-2.0"

echo "==> Done: ./$OUT"

