#pragma once
#include "MusicTextureAdmission.h"

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVector>

#include <cmath>
#include <limits>
#include <optional>

/**
 * Flutter 归档格 → 原生可见格的业务资源投影。
 *
 * 归档页背景那批卡片共享一份实例缓冲，只能当占位档案壳；这里给每格补业务身份
 * （siren:<kind>:<id>，位置不参与）、决定稳定窗准入、并给覆盖绘制定稳定的 draw id。
 * 全是无状态纯函数或可注入时钟的状态机，只靠离线用例回归。
 */
namespace RhineRender {

// 5 列 × 8 行的可见窗口。超出的条目直接丢弃：一次快照不该把整库带进原生侧。
inline constexpr int EmbeddedCellMaxCount = 40;
// 同时"待定"的 key 上限，也就是封面请求的并发闸。
inline constexpr int EmbeddedCellMaxPending = 8;
// 已准入 key 的上限。可见窗口 5 列 × 5 行最多 25 格要能同时显示，再加 3 个热复用余量。
// 内存口径：一格 = 512×220 标签（含 mip 约 0.6MB）+ 512² 封面（含 mip 约 1.3MB），
// 28 格约 54MB，仍在 RhiScene 的 64MB 音乐纹理预算之内。
inline constexpr int EmbeddedCellMaxAdmitted = 28;
// 同一个 URL 的失败重试上限。成功一次之后不再请求（图在 Host 缓存里）。
inline constexpr int EmbeddedCellCoverAttempts = 2;
// 原生格行号的基准：Flutter 的 r 是窗口内偏移，原生 Cell.row = 12 + r。
inline constexpr int EmbeddedCellRowBase = 12;

/** 一个可见格的业务资源。身份与封面地址分开存：身份决定 key，地址决定要不要下载。 */
struct EmbeddedCell {
    QString key;
    QString kind;
    QString id;
    QString title;
    QString artist;
    QString album;
    QString cover;
    int lane = 0;
    int row = 0;

    bool valid() const {
        return !key.isEmpty() && !id.isEmpty();
    }
};

/** 一次快照的投影结果。signature 用于"同一份快照重复上报"的短路判定。 */
struct EmbeddedCellProjection {
    QVector<EmbeddedCell> cells;
    QString signature;
    int dropped = 0;

