// 渲染策略里可以离线判定的那一半（GPU 计时四态、时间戳登记、AA 模式是否需要运动矢量）
// 集中在 header-only 的 Qt/src/render/RenderPolicy.h，渲染器与用例共用同一份实现。
// 这些判断写错不会崩溃，只会让面板/CSV 把"没请求"说成"没样本"、把配置缺口算成驱动延迟，
// 所以只能靠用例拦。本文件只依赖 Qt6::Core：不建 QGuiApplication、不碰 QRhi，三平台 CI
// 都能离线跑。
#include "render/MaterialSlotKey.h"
#include "render/RenderPolicy.h"
#include "render/SceneSyncCache.h"

#include <QString>
#include <cstdio>

namespace {

int g_checks = 0;
int g_failures = 0;

/**
 * 断言：失败时把「断言名 / 期望 / 实际」三样一起写到 stderr。
 *
 * 只打一句"真值表不对"，CI 日志里分不出是四态里的哪一格错了；期望与实际并排才看得懂。
 */
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

QString boolText(bool value)
{
    return value ? QStringLiteral("true") : QStringLiteral("false");
}

/// 状态名走真实实现，失败信息里显示的就是面板/CSV 会看到的那个键。
QString statusText(RhineRender::GpuTimingStatus status)
{
    return QString::fromLatin1(RhineRender::gpuTimingStatusName(status));
}

QString quoted(const QString &value)
{
    return QStringLiteral("\"%1\"").arg(value);
}

/**
 * 四态真值表：(能力, 是否请求, 是否有 >0 样本) → 状态。
 *
 * 面板上的 "0.000 ms" 有三种互不相同的含义，混成一种就回答不了"GPU 到底占多少"。
 */
bool timingTruthTable()
{
    using RhineRender::GpuTimingStatus;
    struct Case {
        bool supported;
        bool requested;
        bool hasSample;
        GpuTimingStatus expected;
        const char *why;
    };
    const Case cases[]{
        // 无能力时 hasSample 一概不可信：后端连查询接口都没有，样本只可能是 0 或陈旧值。
        // 判成 NoSample 会让面板显示"等待样本"，而用户永远等不到。
        {false, false, false, GpuTimingStatus::Unsupported, "无能力、没请求、没样本"},
        {false, false, true, GpuTimingStatus::Unsupported, "无能力却收到样本：不可信，仍判 Unsupported"},
        {false, true, false, GpuTimingStatus::Unsupported, "无能力但已请求：仍然 Unsupported"},
        {false, true, true, GpuTimingStatus::Unsupported, "无能力、已请求、有样本：能力优先"},
        // 支持但没请求是配置问题，不是延迟问题：把 Disabled 误判成 NoSample 会让性能报告
        // 把配置缺口写成驱动延迟，排查方向整个跑偏。
        {true, false, false, GpuTimingStatus::Disabled, "支持但没请求：Disabled"},
        {true, false, true, GpuTimingStatus::Disabled, "支持、没请求却有样本：按配置口径仍算 Disabled"},
        {true, true, false, GpuTimingStatus::NoSample, "已请求但这一帧还没有已完成样本"},
        {true, true, true, GpuTimingStatus::Ok, "已请求且有真实样本：数值可以直接引用"},
    };
    bool ok = true;
    for (const auto &item : cases) {
        const auto actual = RhineRender::classifyGpuTiming(item.supported, item.requested, item.hasSample);
        const QString label = QStringLiteral("classifyGpuTiming(supported=%1, requested=%2, "
                                            "hasSample=%3)：%4")
                                  .arg(boolText(item.supported))
                                  .arg(boolText(item.requested))
                                  .arg(boolText(item.hasSample))
                                  .arg(QString::fromUtf8(item.why));
        ok &= check(actual == item.expected, label, statusText(item.expected), statusText(actual));
    }
    // 面板读的是 name(classify(...)) 这条链，两半对不上只会显示成 unknown。
    const auto composed = RhineRender::classifyGpuTiming(true, true, false);
    ok &= check(QString::fromLatin1(RhineRender::gpuTimingStatusName(composed)) == QStringLiteral("noSample"),
                QStringLiteral("name(classify(true, true, false)) 组合链路"), quoted(QStringLiteral("noSample")),
                quoted(statusText(composed)));
    return ok;
}

/// 面板（QML）与 CSV 都按这几个短名逐字匹配，改名或改大小写等于把消费方全打断。
bool timingStatusNames()
{
    using RhineRender::GpuTimingStatus;
    struct Case {
        GpuTimingStatus status;
        const char *expected;
        const char *why;
    };
    const Case cases[]{
        {GpuTimingStatus::Unsupported, "unsupported", "能力不支持"},
        {GpuTimingStatus::Disabled, "disabled", "支持但没请求"},
        {GpuTimingStatus::NoSample, "noSample", "已请求没样本（驼峰，不是 nosample/NoSample）"},
        {GpuTimingStatus::Ok, "ok", "有真实样本"},
    };
    bool ok = true;
    for (const auto &item : cases) {
        const char *actual = RhineRender::gpuTimingStatusName(item.status);
        const QString label = QStringLiteral("gpuTimingStatusName(%1) [%2]")
                                  .arg(QString::fromLatin1(item.expected))
                                  .arg(QString::fromUtf8(item.why));
        ok &= check(actual != nullptr, label + QStringLiteral(" 不能返回 nullptr"),
                    QStringLiteral("非空 C 字符串"), QStringLiteral("nullptr"));
        if (!actual) {
            continue;
        }
        ok &= check(QString::fromLatin1(actual) == QString::fromLatin1(item.expected), label,
                    quoted(QString::fromLatin1(item.expected)), quoted(QString::fromLatin1(actual)));
    }
    return ok;
}

/**
 * AA 模式 → 是否需要运动矢量 MRT（只看配置，不看运行时能力）。
 *
 * 口径写错有两种后果：漏掉 taa/fsr3 会让时域 pass 读到空运动矢量（画面拖影/抖动），
 * 多给 fsr1/fxaa 分配则白占一份全屏附件。
 */
bool motionModeTable()
{
    struct Case {
        const char *mode;
        bool expected;
        const char *why;
    };
    const Case cases[]{
        {"taa", true, "TAA 重投影必须读运动矢量与历史帧"},
        {"fsr", true, "FSR 的时域升采样要运动矢量"},
        {"fsr3", true, "FSR3 同属时域，目标分配必须预留 MRT"},
        {"fsr1", false, "FSR1 是纯空间滤波，要运动矢量只会白分一份附件"},
        {"fxaa", false, "FXAA 单帧处理，不读历史"},
        {"msaa", false, "MSAA 走硬件采样，不需要运动矢量"},
        {"off", false, "关掉 AA 时不该多分配目标"},
        {"", false, "空模式（没配 RHINE_AA_MODE）必须按不需要处理"},
        {"TAA", false, "大小写敏感：真实配置来自小写环境变量，大写不是合法模式"},
        {"FSR3", false, "第二个大小写用例，防止有人顺手给比较加 ignoringCase"},
    };
    bool ok = true;
    for (const auto &item : cases) {
        const QString mode = QString::fromLatin1(item.mode);
        const bool actual = RhineRender::modeNeedsMotion(mode);
        const QString label = QStringLiteral("modeNeedsMotion(%1) [%2]")
                                  .arg(quoted(mode))
                                  .arg(QString::fromUtf8(item.why));
        ok &= check(actual == item.expected, label, boolText(item.expected), boolText(actual));
    }
    return ok;
}

/*
 * 关于 A05 的 ScenePostProcess::motionConfigured()：这里不直接断言，原因写清楚免得被当成漏测。
 *
 * 它已经落地在 Qt/src/render/ScenePostProcess.h，但签名是 non-static const 成员函数；
 * ScenePostProcess 继承 SceneResources、构造必须传 QRhi*，因此离线构造不出来。要为它写用例
 * 就得起 QRhi/QGuiApplication，违背"纯 Qt6::Core、三平台离线可跑"的约束，也会把契约测试
 * 退化成 GPU 环境测试。
 *
 * 它的口径是 modeNeedsMotion(qEnvironmentVariable("RHINE_AA_MODE")) || RhineFg::isEnabled()：
 * 前半段正是上面按真值表覆盖的 modeNeedsMotion()（含 "TAA" 为 false，钉住小写环境变量约定），
 * 后半段 isEnabled() 的开关语义由 qt_fg_capability_regression 覆盖。
 * 若将来把它改成 static 或抽进 RenderPolicy.h 变成纯函数，在这里补一行断言即可。
 */

/**
 * 启动期时间戳登记是进程级单向开关：main.cpp 与呈现层两条路径谁先登记都行，
 * 一旦登记为 true 就不能再被读成 false——否则"已请求"会被面板说成"没请求"。
 *
 * 本条会永久翻转标志，所以放在 main 的最后跑。断言只要求「调用后必须为 true，再次调用
 * 仍为 true」：同进程若已有别处登记，调用前就可能是 true，那不是失败。
 */
bool timestampRegistration()
{
    const bool before = RhineRender::timestampsRequested();
    RhineRender::requestTimestamps();
    bool ok = true;
    ok &= check(RhineRender::timestampsRequested(),
                QStringLiteral("requestTimestamps() 之后 timestampsRequested()（调用前=%1）")
                    .arg(boolText(before)),
                QStringLiteral("true"), boolText(RhineRender::timestampsRequested()));
    // 两条启动路径都会登记，重复登记必须保持 true，不能翻转或清空。
    RhineRender::requestTimestamps();
    ok &= check(RhineRender::timestampsRequested(), QStringLiteral("重复 requestTimestamps() 之后仍为 true"),
                QStringLiteral("true"), boolText(RhineRender::timestampsRequested()));
    return ok;
}

// C02：材质槽的键。键算错不会崩，只会让两条 draw 共用同一份 uniform 与纹理绑定槽，
// 表现成装配体某一部分突然换上了别处的材质 —— 截图里很难认出来，只能靠用例拦。
bool materialSlotKeys()
{
    bool ok = true;
    const RhineRender::MaterialSlotKey base{17, 3, QStringLiteral("Ivory_Edges")};
    const RhineRender::MaterialSlotKey same{17, 3, QStringLiteral("Ivory_Edges")};
    ok &= check(base == same, QStringLiteral("id/mesh/名字 相同 → 键相等"), QStringLiteral("true"),
                boolText(base == same));
    ok &= check(qHash(base) == qHash(same), QStringLiteral("相等键的哈希相同"), QStringLiteral("true"),
                boolText(qHash(base) == qHash(same)));
    ok &= check(base != RhineRender::MaterialSlotKey{18, 3, QStringLiteral("Ivory_Edges")},
                QStringLiteral("id 不同 → 键不等"), QStringLiteral("true"),
                boolText(base != RhineRender::MaterialSlotKey{18, 3, QStringLiteral("Ivory_Edges")}));
    ok &= check(base != RhineRender::MaterialSlotKey{17, 4, QStringLiteral("Ivory_Edges")},
                QStringLiteral("mesh 不同 → 键不等"), QStringLiteral("true"),
                boolText(base != RhineRender::MaterialSlotKey{17, 4, QStringLiteral("Ivory_Edges")}));
    // 同一个装配 draw 换材质时 id/mesh 可能不变，名字必须参与比较。
    ok &= check(base != RhineRender::MaterialSlotKey{17, 3, QStringLiteral("Frosted_Polymer")},
                QStringLiteral("名字不同 → 键不等"), QStringLiteral("true"),
                boolText(base != RhineRender::MaterialSlotKey{17, 3, QStringLiteral("Frosted_Polymer")}));
    ok &= check(base != RhineRender::MaterialSlotKey{17, 3, QString()},
                QStringLiteral("空名字与具名 → 键不等"), QStringLiteral("true"),
                boolText(base != RhineRender::MaterialSlotKey{17, 3, QString()}));
    return ok;
}

// C03：同步阶段要不要重新取场景快照。少判一项就会在某一帧画出上一帧的内容（开灯后仍是
// 关灯的烘焙、装配体重算后仍是旧几何），而这类画面滞后又只在特定操作顺序下出现。
bool sceneSyncCache()
{
    bool ok = true;
    const RhineRender::SceneSyncSignature base{42, 7, false};
    ok &= check(RhineRender::sceneSyncReusable(base, base), QStringLiteral("签名完全相同 → 复用"),
                QStringLiteral("true"), boolText(RhineRender::sceneSyncReusable(base, base)));
    ok &= check(!RhineRender::sceneSyncReusable(base, RhineRender::SceneSyncSignature{43, 7, false}),
                QStringLiteral("场景版本前进 → 不复用"), QStringLiteral("false"),
                boolText(RhineRender::sceneSyncReusable(base, RhineRender::SceneSyncSignature{43, 7, false})));
    ok &= check(!RhineRender::sceneSyncReusable(base, RhineRender::SceneSyncSignature{42, 8, false}),
                QStringLiteral("几何版本前进 → 不复用"), QStringLiteral("false"),
                boolText(RhineRender::sceneSyncReusable(base, RhineRender::SceneSyncSignature{42, 8, false})));
    // 开灯/关灯会改装配体的烘焙结果，但场景版本可能没前进：光照必须单独参与判断。
    ok &= check(!RhineRender::sceneSyncReusable(base, RhineRender::SceneSyncSignature{42, 7, true}),
                QStringLiteral("光照开关翻转 → 不复用"), QStringLiteral("false"),
                boolText(RhineRender::sceneSyncReusable(base, RhineRender::SceneSyncSignature{42, 7, true})));
    ok &= check(RhineRender::SceneSyncSignature{1, 2, true} == RhineRender::SceneSyncSignature{1, 2, true},
                QStringLiteral("相同签名相等"), QStringLiteral("true"),
                boolText(RhineRender::SceneSyncSignature{1, 2, true} == RhineRender::SceneSyncSignature{1, 2, true}));
    return ok;
}

} // namespace

int main()
{
    bool ok = true;
    ok &= timingTruthTable();
    ok &= timingStatusNames();
    ok &= motionModeTable();
    ok &= materialSlotKeys();
    ok &= sceneSyncCache();
    // 放在最后：它会永久翻转进程级的时间戳登记标志。
    ok &= timestampRegistration();
    if (!ok) {
        std::fprintf(stderr, "[qt_render_policy_regression] 失败：%d/%d 项断言未通过\n", g_failures,
                     g_checks);
        return 1;
    }
    std::printf("[qt_render_policy_regression] 全部通过：%d 项断言（RenderPolicy 契约）\n", g_checks);
    return 0;
}
