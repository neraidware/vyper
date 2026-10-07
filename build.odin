#!/usr/bin/env -S sh -c 'exec odin run "$0" -file -- "$@"'
package main

// The build. Read main and you have the whole thing; everything below it is
// plumbing.
//
// Run it from the repository root. `odin run -file` executes a temp binary with
// argv[0] set to that binary's name, so this cannot find its own directory and
// every path below (./vyper, ./packaging) is relative to where you invoked it.
//
//	./build.odin [check|debug|release|install]
//	odin run build.odin -file [-- check|debug|release|install]
//	VYPER_MODE=release ./build.odin
//
// The shebang is `sh -c 'exec odin run "$0" -file -- "$@"'` rather than a direct
// `odin run -file`, because a direct shebang cannot forward arguments: `env -S`
// puts the script path before them and `odin run` reads the rest as targets, so
// `./build.odin install` died in odin before this file ran. Going through sh is
// what puts the `--` in the right place. VYPER_MODE still works for the mode.
//
// debug (default) is -o:none with frame pointers, symbols and bounds checks.
// release and install are -o:aggressive. None passes -no-bounds-check: it
// cancels the debug build's bounds checking, so an out-of-range index prints
// garbage instead of failing.

// ---------------------------------------------------------------------------
// Configuration
//
// The things worth changing: what the package is called, what each mode compiles
// to, and what has to be built before the compiler runs.
// ---------------------------------------------------------------------------

PKG :: "vyper"

// Package scope: returning a compound literal of a slice hands back the frame's
// stack.
DEBUG_FLAGS   := []string{"-debug"}
RELEASE_FLAGS := []string{"-o:aggressive"}

// Editing a .frag and building without recompiling keeps the OLD SPIR-V and the
// run reports the previous shader's results as the new one. That happened here,
// so an unlisted shader fails the build.
SHADERS := [8]string{
	"rounded_rect.vert",
	"rounded_rect.frag",
	"quad.vert",
	"text.frag",
	"blit_box.frag",
	"blit_lod.frag",
	"nv12_luma.frag",
	"nv12_chroma.frag",
}

// The vendored C files. Where the object lands is per-platform (see clay_obj),
// because the archive directory is named after the OS.
C_SOURCES := [2]string{
	PKG + "/vendor/nanosvg/nanosvg.c",
	PKG + "/vendor/clay.c",
}

main :: proc() {
	mode := resolve_mode()
	// An install builds into <prefix>/build and copies from there, so the build
	// tree and the installed tree stay separate and a re-run cannot half-update
	// an installed copy.
	prefix := install_prefix() if mode == "install" else ""
	opt := mode_flags(mode)
	odin := join_or_empty({resolve_odin_root(), "odin"})
	out := output_path()
	if prefix != "" {
		out = join_or_empty({prefix, "build", strings.concatenate({"vyper", exe_ext()}, context.temp_allocator)})
	} else if !strings.has_suffix(out, exe_ext()) {
		// The default output is a bare name, and on Windows that needs the .exe.
		out = strings.concatenate({out, exe_ext()}, context.temp_allocator)
	}

	if mode != "check" {
		build_shaders()
		build_c_deps()
	}

	// -debug here is load-bearing: odin check does not compile a
	// `when ODIN_DEBUG` branch without it, so this would validate the release
	// view and report clean while the default build went unverified.
	fmt.println("==> Checking Odin")
	run_or_die(
		odin,
		{"check", PKG, "-debug", "-strict-style", "-vet-using-param", "-vet-using-stmt"},
		"check",
	)
	if mode == "check" {
		// The flags above are the only copy of them now. gate.sh used to spell
		// this command out again, which meant the gate validated one flag set
		// while the build used another, and nothing noticed when they diverged.
		return
	}

	fmt.println("==> Building Vyper")
	mkdir_of(out)
	build_args: [dynamic]string
	append(&build_args, "build", PKG)
	append(&build_args, strings.concatenate({"-out:", out}, context.temp_allocator))
	// No `append(xs, ys...)` in Odin, and each group is conditionally present.
	for f in opt {
		append(&build_args, f)
	}
	for f in odin_extra_flags() {
		append(&build_args, f)
	}
	append(
		&build_args,
		strings.concatenate({"-extra-linker-flags:", linker_flags()}, context.temp_allocator),
	)
	run_or_die(odin, build_args[:], "build")

	if prefix != "" {
		install_files(prefix, out)
	}
	fmt.printf("==> Done: %s\n", out)
}

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Backing for the strings that cross a proc boundary as views.
MODE_BUF: [64]u8
ROOT_BUF: [1024]u8
OUT_BUF:  [1024]u8
INST_BUF: [1024]u8