    bool empty() const {
        return cells.isEmpty();
    }
};

/** 资源 key：与选中曲目同一套命名（current["key"] 就是这个形状）。 */
inline QString embeddedCellKey(const QString &kind, const QString &id) {
    if (kind.isEmpty() || id.isEmpty()) {
        return {};
    }
    return QStringLiteral("siren:") + kind + QLatin1Char(':') + id;
}

/**
 * 原生格的实例身份。必须与 NativeSceneUpdate.cpp 的 cellInstanceId 同一编码
 * （lane 高 16 位、row 低 16 位），否则覆盖绘制找不到它所属的格，运动矢量也会错配。
 */
inline quint32 embeddedCellId(int lane, int row) {
    return quint32(quint16(lane)) << 16 | quint16(row);
}

/**
 * 每格两条覆盖绘制的 draw id。取远离 actor 区间（-id*256-part）与 10 的命名空间，
 * 同一格同一槽位跨帧稳定：材质 arena 的键是 (id, mesh, name)，id 抖动会让整批换槽。
 */
inline int embeddedCellDrawId(quint32 cellId, int slot) {
    return -int(0x20000000u + (cellId & 0x00ffffffu) * 2u + quint32(slot));
}

/** 身份字段可能是数字（Song.id）也可能是字符串，两种都按同一种文本落进 key。 */
inline QString embeddedCellIdentity(const QJsonValue &value) {
    if (value.isString()) {
        return value.toString().trimmed();
    }
    if (value.isDouble()) {
        const auto number = value.toDouble();
        if (std::isfinite(number) && number == double(qint64(number))) {
            return QString::number(qint64(number));
        }
        if (std::isfinite(number)) {
            return QString::number(number);
        }
    }
    return {};
}

/**
 * {l,r,k,i,t[,c,a,b]} → EmbeddedCell。身份或位置不可信就返回 nullopt：
 * 宁可这一格保持占位，也不能让它落到别人的格上（贴错封面比不贴更糟）。
 */
inline std::optional<EmbeddedCell> embeddedCellFrom(const QJsonObject &value) {
    EmbeddedCell cell;
    cell.kind = value.value("k").toString().trimmed();
    cell.id = embeddedCellIdentity(value.value("i"));
    cell.key = embeddedCellKey(cell.kind, cell.id);
    if (cell.key.isEmpty()) {
        return std::nullopt;
    }
    const auto lane = value.value("l").toInt(-1);
    const auto offset = value.value("r").toDouble(std::numeric_limits<double>::quiet_NaN());
    if (lane < 0 || lane > 4 || !std::isfinite(offset)) {
        return std::nullopt;
    }
    cell.lane = lane;
    // r 是绝对逻辑行偏移；绝不取模、也不拿行号当身份，行号只用来找格。
    cell.row = EmbeddedCellRowBase + int(std::lround(offset));
    cell.title = value.value("t").toString();
    cell.artist = value.value("a").toString();
    cell.album = value.value("b").toString();
    cell.cover = value.value("c").toString();
    return cell;
}

/**
 * 解析整份快照：保持 Flutter 给的顺序（第一项是窗口首格），同 key 只留第一条，
 * 最多 EmbeddedCellMaxCount 条。contextGeneration 进签名：换了上下文即使内容一样
 * 也要让调用方知道这是新的一批，不能靠旧签名短路。
 */
inline EmbeddedCellProjection projectEmbeddedCells(const QJsonArray &cells, quint64 contextGeneration) {
    EmbeddedCellProjection projection;
    QSet<QString> seen;
    QStringList signature;
    signature.reserve(cells.size() + 1);
    signature.append(QStringLiteral("ctx:") + QString::number(contextGeneration));
    for (const auto &entry : cells) {
        if (projection.cells.size() >= EmbeddedCellMaxCount) {
            ++projection.dropped;
            continue;
        }
        const auto cell = embeddedCellFrom(entry.toObject());
        if (!cell) {
            ++projection.dropped;
            continue;
        }
        if (seen.contains(cell->key)) {
            ++projection.dropped;
            continue;
        }
        seen.insert(cell->key);
        // 签名覆盖一切会影响画面的字段：身份、位置、文字、封面地址。
        signature.append(cell->key + QLatin1Char('@') + QString::number(cell->lane) + QLatin1Char(',') +
                         QString::number(cell->row) + QLatin1Char('|') + cell->cover + QLatin1Char('|') +
                         cell->title + QLatin1Char('|') + cell->artist + QLatin1Char('|') + cell->album);
        projection.cells.append(*cell);
    }
    projection.signature = signature.join(QLatin1Char('\n'));
    return projection;
}

/**
 * 迟到结果还能不能写回这一格：条目必须仍在投影里，且它的封面地址仍是发起请求时那个。
 * A→B→A（同一格先后换成不同身份/不同封面）就是靠这条判据把中间那次的结果丢掉，
 * 否则 late completion 会把旧图贴到新身份上。
 */
inline bool embeddedCellCoverStillWanted(const EmbeddedCell *cell, const QString &requested) {
    return cell != nullptr && !requested.isEmpty() && cell->cover == requested;
}

/**
 * 可见格的多 key 稳定窗准入。
 *
 * 与单焦点的 MusicTextureAdmission 不同，可见格是一组 key，由 step() 每帧上报，
 * 调用方只按 nextAdmissionInMs() 安排唤醒。
 *
 * 规则：同一 key 连续出现不重计时；滚动中计时冻结、一个都不准入；
 * contextGeneration 变化只丢弃待定项；窗口隐藏丢弃待定；名额满时淘汰最久未出现的已准入项。
 */
class EmbeddedCellAdmission {
  public:
    struct Report {
        int visible = 0;
        int admitted = 0;
        int pending = 0;
        int started = 0;
        int dropped = 0;
        // 到期了却进不来（名额全被在窗口里的格占着，没有可淘汰项）。这类待定项不该让引擎
        // 一直醒着等：它们只能等窗口变化，调用方据此排除出唤醒/休眠判据。
        int starved = 0;
        quint64 generation = 0;
    };

    /** 与选中通道同一档延迟（Android 500ms、其它 100ms），可用环境变量压到 0 做排查。 */
    static constexpr int defaultDelayMs() {
        return PlatformTextureAdmissionMs;
    }

    explicit EmbeddedCellAdmission(int delayMs = defaultDelayMs(),
                                   int maxAdmitted = EmbeddedCellMaxAdmitted,
                                   int maxPending = EmbeddedCellMaxPending)
        : m_delayMs(qMax(0, delayMs)), m_maxAdmitted(qMax(1, maxAdmitted)),
          m_maxPending(qMax(1, maxPending)) {}

