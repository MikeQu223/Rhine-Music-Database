#include "PresentationBackend.h"
#include "PresentationWindow.h"
#include "RenderPolicy.h"
#include "../fg/VulkanPresenter.h"
#include "../AppStorage.h"
#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QVulkanFunctions>
#include <QVulkanInstance>
#include <QWindow>
#include <cstring>
#include <rhi/qrhi_platform.h>
#include <vector>

namespace RhineRender {
namespace {
// 管线缓存是「驱动版本 + 设备 ID + pipelineCacheUUID」的函数：换驱动或换卡后旧数据
// 不仅无用，还可能被驱动判为非法。文件头做一次自校验，不匹配就直接丢弃。
struct PipelineCacheHeader {
    quint32 magic = 0;
    quint32 vendorId = 0;
    quint32 deviceId = 0;
    quint32 driverVersion = 0;
    quint32 apiVersion = 0;
    quint8 uuid[VK_UUID_SIZE] = {};
};
constexpr quint32 kPipelineCacheMagic = 0x52484E31u; // "RHN1"
QString qrhiPipelineCachePath() {
    return AppStorage::cacheDirectory() + QStringLiteral("/shaders/qrhi-pipeline.cache");
}

/** Vulkan 专属句柄、图像布局与提交信号量只在本适配器中出现。 */
class VulkanPresentationBackend final : public PresentationBackend {
  public:
    ~VulkanPresentationBackend() override {
        destroyDevice();
        m_window.reset();
        m_instance.reset();
    }
    bool initialize(QSize logicalSize, bool vsync) override {
        m_instance = std::make_unique<QVulkanInstance>();
        // 交换链与 present 只要 1.1 就够；调高只会让旧驱动在设备创建时更容易失败。
        m_instance->setApiVersion(QVersionNumber(1, 1));
        if (!m_instance->create()) {
            m_error =
                QStringLiteral("QVulkanInstance 创建失败（errorCode=%1）").arg(int(m_instance->errorCode()));
            return false;
        }

        m_window = std::make_unique<PresentationWindow>();
        // 必须声明成 Vulkan surface：平台窗口默认按 raster/OpenGL 建，
        // 那样 surfaceForWindow() 永远返回 VK_NULL_HANDLE。
        m_window->setSurfaceType(QSurface::VulkanSurface);
        m_window->setVulkanInstance(m_instance.get());
#ifdef Q_OS_WIN
        m_window->setTitle(QStringLiteral("RHINE MUSIC DATABASE"));
        m_window->setMinimumSize(QSize(960, 540));
        // 必须在创建 HWND 和 Vulkan surface 前确定无边框属性。
        m_window->setFlags(Qt::Window | Qt::FramelessWindowHint | Qt::WindowTitleHint |
                           Qt::WindowSystemMenuHint | Qt::WindowMinMaxButtonsHint |
                           Qt::WindowCloseButtonHint | Qt::WindowFullscreenButtonHint);
#else
        m_window->setTitle(QStringLiteral("Rhine Music Database"));
#endif
        m_window->resize(logicalSize);
        m_window->create();
        if (!m_window->handle()) {
            m_error = QStringLiteral("QWindow 没有创建出平台窗口");
            return false;
        }

        m_window->show();
        // Wayland 下 surface 要等窗口真正 expose 之后才存在，只 create() 会拿到空句柄。
        QElapsedTimer exposeClock;
        exposeClock.start();
        while (!m_window->isExposed() && exposeClock.elapsed() < 2000) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        }