// ---------------------------------------------------------------------------
// Mode and paths
// ---------------------------------------------------------------------------

resolve_mode :: proc() -> string {
	if len(os.args) > 1 {
		return os.args[1]
	}
	mode := os.get_env("VYPER_MODE", context.allocator)
	defer delete(mode)
	if mode == "" {
		return "debug"
	}
	// Copied out: the get_env string is deleted here, so returning it hands the
	// caller freed memory.
	n := min(len(mode), len(MODE_BUF) - 1)
	copy(MODE_BUF[:n], mode[:n])
	return transmute(string)MODE_BUF[:n]
}

// A view into OUT_BUF, so the caller owns nothing and the CONSTANT default
// never reaches `delete`.
output_path :: proc() -> string {
	out := os.get_env("VYPER_OUT", context.allocator)
	defer delete(out)
	if out == "" {
		return "target/vyper"
	}
	n := copy(OUT_BUF[:], out)
	return transmute(string)OUT_BUF[:n]
}

mode_flags :: proc(mode: string) -> []string {
	switch mode {
	case "debug":
		return DEBUG_FLAGS[:]
	case "release", "install":
		assert_probes_gated()
		return RELEASE_FLAGS[:]
	case "check":
		// Typecheck only; nothing is compiled, so no build flags apply.
		return {}
	case:
		fmt.eprintf("error: unknown build mode '%s' (expected: check | debug | release)\n", mode)
		os.exit(2)
	}
}

// install_prefix is where `install` puts things: $INSTALL_PREFIX, or ~/.local.
//
// ~/.local rather than /usr/local, because an install that needs root to run is
// an install people do not run, and it matches the per-user convention the proxy
// cache already uses here.
//
// A view into a buffer, like the other two: the env strings are deleted here.
install_prefix :: proc() -> string {
	prefix := os.get_env("INSTALL_PREFIX", context.allocator)
	defer delete(prefix)
	if prefix != "" {
		n := copy(INST_BUF[:], prefix)
		return transmute(string)INST_BUF[:n]
	}
	home, herr := os.user_home_dir(context.allocator)
	defer delete(home)
	if herr != nil || home == "" {
		fmt.eprintln("error: no INSTALL_PREFIX, and no home directory to default to.")
		os.exit(1)
	}
	local := strings.concatenate({home, "/.local"}, context.temp_allocator)
	n := copy(INST_BUF[:], local)
	return transmute(string)INST_BUF[:n]
}

// The FHS layout: binaries in bin, the menu entry in share/applications, the
// icon where the desktop entry's Icon= name resolves.
INSTALL_FILES := [2]struct{src, dst, mode: string}{
	{"packaging/vyper.desktop", "share/applications/vyper.desktop", "0644"},
	{"packaging/vyper.svg", "share/icons/hicolor/scalable/apps/vyper.svg", "0644"},
}

install_files :: proc(prefix, binary: string) {
	// install(1) rather than cp+mkdir+chmod: -D makes the parent dirs and the
	// mode are one step, so there is no ordering to get wrong.
	run_or_die("install", {"-Dm755", binary, join_or_empty({prefix, "bin", "vyper"})}, "install")
	for f in INSTALL_FILES {
		dst := join_or_empty({prefix, f.dst})
		mode := strings.concatenate({"-Dm", f.mode}, context.temp_allocator)
		run_or_die("install", {mode, f.src, dst}, "install")
		fmt.printf("    %s\n", dst)
	}
}

// ---------------------------------------------------------------------------
// Toolchain
// ---------------------------------------------------------------------------

