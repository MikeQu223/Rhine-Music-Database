#include "VulkanPresenter.h"

#include <QDebug>
#include <QSize>
#include <QStringList>
#include <QVulkanFunctions>
#include <QVulkanInstance>

#include <chrono>

#include <rhi/qrhi.h>
#include <rhi/qrhi_platform.h>

namespace {

// 同时在飞的帧数。2 就够：acquire 一次、渲染一次，present 前不会再有第三帧。
// 帧槽存在的唯一理由是"acquire 信号量必须在提交消费完之后才能复用"，
// 而提交有没有消费完只有围栏能回答。
constexpr int kFrameSlots = 2;

// acquire 的等待上限。交换链失效（窗口最小化、拖到别的显示器）时
// vkAcquireNextImageKHR 可能长时间不返回；给个上限把"卡死"降级成"这一帧跳过"。
constexpr quint64 kAcquireTimeoutNs = 1'000'000'000ull;

VkExtent2D chooseExtent(const VkSurfaceCapabilitiesKHR &capabilities, QSize requested)
{
    if (capabilities.currentExtent.width != UINT32_MAX)
        return capabilities.currentExtent;

    VkExtent2D extent{quint32(qMax(1, requested.width())), quint32(qMax(1, requested.height()))};
    extent.width = qBound(capabilities.minImageExtent.width, extent.width,
                          capabilities.maxImageExtent.width);
    extent.height = qBound(capabilities.minImageExtent.height, extent.height,
                           capabilities.maxImageExtent.height);
    return extent;
}

VkCompositeAlphaFlagBitsKHR chooseCompositeAlpha(VkCompositeAlphaFlagsKHR supported)
{
    if (supported & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
        return VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if (supported & VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR)
        return VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
    if (supported & VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR)
        return VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
    return VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR;
}

}  // namespace

struct VulkanPresenter::Private
{
    QRhi *rhi = nullptr;
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice physicalDevice = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    quint32 queueFamily = 0;
    VkSurfaceKHR surface = VK_NULL_HANDLE;

    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    VkFormat format = VK_FORMAT_UNDEFINED;
    VkColorSpaceKHR colorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    VkPresentModeKHR presentMode = VK_PRESENT_MODE_FIFO_KHR;
    QSize extent;
    bool vsync = true;
    bool ready = false;
    bool needsRecreate = false;
    bool usable = false;
    bool paramsInstalled = false;
    // RHINE_FG_PRESENT_SYNC=idle 时退回 vkDeviceWaitIdle + 无等待信号量的 present。
    // 这是排障用的安全通道：如果 Qt 没有消费 setQueueSubmitParams（比如离屏帧
    // 走了另一条提交路径），默认路径会在 present 上挂死，而这条通道能先把画面跑通。
    bool forceIdleSync = false;
    // 静默降级只警告一次：硬同步会让帧生成掉到同步节奏，不能悄悄发生。
    bool warnedIdleFallback = false;
    bool warnedSuboptimal = false;

    QVector<VkImage> images;
    QVector<VkImageView> views;
    // 重建期间的暂存区，成功后才整体换进上面的正式字段。
    QVector<VkImageView> pendingViews;
    QVector<VkSemaphore> pendingSemaphores;
    // 每个交换链图像一个：这张图能被重新 acquire，就证明上一次 present 已经
    // 消费掉它的信号量，所以永远不需要额外的围栏来回收它。
    QVector<VkSemaphore> renderDone;

    VkSemaphore acquireSemaphore[kFrameSlots]{};
    VkSemaphore submitWaitSemaphore[kFrameSlots]{};
    VkFence slotFence[kFrameSlots]{};
    bool slotInUse[kFrameSlots]{};
    // 空提交已经把 submitWaitSemaphore 置为有信号。只有在 Qt 真的等过它之后
    // （present 等到了 renderDone，就证明渲染提交消费过它）才能再次 signal，
    // 否则"signal 一个已经 signaled 的二进制信号量"是非法用法。
    bool submitWaitPending[kFrameSlots]{};
    int slot = 0;
    int lastSlot = -1;
    quint32 lastImageIndex = 0;

    // QRhi 只保存指针，所以这份参数必须比 setQueueSubmitParams 活得更久。
    QRhiVulkanQueueSubmitParams params{};

    bool hasPending = false;
    Frame pendingFrame;

    QString error;

    PFN_vkGetDeviceProcAddr getDeviceProcAddr = nullptr;
    PFN_vkDeviceWaitIdle deviceWaitIdle = nullptr;
    PFN_vkCreateSwapchainKHR createSwapchain = nullptr;
    PFN_vkDestroySwapchainKHR destroySwapchain = nullptr;
    PFN_vkGetSwapchainImagesKHR getSwapchainImages = nullptr;
    PFN_vkAcquireNextImageKHR acquireNextImage = nullptr;
    PFN_vkQueuePresentKHR queuePresent = nullptr;
    PFN_vkQueueSubmit queueSubmit = nullptr;
    PFN_vkCreateSemaphore createSemaphore = nullptr;
    PFN_vkDestroySemaphore destroySemaphore = nullptr;
    PFN_vkCreateFence createFence = nullptr;
    PFN_vkDestroyFence destroyFence = nullptr;
    PFN_vkWaitForFences waitForFences = nullptr;
    PFN_vkResetFences resetFences = nullptr;
    PFN_vkCreateImageView createImageView = nullptr;
    PFN_vkDestroyImageView destroyImageView = nullptr;
    PFN_vkGetPhysicalDeviceSurfaceSupportKHR getSurfaceSupport = nullptr;
    PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR getSurfaceCapabilities = nullptr;
    PFN_vkGetPhysicalDeviceSurfaceFormatsKHR getSurfaceFormats = nullptr;
    PFN_vkGetPhysicalDeviceSurfacePresentModesKHR getSurfacePresentModes = nullptr;

    // —— 启动期能力快照：一次填好，供启动报告与排障使用 ——
    QStringList supportedPresentModes;
    bool extPresentId = false;
    bool extPresentWait = false;
    bool extFifoLatestReady = false;
    bool extSwapchainMaintenance1 = false;
    bool extPresentTiming = false;

