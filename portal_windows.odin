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
// The returned value is a cstring cloned to the session allocator, owned for
// the rest of the program. Assets and clips store their path by reference
// (`Media_Asset.path = path`), so each call must mint its own buffer: a shared
// one would be overwritten by the next import, silently retargeting earlier
// assets and clips to the latest file. This mirrors the per-call
// `g_filename_from_uri` results the Linux portal returns.
// ---------------------------------------------------------------------------

win32_open_file_picker :: proc() -> cstring {
	filters := strings.concatenate({
		"Media files",
		"\x00",
		"*.mp4;*.m4v;*.mov;*.mkv;*.webm;*.avi;*.mpeg;*.mpg;*.ts;*.m2ts;*.flv;*.wmv;*.3gp;*.mp3;*.wav;*.flac;*.ogg;*.opus;*.m4a;*.aac;*.png;*.jpg;*.jpeg;*.webp;*.gif;*.bmp;*.tiff;*.srt",
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
		lpstrFile    = win32.wstring(&file_buf[0]),
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
		lpstrFile    = win32.wstring(&file_buf[0]),
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
win32_save_file_picker :: proc() -> cstring {
	filters := strings.concatenate({
		"MP4 video",
		"\x00",
		"*.mp4",
		"\x00",
		"All Files",
		"\x00",
		"*.*",
		"\x00\x00",
	}, context.temp_allocator)

	file_buf := make([]u16, win32.MAX_PATH_WIDE, context.temp_allocator)
	defer delete(file_buf)
	if render_output.path_len > 0 {
		// Pre-fill the dialog filename with the last render path. The render
		// path is UTF-8 and the dialog wants UTF-16; a byte-for-byte copy would
		// print every non-ASCII name wrong. A too-long/invalid name just opens
		// the dialog empty -- cosmetic, so a failed conversion is dropped.
		_ = win32.utf8_to_utf16_buf(file_buf[:], string(render_output.path_buf[:render_output.path_len]))
	}

	ofn := win32.OPENFILENAMEW{
		lStructSize  = size_of(win32.OPENFILENAMEW),
		lpstrFile    = win32.wstring(&file_buf[0]),
		nMaxFile     = win32.MAX_PATH_WIDE,
		lpstrTitle   = win32.utf8_to_wstring("Save render output", context.temp_allocator),
		lpstrFilter  = win32.utf8_to_wstring(filters, context.temp_allocator),
		lpstrDefExt  = win32.utf8_to_wstring("mp4", context.temp_allocator),
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