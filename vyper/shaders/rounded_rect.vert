#version 450

layout(std140, set = 1, binding = 0) uniform RectVertex {
    vec4 bounds;
    vec2 viewport;
    vec2 rotation; // (cos(theta), sin(theta)), quad rotated about its center
                   // by theta; (0,0) = axis-aligned (the identity default)
};

layout(location = 0) out vec2 local_position;

void main() {
    const vec2 corners[6] = vec2[](
        vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),
        vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
    );
    vec2 corner = corners[gl_VertexIndex];
    vec2 center = bounds.xy + bounds.zw * 0.5;
    vec2 lc = (corner - 0.5) * bounds.zw;
    vec2 rc;
    if (rotation.x != 0.0 || rotation.y != 0.0) {
        rc = vec2(rotation.x * lc.x - rotation.y * lc.y,
                  rotation.x * lc.y + rotation.y * lc.x);
    } else {
        rc = lc;
    }
    vec2 pixel = center + rc;
    vec2 ndc = pixel / viewport * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    // The fragment SDF expects local_position in the box's OWN (rotated) frame
    // where the rect is axis-aligned; local coords are an affine map of pixel
    // position defined exactly by the corner values, so linear interpolation
    // across the rotated quad is exact -- no frame mismatch at the fragment
    // stage.
    local_position = corner * bounds.zw;
}
