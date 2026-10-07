package avcodec

import avutil "../avutil"
import "core:c"

LINK :: #config(FFMPEG_LINK, "system")

when ODIN_OS == .Windows {
    when ODIN_ARCH == .amd64 {
        when LINK == "static" {
            foreign import avcodec "../windows_x64/avcodec_static.lib"
        } else when LINK == "shared" {
            foreign import avcodec "../windows_x64/avcodec.lib"
        } else {
            foreign import avcodec "avcodec.lib"
        }
    } else when ODIN_ARCH == .arm64 {
        when LINK == "static" {
            foreign import avcodec "../windows_arm64/avcodec_static.lib"
        } else when LINK == "shared" {
            foreign import avcodec "../windows_arm64/avcodec.lib"
        } else {
            foreign import avcodec "avcodec.lib"
        }
    } else {
        #panic("This architecture is currently not supported on Windows")
    }
} else when ODIN_OS == .Darwin {
    when LINK == "static" {
        when ODIN_ARCH == .amd64 {
            // Extra system frameworks/libs required by static libavcodec.
            @(require) foreign import "system:AudioToolbox.framework"
            @(require) foreign import "system:VideoToolbox.framework"
            @(require) foreign import "system:CoreFoundation.framework"
            @(require) foreign import "system:CoreMedia.framework"
            @(require) foreign import "system:CoreVideo.framework"
            @(require) foreign import "system:CoreServices.framework"
            @(require) foreign import "system:bz2"
            @(require) foreign import "system:z"
            // Static libavcodec depends on swresample/swscale and avutil.
            @(require) foreign import _swr "../darwin_x64/libswresample.darwin.a"
            @(require) foreign import _sws "../darwin_x64/libswscale.darwin.a"
            @(require) foreign import _avu "../darwin_x64/libavutil.darwin.a"
            foreign import avcodec "../darwin_x64/libavcodec.darwin.a"
        } else when ODIN_ARCH == .arm64 {
            // Extra system frameworks/libs required by static libavcodec.
            @(require) foreign import "system:AudioToolbox.framework"
            @(require) foreign import "system:VideoToolbox.framework"
            @(require) foreign import "system:CoreFoundation.framework"
            @(require) foreign import "system:CoreMedia.framework"
            @(require) foreign import "system:CoreVideo.framework"
            @(require) foreign import "system:CoreServices.framework"
            @(require) foreign import "system:bz2"
            @(require) foreign import "system:z"
            // Static libavcodec depends on swresample/swscale and avutil.
            @(require) foreign import _swr "../darwin_arm64/libswresample.darwin.a"
            @(require) foreign import _sws "../darwin_arm64/libswscale.darwin.a"
            @(require) foreign import _avu "../darwin_arm64/libavutil.darwin.a"
            foreign import avcodec "../darwin_arm64/libavcodec.darwin.a"
        } else {
            #panic("This architecture is currently not supported on Darwin")
        }
    } else when LINK == "shared" {
        when ODIN_ARCH == .amd64 {
            foreign import avcodec "../darwin_x64/libavcodec.dylib"
        } else when ODIN_ARCH == .arm64 {
            foreign import avcodec "../darwin_arm64/libavcodec.dylib"
        } else {
            #panic("This architecture is currently not supported on Darwin")
        }
    } else {
        foreign import avcodec "system:avcodec"
    }
} else when ODIN_OS == .Linux {
    when LINK == "static" {
        when ODIN_ARCH == .amd64 {
            foreign import avcodec "../linux_x64/libavcodec.linux.a"
        } else when ODIN_ARCH == .arm64 {
            foreign import avcodec "../linux_arm64/libavcodec.linux.a"
        } else {
            #panic("This architecture is currently not supported on Linux")
        }
    } else when LINK == "shared" {
        when ODIN_ARCH == .amd64 {
            @(require) foreign import _swr "../linux_x64/libswresample.so"
            @(require) foreign import _avu "../linux_x64/libavutil.so"
            foreign import avcodec "../linux_x64/libavcodec.so"
        } else when ODIN_ARCH == .arm64 {
            @(require) foreign import _swr "../linux_arm64/libswresample.so"
            @(require) foreign import _avu "../linux_arm64/libavutil.so"
            foreign import avcodec "../linux_arm64/libavcodec.so"
        } else {
            #panic("This architecture is currently not supported on Linux")
        }
    } else {
        foreign import avcodec "system:avcodec"
    }
}

// ---------------------------------------------------------------------------
// avcodec — libavcodec bindings
// Sources: codec_id.h, defs.h, codec.h, codec_par.h, packet.h, avcodec.h, bsf.h
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// codec_id.h — AVCodecID enum
// ---------------------------------------------------------------------------

