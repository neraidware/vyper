package avfilter

import avutil "../avutil"
import "core:c"

LINK :: #config(FFMPEG_LINK, "system")

when ODIN_OS == .Windows {
    when ODIN_ARCH == .amd64 {
        when LINK == "static" {
            foreign import avfilter "../windows_x64/avfilter_static.lib"
        } else when LINK == "shared" {
            foreign import avfilter "../windows_x64/avfilter.lib"
        } else {
            foreign import avfilter "avfilter.lib"
        }
    } else when ODIN_ARCH == .arm64 {
        when LINK == "static" {
            foreign import avfilter "../windows_arm64/avfilter_static.lib"
        } else when LINK == "shared" {
            foreign import avfilter "../windows_arm64/avfilter.lib"
        } else {
            foreign import avfilter "avfilter.lib"
        }
    } else {
        #panic("This architecture is currently not supported on Windows")
    }
} else when ODIN_OS == .Darwin {
    when LINK == "static" {
        when ODIN_ARCH == .amd64 {
            // Extra system frameworks/libs required by static libavfilter.
            @(require) foreign import "system:Foundation.framework"
            @(require) foreign import "system:AudioToolbox.framework"
            @(require) foreign import "system:CoreAudio.framework"
            @(require) foreign import "system:OpenGL.framework"
            @(require) foreign import "system:Metal.framework"
            @(require) foreign import "system:VideoToolbox.framework"
            @(require) foreign import "system:CoreImage.framework"
            @(require) foreign import "system:AppKit.framework"
            @(require) foreign import "system:CoreFoundation.framework"
            @(require) foreign import "system:CoreMedia.framework"
            @(require) foreign import "system:CoreVideo.framework"
            @(require) foreign import "system:CoreServices.framework"
            @(require) foreign import "system:Security.framework"
            @(require) foreign import "system:bz2"
            @(require) foreign import "system:z"
            // Pull static transitive deps explicitly for stable link order.
            @(require) foreign import _avf "../darwin_x64/libavformat.darwin.a"
            @(require) foreign import _avc "../darwin_x64/libavcodec.darwin.a"
            @(require) foreign import _avu "../darwin_x64/libavutil.darwin.a"
            @(require) foreign import _swr "../darwin_x64/libswresample.darwin.a"
            @(require) foreign import _sws "../darwin_x64/libswscale.darwin.a"
            foreign import avfilter "../darwin_x64/libavfilter.darwin.a"
        } else when ODIN_ARCH == .arm64 {
            // Extra system frameworks/libs required by static libavfilter.
            @(require) foreign import "system:Foundation.framework"
            @(require) foreign import "system:AudioToolbox.framework"
            @(require) foreign import "system:CoreAudio.framework"
            @(require) foreign import "system:OpenGL.framework"
            @(require) foreign import "system:Metal.framework"
            @(require) foreign import "system:VideoToolbox.framework"
            @(require) foreign import "system:CoreImage.framework"
            @(require) foreign import "system:AppKit.framework"
            @(require) foreign import "system:CoreFoundation.framework"
            @(require) foreign import "system:CoreMedia.framework"
            @(require) foreign import "system:CoreVideo.framework"
            @(require) foreign import "system:CoreServices.framework"
            @(require) foreign import "system:Security.framework"
            @(require) foreign import "system:bz2"
            @(require) foreign import "system:z"
            // Pull static transitive deps explicitly for stable link order.
            @(require) foreign import _avf "../darwin_arm64/libavformat.darwin.a"
            @(require) foreign import _avc "../darwin_arm64/libavcodec.darwin.a"
            @(require) foreign import _avu "../darwin_arm64/libavutil.darwin.a"
            @(require) foreign import _swr "../darwin_arm64/libswresample.darwin.a"
            @(require) foreign import _sws "../darwin_arm64/libswscale.darwin.a"
            foreign import avfilter "../darwin_arm64/libavfilter.darwin.a"
        } else {
            #panic("This architecture is currently not supported on Darwin")
        }
    } else when LINK == "shared" {
        when ODIN_ARCH == .amd64 {
            foreign import avfilter "../darwin_x64/libavfilter.dylib"
        } else when ODIN_ARCH == .arm64 {
            foreign import avfilter "../darwin_arm64/libavfilter.dylib"
        } else {
            #panic("This architecture is currently not supported on Darwin")
        }
    } else {
        foreign import avfilter "system:avfilter"
    }
} else when ODIN_OS == .Linux {
    when LINK == "static" {
        when ODIN_ARCH == .amd64 {
            foreign import avfilter "../linux_x64/libavfilter.linux.a"
        } else when ODIN_ARCH == .arm64 {
            foreign import avfilter "../linux_arm64/libavfilter.linux.a"
        } else {
            #panic("This architecture is currently not supported on Linux")
        }
    } else when LINK == "shared" {
        when ODIN_ARCH == .amd64 {
            @(require) foreign import _sws "../linux_x64/libswscale.so"
            @(require) foreign import _avf "../linux_x64/libavformat.so"
            @(require) foreign import _avc "../linux_x64/libavcodec.so"
            @(require) foreign import _swr "../linux_x64/libswresample.so"
            @(require) foreign import _avu "../linux_x64/libavutil.so"
            foreign import avfilter "../linux_x64/libavfilter.so"
        } else when ODIN_ARCH == .arm64 {
            @(require) foreign import _sws "../linux_arm64/libswscale.so"
            @(require) foreign import _avf "../linux_arm64/libavformat.so"
            @(require) foreign import _avc "../linux_arm64/libavcodec.so"
            @(require) foreign import _swr "../linux_arm64/libswresample.so"
            @(require) foreign import _avu "../linux_arm64/libavutil.so"
            foreign import avfilter "../linux_arm64/libavfilter.so"
        } else {
            #panic("This architecture is currently not supported on Linux")
        }
    } else {
        foreign import avfilter "system:avfilter"
    }
}

