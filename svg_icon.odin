package main

import "core:math"

// ---------------------------------------------------------------------------
// Minimal embedded SVG icon pipeline.
//
// Icons are placeholder .svg files under icons/ (loaded at compile time via
// #load, so the shipped binary needs no icon directory and nix builds work
// offline). Each is rasterized once into a tiny R8 alpha texture; drawing uses
// the existing text pipeline, which samples the R channel as alpha and tints
// it with a per-draw color uniform -- one white raster serves every UI state
// (normal, hover, active) with zero extra textures.
//
// Supported SVG subset (enough for the placeholders and the simple icons that
// replace them later):
//   - <svg viewBox="minx miny w h"> and the root/<path> fill-rule attribute
//     (nonzero | evenodd; default nonzero)
//   - <path d="..."> with commands M L H V C S Q T Z (absolute + relative),
//     repeated implicit coordinate groups, and the smoothing S/T shorthand.
//   - Everything else (groups, transforms, strokes, rect/circle ...) is
//     ignored; unsupported commands and arcs are skipped.
// The rasterizer fills via nonzero/evenodd scanline coverage with 4x vertical
// supersampling.
// ---------------------------------------------------------------------------

Icon_Id :: enum {
	SkipBack,
	SkipForward,
	SnapClipToPlayhead, // "Clip >"
	SnapPlayheadToClip, // "> Clip"
	Duplicate,
	Import,
}

ICON_COUNT :: 6
ICON_RASTER :: 96 // rasterized texture size per icon (px).

skip_back_svg := #load("icons/skip_back.svg")
skip_forward_svg := #load("icons/skip_forward.svg")
snap_clip_to_playhead_svg := #load("icons/snap_clip_to_playhead.svg")
snap_playhead_to_clip_svg := #load("icons/snap_playhead_to_clip.svg")
duplicate_svg := #load("icons/duplicate.svg")
import_svg := #load("icons/import.svg")

get_icon_svg :: proc(id: Icon_Id) -> []u8 {
	switch id {
	case .SkipBack:
		return skip_back_svg
	case .SkipForward:
		return skip_forward_svg
	case .SnapClipToPlayhead:
		return snap_clip_to_playhead_svg
	case .SnapPlayheadToClip:
		return snap_playhead_to_clip_svg
	case .Duplicate:
		return duplicate_svg
	case .Import:
		return import_svg
	case:
		return nil
	}
}

P2 :: struct { x, y: f32 }

Icon_Rule :: enum { NonZero, EvenOdd }

Icon_Shape :: struct {
	subs: [dynamic][dynamic]P2, // flattened closed polylines (SVG coords)
	rule: Icon_Rule,
	view: [4]f32, // minx, miny, w, h
}


// build_icon_shape parses `data` (an .svg file body) into flattened subpaths.
// Subpaths are filled (implicitly closed), so curves are flattened with a
// tolerance that lands near 0.25 raster pixels once scaled to raster size.
build_icon_shape :: proc(data: []u8) -> (Icon_Shape, bool) {
	s := string(data)
	shape: Icon_Shape
	shape.rule = .NonZero
	shape.view = {0, 0, 24, 24}

	if svg_open_start := find_substring(s, "<svg"); svg_open_start >= 0 {
		open_len_rel := find_substring(s[svg_open_start:], ">")
		if open_len_rel < 0 {
			return shape, false
		}
		tag := s[svg_open_start:svg_open_start + open_len_rel]
		if vb := attr_value(tag, "viewBox"); vb != "" {
			nums := parse_floats(vb)
			if len(nums) == 4 {
				shape.view = {nums[0], nums[1], nums[2], nums[3]}
			}
		}
		if fr := attr_value(tag, "fill-rule"); fr == "evenodd" {
			shape.rule = .EvenOdd
		}
	}

	tol := 0.25 / max(shape.view[2], 1)
	i := 0
	for i < len(s) {
		if s[i] != '<' {
			i += 1
			continue
		}
		if substring_at(s, i, "<!--") {
			j := find_substring(s[i + 4:], "-->")
			if j < 0 {
				break
			}
			i += 4 + j + 3
			continue
		}
		tag_end := i
		for tag_end < len(s) && s[tag_end] != '>' {
			tag_end += 1
		}
		if tag_end >= len(s) {
			break
		}
		tag_text := s[i:tag_end]
		// A path element: parse its d= and fill-rule=.
		if substring_at(tag_text, 1, "path") {
			if d := attr_value(tag_text, "d"); d != "" {
				subs := parse_path_d(d, tol)
				for &s in subs {
					if len(s) >= 3 {
						append(&shape.subs, s)
					} else {
						delete(s)
					}
				}
				delete(subs)
			}
			// Per-path fill-rule overrides the icon default.
			if fr := attr_value(tag_text, "fill-rule"); fr == "evenodd" {
				shape.rule = .EvenOdd
			} else if fr == "nonzero" {
				shape.rule = .NonZero
			}
		}
		i = tag_end + 1
	}
	return shape, len(shape.subs) > 0
}

