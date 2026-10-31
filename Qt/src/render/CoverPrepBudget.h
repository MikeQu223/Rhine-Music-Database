// 封面预处理的并发账本与需求判定（B03）。从 RhiScene 里抽出来，是因为这两件事写错
// 不会崩、只会慢慢漏：并发名额被"逻辑取消"提前归还，实际线程数就会超过上限；
// 需求判定漏掉共享 revision，就会把同专辑好几首共用的封面中途丢掉。
// header-only、只依赖 Qt6::Core，渲染器与用例共用同一份实现。
#pragma once

#include <QHash>
#include <QSet>
#include <QString>
#include <QtGlobal>

namespace RhineRender {

/**
 * 在途预算。语义只有一条要记牢：**逻辑取消不归还名额**——工作线程还在跑，名额就还被
 * 它占着；只有收到它的结果（成功或失败）才 release()。cancel() 只标记"结果回来时
 * 不必留"，账本上的数不变。
 */
class CoverPrepBudget
{
public:
    struct Ticket {
        quint64 serial = 0;
        bool acquired = false;
    };

    explicit CoverPrepBudget(int limit = 4) : m_limit(qMax(1, limit)) {}

    /// 满员返回 acquired=false（调用方当帧不排队，下一帧再试）。
    Ticket acquire(quint64 serial)
    {
        if (int(m_running.size()) >= m_limit) {
            return {};
        }
        m_running.insert(serial);
        m_peak = qMax(m_peak, int(m_running.size()));
        return {serial, true};
    }

    /// 收到结果（成功/失败/放弃）时调用；未知代号返回 false，避免重复归还把上限抬高。
    bool release(quint64 serial) { return m_running.remove(serial) > 0; }

    /// 逻辑取消：不归还名额，只记一笔，方便探针区分"取消"与"丢弃"。
    bool cancel(quint64 serial)
    {
        if (!m_running.contains(serial)) {
            return false;
        }
        ++m_cancelled;
        return true;
    }

    int inflight() const { return int(m_running.size()); }
    int limit() const { return m_limit; }
    int peak() const { return m_peak; }
    quint64 cancelled() const { return m_cancelled; }
    bool contains(quint64 serial) const { return m_running.contains(serial); }

    /// 渲染器随设备重建换新；线程池已经终止时旧账一笔勾销（否则名额永久泄漏）。
    void reset()
    {
        m_running.clear();
        m_peak = 0;
        m_cancelled = 0;
    }

private:
    int m_limit = 4;
    QSet<quint64> m_running;
    int m_peak = 0;
    quint64 m_cancelled = 0;
};

/// 需求表：key → 这个 key 想要的封面 revision（QImage::cacheKey）。
using CoverDemand = QHash<QString, qint64>;

/// 还有没有任何 key 想要这个 revision（共享封面靠它判断，不能按单个 key 判）。
inline bool coverRevisionWanted(const CoverDemand &demand, qint64 revision)
{
    for (auto it = demand.cbegin(); it != demand.cend(); ++it) {
        if (it.value() == revision) {
            return true;
        }
    }
    return false;
}

/// 除 key 之外还有别人要这个 revision 吗（同专辑多曲共用一张封面）。
inline bool coverRevisionSharedByOthers(const CoverDemand &demand, qint64 revision, const QString &key)
{
    for (auto it = demand.cbegin(); it != demand.cend(); ++it) {
        if (it.key() != key && it.value() == revision) {
            return true;
        }
    }
    return false;
}

/**
 * 工作线程回来的一条成品要不要接受。三个条件缺一不可：
 *   1. 请求代号仍是当前在途的那一个（切歌/取消后旧代号作废）；
 *   2. 这张 revision 还没被别的路径（同步兜底、另一条异步结果）做出来；
 *   3. 还有 key 真的想要它——没人要就只释放内存，不建 GPU 纹理。
 */
inline bool shouldAcceptPreparedCover(bool serialCurrent, bool alreadyUploaded, const CoverDemand &demand,
                                      qint64 revision)
{
    return serialCurrent && !alreadyUploaded && coverRevisionWanted(demand, revision);
}

} // namespace RhineRender
