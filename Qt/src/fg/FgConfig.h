#pragma once
#include <QtGlobal>

#include <QByteArray>
#include <QString>

/**
 * FSR3 帧生成（FG）的开关与参数。
 *
 * 为什么默认关闭插值：插值要求应用自己持有 VkSwapchainKHR、自己 acquire/present，
 * 并把渲染完成信号量注入 Qt 的提交。现在呈现层在能力可用时**常驻接管**，所以
 * RHINE_FG 只表示"要不要在每次呈现里插一张补偿帧"，可以随时改、不必重启；
 * 但默认仍取 off——插值对画质与功耗都有代价，应由用户在设置里显式打开。
 *
 * 所有字段都是"能安全给默认值"的：相机参数取了 Rhine 场景的真实量级
 * （NativeSceneCamera 用 near=5 / far=300，m_fov 单位是度），而不是 SDK 样例里
 * 那套 near=0.1 / far=5000。FG 会用它们把设备深度反解到视空间，填错会让
 * 去遮挡掩码和运动矢量场整体偏掉——画面表现为插值帧边缘撕裂、物体轮廓拖影。
 */
struct FgConfig
{
    /// 总开关，对应 RHINE_FG=on/off。
    bool enabled = false;

    /// 打开 SDK 的初始化期自检（FFX_FRAMEINTERPOLATION_ENABLE_DEBUG_CHECKING）。
    /// 自检会逐帧校验描述符并打印警告，只在排查问题时开。
    bool debugChecking = false;

    /// 把 SDK 的调试视图画进插值帧：撕裂线、重置标记、调试视图。
    bool drawDebugTearLines = false;
    bool drawDebugResetIndicators = false;
    bool drawDebugView = false;

    /// 相机与帧时间。fovYRadians 是垂直视场角（弧度），不是度。
    float nearPlane = 5.0f;
    float farPlane = 300.0f;
    float fovYRadians = 1.0f;
    float frameTimeMs = 16.6667f;
    float viewSpaceToMetersFactor = 1.0f;

    /// 与投影矩阵一致的亚像素抖动（像素单位）。FG 的深度重建要用它，
    /// 和 FSR3 超分用的是同一个值，否则两张图会对不齐。
    float jitterX = 0.0f;
    float jitterY = 0.0f;

    /// 呈现层参数。
    bool vsync = true;
    /// 把 present 推迟到下一次 acquire 之前（同一线程内），让 present 不在
    /// 渲染关键路径上。真正的独立呈现线程不安全，理由见 VulkanPresenter.cpp。
    bool deferredPresent = true;

    /// 从环境变量读取。RHINE_FG 接受 on/off，也接受 1/0、true/false、yes/no。
    /// RHINE_FG_DEBUG=on 会打开 SDK 自检，属于排障用的扩展开关。
    static FgConfig fromEnvironment();

    /// 只有显式打开才认为配置有效；上层拿它决定要不要创建 FgBackend。
    bool valid() const { return enabled; }
};

namespace RhineFg {

/// 宽松解析布尔环境变量：认不出来的值退回 fallback，而不是猜。
inline bool parseBool(const QByteArray &raw, bool fallback)
{
    const QByteArray value = raw.trimmed().toLower();
    if (value.isEmpty())
        return fallback;
    if (value == "on" || value == "1" || value == "true" || value == "yes"
        || value == "enable" || value == "enabled")
        return true;
    if (value == "off" || value == "0" || value == "false" || value == "no"
        || value == "disable" || value == "disabled")
        return false;
    return fallback;
}

#ifdef Q_OS_DARWIN
/** Metal 的普通窗口与自建宿主共用启动配置；主变量优先，未指定时默认同步。 */
inline bool metalVSyncEnabled() {
    return parseBool(qgetenv("RHINE_VSYNC"), parseBool(qgetenv("RHINE_FG_VSYNC"), true));
}

#endif

#ifdef Q_OS_LINUX
/**
 * 设置页写完偏好后调用：把偏好值转成 RHINE_FG。
 *
 * 注意：**呈现层是否接管窗口在启动时决定**（fg=off 走 Qt 默认路径，内容帧实测高 35%），
 * 所以这个开关需要重启才生效。这里仍然同步环境变量，是为了让"重启前的当前进程"
 * 与持久化偏好保持一致，避免设置页显示与实际状态打架。
 * 抽成函数是为了能在没有 GPU 的机器上单测这条链路。
 */
#else
/**
 * 设置页写完偏好后调用：把偏好值转成 RHINE_FG。
 *
 * 为什么需要它：呈现层每帧重读 RHINE_FG 来决定要不要插帧（这样开关才能免重启），
 * 而设置页改的是持久化偏好。两处若不同步，表现就是"点了没反应"。
 * 抽成函数是为了能在没有 GPU 的机器上单测这条链路。
 */
#endif
inline void applyInterpolationPreference(const QString &value)
{
    qputenv("RHINE_FG", value == QLatin1String("on") ? "on" : "off");
}

}  // namespace RhineFg

inline FgConfig FgConfig::fromEnvironment()
{
    FgConfig config;
    config.enabled = RhineFg::parseBool(qgetenv("RHINE_FG"), false);
    config.debugChecking = RhineFg::parseBool(qgetenv("RHINE_FG_DEBUG"), false);
    // 垂直同步必须跟着设置页走，否则呈现层永远用 FIFO：实测这台机器上 FIFO 只给到
    // 约半个刷新率（vkcube 47.4fps vs MAILBOX 125.4fps），关掉 vsync 才能拿到 MAILBOX。
#ifdef Q_OS_DARWIN
    config.vsync = RhineFg::metalVSyncEnabled();
#else
    config.vsync = RhineFg::parseBool(qgetenv("RHINE_FG_VSYNC"), true);
#endif
    return config;
}