CodecID :: enum c.int {
    None = 0,

    // video
    Mpeg1Video,
    Mpeg2Video,
    H261,
    H263,
    Rv10,
    Rv20,
    Mjpeg,
    Mjpegb,
    Ljpeg,
    Sp5x,
    Jpegls,
    Mpeg4,
    Rawvideo,
    Msmpeg4v1,
    Msmpeg4v2,
    Msmpeg4v3,
    Wmv1,
    Wmv2,
    H263p,
    H263i,
    Flv1,
    Svq1,
    Svq3,
    Dvvideo,
    Huffyuv,
    Cyuv,
    H264,
    Indeo3,
    Vp3,
    Theora,
    Asv1,
    Asv2,
    Ffv1,
    Xm4,
    Vcr1,
    Cljr,
    Mdec,
    Roq,
    InterplayVideo,
    XanWc3,
    XanWc4,
    Rpza,
    Cinepak,
    WsVqa,
    Msrle,
    Msvideo1,
    Idcin,
    Bps8,
    Smc,
    Flic,
    Truemotion1,
    Vmdvideo,
    Mszh,
    Zlib,
    Qtrle,
    Tscc,
    Ulti,
    Qdraw,
    Vixl,
    Qpeg,
    Png,
    Ppm,
    Pbm,
    Pgm,
    Pgmyuv,
    Pam,
    Ffvhuff,
    Rv30,
    Rv40,
    Vc1,
    Wmv3,
    Loco,
    Wnv1,
    Aasc,
    Indeo2,
    Fraps,
    Truemotion2,
    Bmp,
    Cscd,
    Mmvideo,
    Zmbv,
    Avs,
    Smackvideo,
    Nuv,
    Kmvc,
    Flashsv,
    Cavs,
    Jpeg2000,
    Vmnc,
    Vp5,
    Vp6,
    Vp6f,
    Targa,
    Dsicinvideo,
    Tiertexseqvideo,
    Tiff,
    Gif,
    Dxa,
    Dnxhd,
    Thp,
    Sgi,
    C93,
    Bethsoftvid,
    Ptx,
    Txd,
    Vp6a,
    Amv,
    Vb,
    Pcx,
    Sunrast,
    Indeo4,
    Indeo5,
    Mimic,
    Rl2,
    Escape124,
    Dirac,
    Bfi,
    Cmv,
    Motionpixels,
    Tgv,
    Tgq,
    Tqi,
    Aura,
    Aura2,
    V210x,
    Tmv,
    V210,
    Dpx,
    Mad,
    Frwu,
    Flashsv2,
    Cdgraphics,
    R210,
    Anm,
    Binkvideo,
    IffIlbm,
    // IffByterun1 = IffIlbm, // alias
    Kgv1,
    Yop,
    Vp8,
    Pictor,
    Ansi,
    A64Multi,
    A64Multi5,
    R10k,
    Mxpeg,
    Lagarith,
    Prores,
    Jv,
    Dfa,
    Wmv3image,
    Vc1image,
    Utvideo,
    BmvVideo,
    Vble,
    Dxtory,
    Xwd,
    Cdxl,
    Xbm,
    Zerocodec,
    Mss1,
    Msa1,
    Tscc2,
    Mts2,
    Cllc,
    Mss2,
    Vp9,
    Aic,
    Escape130,
    G2m,
    Webp,
    Hnm4Video,
    Hevc,
    // H265 = Hevc, // alias
    Fic,
    AliasPix,
    BrenderPix,
    PafVideo,
    Exr,
    Vp7,
    Sanm,
    Sgirle,
    Mvc1,
    Mvc2,
    Hqx,
    Tdsc,
    HqHqa,
    Hap,
    Dds,
    Dxv,
    Screenpresso,
    Rscc,
    Avs2,
    Pgx,
    Avs3,
    Msp2,
    Vvc,
    // H266 = Vvc, // alias
    Y41p,
    Avrp,
    V012,
    Avui,
    TargaY216,
    Yuv4,
    Avrn,
    Cpia,
    Xface,
    Snow,
    Smvjpeg,
    Apng,
    Daala,
    Cfhd,
    Truemotion2rt,
    M101,
    Magicyuv,
    Sheervideo,
    Ylc,
    Psd,
    Pixlet,
    Speedhq,
    Fmvc,
    Scpr,
    Clearvideo,
    Xpm,
    Av1,
    Bitpacked,
    Mscc,
    Srgc,
    Svg,
    Gdv,
    Fits,
    Imm4,
    Prosumer,
    Mwsc,
    Wcmv,
    Rasc,
    Hymt,
    Arbc,
    Agm,
    Lscr,
    Vp4,
    Imm5,
    Mvdv,
    Mvha,
    Cdtoons,
    Mv30,
    Notchlc,
    Pfm,
    Mobiclip,
    Photocd,
    Ipu,
    Argo,
    Cri,
    SimbiosisImx,
    SgaVideo,
    Gem,
    Vbn,
    Jpegxl,
    Qoi,
    Phm,
    RadianceHdr,
    Wbmp,
    Media100,
    Vqc,
    Pdv,
    Evc,
    Rtv1,
    Vmix,
    Lead,
    Dnxuc,
    Rv60,
    JpegxlAnim,
    Apv,
    ProresRaw,
    Jpegxs,

    // PCM audio (0x10000 range)
    FirstAudio = 0x10000,
    PcmS16le = 0x10000,
    PcmS16be,
    PcmU16le,
    PcmU16be,
    PcmS8,
    PcmU8,
    PcmMulaw,
    PcmAlaw,
    PcmS32le,
    PcmS32be,
    PcmU32le,
    PcmU32be,
    PcmS24le,
    PcmS24be,
    PcmU24le,
    PcmU24be,
    PcmS24daud,
    PcmZork,
    PcmS16lePlanar,
    PcmDvd,
    PcmF32be,
    PcmF32le,
    PcmF64be,
    PcmF64le,
    PcmBluray,
    PcmLxf,
    S302m,
    PcmS8Planar,
    PcmS24lePlanar,
    PcmS32lePlanar,
    PcmS16bePlanar,
    PcmS64le,
    PcmS64be,
    PcmF16le,
    PcmF24le,
    PcmVidc,
    PcmSga,

    // ADPCM (0x11000 range)
    AdpcmImaQt = 0x11000,
    AdpcmImaWav,
    AdpcmImaDk3,
    AdpcmImaDk4,
    AdpcmImaWs,
    AdpcmImaSmjpeg,
    AdpcmMs,
    Adpcm4xm,
    AdpcmXa,
    AdpcmAdx,
    AdpcmEa,
    AdpcmG726,
    AdpcmCt,
    AdpcmSwf,
    AdpcmYamaha,
    AdpcmSbpro4,
    AdpcmSbpro3,
    AdpcmSbpro2,
    AdpcmThp,
    AdpcmImaAmv,
    AdpcmEaR1,
    AdpcmEaR3,
    AdpcmEaR2,
    AdpcmImaEaSead,
    AdpcmImaEaEacs,
    AdpcmEaXas,
    AdpcmEaMaxisXa,
    AdpcmImaIss,
    AdpcmG722,
    AdpcmImaApc,
    AdpcmVima,
    AdpcmAfc,
    AdpcmImaOki,
    AdpcmDtk,
    AdpcmImaRad,
    AdpcmG726le,
    AdpcmThpLe,
    AdpcmPsx,
    AdpcmAica,
    AdpcmImaDat4,
    AdpcmMtaf,
    AdpcmAgm,
    AdpcmArgo,
    AdpcmImasSsi,
    AdpcmZork,
    AdpcmImaApm,
    AdpcmImaAlp,
    AdpcmImaMtf,
    AdpcmImaCunning,
    AdpcmImaMoflex,
    AdpcmImaAcorn,
    AdpcmXmd,
    AdpcmImaXbox,
    AdpcmSanyo,
    AdpcmImaHvqm4,
    AdpcmImaPda,
    AdpcmN64,
    AdpcmImaHvqm2,
    AdpcmImaMagix,
    AdpcmPsxc,
    AdpcmCircus,
    AdpcmImaEscape,

    // AMR (0x12000 range)
    AmrNb = 0x12000,
    AmrWb,

    // RealAudio (0x13000 range)
    Ra144 = 0x13000,
    Ra288,

    // DPCM (0x14000 range)
    RoqDpcm = 0x14000,
    InterplayDpcm,
    XanDpcm,
    SolDpcm,
    Sdx2Dpcm,
    GremlinDpcm,
    DerfDpcm,
    WadyDpcm,
    Cbd2Dpcm,

    // Audio (0x15000 range)
    Mp2 = 0x15000,
    Mp3,
    Aac,
    Ac3,
    Dts,
    Vorbis,
    Dvaudio,
    Wmav1,
    Wmav2,
    Mace3,
    Mace6,
    Vmdaudio,
    Flac,
    Mp3adu,
    Mp3on4,
    Shorten,
    Alac,
    WestwoodSnd1,
    Gsm,
    Qdm2,
    Cook,
    Truespeech,
    Tta,
    Smackaudio,
    Qcelp,
    Wavpack,
    Dsicinaudio,
    Imc,
    Musepack7,
    Mlp,
    GsmMs,
    Atrac3,
    Ape,
    Nellymoser,
    Musepack8,
    Speex,
    Wmavoice,
    Wmapro,
    Wmalossless,
    Atrac3p,
    Eac3,
    Sipr,
    Mp1,
    Twinvq,
    Truehd,
    Mp4als,
    Atrac1,
    BinkaudioRdft,
    BinkaudioDct,
    AacLatm,
    Qdmc,
    Celt,
    G7231,
    G729,
    Svx8Exp,
    Svx8Fib,
    BmvAudio,
    Ralf,
    Iac,
    Ilbc,
    Opus,
    ComfortNoise,
    Tak,
    Metasound,
    PafAudio,
    On2avc,
    DssSp,
    Codec2,
    Ffwavesynth,
    Sonic,
    SonicLs,
    Evrc,
    Smv,
    DsdLsbf,
    DsdMsbf,
    DsdLsbfPlanar,
    DsdMsbfPlanar,
    Gv4,
    InterplayAcm,
    Xma1,
    Xma2,
    Dst,
    Atrac3al,
    Atrac3pal,
    DolbyE,
    Aptx,
    AptxHd,
    Sbc,
    Atrac9,
    Hcom,
    AccelpKelvin,
    Mpegh3dAudio,
    Siren,
    Hca,
    Fastaudio,
    Msnsiren,
    Dfpwm,
    Bonk,
    Misc4,
    Apac,
    Ftr,
    Wavarc,
    Rka,
    Ac4,
    Osq,
    Qoa,
    Lc3,
    G728,
    Ahx,

    // Subtitles (0x17000 range)
    FirstSubtitle = 0x17000,
    DvdSubtitle = 0x17000,
    DvbSubtitle,
    Text,
    Xsub,
    Ssa,
    MovText,
    HdmvPgsSubtitle,
    DvbTeletext,
    Srt,
    Microdvd,
    Eia608,
    Jacosub,
    Sami,
    Realtext,
    Stl,
    Subviewer1,
    Subviewer,
    Subrip,
    Webvtt,
    Mpl2,
    Vplayer,
    Pjs,
    Ass,
    HdmvTextSubtitle,
    Ttml,
    AribCaption,
    IvtvVbi,

    // Other / attachment (0x18000 range)
    FirstUnknown = 0x18000,
    Ttf = 0x18000,
    Scte35,
    Epg,
    Bintext,
    Xbin,
    Idf,
    Otf,
    SmpteKlv,
    DvdNav,
    TimedId3,
    BinData,
    Smpte2038,
    Lcevc,
    Smpte436mAnc,

    // Special
    Probe = 0x19000,
    Mpeg2ts = 0x20000,
    Mpeg4systems = 0x20001,
    Ffmetadata = 0x21000,
    WrappedAvframe = 0x21001,
    Vnull,
    Anull,
}

