package avutil

import "core:c"

LINK :: #config(FFMPEG_LINK, "system")

when ODIN_OS == .Windows {
    when ODIN_ARCH == .amd64 {
        when LINK == "static" {
            foreign import avutil "../windows_x64/avutil_static.lib"
        } else when LINK == "shared" {
            foreign import avutil "../windows_x64/avutil.lib"
        } else {
            foreign import avutil "avutil.lib"
        }
    } else when ODIN_ARCH == .arm64 {
        when LINK == "static" {
            foreign import avutil "../windows_arm64/avutil_static.lib"
        } else when LINK == "shared" {
            foreign import avutil "../windows_arm64/avutil.lib"
        } else {
            foreign import avutil "avutil.lib"
        }
    } else {
        #panic("This architecture is currently not supported on Windows")
    }
} else when ODIN_OS == .Darwin {
    when LINK == "static" {
        when ODIN_ARCH == .amd64 {
            // Extra system frameworks required by static libavutil.
            @(require) foreign import "system:VideoToolbox.framework"
            @(require) foreign import "system:CoreFoundation.framework"
            @(require) foreign import "system:CoreMedia.framework"
            @(require) foreign import "system:CoreVideo.framework"
            @(require) foreign import "system:CoreServices.framework"
            foreign import avutil "../darwin_x64/libavutil.darwin.a"
        } else when ODIN_ARCH == .arm64 {
            // Extra system frameworks required by static libavutil.
            @(require) foreign import "system:VideoToolbox.framework"
            @(require) foreign import "system:CoreFoundation.framework"
            @(require) foreign import "system:CoreMedia.framework"
            @(require) foreign import "system:CoreVideo.framework"
            @(require) foreign import "system:CoreServices.framework"
            foreign import avutil "../darwin_arm64/libavutil.darwin.a"
        } else {
            #panic("This architecture is currently not supported on Darwin")
        }
    } else when LINK == "shared" {
        when ODIN_ARCH == .amd64 {
            foreign import avutil "../darwin_x64/libavutil.dylib"
        } else when ODIN_ARCH == .arm64 {
            foreign import avutil "../darwin_arm64/libavutil.dylib"
        } else {
            #panic("This architecture is currently not supported on Darwin")
        }
    } else {
        foreign import avutil "system:avutil"
    }
} else when ODIN_OS == .Linux {
    when LINK == "static" {
        when ODIN_ARCH == .amd64 {
            foreign import avutil "../linux_x64/libavutil.linux.a"
        } else when ODIN_ARCH == .arm64 {
            foreign import avutil "../linux_arm64/libavutil.linux.a"
        } else {
            #panic("This architecture is currently not supported on Linux")
        }
    } else when LINK == "shared" {
        when ODIN_ARCH == .amd64 {
            foreign import avutil "../linux_x64/libavutil.so"
        } else when ODIN_ARCH == .arm64 {
            foreign import avutil "../linux_arm64/libavutil.so"
        } else {
            #panic("This architecture is currently not supported on Linux")
        }
    } else {
        foreign import avutil "system:avutil"
    }
}

// ---------------------------------------------------------------------------
// avutil.h — version, media type, picture type, constants
// ---------------------------------------------------------------------------

NUM_DATA_POINTERS :: 8

AV_NOPTS_VALUE :: i64(-0x7FFFFFFFFFFFFFFF - 1) // INT64_MIN / 0x8000000000000000 bit pattern
AV_TIME_BASE :: 1_000_000

FF_LAMBDA_SHIFT :: 7
FF_LAMBDA_SCALE :: (1 << FF_LAMBDA_SHIFT)
FF_QP2LAMBDA :: 118
FF_LAMBDA_MAX :: (256 * 128 - 1)
FF_QUALITY_SCALE :: FF_LAMBDA_SCALE

AV_FOURCC_MAX_STRING_SIZE :: 32
AV_ERROR_MAX_STRING_SIZE :: 64

MediaType :: enum c.int {
    Unknown    = -1,
    Video      = 0,
    Audio      = 1,
    Data       = 2,
    Subtitle   = 3,
    Attachment = 4,
    NB         = 5,
}

PictureType :: enum c.int {
    None = 0,
    I    = 1,
    P    = 2,
    B    = 3,
    S    = 4,
    SI   = 5,
    SP   = 6,
    BI   = 7,
}

// ---------------------------------------------------------------------------
// rational.h — AVRational
// ---------------------------------------------------------------------------

Rational :: struct {
    num: c.int,
    den: c.int,
}

// ---------------------------------------------------------------------------
// error.h — AVERROR constants
// FFERRTAG(a,b,c,d) = -(MKTAG(a,b,c,d)) = -((d<<24)|(c<<16)|(b<<8)|a)
// ---------------------------------------------------------------------------

AVERROR_BSF_NOT_FOUND :: -c.int(0xF8 | ('B' << 8) | ('S' << 16) | ('F' << 24))
AVERROR_BUG :: -c.int('B' | ('U' << 8) | ('G' << 16) | ('!' << 24))
AVERROR_BUFFER_TOO_SMALL :: -c.int('B' | ('U' << 8) | ('F' << 16) | ('S' << 24))
AVERROR_DECODER_NOT_FOUND :: -c.int(0xF8 | ('D' << 8) | ('E' << 16) | ('C' << 24))
AVERROR_DEMUXER_NOT_FOUND :: -c.int(0xF8 | ('D' << 8) | ('E' << 16) | ('M' << 24))
AVERROR_ENCODER_NOT_FOUND :: -c.int(0xF8 | ('E' << 8) | ('N' << 16) | ('C' << 24))
AVERROR_EOF :: -c.int('E' | ('O' << 8) | ('F' << 16) | (' ' << 24))
AVERROR_EXIT :: -c.int('E' | ('X' << 8) | ('I' << 16) | ('T' << 24))
AVERROR_EXTERNAL :: -c.int('E' | ('X' << 8) | ('T' << 16) | (' ' << 24))
AVERROR_FILTER_NOT_FOUND :: -c.int(0xF8 | ('F' << 8) | ('I' << 16) | ('L' << 24))
AVERROR_INVALIDDATA :: -c.int('I' | ('N' << 8) | ('D' << 16) | ('A' << 24))
AVERROR_MUXER_NOT_FOUND :: -c.int(0xF8 | ('M' << 8) | ('U' << 16) | ('X' << 24))
AVERROR_OPTION_NOT_FOUND :: -c.int(0xF8 | ('O' << 8) | ('P' << 16) | ('T' << 24))
AVERROR_PATCHWELCOME :: -c.int('P' | ('A' << 8) | ('W' << 16) | ('E' << 24))
AVERROR_PROTOCOL_NOT_FOUND :: -c.int(0xF8 | ('P' << 8) | ('R' << 16) | ('O' << 24))
AVERROR_STREAM_NOT_FOUND :: -c.int(0xF8 | ('S' << 8) | ('T' << 16) | ('R' << 24))
AVERROR_BUG2 :: -c.int('B' | ('U' << 8) | ('G' << 16) | (' ' << 24))
AVERROR_UNKNOWN :: -c.int('U' | ('N' << 8) | ('K' << 16) | ('N' << 24))
// EAGAIN is platform-specific: 35 on macOS/BSD, 11 on Linux.
when ODIN_OS == .Darwin {
    AVERROR_EAGAIN :: -35
} else {
    AVERROR_EAGAIN :: -11
}
AVERROR_EXPERIMENTAL :: -0x2bb2afa8
AVERROR_INPUT_CHANGED :: -0x636e6701
AVERROR_OUTPUT_CHANGED :: -0x636e6702
AVERROR_HTTP_BAD_REQUEST :: -c.int(0xF8 | ('4' << 8) | ('0' << 16) | ('0' << 24))
AVERROR_HTTP_UNAUTHORIZED :: -c.int(0xF8 | ('4' << 8) | ('0' << 16) | ('1' << 24))
AVERROR_HTTP_FORBIDDEN :: -c.int(0xF8 | ('4' << 8) | ('0' << 16) | ('3' << 24))
AVERROR_HTTP_NOT_FOUND :: -c.int(0xF8 | ('4' << 8) | ('0' << 16) | ('4' << 24))
AVERROR_HTTP_TOO_MANY_REQUESTS :: -c.int(0xF8 | ('4' << 8) | ('2' << 16) | ('9' << 24))
AVERROR_HTTP_OTHER_4XX :: -c.int(0xF8 | ('4' << 8) | ('X' << 16) | ('X' << 24))
AVERROR_HTTP_SERVER_ERROR :: -c.int(0xF8 | ('5' << 8) | ('X' << 16) | ('X' << 24))

