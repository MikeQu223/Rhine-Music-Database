// 快速滚动的冷纹理准入（B01）：焦点 key 在单调时钟上稳定 delayMs 之后才允许创建
// 标签／封面纹理。判定与计时分离：这里只做纯判断（假时钟可测），真正的 QTimer 由
// AdmissionScheduler 承担，GUI 线程只维护"当前焦点的一次性定时器"。
//
// 三条容易写错、写错又不会崩的语义，都在下面的注释里钉住：
//   1. 同 key 重复帧、封面晚到、revision 变化都不重计时——否则滚动越久越等不到；
//   2. 切走再回来要重计时，但已经准入过的 key 直接命中（热缓存立即复用）；
//   3. 隐藏期间不作数：恢复后从恢复时刻重新计时。
// 只依赖 Qt6::Core，渲染器与用例共用同一份实现。
#pragma once

#include <QElapsedTimer>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QtGlobal>
#include <functional>
#include <utility>

namespace RhineRender {

/**
 * RHINE_TEXTURE_ADMISSION_MS：准入延迟毫秒数。默认 100；0 关闭延迟（全部立即准入）；
 * 非数字/负数/超范围回默认值——一个笔误把延迟设成 0 是功能回退，设成几十秒则是"界面
 * 永远不出图"，两种都不该由环境变量静默决定。
 */
inline int musicTextureAdmissionDelayFromEnvironment()
{
    bool ok = false;
    const int value = qEnvironmentVariableIntValue("RHINE_TEXTURE_ADMISSION_MS", &ok);
    if (!ok) {
        return 100;
    }
    if (value < 0 || value > 60000) {
        return 100;
    }
    return value;
}

/**
 * 准入状态机（GUI 线程）。全部输入都是单调毫秒，不读时钟、不碰定时器，因此可以在
 * 用例里用 0／99／100 这种精确边界断言，不需要 sleep。
 */
class MusicTextureAdmission
{
public:
    static constexpr int DefaultDelayMs = 100;
    /// 已准入 key 的记忆条数。与纹理 LRU 同量级：超过之后最早的 key 需要重新计时，
    /// 但那时它的纹理也早被淘汰了，"重新计时"正好等于"重新预热"。
    static constexpr int MaxAdmitted = 32;

    struct Status {
        bool admitted = false;  ///< 当前 key 现在就可以创建资源
        bool pending = false;   ///< 在等延迟到期（要挂一次性定时器）
        quint64 generation = 0; ///< 焦点代号；旧定时器回调靠它失效
    };

    explicit MusicTextureAdmission(int delayMs = DefaultDelayMs) : m_delayMs(delayMs) {}
    static MusicTextureAdmission fromEnvironment()
    {
        return MusicTextureAdmission(musicTextureAdmissionDelayFromEnvironment());
    }

    int delayMs() const { return m_delayMs; }
    bool enabled() const { return m_delayMs > 0; }
    bool visible() const { return m_visible; }
    quint64 generation() const { return m_generation; }
    QString pendingKey() const { return m_pending ? m_key : QString(); }
    qint64 pendingSinceMs() const { return m_sinceMs; }
    QString focusKey() const { return m_key; }

    /// 可见性：隐藏时挂起等待，恢复时若还没准入就从恢复时刻重新计时。
    void setVisible(bool value, qint64 nowMs)
    {
        if (m_visible == value) {
            return;
        }
        m_visible = value;
        if (!value) {
            // 隐藏期间不创建资源：把"已等到一半"作废，但也别把已准入的 key 忘掉，
            // 恢复后热缓存仍要立即复用。
            m_pending = false;
            ++m_generation;
            return;
        }
        if (!m_key.isEmpty() && !isAdmitted(m_key)) {
            m_sinceMs = nowMs;
            m_pending = true;
            ++m_generation;
        }
    }

