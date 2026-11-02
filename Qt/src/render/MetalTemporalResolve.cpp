#include "MetalTemporalResolve.h"
#include <QFile>
#include <QVector4D>

namespace RhineRender {
namespace {
QShader temporalShader(const QString &name) {
    QFile file(":/metalTemporal/" + name + ".qsb");
    if (!file.open(QIODevice::ReadOnly)) {
        qFatal("Missing Metal temporal shader: %s", qPrintable(name));
    }
    return QShader::fromSerialized(file.readAll());
}
struct Parameters {
    QVector4D jitterAndHistory;
    QVector4D projection;
};
} // namespace

MetalTemporalResolve::MetalTemporalResolve(QRhi *device) : SceneResources(device) {
    parameters =
        create(own(rhi->newBuffer(QRhiBuffer::Dynamic, QRhiBuffer::UniformBuffer, sizeof(Parameters))));
    linear = create(own(rhi->newSampler(QRhiSampler::Linear, QRhiSampler::Linear, QRhiSampler::None,
                                        QRhiSampler::ClampToEdge, QRhiSampler::ClampToEdge)));
    nearest = create(own(rhi->newSampler(QRhiSampler::Nearest, QRhiSampler::Nearest, QRhiSampler::None,
                                         QRhiSampler::ClampToEdge, QRhiSampler::ClampToEdge)));
}

MetalTemporalResolve::~MetalTemporalResolve() {
    for (auto &resource : sized) {
        resource.release()->deleteLater();
    }
    for (auto &resource : resources) {
        resource.release()->deleteLater();
    }
}

/** 重建时作废历史；每帧只写当前目标、读另一份历史，不增加 CPU/GPU 完成等待。 */
QRhiTexture *MetalTemporalResolve::resolve(QRhiCommandBuffer *commands, QRhiTexture *color,
                                           QRhiTexture *depth, QRhiTexture *motion, QSize displaySize,
                                           QPointF jitter, const QMatrix4x4 &projection, bool reset) {
    if (display != displaySize || inputColor != color || inputDepth != depth || inputMotion != motion) {
        // Qt 延迟销毁仍在飞行中的资源，绑定和管线先于附件退役。
        for (auto &resource : sized) {
            resource.release()->deleteLater();
        }
        sized.clear();
        display = displaySize;
        inputColor = color;
        inputDepth = depth;
        inputMotion = motion;
        next = 0;
        valid = false;
        for (auto &entry : history) {
            entry = {};
            entry.color = texture(display, QRhiTexture::RGBA16F, QRhiTexture::RenderTarget, true);
            entry.depth = texture(display, QRhiTexture::R32F, QRhiTexture::RenderTarget, true);
            const QRhiColorAttachment attachments[]{entry.color, entry.depth};
            QRhiTextureRenderTargetDescription description;
            description.setColorAttachments(std::begin(attachments), std::end(attachments));
            entry.target = own(rhi->newTextureRenderTarget(description), true);
            entry.target->setRenderPassDescriptor(
                own(entry.target->newCompatibleRenderPassDescriptor(), true));
            create(entry.target);
        }
        for (int index = 0; index < 2; ++index) {
            auto &entry = history[index];
            const auto &previous = history[1 - index];
            entry.bindings = own(rhi->newShaderResourceBindings(), true);
            const auto fragment = QRhiShaderResourceBinding::FragmentStage;
            entry.bindings->setBindings(
                {QRhiShaderResourceBinding::uniformBuffer(0, fragment, parameters),
                 QRhiShaderResourceBinding::sampledTexture(1, fragment, color, linear),
                 QRhiShaderResourceBinding::sampledTexture(2, fragment, depth, nearest),
                 QRhiShaderResourceBinding::sampledTexture(3, fragment, motion, nearest),
                 QRhiShaderResourceBinding::sampledTexture(4, fragment, previous.color, linear),
                 QRhiShaderResourceBinding::sampledTexture(5, fragment, previous.depth, nearest)});
            create(entry.bindings);
            ++bindingCreations;
        }
        pipeline = own(rhi->newGraphicsPipeline(), true);
        pipeline->setShaderStages({{QRhiShaderStage::Vertex, temporalShader("resolve.vert")},
                                   {QRhiShaderStage::Fragment, temporalShader("resolve.frag")}});
        pipeline->setVertexInputLayout({});
        pipeline->setTargetBlends({{}, {}});
        pipeline->setShaderResourceBindings(history[0].bindings);
        pipeline->setRenderPassDescriptor(history[0].target->renderPassDescriptor());
        create(pipeline);
    }
    const auto input = color->pixelSize();
    const Parameters values{{float(jitter.x() / input.width()), float(jitter.y() / input.height()),
                             valid && !reset ? 1.f : 0.f, 0.f},
                            {projection(2, 2), projection(2, 3), 0.f, 0.f}};
    auto batch = rhi->nextResourceUpdateBatch();
    batch->updateDynamicBuffer(parameters, 0, sizeof(values), &values);
    auto &entry = history[next];
    commands->beginPass(entry.target, Qt::black, {1, 0}, batch);
    commands->setGraphicsPipeline(pipeline);
    commands->setShaderResources(entry.bindings);
    commands->setViewport({0, 0, float(display.width()), float(display.height())});
    commands->draw(3);
    ++drawCalls;
    commands->endPass();
    next = 1 - next;
    valid = true;
    return entry.color;
}
} // namespace RhineRender
