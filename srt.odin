package main

import "core:math"
import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// Subtitle (.srt) parsing.
//
// An Srt_Source is a parsed subtitle file: each cue keeps the authored time
// span (start/end ms) and authored text verbatim.
//
// Geometry/timing model (see TODO.md "Subtitle generator clip"):
//   - cues are relative to the clip start (sequence semantics), not absolute.
//   - a cue's span is [start_ms, end_ms) as authored; end is EXCLUSIVE.
//   - cue ms convert to frames at the project frame rate on every hit-test and
//     render, so boundaries land on exact frame positions.
//
// The cache is session-scoped and append-only: every unique path resolves once
// and stays resident for the run, so the cache index (`srt_id`) is a stable
// clip handle and clips never own or free the path. Duplicate/delete of a
// subtitle clip touches no cached string memory.
// ---------------------------------------------------------------------------

Srt_Cue :: struct {
	// start/end in MILLISECONDS (wall time, as authored); end exclusive.
	start_ms: i64,
	end_ms:   i64,
	// Authored cue text (may contain '\n').
	text: string,
}

Srt_Source :: struct {
	// path is the owned cache key (original picker string copied once).
	path: string,
	cues: [dynamic]Srt_Cue,
}

// cue_frame converts an authored wall-time ms value to a frame count at fps.
cue_frame :: proc(ms: i64, fps: f32) -> i64 {
	if ms <= 0 {
		return 0
	}
	return max(0, i64(math.round(f64(ms) * f64(fps) / 1000.0)))
}

// cue_start_frame / cue_end_frame are the frame equivalents of the cue's
// authored span at fps (end EXCLUSIVE: a cue covers [start, end)).
cue_start_frame :: proc(cue: Srt_Cue, fps: f32) -> i64 {
	return cue_frame(cue.start_ms, fps)
}
cue_end_frame :: proc(cue: Srt_Cue, fps: f32) -> i64 {
	return cue_frame(cue.end_ms, fps)
}

// srt_cue_lookup returns the index of the cue covering `frame`, or -1 when no
// cue covers it. `frame` is clip-relative (0 = the clip's own start).
srt_cue_lookup :: proc(cues: []Srt_Cue, frame: i64, fps: f32) -> int {
	if len(cues) == 0 {
		return -1
	}
	lo, hi := 0, len(cues) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if cue_start_frame(cues[mid], fps) <= frame {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	// A cue is active only inside its half-open span [start, end). The binary
	// search lands on the last cue whose start <= frame, but for a frame before
	// the FIRST cue it still converges to index 0 — without the lower bound a
	// blank pre-roll would show the first cue's title early.
	if frame >= cue_start_frame(cues[lo], fps) && frame < cue_end_frame(cues[lo], fps) {
		return lo
	}
	return -1
}

// ---------------------------------------------------------------------------
// Cache: srt_cache maps an (immortal) file path to its parsed source.
// Append-only + session-scoped, so the cache index is a stable clip handle.
// ---------------------------------------------------------------------------

srt_cache: [dynamic]Srt_Source

// srt_cache_index returns the cache index holding `path`, or -1 if unparsed.
srt_cache_index :: proc(path: cstring) -> int {
	if path == nil {
		return -1
	}
	for s, i in srt_cache {
		if s.path == string(path) {
			return i
		}
	}
	return -1
}

// srt_source returns the parsed source at cache index `id`, or nil.
srt_source :: proc(id: int) -> ^Srt_Source {
	if id < 0 || id >= len(srt_cache) {
		return nil
	}
	return &srt_cache[id]
}

// srt_load parses `path` once (cached by path) and returns its cache index,
// or -1 if the file could not be read or contained no cues.
srt_load :: proc(path: cstring) -> int {
	if i := srt_cache_index(path); i >= 0 {
		return i
	}
	src := Srt_Source{path = strings.clone(string(path))}
	parse_srt_file(path, &src)
	if len(src.cues) == 0 {
		delete(src.path)
		clear(&src.cues)
		return -1
	}
	append(&srt_cache, src)
	return len(srt_cache) - 1
}

// srt_duration_ms returns the total authored span of a parsed source (its last
// cue's end), used as the clip's natural length.
srt_duration_ms :: proc(src: ^Srt_Source) -> i64 {
	if src == nil || len(src.cues) == 0 {
		return 1000
	}
	return src.cues[len(src.cues) - 1].end_ms
}

// ---------------------------------------------------------------------------
// Parsing.
//
// Accepts standard "N\nHH:MM:SS,mmm --> HH:MM:SS,mmm\ntext...\n\n" blocks.
// Blanks separate blocks; a block's text is every line AFTER its timing line.
// Malformed blocks are skipped (the author edits the .srt to fix them). CRLF
// and a UTF-8 BOM are handled; "," and "." are both accepted as the ms
// separator.
// ---------------------------------------------------------------------------

// parse_ms parses "HH:MM:SS[,.]mmm" into milliseconds.
parse_ms :: proc(token: string) -> (ms: i64, ok: bool) {
	parts := strings.split(token, ":")
	defer delete(parts)
	if len(parts) != 3 {
		return 0, false
	}
	h, ok1 := parse_i64_safe(parts[0])
	m, ok2 := parse_i64_safe(parts[1])
	if !ok1 || !ok2 || h < 0 || m < 0 {
		return 0, false
	}
	sec_ms, ok3 := parse_sec_ms(parts[2])
	if !ok3 {
		return 0, false
	}
	return (h*60 + m) * 60_000 + sec_ms, true
}

// parse_sec_ms parses "SS[,.]mmm" into seconds*1000 + ms.
parse_sec_ms :: proc(token: string) -> (ms: i64, ok: bool) {
	// Accept both ',' and '.' as the ms separator (some tools write '.').
	sep := strings.index_byte(token, ',')
	if sep < 0 {
		sep = strings.index_byte(token, '.')
	}
	if sep < 0 {
		whole, okw := parse_i64_safe(token)
		if !okw || whole < 0 {
			return 0, false
		}
		return whole * 1000, true
	}
	s_part, ok1 := parse_i64_safe(token[:sep])
	frac := token[sep + 1:]
	if !ok1 || s_part < 0 {
		return 0, false
	}
	// Keep up to 3 digits, pad to 3.
	digits := min(len(frac), 3)
	f, okf := parse_i64_safe(frac[:digits])
	if !okf {
		return 0, false
	}
	ms_part := f
	for _ in len(frac) ..< 3 {
		ms_part *= 10
	}
	return s_part*1000 + ms_part, true
}

// parse_i64_safe parses a non-negative integer string to i64 ("" fails).
parse_i64_safe :: proc(s: string) -> (i64, bool) {
	if len(s) == 0 {
		return 0, false
	}
	n: i64 = 0
	for c in s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + i64(c - '0')
	}
	return n, true
}

