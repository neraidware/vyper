package swsbench

import "core:c"
import "core:fmt"
import "core:time"
import avutil "../vendor/ffmpeg/avutil"
import sws "../vendor/ffmpeg/swscale"

W :: 1920
H :: 1082
ITERS :: 60

bench :: proc(label: string, src_fmt: avutil.PixelFormat, dst_fmt: avutil.PixelFormat, src_bpp: int, flags: sws.Flags) {
	src := make([]u8, W * H * src_bpp); defer delete(src)
	dst := make([]u8, W * H * 4); defer delete(dst)
	for i in 0 ..< len(src) { src[i] = u8(i * 131 + i / 7) }
	ctx := sws.getContext(W, H, src_fmt, W, H, dst_fmt, flags, nil, nil, nil)
	if ctx == nil { fmt.printf("%-22s getContext failed\n", label); return }
	defer sws.freeContext(ctx)
	sf := avutil.frame_alloc()
	df := avutil.frame_alloc()
	defer { p := sf; avutil.frame_free(&p) }
	defer { p := df; avutil.frame_free(&p) }
	sf.format = c.int(src_fmt); sf.width = W; sf.height = H
	sd: [4][^]u8; sl: [4]c.int
	avutil.image_fill_arrays(&sd[0], &sl[0], raw_data(src), src_fmt, W, H, 32)
	for i in 0 ..< 4 { sf.data[i] = sd[i]; sf.linesize[i] = sl[i] }
	df.format = c.int(dst_fmt); df.width = W; df.height = H
	dd: [4][^]u8; dl: [4]c.int
	avutil.image_fill_arrays(&dd[0], &dl[0], raw_data(dst), dst_fmt, W, H, 32)
	for i in 0 ..< 4 { df.data[i] = dd[i]; df.linesize[i] = dl[i] }
	sws.scale_frame(ctx, df, sf)
	t0 := time.tick_now()
	for _ in 0 ..< ITERS { sws.scale_frame(ctx, df, sf) }
	fmt.printf("%-22s %.3f ms/frame\n", label, f64(time.tick_since(t0)) / 1e6 / ITERS)
}

main :: proc() {
	fmt.printf("%dx%d iters=%d\n", W, H, ITERS)
	bench("RGBA->NV12 bilinear", .RGBA, .NV12, 4, {.Bilinear})
	bench("RGBA->YUV420P bilinear", .RGBA, .YUV420P, 4, {.Bilinear})
	bench("RGB24->YUV420P bilinear", .RGB24, .YUV420P, 3, {.Bilinear})
	bench("RGB24->NV12 bilinear", .RGB24, .NV12, 3, {.Bilinear})
	bench("BGR24->YUV420P bilinear", .BGR24, .YUV420P, 3, {.Bilinear})
	bench("ARGB->YUV420P bilinear", .ARGB, .YUV420P, 4, {.Bilinear})
	bench("BGRA->YUV420P bilinear", .BGRA, .YUV420P, 4, {.Bilinear})
	bench("RGB24->YUV420P point", .RGB24, .YUV420P, 3, {.Point})
	bench("RGBA->YUV420P point", .RGBA, .YUV420P, 4, {.Point})
}
