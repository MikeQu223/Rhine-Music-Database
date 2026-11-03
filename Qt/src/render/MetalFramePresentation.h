#pragma once

#include "MetalFxBackend.h"
#include "MetalFrameQueue.h"
#include "SceneResources.h"
#include "../fg/FgFrameTap.h"
#include <QDebug>
#include <QElapsedTimer>
#include <QFile>
#include <QMatrix4x4>
#include <QVariantMap>
#include <cstring>

namespace RhineRender {

/**
 * 在 Qt Quick 的窗口帧内管理无 UI 颜色与原生补帧，不创建离屏 QRhi 帧或主动等待 GPU。
 * 一次真实渲染先输出中间帧，下一次窗口绘制复用真实颜色；历史只由真实渲染推进。
 */
class MetalFramePresentation : public SceneResources {
  public:
    explicit MetalFramePresentation(QRhi *device)
        : SceneResources(device), generator(createMetalFxFrameGenerator(device)) {
    }

    ~MetalFramePresentation() {
        clearSized();
    }

    bool supported() const {
        return bool(generator) && !failed && (!queue || queue->available());
    }

    quint64 presented() const {
        return outputFrames;
    }
    quint64 interpolated() const {
        return interpolatedFrames;
    }
    quint64 rendered() const {
        return realFrames;
    }

    void suspend() {
        if (queue && !queue->available()) {
            failed = true;
            failure = queue->telemetry().value("asyncError").toString();
        }
        invalidate();
        if (!realColor) {
            return;
        }
        if (generator) {
            generator->setTemporalSource(nullptr);
            generator->release();
        }
        clearSized();
        display = {};
        destinationPass = nullptr;
    }

    void invalidate() {
        pendingReal = false;
        if (generator) {
            generator->requestReset();
        }
    }

    bool takeReal(QRhiRenderTarget *destination, quint64 revision, bool reset) {
        if (!pendingReal) {
            return false;
        }
        if (display != destination->pixelSize() || destinationPass != destination->renderPassDescriptor() ||
            configuration != revision || reset) {
            invalidate();
            return false;
        }
        pendingReal = false;
        return true;
    }

    QRhiTextureRenderTarget *realTarget(QRhiRenderTarget *destination, quint64 revision) {
        if (display != destination->pixelSize() || destinationPass != destination->renderPassDescriptor() ||
            configuration != revision) {
            invalidate();
            clearSized();
            display = destination->pixelSize();
            destinationPass = destination->renderPassDescriptor();
            realColor = texture(display, QRhiTexture::RGBA8,
                                QRhiTexture::RenderTarget | QRhiTexture::UsedAsTransferSource, true);
            QRhiTextureRenderTargetDescription description{QRhiColorAttachment(realColor)};
            real = own(rhi->newTextureRenderTarget(description), true);
            auto pass = own(real->newCompatibleRenderPassDescriptor(), true);
            real->setRenderPassDescriptor(pass);
            create(real);
            parameters =
                create(own(rhi->newBuffer(QRhiBuffer::Dynamic, QRhiBuffer::UniformBuffer, 80), true));
            sampler = create(own(rhi->newSampler(QRhiSampler::Linear, QRhiSampler::Linear, QRhiSampler::None,
                                                 QRhiSampler::ClampToEdge, QRhiSampler::ClampToEdge),
                                 true));
        }
        configuration = revision;
        return real;
    }

    void resetHistory(quint64 revision) {
        if (lastResetRevision == revision) {
            return;
        }
        lastResetRevision = revision;
        invalidate();
        clearSized();
        display = {};
        destinationPass = nullptr;
    }

    bool asynchronous() const {
        return qEnvironmentVariable("RHINE_METAL_FG_ASYNC") == "on";
    }

    int reserveSource(QSize render, quint64 sceneRevision) {
        if (!queue) {
            queue = std::make_unique<MetalFrameQueue>(rhi, render, display, workSize(render));
        }
        if (!queue->available() || (lastSourceRevision != 0 && (outputFrames % 2) != 0) ||
            lastSourceRevision == sceneRevision) {
            return -1;
        }
        const int slot = queue->reserve();
        if (slot >= 0) {
            lastSourceRevision = sceneRevision;
        } else {
            ++backpressure;
        }
        return slot;
    }

