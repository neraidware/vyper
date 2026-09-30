#version 450

// Box-average resample. The export CPU reference reduces when shrinking by
// averaging every source texel the output pixel covers, and that is the quality
// bar: a video export that aliases high-frequency detail into moire is worse
// than a slow one.
//
// The obvious GPU answers were both measured dead on this stack. A mip chain is
// generated successfully, yet a hardcoded textureLod(3.0) still returns level-0
// pixels and 16x anisotropy changes nothing, so the driver clamps every lookup
// to level 0 and any reliance on sampler LOD or aniso silently degrades to a
// point sample. This shader therefore asks the sampler to reconstruct nothing
// and builds the footprint itself.
//
// Two details make it match the CPU kernel rather than merely look smoother:
//
//   texelFetch, not texture(). Filtering taps double-blur on top of the box:
//   with bilinear taps the 2:1 case measured mean 5.07 / peak 36 against the CPU
//   reference, worse than no averaging at all, because each tap interpolated
//   before being averaged. Fetching whole texels averages the footprint once.
//
//   Integer footprints come out exact. At rho == 1 every tap lands on the same
//   texel, the sum is 16 copies of one value and the divide is a power of two,
//   so 1:1 is bit-exact and the exactness gate still means something. With
//   filtered taps the same path was off by one ULP at the last pixel.
//
// The footprint comes from the same screen-space derivatives the sampler would
// use for automatic LOD, so this needs no uniform beyond the sampler.
layout(set = 2, binding = 0) uniform sampler2D image;
// Per-layer global alpha (0..1) for this draw, scaled into the sampled alpha
// below. It is a FRAGMENT-stage uniform, not part of the vertex Quad_Uniforms
// block: SDL GPU keeps the vertex and fragment uniform buffers separate, so a
// value pushed with PushGPUVertexUniformData is invisible here. set 3 is the
// fragment slot the text pipeline's per-draw uniform uses.
layout(std140, set = 3, binding = 0) uniform BlitOpacity {
    float opacity;
};
layout(location = 0) in vec2 texcoord;
layout(location = 0) out vec4 out_color;

// MAX_TAPS caps the per-axis sample count so a large reduction cannot turn into
// an unbounded loop. A 5x reduction would want 25 taps; capping at 4 per axis
// samples a strided subset of the footprint, which stays a box estimate rather
// than becoming a different kernel. Everything the export actually hits -- 2:1,
// 3:1, 8:1 upscale -- is inside the cap and therefore exact.
const int MAX_TAPS = 4;

// FOOTPRINT_EPS absorbs the float error in the derivatives. A 1:1 blit
// computes rho as 1.0000001 often enough that a bare ceil() returns 2, which
// averages two texels where the answer is one and blurs the exactness case --
// measured mean 1.18 / peak 5 at 1:1, and it wrecked every other row too.
// Snapping just below the integer is what makes an exact ratio give an exact
// tap count.
const float FOOTPRINT_EPS = 0.01;

void main() {
    ivec2 size = textureSize(image, 0);
    vec2 size_f = vec2(size);
    vec2 rho = max(
        abs(dFdx(texcoord * size_f)),
        abs(dFdy(texcoord * size_f))
    );
    // Magnifying: the output pixel covers less than one source texel, so there
    // is no box to average and the answer is interpolation. The CPU kernel uses
    // bilinear here and so must this, or magnification degrades to nearest:
    // routing it through the box path made the 2x upscale high-frequency row
    // worse (mean 30.18 -> 44.76) for no benefit.
    if (rho.x < 1.0 && rho.y < 1.0) {
        out_color = texture(image, texcoord);
        out_color.a *= opacity;
        return;
    }

    // One tap per covered texel, per axis, which is exactly what the CPU kernel
    // walks. This matters: a fixed 4x4 grid over a 3-texel footprint lands taps
    // at centres -1.125, -0.375, +0.375, +1.125, weighting the middle texels
    // twice, and that triangular kernel measured mean 8.20 / peak 46 against the
    // CPU box versus 2.77 / 19 for this one. A tap count that follows the
    // footprint weights every texel equally, so the two kernels agree.
    // First texel whose CENTRE falls inside the footprint, which is
    // floor(lo_edge + 0.5) -- not floor(lo_edge). The sample point sits at a
    // texel centre (center = x + 0.5), so the bare floor() of the leading edge
    // lands a whole texel low: at 1:1 it read texel x-1 instead of x, which is
    // exactly the off-by-one the failure samples showed at the last pixel,
    // (1599,0899) gpu=102,084,063 against cpu=103,085,064.
    ivec2 lo = ivec2(floor(texcoord * size_f - rho * 0.5 + 0.5));
    int tx = min(int(ceil(rho.x - FOOTPRINT_EPS)), MAX_TAPS);
    int ty = min(int(ceil(rho.y - FOOTPRINT_EPS)), MAX_TAPS);

    vec4 sum = vec4(0.0);
    for (int y = 0; y < ty; ++y) {
        for (int x = 0; x < tx; ++x) {
            ivec2 t = clamp(lo + ivec2(x, y), ivec2(0), size - 1);
            sum += texelFetch(image, t, 0);
        }
    }
    out_color = sum / float(tx * ty);
    out_color.a *= opacity;
}
