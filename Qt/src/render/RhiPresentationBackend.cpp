#include "PresentationBackend.h"
#include "PresentationWindow.h"
#ifdef Q_OS_WIN
#include "../WindowsRoundedCorners.h"
#endif

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QWindow>
#include <rhi/qrhi_platform.h>

namespace RhineRender {
#if defined(RHINE_VULKAN_PRESENTATION) && RHINE_VULKAN_PRESENTATION
std::unique_ptr<PresentationBackend> createVulkanPresentationBackend();
#endif

namespace {

/** 使用 QRhi 自带交换链呈现；Metal 的窗口与 GPU 同步由 Qt 平台后端实现。 */
class RhiPresentationBackend final : public PresentationBackend {
  public:
    ~RhiPresentationBackend() override {
        release();
        m_pass.reset();
        m_swapchain.reset();
        m_rhi.reset();
        m_window.reset();
    }

    bool initialize(QSize logicalSize, bool vsync) override {
#if (defined(Q_OS_DARWIN) && QT_CONFIG(metal)) || (defined(Q_OS_WIN) && RHINE_ENABLE_D3D12_BACKEND)
        m_window = std::make_unique<PresentationWindow>();
#ifdef Q_OS_WIN
        m_window->setSurfaceType(QSurface::Direct3DSurface);
        m_window->setFlags(Qt::Window | Qt::FramelessWindowHint | Qt::WindowTitleHint |
                           Qt::WindowSystemMenuHint | Qt::WindowMinMaxButtonsHint |
                           Qt::WindowCloseButtonHint);
#else
        m_window->setSurfaceType(QSurface::MetalSurface);
#endif
        m_window->setTitle(QStringLiteral("RHINE MUSIC DATABASE"));
#ifndef Q_OS_IOS
        m_window->setMinimumSize(QSize(960, 540));
#endif
        m_window->resize(logicalSize);
#ifdef Q_OS_IOS
        m_window->reportContentOrientationChange(Qt::LandscapeOrientation);
        m_window->showFullScreen();
#else
        m_window->show();
#ifdef Q_OS_WIN
        applyWindowsRoundedCorners(m_window.get());
#endif
#endif
#ifndef Q_OS_IOS
        QElapsedTimer clock;
        clock.start();
        while (!m_window->isExposed() && clock.elapsed() < 2000) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        }
#endif
        m_vsync = vsync;
        return createDevice();
#else
        Q_UNUSED(logicalSize);
        Q_UNUSED(vsync);
        m_error = QStringLiteral("此构建没有原生 QRhi 呈现后端");
        return false;
#endif
    }