    static EmbeddedCellAdmission fromEnvironment() {
        bool ok = false;
        const auto raw = qEnvironmentVariableIntValue("RHINE_CELL_ADMISSION_MS", &ok);
        return EmbeddedCellAdmission(ok ? qBound(0, raw, 60000) : defaultDelayMs());
    }

    int delayMs() const {
        return m_delayMs;
    }
    int maxAdmitted() const {
        return m_maxAdmitted;
    }
    int maxPending() const {
        return m_maxPending;
    }
    bool visible() const {
        return m_visible;
    }
    bool scrolling() const {
        return m_scrolling;
    }
    quint64 generation() const {
        return m_generation;
    }
    quint64 context() const {
        return m_context;
    }

    bool isAdmitted(const QString &key) const {
        return m_entries.value(key).admitted;
    }
    bool isPending(const QString &key) const {
        const auto entry = m_entries.value(key);
        return !entry.admitted && entry.sinceMs >= 0;
    }
    int admittedCount() const {
        int count = 0;
        for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it) {
            if (it->admitted) {
                ++count;
            }
        }
        return count;
    }
    int pendingCount() const {
        int count = 0;
        for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it) {
            if (!it->admitted && it->sinceMs >= 0) {
                ++count;
            }
        }
        return count;
    }
    QStringList admittedKeys() const {
        QStringList keys;
        for (auto it = m_order.cbegin(); it != m_order.cend(); ++it) {
            keys.append(*it);
        }
        return keys;
    }

    void setVisible(bool visible, qint64 nowMs) {
        Q_UNUSED(nowMs);
        if (visible == m_visible) {
            return;
        }
        m_visible = visible;
        ++m_generation;
        if (!visible) {
            // 隐藏时待定项作废：重建图形设备后重新计时，别把旧窗口的进度当成筹码。
            dropPending();
            m_visibleKeys.clear();
        }
    }

    /** 每帧一次：按可见顺序上报，返回聚合结果供诊断与帧字段使用。 */
    Report report(const QStringList &visibleKeys, quint64 contextGeneration, bool scrolling,
                  qint64 nowMs) {
        Report result;
        if (contextGeneration != m_context) {
            m_context = contextGeneration;
            ++m_generation;
            dropPending();
        }
        if (scrolling != m_scrolling) {
            m_scrolling = scrolling;
            ++m_generation;
            if (scrolling) {
                // 滚动开始：所有计时归零。滚动期间不推进计时，停止后才重新起算。
                dropPending();
            }
        }
        m_visibleKeys.clear();
        QStringList ordered;
        ordered.reserve(visibleKeys.size());
        for (const auto &key : visibleKeys) {
            if (key.isEmpty() || m_visibleKeys.contains(key)) {
                continue;
            }
            m_visibleKeys.insert(key);
            ordered.append(key);
        }
        result.visible = ordered.size();
        // 离开窗口的待定项直接丢掉：它们回来时应该重新计时，不然滚动中"顺带"熬满 500ms。
        for (auto it = m_entries.begin(); it != m_entries.end();) {
            if (!it->admitted && !m_visibleKeys.contains(it.key())) {
                it = m_entries.erase(it);
                ++result.dropped;
            } else {
                ++it;
            }
        }
        if (m_visible) {
            // 可见项整体提到 LRU 前端（顺序即可见顺序），淘汰永远从"最久没出现过"的那端开始。
            for (int index = ordered.size() - 1; index >= 0; --index) {
                touch(ordered.at(index));
            }
            int pending = 0;
            for (const auto &key : ordered) {
                if (isAdmitted(key)) {
                    continue;
                }
                if (m_scrolling) {
                    continue;
                }
                if (pending >= m_maxPending) {
                    // 待定名额满：先来先得，其余等空位，避免一次性挂十几张封面。
                    ++result.dropped;
                    continue;
                }
                auto entry = m_entries.value(key);
                if (entry.sinceMs < 0 || entry.sinceMs > nowMs) {
                    // 时钟回退（上下文重建）时同样重新起算，绝不用一个未来的起点。
                    entry.sinceMs = nowMs;
                    m_entries.insert(key, entry);
                    ++result.started;
                    ++pending;
                    continue;
                }
                if (nowMs - entry.sinceMs >= m_delayMs) {
                    if (admit(key)) {
                        continue;
                    }
                    // 名额被可见格占满且无可淘汰：保持待定，下一帧再看。
                    ++result.starved;
                    const auto stalled = m_entries.find(key);
                    if (stalled != m_entries.end()) {
                        stalled->starved = true;
                    }
                } else {
                    const auto waiting = m_entries.find(key);
                    if (waiting != m_entries.end()) {
                        waiting->starved = false;
                    }
                }
                ++pending;
            }
            result.pending = pending;
        }
        result.admitted = admittedCount();
        result.generation = m_generation;
        return result;
    }

    /**
     * 距离下一次"可能准入"还有多久（毫秒）。调用方拿它安排一次唤醒，而不是连着烧帧。
     * 没有待定项返回 -1。
     */
    int nextAdmissionInMs(qint64 nowMs) const {
        int wait = -1;
        for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it) {
            if (it->admitted || it->sinceMs < 0 || it->starved) {
                // starved 项等的是窗口变化，不是时间：按它唤醒只会空转。
                continue;
            }
            const auto remaining = int(qMax<qint64>(0, m_delayMs - (nowMs - it->sinceMs)));
            wait = wait < 0 ? remaining : qMin(wait, remaining);
        }
        return wait;
    }

    void reset() {
        m_entries.clear();
        m_order.clear();
        m_visibleKeys.clear();
        ++m_generation;
    }

  private:
    struct Entry {
        // -1 = 还没开始计时。0 是合法的起点（引擎 elapsed 从 0 起），所以不能用 0 当哨兵。
        qint64 sinceMs = -1;
        bool admitted = false;
        // 上一轮到期却进不来：只有窗口变化才可能解锁，别拿它安排唤醒。
        bool starved = false;
    };

    void dropPending() {
        for (auto it = m_entries.begin(); it != m_entries.end();) {
            if (it->admitted) {
                ++it;
            } else {
                it = m_entries.erase(it);
            }
        }
    }

    void touch(const QString &key) {
        if (!isAdmitted(key)) {
            return;
        }
        m_order.removeAll(key);
        m_order.prepend(key);
    }

    /** 名额满时淘汰最久没在窗口里出现的已准入项。窗口里的格一律不动。 */
    bool evictBehind() {
        for (int index = m_order.size() - 1; index >= 0; --index) {
            const auto &key = m_order.at(index);
            if (m_visibleKeys.contains(key)) {
                continue;
            }
            m_entries.remove(key);
            m_order.removeAt(index);
            return true;
        }
        return false;
    }

    bool admit(const QString &key) {
        if (isAdmitted(key)) {
            return true;
        }
        while (admittedCount() >= m_maxAdmitted) {
            if (!evictBehind()) {
                return false;
            }
        }
        Entry entry;
        entry.admitted = true;
        m_entries.insert(key, entry);
        m_order.removeAll(key);
        m_order.prepend(key);
        ++m_generation;
        return true;
    }

    int m_delayMs = defaultDelayMs();
    int m_maxAdmitted = EmbeddedCellMaxAdmitted;
    int m_maxPending = EmbeddedCellMaxPending;
    bool m_visible = true;
    bool m_scrolling = false;
    quint64 m_generation = 1;
    quint64 m_context = 0;
    QHash<QString, Entry> m_entries;
    QStringList m_order;
    QSet<QString> m_visibleKeys;
};

/**
 * 一帧的可见格记账：真实 = 该格这一帧真的绑到了自己的封面像素；占位 = 只有标签或都没有。
 * 这是"本帧 N 格真实 / M 格占位"唯一的口径来源，日志与 frame 字段都从这里出。
 */
struct EmbeddedCellBinding {
    int visible = 0;
    int admitted = 0;
    int covers = 0;
    int labels = 0;
    int placeholders = 0;
};

inline EmbeddedCellBinding embeddedCellBinding(const QStringList &order, const QSet<QString> &admitted,
                                               const QSet<QString> &covers, const QSet<QString> &labels) {
    EmbeddedCellBinding binding;
    for (const auto &key : order) {
        if (key.isEmpty()) {
            continue;
        }
        ++binding.visible;
        if (admitted.contains(key)) {
            ++binding.admitted;
        }
        if (covers.contains(key)) {
            ++binding.covers;
        }
        if (labels.contains(key)) {
            ++binding.labels;
        }
        // 占位 = 连自己的封面都没有的格。有标签无封面时封面仍是 placeholderCover，
        // 所以口径按封面算：这正是用户看到的"白纸板"。
        if (!covers.contains(key)) {
            ++binding.placeholders;
        }
    }
    return binding;
}

} // namespace RhineRender
