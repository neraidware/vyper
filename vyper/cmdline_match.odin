package vyper

import "core:fmt"
import "core:os"
import "core:sort"
import "core:strings"

// ---------------------------------------------------------------------------
// Fuzzy file matching for the ":" command line. While the buffer is
// `open <query>`, the relative paths of files under the process cwd are
// scored against the query with an fzf-flavored subsequence matcher and the
// top rows are shown under the prompt. Tab/Shift+Tab/Up/Down move the
// highlight, Enter commits `open <path>` for the highlighted row.
//
// The similarity to vim's wildmenu stops at the interaction — the matching is
// subsequence scoring, not vim's prefix/completion engine.
//
// Memory model: the walked file list is owned by the cmdline session (freed by
// cmdline_match_reset, which text_input_begin calls whenever a TI_CMDLINE
// session starts). Matches and the last-query scratch reuse the existing
// buffers on every keystroke — no allocations once the file list is built.
// ---------------------------------------------------------------------------

CMDLINE_MATCH_MAX :: 8    // visible rows under the prompt
CMDLINE_FILES_MAX :: 20000 // safety cap: stop walking past this many files
CMDLINE_QUERY_MAX :: 127  // query bytes considered for matching/draw
CMDLINE_PATH_BUF :: 512   // rewritten `open <path>` command buffer

Cmdline_Match :: struct {
	path:  string, // relative path (slice into match_state.files)
	score: int,
}

// Cmdline_Match_State is the ":" open-command's file-matcher session: the
// cwd-walk file list (session-owned, rebuilt per ":" press) with its dirty
// flag, the scored match list, the selected match (-1 = none), the query the
// matches were built for, and its length.
Cmdline_Match_State :: struct {
	files:     [dynamic]string,
	files_dirty: bool,
	matches:   [dynamic]Cmdline_Match,
	sel:       int,
	query_buf: [CMDLINE_QUERY_MAX + 1]u8,
	query_len: int,
	// last_command is the most recently committed ":" command-line text,
	// shown as the prompt's placeholder. Owned (session-heap): the old string
	// is deleted and replaced by the caller on each commit.
	last_command: string,
}
cmdline_match_state: Cmdline_Match_State = {files_dirty = true, sel = -1}

// cmdline_match_reset drops the session-owned file list and match state.
// Called by text_input_begin when a TI_CMDLINE session starts, so each ":"
// press walks a fresh tree.
cmdline_match_reset :: proc() {
	for path in cmdline_match_state.files {
		delete(path)
	}
	delete(cmdline_match_state.files)
	clear(&cmdline_match_state.matches)
	cmdline_match_state.files_dirty = true
	cmdline_match_state.sel = -1
	cmdline_match_state.query_len = 0
}

// cmdline_match_build_files walks the process cwd once and caches relative
// paths (hidden entries skipped). The walker yields absolute fullpaths on
// this platform, so the cwd prefix is trimmed to make every candidate a
// cwd-relative path — the same form apply_command feeds os.exists.
cmdline_match_build_files :: proc() {
	if !cmdline_match_state.files_dirty {
		return
	}
	cmdline_match_state.files_dirty = false
	cwd := os.get_working_directory(context.temp_allocator) or_else ""
	if len(cwd) == 0 {
		return
	}
	prefix := strings.concatenate({cwd, "/"}, context.temp_allocator)
	w: os.Walker
	os.walker_init_path(&w, ".")
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		if len(cmdline_match_state.files) >= CMDLINE_FILES_MAX {
			break
		}
		if len(info.name) > 0 && info.name[0] == '.' {
			if info.type == .Directory {
				os.walker_skip_dir(&w)
			}
			continue
		}
		if info.type != .Regular {
			continue
		}
		if !strings.has_prefix(info.fullpath, prefix) {
			continue
		}
		rel := info.fullpath[len(prefix):]
		append(&cmdline_match_state.files, strings.clone(rel))
	}
}

// cmdline_match_query extracts the fuzzy-match target from the buffer: the
// text after the leading `open` token. Empty unless the buffer is `open` (or
// `open <something>`), so typing other commands shows no list.
cmdline_match_query :: proc() -> string {
	cmd := strings.trim_space(text_input_string())
	if !strings.has_prefix(cmd, "open") {
		return ""
	}
	rest := cmd[4:]
	if len(rest) == 0 || (rest[0] != ' ' && rest[0] != '\t') {
		return ""
	}
	return strings.trim_space(rest)
}

