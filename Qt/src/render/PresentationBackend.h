#pragma once

#include <QSize>
#include <QString>
#include <memory>
#include <rhi/qrhi.h>

class QWindow;
class QVulkanInstance;

namespace RhineRender {

/**
 * 隔离设备、交换链及原生同步；场景调度和合成只使用 QRhi，不观察平台句柄。
 * acquire 不开始 QRhi 帧，离屏场景必须先完成提交，随后才调用 beginFrame。
 */
class PresentationBackend {
  public:
    enum class AcquireResult { Ok, Suboptimal, OutOfDate, Timeout, Error };
    struct Frame {
        quint32 imageIndex = 0;
    };

    virtual ~PresentationBackend() = default;
    virtual bool initialize(QSize logicalSize, bool vsync) = 0;
    virtual QWindow *window() const = 0;
    virtual QRhi *rhi() const = 0;
    virtual QVulkanInstance *vulkanInstance() const {
        return nullptr;
    }
    virtual bool resize(QSize pixels, bool force) = 0;
    virtual AcquireResult acquire(Frame *frame) = 0;
    virtual QRhi::FrameOpResult beginFrame(const Frame &frame, QRhiCommandBuffer **commands) = 0;
    virtual QRhiRenderTarget *target(const Frame &frame) const = 0;
    virtual bool finishTarget(QRhiCommandBuffer *commands, const Frame &frame) = 0;
    virtual bool endFrame(const Frame &frame, bool rendered) = 0;
    virtual void release() = 0;
    virtual bool ready() const = 0;
    virtual QSize extent() const = 0;
    virtual quint32 imageCount() const = 0;
    virtual int startupProbeFrames() const {
        return 1;
    }
    virtual QString formatName() const = 0;
    virtual QString presentModeName() const = 0;
    /// 同一张交换链图像两次上屏的平均间隔（毫秒）。0 表示后端不提供。
    /// 贴着刷新周期说明是合成器在限速，而不是渲染来不及。
    virtual double imageReuseMs() const {
        return 0.0;
    }
    /// 交换链真正重建过多少次。
    virtual quint64 swapchainRecreates() const {
        return 0;
    }
    /// 重建时为等 GPU 退出旧交换链而做过多少次设备空闲等待（vkDeviceWaitIdle / QRhi::finish）。
    virtual quint64 deviceIdleWaits() const {
        return 0;
    }
    /// 尺寸没变、因此跳过重建的 resize 次数。
    /// 与上面两个数一起看才能证明"去重生效"：跳过数应当远多于重建数，而等待数不该随帧数上涨。
    virtual quint64 resizeSkips() const {
        return 0;
    }
    /// A02：累计离屏提交次数——beginFrame 成功进入的离屏帧数（每个都对应一次 endFrame）。
    /// 在真正提交的后端里计数，而不是在调用方计数：这样以后多一个呈现层调用者也不会漏。
    virtual quint64 offscreenSubmits() const {
        return 0;
    }
    /// A02：最近一次 beginFrame 的耗时（毫秒）＝**帧槽等待**（等上一帧命令缓冲/围栏归还）。
    /// 与 beginMs 的区别：beginMs 是呈现层的 EMA，这里是后端自己量到的原始样本。
    /// 返回负数表示该后端不提供这项测量，呈现层会退回自己的计时。
    virtual double slotWaitMs() const {
        return -1.0;
    }
    virtual QString backendName() const = 0;
    virtual QString lastError() const = 0;
};

std::unique_ptr<PresentationBackend> createPresentationBackend(const QString &name);

} // namespace RhineRender
