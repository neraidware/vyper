#version 450

// Chroma plane of the byte-exact RGBA->NV12 conversion: one pass writing
// interleaved U,V to a single-channel R8 target that is twice the chroma sample
// width, so U and V land in ADJACENT texels and the downloaded plane is
// bit-for-bit the NV12 chroma plane (U,V byte-interleaved, h/2 rows).
//
// The target is 2*uv_w wide rather than uv_w wide with two channels precisely so
// that interleaving is a texel-adjacency question. A one-channel target can hold
// the plane only if the two components are neighbours in memory, and making them
// neighbours is this shader's job rather than a CPU unpack pass's.
//
// This stage is where the 4:4:4 -> 4:2:0 reduction happens, and it is NOT
// separable into "filter then decimate". swscale's order is: sit each chroma
// sample horizontally over an aligned pixel PAIR with equal weights, producing
// a 15-bit P per LUMA ROW, then filter those P values vertically with a
// 4-tap, then round. Doing the horizontal average after the vertical filter --
// the obvious order, and the one a separable blur naturally suggests -- gives
// different bytes, because the P rounding happens once per luma row (4 times)
// instead of once per output sample.
//
// The kernel is [1,3,3,1]/8, not [2,7,7,2]/18. That is measured, not chosen:
// the second is symmetric, the first is what swscale actually applies, and the
// difference is one output LSB on roughly half the samples. See yuv_exact.odin.
layout(set = 2, binding = 0) uniform sampler2D src;
layout(location = 0) in vec2 texcoord;
layout(location = 0) out vec4 out_color;

// libswscale/utils.c:705-713, default BT.601 limited-range chroma. These are
// (int)(0.169 * 224/255 * (1<<15) + 0.5) and friends, evaluated.
const int RU = -4865;
const int GU = -9528;
const int BU = 14392;
const int RV = 14392;
const int GV = -12061;
const int BV = -2332;

// input.c:1155-1172. The bias folds together the 128-offset for unsigned
// chroma and a half-step rounding that is part of the contract, not slack.
const int P_BIAS = 256 * 32768 + 512;
const int P_SHIFT = 15 - 5;

// swscale.c:54 -- sws_pb_64 is {64,64,64,64,64,64,64,64}. "pb" is PLUS BIAS.
// yuv2nv12cX_c (output.c:505) seeds its accumulator with chrDither[i&7] << 12,
// so with dithering off this is a standing +262144, which is exactly half a
// byte after the final >>19. Reading that table as zeros costs half a byte on
// every chroma sample in the frame, and it is the single easiest thing to get
// wrong here because the dithering path really is zero.
const int DITHER_BIAS = 64 << 12;

// [1,3,3,1]/8 normalised to 8192 = 2^13, because yuv2nv12cX_c shifts by 19 and
// 19 - 6 = 13. Sum is exactly 8192, so a constant frame is unchanged by the
// vertical filter -- which is what lets the `flat` probe mode isolate P.
const int T0 = 1024;
const int T1 = 3072;
const int T2 = 3072;
const int T3 = 1024;
const int OUT_SHIFT = 19;

int b8(float v) {
    return int(v * 255.0 + 0.5);
}

// P for one chroma column and one LUMA row: the two aligned pixels averaged
// into a single 15-bit chroma sample, truncated. Two fetches, not four: the
// pair is (2c, 2c+1), so the horizontal siting is an equal-weight average of
// one pair, not a filter with a footprint.
void chroma_p(int cx, int row, ivec2 size, out int pu, out int pv) {
    int y = clamp(row, 0, size.y - 1);
    int x0 = cx * 2;
    int x1 = min(x0 + 1, size.x - 1);
    vec4 a = texelFetch(src, ivec2(x0, y), 0);
    vec4 b = texelFetch(src, ivec2(x1, y), 0);
    int r = b8(a.r) + b8(b.r);
    int g = b8(a.g) + b8(b.g);
    int bl = b8(a.b) + b8(b.b);
    pu = (RU * r + GU * g + BU * bl + P_BIAS) >> P_SHIFT;
    pv = (RV * r + GV * g + BV * bl + P_BIAS) >> P_SHIFT;
}

void main() {
    ivec2 size = textureSize(src, 0);
    ivec2 cw = size / 2;
    // Output texel index in the 2*cw.x wide R8 target. Deriving it from the
    // texcoord (rather than from gl_FragCoord) keeps this identical to the luma
    // pass's addressing, which is what the yuv_exact probe compares against.
    int ox = clamp(int(texcoord.x * float(2 * cw.x)), 0, 2 * cw.x - 1);
    int oy = clamp(int(texcoord.y * float(cw.y)), 0, cw.y - 1);
    // Chroma sample owning this texel: adjacent texels 2c, 2c+1 are the U,V
    // pair for sample c. Clamping ox above means c.x <= cw.x-1, so the pixel
    // pair 2c, 2c+1 is always in range and the per-fetch clamps are dead code.
    ivec2 c = ivec2(ox >> 1, oy);

    // Chroma row k filters luma rows 2k-1 .. 2k+2, i.e. it is centred between
    // luma rows 2k and 2k+1. The asymmetric-looking span is what makes the
    // [1,3,3,1] weights correct: rows 2k and 2k+1 are the pair this sample owns
    // and carry the two large taps.
    int u0, v0, u1, v1, u2, v2, u3, v3;
    chroma_p(c.x, 2 * c.y - 1, size, u0, v0);
    chroma_p(c.x, 2 * c.y, size, u1, v1);
    chroma_p(c.x, 2 * c.y + 1, size, u2, v2);
    chroma_p(c.x, 2 * c.y + 2, size, u3, v3);

    int u = (T0 * u0 + T1 * u1 + T2 * u2 + T3 * u3 + DITHER_BIAS) >> OUT_SHIFT;
    int v = (T0 * v0 + T1 * v1 + T2 * v2 + T3 * v3 + DITHER_BIAS) >> OUT_SHIFT;

    u = clamp(u, 0, 255);
    v = clamp(v, 0, 255);

    // R8 target: this texel holds U or V depending on its parity, and together
    // the adjacent pair is exactly NV12's interleaved chroma byte order. Alpha
    // is 1 so the target is fully written if the driver ever widens it.
    float out_byte = ((ox & 1) == 0) ? float(u) : float(v);
    out_color = vec4(out_byte / 255.0, 0.0, 0.0, 1.0);
}
