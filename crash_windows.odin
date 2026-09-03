#+build windows

package main

import "core:fmt"
import "core:os"

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
// ---------------------------------------------------------------------------

crash_handler_installed: bool

crash_filter :: proc "system" (ep: ^win32.EXCEPTION_POINTERS) -> win32.LONG {
	if ep != nil && ep.ExceptionRecord != nil {
		code := ep.ExceptionRecord.ExceptionCode
		addr := uintptr(ep.ExceptionRecord.ExceptionAddress)

		f, ferr := os.open("nered_crash.log", os.O_CREATE | os.O_WRONLY | os.O_TRUNC)
		if ferr == nil {
			defer os.close(f)
			fmt.fprintln(f, "nered crash")
			fmt.fprintf(f, "exception_code=0x%08X\n", u32(code))
			fmt.fprintf(f, "fault_address=0x%p\n", addr)
			fmt.fprintf(f, "fault_below_4G=%v\n", addr < 0x100000000)
		}
	}
	// Let the OS also show its own error dialog.
	return win32.EXCEPTION_CONTINUE_SEARCH
}

crash_handler_install :: proc() {
	if !crash_handler_installed {
		win32.SetUnhandledExceptionFilter(crash_filter)
		crash_handler_installed = true
	}
}