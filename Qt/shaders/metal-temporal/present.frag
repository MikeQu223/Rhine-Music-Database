#version 440
layout(std140, binding = 0) uniform FgBlock {
    mat4 correction;
    vec4 params;
};
layout(binding = 1) uniform sampler2D sourceColor;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 fragColor;
void main() {
    // 复用原场景的预乘颜色；HUD 由 Qt Quick 在后续场景图合成。
    vec2 uv = params.x > .5 ? vec2(v_uv.x, 1.0 - v_uv.y) : v_uv;
    fragColor = texture(sourceColor, uv);
}
