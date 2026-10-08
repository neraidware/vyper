package vyper

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------
// Diagnostics: where they go, and whether they are on.
//
// Every diagnostic in the app is an env var. Two rules make them usable:
//
//  1. The DEBUGGING code is behind `when ODIN_DEBUG`, so a release binary does
//     not contain it at all. `./build.sh` builds debug, `./build.sh release`
//     does not -- and `strings ./vyper` on a release build has no trace format
//     strings in it, which is the check that this is real exclusion and not a
//     runtime flag that still ships the code.
//
//  2. In a DEBUG build the diagnostic is ON by default and writes under the
//     system temp directory, so a debug run is instrumented without anyone
//     having to remember a flag or invent a path. Setting the variable still
//     wins, and setting it to 0 turns one off -- which is the only way a
//     default-on diagnostic can still be silenced:
//
//	VYPER_TRACE=0 ./vyper project.vyproj   # quiet
//	VYPER_SPALL=/tmp/perf.json ./build.sh  # or a path of your own
//
// Both rules exist because a diagnostic you have to remember is a diagnostic
// that is off when you needed it.
// ---------------------------------------------------------------------------

DIAG_DIR_NAME :: "vyper"

// diag_dir writes "<temp>/vyper/" into buf, NUL-terminated, creating the
// directory (and its parent) on first use. Returns the byte offset just past
// the prefix, or 0 when no temp directory could be resolved or created --
// callers then treat the diagnostic as off rather than writing somewhere
// arbitrary.
diag_dir :: proc(buf: []u8) -> int {
	tmp, err := os.temp_directory(context.temp_allocator)
	if err != nil || tmp == "" {
		return 0
	}
	rel := "/" + DIAG_DIR_NAME + "/"
	n := len(tmp) + len(rel)
	if n + 1 >= len(buf) {
		return 0
	}
	copy(buf[:], tmp)
	copy(buf[len(tmp):], rel)
	buf[n] = 0
	path := transmute(string)buf[:n]
	if os.make_directory(path) != nil {
		// Already existing is the normal case after the first run; anything else
		// means the prefix is not usable and the caller must not write.
		if !os.is_dir(path) {
			return 0
		}
	}
	return n
}

// diag_flag resolves a boolean diagnostic variable.
//
// Set explicitly -> it is `=1` or not, which is the rule every one of these
// already used, so nothing changes for anyone who sets them. Unset -> on in a
// debug build, off in a release one.
diag_flag :: proc(name: string) -> bool {
	if v, ok := os.lookup_env_alloc(name, context.temp_allocator); ok {
		return v == "1"
	}
	when ODIN_DEBUG {
		return true
	}
	return false
}

// diag_path resolves a diagnostic that records to a file.
//
// Set explicitly -> that path. Unset in a debug build -> the named file under
// the temp dir. Unset in a release build -> "" (off), because a release binary
// does not carry the code that would open it anyway.
//
// `buf` is caller-owned fixed storage: the returned string points into it, so
// it is frame-scoped and must not outlive the frame. Callers that keep the path
// (a dump header, an error message after the arena moved) copy it out first --
// the same rule as every other fixed buffer here.
diag_path :: proc(name: string, file: string, buf: []u8) -> string {
	if v, ok := os.lookup_env_alloc(name, context.temp_allocator); ok && v != "" {
		return v
	}
	when ODIN_DEBUG {
		at := diag_dir(buf)
		if at == 0 {
			return ""
		}
		written := len(fmt.bprintf(buf[at:len(buf) - 1], "%s", file))
		if written <= 0 {
			return ""
		}
		buf[at + written] = 0
		return transmute(string)buf[:at + written]
	}
	return ""
}

// diag_interval resolves a numeric diagnostic that takes a value rather than a
// flag (the audio log period, the profiler's run length). Unset in a debug build
// -> `dflt`, because a periodic log with no period never fires and a
// diagnostic that never fires is not on.
diag_interval :: proc(name: string, dflt: i64) -> i64 {
	if v, ok := os.lookup_env_alloc(name, context.temp_allocator); ok {
		n, ok := strconv.parse_i64(v)
		if ok {
			return n
		}
	}
	when ODIN_DEBUG {
		return dflt
	}
	return 0
}

// diag_report_temp is printed once at startup so the path is discoverable
// without reading the source. Gated: a release build has no diagnostics to
// point at.
when ODIN_DEBUG {
	diag_report_temp :: proc() {
		buf: [1024]u8
		if at := diag_dir(buf[:]); at > 0 {
			fmt.printf("[diag] temp dir %s\n", transmute(string)buf[:at])
		} else {
			fmt.printf("[diag] no writable temp dir; file diagnostics are off\n")
		}
	}
}

// flush_stdout drains stdout. Every probe prints its result and then calls
// os.exit, which does not flush: a redirected stdout on Windows is block
// buffered, so the result line never reaches the file and a job that reads it
// sees an EMPTY log -- indistinguishable from a probe that printed nothing at
// all. Probes must call this immediately before os.exit.
flush_stdout :: proc() {
	if os.stdout != nil {
		os.flush(os.stdout)
	}
}