    bool asyncAvailable() const {
        return queue && queue->available();
    }

    void captureSource(QRhiCommandBuffer *commands, int slot, const RhineFg::FrameInputs &inputs) {
        ++realFrames;
        if (!realColor || !inputs.depth || !inputs.motionVectors) {
            queue->cancel(commands, slot);
            return;
        }
        auto source = prepareWorking(commands, workSize(inputs.renderSize));
        commands->beginExternal();
        queue->capture(commands, slot, realColor, source, inputs);
        commands->endExternal();
    }

    /** 成对消费就绪结果：中间帧后必跟同一对的真实帧；缓冲不足时明确记重复帧。 */
    void presentAsync(QRhiCommandBuffer *commands, QRhiRenderTarget *destination) {
        QRhiTexture *source = nullptr;
        if (pendingBundle.slot >= 0) {
            source = pendingBundle.real;
            queue->release(commands, lastBundle.slot);
            lastBundle = pendingBundle;
            pendingBundle = {};
            pendingReal = false;
            ++shownRealFrames;
        } else {
            auto next = queue->take();
            if (next.slot >= 0) {
                pendingBundle = next;
                source = next.interpolated;
                pendingReal = true;
                ++interpolatedFrames;
            } else if (!everShown) {
                // 首帧没有可配对的上一帧，先把真实帧拷到独立纹理再上屏；
                // realColor 会被下一次真实渲染覆盖，不能直接当作重复帧的来源。
                source = hold(commands);
                ++shownRealFrames;
            } else {
                // 真实帧必须等它自己的中间帧先上屏；这里只能重复上一张，
                // 展示刚渲染的 realColor 会让时间顺序倒退。
                source = lastShown;
                ++duplicateFrames;
            }
        }
        copy(commands, destination, source, pipeline);
        lastShown = source;
        everShown = true;
        noteOutput();
    }

    bool hasWork() const {
        return pendingReal || (queue && queue->inFlight() > 0);
    }

    /** 首帧的稳定副本；队列还没产出任何成对结果时用它作为重复帧来源。 */
    QRhiTexture *hold(QRhiCommandBuffer *commands) {
        if (!holdColor) {
            holdColor = texture(display, QRhiTexture::RGBA8,
                                QRhiTexture::RenderTarget | QRhiTexture::UsedAsTransferSource, true);
            QRhiTextureRenderTargetDescription description{QRhiColorAttachment(holdColor)};
            holdTarget = own(rhi->newTextureRenderTarget(description), true);
            auto pass = own(holdTarget->newCompatibleRenderPassDescriptor(), true);
            holdTarget->setRenderPassDescriptor(pass);
            create(holdTarget);
        }
        copy(commands, holdTarget, realColor, holdPipeline);
        return holdColor;
    }

    void generate(QRhiCommandBuffer *commands, const RhineFg::FrameInputs &inputs, void *scaler) {
        ++realFrames;
        pendingReal = false;
        const QSize working = workSize(inputs.renderSize);
        QRhiTexture *inputColor = prepareWorking(commands, working);
        if (working != display) {
            scaler = nullptr;
        }
        if (generator) {
            generator->setTemporalSource(scaler);
        }
        if (!generator || !inputs.depth || !inputs.motionVectors) {
            return;
        }
        if (!generator->resize(rhi, inputs.renderSize, working, QRhiTexture::RGBA8)) {
            failed = true;
            failure = generator->lastError();
            return;
        }
        generator->setCamera(inputs.nearPlane, inputs.farPlane, inputs.fovYRadians, inputs.frameTimeMs);
        generator->setJitter(float(inputs.jitter.x()), float(inputs.jitter.y()));
        if (inputs.reset) {
            generator->requestReset();
        }
        commands->beginExternal();
        const bool prepared =
            generator->prepare(rhi, commands, inputColor, inputs.depth, inputs.motionVectors);
        const bool dispatched =
            prepared && generator->dispatch(rhi, commands, inputColor, inputColor, nullptr);
        commands->endExternal();
        pendingReal = dispatched && !generator->lastFrameReset();
        if (pendingReal) {
            ++interpolatedFrames;
        }
    }