        m_vsync = vsync;
        return createDevice();
    }
    QWindow *window() const override {
        return m_window.get();
    }
    QRhi *rhi() const override {
        return m_rhi.get();
    }
    QVulkanInstance *vulkanInstance() const override {
        return m_instance.get();
    }
    bool resize(QSize size, bool force) override {
        // 尺寸没变时必须只做判断、不碰 GPU：每重建一次都要 m_rhi->finish()（等设备空闲）
        // 并重扫全部交换链包装目标，而 VulkanPresenter::resize 内部的"同尺寸就返回"是在
        // finish() 之后才被调用，省不掉那次硬同步。呈现层在没有尺寸变化时也会一路把尺寸
        // 同步下来，所以这层去重必须放在 finish() 之前，否则去重形同虚设（A10）。
        if (!force && m_presenter && !m_swapTargets.empty() && size == m_size &&
            m_swapSize == m_presenter->extent()) {
            ++m_resizeSkips;
            return true;
        }
        m_rhi->finish();
        // 只统计重建路径上的等待：release() 里那次 finish 是退出清理，混进来会让
        // "每重建一次就等一次"的比例失真。
        ++m_deviceIdleWaits;
        releaseTargets();
        if (!m_presenter->resize(size, force)) {
            m_error = m_presenter->lastError();
            return false;
        }
        // 记下真正生效的尺寸（presenter 会按 surface 能力裁剪），下一次同尺寸判断才对得上。
        m_size = m_presenter->extent();
        ++m_swapchainRecreates;
        return ensureTargets();
    }
    AcquireResult acquire(Frame *frame) override {
        const auto result = m_presenter->acquire(&m_nativeFrame);
        frame->imageIndex = m_nativeFrame.imageIndex;
        switch (result) {
        case VulkanPresenter::AcquireResult::Ok:
            return AcquireResult::Ok;
        case VulkanPresenter::AcquireResult::Suboptimal:
            return AcquireResult::Suboptimal;
        case VulkanPresenter::AcquireResult::OutOfDate:
            return AcquireResult::OutOfDate;
        case VulkanPresenter::AcquireResult::Timeout:
            return AcquireResult::Timeout;
        default:
            return AcquireResult::Error;
        }
    }
    QRhi::FrameOpResult beginFrame(const Frame &, QRhiCommandBuffer **commands) override {
        // A02：帧槽等待只在这里量。beginOffscreenFrame 内部要等上一帧的命令缓冲/围栏
        // 归还，以前这段时间被算进 beginMs 却没人说清它在等什么。计时只读时钟，
        // 不插入额外同步，也不改变提交顺序或队列/信号量逻辑。
        QElapsedTimer slotTimer;
        slotTimer.start();
        const QRhi::FrameOpResult result = m_rhi->beginOffscreenFrame(commands);
        m_lastSlotWaitMs = double(slotTimer.nsecsElapsed()) / 1e6;
        if (result == QRhi::FrameOpSuccess) {
            // 只统计真正进入的离屏帧；失败时调用方不会走 endFrame，不该记成一次提交。
            ++m_offscreenSubmitCount;
        }
        return result;
    }
    QRhiRenderTarget *target(const Frame &frame) const override {
        if (frame.imageIndex >= m_swapTargets.size()) {
            return nullptr;
        }
        m_swapTextures[frame.imageIndex]->setNativeLayout(int(VK_IMAGE_LAYOUT_UNDEFINED));
        return m_swapTargets[frame.imageIndex].get();
    }
    bool finishTarget(QRhiCommandBuffer *cb, const Frame &frame) override {
        // 呈现引擎要求图像处于 PRESENT_SRC_KHR。QRhi 不知道这张图会被 present，
        // 所以这一步只能自己发屏障。
        const auto *handles = static_cast<const QRhiVulkanCommandBufferNativeHandles *>(cb->nativeHandles());
        if (!handles || handles->commandBuffer == VK_NULL_HANDLE) {
            return false;
        }

        VkImageMemoryBarrier barrier{};
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.dstAccessMask = 0;
        barrier.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = m_presenter->imageAt(frame.imageIndex);
        barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};

        QVulkanDeviceFunctions *deviceFunctions = m_instance->deviceFunctions(m_device);
        if (!deviceFunctions) {
            return false;
        }

        cb->beginExternal();
        deviceFunctions->vkCmdPipelineBarrier(handles->commandBuffer,
                                              VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                              VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, //
                                              0, 0, nullptr, 0, nullptr, 1, &barrier);
        cb->endExternal();
        return true;
    }

