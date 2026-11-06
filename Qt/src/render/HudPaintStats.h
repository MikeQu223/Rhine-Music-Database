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
};

inline HudPaintStats &hudPaintStats() {
    static HudPaintStats stats;
    return stats;
}

} // namespace RhineRender
