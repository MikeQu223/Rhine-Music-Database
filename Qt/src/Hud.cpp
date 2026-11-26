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
#include <QSGTransformNode>
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
#if defined(Q_OS_ANDROID)
namespace {
/// 舞台坐标脏区 → item 逻辑坐标。归因失效（空矩形、不足 1 像素、超过 92% 画布）
/// 时返回 full=true，调用方整块重画——绝不能静默跳过，那会让纹理停在上一份内容。
struct HudItemRegion {
    bool full = false;
    QRectF rect;
};
HudItemRegion hudItemRegion(QRectF stage, double scale, double itemWidth, double itemHeight) {
    HudItemRegion result;
    if (stage.isNull()) {
        // 淡入时只有 alpha 在变，它没有包围盒；别让 adjusted(-2,-2,2,2) 把空矩形
        // 撑成 4x4 伪区域绕过 <1 兜底，否则 HUD 整层停在上一页。
        result.full = true;
        return result;
    }
    QRectF rect(stage.x() * scale, stage.y() * scale, stage.width() * scale, stage.height() * scale);
    // 抗锯齿会让路径与字形溢出边界约 1 像素，向外放 2 像素再取整。
    rect = rect.adjusted(-2, -2, 2, 2).intersected(QRectF(0, 0, itemWidth, itemHeight));
    if (rect.width() < 1 || rect.height() < 1) {
        result.full = true;
        return result;
    }
    if (rect.width() * rect.height() > itemWidth * itemHeight * 0.92) {
        result.full = true;
        return result;
    }
    result.rect = rect;
    return result;
}
} // namespace
#endif

void Hud::scheduleUpdate() {
#if defined(Q_OS_ANDROID)
    // HUDFLOW 诊断（第六轮，默认开、限流）：区分「调度没发生」和「调度了但出帧链断了」。
    static int schedCount = 0;
    if (++schedCount % 240 == 1) {
        qWarning("HUDFLOW 调度 #%d: fullRepaint=%d staticFull=%d engineDirtyFull=%d item=%dx%d",
                 schedCount, int(m_fullRepaint), int(m_staticFullRepaint),
                 int(m_engine && m_engine->hudDirtyFull()), int(width()), int(height()));
    }
    // 局部重绘：命令流比对出改动区域，只重画这块、只上传这块（见 render/HudDirtyRect.h）。
    // 默认开启；RHINE_HUD_DIRTY_RECT=0 退回整窗重绘，方便 A/B。
    // 注意别写成 qEnvironmentVariableIntValue(...) != 0——变量未设置时它返回 0，
    // 那个写法会让"默认开启"的开关实际是关的。
    static const bool partial = [] {
        const auto value = qEnvironmentVariable("RHINE_HUD_DIRTY_RECT");
        return value.isEmpty() || value != QLatin1String("0");
    }();
    if (partial && m_engine && width() > 0 && height() > 0) {
        const double scale = height() / 1080;
        const bool layered = m_engine->hudLayered();
        QRectF pending;
        bool anyFull = false;
        // 只调度「本帧真的变了」的那一层：拿旧脏区重画未变的层等于白付一次绘制+
        // 一次纹理上传，分层的收益会被这点浪费吃回去。
        auto accumulate = [&](const QRectF &stage, bool engineFull, bool changed, bool &dirtyFlag,
                              bool &fullFlag, QRectF &target) {
            if (!changed) {
                return;
            }
            dirtyFlag = true;
            auto region = hudItemRegion(stage, scale, width(), height());
            if (engineFull) {
                region.full = true;
            }
            if (region.full) {
                fullFlag = true;
                anyFull = true;
                return;
            }
            target = target.isNull() ? region.rect : target.united(region.rect);
            pending = pending.isNull() ? region.rect : pending.united(region.rect);
        };
        accumulate(m_engine->hudDirtyStage(), m_engine->hudDirtyFull(),
                   !layered || m_engine->hudDynamicChanged(), m_dynamicDirty, m_fullRepaint,
                   m_pendingDirty);
        if (layered) {
            accumulate(m_engine->hudStaticDirtyStage(), m_engine->hudStaticDirtyFull(),
                       m_engine->hudStaticChanged(), m_staticDirty, m_staticFullRepaint,
                       m_pendingStatic);
        }
        if (!m_dynamicDirty && !m_staticDirty) {
            // 过渡期 Engine 会「命令流没变也发一帧」逼呈现。这一帧确实无事可画，
            // 直接回报已消费，别让引擎的兜底轮询空转到超时。
            m_engine->noteHudFramePainted();
            return;
        }
        if (m_fullRepaint || m_staticFullRepaint) {
            anyFull = true;
        }
        if (anyFull) {
            QQuickPaintedItem::update();
        } else {
            // 观测：滑动时到底脏了多少。设备上设不了环境变量，所以默认开着、
            // 只按次数限流（每 240 次局部重绘一行），定位完这段可以删。
            static int probeFrames = 0;
            static double probeArea = 0;
            static double probePeak = 0;
            const double ratio = pending.width() * pending.height() / (width() * height());
            probeArea += ratio;
            probePeak = qMax(probePeak, ratio);
            if (++probeFrames >= 240) {
                qInfo("HUD 脏区: 平均 %.1f%% / 峰值 %.1f%% 画布", probeArea / probeFrames * 100,
                      probePeak * 100);
                probeArea = 0;
                probePeak = 0;
                probeFrames = 0;
            }
            QQuickPaintedItem::update(pending.toAlignedRect());
        }
        requestWindowFrame();
        return;
    }
    m_fullRepaint = true;
    m_staticFullRepaint = true;
    m_dynamicDirty = true;
    m_staticDirty = true;
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
        paintCommands(painter, m_engine->commands());
    }
