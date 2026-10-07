package avformat

import avcodec "../avcodec"
import avutil "../avutil"
import "core:c"

LINK :: #config(FFMPEG_LINK, "system")

when ODIN_OS == .Windows {
    when ODIN_ARCH == .amd64 {
        when LINK == "static" {
            foreign import avformat "../windows_x64/avformat_static.lib"
        } else when LINK == "shared" {
            foreign import avformat "../windows_x64/avformat.lib"
        } else {
            foreign import avformat "avformat.lib"
        }
    } else when ODIN_ARCH == .arm64 {
        when LINK == "static" {
            foreign import avformat "../windows_arm64/avformat_static.lib"
        } else when LINK == "shared" {
            foreign import avformat "../windows_arm64/avformat.lib"
        } else {
            foreign import avformat "avformat.lib"
        }
    } else {
        #panic("This architecture is currently not supported on Windows")
    }
} else when ODIN_OS == .Darwin {
    when LINK == "static" {
        when ODIN_ARCH == .amd64 {
            // Extra system framework/libs and static FFmpeg deps required by
            // static libavformat on macOS.
            @(require) foreign import "system:CoreFoundation.framework"
            @(require) foreign import "system:Security.framework"
            @(require) foreign import "system:bz2"
            @(require) foreign import "system:z"
            // Static libavformat depends on avcodec/avutil and often pulls
            // swresample/swscale from codec paths.
            @(require) foreign import _avc "../darwin_x64/libavcodec.darwin.a"
            @(require) foreign import _avu "../darwin_x64/libavutil.darwin.a"
            @(require) foreign import _swr "../darwin_x64/libswresample.darwin.a"
            @(require) foreign import _sws "../darwin_x64/libswscale.darwin.a"
            foreign import avformat "../darwin_x64/libavformat.darwin.a"
        } else when ODIN_ARCH == .arm64 {
            // Extra system framework/libs and static FFmpeg deps required by
            // static libavformat on macOS.
            @(require) foreign import "system:CoreFoundation.framework"
            @(require) foreign import "system:Security.framework"
            @(require) foreign import "system:bz2"
            @(require) foreign import "system:z"
            // Static libavformat depends on avcodec/avutil and often pulls
            // swresample/swscale from codec paths.
            @(require) foreign import _avc "../darwin_arm64/libavcodec.darwin.a"
            @(require) foreign import _avu "../darwin_arm64/libavutil.darwin.a"
            @(require) foreign import _swr "../darwin_arm64/libswresample.darwin.a"
            @(require) foreign import _sws "../darwin_arm64/libswscale.darwin.a"
            foreign import avformat "../darwin_arm64/libavformat.darwin.a"
        } else {
            #panic("This architecture is currently not supported on Darwin")
        }
    } else when LINK == "shared" {
        when ODIN_ARCH == .amd64 {
            foreign import avformat "../darwin_x64/libavformat.dylib"
        } else when ODIN_ARCH == .arm64 {
            foreign import avformat "../darwin_arm64/libavformat.dylib"
        } else {
            #panic("This architecture is currently not supported on Darwin")
        }
    } else {
        foreign import avformat "system:avformat"
    }
} else when ODIN_OS == .Linux {
    when LINK == "static" {
        when ODIN_ARCH == .amd64 {
            foreign import avformat "../linux_x64/libavformat.linux.a"
        } else when ODIN_ARCH == .arm64 {
            foreign import avformat "../linux_arm64/libavformat.linux.a"
        } else {
            #panic("This architecture is currently not supported on Linux")
        }
    } else when LINK == "shared" {
        when ODIN_ARCH == .amd64 {
            @(require) foreign import _avc "../linux_x64/libavcodec.so"
            @(require) foreign import _avu "../linux_x64/libavutil.so"
            foreign import avformat "../linux_x64/libavformat.so"
        } else when ODIN_ARCH == .arm64 {
            @(require) foreign import _avc "../linux_arm64/libavcodec.so"
            @(require) foreign import _avu "../linux_arm64/libavutil.so"
            foreign import avformat "../linux_arm64/libavformat.so"
        } else {
            #panic("This architecture is currently not supported on Linux")
        }
    } else {
        foreign import avformat "system:avformat"
    }
}

// ---------------------------------------------------------------------------
// AVIO — buffered I/O layer (avio.h) — part of libavformat
// ---------------------------------------------------------------------------

SeekableFlag :: enum c.int {
    Normal = 0,
    Time   = 1,
}
SeekableFlags :: distinct bit_set[SeekableFlag;c.int]

