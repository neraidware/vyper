package swresample

import avutil "../avutil"
import "core:c"

LINK :: #config(FFMPEG_LINK, "system")

when ODIN_OS == .Windows {
    when ODIN_ARCH == .amd64 {
        when LINK == "static" {
            foreign import swresample "../windows_x64/swresample_static.lib"
        } else when LINK == "shared" {
            foreign import swresample "../windows_x64/swresample.lib"
        } else {
            foreign import swresample "swresample.lib"
        }
    } else when ODIN_ARCH == .arm64 {
        when LINK == "static" {
            foreign import swresample "../windows_arm64/swresample_static.lib"
        } else when LINK == "shared" {
            foreign import swresample "../windows_arm64/swresample.lib"
        } else {
            foreign import swresample "swresample.lib"
        }
    } else {
        #panic("This architecture is currently not supported on Windows")
    }
} else when ODIN_OS == .Darwin {
    when LINK == "static" {
        when ODIN_ARCH == .amd64 {
            foreign import swresample "../darwin_x64/libswresample.darwin.a"
        } else when ODIN_ARCH == .arm64 {
            foreign import swresample "../darwin_arm64/libswresample.darwin.a"
        } else {
            #panic("This architecture is currently not supported on Darwin")
        }
    } else when LINK == "shared" {
        when ODIN_ARCH == .amd64 {
            foreign import swresample "../darwin_x64/libswresample.dylib"
        } else when ODIN_ARCH == .arm64 {
            foreign import swresample "../darwin_arm64/libswresample.dylib"
        } else {
            #panic("This architecture is currently not supported on Darwin")
        }
    } else {
        foreign import swresample "system:swresample"
    }
} else when ODIN_OS == .Linux {
    when LINK == "static" {
        when ODIN_ARCH == .amd64 {
            foreign import swresample "../linux_x64/libswresample.linux.a"
        } else when ODIN_ARCH == .arm64 {
            foreign import swresample "../linux_arm64/libswresample.linux.a"
        } else {
            #panic("This architecture is currently not supported on Linux")
        }
    } else when LINK == "shared" {
        when ODIN_ARCH == .amd64 {
            @(require) foreign import _avu "../linux_x64/libavutil.so"
            foreign import swresample "../linux_x64/libswresample.so"
        } else when ODIN_ARCH == .arm64 {
            @(require) foreign import _avu "../linux_arm64/libavutil.so"
            foreign import swresample "../linux_arm64/libswresample.so"
        } else {
            #panic("This architecture is currently not supported on Linux")
        }
    } else {
        foreign import swresample "system:swresample"
    }
}

// ---------------------------------------------------------------------------
// libswresample — audio resampling and conversion (swresample.h)
// ---------------------------------------------------------------------------

ResampleFlag :: enum c.int {
    Resample = 0,
}
ResampleFlags :: distinct bit_set[ResampleFlag;c.int]

DitherType :: enum c.int {
    None = 0,
    Rectangular,
    Triangular,
    TriangularHiPass,
    NsRect,
    NsTri,
    NsTriHiPass,
    NsLipshitz,
    NsF_Weighted,
    NsModifiedEWeighted,
    NsImprovedEWeighted,
    NsGaussian,
    NsBHighShelf,
    NsNb,
    // Aliases
    TriangularNoiseShaped = NsTri,
    NB = NsNb,
}

Engine :: enum c.int {
    Swr = 0,
    Soxr = 1,
    NB,
}

FilterType :: enum c.int {
    Cubic,
    BlackmanNuttall,
    Kaiser,
}

// Context is fully opaque — only used by pointer.
Context :: struct {}

@(link_prefix = "swresample_", default_calling_convention = "c")
foreign swresample {
    version :: proc() -> c.uint ---
    configuration :: proc() -> cstring ---
    license :: proc() -> cstring ---
}

@(link_prefix = "swr_", default_calling_convention = "c")
foreign swresample {
    get_class :: proc() -> ^avutil.Class ---

    // --- Allocation ---
    alloc :: proc() -> ^Context ---
    init :: proc(s: ^Context) -> c.int ---
    is_initialized :: proc(s: ^Context) -> c.int ---

    // Sets all options from channel layouts, sample rate, and format and allocates.
    alloc_set_opts2 :: proc(ps: ^^Context, out_ch_layout: ^avutil.ChannelLayout, out_sample_fmt: avutil.SampleFormat, out_sample_rate: c.int, in_ch_layout: ^avutil.ChannelLayout, in_sample_fmt: avutil.SampleFormat, in_sample_rate: c.int, log_offset: c.int, log_ctx: rawptr) -> c.int ---

    free :: proc(s: ^^Context) ---
    close :: proc(s: ^Context) ---

    // --- Conversion ---
    convert :: proc(s: ^Context, out: [^][^]u8, out_count: c.int, in_: [^][^]u8, in_count: c.int) -> c.int ---

    next_pts :: proc(s: ^Context, pts: c.int64_t) -> c.int64_t ---

    // --- Compensation ---
    set_compensation :: proc(s: ^Context, sample_delta: c.int, compensation_distance: c.int) -> c.int ---

    // --- Channel mapping ---
    set_channel_mapping :: proc(s: ^Context, channel_map: [^]c.int) -> c.int ---

    // --- Matrix ---
    build_matrix2 :: proc(in_layout: ^avutil.ChannelLayout, out_layout: ^avutil.ChannelLayout, center_mix_level: c.double, surround_mix_level: c.double, lfe_mix_level: c.double, maxval: c.double, rematrix_volume: c.double, mat: [^]c.double, stride: c.int, matrix_encoding: avutil.MatrixEncoding, log_ctx: rawptr) -> c.int ---

    set_matrix :: proc(s: ^Context, mat: [^]c.double, stride: c.int) -> c.int ---

    // --- Drop / inject ---
    drop_output :: proc(s: ^Context, count: c.int) -> c.int ---
    inject_silence :: proc(s: ^Context, count: c.int) -> c.int ---

    // --- Delay / output sample count ---
    get_delay :: proc(s: ^Context, base: c.int64_t) -> c.int64_t ---
    get_out_samples :: proc(s: ^Context, in_samples: c.int) -> c.int ---

    // --- Frame-based API ---
    convert_frame :: proc(swr: ^Context, output: ^avutil.Frame, input: ^avutil.Frame) -> c.int ---
    config_frame :: proc(swr: ^Context, out: ^avutil.Frame, in_: ^avutil.Frame) -> c.int ---
}
