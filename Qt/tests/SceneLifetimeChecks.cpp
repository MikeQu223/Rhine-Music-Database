// E04：归位演出的寿命策略离线用例。
//
// 这里不建 NativeScene（它要 QGuiApplication 和整套卡片数据），而是用与
// NativeSceneUpdate.cpp 同一套公式的小模型跑有限往返：先证明快速滚动期间的积压
// 是"暂时的"（有解析上界），再证明没有输入时一定收敛到 0。公式与运行期共用
// SceneLifetimePolicy.h，阈值只在那里出现一次。

#include "SceneLifetimePolicy.h"

#include <QtCore/QString>

#include <cmath>
#include <cstdio>
#include <vector>

namespace {

int failures = 0;
int checks = 0;

bool check(bool condition, const QString &what, const QString &expected, const QString &actual)
{
    ++checks;
    if (!condition) {
        std::fprintf(stderr, "[FAIL] %s\n       期望: %s\n       实际: %s\n", qPrintable(what),
                     qPrintable(expected), qPrintable(actual));
        ++failures;
    }
    return condition;
}

QString number(double value)
{
    return QString::number(value, 'g', 10);
}

struct Model {
    double lift = 0;
    double rotation = 0;
    bool holdLift = false;
    double holdValue = 0;
    double age = 0;
};

/// 与 NativeSceneUpdate.cpp 的归位循环同一套公式（秒为单位的一步）。
void advance(std::vector<Model> &models, double seconds, bool reduced)
{
    for (auto &model : models) {
        model.age += seconds;
        model.rotation = SceneLifetime::returnAngleStep(model.rotation, seconds, reduced);
        if (model.holdLift) {
            model.lift = model.holdValue;
            if (model.rotation == 0) {
                model.holdLift = false;
            }
        } else {
            model.lift = SceneLifetime::returningLiftStep(model.lift, seconds, reduced);
        }
    }
}

/// 与运行期一致的删除判据。
void prune(std::vector<Model> &models)
{
    for (auto it = models.begin(); it != models.end();) {
        if (SceneLifetime::returningConverged(it->lift, it->rotation)) {
            it = models.erase(it);
        } else {
            ++it;
        }
    }
}

bool angleStep()
{
    bool ok = true;
    // 1.2 弧度、非减弱：指数 7、阈值 0.001，约 1 秒内必须归零。
    double angle = 1.2;
    int steps = 0;
    while (angle != 0 && steps < 600) {
        angle = SceneLifetime::returnAngleStep(angle, 1.0 / 60.0, false);
        ++steps;
    }
    ok &= check(angle == 0, QStringLiteral("1.2 弧度回正必须归零"), QStringLiteral("0"),
                number(angle));
    ok &= check(steps < 600, QStringLiteral("回正必须在 10 秒内完成"), QStringLiteral("<600"),
                QString::number(steps));

    const double normal = SceneLifetime::returnAngleStep(1.0, 0.1, false);
    const double reduced = SceneLifetime::returnAngleStep(1.0, 0.1, true);
    ok &= check(reduced < normal, QStringLiteral("减弱模式回正更快"),
                QStringLiteral("reduced < normal"),
                QStringLiteral("%1 / %2").arg(number(reduced), number(normal)));

    ok &= check(SceneLifetime::returnAngleStep(0.7, 0.0, false) == 0.7,
                QStringLiteral("零时长保持角度不变"), QStringLiteral("0.7"), QStringLiteral("0.7"));
    ok &= check(SceneLifetime::returningConverged(0.00001, 0.00001),
                QStringLiteral("阈值以内算收敛"), QStringLiteral("true"), QStringLiteral("false"));
    ok &= check(!SceneLifetime::returningConverged(0.0002, 0),
                QStringLiteral("lift 超阈值不算收敛"), QStringLiteral("false"),
                QStringLiteral("true"));
    return ok;
}

bool liftSettles()
{
    bool ok = true;
    // 落位时间常数：从 2 米落到 0.1 毫米 = ln(2/0.0001)/4.5 ≈ 2.2 秒。
    double lift = 2.0;
    int steps = 0;
    while (lift != 0 && steps < 3600) {
        lift = SceneLifetime::returningLiftStep(lift, 1.0 / 60.0, false);
        ++steps;
    }
    ok &= check(lift == 0, QStringLiteral("2 米落位必须归零"), QStringLiteral("0"), number(lift));
    ok &= check(steps > 60 && steps < 400,
                QStringLiteral("落位约 2 秒完成（帧率无关）"), QStringLiteral("60<steps<400"),
                QString::number(steps));

    // 同样 1 秒的实际时间，用一半的帧率推进两次，结果必须一致（旧 damp 会差很多）。
    double at60 = 2.0;
    for (int frame = 0; frame < 60; ++frame) {
        at60 = SceneLifetime::returningLiftStep(at60, 1.0 / 60.0, false);
    }
    double at30 = 2.0;
    for (int frame = 0; frame < 30; ++frame) {
        at30 = SceneLifetime::returningLiftStep(at30, 1.0 / 30.0, false);
    }
    ok &= check(std::abs(at60 - at30) < 1e-9, QStringLiteral("落位结果与帧率无关"),
                QStringLiteral("at60 == at30"), QStringLiteral("%1 / %2").arg(number(at60), number(at30)));
    ok &= check(SceneLifetime::returningLiftStep(0.5, 0.0, false) == 0.5,
                QStringLiteral("零时长保持落位不变"), QStringLiteral("0.5"), QStringLiteral("0.5"));
    return ok;
}

bool backlogIsTransient()
{
    bool ok = true;
    // 每帧一次换格、每次新增一份归位（holdLift 期间 lift 不衰减）：
    // 单份寿命 ≈ 回正 1.0 秒 + 落位 2.3 秒 ≈ 3.3 秒 ≈ 200 帧，因此积压有解析上界。
    std::vector<Model> models;
    int peak = 0;
    for (int navigation = 0; navigation < 400; ++navigation) {
        Model model;
        model.lift = 3.2;
        model.rotation = 1.4;
        model.holdLift = true;
        model.holdValue = 3.2;
        models.push_back(model);
        advance(models, 1.0 / 60.0, false);
        prune(models);
        peak = std::max(peak, int(models.size()));
    }
    ok &= check(peak > 100, QStringLiteral("按住换格时确实会积压（不是零成本）"),
                QStringLiteral(">100"), QString::number(peak));
    ok &= check(peak < 260, QStringLiteral("积压有解析上界，不是无界增长"),
                QStringLiteral("<260"), QString::number(peak));

    // 停止输入后必须清空：不再新增，只等收敛。
    int steps = 0;
    while (!models.empty() && steps < 3600) {
        advance(models, 1.0 / 60.0, false);
        prune(models);
        ++steps;
    }
    ok &= check(models.empty(), QStringLiteral("停止换格后归位必须全部退出"),
                QStringLiteral("0 份"), QString::number(models.size()));
    ok &= check(steps < 400, QStringLiteral("退出应在数秒内完成"), QStringLiteral("<400"),
                QString::number(steps));
    return ok;
}

bool settlesFromFullBacklog()
{
    bool ok = true;
    std::vector<Model> models;
    for (int index = 0; index < 200; ++index) {
        Model model;
        model.lift = 2.0 + 0.01 * index;
        model.rotation = 0.9;
        model.holdLift = true;
        model.holdValue = model.lift;
        models.push_back(model);
    }
    int steps = 0;
    while (!models.empty() && steps < 3600) {
        advance(models, 1.0 / 60.0, false);
        prune(models);
        ++steps;
    }
    ok &= check(models.empty(), QStringLiteral("满积压下静止 60 秒内必须清空"),
                QStringLiteral("0 份"), QString::number(models.size()));
    ok &= check(steps < 400, QStringLiteral("满积压也在数秒内清空"), QStringLiteral("<400"),
                QString::number(steps));

    // 带回正的非零 rotation：rotation 归零前 lift 一直保持，最终仍须退出。
    std::vector<Model> single;
    Model model;
    model.lift = 3.4;
    model.rotation = 3.1;
    model.holdLift = true;
    model.holdValue = 3.4;
    single.push_back(model);
    int singleSteps = 0;
    while (!single.empty() && singleSteps < 3600) {
        advance(single, 1.0 / 60.0, false);
        prune(single);
        ++singleSteps;
    }
    ok &= check(single.empty(), QStringLiteral("大角度回正也必须收敛退出"),
                QStringLiteral("0 份"), QString::number(single.size()));
    return ok;
}

} // namespace

int main(int argc, char **argv)
{
    Q_UNUSED(argc);
    Q_UNUSED(argv);
    bool ok = true;
    ok &= angleStep();
    ok &= liftSettles();
    ok &= backlogIsTransient();
    ok &= settlesFromFullBacklog();
    std::printf("归位寿命策略: %d 项检查，%d 项失败\n", checks, failures);
    return ok && failures == 0 ? 0 : 1;
}
