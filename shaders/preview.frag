#version 450

layout(set = 2, binding = 0) uniform sampler2D image;
layout(location = 0) in vec2 texcoord;
layout(location = 0) out vec4 out_color;

void main() {
    out_color = texture(image, texcoord);
}