// ---------------------------------------------------------------------------
// mathematics.h — AVRounding + timestamp math
// ---------------------------------------------------------------------------

Rounding :: enum c.int {
    Zero        = 0,
    Inf         = 1,
    Down        = 2,
    Up          = 3,
    Near_Inf    = 5,
    Pass_Minmax = 8192,
}

// ---------------------------------------------------------------------------
// samplefmt.h — AVSampleFormat
// ---------------------------------------------------------------------------

SampleFormat :: enum c.int {
    None = -1,
    U8   = 0,
    S16  = 1,
    S32  = 2,
    Flt  = 3,
    Dbl  = 4,
    U8P  = 5,
    S16P = 6,
    S32P = 7,
    FltP = 8,
    DblP = 9,
    S64  = 10,
    S64P = 11,
    NB   = 12,
}

// ---------------------------------------------------------------------------
// pixfmt.h — AVPixelFormat (all entries from FFmpeg v8.0)
// ---------------------------------------------------------------------------

PixelFormat :: enum c.int {
    None           = -1,
    YUV420P        = 0,
    YUYV422        = 1,
    RGB24          = 2,
    BGR24          = 3,
    YUV422P        = 4,
    YUV444P        = 5,
    YUV410P        = 6,
    YUV411P        = 7,
    GRAY8          = 8,
    MonoWhite      = 9,
    MonoBlack      = 10,
    PAL8           = 11,
    YUVJ420P       = 12,
    YUVJ422P       = 13,
    YUVJ444P       = 14,
    UYVY422        = 15,
    UYYVYY411      = 16,
    BGR8           = 17,
    BGR4           = 18,
    BGR4_Byte      = 19,
    RGB8           = 20,
    RGB4           = 21,
    RGB4_Byte      = 22,
    NV12           = 23,
    NV21           = 24,
    ARGB           = 25,
    RGBA           = 26,
    ABGR           = 27,
    BGRA           = 28,
    GRAY16BE       = 29,
    GRAY16LE       = 30,
    YUV440P        = 31,
    YUVJ440P       = 32,
    YUVA420P       = 33,
    RGB48BE        = 34,
    RGB48LE        = 35,
    RGB565BE       = 36,
    RGB565LE       = 37,
    RGB555BE       = 38,
    RGB555LE       = 39,
    BGR565BE       = 40,
    BGR565LE       = 41,
    BGR555BE       = 42,
    BGR555LE       = 43,
    VAAPI          = 44,
    YUV420P16LE    = 45,
    YUV420P16BE    = 46,
    YUV422P16LE    = 47,
    YUV422P16BE    = 48,
    YUV444P16LE    = 49,
    YUV444P16BE    = 50,
    DXVA2_VLD      = 51,
    RGB444LE       = 52,
    RGB444BE       = 53,
    BGR444LE       = 54,
    BGR444BE       = 55,
    YA8            = 56,
    // Y400A = YA8 (alias)
    // GRAY8A = YA8 (alias)
    BGR48BE        = 57,
    BGR48LE        = 58,
    YUV420P9BE     = 59,
    YUV420P9LE     = 60,
    YUV420P10BE    = 61,
    YUV420P10LE    = 62,
    YUV422P10BE    = 63,
    YUV422P10LE    = 64,
    YUV444P9BE     = 65,
    YUV444P9LE     = 66,
    YUV444P10BE    = 67,
    YUV444P10LE    = 68,
    YUV422P9BE     = 69,
    YUV422P9LE     = 70,
    GBRP           = 71,
    // GBR24P = GBRP (alias)
    GBRP9BE        = 72,
    GBRP9LE        = 73,
    GBRP10BE       = 74,
    GBRP10LE       = 75,
    GBRP16BE       = 76,
    GBRP16LE       = 77,
    YUVA422P       = 78,
    YUVA444P       = 79,
    YUVA420P9BE    = 80,
    YUVA420P9LE    = 81,
    YUVA422P9BE    = 82,
    YUVA422P9LE    = 83,
    YUVA444P9BE    = 84,
    YUVA444P9LE    = 85,
    YUVA420P10BE   = 86,
    YUVA420P10LE   = 87,
    YUVA422P10BE   = 88,
    YUVA422P10LE   = 89,
    YUVA444P10BE   = 90,
    YUVA444P10LE   = 91,
    YUVA420P16BE   = 92,
    YUVA420P16LE   = 93,
    YUVA422P16BE   = 94,
    YUVA422P16LE   = 95,
    YUVA444P16BE   = 96,
    YUVA444P16LE   = 97,
    VDPAU          = 98,
    XYZ12LE        = 99,
    XYZ12BE        = 100,
    NV16           = 101,
    NV20LE         = 102,
    NV20BE         = 103,
    RGBA64BE       = 104,
    RGBA64LE       = 105,
    BGRA64BE       = 106,
    BGRA64LE       = 107,
    YVYU422        = 108,
    YA16BE         = 109,
    YA16LE         = 110,
    GBRAP          = 111,
    GBRAP16BE      = 112,
    GBRAP16LE      = 113,
    QSV            = 114,
    MMAL           = 115,
    D3D11VA_VLD    = 116,
    CUDA           = 117,
    _0RGB          = 118,
    RGB0           = 119,
    _0BGR          = 120,
    BGR0           = 121,
    YUV420P12BE    = 122,
    YUV420P12LE    = 123,
    YUV420P14BE    = 124,
    YUV420P14LE    = 125,
    YUV422P12BE    = 126,
    YUV422P12LE    = 127,
    YUV422P14BE    = 128,
    YUV422P14LE    = 129,
    YUV444P12BE    = 130,
    YUV444P12LE    = 131,
    YUV444P14BE    = 132,
    YUV444P14LE    = 133,
    GBRP12BE       = 134,
    GBRP12LE       = 135,
    GBRP14BE       = 136,
    GBRP14LE       = 137,
    YUVJ411P       = 138,
    BAYER_BGGR8    = 139,
    BAYER_RGGB8    = 140,
    BAYER_GBRG8    = 141,
    BAYER_GRBG8    = 142,
    BAYER_BGGR16LE = 143,
    BAYER_BGGR16BE = 144,
    BAYER_RGGB16LE = 145,
    BAYER_RGGB16BE = 146,
    BAYER_GBRG16LE = 147,
    BAYER_GBRG16BE = 148,
    BAYER_GRBG16LE = 149,
    BAYER_GRBG16BE = 150,
    YUV440P10LE    = 151,
    YUV440P10BE    = 152,
    YUV440P12LE    = 153,
    YUV440P12BE    = 154,
    AYUV64LE       = 155,
    AYUV64BE       = 156,
    VideoToolbox   = 157,
    P010LE         = 158,
    P010BE         = 159,
    GBRAP12BE      = 160,
    GBRAP12LE      = 161,
    GBRAP10BE      = 162,
    GBRAP10LE      = 163,
    MediaCodec     = 164,
    GRAY12BE       = 165,
    GRAY12LE       = 166,
    GRAY10BE       = 167,
    GRAY10LE       = 168,
    P016LE         = 169,
    P016BE         = 170,
    D3D11          = 171,
    GRAY9BE        = 172,
    GRAY9LE        = 173,
    GBRPF32BE      = 174,
    GBRPF32LE      = 175,
    GBRAPF32BE     = 176,
    GBRAPF32LE     = 177,
    DRM_Prime      = 178,
    OpenCL         = 179,
    GRAY14BE       = 180,
    GRAY14LE       = 181,
    GRAYF32BE      = 182,
    GRAYF32LE      = 183,
    YUVA422P12BE   = 184,
    YUVA422P12LE   = 185,
    YUVA444P12BE   = 186,
    YUVA444P12LE   = 187,
    NV24           = 188,
    NV42           = 189,
    Vulkan         = 190,
    Y210BE         = 191,
    Y210LE         = 192,
    X2RGB10LE      = 193,
    X2RGB10BE      = 194,
    X2BGR10LE      = 195,
    X2BGR10BE      = 196,
    P210BE         = 197,
    P210LE         = 198,
    P410BE         = 199,
    P410LE         = 200,
    P216BE         = 201,
    P216LE         = 202,
    P416BE         = 203,
    P416LE         = 204,
    VUYA           = 205,
    RGBAF16BE      = 206,
    RGBAF16LE      = 207,
    VUYX           = 208,
    P012LE         = 209,
    P012BE         = 210,
    Y212BE         = 211,
    Y212LE         = 212,
    XV30BE         = 213,
    XV30LE         = 214,
    XV36BE         = 215,
    XV36LE         = 216,
    RGBF32BE       = 217,
    RGBF32LE       = 218,
    RGBAF32BE      = 219,
    RGBAF32LE      = 220,
    P212BE         = 221,
    P212LE         = 222,
    P412BE         = 223,
    P412LE         = 224,
    GBRAP14BE      = 225,
    GBRAP14LE      = 226,
    D3D12          = 227,
    AYUV           = 228,
    UYVA           = 229,
    VYU444         = 230,
    V30XBE         = 231,
    V30XLE         = 232,
    RGBF16BE       = 233,
    RGBF16LE       = 234,
    RGBA128BE      = 235,
    RGBA128LE      = 236,
    RGB96BE        = 237,
    RGB96LE        = 238,
    Y216BE         = 239,
    Y216LE         = 240,
    XV48BE         = 241,
    XV48LE         = 242,
    GBRPF16BE      = 243,
    GBRPF16LE      = 244,
    GBRAPF16BE     = 245,
    GBRAPF16LE     = 246,
    GRAYF16BE      = 247,
    GRAYF16LE      = 248,
    AMF_Surface    = 249,
    GRAY32BE       = 250,
    GRAY32LE       = 251,
    YAF32BE        = 252,
    YAF32LE        = 253,
    YAF16BE        = 254,
    YAF16LE        = 255,
    GBRAP32BE      = 256,
    GBRAP32LE      = 257,
    YUV444P10MSBBE = 258,
    YUV444P10MSBLE = 259,
    YUV444P12MSBBE = 260,
    YUV444P12MSBLE = 261,
    GBRP10MSBBE    = 262,
    GBRP10MSBLE    = 263,
    GBRP12MSBBE    = 264,
    GBRP12MSBLE    = 265,
    OHCodec        = 266,
    NB             = 267,
}

