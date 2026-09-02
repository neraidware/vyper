# Building & Running nered on Windows

Window for cross-building: it is **not possible to cross-compile a Windows
binary from the Linux box** — nered's build uses host odin + host C toolchain
for post-processing (glslang), and the vendor libs/ffmpeg path differ per-OS. A
Windows build must run **on Windows** under `odin build . -o:speed` targeting
`windows/amd64`. This file lists what has to exist/change for that build to
work and for the app to run.

## What already portables

Most of the render/runtime stack is SDL3 and thus portable — SDL3 abstracts the
GPU backend (Vulkan on Windows), swapchain, window, and audio internally, so no
`VK_KHR_win32_surface`-style code is needed:

- `main.odin` window/GPU/swapchain init: `sdl.CreateWindow`, `sdl.CreateGPUDevice`,
  `sdl.WaitAndAcquireGPUSwapchainTexture` — cross-platform (`main.odin:396,407,1153`).
- `vendor:sdl3` bindings resolve on Windows from Odin's vendor collection.
- `stb/truetype` font rasterization — portable (the odin vendor tree ships a
  Windows lib).
- Clay UI — `clay-odin` already selects `windows/clay.lib` for `.Windows`
  (`clay-odin/clay.odin:6`).

## WONTFIX / out of scope

The `core:sys/posix` `popen/fgets/pclose` shell-outs to `ffmpeg`/`ffprobe`,
`fc-match`, and the single-quote path quoting / `2>/dev/null` redirection in:

- `media.odin` — `probe_video_size`, `probe_media`
- `proxy.odin` — `proxy_probe_frame_count`, `proxy_transcode`,
  `proxy_valid_cache_hit`
- `font.odin` — `system_monospace_font` (`fc-match`)

These assume a POSIX `/bin/sh`. They cannot be exercised from this Linux repo
(no cross-build), so **leave them as-is**; they are only a concern if/when a
Windows port of the media/proxy path is actually attempted on a Windows machine.

## Changes required for a Windows build

### 1. File picker — `portal.odin` is Linux-only

`portal.odin` foreign-imports `system:glib-2.0` / `system:gio-2.0` and drives
the xdg-desktop-portal FileChooser D-Bus API. This is the only path feeding
`media.open_file_picker` (`media.odin:291`). It will not compile or link on
Windows.

Needed: gate it behind `when ODIN_OS == .Linux` and provide a Windows
`open_file_picker` (e.g. `GetOpenFileNameW` Win32 common dialog, or `IFileOpenDialog`).
Treat `portal.odin` as Linux-only; do not include it in a Windows build.

### 2. Font loading — `font.odin` hardcodes fontconfig

`system_monospace_font` shells out to `fc-match` (fontconfig, absent on
Windows) and falls back to `/usr/share/fonts/.../DejaVuSansMono.ttf`, which
does not exist on Windows (`font.odin:27-44`).

Needed: branch `system_monospace_font` per-OS — on Windows resolve a system
font via the registry (`SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts`, e.g.
`Consola.ttf`) or bundle a monospace TTF and read it directly. `load_font_data`
(`font.odin:14`) then works unchanged.

### 3. ffmpeg bindings — prebuilt libs are NOT in the tree

The `vendor/ffmpeg/*` bindings already have `.Windows` branches pointing at
`../windows_x64/avformat.lib` etc. (e.g. `avformat.odin:9-27`), controlled by
`LINK :: #config(FFMPEG_LINK, "system")`. But **no `windows_x64/` prebuilt
archives exist in the repo** — only the `.odin` bindings. `FFMPEG_LINK=system`
resolves to `avformat.lib` by name, which must be present.

Needed (pick one):
- `-define:FFMPEG_LINK=shared` and place ffmpeg import libs (`avformat.lib`,
  `avcodec.lib`, `avutil.lib`, `swresample.lib`, `swscale.lib`) in the working
  dir / on the search path, shipping the matching ffmpeg DLLs next to `nered.exe`, or
- Drop prebuilt `windows_x64/*.lib` into each `vendor/ffmpeg/<lib>/` (from a
  Windows ffmpeg binary build) and build with `FFMPEG_LINK=static`.

The Linux Nix build sidesteps this via `system:avformat` + `-L`. Windows has no
Nix, so the libs must be sourced manually.

### 4. Build loop / packaging

There is no Windows build script (the `flake.nix` Nix derivation is
Linux-only). On Windows the flow is a manual odin invocation:

```
odin build . -out:nered.exe -define:FFMPEG_LINK=shared
```
plus placing ffmpeg DLLs (and SDL3.dll) beside `nered.exe`. A
`build.bat`/`build.ps1` mirroring the flake's shader compile
(`glslangValidator -V shaders/*.(vert|frag) -> .spv`) + odin build would replace
`buildPhase` from `flake.nix`.

### 5. Shader backend note

`main.odin:407` requests the SDL3 GPU device with `{.SPIRV}`. On Windows with a
Vulkan driver SPIR-V is fine; if targeting D3D12 you would switch to `{.DXIL}`
and recompile shaders. Not required for a Vulkan-backed Windows build.

## Test hooks that already work cross-platform

The probe/headless entry points use only `core:os`/env (`NERED_FRAME_PROBE`,
`NERED_CACHE_PROBE`, `NERED_PROXY_PROBE`, `NERED_RENDER_TEST`, etc.) and do not
touch the POSIX shell-outs — they are the way to sanity-check a Windows build
without a display/ffmpeg-on-PATH.