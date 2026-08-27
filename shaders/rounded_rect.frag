#version 450

layout(std140, set = 3, binding = 0) uniform RectFragment {
    vec4 color;
    vec4 shape;
};

layout(location = 0) in vec2 local_position;
layout(location = 0) out vec4 out_color;

void main() {
    vec2 half_size = shape.xy * 0.5;
    float radius = min(shape.z, min(half_size.x, half_size.y));
    vec2 point = abs(local_position - half_size) - (half_size - radius);
    float distance = length(max(point, 0.0)) + min(max(point.x, point.y), 0.0) - radius;
    float alpha = 1.0 - smoothstep(-1.0, 0.0, distance);
    float border = shape.w;
    if (border > 0.0) {
        float inner_distance = distance + border;
        alpha *= smoothstep(-1.0, 0.0, inner_distance);
    }
    out_color = vec4(color.rgb, color.a * alpha);
}
