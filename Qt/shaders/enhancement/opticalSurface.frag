#version 440
#extension GL_GOOGLE_include_directive : enable
#include "opticalCommon.glsl"
layout(location = 0) in vec2 v_surfaceUv;
layout(location = 1) in vec2 v_uv;
layout(location = 2) in vec3 v_lightUv;
layout(location = 3) in float v_theme;
layout(location = 4) in float v_viewZ;
layout(location = 5) in float v_quality;
layout(location = 6) in float v_lightMask;
layout(location = 7) in vec2 v_normalUv;
layout(location = 8) in float v_clarity;
layout(location = 9) in vec3 v_world;
layout(location = 10) in vec3 v_normal;
layout(location = 11) in float v_mode;
layout(std140, binding = 1) uniform SurfaceBlock {
    Surface m;
};
layout(binding = 2) uniform sampler2D surfaceAtlas;
layout(binding = 3) uniform sampler3D lightAtlas;
layout(binding = 4) uniform sampler2D label;
layout(binding = 5) uniform sampler2D cover;
layout(binding = 6) uniform sampler2D normalAtlas;
layout(location = 0) out vec4 fragColor;
#ifdef RHINE_SINGLE_PASS_MOTION
// 第二个颜色附件：运动矢量（RG = 屏幕 UV 位移，BA 预留给 FSR3）。
layout(location = 1) out vec4 velocityOut;
layout(location = 12) in vec2 v_velocity;
#endif
/** 只插值烘焙光场的相邻高度切片；没有实时光源求值、光线追踪或折射背景采样。 */
vec3 bakedIllumination() {
    // 三维光场由硬件三线性采样；RGB 按 sRGB8(线性/4) 存放，这里手工解码后乘回 4.0。
    return linearColor(texture(lightAtlas, v_lightUv).rgb) * 4.0 * v_lightMask * opticalLight.x * opticalLight.y;
}
/** 正上方一束主光：漫反射 + 玻璃高光。
 *  场景没有实时阴影，这束光只负责给唱片与壳体一个明确的高光方向，
 *  让 CD 表面出现镜面反射而非纯烘焙的平涂。 */
/** 主光方向：正上方略偏前。纯正上方时竖直的盘面 N·L 接近 0，
 *  盘面收不到光，看起来会发平；偏前一点才能让 CD 正面出高光。 */
