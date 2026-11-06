#pragma once

#include <QtGlobal>
#include <atomic>

namespace RhineRender {

/**
 * HUD 局部重绘的运行时账本（Android）。
 *
 * 为什么要走性能 JSON 而不是日志：设备上设不了环境变量，OPPO 的 logcat 配额还会把
 * 行挤掉；而 `RHINE Diagnostics` 是用户每次都会拉给我们的。把"每帧到底重画了多少"
 * 记进采样，就不必再靠猜。
 *
 * 只放原子计数，不依赖 QSG/RHI，`FrameProfiler` 才能安全 include。
 */
struct HudPaintStats {
    std::atomic<quint64> paints{0};      ///< 实际画了几次（局部 + 整块）
    std::atomic<quint64> dirtyPixels{0}; ///< 累计重画像素
    std::atomic<quint64> canvasPixels{0}; ///< 累计画布像素（与 dirtyPixels 同口径相除）
    /// 相交预筛账本：脏区重画时有多少条命令整体落在裁剪区外、被直接跳过。
    /// 滑列表时这个比例应该很高（静态画面一条都没动）；接近 0 说明脏区几乎盖满全屏。
    std::atomic<quint64> cullConsidered{0};
    std::atomic<quint64> cullSkipped{0};
};

inline HudPaintStats &hudPaintStats() {
    static HudPaintStats stats;
    return stats;
}

/**
 * `NativeHud::draw` 这一步的时间账：切歌动画期间它每帧都要重建整条命令流，
 * 15ms 的 `stepMeanCpuMs` 里到底有多少是它、有多少是场景采样，只能分开量。
 */
struct StepPhaseStats {
    std::atomic<quint64> count{0};
    std::atomic<quint64> sceneSampleNs{0}; ///< `NativeScene::sample`
    std::atomic<quint64> observeNs{0};     ///< 观察当前曲目 / 专辑跟随
    std::atomic<quint64> hudDrawNs{0};     ///< `NativeHud::draw`（命令流重建）
};

inline StepPhaseStats &stepPhaseStats() {
    static StepPhaseStats stats;
    return stats;
}

} // namespace RhineRender
