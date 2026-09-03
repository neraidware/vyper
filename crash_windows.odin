#+build windows

package main

import "core:fmt"

import win32 "core:sys/windows"

// ---------------------------------------------------------------------------
// Windows crash handler.
//
// Installs a SetUnhandledExceptionFilter so an unhandled crash writes
// nered_crash.log next to the exe with the exception code and faulting
// address. A crash report of just "it closed" becomes concrete exceptions
// (e.g. 0xC0000005 access violation, 0xC00000FD stack overflow). Without a
// PDB / full minidump this can't walk the stack, but code+address is what
// separates a bug in nered from a fault inside a loaded DLL.
//
// The handler itself uses only raw Win32 (CreateFileW/WriteFile) and a stack
// buffer for formatting: no Odin heap allocator, so it stays safe even when
// the heap state is what crashed the process - a "system" calling-convention
// proc has no Odin context and must not allocate.
// ---------------------------------------------------------------------------

crash_handler_installed: bool

crash_log_name: [win32.MAX_PATH]u16
crash_log_wide_len: int

crash_log_write :: proc(code: u32, addr: uintptr) {
	buf: [256]u8
	n := fmt.bprintf(buf[:], "nered crash\nexception_code=0x%08X\nfault_address=0x%p\n", code, addr)

	log_name := crash_log_name[:crash_log_wide_len]
	log_handle := win32.CreateFileW(
		cast(win32.LPCWSTR)log_name,
		win32.GENERIC_WRITE,
		win32.FILE_SHARE_READ,
		nil,
		win32.CREATE_ALWAYS,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if log_handle == win32.INVALID_HANDLE_VALUE { return }

	written: win32.DWORD
	win32.WriteFile(log_handle, &buf[0], u32(n), &written, nil)
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
	if !crash_handler_installed {
		w := win32.utf8_to_utf16_buf(crash_log_name[:], "nered_crash.log")
		crash_log_wide_len = len(w)
		win32.SetUnhandledExceptionFilter(crash_filter)
		crash_handler_installed = true
	}
}