destroy_icon_shape :: proc(shape: ^Icon_Shape) {
	for &s in shape.subs {
		delete(s)
	}
	delete(shape.subs)
}

// find_substring returns the byte offset of `needle` in `s`, or -1.
find_substring :: proc(s, needle: string) -> int {
	if len(needle) == 0 {
		return 0
	}
	needle_len := len(needle)
	for i := 0; i + needle_len <= len(s); i += 1 {
		if s[i:i + needle_len] == needle {
			return i
		}
	}
	return -1
}

substring_at :: proc(s: string, off: int, needle: string) -> bool {
	if off < 0 || off + len(needle) > len(s) {
		return false
	}
	return s[off:off + len(needle)] == needle
}

// attr_value extracts a double-quoted attribute value from an XML tag.
attr_value :: proc(tag, name: string) -> string {
	at := find_substring(tag, name)
	if at < 0 {
		return ""
	}
	i := at + len(name)
	for i < len(tag) && (tag[i] == ' ' || tag[i] == '=') {
		i += 1
	}
	if i < len(tag) && tag[i] == '"' {
		quote_start := i + 1
		j := quote_start
		for j < len(tag) && tag[j] != '"' {
			j += 1
		}
		if j < len(tag) {
			return tag[quote_start:j]
		}
	}
	return ""
}

// parse_floats extracts every number from a whitespace/comma separated list.
parse_floats :: proc(s: string) -> [dynamic]f32 {
	out := make([dynamic]f32)
	i := 0
	for {
		_, ok := read_svg_num(s, &i)
		if !ok {
			break
		}
	}
	return out
}

// skip_num_ws advances `i` past whitespace/commas; reports whether anything is
// left to parse.
skip_num_ws :: proc(s: string, i: ^int) -> bool {
	for i^ < len(s) {
		ch := s[i^]
		if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == ',' {
			i^ += 1
		} else {
			break
		}
	}
	return i^ < len(s)
}

// read_svg_num parses a float (with optional sign and exponent) at `i^`,
// advancing past it. Returns false when no number is present at `i^`.
read_svg_num :: proc(s: string, i: ^int) -> (f32, bool) {
	token_start := i^
	skip_num_ws(s, i)
	if i^ >= len(s) {
		return 0, false
	}
	neg := false
	if s[i^] == '+' {
		i^ += 1
	} else if s[i^] == '-' {
		neg = true
		i^ += 1
	}
	start := i^
	int_val: f64 = 0
	has_int := false
	for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' {
		int_val = int_val * 10 + f64(s[i^] - '0')
		has_int = true
		i^ += 1
	}
	frac: f64 = 0
	has_frac := false
	if i^ < len(s) && s[i^] == '.' {
		i^ += 1
		scale := 0.1
		for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' {
			frac += f64(s[i^] - '0') * scale
			scale *= 0.1
			has_frac = true
			i^ += 1
		}
		if !has_frac && !has_int {
			i^ = token_start
			return 0, false
		}
	}
	if !has_int && !has_frac {
		i^ = token_start
		return 0, false
	}
	val := int_val + frac
	if neg {
		val = -val
	}
	// Exponent.
	if i^ < len(s) && (s[i^] == 'e' || s[i^] == 'E') {
		e_save := i^
		i^ += 1
		eneg := false
		if i^ < len(s) && (s[i^] == '+' || s[i^] == '-') {
			eneg = s[i^] == '-'
			i^ += 1
		}
		estart := i^
		exp: i64 = 0
		for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' {
			exp = exp * 10 + i64(s[i^] - '0')
			i^ += 1
		}
		if i^ == estart {
			i^ = e_save
		} else {
			if eneg {
				val *= math.pow(10.0, -f64(exp))
			} else {
				val *= math.pow(10.0, f64(exp))
			}
		}
	}
	return f32(val), true
}


