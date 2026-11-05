#version 440

// QRhi 的统一清屏色会写入所有 MRT 附件；颜色保持写保护，只把运动附件归零。
layout(location = 0) out vec4 colorOut;
layout(location = 1) out vec4 motionOut;

void main() {
    colorOut = vec4(0);
    motionOut = vec4(0);
}
