#include "LyricsBackdrop.h"

#include "Engine.h"
#include "render/LyricsBackdropPolicy.h"

#include <QFile>
#include <QMatrix4x4>
#include <QQuickWindow>
#include <QVector3D>
#include <QVector4D>
#include <rhi/qrhi.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

namespace {

constexpr int PaletteColorCount = 4;

QShader loadShader(const QString &name) {
    QFile file(QStringLiteral(":/shaders/") + name + QStringLiteral(".qsb"));
    if (!file.open(QIODevice::ReadOnly)) {
        qFatal("Missing lyrics backdrop shader: %s", qPrintable(name));
    }
    const auto shader = QShader::fromSerialized(file.readAll());
    if (!shader.isValid()) {
        qFatal("Invalid lyrics backdrop shader: %s", qPrintable(name));
    }
    return shader;
}

struct BackdropUniforms {
    std::array<float, 16> correction;
    std::array<float, 4> viewport;
    std::array<float, 4> paper;
    std::array<float, 4> parameters;
    std::array<float, PaletteColorCount * 4> palette;
    std::array<float, PaletteColorCount * 4> anchors;
};

static_assert(sizeof(BackdropUniforms) == 240);

QVector3D averageColor(const std::vector<QVector3D> &points) {
    QVector3D result;
    for (const auto &point : points) {
        result += point;
    }
    return points.empty() ? result : result / float(points.size());
}

std::array<QVector4D, PaletteColorCount> extractPalette(const QImage &source) {
    std::array<QVector4D, PaletteColorCount> result{};
    if (source.isNull()) {
        return result;
    }

    auto image = source.convertToFormat(QImage::Format_RGB32);
    if (image.width() != image.height()) {
        const int side = std::min(image.width(), image.height());
        const QRect crop((image.width() - side) / 2, (image.height() - side) / 2, side, side);
        image = image.copy(crop);
    }
    image = image.scaled(32, 32, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);

    std::vector<QVector3D> points;
    std::vector<float> weights;
    points.reserve(32 * 32);
    weights.reserve(32 * 32);
    for (int y = 0; y < image.height(); ++y) {
        for (int x = 0; x < image.width(); ++x) {
            const auto color = image.pixelColor(x, y);
            const QVector3D point(float(color.redF()), float(color.greenF()), float(color.blueF()));
            // 中性色仍然参与，但降低一点权重，避免黑边或白底完全压过封面主色。
            const float weight = .15f + 1.85f * float(color.saturationF());
            points.push_back(point);
            weights.push_back(weight);
        }
    }
    if (points.empty()) {
        return result;
    }

    const auto average = averageColor(points);
    std::array<QVector3D, PaletteColorCount> centers{};
    centers[0] = average;
    for (int index = 1; index < PaletteColorCount; ++index) {
        float bestScore = -1.f;
        int bestPoint = 0;
        for (int pointIndex = 0; pointIndex < int(points.size()); ++pointIndex) {
            float nearest = std::numeric_limits<float>::max();
            for (int centerIndex = 0; centerIndex < index; ++centerIndex) {
                nearest = std::min(nearest, (points[pointIndex] - centers[centerIndex]).lengthSquared());
            }
            const float score = nearest * weights[pointIndex];
            if (score > bestScore) {
                bestScore = score;
                bestPoint = pointIndex;
            }
        }
        centers[index] = points[bestPoint];
    }

    // 固定次数的轻量 k-means；只在换封面时执行，不进入逐帧路径。
    for (int iteration = 0; iteration < 6; ++iteration) {
        std::array<QVector3D, PaletteColorCount> sums{};
        std::array<float, PaletteColorCount> counts{};
        for (int pointIndex = 0; pointIndex < int(points.size()); ++pointIndex) {
            int nearest = 0;
            float distance = std::numeric_limits<float>::max();
            for (int centerIndex = 0; centerIndex < PaletteColorCount; ++centerIndex) {
                const float candidate = (points[pointIndex] - centers[centerIndex]).lengthSquared();
                if (candidate < distance) {
                    distance = candidate;
                    nearest = centerIndex;
                }
            }
            sums[nearest] += points[pointIndex] * weights[pointIndex];
            counts[nearest] += weights[pointIndex];
        }
        for (int index = 0; index < PaletteColorCount; ++index) {
            if (counts[index] > 0.f) {
                centers[index] = sums[index] / counts[index];
            }
        }
    }

    std::array<float, PaletteColorCount> clusterWeights{};
    for (int pointIndex = 0; pointIndex < int(points.size()); ++pointIndex) {
        int nearest = 0;
        float distance = std::numeric_limits<float>::max();
        for (int centerIndex = 0; centerIndex < PaletteColorCount; ++centerIndex) {
            const float candidate = (points[pointIndex] - centers[centerIndex]).lengthSquared();
            if (candidate < distance) {
                distance = candidate;
                nearest = centerIndex;
            }
        }
        clusterWeights[nearest] += weights[pointIndex];
    }
    const float totalWeight =
        std::max(1.f, clusterWeights[0] + clusterWeights[1] + clusterWeights[2] + clusterWeights[3]);
    for (int index = 0; index < PaletteColorCount; ++index) {
        const auto &color = centers[index];
        result[index] = {color.x(), color.y(), color.z(), clusterWeights[index] / totalWeight};
    }
    std::sort(result.begin(), result.end(),
              [](const QVector4D &left, const QVector4D &right) { return left.w() > right.w(); });
    return result;
}

class LyricsBackdropRenderer : public QQuickRhiItemRenderer {
  public:
    ~LyricsBackdropRenderer() override {
        if (m_pipeline) {
            m_pipeline->deleteLater();
        }
        if (m_bindings) {
            m_bindings->deleteLater();
        }
        if (m_uniforms) {
            m_uniforms->deleteLater();
        }
        if (m_renderPass) {
            m_renderPass->deleteLater();
        }
        if (m_target) {
            m_target->deleteLater();
        }
    }