    bool endFrame(const Frame &, bool rendered) override {
        const bool installed = rendered && m_presenter->installSubmitParams(m_rhi.get(), m_nativeFrame);
        m_rhi->endOffscreenFrame();
        if (!installed) {
            m_error = m_presenter->lastError();
            return false;
        }
        const bool presented = m_presenter->present(m_nativeFrame, nullptr);
        if (!presented) {
            m_error = m_presenter->lastError();
        } else if (++m_framesSubmitted == 240) {
            // 管线在启动阶段就编译完了，之后只有切分辨率/换格式才会新增。
            // 提前落盘一次，被强杀（开发时常用 Ctrl-C / kill）也不会丢掉这批编译成果。
            savePipelineCache();
        }
        return presented;
    }
    void release() override {
        if (m_rhi) {
            m_rhi->finish();
        }
        releaseTargets();
        if (m_presenter) {
            m_presenter->release();
        }
    }
    bool ready() const override {
        return m_presenter && m_presenter->ready();
    }
    QSize extent() const override {
        return m_presenter ? m_presenter->extent() : QSize();
    }
    int startupProbeFrames() const override {
        // 保留自持 Vulkan 交换链的连续呈现预检，识别只成功呈现最初几帧的设备。
        return 20;
    }
    quint32 imageCount() const override {
        return m_presenter ? m_presenter->imageCount() : 0;
    }
    QString formatName() const override {
        switch (int(m_presenter->colorFormat())) {
        case 37:
            return QStringLiteral("R8G8B8A8_UNORM");
        case 43:
            return QStringLiteral("R8G8B8A8_SRGB");
        case 44:
            return QStringLiteral("B8G8R8A8_UNORM");
        case 50:
            return QStringLiteral("B8G8R8A8_SRGB");
        case 58:
            return QStringLiteral("A2B10G10R10_UNORM_PACK32");
        case 97:
            return QStringLiteral("R16G16B16A16_SFLOAT");
        default:
            return QStringLiteral("VkFormat %1").arg(int(m_presenter->colorFormat()));
        }
    }
    QString presentModeName() const override {
        return m_presenter->presentModeName();
    }
    double imageReuseMs() const override {
        return m_presenter ? m_presenter->imageReuseMs() : 0.0;
    }
    quint64 swapchainRecreates() const override {
        return m_swapchainRecreates;
    }
    quint64 deviceIdleWaits() const override {
        return m_deviceIdleWaits;
    }
    quint64 resizeSkips() const override {
        return m_resizeSkips;
    }
    quint64 offscreenSubmits() const override {
        return m_offscreenSubmitCount;
    }
    double slotWaitMs() const override {
        return m_lastSlotWaitMs;
    }
    QString backendName() const override {
        return QStringLiteral("Vulkan");
    }
    QString lastError() const override {
        return m_error;
    }

  private:
    /// 把上一进程存下的管线缓存灌回 QRhi；设备或驱动换了就整块丢弃。
    void restorePipelineCache(VkPhysicalDevice physDev) {
        if (!m_rhi || physDev == VK_NULL_HANDLE ||
            !m_rhi->isFeatureSupported(QRhi::PipelineCacheDataLoadSave)) {
            return;
        }
        QFile file(qrhiPipelineCachePath());
        if (!file.open(QIODevice::ReadOnly)) {
            return;
        }
        const QByteArray blob = file.readAll();
        if (blob.size() <= int(sizeof(PipelineCacheHeader))) {
            return;
        }
        PipelineCacheHeader header;
        std::memcpy(&header, blob.constData(), sizeof(header));
        VkPhysicalDeviceProperties props{};
        m_instance->functions()->vkGetPhysicalDeviceProperties(physDev, &props);
        const bool sameDevice = header.magic == kPipelineCacheMagic &&
                                header.vendorId == props.vendorID &&
                                header.deviceId == props.deviceID &&
                                header.driverVersion == props.driverVersion &&
                                header.apiVersion == props.apiVersion &&
                                std::memcmp(header.uuid, props.pipelineCacheUUID, VK_UUID_SIZE) == 0;
        if (!sameDevice) {
            // 静默丢弃：不同机器/驱动之间共享缓存目录是常态，不值得警告。
            return;
        }
        const QByteArray payload = blob.mid(int(sizeof(header)));
        m_rhi->setPipelineCacheData(payload);
        qInfo().noquote() << "QRhi 管线缓存: 已恢复" << payload.size() << "字节 ←"
                          << QDir::toNativeSeparators(qrhiPipelineCachePath());
    }
    /// 退出前落盘；管线缓存只对「下次启动的同一驱动」有用。
    void savePipelineCache() {
        if (!m_rhi || m_physDev == VK_NULL_HANDLE ||
            !m_rhi->isFeatureSupported(QRhi::PipelineCacheDataLoadSave)) {
            return;
        }
        const QByteArray data = m_rhi->pipelineCacheData();
        if (data.isEmpty()) {
            return;
        }
        VkPhysicalDeviceProperties props{};
        m_instance->functions()->vkGetPhysicalDeviceProperties(m_physDev, &props);
        PipelineCacheHeader header;
        header.magic = kPipelineCacheMagic;
        header.vendorId = props.vendorID;
        header.deviceId = props.deviceID;
        header.driverVersion = props.driverVersion;
        header.apiVersion = props.apiVersion;
        std::memcpy(header.uuid, props.pipelineCacheUUID, VK_UUID_SIZE);
        const QString path = qrhiPipelineCachePath();
        QDir().mkpath(QFileInfo(path).absolutePath());
        QSaveFile file(path);
        if (!file.open(QIODevice::WriteOnly)) {
            return;
        }
        file.write(reinterpret_cast<const char *>(&header), sizeof(header));
        file.write(data);
        file.commit();
    }
    /// 提交过多少帧；用来在启动阶段结束后提前落盘一次管线缓存。
    int m_framesSubmitted = 0;

