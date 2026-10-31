#include <QtGlobal>
#include "Hud.h"
#include "Engine.h"
#include "render/HotPathProbe.h"
#include <QDebug>
#include <QElapsedTimer>
#include <QPainter>
#include <QQuickWindow>
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
        connect(engine, &Engine::hudUpdated, this, [this] { update(); });
    }
    emit engineChanged();
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
#else
    m_engine->glyphs()->commands(*painter, m_engine->commands(),
                                 [this](QString key) { return m_engine->host.image(key); });
#endif
    painter->restore();
    if (hudTiming) {
        paintMs = paintMs * 0.8 + double(paintClock.nsecsElapsed()) / 1e6 * 0.2;
        if (++paintFrames % 30 == 0) {
            qWarning("HUD 绘制: %d 条命令 绘制 %.2f ms (item %.0fx%.0f)",
                     int(m_engine->commands().size()), paintMs, width(), height());
        }
    }
}