// ---------------------------------------------------------------------------
// Path `d` parsing + flattening.
// ---------------------------------------------------------------------------

// parse_path_d parses a path `d` string into per-subpath flattened polylines
// (SVG coordinates; cubic/quad curves reduced to line segments on tolerance
// `tol`, in SVG units). Returns a slice of subpath point arrays.
parse_path_d :: proc(d: string, tol: f32) -> [dynamic][dynamic]P2 {
	out := make([dynamic][dynamic]P2)
	pts := make([dynamic]P2)
	cur := P2{}
	cmd: u8 = 'M'
	i := 0

	// Local helpers (each takes explicit state to avoid accidental capture).
	skip_ws :: proc(s: string, i: ^int) {
		for i^ < len(s) {
			ch := s[i^]
			if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == ',' {
				i^ += 1
			} else {
				break
			}
		}
	}
	read_n :: proc(s: string, i: ^int) -> (f32, bool) {
		token := i^
		skip_ws(s, i)
		if i^ >= len(s) {
			return 0, false
		}
		neg := false
		if s[i^] == '+' {
			i^ += 1
		} else if s[i^] == '-' {
			neg = true
			i^ += 1
		}
		int_val: f64 = 0
		has_int := false
		for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' {
			int_val = int_val * 10 + f64(s[i^] - '0')
			has_int = true
			i^ += 1
		}
		frac: f64 = 0
		if i^ < len(s) && s[i^] == '.' {
			i^ += 1
			scale := 0.1
			has_frac := false
			for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' {
				frac += f64(s[i^] - '0') * scale
				scale *= 0.1
				has_frac = true
				i^ += 1
			}
			if !has_frac && !has_int {
				i^ = token
				return 0, false
			}
		}
		if !has_int && int_val == 0 && frac == 0 {
			// No digits at all (e.g. another command follows): not a number.
			i^ = token
			return 0, false
		}
		val := int_val + frac
		if neg {
			val = -val
		}
		if i^ < len(s) && (s[i^] == 'e' || s[i^] == 'E') {
			e_save := i^
			i^ += 1
			eneg := false
			if i^ < len(s) && (s[i^] == '+' || s[i^] == '-') {
				eneg = s[i^] == '-'
				i^ += 1
			}
			e_start := i^
			exp: i64 = 0
			for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' {
				exp = exp * 10 + i64(s[i^] - '0')
				i^ += 1
			}
			if i^ == e_start {
				i^ = e_save
			} else if eneg {
				val *= math.pow(10.0, -f64(exp))
			} else {
				val *= math.pow(10.0, f64(exp))
			}
		}
		return f32(val), true
	}
	is_cmd_char :: proc(s: string, i: ^int) -> (u8, bool) {
		skip_ws(s, i)
		if i^ >= len(s) {
			return 0, false
		}
		ch := s[i^]
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') {
			if ch == 'e' || ch == 'E' {
				// Exponent never starts a command; the number parser owns 'e'.
				return 0, false
			}
			i^ += 1
			return ch, true
		}
		return 0, false
	}
	add_pt :: proc(poly: ^[dynamic]P2, p: P2) {
		if len(poly^) == 0 || poly^[len(poly^) - 1] != p {
			append(poly, p)
		}
	}
	close_sub :: proc(pts: ^[dynamic]P2, out: ^[dynamic][dynamic]P2) {
		if len(pts^) >= 3 {
			if pts^[0] != pts^[len(pts^) - 1] {
				append(pts, pts^[0])
			}
			append(out, clone_path(pts))
		}
		clear(pts)
	}
	// Flatten helpers.
	flat_enough :: proc(p0, p1, p2, p3: P2, eps: f32) -> bool {
		c1x := p1.x - (p0.x + (p3.x - p0.x) / 3)
		c1y := p1.y - (p0.y + (p3.y - p0.y) / 3)
		c2x := p2.x - (p0.x + 2 * (p3.x - p0.x) / 3)
		c2y := p2.y - (p0.y + 2 * (p3.y - p0.y) / 3)
		return math.sqrt(c1x * c1x + c1y * c1y) <= eps && math.sqrt(c2x * c2x + c2y * c2y) <= eps
	}
	cubic_flat :: proc(p0, p1, p2, p3: P2, eps: f32, poly: ^[dynamic]P2) {
		if flat_enough(p0, p1, p2, p3, eps) {
			append(poly, p3)
			return
		}
		ab  := P2{(p0.x + p1.x) * 0.5, (p0.y + p1.y) * 0.5}
		bc  := P2{(p1.x + p2.x) * 0.5, (p1.y + p2.y) * 0.5}
		cd  := P2{(p2.x + p3.x) * 0.5, (p2.y + p3.y) * 0.5}
		abc := P2{(ab.x + bc.x) * 0.5, (ab.y + bc.y) * 0.5}
		bcd := P2{(bc.x + cd.x) * 0.5, (bc.y + cd.y) * 0.5}
		mid := P2{(abc.x + bcd.x) * 0.5, (abc.y + bcd.y) * 0.5}
		cubic_flat(p0, ab, abc, mid, eps, poly)
		cubic_flat(mid, bcd, cd, p3, eps, poly)
	}
	quad_flat :: proc(p0, q1, p2: P2, eps: f32, poly: ^[dynamic]P2) {
		// Convert the quad to the equivalent bezier cubic and flatten that.
		cubic_flat(p0, P2{p0.x + 2.0 / 3.0 * (q1.x - p0.x), p0.y + 2.0 / 3.0 * (q1.y - p0.y)}, P2{q1.x + 1.0 / 3.0 * (p2.x - q1.x), q1.y + 1.0 / 3.0 * (p2.y - q1.y)}, p2, eps, poly)
	}
	to_abs :: proc(p: P2, x, y: f32, relative: bool) -> P2 {
		if relative {
			return {p.x + x, p.y + y}
		}
		return {x, y}
	}

	prev_ctrl := P2{}
	have_ctrl := false
	sub_start := P2{}
	have_sub := false
	moved := false

	// A moveto placeholder so `pts` starts empty and the first command must be
	// a real moveto as the spec requires.
	for {
		finished := false
		relative: bool
		processed := false

		save := i
		nc, ok := is_cmd_char(d, &i)
		if ok {
			cmd = nc
		} else {
			i = save
			if !moved || i >= len(d) {
				break // nothing but whitespace left, or no leading M yet
			}
			// Implicit repeated command.
		}
		relative = cmd >= 'a' && cmd <= 'z'

		switch (cmd) {
		case 'M', 'm':
			mrel := relative
			for {
				num_ok := false
				_ = num_ok
				x, ok1 := read_n(d, &i)
				if !ok1 {
					break
				}
				y, ok2 := read_n(d, &i)
				if !ok2 {
					break
				}
				nxt := to_abs(cur, x, y, mrel)
				if !have_sub {
					have_sub = true
					moved = true
					sub_start = nxt
					cur = nxt
					add_pt(&pts, cur)
					processed = true
					mrel = false // subsequent pairs are linetos
				} else {
					// A moveto while a subpath is open: close it, then move.
					close_sub(&pts, &out)
					if len(pts) == 0 {
						add_pt(&pts, nxt)
					} else {
						add_pt(&pts, nxt)
					}
					cur = nxt
					sub_start = nxt
					have_sub = true
					processed = true
					mrel = false
				}
			}
		case 'L', 'l':
			for {
				x, ok1 := read_n(d, &i)
				if !ok1 {
					break
				}
				y, ok2 := read_n(d, &i)
				if !ok2 {
					break
				}
				nxt := to_abs(cur, x, y, relative)
				add_pt(&pts, nxt)
				cur = nxt
				sub_start = sub_start // keep
				processed = true
			}
			have_ctrl = false
		case 'H', 'h':
			for {
				x, ok1 := read_n(d, &i)
				if !ok1 {
					break
				}
				nxt := P2{}
				if relative {
					nxt = {cur.x + x, cur.y}
				} else {
					nxt = {x, cur.y}
				}
				add_pt(&pts, nxt)
				cur = nxt
				processed = true
			}
			have_ctrl = false
		case 'V', 'v':
			for {
				y, ok1 := read_n(d, &i)
				if !ok1 {
					break
				}
				nxt := P2{}
				if relative {
					nxt = {cur.x, cur.y + y}
				} else {
					nxt = {cur.x, y}
				}
				add_pt(&pts, nxt)
				cur = nxt
				processed = true
			}
			have_ctrl = false
		case 'C', 'c':
			for {
				c1x, ok1 := read_n(d, &i)
				c1y, ok2 := read_n(d, &i)
				c2x, ok3 := read_n(d, &i)
				c2y, ok4 := read_n(d, &i)
				ex, ok5 := read_n(d, &i)
				ey, ok6 := read_n(d, &i)
				if !(ok1 && ok2 && ok3 && ok4 && ok5 && ok6) {
					break
				}
				c1 := to_abs(cur, c1x, c1y, relative)
				c2 := to_abs(cur, c2x, c2y, relative)
				end := to_abs(cur, ex, ey, relative)
				cubic_flat(cur, c1, c2, end, tol, &pts)
				cur = end
				prev_ctrl = c2
				have_ctrl = true
				processed = true
			}
		case 'S', 's':
			for {
				c2x, ok1 := read_n(d, &i)
				c2y, ok2 := read_n(d, &i)
				ex, ok3 := read_n(d, &i)
				ey, ok4 := read_n(d, &i)
				if !(ok1 && ok2 && ok3 && ok4) {
					break
				}
				c1: P2
				if have_ctrl {
					c1 = {2 * cur.x - prev_ctrl.x, 2 * cur.y - prev_ctrl.y}
				} else {
					c1 = cur
				}
				c2 := to_abs(cur, c2x, c2y, relative)
				end := to_abs(cur, ex, ey, relative)
				cubic_flat(cur, c1, c2, end, tol, &pts)
				cur = end
				prev_ctrl = c2
				have_ctrl = true
				processed = true
			}
		case 'Q', 'q':
			for {
				q1x, ok1 := read_n(d, &i)
				q1y, ok2 := read_n(d, &i)
				ex, ok3 := read_n(d, &i)
				ey, ok4 := read_n(d, &i)
				if !(ok1 && ok2 && ok3 && ok4) {
					break
				}
				q1 := to_abs(cur, q1x, q1y, relative)
				end := to_abs(cur, ex, ey, relative)
				quad_flat(cur, q1, end, tol, &pts)
				cur = end
				prev_ctrl = q1
				have_ctrl = true
				processed = true
			}
		case 'T', 't':
			for {
				ex, ok1 := read_n(d, &i)
				ey, ok2 := read_n(d, &i)
				if !(ok1 && ok2) {
					break
				}
				q1: P2
				if have_ctrl {
					q1 = {2 * cur.x - prev_ctrl.x, 2 * cur.y - prev_ctrl.y}
				} else {
					q1 = cur
				}
				end := to_abs(cur, ex, ey, relative)
				quad_flat(cur, q1, end, tol, &pts)
				cur = end
				prev_ctrl = q1
				have_ctrl = true
				processed = true
			}
		case 'Z', 'z':
			close_sub(&pts, &out)
			cur = sub_start
			have_sub = false
			have_ctrl = false
			processed = true
		case:
			// Unknown command (arcs, etc.): consume one following number pair so
			// the loop does not spin, then continue.
			_, _ = read_n(d, &i)
			_, _ = read_n(d, &i)
		}

		if !processed && !ok {
			break
		}
		_ = finished
		_ = relative
	}
	if have_sub && len(pts) >= 3 && pts[0] != pts[len(pts) - 1] {
		append(&pts, pts[0])
	}
	if len(pts) >= 3 {
		append(&out, clone_path(&pts))
	} else {
		clear(&pts)
	}
	delete(pts)
	return out
}