    bool createDevice() {
        QRhiVulkanInitParams params;
        params.inst = m_instance.get();
        // 自建交换链需要设备支持该扩展；QRhi 默认不请求它。
        params.deviceExtensions = {QByteArrayLiteral("VK_KHR_swapchain")};
        // EnablePipelineCacheDataSave：让 QRhi 暴露 pipelineCacheData()/setPipelineCacheData()，
        // 否则每次启动都要重新编译全部场景管线（核显上单次编译可达数百毫秒）。
        // EnableTimestamps：不请求的话 isFeatureSupported(QRhi::Timestamps) 直接是 false，
        // 渲染器只能在"设备不支持"和"没开"之间瞎猜，面板永远给不出可信的 GPU 耗时（A01）。
        m_rhi.reset(QRhi::create(QRhi::Vulkan, &params,
                                 QRhi::EnablePipelineCacheDataSave | QRhi::EnableTimestamps));
        if (!m_rhi) {
            m_error = QStringLiteral("QRhi(Vulkan) 创建失败");
            return false;
        }
        // 登记"时间戳已经请求过"。离屏层通过 QQuickGraphicsDevice::fromRhi 共用这台
        // 设备，所以这一处登记同时覆盖 FG 路径；漏登记会让 classifyGpuTiming() 把
        // "已请求但本帧没样本"误判成"没请求"，把配置缺口说成驱动延迟。
        if (m_rhi->isFeatureSupported(QRhi::Timestamps)) {
            RhineRender::requestTimestamps();
        }

        const auto *native = static_cast<const QRhiVulkanNativeHandles *>(m_rhi->nativeHandles());
        m_device = native->dev;
        m_physDev = native->physDev;
        if (m_device == VK_NULL_HANDLE) {
            m_error = QStringLiteral("拿不到 QRhi 的 VkDevice");
            return false;
        }
        // 必须在任何管线创建之前灌入，否则缓存只对之后创建的管线生效。
        restorePipelineCache(m_physDev);

        const VkSurfaceKHR surface = QVulkanInstance::surfaceForWindow(m_window.get());
        if (surface == VK_NULL_HANDLE) {
            m_error = QStringLiteral("拿不到 QWindow 的 VkSurfaceKHR");
            return false;
        }

        m_size = m_window->size();
        m_presenter = std::make_unique<VulkanPresenter>();
#ifdef Q_OS_WIN
        // Windows 高 DPI 下交换链按物理像素建立。
        const QSize swapchainSize = m_size * m_window->devicePixelRatio();
#else
        // 其他平台由 surface 的 currentExtent 决定交换链大小。
        const QSize swapchainSize = m_size;
#endif
        if (!m_presenter->init(m_rhi.get(), surface, swapchainSize, m_vsync)) {
            m_error = QStringLiteral("交换链创建失败：%1").arg(m_presenter->lastError());
            return false;
        }
        const bool targetsReady = ensureTargets();
        // 上面那次赋值是窗口逻辑尺寸，只用于推导 swapchainSize。从这里起 m_size 表示
        // "已生效的交换链尺寸"（像素），与 resize() 的入参同一口径——高 DPI 下逻辑像素
        // 和物理像素永远不相等，混用会让同尺寸判断永远失败、每帧都重建。
        m_size = m_presenter->extent();
        return targetsReady;
    }

    void destroyDevice() {
        release();
        // 交换链与 render target 先拆，管线缓存数据在 QRhi 还活着时导出。
        m_presenter.reset();
        savePipelineCache();
        m_rhi.reset();
        m_device = VK_NULL_HANDLE;
        m_physDev = VK_NULL_HANDLE;
        m_nativeFrame = {};
    }