    /** 固定颜色纹理变化时重建无深度目标与管线，尺寸相关资源不跨 target 生命周期复用。 */
    void initialize(QRhiCommandBuffer *commandBuffer) override {
        Q_UNUSED(commandBuffer);
        ensureResources();
        if (m_pipeline) {
            m_pipeline->deleteLater();
            m_pipeline = nullptr;
        }
        if (m_renderPass) {
            m_renderPass->deleteLater();
            m_renderPass = nullptr;
        }
        if (m_target) {
            m_target->deleteLater();
            m_target = nullptr;
        }
        m_target = rhi()->newTextureRenderTarget(
            QRhiTextureRenderTargetDescription{QRhiColorAttachment(colorTexture())});
        m_renderPass = m_target->newCompatibleRenderPassDescriptor();
        m_target->setRenderPassDescriptor(m_renderPass);
        if (!m_target->create()) {
            qFatal("Cannot create lyrics backdrop render target");
        }
        createPipeline();
    }

    /** GUI 线程已停住，只复制标量、封面 revision 与已提取的调色板。 */
    void synchronize(QQuickRhiItem *item) override {
        const auto *backdrop = static_cast<LyricsBackdrop *>(item);
        m_phase = float(backdrop->phase());
        m_darkTheme = backdrop->darkTheme();
        m_controlsOpacity = float(backdrop->controlsOpacity());
        m_controlsTop = float(backdrop->controlsTop());
        m_hasCover = backdrop->coverRevision() != 0 && !backdrop->coverImage().isNull();
        m_palette = backdrop->palette();
    }

    /** 单 pass 绘制全屏背景；封面仅在 revision 变化时上传，稳态只更新小 UBO。 */
    void render(QRhiCommandBuffer *commandBuffer) override {
        ensureResources();
        if (!m_target || !m_pipeline) {
            return;
        }

        BackdropUniforms data;
        std::memset(&data, 0, sizeof(data));
        const auto correction = rhi()->clipSpaceCorrMatrix();
        std::memcpy(data.correction.data(), correction.constData(), sizeof(data.correction));
        const auto targetSize = m_target->pixelSize();
        data.viewport = {float(targetSize.width()), float(targetSize.height()), m_phase,
                         m_hasCover ? 1.f : 0.f};
        data.paper = m_darkTheme ? std::array<float, 4>{.075f, .110f, .094f, 1.f}
                                 : std::array<float, 4>{.933f, .925f, .894f, .84f};
        data.parameters = {m_darkTheme ? 1.f : 0.f, m_controlsOpacity, m_controlsTop, 0.f};
        configurePalette(data, m_palette);

        auto *updates = rhi()->nextResourceUpdateBatch();
        updates->updateDynamicBuffer(m_uniforms, 0, sizeof(data), &data);
        commandBuffer->resourceUpdate(updates);

        commandBuffer->beginPass(m_target, Qt::black, {1.f, 0});
        commandBuffer->setGraphicsPipeline(m_pipeline);
        commandBuffer->setShaderResources(m_bindings);
        commandBuffer->setViewport({0.f, 0.f, float(targetSize.width()), float(targetSize.height())});
        commandBuffer->draw(3);
        commandBuffer->endPass();
    }