// ---------------------------------------------------------------------------
// defs.h — misc types and constants
// ---------------------------------------------------------------------------

AV_INPUT_BUFFER_PADDING_SIZE :: 64

// Error flags (AV_EF_*)
ErrFlag :: enum c.int {
    CRC_Check  = 0,
    Bitstream  = 1,
    Buffer     = 2,
    Explode    = 3,
    Ignore_Err = 15,
    Careful    = 16,
    Compliant  = 17,
    Aggressive = 18,
}
ErrFlags :: distinct bit_set[ErrFlag;c.int]

// Compliance constants
FF_COMPLIANCE_VERY_STRICT :: 2
FF_COMPLIANCE_STRICT :: 1
FF_COMPLIANCE_NORMAL :: 0
FF_COMPLIANCE_UNOFFICIAL :: -1
FF_COMPLIANCE_EXPERIMENTAL :: -2

// Profile constants (subset of most common)
AV_PROFILE_UNKNOWN :: -99
AV_PROFILE_RESERVED :: -100
AV_LEVEL_UNKNOWN :: -99

// H.264 profiles
AV_PROFILE_H264_BASELINE :: 66
AV_PROFILE_H264_CONSTRAINED_BASELINE :: 66 | (1 << 9)
AV_PROFILE_H264_MAIN :: 77
AV_PROFILE_H264_EXTENDED :: 88
AV_PROFILE_H264_HIGH :: 100
AV_PROFILE_H264_HIGH_10 :: 110
AV_PROFILE_H264_HIGH_422 :: 122
AV_PROFILE_H264_HIGH_444_PREDICTIVE :: 244

// HEVC profiles
AV_PROFILE_HEVC_MAIN :: 1
AV_PROFILE_HEVC_MAIN_10 :: 2
AV_PROFILE_HEVC_MAIN_STILL_PICTURE :: 3
AV_PROFILE_HEVC_REXT :: 4
AV_PROFILE_HEVC_SCC :: 9

// VVC profiles
AV_PROFILE_VVC_MAIN_10 :: 1
AV_PROFILE_VVC_MAIN_10_444 :: 33

// AV1 profiles
AV_PROFILE_AV1_MAIN :: 0
AV_PROFILE_AV1_HIGH :: 1
AV_PROFILE_AV1_PROFESSIONAL :: 2

// AAC profiles
AV_PROFILE_AAC_MAIN :: 0
AV_PROFILE_AAC_LOW :: 1
AV_PROFILE_AAC_HE :: 4

// VP9 profiles
AV_PROFILE_VP9_0 :: 0
AV_PROFILE_VP9_1 :: 1
AV_PROFILE_VP9_2 :: 2
AV_PROFILE_VP9_3 :: 3

// ProRes profiles
AV_PROFILE_PRORES_PROXY :: 0
AV_PROFILE_PRORES_LT :: 1
AV_PROFILE_PRORES_STANDARD :: 2
AV_PROFILE_PRORES_HQ :: 3
AV_PROFILE_PRORES_4444 :: 4
AV_PROFILE_PRORES_XQ :: 5

FieldOrder :: enum c.int {
    Unknown,
    Progressive,
    TT,
    BB,
    TB,
    BT,
}

Discard :: enum c.int {
    None     = -16,
    Default  = 0,
    Nonref   = 8,
    Bidir    = 16,
    Nonintra = 24,
    Nonkey   = 32,
    All      = 48,
}

