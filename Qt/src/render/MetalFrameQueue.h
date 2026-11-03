#pragma once

#include "../fg/FgFrameTap.h"
#include <QVariantMap>
#include <memory>
#include <rhi/qrhi.h>

namespace RhineRender {
/** 原生异步插帧队列；只在窗口 GPU 完成后读取快照，输出完成后才交给 Qt 合成。 */
class MetalFrameQueue {
  public:
    struct Frame {
        QRhiTexture *interpolated = nullptr;
        QRhiTexture *real = nullptr;
        int slot = -1;
    };
    MetalFrameQueue(QRhi *rhi, QSize render, QSize display, QSize working);
    ~MetalFrameQueue();
    bool available() const;
    int reserve();
    void capture(QRhiCommandBuffer *commands, int slot, QRhiTexture *real, QRhiTexture *working,
                 const RhineFg::FrameInputs &inputs);
    Frame take();
    void release(QRhiCommandBuffer *commands, int slot);
    void cancel(QRhiCommandBuffer *commands, int slot);
    int inFlight() const;
    QVariantMap telemetry() const;

  private:
    struct Private;
    std::unique_ptr<Private> d;
};
} // namespace RhineRender
