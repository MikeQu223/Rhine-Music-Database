#version 440
#extension GL_GOOGLE_include_directive : enable
#include "opticalCommon.glsl"
layout(binding = 2) uniform sampler2D color;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 fragColor;
// 九点柔化的权重与归一（A07 评估结论，别再试图折叠）：中心 4、上下左右 2、四个对角 1，
// 权重和 = 4 + 4*2 + 4*1 = 16，末尾统一 /16，即二项核 [1 2 1; 2 4 2; 1 2 1]/16。均值保持 1，
// 所以它只做模糊，不会整体提亮。
//
// tap 半径 k = 1 + 6*distanceFromFocus*soften，取值 [1, 7] texel：
//   · soften == 0（g.clip.z == 1 即 detail 关，或 g.viewport.w == 1 即查看封面页）时，
//     k 仍然是 1，九次采样落在 ±1 texel 的九个**不同** texel 上；
//   · distanceFromFocus == 0（画面中部 |y-0.52| <= 0.05 那条带）时同样只是 k == 1。
// 也就是说这里不存在“某个因子为 0 → 九个 tap 采同一个 texel → 只采一次即可”的退化：
// 把九次采样折成一次会直接改画面（丢掉常驻的 3×3 二项模糊），因此默认路径必须保持九点。
//
// 实数域唯一等价的省法（本轮不启用，留作下一轮质量档）：k == 1 时用四次双线性折叠——在
// (v_uv ± 0.5 texel, 两个轴各取 ±0.5) 的四个对角位置各采一次、权重各 1/4，展开后
// 中心 4/16、轴向 2/16、对角 1/16，与上面的核逐项相同，采样次数 9 → 4。不默认启用的原因：
//   1) 它只在 k == 1 时成立，k > 1 的像素（画面上下边缘）仍要走九点，需要运行期分支；
//   2) 它依赖硬件双线性在 0.5 亚纹素权重上的精度（规范只保证 ≥ 8 位亚纹素），并且求和顺序
//      与九点不同，float32 下最多差 1~2 ULP，做不到逐像素相同；
//   3) 分档需要新的 uniform 或构建期 define，落在 opticalCommon.glsl / CMakeLists / RhiScene
//      这几处本轮不允许改的文件里。
vec4 effect() {
    float theme = g.viewport.z;
    // 在已有合成中完成轻量边缘柔化，不增加渲染目标或单独的全屏模糊通道。
    float distanceFromFocus = smoothstep(0.05, 0.48, abs(v_uv.y - 0.52));
    float soften = (1.0 - g.clip.z) * (1.0 - g.viewport.w);
    vec2 texel = (1.0 + 6.0 * distanceFromFocus * soften) / vec2(textureSize(color, 0));
    vec3 hdr = texture(color, rtUV(v_uv)).rgb * 4.0;
    vec3 neighbors = texture(color, rtUV(v_uv + vec2(texel.x, 0.0))).rgb;
    neighbors += texture(color, rtUV(v_uv - vec2(texel.x, 0.0))).rgb;
    neighbors += texture(color, rtUV(v_uv + vec2(0.0, texel.y))).rgb;
    neighbors += texture(color, rtUV(v_uv - vec2(0.0, texel.y))).rgb;
    hdr += neighbors * 2.0;
    hdr += texture(color, rtUV(v_uv + texel)).rgb;
    hdr += texture(color, rtUV(v_uv - texel)).rgb;
    hdr += texture(color, rtUV(v_uv + vec2(texel.x, -texel.y))).rgb;
    hdr += texture(color, rtUV(v_uv + vec2(-texel.x, texel.y))).rgb;
    hdr /= 16.0;
    vec3 rgb = outputColor(aces(hdr, mix(0.76, 0.98, theme)));
    float shade = g.clip.z;
    if (g.viewport.w < 0.5 && g.clip.w < 0.5) {
        vec3 paper = mix(vec3(222, 219, 215) / 255, vec3(17, 24, 27) / 255, theme);
        float top = mix(.72 * (1 - saturate(v_uv.y / .50)), .82 * (1 - saturate(v_uv.y / .36)), theme);
        rgb = mix(rgb, mix(vec3(224, 221, 216) / 255, paper, theme), top * (1 - shade));
        float bottom = mix(.72, .84, theme) * (1 - saturate((1 - v_uv.y) / .35));
        rgb = mix(rgb, paper, bottom * (1 - shade));
        float radius = length((v_uv - vec2(.42, .47)) / vec2(.58, .53)) / sqrt(2.0);
        float darkRadius = length((v_uv - vec2(.48, .48)) / vec2(.58, .53)) / sqrt(2.0);
        float edge = mix(.19 * saturate((radius - .32) / (.85 - .32)),
                         .48 * saturate((darkRadius - .42) / (.90 - .42)), theme);
        rgb = mix(rgb, paper, edge * (1 - shade));
        float side = v_uv.x < .59   ? mix(0.0, .2, saturate((v_uv.x - .4) / .19))
                     : v_uv.x < .68 ? mix(.2, .92, (v_uv.x - .59) / .09)
                                    : mix(.92, 1.0, (v_uv.x - .68) / .32);
        rgb = mix(rgb, paper, side * shade);
    }
    return vec4(rgb, 1);
}
void main() {
    fragColor = effect();
}
