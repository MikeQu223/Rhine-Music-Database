#include <QtGlobal>
// 帧生成的落地条件里有一半是"没有 GPU 也能测"的纯逻辑：环境变量解析、
// 能力快照的刷新语义、设置页三态判定、以及场景到 FG 的帧输入投递。
// 这个用例把这一半钉住，免得以后改门控时把"该置灰的放开了"或"该生效的灰掉了"。
#include "fg/FgCapability.h"
#include "fg/FgConfig.h"
#include "fg/FgFrameTap.h"
#include "fg/FgStats.h"

#include <QByteArray>
#include <QPointF>
#include <QSize>
#include <QVector>
#include <cstdio>

namespace {

bool check(bool result, const char *message)
{
    if (!result) {
        std::fprintf(stderr, "%s\n", message);
    }
    return result;
}

/// 环境变量类用例跑完要还原，否则同一进程里后面的用例会读到上一条的状态。
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

bool parsesBooleans()
{
    bool ok = true;
    EnvGuard guard("RHINE_FG");
    const QVector<QPair<QByteArray, bool>> cases{
        {"on", true},    {"ON", true},     {"1", true},      {"true", true},
        {"yes", true},   {" on ", true},   {"off", false},   {"0", false},
        {"false", false}, {"no", false},   {"", false},      {"随便写点什么", false},
    };
    for (const auto &item : cases) {
        if (item.first.isEmpty()) {
            qunsetenv("RHINE_FG");
        } else {
            qputenv("RHINE_FG", item.first);
        }
        const auto config = FgConfig::fromEnvironment();
        ok &= check(config.enabled == item.second, "RHINE_FG 的布尔解析和约定不一致");
        ok &= check(config.valid() == item.second, "valid() 必须跟 enabled 一致");
    }
    // 默认值：没设环境变量时必须是关的——FG 没接呈现层的构建默认打开只会黑屏。
    qunsetenv("RHINE_FG");
    ok &= check(!FgConfig::fromEnvironment().enabled, "没设 RHINE_FG 时帧生成必须默认关闭");
    return ok;
}

#ifdef Q_OS_DARWIN
/** 覆盖 Metal 两条呈现路径共用的默认值、覆盖优先级和非法值回退。 */
bool metalPresentationConfiguration() {
    EnvGuard primary("RHINE_VSYNC");
    EnvGuard legacy("RHINE_FG_VSYNC");
    bool ok = true;
    qunsetenv("RHINE_VSYNC");
    qunsetenv("RHINE_FG_VSYNC");
    ok &= check(RhineFg::metalVSyncEnabled(), "Metal 默认必须同步呈现");
    qputenv("RHINE_FG_VSYNC", "off");
    ok &= check(!RhineFg::metalVSyncEnabled(), "兼容已有排障覆盖值");
    qputenv("RHINE_VSYNC", "on");
    ok &= check(RhineFg::metalVSyncEnabled(), "主变量开启必须优先于旧变量关闭");
    qputenv("RHINE_FG_VSYNC", "on");
    qputenv("RHINE_VSYNC", "off");
    ok &= check(!RhineFg::metalVSyncEnabled(), "主变量关闭必须优先于旧变量开启");
#ifdef Q_OS_DARWIN
    ok &= check(!FgConfig::fromEnvironment().vsync, "自建宿主必须采用相同的主变量优先级");
#endif
    qputenv("RHINE_FG_VSYNC", "off");
    qputenv("RHINE_VSYNC", "invalid");
    ok &= check(!RhineFg::metalVSyncEnabled(), "非法主变量应回退兼容变量");
    qunsetenv("RHINE_FG_VSYNC");
    ok &= check(RhineFg::metalVSyncEnabled(), "全部无效时应回退同步默认值");
    return ok;
}
#endif

/// 设置页开关 → 环境变量 → 解析结果，这条链就是"点一下立刻生效"的全部依据。
bool preferenceReachesConfig()
{
    bool ok = true;
    EnvGuard guard("RHINE_FG");
    qunsetenv("RHINE_FG");

    // 打开：偏好写 "on" 之后，呈现层每帧读到的配置必须是开的。
    RhineFg::applyInterpolationPreference(QStringLiteral("on"));
    ok &= check(qgetenv("RHINE_FG") == "on", "偏好 on 必须同步成 RHINE_FG=on");
    ok &= check(FgConfig::fromEnvironment().enabled, "偏好 on 之后解析结果必须是开启");

    // 关闭：任何非 "on" 的值都要落成 off，不能让脏值把插值留在开的状态。
    RhineFg::applyInterpolationPreference(QStringLiteral("off"));
    ok &= check(qgetenv("RHINE_FG") == "off", "偏好 off 必须同步成 RHINE_FG=off");
    ok &= check(!FgConfig::fromEnvironment().enabled, "偏好 off 之后解析结果必须是关闭");
    RhineFg::applyInterpolationPreference(QStringLiteral("乱七八糟"));
    ok &= check(qgetenv("RHINE_FG") == "off", "非法偏好必须退化成 off");
    ok &= check(!FgConfig::fromEnvironment().enabled, "非法偏好不好让插值保持开启");
    return ok;
}

bool keepsCameraDefaults()
{
    const FgConfig config;
    bool ok = true;
    // 默认值取的是 Rhine 场景真实量级（NativeSceneCamera 的 near/far），
    // 写成 SDK 样例的 0.1/5000 会让去遮挡掩码整体偏掉。
    ok &= check(config.nearPlane == 5.0f, "近平面默认值必须跟场景一致");
    ok &= check(config.farPlane == 300.0f, "远平面默认值必须跟场景一致");
    ok &= check(config.vsync, "呈现层默认应该开垂直同步");
    ok &= check(config.deferredPresent, "呈现默认应该推迟到下一次 acquire 之前");
    return ok;
}

bool snapshotLifecycle()
{
    bool ok = true;
    RhineFg::publishCapability(false, false, false, QStringLiteral("未编入"));
    ok &= check(!RhineFg::capability().compiledIn, "快照应记住 compiledIn=false");
    ok &= check(RhineFg::capability().reason == QStringLiteral("未编入"), "快照应保留原因");

    // publishActive 意味着"呈现层接管了"，此时 compiledIn 一定是 true。
    RhineFg::publishActive(false);
    ok &= check(RhineFg::capability().presentLayerActive, "publishActive 必须置位呈现层");
    ok &= check(RhineFg::capability().compiledIn, "呈现层接管时必然已编入");
    ok &= check(!RhineFg::capability().interpolationAvailable, "插值可用性要单独传入");
    ok &= check(RhineFg::capability().reason.isEmpty(), "可用时不该留原因");

    // publishInactive 只改"没接管"，不能把 compiledIn 抹掉——否则回退后
    // 设置页会同时失去"重启生效"这个可点击状态。
    // 运行期插值降级只该改插值可用性，呈现层必须继续算"已接管"——
    // 合成还在跑，只是没有补偿帧，设置页不该因此把整层判死。
    RhineFg::publishInterpolationState(false, QStringLiteral("ffxFrameInterpolationDispatch 失败"));
    ok &= check(RhineFg::capability().presentLayerActive, "插值降级不该取消呈现层接管");
    ok &= check(!RhineFg::capability().interpolationAvailable, "插值降级应置 false");
    ok &= check(RhineFg::capability().reason == QStringLiteral("ffxFrameInterpolationDispatch 失败"),
                "插值降级应记录原因");
    RhineFg::publishInterpolationState(true);
    ok &= check(RhineFg::capability().interpolationAvailable && RhineFg::capability().reason.isEmpty(),
                "恢复可用后原因应清空");

    RhineFg::publishInactive(QStringLiteral("交换链创建失败"));
    ok &= check(!RhineFg::capability().presentLayerActive, "回退后呈现层应为未接管");
    ok &= check(RhineFg::capability().compiledIn, "回退不该改变是否编入");
    ok &= check(RhineFg::capability().reason == QStringLiteral("交换链创建失败"),
                "回退后应记录失败原因");
    RhineFg::publishCapability(true, false, false);
    return ok;
}

bool settingsRowStates()
{
    using RhineFg::frameGenerationUi;
    bool ok = true;

    // 1. 没编入：置灰，文案就是原因。
    auto ui = frameGenerationUi(false, false, false, QStringLiteral("此构建未编入 Vulkan 帧生成"),
                                true, true);
    ok &= check(!ui.clickable, "没编入时不能点");
    ok &= check(ui.value == QStringLiteral("此构建未编入 Vulkan 帧生成"), "没编入应展示原因");
    ui = frameGenerationUi(false, false, false, QString(), true, false);
    ok &= check(!ui.clickable, "没编入且无原因时也不能点");
    ok &= check(ui.value == QStringLiteral("此构建未编入"), "没编入应给出兜底文案");

    // 2. 编入了但当前图形后端跑不了。
    ui = frameGenerationUi(true, false, false, QString(), false, true);
    ok &= check(!ui.clickable, "opengl 后端不能点");
    ok &= check(ui.value == QStringLiteral("当前图形后端不支持"), "opengl 后端应写明原因");

    // 3. 呈现层已接管、插值可用：可点，且文案随偏好变化（热切换）。
    ui = frameGenerationUi(true, true, true, QString(), true, true);
    ok &= check(ui.clickable, "接管后应可点");
    ok &= check(ui.value == QStringLiteral("开启"), "偏好开启时应显示开启");
    ui = frameGenerationUi(true, true, true, QString(), true, false);
    ok &= check(ui.clickable && ui.value == QStringLiteral("关闭"), "偏好关闭时应显示关闭");

    // 4. 接管了但插值不可用（上下文没建起来）：置灰，不能假装点了有用。
    ui = frameGenerationUi(true, true, false, QString(), true, true);
    ok &= check(!ui.clickable, "接管但插值不可用时不能点");
    ok &= check(ui.value == QStringLiteral("插值暂不可用"), "此时应给出兜底说明");
    // 4b. 同上，但降级时留下了原因：原因优先展示，用户才知道为什么灰。
    ui = frameGenerationUi(true, true, false, QStringLiteral("交换链图像格式不支持"), true, true);
    ok &= check(!ui.clickable, "降级且带原因时不能点");
    ok &= check(ui.value == QStringLiteral("交换链图像格式不支持"), "降级应展示真实原因");

#ifdef Q_OS_LINUX
    // 5. 能力齐备但本次进程没接管呈现层 —— 这是**正常状态**：fg=off 启动时呈现层
    //    本来就不接管（Qt 默认路径的内容帧实测高 35%）。此时必须可点，否则开关永远打不开。
#else
    // 5. 能力齐备却没接管（RHINE_FG_LAYER=off）：置灰，不误导用户去写偏好。
#endif
    ui = frameGenerationUi(true, false, false, QString(), true, false);
#ifdef Q_OS_LINUX
    ok &= check(ui.clickable, "偏好为关且未接管时必须仍可点开");
    ok &= check(ui.value == QStringLiteral("关闭"), "偏好为关时显示关闭");

    // 5b. 偏好已开但本次启动没接管：可点（允许改回去），并提示重启才生效。
    ui = frameGenerationUi(true, false, false, QString(), true, true);
    ok &= check(ui.clickable, "偏好为开但未接管时仍应可点");
    ok &= check(ui.value == QStringLiteral("已开启 · 重启生效"), "应提示重启生效");
#else
    ok &= check(!ui.clickable, "没接管时不能点");
    ok &= check(ui.value == QStringLiteral("呈现层未接管"), "没接管应写明状态");
#endif

    // 6. 接管失败留下原因：置灰并把原因显示出来。
    ui = frameGenerationUi(true, false, false, QStringLiteral("交换链创建失败"), true, true);
    ok &= check(!ui.clickable, "接管失败时不能点");
    ok &= check(ui.value == QStringLiteral("交换链创建失败"), "接管失败应展示原因");
    return ok;
}

bool frameTapGating()
{
    bool ok = true;
    RhineFg::FrameInputs inputs;
    inputs.renderSize = QSize(640, 360);
    inputs.displaySize = QSize(1280, 720);
    inputs.nearPlane = 5.0f;
    inputs.farPlane = 300.0f;
    inputs.fovYRadians = 0.9f;
    inputs.jitter = QPointF(0.25, -0.25);

    // 关掉的时候投递必须是空转：默认路径下根本不建 FgBackend，白存一份指针没意义。
    RhineFg::setEnabled(false);
    const auto serialBefore = RhineFg::latestSerial();
    RhineFg::publish(inputs);
    ok &= check(RhineFg::latestSerial() == serialBefore, "tap 关闭时不该推进 serial");
    ok &= check(RhineFg::latest().depth == nullptr, "tap 关闭时不该保留输入");

    // 打开之后投递才是实打实的，并且每次 publish 都换一个新序号——
    // FgShell 靠 serial 不变来判断"场景没有重渲，别重建上下文"。
    RhineFg::setEnabled(true);
    RhineFg::publish(inputs);
    const auto serialAfterFirst = RhineFg::latestSerial();
    ok &= check(serialAfterFirst != serialBefore, "tap 打开后 publish 必须推进 serial");
    ok &= check(RhineFg::latest().renderSize == QSize(640, 360), "renderSize 应被保留");
    ok &= check(RhineFg::latest().displaySize == QSize(1280, 720), "displaySize 应被保留");
    ok &= check(RhineFg::latest().jitter == QPointF(0.25, -0.25), "抖动应被保留");
    RhineFg::publish(inputs);
    ok &= check(RhineFg::latestSerial() != serialAfterFirst, "连续 publish 的 serial 必须递增");

    RhineFg::setEnabled(false);
    return ok;
}

bool statsChannel()
{
    bool ok = true;
    RhineFg::Stats sample;
    sample.layerActive = true;
    sample.interpolationWanted = true;
    sample.interpolationActive = true;
    sample.interpolationAvailable = true;
    sample.presented = 120;
    sample.interpolated = 60;
    sample.rendered = 60;
    sample.prepareMs = 0.8;
    sample.dispatchMs = 3.1;
    sample.presentMs = 0.12;
    sample.swapchainImages = 5;
    sample.swapchainFormat = QStringLiteral("B8G8R8A8_UNORM");
    sample.renderSize = QSize(1262, 1370);
    sample.depthReady = true;

    RhineFg::publish(sample);
    const auto published = RhineFg::stats();
    ok &= check(published.layerActive && published.interpolationActive, "发布后应能读到标志位");
    ok &= check(published.presented == 120 && published.interpolated == 60 && published.rendered == 60,
                "累计计数必须原样带出去（面板靠差值算 FPS）");
    ok &= check(published.prepareMs == 0.8 && published.dispatchMs == 3.1, "分项耗时必须原样带出去");
    ok &= check(published.swapchainImages == 5
                    && published.swapchainFormat == QStringLiteral("B8G8R8A8_UNORM"),
                "交换链信息必须原样带出去");
    ok &= check(published.renderSize == QSize(1262, 1370), "渲染尺寸必须原样带出去");
    ok &= check(published.serial > 0, "publish 必须推进 serial");

    // serial 单调递增是"面板能判断数据是否还在更新"的唯一依据。
    const auto firstSerial = published.serial;
    RhineFg::publish(sample);
    ok &= check(RhineFg::stats().serial == firstSerial + 1, "每次 publish 的 serial 必须自增");

    // 呈现层退出后必须清场：否则面板会继续显示上一轮的数字，看起来像还在跑。
    RhineFg::clear();
    const auto cleared = RhineFg::stats();
    ok &= check(!cleared.layerActive && cleared.presented == 0, "clear 之后不该残留任何统计");
    ok &= check(cleared.serial > firstSerial + 1, "clear 也要推进 serial");
    return ok;
}

} // namespace

int main()
{
    bool ok = true;
    ok &= parsesBooleans();
#ifdef Q_OS_DARWIN
    ok &= metalPresentationConfiguration();
#endif
    ok &= keepsCameraDefaults();
    ok &= preferenceReachesConfig();
    ok &= snapshotLifecycle();
    ok &= settingsRowStates();
    ok &= frameTapGating();
    ok &= statsChannel();
    return ok ? 0 : 1;
}
