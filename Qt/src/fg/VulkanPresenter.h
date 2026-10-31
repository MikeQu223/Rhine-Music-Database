#pragma once

#include <QSize>
#include <QString>
#include <memory>

#include <vulkan/vulkan.h>

class QRhi;

/**
 * FG 的呈现层：应用自己持有 VkSwapchainKHR，自己 acquire/present。
 *
 * 为什么必须自己持有交换链：SDK 的 FG 呈现层（ffx_frameinterpolation_swapchain）
 * 要接管 present 回调、帧节奏和 UI 合成，而 Rhine 的 UI 是 Qt 画的，两者抢同一个
 * 交换链只会互相踩。这里绕开 SDK 的 swapchain，直接调算法 API，present 由本类负责。
 *
 * 与 Qt 的协作方式（这是 FG 收益能否成立的关键）：
 *  - acquire() 用 vkAcquireNextImageKHR 拿到一张图，并做一次"只带信号量"的空提交，
 *    把图像可用信号量转成 submitWaitSemaphore，同时给这个帧槽一个可观测的围栏。
 *  - 调用方在 Qt 提交本帧之前调 installSubmitParams()，把 submitWaitSemaphore 作为
 *    等待信号量、把该图像的 renderDone 作为信号信号量注入 QRhi 的 vkQueueSubmit。
 *    这样渲染队列会等"图像可用"，present 会等"渲染完成"，全程不需要 vkQueueWaitIdle。
 *  - present() 用 renderDone 做等待信号量。renderDone 是每个交换链图像一个，
 *    因为"这张图能被重新 acquire"本身就证明了上一次 present 已经消费掉它的信号量。
 *
 * 线程模型：所有方法都在渲染线程调用。不做独立呈现线程，原因是 Vulkan 要求
 * 同一个 VkQueue 的访问外部同步，而 Qt 的 vkQueueSubmit 在渲染线程、我们无法
 * 给它加锁；两条线程同时碰同一个队列是未定义行为。作为替代，presentDeferred()
 * 把 present 推迟到下一次 acquire 之前（仍在同一线程），present 因此不在渲染
 * 关键路径上——这就是"异步 present"的安全形态。
 */
class VulkanPresenter
{
public:
    enum class AcquireResult
    {
        Ok,
        Suboptimal,  ///< 拿到图了，但交换链已不理想；调用方应尽快 resize。
        OutOfDate,   ///< 交换链失效，需要 resize。
        Timeout,     ///< 等不到可用图像（窗口最小化、设备丢失等）。
        Error,
    };

    struct Frame
    {
        quint32 imageIndex = 0;
        VkImage image = VK_NULL_HANDLE;
        VkImageView view = VK_NULL_HANDLE;

        bool valid() const { return image != VK_NULL_HANDLE; }
    };

    VulkanPresenter();
    ~VulkanPresenter();
    VulkanPresenter(const VulkanPresenter &) = delete;
    VulkanPresenter &operator=(const VulkanPresenter &) = delete;

    /// 只有 Vulkan 后端可以自己建交换链。
    static bool supported(QRhi *rhi);

    /**
     * 从 QRhi 的原生句柄取 instance/physDev/dev/queue，在调用方给的 surface 上
     * 建交换链。surface 通常来自 QWindow 的 QVulkanInstance
     * （QVulkanInstance::surfaceForWindow(window)），生命周期由调用方持有。
     */
    bool init(QRhi *rhi, VkSurfaceKHR surface, QSize extent, bool vsync = true);

    /// 销毁交换链与信号量。不会销毁 surface/device（那是调用方的）。
    void release();

    /// 重建交换链。尺寸没变时是空操作；调用前本类会自己等 GPU 空闲。
    ///
    /// force 是为 OutOfDate 准备的：交换链失效**不一定**伴随窗口尺寸变化
    /// （合成器重建 surface、跨 GPU 导入失败都会触发），此时必须无视尺寸照建，
    /// 否则"尺寸没变就返回"会把重建吞掉，acquire 从此永远 OutOfDate。
    bool resize(QSize extent, bool force = false);

    /// 取下一张可渲染的图像。返回 OutOfDate 时调用方应 resize() 后重试。
    AcquireResult acquire(Frame *out);

    /**
     * 把本帧的等待/信号信号量注入 QRhi 的下一次提交。
     * 必须在 QRhi 提交本帧之前调用（QQuickRhiItem 下是在 render() 里、
     * endFrame 之前）。QRhi 只保存指针，所以参数对象由本类持有，调用方不必管。
     */
    bool installSubmitParams(QRhi *rhi, const Frame &frame);

    /// 呈现。needsRecreate 非空时带回"交换链需要重建"。
    bool present(const Frame &frame, bool *needsRecreate = nullptr);

    /// 把 present 推迟到下一次 acquire()/flushDeferredPresent() 之前。
    bool presentDeferred(const Frame &frame);
    bool flushDeferredPresent();

    bool ready() const;
    QSize extent() const;
    VkFormat colorFormat() const;
    quint32 imageCount() const;
    /// 当前真正生效的呈现模式（FIFO / MAILBOX / IMMEDIATE / FIFO_LATEST_READY）。
    /// 帧率上限几乎完全由它决定，所以性能面板要把它写出来。
    QString presentModeName() const;
    /// 同一张交换链图像两次上屏的平均间隔（毫秒）。
    /// 贴着刷新周期 = 合成器在限速；远大于刷新周期且忽大忽小 = GPU 或 CPU 提交跟不上。
    double imageReuseMs() const;

    /// 第 index 张交换链图像的裸句柄。FG 宿主需要把它们包成 QRhi 纹理才能当
    /// 渲染目标用；句柄在 resize()/release() 之后失效。
    VkImage imageAt(quint32 index) const;
    quint32 indexOf(VkImage image) const;
    QString lastError() const;

    // 实现细节类型。公开声明只是为了让 .cpp 里的匿名命名空间辅助函数能拿到它，
    // 本身不暴露任何字段（定义在 .cpp 内）。
    struct Private;

private:
    std::unique_ptr<Private> d;
};