    QWindow *window() const override {
        return m_window.get();
    }
    QRhi *rhi() const override {
        return m_rhi.get();
    }
    bool resize(QSize, bool force) override {
        if (!m_swapchain || !m_window->isExposed()) {
            return false;
        }
        const auto pixels = m_swapchain->surfacePixelSize();
        if (pixels.isEmpty()) {
            return false;
        }
        if (!force && pixels == m_size) {
            return true;
        }
        if (!m_swapchain->createOrResize()) {
            m_error = QStringLiteral("QRhi 交换链创建失败");
            return false;
        }
        m_size = m_swapchain->currentPixelSize();
        return true;
    }
    AcquireResult acquire(Frame *frame) override {
        if (!m_window || !m_window->isExposed() || m_window->visibility() == QWindow::Minimized) {
            return AcquireResult::Timeout;
        }
        frame->imageIndex = 0;
        if (m_swapchain->surfacePixelSize() != m_size) {
            return AcquireResult::OutOfDate;
        }
        return AcquireResult::Ok;
    }
    QRhi::FrameOpResult beginFrame(const Frame &, QRhiCommandBuffer **commands) override {
        const auto result = m_rhi->beginFrame(m_swapchain.get());
        m_frameOpen = result == QRhi::FrameOpSuccess;
        if (m_frameOpen) {
            *commands = m_swapchain->currentFrameCommandBuffer();
        }
        return result;
    }
    QRhiRenderTarget *target(const Frame &) const override {
        return m_swapchain->currentFrameRenderTarget();
    }
    bool finishTarget(QRhiCommandBuffer *, const Frame &) override {
        return true;
    }
    bool endFrame(const Frame &, bool rendered) override {
        if (!m_frameOpen) {
            return false;
        }
        m_frameOpen = false;
        const auto result =
            m_rhi->endFrame(m_swapchain.get(), rendered ? QRhi::EndFrameFlags{} : QRhi::SkipPresent);
        return result == QRhi::FrameOpSuccess;
    }
    void release() override {
        if (m_rhi) {
            m_rhi->finish();
        }
        if (m_swapchain) {
            m_swapchain->destroy();
        }
        m_size = {};
    }
    bool ready() const override {
        return m_swapchain && !m_size.isEmpty();
    }
    QSize extent() const override {
        return m_size;
    }
    quint32 imageCount() const override {
        // QRhi 不公开 Metal 交换链图像数量，诊断中以 0 表示未知。
        return 0;
    }
    QString formatName() const override {
        return QStringLiteral("QRhi swapchain");
    }
    QString presentModeName() const override {
        return m_vsync ? QStringLiteral("VSync") : QStringLiteral("NoVSync");
    }
    QString backendName() const override {
#ifdef Q_OS_WIN
        return QStringLiteral("D3D12");
#else
        return QStringLiteral("Metal");
#endif
    }
    QString lastError() const override {
        return m_error;
    }

  private:
    bool createDevice() {
#if (defined(Q_OS_DARWIN) && QT_CONFIG(metal)) || (defined(Q_OS_WIN) && RHINE_ENABLE_D3D12_BACKEND)
#ifdef Q_OS_WIN
        QRhiD3D12InitParams parameters;
        m_rhi.reset(QRhi::create(QRhi::D3D12, &parameters));
#else
        QRhiMetalInitParams parameters;
        m_rhi.reset(QRhi::create(QRhi::Metal, &parameters));
#endif
        if (!m_rhi) {
            m_error = QStringLiteral("QRhi 呈现设备创建失败");
            return false;
        }
        m_swapchain.reset(m_rhi->newSwapChain());
        m_swapchain->setWindow(m_window.get());
        if (!m_vsync) {
            m_swapchain->setFlags(QRhiSwapChain::NoVSync);
        }
        m_pass.reset(m_swapchain->newCompatibleRenderPassDescriptor());
        m_swapchain->setRenderPassDescriptor(m_pass.get());
        // 隐藏窗口可先建设备，交换链等第一次 expose 再建立。
        return !m_window->isExposed() || resize({}, true);
#else
        return false;
#endif
    }

    std::unique_ptr<QWindow> m_window;
    std::unique_ptr<QRhi> m_rhi;
    std::unique_ptr<QRhiSwapChain> m_swapchain;
    std::unique_ptr<QRhiRenderPassDescriptor> m_pass;
    QSize m_size;
    QString m_error;
    bool m_vsync = true;
    bool m_frameOpen = false;
};
} // namespace

std::unique_ptr<PresentationBackend> createPresentationBackend(const QString &name) {
#if defined(Q_OS_WIN) && RHINE_ENABLE_D3D12_BACKEND
    if (name == QLatin1String("d3d12")) {
        return std::make_unique<RhiPresentationBackend>();
    }
#endif
    if (name == QLatin1String("metal")) {
        return std::make_unique<RhiPresentationBackend>();
    }
#if defined(RHINE_VULKAN_PRESENTATION) && RHINE_VULKAN_PRESENTATION
    if (name == QLatin1String("vulkan")) {
        return createVulkanPresentationBackend();
    }
#endif
    return {};
}
} // namespace RhineRender
