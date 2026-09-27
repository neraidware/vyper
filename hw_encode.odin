package main

import "core:c"
import avutil "vendor/ffmpeg/avutil"
import avcodec "vendor/ffmpeg/avcodec"

// ---------------------------------------------------------------------------
// Hardware video encode, shared by every encoder this app opens.
//
// Export (render.odin) and proxy (proxy_encode.odin) want the same thing: try
// the platform's hardware H.264 encoders, accept one only when it really opens,
// and end at libx264 when none do. The device/frames-context setup is the
// fiddly part and is identical for both, so it lives here once rather than
// being copied into each encoder path.
//
// What deliberately does NOT live here is rate control and the software pixel
// format. Those are per-path decisions — export wants a fixed 8 Mbit and
// YUV420P-or-NV12 by encoder, proxies want an all-intra intermediate — and
// folding them in here is what would make this an abstraction nobody can swap.
// ---------------------------------------------------------------------------

// Order matters: it is preference order, best-supported first. NVENC leads on
// Linux/Windows because it is the most widely available of the three there, and
// VA-API leads nowhere on macOS because it does not exist there.
HW_ENC_CANDIDATES_LINUX :: []cstring{"h264_nvenc", "h264_vaapi", "h264_qsv", "h264_amf"}
HW_ENC_CANDIDATES_MACOS :: []cstring{"h264_videotoolbox"}
HW_ENC_CANDIDATES_WINDOWS :: []cstring{"h264_nvenc", "h264_qsv", "h264_amf"}

// hw_enc_candidate_names returns the encoder names to try, in order, always
// ending with libx264 as the guaranteed last resort. `cpu_only` skips every
// hardware entry, which is how the "force CPU" path and the CI cross-check
// reach the fallback deliberately instead of by accident.
hw_enc_candidate_names :: proc(cpu_only: bool) -> [dynamic]cstring {
	names: [dynamic]cstring
	if !cpu_only {
		when ODIN_OS == .Linux {
			for n in HW_ENC_CANDIDATES_LINUX {
				append(&names, n)
			}
		} else when ODIN_OS == .Darwin {
			for n in HW_ENC_CANDIDATES_MACOS {
				append(&names, n)
			}
		} else when ODIN_OS == .Windows {
			for n in HW_ENC_CANDIDATES_WINDOWS {
				append(&names, n)
			}
		}
	}
	append(&names, "libx264")
	return names
}

// hw_enc_open enables `codec` on a hardware device for width x height, filling
// ctx with the device/frames contexts and the hardware pixel format, and
// opening it. On success the caller owns the returned refs and must
// buffer_unref both; ctx holds its own references to the same buffers, which
// avcodec_free_context releases.
//
// Returns false without opening anything when no config on this encoder works.
// That is the expected outcome on a machine with no hardware encoder, and the
// caller's next candidate (ultimately libx264) is the real fallback — a name
// being registered in the build proves nothing, since an encoder can be
// present and still fail to open without the device or driver behind it.
hw_enc_open :: proc(
	ctx: ^avcodec.CodecContext,
	codec: ^avcodec.Codec,
	width, height: c.int,
) -> (ok: bool, dev: ^avutil.BufferRef, frames: ^avutil.BufferRef) {
	for i: c.int = 0; ; i += 1 {
		cfg := avcodec.get_hw_config(codec, i)
		if cfg == nil {
			break
		}
		if .HW_Frames_Ctx not_in cfg.methods && .HW_Device_Ctx not_in cfg.methods {
			continue
		}
		// A config whose pixel format isn't a real format is a software-input
		// hint, not a hardware-upload target.
		if cfg.pix_fmt == .None {
			continue
		}
		// A missing device/driver is expected and handled (we move on to the
		// next config), but libav logs each attempt at ERROR, which would fill
		// the log with noise on every proxy build. Suppress for the probe
		// window only, same as the decode probe does.
		probe_level := avutil.log_get_level()
		avutil.log_set_level(.Quiet)
		dev_ref: ^avutil.BufferRef
		dev_ok := avutil.hwdevice_ctx_create(&dev_ref, cfg.device_type, nil, nil, 0)
		if dev_ok != 0 && cfg.device_type == .Vaapi {
			// VA-API usually resolves through a DRM render node, but the
			// device name is not discoverable without a display in some
			// sessions, so retry with the conventional node before giving up.
			dev_ok = avutil.hwdevice_ctx_create(
				&dev_ref,
				cfg.device_type,
				"/dev/dri/renderD128",
				nil,
				0,
			)
		}
		avutil.log_set_level(probe_level)
		if dev_ok != 0 {
			continue
		}
		frames_ref := avutil.hwframe_ctx_alloc(dev_ref)
		if frames_ref == nil {
			avutil.buffer_unref(&dev_ref)
			continue
		}
		frm := (^HwFramesContext)(frames_ref.data)
		frm.format = cfg.pix_fmt
		// NV12 is the software carrier every hardware encoder here accepts.
		frm.sw_format = .NV12
		frm.width = width
		frm.height = height
		if ret := avutil.hwframe_ctx_init(frames_ref); ret < 0 {
			avutil.buffer_unref(&frames_ref)
			avutil.buffer_unref(&dev_ref)
			continue
		}
		ctx.hw_device_ctx = avutil.buffer_ref(dev_ref)
		ctx.hw_frames_ctx = avutil.buffer_ref(frames_ref)
		ctx.pix_fmt = cfg.pix_fmt
		if ret := avcodec.open2(ctx, codec, nil); ret < 0 {
			// ctx now owns references to both; avcodec_free_context releases
			// them. Free only our own duplicates here — unreffing ctx's here
			// and again at teardown is a double free.
			avutil.buffer_unref(&frames_ref)
			avutil.buffer_unref(&dev_ref)
			continue
		}
		return true, dev_ref, frames_ref
	}
	return false, nil, nil
}
