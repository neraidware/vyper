#+build windows

package vyper

import "core:c"
import "core:fmt"
import win32 "core:sys/windows"
import avcodec "vendor/ffmpeg/avcodec"
import avfmt "vendor/ffmpeg/avformat"
import avutil "vendor/ffmpeg/avutil"
import sws "vendor/ffmpeg/swscale"

// ---------------------------------------------------------------------------
// Windows crash handler.
//
// Installs a SetUnhandledExceptionFilter so an unhandled crash writes
// vyper_crash.log next to the exe with the exception code and faulting
// address. A crash report of just "it closed" becomes concrete exceptions
// (e.g. 0xC0000005 access violation, 0xC00000FD stack overflow). Without a
// PDB / full minidump this can't walk the stack, but code+address is what
// separates a bug in vyper from a fault inside a loaded DLL.
//
// The handler itself uses only raw Win32 (CreateFileW/WriteFile) and a stack
// buffer for formatting: no Odin heap allocator, so it stays safe even when
// the heap state is what crashed the process - a "system" calling-convention
// proc has no Odin context and must not allocate.
// ---------------------------------------------------------------------------

// Crash_State is the crash-handler's once-only setup state: whether the
// handler is installed and the absolute log path next to the exe, both written
// during startup guard, never torn down.
Crash_State :: struct {
	handler_installed: bool,
	log_name:          [win32.MAX_PATH]u16,
}
crash_state: Crash_State

// win_ffmpeg_versions_diag prints the running FFmpeg shared-library majors once,
// first thing at startup. The vendored bindings link these DLLs at import time;
// if the DLL set on disk has drifted from the ABI the bindings were written
// against, the very first in-process decode (the thumbnail of a just-opened
// video) faults inside the DLLs. This line separates "DLL/binding drift" (majors
// here disagree with what the bindings expect) from a code bug in the decode
// path -- read it in CI logs or before the crash, it is printed before any
// window/canvas work.
ff_major :: proc(v: c.uint) -> u32 {
	return u32(v >> 16)
}

win_ffmpeg_versions_diag :: proc() {
	fmt.printf(
		"[win-ff] avformat=%d avcodec=%d avutil=%d swscale=%d\n",
		ff_major(avfmt.version()),
		ff_major(avcodec.version()),
		ff_major(avutil.version()),
		ff_major(sws.version()),
	)
}

crash_log_put :: proc "system" (b: []u8, p: ^int, c: u8) {
	if p^ < len(b) {b[p^] = c}
	p^ += 1
}

crash_log_put_cstr :: proc "system" (b: []u8, p: ^int, s: string) {
	for i := 0; i < len(s); i += 1 {crash_log_put(b, p, s[i])}
}

crash_log_put_hex :: proc "system" (b: []u8, p: ^int, value: u64, width: int) {
	d := "0123456789ABCDEF"
	v := value
	for i := width - 1; i >= 0; i -= 1 {
		crash_log_put(b, p, d[v & 0xF])
		v >>= 4
	}
}

crash_log_write :: proc "system" (code: u32, addr: uintptr) {
	buf: [256]u8
	pos := 0

	crash_log_put_cstr(buf[:], &pos, "vyper crash\nexception_code=0x")
	crash_log_put_hex(buf[:], &pos, u64(code), 8)
	crash_log_put_cstr(buf[:], &pos, "\nfault_address=0x")
	crash_log_put_hex(buf[:], &pos, u64(addr), 16)
	crash_log_put_cstr(buf[:], &pos, "\n")

	log_handle := win32.CreateFileW(
		cast(cstring16)&crash_state.log_name[0],
		win32.GENERIC_WRITE,
		win32.FILE_SHARE_READ,
		nil,
		win32.CREATE_ALWAYS,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if log_handle == win32.INVALID_HANDLE_VALUE {return}

	written: win32.DWORD
	win32.WriteFile(log_handle, cast(win32.LPVOID)&buf[0], u32(pos), &written, nil)
	win32.CloseHandle(log_handle)
}

crash_filter :: proc "system" (ep: ^win32.EXCEPTION_POINTERS) -> win32.LONG {
	if ep != nil && ep.ExceptionRecord != nil {
		crash_log_write(
			u32(ep.ExceptionRecord.ExceptionCode),
			uintptr(ep.ExceptionRecord.ExceptionAddress),
		)
	}
	// Let the OS also show its own error dialog.
	return win32.EXCEPTION_CONTINUE_SEARCH
}

crash_handler_install :: proc() {
	if crash_state.handler_installed {return}

	// Win32 path separators as they appear in the UTF-16 module path. Both are
	// accepted: GetModuleFileNameW echoes whatever the loader was given, and a
	// binary launched through a forward-slash path gets forward slashes back.
	SEPARATOR      :: u16(0x5C) // '\'
	SEPARATOR_ALT  :: u16(0x2F) // '/'

	// The log goes NEXT TO THE EXE, and a bare filename does NOT mean that:
	// Windows resolves a relative path against the process working directory,
	// so "vyper_crash.log" was written wherever the user happened to launch
	// from -- a desktop, a shortcut's "Start in", a project folder -- and the
	// documented location stayed empty after a crash. Resolve the module path
	// and build the name from it, so the file is where the header says it is.
	//
	// The file name is converted into its OWN buffer first: the conversion
	// writes from index 0, so running it over the module path would overwrite
	// the very directory prefix the name has to be appended to.
	CRASH_LOG_FILE_NAME :: "vyper_crash.log"
	file_name: [32]u16
	name_w := win32.utf8_to_utf16_buf(file_name[:], CRASH_LOG_FILE_NAME)

	module_path: [win32.MAX_PATH]u16
	copied := int(
		win32.GetModuleFileNameW(nil, &module_path[0], win32.DWORD(len(module_path))),
	)
	// A result that exactly fills the buffer was truncated, so its tail -- and
	// therefore the directory split below -- would not be the real path.
	if name_w != nil && copied > 0 && copied < len(module_path) {
		// Drop the trailing NUL so the split sees only real characters.
		path_len := copied
		if module_path[path_len - 1] == 0 {path_len -= 1}

		// Scan back to the last separator: the file name starts just past it,
		// which is where the log name has to be appended.
		name_start := path_len
		for i := path_len - 1; i >= 0; i -= 1 {
			if module_path[i] == SEPARATOR || module_path[i] == SEPARATOR_ALT {
				name_start = i + 1
				break
			}
		}

		if name_start + len(name_w) < len(crash_state.log_name) {
			for i in 0 ..< name_start {crash_state.log_name[i] = module_path[i]}
			for i in 0 ..< len(name_w) {crash_state.log_name[name_start + i] = name_w[i]}
			crash_state.log_name[name_start + len(name_w)] = 0
		}
	}

	// Fall back to the bare name if the module path could not be resolved: a log
	// in an unknown directory still beats no crash record at all.
	if crash_state.log_name[0] == 0 {
		_ = win32.utf8_to_utf16_buf(crash_state.log_name[:], CRASH_LOG_FILE_NAME)
	}

	win32.SetUnhandledExceptionFilter(crash_filter)
	crash_state.handler_installed = true
}
