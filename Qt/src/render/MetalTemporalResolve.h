#pragma once

#include "SceneResources.h"
#include <QMatrix4x4>
#include <QPointF>

namespace RhineRender {

/** Metal 轻量时域实验：全分辨率 HDR 历史、运动重投影和深度遮挡拒绝。 */
class MetalTemporalResolve : public SceneResources {
  public:
    explicit MetalTemporalResolve(QRhi *device);
    ~MetalTemporalResolve();
    QRhiTexture *resolve(QRhiCommandBuffer *commands, QRhiTexture *color, QRhiTexture *depth,
                         QRhiTexture *motion, QSize displaySize, QPointF jitter, const QMatrix4x4 &projection,
                         bool reset);
    quint64 bindingCreations = 0;
    quint64 drawCalls = 0;

  private:
    struct History {
        QRhiTexture *color = nullptr;
        QRhiTexture *depth = nullptr;
        QRhiTextureRenderTarget *target = nullptr;
        QRhiShaderResourceBindings *bindings = nullptr;
    };
    History history[2];
    QRhiBuffer *parameters = nullptr;
    QRhiSampler *linear = nullptr;
    QRhiSampler *nearest = nullptr;
    QRhiGraphicsPipeline *pipeline = nullptr;
    QRhiTexture *inputColor = nullptr;
    QRhiTexture *inputDepth = nullptr;
    QRhiTexture *inputMotion = nullptr;
    QSize display;
    int next = 0;
    bool valid = false;
};
} // namespace RhineRender
