#pragma once
#include <functional>

#include "FrameGenerator.h"
#include <QPointF>
#include <memory>

namespace RhineRender {

/** Apple 官方时域抗锯齿和超分；颜色历史由 MetalFX 所属上下文维护。 */
class MetalFxTemporal {
  public:
    explicit MetalFxTemporal(QRhi *rhi);
    ~MetalFxTemporal();
    static bool supported(QRhi *rhi);
    QRhiTexture *resolve(QRhiCommandBuffer *commands, QRhiTexture *color, QRhiTexture *depth,
                         QRhiTexture *motion, QSize displaySize, QPointF jitter, bool reset);
    bool active() const;
#ifdef Q_OS_DARWIN
    void *nativeScaler() const;
#endif

  private:
    struct Private;
    std::unique_ptr<Private> d;
};

// 不支持原生插帧的系统、设备或 SDK 返回空；时域超分仍可独立使用。
std::unique_ptr<FrameGenerator> createMetalFxFrameGenerator(QRhi *rhi);
} // namespace RhineRender