// cmdline_fuzzy_score is a case-insensitive subsequence scorer with fzf-ish
// bonuses: consecutive runs, word starts (after / - _ . and string start),
// and basename starts (after the last /) score higher. Returns 0 when the
// query is not a subsequence of path.
cmdline_fuzzy_score :: proc(query, path: string) -> int {
	ql := len(query)
	if ql == 0 || ql > len(path) {
		return 0
	}
	fold :: proc(c: u8) -> u8 {
		if 'A' <= c && c <= 'Z' {
			return c + 32
		}
		return c
	}
	basename_start := 0
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			basename_start = i + 1
			break
		}
	}
	score := 0
	qi := 0
	last_matched := -2
	for i := 0; i < len(path) && qi < ql; i += 1 {
		if fold(path[i]) != fold(query[qi]) {
			continue
		}
		sc := 10
		if i == last_matched + 1 {
			sc += 20 // consecutive run
		}
		if i == 0 || path[i-1] == '/' || path[i-1] == '-' || path[i-1] == '_' || path[i-1] == '.' {
			sc += 30 // word start
		}
		if i == basename_start {
			sc += 40 // basename start
		} else if i > basename_start {
			sc += 5 // inside basename
		}
		score += sc
		last_matched = i
		qi += 1
	}
	if qi != ql {
		return 0
	}
	return score
}

// cmdline_match_refresh re-scores candidates only when the query text changed
// since the last build; otherwise the stored list stands. Called once per
// draw of the cmdline popup.
cmdline_match_refresh :: proc() {
	query := cmdline_match_query()
	// Compare against the stored query byte-for-byte; identical text means the
	// existing match list is still current.
	if len(query) == cmdline_match_state.query_len &&
		string(cmdline_match_state.query_buf[:cmdline_match_state.query_len]) == query {
		return
	}
	qn := min(len(query), CMDLINE_QUERY_MAX)
	copy(cmdline_match_state.query_buf[:qn], query[:qn])
	cmdline_match_state.query_len = qn
	clear(&cmdline_match_state.matches)
	if qn == 0 {
		cmdline_match_state.sel = -1
		return
	}
	cmdline_match_build_files()
	for path in cmdline_match_state.files {
		if sc := cmdline_fuzzy_score(query[:qn], path); sc > 0 {
			append(&cmdline_match_state.matches, Cmdline_Match{path = path, score = sc})
		}
	}
	sort.quick_sort_proc(cmdline_match_state.matches[:], proc(a, b: Cmdline_Match) -> int {
		if a.score > b.score { return -1 }
		if a.score < b.score { return 1 }
		return 0
	})
	// Keep only the rows that fit the dropdown so navigation and rendering
	// agree on the same list (sel wraps over exactly what's shown).
	if len(cmdline_match_state.matches) > CMDLINE_MATCH_MAX {
		resize(&cmdline_match_state.matches, CMDLINE_MATCH_MAX)
	}
	cmdline_match_state.sel = 0 if len(cmdline_match_state.matches) > 0 else -1
}

// cmdline_match_navigate moves the highlight by delta rows, wrapping.
cmdline_match_navigate :: proc(delta: int) {
	if len(cmdline_match_state.matches) == 0 {
		return
	}
	cmdline_match_state.sel = (cmdline_match_state.sel + delta + len(cmdline_match_state.matches)) % len(cmdline_match_state.matches)
}

// cmdline_match_apply_selection rewrites the buffer to the highlighted
// row's `open <path>` command so the normal commit path opens it. A typed
// text that is itself an existing relative path wins over the highlight (the
// person finished typing the path; the match list is only an accelerator).
// No-op when there is no list or none selected; returns true if the buffer
// changed.
cmdline_match_apply_selection :: proc() -> bool {
	cmdline_match_refresh()
	query := cmdline_match_query()
	if len(query) > 0 {
		cmdline_match_build_files()
		for path in cmdline_match_state.files {
			if path == query {
				buf: [CMDLINE_PATH_BUF]u8
				text_input_set_buf(fmt.bprintf(buf[:], "open %s", path))
				return true
			}
		}
	}
	if cmdline_match_state.sel < 0 || cmdline_match_state.sel >= len(cmdline_match_state.matches) {
		return false
	}
	path := cmdline_match_state.matches[cmdline_match_state.sel].path
	buf: [CMDLINE_PATH_BUF]u8
	text_input_set_buf(fmt.bprintf(buf[:], "open %s", path))
	return true
}

// cmdline_match_matched_runs fills `runs` with (start, length) byte ranges of
// path that match the stored query, for highlight drawing. Returns the number
// of runs written.
cmdline_match_matched_runs :: proc(path: string, runs: [][2]int) -> int {
	q := string(cmdline_match_state.query_buf[:cmdline_match_state.query_len])
	ql := len(q)
	if ql == 0 {
		return 0
	}
	fold :: proc(c: u8) -> u8 {
		if 'A' <= c && c <= 'Z' {
			return c + 32
		}
		return c
	}
	n := 0
	qi := 0
	run_len := 0
	for i := 0; i < len(path); i += 1 {
		if qi < ql && fold(path[i]) == fold(q[qi]) {
			qi += 1
			run_len += 1
		} else if run_len > 0 {
			runs[n] = {i - run_len, run_len}
			n += 1
			run_len = 0
		}
	}
	if run_len > 0 {
		runs[n] = {len(path) - run_len, run_len}
		n += 1
	}
	return n
}