// ---------------------------------------------------------------------------
// pixfmt.h — color metadata enums (used by AVFrame)
// ---------------------------------------------------------------------------

ColorPrimaries :: enum c.int {
    Reserved0   = 0,
    BT709       = 1,
    Unspecified = 2,
    Reserved    = 3,
    BT470M      = 4,
    BT470BG     = 5,
    SMPTE170M   = 6,
    SMPTE240M   = 7,
    Film        = 8,
    BT2020      = 9,
    SMPTE428    = 10,
    SMPTE431    = 11,
    SMPTE432    = 12,
    EBU3213     = 22,
    NB          = 23,
    // Extended entries (not part of H.273)
    Ext_Base    = 256,
    V_Gamut     = 256,
    Ext_NB      = 257,
}

ColorTransferCharacteristic :: enum c.int {
    Reserved0    = 0,
    BT709        = 1,
    Unspecified  = 2,
    Reserved     = 3,
    Gamma22      = 4,
    Gamma28      = 5,
    SMPTE170M    = 6,
    SMPTE240M    = 7,
    Linear       = 8,
    Log          = 9,
    Log_Sqrt     = 10,
    IEC61966_2_4 = 11,
    BT1361_ECG   = 12,
    IEC61966_2_1 = 13,
    BT2020_10    = 14,
    BT2020_12    = 15,
    SMPTE2084    = 16,
    SMPTE428     = 17,
    ARIB_STD_B67 = 18,
    NB           = 19,
    Ext_Base     = 256,
    V_Log        = 256,
    Ext_NB       = 257,
}

ColorSpace :: enum c.int {
    RGB                = 0,
    BT709              = 1,
    Unspecified        = 2,
    Reserved           = 3,
    FCC                = 4,
    BT470BG            = 5,
    SMPTE170M          = 6,
    SMPTE240M          = 7,
    YCgCo              = 8,
    BT2020_NCL         = 9,
    BT2020_CL          = 10,
    SMPTE2085          = 11,
    Chroma_Derived_NCL = 12,
    Chroma_Derived_CL  = 13,
    ICtCp              = 14,
    IPT_C2             = 15,
    YCgCo_RE           = 16,
    YCgCo_RO           = 17,
    NB                 = 18,
}

ColorRange :: enum c.int {
    Unspecified = 0,
    MPEG        = 1,
    JPEG        = 2,
    NB          = 3,
}

