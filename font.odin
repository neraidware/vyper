package main

import "core:fmt"
import "core:os"
import "core:strings"
import clay "clay-odin"

// ---------------------------------------------------------------------------
// Font loading (via fontconfig) and Clay text-measurement/error callbacks.
// ---------------------------------------------------------------------------

font_data: []byte

load_font_data :: proc() -> bool {
	path := string(system_monospace_font())
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil || len(data) == 0 {
		fmt.println("Could not load font:", path)
		return false
	}
	font_data = data
	return true
}

system_font_path: [1024]byte

system_monospace_font :: proc() -> cstring {
	when ODIN_OS == .Windows {
		// Windows ships Consolas in %SystemRoot%\Fonts on every install; use it
		// directly (no fontconfig on Windows).
		computed := "C:\\Windows\\Fonts\\consola.ttf"
		n := copy(system_font_path[:], computed)
		system_font_path[n] = 0
		return cstring(&system_font_path[0])
	} else {
		// Ask Fontconfig for configured monospace family instead of hard-coding font.
		out, _, okin := run_capture({"fc-match", "-f", "%{file}", "monospace"})
		defer delete(out)
		if okin && len(out) > 0 {
			n := copy(system_font_path[:], strings.trim_space(out))
			system_font_path[n] = 0
			if system_font_path[0] != 0 {
				return cstring(&system_font_path[0])
			}
		}
		return "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
	}
}

measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	user_data: rawptr,
) -> clay.Dimensions {
	// Temporary font metrics keep layout independent from renderer resources.
	return {width = f32(text.length) * f32(config.fontSize) * 0.55, height = f32(config.fontSize)}
}

clay_error :: proc "c" (data: clay.ErrorData) {
}
