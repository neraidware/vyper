package swscale

import avutil "../avutil"
import "core:c"

LINK :: #config(FFMPEG_LINK, "system")

when ODIN_OS == .Windows {
    when ODIN_ARCH == .amd64 {
        when LINK == "static" {
            foreign import swscale "../windows_x64/swscale_static.lib"
        } else when LINK == "shared" {
            foreign import swscale "../windows_x64/swscale.lib"
        } else {
            foreign import swscale "swscale.lib"
        }
    } else when ODIN_ARCH == .arm64 {
        when LINK == "static" {
            foreign import swscale "../windows_arm64/swscale_static.lib"
        } else when LINK == "shared" {
            foreign import swscale "../windows_arm64/swscale.lib"
        } else {
            foreign import swscale "swscale.lib"
        }
    } else {
        #panic("This architecture is currently not supported on Windows")
    }
} else when ODIN_OS == .Darwin {
    when LINK == "static" {
        when ODIN_ARCH == .amd64 {
            foreign import swscale "../darwin_x64/libswscale.darwin.a"
        } else when ODIN_ARCH == .arm64 {
            foreign import swscale "../darwin_arm64/libswscale.darwin.a"
        } else {
            #panic("This architecture is currently not supported on Darwin")
        }
    } else when LINK == "shared" {
        when ODIN_ARCH == .amd64 {
            foreign import swscale "../darwin_x64/libswscale.dylib"
        } else when ODIN_ARCH == .arm64 {
            foreign import swscale "../darwin_arm64/libswscale.dylib"
        } else {
            #panic("This architecture is currently not supported on Darwin")
        }
    } else {
        foreign import swscale "system:swscale"
    }
} else when ODIN_OS == .Linux {
    when LINK == "static" {
        when ODIN_ARCH == .amd64 {
            foreign import swscale "../linux_x64/libswscale.linux.a"
        } else when ODIN_ARCH == .arm64 {
            foreign import swscale "../linux_arm64/libswscale.linux.a"
        } else {
            #panic("This architecture is currently not supported on Linux")
        }
    } else when LINK == "shared" {
        when ODIN_ARCH == .amd64 {
            @(require) foreign import _avu "../linux_x64/libavutil.so"
            foreign import swscale "../linux_x64/libswscale.so"
        } else when ODIN_ARCH == .arm64 {
            @(require) foreign import _avu "../linux_arm64/libavutil.so"
            foreign import swscale "../linux_arm64/libswscale.so"
        } else {
            #panic("This architecture is currently not supported on Linux")
        }
    } else {
        foreign import swscale "system:swscale"
    }
}

// ---------------------------------------------------------------------------
// libswscale — color conversion and scaling (swscale.h)
// ---------------------------------------------------------------------------

Dither :: enum c.int {
    None = 0,
    Auto,
    Bayer,
    Ed,
    A_Dither,
    X_Dither,
    NB,
}

AlphaBlend :: enum c.int {
    None = 0,
    Uniform,
    Checkerboard,
    NB,
}

Flag :: enum c.int {
    Fast_Bilinear   = 0,
    Bilinear        = 1,
    Bicubic         = 2,
    X               = 3,
    Point           = 4,
    Area            = 5,
    Bicublin        = 6,
    Gauss           = 7,
    Sinc            = 8,
    Lanczos         = 9,
    Spline          = 10,
    Strict          = 11,
    Print_Info      = 12,
    Full_Chr_H_Int  = 13,
    Full_Chr_H_Inp  = 14,
    // deprecated flags:
    Direct_BGR      = 15,
    Accurate_Rnd    = 18,
    Bit_Exact       = 19,
    Unstable        = 20,
    Error_Diffusion = 23,
}
Flags :: distinct bit_set[Flag;c.int]

Intent :: enum c.int {
    Perceptual = 0,
    RelativeColorimetric = 1,
    Saturation = 2,
    AbsoluteColorimetric = 3,
    NB,
}

SWS_SRC_V_CHR_DROP_MASK :: 0x30000
SWS_SRC_V_CHR_DROP_SHIFT :: 16
SWS_PARAM_DEFAULT :: 123456

// Color space identifiers for sws_getCoefficients / setColorspaceDetails.
// ITU624, SMPTE170M, and Default are aliases for ITU601 (all = 5).
ColorSpace :: enum c.int {
    ITU709    = 1,
    FCC       = 4,
    ITU601    = 5,
    SMPTE240M = 7,
    BT2020    = 9,
}
CS_ITU624 :: ColorSpace.ITU601
CS_SMPTE170M :: ColorSpace.ITU601
CS_Default :: ColorSpace.ITU601

Context :: struct {
    av_class:      ^avutil.Class,
    opaque:        rawptr,
    flags:         Flags,
    scaler_params: [2]c.double,
    threads:       c.int,
    dither:        Dither,
    alpha_blend:   AlphaBlend,
    gamma_flag:    c.int,
    src_w:         c.int,
    src_h:         c.int,
    dst_w:         c.int,
    dst_h:         c.int,
    src_format:    c.int,
    dst_format:    c.int,
    src_range:     c.int,
    dst_range:     c.int,
    src_v_chr_pos: c.int,
    src_h_chr_pos: c.int,
    dst_v_chr_pos: c.int,
    dst_h_chr_pos: c.int,
    intent:        c.int,
}