  private:
    void ensureResources() {
        if (!m_uniforms) {
            m_uniforms =
                rhi()->newBuffer(QRhiBuffer::Dynamic, QRhiBuffer::UniformBuffer, sizeof(BackdropUniforms));
            if (!m_uniforms->create()) {
                qFatal("Cannot create lyrics backdrop uniform buffer");
            }
        }
        if (!m_bindings) {
            m_bindings = rhi()->newShaderResourceBindings();
            m_bindings->setBindings({QRhiShaderResourceBinding::uniformBuffer(
                0, QRhiShaderResourceBinding::VertexStage | QRhiShaderResourceBinding::FragmentStage,
                m_uniforms)});
            if (!m_bindings->create()) {
                qFatal("Cannot create lyrics backdrop resource bindings");
            }
        }
    }

    void createPipeline() {
        m_pipeline = rhi()->newGraphicsPipeline();
        m_pipeline->setShaderStages(
            {{QRhiShaderStage::Vertex, loadShader(QStringLiteral("lyricsBackdrop.vert"))},
             {QRhiShaderStage::Fragment, loadShader(QStringLiteral("lyricsBackdrop.frag"))}});
        m_pipeline->setTargetBlends({QRhiGraphicsPipeline::TargetBlend{}});
        m_pipeline->setShaderResourceBindings(m_bindings);
        m_pipeline->setRenderPassDescriptor(m_renderPass);
        m_pipeline->setDepthTest(false);
        m_pipeline->setDepthWrite(false);
        m_pipeline->setSampleCount(1);
        if (!m_pipeline->create()) {
            qFatal("Cannot create lyrics backdrop pipeline");
        }
    }

    static void configurePalette(BackdropUniforms &data,
                                 const std::array<QVector4D, PaletteColorCount> &palette) {
        constexpr std::array<std::array<float, 4>, PaletteColorCount> anchors{{
            {.16f, .14f, .13f, 0.f},
            {.84f, .18f, .15f, 0.f},
            {.84f, .82f, .12f, 0.f},
            {.16f, .84f, .14f, 0.f},
        }};
        for (int index = 0; index < PaletteColorCount; ++index) {
            const auto &color = palette[index];
            const int base = index * 4;
            data.palette[base + 0] = color.x();
            data.palette[base + 1] = color.y();
            data.palette[base + 2] = color.z();
            data.palette[base + 3] = std::max(.02f, color.w());
            std::copy(anchors[index].begin(), anchors[index].end(), data.anchors.begin() + base);
        }
    }

    QRhiBuffer *m_uniforms = nullptr;
    QRhiShaderResourceBindings *m_bindings = nullptr;
    QRhiGraphicsPipeline *m_pipeline = nullptr;
    QRhiTextureRenderTarget *m_target = nullptr;
    QRhiRenderPassDescriptor *m_renderPass = nullptr;
    std::array<QVector4D, PaletteColorCount> m_palette{};
    float m_phase = 0;
    bool m_hasCover = false;
    bool m_darkTheme = false;
    float m_controlsOpacity = 0;
    float m_controlsTop = .68f;
};

} // namespace

LyricsBackdrop::LyricsBackdrop(QQuickItem *parent) : QQuickRhiItem(parent) {
    setAutoRenderTarget(false);
    setAlphaBlending(false);
    setSampleCount(1);
    setColorBufferFormat(QQuickRhiItem::TextureFormat::RGBA8);
    m_timer.setSingleShot(true);
    m_timer.setTimerType(Qt::PreciseTimer);
    connect(&m_timer, &QTimer::timeout, this, &LyricsBackdrop::tick);
    connect(this, &QQuickItem::visibleChanged, this, [this] {
        updateColorBufferSize();
        refreshCover();
        refreshTimer();
        update();
        requestWindowFrame();
    });
    connect(this, &QQuickItem::windowChanged, this, [this](QQuickWindow *window) {
        observeWindow(window);
        updateColorBufferSize();
        refreshTimer();
    });
}

void LyricsBackdrop::setEngine(Engine *engine) {
    if (m_engine == engine) {
        return;
    }
    if (m_engine) {
        disconnect(m_engine, nullptr, this, nullptr);
    }
    m_engine = engine;
    if (m_engine) {
        connect(m_engine, &Engine::hudUpdated, this, &LyricsBackdrop::refreshCover);
        connect(m_engine, &Engine::stateChanged, this, [this] {
            refreshCover();
            refreshTimer();
        });
    }
    refreshCover();
    refreshTimer();
    emit engineChanged();
}

void LyricsBackdrop::setPlaybackActive(bool value) {
    if (m_playbackActive == value) {
        return;
    }
    m_playbackActive = value;
    refreshTimer();
    emit playbackActiveChanged();
}

