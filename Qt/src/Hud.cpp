#include <QtGlobal>
#include "Hud.h"
#include "Engine.h"
#include "render/HotPathProbe.h"
#include <QDebug>
#include <QElapsedTimer>
#include <QPainter>
#include <QQuickWindow>
#if defined(Q_OS_MACOS) || defined(Q_OS_ANDROID)
#include "render/HudUploadTexture.h"
#include <QSGSimpleTextureNode>
#include <QtMath>
#endif
Hud::Hud(QQuickItem *parent) : QQuickPaintedItem(parent) {
    setOpaquePainting(false);
    setAntialiasing(true);
}
void Hud::setEngine(Engine *engine) {
    if (engine == m_engine) {
        return;
    }
    if (m_engine) {
        disconnect(m_engine, nullptr, this, nullptr);
    }
    m_engine = engine;
    if (engine) {
        connect(engine, &Engine::hudUpdated, this, [this] { scheduleUpdate(); });
    }
    emit engineChanged();
    update();
}
void Hud::scheduleUpdate() {
#if defined(Q_OS_ANDROID)
    // 局部重绘：命令流比对出改动区域，只重画这块、只上传这块（见 render/HudDirtyRect.h）。
    // 关掉开关（RHINE_HUD_DIRTY_RECT=0）退回整窗重绘，方便 A/B。
    static const bool partial = qEnvironmentVariableIntValue("RHINE_HUD_DIRTY_RECT") != 0;
    if (partial && m_engine && width() > 0 && height() > 0 && !m_fullRepaint) {
        if (!m_engine->hudDirtyFull()) {
            const double scale = height() / 1080;
            const auto stage = m_engine->hudDirtyStage();
            QRectF rect(stage.x() * scale, stage.y() * scale, stage.width() * scale, stage.height() * scale);
            // 抗锯齿会让路径与字形溢出边界约 1 像素，向外放 2 像素再取整。
            rect = rect.adjusted(-2, -2, 2, 2).intersected(QRectF(0, 0, width(), height()));
            if (rect.width() < 1 || rect.height() < 1) {
                return; // 命令流变了但没有绘制内容变化（例如只改了命中区）。
            }
            if (rect.width() * rect.height() > width() * height() * 0.92) {
                m_fullRepaint = true;
                QQuickPaintedItem::update();
                return;
            }
            // 探针（RHINE_HUD_PROBE=1）：脏区占比直接回答"是不是整屏都在动"。
            // 滑列表时若这个数远小于 100%，局部重绘就是有效的。
            static const bool probe = qEnvironmentVariableIntValue("RHINE_HUD_PROBE") == 1;
            static int probeFrames = 0;
            static double probeArea = 0;
            static double probePeak = 0;
            if (probe) {
                const double ratio = rect.width() * rect.height() / (width() * height());
                probeArea += ratio;
                probePeak = qMax(probePeak, ratio);
                if (++probeFrames % 60 == 0) {
                    qInfo("HUD 脏区: 平均 %.1f%% / 峰值 %.1f%% 画布", probeArea / probeFrames * 100,
                          probePeak * 100);
                    probeArea = 0;
                    probePeak = 0;
                    probeFrames = 0;
                }
            }
            m_pendingDirty = m_pendingDirty.isNull() ? rect : m_pendingDirty.united(rect);
            QQuickPaintedItem::update(rect.toAlignedRect());
            return;
        }
    }
    m_fullRepaint = true;
#endif
    update();
}
void Hud::paint(QPainter *painter) {
    if (!m_engine) {
        return;
    }
    // F01：HUD 绘制成本与命令条数，和卡片展开、实例打包一起看才分得清谁是真瓶颈。
    RhineRender::HotPathTimer hudTimer(RhineRender::hotPathWindow().hudNs);
    RhineRender::hotPathWindow().hudPaints.fetch_add(1);
    RhineRender::hotPathWindow().hudCommands.fetch_add(quint64(m_engine->commands().size()));
    // 探针（RHINE_HUD_PROBE=1）：这条覆盖层的真实尺寸与 DPR 决定 HUD 的绘制缩放，
    // 与 NativeHud 记录的舞台宽度必须自洽（舞台宽 = item 宽 / (item 高/1080)）。
    if (qEnvironmentVariableIntValue("RHINE_HUD_PROBE") == 1) {
        static QSizeF lastProbeSize;
        const QSizeF size(width(), height());
        if (size != lastProbeSize) {
            lastProbeSize = size;
            qWarning().noquote() << "HUD 探针: item 尺寸" << size << "DPR"
                                 << (window() ? window()->devicePixelRatio() : 0.0);
        }
    }
    // 绘制成本探针（RHINE_HUD_PROBE=1）：HUD 是 QPainter 程序化绘制，
    // 这个数字决定「按中间相位再画一遍」这种插值方案的实际价码。
    static const bool hudTiming = qEnvironmentVariableIntValue("RHINE_HUD_PROBE") == 1;
    static double paintMs = 0.0;
    static int paintFrames = 0;
    QElapsedTimer paintClock;
    if (hudTiming) {
        paintClock.start();
    }
#ifdef Q_OS_LINUX
    // 上限实验（RHINE_HUD_SKIP_PAINT=1）：完全跳过 HUD 绘制，量"文字栅格化免费"时的
    // 帧率天花板。画面会缺 HUD，只用于测定收益上限，不作正常配置。
    static const bool skipPaint = qEnvironmentVariableIntValue("RHINE_HUD_SKIP_PAINT") == 1;
#endif
    painter->save();
    painter->scale(height() / 1080, height() / 1080);
#ifdef Q_OS_LINUX
    if (!skipPaint) {
        m_engine->glyphs()->commands(*painter, m_engine->commands(),
                                     [this](QString key) { return m_engine->host.image(key); });
    }
#elif defined(Q_OS_DARWIN)
    static const bool cacheText = qEnvironmentVariableIntValue("RHINE_HUD_TEXT_CACHE") == 1;
    m_engine->glyphs()->commands(
        *painter, m_engine->commands(), [this](QString key) { return m_engine->host.image(key); }, cacheText);
#else
    m_engine->glyphs()->commands(*painter, m_engine->commands(),
                                 [this](QString key) { return m_engine->host.image(key); });
#endif
    painter->restore();
    if (hudTiming) {
        paintMs = paintMs * 0.8 + double(paintClock.nsecsElapsed()) / 1e6 * 0.2;
        if (++paintFrames % 30 == 0) {
            qWarning("HUD 绘制: %d 条命令 绘制 %.2f ms (item %.0fx%.0f)", int(m_engine->commands().size()),
                     paintMs, width(), height());
        }
    }
}

