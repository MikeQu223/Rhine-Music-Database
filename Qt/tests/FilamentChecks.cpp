// Filament 适配层的契约检查。
//
// 覆盖实施计划 §9 里"不开 GPU 也要钉住"的三条：
//   V1  关闭时零差异 —— 三层开关任何一层关掉，判定结果都必须落回旧链路（查 requested/source/describe）；
//   V9  降级         —— 非法共享上下文时 initialize() 必须失败、状态进 Degraded、留下具体失败码，
//                       而进程照活（"降级不崩"）；
//   V11 退出安全     —— shutdown()/destroy() 幂等、shutdown 之后 state() 必须是 Off（T5 是"Filament
//                       Engine 晚于 VkDevice 销毁"的退出崩溃，轻量版只能钉顺序与幂等）。
// 第 5 条（渲染交接）需要真实 Vulkan 设备：拿不到设备时打印 SKIP 并返回 0，CI 上不判失败。
//
// 两套 C++ 运行库的边界：Filament 侧用 libc++ 编译，本文件与 Qt 侧用默认 libstdc++。所以这里只
// include FilamentBridge.h / FilamentContract.h / FilamentConfig.h 三个只有 POD 的头，绝不 include
// 任何 Filament 头。宿主 Vulkan 设备在本文件里自己建（只用 vulkan.h 的 C 定义，函数指针靠
// dlopen/dlsym 取），因此本用例不引入 libvulkan 的链接依赖，也不带任何 Filament 类型过界。
//
// 运行方式（ctest 集成由构建脚本决定）：
//   RhineFilamentChecks [资源根]     资源根也可用环境变量 RHINE_FILAMENT_ASSET_ROOT 指定。

#include "FilamentBridge.h"
#include "FilamentConfig.h"
#include "FilamentContract.h"

#include <QByteArray>
#include <QString>
#include <QtGlobal>

#include <cstdint>
#include <cstdio>
#include <cstring>

namespace RF = RhineFilament;

// 宿主 Vulkan 设备创建：仅需要 vulkan.h 的 C 定义（POD）。macOS 走 Metal（计划 §P5），
// 这里不提供；没有头文件或没有加载器的机器一律走 SKIP 分支。
#if defined(__has_include)
#if __has_include(<vulkan/vulkan.h>) && (defined(Q_OS_LINUX) || defined(Q_OS_WIN) || defined(Q_OS_FREEBSD))
#define RHINE_VK_HOST 1
#endif
#endif

#if defined(RHINE_VK_HOST)
#include <vulkan/vulkan.h>

#if defined(Q_OS_WIN)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#include <vector>
#endif