AudioServiceType :: enum c.int {
    Main = 0,
    Effects = 1,
    VisuallyImpaired = 2,
    HearingImpaired = 3,
    Dialogue = 4,
    Commentary = 5,
    Emergency = 6,
    VoiceOver = 7,
    Karaoke = 8,
    NB,
}

PanScan :: struct {
    id:       c.int,
    width:    c.int,
    height:   c.int,
    position: [3][2]c.int16_t,
}

CPBProperties :: struct {
    max_bitrate: c.int64_t,
    min_bitrate: c.int64_t,
    avg_bitrate: c.int64_t,
    buffer_size: c.int64_t,
    vbv_delay:   c.uint64_t,
}

ProducerReferenceTime :: struct {
    wallclock: c.int64_t,
    flags:     c.int,
}

RTCPSenderReport :: struct {
    ssrc:              c.uint32_t,
    ntp_timestamp:     c.uint64_t,
    rtp_timestamp:     c.uint32_t,
    sender_nb_packets: c.uint32_t,
    sender_nb_bytes:   c.uint32_t,
}

// ---------------------------------------------------------------------------
// packet.h — AVPacketSideDataType, AVPacketSideData, AVPacket
// ---------------------------------------------------------------------------

PacketSideDataType :: enum c.int {
    Palette,
    NewExtradata,
    ParamChange,
    H263MbInfo,
    Replaygain,
    Displaymatrix,
    Stereo3d,
    AudioServiceType,
    QualityStats,
    FallbackTrack,
    CpbProperties,
    SkipSamples,
    JpDualmono,
    StringsMetadata,
    SubtitlePosition,
    MatroskaBlockadditional,
    WebvttIdentifier,
    WebvttSettings,
    MetadataUpdate,
    MpegtsStreamId,
    MasteringDisplayMetadata,
    Spherical,
    ContentLightLevel,
    A53Cc,
    EncryptionInitInfo,
    EncryptionInfo,
    Afd,
    Prft,
    IccProfile,
    DoviConf,
    S12mTimecode,
    DynamicHdr10Plus,
    IamfMixGainParam,
    IamfDemixingInfoParam,
    IamfReconGainInfoParam,
    AmbientViewingEnvironment,
    FrameCropping,
    Lcevc,
    ThreeDReferenceDisplays,
    RtcpSr,
    Exif,
    NB,
}

PacketSideData :: struct {
    data: [^]u8,
    size: c.size_t,
    type: PacketSideDataType,
}

Packet :: struct {
    buf:             ^avutil.BufferRef,
    pts:             c.int64_t,
    dts:             c.int64_t,
    data:            [^]u8,
    size:            c.int,
    stream_index:    c.int,
    flags:           PacketFlags,
    side_data:       ^PacketSideData,
    side_data_elems: c.int,
    duration:        c.int64_t,
    pos:             c.int64_t,
    opaque:          rawptr,
    opaque_ref:      ^avutil.BufferRef,
    time_base:       avutil.Rational,
}

SideDataParamChangeFlag :: enum c.int {
    SampleRate = 0x0004,
    Dimensions = 0x0008,
}
SideDataParamChangeFlags :: distinct bit_set[SideDataParamChangeFlag;c.int]

// Packet flags
PacketFlag :: enum c.int {
    Key        = 0,
    Corrupt    = 1,
    Discard    = 2,
    Trusted    = 3,
    Disposable = 4,
}
PacketFlags :: distinct bit_set[PacketFlag;c.int]

// ---------------------------------------------------------------------------
// codec.h — AVCodec capabilities and struct
// ---------------------------------------------------------------------------

// Codec capability flags
CodecCap :: enum c.int {
    Draw_Horiz_Band          = 0,
    DR1                      = 1,
    Delay                    = 5,
    Small_Last_Frame         = 6,
    Experimental             = 9,
    Channel_Conf             = 10,
    Frame_Threads            = 12,
    Slice_Threads            = 13,
    Param_Change             = 14,
    Other_Threads            = 15,
    Variable_Frame_Size      = 16,
    Avoid_Probing            = 17,
    Hardware                 = 18,
    Hybrid                   = 19,
    Encoder_Reordered_Opaque = 20,
    Encoder_Flush            = 21,
    Encoder_Recon_Frame      = 22,
}
CodecCaps :: distinct bit_set[CodecCap;c.int]

// HW config methods
HWConfigMethod :: enum c.int {
    HW_Device_Ctx = 0,
    HW_Frames_Ctx = 1,
    Internal      = 2,
    Ad_Hoc        = 3,
}
HWConfigMethods :: distinct bit_set[HWConfigMethod;c.int]

Profile :: struct {
    profile: c.int,
    name:    cstring,
}

Codec :: struct {
    name:                  cstring,
    long_name:             cstring,
    type:                  avutil.MediaType,
    id:                    CodecID,
    capabilities:          CodecCaps,
    max_lowres:            u8,
    supported_framerates:  ^avutil.Rational, // deprecated
    pix_fmts:              ^avutil.PixelFormat, // deprecated
    supported_samplerates: ^c.int, // deprecated
    sample_fmts:           ^avutil.SampleFormat, // deprecated
    priv_class:            ^avutil.Class,
    profiles:              ^Profile,
    wrapper_name:          cstring,
    ch_layouts:            ^avutil.ChannelLayout, // deprecated
}

CodecHWConfig :: struct {
    pix_fmt:     avutil.PixelFormat,
    methods:     HWConfigMethods,
    device_type: avutil.HWDeviceType,
}

// ---------------------------------------------------------------------------
// codec_par.h — AVCodecParameters
// ---------------------------------------------------------------------------

CodecParameters :: struct {
    codec_type:            avutil.MediaType,
    codec_id:              CodecID,
    codec_tag:             c.uint32_t,
    extradata:             [^]u8,
    extradata_size:        c.int,
    coded_side_data:       ^PacketSideData,
    nb_coded_side_data:    c.int,
    format:                c.int,
    bit_rate:              c.int64_t,
    bits_per_coded_sample: c.int,
    bits_per_raw_sample:   c.int,
    profile:               c.int,
    level:                 c.int,
    width:                 c.int,
    height:                c.int,
    sample_aspect_ratio:   avutil.Rational,
    framerate:             avutil.Rational,
    field_order:           FieldOrder,
    color_range:           avutil.ColorRange,
    color_primaries:       avutil.ColorPrimaries,
    color_trc:             avutil.ColorTransferCharacteristic,
    color_space:           avutil.ColorSpace,
    chroma_location:       avutil.ChromaLocation,
    video_delay:           c.int,
    ch_layout:             avutil.ChannelLayout,
    sample_rate:           c.int,
    block_align:           c.int,
    frame_size:            c.int,
    initial_padding:       c.int,
    trailing_padding:      c.int,
    seek_preroll:          c.int,
    alpha_mode:            avutil.AlphaMode,
}

