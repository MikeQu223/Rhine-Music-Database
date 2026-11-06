#version 440
#extension GL_GOOGLE_include_directive : enable
#include "opticalCommon.glsl"
layout(binding = 2) uniform sampler2D color;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 fragColor;
// 九点柔化的权重与归一（A07 评估结论）：中心 4、上下左右 2、四个对角 1，
// 权重和 = 4 + 4*2 + 4*1 = 16，末尾统一 /16，即二项核 [1 2 1; 2 4 2; 1 2 1]/16。均值保持 1，
// 所以它只做模糊，不会整体提亮。
//
// tap 半径 k = 1 + 6*distanceFromFocus*soften，取值 [1, 7] texel：
//   · soften == 0（g.clip.z == 1 即 detail 关，或 g.viewport.w == 1 即查看封面页）时，
//     k 仍然是 1，九次采样落在 ±1 texel 的九个**不同** texel 上；
//   · distanceFromFocus == 0（画面中部 |y-0.52| <= 0.05 那条带）时同样只是 k == 1。
// 不存在“某个因子为 0 → 九个 tap 采同一个 texel → 只采一次即可”的退化：
// 把九次采样折成一次会丢掉常驻的 3×3 二项模糊，直接改画面。
//
// k == 1 时有**逐项等价**的四次折叠，Android 由 RHINE_OPTICAL_QUAD_FOLD 启用：
// 在 v_uv ± 0.5 texel 的四个对角点各采一次。线性采样器下每个点等权混合相邻 2×2 texel，
// 四点求和后中心出现 4 次、轴向各 2 次、对角各 1 次，正是 [1 2 1; 2 4 2; 1 2 1] 的
// 双线性展开；结果乘 4、末尾统一 /16，等价于九点路径，纹理读取 9 → 4 次。
//   · 严格等价的前提是 v_uv 落在源纹理 texel 中心（内部渲染尺寸 == 输出尺寸）。渲染分辨率
//     低于 100% 时九点本身也是「双线性重采样 + 柔化」的近似核，四点版权重略有差异，
//     属于肉眼不可见的极轻微观感变化，已获授权。
//   · k > 1 时半径不是 1 texel，折叠不成立，代码保留九点。
//   · 亚纹素权重依赖硬件双线性精度（规范只保证 ≥ 8 位），求和顺序也不同，float32 下
//     最多差 1~2 ULP。
//   · 宏只在 Android 构建的 qsb 烘焙里定义（CMakeLists.txt 的 if(ANDROID)），桌面 / iOS
//     不带这个宏，保留原来的九点语句，着色器产物逐字节不变。
vec4 effect() {
    float theme = g.viewport.z;
    // 在已有合成中完成轻量边缘柔化，不增加渲染目标或单独的全屏模糊通道。
    float distanceFromFocus = smoothstep(0.05, 0.48, abs(v_uv.y - 0.52));
    float soften = (1.0 - g.clip.z) * (1.0 - g.viewport.w);
    vec2 texel = (1.0 + 6.0 * distanceFromFocus * soften) / vec2(textureSize(color, 0));
    vec3 hdr;
#ifdef RHINE_OPTICAL_QUAD_FOLD
    // k == 1：四个半纹素对角采样在双线性下展开就是 [1 2 1;2 4 2;1 2 1]，
    // 求和乘 4 后与九点加权和等价，末尾统一 /16。k > 1 时半径不是 1 texel，保留九点。
    const float k = 1.0 + 6.0 * distanceFromFocus * soften;
    if (k >= 1.0 - 1e-5 && k <= 1.0 + 1e-5) {
        const vec2 halfTexel = 0.5 * texel;
        hdr = (texture(color, rtUV(v_uv + vec2(halfTexel.x, halfTexel.y))).rgb
             + texture(color, rtUV(v_uv + vec2(-halfTexel.x, halfTexel.y))).rgb
             + texture(color, rtUV(v_uv + vec2(halfTexel.x, -halfTexel.y))).rgb
             + texture(color, rtUV(v_uv + vec2(-halfTexel.x, -halfTexel.y))).rgb) * 4.0;
    } else
#endif
    {
        hdr = texture(color, rtUV(v_uv)).rgb * 4.0;
        vec3 neighbors = texture(color, rtUV(v_uv + vec2(texel.x, 0.0))).rgb;
        neighbors += texture(color, rtUV(v_uv - vec2(texel.x, 0.0))).rgb;
        neighbors += texture(color, rtUV(v_uv + vec2(0.0, texel.y))).rgb;
        neighbors += texture(color, rtUV(v_uv - vec2(0.0, texel.y))).rgb;
        hdr += neighbors * 2.0;
        hdr += texture(color, rtUV(v_uv + texel)).rgb;
        hdr += texture(color, rtUV(v_uv - texel)).rgb;
        hdr += texture(color, rtUV(v_uv + vec2(texel.x, -texel.y))).rgb;
        hdr += texture(color, rtUV(v_uv + vec2(-texel.x, texel.y))).rgb;
    }
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