namespace {

int g_checks = 0;   // 断言数（含"不崩溃"这类被动断言）
int g_failures = 0; // 失败数
int g_skips = 0;    // 跳过的组数

QString quoted(const char *text)
{
    return text ? QString::fromUtf8(text) : QStringLiteral("<nullptr>");
}

void section(const QString &title)
{
    std::printf("\n== %s ==\n", qPrintable(title));
    std::fflush(stdout);
}

/// 断言失败时把"期望 / 实际"一起打出来：CTest 里只看得到 stderr 的那几行。
void expect(bool ok, const QString &name, const QString &expected, const QString &actual)
{
    ++g_checks;
    if (ok) {
        std::printf("  ok   %s\n", qPrintable(name));
        std::fflush(stdout);
        return;
    }
    ++g_failures;
    std::fprintf(stderr, "  FAIL %s\n        期望: %s\n        实际: %s\n", qPrintable(name), qPrintable(expected),
                 qPrintable(actual));
    std::fflush(stderr);
}

void expectTrue(bool actual, const QString &name)
{
    expect(actual, name, QStringLiteral("true"), QStringLiteral("false"));
}

void expectFalse(bool actual, const QString &name)
{
    expect(!actual, name, QStringLiteral("false"), QStringLiteral("true"));
}

void expectText(const QString &actual, const QString &expected, const QString &name)
{
    expect(actual == expected, name, expected, actual);
}

void expectCount(uint32_t actual, uint32_t expected, const QString &name)
{
    expect(actual == expected, name, QString::number(expected), QString::number(actual));
}

/// 已经执行完、结果只可能是"没崩"的被动断言（崩溃的话进程直接死，跑不到这里）。
void note(const QString &text)
{
    ++g_checks;
    std::printf("  ok   %s\n", qPrintable(text));
    std::fflush(stdout);
}

void skip(const QString &reason)
{
    ++g_skips;
    std::printf("  SKIP %s\n", qPrintable(reason));
    std::fflush(stdout);
}

/// 环境变量类用例跑完要还原，否则同进程里后面的用例会读到上一条的状态。
struct EnvGuard
{
    explicit EnvGuard(const char *name) : key(name)
    {
        hadValue = qEnvironmentVariableIsSet(name);
        previous = qgetenv(name);
    }
    ~EnvGuard()
    {
        if (hadValue) {
            qputenv(key.constData(), previous);
        } else {
            qunsetenv(key.constData());
        }
    }
    QByteArray key;
    QByteArray previous;
    bool hadValue = false;
};

/// nullptr 表示"不设这个环境变量"，""表示"设成空串"。
void applyEnv(const char *value)
{
    if (value) {
        qputenv("RHINE_FILAMENT", QByteArray(value));
    } else {
        qunsetenv("RHINE_FILAMENT");
    }
}

QString stateText(RF::State state)
{
    return QStringLiteral("%1(%2)").arg(int(state)).arg(quoted(RF::stateName(state)));
}

QString errorText(RF::Error error)
{
    return QStringLiteral("%1(%2)").arg(int(error)).arg(quoted(RF::errorCode(error)));
}

// ---------------------------------------------------------------------------
// 1. 开关矩阵：三层优先级 + Config::describe()
// ---------------------------------------------------------------------------
// 由高到低：legacyOnly（--self-test/--visual-fixtures/--ui-self-test/--offline）
//          → 编译期 RHINE_FILAMENT（未编入则永远关闭）
//          → 环境变量 RHINE_FILAMENT
//          → 偏好 filament。
// 一个二进制只可能处于"编入"或"未编入"其中一种状态，所以两条分支都在代码里，按 compiledIn()
// 的运行期结果二选一；未编入时的结论本身就是 V1 的前提，必须逐个组合都断言到。
bool runSwitchMatrix()
{
    section(QStringLiteral("1 开关矩阵：三层优先级与 Config::describe()"));
    bool ok = true;
    EnvGuard guard("RHINE_FILAMENT");

    // legacyForced 只允许由 legacyOnly 置位；describe() 的契约：legacyForced 优先输出
    // "legacy-forced"，否则 requested 时是 "on:<source>"，未开启时就是 source 本身。
    const auto verdict = [](const RF::Config &config) {
        return QStringLiteral("requested=%1 legacyForced=%2 source=%3 describe=%4")
            .arg(config.requested ? QStringLiteral("true") : QStringLiteral("false"))
            .arg(config.legacyForced ? QStringLiteral("true") : QStringLiteral("false"))
            .arg(config.source, config.describe());
    };
    const auto expectedVerdict = [](bool requested, bool legacyForced, const char *source) {
        const QString expectedSource = QString::fromUtf8(source);
        const QString expectedDescribe = legacyForced ? QStringLiteral("legacy-forced")
                                          : requested ? QStringLiteral("on:") + expectedSource
                                                      : expectedSource;
        return QStringLiteral("requested=%1 legacyForced=%2 source=%3 describe=%4")
            .arg(requested ? QStringLiteral("true") : QStringLiteral("false"))
            .arg(legacyForced ? QStringLiteral("true") : QStringLiteral("false"))
            .arg(expectedSource, expectedDescribe);
    };
    const auto label = [](const char *env, const char *preference, bool legacyOnly) {
        return QStringLiteral("env=%1 pref=\"%2\" legacyOnly=%3")
            .arg(env ? QString::fromUtf8(env) : QStringLiteral("<未设>"), preference ? QString::fromUtf8(preference)
                                                                                    : QStringLiteral("<空>"))
            .arg(legacyOnly ? QStringLiteral("true") : QStringLiteral("false"));
    };

    // 【功能暂未完成】resolveConfig() 已无条件回退到 legacy 链路（见 FilamentConfig.cpp）：
    // V3/V4 画面保真度未达标，任何 CMake 开关、环境变量与应用偏好都不得打开 Filament。
    // 因此这里断言的是「恒为关闭、source 恒为 unimplemented」。
    // 功能完成并恢复可切换后，删除下面的 return 即可回到原来的三层优先级矩阵。
    {
        const char *const envs[] = {nullptr, "1", "on", "force", "0", "off"};
        const char *const preferences[] = {"", "on", "1", "force", "off", "randoms"};
        for (const char *env : envs) {
            for (const char *preference : preferences) {
                applyEnv(env);
                const RF::Config config = RF::resolveConfig(QString::fromUtf8(preference), false);
                expect(verdict(config) == expectedVerdict(false, false, "unimplemented"),
                       label(env, preference, false) + QStringLiteral(" 功能未完成必须恒回退 legacy"),
                       expectedVerdict(false, false, "unimplemented"), verdict(config));
            }
        }
        applyEnv("1");
        const RF::Config forced = RF::resolveConfig(QStringLiteral("force"), true);
        expect(verdict(forced) == expectedVerdict(false, true, "unimplemented"),
               QStringLiteral("legacyOnly 仍应置位 legacyForced"),
               expectedVerdict(false, true, "unimplemented"), verdict(forced));
        std::printf("  info Filament 渲染功能暂未完成：resolveConfig() 无条件回退 legacy\n");
        return ok;
    }

    if (!RF::compiledIn()) {
        // 未编入：除 legacyOnly 之外，任何环境变量与偏好都不得把 Filament 打开（设置页此时整组隐藏）。
        const char *const envs[] = {nullptr, "1", "on", "force"};
        const char *const preferences[] = {"", "on", "1", "force", "off", "乱七八糟"};
        for (const char *env : envs) {
            for (const char *preference : preferences) {
                applyEnv(env);
                const RF::Config config = RF::resolveConfig(QString::fromUtf8(preference), false);
                expect(verdict(config) == expectedVerdict(false, false, "cmake-off"),
                       label(env, preference, false) + QStringLiteral(" 未编入必须恒 off"),
                       expectedVerdict(false, false, "cmake-off"), verdict(config));
            }
        }
        // legacyOnly 压过一切，包括"未编入"（此时 source 与 describe 都是 legacy-forced）。
        applyEnv("1");
        const RF::Config forced = RF::resolveConfig(QStringLiteral("force"), true);
        expect(verdict(forced) == expectedVerdict(false, true, "legacy-forced"),
               QStringLiteral("env=1 pref=\"force\" legacyOnly=true 强制旧链路"),
               expectedVerdict(false, true, "legacy-forced"), verdict(forced));
        std::printf("  info 本二进制未编入 Filament（compiledIn()=false），以上为编译期关闭分支\n");
        return ok;
    }

    struct Case
    {
        const char *env;        // nullptr = 不设环境变量
        const char *preference; // 偏好 filament 的取值
        bool legacyOnly;
        QString verdict; // 期望的 requested/legacyForced/source/describe
    };
    const Case cases[] = {
        // legacyOnly 最高：自检/离线参数必须无条件回旧链路，环境变量与偏好一律不算数。
        {"1", "on", true, expectedVerdict(false, true, "legacy-forced")},
        {nullptr, "force", true, expectedVerdict(false, true, "legacy-forced")},
        {"0", nullptr, true, expectedVerdict(false, true, "legacy-forced")},
        // 环境变量关：压过偏好。
        {"0", "on", false, expectedVerdict(false, false, "env-off")},
        {"off", "force", false, expectedVerdict(false, false, "env-off")},
        {"false", nullptr, false, expectedVerdict(false, false, "env-off")},
        // 环境变量开：偏好写 off 也拦不住。
        {"1", nullptr, false, expectedVerdict(true, false, "env")},
        {"on", "off", false, expectedVerdict(true, false, "env")},
        {"force", "", false, expectedVerdict(true, false, "env")},
        {" ON ", nullptr, false, expectedVerdict(true, false, "env")}, // 大小写与空白不算错
        // 偏好层：只在环境变量缺席时生效。
        {nullptr, "on", false, expectedVerdict(true, false, "preference")},
        {nullptr, "1", false, expectedVerdict(true, false, "preference")},
        {nullptr, "force", false, expectedVerdict(true, false, "preference")},
        {nullptr, " ON ", false, expectedVerdict(true, false, "preference")},
        // 关：空值、off 与任意脏值都必须关（fail-closed，脏值绝不能把链路点亮）。
        {nullptr, "", false, expectedVerdict(false, false, "off")},
        {nullptr, "off", false, expectedVerdict(false, false, "off")},
        {nullptr, "乱七八糟", false, expectedVerdict(false, false, "off")},
        {"", "yes", false, expectedVerdict(false, false, "off")},      // 空环境变量等于没设
        {"yes", "on", false, expectedVerdict(true, false, "preference")}, // 未识别的值不改变结论，继续看偏好
    };
    for (const Case &item : cases) {
        applyEnv(item.env);
        const RF::Config config = RF::resolveConfig(item.preference ? QString::fromUtf8(item.preference) : QString(),
                                                    item.legacyOnly);
        expectText(verdict(config), item.verdict, label(item.env, item.preference, item.legacyOnly));
    }
    return ok;
}

// ---------------------------------------------------------------------------
// 2. 失败码与状态名
// ---------------------------------------------------------------------------
// 失败码会原样写进偏好 filament-last-error（"<code>: <detail>"），状态名会进遥测与设置页；
// 两者都必须是稳定的、非空的、互不相同的字面量，否则面板与日志会串味。
bool runErrorCodes()
{
    section(QStringLiteral("2 失败码与状态名"));
    bool ok = true;

    struct ErrorCase
    {
        RF::Error value;
        const char *name;
    };
    const ErrorCase errors[] = {
        {RF::Error::None, "None"},
        {RF::Error::Disabled, "Disabled"},
        {RF::Error::BackendUnsupported, "BackendUnsupported"},
        {RF::Error::SharedContext, "SharedContext"},
        {RF::Error::EngineCreate, "EngineCreate"},
        {RF::Error::SceneCreate, "SceneCreate"},
        {RF::Error::MaterialLoad, "MaterialLoad"},
        {RF::Error::MaterialMissing, "MaterialMissing"},
        {RF::Error::ImageHandoff, "ImageHandoff"},
        {RF::Error::FirstFrame, "FirstFrame"},
        {RF::Error::SizeInvalid, "SizeInvalid"},
        {RF::Error::Sync, "Sync"},
        {RF::Error::Runtime, "Runtime"},
    };
    const int count = int(sizeof(errors) / sizeof(errors[0]));
    // 枚举是连续的 uint8_t：新增成员必须同时更新这张表，否则下面的覆盖断言会立刻失败。
    expectCount(uint32_t(count), uint32_t(RF::Error::Runtime) + 1u,
                QStringLiteral("Error 枚举连续且被这张表完全覆盖（新增失败码要一起登记）"));

    QString clashes;
    for (int i = 0; i < count; ++i) {
        const ErrorCase &item = errors[i];
        const char *code = RF::errorCode(item.value);
        const QString name = QStringLiteral("errorCode(%1)").arg(QString::fromUtf8(item.name));
        expect(code != nullptr, name + QStringLiteral(" 不能是空指针"), QStringLiteral("非 nullptr"),
               QStringLiteral("nullptr"));
        if (!code) {
            ok = false;
            continue;
        }
        // None 是"无错误"的哨兵，允许空串；其余每个失败码都必须是 E_* 且 E_ 之后还有内容。
        if (item.value == RF::Error::None) {
            expect(code[0] == '\0' || std::strncmp(code, "E_", 2) == 0,
                   name + QStringLiteral(" 必须是空串或 E_* 码"), QStringLiteral("空串或 E_*"), quoted(code));
        } else {
            expect(std::strncmp(code, "E_", 2) == 0 && code[2] != '\0', name + QStringLiteral(" 形如 E_*_..."),
                   QStringLiteral("E_*"), quoted(code));
        }
        // 稳定性：同一次运行里重复取值必须一致（偏好与日志按字符串比较）。
        expect(std::strcmp(code, RF::errorCode(item.value)) == 0, name + QStringLiteral(" 取值稳定"),
               quoted(code), quoted(RF::errorCode(item.value)));
        // 不重复：两个原因写出同一个码，事后就分不清是材质缺失还是首帧失败。
        if (code[0] == '\0') {
            continue;
        }
        for (int j = i + 1; j < count; ++j) {
            const char *other = RF::errorCode(errors[j].value);
            if (other && other[0] != '\0' && std::strcmp(code, other) == 0) {
                clashes += QStringLiteral("%1 与 %2 同为 %3；")
                               .arg(QString::fromUtf8(item.name), QString::fromUtf8(errors[j].name), quoted(code));
            }
        }
    }
    expect(clashes.isEmpty(), QStringLiteral("失败码两两不重复"), QStringLiteral("全部唯一"),
           clashes.isEmpty() ? QStringLiteral("唯一") : clashes);

    // 状态名：设置页与遥测直接显示这三个词。
    const struct
    {
        RF::State value;
        const char *expected;
    } states[] = {{RF::State::Off, "off"}, {RF::State::Active, "active"}, {RF::State::Degraded, "degraded"}};
    QString stateClashes;
    for (const auto &item : states) {
        const char *name = RF::stateName(item.value);
        const QString label = QStringLiteral("stateName(%1)").arg(QString::fromUtf8(item.expected));
        expect(name != nullptr, label + QStringLiteral(" 不能是空指针"), QStringLiteral("非 nullptr"),
               QStringLiteral("nullptr"));
        if (!name) {
            continue;
        }
        expectText(QString::fromUtf8(name), QString::fromUtf8(item.expected), label);
        expect(std::strcmp(name, RF::stateName(item.value)) == 0, label + QStringLiteral(" 取值稳定"),
               quoted(name), quoted(RF::stateName(item.value)));
        for (const auto &other : states) {
            if (other.value == item.value) {
                continue;
            }
            const char *otherName = RF::stateName(other.value);
            if (otherName && std::strcmp(name, otherName) == 0) {
                stateClashes += QStringLiteral("%1 与 %2 重名；")
                                    .arg(QString::fromUtf8(item.expected), QString::fromUtf8(other.expected));
            }
        }
    }
    expect(stateClashes.isEmpty(), QStringLiteral("三个状态名互不相同"), QStringLiteral("全部唯一"),
           stateClashes.isEmpty() ? QStringLiteral("唯一") : stateClashes);
    return ok;
}

// ---------------------------------------------------------------------------
// 3. 契约自检：SharedContext::valid() / ImageHandoff::valid()
// ---------------------------------------------------------------------------
// 这两个 valid() 是"到底要不要相信宿主句柄"的唯一闸门，边界写错了就会拿 0 句柄去调 Vulkan。
bool runContractBounds()
{
    section(QStringLiteral("3 契约自检：SharedContext/ImageHandoff 的边界"));
    bool ok = true;

    // 全 0：零句柄 → 无效（graphicsFamily 的 0 本身合法，但句柄全 0 说明宿主没填）。
    RF::SharedContext zero;
    expectFalse(zero.valid(), QStringLiteral("零句柄 SharedContext 必须无效"));

    // 逐项缺一个都要无效。
    RF::SharedContext context;
    context.instance = 0x1000;
    expectFalse(context.valid(), QStringLiteral("只有 instance 时必须无效"));
    context.physicalDevice = 0x2000;
    expectFalse(context.valid(), QStringLiteral("缺 device 时必须无效"));
    context.device = 0x3000;
    context.graphicsFamily = 0; // family 0 是合法取值，不能当成"未填"
    expectTrue(context.valid(), QStringLiteral("三个句柄齐全且 family=0 时必须有效"));

    // 0xFFFFFFFF 是"没有图形队列"的哨兵：句柄再全也要判无效，否则会拿着不存在的队列去用。
    RF::SharedContext noFamily = context;
    noFamily.graphicsFamily = 0xFFFFFFFFu;
    expectFalse(noFamily.valid(), QStringLiteral("graphicsFamily=0xFFFFFFFF 时必须无效"));

    // multiview 只影响渲染路径，不参与有效性判定。
    RF::SharedContext multiview = context;
    multiview.multiview = true;
    expectTrue(multiview.valid(), QStringLiteral("multiview=true 不影响有效性"));

    // 图像交接：image/width/height 三件套缺一个都无效；format 与 sampledLayout 不参与判定。
    RF::ImageHandoff handoff;
    expectFalse(handoff.valid(), QStringLiteral("零值 ImageHandoff 必须无效"));
    handoff.image = 0x4000;
    expectFalse(handoff.valid(), QStringLiteral("只有 image 时必须无效"));
    handoff.width = 64;
    expectFalse(handoff.valid(), QStringLiteral("缺 height 时必须无效"));
    handoff.height = 64;
    expectTrue(handoff.valid(), QStringLiteral("image+width+height 齐全时必须有效"));
    expectTrue(handoff.format == 0 && handoff.sampledLayout == 0,
               QStringLiteral("format/sampledLayout 不参与 valid() 判定（此时仍为默认 0）"));
    handoff.format = 97;
    handoff.sampledLayout = 5;
    expectTrue(handoff.valid(), QStringLiteral("填上 format/sampledLayout 后仍有效"));
    handoff.width = 0;
    expectFalse(handoff.valid(), QStringLiteral("width=0 时必须无效"));
    return ok;
}

// ---------------------------------------------------------------------------
// 4. 降级不崩：非法 SharedContext
// ---------------------------------------------------------------------------
// V9 的核心：桥接层拿到一个不合法上下文时必须"失败得干净"——状态进 Degraded、留下具体失败码、
// 让宿主照常走旧链路，而不是崩溃或静默成功。随后的 shutdown()/destroy() 必须可重复调用：
// 退出编排与 rhi 重建都会重复走这段。
bool runDegraded(const QString &assetRoot)
{
    section(QStringLiteral("4 降级不崩：非法 SharedContext"));
    bool ok = true;

    RF::Bridge *bridge = RF::Bridge::create();
    expect(bridge != nullptr, QStringLiteral("Bridge::create() 不需要 GPU 就能返回实例"),
           QStringLiteral("非 nullptr"), QStringLiteral("nullptr"));
    if (!bridge) {
        return false;
    }
    expectText(stateText(bridge->state()), stateText(RF::State::Off),
               QStringLiteral("create() 之后必须是 Off（还没 initialize）"));

    // 全 0 = 零句柄：instance/physicalDevice/device 都是 0，与真实的 QRhi 句柄无关。
    RF::SharedContext empty;
    expectFalse(empty.valid(), QStringLiteral("被测用的空上下文本身必须 valid()==false"));

    const QByteArray root = assetRoot.toUtf8();
    char detail[512] = {};
    const bool initialized = bridge->initialize(empty, root.constData(), detail, sizeof(detail));
    expectFalse(initialized, QStringLiteral("非法上下文 initialize() 必须返回 false"));
    expectText(stateText(bridge->state()), stateText(RF::State::Degraded),
               QStringLiteral("失败后 state() 必须是 Degraded（回旧链路，不是 Active）"));
    expect(bridge->error() == RF::Error::SharedContext,
           QStringLiteral("非法上下文必须报 E_SHARED_CONTEXT（计划 §2.4 的第一站）"),
           errorText(RF::Error::SharedContext), errorText(bridge->error()));
    const char *const text = bridge->detail();
    expect(text != nullptr && text[0] != '\0',
           QStringLiteral("detail() 必须非空（否则 filament-last-error 写不出原因）"),
           QStringLiteral("非空字符串"), quoted(text));
    if (detail[0] != '\0') {
        std::printf("  info detail() = %s\n", qPrintable(QString::fromUtf8(text ? text : "")));
    }

    // 降级期间真实调用链仍会每帧调 resize()/renderFrame()：只要求不崩，不约束返回值
    // （那几帧的输出属于旧链路）。崩溃的话进程直接死在这里。
    RF::FrameGlobals globals{};
    RF::FrameStats stats{};
    bridge->resize(64, 64);
    bridge->renderFrame(globals, nullptr, 0, &stats);
    note(QStringLiteral("降级状态下 resize()/renderFrame() 不崩溃"));

    // 重复关闭必须幂等；destroy(nullptr) 必须是无害的空操作（退出编排里常这么写）。
    bridge->shutdown();
    bridge->shutdown();
    RF::Bridge::destroy(bridge);
    RF::Bridge::destroy(nullptr);
    note(QStringLiteral("降级后 shutdown() 两次 + destroy()/destroy(nullptr) 不崩溃"));
    return ok;
}

#if defined(RHINE_VK_HOST)
/// 宿主侧最小的 Vulkan 设备：等价于真实应用里 QRhi 交给 Filament 的那套句柄。
/// 函数指针一律从加载器动态取——用例因此不需要链接 libvulkan，没装载器的机器直接 SKIP。
struct HostDevice
{
    ~HostDevice() { release(); }