ChromaLocation :: enum c.int {
    Unspecified = 0,
    Left        = 1,
    Center      = 2,
    TopLeft     = 3,
    Top         = 4,
    BottomLeft  = 5,
    Bottom      = 6,
    NB          = 7,
}

AlphaMode :: enum c.int {
    Unspecified   = 0,
    Premultiplied = 1,
    Straight      = 2,
    NB            = 3,
}

// ---------------------------------------------------------------------------
// channel_layout.h — AVChannel, AVChannelOrder, AVMatrixEncoding
// ---------------------------------------------------------------------------

Channel :: enum c.int {
    None                  = -1,
    Front_Left            = 0,
    Front_Right           = 1,
    Front_Center          = 2,
    Low_Frequency         = 3,
    Back_Left             = 4,
    Back_Right            = 5,
    Front_Left_of_Center  = 6,
    Front_Right_of_Center = 7,
    Back_Center           = 8,
    Side_Left             = 9,
    Side_Right            = 10,
    Top_Center            = 11,
    Top_Front_Left        = 12,
    Top_Front_Center      = 13,
    Top_Front_Right       = 14,
    Top_Back_Left         = 15,
    Top_Back_Center       = 16,
    Top_Back_Right        = 17,
    Stereo_Left           = 29,
    Stereo_Right          = 30,
    Wide_Left             = 31,
    Wide_Right            = 32,
    Surround_Direct_Left  = 33,
    Surround_Direct_Right = 34,
    Low_Frequency_2       = 35,
    Top_Side_Left         = 36,
    Top_Side_Right        = 37,
    Bottom_Front_Center   = 38,
    Bottom_Front_Left     = 39,
    Bottom_Front_Right    = 40,
    Side_Surround_Left    = 41,
    Side_Surround_Right   = 42,
    Top_Surround_Left     = 43,
    Top_Surround_Right    = 44,
    Binaural_Left         = 61,
    Binaural_Right        = 62,
    Unused                = 0x200,
    Unknown               = 0x300,
    Ambisonic_Base        = 0x400,
    Ambisonic_End         = 0x7ff,
}

ChannelOrder :: enum c.int {
    Unspec    = 0,
    Native    = 1,
    Custom    = 2,
    Ambisonic = 3,
}

MatrixEncoding :: enum c.int {
    None            = 0,
    Dolby           = 1,
    DPL_II          = 2,
    DPL_IIx         = 3,
    DPL_IIz         = 4,
    Dolby_EX        = 5,
    Dolby_Headphone = 6,
    NB              = 7,
}

ChannelCustom :: struct {
    id:     Channel,
    name:   [16]c.char,
    opaque: rawptr,
}

ChannelLayout :: struct {
    order:       ChannelOrder,
    nb_channels: c.int,
    u:           struct #raw_union {
        mask: c.uint64_t,
        map_: [^]ChannelCustom,
    },
    opaque:      rawptr,
}

// Common channel layout masks (bitmasks for native order)
AV_CH_FRONT_LEFT :: u64(1) << 0
AV_CH_FRONT_RIGHT :: u64(1) << 1
AV_CH_FRONT_CENTER :: u64(1) << 2
AV_CH_LOW_FREQUENCY :: u64(1) << 3
AV_CH_BACK_LEFT :: u64(1) << 4
AV_CH_BACK_RIGHT :: u64(1) << 5
AV_CH_FRONT_LEFT_OF_CENTER :: u64(1) << 6
AV_CH_FRONT_RIGHT_OF_CENTER :: u64(1) << 7
AV_CH_BACK_CENTER :: u64(1) << 8
AV_CH_SIDE_LEFT :: u64(1) << 9
AV_CH_SIDE_RIGHT :: u64(1) << 10
AV_CH_TOP_CENTER :: u64(1) << 11
AV_CH_TOP_FRONT_LEFT :: u64(1) << 12
AV_CH_TOP_FRONT_CENTER :: u64(1) << 13
AV_CH_TOP_FRONT_RIGHT :: u64(1) << 14
AV_CH_TOP_BACK_LEFT :: u64(1) << 15
AV_CH_TOP_BACK_CENTER :: u64(1) << 16
AV_CH_TOP_BACK_RIGHT :: u64(1) << 17
AV_CH_STEREO_LEFT :: u64(1) << 29
AV_CH_STEREO_RIGHT :: u64(1) << 30
AV_CH_WIDE_LEFT :: u64(1) << 31
AV_CH_WIDE_RIGHT :: u64(1) << 32
AV_CH_SURROUND_DIRECT_LEFT :: u64(1) << 33
AV_CH_SURROUND_DIRECT_RIGHT :: u64(1) << 34
AV_CH_LOW_FREQUENCY_2 :: u64(1) << 35
AV_CH_TOP_SIDE_LEFT :: u64(1) << 36
AV_CH_TOP_SIDE_RIGHT :: u64(1) << 37
AV_CH_BOTTOM_FRONT_CENTER :: u64(1) << 38
AV_CH_BOTTOM_FRONT_LEFT :: u64(1) << 39
AV_CH_BOTTOM_FRONT_RIGHT :: u64(1) << 40
AV_CH_BINAURAL_LEFT :: u64(1) << 61
AV_CH_BINAURAL_RIGHT :: u64(1) << 62

// Common layout presets
AV_CH_LAYOUT_MONO :: AV_CH_FRONT_CENTER
AV_CH_LAYOUT_STEREO :: (AV_CH_FRONT_LEFT | AV_CH_FRONT_RIGHT)
AV_CH_LAYOUT_5POINT1 ::
    (AV_CH_FRONT_LEFT |
        AV_CH_FRONT_RIGHT |
        AV_CH_FRONT_CENTER |
        AV_CH_LOW_FREQUENCY |
        AV_CH_BACK_LEFT |
        AV_CH_BACK_RIGHT)
AV_CH_LAYOUT_7POINT1 :: (AV_CH_LAYOUT_5POINT1 | AV_CH_SIDE_LEFT | AV_CH_SIDE_RIGHT)

// ---------------------------------------------------------------------------
// log.h — AVClassCategory, AVClassStateFlags, Class
// ---------------------------------------------------------------------------

ClassCategory :: enum c.int {
    NA                  = 0,
    Input               = 1,
    Output              = 2,
    Muxer               = 3,
    Demuxer             = 4,
    Encoder             = 5,
    Decoder             = 6,
    Filter              = 7,
    Bitstream_Filter    = 8,
    SwScaler            = 9,
    SwResampler         = 10,
    HWDevice            = 11,
    Device_Video_Output = 40,
    Device_Video_Input  = 41,
    Device_Audio_Output = 42,
    Device_Audio_Input  = 43,
    Device_Output       = 44,
    Device_Input        = 45,
    NB                  = 46,
}

ClassStateFlag :: enum c.int {
    Initialized = 0,
}
ClassStateFlags :: distinct bit_set[ClassStateFlag;c.int]