// ---------------------------------------------------------------------------
// avcodec.h — flags, AVCodecContext, AVHWAccel, subtitles, parser
// ---------------------------------------------------------------------------

RcOverride :: struct {
    start_frame:    c.int,
    end_frame:      c.int,
    qscale:         c.int,
    quality_factor: c.float,
}

// Codec flags (AV_CODEC_FLAG_*)
CodecFlag :: enum c.uint {
    Unaligned      = 0,
    Qscale         = 1,
    _4MV           = 2,
    Output_Corrupt = 3,
    Qpel           = 4,
    Recon_Frame    = 6,
    Copy_Opaque    = 7,
    Frame_Duration = 8,
    Pass1          = 9,
    Pass2          = 10,
    Loop_Filter    = 11,
    Gray           = 13,
    PSNR           = 15,
    Interlaced_DCT = 18,
    Low_Delay      = 19,
    Global_Header  = 22,
    Bitexact       = 23,
    AC_Pred        = 24,
    Interlaced_ME  = 29,
    Closed_GOP     = 31,
}
CodecFlags :: distinct bit_set[CodecFlag;c.uint]

// Codec flags2 (AV_CODEC_FLAG2_*)
CodecFlag2 :: enum c.uint {
    Fast          = 0,
    No_Output     = 2,
    Local_Header  = 3,
    Chunks        = 15,
    Ignore_Crop   = 16,
    Show_All      = 22,
    Export_MVS    = 28,
    Skip_Manual   = 29,
    RO_Flush_Noop = 30,
    ICC_Profiles  = 31,
}
CodecFlags2 :: distinct bit_set[CodecFlag2;c.uint]

// Export side data flags
ExportDataFlag :: enum c.int {
    MVS              = 0,
    PRFT             = 1,
    Video_Enc_Params = 2,
    Film_Grain       = 3,
    Enhancements     = 4,
}
ExportDataFlags :: distinct bit_set[ExportDataFlag;c.int]

// Buffer flags (get_buffer2 / get_encode_buffer callbacks)
GetBufferFlag :: enum c.int {
    Ref = 0,
}
GetBufferFlags :: distinct bit_set[GetBufferFlag;c.int]
AV_CODEC_RECEIVE_FRAME_FLAG_SYNCHRONOUS :: 1 << 0

// Motion estimation compare functions
// CMP_CHROMA (256) is a modifier OR'd with the function; keep as plain constant.
CmpFunc :: enum c.int {
    SAD        = 0,
    SSE        = 1,
    SATD       = 2,
    DCT        = 3,
    PSNR       = 4,
    BIT        = 5,
    RD         = 6,
    ZERO       = 7,
    VSAD       = 8,
    VSSE       = 9,
    NSSE       = 10,
    W53        = 11,
    W97        = 12,
    DCTMax     = 13,
    DCT264     = 14,
    Median_SAD = 15,
}
CMP_CHROMA :: 256

// Macroblock decision mode
MBDecision :: enum c.int {
    Simple = 0,
    Bits   = 1,
    RD     = 2,
}

// Thread types (OR-able)
ThreadType :: enum c.int {
    Frame = 0,
    Slice = 1,
}
ThreadTypes :: distinct bit_set[ThreadType;c.int]

// HWAccel flags
HWAccelFlag :: enum c.int {
    Ignore_Level           = 0,
    Allow_High_Depth       = 1,
    Allow_Profile_Mismatch = 2,
    Unsafe_Output          = 3,
}
HWAccelFlags :: distinct bit_set[HWAccelFlag;c.int]
HWACCEL_CODEC_CAP_EXPERIMENTAL :: 0x0200

// Opaque internal codec type
CodecInternal :: struct {}
CodecDescriptor :: struct {} // defined in codec_desc.h
HWAccel_Rec :: struct {}

