#pragma once

#include "FilamentContract.h"

#include <backend/platforms/VulkanPlatform.h>

namespace RhineFilament {

/**
 * 把宿主自建的 VkImage 当作交换链交给 Filament（零回读交接）。
 *
 * 只能与 libc++ 一起编译：Filament 预编译库是 libc++ ABI。
 * 所有 Vulkan 调用都在驱动初始化之后（createSwapChain 及之后），因为 bluevk 的
 * 函数指针在这之前还是空的。
 */
class Platform final : public filament::backend::VulkanPlatform {
  public:
    explicit Platform(const SharedContext &context);
    ~Platform() override;

    /** 目标尺寸变化时调用；下一帧重建镜像。 */
    void setSize(uint32_t width, uint32_t height);
    ImageHandoff handoff() const {
        return m_handoff;
    }
    uint32_t width() const {
        return m_width;
    }
    uint32_t height() const {
        return m_height;
    }
    /** 上一个完整帧是否已经把镜像留在可采样布局。 */
    bool sampled() const {
        return m_sampled;
    }
    /**
     * 主动把镜像切到可采样布局。
     * 不依赖 Platform::present()：驱动可能跳过 present（无 surface 的 headless 交换链），
     * 而 QRhi 必须在同一帧里就能采到结果。
     */
    bool ensureSampleable();

    ExtensionSet getSwapchainInstanceExtensions() const override;
    SurfaceBundle createVkSurfaceKHR(void *nativeWindow, VkInstance instance, uint64_t flags) const noexcept override;
    SwapChainPtr createSwapChain(void *nativeWindow, uint64_t flags, VkExtent2D extent) override;
    SwapChainBundle getSwapChainBundle(SwapChainPtr handle) override;
    VkResult acquire(SwapChainPtr handle, ImageSyncData *outImageSyncData) override;
    VkResult present(SwapChainPtr handle, uint32_t index, VkSemaphore finishedDrawing) override;
    bool hasResized(SwapChainPtr handle) override;
    bool isProtected(SwapChainPtr handle) override;
    VkResult recreate(SwapChainPtr handle) override;
    void destroy(SwapChainPtr handle) override;
    void terminate() override;
    Customization getCustomization() const noexcept override;

  private:
    struct SwapChainImpl;
    struct Transition;
    bool ensurePool();
    void releasePool();
    bool transition(VkImageLayout from, VkImageLayout to);
    bool clearDepth(SwapChainImpl *swapChain);

    SharedContext m_context;
    ImageHandoff m_handoff;
    SwapChainImpl *m_swapChain = nullptr;
    VkCommandPool m_pool = VK_NULL_HANDLE;
    // 每帧布局转换专用：持久命令缓冲 + fence，避免 vkQueueWaitIdle 等整条队列。
    VkCommandBuffer m_transitionCmd = VK_NULL_HANDLE;
    VkFence m_transitionFence = VK_NULL_HANDLE;
    VkImageLayout m_layout = VK_IMAGE_LAYOUT_UNDEFINED;
    uint32_t m_width = 0;
    uint32_t m_height = 0;
    bool m_pending = true;
    bool m_sampled = false;
};

}  // namespace RhineFilament
