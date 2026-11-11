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
#if defined(Q_OS_ANDROID)
#include "render/HudPaintStats.h"
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
void Hud::requestWindowFrame() {
    // QQuickItem::update() 只把 item 标脏；本项目有 QQuickRenderControl 驱动的
    // 呈现路径，窗口未必会因 item 标脏自动出帧。没有帧就不会走到
    // HudUploadTexture::commitTextureOperations，纹理仍是空的——表现为
    // 「命中区是新的、按钮能点，但整层 HUD 不显示」。显式请求一次呈现帧。
    if (auto *w = window()) {
        w->update();
    }
}
void Hud::scheduleUpdate() {
#if defined(Q_OS_ANDROID)
    // HUDFLOW 诊断（第六轮，默认开、限流）：区分「调度没发生」和「调度了但出帧链断了」。
    static int schedCount = 0;
    if (++schedCount % 240 == 1) {
        qWarning("HUDFLOW 调度 #%d: fullRepaint=%d engineDirtyFull=%d item=%dx%d", schedCount,
                 int(m_fullRepaint), int(m_engine && m_engine->hudDirtyFull()), int(width()),
                 int(height()));
    }
    // 局部重绘：命令流比对出改动区域，只重画这块、只上传这块（见 render/HudDirtyRect.h）。
    // 默认开启；RHINE_HUD_DIRTY_RECT=0 退回整窗重绘，方便 A/B。
    // 注意别写成 qEnvironmentVariableIntValue(...) != 0——变量未设置时它返回 0，
    // 那个写法会让"默认开启"的开关实际是关的。
    static const bool partial = [] {
        const auto value = qEnvironmentVariable("RHINE_HUD_DIRTY_RECT");
        return value.isEmpty() || value != QLatin1String("0");
    }();
    if (partial && m_engine && width() > 0 && height() > 0 && !m_fullRepaint) {
        if (!m_engine->hudDirtyFull()) {
            const double scale = height() / 1080;
            const auto stage = m_engine->hudDirtyStage();
            if (stage.isNull()) {
                // 归因失效（真机实证：详情淡入期间唯一逐帧变化的命令是 alpha，它没有
                // 包围盒，归因出空矩形）。绝不能让下面的 adjusted(-2,-2,2,2) 把空矩形
                // 变成 4x4 伪区域绕过 <1 兜底——那正是「进详情后 HUD 只更新 6x6 像素、
                // 整层停在上一页」的成因。命令流变了却定位不了，就整窗重画。
                m_fullRepaint = true;
                QQuickPaintedItem::update();
                requestWindowFrame();
                return;
            }
            QRectF rect(stage.x() * scale, stage.y() * scale, stage.width() * scale, stage.height() * scale);
            // 抗锯齿会让路径与字形溢出边界约 1 像素，向外放 2 像素再取整。
            rect = rect.adjusted(-2, -2, 2, 2).intersected(QRectF(0, 0, width(), height()));
            if (rect.width() < 1 || rect.height() < 1) {
                // 命令流变了却归因不出可用脏区：绝不能静默 return。
                // 那样纹理会停在上一份内容，正是「按钮能点但整层 HUD 不显示」的成因。
                m_fullRepaint = true;
                QQuickPaintedItem::update();
                requestWindowFrame();
                return;
            }
            if (rect.width() * rect.height() > width() * height() * 0.92) {
                m_fullRepaint = true;
                QQuickPaintedItem::update();
                requestWindowFrame();
                return;
            }
            // 观测：滑动时到底脏了多少。设备上设不了环境变量，所以默认开着、
            // 只按次数限流（每 240 次局部重绘一行），定位完这段可以删。
            static int probeFrames = 0;
            static double probeArea = 0;
            static double probePeak = 0;
            const double ratio = rect.width() * rect.height() / (width() * height());
            probeArea += ratio;
            probePeak = qMax(probePeak, ratio);
            if (++probeFrames >= 240) {
                qInfo("HUD 脏区: 平均 %.1f%% / 峰值 %.1f%% 画布", probeArea / probeFrames * 100,
                      probePeak * 100);
                probeArea = 0;
                probePeak = 0;
                probeFrames = 0;
            }
            m_pendingDirty = m_pendingDirty.isNull() ? rect : m_pendingDirty.united(rect);
            QQuickPaintedItem::update(rect.toAlignedRect());
            requestWindowFrame();
            return;
        }
    }
    m_fullRepaint = true;
#endif
    update();
    requestWindowFrame();
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
    static const bool partial = [] {
        const auto value = qEnvironmentVariable("RHINE_HUD_DIRTY_RECT");
        return value.isEmpty() || value != QLatin1String("0");
    }();
    if (!partial || !window() || !window()->rhi()) {
        if (m_engine) {
            m_engine->noteHudFramePainted();
        }
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
    // HUDFLOW 诊断（第六轮，默认开、限流）：sync 真发生了才有这行。region=0x0 表示
    // 被判定为「无事可画」——若此时 Engine 侧 pending 仍置位，说明 item 脏位/基线
    // 出了问题，轮询兜底会持续逼渲直到画上为止。
    static int nodeCount = 0;
    if (++nodeCount % 240 == 1) {
        qWarning("HUDFLOW sync #%d: region=%dx%d full=%d pending=%dx%d node=%d", nodeCount,
                 region.width(), region.height(), int(m_fullRepaint), int(m_pendingDirty.width()),
                 int(m_pendingDirty.height()), int(node != nullptr));
    }
    if (!region.isEmpty()) {
        auto &stats = RhineRender::hudPaintStats();
        stats.paints.fetch_add(1, std::memory_order_relaxed);
        stats.dirtyPixels.fetch_add(quint64(region.width()) * quint64(region.height()),
                                    std::memory_order_relaxed);
        stats.canvasPixels.fetch_add(quint64(pixels.width()) * quint64(pixels.height()),
                                     std::memory_order_relaxed);
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
    if (m_engine && !region.isEmpty()) {
        // 只有真正把命令流画进了纹理才允许 Engine 恢复连轴转；上面 fallback 分支
        // 也在自己的出口清位。区域为空时不画也不清位（交给 Engine 的 2 秒兜底）。
        if (m_engine->noteHudFramePainted()) {
            static int consumedFrames = 0;
            if (++consumedFrames % 20 == 1) {
                qInfo("HUD frame: consumed region=%dx%d (render sync 已发生)", region.width(),
                      region.height());
            }
        }
    }
    return node;
}
#endif
