#ifndef RHINE_EMBEDDED_SCENE_ORIGIN_H
#define RHINE_EMBEDDED_SCENE_ORIGIN_H

// 嵌入式场景的产出者身份与生命周期判据。header-only，无 Engine / QQuickView / JNI，
// 宿主与离线测试共用同一份判据。
//
// 硬规则：origin 随值走，不读全局；未登记、已关闭、旧视图、旧代次一律 fail-closed；
// 按住期间不许被 idle-commit；只有真正换人才退休旧手势，普通滚动帧保住拖动与惯性。

#include <QString>
#include <QtGlobal>

#include <cmath>

namespace RhineEmbedded {

/// 一份快照 / 一个输入的产出者：哪个平台视图，该视图的第几代交互上下文。
///
/// **不可变值类型**：每次跨界（JNI 参数 → 队列 lambda → 应用点 → 动作出口）都整份拷贝，
/// 任何环节都不许用"当前是谁"来补齐缺失字段——那正是本缺陷的成因。
struct ProducerOrigin
{
    /// 平台视图 id（Dart 的 PlatformView id / Kotlin 的 viewId）；<0 = 未登记。
    int viewId = -1;
    /// 交互上下文代次（Dart 的 ctx：目录/所属/窗口集合身份变化时递增）；0 = 未登记。
    quint64 context = 0;

    /// 产出者有没有登记身份（Android 搬运通道之外的老调用点是 false）。
    bool registered() const { return viewId >= 0; }
    /// 视图与代次都有值：才可能和已应用 origin 精确对上。
    bool bound() const { return viewId >= 0 && context != 0; }

    bool operator==(const ProducerOrigin &other) const
    {
        return viewId == other.viewId && context == other.context;
    }
    bool operator!=(const ProducerOrigin &other) const { return !(*this == other); }
};

/// 日志/测试用的稳定文本，例如 "view=11 ctx=7"。
inline QString describeOrigin(const ProducerOrigin &origin)
{
    return QStringLiteral("view=%1 ctx=%2").arg(origin.viewId).arg(origin.context);
}

/// 一次输入能否落到当前画面。用枚举而不是 bool，被拒理由要能进日志与断言。
enum class OriginVerdict
{
    /// 精确命中当前应用点。
    Accept,
    /// 还没有任何应用点（进程刚起 / 场景刚建）：首帧窗口，放行。
    AcceptFirstFrame,
    /// 场景已经拆掉：在新快照 apply 之前一律不放行（旧代码在这里 fail-open）。
    DropClosedScene,
    /// 产出者没登记身份：Android 通道上不该出现，出现就是老调用点或错误包装。
    DropUnregistered,
    /// 上一代（或已 retired）的视图：它的动作不许改当前画面。
    DropStaleView,
    /// 同一个视图换了交互上下文（目录/所属/窗口集合）：旧代次的迟到输入不许落地。
    DropStaleContext,
};

/// verdict 的短名（日志/测试断言共用，避免两边各写一份字符串）。
inline const char *originVerdictName(OriginVerdict verdict)
{
    switch (verdict) {
    case OriginVerdict::Accept:
        return "accept";
    case OriginVerdict::AcceptFirstFrame:
        return "accept-first-frame";
    case OriginVerdict::DropClosedScene:
        return "drop-closed";
    case OriginVerdict::DropUnregistered:
        return "drop-unregistered";
    case OriginVerdict::DropStaleView:
        return "drop-stale-view";
    case OriginVerdict::DropStaleContext:
        return "drop-stale-context";
    }
    return "drop-unknown";
}

inline bool originAccepted(OriginVerdict verdict)
{
    return verdict == OriginVerdict::Accept || verdict == OriginVerdict::AcceptFirstFrame;
}

/// 当前画面的 owner 账本（Qt 线程独占；调用方自己保证线程，这里不加锁——加锁会让人以为
/// 可以在 JNI 线程上 commit，而"在 apply 点之外改写"正是要根除的行为）。
class OriginLedger
{
public:
    enum class Phase
    {
        /// 还没有任何应用点（冷启动/场景未就绪）。
        Empty,
        /// 有一份成功的应用点，之后的输入必须精确对上。
        Open,
        /// 场景已拆：在新快照 apply 之前 fail-closed。
        Closed,
    };

    /// **唯一写入口**：applySceneState() 在 Qt 线程上真的把快照落到场景之后调用。
    void commit(const ProducerOrigin &origin)
    {
        m_applied = origin;
        m_phase = Phase::Open;
        ++m_commits;
    }

    /// 场景整体拆掉：退回 Closed（而不是旧代码的"未登记 = 放行"）。
    void close()
    {
        m_applied = ProducerOrigin();
        m_phase = Phase::Closed;
    }