// A stale ODIN_ROOT fails with "directory does not exist" and never mentions that
// it points at a compiler that has been replaced. So it is validated, and when it
// is wrong we walk up from the odin on PATH.
resolve_odin_root :: proc() -> string {
	root, has := os.lookup_env("ODIN_ROOT", context.allocator)
	defer delete(root)
	if has && os.is_dir(join_or_empty({root, "base"})) {
		// Copied out, like every other string crossing a proc boundary here: the
		// get_env allocation is deleted by the defer, so returning it hands the
		// caller freed memory. It only showed up once gate.sh and nix set
		// ODIN_ROOT, because that is the only path that returns this branch.
		n := min(len(root), len(ROOT_BUF) - 1)
		copy(ROOT_BUF[:], root[:n])
		return transmute(string)ROOT_BUF[:n]
	}

	odin_bin := locate_tool("odin")
	if odin_bin == "" {
		fmt.eprintln("error: odin not found on PATH.  mise install provisions it.")
		os.exit(1)
	}
	candidate, _ := os.split_path(odin_bin)
	for candidate != "" && !os.is_dir(join_or_empty({candidate, "base"})) {
		candidate, _ = os.split_path(candidate)
	}
	if candidate == "" {
		fmt.eprintf("error: no Odin tree at or above %s.\n", odin_bin)
		os.exit(1)
	}
	if has {
		fmt.eprintf("==> ODIN_ROOT '%s' is not an Odin tree; using %s\n", root, candidate)
	}
	return candidate
}

// linker_flags is the -extra-linker-flags value.
//
// --sysroot=/ so the driver resolves ffmpeg/SDL3/glib from / rather than from
// whatever sysroot the compiler carries.
//
// VYPER_LINK_FLAGS replaces the lot, for a platform whose link line cannot be
// expressed here (the Windows build names .lib import libraries and a subsystem).
//
// VYPER_LINKER names the linker, and the default is mold wherever it exists:
// on a binary this size it is the one part of the build where the linker, not
// the code, sets the wall clock. "none" asks for the compiler's own, and so does
// a host with no mold -- that fallback changes link speed, not behaviour. The
// nix package pins gold, because mold and lld both fail to resolve Odin's
// absolute -l: namespecs inside the sandbox.
linker_flags :: proc() -> string {
	// Read on the TEMP arena and never deleted: the result is temp-arena memory
	// the caller formats into a flag and does not own. Deleting it here freed
	// the string being returned.
	if f := os.get_env("VYPER_LINK_FLAGS", context.temp_allocator); f != "" {
		return f
	}
	when ODIN_OS == .Windows {
		// The SDL3 and ffmpeg import libs were staged by hand into deps\lib, and
		// the binary is a GUI app that returns from WinMain directly.
		lib := join_or_empty({current_dir(), "deps", "lib"})
		return strings.concatenate(
			{"/LIBPATH:", lib, " /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup"},
			context.temp_allocator,
		)
	}

	flags := "--sysroot=/ -lavcodec -lavformat -lavutil -lswresample -lswscale -lgio-2.0 -lglib-2.0"
	want := os.get_env("VYPER_LINKER", context.temp_allocator)
	if want == "" {
		want = "mold" if locate_tool("mold") != "" else "none"
	}
	if want != "none" {
		// Said out loud: the linker is the one input to the build that this host
		// decides rather than the repo, so it is the one worth being able to see.
		fmt.printf("    linker: %s\n", want)
		flags = strings.concatenate({"-fuse-ld=", want, " ", flags}, context.temp_allocator)
	}
	return flags
}

// odin_extra_flags are defines the build needs on this platform. Windows links
// the ffmpeg import libraries by name, which is what FFMPEG_LINK=system selects.
odin_extra_flags :: proc() -> []string {
	when ODIN_OS == .Windows {
		WINDOWS_FLAGS := []string{"-define:FFMPEG_LINK=system"}
		return WINDOWS_FLAGS[:]
	}
	return {}
}

// exe_ext is what the built binary is called.
exe_ext :: proc() -> string {
	when ODIN_OS == .Windows {
		return ".exe"
	}
	return ""
}

