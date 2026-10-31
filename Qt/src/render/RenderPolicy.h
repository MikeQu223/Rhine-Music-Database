#pragma once

#include <QString>

/**
 * 渲染策略里可以离线判定的那一半：GPU 计时可信度、时间戳登记、运动矢量需求。
 *
 * 这些判断全部与 GPU 无关，所以放在 header-only 里，让渲染器与回归用例共用同一份实现。
 * 写错的后果不是崩溃而是“数字看着合理但含义错”，只有用例拦得住。
 */
namespace RhineRender {

/**
 * GPU 计时可信度的四态。
 *
 * 面板上的“0.000 ms”有三种互不相同的含义：后端不支持时间戳、支持但本次没有请求、
 * 请求了但这一帧还没拿到已完成样本。混成一个 0 会让“GPU 到底占多少”这个问题
 * 无法回答（docs/vulkan-3d-fullchain-performance-report.md 的 A01），
 * 所以状态与数值分开传递：数值只表示测量结果，状态表示这个结果能不能用。
 */
enum class GpuTimingStatus {
    /// 后端或设备不支持时间戳查询（例如软件光栅化、部分 GL 实现）。
    Unsupported,
    /// 支持，但创建 QRhi 时没有请求 EnableTimestamps / 图形配置里没开时间戳。
    Disabled,
    /// 已请求，且这一帧还没有“已完成”的样本（帧在飞、刚重建资源、或后端延迟上报）。
    NoSample,
    /// 有真实样本，gpuTimeMs 可以直接引用。
    Ok,
};

constexpr const char *gpuTimingStatusName(GpuTimingStatus status) {
    switch (status) {
    case GpuTimingStatus::Unsupported:
        return "unsupported";
    case GpuTimingStatus::Disabled:
        return "disabled";
    case GpuTimingStatus::NoSample:
        return "noSample";
    case GpuTimingStatus::Ok:
        return "ok";
    }
    return "unknown";
}

/// 采样状态：能力 → 是否请求 → 是否拿到 >0 的样本，三者缺一不可。
constexpr GpuTimingStatus classifyGpuTiming(bool featureSupported, bool timestampsRequested,
                                            bool hasSample) {
    if (!featureSupported) {
        return GpuTimingStatus::Unsupported;
    }
    if (!timestampsRequested) {
        return GpuTimingStatus::Disabled;
    }
    return hasSample ? GpuTimingStatus::Ok : GpuTimingStatus::NoSample;
}

/**
 * 启动期登记：已经有某个 QRhi 实例请求了时间戳查询。
 *
 * 三条路径都要登记，否则面板会把“没请求”说成“没样本”：
 *   · main.cpp 的 QQuickGraphicsConfiguration::setTimestamps(true)（默认 Qt Quick 路径）；
 *   · VulkanPresentationBackend 建 QRhi 时的 QRhi::EnableTimestamps（呈现层自建实例，
 *     离屏层通过 QQuickGraphicsDevice::fromRhi 共用同一个设备，所以这一处顺带覆盖 FG 路径）。
 *
 * 只写一次、之后只读，不跨线程改写，所以不加锁。
 */
inline bool &timestampsRequestedFlag() {
    static bool requested = false;
    return requested;
}
inline void requestTimestamps() {
    timestampsRequestedFlag() = true;
}
inline bool timestampsRequested() {
    return timestampsRequestedFlag();
}

/**
 * 需要运动矢量 MRT 的 AA 模式：TAA 与 FSR 的时域升采样。
 *
 * 只看**配置**，不看运行时是否可用（FSR 能力可能前几帧才探测出来）。目标分配用这个
 * 口径，避免“能力翻转 → 重建整帧目标”的一帧抖动；真正消费运动矢量前仍然查一次
 * 运行时可用性。
 */
inline bool modeNeedsMotion(const QString &mode) {
    return mode == QLatin1String("taa") || mode == QLatin1String("fsr") ||
           mode == QLatin1String("fsr3");
}

} // namespace RhineRender
