// 保留原渲染器的 Three.js r183 公式；MIT 归属见 NOTICE。
const float PI = 3.141592653589793;
struct Globals {
    mat4 view;
    mat4 projection;
    mat4 shadow;
    mat4 inverseProjection;
    mat4 aoProjection;
    mat4 aoInverseProjection;
    vec4 eye;
    vec4 fogColor;
    vec4 fog;
    vec4 viewport;
    vec4 clip;
};
struct Surface {
    vec4 color;
    vec4 physical;
    vec4 optics;
    vec4 attenuation;
    vec4 extra;
    vec4 flags;
    vec4 darkColor;
    vec4 emission;
};
layout(std140, binding = 0) uniform GlobalBlock {
    Globals g;
    mat4 correction;
    vec4 backend;
    mat4 emitterWorld;
    mat4 emitterInverse;
    vec4 opticalLight;
    vec4 emissionColor;
    vec4 normalParams;
#ifdef RHINE_SINGLE_PASS_MOTION
    // 运动矢量随主渲染单趟输出所需的两台相机矩阵；顺序必须与 C++ 侧 Globals 尾部一致。
    mat4 previousViewProjection;
    mat4 currentViewProjection;
#endif
};
vec2 rtUV(vec2 uv) {
    return backend.x > 0.5 ? vec2(uv.x, 1 - uv.y) : uv;
}
#define saturate(x) clamp(x, 0.0, 1.0)
float srgb(float v) {
    return v <= .04045 ? v / 12.92 : pow((v + .055) / 1.055, 2.4);
}
vec3 linearColor(vec3 v) {
    return vec3(srgb(v.x), srgb(v.y), srgb(v.z));
}
vec3 outputColor(vec3 x) {
    return mix(1.055 * pow(max(x, 0.0), vec3(1.0 / 2.4)) - .055, 12.92 * x, lessThanEqual(x, vec3(.0031308)));
}
vec3 aces(vec3 c, float exposure) {
    c *= exposure / .6;
    mat3 acesInput =
        mat3(vec3(.59719, .076, .02840), vec3(.35458, .90834, .13383), vec3(.04823, .01566, .83777));
    mat3 acesOutput = mat3(vec3(1.60475, -.10208, -.00327), vec3(-.53108, 1.10813, -.07276),
                           vec3(-.07367, -.00605, 1.07602));
    c = acesInput * c;
    vec3 a = c * (c + .0245786) - .000090537;
    vec3 b = c * (.983729 * c + .4329510) + .238081;
    return saturate(acesOutput * (a / b));
}
float getFace(vec3 d) {
    vec3 a = abs(d);
    if (a.x > a.z) {
        return a.x > a.y ? (d.x > 0 ? 0 : 3) : (d.y > 0 ? 1 : 4);
    }
    return a.z > a.y ? (d.z > 0 ? 2 : 5) : (d.y > 0 ? 1 : 4);
}