    /// 同一张交换链图像两次 present 的间隔（指数滑动平均）。
    /// 它贴着刷新周期就说明合成器在压节奏，而不是 GPU 算不过来。
    double imageReuseMs = 0.0;
    QVector<quint64> lastPresentNs;
};

namespace {

void destroySwapchainObjects(VulkanPresenter::Private *d)
{
    if (!d || d->device == VK_NULL_HANDLE)
        return;

    for (VkImageView view : d->views)
    {
        if (view != VK_NULL_HANDLE && d->destroyImageView)
            d->destroyImageView(d->device, view, nullptr);
    }
    d->views.clear();
    d->images.clear();

    for (VkSemaphore semaphore : d->renderDone)
    {
        if (semaphore != VK_NULL_HANDLE && d->destroySemaphore)
            d->destroySemaphore(d->device, semaphore, nullptr);
    }
    d->renderDone.clear();

    if (d->swapchain != VK_NULL_HANDLE && d->destroySwapchain)
        d->destroySwapchain(d->device, d->swapchain, nullptr);
    d->swapchain = VK_NULL_HANDLE;
}

bool loadProcedures(VulkanPresenter::Private *d, QVulkanInstance *instance)
{
    if (!instance)
    {
        d->error = QStringLiteral("FG present: QRhi 没有提供 QVulkanInstance");
        return false;
    }

    const auto gipa = instance->getInstanceProcAddr("vkGetDeviceProcAddr");
    if (!gipa)
    {
        d->error = QStringLiteral("FG present: 取不到 vkGetDeviceProcAddr");
        return false;
    }
    d->getDeviceProcAddr = reinterpret_cast<PFN_vkGetDeviceProcAddr>(gipa);

    auto loadDevice = [&](const char *name) {
        return d->getDeviceProcAddr(d->device, name);
    };

    d->deviceWaitIdle = reinterpret_cast<PFN_vkDeviceWaitIdle>(loadDevice("vkDeviceWaitIdle"));
    d->queueSubmit = reinterpret_cast<PFN_vkQueueSubmit>(loadDevice("vkQueueSubmit"));
    d->createSemaphore = reinterpret_cast<PFN_vkCreateSemaphore>(loadDevice("vkCreateSemaphore"));
    d->destroySemaphore = reinterpret_cast<PFN_vkDestroySemaphore>(loadDevice("vkDestroySemaphore"));
    d->createFence = reinterpret_cast<PFN_vkCreateFence>(loadDevice("vkCreateFence"));
    d->destroyFence = reinterpret_cast<PFN_vkDestroyFence>(loadDevice("vkDestroyFence"));
    d->waitForFences = reinterpret_cast<PFN_vkWaitForFences>(loadDevice("vkWaitForFences"));
    d->resetFences = reinterpret_cast<PFN_vkResetFences>(loadDevice("vkResetFences"));
    d->createImageView = reinterpret_cast<PFN_vkCreateImageView>(loadDevice("vkCreateImageView"));
    d->destroyImageView = reinterpret_cast<PFN_vkDestroyImageView>(loadDevice("vkDestroyImageView"));

    d->getSurfaceSupport = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceSupportKHR>(
        instance->getInstanceProcAddr("vkGetPhysicalDeviceSurfaceSupportKHR"));
    d->getSurfaceCapabilities = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR>(
        instance->getInstanceProcAddr("vkGetPhysicalDeviceSurfaceCapabilitiesKHR"));
    d->getSurfaceFormats = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceFormatsKHR>(
        instance->getInstanceProcAddr("vkGetPhysicalDeviceSurfaceFormatsKHR"));
    d->getSurfacePresentModes = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfacePresentModesKHR>(
        instance->getInstanceProcAddr("vkGetPhysicalDeviceSurfacePresentModesKHR"));

    // 交换链函数是设备扩展函数：vkGetDeviceProcAddr 对"没有在设备上启用"的扩展
    // 返回空指针，所以这里同时起到能力探测的作用。返回空通常意味着 Qt 建
    // VkDevice 时没有启用 VK_KHR_swapchain（Qt 侧要
    // QQuickGraphicsConfiguration::setDeviceExtensions）。
    d->createSwapchain = reinterpret_cast<PFN_vkCreateSwapchainKHR>(
        loadDevice("vkCreateSwapchainKHR"));
    d->destroySwapchain = reinterpret_cast<PFN_vkDestroySwapchainKHR>(
        loadDevice("vkDestroySwapchainKHR"));
    d->getSwapchainImages = reinterpret_cast<PFN_vkGetSwapchainImagesKHR>(
        loadDevice("vkGetSwapchainImagesKHR"));
    d->acquireNextImage = reinterpret_cast<PFN_vkAcquireNextImageKHR>(
        loadDevice("vkAcquireNextImageKHR"));
    d->queuePresent = reinterpret_cast<PFN_vkQueuePresentKHR>(loadDevice("vkQueuePresentKHR"));

    if (!d->createSwapchain || !d->destroySwapchain || !d->getSwapchainImages
        || !d->acquireNextImage || !d->queuePresent)
    {
        d->error = QStringLiteral(
            "FG present: 设备没有启用 VK_KHR_swapchain（或不是标准 loader 创建的设备）");
        return false;
    }

    if (!d->deviceWaitIdle || !d->queueSubmit || !d->createSemaphore || !d->destroySemaphore
        || !d->createFence || !d->destroyFence || !d->waitForFences || !d->resetFences
        || !d->createImageView || !d->destroyImageView || !d->getSurfaceSupport
        || !d->getSurfaceCapabilities || !d->getSurfaceFormats || !d->getSurfacePresentModes)
    {
        d->error = QStringLiteral("FG present: Vulkan 核心/表面函数表不完整");
        return false;
    }
    return true;
}

quint64 monotonicNs()
{
    return quint64(std::chrono::duration_cast<std::chrono::nanoseconds>(
                       std::chrono::steady_clock::now().time_since_epoch())
                       .count());
}

const char *presentModeLabel(VkPresentModeKHR mode)
{
    switch (mode)
    {
    case VK_PRESENT_MODE_IMMEDIATE_KHR:
        return "IMMEDIATE";
    case VK_PRESENT_MODE_MAILBOX_KHR:
        return "MAILBOX";
    case VK_PRESENT_MODE_FIFO_KHR:
        return "FIFO";
    case VK_PRESENT_MODE_FIFO_RELAXED_KHR:
        return "FIFO_RELAXED";
#ifdef VK_PRESENT_MODE_FIFO_LATEST_READY_KHR
    case VK_PRESENT_MODE_FIFO_LATEST_READY_KHR:
        return "FIFO_LATEST_READY";
#endif
    default:
        return "OTHER";
    }
}

/// 记录一次成功上屏，更新"同图像复用间隔"。
///
/// 这个数是区分「GPU 渲染来不及」和「合成器不取图」最便宜的信号：前者会让间隔
/// 大小不一，后者会把间隔钉在刷新周期上（60Hz → 16.7ms）。
void notePresentedImage(VulkanPresenter::Private *d, quint32 imageIndex)
{
    if (int(imageIndex) >= d->lastPresentNs.size())
        return;
    const quint64 now = monotonicNs();
    const quint64 previous = d->lastPresentNs[int(imageIndex)];
    d->lastPresentNs[int(imageIndex)] = now;
    if (previous == 0)
        return;
    const double intervalMs = double(now - previous) / 1e6;
    d->imageReuseMs = d->imageReuseMs == 0.0 ? intervalMs
                                             : d->imageReuseMs * 0.85 + intervalMs * 0.15;
}

/// 设备扩展支持探测。必须在设备创建之后查：VkPhysicalDevice 有效即可，
/// 是否已在 VkDevice 上启用由调用方另行判断（这里只做"驱动有没有"）。
void queryPresentExtensionSupport(VulkanPresenter::Private *d, QVulkanInstance *instance)
{
    quint32 count = 0;
    if (instance->functions()->vkEnumerateDeviceExtensionProperties(
            d->physicalDevice, nullptr, &count, nullptr)
        != VK_SUCCESS
        || count == 0)
    {
        return;
    }
    QVector<VkExtensionProperties> extensions(static_cast<int>(count));
    if (instance->functions()->vkEnumerateDeviceExtensionProperties(
            d->physicalDevice, nullptr, &count, extensions.data())
        != VK_SUCCESS)
    {
        return;
    }
    extensions.resize(static_cast<int>(count));
    for (const VkExtensionProperties &extension : extensions)
    {
        const auto name = QByteArray(extension.extensionName);
        if (name == "VK_KHR_present_id")
            d->extPresentId = true;
        else if (name == "VK_KHR_present_wait")
            d->extPresentWait = true;
        else if (name == "VK_KHR_present_mode_fifo_latest_ready"
                 || name == "VK_EXT_present_mode_fifo_latest_ready")
            d->extFifoLatestReady = true;
        else if (name == "VK_KHR_swapchain_maintenance1"
                 || name == "VK_EXT_swapchain_maintenance1")
            d->extSwapchainMaintenance1 = true;
        else if (name == "VK_EXT_present_timing")
            d->extPresentTiming = true;
    }
}

/// 一行覆盖"这个交换链到底是什么状态"的全部事实。
/// 现场排障最常缺的就是这些数字：呈现模式、图像数、格式与颜色空间、扩展可用性。
QString describePresentSetup(VulkanPresenter::Private *d, QVulkanInstance *instance)
{
    VkPhysicalDeviceProperties props{};
    instance->functions()->vkGetPhysicalDeviceProperties(d->physicalDevice, &props);
    const QStringList modes = d->supportedPresentModes;
    return QStringLiteral("设备 %1 · API %2.%3.%4 · driver 0x%5 · 交换链 %6x%7 %8 张"
                          " · 格式 %9 · 颜色空间 %10 · 呈现 %11（可选 %12）"
                          " · 扩展 present_id=%13 present_wait=%14 fifo_latest_ready=%15"
                          " maintenance1=%16 present_timing=%17")
        .arg(QString::fromUtf8(props.deviceName))
        .arg(VK_API_VERSION_MAJOR(props.apiVersion))
        .arg(VK_API_VERSION_MINOR(props.apiVersion))
        .arg(VK_API_VERSION_PATCH(props.apiVersion))
        .arg(props.driverVersion, 0, 16)
        .arg(d->extent.width())
        .arg(d->extent.height())
        .arg(d->images.size())
        .arg(int(d->format))
        .arg(int(d->colorSpace))
        .arg(QString::fromLatin1(presentModeLabel(d->presentMode)))
        .arg(modes.join(QLatin1Char('/')))
        .arg(d->extPresentId ? 1 : 0)
        .arg(d->extPresentWait ? 1 : 0)
        .arg(d->extFifoLatestReady ? 1 : 0)
        .arg(d->extSwapchainMaintenance1 ? 1 : 0)
        .arg(d->extPresentTiming ? 1 : 0);
}

bool createSwapchain(VulkanPresenter::Private *d)
{
    if (!d->device || d->surface == VK_NULL_HANDLE)
    {
        d->error = QStringLiteral("FG present: 交换链创建前缺少设备或 surface");
        return false;
    }

    VkSurfaceCapabilitiesKHR capabilities{};
    VkResult result = d->getSurfaceCapabilities(d->physicalDevice, d->surface, &capabilities);
    if (result != VK_SUCCESS)
    {
        d->error = QStringLiteral("FG present: 查询 surface 能力失败（%1）").arg(int(result));
        return false;
    }

    if ((capabilities.supportedUsageFlags & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) == 0)
    {
        d->error = QStringLiteral("FG present: surface 不支持 COLOR_ATTACHMENT 用法");
        return false;
    }

    const VkExtent2D extent = chooseExtent(capabilities, d->extent);
    if (extent.width == 0 || extent.height == 0)
    {
        d->error = QStringLiteral("FG present: 交换链尺寸为 0（窗口可能已最小化）");
        return false;
    }

    quint32 imageCount = capabilities.minImageCount + 1;
    // 非 FIFO（MAILBOX/IMMEDIATE）时多要几张图，让渲染能跑到合成器前面。
    // 实测（1262x1370、插帧关、强制动画）：3 张 318fps vs 6 张 335fps，只差约 5%—— 所以
    // 交换链图像数从来不是"帧率上不去"的主因，主因是 FIFO 呈现模式本身（vkcube 实测
    // FIFO 47fps vs MAILBOX 125fps）以及场景静止时引擎主动休眠。多要几张只是顺带。
    // RHINE_FG_SWAP_IMAGES 可以覆盖（A/B 用：设 3 就退回旧行为）。
    if (d->presentMode != VK_PRESENT_MODE_FIFO_KHR) {
        static const int overrideImages = qEnvironmentVariableIntValue("RHINE_FG_SWAP_IMAGES");
        const quint32 wanted = overrideImages > 0 ? quint32(overrideImages) : 6u;
        if (imageCount < wanted)
            imageCount = wanted;
    }
    if (capabilities.maxImageCount > 0 && imageCount > capabilities.maxImageCount)
        imageCount = capabilities.maxImageCount;

    // 排障：OutOfDate 的成因几乎都在这些字段里（extent 与 surface 实际尺寸不符、
    // transform 不匹配、compositeAlpha/usage 选到了不支持的值）。只在显式开诊断时打，
    // 因为重建不频繁但也不希望正常运行时刷屏。
    if (qEnvironmentVariableIsSet("RHINE_FG_DIAG")) {
        qWarning().noquote()
            << "FG present: 交换链" << extent.width << "x" << extent.height
            << "· surface currentExtent" << capabilities.currentExtent.width << "x"
            << capabilities.currentExtent.height << "· min/max 图像"
            << capabilities.minImageCount << capabilities.maxImageCount << "选用" << imageCount
            << "· transform" << int(capabilities.currentTransform) << "· compositeAlpha"
            << QString::number(capabilities.supportedCompositeAlpha, 16)
            << "· usage" << QString::number(capabilities.supportedUsageFlags, 16);
    }

    VkSwapchainCreateInfoKHR info{};
    info.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    info.surface = d->surface;
    info.minImageCount = imageCount;
    info.imageFormat = d->format;
    info.imageColorSpace = d->colorSpace;
    info.imageExtent = extent;
    info.imageArrayLayers = 1;
    // TRANSFER_DST 让调用方可以把 FG 合成结果直接 blit 进来，不必再建中间目标。
    info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT
                      | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    info.preTransform = capabilities.currentTransform;
    info.compositeAlpha = chooseCompositeAlpha(capabilities.supportedCompositeAlpha);
    info.presentMode = d->presentMode;
    info.clipped = VK_TRUE;
    info.oldSwapchain = d->swapchain;

    // 事务式重建：新的交换链/视图/信号量全部在局部变量里建好，最后一步才替换
    // 旧状态。中途失败时旧交换链仍然完整可用，不会留下"视图没了但交换链还在"
    // 这种一半销毁的状态（那种状态下一次 acquire 会直接越界）。
    VkSwapchainKHR newSwapchain = VK_NULL_HANDLE;
    result = d->createSwapchain(d->device, &info, nullptr, &newSwapchain);
    if (result != VK_SUCCESS)
    {
        d->error = QStringLiteral("FG present: vkCreateSwapchainKHR 失败（%1）").arg(int(result));
        d->usable = false;
        return false;
    }

    auto abandon = [&](const QString &message) {
        for (VkSemaphore semaphore : d->pendingSemaphores)
        {
            if (semaphore != VK_NULL_HANDLE)
                d->destroySemaphore(d->device, semaphore, nullptr);
        }
        d->pendingSemaphores.clear();
        for (VkImageView view : d->pendingViews)
        {
            if (view != VK_NULL_HANDLE)
                d->destroyImageView(d->device, view, nullptr);
        }
        d->pendingViews.clear();
        if (newSwapchain != VK_NULL_HANDLE)
            d->destroySwapchain(d->device, newSwapchain, nullptr);
        d->usable = false;
        d->error = message;
        return false;
    };

    quint32 count = 0;
    result = d->getSwapchainImages(d->device, newSwapchain, &count, nullptr);
    if (result != VK_SUCCESS || count == 0)
        return abandon(QStringLiteral("FG present: 取交换链图像数量失败（%1）").arg(int(result)));

    QVector<VkImage> newImages(static_cast<int>(count));
    result = d->getSwapchainImages(d->device, newSwapchain, &count, newImages.data());
    if (result != VK_SUCCESS)
        return abandon(QStringLiteral("FG present: 取交换链图像失败（%1）").arg(int(result)));
    newImages.resize(static_cast<int>(count));

    d->pendingViews.clear();
    d->pendingViews.resize(static_cast<int>(count));
    for (int i = 0; i < static_cast<int>(count); ++i)
    {
        VkImageViewCreateInfo viewInfo{};
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        viewInfo.image = newImages[i];
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
        viewInfo.format = d->format;
        viewInfo.components = {VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY,
                               VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY};
        viewInfo.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        result = d->createImageView(d->device, &viewInfo, nullptr, &d->pendingViews[i]);
        if (result != VK_SUCCESS)
            return abandon(QStringLiteral("FG present: 创建交换链图像视图失败（%1）").arg(int(result)));
    }

    VkSemaphoreCreateInfo semaphoreInfo{};
    semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    d->pendingSemaphores.clear();
    d->pendingSemaphores.resize(static_cast<int>(count));
    for (int i = 0; i < static_cast<int>(count); ++i)
    {
        result = d->createSemaphore(d->device, &semaphoreInfo, nullptr, &d->pendingSemaphores[i]);
        if (result != VK_SUCCESS)
            return abandon(QStringLiteral("FG present: 创建呈现信号量失败（%1）").arg(int(result)));
    }

    // 到这里新交换链已经完全可用，可以安全地拆旧的。
    for (VkImageView view : d->views)
    {
        if (view != VK_NULL_HANDLE)
            d->destroyImageView(d->device, view, nullptr);
    }
    for (VkSemaphore semaphore : d->renderDone)
    {
        if (semaphore != VK_NULL_HANDLE)
            d->destroySemaphore(d->device, semaphore, nullptr);
    }
    if (d->swapchain != VK_NULL_HANDLE)
        d->destroySwapchain(d->device, d->swapchain, nullptr);

    d->swapchain = newSwapchain;
    d->images = newImages;
    d->views = d->pendingViews;
    d->renderDone = d->pendingSemaphores;
    d->pendingViews.clear();
    d->pendingSemaphores.clear();
    // 新交换链的图像句柄全变了，复用间隔必须重新起算，否则第一次会算出天文数字。
    d->lastPresentNs.assign(d->images.size(), 0);
    d->imageReuseMs = 0.0;

    d->extent = QSize(int(extent.width), int(extent.height));
    d->needsRecreate = false;
    d->usable = true;
    return true;
}

}  // namespace

VulkanPresenter::VulkanPresenter() : d(new Private) {}

VulkanPresenter::~VulkanPresenter()
{
    release();
}

bool VulkanPresenter::supported(QRhi *rhi)
{
    return rhi && rhi->backend() == QRhi::Vulkan;
}

bool VulkanPresenter::init(QRhi *rhi, VkSurfaceKHR surface, QSize extent, bool vsync)
{
    d->error.clear();
    if (!supported(rhi))
    {
        d->error = QStringLiteral("FG present: 只支持 Vulkan 后端");
        return false;
    }
    if (surface == VK_NULL_HANDLE)
    {
        d->error = QStringLiteral("FG present: 没有有效的 VkSurfaceKHR");
        return false;
    }

    const auto *handles = static_cast<const QRhiVulkanNativeHandles *>(rhi->nativeHandles());
    if (!handles || handles->dev == VK_NULL_HANDLE || handles->physDev == VK_NULL_HANDLE
        || !handles->inst)
    {
        d->error = QStringLiteral("FG present: QRhi 没有提供完整的 Vulkan 原生句柄");
        return false;
    }
    if (handles->gfxQueue == VK_NULL_HANDLE)
    {
        d->error = QStringLiteral("FG present: QRhi 没有暴露图形队列（gfxQueue 为空）");
        return false;
    }

    if (d->ready)
        release();

    d->rhi = rhi;
    d->instance = handles->inst->vkInstance();
    d->physicalDevice = handles->physDev;
    d->device = handles->dev;
    d->queue = handles->gfxQueue;
    d->queueFamily = handles->gfxQueueFamilyIdx;
    d->surface = surface;
    d->extent = extent;
    d->vsync = vsync;
    // 排障通道：强制走 vkDeviceWaitIdle + 无等待信号量的 present。
    // 用环境变量而不是编译开关，是因为"Qt 到底有没有消费 setQueueSubmitParams"
    // 只有真机跑起来才知道，需要能不改代码就切过去验证。
    d->forceIdleSync = qEnvironmentVariable("RHINE_FG_PRESENT_SYNC").trimmed().toLower()
                       == QStringLiteral("idle");

    if (!loadProcedures(d.get(), handles->inst))
        return false;

    VkBool32 supportedByQueue = VK_FALSE;
    const VkResult supportResult =
        d->getSurfaceSupport(d->physicalDevice, d->queueFamily, d->surface, &supportedByQueue);
    if (supportResult != VK_SUCCESS || supportedByQueue != VK_TRUE)
    {
        d->error = QStringLiteral("FG present: 图形队列不支持向这个 surface 呈现");
        return false;
    }

    quint32 formatCount = 0;
    if (d->getSurfaceFormats(d->physicalDevice, d->surface, &formatCount, nullptr) != VK_SUCCESS
        || formatCount == 0)
    {
        d->error = QStringLiteral("FG present: surface 没有可用格式");
        return false;
    }
    QVector<VkSurfaceFormatKHR> formats(static_cast<int>(formatCount));
    d->getSurfaceFormats(d->physicalDevice, d->surface, &formatCount, formats.data());
    formats.resize(int(formatCount));

    VkSurfaceFormatKHR chosen = formats.first();
    bool foundPreferred = false;
    for (const VkSurfaceFormatKHR &candidate : formats)
    {
        if ((candidate.format == VK_FORMAT_B8G8R8A8_UNORM
             || candidate.format == VK_FORMAT_R8G8B8A8_UNORM)
            && candidate.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
        {
            chosen = candidate;
            foundPreferred = true;
            break;
        }
    }
    if (!foundPreferred && formats.size() == 1 && formats[0].format == VK_FORMAT_UNDEFINED)
    {
        chosen.format = VK_FORMAT_B8G8R8A8_UNORM;
        chosen.colorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    }
    d->format = chosen.format;
    d->colorSpace = chosen.colorSpace;

    quint32 modeCount = 0;
    if (d->getSurfacePresentModes(d->physicalDevice, d->surface, &modeCount, nullptr)
            == VK_SUCCESS
        && modeCount > 0)
    {
        QVector<VkPresentModeKHR> modes(static_cast<int>(modeCount));
        d->getSurfacePresentModes(d->physicalDevice, d->surface, &modeCount, modes.data());
        modes.resize(int(modeCount));

        d->supportedPresentModes.clear();
        for (VkPresentModeKHR mode : modes)
            d->supportedPresentModes << QString::fromLatin1(presentModeLabel(mode));

        d->presentMode = VK_PRESENT_MODE_FIFO_KHR;
        if (!vsync)
        {
            for (VkPresentModeKHR mode : modes)
            {
                if (mode == VK_PRESENT_MODE_MAILBOX_KHR)
                {
                    d->presentMode = mode;
                    break;
                }
            }
            if (d->presentMode == VK_PRESENT_MODE_FIFO_KHR)
            {
                for (VkPresentModeKHR mode : modes)
                {
                    if (mode == VK_PRESENT_MODE_IMMEDIATE_KHR)
                    {
                        d->presentMode = mode;
                        break;
                    }
                }
            }
        }
    }

    if (!createSwapchain(d.get()))
        return false;

    VkSemaphoreCreateInfo semaphoreInfo{};
    semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    VkFenceCreateInfo fenceInfo{};
    fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    // 不能带 SIGNALED：vkQueueSubmit 要求传入的围栏在调用时是无信号的。
    // "槽还没被用过"这件事由 slotInUse 跟踪，不需要靠初始信号表达。
    fenceInfo.flags = 0;

    for (int i = 0; i < kFrameSlots; ++i)
    {
        VkResult result = d->createSemaphore(d->device, &semaphoreInfo, nullptr,
                                             &d->acquireSemaphore[i]);
        if (result == VK_SUCCESS)
            result = d->createSemaphore(d->device, &semaphoreInfo, nullptr,
                                        &d->submitWaitSemaphore[i]);
        if (result == VK_SUCCESS)
            result = d->createFence(d->device, &fenceInfo, nullptr, &d->slotFence[i]);
        if (result != VK_SUCCESS)
        {
            d->error = QStringLiteral("FG present: 创建帧槽同步对象失败（%1）").arg(int(result));
            return false;
        }
        d->slotInUse[i] = false;
    }

    d->ready = true;
    d->slot = 0;
    d->lastSlot = -1;
    qInfo().noquote() << "FG present: 已建立" << d->extent << "的交换链，格式"
                      << int(d->format) << "，共" << d->images.size() << "张图像";
    // 启动报告：一次把"这条 Vulkan 呈现链路处在什么配置"讲清楚。
    // 只在初始化/重建时打，正常运行时不会刷屏。
    queryPresentExtensionSupport(d.get(), handles->inst);
    qInfo().noquote() << "FG present 配置:" << describePresentSetup(d.get(), handles->inst);
    return true;
}

void VulkanPresenter::release()
{
    if (d->device != VK_NULL_HANDLE && d->deviceWaitIdle)
        d->deviceWaitIdle(d->device);

    destroySwapchainObjects(d.get());

    for (int i = 0; i < kFrameSlots; ++i)
    {
        if (d->acquireSemaphore[i] != VK_NULL_HANDLE && d->destroySemaphore)
            d->destroySemaphore(d->device, d->acquireSemaphore[i], nullptr);
        if (d->submitWaitSemaphore[i] != VK_NULL_HANDLE && d->destroySemaphore)
            d->destroySemaphore(d->device, d->submitWaitSemaphore[i], nullptr);
        if (d->slotFence[i] != VK_NULL_HANDLE && d->destroyFence)
            d->destroyFence(d->device, d->slotFence[i], nullptr);
        d->acquireSemaphore[i] = VK_NULL_HANDLE;
        d->submitWaitSemaphore[i] = VK_NULL_HANDLE;
        d->slotFence[i] = VK_NULL_HANDLE;
        d->slotInUse[i] = false;
        d->submitWaitPending[i] = false;
    }

    d->hasPending = false;
    d->paramsInstalled = false;
    d->params = {};
    d->ready = false;
    d->usable = false;
    d->lastSlot = -1;
    d->needsRecreate = false;
    d->swapchain = VK_NULL_HANDLE;
    d->images.clear();
    d->views.clear();
    d->renderDone.clear();
    d->device = VK_NULL_HANDLE;
    d->physicalDevice = VK_NULL_HANDLE;
    d->queue = VK_NULL_HANDLE;
    d->surface = VK_NULL_HANDLE;
    d->instance = VK_NULL_HANDLE;
    d->rhi = nullptr;
}

bool VulkanPresenter::resize(QSize extent, bool force)
{
    d->error.clear();
    if (!d->ready)
    {
        d->error = QStringLiteral("FG present: 交换链还没有初始化");
        return false;
    }
    if (!extent.isValid() || extent.width() <= 0 || extent.height() <= 0)
    {
        d->error = QStringLiteral("FG present: 无效的新尺寸");
        return false;
    }
    // force 时无条件重建：OutOfDate 的交换链即使尺寸没变也已经不可用。
    if (!force && extent == d->extent && d->swapchain != VK_NULL_HANDLE && d->usable)
        return true;

    flushDeferredPresent();
    // 重建会销毁旧交换链；此时可能还有在飞的帧，先等 GPU 空闲。
    // 这是 resize 路径上唯一的一次硬同步，不在每帧路径上。
    if (d->deviceWaitIdle)
        d->deviceWaitIdle(d->device);

    const QSize previous = d->extent;
    d->extent = extent;
    d->needsRecreate = false;
    if (!createSwapchain(d.get()))
    {
        // 重建失败时恢复旧尺寸：否则下一次 resize(同一尺寸) 会被"尺寸没变"提前返回，
        // 调用方以为交换链已经好了，实际仍是坏的。
        d->extent = previous;
        return false;
    }
    return true;
}

VulkanPresenter::AcquireResult VulkanPresenter::acquire(Frame *out)
{
    d->error.clear();
    if (!out)
        return AcquireResult::Error;
    *out = Frame{};

    if (!d->ready || d->swapchain == VK_NULL_HANDLE || !d->usable)
    {
        d->error = QStringLiteral("FG present: 交换链不可用");
        return AcquireResult::OutOfDate;
    }

    if (d->hasPending)
        flushDeferredPresent();
    if (d->needsRecreate)
        return AcquireResult::OutOfDate;

    const int slot = d->slot;
    if (d->slotInUse[slot])
    {
        // 这个槽上一次的空提交还没完成，说明 acquire 信号量还被队列占着。
        // 空提交没有任何命令，正常情况下这里几乎不会真的等。
        const VkResult waitResult =
            d->waitForFences(d->device, 1, &d->slotFence[slot], VK_TRUE, kAcquireTimeoutNs);
        if (waitResult == VK_TIMEOUT)
        {
            d->error = QStringLiteral("FG present: 等待帧槽围栏超时");
            return AcquireResult::Timeout;
        }
        if (waitResult != VK_SUCCESS)
        {
            d->error = QStringLiteral("FG present: 等待帧槽围栏失败（%1）").arg(int(waitResult));
            return AcquireResult::Error;
        }
        d->resetFences(d->device, 1, &d->slotFence[slot]);
    }

    if (d->submitWaitPending[slot])
    {
        // 上一帧没有走到 present（调用方漏了 installSubmitParams，或 present 失败），
        // 这个槽的 submitWaitSemaphore 还停在有信号状态。用一个"只等不信号"的空
        // 提交把它消费掉，否则下一次 signal 同一个二进制信号量是非法用法。
        VkPipelineStageFlags recoverStage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
        VkSubmitInfo recover{};
        recover.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        recover.waitSemaphoreCount = 1;
        recover.pWaitSemaphores = &d->submitWaitSemaphore[slot];
        recover.pWaitDstStageMask = &recoverStage;
        const VkResult recoverResult =
            d->queueSubmit(d->queue, 1, &recover, d->slotFence[slot]);
        if (recoverResult != VK_SUCCESS)
        {
            d->error = QStringLiteral("FG present: 回收悬空信号量失败（%1）").arg(int(recoverResult));
            return AcquireResult::Error;
        }
        d->slotInUse[slot] = true;
        d->submitWaitPending[slot] = false;
        const VkResult waitResult =
            d->waitForFences(d->device, 1, &d->slotFence[slot], VK_TRUE, kAcquireTimeoutNs);
        if (waitResult != VK_SUCCESS)
        {
            d->error = QStringLiteral("FG present: 等待信号量回收提交失败（%1）").arg(int(waitResult));
            return AcquireResult::Error;
        }
        d->resetFences(d->device, 1, &d->slotFence[slot]);
    }

    quint32 imageIndex = 0;
    VkResult result = d->acquireNextImage(d->device, d->swapchain, kAcquireTimeoutNs,
                                          d->acquireSemaphore[slot], VK_NULL_HANDLE, &imageIndex);
    if (result == VK_TIMEOUT || result == VK_NOT_READY)
    {
        d->error = QStringLiteral("FG present: 等不到可用交换链图像（窗口可能最小化）");
        return AcquireResult::Timeout;
    }
    if (result == VK_ERROR_OUT_OF_DATE_KHR)
    {
        d->needsRecreate = true;
        return AcquireResult::OutOfDate;
    }
    if (result == VK_ERROR_SURFACE_LOST_KHR)
    {
        d->needsRecreate = true;
        d->error = QStringLiteral("FG present: surface 已丢失，需要重建");
        return AcquireResult::Error;
    }
    if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR)
    {
        d->error = QStringLiteral("FG present: vkAcquireNextImageKHR 失败（%1）").arg(int(result));
        return AcquireResult::Error;
    }
    const bool suboptimal = (result == VK_SUBOPTIMAL_KHR);
    if (suboptimal)
        d->needsRecreate = true;

    // 空提交（0 个命令缓冲区）：把"图像已可用"这个信号量转成 Qt 提交能等待的
    // 信号量，同时让这个帧槽有一个可观测的围栏。Vulkan 允许只带信号量的提交，
    // 这正是把 acquire 信号量的生命周期和渲染提交对齐的标准做法。
    VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo submit{};
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.waitSemaphoreCount = 1;
    submit.pWaitSemaphores = &d->acquireSemaphore[slot];
    submit.pWaitDstStageMask = &waitStage;
    // 强制空闲模式下 Qt 不会等这个信号量，所以也不能 signal 它，否则它会一直
    // 停在有信号状态、下一帧再 signal 就非法。
    submit.signalSemaphoreCount = d->forceIdleSync ? 0u : 1u;
    submit.pSignalSemaphores = d->forceIdleSync ? nullptr : &d->submitWaitSemaphore[slot];
    result = d->queueSubmit(d->queue, 1, &submit, d->slotFence[slot]);
    if (result != VK_SUCCESS)
    {
        d->error = QStringLiteral("FG present: 信号量链提交失败（%1）").arg(int(result));
        return AcquireResult::Error;
    }
    d->slotInUse[slot] = true;
    d->submitWaitPending[slot] = !d->forceIdleSync;

    if (int(imageIndex) >= d->images.size() || int(imageIndex) >= d->views.size())
    {
        d->error = QStringLiteral("FG present: acquire 返回了越界的图像索引");
        return AcquireResult::Error;
    }

    d->lastSlot = slot;
    d->lastImageIndex = imageIndex;
    d->slot = (slot + 1) % kFrameSlots;

    out->imageIndex = imageIndex;
    out->image = d->images[int(imageIndex)];
    out->view = d->views[int(imageIndex)];
    return suboptimal ? AcquireResult::Suboptimal : AcquireResult::Ok;
}

bool VulkanPresenter::installSubmitParams(QRhi *rhi, const Frame &frame)
{
    d->error.clear();
    if (!d->ready || !rhi)
    {
        d->error = QStringLiteral("FG present: 注入提交参数前没有可用的交换链");
        return false;
    }
    if (d->lastSlot < 0 || frame.imageIndex != d->lastImageIndex)
    {
        d->error = QStringLiteral("FG present: 注入的帧与最近一次 acquire 不匹配");
        return false;
    }

    if (d->forceIdleSync)
    {
        // 排障通道：不注入信号量，present 会先 vkDeviceWaitIdle 再呈现。
        d->paramsInstalled = true;
        return true;
    }

    d->params = QRhiVulkanQueueSubmitParams{};
    d->params.waitSemaphoreCount = 1;
    d->params.waitSemaphores = &d->submitWaitSemaphore[d->lastSlot];
    d->params.signalSemaphoreCount = 1;
    d->params.signalSemaphores = &d->renderDone[int(frame.imageIndex)];
    // present 由本类自己做，不需要 QRhi 帮忙挂 present 等待信号量。
    d->params.presentWaitSemaphoreCount = 0;
    d->params.presentWaitSemaphores = nullptr;

    rhi->setQueueSubmitParams(&d->params);
    d->paramsInstalled = true;
    return true;
}

bool VulkanPresenter::present(const Frame &frame, bool *needsRecreate)
{
    d->error.clear();
    if (needsRecreate)
        *needsRecreate = false;
    if (!d->ready || d->swapchain == VK_NULL_HANDLE || !d->usable)
    {
        d->error = QStringLiteral("FG present: 交换链不可用");
        return false;
    }
    if (int(frame.imageIndex) >= d->renderDone.size())
    {
        d->error = QStringLiteral("FG present: 图像索引越界");
        return false;
    }

    // 只有真的把 renderDone 注入给 Qt 的提交，才能等它；否则这个信号量永远不会
    // 有信号，present 会在驱动里挂死。两种情况都退回设备空闲同步，画面正确、
    // 代价是这一帧掉到同步节奏。
    const bool waitOnRenderDone = d->paramsInstalled && !d->forceIdleSync;
    if (!waitOnRenderDone && !d->forceIdleSync && !d->warnedIdleFallback)
    {
        // 走到这里说明 installSubmitParams() 没成功（图像索引不匹配等）：present 只能等
        // 整个 VkDevice 排空，单次 50ms 级，帧生成会退化到同步节奏。以前这条路径完全
        // 静默，排障时只能看到"上屏 55ms"却查不到原因，所以至少要留下一条日志。
        d->warnedIdleFallback = true;
        qWarning().noquote() << "FG present: 本帧未注入提交参数，退回 vkDeviceWaitIdle 硬同步"
                             << d->error;
    }
    if (!waitOnRenderDone && d->deviceWaitIdle)
        d->deviceWaitIdle(d->device);

    VkPresentInfoKHR info{};
    info.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    info.waitSemaphoreCount = waitOnRenderDone ? 1u : 0u;
    info.pWaitSemaphores = waitOnRenderDone ? &d->renderDone[int(frame.imageIndex)] : nullptr;
    info.swapchainCount = 1;
    info.pSwapchains = &d->swapchain;
    info.pImageIndices = &frame.imageIndex;

    const VkResult result = d->queuePresent(d->queue, &info);
    if (waitOnRenderDone && d->lastSlot >= 0 && d->lastSlot < kFrameSlots)
    {
        // present 消费了 renderDone，等价于 Qt 的提交已经消费过 submitWaitSemaphore。
        d->submitWaitPending[d->lastSlot] = false;
    }
    d->paramsInstalled = false;
    if (result == VK_ERROR_OUT_OF_DATE_KHR)
    {
        d->needsRecreate = true;
        if (needsRecreate)
            *needsRecreate = true;
        return false;
    }
    if (result == VK_ERROR_SURFACE_LOST_KHR)
    {
        d->needsRecreate = true;
        d->error = QStringLiteral("FG present: surface 已丢失");
        if (needsRecreate)
            *needsRecreate = true;
        return false;
    }
    if (result == VK_SUBOPTIMAL_KHR)
    {
        // Suboptimal 只表示"这张图已经呈现出去，但交换链不再最优"（常见于窗口尺寸刚变）。
        // 为此整链重建（deviceWaitIdle + 5 张 image/view/semaphore + 全部纹理与管线）代价
        // 太高，而且重建本身会再吃几帧——实测 gapP50 26ms 与均值 52ms 的双峰就是它造成的。
        // 真正的重建交给 VK_ERROR_OUT_OF_DATE_KHR 与窗口的 Resize/Expose 事件。
        if (!d->warnedSuboptimal)
        {
            d->warnedSuboptimal = true;
            qWarning().noquote() << "FG present: 交换链 suboptimal（继续使用，等 OutOfDate 或窗口事件再重建）";
        }
        notePresentedImage(d.get(), frame.imageIndex);
        return true;
    }
    if (result != VK_SUCCESS)
    {
        d->error = QStringLiteral("FG present: vkQueuePresentKHR 失败（%1）").arg(int(result));
        return false;
    }
    notePresentedImage(d.get(), frame.imageIndex);
    return true;
}

bool VulkanPresenter::presentDeferred(const Frame &frame)
{
    if (d->hasPending)
        flushDeferredPresent();
    d->pendingFrame = frame;
    d->hasPending = true;
    return true;
}

bool VulkanPresenter::flushDeferredPresent()
{
    if (!d->hasPending)
        return true;
    const Frame frame = d->pendingFrame;
    d->hasPending = false;
    return present(frame, nullptr);
}

bool VulkanPresenter::ready() const
{
    return d->ready;
}

QSize VulkanPresenter::extent() const
{
    return d->extent;
}

VkFormat VulkanPresenter::colorFormat() const
{
    return d->format;
}

quint32 VulkanPresenter::imageCount() const
{
    return quint32(d->images.size());
}

QString VulkanPresenter::presentModeName() const
{
    // 这个字符串会直接显示在性能面板上，所以用 Vulkan 的正式名字，方便和
    // 外部工具（vulkaninfo / vkcube --present_mode）的输出对齐。
    switch (d->presentMode)
    {
    case VK_PRESENT_MODE_MAILBOX_KHR:
        return QStringLiteral("MAILBOX");
    case VK_PRESENT_MODE_IMMEDIATE_KHR:
        return QStringLiteral("IMMEDIATE");
    case VK_PRESENT_MODE_FIFO_RELAXED_KHR:
        return QStringLiteral("FIFO_RELAXED");
#ifdef VK_PRESENT_MODE_FIFO_LATEST_READY_KHR
    case VK_PRESENT_MODE_FIFO_LATEST_READY_KHR:
        return QStringLiteral("FIFO_LATEST_READY");
#endif
    case VK_PRESENT_MODE_FIFO_KHR:
        return QStringLiteral("FIFO");
    default:
        return QStringLiteral("UNKNOWN");
    }
}

double VulkanPresenter::imageReuseMs() const
{
    return d->imageReuseMs;
}

VkImage VulkanPresenter::imageAt(quint32 index) const
{
    return index < quint32(d->images.size()) ? d->images.at(int(index)) : VK_NULL_HANDLE;
}

quint32 VulkanPresenter::indexOf(VkImage image) const
{
    for (int i = 0; i < d->images.size(); ++i) {
        if (d->images.at(i) == image)
            return quint32(i);
    }
    return UINT32_MAX;
}

QString VulkanPresenter::lastError() const
{
    return d->error;
}