    Phase phase() const { return m_phase; }
    bool isOpen() const { return m_phase == Phase::Open; }
    ProducerOrigin applied() const { return m_applied; }
    /// 应用点序号（诊断用：能证明"这一帧是第几次成功应用之后来的"）。
    quint64 commits() const { return m_commits; }

    OriginVerdict evaluate(const ProducerOrigin &origin) const
    {
        switch (m_phase) {
        case Phase::Empty:
            return OriginVerdict::AcceptFirstFrame;
        case Phase::Closed:
            return OriginVerdict::DropClosedScene;
        case Phase::Open:
            break;
        }
        // 应用点有身份时，没身份的产出者不许"猜"成当前画面。
        if (!origin.registered())
            return OriginVerdict::DropUnregistered;
        if (origin.viewId != m_applied.viewId)
            return OriginVerdict::DropStaleView;
        // 严格相等：ctx 缺失(0) ≠ 已应用的非 0 ctx。旧代码在"任一侧为 0"时放行，
        // 等于让没带代次的调用点穿透所有门禁。
        if (origin.context != m_applied.context)
            return OriginVerdict::DropStaleContext;
        return OriginVerdict::Accept;
    }

    bool accepts(const ProducerOrigin &origin) const { return originAccepted(evaluate(origin)); }

private:
    ProducerOrigin m_applied;
    Phase m_phase = Phase::Empty;
    quint64 m_commits = 0;
};

/// 场景世代：每次建场景一个号，让"旧 host 的 destroy"不能拆掉新 host 的场景。
///
/// 号由 Java 侧分配（RhineQtView 每发一次 create 请求 +1）再交给这里 adopt：
/// 两侧同一个单调计数器，比较才有意义。token == 0 表示"不带世代的老调用点/内部路径"，
/// owns() 对它返回 true（内部 create 里先拆旧再建新的那次拆除必须无条件生效）。
class SceneEpoch
{
public:
    quint64 current() const { return m_current; }

    /// 采用 Java 侧给的世代号（只前进不回退：迟到的旧 token 不许把当前世代拉回去）。
    void adopt(quint64 token)
    {
        if (token > m_current)
            m_current = token;
    }

    quint64 next() { return ++m_current; }

    bool owns(quint64 token) const { return token == 0 || token == m_current; }

private:
    quint64 m_current = 0;
};

/// Engine::projectEmbeddedCells 的 contextGeneration。
///
/// 149 的契约是"同一份窗口内容重复 apply 必须给同一个值"：给变了就会重置准入计时、把已经
/// 热的封面打回冷态。所以这里取**已应用 origin 的交互代次**（Dart 只在集合身份真正变化时
/// 递增），未登记时退化成稳定常量 1 —— 绝不每帧递增、也绝不掺时间戳。
inline quint64 collectionContextFor(const ProducerOrigin &origin)
{
    return origin.context != 0 ? origin.context : 1;
}

/// 一次连续拖动/惯性序列。
///
/// origin 在序列**开始**时捕获，之后所有 move/commit 都带着它出去。这是第二条缺陷路径的
/// 修法：ticker 不再读"当前是谁"，所以 A 起手的惯性永远不会被贴上 B 的标签（B 那边会
/// 因为 view/ctx 对不上而丢掉它 —— 这是有意的 fail-closed，不是丢帧 bug）。
struct ScrollGesture
{
    ProducerOrigin origin;
    /// 序列编号：每次 begin() +1。测试与日志用它证明"这是新的一段手势"，而不是旧的那段
    /// 还在继续（旧 ticker 把新手势 idle-commit 掉时，编号与阶段会自相矛盾）。
    quint64 epoch = 0;
    /// 序列起点（条目）。move/commit 报出去的是 item - base。
    double base = 0;
    /// 上一帧读到的位置（判"停下来了"）。
    double reference = 0;
    /// 连续多少帧没变化。
    int idle = 0;
    /// 手指还按着（拖动中）。
    bool tracking = false;
    /// 松手后 ticker 还在跟惯性。
    bool ticker = false;

    bool active() const { return tracking || ticker; }
    /// 手指按着（阶段 1）：位移由 pointermove 直接报，ticker 不得替它计数。
    bool held() const { return tracking; }
    /// 惯性阶段（阶段 2）：只有这里才允许"停下来就 commit"。
    bool inertia() const { return ticker; }

    /// 新起手：**不发 QTimer**（纯状态），但会清掉上一段的 ticker 阶段标记，所以旧
    /// timeout 即便进来了也不再被当成"惯性该收尾"。宿主另外要 stop() 旧 QTimer。
    void begin(const ProducerOrigin &who, double referenceItem)
    {
        origin = who;
        base = referenceItem;
        reference = referenceItem;
        idle = 0;
        tracking = true;
        ticker = false;
        ++epoch;
    }