#else
    paintCommands(painter, m_engine->commands());
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

/**
 * 一段命令流的绘制。分层后静态前缀与动态条带各调一次（各自一张纹理），
 * 单层路径仍是一整条流调一次——两条路径的绘制代码是同一份，不是两套实现。
 */
void Hud::paintCommands(QPainter *painter, const QJsonArray &commands) {
#ifdef Q_OS_LINUX
    static const bool skipPaint = qEnvironmentVariableIntValue("RHINE_HUD_SKIP_PAINT") == 1;
    if (skipPaint) {
        return;
    }
#endif
#if defined(Q_OS_DARWIN)
    static const bool cacheText = qEnvironmentVariableIntValue("RHINE_HUD_TEXT_CACHE") == 1;
    m_engine->glyphs()->commands(*painter, commands,
                                 [this](QString key) { return m_engine->host.image(key); }, cacheText);
#else
    m_engine->glyphs()->commands(*painter, commands,
                                 [this](QString key) { return m_engine->host.image(key); });
#endif
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
 * Android：把 HUD 画进自己管的纹理，只重传改动过的子矩形。
 *
 * 默认的 QQuickPaintedItem 节点不管脏区大小，每次 commit 都 `uploadTexture(整张)`，
 * 2880x1800 就是每帧 20.7MB 的写带宽；叠上整张画布的透明清屏，滑动时等于每帧
 * 白白来回搬 40MB 以上。这里换成子区域上传，块大小由命令流比对给出。
 *
 * 分层（见 render/HudLayers.h）：命令流被切成「静态前缀 / 动态条带」两段，各一张纹理、
 * 各一个节点，静态在前动态在后。静态前缀（列表遮罩、品牌、导航、footer）不变时
 * 这一层完全不画、不上传——滑列表时它覆盖整个列表条带，正是单层脏区退化成整屏的原因。
 */
QSGNode *Hud::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *updateData) {
    const bool hadNode = oldNode != nullptr;
    static const bool partial = [] {
        const auto value = qEnvironmentVariable("RHINE_HUD_DIRTY_RECT");
        return value.isEmpty() || value != QLatin1String("0");
    }();
    // 分层开关：默认开，RHINE_HUD_LAYERED=0 退回单层（A/B 与现场排障用）。
    static const bool layeredEnabled = [] {
        const auto value = qEnvironmentVariable("RHINE_HUD_LAYERED");
        return value.isEmpty() || value != QLatin1String("0");
    }();
    if (!partial || !window() || !window()->rhi()) {
        if (m_engine) {
            m_engine->noteHudFramePainted();
        }
        if (m_layeredNode) {
            // 退回默认绘制路径：节点形态不同，不能把这个容器节点交给基类强转。
            delete oldNode;
            m_layeredNode = false;
            m_fullRepaint = true;
            m_staticFullRepaint = true;
            m_dynamicDirty = true;
            m_staticDirty = true;
        }
        return QQuickPaintedItem::updatePaintNode(oldNode, updateData);
    }
    const QSize logical(qCeil(width()), qCeil(height()));
    if (logical.isEmpty()) {
        delete oldNode;
        m_layeredNode = false;
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
    const bool layered = layeredEnabled && m_engine && m_engine->hudLayered();
    // item 逻辑坐标 → 纹理像素：脏区按比例换算并向外取整 1 像素，避免取整切掉边缘。
    auto pixelRegion = [&](const QRectF &dirty, bool full) {
        if (full || dirty.isNull()) {
            return QRect(QPoint(0, 0), pixels);
        }
        const double sx = double(pixels.width()) / logical.width();
        const double sy = double(pixels.height()) / logical.height();
        const QRect cover(qFloor(dirty.x() * sx), qFloor(dirty.y() * sy),
                          qCeil(dirty.width() * sx) + 1, qCeil(dirty.height() * sy) + 1);
        return cover.intersected(QRect(QPoint(0, 0), pixels));
    };
    auto paintLayer = [&](QSGSimpleTextureNode *target, const QRect &region,
                          const QJsonArray &commands) {
        if (region.isEmpty()) {
            return;
        }
        auto &stats = RhineRender::hudPaintStats();
        stats.paints.fetch_add(1, std::memory_order_relaxed);
        stats.dirtyPixels.fetch_add(quint64(region.width()) * quint64(region.height()),
                                    std::memory_order_relaxed);
        stats.canvasPixels.fetch_add(quint64(pixels.width()) * quint64(pixels.height()),
                                     std::memory_order_relaxed);
        auto texture = static_cast<RhineRender::HudUploadTexture *>(target->texture());
        texture->paintRegion(pixels, region, [&](QPainter &painter) {
            painter.scale(double(pixels.width()) / logical.width(),
                          double(pixels.height()) / logical.height());
            paintCommands(&painter, commands);
        });
    };
    auto configure = [&](QSGSimpleTextureNode *target) {
        target->setRect(0, 0, logical.width(), logical.height());
        target->setSourceRect(QRectF(QPointF(), pixels));
        // 纹理被缩过就必须线性过滤，否则文字边缘会出锯齿块。
        target->setFiltering((smooth() || texScale < 1.0) ? QSGTexture::Linear : QSGTexture::Nearest);
        target->markDirty(QSGNode::DirtyMaterial);
    };
    if (layered) {
        QSGTransformNode *root = nullptr;
        QSGSimpleTextureNode *background = nullptr;
        QSGSimpleTextureNode *foreground = nullptr;
        if (m_layeredNode && oldNode && oldNode->childCount() == 2) {
            root = static_cast<QSGTransformNode *>(oldNode);
            background = static_cast<QSGSimpleTextureNode *>(root->firstChild());
            foreground = static_cast<QSGSimpleTextureNode *>(background->nextSibling());
        } else {
            delete oldNode;
            // QSGNode 的构造函数是 protected，借恒等变换节点当容器最便宜的载体。
            root = new QSGTransformNode;
            background = new QSGSimpleTextureNode;
            foreground = new QSGSimpleTextureNode;
            background->setTexture(new RhineRender::HudUploadTexture);
            background->setOwnsTexture(true);
            foreground->setTexture(new RhineRender::HudUploadTexture);
            foreground->setOwnsTexture(true);
            root->appendChildNode(background);
            root->appendChildNode(foreground);
            m_layeredNode = true;
            m_staticFullRepaint = true;
            m_fullRepaint = true;
            m_dynamicDirty = true;
            m_staticDirty = true;
        }
        const QRect staticRegion = m_staticDirty ? pixelRegion(m_pendingStatic, m_staticFullRepaint)
                                                 : QRect();
        const QRect dynamicRegion = m_dynamicDirty ? pixelRegion(m_pendingDirty, m_fullRepaint)
                                                   : QRect();
        // HUDFLOW 诊断（默认开、限流）：sync 真发生了才有这行。两层都 0x0 表示这一帧
        // 被判定为「无事可画」——若此时 Engine 侧 pending 仍置位，说明握手没被清掉。
        static int nodeCount = 0;
        if (++nodeCount % 240 == 1) {
            qWarning("HUDFLOW sync #%d: layered bg=%dx%d fg=%dx%d full=%d/%d node=%d", nodeCount,
                     staticRegion.width(), staticRegion.height(), dynamicRegion.width(),
                     dynamicRegion.height(), int(m_staticFullRepaint), int(m_fullRepaint),
                     int(hadNode));
        }
        if (!staticRegion.isEmpty() || !dynamicRegion.isEmpty()) {
            // 与单层路径同一口径：一帧记一次 paints，命令条数记两段之和，
            // hudNs 覆盖两层的栅格化时间（这才是这一帧真实的 HUD 成本）。
            RhineRender::HotPathTimer hudTimer(RhineRender::hotPathWindow().hudNs);
            RhineRender::hotPathWindow().hudPaints.fetch_add(1);
            RhineRender::hotPathWindow().hudCommands.fetch_add(
                quint64(m_engine->hudStaticCommands().size() +
                        m_engine->hudDynamicCommands().size()));
            paintLayer(background, staticRegion, m_engine->hudStaticCommands());
            paintLayer(foreground, dynamicRegion, m_engine->hudDynamicCommands());
        }
        configure(background);
        configure(foreground);
        m_staticDirty = false;
        m_dynamicDirty = false;
        m_staticFullRepaint = false;
        m_fullRepaint = false;
        m_pendingStatic = QRectF();
        m_pendingDirty = QRectF();
        if ((!staticRegion.isEmpty() || !dynamicRegion.isEmpty()) &&
            m_engine->noteHudFramePainted()) {
            static int consumedFrames = 0;
            if (++consumedFrames % 20 == 1) {
                qInfo("HUD frame: consumed bg=%dx%d fg=%dx%d (render sync 已发生)",
                      staticRegion.width(), staticRegion.height(), dynamicRegion.width(),
                      dynamicRegion.height());
            }
        }
        return root;
    }
    if (m_layeredNode) {
        // 分层 → 单层：节点形态变了，整棵重建（下一帧再画）。
        delete oldNode;
        oldNode = nullptr;
        m_layeredNode = false;
        m_fullRepaint = true;
        m_staticFullRepaint = true;
        m_dynamicDirty = true;
        m_staticDirty = true;
    }
    auto node = static_cast<QSGSimpleTextureNode *>(oldNode);
    auto texture = node ? static_cast<RhineRender::HudUploadTexture *>(node->texture())
                        : new RhineRender::HudUploadTexture();
    const QRect region = m_dynamicDirty ? pixelRegion(m_pendingDirty, m_fullRepaint) : QRect();
    // HUDFLOW 诊断（第六轮，默认开、限流）：region=0x0 表示被判定为「无事可画」——
    // 若此时 Engine 侧 pending 仍置位，说明 item 脏位/基线出了问题。
    static int nodeCount = 0;
    if (++nodeCount % 240 == 1) {
        qWarning("HUDFLOW sync #%d: region=%dx%d full=%d pending=%dx%d node=%d", nodeCount,
                 region.width(), region.height(), int(m_fullRepaint), int(m_pendingDirty.width()),
                 int(m_pendingDirty.height()), int(node != nullptr));
    }
    if (!node) {
        node = new QSGSimpleTextureNode();
        node->setTexture(texture);
        node->setOwnsTexture(true);
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
    configure(node);
    // 单层路径没有静态层：把静态层的待绘状态一并清掉，否则 scheduleUpdate 会
    // 因为一个永远消费不掉的 m_staticDirty 而每帧都整窗重画。
    m_dynamicDirty = false;
    m_staticDirty = false;
    m_fullRepaint = false;
    m_staticFullRepaint = false;
    m_pendingDirty = QRectF();
    m_pendingStatic = QRectF();
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
