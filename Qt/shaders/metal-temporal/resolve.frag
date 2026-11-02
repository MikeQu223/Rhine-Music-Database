#version 440
layout(std140, binding = 0) uniform Parameters {
    vec4 jitterAndHistory;
    vec4 projection;
};
layout(binding = 1) uniform sampler2D currentColor;
layout(binding = 2) uniform sampler2D currentDepth;
layout(binding = 3) uniform sampler2D currentMotion;
layout(binding = 4) uniform sampler2D historyColor;
layout(binding = 5) uniform sampler2D historyDepth;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 resolvedColor;
layout(location = 1) out float resolvedDepth;

vec3 toYCoCg(vec3 color) {
    return vec3(dot(color, vec3(.25, .5, .25)), (color.r - color.b) * .5,
                (-color.r + 2 * color.g - color.b) * .25);
}
vec3 fromYCoCg(vec3 color) {
    return vec3(color.x + color.y - color.z, color.x + color.z, color.x - color.y - color.z);
}

/** 用九次双线性采样重建 Catmull-Rom，避免每轴四点展开为十六次。 */
vec3 reconstruct(sampler2D source, vec2 uv) {
    vec2 size = vec2(textureSize(source, 0));
    vec2 pixel = uv * size - .5;
    vec2 base = floor(pixel);
    vec2 phase = pixel - base;
    vec2 square = phase * phase;
    vec2 cube = square * phase;
    vec2 w0 = -.5 * phase + square - .5 * cube;
    vec2 w1 = 1 - 2.5 * square + 1.5 * cube;
    vec2 w2 = .5 * phase + 2 * square - 1.5 * cube;
    vec2 w3 = -.5 * square + .5 * cube;
    vec2 middle = w1 + w2;
    vec2 p0 = (base - .5) / size;
    vec2 p1 = (base + .5 + w2 / middle) / size;
    vec2 p2 = (base + 2.5) / size;
    vec3 result = texture(source, vec2(p0.x, p0.y)).rgb * w0.x * w0.y;
    result += texture(source, vec2(p1.x, p0.y)).rgb * middle.x * w0.y;
    result += texture(source, vec2(p2.x, p0.y)).rgb * w3.x * w0.y;
    result += texture(source, vec2(p0.x, p1.y)).rgb * w0.x * middle.y;
    result += texture(source, p1).rgb * middle.x * middle.y;
    result += texture(source, vec2(p2.x, p1.y)).rgb * w3.x * middle.y;
    result += texture(source, vec2(p0.x, p2.y)).rgb * w0.x * w3.y;
    result += texture(source, vec2(p1.x, p2.y)).rgb * middle.x * w3.y;
    result += texture(source, p2).rgb * w3.x * w3.y;
    return max(result, vec3(0));
}

void main() {
    vec2 texel = 1.0 / vec2(textureSize(currentColor, 0));
    // 历史位于未抖动的输出网格；本帧输入的光栅位置包含正向像素抖动。
    vec2 sampleUV = v_uv + jitterAndHistory.xy;
    vec3 current = reconstruct(currentColor, sampleUV);
    float depth = texture(currentDepth, sampleUV).r;
    resolvedDepth = abs(projection.y / (2 * depth - 1 + projection.x));
    vec2 motionUV = sampleUV;
    float nearestDepth = depth;
    vec3 low = vec3(1e20);
    vec3 high = vec3(-1e20);
    vec3 mean = vec3(0);
    vec3 square = vec3(0);
    // 前景速度扩张一像素；邻域方差约束遮挡变化与高频历史的颜色范围。
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            vec2 uv = sampleUV + vec2(x, y) * texel;
            float candidateDepth = texture(currentDepth, uv).r;
            if (candidateDepth < nearestDepth) {
                nearestDepth = candidateDepth;
                motionUV = uv;
            }
            vec3 color = toYCoCg(texture(currentColor, uv).rgb);
            low = min(low, color);
            high = max(high, color);
            mean += color;
            square += color * color;
        }
    }
    mean /= 9;
    vec3 deviation = sqrt(max(square / 9 - mean * mean, vec3(0)));
    low = max(low, mean - 1.25 * deviation);
    high = min(high, mean + 1.25 * deviation);
    // 常量邻域的累加舍入可能使区间反转，先恢复有效边界再夹紧历史。
    high = max(high, low);
    vec4 motion = texture(currentMotion, motionUV);
    vec2 previousUV = v_uv + motion.rg;
    bool inside = all(greaterThanEqual(previousUV, vec2(0))) && all(lessThanEqual(previousUV, vec2(1)));
    bool acceptsHistory = jitterAndHistory.z > .5 && inside && depth < 1 && motion.b > 0;
    vec3 result = current;
    if (acceptsHistory) {
        float previousDepth = texture(historyDepth, previousUV).r;
        // 前帧裁剪 W 等于透视相机距离；容差覆盖 half 量化，不跨越明确遮挡面。
        float tolerance = max(.01, motion.b * .003);
        if (abs(previousDepth - motion.b) < tolerance) {
            vec3 history = toYCoCg(reconstruct(historyColor, previousUV));
            history = clamp(history, low, high);
            float pixels = length(motion.rg * vec2(textureSize(historyColor, 0)));
            float weight = .92 / (1 + .05 * pixels);
            weight *= 1 - clamp(motion.a, 0, 1);
            result = mix(current, fromYCoCg(history), weight);
        }
    }
    resolvedColor = vec4(max(result, vec3(0)), 1);
}
