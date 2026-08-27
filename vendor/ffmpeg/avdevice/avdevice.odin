package avdevice

import avformat "../avformat"
import avutil "../avutil"
import "core:c"

LINK :: #config(FFMPEG_LINK, "system")

when ODIN_OS == .Windows {
    when ODIN_ARCH == .amd64 {
        when LINK == "static" {
            foreign import avdevice "../windows_x64/avdevice_static.lib"
        } else when LINK == "shared" {
            foreign import avdevice "../windows_x64/avdevice.lib"
        } else {
            foreign import avdevice "avdevice.lib"
        }
    } else when ODIN_ARCH == .arm64 {
        when LINK == "static" {
            foreign import avdevice "../windows_arm64/avdevice_static.lib"
        } else when LINK == "shared" {
            foreign import avdevice "../windows_arm64/avdevice.lib"
        } else {
            foreign import avdevice "avdevice.lib"
        }
    } else {
        #panic("This architecture is currently not supported on Windows")
    }
} else when ODIN_OS == .Darwin {
    when LINK == "static" {
        when ODIN_ARCH == .amd64 {
            foreign import avdevice "../darwin_x64/libavdevice.darwin.a"
        } else when ODIN_ARCH == .arm64 {
            foreign import avdevice "../darwin_arm64/libavdevice.darwin.a"
        } else {
            #panic("This architecture is currently not supported on Darwin")
        }
    } else when LINK == "shared" {
        when ODIN_ARCH == .amd64 {
            foreign import avdevice "../darwin_x64/libavdevice.dylib"
        } else when ODIN_ARCH == .arm64 {
            foreign import avdevice "../darwin_arm64/libavdevice.dylib"
        } else {
            #panic("This architecture is currently not supported on Darwin")
        }
    } else {
        foreign import avdevice "system:avdevice"
    }
} else when ODIN_OS == .Linux {
    when LINK == "static" {
        when ODIN_ARCH == .amd64 {
            foreign import avdevice "../linux_x64/libavdevice.linux.a"
        } else when ODIN_ARCH == .arm64 {
            foreign import avdevice "../linux_arm64/libavdevice.linux.a"
        } else {
            #panic("This architecture is currently not supported on Linux")
        }
    } else when LINK == "shared" {
        when ODIN_ARCH == .amd64 {
            @(require) foreign import _avf "../linux_x64/libavfilter.so"
            @(require) foreign import _avfmt "../linux_x64/libavformat.so"
            @(require) foreign import _avc "../linux_x64/libavcodec.so"
            @(require) foreign import _avu "../linux_x64/libavutil.so"
            foreign import avdevice "../linux_x64/libavdevice.so"
        } else when ODIN_ARCH == .arm64 {
            @(require) foreign import _avf "../linux_arm64/libavfilter.so"
            @(require) foreign import _avfmt "../linux_arm64/libavformat.so"
            @(require) foreign import _avc "../linux_arm64/libavcodec.so"
            @(require) foreign import _avu "../linux_arm64/libavutil.so"
            foreign import avdevice "../linux_arm64/libavdevice.so"
        } else {
            #panic("This architecture is currently not supported on Linux")
        }
    } else {
        foreign import avdevice "system:avdevice"
    }
}

// ---------------------------------------------------------------------------
// libavdevice — device enumeration and control (avdevice.h)
// ---------------------------------------------------------------------------

DeviceRect :: struct {
    x:      c.int,
    y:      c.int,
    width:  c.int,
    height: c.int,
}