IOInterruptCB :: struct {
    callback: #type proc "c" (opaque: rawptr) -> c.int,
    opaque:   rawptr,
}

IODirEntryType :: enum c.int {
    Unknown = 0,
    BlockDevice,
    CharacterDevice,
    Directory,
    NamedPipe,
    SymbolicLink,
    Socket,
    File,
    Server,
    Share,
    Workgroup,
}

IODirEntry :: struct {
    name:                    cstring,
    type:                    c.int,
    utf8:                    c.int,
    size:                    c.int64_t,
    modification_timestamp:  c.int64_t,
    access_timestamp:        c.int64_t,
    status_change_timestamp: c.int64_t,
    user_id:                 c.int64_t,
    group_id:                c.int64_t,
    filemode:                c.int64_t,
}

IODirContext :: struct {} // opaque

IODataMarkerType :: enum c.int {
    Header,
    SyncPoint,
    BoundaryPoint,
    Unknown,
    Trailer,
    FlushPoint,
}

IOContext :: struct {
    av_class:              ^avutil.Class,
    buffer:                [^]u8,
    buffer_size:           c.int,
    buf_ptr:               [^]u8,
    buf_end:               [^]u8,
    opaque:                rawptr,
    read_packet:           #type proc "c" (opaque: rawptr, buf: [^]u8, buf_size: c.int) -> c.int,
    write_packet:          #type proc "c" (opaque: rawptr, buf: [^]u8, buf_size: c.int) -> c.int,
    seek:                  #type proc "c" (opaque: rawptr, offset: c.int64_t, whence: c.int) -> c.int64_t,
    pos:                   c.int64_t,
    eof_reached:           c.int,
    error:                 c.int,
    write_flag:            c.int,
    max_packet_size:       c.int,
    min_packet_size:       c.int,
    checksum:              c.ulong,
    checksum_ptr:          [^]u8,
    update_checksum:       #type proc "c" (checksum: c.ulong, buf: [^]u8, size: c.uint) -> c.ulong,
    read_pause:            #type proc "c" (opaque: rawptr, pause: c.int) -> c.int,
    read_seek:             #type proc "c" (
        opaque: rawptr,
        stream_index: c.int,
        timestamp: c.int64_t,
        flags: c.int,
    ) -> c.int64_t,
    seekable:              SeekableFlags,
    direct:                c.int,
    protocol_whitelist:    cstring,
    protocol_blacklist:    cstring,
    write_data_type:       #type proc "c" (
        opaque: rawptr,
        buf: [^]u8,
        buf_size: c.int,
        type: IODataMarkerType,
        time: c.int64_t,
    ) -> c.int,
    ignore_boundary_point: c.int,
    buf_ptr_max:           [^]u8,
    bytes_read:            c.int64_t,
    bytes_written:         c.int64_t,
}

AVSEEK_SIZE :: 0x10000
AVSEEK_FORCE :: 0x20000

IOFlag :: enum c.int {
    Read     = 0,
    Write    = 1,
    Nonblock = 3,
    Direct   = 15,
}
IOFlags :: distinct bit_set[IOFlag;c.int]
IO_FLAG_READ_WRITE :: IOFlags{.Read, .Write}

// ---------------------------------------------------------------------------
// libavformat — core types (avformat.h)
// ---------------------------------------------------------------------------

AVPROBE_SCORE_RETRY :: 25
AVPROBE_SCORE_STREAM_RETRY :: 26
AVPROBE_SCORE_EXTENSION :: 50
AVPROBE_SCORE_MIME :: 75
AVPROBE_SCORE_MAX :: 100

ProbeData :: struct {
    filename:  cstring,
    buf:       [^]u8,
    buf_size:  c.int,
    mime_type: cstring,
}

// Output format flags (OutputFormat.flags)
OutputFmtFlag :: enum c.int {
    No_File       = 0,
    Need_Number   = 1,
    Global_Header = 6,
    No_Timestamps = 7,
    Generic_Index = 8,
    TS_Disc       = 9,
    Variable_FPS  = 10,
    No_Dimensions = 11,
    No_Streams    = 12,
    No_Bin_Search = 13,
    No_Gen_Search = 14,
    No_Byte_Seek  = 15,
    Allow_Flush   = 16,
    TS_Nonstrict  = 17,
    TS_Negative   = 18,
    Seek_To_PTS   = 26,
}
OutputFmtFlags :: distinct bit_set[OutputFmtFlag;c.int]

CodecTag :: struct {} // opaque internal type

