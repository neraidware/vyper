#version 450

layout(set = 2, binding = 0) uniform sampler2D font_atlas;
layout(std140, set = 3, binding = 0) uniform TextFragment {
    vec4 color;
};

layout(location = 0) in vec2 texcoord;
layout(location = 0) out vec4 out_color;

void main() {
    float alpha = texture(font_atlas, texcoord).r;
    out_color = vec4(color.rgb, color.a * alpha);
}