CodecContext :: struct {
    av_class:                    ^avutil.Class,
    log_level_offset:            c.int,
    codec_type:                  avutil.MediaType,
    codec:                       ^Codec,
    codec_id:                    CodecID,
    codec_tag:                   c.uint,
    priv_data:                   rawptr,
    internal:                    ^CodecInternal,
    opaque:                      rawptr,
    bit_rate:                    c.int64_t,
    flags:                       CodecFlags,
    flags2:                      CodecFlags2,
    extradata:                   [^]u8,
    extradata_size:              c.int,
    time_base:                   avutil.Rational,
    pkt_timebase:                avutil.Rational,
    framerate:                   avutil.Rational,
    delay:                       c.int,
    width:                       c.int,
    height:                      c.int,
    coded_width:                 c.int,
    coded_height:                c.int,
    sample_aspect_ratio:         avutil.Rational,
    pix_fmt:                     avutil.PixelFormat,
    sw_pix_fmt:                  avutil.PixelFormat,
    color_primaries:             avutil.ColorPrimaries,
    color_trc:                   avutil.ColorTransferCharacteristic,
    colorspace:                  avutil.ColorSpace,
    color_range:                 avutil.ColorRange,
    chroma_sample_location:      avutil.ChromaLocation,
    field_order:                 FieldOrder,
    refs:                        c.int,
    has_b_frames:                c.int,
    slice_flags:                 c.int,
    draw_horiz_band:             #type proc "c" (
        s: ^CodecContext,
        src: ^avutil.Frame,
        offset: [8]c.int,
        y, type, height: c.int,
    ),
    get_format:                  #type proc "c" (s: ^CodecContext, fmt: ^avutil.PixelFormat) -> avutil.PixelFormat,
    max_b_frames:                c.int,
    b_quant_factor:              c.float,
    b_quant_offset:              c.float,
    i_quant_factor:              c.float,
    i_quant_offset:              c.float,
    lumi_masking:                c.float,
    temporal_cplx_masking:       c.float,
    spatial_cplx_masking:        c.float,
    p_masking:                   c.float,
    dark_masking:                c.float,
    nsse_weight:                 c.int,
    me_cmp:                      CmpFunc,
    me_sub_cmp:                  CmpFunc,
    mb_cmp:                      CmpFunc,
    ildct_cmp:                   CmpFunc,
    dia_size:                    c.int,
    last_predictor_count:        c.int,
    me_pre_cmp:                  CmpFunc,
    pre_dia_size:                c.int,
    me_subpel_quality:           c.int,
    me_range:                    c.int,
    mb_decision:                 MBDecision,
    intra_matrix:                ^c.uint16_t,
    inter_matrix:                ^c.uint16_t,
    chroma_intra_matrix:         ^c.uint16_t,
    intra_dc_precision:          c.int,
    mb_lmin:                     c.int,
    mb_lmax:                     c.int,
    bidir_refine:                c.int,
    keyint_min:                  c.int,
    gop_size:                    c.int,
    mv0_threshold:               c.int,
    slices:                      c.int,
    sample_rate:                 c.int,
    sample_fmt:                  avutil.SampleFormat,
    ch_layout:                   avutil.ChannelLayout,
    frame_size:                  c.int,
    block_align:                 c.int,
    cutoff:                      c.int,
    audio_service_type:          AudioServiceType,
    request_sample_fmt:          avutil.SampleFormat,
    initial_padding:             c.int,
    trailing_padding:            c.int,
    seek_preroll:                c.int,
    get_buffer2:                 #type proc "c" (
        s: ^CodecContext,
        frame: ^avutil.Frame,
        flags: GetBufferFlags,
    ) -> c.int,
    bit_rate_tolerance:          c.int,
    global_quality:              c.int,
    compression_level:           c.int,
    qcompress:                   c.float,
    qblur:                       c.float,
    qmin:                        c.int,
    qmax:                        c.int,
    max_qdiff:                   c.int,
    rc_buffer_size:              c.int,
    rc_override_count:           c.int,
    rc_override:                 ^RcOverride,
    rc_max_rate:                 c.int64_t,
    rc_min_rate:                 c.int64_t,
    rc_max_available_vbv_use:    c.float,
    rc_min_vbv_overflow_use:     c.float,
    rc_initial_buffer_occupancy: c.int,
    trellis:                     c.int,
    stats_out:                   cstring,
    stats_in:                    cstring,
    workaround_bugs:             c.int,
    strict_std_compliance:       c.int,
    error_concealment:           c.int,
    debug:                       c.int,
    err_recognition:             ErrFlags,
    hwaccel:                     ^HWAccel_Rec,
    hwaccel_context:             rawptr,
    hw_frames_ctx:               ^avutil.BufferRef,
    hw_device_ctx:               ^avutil.BufferRef,
    hwaccel_flags:               HWAccelFlags,
    extra_hw_frames:             c.int,
    error:                       [8]c.uint64_t,
    dct_algo:                    c.int,
    idct_algo:                   c.int,
    bits_per_coded_sample:       c.int,
    bits_per_raw_sample:         c.int,
    thread_count:                c.int,
    thread_type:                 ThreadTypes,
    active_thread_type:          ThreadTypes,
    execute:                     #type proc "c" (
        c_: ^CodecContext,
        func: #type proc "c" (c2: ^CodecContext, arg: rawptr) -> c.int,
        arg2: rawptr,
        ret: ^c.int,
        count, size: c.int,
    ) -> c.int,
    execute2:                    #type proc "c" (
        c_: ^CodecContext,
        func: #type proc "c" (c2: ^CodecContext, arg: rawptr, jobnr, threadnr: c.int) -> c.int,
        arg2: rawptr,
        ret: ^c.int,
        count: c.int,
    ) -> c.int,
    profile:                     c.int,
    level:                       c.int,
    properties:                  c.uint, // deprecated
    skip_loop_filter:            Discard,
    skip_idct:                   Discard,
    skip_frame:                  Discard,
    skip_alpha:                  c.int,
    skip_top:                    c.int,
    skip_bottom:                 c.int,
    lowres:                      c.int,
    codec_descriptor:            ^CodecDescriptor,
    sub_charenc:                 cstring,
    sub_charenc_mode:            c.int,
    subtitle_header_size:        c.int,
    subtitle_header:             [^]u8,
    dump_separator:              [^]u8,
    codec_whitelist:             cstring,
    coded_side_data:             ^PacketSideData,
    nb_coded_side_data:          c.int,
    export_side_data:            ExportDataFlags,
    max_pixels:                  c.int64_t,
    apply_cropping:              c.int,
    discard_damaged_percentage:  c.int,
    max_samples:                 c.int64_t,
    get_encode_buffer:           #type proc "c" (s: ^CodecContext, pkt: ^Packet, flags: c.int) -> c.int,
    frame_num:                   c.int64_t,
    side_data_prefer_packet:     ^c.int,
    nb_side_data_prefer_packet:  c.uint,
    decoded_side_data:           ^^avutil.FrameSideData,
    nb_decoded_side_data:        c.int,
    alpha_mode:                  avutil.AlphaMode,
}

HWAccel :: struct {
    name:         cstring,
    type:         avutil.MediaType,
    id:           CodecID,
    pix_fmt:      avutil.PixelFormat,
    capabilities: c.int,
}

SubtitleType :: enum c.int {
    None,
    Bitmap,
    Text,
    Ass,
}

AV_SUBTITLE_FLAG_FORCED :: 0x00000001

SubtitleRect :: struct {
    x:         c.int,
    y:         c.int,
    w:         c.int,
    h:         c.int,
    nb_colors: c.int,
    data:      [4][^]u8,
    linesize:  [4]c.int,
    flags:     c.int,
    type:      SubtitleType,
    text:      cstring,
    ass:       cstring,
}

Subtitle :: struct {
    format:             c.uint16_t,
    start_display_time: c.uint32_t,
    end_display_time:   c.uint32_t,
    num_rects:          c.uint,
    rects:              ^^SubtitleRect,
    pts:                c.int64_t,
}

CodecConfig :: enum c.int {
    PixFormat,
    FrameRate,
    SampleRate,
    SampleFormat,
    ChannelLayout,
    ColorRange,
    ColorSpace,
    AlphaMode,
}

PictureStructure :: enum c.int {
    Unknown,
    TopField,
    BottomField,
    Frame,
}

AV_PARSER_PTS_NB :: 4

CodecParserContext :: struct {
    priv_data:             rawptr,
    parser:                ^CodecParser,
    frame_offset:          c.int64_t,
    cur_offset:            c.int64_t,
    next_frame_offset:     c.int64_t,
    pict_type:             c.int,
    repeat_pict:           c.int,
    pts:                   c.int64_t,
    dts:                   c.int64_t,
    last_pts:              c.int64_t,
    last_dts:              c.int64_t,
    fetch_timestamp:       c.int,
    cur_frame_start_index: c.int,
    cur_frame_offset:      [AV_PARSER_PTS_NB]c.int64_t,
    cur_frame_pts:         [AV_PARSER_PTS_NB]c.int64_t,
    cur_frame_dts:         [AV_PARSER_PTS_NB]c.int64_t,
    flags:                 c.int,
    offset:                c.int64_t,
    cur_frame_end:         [AV_PARSER_PTS_NB]c.int64_t,
    key_frame:             c.int,
    dts_sync_point:        c.int,
    dts_ref_dts_delta:     c.int,
    pts_dts_delta:         c.int,
    cur_frame_pos:         [AV_PARSER_PTS_NB]c.int64_t,
    pos:                   c.int64_t,
    last_pos:              c.int64_t,
    duration:              c.int,
    field_order:           FieldOrder,
    picture_structure:     PictureStructure,
    output_picture_number: c.int,
    width:                 c.int,
    height:                c.int,
    coded_width:           c.int,
    coded_height:          c.int,
    format:                c.int,
}

