#+build windows

package main

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
// handler is installed and the fixed .mdmp/.txt log path, both written during
// startup guard, never torn down.
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
	if !crash_state.handler_installed {
		w := win32.utf8_to_utf16_buf(crash_state.log_name[:], "vyper_crash.log")
		if w != nil {crash_state.log_name[len(w)] = 0}
		win32.SetUnhandledExceptionFilter(crash_filter)
		crash_state.handler_installed = true
	}
}