// ---------------------------------------------------------------------------
// libavfilter — filter graph API (avfilter.h, buffersink.h, buffersrc.h)
// ---------------------------------------------------------------------------

// Filter flags
FilterFlag :: enum c.int {
    Dynamic_Inputs            = 0,
    Dynamic_Outputs           = 1,
    Slice_Threads             = 2,
    Metadata_Only             = 4,
    HW_Device                 = 5,
    Support_Timeline_Generic  = 16,
    Support_Timeline_Internal = 17,
}
FilterFlags :: distinct bit_set[FilterFlag;c.int]
FILTER_FLAG_SUPPORT_TIMELINE :: FilterFlags{.Support_Timeline_Generic, .Support_Timeline_Internal}

FilterPad :: struct {} // opaque; accessed only through avfilter_pad_* functions

Filter :: struct {
    name:        cstring,
    description: cstring,
    inputs:      ^FilterPad,
    outputs:     ^FilterPad,
    priv_class:  ^avutil.Class,
    flags:       FilterFlags,
    // private fields follow — do not access
}

FilterContext :: struct {
    av_class:    ^avutil.Class,
    filter:      ^Filter,
    name:        cstring,
    input_pads:  ^FilterPad,
    inputs:      [^]^FilterLink,
    nb_inputs:   c.uint,
    output_pads: ^FilterPad,
    outputs:     [^]^FilterLink,
    nb_outputs:  c.uint,
    priv:        rawptr,
    graph:       ^FilterGraph,
    thread_type: c.int,
    // private fields follow — do not access
}

FilterLink :: struct {
    src:                 ^FilterContext,
    srcpad:              ^FilterPad,
    dst:                 ^FilterContext,
    dstpad:              ^FilterPad,
    type:                avutil.MediaType,
    w:                   c.int,
    h:                   c.int,
    sample_aspect_ratio: avutil.Rational,
    ch_layout:           avutil.ChannelLayout,
    sample_rate:         c.int,
    format:              c.int,
    time_base:           avutil.Rational,
    // private fields follow — do not access
}

FilterGraph :: struct {
    av_class:       ^avutil.Class,
    filters:        [^]^FilterContext,
    nb_filters:     c.uint,
    scale_sws_opts: cstring,
    // private fields follow — do not access
}

FilterInOut :: struct {
    name:       cstring,
    filter_ctx: ^FilterContext,
    pad_idx:    c.int,
    next:       ^FilterInOut,
}

FilterPadParams :: struct {
    label: cstring,
}

FilterParams :: struct {
    filter:        ^FilterContext,
    filter_name:   cstring,
    instance_name: cstring,
    opts:          ^avutil.Dictionary,
    inputs:        [^]^FilterPadParams,
    nb_inputs:     c.uint,
    outputs:       [^]^FilterPadParams,
    nb_outputs:    c.uint,
}

FilterChain :: struct {
    filters:    [^]^FilterParams,
    nb_filters: c.size_t,
}

FilterGraphSegment :: struct {
    graph:          ^FilterGraph,
    chains:         [^]^FilterChain,
    nb_chains:      c.size_t,
    scale_sws_opts: cstring,
}

