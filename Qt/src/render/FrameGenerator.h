#pragma once

#include <rhi/qrhi.h>

namespace RhineRender {
/** 原生插帧算法的共同契约；调度、UI 合成与真实帧呈现均由公共宿主负责。 */
class FrameGenerator {
  public:
    virtual ~FrameGenerator() = default;
    virtual bool available() const = 0;
#ifdef Q_OS_DARWIN
    virtual void setTemporalSource(void *source) {
        Q_UNUSED(source);
    }
#endif
    virtual bool resize(QRhi *rhi, QSize renderSize, QSize displaySize, QRhiTexture::Format colorFormat) = 0;
    virtual void release() = 0;
    virtual void setCamera(float nearPlane, float farPlane, float fovYRadians, float frameTimeMs) = 0;
    virtual void setJitter(float x, float y) = 0;
    virtual void requestReset() = 0;
    virtual bool prepare(QRhi *rhi, QRhiCommandBuffer *commands, QRhiTexture *color, QRhiTexture *depth,
                         QRhiTexture *motion) = 0;
    virtual bool dispatch(QRhi *rhi, QRhiCommandBuffer *commands, QRhiTexture *color,
                          QRhiTexture *colorWithoutUi, QRhiTexture *output) = 0;
    virtual QRhiTexture *output() const = 0;
    virtual bool lastFrameReset() const = 0;
    virtual QString lastError() const = 0;
};
} // namespace RhineRender
