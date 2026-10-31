// C04：用"发布／消费"序号合并过量完整 step 的纯策略。
//
// 这里钉的都是"不会崩、只会白白烧 CPU 或让动画卡住"的边界：
//   · 渲染线程没取走上一份，就别再算一份会被覆盖的中间状态；
//   · 输入必须优先于消费反馈，否则按键响应会被拖慢一帧以上；
//   · 渲染线程长时间不消费（遮挡、最小化）时必须有看门狗，不能让动画永久停在半路；
//   · 旧序号、重复序号、从未发布过的序号都不能把"已消费"往前推。
//
// 依赖：Qt6::Core。策略本身不读时钟、不接事件循环，时间由调用方传入。
#include "render/FramePacingPolicy.h"

#include <QString>
#include <cstdio>

using RhineRender::FramePacingPolicy;

namespace {

int g_checks = 0;
int g_failures = 0;

bool check(bool result, const QString &what, const QString &expected, const QString &actual)
{
    ++g_checks;
    if (!result) {
        ++g_failures;
        std::fprintf(stderr, "[FAIL] %s\n       期望: %s\n       实际: %s\n", what.toUtf8().constData(),
                     expected.toUtf8().constData(), actual.toUtf8().constData());
    }
    return result;
}

QString actionName(FramePacingPolicy::Action action)
{
    switch (action) {
    case FramePacingPolicy::Action::Step:
        return QStringLiteral("Step");
    case FramePacingPolicy::Action::Skip:
        return QStringLiteral("Skip");
    case FramePacingPolicy::Action::Sleep:
        return QStringLiteral("Sleep");
    }
    return QStringLiteral("?");
}

void expectAction(const FramePacingPolicy::Decision &decision, FramePacingPolicy::Action expected,
                  const QString &what)
{
    check(decision.action == expected, what, actionName(expected), actionName(decision.action));
}

/** 一次输入合并掉重复 step：连续两拍都算输入，但只应产生一次真的 step。 */
void inputIsMerged()
{
    FramePacingPolicy pacing;
    pacing.publish(1, 0);
    // 输入优先：即使上一份还没被消费，也必须立刻 step。
    expectAction(pacing.decide(true, true, 5), FramePacingPolicy::Action::Step, "输入优先于消费反馈");
    // 输入处理完、这一拍发布了新快照，下一拍就该等消费。
    pacing.publish(2, 5);
    expectAction(pacing.decide(true, false, 10), FramePacingPolicy::Action::Skip, "未消费时合并重复 step");
}

/** 消费之后只放行一次：不能因为消费反馈自己形成空转。 */
void consumptionReleasesExactlyOnce()
{
    FramePacingPolicy pacing;
    pacing.publish(1, 0);
    expectAction(pacing.decide(true, false, 4), FramePacingPolicy::Action::Skip, "发布后未消费应跳过");
    pacing.consume(1);
    check(!pacing.awaitingConsumption(), "消费后不应再等待", "false",
          pacing.awaitingConsumption() ? "true" : "false");
    expectAction(pacing.decide(true, false, 8), FramePacingPolicy::Action::Step, "消费后放行一拍");
    pacing.publish(2, 8);
    // 没有再消费：重新进入等待，不能连续放行。
    expectAction(pacing.decide(true, false, 12), FramePacingPolicy::Action::Skip, "发布后重新等待消费");
    pacing.noteStep(true);
    pacing.noteStep(true);
    check(pacing.skipped() == 2, "跳过次数应累计两次", "2", QString::number(pacing.skipped()));
}

/** 旧序号、重复序号、未发布的序号都不能推进消费。 */
void staleAndDuplicateConsumptionIgnored()
{
    FramePacingPolicy pacing;
    pacing.publish(3, 0);
    pacing.consume(3);
    pacing.consume(3);
    check(pacing.consumeCount() == 1, "重复确认只记一次", "1", QString::number(pacing.consumeCount()));
    pacing.consume(2);
    check(pacing.consumed() == 3, "旧序号不得回退消费进度", "3", QString::number(pacing.consumed()));
    pacing.consume(9);
    check(pacing.consumed() == 3, "从未发布过的序号不得推进消费", "3", QString::number(pacing.consumed()));
    pacing.consume(0);
    check(pacing.consumed() == 3, "0 不是有效序号", "3", QString::number(pacing.consumed()));
}

/** 发布序号必须单调递增；重复或回退的发布不改变状态。 */
void publishIsMonotonic()
{
    FramePacingPolicy pacing;
    pacing.publish(4, 0);
    pacing.publish(4, 1);
    pacing.publish(2, 2);
    check(pacing.published() == 4, "重复与回退的发布忽略", "4", QString::number(pacing.published()));
    check(pacing.publishCount() == 1, "只记一次发布", "1", QString::number(pacing.publishCount()));
}

/** 动画连续推进；工作结束后必须自己停，不能自激。 */
void animationStopsWithoutSelfExcitation()
{
    FramePacingPolicy pacing;
    qint64 now = 0;
    int steps = 0;
    for (int frame = 0; frame < 6; ++frame) {
        const auto decision = pacing.decide(true, false, now);
        if (decision.action == FramePacingPolicy::Action::Step) {
            pacing.publish(quint64(frame + 1), now);
            pacing.noteStep(false);
            ++steps;
        } else {
            pacing.noteStep(true);
            pacing.consume(pacing.published());
        }
        now += 16;
    }
    check(steps == 3, "六拍里应只有三次真的 step", "3", QString::number(steps));
    // 动画停了：即使上一份还没被消费，也不能继续 step。
    expectAction(pacing.decide(false, false, now), FramePacingPolicy::Action::Sleep, "无待办时休眠");
}

/** 渲染线程长时间不消费：看门狗到点必须放行，否则动画会卡在中间状态。 */
void watchdogForcesStep()
{
    FramePacingPolicy pacing;
    pacing.publish(1, 1000);
    auto decision = pacing.decide(true, false, 1000 + FramePacingPolicy::DefaultWatchdogMs - 1);
    expectAction(decision, FramePacingPolicy::Action::Skip, "看门狗未到点仍应跳过");
    decision = pacing.decide(true, false, 1000 + FramePacingPolicy::DefaultWatchdogMs);
    expectAction(decision, FramePacingPolicy::Action::Step, "看门狗到点放行");
    check(decision.forced, "看门狗放行应标记 forced", "true", decision.forced ? "true" : "false");
    check(decision.waitedMs == FramePacingPolicy::DefaultWatchdogMs, "等待时长应等于看门狗阈值",
          QString::number(FramePacingPolicy::DefaultWatchdogMs), QString::number(decision.waitedMs));
}

/** 纯资源请求：只发布视觉快照，不推进模拟，也不该被当成"有工作要 step"。 */
void resourcePublishDoesNotStep()
{
    FramePacingPolicy pacing;
    pacing.noteStep(false);
    pacing.publish(7, 0);
    expectAction(pacing.decide(false, false, 10), FramePacingPolicy::Action::Sleep,
                 "资源就绪不产生 step");
    check(pacing.awaitingConsumption(), "资源快照仍等待消费", "true",
          pacing.awaitingConsumption() ? "true" : "false");
    pacing.consume(7);
    check(pacing.steps() == 1, "资源发布不改变 step 计数", "1", QString::number(pacing.steps()));
}

/** 隐藏／设备重建：序号与计数一起作废，恢复首帧能自举。 */
void resetClearsState()
{
    FramePacingPolicy pacing;
    pacing.publish(5, 0);
    pacing.consume(5);
    pacing.noteStep(false);
    pacing.noteStep(true);
    pacing.reset();
    check(pacing.published() == 0 && pacing.consumed() == 0, "序号归零", "0/0",
          QString::number(pacing.published()) + "/" + QString::number(pacing.consumed()));
    check(pacing.steps() == 0 && pacing.skipped() == 0, "计数归零", "0/0",
          QString::number(pacing.steps()) + "/" + QString::number(pacing.skipped()));
    pacing.consume(5);
    check(pacing.consumed() == 0, "复位后旧确认无效", "0", QString::number(pacing.consumed()));
    expectAction(pacing.decide(true, false, 0), FramePacingPolicy::Action::Step, "复位后立即可 step");
}

} // namespace

int main()
{
    inputIsMerged();
    consumptionReleasesExactlyOnce();
    staleAndDuplicateConsumptionIgnored();
    publishIsMonotonic();
    animationStopsWithoutSelfExcitation();
    watchdogForcesStep();
    resourcePublishDoesNotStep();
    resetClearsState();
    std::printf("frame pacing: %d 项检查, %d 项失败\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
