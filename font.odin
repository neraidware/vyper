package main

import "core:fmt"
import "core:os"
import posix "core:sys/posix"
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
	// Ask Fontconfig for configured monospace family instead of hard-coding font.
	pipe := posix.popen("fc-match -f '%{file}' monospace", "r")
	if pipe != nil {
		posix.fgets(raw_data(system_font_path[:]), len(system_font_path), pipe)
		posix.pclose(pipe)
		for i in 0..<len(system_font_path) {
			if system_font_path[i] == '\n' {
				system_font_path[i] = 0
				break
			}
		}
		if system_font_path[0] != 0 {
			return cstring(raw_data(system_font_path[:]))
		}
	}
	return "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
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
