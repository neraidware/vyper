package main

import "core:os"
import "core:strings"

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
	state, out, err_out, err := os.process_exec({command = argv}, allocator)
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