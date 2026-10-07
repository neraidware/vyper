#version 450

// Luma plane of the byte-exact RGBA->NV12 conversion. This is the GPU half of
// yuv_exact.odin, and the yuv_exact gate is what says the two agree: every
// constant below has a named twin in that file and a line number in FFmpeg
// behind it.
//
// THE WHOLE POINT OF THIS SHADER IS THAT IT IS NOT A float CONVERSION. A
// plausible-looking shader that computes 0.299r+0.587g+0.114b in float and
// rounds at the end is wrong on roughly half the samples, because swscale
// computes in fixed point and truncates at a specific intermediate: the 15-bit
// luma is rounded, the 15-bit chroma P is rounded TWICE (once at P, once by
// the +262144 plus-bias that is really the dither table), and the final shift
// truncates. Any of those three roundings replaced by a single round at the end
// moves samples. So the arithmetic below is int32 throughout and the only
// floats are the unorm trip through the texture, which is exact because 8-bit
// values survive k/255 -> 8-bit -> k/255 -> k.
layout(set = 2, binding = 0) uniform sampler2D src;
layout(location = 0) in vec2 texcoord;
layout(location = 0) out vec4 out_color;

// libswscale/utils.c:705-711, the default BT.601 limited-range table. The
// C computes these as (int)(0.299 * 219/255 * (1<<15) + 0.5) etc; these are
// that expression evaluated, not rounded by eye.
const int RY = 8414;
const int GY = 16519;
const int BY = 3208;

// (0x2001 << (RGB2YUV_SHIFT-1)) with RGB2YUV_SHIFT = 15 -- input.c:56. Note
// this is 0x2001, not a bare 0x2000: the half-step is in the source, and
// dropping it shifts the image by one LSB on roughly half the samples.
const int LUMA_BIAS = 540928;
const int LUMA_SHIFT = 15;

// texelFetch on an RGBA8 UNORM sampler returns k/255. Multiplying by 255 and
// adding 0.5 recovers k exactly for every 0..255, which is what lets the
// integer chain below start from the real 8-bit samples instead of a float
// approximation of them. Do not "optimise" this into a plain cast.
int b8(float v) {
    return int(v * 255.0 + 0.5);
}

void main() {
    ivec2 size = textureSize(src, 0);
    ivec2 p = ivec2(texcoord * vec2(size));
    // texcoord reaches exactly 1.0 on the last fragment; that would index one
    // past the last texel, and the reference clamps rows for the same reason.
    p = clamp(p, ivec2(0), size - 1);

    vec4 t = texelFetch(src, p, 0);
    int y = (RY * b8(t.r) + GY * b8(t.g) + BY * b8(t.b) + LUMA_BIAS) >> LUMA_SHIFT;

    // av_clip_uint8. out-of-range luma is reachable from saturated input and
    // clamping is part of the contract, not a safety net bolted on afterwards.
    y = clamp(y, 0, 255);

    out_color = vec4(float(y) / 255.0, 0.0, 0.0, 1.0);
}
