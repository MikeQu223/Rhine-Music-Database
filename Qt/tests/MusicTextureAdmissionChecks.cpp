// 快速滚动的冷纹理准入（B01）与封面需求账本（B03）里能离线判定的那一半。
//
// 这两块写错的后果都不是崩溃，而是"界面看起来慢"或"并发慢慢超过上限"：准入边界差 1ms
// 只是多等一帧；逻辑取消提前归还名额，则要等到线程池被压垮才会被发现。所以边界条件、
// 共享 revision、取消后并发上限都在这里钉死。
//
// 依赖：Qt6::Core（MusicTextureAdmission.h 用 QTimer，需要 QCoreApplication 才跑事件循环）。
#include "render/CoverPrepBudget.h"
#include "render/MusicTextureAdmission.h"

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QString>
#include <QThread>
#include <cstdio>
#include <functional>
#include <memory>

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

QString num(qint64 value)
{
    return QString::number(value);
}

QString boolText(bool value)
{
    return value ? QStringLiteral("true") : QStringLiteral("false");
}

/// 环境变量解析：默认 100；0 合法（关闭延迟）；非法值必须回默认而不是 0。
bool environmentParsing()
{
    bool ok = true;
    const QByteArray original = qgetenv("RHINE_TEXTURE_ADMISSION_MS");
    qunsetenv("RHINE_TEXTURE_ADMISSION_MS");
    ok &= check(RhineRender::musicTextureAdmissionDelayFromEnvironment() == 100,
                QStringLiteral("未设置时默认 100ms"), QStringLiteral("100"),
                num(RhineRender::musicTextureAdmissionDelayFromEnvironment()));

    const auto parseWith = [](const char *text) {
        qputenv("RHINE_TEXTURE_ADMISSION_MS", text);
        return RhineRender::musicTextureAdmissionDelayFromEnvironment();
    };
    ok &= check(parseWith("0") == 0, QStringLiteral("0 = 关闭延迟"), QStringLiteral("0"), num(parseWith("0")));
    ok &= check(parseWith("250") == 250, QStringLiteral("250 原样采纳"), QStringLiteral("250"),
                num(parseWith("250")));
    ok &= check(parseWith("abc") == 100, QStringLiteral("非数字回默认"), QStringLiteral("100"),
                num(parseWith("abc")));
    ok &= check(parseWith("-5") == 100, QStringLiteral("负数回默认"), QStringLiteral("100"),
                num(parseWith("-5")));
    ok &= check(parseWith("99999") == 100, QStringLiteral("超范围回默认"), QStringLiteral("100"),
                num(parseWith("99999")));

    if (original.isNull()) {
        qunsetenv("RHINE_TEXTURE_ADMISSION_MS");
    } else {
        qputenv("RHINE_TEXTURE_ADMISSION_MS", original);
    }
    return ok;
}

/// 假时钟边界：0／99／100 三个点，不 sleep。
bool admissionBoundaries()
{
    bool ok = true;
    RhineRender::MusicTextureAdmission admission(100);

    auto status = admission.focus(QStringLiteral("a"), 0);
    ok &= check(status.pending && !status.admitted, QStringLiteral("t=0 进入等待"), QStringLiteral("pending"),
                QStringLiteral("%1/%2").arg(boolText(status.pending), boolText(status.admitted)));

    // 封面晚到、标题 revision 变化只是"采用最新内容"，不能把等待起点往后推。
    status = admission.focus(QStringLiteral("a"), 60);
    ok &= check(status.pending && admission.pendingSinceMs() == 0,
                QStringLiteral("同 key 晚到内容不重置等待起点"), QStringLiteral("0"),
                num(admission.pendingSinceMs()));
    status = admission.focus(QStringLiteral("a"), 99);
    ok &= check(status.pending && !status.admitted, QStringLiteral("t=99 仍未准入"),
                QStringLiteral("pending"),
                QStringLiteral("%1/%2").arg(boolText(status.pending), boolText(status.admitted)));

    status = admission.focus(QStringLiteral("a"), 100);
    ok &= check(status.admitted && !status.pending, QStringLiteral("t=100 恰好准入"),
                QStringLiteral("admitted"),
                QStringLiteral("%1/%2").arg(boolText(status.admitted), boolText(status.pending)));

    // 同 key 重复帧不能重计时：拿一个更晚的时钟再问，仍然是已准入。
    status = admission.focus(QStringLiteral("a"), 100000);
    ok &= check(status.admitted, QStringLiteral("同 key 重复帧不重计时"), QStringLiteral("admitted"),
                boolText(status.admitted));

    // 切走：从切走时刻重新计时；切回已准入的 key 立即命中。
    status = admission.focus(QStringLiteral("b"), 200);
    ok &= check(status.pending && !status.admitted, QStringLiteral("新焦点 b 重新计时"),
                QStringLiteral("pending"),
                QStringLiteral("%1/%2").arg(boolText(status.pending), boolText(status.admitted)));
    status = admission.focus(QStringLiteral("b"), 250);
    ok &= check(status.pending, QStringLiteral("b 在 50ms 时仍等待"), QStringLiteral("pending"),
                boolText(status.pending));
    status = admission.focus(QStringLiteral("b"), 300);
    ok &= check(status.admitted, QStringLiteral("b 在 100ms 准入"), QStringLiteral("admitted"),
                boolText(status.admitted));
    status = admission.focus(QStringLiteral("a"), 301);
    ok &= check(status.admitted, QStringLiteral("切回已准入的 a 立即命中"), QStringLiteral("admitted"),
                boolText(status.admitted));

    // 空 key：撤销等待，不创建资源。
    status = admission.focus(QString(), 400);
    ok &= check(!status.pending && !status.admitted, QStringLiteral("空焦点撤销等待"),
                QStringLiteral("neither"),
                QStringLiteral("%1/%2").arg(boolText(status.pending), boolText(status.admitted)));
    return ok;
}