#ifdef Q_OS_DARWIN
/** Metal 排障候选：复用原绘制顺序和物理尺寸，只替换纹理上传策略。 */
QSGNode *Hud::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *updateData) {
#ifdef Q_OS_MACOS
    static const bool partialUpload = qEnvironmentVariableIntValue("RHINE_HUD_PARTIAL_UPLOAD") == 1;
    if (partialUpload && window() && window()->rhi() && window()->rhi()->backend() == QRhi::Metal) {
        const QSize logical(qCeil(width()), qCeil(height()));
        const auto pixels = logical * window()->effectiveDevicePixelRatio();
        if (pixels.isEmpty()) {
            delete oldNode;
            return nullptr;
        }
        auto node = static_cast<QSGSimpleTextureNode *>(oldNode);
        auto texture = node ? static_cast<RhineRender::HudUploadTexture *>(node->texture())
                            : new RhineRender::HudUploadTexture();
        texture->paint(pixels, [&](QPainter &painter) {
            painter.scale(double(pixels.width()) / logical.width(),
                          double(pixels.height()) / logical.height());
            paint(&painter);
        });
        if (!node) {
            node = new QSGSimpleTextureNode();
            node->setTexture(texture);
            node->setOwnsTexture(true);
        }
        node->setRect(0, 0, logical.width(), logical.height());
        node->setSourceRect(QRectF(QPointF(), pixels));
        node->setFiltering(smooth() ? QSGTexture::Linear : QSGTexture::Nearest);
        node->markDirty(QSGNode::DirtyMaterial);
        return node;
    }
#endif
    return QQuickPaintedItem::updatePaintNode(oldNode, updateData);
}

