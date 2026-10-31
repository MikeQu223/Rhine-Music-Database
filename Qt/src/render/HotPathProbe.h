#pragma once

// F01 热路径分段账本：把「卡片展开 / 实例打包 / 批次组装 / 池化对比与上传 / HUD 绘制」
// 各自的调用数、字节数、耗时收在同一张表里，由 RHINE_STEP_PROBE 每若干帧打印一行。
//
// 只做观测，不参与渲染决策。GUI 线程写卡片与 HUD，渲染线程写打包与批次，因此每个字段
// 都是原子量；打印方（GUI 线程）用 take() 一次性交换归零，避免跨帧混算。

#include <QString>
#include <QElapsedTimer>
#include <atomic>

namespace RhineRender {

struct HotPathWindow {
    std::atomic<quint64> frames{0};

    std::atomic<quint64> cardCalls{0};
    std::atomic<quint64> cardNs{0};
    std::atomic<quint64> cards{0};
    std::atomic<quint64> cardParts{0};
    std::atomic<quint64> cardDraws{0};

    std::atomic<quint64> packBytes{0};
    std::atomic<quint64> packNs{0};

    std::atomic<quint64> batchCount{0};
    std::atomic<quint64> batchBytes{0};
    std::atomic<quint64> batchNs{0};

    std::atomic<quint64> poolCompareBytes{0};
    std::atomic<quint64> poolUploadBytes{0};
    std::atomic<quint64> poolUploads{0};

    std::atomic<quint64> hudPaints{0};
    std::atomic<quint64> hudNs{0};
    std::atomic<quint64> hudCommands{0};
};

struct HotPathSample {
    quint64 frames = 0;
    quint64 cardCalls = 0, cardParts = 0, cards = 0, cardDraws = 0;
    double cardMs = 0, packMs = 0, batchMs = 0, hudMs = 0;
    quint64 packBytes = 0, batchCount = 0, batchBytes = 0;
    quint64 poolCompareBytes = 0, poolUploadBytes = 0, poolUploads = 0;
    quint64 hudPaints = 0, hudCommands = 0;
};

inline HotPathWindow &hotPathWindow()
{
    static HotPathWindow window;
    return window;
}

inline HotPathSample takeHotPathSample()
{
    auto &w = hotPathWindow();
    HotPathSample s;
    s.frames = w.frames.exchange(0);
    s.cardCalls = w.cardCalls.exchange(0);
    const quint64 cardNs = w.cardNs.exchange(0);
    s.cardMs = cardNs / 1e6;
    s.cards = w.cards.exchange(0);
    s.cardParts = w.cardParts.exchange(0);
    s.cardDraws = w.cardDraws.exchange(0);
    s.packBytes = w.packBytes.exchange(0);
    s.packMs = w.packNs.exchange(0) / 1e6;
    s.batchCount = w.batchCount.exchange(0);
    s.batchBytes = w.batchBytes.exchange(0);
    s.batchMs = w.batchNs.exchange(0) / 1e6;
    s.poolCompareBytes = w.poolCompareBytes.exchange(0);
    s.poolUploadBytes = w.poolUploadBytes.exchange(0);
    s.poolUploads = w.poolUploads.exchange(0);
    s.hudPaints = w.hudPaints.exchange(0);
    s.hudMs = w.hudNs.exchange(0) / 1e6;
    s.hudCommands = w.hudCommands.exchange(0);
    return s;
}

// 作用域计时：把 nsecsElapsed 累加进某个原子计数。
class HotPathTimer
{
public:
    explicit HotPathTimer(std::atomic<quint64> &sink) : m_sink(sink) { m_clock.start(); }
    ~HotPathTimer() { m_sink.fetch_add(quint64(m_clock.nsecsElapsed())); }
    HotPathTimer(const HotPathTimer &) = delete;
    HotPathTimer &operator=(const HotPathTimer &) = delete;

private:
    std::atomic<quint64> &m_sink;
    QElapsedTimer m_clock;
};

inline QString formatHotPathLine(const HotPathSample &s)
{
    const quint64 frames = s.frames ? s.frames : 1;
    // 字节按「每帧」给，便于和 3D内部 的分段耗时段对齐。
    const double packKb = double(s.packBytes) / double(frames) / 1024.0;
    const double batchKb = double(s.batchBytes) / double(frames) / 1024.0;
    const double poolKb = double(s.poolUploadBytes) / double(frames) / 1024.0;
    const double compareKb = double(s.poolCompareBytes) / double(frames) / 1024.0;
    return QStringLiteral("热路径(每帧): 卡片展开 %1 次 %2 ms/%3 卡 %4 部件 → %5 draw | "
                          "实例打包 %6 KB %7 ms | 批次 %8 组 %9 KB %10 ms | "
                          "池化 对比 %11 KB 上传 %12 KB(%13 次) | "
                          "HUD %14 次 %15 ms %16 条命令")
        .arg(double(s.cardCalls) / double(frames), 0, 'f', 2)
        .arg(s.cardMs / double(frames), 0, 'f', 2)
        .arg(double(s.cards) / double(frames), 0, 'f', 1)
        .arg(double(s.cardParts) / double(frames), 0, 'f', 1)
        .arg(double(s.cardDraws) / double(frames), 0, 'f', 1)
        .arg(packKb, 0, 'f', 1)
        .arg(s.packMs / double(frames), 0, 'f', 2)
        .arg(double(s.batchCount) / double(frames), 0, 'f', 1)
        .arg(batchKb, 0, 'f', 1)
        .arg(s.batchMs / double(frames), 0, 'f', 2)
        .arg(compareKb, 0, 'f', 1)
        .arg(poolKb, 0, 'f', 1)
        .arg(double(s.poolUploads) / double(frames), 0, 'f', 1)
        .arg(double(s.hudPaints) / double(frames), 0, 'f', 2)
        .arg(s.hudMs / double(frames), 0, 'f', 2)
        .arg(double(s.hudCommands) / double(frames), 0, 'f', 1);
}

} // namespace RhineRender