OutputFormat :: struct {
    name:           cstring,
    long_name:      cstring,
    mime_type:      cstring,
    extensions:     cstring,
    audio_codec:    avcodec.CodecID,
    video_codec:    avcodec.CodecID,
    subtitle_codec: avcodec.CodecID,
    flags:          OutputFmtFlags,
    codec_tag:      [^]^CodecTag,
    priv_class:     ^avutil.Class,
}

// Input format flags (InputFormat.flags)
InputFmtFlag :: enum c.int {
    No_File       = 0,
    Need_Number   = 1,
    Show_IDs      = 3,
    Generic_Index = 8,
    TS_Disc       = 9,
    No_Bin_Search = 13,
    No_Gen_Search = 14,
    No_Byte_Seek  = 15,
    Seek_To_PTS   = 26,
}
InputFmtFlags :: distinct bit_set[InputFmtFlag;c.int]

InputFormat :: struct {
    name:       cstring,
    long_name:  cstring,
    flags:      InputFmtFlags,
    extensions: cstring,
    codec_tag:  [^]^CodecTag,
    priv_class: ^avutil.Class,
    mime_type:  cstring,
}

StreamParseType :: enum c.int {
    None,
    Full,
    Headers,
    Timestamps,
    Full_Once,
    Full_RAW = 0x57415230,
}

IndexEntry :: struct {
    pos:          c.int64_t,
    timestamp:    c.int64_t,
    // bits 0-1 = flags (AVINDEX_KEYFRAME=1, AVINDEX_DISCARD_FRAME=2),
    // bits 2-31 = size
    flags_size:   c.int,
    min_distance: c.int,
}

AVINDEX_KEYFRAME :: 0x0001
AVINDEX_DISCARD_FRAME :: 0x0002

// AV_DISPOSITION_* flags (Stream.disposition)
DispositionFlag :: enum c.int {
    Default          = 0,
    Dub              = 1,
    Original         = 2,
    Comment          = 3,
    Lyrics           = 4,
    Karaoke          = 5,
    Forced           = 6,
    Hearing_Impaired = 7,
    Visual_Impaired  = 8,
    Clean_Effects    = 9,
    Attached_Pic     = 10,
    Timed_Thumbnails = 11,
    Non_Diegetic     = 12,
    Captions         = 16,
    Descriptions     = 17,
    Metadata         = 18,
    Dependent        = 19,
    Still_Image      = 20,
    Multilayer       = 21,
}
DispositionFlags :: distinct bit_set[DispositionFlag;c.int]

StreamEventFlag :: enum c.int {
    Metadata_Updated = 0,
    New_Packets      = 1,
}
StreamEventFlags :: distinct bit_set[StreamEventFlag;c.int]

Stream :: struct {
    av_class:            ^avutil.Class,
    index:               c.int,
    id:                  c.int,
    codecpar:            ^avcodec.CodecParameters,
    priv_data:           rawptr,
    time_base:           avutil.Rational,
    start_time:          c.int64_t,
    duration:            c.int64_t,
    nb_frames:           c.int64_t,
    disposition:         DispositionFlags,
    discard:             avcodec.Discard,
    sample_aspect_ratio: avutil.Rational,
    metadata:            ^avutil.Dictionary,
    avg_frame_rate:      avutil.Rational,
    attached_pic:        avcodec.Packet,
    event_flags:         StreamEventFlags,
    r_frame_rate:        avutil.Rational,
    pts_wrap_bits:       c.int,
}

StreamGroupTileGrid_Offset :: struct {
    idx:        c.uint,
    horizontal: c.int,
    vertical:   c.int,
}

StreamGroupTileGrid :: struct {
    av_class:           ^avutil.Class,
    nb_tiles:           c.uint,
    coded_width:        c.int,
    coded_height:       c.int,
    offsets:            ^StreamGroupTileGrid_Offset,
    background:         [4]u8,
    horizontal_offset:  c.int,
    vertical_offset:    c.int,
    width:              c.int,
    height:             c.int,
    coded_side_data:    ^avcodec.PacketSideData,
    nb_coded_side_data: c.int,
}

StreamGroupLCEVC :: struct {
    av_class:    ^avutil.Class,
    lcevc_index: c.uint,
    width:       c.int,
    height:      c.int,
}

StreamGroupParamsType :: enum c.int {
    None = 0,
    IAMFAudioElement,
    IAMFMixPresentation,
    TileGrid,
    LCEVC,
}

// Forward declarations for IAMF types (defined in avutil iamf.h)
IAMFAudioElement :: struct {}
IAMFMixPresentation :: struct {}

