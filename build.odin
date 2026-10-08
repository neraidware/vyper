#!/usr/bin/env -S sh -c 'exec odin run "$0" -file -- "$@"'
package main

// The build. Read main and you have the whole thing; everything below it is
// plumbing.
//
// Run it from the repository root. `odin run -file` executes a temp binary with
// argv[0] set to that binary's name, so this cannot find its own directory and
// every path below (./vyper, ./packaging) is relative to where you invoked it.
//
//	./build.odin [check|debug|release|run|install]
//	odin run build.odin -file -- [check|debug|release|run|install]
//	VYPER_MODE=release ./build.odin
//
// Both invocation forms are supported and do the same thing: `./build.odin` is
// the shebang above, and `odin run build.odin -file --` is what a platform
// without it uses. PowerShell cannot execute an sh shebang at all -- no process
// starts, so an exit code is never set -- which is why the Windows job uses the
// second form and cannot use the first.
//
//	check    typecheck only; nothing is compiled, no build flags apply
//	debug    a debug binary (the default)
//	release  an optimised binary, with every probe proven gated out
//	run      compile and run without writing a binary
//	install  a release binary, plus the FHS copy into $INSTALL_PREFIX
//
// There is no separate "build" mode: it named the same thing as debug, and two
// names for one build is how a script ends up asking for a mode that does
// nothing. `install` stays because it is the one thing the nix packages cannot
// do -- they build inside a sandbox and copy the result into their own store.
//
// The shebang is `sh -c 'exec odin run "$0" -file -- "$@"'` rather than a direct
// `odin run -file`, because a direct shebang cannot forward arguments: `env -S`
// puts the script path before them and `odin run` reads the rest as targets, so
// `./build.odin install` died in odin before this file ran. Going through sh is
// what puts the `--` in the right place. VYPER_MODE still works for the mode.
//
// debug (default) is -o:none with frame pointers, symbols and bounds checks.
// release and install are -o:aggressive. Neither passes -no-bounds-check: it
// cancels the debug build's bounds checking, so an out-of-range index prints
// garbage instead of failing.
//
// Each mode writes its own binary: debug to target/debug, release to
// target/release. VYPER_OUT overrides the path, which is how `gate.sh` keeps one
// stable location (it names the binary in 66 places and checks its freshness)
// while nix takes the per-mode default.

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
SHADERS := [?]string{
	"rounded_rect.vert",
	"rounded_rect.frag",
	"quad.vert",
	"text.frag",
	"blit_box.frag",
	"blit_lod.frag",
	"nv12_luma.frag",
	"nv12_chroma.frag",
}

// The vendored C files. Where each one's object lands is DERIVED from its source
// (see object_for), so adding a file here cannot compile and then fail at run
// time against a parallel list nobody updated.
C_SOURCES := [?]string{
	PKG + "/vendor/nanosvg/nanosvg.c",
	PKG + "/vendor/clay.c",
}

main :: proc() {
	mode := resolve_mode()
	switch mode {
	case "check":
		check_mode()
	case "run":
		run_mode()
	case "debug":
		build_mode("debug")
	case "release":
		build_mode("release")
	case "install":
		install_mode()
	case:
		// No braces: Odin's fmt reads `{` as a placeholder.
		fmt.eprintf(
			"error: unknown build mode '%s' (expected: check | debug | release | run | install)\n",
			mode,
		)
		os.exit(2)
	}
}

check_mode :: proc() {
	fmt.println("==> Checking Odin")
	// -debug is load-bearing: `odin check` without it does not compile a
	// `when ODIN_DEBUG` branch, so this would validate the release view and
	// report clean while the default build went unverified.
	run_or_die(
		odin_tool(),
		{"check", PKG, "-debug", "-strict-style", "-vet-using-param", "-vet-using-stmt"},
		"check",
	)
}

run_mode :: proc() {
	run_or_die(odin_tool(), odin_args("run", "", DEBUG_FLAGS[:]), "run")
}

