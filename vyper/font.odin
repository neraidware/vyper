package vyper

import clay "clay-odin"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Font loading (via fontconfig) and Clay text-measurement/error callbacks.
// ---------------------------------------------------------------------------

// Font_State is the loaded UI font: the in-memory TTF bytes and the
// resolved fontconfig path buffer used to find them. Owned by load_font_data /
// system_monospace_font; read by Clay setup.
Font_State :: struct {
	data:       []byte,
	// sys_path is where system_monospace_font writes the resolved path.
	sys_path:   [1024]byte,
}
font_state: Font_State

load_font_data :: proc() -> bool {
	path := string(system_monospace_font())
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil || len(data) == 0 {
		fmt.println("Could not load font:", path)
		return false
	}
	font_state.data = data
	return true
}

system_monospace_font :: proc() -> cstring {
	sys := &font_state.sys_path
	when ODIN_OS == .Windows {
		// No fontconfig on Windows: prefer Noto Sans if present, else Segoe UI
		// (the default sans face that ships with every install).
		noto := "C:\\Windows\\Fonts\\NotoSans-Regular.ttf"
		if os.exists(noto) {
			n := copy(sys[:], noto)
			sys[n] = 0
			return cstring(&sys[0])
		}
		computed := "C:\\Windows\\Fonts\\segoeui.ttf"
		n := copy(sys[:], computed)
		sys[n] = 0
		return cstring(&sys[0])
	} else {
		// Ask Fontconfig for DejaVu Sans (the editor UI + title/subtitle clips),
		// instead of hard-coding a path. fc-match aliases "DejaVu Sans" and falls
		// back to the nearest configured sans when it is not installed.
		out, _, okin := run_capture({"fc-match", "-f", "%{file}", "monospace"})
		defer delete(out)
		if okin && len(out) > 0 {
n := copy(sys[:], strings.trim_space(out))
			sys[n] = 0
			if sys[0] != 0 {
				return cstring(&sys[0])
			}
		}
		return "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
	}
}

// FONT_ADVANCE_RATIO is the width of one rune as a fraction of the font size.
// It is the whole of clay's text measurement, and text_px (ui.odin) multiplies
// by the same number to decide where a label has to be cut — so a truncation
// lands exactly where clay would have laid the text out. Two copies of this
// constant would be a number that drifts: the cut would land in the wrong place
// the moment one of them moved.
FONT_ADVANCE_RATIO :: f32(0.55)

measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	user_data: rawptr,
) -> clay.Dimensions {
	// Temporary font metrics keep layout independent from renderer resources.
	// Count runes, not bytes -- a multi-byte rune like <é> lays out one glyph
	// regardless of its UTF-8 width, so extra bytes must not widen the box.
	runes := 0
	raw := ([^]u8)(text.chars)[:int(text.length)]
	for i := 0; i < len(raw); {
		r, size := utf8.decode_rune(string(raw[i:]))
		runes += 1
		i += size
	}
	return {width = f32(runes) * f32(config.fontSize) * FONT_ADVANCE_RATIO, height = f32(config.fontSize)}
}

clay_error :: proc "c" (data: clay.ErrorData) {
}