#endif

#if defined(Q_OS_ANDROID)
/**
 * Android：把 HUD 画进一张自己管的纹理，只重传改动过的子矩形。
 *
 * 默认的 QQuickPaintedItem 节点不管脏区大小，每次 commit 都 `uploadTexture(整张)`，
 * 2880x1800 就是每帧 20.7MB 的写带宽；叠上整张画布的透明清屏，滑动时等于每帧
 * 白白来回搬 40MB 以上。这里换成子区域上传，块大小由命令流比对给出。
 */
QSGNode *Hud::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *updateData) {
    static const bool partial = qEnvironmentVariableIntValue("RHINE_HUD_DIRTY_RECT") != 0;
    if (!partial || !window() || !window()->rhi()) {
        return QQuickPaintedItem::updatePaintNode(oldNode, updateData);
    }
    const QSize logical(qCeil(width()), qCeil(height()));
    if (logical.isEmpty()) {
        delete oldNode;
        return nullptr;
    }
    // 纹理分辨率档（RHINE_HUD_TEXTURE_SCALE=50..100，默认 100）：脏区再小，
    // 遇到整块重画（换页 / 启动动画）时这也是唯一能直接砍像素数的旋钮。
    static const double texScale = [] {
        const int percent = qEnvironmentVariableIntValue("RHINE_HUD_TEXTURE_SCALE");
        return percent >= 50 && percent <= 100 ? percent / 100.0 : 1.0;
    }();
    const double dpr = window()->effectiveDevicePixelRatio();
    const QSize pixels(qMax(1, qRound(logical.width() * dpr * texScale)),
                       qMax(1, qRound(logical.height() * dpr * texScale)));
    auto node = static_cast<QSGSimpleTextureNode *>(oldNode);
    auto texture = node ? static_cast<RhineRender::HudUploadTexture *>(node->texture())
                        : new RhineRender::HudUploadTexture();
    QRect region(QPoint(0, 0), pixels);
    if (node && !m_fullRepaint && !m_pendingDirty.isNull()) {
        const double sx = double(pixels.width()) / logical.width();
        const double sy = double(pixels.height()) / logical.height();
        const QRect cover(qFloor(m_pendingDirty.x() * sx), qFloor(m_pendingDirty.y() * sy),
                          qCeil(m_pendingDirty.width() * sx) + 1,
                          qCeil(m_pendingDirty.height() * sy) + 1);
        region = cover.intersected(QRect(QPoint(0, 0), pixels));
    }
    if (!region.isEmpty()) {
        texture->paintRegion(pixels, region, [&](QPainter &painter) {
            painter.scale(double(pixels.width()) / logical.width(),
                          double(pixels.height()) / logical.height());
            paint(&painter);
        });
    }
    if (!node) {
        node = new QSGSimpleTextureNode();
        node->setTexture(texture);
        node->setOwnsTexture(true);
    }
    node->setRect(0, 0, logical.width(), logical.height());
    node->setSourceRect(QRectF(QPointF(), pixels));
    // 纹理被缩过就必须线性过滤，否则文字边缘会出锯齿块。
    node->setFiltering((smooth() || texScale < 1.0) ? QSGTexture::Linear : QSGTexture::Nearest);
    node->markDirty(QSGNode::DirtyMaterial);
    m_fullRepaint = false;
    m_pendingDirty = QRectF();
    return node;
}
#endif
