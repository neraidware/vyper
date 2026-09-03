#+build windows

package main

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

crash_log_put :: proc "system" (b: []u8, p: ^int, c: u8) {
	if p^ < len(b) { b[p^] = c }
	p^ += 1
}

crash_log_put_cstr :: proc "system" (b: []u8, p: ^int, s: string) {
	for i := 0; i < len(s); i += 1 { crash_log_put(b, p, s[i]) }
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

	crash_log_put_cstr(buf[:], &pos, "nered crash\nexception_code=0x")
	crash_log_put_hex(buf[:], &pos, u64(code), 8)
	crash_log_put_cstr(buf[:], &pos, "\nfault_address=0x")
	crash_log_put_hex(buf[:], &pos, u64(addr), 16)
	crash_log_put_cstr(buf[:], &pos, "\n")

	log_handle := win32.CreateFileW(
		cast(cstring16)&crash_log_name[0],
		win32.GENERIC_WRITE,
		win32.FILE_SHARE_READ,
		nil,
		win32.CREATE_ALWAYS,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if log_handle == win32.INVALID_HANDLE_VALUE { return }

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
	if !crash_handler_installed {
		w := win32.utf8_to_utf16_buf(crash_log_name[:], "nered_crash.log")
		if w != nil { crash_log_name[len(w)] = 0 }
		win32.SetUnhandledExceptionFilter(crash_filter)
		crash_handler_installed = true
	}
}