LogLevel :: enum c.int {
    Quiet   = -8,
    Panic   = 0,
    Fatal   = 8,
    Error   = 16,
    Warning = 24,
    Info    = 32,
    Verbose = 40,
    Debug   = 48,
    Trace   = 56,
}

LogFlag :: enum c.int {
    Skip_Repeated  = 0,
    Print_Level    = 1,
    Print_Time     = 2,
    Print_Datetime = 3,
}
LogFlags :: distinct bit_set[LogFlag;c.int]

// Forward declarations for Class
Option :: struct {} // defined in opt.h — opaque to callers
OptionRanges :: struct {} // defined in opt.h — opaque to callers

Class :: struct {
    class_name:                cstring,
    item_name:                 #type proc "c" (ctx: rawptr) -> cstring,
    option:                    ^Option,
    version:                   c.int,
    log_level_offset_offset:   c.int,
    parent_log_context_offset: c.int,
    category:                  ClassCategory,
    get_category:              #type proc "c" (ctx: rawptr) -> ClassCategory,
    query_ranges:              #type proc "c" (
        ranges: ^^OptionRanges,
        obj: rawptr,
        key: cstring,
        flags: c.int,
    ) -> c.int,
    child_next:                #type proc "c" (obj, prev: rawptr) -> rawptr,
    child_class_iterate:       #type proc "c" (iter: ^rawptr) -> ^Class,
    state_flags_offset:        c.int,
}

// ---------------------------------------------------------------------------
// hwcontext.h — hardware device types
// ---------------------------------------------------------------------------

HWDeviceType :: enum c.int {
    None = 0,
    Vdpau,
    Cuda,
    Vaapi,
    Dxva2,
    Qsv,
    Videotoolbox,
    D3d11va,
    Drm,
    Opencl,
    Mediacodec,
    Vulkan,
    D3d12va,
    Amf,
    Ohcodec,
}

// ---------------------------------------------------------------------------
// buffer.h — Buffer (opaque), AVBufferRef, BufferPool (opaque)
// ---------------------------------------------------------------------------

Buffer :: struct {} // opaque
BufferPool :: struct {} // opaque

BufferFreeFunc :: #type proc "c" (opaque: rawptr, data: [^]u8)

BufferRef :: struct {
    buffer: ^Buffer,
    data:   [^]u8,
    size:   c.size_t,
}

BufferFlag :: enum c.int {
    Readonly = 0,
}
BufferFlags :: distinct bit_set[BufferFlag;c.int]

// ---------------------------------------------------------------------------
// dict.h — AVDictionaryEntry, Dictionary, flags
// ---------------------------------------------------------------------------

DictFlag :: enum c.int {
    Match_Case      = 0,
    Ignore_Suffix   = 1,
    Dont_Strdup_Key = 2,
    Dont_Strdup_Val = 3,
    Dont_Overwrite  = 4,
    Append          = 5,
    Multikey        = 6,
    Dedup           = 7,
}
DictFlags :: distinct bit_set[DictFlag;c.int]

DictionaryEntry :: struct {
    key:   cstring,
    value: cstring,
}

Dictionary :: struct {} // opaque

// ---------------------------------------------------------------------------
// frame.h — AVFrameSideDataType, AVSideDataProps, AVFrameSideData,
//           AVSideDataDescriptor, AVRegionOfInterest, AVFrame
// ---------------------------------------------------------------------------

FrameSideDataType :: enum c.int {
    PanScan                     = 0,
    A53_CC                      = 1,
    Stereo3D                    = 2,
    MatrixEncoding_SD           = 3,
    Downmix_Info                = 4,
    ReplayGain                  = 5,
    DisplayMatrix               = 6,
    AFD                         = 7,
    Motion_Vectors              = 8,
    Skip_Samples                = 9,
    Audio_Service_Type          = 10,
    Mastering_Display_Metadata  = 11,
    GOP_Timecode                = 12,
    Spherical                   = 13,
    Content_Light_Level         = 14,
    ICC_Profile                 = 15,
    S12M_Timecode               = 16,
    Dynamic_HDR_Plus            = 17,
    Regions_Of_Interest         = 18,
    Video_Enc_Params            = 19,
    SEI_Unregistered            = 20,
    Film_Grain_Params           = 21,
    Detection_BBoxes            = 22,
    DOVI_RPU_Buffer             = 23,
    DOVI_Metadata               = 24,
    Dynamic_HDR_Vivid           = 25,
    Ambient_Viewing_Environment = 26,
    Video_Hint                  = 27,
    LCEVC                       = 28,
    View_ID                     = 29,
    _3D_Reference_Displays      = 30,
    EXIF                        = 31,
}

SideDataPropFlag :: enum c.uint {
    Global            = 0,
    Multi             = 1,
    Size_Dependent    = 2,
    Color_Dependent   = 3,
    Channel_Dependent = 4,
}
SideDataProps :: distinct bit_set[SideDataPropFlag;c.uint]

ActiveFormatDescription :: enum c.int {
    Same          = 8,
    _4_3          = 9,
    _16_9         = 10,
    _14_9         = 11,
    _4_3_SP_14_9  = 13,
    _16_9_SP_14_9 = 14,
    SP_4_3        = 15,
}

FrameSideData :: struct {
    type:     FrameSideDataType,
    data:     [^]u8,
    size:     c.size_t,
    metadata: ^Dictionary,
    buf:      ^BufferRef,
}

SideDataDescriptor :: struct {
    name:  cstring,
    props: c.uint,
}

FrameFlag :: enum c.int {
    Corrupt         = 0,
    Key             = 1,
    Discard         = 2,
    Interlaced      = 3,
    Top_Field_First = 4,
    Lossless        = 5,
}
FrameFlags :: distinct bit_set[FrameFlag;c.int]

FF_DECODE_ERROR_INVALID_BITSTREAM :: 1
FF_DECODE_ERROR_MISSING_REFERENCE :: 2
FF_DECODE_ERROR_CONCEALMENT_ACTIVE :: 4
FF_DECODE_ERROR_DECODE_SLICES :: 8

RegionOfInterest :: struct {
    self_size: c.uint32_t,
    top:       c.int,
    bottom:    c.int,
    left:      c.int,
    right:     c.int,
    qoffset:   Rational,
}

Frame :: struct {
    data:                  [NUM_DATA_POINTERS][^]u8,
    linesize:              [NUM_DATA_POINTERS]c.int,
    extended_data:         ^[^]u8,
    width:                 c.int,
    height:                c.int,
    nb_samples:            c.int,
    format:                c.int,
    pict_type:             PictureType,
    sample_aspect_ratio:   Rational,
    pts:                   c.int64_t,
    pkt_dts:               c.int64_t,
    time_base:             Rational,
    quality:               c.int,
    opaque:                rawptr,
    repeat_pict:           c.int,
    sample_rate:           c.int,
    buf:                   [NUM_DATA_POINTERS]^BufferRef,
    extended_buf:          ^^BufferRef,
    nb_extended_buf:       c.int,
    side_data:             ^^FrameSideData,
    nb_side_data:          c.int,
    flags:                 FrameFlags,
    color_range:           ColorRange,
    color_primaries:       ColorPrimaries,
    color_trc:             ColorTransferCharacteristic,
    colorspace:            ColorSpace,
    chroma_location:       ChromaLocation,
    best_effort_timestamp: c.int64_t,
    metadata:              ^Dictionary,
    decode_error_flags:    c.int,
    hw_frames_ctx:         ^BufferRef,
    opaque_ref:            ^BufferRef,
    crop_top:              c.size_t,
    crop_bottom:           c.size_t,
    crop_left:             c.size_t,
    crop_right:            c.size_t,
    private_ref:           rawptr,
    ch_layout:             ChannelLayout,
    duration:              c.int64_t,
    alpha_mode:            AlphaMode,
}

