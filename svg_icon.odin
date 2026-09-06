package main

import "core:c"

// ---------------------------------------------------------------------------
// UI icons. Source of truth is the placeholder .svg files under icons/ (the
// ones that paint skip/jog, the two snap toggles, the duplicate-track button
// and the import button). Parsing and rasterization use the vendored
// nanosvg single-header renderer (vendor/nanosvg/nanosvg.c) - a proven,
// stb-family SVG rasterizer. Each icon renders once at startup to a tiny R8
// alpha texture; drawing reuses the existing text pipeline which samples the
// R channel as alpha and tints it with the draw color uniform.
//
// NOTE: nanosvg mutates its input, so #load'd strings are copied into a
// NUL-terminated scratch buffer before parsing.
// ---------------------------------------------------------------------------

Icon_Id :: enum {
	SkipBack,
	SkipForward,
	SnapClipToPlayhead, // "Clip >"
	SnapPlayheadToClip, // "> Clip"
	Duplicate,
	Import,
}

ICON_COUNT :: 6
ICON_RASTER :: 96 // rasterized texture size per icon (px).

skip_back_svg := #load("icons/skip_back.svg")
skip_forward_svg := #load("icons/skip_forward.svg")
snap_clip_to_playhead_svg := #load("icons/snap_clip_to_playhead.svg")
snap_playhead_to_clip_svg := #load("icons/snap_playhead_to_clip.svg")
duplicate_svg := #load("icons/duplicate.svg")
import_svg := #load("icons/import.svg")

get_icon_svg :: proc(id: Icon_Id) -> []u8 {
	switch id {
	case .SkipBack:
		return skip_back_svg
	case .SkipForward:
		return skip_forward_svg
	case .SnapClipToPlayhead:
		return snap_clip_to_playhead_svg
	case .SnapPlayheadToClip:
		return snap_playhead_to_clip_svg
	case .Duplicate:
		return duplicate_svg
	case .Import:
		return import_svg
	case:
		return nil
	}
}

// foreign bindings to vendor/nanosvg (see vendor/nanosvg/nanosvg.c). The C TU
// is compiled to an object file before the app (flake.nix / workflows clang or
// MSVC `cl`), and linked through this file-path foreign import — the same
// pattern vendor/stb uses for its prebuilt archives.
NANOSVG_LIB :: "vendor/nanosvg/nanosvg.obj" when ODIN_OS == .Windows else "vendor/nanosvg/nanosvg.o"

foreign import nanosvg { NANOSVG_LIB }

foreign nanosvg {
	@(link_name = "nsvgParse")
	nsvg_parse     :: proc(input: cstring, units: cstring, dpi: c.float) -> rawptr ---
	@(link_name = "nsvgCreateRasterizer")
	nsvg_create_rasterizer :: proc() -> rawptr ---
	@(link_name = "nsvgDeleteRasterizer")
	nsvg_delete_rasterizer :: proc(r: rawptr) ---
	@(link_name = "nsvgDelete")
	nsvg_delete    :: proc(image: rawptr) ---
	@(link_name = "nsvgRasterize")
	nsvg_rasterize :: proc(r, image: rawptr, tx, ty, scale: c.float, dst: [^]c.uchar, w, h, stride: c.int) ---
}

// rasterize_icon_svg renders an embedded .svg body to a fresh ICON_RASTER^2
// R8 alpha mask (nanosvg outputs RGBA, non-multiplied alpha taken as the
// coverage mask). Caller owns and must delete the returned slice.
rasterize_icon_svg :: proc(svg: []u8) -> ([]u8, bool) {
	scratch := make([]u8, len(svg) + 1)
	defer delete(scratch)
	copy(scratch, svg)
	image := nsvg_parse(cstring(raw_data(scratch)), cstring("px"), 96.0)
	if image == nil {
		return nil, false
	}
	defer nsvg_delete(image)
	rast := nsvg_create_rasterizer()
	if rast == nil {
		return nil, false
	}
	defer nsvg_delete_rasterizer(rast)

	raster := c.int(ICON_RASTER)
	rgba := make([]u8, ICON_RASTER * ICON_RASTER * 4)
	defer delete(rgba)
	nsvg_rasterize(rast, image, 0, 0, 4.0, raw_data(rgba), raster, raster, raster * 4)

	out := make([]u8, ICON_RASTER * ICON_RASTER)
	for i in 0..<ICON_RASTER * ICON_RASTER {
		out[i] = rgba[i * 4 + 3]
	}
	return out, true
}
