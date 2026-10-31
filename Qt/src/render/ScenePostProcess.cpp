#include "ScenePostProcess.h"
#include "RenderPolicy.h"
#include "../fsr/FsrSharpness.h"
#include <QDebug>
#include <QFile>
#include <QJsonArray>
#include <cmath>
#include <cstring>

namespace RhineRender {
namespace {
bool isFsr(const QString &mode) {
    return mode == "fsr" || mode == "fsr1" || mode == "fsr3";
}
int sharpness() {
    if (qEnvironmentVariableIsEmpty("RHINE_FSR_SHARPNESS")) {
        return 50;
    }
    return qBound(0, qEnvironmentVariableIntValue("RHINE_FSR_SHARPNESS"), 100);
}
QShader shader(const QString &name) {
    QFile file(":/shaders/" + name + ".qsb");
    if (!file.open(QIODevice::ReadOnly)) {
        qFatal("Missing post-process shader: %s", qPrintable(name));
    }
    return QShader::fromSerialized(file.readAll());
}
/**
 * RHINE_POST_PROBE：只读一次环境变量，之后每帧只多一次静态布尔判断。
 * 用来回答“这一帧全屏 pass 走了哪条链、分别几条”，避免靠猜。
 */
bool postProbe() {
    static const bool enabled = qEnvironmentVariableIsSet("RHINE_POST_PROBE");
    return enabled;
}
/**
 * A07 的回滚开关，默认开启。本轮唯一的运行时行为变化是“RHINE_FSR_ENGINE 只在值变化时写”，
 * 设 RHINE_POST_REUSE=0 即恢复原来的每帧无条件 qputenv，便于 A/B 对比或出事时一键回到旧路径。
 * 两条全屏拷贝（taa→history→destination、m_output→destination）已证明在允许改动的文件内无法
 * 等价合并，所以这里没有对应的“新路径”需要开关。
 */
bool postReuse() {
    static const bool enabled = qEnvironmentVariable("RHINE_POST_REUSE").trimmed() != "0";
    return enabled;
}
} // namespace

void ScenePostProcess::probe(const char *path, const char *detail) {
    if (!postProbe() || m_probePath == QLatin1String(path)) {
        return;
    }
    m_probePath = QString::fromLatin1(path);
    // 计数仍用 quad() 维护的 drawCalls/bindingCreations，不自造第二套：一次全屏 pass 记一个
    // drawCall，所以“每帧增量”直接反映这条链还剩几次全屏绘制（含无法合并的拷贝）。注意计数在
    // 路径决定处采样，taa-init 那条链会在它之后还有一次 copyColor→destination，故少算 1 个 pass。
    qInfo().noquote() << "post-probe:" << path << "|" << detail << "| 累计 drawCalls" << drawCalls
                      << "bindingCreations" << bindingCreations;
}

QSize ScenePostProcess::renderSize(QSize display) const {
    const auto mode = qEnvironmentVariable("RHINE_AA_MODE");
    const int supersample = qBound(1, qEnvironmentVariableIntValue("RHINE_SUPERSAMPLE"), 2);
    const int percent = qEnvironmentVariableIntValue("RHINE_RENDER_SCALE");
    const double scale = percent > 0 ? qBound(.5, percent / 100., 1.) : 1.;
    const double aaScale =
        mode == "ssaa" ? qBound(1., qEnvironmentVariableIntValue("RHINE_AA_SCALE") / 100., 2.) : 1.;
    double divisor = 1.;
    if (isFsr(mode)) {
        const auto quality = qEnvironmentVariable("RHINE_FSR_QUALITY");
        if (quality == "super") {
            divisor = 3.;
        } else if (quality == "performance") {
            divisor = 2.;
        } else if (quality == "balanced") {
            divisor = 1.7;
        } else if (quality == "quality") {
            divisor = 1.5;
        }
    }
    const double factor = supersample * scale * aaScale / divisor;
    return {qMax(1, qRound(display.width() * factor)), qMax(1, qRound(display.height() * factor))};
}
int ScenePostProcess::samples() const {
    if (qEnvironmentVariable("RHINE_AA_MODE") != "msaa") {
        return 1;
    }
    const int configured = qEnvironmentVariableIntValue("RHINE_MSAA");
    const int wanted = configured > 1 ? qBound(2, configured, 8) : 4;
    int best = 1;
    for (int candidate : rhi->supportedSampleCounts()) {
        if (candidate > best && candidate <= wanted) {
            best = candidate;
        }
    }
    return best;
}
bool ScenePostProcess::temporal() const {
    const auto mode = qEnvironmentVariable("RHINE_AA_MODE");
    return mode == "taa" || (isFsr(mode) && mode != "fsr1" && m_fsr && m_fsr->available());
}
bool ScenePostProcess::needsMotion() const {
    return temporal() || RhineFg::isEnabled();
}
/**
 * 目标分配口径：只看配置。AA 模式给出"是不是时域"（taa/fsr/fsr3），FG 宿主开关给出
 * "插帧要不要读矢量"。运行期能力一律不参与，理由见头文件注释。
 */
bool ScenePostProcess::motionConfigured() const {
    return RhineRender::modeNeedsMotion(qEnvironmentVariable("RHINE_AA_MODE")) ||
           RhineFg::isEnabled();
}
bool ScenePostProcess::active() const {
    return m_mode == "fxaa" || m_mode == "taa" || isFsr(m_mode);
}
ScenePostProcess::Target ScenePostProcess::target(QSize size, QRhiTexture::Format format,
                                                  QRhiTexture::Flags flags) {
    auto color = texture(size, format, flags | QRhiTexture::RenderTarget);
    auto result =
        own(rhi->newTextureRenderTarget(QRhiTextureRenderTargetDescription{QRhiColorAttachment(color)}));
    result->setRenderPassDescriptor(own(result->newCompatibleRenderPassDescriptor()));
    create(result);
    return {color, result};
}

/** 在任何 pass 之前重建尺寸相关资源和 FSR 上下文；关闭模式立即释放历史。 */
void ScenePostProcess::prepare(QSize render, QSize display, const QJsonObject &frame) {
    const auto mode = qEnvironmentVariable("RHINE_AA_MODE");
    if (m_mode != mode || m_renderSize != render || m_displaySize != display) {
        m_bindings.clear();
        m_pipelines.clear();
        resources.clear();
        m_input = {};
        m_output = {};
        m_history[0] = {};
        m_history[1] = {};
        m_historyValid = false;
        m_historyIndex = 0;
        m_mode = mode;
        m_renderSize = render;
        m_displaySize = display;
        if (active()) {
            m_globals = create(own(rhi->newBuffer(QRhiBuffer::Dynamic, QRhiBuffer::UniformBuffer, 544)));
            m_constants =
                create(own(rhi->newBuffer(QRhiBuffer::Dynamic, QRhiBuffer::UniformBuffer, sizeof(Fsr1Con))));
            // 保存 RCAS 常量，避免同帧动态更新覆盖 EASU。
            m_rcasConstants =
                create(own(rhi->newBuffer(QRhiBuffer::Dynamic, QRhiBuffer::UniformBuffer, sizeof(Fsr1Con))));
            m_sampler =
                create(own(rhi->newSampler(QRhiSampler::Linear, QRhiSampler::Linear, QRhiSampler::None,
                                           QRhiSampler::ClampToEdge, QRhiSampler::ClampToEdge)));
            m_input = target(render, isFsr(mode) ? QRhiTexture::RGBA16F : QRhiTexture::RGBA8);
            if (isFsr(mode)) {
                m_output = target(display, QRhiTexture::RGBA16F, QRhiTexture::UsedWithLoadStore);
            }
            if (mode == "taa") {
                m_history[0] = target(render, QRhiTexture::RGBA16F);
                m_history[1] = target(render, QRhiTexture::RGBA16F);
            }
        }
    }
    if (frame["temporalReset"].toBool()) {
        m_historyValid = false;
    }
    const bool computeFsr = isFsr(mode) && mode != "fsr1";
    if (computeFsr) {
        if (!m_fsr) {
            m_fsr = std::make_unique<Fsr3Backend>();
        }
        const float milliseconds = m_clock.isValid() ? float(m_clock.nsecsElapsed()) / 1e6f : 16.6667f;
        m_clock.start();
        const auto projection = frame["projection"].toArray();
        if (projection.size() == 16) {
            const float c = float(projection[10].toDouble());
            const float translation = float(projection[14].toDouble());
            if (std::abs(c - 1.f) > 1e-6f && std::abs(c + 1.f) > 1e-6f) {
                m_fsr->setCamera(translation / (c - 1.f), translation / (c + 1.f), milliseconds);
            }
        }
        const auto jitter = frame["jitter"].toArray();
        // 投影偏移与 FSR 采样位置使用相反符号；无抖动时显式清零。
        const float jitterX = jitter.size() == 2 ? float(-jitter[0].toDouble()) : 0.f;
        const float jitterY = jitter.size() == 2 ? float(-jitter[1].toDouble()) : 0.f;
        m_fsr->setJitter(jitterX, jitterY);
        if (frame["temporalReset"].toBool()) {
            m_fsr->requestReset();
        }
        m_fsr->resize(rhi, render, display);
    } else if (m_fsr) {
        m_fsr.reset();
    }
}

void ScenePostProcess::quad(QRhiCommandBuffer *commands, const QString &kind, QRhiRenderTarget *destination,
                            const QList<QRhiTexture *> &textures) {
    QString bindingKey = kind;
    for (auto texture : textures) {
        bindingKey += '/' + QString::number(quintptr(texture));
    }
    auto &binding = m_bindings[bindingKey];
    if (!binding) {
        binding = own(rhi->newShaderResourceBindings());
        const auto stages = QRhiShaderResourceBinding::VertexStage | QRhiShaderResourceBinding::FragmentStage;
        QList<QRhiShaderResourceBinding> values{
            QRhiShaderResourceBinding::uniformBuffer(0, stages, m_globals)};
        if (kind.startsWith("fsr1_")) {
            auto *constants = kind == "fsr1_rcas" ? m_rcasConstants : m_constants;
            values.append(QRhiShaderResourceBinding::uniformBuffer(
                1, QRhiShaderResourceBinding::FragmentStage, constants));
        }
        for (int index = 0; index < textures.size(); ++index) {
            values.append(QRhiShaderResourceBinding::sampledTexture(
                2 + index, QRhiShaderResourceBinding::FragmentStage, textures[index], m_sampler));
        }
        binding->setBindings(values.cbegin(), values.cend());
        create(binding);
        ++bindingCreations;
    }
    const auto pipelineKey = kind + '/' + QString::number(quintptr(destination->renderPassDescriptor()));
    auto &pipeline = m_pipelines[pipelineKey];
    if (!pipeline) {
        pipeline = own(rhi->newGraphicsPipeline());
        pipeline->setShaderStages({{QRhiShaderStage::Vertex, shader("quad.vert")},
                                   {QRhiShaderStage::Fragment, shader(kind + ".frag")}});
        pipeline->setTargetBlends({QRhiGraphicsPipeline::TargetBlend{}});
        pipeline->setShaderResourceBindings(binding);
        pipeline->setRenderPassDescriptor(destination->renderPassDescriptor());
        create(pipeline);
    }
    commands->beginPass(destination, Qt::black, {1, 0});
    commands->setGraphicsPipeline(pipeline);
    commands->setShaderResources(binding);
    const auto size = destination->pixelSize();
    commands->setViewport({0, 0, float(size.width()), float(size.height())});
    commands->draw(3);
    ++drawCalls;
    commands->endPass();
}
void ScenePostProcess::fsrQuad(QRhiCommandBuffer *commands, const QString &kind,
                               QRhiRenderTarget *destination, QRhiTexture *source, const Fsr1Con &constants) {
    auto batch = rhi->nextResourceUpdateBatch();
    auto *buffer = kind == "fsr1_rcas" ? m_rcasConstants : m_constants;
    batch->updateDynamicBuffer(buffer, 0, sizeof(constants), &constants);
    commands->resourceUpdate(batch);
    quad(commands, kind, destination, {source});
}

/** 对新场景的最终颜色执行互斥 AA/FSR；计算派发失败时仍输出有效场景。 */
void ScenePostProcess::resolve(QRhiCommandBuffer *commands, QRhiRenderTarget *destination,
                               const RhineFg::FrameInputs &motion) {
    QByteArray globals(544, '\0');
    const auto correction = rhi->clipSpaceCorrMatrix();
    std::memcpy(globals.data() + 464, correction.constData(), 64);
    const float backend = rhi->isYUpInFramebuffer() ? 1.f : 0.f;
    std::memcpy(globals.data() + 528, &backend, 4);
    auto batch = rhi->nextResourceUpdateBatch();
    batch->updateDynamicBuffer(m_globals, 0, globals.size(), globals.constData());
    commands->resourceUpdate(batch);
    if (m_mode == "fxaa") {
        quad(commands, "aaFragment", destination, {m_input.texture});
        probe("fxaa", "aaFragment→destination，1 次全屏 pass，没有多余拷贝");
    } else if (m_mode == "taa") {
        // A07 复查结论：这两次全屏 pass（taa→history、copyColor→destination）没法合并成
        // “taa 直接写 destination”，三点原因缺一不可：
        //   1) m_history[next] 要留下**尚未呈现**的 16F 结果当下一帧的重投影历史，而 destination
        //      是调用方（RhiScene::composite）交进来的呈现目标，跨帧内容不保证保留，当不了历史；
        //   2) destination 是 8 位目标，拿它当历史会把 TAA 的多帧累积精度压回 8 位；
        //   3) taa 这个 pass 读 m_input、写 m_history[next]，两者不能别名。
        // 真要把这次拷贝收掉，只能让下游（呈现侧）直接采 m_history，那是 RhiScene 的接线，
        // 不在 A07 允许改动的文件里。第一帧多出来的那次 copyColor 同样必要：它就是历史初始化。
        if (!m_historyValid) {
            quad(commands, "copyColor", m_history[m_historyIndex].target, {m_input.texture});
            probe("taa-init", "首帧：copyColor→history 初始化 + copyColor→destination，2 次全屏 pass");
        } else {
            const int next = 1 - m_historyIndex;
            quad(commands, "taa", m_history[next].target,
                 {m_input.texture, m_history[m_historyIndex].texture, motion.motionVectors});
            m_historyIndex = next;
            probe("taa-steady", "taa→history(16F) + copyColor→destination，2 次全屏 pass（第二次数不了）");
        }
        quad(commands, "copyColor", destination, {m_history[m_historyIndex].texture});
        m_historyValid = true;
    } else if (isFsr(m_mode)) {
        const bool compute = m_fsr && m_fsr->available();
        bool resolved = false;
        if (compute) {
            commands->beginExternal();
            resolved = m_fsr->dispatch(rhi, commands, m_input.texture, motion.depth, motion.motionVectors,
                                       m_output.texture);
            commands->endExternal();
        }
        // A07：这个环境变量是 Engine/FrameProfiler 读的进程级开关，值只由 resolved 决定，而
        // resolved 在稳态下每帧都一样。原来每帧 qputenv 一次（QByteArray 堆分配 + 环境变量锁），
        // 现在只在值变化时写：跳过写入与重复写同一个值对读方完全等价，只在“能力翻转”时有一次
        // 额外写入，反而少了跨线程改环境的机会。回滚：RHINE_POST_REUSE=0 恢复每帧无条件写。
        const QByteArray engine = resolved ? QByteArrayLiteral("fsr3") : QByteArrayLiteral("shader");
        const bool changed = engine != m_fsrEngine;
        if (changed || !postReuse()) {
            qputenv("RHINE_FSR_ENGINE", engine);
        }
        if (changed) {
            m_fsrEngine = engine;
        }
        if (resolved) {
            // A07 复查结论：这次 copyColor 也省不掉。FSR3 的 compute 派发必须写进带
            // UsedWithLoadStore 的 16F 纹理（m_output），而 destination 是 8 位呈现目标：Vulkan 下
            // copyImage 跨格式是未定义数据（copyColor.frag 头注释记着实测整屏粉红），所以必须有一次
            // 采样式格式转换；m_output 也不能和 dispatch 的输出别名。让下游直接采 m_output 同样要改
            // RhiScene 的呈现接线，不在本轮范围。
            quad(commands, "copyColor", destination, {m_output.texture});
            probe("fsr3", "dispatch→m_output(16F) + copyColor→destination，2 次全屏 pass（含 16F→8 位转换）");
        } else {
            fsrQuad(commands, "fsr1_easu", m_output.target, m_input.texture,
                    Fsr1Constants::easu(m_renderSize, m_displaySize));
            const int effective =
                RhineFsr::effectiveSharpnessPercent(sharpness(), m_renderSize, m_displaySize);
            fsrQuad(commands, "fsr1_rcas", destination, m_output.texture,
                    Fsr1Constants::rcas(m_displaySize, float(100 - effective) / 100.f * 2.f));
            probe("fsr1", "easu→m_output + rcas→destination，2 次全屏 pass，没有额外拷贝");
        }
    }
}
} // namespace RhineRender