// Opaque types (fully-opaque; used only by pointer)
MD5 :: struct {}
AudioFifo :: struct {}

// ---------------------------------------------------------------------------
// Foreign procedure blocks
// ---------------------------------------------------------------------------

@(link_prefix = "av_", default_calling_convention = "c")
foreign avutil {
    // avutil.h
    @(link_name = "avutil_version")
    version :: proc() -> c.uint ---
    version_info :: proc() -> cstring ---
    @(link_name = "avutil_configuration")
    configuration :: proc() -> cstring ---
    @(link_name = "avutil_license")
    license :: proc() -> cstring ---
    get_media_type_string :: proc(media_type: MediaType) -> cstring ---
    get_picture_type_char :: proc(pict_type: PictureType) -> c.char ---
    get_time_base_q :: proc() -> Rational ---
    fourcc_make_string :: proc(buf: [^]c.char, fourcc: c.uint32_t) -> [^]c.char ---

    // rational.h
    reduce :: proc(dst_num, dst_den: ^c.int, num, den, max: c.int64_t) -> c.int ---
    mul_q :: proc(b, c_: Rational) -> Rational ---
    div_q :: proc(b, c_: Rational) -> Rational ---
    add_q :: proc(b, c_: Rational) -> Rational ---
    sub_q :: proc(b, c_: Rational) -> Rational ---
    d2q :: proc(d: c.double, max: c.int) -> Rational ---
    nearer_q :: proc(q, q1, q2: Rational) -> c.int ---
    find_nearest_q_idx :: proc(q: Rational, q_list: [^]Rational) -> c.int ---
    q2intfloat :: proc(q: Rational) -> c.uint32_t ---
    gcd_q :: proc(a, b: Rational, max_den: c.int, def: Rational) -> Rational ---

    // error.h
    strerror :: proc(errnum: c.int, errbuf: [^]c.char, errbuf_size: c.size_t) -> c.int ---

    // mathematics.h
    gcd :: proc(a, b: c.int64_t) -> c.int64_t ---
    rescale :: proc(a, b, c_: c.int64_t) -> c.int64_t ---
    rescale_rnd :: proc(a, b, c_: c.int64_t, rnd: Rounding) -> c.int64_t ---
    rescale_q :: proc(a: c.int64_t, bq, cq: Rational) -> c.int64_t ---
    rescale_q_rnd :: proc(a: c.int64_t, bq, cq: Rational, rnd: Rounding) -> c.int64_t ---
    compare_ts :: proc(ts_a: c.int64_t, tb_a: Rational, ts_b: c.int64_t, tb_b: Rational) -> c.int ---
    compare_mod :: proc(a, b, mod: c.uint64_t) -> c.int64_t ---
    rescale_delta :: proc(in_tb: Rational, in_ts: c.int64_t, fs_tb: Rational, duration: c.int, last: ^c.int64_t, out_tb: Rational) -> c.int64_t ---
    add_stable :: proc(ts_tb: Rational, ts: c.int64_t, inc_tb: Rational, inc: c.int64_t) -> c.int64_t ---
    bessel_i0 :: proc(x: c.double) -> c.double ---

    // samplefmt.h
    get_sample_fmt_name :: proc(sample_fmt: SampleFormat) -> cstring ---
    get_sample_fmt :: proc(name: cstring) -> SampleFormat ---
    get_alt_sample_fmt :: proc(sample_fmt: SampleFormat, planar: c.int) -> SampleFormat ---
    get_packed_sample_fmt :: proc(sample_fmt: SampleFormat) -> SampleFormat ---
    get_planar_sample_fmt :: proc(sample_fmt: SampleFormat) -> SampleFormat ---
    get_sample_fmt_string :: proc(buf: [^]c.char, buf_size: c.int, sample_fmt: SampleFormat) -> [^]c.char ---
    get_bytes_per_sample :: proc(sample_fmt: SampleFormat) -> c.int ---
    sample_fmt_is_planar :: proc(sample_fmt: SampleFormat) -> c.int ---
    samples_get_buffer_size :: proc(linesize: ^c.int, nb_channels, nb_samples: c.int, sample_fmt: SampleFormat, align: c.int) -> c.int ---
    samples_fill_arrays :: proc(audio_data: ^[^]u8, linesize: ^c.int, buf: [^]u8, nb_channels, nb_samples: c.int, sample_fmt: SampleFormat, align: c.int) -> c.int ---
    samples_alloc :: proc(audio_data: ^[^]u8, linesize: ^c.int, nb_channels, nb_samples: c.int, sample_fmt: SampleFormat, align: c.int) -> c.int ---
    samples_alloc_array_and_samples :: proc(audio_data: ^^[^]u8, linesize: ^c.int, nb_channels, nb_samples: c.int, sample_fmt: SampleFormat, align: c.int) -> c.int ---
    samples_copy :: proc(dst, src: [^][^]u8, dst_offset, src_offset, nb_samples, nb_channels: c.int, sample_fmt: SampleFormat) -> c.int ---
    samples_set_silence :: proc(audio_data: [^][^]u8, offset, nb_samples, nb_channels: c.int, sample_fmt: SampleFormat) -> c.int ---

    // log.h
    log :: proc(avcl: rawptr, level: LogLevel, fmt: cstring, #c_vararg args: ..any) ---
    vlog :: proc(avcl: rawptr, level: LogLevel, fmt: cstring, vl: rawptr) ---
    log_get_level :: proc() -> LogLevel ---
    log_set_level :: proc(level: LogLevel) ---
    log_set_callback :: proc(callback: #type proc "c" (avcl: rawptr, level: LogLevel, fmt: cstring, vl: rawptr)) ---
    log_default_callback :: proc(avcl: rawptr, level: LogLevel, fmt: cstring, vl: rawptr) ---
    default_item_name :: proc(ctx: rawptr) -> cstring ---
    default_get_category :: proc(ptr: rawptr) -> ClassCategory ---
    log_format_line :: proc(ptr: rawptr, level: LogLevel, fmt: cstring, vl: rawptr, line: [^]c.char, line_size: c.int, print_prefix: ^c.int) ---
    log_format_line2 :: proc(ptr: rawptr, level: LogLevel, fmt: cstring, vl: rawptr, line: [^]c.char, line_size: c.int, print_prefix: ^c.int) -> c.int ---
    log_set_flags :: proc(arg: LogFlags) ---
    log_get_flags :: proc() -> LogFlags ---

    // buffer.h
    buffer_alloc :: proc(size: c.size_t) -> ^BufferRef ---
    buffer_allocz :: proc(size: c.size_t) -> ^BufferRef ---
    buffer_create :: proc(data: [^]u8, size: c.size_t, free: BufferFreeFunc, opaque: rawptr, flags: BufferFlags) -> ^BufferRef ---
    buffer_default_free :: proc(opaque: rawptr, data: [^]u8) ---
    buffer_ref :: proc(buf: ^BufferRef) -> ^BufferRef ---
    buffer_unref :: proc(buf: ^^BufferRef) ---
    buffer_is_writable :: proc(buf: ^BufferRef) -> c.int ---
    buffer_get_opaque :: proc(buf: ^BufferRef) -> rawptr ---
    buffer_get_ref_count :: proc(buf: ^BufferRef) -> c.int ---
    buffer_make_writable :: proc(buf: ^^BufferRef) -> c.int ---
    buffer_realloc :: proc(buf: ^^BufferRef, size: c.size_t) -> c.int ---
    buffer_replace :: proc(dst: ^^BufferRef, src: ^BufferRef) -> c.int ---
    buffer_pool_init :: proc(size: c.size_t, alloc: #type proc "c" (size: c.size_t) -> ^BufferRef) -> ^BufferPool ---
    buffer_pool_init2 :: proc(size: c.size_t, opaque: rawptr, alloc: #type proc "c" (opaque: rawptr, size: c.size_t) -> ^BufferRef, pool_free: #type proc "c" (opaque: rawptr)) -> ^BufferPool ---
    buffer_pool_uninit :: proc(pool: ^^BufferPool) ---
    buffer_pool_get :: proc(pool: ^BufferPool) -> ^BufferRef ---
    buffer_pool_buffer_get_opaque :: proc(ref: ^BufferRef) -> rawptr ---

    // dict.h
    dict_get :: proc(m: ^Dictionary, key: cstring, prev: ^DictionaryEntry, flags: DictFlags) -> ^DictionaryEntry ---
    dict_iterate :: proc(m: ^Dictionary, prev: ^DictionaryEntry) -> ^DictionaryEntry ---
    dict_count :: proc(m: ^Dictionary) -> c.int ---
    dict_set :: proc(pm: ^^Dictionary, key, value: cstring, flags: DictFlags) -> c.int ---
    dict_set_int :: proc(pm: ^^Dictionary, key: cstring, value: c.int64_t, flags: DictFlags) -> c.int ---
    dict_parse_string :: proc(pm: ^^Dictionary, str, key_val_sep, pairs_sep: cstring, flags: DictFlags) -> c.int ---
    dict_copy :: proc(dst: ^^Dictionary, src: ^Dictionary, flags: DictFlags) -> c.int ---
    dict_free :: proc(m: ^^Dictionary) ---
    dict_get_string :: proc(m: ^Dictionary, buffer: ^cstring, key_val_sep, pairs_sep: c.char) -> c.int ---

    // channel_layout.h
    channel_name :: proc(buf: [^]c.char, buf_size: c.size_t, channel: Channel) -> c.int ---
    channel_description :: proc(buf: [^]c.char, buf_size: c.size_t, channel: Channel) -> c.int ---
    channel_from_string :: proc(name: cstring) -> Channel ---
    channel_layout_custom_init :: proc(channel_layout: ^ChannelLayout, nb_channels: c.int) -> c.int ---
    channel_layout_from_mask :: proc(channel_layout: ^ChannelLayout, mask: c.uint64_t) -> c.int ---
    channel_layout_from_string :: proc(channel_layout: ^ChannelLayout, str: cstring) -> c.int ---
    channel_layout_default :: proc(ch_layout: ^ChannelLayout, nb_channels: c.int) ---
    channel_layout_standard :: proc(opaque: ^rawptr) -> ^ChannelLayout ---
    channel_layout_uninit :: proc(channel_layout: ^ChannelLayout) ---
    channel_layout_copy :: proc(dst, src: ^ChannelLayout) -> c.int ---
    channel_layout_describe :: proc(channel_layout: ^ChannelLayout, buf: [^]c.char, buf_size: c.size_t) -> c.int ---
    channel_layout_index_from_channel :: proc(channel_layout: ^ChannelLayout, channel: Channel) -> c.int ---
    channel_layout_index_from_string :: proc(channel_layout: ^ChannelLayout, name: cstring) -> c.int ---
    channel_layout_channel_from_index :: proc(channel_layout: ^ChannelLayout, idx: c.uint) -> Channel ---
    channel_layout_channel_from_string :: proc(channel_layout: ^ChannelLayout, name: cstring) -> Channel ---
    channel_layout_subset :: proc(channel_layout: ^ChannelLayout, mask: c.uint64_t) -> c.uint64_t ---
    channel_layout_check :: proc(channel_layout: ^ChannelLayout) -> c.int ---
    channel_layout_compare :: proc(chl, chl1: ^ChannelLayout) -> c.int ---
    channel_layout_ambisonic_order :: proc(channel_layout: ^ChannelLayout) -> c.int ---

    // frame.h
    frame_alloc :: proc() -> ^Frame ---
    frame_free :: proc(frame: ^^Frame) ---
    frame_ref :: proc(dst, src: ^Frame) -> c.int ---
    frame_replace :: proc(dst, src: ^Frame) -> c.int ---
    frame_clone :: proc(src: ^Frame) -> ^Frame ---
    frame_unref :: proc(frame: ^Frame) ---
    frame_move_ref :: proc(dst, src: ^Frame) ---
    frame_get_buffer :: proc(frame: ^Frame, align: c.int) -> c.int ---
    frame_is_writable :: proc(frame: ^Frame) -> c.int ---
    frame_make_writable :: proc(frame: ^Frame) -> c.int ---
    frame_copy :: proc(dst, src: ^Frame) -> c.int ---
    frame_copy_props :: proc(dst, src: ^Frame) -> c.int ---
    frame_get_plane_buffer :: proc(frame: ^Frame, plane: c.int) -> ^BufferRef ---
    frame_new_side_data :: proc(frame: ^Frame, type_: FrameSideDataType, size: c.size_t) -> ^FrameSideData ---
    frame_new_side_data_from_buf :: proc(frame: ^Frame, type_: FrameSideDataType, buf: ^BufferRef) -> ^FrameSideData ---
    frame_get_side_data :: proc(frame: ^Frame, type_: FrameSideDataType) -> ^FrameSideData ---
    frame_remove_side_data :: proc(frame: ^Frame, type_: FrameSideDataType) ---
    frame_apply_cropping :: proc(frame: ^Frame, flags: c.int) -> c.int ---
    frame_side_data_name :: proc(type_: FrameSideDataType) -> cstring ---
    frame_side_data_desc :: proc(type_: FrameSideDataType) -> ^SideDataDescriptor ---
    get_pix_fmt_name :: proc(pix_fmt: PixelFormat) -> cstring ---
    get_pix_fmt :: proc(name: cstring) -> PixelFormat ---

    // Allocates an image buffer. Returns the size of the buffer on success, negative error on failure.
    // pointers and linesizes are filled; linesizes[0] buffer must be freed with av_freep(&pointers[0]).
    image_alloc :: proc(pointers: [^][^]u8, linesizes: [^]c.int, w, h: c.int, pix_fmt: PixelFormat, align: c.int) -> c.int ---

    // Return the size of the buffer needed for an image.
    image_get_buffer_size :: proc(pix_fmt: PixelFormat, width, height: c.int, align: c.int) -> c.int ---

    // Fill plane data pointers and linesizes for an image with known buffer.
    image_fill_arrays :: proc(dst_data: [^][^]u8, dst_linesize: [^]c.int, src: [^]u8, pix_fmt: PixelFormat, width, height: c.int, align: c.int) -> c.int ---
    malloc :: proc(size: c.size_t) -> rawptr ---
    mallocz :: proc(size: c.size_t) -> rawptr ---
    calloc :: proc(nmemb: c.size_t, size: c.size_t) -> rawptr ---
    realloc :: proc(ptr: rawptr, size: c.size_t) -> rawptr ---
    free :: proc(ptr: rawptr) ---

    // av_freep sets *ptr to NULL after freeing
    freep :: proc(ptr: rawptr) ---
    strdup :: proc(s: cstring) -> cstring ---
    strndup :: proc(s: cstring, len: c.size_t) -> cstring ---
    opt_set :: proc(obj: rawptr, name: cstring, val: cstring, search_flags: c.int) -> c.int ---
    opt_set_int :: proc(obj: rawptr, name: cstring, val: c.int64_t, search_flags: c.int) -> c.int ---
    opt_set_double :: proc(obj: rawptr, name: cstring, val: c.double, search_flags: c.int) -> c.int ---
    opt_set_q :: proc(obj: rawptr, name: cstring, val: Rational, search_flags: c.int) -> c.int ---
    opt_set_bin :: proc(obj: rawptr, name: cstring, val: [^]u8, size: c.int, search_flags: c.int) -> c.int ---
    opt_set_sample_fmt :: proc(obj: rawptr, name: cstring, fmt: SampleFormat, search_flags: c.int) -> c.int ---
    opt_set_pixel_fmt :: proc(obj: rawptr, name: cstring, fmt: PixelFormat, search_flags: c.int) -> c.int ---
    opt_set_chlayout :: proc(obj: rawptr, name: cstring, layout: ^ChannelLayout, search_flags: c.int) -> c.int ---

    // av_opt_set_array: set an array option (FFmpeg 7+)
    opt_set_array :: proc(obj: rawptr, name: cstring, search_flags: c.int, start_elem: c.uint, nb_elems: c.uint, elem_type: c.uint, elem_value: rawptr) -> c.int ---
    opt_get :: proc(obj: rawptr, name: cstring, search_flags: c.int, out_val: ^[^]u8) -> c.int ---
    usleep :: proc(usec: c.uint) -> c.int ---
    file_map :: proc(filename: cstring, bufptr: ^^u8, size: ^c.size_t, log_offset: c.int, log_ctx: rawptr) -> c.int ---
    file_unmap :: proc(bufptr: [^]u8, size: c.size_t) ---
    md5_alloc :: proc() -> ^MD5 ---
    md5_init :: proc(ctx: ^MD5) ---
    md5_update :: proc(ctx: ^MD5, src: [^]u8, len: c.size_t) ---
    md5_final :: proc(ctx: ^MD5, dst: [^]u8) ---
    md5_sum :: proc(dst: [^]u8, src: [^]u8, len: c.size_t) ---

    // Create a HW device context of the specified type.
    hwdevice_ctx_create :: proc(device_ctx: ^^BufferRef, type_: HWDeviceType, device: cstring, opts: ^Dictionary, flags: c.int) -> c.int ---

    // Transfer data from a HW frame to a SW frame.
    hwframe_transfer_data :: proc(dst: ^Frame, src: ^Frame, flags: c.int) -> c.int ---

    // Allocate an AVHWFramesContext tied to a given device context.
    hwframe_ctx_alloc :: proc(device_ctx: ^BufferRef) -> ^BufferRef ---

    // Finalize the context and allocate the frame pool.
    hwframe_ctx_init :: proc(ref: ^BufferRef) -> c.int ---

    // Allocate a new frame from the frame pool.
    hwframe_get_buffer :: proc(hwframe_ctx: ^BufferRef, frame: ^Frame, flags: c.int) -> c.int ---

    // Look up a device type by name.
    hwdevice_find_type_by_name :: proc(name: cstring) -> HWDeviceType ---

    // Iterate over available device types.
    hwdevice_iterate_types :: proc(prev: HWDeviceType) -> HWDeviceType ---

    // Get the name string for a device type.
    hwdevice_get_type_name :: proc(type_: HWDeviceType) -> cstring ---
    audio_fifo_alloc :: proc(sample_fmt: SampleFormat, channels, nb_samples: c.int) -> ^AudioFifo ---
    audio_fifo_free :: proc(af: ^AudioFifo) ---
    audio_fifo_realloc :: proc(af: ^AudioFifo, nb_samples: c.int) -> c.int ---
    audio_fifo_write :: proc(af: ^AudioFifo, data: rawptr, nb_samples: c.int) -> c.int ---
    audio_fifo_read :: proc(af: ^AudioFifo, data: rawptr, nb_samples: c.int) -> c.int ---
    audio_fifo_size :: proc(af: ^AudioFifo) -> c.int ---
    parse_video_size :: proc(width_ptr: ^c.int, height_ptr: ^c.int, str: cstring) -> c.int ---
    image_copy :: proc(dst_data: [^][^]u8, dst_linesizes: [^]c.int, src_data: [^][^]u8, src_linesizes: [^]c.int, pix_fmt: PixelFormat, width, height: c.int) ---
    malloc_array :: proc(nmemb: c.size_t, size: c.size_t) -> rawptr ---
    image_copy_to_buffer :: proc(dst: [^]u8, dst_size: c.int, src_data: [^][^]u8, src_linesize: [^]c.int, pix_fmt: PixelFormat, width, height, align: c.int) -> c.int ---
    opt_set_dict :: proc(obj: rawptr, options: ^^Dictionary) -> c.int ---
}


// ---------------------------------------------------------------------------
// Version helper
// ---------------------------------------------------------------------------

// av_version_int encodes major.minor.micro into a single integer.
av_version_int :: #force_inline proc "contextless" (a, b, c_: c.int) -> c.int {
    return (a << 16) | (b << 8) | c_
}

// av_inv_q is static-inline in rational.h — not an exported symbol.
inv_q :: #force_inline proc "contextless" (q: Rational) -> Rational {
    return {q.den, q.num}
}

// av_image_copy2 (FFmpeg 6+) is unavailable on older installs; inline it via image_copy.
image_copy2 :: #force_inline proc "c" (
    dst_data: [^][^]u8,
    dst_linesizes: [^]c.int,
    src_data: [^][^]u8,
    src_linesizes: [^]c.int,
    pix_fmt: PixelFormat,
    width, height: c.int,
) {
    image_copy(dst_data, dst_linesizes, src_data, src_linesizes, pix_fmt, width, height)
}