/// 延迟为 0：等价于"关闭准入"，但第一次仍走 pending，下一帧立刻准入。
bool admissionDisabled()
{
    bool ok = true;
    RhineRender::MusicTextureAdmission admission(0);
    auto status = admission.focus(QStringLiteral("a"), 10);
    ok &= check(status.pending, QStringLiteral("0ms 首帧仍是 pending（不提前返回）"),
                QStringLiteral("pending"), boolText(status.pending));
    status = admission.focus(QStringLiteral("a"), 10);
    ok &= check(status.admitted, QStringLiteral("0ms 下一帧立即准入"), QStringLiteral("admitted"),
                boolText(status.admitted));

    // 定时器语义：delay=0 时到期判定不能因为"差 0ms"而永远 false。
    RhineRender::MusicTextureAdmission timerAdmission(0);
    const auto pending = timerAdmission.focus(QStringLiteral("k"), 5);
    ok &= check(timerAdmission.expire(QStringLiteral("k"), pending.generation, 5),
                QStringLiteral("0ms 时 expire 直接通过"), QStringLiteral("true"), QStringLiteral("false"));
    return ok;
}

/// 旧回调必须失效：切歌／隐藏都会推进代号。
bool staleCallbacks()
{
    bool ok = true;
    RhineRender::MusicTextureAdmission admission(100);
    const auto first = admission.focus(QStringLiteral("a"), 0);
    const auto second = admission.focus(QStringLiteral("b"), 10);
    ok &= check(first.generation != second.generation, QStringLiteral("切歌推进代号"),
                QStringLiteral("不同"), QStringLiteral("相同"));
    ok &= check(!admission.expire(QStringLiteral("a"), first.generation, 120),
                QStringLiteral("旧 key 的到期回调被拒绝"), QStringLiteral("false"), QStringLiteral("true"));
    ok &= check(!admission.expire(QStringLiteral("b"), first.generation, 120),
                QStringLiteral("旧代号的到期回调被拒绝"), QStringLiteral("false"), QStringLiteral("true"));
    ok &= check(admission.expire(QStringLiteral("b"), second.generation, 120),
                QStringLiteral("当前代号到期通过"), QStringLiteral("true"), QStringLiteral("false"));
    return ok;
}

/// 隐藏期间不计时，恢复后从恢复时刻重新计时。
bool hiddenVisibility()
{
    bool ok = true;
    RhineRender::MusicTextureAdmission admission(100);
    admission.setVisible(false, 0);
    auto status = admission.focus(QStringLiteral("a"), 50);
    ok &= check(!status.pending && !status.admitted, QStringLiteral("隐藏时不计时也不出帧"),
                QStringLiteral("neither"),
                QStringLiteral("%1/%2").arg(boolText(status.pending), boolText(status.admitted)));
    admission.setVisible(true, 500);
    status = admission.focus(QStringLiteral("a"), 550);
    ok &= check(status.pending, QStringLiteral("恢复后 50ms 仍等待"), QStringLiteral("pending"),
                boolText(status.pending));
    status = admission.focus(QStringLiteral("a"), 600);
    ok &= check(status.admitted, QStringLiteral("恢复后满 100ms 准入"), QStringLiteral("admitted"),
                boolText(status.admitted));

    // 已准入的 key 隐藏再恢复仍直接命中（热缓存立即复用）。
    admission.setVisible(false, 700);
    admission.setVisible(true, 800);
    status = admission.focus(QStringLiteral("a"), 801);
    ok &= check(status.admitted, QStringLiteral("已准入 key 恢复后仍命中"), QStringLiteral("admitted"),
                boolText(status.admitted));
    return ok;
}

