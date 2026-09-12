# Building & Running vyper on Windows

## CI

A GitHub Actions workflow (`/.github/workflows/windows.yml`) builds a Windows
executable on every push. The runner is `windows-latest` (VS 2022 + MSVC).
The artifact `vyper-windows` contains the exe + all required DLLs + ffmpeg/ffprobe.

Download: https://github.com/neraidware/vyper/actions → latest successful `windows` run → `vyper-windows` artifact.

## Dependencies (provided by CI; listed here for local dev)

| Dep | Source | Layout |
|-----|--------|--------|
| Odin `dev-2026-07a` | [laytan/setup-odin](https://github.com/laytan/setup-odin) or [releases](https://github.com/odin-lang/Odin/releases) | System-wide |
| SDL3 3.4.14 | `SDL3-devel-3.4.14-VC.zip` from [SDL3 releases](https://github.com/libsdl-org/SDL/releases) | `lib/x64/SDL3.lib` + `lib/x64/SDL3.dll` |
| ffmpeg (shared, BtbN) | [ffmpeg-master-latest-win64-gpl-shared.zip](https://github.com/BtbN/FFmpeg-Builds/releases/latest) | `lib/*.lib` (import) + `bin/*.dll` + `bin/ffmpeg.exe` + `bin/ffprobe.exe` |

## Build command

```
odin build . -out:vyper.exe -define:FFMPEG_LINK=system -extra-linker-flags:"/LIBPATH:C:\path\to\sdl3\lib\x64;C:\path\to\ffmpeg\lib"
```

### Critical: ffmpeg import libs must be in vendor/ffmpeg/\<lib\>/

The vendored `vendor:ffmpeg` bindings declare Windows imports as bare relative
names (`foreign import "avcodec.lib"`), which Odin resolves relative to the
binding source file dir (`vendor/ffmpeg/<lib>/<lib>.lib`) and passes as an
absolute file path to `link.exe`. **`/LIBPATH` does not apply** for these.

The CI copies the BtbN import libs into the correct vendor slots before
building. If building locally, you must do the same:

```powershell
Copy-Item deps\lib\avcodec.lib   vendor\ffmpeg\avcodec\avcodec.lib -Force
Copy-Item deps\lib\avformat.lib  vendor\ffmpeg\avformat\avformat.lib -Force
Copy-Item deps\lib\avutil.lib    vendor\ffmpeg\avutil\avutil.lib -Force
Copy-Item deps\lib\swresample.lib vendor\ffmpeg\swresample\swresample.lib -Force
Copy-Item deps\lib\swscale.lib   vendor\ffmpeg\swscale\swscale.lib -Force
```

SDL3 is different: `vendor:sdl3` uses `{ "SDL3.lib" }` (name form), resolved
via `/LIBPATH`.

## Runtime

All files must be co-located (`dist/`):

```
vyper.exe
SDL3.dll
ffmpeg.exe        ← vyper shells out to this for transcoding
ffprobe.exe       ← vyper shells out to this for probing
avcodec-63.dll    ← ffmpeg runtime DLLs (version numbers vary by BtbN build)
avformat-63.dll
avutil-61.dll
swresample-7.dll
swscale-10.dll
```

`ffmpeg.exe`/`ffprobe.exe` must live next to `vyper.exe` — vyper resolves them
by exe directory, not `PATH`. On a crash, vyper writes `vyper_crash.log`
(exception code + fault address) in this same directory.

Preview proxies (low-res all-intra cache of edited clips) are stored under
`%LOCALAPPDATA%\vyper\` — `<base>-<hash>.vyperproxy.mp4`, per-segment
`.vyperproxy.segNNNN.mp4`, and the `.vyperproxy.idx` index. Old proxies from
before this change may linger in `%USERPROFILE%\.cache\vyper\`.

## CI smoke test (decode + proxy)

The `windows` workflow runs headless probes against the staged `dist/` before
uploading the artifact, so a build whose FFmpeg DLL set or decode path is broken
fails the run instead of shipping a binary that crashes on open:

- generates `sample.mp4` with the bundled `ffmpeg.exe`; then
- `VYPER_FRAME_PROBE="sample.mp4|0-240|30"` decodes a frame range through the
  vendored FFmpeg DLLs; and
- `VYPER_PROXY_PROBE="sample.mp4"` builds a proxy with `ffmpeg.exe` and verifies
  proxy/source parity.
- Any non-zero exit, or `vyper_crash.log` next to the exe, fails the job.

`vyper.exe` also prints the linked FFmpeg majors first thing on startup:
`[win-ff] avformat=N avcodec=N avutil=N swscale=N`. If those differ from the
majors the vendored bindings target, the first in-process decode (thumbnail of a
just-opened video) can fault inside the DLLs — the print separates DLL/binding
drift from a code bug in the decode path.

## What was ported

- **Shell-outs** (`posix.popen/fgets/pclose`) → `run_capture()` via
  `core:os.process_exec` (argv, no shell — works on both Windows and Unix).
  Files: `subprocess.odin` (new), `media.odin`, `proxy.odin`, `font.odin`.
- **ffprobe/ffmpeg exe-dir resolution** (`subprocess.odin`): on Windows,
  `CreateProcessW` does not search the running exe's directory for a bare
  argv0. `resolve_tool_argv()` rewrites a bare `ffprobe`/`ffmpeg` argv0 to
  `<exe_dir>\ffprobe.exe` / `<exe_dir>\ffmpeg.exe` via
  `os.get_executable_directory`, so vyper finds its co-located tools regardless
  of the CWD that launched it.
- **Crash logger** (`crash_windows.odin`, gated `#+build windows`): installs a
  `SetUnhandledExceptionFilter` via `crash_handler_install()` (called from
  `main.odin` under `when ODIN_OS == .Windows`) that writes `vyper_crash.log`
  next to the exe with `exception_code` + `fault_address` on an unhandled
  exception. Uses only raw `CreateFileW`/`WriteFile` + a stack buffer and
  `proc "system"` bindings, so it works with no Odin `context`/allocator. This
  is how crashes (e.g. on file open) are diagnosed on Windows.
- **File picker** (`portal.odin` xdg-desktop-portal) → Win32
  `GetOpenFileNameW` common dialog (`portal_windows.odin`, gated with
  `#+build windows`). `portal.odin` gated with `#+build !windows`.
- **System font**: Windows → `C:\Windows\Fonts\consola.ttf` (Consolas); Linux
  → `fc-match` via `run_capture`. File: `font.odin`.
- **Shader compilation**: `.spv` files are committed in the repo; the CI
  recompiles them when `glslangValidator` is available (best-effort).

## Architecture notes

- `vendor:sdl3` on `ODIN_OS == .Windows` links `SDL3.lib` (static import lib)
  from the vendored `SDL3.dll`; no SDL3_ttf at runtime.
- `vendor:ffmpeg` uses `FFMPEG_LINK :: #config(FFMPEG_LINK, "system")`. On
  Windows this resolves to bare `<lib>.lib` by name (vendor-dir-relative), as
  opposed to the `static`/`shared` modes that point at `windows_x64/*.lib`.
- `clay-odin` selects `windows/clay.lib` for `.Windows` (`clay-odin/clay.odin`).
- The Odin release **must be `dev-2026-07a` or later** (dev-2026-04 is missing
  `sdl.Condition`/`sdl.CreateCondition` which `vdecode.odin` requires).

## Not working yet

- `win32_open_file_picker` returns a `cstring` into a `[1024]byte` global;
  very long paths may be truncated. Acceptable for typical media files.
- No `build.bat`/`build.ps1` for local Windows dev (the CI workflow is the
  canonical build script).
