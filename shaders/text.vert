#version 450

layout(std140, set = 1, binding = 0) uniform TextVertex {
    vec4 bounds;
    vec2 viewport;
    vec4 uv;
};

layout(location = 0) out vec2 texcoord;

void main() {
    const vec2 corners[6] = vec2[](
        vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),
        vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
    );
    vec2 corner = corners[gl_VertexIndex];
    vec2 pixel = bounds.xy + corner * bounds.zw;
    vec2 ndc = pixel / viewport * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    texcoord = mix(uv.xy, uv.zw, corner);
}
