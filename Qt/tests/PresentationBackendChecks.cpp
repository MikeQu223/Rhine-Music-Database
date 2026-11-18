#include "render/PresentationBackend.h"
#include <QCoreApplication>
#include <QGuiApplication>
#include <QWindow>
#include <rhi/qrhi_platform.h>
#include <cstdio>

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
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
    backend->release();
    ok = ok && !backend->ready();
    std::fprintf(stderr, "D3D12 native presentation, resize and release: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