const vec3 KEY_LIGHT = normalize(vec3(0.0, 0.55, 0.84));
vec3 keyLight(vec3 base, float gloss) {
    if (v_mode < 0.5) {
        return base;
    }
    vec3 n = normalize(v_normal);
    vec3 l = KEY_LIGHT;
    vec3 v = normalize(g.eye.xyz - v_world);
    float ndl = max(dot(n, l), 0.0);
    float spec = pow(max(dot(n, normalize(l + v)), 0.0), mix(20.0, 90.0, gloss)) * mix(0.18, 0.85, gloss);
    return base * (0.55 + 0.45 * ndl) + vec3(spec);
}
void main() {
#ifdef RHINE_SINGLE_PASS_MOTION
    // 先写运动矢量：本函数有多处提前 return（背板、透明、阴影专用），
    // 提前返回的像素仍保留顶点阶段算出的正确速度。
    velocityOut = vec4(v_velocity, 0.0, 1.0);
#endif
    if (m.flags.x == 1.0) {
        if (!gl_FrontFacing && v_mode > 0.5) {
            // 素面封底：封面纸背不承载印刷内容，给一层哑光纸背底色。
            vec3 paperBack = mix(vec3(.82, .80, .76), vec3(.15, .16, .17), v_theme);
            fragColor = vec4(linearColor(paperBack), v_quality);
            return;
        }
        vec4 ink = texture(label, vec2(v_uv.x, 1.0 - v_uv.y));
        vec3 rgb = linearColor(ink.rgb);
        float amount = 1.0 - smoothstep(.12, .65, dot(rgb, vec3(.2126, .7152, .0722)));
        rgb = mix(rgb, mix(vec3(.023, .032, .037), vec3(.78, .78, .71), amount), v_theme);
        fragColor = vec4(rgb, ink.a * v_quality);
        return;
    }
    if (!gl_FrontFacing && v_mode > 0.5) {
        // 素面封底：表面图集与烘焙光场只对应正面，背面采样会取到错位的邻面图块，
        // 表现成一片发虚的色斑。背面一律给哑光底色，不采样图集。
        vec3 back = mix(m.color.rgb, m.darkColor.rgb, v_theme);
        back = mix(back, g.fogColor.xyz, smoothstep(g.fog.x, g.fog.y, v_viewZ));
        fragColor = vec4(back, m.color.a);
        return;
    }
    if (m.flags.x == 7.0) {
        // 卡片上独立的装饰文字：只做线性化后直接叠加。
        vec4 ink = texture(label, vec2(v_uv.x, 1.0 - v_uv.y));
        fragColor = vec4(linearColor(ink.rgb), ink.a);
        return;
    }
    if (m.flags.x == 9.0 && v_mode > 0.5) {
        // 唱片上的光学薄膜：本体几乎全透，只留下正上方主光的镜面高光与边缘菲涅耳。
        // 这层就是 CD 表面那圈玻璃反射的来源，缺了它盘面会显得发平。
        vec3 n = normalize(v_normal);
        vec3 l = KEY_LIGHT;
        vec3 v = normalize(g.eye.xyz - v_world);
        float ndl = max(dot(n, l), 0.0);
        float spec = pow(max(dot(n, normalize(l + v)), 0.0), 160.0) * 1.8;
        float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0) * 0.30;
        vec3 tint = mix(m.color.rgb, m.darkColor.rgb, v_theme);
        fragColor = vec4(tint * (0.12 + 0.30 * ndl) + vec3(spec + rim), m.color.a);
        return;
    }
    if (m.flags.x == 2.0) {
        float coverage = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(.06711056, .00583715))));
        if (v_quality <= coverage) {
            discard;
        }
    }
    if (m.flags.x == 4.0 && v_mode > 0.5) {
        // 象牙壳体是整块平整面板：面片图集按小唱片壳尺度烘焙，放大到这种尺寸会变成
        // 块状色斑。这里只用材料色加烘焙光场，得到干净的素面壳体。
        vec3 ivory = mix(m.color.rgb, m.darkColor.rgb, v_theme) + bakedIllumination();
        ivory = keyLight(ivory, 0.35);
        ivory = mix(ivory, g.fogColor.xyz, smoothstep(g.fog.x, g.fog.y, v_viewZ));
        fragColor = vec4(ivory, m.color.a);
        return;
    }
    bool shell = m.flags.x == 3.0 || m.flags.x == 4.0 || m.flags.x == 5.0;
    vec4 baked = texture(surfaceAtlas, v_surfaceUv);
    // 表面图集以 sRGB8 存放线性辐亮度/4；这里手工解码后乘回 4.0。
    baked.rgb = linearColor(baked.rgb) * 4.0;
    vec4 normalResponse = texture(normalAtlas, v_normalUv);
    if (v_theme > 0.0) {
        vec4 night = texture(surfaceAtlas, v_surfaceUv + vec2(0.0, 0.5));
        night.rgb = linearColor(night.rgb) * 4.0;
        baked = mix(baked, night, v_theme);
        normalResponse = mix(normalResponse, texture(normalAtlas, v_normalUv + vec2(0.0, 0.5)), v_theme);
    }
    vec3 color = baked.rgb * normalResponse.rgb + vec3(normalResponse.a);
    if (m.flags.x == 3.0 && v_mode > 0.5) {
        // 玻璃壳：旧渲染器用 transmission/ior 走折射通道，把整张 CD 包在里面。
        // 这里没有背景捕获，改用菲涅耳近似——正视几乎全透，掠射角反射增强，
        // 再叠一条主光镜面高光，观感与折射玻璃一致。
        vec3 n = normalize(v_normal);
        vec3 v = normalize(g.eye.xyz - v_world);
        float ndv = clamp(dot(n, v), 0.0, 1.0);
        float fresnel = pow(1.0 - ndv, 5.0);
        // 光学包裹：掠射角强反射 + 轮廓亮边，否则这层壳几乎看不见，画面会像少了一层。
        float rim = pow(1.0 - ndv, 2.2);
        float edge = smoothstep(0.55, 0.98, rim);
        vec3 tint = mix(m.color.rgb, m.darkColor.rgb, v_theme);
        // 清晰 / 磨砂：clarity 越低，霜层越厚。磨砂把镜面高光打散成宽而弱的漫反射，
        // 同时抬高不透明度，玻璃从"透亮"变成"雾面"。
        float frost = (g.viewport.w > 0.5) ? (1.0 - clamp(v_clarity, 0.0, 1.0)) : 0.0;
        float spec = pow(max(dot(n, normalize(KEY_LIGHT + v)), 0.0), mix(90.0, 6.0, frost)) *
                     mix(1.2, 0.30, frost);
        // 透明亚克力外壳：原版靠折射与厚度把整台机器包起来。这里没有折射通道，
        // 改用"掠射角几乎全反 + 轮廓亮边"来还原盒子的存在感，正视仍保持通透。
        vec3 sheen = mix(tint, vec3(1.0), 0.30) * (0.10 + 1.15 * rim);
        vec3 clearGlass = tint * 0.06 + g.fogColor.xyz * (0.04 + 0.95 * fresnel) + vec3(spec) +
                          sheen * 0.85 + vec3(edge * 0.55);
        // 磨砂不是盖一层白膜：玻璃仍然透明，只是高光被打散。真正的"糊"来自
        // 背后盘面封面的模糊，所以这里只把镜面高光变宽变弱，几乎不加不透明度。
        vec3 milkyGlass = g.fogColor.xyz * 0.55 + tint * 0.45 + vec3(spec * 0.5);
        vec3 glass = mix(clearGlass, milkyGlass, frost * 0.35);
        float alpha = clamp(0.06 + rim * 1.30 + fresnel * 0.35 + frost * 0.06, 0.0, 0.92);
        fragColor = vec4(glass, alpha);
        return;
    }
    if (shell) {
        // 磨砂：clarity 越低越接近毛玻璃。旧渲染器靠顶点高度推进霜层边界，
        // 这里没有高度属性，改用亮度向散射白收拢来表达同一观感。
        if (m.flags.x == 3.0 && g.viewport.w > 0.5) {
            // 注意：clarity 在其他页面是解密动画进度，不能用来驱动霜层，
            // 否则列表卡片会随解密动画一起变成磨砂。只有查看封面页的开关才有意义。
            float frost = 1.0 - clamp(v_clarity, 0.0, 1.0);
            float luma = dot(color, vec3(.2126, .7152, .0722));
            color = mix(color, vec3(luma) * 1.18 + vec3(.015), frost * 0.7);
        }
        // 选中壳体同样接收内部烘焙光，再叠加自身柔光，保持光源亮于受照邻壳。
        color += bakedIllumination();
        color += emissionColor.rgb * baked.a * m.emission.x * opticalLight.x * opticalLight.y;
    } else {
        color = mix(m.color.rgb, m.darkColor.rgb, v_theme) * 0.8 + baked.rgb * 0.08;
    }
    if (m.flags.x == 6.0) {
        vec2 discUv = vec2(v_uv.x, 1.0 - v_uv.y);
        vec2 centered = discUv - vec2(.5);
        discUv = mat2(m.extra.z, -m.extra.w, m.extra.w, m.extra.z) * centered + vec2(.5);
        // 磨砂：隔着霜层看盘面，封面必须真的糊掉，而不只是蒙一层乳白。
        float blur = (g.viewport.w > 0.5) ? (1.0 - clamp(v_clarity, 0.0, 1.0)) : 0.0;
        // 清晰档（blur == 0：不在查看封面页，或 clarity 已到 1.0，也就是默认状态）下，
        // 下面 17 次采样用的全是同一个 discUv —— 中心 1 次权重 4.0，两个环各 8 次权重 1.0，
        // 权重和 20.0，(4S + 16S) / 20 恒等于 S，画面与"只采一次"逐像素相同，只差浮点舍入。
        // 所以这里短路成 1 次纹理采样：省掉 16 次采样指令及其纹理带宽。
        // blur > 0 的磨砂档仍走原来的双环模糊，观感不变。
        if (blur <= 1e-6) {
            color = linearColor(texture(cover, discUv).rgb) * 0.8;
        } else {
            vec3 art = texture(cover, discUv).rgb * 4.0;
            float total = 4.0;
            for (int ring = 1; ring <= 2; ++ring) {
                vec2 delta = vec2(blur * 0.009 * float(ring));
                art += texture(cover, discUv + vec2(delta.x, 0.0)).rgb;
                art += texture(cover, discUv - vec2(delta.x, 0.0)).rgb;
                art += texture(cover, discUv + vec2(0.0, delta.y)).rgb;
                art += texture(cover, discUv - vec2(0.0, delta.y)).rgb;
                art += texture(cover, discUv + delta).rgb;
                art += texture(cover, discUv - delta).rgb;
                art += texture(cover, discUv + vec2(delta.x, -delta.y)).rgb;
                art += texture(cover, discUv + vec2(-delta.x, delta.y)).rgb;
                total += 8.0;
            }
            color = linearColor(art / total) * 0.8;
        }
        // 盘面是上光玻璃：给足高光，出射方向明确。
        color = keyLight(color, 1.0);
    } else if (m.flags.x == 8.0) {
        // CD 本体（银层、轴心）没有贴图可模糊，用降对比 + 轻微提亮表达同一层霜。
        float blur = (g.viewport.w > 0.5) ? (1.0 - clamp(v_clarity, 0.0, 1.0)) : 0.0;
        float luma = dot(color, vec3(.2126, .7152, .0722));
        color = mix(color, vec3(luma) * 1.06 + vec3(.02), blur * 0.55);
        color = keyLight(color, 0.6);
    } else {
        color = keyLight(color, shell ? 0.6 : 0.15);
    }
    color = mix(color, g.fogColor.xyz, smoothstep(g.fog.x, g.fog.y, v_viewZ));
    fragColor = vec4(color, m.color.a);
}