StreamGroup_Params :: struct #raw_union {
    iamf_audio_element:    ^IAMFAudioElement,
    iamf_mix_presentation: ^IAMFMixPresentation,
    tile_grid:             ^StreamGroupTileGrid,
    lcevc:                 ^StreamGroupLCEVC,
}

StreamGroup :: struct {
    av_class:    ^avutil.Class,
    priv_data:   rawptr,
    index:       c.uint,
    id:          c.int64_t,
    type:        StreamGroupParamsType,
    params:      StreamGroup_Params,
    metadata:    ^avutil.Dictionary,
    nb_streams:  c.uint,
    streams:     [^]^Stream,
    disposition: DispositionFlags,
}

AV_PROGRAM_RUNNING :: 1

Program :: struct {
    id:                 c.int,
    flags:              c.int,
    discard:            avcodec.Discard,
    stream_index:       [^]c.uint,
    nb_stream_indexes:  c.uint,
    metadata:           ^avutil.Dictionary,
    program_num:        c.int,
    pmt_pid:            c.int,
    pcr_pid:            c.int,
    pmt_version:        c.int,
    start_time:         c.int64_t,
    end_time:           c.int64_t,
    pts_wrap_reference: c.int64_t,
    pts_wrap_behavior:  c.int,
}

FmtCtxFlag :: enum c.int {
    No_Header  = 0,
    Unseekable = 1,
}
FmtCtxFlags :: distinct bit_set[FmtCtxFlag;c.int]

Chapter :: struct {
    id:        c.int64_t,
    time_base: avutil.Rational,
    start:     c.int64_t,
    end:       c.int64_t,
    metadata:  ^avutil.Dictionary,
}

DurationEstimationMethod :: enum c.int {
    FromPTS,
    FromStream,
    FromBitrate,
}

// FormatContext.flags values
FmtFlag :: enum c.int {
    Gen_PTS         = 0,
    Ign_Idx         = 1,
    Nonblock        = 2,
    Ign_DTS         = 3,
    No_Fill_In      = 4,
    No_Parse        = 5,
    No_Buffer       = 6,
    Custom_IO       = 7,
    Discard_Corrupt = 8,
    Flush_Packets   = 9,
    Bitexact        = 10,
    Sort_DTS        = 16,
    Fast_Seek       = 19,
    Auto_BSF        = 21,
}
FmtFlags :: distinct bit_set[FmtFlag;c.int]

FmtEventFlag :: enum c.int {
    Metadata_Updated = 0,
}
FmtEventFlags :: distinct bit_set[FmtEventFlag;c.int]

AvoidNegTS :: enum c.int {
    Auto              = -1,
    Disabled          = 0,
    Make_Non_Negative = 1,
    Make_Zero         = 2,
}

FF_FDEBUG_TS :: 0x0001