AVFILTER_AUTO_CONVERT_ALL :: 0
AVFILTER_AUTO_CONVERT_NONE :: -1

// ---------------------------------------------------------------------------
// buffersink.h
// ---------------------------------------------------------------------------

BufferSinkFlag :: enum c.int {
    Peek       = 0,
    No_Request = 1,
}
BufferSinkFlags :: distinct bit_set[BufferSinkFlag;c.int]

// ---------------------------------------------------------------------------
// buffersrc.h
// ---------------------------------------------------------------------------

BufferSrcFlag :: enum c.int {
    No_Check_Format = 0,
    Push            = 2,
    Keep_Ref        = 3,
}
BufferSrcFlags :: distinct bit_set[BufferSrcFlag;c.int]

BufferSrcParameters :: struct {
    format:              c.int,
    time_base:           avutil.Rational,
    width:               c.int,
    height:              c.int,
    sample_aspect_ratio: avutil.Rational,
    frame_rate:          avutil.Rational,
    hw_frames_ctx:       ^avutil.BufferRef,
    sample_rate:         c.int,
    ch_layout:           avutil.ChannelLayout,
    color_space:         avutil.ColorSpace,
    color_range:         avutil.ColorRange,
    side_data:           [^]^avutil.FrameSideData,
    nb_side_data:        c.int,
    alpha_mode:          avutil.AlphaMode,
}

// ---------------------------------------------------------------------------
// Foreign block — libavfilter
// ---------------------------------------------------------------------------

@(link_prefix = "avfilter_", default_calling_convention = "c")
foreign avfilter {
    // --- Version / configuration ---
    version :: proc() -> c.uint ---
    configuration :: proc() -> cstring ---
    license :: proc() -> cstring ---

    // --- Pad introspection ---
    pad_count :: proc(pads: ^FilterPad) -> c.int ---
    pad_get_name :: proc(pads: ^FilterPad, pad_idx: c.int) -> cstring ---
    pad_get_type :: proc(pads: ^FilterPad, pad_idx: c.int) -> avutil.MediaType ---

    // --- Linking ---
    link :: proc(src: ^FilterContext, srcpad: c.uint, dst: ^FilterContext, dstpad: c.uint) -> c.int ---
    link_free :: proc(link: ^^FilterLink) ---

    // --- Filter commands ---
    process_command :: proc(filter: ^FilterContext, cmd: cstring, arg: cstring, res: cstring, res_len: c.int, flags: c.int) -> c.int ---
    get_by_name :: proc(name: cstring) -> ^Filter ---
    get_class :: proc() -> ^avutil.Class ---

    // --- Filter context init / free ---
    init_str :: proc(ctx: ^FilterContext, args: cstring) -> c.int ---
    init_dict :: proc(ctx: ^FilterContext, options: ^^avutil.Dictionary) -> c.int ---
    free :: proc(filter: ^FilterContext) ---

    // --- Filter insertion ---
    insert_filter :: proc(link: ^FilterLink, filt: ^FilterContext, filt_srcpad_idx: c.uint, filt_dstpad_idx: c.uint) -> c.int ---

    // --- Graph ---
    graph_alloc :: proc() -> ^FilterGraph ---
    graph_alloc_filter :: proc(graph: ^FilterGraph, filter: ^Filter, name: cstring) -> ^FilterContext ---
    graph_get_filter :: proc(graph: ^FilterGraph, name: cstring) -> ^FilterContext ---
    graph_create_filter :: proc(filt_ctx: ^^FilterContext, filt: ^Filter, name: cstring, args: cstring, opaque: rawptr, graph_ctx: ^FilterGraph) -> c.int ---
    graph_set_auto_convert :: proc(graph: ^FilterGraph, flags: c.uint) ---
    graph_config :: proc(graphctx: ^FilterGraph, log_ctx: rawptr) -> c.int ---
    graph_free :: proc(graph: ^^FilterGraph) ---

    // --- In/Out ---
    inout_alloc :: proc() -> ^FilterInOut ---
    inout_free :: proc(inout: ^^FilterInOut) ---

    // --- Graph parsing ---
    graph_parse :: proc(graph: ^FilterGraph, filters: cstring, inputs: ^FilterInOut, outputs: ^FilterInOut, log_ctx: rawptr) -> c.int ---
    graph_parse_ptr :: proc(graph: ^FilterGraph, filters: cstring, inputs: ^^FilterInOut, outputs: ^^FilterInOut, log_ctx: rawptr) -> c.int ---
    graph_parse2 :: proc(graph: ^FilterGraph, filters: cstring, inputs: ^^FilterInOut, outputs: ^^FilterInOut) -> c.int ---

    // --- Graph segment API ---
    graph_segment_parse :: proc(graph: ^FilterGraph, graph_str: cstring, flags: c.int, seg: ^^FilterGraphSegment) -> c.int ---
    graph_segment_create_filters :: proc(seg: ^FilterGraphSegment, flags: c.int) -> c.int ---
    graph_segment_apply_opts :: proc(seg: ^FilterGraphSegment, flags: c.int) -> c.int ---
    graph_segment_init :: proc(seg: ^FilterGraphSegment, flags: c.int) -> c.int ---
    graph_segment_link :: proc(seg: ^FilterGraphSegment, flags: c.int, inputs: ^^FilterInOut, outputs: ^^FilterInOut) -> c.int ---
    graph_segment_apply :: proc(seg: ^FilterGraphSegment, flags: c.int, inputs: ^^FilterInOut, outputs: ^^FilterInOut) -> c.int ---
    graph_segment_free :: proc(seg: ^^FilterGraphSegment) ---
}