// build_mode compiles to output_path, after the shader and C prerequisites. One
// place assembles the argument vector, so debug and release cannot drift apart in
// a flag, and one place reports where the binary landed.
build_mode :: proc(mode: string) {
	opt := mode_flags(mode)
	// A release binary must carry no probe, and the guarantee is a scan rather
	// than a convention (see assert_probes_gated). Named by mode, not inferred
	// from a flag count: two modes sharing flags is exactly when that inference
	// starts asserting the wrong thing.
	if mode == "release" {
		assert_probes_gated()
	}
	build_shaders()
	build_c_deps()
	out := output_path(mode)
	mkdir_of(out)
	run_or_die(odin_tool(), odin_args("build", out, opt), "build")
	fmt.printf("==> Done: %s\n", out)
}

// install_mode is a release build plus the FHS copy, which is what the nix
// packages cannot do for themselves: they build in a sandbox and copy the result
// into their own store. It installs the binary THIS run wrote, named the way
// install(1) wants it, so an install cannot ship a stale path -- which is what the
// earlier version did, installing whatever `out` had been left as.
install_mode :: proc() {
	build_mode("release")
	prefix := install_prefix()
	binary := output_path("release")
	if !strings.has_suffix(binary, exe_ext()) {
		// VYPER_OUT may already carry it (Windows CI sets "vyper.exe"), and
		// appending unconditionally produced vyper.exe.exe.
		binary = strings.concatenate({binary, exe_ext()}, context.temp_allocator)
	}
	install_files(prefix, binary)
}

// install_prefix is where `install` puts things: $INSTALL_PREFIX, or ~/.local.
//
// ~/.local rather than /usr/local, because an install that needs root to run is
// an install people do not run, and it matches the per-user convention the proxy
// cache already uses here.
//
// A view into a buffer, like the other path helpers: the env strings are
// deleted here.
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

// odin_args is the one argv builder. `out` empty means no -out:, which is what
// `run` wants; flags the platform needs come after the mode's own.
odin_args :: proc(kind, out: string, opt: []string) -> []string {
	args := make([dynamic]string, 0, 12, context.temp_allocator)
	append(&args, kind, PKG)
	if out != "" {
		append(&args, strings.concatenate({"-out:", out}, context.temp_allocator))
	}
	// No `append(xs, ys...)` in Odin, hence the loops rather than two appends.
	for f in opt {
		append(&args, f)
	}
	for f in odin_extra_flags() {
		append(&args, f)
	}
	append(
		&args,
		strings.concatenate({"-extra-linker-flags:", linker_flags()}, context.temp_allocator),
	)
	return args[:]
}

odin_tool :: proc() -> string {
	return join_or_empty({resolve_odin_root(), "odin"})
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
		// debug, because `./build.odin` with no arguments is how `gate.sh build`
		// and the nix debug package build, and both want the debug binary.
		return "debug"
	}
	// Copied out: the get_env string is deleted here, so returning it hands the
	// caller freed memory.
	n := min(len(mode), len(MODE_BUF) - 1)
	copy(MODE_BUF[:n], mode[:n])
	return transmute(string)MODE_BUF[:n]
}

// output_path is where `mode`'s binary lands. A view into OUT_BUF, so the caller
// owns nothing and the constructed default never reaches `delete`.
output_path :: proc(mode: string) -> string {
	if out := os.get_env("VYPER_OUT", context.allocator); out != "" {
		defer delete(out)
		n := copy(OUT_BUF[:], out)
		return transmute(string)OUT_BUF[:n]
	}
	def := strings.concatenate(
		{"target/", mode_output_dir(mode), "/vyper", exe_ext()},
		context.temp_allocator,
	)
	n := copy(OUT_BUF[:], def)
	return transmute(string)OUT_BUF[:n]
}

// mode_output_dir is the directory under target/ that a mode's binary goes in.
// `install` builds a release, so it shares that directory; `run` writes no binary
// at all, so it never asks.
mode_output_dir :: proc(mode: string) -> string {
	switch mode {
	case "release", "install":
		return "release"
	case:
		return "debug"
	}
}