void LyricsBackdrop::setReducedMotion(bool value) {
    if (m_reducedMotion == value) {
        return;
    }
    m_reducedMotion = value;
    refreshTimer();
    update();
    requestWindowFrame();
    emit reducedMotionChanged();
}

void LyricsBackdrop::setDarkTheme(bool value) {
    if (m_darkTheme == value) {
        return;
    }
    m_darkTheme = value;
    update();
    requestWindowFrame();
    emit darkThemeChanged();
}

void LyricsBackdrop::setControlsOpacity(double value) {
    const double next = std::clamp(value, 0., 1.);
    if (qFuzzyCompare(m_controlsOpacity + 1., next + 1.)) {
        return;
    }
    m_controlsOpacity = next;
    update();
    requestWindowFrame();
    emit controlsOpacityChanged();
}

void LyricsBackdrop::setControlsTop(double value) {
    const double next = std::clamp(value, 0., 1.);
    if (qFuzzyCompare(m_controlsTop + 1., next + 1.)) {
        return;
    }
    m_controlsTop = next;
    update();
    requestWindowFrame();
    emit controlsTopChanged();
}

QQuickRhiItemRenderer *LyricsBackdrop::createRenderer() {
    return new LyricsBackdropRenderer();
}

void LyricsBackdrop::geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) {
    QQuickRhiItem::geometryChange(newGeometry, oldGeometry);
    updateColorBufferSize();
}

void LyricsBackdrop::observeWindow(QQuickWindow *window) {
    if (m_observedWindow == window) {
        return;
    }
    if (m_observedWindow) {
        disconnect(m_windowActiveConnection);
        disconnect(m_windowVisibilityConnection);
    }
    m_observedWindow = window;
    if (!window) {
        return;
    }
    m_windowActiveConnection = connect(window, &QWindow::activeChanged, this, &LyricsBackdrop::refreshTimer);
    m_windowVisibilityConnection =
        connect(window, &QWindow::visibilityChanged, this, &LyricsBackdrop::refreshTimer);
}

void LyricsBackdrop::refreshCover() {
    const auto image = m_engine ? m_engine->cover() : QImage();
    const auto revision = image.isNull() ? 0 : image.cacheKey();
    if (revision == m_coverRevision && image.isNull() == m_coverImage.isNull()) {
        return;
    }
    m_coverImage = image;
    m_coverRevision = revision;
    m_palette = extractPalette(image);
    update();
    requestWindowFrame();
}

/** 只有目标页可见、有效播放且应用可见时，低频定时器才推进背景相位。 */
void LyricsBackdrop::refreshTimer() {
    if (!shouldAnimate()) {
        m_timer.stop();
        return;
    }
    if (m_timer.isActive()) {
        return;
    }
    m_phaseClock.restart();
    m_timer.start(RhineRender::LyricsBackdropIntervalMs);
}

bool LyricsBackdrop::shouldAnimate() const {
    if (!m_engine || !isVisible()) {
        return false;
    }
    const bool engineVisible = m_engine->performance().value(QStringLiteral("visible"), true).toBool();
    // QQuickRenderControl 的离屏窗口永远不会 active/exposed；Engine 的可见状态才是可靠门控。
    return RhineRender::lyricsBackdropShouldAnimate(true, m_playbackActive, m_reducedMotion, engineVisible);
}

/** 15Hz 推进一次相位；背景静止或掉出可视状态后不再请求新帧。 */
void LyricsBackdrop::tick() {
    if (!shouldAnimate()) {
        m_timer.stop();
        return;
    }
    const qint64 elapsed = m_phaseClock.isValid() ? m_phaseClock.restart() : 0;
    // 页面短暂停顿后不补跳；背景运动本身足够慢，一次最多推进 120ms。
    m_phase += std::clamp(double(elapsed) / 1000.0, 0.0, .12);
    update();
    requestWindowFrame();
    m_timer.start(RhineRender::LyricsBackdropIntervalMs);
}

void LyricsBackdrop::requestWindowFrame() {
    // QQuickRenderControl 路径不会因为 QQuickItem 标脏就自动提交呈现帧。
    if (auto *quickWindow = window()) {
        quickWindow->update();
    }
}

void LyricsBackdrop::updateColorBufferSize() {
    const auto size = RhineRender::lyricsBackdropTargetSize(QSizeF(width(), height()));
    if (size.isEmpty() ||
        (size.width() == fixedColorBufferWidth() && size.height() == fixedColorBufferHeight())) {
        return;
    }
    setFixedColorBufferWidth(size.width());
    setFixedColorBufferHeight(size.height());
}