    void present(QRhiCommandBuffer *commands, QRhiRenderTarget *destination, bool interpolated) {
        auto source = interpolated ? generator->output() : realColor;
        copy(commands, destination, source, pipeline);
        if (!interpolated) {
            ++shownRealFrames;
        }
        noteOutput();
    }

    void copy(QRhiCommandBuffer *commands, QRhiRenderTarget *destination, QRhiTexture *source,
              QRhiGraphicsPipeline *&copyPipeline) {
        auto binding = copies.value(source);
        if (!binding) {
            binding = own(rhi->newShaderResourceBindings(), true);
            binding->setBindings(
                {QRhiShaderResourceBinding::uniformBuffer(
                     0, QRhiShaderResourceBinding::VertexStage | QRhiShaderResourceBinding::FragmentStage,
                     parameters),
                 QRhiShaderResourceBinding::sampledTexture(1, QRhiShaderResourceBinding::FragmentStage,
                                                           source, sampler)});
            create(binding);
            copies.insert(source, binding);
        }
        if (!copyPipeline) {
            copyPipeline = own(rhi->newGraphicsPipeline(), true);
            copyPipeline->setShaderStages({{QRhiShaderStage::Vertex, shader("present.vert")},
                                           {QRhiShaderStage::Fragment, shader("present.frag")}});
            copyPipeline->setVertexInputLayout({});
            copyPipeline->setSampleCount(destination->sampleCount());
            copyPipeline->setShaderResourceBindings(binding);
            copyPipeline->setRenderPassDescriptor(destination->renderPassDescriptor());
            create(copyPipeline);
        }
        float uniforms[20] = {};
        const auto correction = rhi->clipSpaceCorrMatrix();
        std::memcpy(uniforms, correction.constData(), 64);
        uniforms[16] = rhi->isYUpInFramebuffer() ? 1.f : 0.f;
        auto updates = rhi->nextResourceUpdateBatch();
        updates->updateDynamicBuffer(parameters, 0, sizeof(uniforms), uniforms);
        commands->beginPass(destination, Qt::transparent, {1.f, 0}, updates);
        commands->setGraphicsPipeline(copyPipeline);
        commands->setShaderResources(binding);
        const auto extent = destination->pixelSize();
        commands->setViewport({0, 0, float(extent.width()), float(extent.height())});
        commands->draw(3);
        commands->endPass();
    }

    QVariantMap telemetry() const {
        return {
            {"fgAvailable", supported()},
            {"fgAsync", asynchronous()},
            {"fgShownReal", qulonglong(shownRealFrames)},
            {"fgDuplicates", qulonglong(duplicateFrames)},
            {"fgBackpressure", qulonglong(backpressure)},
            {"async", queue ? queue->telemetry() : QVariantMap{}},
            {"fgReal", qulonglong(realFrames)},
            {"fgInterpolated", qulonglong(interpolatedFrames)},
            {"fgOutputFrames", qulonglong(outputFrames)},
            {"fgPendingReal", pendingReal},
            {"fgWorkingWidth", workingSize.width()},
            {"fgWorkingHeight", workingSize.height()},
            {"fgError",
             failed ? failure : (generator ? generator->lastError() : QStringLiteral("设备不支持原生插帧"))}};
    }

    bool pendingReal = false;

  private:
    /** RHINE_METAL_FG_DIAG=1 时约每秒打印一次呈现节奏与真实/插值比例。 */
    void noteOutput() {
        ++outputFrames;
        static const bool diagnostics = qEnvironmentVariableIsSet("RHINE_METAL_FG_DIAG");
        if (!diagnostics) {
            return;
        }
        if (!diagClock.isValid()) {
            diagClock.start();
            return;
        }
        if (++diagFrames < 120) {
            return;
        }
        const double elapsedMs = double(diagClock.restart());
        const quint64 shown = shownRealFrames - diagShownReal;
        const quint64 interpolated = interpolatedFrames - diagInterpolated;
        const quint64 duplicates = duplicateFrames - diagDuplicates;
        qInfo().noquote() << "MetalFX FG: 呈现" << QString::number(diagFrames * 1000.0 / elapsedMs, 'f', 1)
                          << "FPS · 真实" << shown << "插值" << interpolated << "重复" << duplicates
                          << "· 工作" << workingSize << "· 异步" << (queue != nullptr);
        diagFrames = 0;
        diagShownReal = shownRealFrames;
        diagInterpolated = interpolatedFrames;
        diagDuplicates = duplicateFrames;
    }