// mode_flags is a lookup, and deliberately has no side effects: the probe gate
// is asserted from build_mode, where the mode actually means something, rather
// than from the proc that answers "which flags does this mode use".
mode_flags :: proc(mode: string) -> []string {
	switch mode {
	case "debug", "run":
		return DEBUG_FLAGS[:]
	case "release", "install":
		return RELEASE_FLAGS[:]
	case "check":
		// Typecheck only; nothing is compiled, so no build flags apply.
		return {}
	case:
		return {}
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

// shader_compiler is glslang's command line under whichever name this host has it.
// Upstream renamed glslangValidator to glslang (same tool, same -V), and the 16.x
// Windows release zip ships only the new name, so a host with a current glslang and
// no compatibility link would otherwise be told it has no compiler. The old name wins
// when both exist, so a host that has always built keeps building the same way.
shader_compiler :: proc() -> string {
	for name in ([]string{"glslangValidator", "glslang"}) {
		if locate_tool(name) != "" {
			return name
		}
	}
	return ""
}

build_shaders :: proc() {
	fmt.println("==> Compiling shaders")
	// Required, not optional. A host without it used to fall back to the
	// committed .spv, so whether the shaders were recompiled depended on the
	// machine -- and a silently stale .spv is exactly the failure the shader
	// list exists to catch.
	compiler := shader_compiler()
	if compiler == "" {
		fmt.eprintln("error: glslangValidator (or glslang) not found; the shaders are compiled on every build.")
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
		run_or_die(compiler, {"-V", src, "-o", spv}, "shaders")
	}
}

// obj_ext is the platform's C object extension.
obj_ext :: proc() -> string {
	when ODIN_OS == .Windows {
		return "obj"
	}
	return "o"
}

// object_for is where one C source's object goes.
//
// Linux derives it from the source: `vyper/vendor/clay.c` -> `vyper/vendor/clay.o`,
// beside the source, which is the path .gitignore lists.
//
// Windows cannot: MSVC's `lib` builds an archive from objects RELATIVE TO THE
// ARCHIVE, so clay's object has to sit beside clay-odin/windows/clay.lib at
// `vyper/clay.obj`, not beside its source. Naming the one divergent path here,
// rather than deriving a wrong one, is why this returns different answers per
// platform. Caught by CI: the derived path made `lib` exit 1104.
// ar has no such rule (it takes the archive and the object as arguments), which
// is why the same code is fine on Linux and was never caught locally.
object_for :: proc(src: string) -> string {
	when ODIN_OS == .Windows {
		if strings.has_suffix(src, "clay.c") {
			// Concatenated, never joined, and with a BACKSLASH: filepath.join reads a
			// "." element as a path segment and absorbs it (yielding vyper\clay.obj,
			// the very path this branch avoids), and it emits the host separator, so on
			// Windows it produced the forward-slash `vyper/clay.obj` -- which `lib`
			// would not resolve beside the archive. CI caught that one too.
			return strings.concatenate({PKG, "\\clay.", obj_ext()}, context.temp_allocator)
		}
	}
	return strings.concatenate({strings.trim_suffix(src, ".c"), ".", obj_ext()}, context.temp_allocator)
}

// clay_lib is where the clay archive goes, in a directory named after the OS,
// which is the naming the prebuilt archives used.
clay_lib :: proc() -> string {
	when ODIN_OS == .Windows {
		return join_or_empty({PKG, "clay-odin", "windows", "clay.lib"})
	}
	return join_or_empty({PKG, "clay-odin", "linux", "clay.a"})
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

	// Every source, every build: reusing a leftover .o made the output depend on
	// what was in the tree.
	clay_obj := ""
	for src in C_SOURCES {
		obj := object_for(src)
		mkdir_of(obj)
		compile_c(src, obj)
		if strings.has_suffix(src, "clay.c") {
			clay_obj = obj
		}
	}
	if clay_obj == "" {
		// The archive below is built from exactly this object, so without it there
		// is nothing to archive and the failure would surface as a link error a
		// long way from the cause.
		fmt.eprintf("error: C_SOURCES has no clay.c, so %s cannot be built\n", clay_lib())
		os.exit(1)
	}

	lib := clay_lib()
	// The archive's own directory has to exist first. clay's object no longer
	// lands inside it (see object_for), so nothing else creates it, and `lib`
	// does not create its /OUT: directory either -- it just fails, which cost
	// three CI round trips before the message was read closely.
	mkdir_of(lib)
	when ODIN_OS == .Windows {
		out := strings.concatenate({"/OUT:", lib}, context.temp_allocator)
		run_or_die("lib", {"/nologo", out, clay_obj}, "C dependencies")
		return
	}
	run_or_die("ar", {"rcs", lib, clay_obj}, "C dependencies")
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