    static void *symbol(void *handle, const char *name)
    {
#if defined(Q_OS_WIN)
        return (void *)::GetProcAddress((HMODULE)handle, name);
#else
        return ::dlsym(handle, name);
#endif
    }

    template <typename Function> bool resolve(Function &out, void *handle, const char *name)
    {
        out = reinterpret_cast<Function>(symbol(handle, name));
        return out != nullptr;
    }

    bool create(QString *why)
    {
        const auto fail = [why](const QString &message) {
            *why = message;
            return false;
        };
#if defined(Q_OS_WIN)
        loader = (void *)::LoadLibraryA("vulkan-1.dll");
#else
        loader = ::dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
        if (!loader) {
            loader = ::dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
        }
#endif
        if (!loader) {
            return fail(QStringLiteral("没有 Vulkan 加载器（libvulkan）"));
        }
        PFN_vkGetInstanceProcAddr getInstanceProc = nullptr;
        if (!resolve(getInstanceProc, loader, "vkGetInstanceProcAddr")) {
            return fail(QStringLiteral("加载器没有导出 vkGetInstanceProcAddr"));
        }

        // 全 0 再填 sType：vulkan.h 的结构体都带 pNext，聚合初始化会触发缺字段告警。
        VkApplicationInfo app{};
        app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app.pApplicationName = "rhine-filament-checks";
        app.applicationVersion = 1;
        app.pEngineName = "none";
        app.engineVersion = 1;
        app.apiVersion = VK_API_VERSION_1_2;
        VkInstanceCreateInfo info{};
        info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        info.pApplicationInfo = &app;

        const auto createInstance =
            reinterpret_cast<PFN_vkCreateInstance>(getInstanceProc(nullptr, "vkCreateInstance"));
        if (!createInstance) {
            return fail(QStringLiteral("取不到 vkCreateInstance"));
        }
        VkInstance created = VK_NULL_HANDLE;
        VkResult result = createInstance(&info, nullptr, &created);
        if (result == VK_ERROR_INCOMPATIBLE_DRIVER) { // 老驱动只认 1.0
            app.apiVersion = VK_API_VERSION_1_0;
            result = createInstance(&info, nullptr, &created);
        }
        if (result != VK_SUCCESS || created == VK_NULL_HANDLE) {
            return fail(QStringLiteral("vkCreateInstance 失败（%1）").arg(int(result)));
        }
        instance = created;

        // 实例建好之后所有核心命令都能从 vkGetInstanceProcAddr 取到（加载器返回跳板）。
        // 销毁函数先取出来，后面任何一步失败都能收尾。
        destroyInstance = reinterpret_cast<PFN_vkDestroyInstance>(getInstanceProc(instance, "vkDestroyInstance"));
        const auto enumerate =
            reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(getInstanceProc(instance, "vkEnumeratePhysicalDevices"));
        const auto properties = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties>(
            getInstanceProc(instance, "vkGetPhysicalDeviceProperties"));
        const auto families = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
            getInstanceProc(instance, "vkGetPhysicalDeviceQueueFamilyProperties"));
        const auto features = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures>(
            getInstanceProc(instance, "vkGetPhysicalDeviceFeatures"));
        const auto createDevice = reinterpret_cast<PFN_vkCreateDevice>(getInstanceProc(instance, "vkCreateDevice"));
        destroyDevice = reinterpret_cast<PFN_vkDestroyDevice>(getInstanceProc(instance, "vkDestroyDevice"));
        if (!enumerate || !properties || !families || !features || !createDevice) {
            return fail(QStringLiteral("取不到设备枚举/创建函数"));
        }