clone_path :: proc(p: ^[dynamic]P2) -> [dynamic]P2 {
	out := make([dynamic]P2, len(p))
	copy(out[:], p[:])
	return out
}

// ---------------------------------------------------------------------------
// Scanline rasterizer (SVG coords -> R8 alpha in ICON_RASTER^2).
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// Scanline rasterizer (SVG coords -> R8 alpha in ICON_RASTER^2).
// ---------------------------------------------------------------------------

Icon_Cut :: struct { x: f32, dir: i8 }

// add_span weights every cell under the horizontal run [lo, hi) on the current
// scanline. Because a scanline is a thin sample, a crossing span contributes a
// unit of coverage to each cell it intersects.
add_span :: proc(row_cov: []f32, lo, hi: f32) {
	row := f32(int(ICON_RASTER))
	x0 := lo
	x1 := hi
	if x0 < 0 {
		x0 = 0
	}
	if x1 > row {
		x1 = row
	}
	if x1 <= x0 {
		return
	}
	c0 := int(math.floor(x0))
	c1 := int(math.ceil(x1))
	if c0 < 0 {
		c0 = 0
	}
	if c1 > int(row) {
		c1 = int(row)
	}
	for c in c0..<c1 {
		row_cov[c] += 1.0
	}
}

// rasterize_shape fills `out` (ICON_RASTER^2 R8 coverage bytes) from `shape`.
// Nonzero/evenodd winding per shape.rule; 4x vertical supersampling.
rasterize_shape :: proc(shape: ^Icon_Shape, out: []u8) -> bool {
	raster := ICON_RASTER
	if len(out) < raster * raster || shape.view[2] <= 0 || shape.view[3] <= 0 || len(shape.subs) == 0 {
		return false
	}
	scale := f32(raster) / shape.view[2]
	ox := shape.view[0]
	oy := shape.view[1]

	scaled := make([dynamic][dynamic]P2, len(shape.subs))
	defer {
		for &s in scaled {
			delete(s)
		}
		delete(scaled)
	}
	for i in 0..<len(shape.subs) {
		src := &shape.subs[i]
		slt := make([dynamic]P2, len(src))
		for j in 0..<len(src) {
			slt[j] = {(src[j].x - ox) * scale, (src[j].y - oy) * scale}
		}
		scaled[i] = slt
	}

	cuts := make([dynamic]Icon_Cut, 0, 32)
	defer delete(cuts)
	row_cov := make([]f32, raster)
	defer delete(row_cov)

	inside :: proc(rule: Icon_Rule, w: i32) -> bool {
		switch rule {
		case .EvenOdd:
			return w % 2 == 1
		case .NonZero:
			return w != 0
		}
		return false
	}

	SUBSY :: 4
	for y in 0..<raster {
		for c in 0..<raster {
			row_cov[c] = 0
		}
		for s in 0..<SUBSY {
			yc := f32(y) + (f32(s) + 0.5) / f32(SUBSY)
			clear(&cuts)
			// Cross-cut every subpath (implicitly closed for filling).
			for &sp in scaled {
				n := len(sp)
				if n < 2 {
					continue
				}
				for k in 0..<n {
					a := sp[k]
					b := sp[(k + 1) % n]
					if (a.y <= yc && b.y > yc) || (b.y <= yc && a.y > yc) {
						t := (yc - a.y) / (b.y - a.y)
						append(&cuts, Icon_Cut{x = a.x + t * (b.x - a.x), dir = b.y > a.y ? 1 : -1})
					}
				}
			}
			// Insertion sort (few cuts per scanline; avoids a comparator callback).
			for si in 1..<len(cuts) {
				key := cuts[si]
				j := si
				for j > 0 && cuts[j - 1].x > key.x {
					cuts[j] = cuts[j - 1]
					j -= 1
				}
				cuts[j] = key
			}
			w: i32 = 0
			last_x := f32(-1)
			for cut in cuts {
				if last_x >= 0 && inside(shape.rule, w) {
					add_span(row_cov, last_x, cut.x)
				}
				w += i32(cut.dir)
				last_x = cut.x
			}
			if last_x >= 0 && inside(shape.rule, w) {
				add_span(row_cov, last_x, f32(raster))
			}
		}
		row_off := y * raster
		for c in 0..<raster {
			cov := row_cov[c] / f32(SUBSY)
			if cov > 1 {
				cov = 1
			}
			out[row_off + c] = u8(cov * 255.0)
		}
	}
	return true
}

// rasterize_icon_svg rasterizes an embedded .svg body to a fresh ICON_RASTER^2
// R8 allocation. Caller owns and must delete the returned slice.
rasterize_icon_svg :: proc(svg: []u8) -> ([]u8, bool) {
	shape, ok := build_icon_shape(svg)
	if !ok {
		return nil, false
	}
	defer destroy_icon_shape(&shape)
	out := make([]u8, ICON_RASTER * ICON_RASTER)
	return out, rasterize_shape(&shape, out)
}