CodecParser :: struct {
    codec_ids: [7]CodecID,
    // private fields omitted (deprecated)
}

// ---------------------------------------------------------------------------
// bsf.h — AVBSFContext, AVBitStreamFilter, AVBSFList
// ---------------------------------------------------------------------------

BitStreamFilter :: struct {
    name:       cstring,
    codec_ids:  ^CodecID,
    priv_class: ^avutil.Class,
}

BSFContext :: struct {
    av_class:      ^avutil.Class,
    filter:        ^BitStreamFilter,
    priv_data:     rawptr,
    par_in:        ^CodecParameters,
    par_out:       ^CodecParameters,
    time_base_in:  avutil.Rational,
    time_base_out: avutil.Rational,
}

BSFList :: struct {} // opaque

// ---------------------------------------------------------------------------
// Foreign function declarations
// ---------------------------------------------------------------------------

@(link_prefix = "avcodec_", default_calling_convention = "c")
foreign avcodec {
    // -------------------------------------------------------------------------
    // codec_id.h functions
    // -------------------------------------------------------------------------
    get_type :: proc(codec_id: CodecID) -> avutil.MediaType ---
    get_name :: proc(id: CodecID) -> cstring ---
    profile_name :: proc(codec_id: CodecID, profile: c.int) -> cstring ---
    find_decoder :: proc(id: CodecID) -> ^Codec ---
    find_decoder_by_name :: proc(name: cstring) -> ^Codec ---
    find_encoder :: proc(id: CodecID) -> ^Codec ---
    find_encoder_by_name :: proc(name: cstring) -> ^Codec ---
    get_hw_config :: proc(codec: ^Codec, index: c.int) -> ^CodecHWConfig ---

    // -------------------------------------------------------------------------
    // codec_par.h functions
    // -------------------------------------------------------------------------
    parameters_alloc :: proc() -> ^CodecParameters ---
    parameters_free :: proc(par: ^^CodecParameters) ---
    parameters_copy :: proc(dst, src: ^CodecParameters) -> c.int ---

    // -------------------------------------------------------------------------
    // avcodec.h functions
    // -------------------------------------------------------------------------
    version :: proc() -> c.uint ---
    configuration :: proc() -> cstring ---
    license :: proc() -> cstring ---
    alloc_context3 :: proc(codec: ^Codec) -> ^CodecContext ---
    free_context :: proc(avctx: ^^CodecContext) ---
    get_class :: proc() -> ^avutil.Class ---
    get_subtitle_rect_class :: proc() -> ^avutil.Class ---
    parameters_from_context :: proc(par: ^CodecParameters, codec: ^CodecContext) -> c.int ---
    parameters_to_context :: proc(codec: ^CodecContext, par: ^CodecParameters) -> c.int ---
    open2 :: proc(avctx: ^CodecContext, codec: ^Codec, options: ^^avutil.Dictionary) -> c.int ---
    @(link_name = "avsubtitle_free")
    subtitle_free :: proc(sub: ^Subtitle) ---
    default_get_buffer2 :: proc(s: ^CodecContext, frame: ^avutil.Frame, flags: c.int) -> c.int ---
    default_get_encode_buffer :: proc(s: ^CodecContext, pkt: ^Packet, flags: c.int) -> c.int ---
    align_dimensions :: proc(s: ^CodecContext, width, height: ^c.int) ---
    align_dimensions2 :: proc(s: ^CodecContext, width, height: ^c.int, linesize_align: ^[8]c.int) ---
    decode_subtitle2 :: proc(avctx: ^CodecContext, sub: ^Subtitle, got_sub_ptr: ^c.int, avpkt: ^Packet) -> c.int ---
    send_packet :: proc(avctx: ^CodecContext, avpkt: ^Packet) -> c.int ---
    receive_frame :: proc(avctx: ^CodecContext, frame: ^avutil.Frame) -> c.int ---
    receive_frame_flags :: proc(avctx: ^CodecContext, frame: ^avutil.Frame, flags: c.uint) -> c.int ---
    send_frame :: proc(avctx: ^CodecContext, frame: ^avutil.Frame) -> c.int ---
    receive_packet :: proc(avctx: ^CodecContext, avpkt: ^Packet) -> c.int ---
    get_hw_frames_parameters :: proc(avctx: ^CodecContext, device_ref: ^avutil.BufferRef, hw_pix_fmt: avutil.PixelFormat, out_frames_ref: ^^avutil.BufferRef) -> c.int ---
    get_supported_config :: proc(avctx: ^CodecContext, codec: ^Codec, config: CodecConfig, flags: c.uint, out_configs: ^rawptr, out_num_configs: ^c.int) -> c.int ---
    pix_fmt_to_codec_tag :: proc(pix_fmt: avutil.PixelFormat) -> c.uint ---
    find_best_pix_fmt_of_list :: proc(pix_fmt_list: ^avutil.PixelFormat, src_pix_fmt: avutil.PixelFormat, has_alpha: c.int, loss_ptr: ^c.int) -> avutil.PixelFormat ---
    default_get_format :: proc(s: ^CodecContext, fmt: ^avutil.PixelFormat) -> avutil.PixelFormat ---
    string :: proc(buf: cstring, buf_size: c.int, enc: ^CodecContext, encode: c.int) ---
    fill_audio_frame :: proc(frame: ^avutil.Frame, nb_channels: c.int, sample_fmt: avutil.SampleFormat, buf: [^]u8, buf_size, align: c.int) -> c.int ---
    flush_buffers :: proc(avctx: ^CodecContext) ---
    is_open :: proc(s: ^CodecContext) -> c.int ---
    encode_subtitle :: proc(avctx: ^CodecContext, buf: [^]u8, buf_size: c.int, sub: ^Subtitle) -> c.int ---
}

