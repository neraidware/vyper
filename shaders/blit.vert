#version 450

// Offscreen blit/resample: draws one axis-aligned quad sampling a sub-rect of
// a source texture into a sub-rect of the render target. The hardware sampler
// does the filtering, so a scaled draw is one filtered texture fetch per output
// pixel instead of a CPU loop over the source footprint.
//
// Used by the export worker's GPU compositor and by the GPU resample probe.
layout(std140, set = 1, binding = 0) uniform BlitVertex {
    vec4 dst_rect;   // x, y, w, h in render-target pixels, top-left origin
    vec4 src_rect;   // (u0, v0, u1, v1) normalized, the source sub-rect
    vec2 viewport;   // render target size in pixels
};

layout(location = 0) out vec2 texcoord;

void main() {
    const vec2 corners[6] = vec2[](
        vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),
        vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
    );
    vec2 corner = corners[gl_VertexIndex];
    vec2 pixel = dst_rect.xy + corner * dst_rect.zw;
    vec2 ndc = pixel / viewport * 2.0 - 1.0;
    // Y flip: SDL3 GPU clip space has +Y up, image space has +Y down.
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    texcoord = mix(src_rect.xy, src_rect.zw, corner);
}