/// 32 条上限：第 33 个 key 准入时挤掉最早的；设备恢复不清空，只有 reset 才清。
bool admissionLru()
{
    bool ok = true;
    RhineRender::MusicTextureAdmission admission(0);
    for (int i = 0; i < 33; ++i) {
        const auto key = QStringLiteral("k%1").arg(i);
        admission.focus(key, i);
        admission.focus(key, i);
    }
    ok &= check(admission.admittedCount() == RhineRender::MusicTextureAdmission::MaxAdmitted,
                QStringLiteral("准入记忆不超过 32 条"), num(RhineRender::MusicTextureAdmission::MaxAdmitted),
                num(admission.admittedCount()));
    ok &= check(!admission.isAdmitted(QStringLiteral("k0")), QStringLiteral("最早的 key 被挤出"),
                QStringLiteral("false"), boolText(admission.isAdmitted(QStringLiteral("k0"))));
    ok &= check(admission.isAdmitted(QStringLiteral("k32")), QStringLiteral("最新的 key 在记忆中"),
                QStringLiteral("true"), boolText(admission.isAdmitted(QStringLiteral("k32"))));

    admission.reset();
    ok &= check(admission.admittedCount() == 0, QStringLiteral("reset 清空准入记忆"), QStringLiteral("0"),
                num(admission.admittedCount()));
    const auto status = admission.focus(QStringLiteral("k32"), 900);
    ok &= check(status.pending, QStringLiteral("reset 后重新计时"), QStringLiteral("pending"),
                boolText(status.pending));
    return ok;
}

/// 需求判定：共享 revision 不能按单个 key 判死。
bool coverDemandHelpers()
{
    bool ok = true;
    RhineRender::CoverDemand demand;
    demand.insert(QStringLiteral("a"), 100);
    demand.insert(QStringLiteral("b"), 100);
    demand.insert(QStringLiteral("c"), 200);
    ok &= check(RhineRender::coverRevisionWanted(demand, 100), QStringLiteral("revision 100 有人要"),
                QStringLiteral("true"), boolText(RhineRender::coverRevisionWanted(demand, 100)));
    ok &= check(!RhineRender::coverRevisionWanted(demand, 300), QStringLiteral("revision 300 没人要"),
                QStringLiteral("false"), boolText(RhineRender::coverRevisionWanted(demand, 300)));
    ok &= check(RhineRender::coverRevisionSharedByOthers(demand, 100, QStringLiteral("a")),
                QStringLiteral("100 被 a 之外的 b 共享"), QStringLiteral("true"),
                boolText(RhineRender::coverRevisionSharedByOthers(demand, 100, QStringLiteral("a"))));
    ok &= check(!RhineRender::coverRevisionSharedByOthers(demand, 200, QStringLiteral("c")),
                QStringLiteral("200 只有 c 要"), QStringLiteral("false"),
                boolText(RhineRender::coverRevisionSharedByOthers(demand, 200, QStringLiteral("c"))));

    ok &= check(RhineRender::shouldAcceptPreparedCover(true, false, demand, 100),
                QStringLiteral("当前代号 + 未上传 + 有人要 → 接受"), QStringLiteral("true"),
                QStringLiteral("false"));
    ok &= check(!RhineRender::shouldAcceptPreparedCover(false, false, demand, 100),
                QStringLiteral("代号过期 → 拒绝"), QStringLiteral("false"), QStringLiteral("true"));
    ok &= check(!RhineRender::shouldAcceptPreparedCover(true, true, demand, 100),
                QStringLiteral("已经上传过 → 拒绝"), QStringLiteral("false"), QStringLiteral("true"));
    ok &= check(!RhineRender::shouldAcceptPreparedCover(true, false, demand, 300),
                QStringLiteral("没人要 → 只释放内存"), QStringLiteral("false"), QStringLiteral("true"));
    return ok;
}

