#include "render/PresentationBackend.h"
#include "render/SceneLayerHost.h"
#include <QCoreApplication>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QWindow>
#include <rhi/qrhi_platform.h>
#if QT_CONFIG(vulkan) && __has_include(<vulkan/vulkan.h>)
#include <QVulkanInstance>
#endif
#include <cstdio>
#include <memory>

namespace {
QUrl writeQmlFixture(const QTemporaryDir &directory, const QString &name, const QByteArray &contents) {
    QFile file(directory.filePath(name));
    if (!file.open(QIODevice::WriteOnly) || file.write(contents) != contents.size() || !file.flush()) {
        return {};
    }
    return QUrl::fromLocalFile(file.fileName());
}

bool checkOverlayPixels(SceneLayerHost &layers, QRhi *rhi) {
    if (!layers.isValid() || !layers.renderFrame()) {
        std::fprintf(stderr, "%s offscreen layer rendering failed\n", rhi->backendName());
        return false;
    }
    QRhiCommandBuffer *commands = nullptr;
    if (rhi->beginOffscreenFrame(&commands) != QRhi::FrameOpSuccess) {
        return false;
    }
    QRhiReadbackResult result;
    auto *updates = rhi->nextResourceUpdateBatch();
    updates->readBackTexture(QRhiReadbackDescription(layers.overlayTexture()), &result);
    commands->resourceUpdate(updates);
    const auto frameResult = rhi->endOffscreenFrame();
    const auto finishResult = rhi->finish();
    const auto size = result.pixelSize;
    if (frameResult != QRhi::FrameOpSuccess || finishResult != QRhi::FrameOpSuccess ||
        size != layers.pixelSize() || result.data.size() != qsizetype(size.width()) * size.height() * 4) {
        std::fprintf(stderr, "%s overlay readback failed\n", rhi->backendName());
        return false;
    }
    const QImage image(reinterpret_cast<const uchar *>(result.data.constData()), size.width(), size.height(),
                       QImage::Format_RGBA8888_Premultiplied);
    const auto foreground = image.pixelColor(size.width() / 2, size.height() / 2);
    const auto background = image.pixelColor(size.width() / 4, size.height() / 2);
    const auto corner = image.pixelColor(0, 0);
    if (foreground != QColor(Qt::blue) || background != QColor(Qt::red) || corner.alpha() != 0) {
        std::fprintf(stderr, "%s overlay %dx%d returned foreground %08x, background %08x, corner %08x\n",
                     rhi->backendName(), size.width(), size.height(), foreground.rgba(), background.rgba(),
                     corner.rgba());
        return false;
    }
    return true;
}

bool checkOffscreenOverlay(QRhi *rhi, QWindow *window, QVulkanInstance *vulkanInstance = nullptr) {
    QTemporaryDir directory;
    if (!directory.isValid()) {
        return false;
    }
    const auto scene = writeQmlFixture(directory, QStringLiteral("Scene.qml"), "import QtQuick\nItem {}");
    const auto overlay = writeQmlFixture(directory, QStringLiteral("Overlay.qml"), R"qml(
import QtQuick
Item {
    Rectangle {
        anchors.centerIn: parent
        width: parent.width * 0.75
        height: parent.height * 0.75
        color: "red"
    }
    Rectangle {
        anchors.centerIn: parent
        width: parent.width * 0.25
        height: parent.height * 0.25
        color: "blue"
    }
}
)qml");
    QQmlEngine engine;
    SceneLayerHost layers;
    if (!layers.start(engine, scene, overlay, rhi, vulkanInstance, window)) {
        return false;
    }
    layers.setPixelRatio(window->devicePixelRatio());
    const bool beforeResize = checkOverlayPixels(layers, rhi);
    layers.resize(QSize(640, 360));
    const bool afterResize = checkOverlayPixels(layers, rhi);
    return beforeResize && afterResize;
}

int checkVulkanOverlay() {
#if QT_CONFIG(vulkan) && __has_include(<vulkan/vulkan.h>)
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Vulkan);
    QVulkanInstance instance;
    if (instance.create()) {
        QWindow window;
        window.setSurfaceType(QSurface::VulkanSurface);
        window.setVulkanInstance(&instance);
        QRhiVulkanInitParams parameters;
        parameters.inst = &instance;
        if (auto rhi = std::unique_ptr<QRhi>(QRhi::create(QRhi::Vulkan, &parameters))) {
            return checkOffscreenOverlay(rhi.get(), &window, &instance) ? 0 : 1;
        }
    }
#endif
    std::fprintf(stderr, "SKIP: no Vulkan device available\n");
    return 77;
}
}

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    if (app.arguments().contains(QStringLiteral("--vulkan"))) {
        return checkVulkanOverlay();
    }
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Direct3D12);
    QRhiD3D12InitParams parameters;
    if (!QRhi::probe(QRhi::D3D12, &parameters)) {
        std::fprintf(stderr, "SKIP: no D3D12 device available\n");
        return 0;
    }
    auto backend = RhineRender::createPresentationBackend(QStringLiteral("d3d12"));
    if (!backend || !backend->initialize(QSize(960, 540), true)) {
        std::fprintf(stderr, "D3D12 presentation initialization failed\n");
        return 1;
    }
    bool ok = backend->rhi()->backend() == QRhi::D3D12;
    for (int i = 0; i < 30 && ok; ++i) {
        QCoreApplication::processEvents();
        if (i == 15) {
            backend->window()->resize(1024, 600);
            QCoreApplication::processEvents();
        }
        ok = backend->resize({}, i == 15);
        RhineRender::PresentationBackend::Frame frame;
        ok = ok && backend->acquire(&frame) == RhineRender::PresentationBackend::AcquireResult::Ok;
        QRhiCommandBuffer *commands = nullptr;
        ok = ok && backend->beginFrame(frame, &commands) == QRhi::FrameOpSuccess;
        if (!ok) {
            break;
        }
        commands->beginPass(backend->target(frame), QColor(20, 30, 40), {1.0f, 0});
        commands->endPass();
        ok = backend->finishTarget(commands, frame) && backend->endFrame(frame, true);
    }
    ok = ok && backend->extent() == backend->window()->size() * backend->window()->devicePixelRatio();
    ok = ok && checkOffscreenOverlay(backend->rhi(), backend->window());
    backend->release();
    ok = ok && !backend->ready();
    std::fprintf(stderr, "D3D12 native presentation and offscreen overlay: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
