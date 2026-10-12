#+build windows

package vyper

import win32 "core:sys/windows"
import "core:fmt"
import "core:strings"

// ---------------------------------------------------------------------------
// Windows file picker.
//
// Linux uses xdg-desktop-portal through glib/gio (`portal.odin`); that does not
// exist on Windows. This provides the `win32_open_file_picker` entry point used
// by `media.open_file_picker` on `.Windows`, backed by the Win32 common dialog
// (`GetOpenFileNameW`).
//
// The returned value is a cstring cloned to the session allocator, owned for
// the rest of the program. Assets and clips copy this path into their own
// session buffers (`import_media_to_bin` clones it), so each call mints its own
// buffer for the caller's own bookkeeping, and a shared one would be
// overwritten by the next import. This mirrors the per-call
// `g_filename_from_uri` results the Linux portal returns.
// ---------------------------------------------------------------------------

win32_open_file_picker :: proc() -> cstring {
	filters := strings.concatenate({
		"Media and projects",
		"\x00",
		"*.mp4;*.m4v;*.mov;*.mkv;*.webm;*.avi;*.mpeg;*.mpg;*.ts;*.m2ts;*.flv;*.wmv;*.3gp;*.mp3;*.wav;*.flac;*.ogg;*.opus;*.m4a;*.aac;*.png;*.jpg;*.jpeg;*.webp;*.gif;*.bmp;*.tiff;*.srt;*.vyproj",
		"\x00",
		"All Files",
		"\x00",
		"*.*",
		"\x00\x00",
	}, context.temp_allocator)

	// lpstrFile is LPWSTR (^WCHAR) as of Odin dev-2026-10; dev-2026-09 typed it
	// cstring16 and wanted a win32.wstring() wrap. The field changed, not just the
	// helper, so the two versions need different source here.
	file_buf := make([]u16, win32.MAX_PATH_WIDE, context.temp_allocator)
	defer delete(file_buf)

	ofn := win32.OPENFILENAMEW{
		lStructSize  = size_of(win32.OPENFILENAMEW),
		lpstrFile    = &file_buf[0],
		nMaxFile     = win32.MAX_PATH_WIDE,
		lpstrTitle   = win32.utf8_to_wstring("Open media file", context.temp_allocator),
		lpstrFilter  = win32.utf8_to_wstring(filters, context.temp_allocator),
		Flags        = win32.OPEN_FLAGS,
	}

	if win32.GetOpenFileNameW(&ofn) == win32.FALSE {
		return nil // user cancelled or error
	}

	path_utf8, err := win32.utf16_to_utf8(file_buf[:], context.temp_allocator)
	if err != nil {
		return nil
	}
	return strings.clone_to_cstring(path_utf8)
}

// win32_open_srt_picker is the subtitle variant of win32_open_file_picker,
// filtered to .srt files.
win32_open_srt_picker :: proc() -> cstring {
	filters := strings.concatenate({
		"Subtitle files",
		"\x00",
		"*.srt",
		"\x00",
		"All Files",
		"\x00",
		"*.*",
		"\x00\x00",
	}, context.temp_allocator)

	file_buf := make([]u16, win32.MAX_PATH_WIDE, context.temp_allocator)
	defer delete(file_buf)

	ofn := win32.OPENFILENAMEW{
		lStructSize  = size_of(win32.OPENFILENAMEW),
		lpstrFile    = &file_buf[0],
		nMaxFile     = win32.MAX_PATH_WIDE,
		lpstrTitle   = win32.utf8_to_wstring("Select subtitle file", context.temp_allocator),
		lpstrFilter  = win32.utf8_to_wstring(filters, context.temp_allocator),
		Flags        = win32.OPEN_FLAGS,
	}

	if win32.GetOpenFileNameW(&ofn) == win32.FALSE {
		return nil // user cancelled or error
	}

	path_utf8, err := win32.utf16_to_utf8(file_buf[:], context.temp_allocator)
	if err != nil {
		return nil
	}
	return strings.clone_to_cstring(path_utf8)
}

// win32_save_file_picker opens the Win32 common Save-As dialog for the render
// output path, pre-filtered to .mp4 with an overwrite prompt. Mirror of
// win32_open_file_picker using GetSaveFileNameW.
win32_save_file_picker :: proc(target: Save_Target) -> cstring {
	def_ext := "mp4"
	primary := "MP4 video"
	if target == .Project {
		def_ext = "vyproj"
		primary = "vyper projects"
	}
	// Odin concatenates only constant strings, so the pattern is formatted into a
	// fixed buffer rather than built with "+".
	pattern_buf: [64]u8
	pattern_len := len(fmt.bprintf(pattern_buf[:], "*.%s", def_ext))
	if pattern_len <= 0 || pattern_len >= len(pattern_buf) {
		return nil
	}
	pattern_buf[pattern_len] = 0
	filters := strings.concatenate({
		primary,
		"\x00",
		string(pattern_buf[:pattern_len]),
		"\x00",
		"All Files",
		"\x00",
		"*.*",
		"\x00\x00",
	}, context.temp_allocator)

	file_buf := make([]u16, win32.MAX_PATH_WIDE, context.temp_allocator)
	defer delete(file_buf)
	{
		// Pre-fill with what is being saved. The name is UTF-8 and the dialog
		// wants UTF-16; a byte-for-byte copy would print every non-ASCII name
		// wrong. A too-long/invalid name just opens the dialog empty --
		// cosmetic, so a failed conversion is dropped.
		name_buf: [512]u8
		written := len(fmt.bprintf(name_buf[:], "%s", save_target_name(target)))
		if written > 0 {
			name_buf[written] = 0
			_ = win32.utf8_to_utf16_buf(file_buf[:], string(name_buf[:written]))
		}
	}

	ofn := win32.OPENFILENAMEW{
		lStructSize  = size_of(win32.OPENFILENAMEW),
		lpstrFile    = &file_buf[0],
		nMaxFile     = win32.MAX_PATH_WIDE,
		lpstrTitle   = win32.utf8_to_wstring(save_target_title(target), context.temp_allocator),
		lpstrFilter  = win32.utf8_to_wstring(filters, context.temp_allocator),
		lpstrDefExt  = win32.utf8_to_wstring(def_ext, context.temp_allocator),
		Flags        = win32.SAVE_FLAGS,
	}

	if win32.GetSaveFileNameW(&ofn) == win32.FALSE {
		return nil // user cancelled or error
	}

	path_utf8, err := win32.utf16_to_utf8(file_buf[:], context.temp_allocator)
	if err != nil {
		return nil
	}
	return strings.clone_to_cstring(path_utf8)
}