    /**
     * 报告当前焦点（每帧可调用）。key 为空表示没有焦点，撤销等待。
     * 返回 pending 时调用方负责 arm 一次性定时器；返回 admitted 时定时器可以停掉。
     */
    Status focus(const QString &key, qint64 nowMs)
    {
        if (key.isEmpty()) {
            m_key.clear();
            m_pending = false;
            ++m_generation;
            return {false, false, m_generation};
        }
        if (key != m_key) {
            m_key = key;
            ++m_generation;
            if (isAdmitted(key)) {
                m_pending = false;
                m_sinceMs = nowMs;
                return {true, false, m_generation};
            }
            m_sinceMs = nowMs;
            // 隐藏期间不创建资源，也就不该挂定时器：setVisible(true) 会从恢复时刻重新计时。
            m_pending = m_visible;
            return {false, m_pending, m_generation};
        }
        // 同 key：不重计时。封面晚到、标题 revision 变化都只是"采用最新内容"。
        if (!m_pending) {
            return {isAdmitted(key), false, m_generation};
        }
        if (!m_visible) {
            // 隐藏期间不计时：等恢复时 setVisible(true) 会重置起点。
            return {false, false, m_generation};
        }
        if (m_delayMs <= 0) {
            admit(key);
            return {true, false, m_generation};
        }
        if (nowMs - m_sinceMs >= m_delayMs) {
            admit(key);
            return {true, false, m_generation};
        }
        return {false, true, m_generation};
    }

    /**
     * 定时器到期：核对 key／代号／可见性／剩余时长。任何一项不符都返回 false，调用方
     * 不要自己猜——旧回调就是这么被挡掉的。
     */
    bool expire(const QString &key, quint64 generation, qint64 nowMs)
    {
        if (!m_pending || !m_visible || key != m_key || generation != m_generation) {
            return false;
        }
        if (m_delayMs > 0 && nowMs - m_sinceMs < m_delayMs) {
            return false;
        }
        admit(key);
        return true;
    }

    bool isAdmitted(const QString &key) const { return m_admitted.contains(key); }
    QSet<QString> admittedKeys() const { return m_admitted; }
    int admittedCount() const { return int(m_admitted.size()); }

    /// 设备恢复后不清空：准入是"用户已经看过它"的事实，纹理重建要沿着这份记忆走。
    /// 只有显式 reset（切换数据源／退出）才清。
    void reset()
    {
        m_admitted.clear();
        m_key.clear();
        m_pending = false;
        m_sinceMs = 0;
        ++m_generation;
    }

private:
    void admit(const QString &key)
    {
        m_pending = false;
        if (isAdmitted(key)) {
            return;
        }
        m_admitted.insert(key);
        m_order.removeAll(key);
        m_order << key;
        while (m_order.size() > MaxAdmitted) {
            m_admitted.remove(m_order.takeFirst());
        }
    }

    int m_delayMs = DefaultDelayMs;
    bool m_visible = true;
    bool m_pending = false;
    QString m_key;
    QStringList m_order;  // 准入顺序（尾部最新），超限时丢最旧的
    QSet<QString> m_admitted;
    quint64 m_generation = 0;
    qint64 m_sinceMs = 0;
};

/**
 * 一次性定时器。只负责"到点喊一声"，判定全在 MusicTextureAdmission：
 * 回调参数带着 arm 时的 key 与代号，过期回调由 expire() 自己核对掉。
 *
 * 用 QTimer 成员而不是 QObject 子类：没有 Q_OBJECT，用例与引擎都能直接持有；
 * 计时器随对象析构，销毁后不会再有回调（Qt 保证 context 对象销毁即断开）。
 */
class AdmissionScheduler
{
public:
    using Handler = std::function<void(const QString &key, quint64 generation)>;

    AdmissionScheduler()
    {
        m_timer.setSingleShot(true);
        m_timer.setTimerType(Qt::PreciseTimer);
        QObject::connect(&m_timer, &QTimer::timeout, &m_timer, [this] {
            if (m_handler) {
                m_handler(m_key, m_generation);
            }
        });
    }

    void setHandler(Handler handler) { m_handler = std::move(handler); }
    /// 只在焦点代号变化时 arm；同一个 key 的重复帧再次 arm 会把到期时间无限推后。
    void arm(int delayMs, const QString &key, quint64 generation)
    {
        if (m_timer.isActive() && m_key == key && m_generation == generation) {
            return;
        }
        m_key = key;
        m_generation = generation;
        m_timer.start(qMax(0, delayMs));
    }
    void stop() { m_timer.stop(); }
    bool active() const { return m_timer.isActive(); }
    int remainingMs() const { return m_timer.remainingTime(); }
    QString key() const { return m_key; }
    quint64 generation() const { return m_generation; }

private:
    QTimer m_timer;
    QString m_key;
    quint64 m_generation = 0;
    Handler m_handler;
};

} // namespace RhineRender