FormatContext :: struct {
    av_class:                        ^avutil.Class,
    iformat:                         ^InputFormat,
    oformat:                         ^OutputFormat,
    priv_data:                       rawptr,
    pb:                              ^IOContext,
    ctx_flags:                       FmtCtxFlags,
    nb_streams:                      c.uint,
    streams:                         [^]^Stream,
    nb_stream_groups:                c.uint,
    stream_groups:                   [^]^StreamGroup,
    nb_chapters:                     c.uint,
    chapters:                        [^]^Chapter,
    url:                             cstring,
    start_time:                      c.int64_t,
    duration:                        c.int64_t,
    bit_rate:                        c.int64_t,
    packet_size:                     c.uint,
    max_delay:                       c.int,
    flags:                           FmtFlags,
    probesize:                       c.int64_t,
    max_analyze_duration:            c.int64_t,
    key:                             [^]u8,
    keylen:                          c.int,
    nb_programs:                     c.uint,
    programs:                        [^]^Program,
    video_codec_id:                  avcodec.CodecID,
    audio_codec_id:                  avcodec.CodecID,
    subtitle_codec_id:               avcodec.CodecID,
    data_codec_id:                   avcodec.CodecID,
    metadata:                        ^avutil.Dictionary,
    start_time_realtime:             c.int64_t,
    fps_probe_size:                  c.int,
    error_recognition:               c.int,
    interrupt_callback:              IOInterruptCB,
    debug:                           c.int,
    max_streams:                     c.int,
    max_index_size:                  c.uint,
    max_picture_buffer:              c.uint,
    max_interleave_delta:            c.int64_t,
    max_ts_probe:                    c.int,
    max_chunk_duration:              c.int,
    max_chunk_size:                  c.int,
    max_probe_packets:               c.int,
    strict_std_compliance:           c.int,
    event_flags:                     FmtEventFlags,
    avoid_negative_ts:               AvoidNegTS,
    audio_preload:                   c.int,
    use_wallclock_as_timestamps:     c.int,
    skip_estimate_duration_from_pts: c.int,
    avio_flags:                      IOFlags,
    duration_estimation_method:      DurationEstimationMethod,
    skip_initial_bytes:              c.int64_t,
    correct_ts_overflow:             c.uint,
    seek2any:                        c.int,
    flush_packets:                   c.int,
    probe_score:                     c.int,
    format_probesize:                c.int,
    codec_whitelist:                 cstring,
    format_whitelist:                cstring,
    protocol_whitelist:              cstring,
    protocol_blacklist:              cstring,
    io_repositioned:                 c.int,
    video_codec:                     ^avcodec.Codec,
    audio_codec:                     ^avcodec.Codec,
    subtitle_codec:                  ^avcodec.Codec,
    data_codec:                      ^avcodec.Codec,
    metadata_header_padding:         c.int,
    opaque:                          rawptr,
    control_message_cb:              #type proc "c" (
        s: ^FormatContext,
        type: c.int,
        data: rawptr,
        data_size: c.size_t,
    ) -> c.int,
    output_ts_offset:                c.int64_t,
    dump_separator:                  [^]u8,
    io_open:                         #type proc "c" (
        s: ^FormatContext,
        pb: ^^IOContext,
        url: cstring,
        flags: c.int,
        options: ^^avutil.Dictionary,
    ) -> c.int,
    io_close2:                       #type proc "c" (s: ^FormatContext, pb: ^IOContext) -> c.int,
    duration_probesize:              c.int64_t,
    name:                            cstring,
}

SeekFlag :: enum c.int {
    Backward = 0,
    Byte     = 1,
    Any      = 2,
    Frame_   = 3,
}
SeekFlags :: distinct bit_set[SeekFlag;c.int]

// Return value of avformat_init_output
StreamInitIn :: enum c.int {
    Write_Header = 0,
    Init_Output  = 1,
}

FormatCommandID :: enum c.int {
    RTSPSetParameter,
}

RTSPCommandRequest :: struct {
    headers:  ^avutil.Dictionary,
    body_len: c.size_t,
    body:     cstring,
}

RTSPResponse :: struct {
    status_code: c.int,
    reason:      cstring,
    body_len:    c.size_t,
    body:        [^]u8,
}

FrameFilenameFlag :: enum c.int {
    Multiple          = 0,
    Ignore_Truncation = 1,
}
FrameFilenameFlags :: distinct bit_set[FrameFilenameFlag;c.int]

// ---------------------------------------------------------------------------
// Foreign block — libavformat (includes avio)
// ---------------------------------------------------------------------------

