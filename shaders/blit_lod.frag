#version 450

// Diagnostic fragment shader: identical to preview.frag except that it pins the
// LOD instead of deriving it. It exists to answer one question automatic LOD
// cannot: is there DATA in the mip levels, or is the chain empty?
//
//   texture(image, texcoord)            -> LOD from screen-space derivatives
//   textureLod(image, texcoord, 3.0)    -> always level 3
//
// If the explicit-LOD path returns a blurred frame then the chain was generated
// and automatic selection is what is broken. If it returns level-0 data, or
// black, the chain was never filled and mips cannot fix the aliasing at all.
// Either way this distinguishes the two, which guessing did not.
layout(set = 2, binding = 0) uniform sampler2D image;
layout(location = 0) in vec2 texcoord;
layout(location = 0) out vec4 out_color;

void main() {
    out_color = textureLod(image, texcoord, 3.0);
}
