#+build windows

package main

import win32 "core:sys/windows"
import "core:strings"

// ---------------------------------------------------------------------------
// Windows file picker.
//
// Linux uses xdg-desktop-portal through glib/gio (`portal.odin`); that does not
// exist on Windows. This provides the `win32_open_file_picker` entry point used
// by `media.open_file_picker` on `.Windows`, backed by the Win32 common dialog
// (`GetOpenFileNameW`).
//
// The returned value is a cstring into a package-level buffer, kept alive for
// the duration of the program (mirrors the persistent `g_filename_from_uri`
// result the Linux portal returns). Reusing the buffer each call is fine: the
// previous import has already been consumed.
// ---------------------------------------------------------------------------

win32_picked_path: [1024]byte

win32_open_file_picker :: proc() -> cstring {
	filters := strings.concatenate({
		"Video",
		"\0",
		"*.mp4;*.m4v;*.mov;*.mkv;*.webm;*.avi;*.mpeg;*.mpg;*.ts;*.m2ts;*.flv;*.wmv;*.3gp",
		"\0",
		"Audio",
		"\0",
		"*.mp3;*.wav;*.flac;*.ogg;*.opus;*.m4a;*.aac",
		"\0",
		"Images",
		"\0",
		"*.png;*.jpg;*.jpeg;*.webp;*.gif;*.bmp;*.tiff",
		"\0",
		"All Files",
		"\0",
		"*.*",
		"\0\0",
	}, context.temp_allocator)

	file_buf := make([]u16, win32.MAX_PATH_WIDE, context.temp_allocator)
	defer delete(file_buf)

	ofn := win32.OPENFILENAMEW{
		lStructSize  = size_of(win32.OPENFILENAMEW),
		lpstrFile    = wstring(&file_buf[0]),
		nMaxFile     = win32.MAX_PATH_WIDE,
		lpstrTitle   = win32.utf8_to_wstring("Open media file", context.temp_allocator),
		lpstrFilter  = win32.utf8_to_wstring(filters, context.temp_allocator),
		Flags        = win32.OPEN_FLAGS,
	}

	if win32.GetOpenFileNameW(&ofn) == 0 {
		return nil // user cancelled or error
	}

	path_utf8, ok := win32.utf16_to_utf8(file_buf[:], context.temp_allocator)
	if !ok {
		return nil
	}
	path_utf8 = strings.trim_right_null(path_utf8)
	// Copy into the persistent global so the cstring survives frame-to-frame.
	n := copy(win32_picked_path[:], path_utf8)
	win32_picked_path[n] = 0
	return cstring(&win32_picked_path[0])
}