@(link_prefix = "avformat_", default_calling_convention = "c")
foreign avformat {
    // --- Version / configuration ---
    version :: proc() -> c.uint ---
    configuration :: proc() -> cstring ---
    license :: proc() -> cstring ---

    // --- Network ---
    network_init :: proc() -> c.int ---
    network_deinit :: proc() -> c.int ---

    // --- Context allocation ---
    alloc_context :: proc() -> ^FormatContext ---
    free_context :: proc(s: ^FormatContext) ---
    get_class :: proc() -> ^avutil.Class ---

    // --- Stream group ---
    stream_group_name :: proc(type: StreamGroupParamsType) -> cstring ---
    stream_group_create :: proc(s: ^FormatContext, type: StreamGroupParamsType, options: ^^avutil.Dictionary) -> ^StreamGroup ---
    stream_group_add_stream :: proc(stg: ^StreamGroup, st: ^Stream) -> c.int ---

    // --- Streams / programs ---
    new_stream :: proc(s: ^FormatContext, c: ^avcodec.Codec) -> ^Stream ---

    // --- Output allocation ---
    alloc_output_context2 :: proc(ctx: ^^FormatContext, oformat: ^OutputFormat, format_name: cstring, filename: cstring) -> c.int ---

    // --- Demuxing ---
    open_input :: proc(ps: ^^FormatContext, url: cstring, fmt: ^InputFormat, options: ^^avutil.Dictionary) -> c.int ---
    find_stream_info :: proc(ic: ^FormatContext, options: ^^avutil.Dictionary) -> c.int ---
    seek_file :: proc(s: ^FormatContext, stream_index: c.int, min_ts: c.int64_t, ts: c.int64_t, max_ts: c.int64_t, flags: SeekFlags) -> c.int ---
    flush :: proc(s: ^FormatContext) -> c.int ---
    close_input :: proc(s: ^^FormatContext) ---
    send_command :: proc(s: ^FormatContext, id: FormatCommandID, data: rawptr) -> c.int ---
    receive_command_reply :: proc(s: ^FormatContext, id: FormatCommandID, data_out: ^rawptr) -> c.int ---

    // --- Muxing ---
    write_header :: proc(s: ^FormatContext, options: ^^avutil.Dictionary) -> c.int ---
    init_output :: proc(s: ^FormatContext, options: ^^avutil.Dictionary) -> c.int ---
    index_get_entries_count :: proc(st: ^Stream) -> c.int ---
    index_get_entry :: proc(st: ^Stream, idx: c.int) -> ^IndexEntry ---
    index_get_entry_from_timestamp :: proc(st: ^Stream, wanted_timestamp: c.int64_t, flags: c.int) -> ^IndexEntry ---
    query_codec :: proc(ofmt: ^OutputFormat, codec_id: avcodec.CodecID, std_compliance: c.int) -> c.int ---
    get_riff_video_tags :: proc() -> ^CodecTag ---
    get_riff_audio_tags :: proc() -> ^CodecTag ---
    get_mov_video_tags :: proc() -> ^CodecTag ---
    get_mov_audio_tags :: proc() -> ^CodecTag ---
    match_stream_specifier :: proc(s: ^FormatContext, st: ^Stream, spec: cstring) -> c.int ---
    queue_attached_pictures :: proc(s: ^FormatContext) -> c.int ---
}

