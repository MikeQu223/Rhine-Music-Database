#version 440

layout(std140, binding = 0) uniform BackdropBlock {
    mat4 correction;
    vec4 viewport;
    vec4 paper;
    vec4 parameters;
    vec4 palette[4];
    vec4 anchors[4];
};

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 fragColor;

vec2 rotateVector(vec2 value, vec2 rotation) {
    return vec2(rotation.x * value.x - rotation.y * value.y, rotation.y * value.x + rotation.x * value.y);
}

vec2 liquidWarp(vec2 uv) {
    vec2 centered = uv - .5;
    float angle = .032 * sin(viewport.z * .19 + dot(centered, centered) * 14.0);
    float sine = angle * (1.0 - angle * angle / 6.0);
    float cosine = 1.0 - angle * angle / 2.0;
    vec2 rotated = vec2(cosine * centered.x - sine * centered.y, sine * centered.x + cosine * centered.y);
    vec2 flow = vec2(sin(uv.y * 4.2 + viewport.z * .16), cos(uv.x * 3.8 - viewport.z * .13)) * .018;
    return uv + (rotated - centered) + flow;
}

vec3 adjustPalette(vec3 color, float dark) {
    float luminance = dot(color, vec3(.2126, .7152, .0722));
    // 仿 Apple Music 的低饱和封面取色：保留色相，压低霓虹感，再与纸色轻微融合。
    color = mix(vec3(luminance), color, dark > .5 ? 1.20 : .88);
    color = mix(color, paper.rgb, dark > .5 ? .02 : .16);
    color = color * (dark > .5 ? 1.18 : 1.02) + (dark > .5 ? .025 : 0.0);
    return clamp(color, 0.0, .96);
}

vec3 colorField(vec2 uv) {
    vec2 warped = liquidWarp(uv);
    vec3 weighted = vec3(0.0);
    float total = 0.0;
    for (int index = 0; index < 4; ++index) {
        vec2 center = anchors[index].xy;
        center +=
            vec2(sin(viewport.z * .12 + float(index) * 1.7), cos(viewport.z * .10 + float(index) * 1.3)) *
            anchors[index].z;
        float distanceSquared = dot(warped - center, warped - center);
        float weight = palette[index].w / (distanceSquared + .055);
        weighted += adjustPalette(palette[index].rgb, parameters.x) * weight;
        total += weight;
    }
    return weighted / max(total, .001);
}

void main() {
    vec3 paperColor = paper.rgb;
    vec3 color = paperColor;
    if (viewport.w > .5) {
        color = colorField(v_uv);
    }

    // 控制区只用柔化后的色场和纸色薄纱区分，不使用硬边分隔线或实色遮罩。
    float frost = 0.0;
    float controlsOpacity = clamp(parameters.y, 0.0, 1.0);
    if (controlsOpacity > .001) {
        float controlsTop = clamp(parameters.z, 0.0, 1.0);
        float edge = smoothstep(controlsTop - .055, controlsTop + .018, v_uv.y);
        frost = edge * controlsOpacity;
        if (frost > .001 && viewport.w > .5) {
            vec2 sampleStep = 2.5 / max(viewport.xy, vec2(1.0));
            vec3 frosted = color * .40;
            frosted += colorField(clamp(v_uv + vec2(sampleStep.x, 0.0), 0.0, 1.0)) * .15;
            frosted += colorField(clamp(v_uv - vec2(sampleStep.x, 0.0), 0.0, 1.0)) * .15;
            frosted += colorField(clamp(v_uv + vec2(0.0, sampleStep.y), 0.0, 1.0)) * .15;
            frosted += colorField(clamp(v_uv - vec2(0.0, sampleStep.y), 0.0, 1.0)) * .15;
            color = mix(color, frosted, frost * .78);
        }
    }

    float vignette = 1.0 - smoothstep(.20, .82, length((v_uv - .5) * vec2(1.0, 1.18)));
    color *= mix(.90, 1.03, vignette);
    float amount = viewport.w > .5 ? paper.w : 0.0;
    vec3 result = mix(paperColor, color, amount);
    result = mix(result, paperColor, frost * (parameters.x > .5 ? .035 : .075));

    // 极轻的静态抖动只用于打破大面积色带，不参与流动形状。
    float dither = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453) - .5;
    result += dither / 1020.0;
    fragColor = vec4(result, 1.0);
}