/// 并发账本：逻辑取消不归还名额；收到结果才 release；未知代号不能重复归还。
bool coverPrepBudgetLimits()
{
    bool ok = true;
    RhineRender::CoverPrepBudget budget(2);
    const auto first = budget.acquire(1);
    const auto second = budget.acquire(2);
    ok &= check(first.acquired && second.acquired, QStringLiteral("前两个名额拿到"),
                QStringLiteral("true/true"),
                QStringLiteral("%1/%2").arg(boolText(first.acquired), boolText(second.acquired)));
    const auto third = budget.acquire(3);
    ok &= check(!third.acquired, QStringLiteral("满员时 acquire 失败"), QStringLiteral("false"),
                boolText(third.acquired));

    // 取消（工作线程还在跑）不释放名额：这正是不删记录的理由。
    budget.cancel(1);
    ok &= check(budget.inflight() == 2, QStringLiteral("取消后实际在途仍是 2"), QStringLiteral("2"),
                num(budget.inflight()));
    ok &= check(!budget.acquire(3).acquired, QStringLiteral("取消后仍不能再起一个"),
                QStringLiteral("false"), QStringLiteral("true"));

    // 结果回来才结清，然后名额立刻可用。
    ok &= check(budget.release(1), QStringLiteral("release 已知代号成功"), QStringLiteral("true"),
                QStringLiteral("false"));
    ok &= check(!budget.release(1), QStringLiteral("重复 release 被拒绝"), QStringLiteral("false"),
                QStringLiteral("true"));
    ok &= check(budget.acquire(3).acquired, QStringLiteral("结清后名额可复用"), QStringLiteral("true"),
                QStringLiteral("false"));
    ok &= check(budget.peak() == 2, QStringLiteral("峰值记录为 2"), QStringLiteral("2"),
                num(budget.peak()));

    budget.reset();
    ok &= check(budget.inflight() == 0 && budget.peak() == 0, QStringLiteral("reset 清空账本"),
                QStringLiteral("0/0"), QStringLiteral("%1/%2").arg(num(budget.inflight())).arg(num(budget.peak())));
    return ok;
}

/// 隔离计时器：没有帧循环也能到点通知；同 key+代号重复 arm 不重计时；销毁后无回调。
bool admissionScheduler()
{
    bool ok = true;
    const auto spinUntil = [](std::function<bool()> done, int timeoutMs) {
        QElapsedTimer timer;
        timer.start();
        while (!done() && timer.elapsed() < timeoutMs) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
            QThread::msleep(1);
        }
        return done();
    };

    RhineRender::AdmissionScheduler scheduler;
    QString firedKey;
    quint64 firedGeneration = 0;
    int fired = 0;
    scheduler.setHandler([&](const QString &key, quint64 generation) {
        firedKey = key;
        firedGeneration = generation;
        ++fired;
    });
    scheduler.arm(30, QStringLiteral("k"), 7);
    ok &= check(spinUntil([&] { return fired == 1; }, 2000),
                QStringLiteral("无持续出帧也能按时通知（事件循环）"), QStringLiteral("1"), num(fired));
    ok &= check(firedKey == QStringLiteral("k") && firedGeneration == 7,
                QStringLiteral("回调携带 arm 时的 key 与代号"), QStringLiteral("k/7"),
                QStringLiteral("%1/%2").arg(firedKey).arg(firedGeneration));

    // 同 key+代号重复 arm 不得重置到期时间。
    fired = 0;
    scheduler.arm(80, QStringLiteral("m"), 9);
    QThread::msleep(25);
    const int remainingBefore = scheduler.remainingMs();
    scheduler.arm(80, QStringLiteral("m"), 9);
    const int remainingAfter = scheduler.remainingMs();
    ok &= check(remainingAfter <= remainingBefore, QStringLiteral("重复 arm 不会把到期时间推后"),
                QStringLiteral("<= %1").arg(remainingBefore), num(remainingAfter));
    ok &= check(spinUntil([&] { return fired == 1; }, 2000), QStringLiteral("m 仍然按时触发"),
                QStringLiteral("1"), num(fired));

    // 销毁后不得再有回调（QTimer 随对象析构，connect 的 context 也一起消失）。
    int afterDestroy = 0;
    {
        auto pending = std::make_unique<RhineRender::AdmissionScheduler>();
        pending->setHandler([&](const QString &, quint64) { ++afterDestroy; });
        pending->arm(20, QStringLiteral("z"), 1);
    }
    QElapsedTimer wait;
    wait.start();
    while (wait.elapsed() < 80) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
        QThread::msleep(1);
    }
    ok &= check(afterDestroy == 0, QStringLiteral("销毁后无回调"), QStringLiteral("0"), num(afterDestroy));
    return ok;
}

} // namespace

int main(int argc, char **argv)
{
    QCoreApplication application(argc, argv);
    bool ok = true;
    ok &= environmentParsing();
    ok &= admissionBoundaries();
    ok &= admissionDisabled();
    ok &= staleCallbacks();
    ok &= hiddenVisibility();
    ok &= admissionLru();
    ok &= coverDemandHelpers();
    ok &= coverPrepBudgetLimits();
    ok &= admissionScheduler();
    if (!ok) {
        std::fprintf(stderr, "[qt_music_texture_admission_regression] 失败：%d/%d 项断言未通过\n",
                     g_failures, g_checks);
        return 1;
    }
    std::printf("[qt_music_texture_admission_regression] 全部通过：%d 项断言（准入与封面账本契约）\n",
                g_checks);
    return 0;
}