    void releaseTargets() {
        m_swapTargets.clear();
        m_swapPasses.clear();
        m_swapTextures.clear();
        m_swapSize = {};
    }
    bool ensureTargets() {
        if (!m_presenter || !m_presenter->ready()) {
            return false;
        }
        const quint32 count = m_presenter->imageCount();
        const QSize extent = m_presenter->extent();
        if (count == 0 || extent.isEmpty()) {
            return false;
        }
        if (!m_swapTextures.empty() && m_swapSize == extent &&
            qint32(m_swapTextures.size()) == qint32(count)) {
            return true;
        }
        releaseTargets();
        m_swapSize = extent;

        for (quint32 i = 0; i < count; ++i) {
            const VkImage image = m_presenter->imageAt(i);
            if (image == VK_NULL_HANDLE) {
                m_error = QStringLiteral("交换链第 %1 张图像为空").arg(i);
                return false;
            }
            // 包装格式必须与交换链图像的真实通道序一致。QRhi 里 RGBA8 与 BGRA8 是两个
            // 不同的格式：按 RGBA8 去解释一张 B8G8R8A8 图像，着色器写进第 0 字节的 R
            // 会被合成器当成 B 读出来——整屏 R/B 互换（暖色场景整体发蓝，AA 边缘出现
            // 彩色光点）。presenter 只会选 B8G8R8A8_UNORM(44) 或 R8G8B8A8_UNORM(37)。
            const int swapFormat = int(m_presenter->colorFormat());
            const QRhiTexture::Format textureFormat =
                (swapFormat == 44 || swapFormat == 50) ? QRhiTexture::BGRA8 : QRhiTexture::RGBA8;
            auto texture = std::unique_ptr<QRhiTexture>(m_rhi->newTexture(textureFormat, extent));
            texture->setFlags(QRhiTexture::RenderTarget);
            // 布局不在这里固定：每帧合成前用 setNativeLayout(UNDEFINED) 声明"内容作废"，
            // 因此不需要跟踪 present 之后的真实布局。
            if (!texture->createFrom({quint64(quintptr(image)), int(VK_IMAGE_LAYOUT_UNDEFINED)})) {
                m_error = QStringLiteral("包装交换链图像失败（第 %1 张）").arg(i);
                return false;
            }
            auto target = std::unique_ptr<QRhiTextureRenderTarget>(
                m_rhi->newTextureRenderTarget({QRhiColorAttachment(texture.get())}));
            auto pass =
                std::unique_ptr<QRhiRenderPassDescriptor>(target->newCompatibleRenderPassDescriptor());
            if (!pass) {
                m_error = QStringLiteral("交换链渲染通道描述符创建失败");
                return false;
            }
            target->setRenderPassDescriptor(pass.get());
            if (!target->create()) {
                m_error = QStringLiteral("交换链渲染目标创建失败");
                return false;
            }
            m_swapTextures.push_back(std::move(texture));
            m_swapPasses.push_back(std::move(pass));
            m_swapTargets.push_back(std::move(target));
        }
        return true;
    }
    bool m_vsync = true;
    std::unique_ptr<QVulkanInstance> m_instance;
    std::unique_ptr<QWindow> m_window;
    std::unique_ptr<QRhi> m_rhi;
    std::unique_ptr<VulkanPresenter> m_presenter;
    std::vector<std::unique_ptr<QRhiTexture>> m_swapTextures;
    std::vector<std::unique_ptr<QRhiTextureRenderTarget>> m_swapTargets;
    std::vector<std::unique_ptr<QRhiRenderPassDescriptor>> m_swapPasses;
    VulkanPresenter::Frame m_nativeFrame;
    VkDevice m_device = VK_NULL_HANDLE;
    VkPhysicalDevice m_physDev = VK_NULL_HANDLE;
    QSize m_size;
    QSize m_swapSize;
    quint64 m_swapchainRecreates = 0;
    quint64 m_deviceIdleWaits = 0;
    quint64 m_resizeSkips = 0;
    // A02：只做观测。m_offscreenSubmitCount 在 beginFrame 成功后 +1；m_lastSlotWaitMs 是
    // 最近一次 beginFrame 的原始耗时（帧槽等待），两者都不参与任何提交/同步决策。
    quint64 m_offscreenSubmitCount = 0;
    double m_lastSlotWaitMs = 0.0;
    QString m_error;
};
} // namespace
std::unique_ptr<PresentationBackend> createVulkanPresentationBackend() {
    return std::make_unique<VulkanPresentationBackend>();
}
} // namespace RhineRender
