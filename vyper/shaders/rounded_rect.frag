#version 450

layout(std140, set = 3, binding = 0) uniform RectFragment {
    vec4 color;
    vec4 shape;
    vec4 mode; // x: 0 = circular-arc corner, 1 = squircle (superellipse)
};

layout(location = 0) in vec2 local_position;
layout(location = 0) out vec4 out_color;

// Squircle (superellipse) exponent: 2 would be the circular arc; values above
// 2 flatten the corner's mid-arc toward a rounded square while keeping the
// edge tangent, which is the iOS-style squircle look.
const float SQUIRCLE_N = 4.0;

float corner_distance(vec2 point, float radius) {
    if (mode.x > 0.5) {
        // |x|^n + |y|^n = r^n norm for the corner blob.
        float vx = pow(max(point.x, 0.0), SQUIRCLE_N);
        float vy = pow(max(point.y, 0.0), SQUIRCLE_N);
        float corner = pow(vx + vy, 1.0 / SQUIRCLE_N);
        return corner + min(max(point.x, point.y), 0.0) - radius;
    }
    return length(max(point, 0.0)) + min(max(point.x, point.y), 0.0) - radius;
}

void main() {
    vec2 half_size = shape.xy * 0.5;
    float radius = min(shape.z, min(half_size.x, half_size.y));
    vec2 point = abs(local_position - half_size) - (half_size - radius);
    float distance = corner_distance(point, radius);
    float alpha = 1.0 - smoothstep(-1.0, 0.0, distance);
    float border = shape.w;
    if (border > 0.0) {
        float inner_distance = distance + border;
        alpha *= smoothstep(-1.0, 0.0, inner_distance);
    }
    out_color = vec4(color.rgb, color.a * alpha);
}