        uint32_t deviceCount = 0;
        if (enumerate(instance, &deviceCount, nullptr) != VK_SUCCESS || deviceCount == 0) {
            return fail(QStringLiteral("没有可用的 Vulkan 物理设备"));
        }
        std::vector<VkPhysicalDevice> devices(deviceCount);
        if (enumerate(instance, &deviceCount, devices.data()) != VK_SUCCESS) {
            return fail(QStringLiteral("枚举物理设备失败"));
        }
        // 取第一台带图形队列族的设备（与 P0 spike 的选法一致）。
        for (uint32_t index = 0; index < deviceCount && physicalDevice == VK_NULL_HANDLE; ++index) {
            VkPhysicalDeviceProperties deviceProperties{};
            properties(devices[index], &deviceProperties);
            uint32_t familyCount = 0;
            families(devices[index], &familyCount, nullptr);
            std::vector<VkQueueFamilyProperties> queueFamilies(familyCount);
            if (familyCount > 0) {
                families(devices[index], &familyCount, queueFamilies.data());
            }
            for (uint32_t family = 0; family < familyCount; ++family) {
                if ((queueFamilies[family].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0) {
                    physicalDevice = devices[index];
                    graphicsFamily = family;
                    name = QString::fromUtf8(deviceProperties.deviceName);
                    break;
                }
            }
        }
        if (physicalDevice == VK_NULL_HANDLE) {
            return fail(QStringLiteral("没有带图形队列族的设备"));
        }

        VkPhysicalDeviceFeatures supported{};
        features(physicalDevice, &supported);
        float priority = 1.0f;
        VkDeviceQueueCreateInfo queue{};
        queue.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue.queueFamilyIndex = graphicsFamily;
        queue.queueCount = 1;
        queue.pQueuePriorities = &priority;
        VkDeviceCreateInfo deviceInfo{};
        deviceInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        deviceInfo.queueCreateInfoCount = 1;
        deviceInfo.pQueueCreateInfos = &queue;
        deviceInfo.pEnabledFeatures = &supported; // 与 P0 spike 相同：把设备支持的特性全开
        VkDevice created_device = VK_NULL_HANDLE;
        result = createDevice(physicalDevice, &deviceInfo, nullptr, &created_device);
        if (result != VK_SUCCESS || created_device == VK_NULL_HANDLE) {
            return fail(QStringLiteral("vkCreateDevice 失败（%1）").arg(int(result)));
        }
        device = created_device;
        return true;
    }

