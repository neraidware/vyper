#version 450

// The one vertex stage for every textured axis-aligned quad in the app: SDF
// rects are separate (rounded_rect.vert), but text glyphs, preview image
// layers, and the export resampler all draw "sample this sub-rect of a
// texture into that sub-rect of the render target" and agree on the transform.
//
// The field names are the shared vocabulary: `bounds` is the destination rect
// in render-target pixels (top-left origin), `uv` is the source sub-rect as
// normalized corners, `viewport` is the render-target size. The companion
// fragment stages (text.frag, preview.frag, blit_box.frag) all consume the
// interpolated `texcoord` and are interchangeable behind this layout, so a
// caller only has to agree with THIS file -- which is why the per-draw uniform
// block lives in one Odin type (Quad_Uniforms) rather than one per pipeline.
layout(std140, set = 1, binding = 0) uniform QuadVertex {
    vec4 bounds;
    vec2 viewport;
    vec4 uv;
};

layout(location = 0) out vec2 texcoord;

void main() {
    const vec2 corners[6] = vec2[](
        vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),
        vec2(0.0, 0.0), vec2(0.0, 1.0), vec2(1.0, 1.0)
    );
    vec2 corner = corners[gl_VertexIndex];
    vec2 pixel = bounds.xy + corner * bounds.zw;
    vec2 ndc = pixel / viewport * 2.0 - 1.0;
    // Y flip: SDL3 GPU clip space has +Y up, image space has +Y down.
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    texcoord = mix(uv.xy, uv.zw, corner);
}
