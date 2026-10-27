#include "FilamentPlatform.h"

#include <bluevk/BlueVK.h>

#include <cstdio>
#include <cstring>

namespace RhineFilament {
namespace {

constexpr VkFormat kColorFormat = VK_FORMAT_R16G16B16A16_SFLOAT;

VkImageMemoryBarrier colorBarrier(VkImage image, VkImageLayout from, VkImageLayout to) {
    VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    barrier.oldLayout = from;
    barrier.newLayout = to;
    if (to == VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL) {
        barrier.srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
        barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    } else {
        barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    }
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image;
    barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    return barrier;
}

}  // namespace

struct Platform::SwapChainImpl : public Platform::SwapChain {
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImage depth = VK_NULL_HANDLE;
    VkDeviceMemory depthMemory = VK_NULL_HANDLE;
    VkExtent2D extent{0, 0};
    int next = 0;
};

Platform::Platform(const SharedContext &context) : m_context(context) {}

Platform::~Platform() {
    releasePool();
    delete m_swapChain;
    m_swapChain = nullptr;
}

Platform::ExtensionSet Platform::getSwapchainInstanceExtensions() const {
    return ExtensionSet{};
}

Platform::SurfaceBundle Platform::createVkSurfaceKHR(void *nativeWindow, VkInstance instance,
                                                    uint64_t flags) const noexcept {
    (void) nativeWindow;
    (void) instance;
    (void) flags;
    return {VK_NULL_HANDLE, {m_width, m_height}};
}

void Platform::setSize(uint32_t width, uint32_t height) {
    if (width == 0 || height == 0) {
        return;
    }
    if (width == m_width && height == m_height) {
        return;
    }
    m_width = width;
    m_height = height;
    m_pending = true;
    m_sampled = false;
}

bool Platform::ensurePool() {
    if (m_pool != VK_NULL_HANDLE) {
        return true;
    }
    VkDevice device = getDevice();
    if (device == VK_NULL_HANDLE) {
        return false;
    }
    VkCommandPoolCreateInfo info{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    info.queueFamilyIndex = m_context.graphicsFamily;
    return bluevk::vkCreateCommandPool(device, &info, nullptr, &m_pool) == VK_SUCCESS;
}

void Platform::releasePool() {
    if (m_pool != VK_NULL_HANDLE) {
        bluevk::vkDestroyCommandPool(getDevice(), m_pool, nullptr);
        m_pool = VK_NULL_HANDLE;
    }
}

bool Platform::clearDepth(SwapChainImpl *swapChain) {
    if (swapChain == nullptr || swapChain->depth == VK_NULL_HANDLE || m_pool == VK_NULL_HANDLE) {
        return false;
    }
    VkDevice device = getDevice();
    VkCommandBufferAllocateInfo allocate{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    allocate.commandPool = m_pool;
    allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocate.commandBufferCount = 1;
    VkCommandBuffer commands = VK_NULL_HANDLE;
    if (bluevk::vkAllocateCommandBuffers(device, &allocate, &commands) != VK_SUCCESS) {
        return false;
    }
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    bluevk::vkBeginCommandBuffer(commands, &begin);
    VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = swapChain->depth;
    barrier.subresourceRange = {VK_IMAGE_ASPECT_DEPTH_BIT, 0, 1, 0, 1};
    barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    barrier.srcAccessMask = 0;
    barrier.dstAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
    bluevk::vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                                 VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, nullptr, 0, nullptr, 1,
                                 &barrier);
    VkClearDepthStencilValue clearValue{1.0f, 0u};
    VkImageSubresourceRange range{VK_IMAGE_ASPECT_DEPTH_BIT, 0, 1, 0, 1};
    bluevk::vkCmdClearDepthStencilImage(commands, swapChain->depth,
                                        VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL, &clearValue,
                                        1, &range);
    bluevk::vkEndCommandBuffer(commands);
    VkQueue queue = VK_NULL_HANDLE;
    bluevk::vkGetDeviceQueue(device, m_context.graphicsFamily, m_context.graphicsIndex, &queue);
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &commands;
    const bool ok = queue != VK_NULL_HANDLE &&
                    bluevk::vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE) == VK_SUCCESS;
    if (ok) {
        bluevk::vkQueueWaitIdle(queue);
    }
    bluevk::vkFreeCommandBuffers(device, m_pool, 1, &commands);
    return ok;
}

bool Platform::transition(VkImageLayout from, VkImageLayout to) {
    if (m_swapChain == nullptr || m_swapChain->image == VK_NULL_HANDLE || m_pool == VK_NULL_HANDLE) {
        return false;
    }
    VkDevice device = getDevice();
    if (m_transitionFence == VK_NULL_HANDLE) {
        VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        fenceInfo.flags = VK_FENCE_CREATE_SIGNALED_BIT;
        if (bluevk::vkCreateFence(device, &fenceInfo, nullptr, &m_transitionFence) != VK_SUCCESS) {
            return false;
        }
    }
    if (m_transitionCmd == VK_NULL_HANDLE) {
        VkCommandBufferAllocateInfo allocate{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        allocate.commandPool = m_pool;
        allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        allocate.commandBufferCount = 1;
        if (bluevk::vkAllocateCommandBuffers(device, &allocate, &m_transitionCmd) != VK_SUCCESS) {
            return false;
        }
    }
    // 只等自己上一次转换完成；QRhi 与 Filament 同队列，提交顺序本身就保证了先后。
    bluevk::vkWaitForFences(device, 1, &m_transitionFence, VK_TRUE, UINT64_MAX);
    bluevk::vkResetFences(device, 1, &m_transitionFence);
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (bluevk::vkBeginCommandBuffer(m_transitionCmd, &begin) != VK_SUCCESS) {
        return false;
    }
    VkImageMemoryBarrier barrier = colorBarrier(m_swapChain->image, from, to);
    bluevk::vkCmdPipelineBarrier(m_transitionCmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                                 VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, nullptr, 0, nullptr, 1,
                                 &barrier);
    if (bluevk::vkEndCommandBuffer(m_transitionCmd) != VK_SUCCESS) {
        return false;
    }
    VkQueue queue = VK_NULL_HANDLE;
    bluevk::vkGetDeviceQueue(device, m_context.graphicsFamily, m_context.graphicsIndex, &queue);
    if (queue == VK_NULL_HANDLE) {
        return false;
    }
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &m_transitionCmd;
    return bluevk::vkQueueSubmit(queue, 1, &submit, m_transitionFence) == VK_SUCCESS;
}

Platform::SwapChainPtr Platform::createSwapChain(void *nativeWindow, uint64_t flags, VkExtent2D extent) {
    (void) nativeWindow;
    (void) flags;
    if (extent.width != 0 && extent.height != 0) {
        if (extent.width != m_width || extent.height != m_height) {
            m_width = extent.width;
            m_height = extent.height;
            m_pending = true;
        }
    }
    if (!ensurePool()) {
        return nullptr;
    }
    if (m_swapChain == nullptr) {
        m_swapChain = new SwapChainImpl();
    }
    m_swapChain->extent = {m_width, m_height};
    m_handoff.width = m_width;
    m_handoff.height = m_height;
    m_handoff.format = uint32_t(kColorFormat);
    m_handoff.sampledLayout = uint32_t(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    if (m_pending) {
        // 立刻把宿主镜像建出来：交接结果不必等到第一帧才可用。
        (void) getSwapChainBundle(m_swapChain);
    }
    return m_swapChain;
}

Platform::SwapChainBundle Platform::getSwapChainBundle(SwapChainPtr handle) {
    SwapChainBundle bundle;
    auto *swapChain = static_cast<SwapChainImpl *>(handle);
    VkDevice device = getDevice();
    VkPhysicalDevice physical = getPhysicalDevice();

    if (m_pending && device != VK_NULL_HANDLE && physical != VK_NULL_HANDLE) {
        if (swapChain->image != VK_NULL_HANDLE) {
            bluevk::vkDestroyImage(device, swapChain->image, nullptr);
            swapChain->image = VK_NULL_HANDLE;
        }
        if (swapChain->memory != VK_NULL_HANDLE) {
            bluevk::vkFreeMemory(device, swapChain->memory, nullptr);
            swapChain->memory = VK_NULL_HANDLE;
        }
        if (swapChain->depth != VK_NULL_HANDLE) {
            bluevk::vkDestroyImage(device, swapChain->depth, nullptr);
            swapChain->depth = VK_NULL_HANDLE;
        }
        if (swapChain->depthMemory != VK_NULL_HANDLE) {
            bluevk::vkFreeMemory(device, swapChain->depthMemory, nullptr);
            swapChain->depthMemory = VK_NULL_HANDLE;
        }
        VkImageCreateInfo info{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
        info.imageType = VK_IMAGE_TYPE_2D;
        info.format = kColorFormat;
        info.extent = {m_width, m_height, 1};
        info.mipLevels = 1;
        info.arrayLayers = 1;
        info.samples = VK_SAMPLE_COUNT_1_BIT;
        info.tiling = VK_IMAGE_TILING_OPTIMAL;
        info.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
                     VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        if (bluevk::vkCreateImage(device, &info, nullptr, &swapChain->image) == VK_SUCCESS) {
            VkMemoryRequirements requirements{};
            bluevk::vkGetImageMemoryRequirements(device, swapChain->image, &requirements);
            VkPhysicalDeviceMemoryProperties properties{};
            bluevk::vkGetPhysicalDeviceMemoryProperties(physical, &properties);
            VkMemoryAllocateInfo allocate{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
            allocate.allocationSize = requirements.size;
            for (uint32_t type = 0; type < properties.memoryTypeCount; ++type) {
                if ((requirements.memoryTypeBits & (1u << type)) != 0u &&
                    (properties.memoryTypes[type].propertyFlags &
                     VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0u) {
                    allocate.memoryTypeIndex = type;
                    break;
                }
            }
            if (bluevk::vkAllocateMemory(device, &allocate, nullptr, &swapChain->memory) == VK_SUCCESS) {
                bluevk::vkBindImageMemory(device, swapChain->image, swapChain->memory, 0);
            }
        }
        // Filament 的 Vulkan 后端需要深度附件；缺省(null)时整帧会被跳过（实测输出全黑）。
        if (swapChain->image != VK_NULL_HANDLE) {
            VkImageCreateInfo depthInfo{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
            depthInfo.imageType = VK_IMAGE_TYPE_2D;
            depthInfo.format = VK_FORMAT_D32_SFLOAT;
            depthInfo.extent = {m_width, m_height, 1};
            depthInfo.mipLevels = 1;
            depthInfo.arrayLayers = 1;
            depthInfo.samples = VK_SAMPLE_COUNT_1_BIT;
            depthInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
            depthInfo.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT |
                              VK_IMAGE_USAGE_TRANSFER_DST_BIT;
            depthInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
            depthInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            if (bluevk::vkCreateImage(device, &depthInfo, nullptr, &swapChain->depth) == VK_SUCCESS) {
                VkMemoryRequirements requirements{};
                bluevk::vkGetImageMemoryRequirements(device, swapChain->depth, &requirements);
                VkPhysicalDeviceMemoryProperties properties{};
                bluevk::vkGetPhysicalDeviceMemoryProperties(physical, &properties);
                VkMemoryAllocateInfo allocate{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
                allocate.allocationSize = requirements.size;
                for (uint32_t type = 0; type < properties.memoryTypeCount; ++type) {
                    if ((requirements.memoryTypeBits & (1u << type)) != 0u &&
                        (properties.memoryTypes[type].propertyFlags &
                         VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0u) {
                        allocate.memoryTypeIndex = type;
                        break;
                    }
                }
                if (bluevk::vkAllocateMemory(device, &allocate, nullptr,
                                             &swapChain->depthMemory) == VK_SUCCESS) {
                    bluevk::vkBindImageMemory(device, swapChain->depth, swapChain->depthMemory, 0);
                    // 深度必须显式清成 1.0：内容为 0 时所有片元都会被深度测试拒绝（画面空白）。
                    clearDepth(swapChain);
                }
            }
        }
        m_layout = VK_IMAGE_LAYOUT_UNDEFINED;
        m_pending = false;
        m_sampled = false;
        m_handoff.image = uint64_t(swapChain->image);
        m_handoff.width = m_width;
        m_handoff.height = m_height;
        m_handoff.format = uint32_t(kColorFormat);
        m_handoff.sampledLayout = uint32_t(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        if (swapChain->image == VK_NULL_HANDLE) {
            std::fprintf(stderr, "[filament] host image allocation failed\n");
        }
    }

    if (swapChain->image != VK_NULL_HANDLE) {
        utils::FixedCapacityVector<VkImage> colors(1);
        colors[0] = swapChain->image;
        bundle.colors = std::move(colors);
    }
    bundle.colorFormat = kColorFormat;
    if (swapChain->depth != VK_NULL_HANDLE) {
        bundle.depth = swapChain->depth;
        bundle.depthFormat = VK_FORMAT_D32_SFLOAT;
    } else {
        bundle.depthFormat = VK_FORMAT_UNDEFINED;
    }
    bundle.depth = VK_NULL_HANDLE;
    bundle.extent = {m_width, m_height};
    bundle.layerCount = 1;
    bundle.isProtected = false;
    return bundle;
}

VkResult Platform::acquire(SwapChainPtr handle, ImageSyncData *outImageSyncData) {
    auto *swapChain = static_cast<SwapChainImpl *>(handle);
    if (swapChain == nullptr || swapChain->image == VK_NULL_HANDLE) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    if (outImageSyncData != nullptr) {
        outImageSyncData->imageIndex = uint32_t(swapChain->next++ % 1);
        outImageSyncData->imageReadySemaphore = VK_NULL_HANDLE;
    }
    if (m_layout != VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL) {
        if (!transition(m_layout, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)) {
            return VK_ERROR_DEVICE_LOST;
        }
    }
    m_sampled = false;
    return VK_SUCCESS;
}

VkResult Platform::present(SwapChainPtr handle, uint32_t index, VkSemaphore finishedDrawing) {
    (void) handle;
    (void) index;
    (void) finishedDrawing;
    if (!transition(m_layout, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) {
        return VK_ERROR_DEVICE_LOST;
    }
    m_sampled = true;
    return VK_SUCCESS;
}

bool Platform::ensureSampleable() {
    if (m_swapChain == nullptr || m_swapChain->image == VK_NULL_HANDLE) {
        return false;
    }
    if (m_layout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
        m_sampled = true;
        return true;
    }
    if (!transition(m_layout, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) {
        return false;
    }
    m_sampled = true;
    return true;
}

bool Platform::hasResized(SwapChainPtr handle) {
    (void) handle;
    return false;
}

bool Platform::isProtected(SwapChainPtr handle) {
    (void) handle;
    return false;
}

VkResult Platform::recreate(SwapChainPtr handle) {
    (void) handle;
    m_pending = true;
    return VK_SUCCESS;
}

void Platform::destroy(SwapChainPtr handle) {
    // 宿主镜像由平台独占：Filament 在 endFrame 的 GC 里会对交换链调用 destroy()，
    // 但镜像本身必须活到 QRhi 采完（同帧！），所以这里只清句柄状态，不释放图像。
    // 真正的释放发生在 Platform 析构（此时引擎已销毁、宿主仍在）。
    auto *swapChain = static_cast<SwapChainImpl *>(handle);
    if (swapChain == nullptr || swapChain != m_swapChain) {
        return;
    }
    m_sampled = false;
}

void Platform::terminate() {
    releasePool();
}

Platform::Customization Platform::getCustomization() const noexcept {
    Customization customization;
    // 宿主镜像是 RGBA16F 线性 HDR：不做 sRGB 交换链，也不让 Filament 自行切到展示布局，
    // 布局循环由 acquire()/present() 自己严格成对管理。
    customization.isSRGBSwapChainSupported = false;
    customization.transitionSwapChainImageLayoutForPresent = false;
    customization.flushAndWaitOnWindowResize = true;
    return customization;
}

}  // namespace RhineFilament