@(link_prefix = "avio_", default_calling_convention = "c")
foreign avformat {
    // --- AVIO functions ---
    find_protocol_name :: proc(url: cstring) -> cstring ---
    check :: proc(url: cstring, flags: c.int) -> c.int ---
    open_dir :: proc(s: ^^IODirContext, url: cstring, options: ^^avutil.Dictionary) -> c.int ---
    read_dir :: proc(s: ^IODirContext, next: ^^IODirEntry) -> c.int ---
    close_dir :: proc(s: ^^IODirContext) -> c.int ---
    free_directory_entry :: proc(entry: ^^IODirEntry) ---
    @(link_name = "avio_alloc_context")
    avio_alloc_context :: proc(buffer: [^]u8, buffer_size: c.int, write_flag: c.int, opaque: rawptr, read_packet: #type proc "c" (opaque: rawptr, buf: [^]u8, buf_size: c.int) -> c.int, write_packet: #type proc "c" (opaque: rawptr, buf: [^]u8, buf_size: c.int) -> c.int, seek: #type proc "c" (opaque: rawptr, offset: c.int64_t, whence: c.int) -> c.int64_t) -> ^IOContext ---
    context_free :: proc(s: ^^IOContext) ---
    w8 :: proc(s: ^IOContext, b: c.int) ---
    write :: proc(s: ^IOContext, buf: [^]u8, size: c.int) ---
    wl64 :: proc(s: ^IOContext, val: c.uint64_t) ---
    wb64 :: proc(s: ^IOContext, val: c.uint64_t) ---
    wl32 :: proc(s: ^IOContext, val: c.uint) ---
    wb32 :: proc(s: ^IOContext, val: c.uint) ---
    wl24 :: proc(s: ^IOContext, val: c.uint) ---
    wb24 :: proc(s: ^IOContext, val: c.uint) ---
    wl16 :: proc(s: ^IOContext, val: c.uint) ---
    wb16 :: proc(s: ^IOContext, val: c.uint) ---
    put_str :: proc(s: ^IOContext, str: cstring) -> c.int ---
    put_str16le :: proc(s: ^IOContext, str: cstring) -> c.int ---
    put_str16be :: proc(s: ^IOContext, str: cstring) -> c.int ---
    write_marker :: proc(s: ^IOContext, time: c.int64_t, type: IODataMarkerType) ---
    seek :: proc(s: ^IOContext, offset: c.int64_t, whence: c.int) -> c.int64_t ---
    skip :: proc(s: ^IOContext, offset: c.int64_t) -> c.int64_t ---
    size :: proc(s: ^IOContext) -> c.int64_t ---
    feof :: proc(s: ^IOContext) -> c.int ---
    @(link_name = "avio_flush")
    avio_flush :: proc(s: ^IOContext) ---
    read :: proc(s: ^IOContext, buf: [^]u8, size: c.int) -> c.int ---
    read_partial :: proc(s: ^IOContext, buf: [^]u8, size: c.int) -> c.int ---
    r8 :: proc(s: ^IOContext) -> c.int ---
    rl16 :: proc(s: ^IOContext) -> c.uint ---
    rl24 :: proc(s: ^IOContext) -> c.uint ---
    rl32 :: proc(s: ^IOContext) -> c.uint ---
    rl64 :: proc(s: ^IOContext) -> c.uint64_t ---
    rb16 :: proc(s: ^IOContext) -> c.uint ---
    rb24 :: proc(s: ^IOContext) -> c.uint ---
    rb32 :: proc(s: ^IOContext) -> c.uint ---
    rb64 :: proc(s: ^IOContext) -> c.uint64_t ---
    get_str :: proc(pb: ^IOContext, maxlen: c.int, buf: cstring, buflen: c.int) -> c.int ---
    get_str16le :: proc(pb: ^IOContext, maxlen: c.int, buf: cstring, buflen: c.int) -> c.int ---
    get_str16be :: proc(pb: ^IOContext, maxlen: c.int, buf: cstring, buflen: c.int) -> c.int ---
    open :: proc(s: ^^IOContext, url: cstring, flags: IOFlags) -> c.int ---
    open2 :: proc(s: ^^IOContext, url: cstring, flags: IOFlags, int_cb: ^IOInterruptCB, options: ^^avutil.Dictionary) -> c.int ---
    close :: proc(s: ^IOContext) -> c.int ---
    closep :: proc(s: ^^IOContext) -> c.int ---
    open_dyn_buf :: proc(s: ^^IOContext) -> c.int ---
    get_dyn_buf :: proc(s: ^IOContext, pbuffer: ^^u8) -> c.int ---
    close_dyn_buf :: proc(s: ^IOContext, pbuffer: ^^u8) -> c.int ---
    enum_protocols :: proc(opaque: ^rawptr, output: c.int) -> cstring ---
    protocol_get_class :: proc(name: cstring) -> ^avutil.Class ---
    pause :: proc(h: ^IOContext, pause: c.int) -> c.int ---
    seek_time :: proc(h: ^IOContext, stream_index: c.int, timestamp: c.int64_t, flags: c.int) -> c.int64_t ---
    print_string_array :: proc(s: ^IOContext, strings: [^]cstring) ---

    // HTTP server: accept one client connection from a listening server IOContext.
    accept :: proc(s: ^IOContext, client: ^^IOContext) -> c.int ---

    // Perform the handshake with the client (non-blocking, returns > 0 while in progress).
    handshake :: proc(client: ^IOContext) -> c.int ---
}

@(link_prefix = "av_", default_calling_convention = "c")
foreign avformat {
    // --- Iteration ---
    muxer_iterate :: proc(opaque: ^rawptr) -> ^OutputFormat ---
    demuxer_iterate :: proc(opaque: ^rawptr) -> ^InputFormat ---
    stream_get_class :: proc() -> ^avutil.Class ---
    stream_group_get_class :: proc() -> ^avutil.Class ---
    new_program :: proc(s: ^FormatContext, id: c.int) -> ^Program ---
    stream_get_parser :: proc(s: ^Stream) -> ^avcodec.CodecParserContext ---

    // --- Input format probing ---
    find_input_format :: proc(short_name: cstring) -> ^InputFormat ---
    probe_input_format :: proc(pd: ^ProbeData, is_opened: c.int) -> ^InputFormat ---
    probe_input_format2 :: proc(pd: ^ProbeData, is_opened: c.int, score_max: ^c.int) -> ^InputFormat ---
    probe_input_format3 :: proc(pd: ^ProbeData, is_opened: c.int, score_ret: ^c.int) -> ^InputFormat ---
    probe_input_buffer2 :: proc(pb: ^IOContext, fmt: ^^InputFormat, url: cstring, logctx: rawptr, offset: c.uint, max_probe_size: c.uint) -> c.int ---
    probe_input_buffer :: proc(pb: ^IOContext, fmt: ^^InputFormat, url: cstring, logctx: rawptr, offset: c.uint, max_probe_size: c.uint) -> c.int ---
    find_program_from_stream :: proc(ic: ^FormatContext, last: ^Program, s: c.int) -> ^Program ---
    program_add_stream_index :: proc(ac: ^FormatContext, progid: c.int, idx: c.uint) ---
    find_best_stream :: proc(ic: ^FormatContext, type: avutil.MediaType, wanted_stream_nb: c.int, related_stream: c.int, decoder_ret: ^^avcodec.Codec, flags: c.int) -> c.int ---
    read_frame :: proc(s: ^FormatContext, pkt: ^avcodec.Packet) -> c.int ---
    seek_frame :: proc(s: ^FormatContext, stream_index: c.int, timestamp: c.int64_t, flags: SeekFlags) -> c.int ---
    read_play :: proc(s: ^FormatContext) -> c.int ---
    read_pause :: proc(s: ^FormatContext) -> c.int ---
    write_frame :: proc(s: ^FormatContext, pkt: ^avcodec.Packet) -> c.int ---
    interleaved_write_frame :: proc(s: ^FormatContext, pkt: ^avcodec.Packet) -> c.int ---
    write_uncoded_frame :: proc(s: ^FormatContext, stream_index: c.int, frame: ^avutil.Frame) -> c.int ---
    interleaved_write_uncoded_frame :: proc(s: ^FormatContext, stream_index: c.int, frame: ^avutil.Frame) -> c.int ---
    write_uncoded_frame_query :: proc(s: ^FormatContext, stream_index: c.int) -> c.int ---
    write_trailer :: proc(s: ^FormatContext) -> c.int ---
    guess_format :: proc(short_name: cstring, filename: cstring, mime_type: cstring) -> ^OutputFormat ---
    guess_codec :: proc(fmt: ^OutputFormat, short_name: cstring, filename: cstring, mime_type: cstring, type: avutil.MediaType) -> avcodec.CodecID ---
    get_output_timestamp :: proc(s: ^FormatContext, stream: c.int, dts: ^c.int64_t, wall: ^c.int64_t) -> c.int ---

    // --- Utility ---
    hex_dump :: proc(f: rawptr, buf: [^]u8, size: c.int) ---
    hex_dump_log :: proc(avcl: rawptr, level: c.int, buf: [^]u8, size: c.int) ---
    pkt_dump2 :: proc(f: rawptr, pkt: ^avcodec.Packet, dump_payload: c.int, st: ^Stream) ---
    pkt_dump_log2 :: proc(avcl: rawptr, level: c.int, pkt: ^avcodec.Packet, dump_payload: c.int, st: ^Stream) ---
    codec_get_id :: proc(tags: [^]^CodecTag, tag: c.uint) -> avcodec.CodecID ---
    codec_get_tag :: proc(tags: [^]^CodecTag, id: avcodec.CodecID) -> c.uint ---
    codec_get_tag2 :: proc(tags: [^]^CodecTag, id: avcodec.CodecID, tag: ^c.uint) -> c.int ---
    find_default_stream_index :: proc(s: ^FormatContext) -> c.int ---
    index_search_timestamp :: proc(st: ^Stream, timestamp: c.int64_t, flags: c.int) -> c.int ---
    add_index_entry :: proc(st: ^Stream, pos: c.int64_t, timestamp: c.int64_t, size: c.int, distance: c.int, flags: c.int) -> c.int ---
    url_split :: proc(proto: cstring, proto_size: c.int, authorization: cstring, authorization_size: c.int, hostname: cstring, hostname_size: c.int, port_ptr: ^c.int, path: cstring, path_size: c.int, url: cstring) ---
    dump_format :: proc(ic: ^FormatContext, index: c.int, url: cstring, is_output: c.int) ---
    get_frame_filename2 :: proc(buf: cstring, buf_size: c.int, path: cstring, number: c.int, flags: FrameFilenameFlags) -> c.int ---
    get_frame_filename :: proc(buf: cstring, buf_size: c.int, path: cstring, number: c.int) -> c.int ---
    filename_number_test :: proc(filename: cstring) -> c.int ---
    sdp_create :: proc(ac: [^]^FormatContext, n_files: c.int, buf: cstring, size: c.int) -> c.int ---
    match_ext :: proc(filename: cstring, extensions: cstring) -> c.int ---
    guess_sample_aspect_ratio :: proc(format: ^FormatContext, stream: ^Stream, frame: ^avutil.Frame) -> avutil.Rational ---
    guess_frame_rate :: proc(ctx: ^FormatContext, stream: ^Stream, frame: ^avutil.Frame) -> avutil.Rational ---
}

// avio_tell: inline wrapper (avio.h)
tell :: #force_inline proc "c" (s: ^IOContext) -> c.int64_t {
    return seek(
        s,
        0,
        1,
        /* SEEK_CUR */
    )
}