Vector :: struct {
    coeff:  [^]c.double,
    length: c.int,
}

Filter :: struct {
    lumH: ^Vector,
    lumV: ^Vector,
    chrH: ^Vector,
    chrV: ^Vector,
}

@(link_prefix = "swscale_", default_calling_convention = "c")
foreign swscale {
    version :: proc() -> c.uint ---
    configuration :: proc() -> cstring ---
    license :: proc() -> cstring ---
}

@(link_prefix = "sws_", default_calling_convention = "c")
foreign swscale {
    get_class :: proc() -> ^avutil.Class ---

    // --- Format support tests ---
    test_format :: proc(format: avutil.PixelFormat, output: c.int) -> c.int ---
    test_hw_format :: proc(format: avutil.PixelFormat) -> c.int ---
    test_colorspace :: proc(colorspace: avutil.ColorSpace, output: c.int) -> c.int ---
    test_primaries :: proc(primaries: avutil.ColorPrimaries, output: c.int) -> c.int ---
    test_transfer :: proc(trc: avutil.ColorTransferCharacteristic, output: c.int) -> c.int ---
    test_frame :: proc(frame: ^avutil.Frame, output: c.int) -> c.int ---

    // --- Context allocation ---
    alloc_context :: proc() -> ^Context ---
    free_context :: proc(ctx: ^^Context) ---

    // --- Modern frame-based API ---
    frame_setup :: proc(ctx: ^Context, dst: ^avutil.Frame, src: ^avutil.Frame) -> c.int ---
    is_noop :: proc(dst: ^avutil.Frame, src: ^avutil.Frame) -> c.int ---
    scale_frame :: proc(ctx: ^Context, dst: ^avutil.Frame, src: ^avutil.Frame) -> c.int ---

    // --- Slice-based API ---
    frame_start :: proc(ctx: ^Context, dst: ^avutil.Frame, src: ^avutil.Frame) -> c.int ---
    frame_end :: proc(ctx: ^Context) ---
    send_slice :: proc(ctx: ^Context, slice_start: c.uint, slice_height: c.uint) -> c.int ---
    receive_slice :: proc(ctx: ^Context, slice_start: c.uint, slice_height: c.uint) -> c.int ---
    receive_slice_alignment :: proc(ctx: ^Context) -> c.uint ---

    // --- Legacy API ---
    getCoefficients :: proc(colorspace: c.int) -> ^c.int ---
    isSupportedInput :: proc(pix_fmt: avutil.PixelFormat) -> c.int ---
    isSupportedOutput :: proc(pix_fmt: avutil.PixelFormat) -> c.int ---
    isSupportedEndiannessConversion :: proc(pix_fmt: avutil.PixelFormat) -> c.int ---
    init_context :: proc(sws_context: ^Context, srcFilter: ^Filter, dstFilter: ^Filter) -> c.int ---
    freeContext :: proc(swsContext: ^Context) ---
    getContext :: proc(srcW: c.int, srcH: c.int, srcFormat: avutil.PixelFormat, dstW: c.int, dstH: c.int, dstFormat: avutil.PixelFormat, flags: Flags, srcFilter: ^Filter, dstFilter: ^Filter, param: ^c.double) -> ^Context ---
    scale :: proc(ctx: ^Context, srcSlice: [^][^]u8, srcStride: [^]c.int, srcSliceY: c.int, srcSliceH: c.int, dst: [^][^]u8, dstStride: [^]c.int) -> c.int ---
    setColorspaceDetails :: proc(ctx: ^Context, inv_table: [^]c.int, srcRange: c.int, table: [^]c.int, dstRange: c.int, brightness: c.int, contrast: c.int, saturation: c.int) -> c.int ---
    getColorspaceDetails :: proc(ctx: ^Context, inv_table: ^^c.int, srcRange: ^c.int, table: ^^c.int, dstRange: ^c.int, brightness: ^c.int, contrast: ^c.int, saturation: ^c.int) -> c.int ---
    getCachedContext :: proc(ctx: ^Context, srcW: c.int, srcH: c.int, srcFormat: avutil.PixelFormat, dstW: c.int, dstH: c.int, dstFormat: avutil.PixelFormat, flags: Flags, srcFilter: ^Filter, dstFilter: ^Filter, param: ^c.double) -> ^Context ---

    // --- Filter/vector helpers ---
    allocVec :: proc(length: c.int) -> ^Vector ---
    getGaussianVec :: proc(variance: c.double, quality: c.double) -> ^Vector ---
    scaleVec :: proc(a: ^Vector, scalar: c.double) ---
    normalizeVec :: proc(a: ^Vector, height: c.double) ---
    freeVec :: proc(a: ^Vector) ---
    getDefaultFilter :: proc(lumaGBlur: c.float, chromaGBlur: c.float, lumaSharpen: c.float, chromaSharpen: c.float, chromaHShift: c.float, chromaVShift: c.float, verbose: c.int) -> ^Filter ---
    freeFilter :: proc(filter: ^Filter) ---

    // --- Palette conversion ---
    convertPalette8ToPacked32 :: proc(src: [^]u8, dst: [^]u8, num_pixels: c.int, palette: [^]u8) ---
    convertPalette8ToPacked24 :: proc(src: [^]u8, dst: [^]u8, num_pixels: c.int, palette: [^]u8) ---
}