@(link_prefix = "av_", default_calling_convention = "c")
foreign avcodec {
    get_bits_per_sample :: proc(codec_id: CodecID) -> c.int ---
    get_exact_bits_per_sample :: proc(codec_id: CodecID) -> c.int ---
    get_pcm_codec :: proc(fmt: avutil.SampleFormat, be: c.int) -> CodecID ---

    // -------------------------------------------------------------------------
    // defs.h functions
    // -------------------------------------------------------------------------
    cpb_properties_alloc :: proc(size: ^c.size_t) -> ^CPBProperties ---
    xiphlacing :: proc(s: [^]u8, v: c.uint) -> c.uint ---

    // -------------------------------------------------------------------------
    // codec.h functions
    // -------------------------------------------------------------------------
    codec_iterate :: proc(opaque: ^rawptr) -> ^Codec ---
    codec_is_encoder :: proc(codec: ^Codec) -> c.int ---
    codec_is_decoder :: proc(codec: ^Codec) -> c.int ---
    get_profile_name :: proc(codec: ^Codec, profile: c.int) -> cstring ---
    get_audio_frame_duration2 :: proc(par: ^CodecParameters, frame_bytes: c.int) -> c.int ---

    // -------------------------------------------------------------------------
    // packet.h functions
    // -------------------------------------------------------------------------
    packet_side_data_new :: proc(psd: ^^PacketSideData, pnb_sd: ^c.int, type: PacketSideDataType, size: c.size_t, flags: c.int) -> ^PacketSideData ---
    packet_side_data_add :: proc(sd: ^^PacketSideData, nb_sd: ^c.int, type: PacketSideDataType, data: rawptr, size: c.size_t, flags: c.int) -> ^PacketSideData ---
    packet_side_data_get :: proc(sd: ^PacketSideData, nb_sd: c.int, type: PacketSideDataType) -> ^PacketSideData ---
    packet_side_data_remove :: proc(sd: ^PacketSideData, nb_sd: ^c.int, type: PacketSideDataType) ---
    packet_side_data_free :: proc(sd: ^^PacketSideData, nb_sd: ^c.int) ---
    packet_side_data_name :: proc(type: PacketSideDataType) -> cstring ---
    packet_alloc :: proc() -> ^Packet ---
    packet_clone :: proc(src: ^Packet) -> ^Packet ---
    packet_free :: proc(pkt: ^^Packet) ---
    new_packet :: proc(pkt: ^Packet, size: c.int) -> c.int ---
    shrink_packet :: proc(pkt: ^Packet, size: c.int) ---
    grow_packet :: proc(pkt: ^Packet, grow_by: c.int) -> c.int ---
    packet_from_data :: proc(pkt: ^Packet, data: [^]u8, size: c.int) -> c.int ---
    packet_new_side_data :: proc(pkt: ^Packet, type: PacketSideDataType, size: c.size_t) -> [^]u8 ---
    packet_add_side_data :: proc(pkt: ^Packet, type: PacketSideDataType, data: [^]u8, size: c.size_t) -> c.int ---
    packet_shrink_side_data :: proc(pkt: ^Packet, type: PacketSideDataType, size: c.size_t) -> c.int ---
    packet_get_side_data :: proc(pkt: ^Packet, type: PacketSideDataType, size: ^c.size_t) -> [^]u8 ---
    packet_pack_dictionary :: proc(dict: ^avutil.Dictionary, size: ^c.size_t) -> [^]u8 ---
    packet_unpack_dictionary :: proc(data: [^]u8, size: c.size_t, dict: ^^avutil.Dictionary) -> c.int ---
    packet_free_side_data :: proc(pkt: ^Packet) ---
    packet_ref :: proc(dst, src: ^Packet) -> c.int ---
    packet_unref :: proc(pkt: ^Packet) ---
    packet_move_ref :: proc(dst, src: ^Packet) ---
    packet_copy_props :: proc(dst, src: ^Packet) -> c.int ---
    packet_make_refcounted :: proc(pkt: ^Packet) -> c.int ---
    packet_make_writable :: proc(pkt: ^Packet) -> c.int ---
    packet_rescale_ts :: proc(pkt: ^Packet, tb_src, tb_dst: avutil.Rational) ---
    get_audio_frame_duration :: proc(avctx: ^CodecContext, frame_bytes: c.int) -> c.int ---
    fast_padded_malloc :: proc(ptr: rawptr, size: ^c.uint, min_size: c.size_t) ---
    fast_padded_mallocz :: proc(ptr: rawptr, size: ^c.uint, min_size: c.size_t) ---
    parser_iterate :: proc(opaque: ^rawptr) -> ^CodecParser ---
    parser_init :: proc(codec_id: CodecID) -> ^CodecParserContext ---
    parser_parse2 :: proc(s: ^CodecParserContext, avctx: ^CodecContext, poutbuf: ^^u8, poutbuf_size: ^c.int, buf: [^]u8, buf_size: c.int, pts, dts, pos: c.int64_t) -> c.int ---
    parser_close :: proc(s: ^CodecParserContext) ---

    // -------------------------------------------------------------------------
    // bsf.h functions
    // -------------------------------------------------------------------------
    bsf_get_by_name :: proc(name: cstring) -> ^BitStreamFilter ---
    bsf_iterate :: proc(opaque: ^rawptr) -> ^BitStreamFilter ---
    bsf_alloc :: proc(filter: ^BitStreamFilter, ctx: ^^BSFContext) -> c.int ---
    bsf_init :: proc(ctx: ^BSFContext) -> c.int ---
    bsf_send_packet :: proc(ctx: ^BSFContext, pkt: ^Packet) -> c.int ---
    bsf_receive_packet :: proc(ctx: ^BSFContext, pkt: ^Packet) -> c.int ---
    bsf_flush :: proc(ctx: ^BSFContext) ---
    bsf_free :: proc(ctx: ^^BSFContext) ---
    bsf_get_class :: proc() -> ^avutil.Class ---
    bsf_list_alloc :: proc() -> ^BSFList ---
    bsf_list_free :: proc(lst: ^^BSFList) ---
    bsf_list_append :: proc(lst: ^BSFList, bsf: ^BSFContext) -> c.int ---
    bsf_list_append2 :: proc(lst: ^BSFList, bsf_name: cstring, options: ^^avutil.Dictionary) -> c.int ---
    bsf_list_finalize :: proc(lst: ^^BSFList, bsf: ^^BSFContext) -> c.int ---
    bsf_list_parse_str :: proc(str: cstring, bsf: ^^BSFContext) -> c.int ---
    bsf_get_null_filter :: proc(bsf: ^^BSFContext) -> c.int ---

    // -------------------------------------------------------------------------
    // packet side data cross-frame functions
    // -------------------------------------------------------------------------
    packet_side_data_from_frame :: proc(sd: ^^PacketSideData, nb_sd: ^c.int, src: ^avutil.FrameSideData, flags: c.uint) -> c.int ---
    packet_side_data_to_frame :: proc(sd: ^^^avutil.FrameSideData, nb_sd: ^c.int, src: ^PacketSideData, flags: c.uint) -> c.int ---
}
