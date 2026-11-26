/**
 * origin / 生命周期的离线回归（Qt6::Core，无 GUI/GPU/QtTest/Engine）。
 *
 * 覆盖：排队输入按产出时的 origin 判、惯性带起手 origin、拆场景后 fail-closed、
 * 旧世代 destroy 被拒、手势阶段不被旧 ticker 收尾、只有换人才退休旧手势。
 * 运行：cmake --build <build-dir> --target RhineEmbeddedSceneOrigin153Test
 *       ctest -R qt_embedded_scene_origin_153 --output-on-failure
 */
#include "EmbeddedSceneOrigin.h"

#include <QCoreApplication>
#include <QString>

#include <cmath>

namespace {

int g_checks = 0;
int g_failures = 0;

bool check(bool result, const QString &what, const QString &expected, const QString &actual)
{
    ++g_checks;
    if (!result) {
        ++g_failures;
        qWarning("[FAIL] %s expected=%s actual=%s", qPrintable(what), qPrintable(expected),
                 qPrintable(actual));
    }
    return result;
}

QString number(double value)
{
    return QString::number(value, 'g', 10);
}

RhineEmbedded::ProducerOrigin originOf(int viewId, quint64 context)
{
    RhineEmbedded::ProducerOrigin origin;
    origin.viewId = viewId;
    origin.context = context;
    return origin;
}

/// 首帧窗口：还没有任何应用点时放行；一旦有应用点，四类不匹配各回各的拒因。
bool firstFrameAndStrictMatch()
{
    using namespace RhineEmbedded;
    bool ok = true;
    OriginLedger ledger;

    ok &= check(ledger.phase() == OriginLedger::Phase::Empty, "fresh ledger is empty", "empty",
                QString::number(static_cast<int>(ledger.phase())));
    ok &= check(ledger.commits() == 0, "fresh ledger has no commits", "0",
                QString::number(ledger.commits()));
    ok &= check(ledger.evaluate(originOf(11, 7)) == OriginVerdict::AcceptFirstFrame,
                "first frame accepts", "accept-first-frame",
                QString::fromLatin1(originVerdictName(ledger.evaluate(originOf(11, 7)))));
    ok &= check(ledger.accepts(originOf(11, 7)) == true, "first frame accepted()", "true",
                QString::number(ledger.accepts(originOf(11, 7))));
    // 首帧窗口连"没登记 origin"都放行：那时还没有任何画面可比对，拒掉会让第一帧输入全丢。
    ok &= check(ledger.evaluate(originOf(-1, 0)) == OriginVerdict::AcceptFirstFrame,
                "first frame accepts unregistered", "accept-first-frame",
                QString::fromLatin1(originVerdictName(ledger.evaluate(originOf(-1, 0)))));

    ledger.commit(originOf(11, 7));
    ok &= check(ledger.phase() == OriginLedger::Phase::Open, "commit opens", "open",
                QString::number(static_cast<int>(ledger.phase())));
    ok &= check(ledger.commits() == 1, "commit counts", "1", QString::number(ledger.commits()));
    ok &= check(ledger.applied() == originOf(11, 7), "commit records origin", "view=11 ctx=7",
                describeOrigin(ledger.applied()));

    ok &= check(ledger.evaluate(originOf(11, 7)) == OriginVerdict::Accept, "exact match accepts",
                "accept",
                QString::fromLatin1(originVerdictName(ledger.evaluate(originOf(11, 7)))));
    ok &= check(ledger.evaluate(originOf(-1, 0)) == OriginVerdict::DropUnregistered,
                "unregistered drops", "drop-unregistered",
                QString::fromLatin1(originVerdictName(ledger.evaluate(originOf(-1, 0)))));
    ok &= check(ledger.evaluate(originOf(12, 7)) == OriginVerdict::DropStaleView,
                "other view drops", "drop-stale-view",
                QString::fromLatin1(originVerdictName(ledger.evaluate(originOf(12, 7)))));
    ok &= check(ledger.evaluate(originOf(11, 8)) == OriginVerdict::DropStaleContext,
                "other context drops", "drop-stale-context",
                QString::fromLatin1(originVerdictName(ledger.evaluate(originOf(11, 8)))));
    // 严格相等：没带代次的输入不许因为"旧代码任一侧为 0 就放行"而穿透。
    ok &= check(ledger.evaluate(originOf(11, 0)) == OriginVerdict::DropStaleContext,
                "missing context drops", "drop-stale-context",
                QString::fromLatin1(originVerdictName(ledger.evaluate(originOf(11, 0)))));
    ok &= check(ledger.accepts(originOf(11, 8)) == false, "stale context rejected()", "false",
                QString::number(ledger.accepts(originOf(11, 8))));

    // 已应用 origin 是 0 代次时，"0 vs 0"只对同一个视图成立；换视图仍然拒。
    OriginLedger zero;
    zero.commit(originOf(4, 0));
    ok &= check(zero.evaluate(originOf(4, 0)) == OriginVerdict::Accept, "zero ctx same view",
                "accept", QString::fromLatin1(originVerdictName(zero.evaluate(originOf(4, 0)))));
    ok &= check(zero.evaluate(originOf(5, 0)) == OriginVerdict::DropStaleView,
                "zero ctx other view drops", "drop-stale-view",
                QString::fromLatin1(originVerdictName(zero.evaluate(originOf(5, 0)))));
    return ok;
}

/// 拆场景之后必须 fail-closed（旧实现 resetAppliedState() 把 origin 清成"未登记 = 放行"）。
bool closedSceneFailsClosed()
{
    using namespace RhineEmbedded;
    bool ok = true;
    OriginLedger ledger;
    ledger.commit(originOf(11, 7));
    ledger.close();

    ok &= check(ledger.phase() == OriginLedger::Phase::Closed, "close closes", "closed",
                QString::number(static_cast<int>(ledger.phase())));
    ok &= check(ledger.applied().viewId == -1, "close clears origin view", "-1",
                QString::number(ledger.applied().viewId));
    ok &= check(ledger.commits() == 1, "close does not count as a commit", "1",
                QString::number(ledger.commits()));
    ok &= check(ledger.evaluate(originOf(11, 7)) == OriginVerdict::DropClosedScene,
                "closed drops the exact origin", "drop-closed",
                QString::fromLatin1(originVerdictName(ledger.evaluate(originOf(11, 7)))));
    ok &= check(ledger.evaluate(originOf(-1, 0)) == OriginVerdict::DropClosedScene,
                "closed drops unregistered", "drop-closed",
                QString::fromLatin1(originVerdictName(ledger.evaluate(originOf(-1, 0)))));
    ok &= check(ledger.accepts(originOf(11, 7)) == false, "closed accepts nothing", "false",
                QString::number(ledger.accepts(originOf(11, 7))));

    // 只有真的 apply 才重新打开（不是"再 close 一次"或"读一下"）。
    ledger.commit(originOf(12, 3));
    ok &= check(ledger.isOpen() == true, "new commit reopens", "true",
                QString::number(ledger.isOpen()));
    ok &= check(ledger.evaluate(originOf(12, 3)) == OriginVerdict::Accept, "new origin accepts",
                "accept",
                QString::fromLatin1(originVerdictName(ledger.evaluate(originOf(12, 3)))));
    return ok;
}

/// 缺陷本体：A 已应用，B 的快照已入队但还没 apply。
///
/// 同一份 A 输入：B 应用前必须放行（画面还是 A），B 应用后必须被拒（画面已经是 B）。
/// 旧实现的错法正好相反——输入在 B 应用前过门，但 emit 时才去读"当前"全局，读到 B。
bool queuedProducerKeepsItsOrigin()
{
    using namespace RhineEmbedded;
    bool ok = true;
    OriginLedger ledger;
    const ProducerOrigin a = originOf(11, 7);
    const ProducerOrigin b = originOf(12, 9);

    ledger.commit(a);
    // A 的手指动作产出时，B 的 state 已经 push（排队中），但 apply 还没发生。
    const ProducerOrigin queuedInput = a;
    ok &= check(ledger.evaluate(queuedInput) == OriginVerdict::Accept,
                "queued A input accepted while A is applied", "accept",
                QString::fromLatin1(originVerdictName(ledger.evaluate(queuedInput))));
    // B 被应用（Qt 线程）。
    ledger.commit(b);
    // 同一份排队输入这时才真正落地：必须按它自己的身份判，结果是"旧视图"而不是"当前视图"。
    ok &= check(ledger.evaluate(queuedInput) == OriginVerdict::DropStaleView,
                "same queued A input dropped after B applies", "drop-stale-view",
                QString::fromLatin1(originVerdictName(ledger.evaluate(queuedInput))));
    ok &= check(ledger.applied() == b, "B is the applied origin", "view=12 ctx=9",
                describeOrigin(ledger.applied()));

    // 反向：B 的输入在 A 应用期间到达，同样不能落到 A 的画面上。
    OriginLedger second;
    second.commit(b);
    ok &= check(second.evaluate(a) == OriginVerdict::DropStaleView,
                "input from a retired view drops", "drop-stale-view",
                QString::fromLatin1(originVerdictName(second.evaluate(a))));
    return ok;
}

/// 惯性 ticker：序列开始捕获 origin，之后哪怕已应用 origin 换人也不改。
bool scrollGestureCapturesOrigin()
{
    using namespace RhineEmbedded;
    bool ok = true;
    const ProducerOrigin a = originOf(11, 7);
    const ProducerOrigin b = originOf(12, 9);

    ScrollGesture gesture;
    gesture.begin(a, 100.0);
    ok &= check(gesture.active() == true, "gesture begins active", "true",
                QString::number(gesture.active()));
    ok &= check(gesture.origin == a, "gesture captured A", "view=11 ctx=7",
                describeOrigin(gesture.origin));

    ScrollStep step = advanceScroll(gesture, 104.0);
    ok &= check(step.kind == ScrollStepKind::Move, "drag frame is a move", "move",
                QString::number(static_cast<int>(step.kind)));
    ok &= check(step.origin == a, "drag frame carries A", "view=11 ctx=7",
                describeOrigin(step.origin));
    ok &= check(std::abs(step.delta - 4.0) < 1e-9, "move delta from base", "4", number(step.delta));

    // B 的快照在这段手势中间被应用了（就是"另一个宿主接管"）。
    OriginLedger ledger;
    ledger.commit(b);
    // 松手：ticker 接管（tracking 关，ticker 开），origin 仍是 A。
    gesture.tracking = false;
    gesture.ticker = true;
    step = advanceScroll(gesture, 106.0);
    ok &= check(step.kind == ScrollStepKind::Move, "inertia frame is a move", "move",
                QString::number(static_cast<int>(step.kind)));
    ok &= check(step.origin == a, "inertia keeps A after B applied", "view=11 ctx=7",
                describeOrigin(step.origin));
    ok &= check(std::abs(step.delta - 6.0) < 1e-9, "inertia delta still from base", "6",
                number(step.delta));
    // 这份 A 标签的动作在 B 的门禁上应该被拒——fail-closed，不是丢帧 bug。
    ok &= check(ledger.evaluate(step.origin) == OriginVerdict::DropStaleView,
                "inertia action from A dropped by B", "drop-stale-view",
                QString::fromLatin1(originVerdictName(ledger.evaluate(step.origin))));
    return ok;
}

/// 停下来才 commit：连续 idleFrames 帧不动才收尾，且 commit 之后不再发。
bool scrollInertiaCommits()
{
    using namespace RhineEmbedded;
    bool ok = true;
    const ProducerOrigin a = originOf(11, 7);
    ScrollGesture gesture;
    gesture.begin(a, 100.0);
    gesture.tracking = false;
    gesture.ticker = true;

    ScrollStep step = advanceScroll(gesture, 103.0);
    ok &= check(step.kind == ScrollStepKind::Move, "move before stop", "move",
                QString::number(static_cast<int>(step.kind)));

    step = advanceScroll(gesture, 103.0);
    ok &= check(step.kind == ScrollStepKind::None, "first still frame is none", "none",
                QString::number(static_cast<int>(step.kind)));
    step = advanceScroll(gesture, 103.0);
    ok &= check(step.kind == ScrollStepKind::None, "second still frame is none", "none",
                QString::number(static_cast<int>(step.kind)));
    step = advanceScroll(gesture, 103.0);
    ok &= check(step.kind == ScrollStepKind::Commit, "third still frame commits", "commit",
                QString::number(static_cast<int>(step.kind)));
    ok &= check(step.origin == a, "commit carries the captured origin", "view=11 ctx=7",
                describeOrigin(step.origin));
    ok &= check(std::abs(step.delta - 3.0) < 1e-9, "commit delta from base", "3",
                number(step.delta));
    ok &= check(gesture.active() == false, "commit ends the gesture", "false",
                QString::number(gesture.active()));

    step = advanceScroll(gesture, 108.0);
    ok &= check(step.kind == ScrollStepKind::None, "after commit nothing is emitted", "none",
                QString::number(static_cast<int>(step.kind)));
    return ok;
}

/// 旧惯性还在滑时按下新手势，旧 ticker 的帧不许把新手势 idle-commit 掉。
bool oldInertiaDoesNotEndNewHeldDrag()
{
    using namespace RhineEmbedded;
    bool ok = true;
    const ProducerOrigin a = originOf(11, 7);
    const ProducerOrigin b = originOf(12, 9);

    ScrollGesture gesture;
    gesture.begin(a, 100.0);
    gesture.handOffToInertia(100.0); // 松手 → 惯性阶段
    const ScrollStep fling = advanceScroll(gesture, 140.0);
    ok &= check(fling.kind == ScrollStepKind::Move, "fling frame moves", "move",
                QString::number(static_cast<int>(fling.kind)));
    const quint64 flingEpoch = gesture.epoch;

    // 新手势：宿主在 pointerdown 里 stop() 了旧 ticker，然后 begin()。
    gesture.begin(b, 200.0);
    ok &= check(gesture.epoch != flingEpoch, "new down starts a new epoch", "different",
                QString::number(gesture.epoch));
    ok &= check(gesture.held() == true && gesture.inertia() == false,
                "new gesture is held, not inertia", "held",
                gesture.held() ? (gesture.inertia() ? "inertia" : "held") : "idle");

    // 排队中的旧 timeout 继续进来 4 帧：手指按着、位置没变 → 只能什么都不做。
    for (int frame = 0; frame < 4; ++frame) {
        const ScrollStep stale = advanceScroll(gesture, 200.0);
        ok &= check(stale.kind == ScrollStepKind::None, "stale ticker frame emits nothing", "none",
                    QString::number(static_cast<int>(stale.kind)));
        ok &= check(gesture.held() == true, "stale ticker must not end the held drag", "true",
                    QString::number(gesture.held()));
    }
    // 新手指真的动了：必须照旧同步（M1 的失败表现正是这里不再有 move）。
    const ScrollStep drag = advanceScroll(gesture, 205.0);
    ok &= check(drag.kind == ScrollStepKind::Move, "held drag still moves after stale ticks",
                "move", QString::number(static_cast<int>(drag.kind)));
    ok &= check(drag.origin == b, "held drag carries the new origin", "view=12 ctx=9",
                describeOrigin(drag.origin));
    ok &= check(std::abs(drag.delta - 5.0) < 1e-9, "held delta measured from the new base", "5",
                number(drag.delta));

    // 抬手 → 惯性收尾，仍然是新 origin。
    gesture.handOffToInertia(205.0);
    ScrollStep commit;
    for (int frame = 0; frame < 3; ++frame)
        commit = advanceScroll(gesture, 205.0);
    ok &= check(commit.kind == ScrollStepKind::Commit, "held drag commits after handoff", "commit",
                QString::number(static_cast<int>(commit.kind)));
    ok &= check(commit.origin == b, "commit carries the new origin", "view=12 ctx=9",
                describeOrigin(commit.origin));
    ok &= check(gesture.active() == false, "commit ends the new gesture", "false",
                QString::number(gesture.active()));
    return ok;
}

/// M2：只有**真正的换人**才退休旧手势；普通滚动帧必须让惯性继续。
bool contextReplacementRetiresGesture()
{
    using namespace RhineEmbedded;
    bool ok = true;
    const ProducerOrigin a = originOf(11, 7);
    const ProducerOrigin sameViewNewContext = originOf(11, 8);
    const ProducerOrigin otherView = originOf(12, 7);

    // 还没有应用点：首帧，不退休（那时也没有手势可退休）。
    {
        OriginLedger ledger;
        ScrollGesture gesture;
        ok &= check(classifyApply(ledger, a) == ApplyKind::FirstFrame, "fresh ledger is first frame",
                    "first-frame", QString::fromLatin1(applyKindName(classifyApply(ledger, a))));
        ok &= check(planApply(gesture, ledger, a).retireGesture == false,
                    "first frame retires nothing", "false",
                    QString::number(planApply(gesture, ledger, a).retireGesture));
    }

    // 普通滚动帧（同一 origin 的新 pos/cells/画质）：手势必须活着。
    {
        OriginLedger ledger;
        ledger.commit(a);
        ScrollGesture gesture;
        gesture.begin(a, 100.0);
        gesture.handOffToInertia(100.0);
        const ApplyGesturePlan plan = planApply(gesture, ledger, a);
        ok &= check(plan.kind == ApplyKind::SameProducer,
                    "ordinary frame is not a replacement", "same-producer",
                    QString::fromLatin1(applyKindName(plan.kind)));
        ok &= check(plan.retireGesture == false, "ordinary frame keeps the gesture", "false",
                    QString::number(plan.retireGesture));
        ok &= check(plan.gestureDriving == true, "ordinary frame lets the gesture drive", "true",
                    QString::number(plan.gestureDriving));
        ok &= check(gesture.inertia() == true, "inertia survives an ordinary frame", "true",
                    QString::number(gesture.inertia()));
    }

    // 同一视图换了交互代次（换目录/换所属 = 集合被替换）：B 的位置必须立刻权威。
    {
        OriginLedger ledger;
        ledger.commit(a);
        ScrollGesture gesture;
        gesture.begin(a, 100.0);
        gesture.handOffToInertia(100.0);
        const ApplyGesturePlan plan = planApply(gesture, ledger, sameViewNewContext);
        ok &= check(plan.kind == ApplyKind::Replacement,
                    "same view new context is a replacement", "replacement",
                    QString::fromLatin1(applyKindName(plan.kind)));
        ok &= check(plan.retireGesture == true, "replacement retires the old gesture", "true",
                    QString::number(plan.retireGesture));
        ok &= check(plan.gestureDriving == false, "replacement does not treat B as an echo", "false",
                    QString::number(plan.gestureDriving));
        ok &= check(gesture.active() == false, "replacement ends the old gesture", "false",
                    QString::number(gesture.active()));
    }

    // 视图换人（旧视图退休）：同样是换人，旧 origin 的动作之后一律被拒。
    {
        OriginLedger ledger;
        ledger.commit(a);
        ScrollGesture gesture;
        gesture.begin(a, 100.0);
        gesture.handOffToInertia(100.0);
        const ApplyGesturePlan plan = planApply(gesture, ledger, otherView);
        ok &= check(plan.kind == ApplyKind::Replacement, "other view is a replacement", "replacement",
                    QString::fromLatin1(applyKindName(plan.kind)));
        ok &= check(gesture.active() == false, "retired view ends the old gesture", "false",
                    QString::number(gesture.active()));
        ledger.commit(otherView);
        ok &= check(ledger.evaluate(a) == OriginVerdict::DropStaleView,
                    "retired origin stays refused", "drop-stale-view",
                    QString::fromLatin1(originVerdictName(ledger.evaluate(a))));
    }

    // 场景拆掉之后再来的快照：也算换人（旧手势/回声都不能延续到新场景）。
    {
        OriginLedger ledger;
        ledger.commit(a);
        ledger.close();
        ok &= check(classifyApply(ledger, a) == ApplyKind::Replacement,
                    "apply after close is a replacement", "replacement",
                    QString::fromLatin1(applyKindName(classifyApply(ledger, a))));
    }
    return ok;
}

/// 149 的 contract：同一份窗口内容必须给同一个 contextGeneration。
bool collectionContextIsStable()
{
    using namespace RhineEmbedded;
    bool ok = true;
    ok &= check(collectionContextFor(originOf(11, 7)) == 7, "registered ctx passes through", "7",
                QString::number(collectionContextFor(originOf(11, 7))));
    ok &= check(collectionContextFor(originOf(11, 0)) == 1, "unregistered ctx → 1", "1",
                QString::number(collectionContextFor(originOf(11, 0))));
    ok &= check(collectionContextFor(originOf(-1, 0)) == 1, "no origin → 1", "1",
                QString::number(collectionContextFor(originOf(-1, 0))));
    const quint64 first = collectionContextFor(originOf(11, 0));
    const quint64 second = collectionContextFor(originOf(11, 0));
    ok &= check(first == second, "fallback is stable across calls", QString::number(first),
                QString::number(second));
    return ok;
}

/// 世代：只前进；旧 host 的 destroy（旧号）必须被拒。
bool sceneEpochOnlyMovesForward()
{
    using namespace RhineEmbedded;
    bool ok = true;
    SceneEpoch epoch;
    ok &= check(epoch.current() == 0, "fresh epoch is 0", "0", QString::number(epoch.current()));
    ok &= check(epoch.owns(0) == true, "token 0 is unconditional", "true",
                QString::number(epoch.owns(0)));

    epoch.adopt(0);
    ok &= check(epoch.current() == 0, "adopt(0) does not move", "0",
                QString::number(epoch.current()));
    epoch.adopt(3);
    ok &= check(epoch.current() == 3, "adopt(3) moves", "3", QString::number(epoch.current()));
    ok &= check(epoch.owns(3) == true, "owns current", "true", QString::number(epoch.owns(3)));
    ok &= check(epoch.owns(2) == false, "stale destroy is not owned", "false",
                QString::number(epoch.owns(2)));

    epoch.adopt(2);
    ok &= check(epoch.current() == 3, "late adopt(2) cannot roll back", "3",
                QString::number(epoch.current()));
    ok &= check(epoch.owns(2) == false, "stale token still refused", "false",
                QString::number(epoch.owns(2)));

    const quint64 next = epoch.next();
    ok &= check(next == 4, "next increments", "4", QString::number(next));
    ok &= check(epoch.owns(3) == false, "previous generation retires", "false",
                QString::number(epoch.owns(3)));

    // owns() 是"等于当前世代"，所以**排队的 create**（Java 已经发出、Qt 线程还没跑到）
    // 拿到的号一定不被 owns() 认。这正是 destroy 不能在 Java UI 线程上提前判世代的理由：
    // 那个窗口里提前判会把 destroy 整段丢掉，而 Java 侧已经把号归零、不会重发（见
    // EmbeddedSceneHost.cpp destroyEmbeddedScene 的注释）。判定只能在 Qt 线程、create
    // 之后做——这条断言把"未 adopt 的更大号是 pending，不是 stale"钉在测试里。
    ok &= check(epoch.owns(9) == false, "a not-yet-adopted token is pending, not owned", "false",
                QString::number(epoch.owns(9)));
    return ok;
}

/// 值类型与日志文本：origin 是逐份拷贝的值，没有"当前"可读。
bool originIsAValue()
{
    using namespace RhineEmbedded;
    bool ok = true;
    ProducerOrigin unset;
    ok &= check(unset.viewId == -1, "default view is -1", "-1", QString::number(unset.viewId));
    ok &= check(unset.context == 0, "default ctx is 0", "0", QString::number(unset.context));
    ok &= check(unset.registered() == false, "default is unregistered", "false",
                QString::number(unset.registered()));
    ok &= check(unset.bound() == false, "default is unbound", "false",
                QString::number(unset.bound()));

    const ProducerOrigin viewOnly = originOf(11, 0);
    ok &= check(viewOnly.registered() == true, "view without ctx is registered", "true",
                QString::number(viewOnly.registered()));
    ok &= check(viewOnly.bound() == false, "view without ctx is unbound", "false",
                QString::number(viewOnly.bound()));

    const ProducerOrigin full = originOf(11, 7);
    ok &= check(full.bound() == true, "view + ctx is bound", "true",
                QString::number(full.bound()));
    ok &= check(full == originOf(11, 7), "same value compares equal", "true",
                QString::number(full == originOf(11, 7)));
    ok &= check(full != originOf(11, 8), "different ctx compares unequal", "true",
                QString::number(full != originOf(11, 8)));
    ok &= check(describeOrigin(full) == QStringLiteral("view=11 ctx=7"), "describe text",
                "view=11 ctx=7", describeOrigin(full));

    // 拷贝语义：副本改动不影响原件（"逐份拷贝、无共享状态"）。
    ProducerOrigin copy = full;
    copy.context = 99;
    ok &= check(full.context == 7, "copy does not mutate the original", "7",
                QString::number(full.context));
    return ok;
}

} // namespace

int main(int argc, char **argv)
{
    QCoreApplication application(argc, argv);
    bool ok = true;
    ok &= firstFrameAndStrictMatch();
    ok &= closedSceneFailsClosed();
    ok &= queuedProducerKeepsItsOrigin();
    ok &= scrollGestureCapturesOrigin();
    ok &= scrollInertiaCommits();
    ok &= oldInertiaDoesNotEndNewHeldDrag();
    ok &= contextReplacementRetiresGesture();
    ok &= collectionContextIsStable();
    ok &= sceneEpochOnlyMovesForward();
    ok &= originIsAValue();
    if (g_failures > 0) {
        qWarning("embedded scene origin: %d/%d checks failed", g_failures, g_checks);
        return 1;
    }
    qInfo("embedded scene origin: %d checks passed", g_checks);
    return 0;
}