current_dir :: proc() -> string {
	dir, err := os.get_working_directory(context.allocator)
	if err != nil {
		return ""
	}
	return dir
}

// ---------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------

// The guarantee a release build needs: no probe in the shipped binary. This was
// once enforced by copying the tree minus the probes and building there, but
// `cp -a . target/release-src` recurses into target/ and its errors went to
// /dev/null, so a partial copy silently dropped source files. A check cannot
// half-copy anything.
assert_probes_gated :: proc() {
	dir, err := os.open(PKG)
	if err != nil {
		fmt.eprintf("error: cannot read ./%s (%v) -- run build.odin from the repo root.\n", PKG, err)
		os.exit(1)
	}
	defer os.close(dir)
	entries, rerr := os.read_dir(dir, 0, context.allocator)
	if rerr != nil {
		return
	}
	// A File_Info owns its name, so nothing that outlives this proc may hold one.
	defer for e in entries {
		os.file_info_delete(e, context.allocator)
	}
	slice.sort_by(entries[:], proc(a, b: os.File_Info) -> bool { return a.name < b.name })

	ungated := 0
	for e in entries {
		if !strings.has_suffix(e.name, "_probe.odin") {
			continue
		}
		probe := join_or_empty({PKG, e.name})
		if !file_has_gate(probe) {
			// No braces: Odin's fmt reads `{` as a placeholder.
			fmt.eprintf("error: %s has no file-scope when-ODIN_DEBUG gate\n", probe)
			ungated += 1
		}
	}
	if ungated != 0 {
		fmt.eprintf("error: %d probe file(s) are not gated out of release\n", ungated)
		os.exit(1)
	}
}

file_has_gate :: proc(path: string) -> bool {
	// Heap, not the temp arena: this proc owns the buffer and deletes it.
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return false
	}
	defer delete(data)
	return strings.contains(string(data), "when ODIN_DEBUG {")
}

build_shaders :: proc() {
	fmt.println("==> Compiling shaders")
	// Required, not optional. A host without it used to fall back to the
	// committed .spv, so whether the shaders were recompiled depended on the
	// machine -- and a silently stale .spv is exactly the failure the shader
	// list exists to catch.
	if locate_tool("glslangValidator") == "" {
		fmt.eprintln("error: glslangValidator not found; the shaders are compiled on every build.")
		os.exit(1)
	}
	// Every shader, every build. Skipping one whose .spv looked fresh made the
	// output depend on what was already in the tree, which is the one thing a
	// reproducible build cannot do: the same sources produced two binaries
	// depending on whether someone had built once. It also means the committed
	// .spv is a cache, never an input.
	dir := join_or_empty({PKG, "shaders"})
	for name in SHADERS {
		src := join_or_empty({dir, name})
		spv := strings.concatenate({src, ".spv"}, context.temp_allocator)
		run_or_die("glslangValidator", {"-V", src, "-o", spv}, "shaders")
	}
}

// clay_obj is where the clay object goes. The archive sits beside it, in a
// directory named after the OS, which is the naming the prebuilt archives used.
clay_obj :: proc() -> string {
	when ODIN_OS == .Windows {
		return join_or_empty({PKG, "clay-odin", "windows", "clay.obj"})
	}
	return join_or_empty({PKG, "clay-odin", "linux", "clay.o"})
}

clay_lib :: proc() -> string {
	when ODIN_OS == .Windows {
		return join_or_empty({PKG, "clay-odin", "windows", "clay.lib"})
	}
	return join_or_empty({PKG, "clay-odin", "linux", "clay.a"})
}

nanosvg_obj :: proc() -> string {
	when ODIN_OS == .Windows {
		return join_or_empty({PKG, "vendor", "nanosvg", "nanosvg.obj"})
	}
	return join_or_empty({PKG, "vendor", "nanosvg", "nanosvg.o"})
}

