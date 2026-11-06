#pragma once
#include <QtGlobal>

// Android 专属的 3D 渲染默认策略（只决定「默认值」，不含任何渲染代码）。
//
// 背景：RhiScene 里有几项只改 buffer 组织 / render pass 存储策略、不改任何像素的优化，
// 最初是照 Vulkan 后端的收益写的——默认关，或只对 Vulkan 后端放行。Android 走
// QRhi::OpenGLES2（GLES 3.0），于是这几项一个都没生效，而移动端恰恰最吃逐 draw 的
// 状态切换与上传带宽。这里把判断收拢到一处，用平台宏给出 Android 默认值。
//
// 三条不变式：
//   1. 显式环境变量永远优先（写 =0 可逐项关掉做 A/B，=1 可强制开）。
//   2. 未设置时 Android 取本文件的新默认值，桌面 / iOS 取历史默认值——逐值不变。
//   3. RHINE_ANDROID_RENDER_TUNING=0 让 Android 整体退回改动前的默认值（一键回退）。
//
// 用 Q_OS_ANDROID 而不是 RHINE_MOBILE：这些判断依赖 GLES 后端与 300es 着色器变体，
// iOS 是 Metal，顶点接口与后端行为都不同，不该一起打开。

namespace RhineRender {

/// 总开关。只在首次调用时读一次环境变量，之后每帧零开销。
inline bool androidRenderTuningEnabled() {
    static const bool enabled = qEnvironmentVariable("RHINE_ANDROID_RENDER_TUNING").trimmed() != "0";
    return enabled;
}

/**
 * 读取 0/1 开关：显式设置时用它的值，未设置时 Android 用 androidDefault、其余平台用
 * legacyDefault。
 *
 * 刻意保留 == 1 而不是 != 0：旧代码就是 qEnvironmentVariableIntValue(...) == 1，
 * 写 2 这类值在旧代码里也算关，这里不能悄悄改掉。
 */
inline bool renderFlag(const char *name, bool androidDefault, bool legacyDefault) {
    if (qEnvironmentVariableIsSet(name)) {
        return qEnvironmentVariableIntValue(name) == 1;
    }
#if defined(Q_OS_ANDROID)
    return androidRenderTuningEnabled() ? androidDefault : legacyDefault;
#else
    Q_UNUSED(androidDefault);
    return legacyDefault;
#endif
}

/**
 * Android 上是否允许实例池在 GLES 后端生效（原实现只允许 Vulkan）。
 *
 * 依据：池化只用通用 QRhi API——一个 Dynamic VertexBuffer、按区间的
 * updateDynamicBuffer，以及把每个 draw 的偏移交给 VertexInput::offset；Qt 的 GLES2
 * 后端用 glVertexAttribPointer 的指针偏移实现它，还对同一 buffer 的重复绑定做了跳过。
 * 项目里 D03 的注释也记着 OpenGL 后端实测：非池化每帧上传约 165 KB，池化加内容差分
 * 之后接近 0。容量/对齐放不下时 poolInstances() 仍会整帧回退逐 draw buffer。
 */
inline bool androidInstancePoolOnGles() {
#if defined(Q_OS_ANDROID)
    return androidRenderTuningEnabled();
#else
    return false;
#endif
}

/**
 * Android 是否跳过「没有消费者的运动矢量收尾工作」。
 *
 * 依据：RhiScene.cpp 的 `#elif defined(Q_OS_LINUX)` 分支会被 Android 命中
 * （Q_OS_ANDROID 蕴含 Q_OS_LINUX），于是每帧跑 publishMotionInputs() 并填写 Globals
 * 尾部的 current/previousViewProjection。但 Android 的 FG 与 TAA/FSR 默认全关，
 * 300es 主变体没有 RHINE_SINGLE_PASS_MOTION，shader 根本不读那 128 字节；
 * FgFrameTap::publish() 在 tap 未启用时也只是一次原子读、无副作用。
 *
 * 这里只决定默认值。真正的消费者检查留在调用点（motionConfigured() / RHINE_WARP_PROBE），
 * 将来在 Android 打开时域功能时会自动恢复，不会静默丢掉运动矢量。
 */
inline bool androidSkipIdleMotionWork() {
    return renderFlag("RHINE_VK_SKIP_IDLE_MOTION", true, false);
}

/**
 * Android 是否对 Globals 常量缓冲做差分上传：内容逐字节未变就跳过 updateDynamicBuffer。
 * Globals 只随相机 / 选中项 / 主题变化，滚动与唱片旋转的不少帧里它是完全相同的。
 * GLES2 后端把 Dynamic UniformBuffer 存成 QByteArray 字节镜像（qrhigles2.cpp:2846），
 * updateDynamicBuffer 只是 memcpy 到它；内容相同就省掉这次拷贝和一条 resourceUpdate 记录。
 * 注意 uniform 值仍由 setShaderResources 每帧从镜像读出并下发，差分不改变下发结果。
 * 首帧强制上传，避免读到未定义内容。
 */
inline bool androidDifferentialGlobals() {
    return renderFlag("RHINE_VK_DIFF_GLOBALS", true, false);
}

/**
 * Android 的默认渲染分辨率（百分比）。
 *
 * 这是本文件里唯一会改变像素数的默认值：75% 让内部渲染目标与合成通道的像素数降到
 * 约 56%（0.75²），是 GLES 上最直接的 GPU 侧杠杆。桌面 / iOS 仍是 100（原生）。
 *
 * 两处消费点必须一致，否则设置页显示与实际生效值会打架：
 *   · main.cpp::applyRenderScaleSetting() —— 决定 RHINE_RENDER_SCALE 的启动默认值；
 *   · SettingsSchema.cpp 的 render-scale 描述符 —— 决定设置页的默认值与标签。
 * 用户在设置页改过之后写进 preference，启动默认值不再参与，行为与其他平台相同。
 *
 * 覆盖：RHINE_ANDROID_RENDER_SCALE=50..100 显式指定；总开关
 * RHINE_ANDROID_RENDER_TUNING=0 直接退回 100。RHINE_RENDER_SCALE 由
 * applyRenderScaleSetting() 优先尊重，显式设置的用户值不会被动到。
 */
inline int androidDefaultRenderScale() {
#if defined(Q_OS_ANDROID)
    if (!androidRenderTuningEnabled()) {
        return 100;
    }
    const int configured = qEnvironmentVariableIntValue("RHINE_ANDROID_RENDER_SCALE");
    return configured >= 50 && configured <= 100 ? configured : 75;
#else
    return 100;
#endif
}

} // namespace RhineRender