    QSize workSize(QSize render) const {
        const int requested = qEnvironmentVariableIntValue("RHINE_METAL_FG_SCALE");
        const int scale = requested > 0 ? qBound(50, requested, 100) : 100;
        return QSize(qMax(1, display.width() * scale / 100), qMax(1, display.height() * scale / 100))
            .expandedTo(render);
    }

    QRhiTexture *prepareWorking(QRhiCommandBuffer *commands, QSize working) {
        workingSize = working;
        if (working == display) {
            return realColor;
        }
        if (!workingColor) {
            workingColor = texture(working, QRhiTexture::RGBA8,
                                   QRhiTexture::RenderTarget | QRhiTexture::UsedAsTransferSource, true);
            QRhiTextureRenderTargetDescription description{QRhiColorAttachment(workingColor)};
            workingTarget = own(rhi->newTextureRenderTarget(description), true);
            auto pass = own(workingTarget->newCompatibleRenderPassDescriptor(), true);
            workingTarget->setRenderPassDescriptor(pass);
            create(workingTarget);
        }
        copy(commands, workingTarget, realColor, workingPipeline);
        return workingColor;
    }

    static QShader shader(const QString &name) {
        QFile file(":/metalTemporal/" + name + ".qsb");
        if (!file.open(QIODevice::ReadOnly)) {
            qFatal("Missing Metal presentation shader");
        }
        return QShader::fromSerialized(file.readAll());
    }

    void clearSized() {
        copies.clear();
        for (auto entry = sized.rbegin(); entry != sized.rend(); ++entry) {
            entry->release()->deleteLater();
        }
        sized.clear();
        queue.reset();
        pendingBundle = {};
        lastBundle = {};
        lastShown = nullptr;
        everShown = false;
        lastSourceRevision = 0;
        real = nullptr;
        realColor = nullptr;
        pipeline = nullptr;
        workingPipeline = nullptr;
        workingColor = nullptr;
        workingTarget = nullptr;
        holdPipeline = nullptr;
        holdColor = nullptr;
        holdTarget = nullptr;
    }

    std::unique_ptr<FrameGenerator> generator;
    std::unique_ptr<MetalFrameQueue> queue;
    MetalFrameQueue::Frame pendingBundle;
    MetalFrameQueue::Frame lastBundle;
    QRhiTexture *lastShown = nullptr;
    bool everShown = false;
    quint64 lastSourceRevision = 0;
    quint64 lastResetRevision = 0;
    quint64 shownRealFrames = 0;
    quint64 duplicateFrames = 0;
    quint64 backpressure = 0;
    bool failed = false;
    QString failure;
    QRhiTextureRenderTarget *workingTarget = nullptr;
    QRhiTexture *workingColor = nullptr;
    QRhiGraphicsPipeline *workingPipeline = nullptr;
    QRhiTextureRenderTarget *holdTarget = nullptr;
    QRhiTexture *holdColor = nullptr;
    QRhiGraphicsPipeline *holdPipeline = nullptr;
    QSize workingSize;
    QRhiTextureRenderTarget *real = nullptr;
    QRhiTexture *realColor = nullptr;
    QRhiBuffer *parameters = nullptr;
    QRhiSampler *sampler = nullptr;
    QRhiGraphicsPipeline *pipeline = nullptr;
    QRhiRenderPassDescriptor *destinationPass = nullptr;
    QHash<QRhiTexture *, QRhiShaderResourceBindings *> copies;
    QSize display;
    quint64 configuration = 0;
    quint64 realFrames = 0;
    quint64 interpolatedFrames = 0;
    quint64 outputFrames = 0;
    QElapsedTimer diagClock;
    quint64 diagFrames = 0;
    quint64 diagShownReal = 0;
    quint64 diagInterpolated = 0;
    quint64 diagDuplicates = 0;
};
} // namespace RhineRender