// compile_c builds one vendored C file.
//
// The toolchain is per-platform. On unix it is clang, which is also the link
// driver Odin shells out to: Odin's -linker: cannot name a different driver, so
// gcc would compile these and then fail at the link on a missing clang. On
// Windows it is MSVC, because that is what links the .lib import libraries that
// Odin's SDL3 and ffmpeg bindings name.
compile_c :: proc(src, obj: string) {
	when ODIN_OS == .Windows {
		fo := strings.concatenate({"/Fo", obj}, context.temp_allocator)
		run_or_die("cl", {"/nologo", "/O2", "/c", src, fo}, "C dependencies")
		return
	}
	run_or_die("clang", {"-c", "-O2", "-o", obj, src}, "C dependencies")
}

build_c_deps :: proc() {
	fmt.println("==> Building C dependencies")
	when ODIN_OS != .Windows {
		if locate_tool("clang") == "" {
			fmt.eprintln("error: clang not found (it builds vendor/*.c and drives the link).")
			os.exit(1)
		}
	}

	// Both files, every build: reusing a leftover .o made the output depend on
	// what was in the tree.
	objs := [2]string{nanosvg_obj(), clay_obj()}
	for src, i in C_SOURCES {
		obj := objs[i]
		mkdir_of(obj)
		compile_c(src, obj)
	}

	lib := clay_lib()
	when ODIN_OS == .Windows {
		out := strings.concatenate({"/OUT:", lib}, context.temp_allocator)
		run_or_die("lib", {"/nologo", out, clay_obj()}, "C dependencies")
		return
	}
	run_or_die("ar", {"rcs", lib, clay_obj()}, "C dependencies")
}

// ---------------------------------------------------------------------------
// Plumbing
// ---------------------------------------------------------------------------

run :: proc(tool: string, args: []string) -> int {
	// Process_Desc.command is the whole argv, so the tool is argv[0].
	command := make([dynamic]string, 0, len(args) + 1, context.allocator)
	defer delete(command)
	append(&command, tool)
	for a in args {
		append(&command, a)
	}
	process, err := os.process_start({command = command[:]})
	if err != nil {
		fmt.eprintf("error: could not run %s: %v\n", tool, err)
		return -1
	}
	state, werr := os.process_wait(process)
	if werr != nil {
		fmt.eprintf("error: waiting for %s: %v\n", tool, werr)
		return -1
	}
	return state.exit_code
}

run_or_die :: proc(tool: string, args: []string, what: string) {
	code := run(tool, args)
	if code == 0 {
		return
	}
	fmt.eprintf("build: %s failed (%s exited %d)\n  command: %s", what, tool, code, tool)
	for a in args {
		fmt.eprintf(" %s", a)
	}
	fmt.eprintln()
	os.exit(1)
}

// core:os has no PATH locator, and this runs before anything else is known to
// work -- a build that dies inside its own helper is worse than one that dies
// inside a compile.
locate_tool :: proc(tool: string) -> string {
	suffix := ""
	when ODIN_OS == .Windows {
		suffix = ".exe"
	}
	// The suffix goes in the NAME: os.exists("clang/") is false for a regular
	// file, which reads as "clang is not installed".
	name := strings.concatenate({tool, suffix}, context.temp_allocator)
	list_sep: [1]u8 = {byte(filepath.LIST_SEPARATOR)}
	dirs := strings.split(
		os.get_env("PATH", context.temp_allocator),
		transmute(string)list_sep[:],
		context.temp_allocator,
	)
	for dir in dirs {
		full, jerr := filepath.join({dir, name}, context.temp_allocator)
		if jerr != nil {
			continue
		}
		if os.exists(full) {
			return strings.clone(full, context.allocator)
		}
	}
	return ""
}

mkdir_of :: proc(path: string) {
	dir, _ := os.split_path(path)
	if dir == "" {
		return
	}
	// _all, not _directory: an output like target/a/b/v is two levels deep.
	if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
		fmt.eprintf("error: could not create %s: %v\n", dir, err)
		os.exit(1)
	}
}

// The paths here cannot fail to join, so an error return would only add a branch.
join_or_empty :: proc(elems: []string) -> string {
	joined, jerr := filepath.join(elems, context.temp_allocator)
	if jerr != nil {
		return ""
	}
	return joined
}