    /// 手指抬起 → 交给 ticker 跟惯性（阶段 1 → 阶段 2）。reference 用"抬手这一帧的位置"，
    /// 否则第一帧会因为和拖动末帧比较而立刻算作"没动"。
    void handOffToInertia(double referenceItem)
    {
        reference = referenceItem;
        idle = 0;
        tracking = false;
        ticker = true;
    }

    void end()
    {
        tracking = false;
        ticker = false;
        idle = 0;
    }
};

enum class ScrollStepKind
{
    None,
    Move,
    Commit,
};

/// ticker 一帧的结论。origin 是**起手时捕获的那份**，不是调用时刻的全局。
struct ScrollStep
{
    ScrollStepKind kind = ScrollStepKind::None;
    double delta = 0;
    ProducerOrigin origin;
};

/// 推进一帧：纯函数，测试可以不带 Engine 驱动整段拖动 → 松手 → 惯性 → commit。
///
/// 两个阶段必须分开：按住时只可能是 move，永远不会 Commit；惯性要连续多帧不动才收尾。
inline ScrollStep advanceScroll(ScrollGesture &gesture, double item, int idleFrames = 3)
{
    ScrollStep step;
    if (!gesture.active())
        return step;
    if (std::abs(item - gesture.reference) >= 1e-3) {
        gesture.idle = 0;
        gesture.reference = item;
        step.kind = ScrollStepKind::Move;
        step.delta = item - gesture.base;
        step.origin = gesture.origin;
        return step;
    }
    // 这一帧没动：手指按着时只是"按住"，计数但不收尾；只有惯性阶段才允许 Commit。
    ++gesture.idle;
    if (!gesture.inertia() || gesture.idle < idleFrames)
        return step;
    // 停下：先拍下 delta 与 origin，再 end()，避免 end() 清掉阶段后又要读它。
    step.kind = ScrollStepKind::Commit;
    step.delta = item - gesture.base;
    step.origin = gesture.origin;
    gesture.end();
    return step;
}

/// 一次快照到达时的「换人」分类。
///
/// 普通滚动帧（同一 origin 的新 pos/cells）必须保留拖动与惯性；真正的换人（换视图、
/// 或交互代次变了）必须在应用前退休旧手势，否则旧 ticker 会继续往新画面上写。
enum class ApplyKind
{
    /// 还没有任何应用点（进程刚起/场景刚建）。
    FirstFrame,
    /// 同一个产出者的普通一帧：**不许**动手势状态（否则每帧都会杀掉惯性）。
    SameProducer,
    /// 换了视图，或同一视图换了交互代次：真正的换人。
    Replacement,
};

inline const char *applyKindName(ApplyKind kind)
{
    switch (kind) {
    case ApplyKind::FirstFrame:
        return "first-frame";
    case ApplyKind::SameProducer:
        return "same-producer";
    case ApplyKind::Replacement:
        return "replacement";
    }
    return "unknown";
}

/// 只用账本的**上一份已应用** origin 判定（调用点在 commit 新 origin 之前）。
inline ApplyKind classifyApply(const OriginLedger &ledger, const ProducerOrigin &origin)
{
    if (ledger.phase() == OriginLedger::Phase::Empty)
        return ApplyKind::FirstFrame;
    if (ledger.phase() == OriginLedger::Phase::Closed)
        return ApplyKind::Replacement;
    return ledger.applied() == origin ? ApplyKind::SameProducer : ApplyKind::Replacement;
}

/// 这条快照到达时，宿主该对手势状态做什么（宿主与测试共用的**同一份**判断）。
struct ApplyGesturePlan
{
    ApplyKind kind = ApplyKind::FirstFrame;
    /// 换人：应用前把 origin/手势/timer 的相位整段退休（timer 由宿主 stop()）。
    bool retireGesture = false;
    /// 应用这一刻手势是否还在驱动画面（决定 index/pos 是"回声"还是"权威"）。
    bool gestureDriving = false;
};

/// 说明：会**改** gesture（换人时 end()）。账本不动——新 origin 的 commit 仍由宿主在
/// 成功应用之后执行，这样"只有真的 apply 才改写已应用 origin"这条唯一写入口不被绕过。
inline ApplyGesturePlan planApply(ScrollGesture &gesture, const OriginLedger &ledger,
                                  const ProducerOrigin &origin)
{
    ApplyGesturePlan plan;
    plan.kind = classifyApply(ledger, origin);
    plan.retireGesture = plan.kind == ApplyKind::Replacement;
    if (plan.retireGesture)
        gesture.end();
    plan.gestureDriving = gesture.active();
    return plan;
}

} // namespace RhineEmbedded

#endif // RHINE_EMBEDDED_SCENE_ORIGIN_H
