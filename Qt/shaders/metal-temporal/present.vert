#version 440
// FG 呈现层的全屏三角。与 quad.vert 等价，但用自己的 uniform 块：
// FG 宿主不是 RhiScene 的渲染器，拿不到它的 GlobalBlock（那里面一整套相机矩阵
// 与后端口径开关都跟这里无关）。
layout(std140, binding = 0) uniform FgBlock {
    // Vulkan 的 NDC y 轴朝下，OpenGL 朝上；QRhi 各后端要的校正不同，
    // 所以矩阵由宿主按 rhi->isYUpInFramebuffer() 算好传进来，着色器不判断后端。
    mat4 correction;
    vec4 params;
};
layout(location = 0) out vec2 v_uv;
void main() {
    int id = gl_VertexIndex;
    vec2 p = vec2(id == 2 ? 3 : -1, id == 1 ? 3 : -1);
    gl_Position = correction * vec4(p, 0, 1);
    v_uv = vec2((p.x + 1) * .5, 1 - (p.y + 1) * .5);
}