// MKBETAG(a,b,c,d) = (ord(a) << 24) | (ord(b) << 16) | (ord(c) << 8) | ord(d)
// All values below are precomputed from the C header macros.
AppToDevMessageType :: enum c.int {
    None          = 0x4E4F4E45, // MKBETAG('N','O','N','E')
    WindowSize    = 0x47454F4D, // MKBETAG('G','E','O','M')
    WindowRepaint = 0x52455041, // MKBETAG('R','E','P','A')
    Pause         = 0x50415520, // MKBETAG('P','A','U',' ')
    Play          = 0x504C4159, // MKBETAG('P','L','A','Y')
    TogglePause   = 0x50415554, // MKBETAG('P','A','U','T')
    SetVolume     = 0x53564F4C, // MKBETAG('S','V','O','L')
    Mute          = 0x204D5554, // MKBETAG(' ','M','U','T')
    Unmute        = 0x554D5554, // MKBETAG('U','M','U','T')
    ToggleMute    = 0x544D5554, // MKBETAG('T','M','U','T')
    GetVolume     = 0x47564F4C, // MKBETAG('G','V','O','L')
    GetMute       = 0x474D5554, // MKBETAG('G','M','U','T')
}

DevToAppMessageType :: enum c.int {
    None                = 0x4E4F4E45, // MKBETAG('N','O','N','E')
    CreateWindowBuffer  = 0x42435245, // MKBETAG('B','C','R','E')
    PrepareWindowBuffer = 0x42505245, // MKBETAG('B','P','R','E')
    DisplayWindowBuffer = 0x42444953, // MKBETAG('B','D','I','S')
    DestroyWindowBuffer = 0x42444553, // MKBETAG('B','D','E','S')
    BufferOverflow      = 0x424F464C, // MKBETAG('B','O','F','L')
    BufferUnderflow     = 0x4255464C, // MKBETAG('B','U','F','L')
    BufferReadable      = 0x42524420, // MKBETAG('B','R','D',' ')
    BufferWritable      = 0x42575220, // MKBETAG('B','W','R',' ')
    MuteStateChanged    = 0x434D5554, // MKBETAG('C','M','U','T')
    VolumeLevelChanged  = 0x43564F4C, // MKBETAG('C','V','O','L')
}

DeviceInfo :: struct {
    device_name:        cstring,
    device_description: cstring,
    media_types:        [^]avutil.MediaType,
    nb_media_types:     c.int,
}

DeviceInfoList :: struct {
    devices:        [^]^DeviceInfo,
    nb_devices:     c.int,
    default_device: c.int,
}

@(link_prefix = "avdevice_", default_calling_convention = "c")
foreign avdevice {
    // --- Version / configuration ---
    version :: proc() -> c.uint ---
    configuration :: proc() -> cstring ---
    license :: proc() -> cstring ---

    // --- Registration ---
    register_all :: proc() ---

    // --- Control messages ---
    app_to_dev_control_message :: proc(s: ^avformat.FormatContext, type: AppToDevMessageType, data: rawptr, data_size: c.size_t) -> c.int ---
    dev_to_app_control_message :: proc(s: ^avformat.FormatContext, type: DevToAppMessageType, data: rawptr, data_size: c.size_t) -> c.int ---

    // --- Device enumeration ---
    list_devices :: proc(s: ^avformat.FormatContext, device_list: ^^DeviceInfoList) -> c.int ---
    free_list_devices :: proc(device_list: ^^DeviceInfoList) ---
    list_input_sources :: proc(device: ^avformat.InputFormat, device_name: cstring, device_options: ^avutil.Dictionary, device_list: ^^DeviceInfoList) -> c.int ---
    list_output_sinks :: proc(device: ^avformat.OutputFormat, device_name: cstring, device_options: ^avutil.Dictionary, device_list: ^^DeviceInfoList) -> c.int ---
}

@(link_prefix = "av_", default_calling_convention = "c")
foreign avdevice {
    // --- Device iteration ---
    input_audio_device_next :: proc(d: ^avformat.InputFormat) -> ^avformat.InputFormat ---
    input_video_device_next :: proc(d: ^avformat.InputFormat) -> ^avformat.InputFormat ---
    output_audio_device_next :: proc(d: ^avformat.OutputFormat) -> ^avformat.OutputFormat ---
    output_video_device_next :: proc(d: ^avformat.OutputFormat) -> ^avformat.OutputFormat ---
}