    void release()
    {
        if (device != VK_NULL_HANDLE && destroyDevice) {
            destroyDevice(device, nullptr);
        }
        device = VK_NULL_HANDLE;
        if (instance != VK_NULL_HANDLE && destroyInstance) {
            destroyInstance(instance, nullptr);
        }
        instance = VK_NULL_HANDLE;
        physicalDevice = VK_NULL_HANDLE;
        graphicsFamily = 0xFFFFFFFFu;
        if (loader) {
#if defined(Q_OS_WIN)
            ::FreeLibrary((HMODULE)loader);
#else
            ::dlclose(loader);
#endif
            loader = nullptr;
        }
    }

    /// 填进 SharedContext：句柄一律按指针位宽转成 uint64_t，与 QRhi 侧的做法一致。
    RF::SharedContext sharedContext() const
    {
        RF::SharedContext context;
        context.instance = uint64_t(reinterpret_cast<uintptr_t>(instance));
        context.physicalDevice = uint64_t(reinterpret_cast<uintptr_t>(physicalDevice));
        context.device = uint64_t(reinterpret_cast<uintptr_t>(device));
        context.graphicsFamily = graphicsFamily;
        context.graphicsIndex = 0;
        context.multiview = false;
        return context;
    }

    void *loader = nullptr;
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice physicalDevice = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    uint32_t graphicsFamily = 0xFFFFFFFFu;
    QString name;
    PFN_vkDestroyInstance destroyInstance = nullptr;
    PFN_vkDestroyDevice destroyDevice = nullptr;
};
#endif // RHINE_VK_HOST

// ---------------------------------------------------------------------------
// 5. 渲染交接 + 6. 退出安全（需要真实 Vulkan 设备，可跳过）
// ---------------------------------------------------------------------------
// 交接：宿主建 instance+device → 填 SharedContext → initialize() → resize(64,64) → 渲一帧（零批次 +
// 全屏清色）→ handoff() 必须是"一张合法、尺寸与请求一致、格式恒为 RGBA16F"的宿主图像，Qt 侧才能用
// QRhiTexture::createFrom() 认领（计划 §4.1/§4.2）。
// 退出：成功初始化后 shutdown() 必须先于 VkDevice 销毁，且关完状态落回 Off、重复关闭幂等（T5/V11）。
// 三种情况一律 SKIP 并算通过：编译期没编入 Filament、本机没有可用 Vulkan 设备、资源根里还没有
// .filamat（E_MATERIAL_MISSING 属于"资源没准备好"）。材质存在却装载失败（E_MATERIAL_LOAD）照常判失败。
bool runGpuSequence(const QString &assetRoot)
{
    section(QStringLiteral("5 渲染交接 / 6 退出安全（需要 Vulkan 设备）"));
    if (!RF::compiledIn()) {
        skip(QStringLiteral("编译期未编入 Filament（RHINE_FILAMENT_AVAILABLE=0）"));
        return true;
    }
#if !defined(RHINE_VK_HOST)
    Q_UNUSED(assetRoot);
    skip(QStringLiteral("本平台没有 vulkan.h/动态加载能力（macOS 走 Metal，见计划 §P5）"));
    return true;
#else
    bool ok = true;
    HostDevice host;
    QString why;
    if (!host.create(&why)) {
        skip(QStringLiteral("宿主 Vulkan 设备不可用：%1").arg(why));
        return true;
    }
    std::printf("  info 宿主设备 %s（graphics family %u）\n", qPrintable(host.name), host.graphicsFamily);

    const RF::SharedContext context = host.sharedContext();
    expect(context.valid(), QStringLiteral("宿主填好的 SharedContext 必须 valid()"), QStringLiteral("true"),
           QStringLiteral("false"));

    RF::Bridge *bridge = RF::Bridge::create();
    expect(bridge != nullptr, QStringLiteral("Bridge::create() 必须返回实例"), QStringLiteral("非 nullptr"),
           QStringLiteral("nullptr"));
    if (!bridge) {
        return false;
    }

    const QByteArray root = assetRoot.toUtf8();
    char detail[512] = {};
    if (!bridge->initialize(context, root.constData(), detail, sizeof(detail))) {
        const RF::Error error = bridge->error();
        const QString reason = QStringLiteral("%1（资源根 %2）").arg(errorText(error), assetRoot);
        if (error == RF::Error::MaterialMissing) {
            // P1 还没产出 .filamat 时属于环境没准备好，不能因此判定用例失败。
            skip(QStringLiteral("资源根里没有 .filamat，交接检查跳过：%1").arg(reason));
            bridge->shutdown();
            RF::Bridge::destroy(bridge);
            return true;
        }
        expect(false, QStringLiteral("有 Vulkan 设备时 initialize() 必须成功"), QStringLiteral("true"),
               reason + QStringLiteral(" %1").arg(quoted(detail)));
        bridge->shutdown();
        RF::Bridge::destroy(bridge);
        return false;
    }
    expectText(stateText(bridge->state()), stateText(RF::State::Active),
               QStringLiteral("initialize() 成功后 state() 必须是 Active"));

    // 尺寸变化 → 下一帧重建宿主镜像；交接尺寸必须跟着请求走。
    expectTrue(bridge->resize(64, 64), QStringLiteral("resize(64, 64) 必须成功"));

    // 零批次 + 全屏清色：只验证"帧能跑完、图能交接"，不涉及场景内容。
    RF::FrameGlobals globals{};
    for (int i = 0; i < 16; i += 5) { // 单位矩阵的对角线，避免退化的相机矩阵
        globals.view[i] = 1.0f;
        globals.projection[i] = 1.0f;
        globals.correction[i] = 1.0f;
    }
    globals.background[0] = 0.25f;
    globals.background[1] = 0.5f;
    globals.background[2] = 0.75f;
    globals.viewport[2] = 64.0f;
    globals.viewport[3] = 64.0f;
    globals.lighting = false;
    RF::FrameStats stats{};
    expectTrue(bridge->renderFrame(globals, nullptr, 0, &stats), QStringLiteral("零批次 renderFrame() 必须成功"));

    const RF::ImageHandoff handoff = bridge->handoff();
    expectTrue(handoff.valid(), QStringLiteral("handoff().valid() 必须为真"));
    expectCount(handoff.width, 64u, QStringLiteral("handoff().width 必须等于请求的 64"));
    expectCount(handoff.height, 64u, QStringLiteral("handoff().height 必须等于请求的 64"));
    // 计划 §4.2：宿主颜色图像恒为 VK_FORMAT_R16G16B16A16_SFLOAT（= 97），与 AA 模式无关。
    expectCount(handoff.format, uint32_t(VK_FORMAT_R16G16B16A16_SFLOAT),
                QStringLiteral("handoff().format 必须是 R16G16B16A16_SFLOAT"));
    expect(handoff.image != 0, QStringLiteral("handoff().image 必须非 0（createFrom 要用它）"),
           QStringLiteral("非 0"), QStringLiteral("0"));
    std::printf("  info handoff: image=0x%llx format=%u %ux%u layout=%u\n",
                (unsigned long long)handoff.image, handoff.format, handoff.width, handoff.height,
                handoff.sampledLayout);

    // 退出安全：shutdown() 必须在宿主 VkDevice 销毁之前把 Filament 的 Engine 放掉（T5）。
    bridge->shutdown();
    expectText(stateText(bridge->state()), stateText(RF::State::Off),
               QStringLiteral("shutdown() 之后 state() 必须是 Off"));
    bridge->shutdown(); // 退出编排与 rhi 重建都会重复调用，必须幂等
    RF::Bridge::destroy(bridge);
    note(QStringLiteral("initialize 成功后 shutdown() 两次 + destroy() 不崩溃"));
    // host 的析构函数在这里释放 VkDevice/VkInstance，顺序必须在 Filament 关闭之后。
    return ok;
#endif
}

/// 资源根：命令行 > 环境变量 > 源码树里的着色器目录（相对构建目录）。
QString resolveAssetRoot(int argc, char **argv)
{
    if (argc > 1 && argv[1] && argv[1][0] != '\0') {
        return QString::fromLocal8Bit(argv[1]);
    }
    const QByteArray fromEnvironment = qgetenv("RHINE_FILAMENT_ASSET_ROOT");
    if (!fromEnvironment.isEmpty()) {
        return QString::fromLocal8Bit(fromEnvironment);
    }
    return QStringLiteral("Qt/shaders/filament");
}

} // namespace

int main(int argc, char **argv)
{
    const QString assetRoot = resolveAssetRoot(argc, argv);
    std::printf("FilamentChecks: compiledIn()=%s，资源根 %s\n", RF::compiledIn() ? "true" : "false",
                qPrintable(assetRoot));

    bool ok = true;
    ok &= runSwitchMatrix();
    ok &= runErrorCodes();
    ok &= runContractBounds();
    ok &= runDegraded(assetRoot);
    ok &= runGpuSequence(assetRoot);

    std::printf("\nFilamentChecks: %d 项检查，%d 项失败，%d 组跳过\n", g_checks, g_failures, g_skips);
    return (ok && g_failures == 0) ? 0 : 1;
}