@(link_prefix = "av_buffersink_", default_calling_convention = "c")
foreign avfilter {
    // --- buffersink (avfilter) ---
    get_frame_flags :: proc(ctx: ^FilterContext, frame: ^avutil.Frame, flags: BufferSinkFlags) -> c.int ---
    set_frame_size :: proc(ctx: ^FilterContext, frame_size: c.uint) ---
    get_type :: proc(ctx: ^FilterContext) -> avutil.MediaType ---
    get_time_base :: proc(ctx: ^FilterContext) -> avutil.Rational ---
    get_format :: proc(ctx: ^FilterContext) -> c.int ---
    get_frame_rate :: proc(ctx: ^FilterContext) -> avutil.Rational ---
    get_w :: proc(ctx: ^FilterContext) -> c.int ---
    get_h :: proc(ctx: ^FilterContext) -> c.int ---
    get_sample_aspect_ratio :: proc(ctx: ^FilterContext) -> avutil.Rational ---
    get_colorspace :: proc(ctx: ^FilterContext) -> avutil.ColorSpace ---
    get_color_range :: proc(ctx: ^FilterContext) -> avutil.ColorRange ---
    get_alpha_mode :: proc(ctx: ^FilterContext) -> avutil.AlphaMode ---
    get_channels :: proc(ctx: ^FilterContext) -> c.int ---
    get_ch_layout :: proc(ctx: ^FilterContext, ch_layout: ^avutil.ChannelLayout) -> c.int ---
    get_sample_rate :: proc(ctx: ^FilterContext) -> c.int ---
    get_hw_frames_ctx :: proc(ctx: ^FilterContext) -> ^avutil.BufferRef ---
    get_side_data :: proc(ctx: ^FilterContext, nb_side_data: ^c.int) -> [^]^avutil.FrameSideData ---
    get_frame :: proc(ctx: ^FilterContext, frame: ^avutil.Frame) -> c.int ---
    get_samples :: proc(ctx: ^FilterContext, frame: ^avutil.Frame, nb_samples: c.int) -> c.int ---
}

@(link_prefix = "av_buffersrc_", default_calling_convention = "c")
foreign avfilter {
    // --- buffersrc (avfilter) ---
    get_nb_failed_requests :: proc(buffer_src: ^FilterContext) -> c.uint ---
    parameters_alloc :: proc() -> ^BufferSrcParameters ---
    parameters_set :: proc(ctx: ^FilterContext, param: ^BufferSrcParameters) -> c.int ---
    write_frame :: proc(ctx: ^FilterContext, frame: ^avutil.Frame) -> c.int ---
    add_frame :: proc(ctx: ^FilterContext, frame: ^avutil.Frame) -> c.int ---
    add_frame_flags :: proc(buffer_src: ^FilterContext, frame: ^avutil.Frame, flags: BufferSrcFlags) -> c.int ---
    close :: proc(ctx: ^FilterContext, pts: c.int64_t, flags: BufferSrcFlags) -> c.int ---
    get_status :: proc(ctx: ^FilterContext) -> c.int ---
}

@(link_prefix = "av_", default_calling_convention = "c")
foreign avfilter {
    // --- Filter lookup / iteration ---
    filter_iterate :: proc(opaque: ^rawptr) -> ^Filter ---
}
