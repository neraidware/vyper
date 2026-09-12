package main

import "core:os"
import "core:strings"

// resolve_tool_argv rewrites argv[0] to an absolute path on Windows when it is
// a bare program name (no path separator) such as "ffprobe" or "ffmpeg".
//
// os.process_exec on Windows calls CreateProcessW with lpApplicationName=nil,
// so the first command token is resolved with the standard search order, which
// conspicuously does NOT include the directory of the running exe (the runtime
// tools ffprobe.exe / ffmpeg.exe are staged right next to vyper.exe, not on
// PATH). If left bare, the spawn fails and every probe/transcode silently
// returns "unavailable". Rewriting to <exe_dir>\<name>.exe fixes it.
//
// Returns the argv to spawn (resolving as needed) and an owned string to free
// when the resolved path was allocated; callers must free the returned copy of
// the argv too. On non-Windows this is a no-op returning the input unchanged.
resolve_tool_argv :: proc(argv: []string, allocator := context.allocator) -> (resolved: []string, free_path: string, free_argv: bool) {
	when ODIN_OS == .Windows {
		if len(argv) == 0 { return argv, "", false }
		name := argv[0]
		if !strings.contains_any(name, "\\/") && !strings.has_suffix(name, ".exe") {
			dir, _ := os.get_executable_directory(allocator)
			defer delete(dir, allocator)
			sep := `\`
			resolved_slice := make([]string, len(argv), allocator)
			resolved_slice[0] = strings.concatenate({dir, sep, name, ".exe"}, allocator)
			for i := 1; i < len(argv); i += 1 {
				resolved_slice[i] = argv[i]
			}
			return resolved_slice, resolved_slice[0], true
		}
	}
	return argv, "", false
}

// ---------------------------------------------------------------------------
// Subprocess helpers.
//
// Replaces the Linux-only `core:sys/posix` popen/fgets/pclose shell-outs that
// used to run ffmpeg/ffprobe. `core:os.process_exec` is cross-platform: it
// spawns the program with an argv (no shell, so no quoting/redirection games
// needed — passing a []string arg vector works on both Windows and Unix),
// captures stdout+stderr, and waits. ffprobe's `2>/dev/null` is replaced by
// simply discarding the captured stderr.
//
// NOTE: on Windows the child argv is auto-escaped by Odin into a proper
// CreateProcessW command line, so raw paths (which may contain spaces) must be
// passed as separate argv elements — never hand-built into a shell command
// string.
// ---------------------------------------------------------------------------

ffmpeg_argv_from_command :: proc(command: string, allocator := context.allocator) -> (argv: [dynamic]string) {
	// Parses a whitespace-separated `ffprobe ...` command string into an argv
	// so the same high-level call sites can build argv directly. Keep it dumb:
	// split on spaces, no quote handling (callers pass literal fields).
	parts := strings.split(command, " ", allocator)
	defer delete(parts)
	for p in parts {
		if p != "" {
			append(&argv, p)
		}
	}
	return argv
}

// run_capture runs an argv and returns its stdout as an owned string plus the
// process exit code. Caller frees the string. Returns ok=false if the program
// could not be started (binary missing).
run_capture :: proc(argv: []string, allocator := context.allocator) -> (stdout: string, exit_code: int, ok: bool) {
	rargv, free_path, free_argv := resolve_tool_argv(argv, allocator)
	defer if free_argv {
		delete(rargv, allocator)
	}
	defer if free_path != "" {
		delete(free_path, allocator)
	}
	state, out, err_out, err := os.process_exec({command = rargv}, allocator)
	defer delete(err_out)
	if err != nil {
		if out != nil {
			delete(out)
		}
		return "", -1, false
	}
	text := strings.clone(string(out), allocator)
	delete(out)
	return text, state.exit_code, true
}

// discard_stderr_diag: nothing to do — run_capture already captured (and we
// delete) stderr. Kept as a named helper so call sites read intentionally.
discard_stderr :: proc() {
}