// split_timing_line splits a timing line on " --> " into two trimmed timecodes.
split_timing_line :: proc(line: string) -> (a, b: string, ok: bool) {
	arrow := strings.index(line, "-->")
	if arrow < 0 {
		return "", "", false
	}
	return strings.trim_space(line[:arrow]), strings.trim_space(line[arrow + 3:]), true
}

// parse_cue_line returns a cue for a "HH:MM:SS,mmm --> HH:MM:SS,mmm" timing
// line with no text yet (text assigned by parse_srt_file).
parse_cue_line :: proc(line: string) -> (Srt_Cue, bool) {
	a, b, ok := split_timing_line(line)
	if !ok {
		return {}, false
	}
	start, ok1 := parse_ms(a)
	if !ok1 {
		return {}, false
	}
	end, ok2 := parse_ms(b)
	if !ok2 {
		return {}, false
	}
	if end <= start {
		return {}, false
	}
	return Srt_Cue{start_ms = start, end_ms = end}, true
}

// parse_srt_file parses `path` into `receives` (all cue memory owned by the
// caller's source).
parse_srt_file :: proc(path: cstring, receives: ^Srt_Source) {
	bytes, err := os.read_entire_file_from_path(string(path), context.allocator)
	if err != nil {
		return
	}
	defer delete(bytes)

	if len(bytes) >= 3 {
		prefix := bytes[:3]
		if prefix[0] == 0xEF && prefix[1] == 0xBB && prefix[2] == 0xBF {
			bytes = bytes[3:]
		}
	}
	s := string(bytes)

	lines := strings.split(s, "\n")
	defer delete(lines)
	// Strip \r from line ends (CRLF) and keep lines as raw slices into s
	// (parse_srt_file never mutates s, so slices stay valid through the loop).
	for i in 0 ..< len(lines) {
		lines[i] = strings.trim_right(lines[i], "\r")
	}

	// Accumulate one block: [first_line, last_line) filled with the block's
	// lines (timing line + text lines). We split on blank lines.
	block_start := 0
	for i in 0 ..= len(lines) {
		at_end := i == len(lines)
		blank := !at_end && strings.trim_space(lines[i]) == ""
		if at_end || blank {
			if i > block_start {
				parse_srt_block(lines[block_start:i], receives)
			}
			block_start = i + 1
		}
	}
}

// parse_srt_block parses one block (its raw lines) and appends the cue.
parse_srt_block :: proc(block: []string, receives: ^Srt_Source) {
	// Find the timing line: a line containing " --> ".
	timing := -1
	for l, i in block {
		if strings.index(l, "-->") >= 0 {
			timing = i
			break
		}
	}
	if timing < 0 {
		return
	}
	cue, ok := parse_cue_line(block[timing])
	if !ok {
		return
	}
	// Text = every block line after the timing line, joined with '\n'.
	text_parts := block[timing + 1:]
	// Drop a leading empty line if the author left one blank between timing
	// and text (blank line inside a block is not a block separator here).
	for len(text_parts) > 0 && strings.trim_space(text_parts[0]) == "" {
		text_parts = text_parts[1:]
	}
	if len(text_parts) > 0 {
		cue.text = strings.join(text_parts, "\n")
	}
	append(&receives.cues, cue)
}