#include "SettingsSchema.h"
#include "GraphicsBackend.h"
#include "Host.h"
#include "MusicLibrary.h"
#include "MusicPlayer.h"
#include "PlatformFeatures.h"
#include "fg/FgCapability.h"
#include <QHash>
#include <QSet>
#include <algorithm>
#include <cmath>
#include <iterator>

namespace SettingsSchema {
namespace {
constexpr const char *On = "on";
constexpr const char *Off = "off";

QVector<SettingChoice> onOffChoices() {
    return {{Off, QStringLiteral("关闭")}, {On, QStringLiteral("开启")}};
}

QVector<SettingChoice> themeChoices() {
    return {{"light", QStringLiteral("亮色")},
            {"dark", QStringLiteral("暗色")},
            {"system", QStringLiteral("跟随系统")}};
}

QVector<SettingChoice> motionChoices() {
    return {{"full", QStringLiteral("完整动效")}, {"reduced", QStringLiteral("减少动效")}};
}

QVector<SettingChoice> trayQuitChoices() {
    return {{"quit", QStringLiteral("退出播放器")}, {"tray", QStringLiteral("最小化到托盘")}};
}

QVector<SettingChoice> appendReplaceChoices() {
    return {{"replace", QStringLiteral("替换为所在列表")}, {"append", QStringLiteral("仅添加当前单曲")}};
}

QVector<SettingChoice> alternativeChoices() {
    return {{Off, QStringLiteral("关闭（使用平台默认音质）")},
            {On, QStringLiteral("开启（音质由来源决定）")}};
}

QVector<SettingChoice> fsrChoices() {
    return {{"native", QStringLiteral("原生 AA")},
            {"quality", QStringLiteral("高质量")},
            {"balanced", QStringLiteral("平衡")},
            {"performance", QStringLiteral("性能")},
            {"super", QStringLiteral("超级性能")}};
}

bool alwaysVisible(const SettingsContext &) {
    return true;
}

bool desktopWindowVisible(const SettingsContext &) {
    return PlatformFeatures::DesktopWindowControls;
}

bool closeVisible(const SettingsContext &) {
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
    return true;
#else
    return false;
#endif
}

bool qualityVisible(const SettingsContext &context) {
    return context.music && !context.music->isLocal();
}

bool alternativeVisible(const SettingsContext &context) {
    return context.music && !context.music->isLocal() && context.music->provider == "netease";
}

bool officialVisible(const SettingsContext &context) {
    return PlatformFeatures::OfficialPlayback && context.music && !context.music->isLocal();
}

bool vsyncVisible(const SettingsContext &) {
#if defined(Q_OS_DARWIN)
    return false;
#else
    return true;
#endif
}

bool gpuVisible(const SettingsContext &) {
#if defined(Q_OS_LINUX)
    return RhineGraphics::gpuDeviceCount() > 1;
#else
    return false;
#endif
}

bool graphicsEnabled(const SettingsContext &) {
#if defined(Q_OS_DARWIN)
    return false;
#else
    return true;
#endif
}

QString aaMode(const SettingsContext &context) {
    return context.host ? context.host->preference("aa-mode") : QString();
}

bool nonDarwinVisible(const SettingsContext &) {
#if defined(Q_OS_DARWIN)
    return false;
#else
    return true;
#endif
}

bool aaScaleVisible(const SettingsContext &context) {
    return nonDarwinVisible(context) && aaMode(context) == "ssaa";
}

bool msaaVisible(const SettingsContext &context) {
    return nonDarwinVisible(context) && aaMode(context) == "msaa";
}

bool fsrVisible(const SettingsContext &context) {
    const auto mode = aaMode(context);
    return nonDarwinVisible(context) && (mode == "fsr" || mode == "fsr1" || mode == "fsr3");
}

bool aaEnabled(const SettingsContext &) {
#if defined(Q_OS_DARWIN)
    return RhineFg::capability().temporalAvailable;
#else
    return true;
#endif
}

// 关闭帧生成
#if 0
RhineFg::FrameGenerationUi frameGenerationState(const SettingsContext &context) {
    const bool preferenceOn = context.host && context.host->preference("fg") == On;
    const auto &capability = RhineFg::capability();
    const auto active = RhineGraphics::activeBackend();
    const bool backendCapable = active.isEmpty()
                                    ? context.host && context.host->preference("graphics-backend") != "opengl"
                                    : active == QLatin1String("vulkan")
#ifdef Q_OS_DARWIN
                                          || active == QLatin1String("metal")
#endif
        ;
    return RhineFg::frameGenerationUi(capability.compiledIn, capability.presentLayerActive,
                                      capability.interpolationAvailable, capability.reason, backendCapable,
                                      preferenceOn);
}

bool fgEnabled(const SettingsContext &context) {
    return frameGenerationState(context).clickable;
}
#endif

QVector<SettingChoice> qualityChoices(const SettingsContext &context) {
    QVector<SettingChoice> values;
    if (!context.music) {
        return values;
    }
    for (const auto &option : MusicPlayer::qualityOptions(context.music->provider)) {
        values.append({option.first, option.second});
    }
    return values;
}

QVector<SettingChoice> graphicsChoices(const SettingsContext &) {
#if defined(Q_OS_DARWIN)
    // macOS 只有 Metal 后端；不再暴露 Vulkan/OpenGL 等无效选项。
    return {{"metal", "Metal"}};
#else
    QVector<SettingChoice> values{
        {"", QStringLiteral("默认 / 自动探测")}, {"vulkan", "Vulkan"}, {"opengl", "OpenGL"}};
#if RHINE_ENABLE_D3D12_BACKEND
    values.append({"d3d12", "Direct3D 12"});
#endif
    return values;
#endif
}

QVector<SettingChoice> gpuChoices(const SettingsContext &) {
    QVector<SettingChoice> values{{"", QStringLiteral("默认")}};
    for (int index = 0; index < RhineGraphics::gpuDeviceCount(); ++index) {
        values.append({QString::number(index), QStringLiteral("显卡 ") + QString::number(index)});
    }
    return values;
}

QVector<SettingChoice> aaChoices(const SettingsContext &) {
#if defined(Q_OS_DARWIN)
    return {{"off", QStringLiteral("关闭")}, {"metalfx", "MetalFX Temporal"}};
#else
    return {{"off", QStringLiteral("关闭")},
            {"fxaa", "FXAA"},
            {"ssaa", "SSAA"},
            {"msaa", "MSAA"},
            {"taa", "TAA"},
            {"fsr", "FSR"}};
#endif
}

QString themeLabel(const SettingsContext &, const SettingsValue &value) {
    for (const auto &choice : themeChoices()) {
        if (choice.value == value.canonical) {
            return choice.label;
        }
    }
    return value.canonical;
}

QString archiveMaskLabel(const SettingsContext &, const SettingsValue &value) {
    return value.integer == 0 ? QStringLiteral("0 · 关闭") : QString::number(value.integer) + "%";
}

QString renderScaleLabel(const SettingsContext &, const SettingsValue &value) {
    return value.integer == 100 ? QStringLiteral("100% · 原生") : QString::number(value.integer) + "%";
}

QString percentLabel(const SettingsContext &, const SettingsValue &value) {
    return QString::number(value.integer) + "%";
}

QString msaaLabel(const SettingsContext &, const SettingsValue &value) {
    return QString::number(value.integer) + "x";
}

QString graphicsBackendLabel(const SettingsContext &context) {
#if defined(Q_OS_DARWIN)
    Q_UNUSED(context);
    return QStringLiteral("Metal");
#else
    const auto saved = context.host ? context.host->preference("graphics-backend") : QString();
    static const QHash<QString, QString> names{
        {"vulkan", "Vulkan"}, {"opengl", "OpenGL"}, {"d3d12", "Direct3D 12"}};
    const auto pending = saved.isEmpty() ? QStringLiteral("默认 / 自动探测") : names.value(saved, saved);
    const auto applied = RhineGraphics::activeBackend();
    if (applied.isEmpty()) {
        return pending;
    }
    const auto appliedName = names.value(applied, applied);
    if (saved.isEmpty()) {
        return appliedName + QStringLiteral("（自动）");
    }
    if (applied != saved) {
        return appliedName + QStringLiteral("（下次启动：") + pending + QStringLiteral("）");
    }
    return appliedName;
#endif
}

QString gpuIndexLabel(const SettingsContext &context) {
    const auto saved = context.host ? context.host->preference("gpu-index").trimmed() : QString();
    bool numeric = false;
    const auto index = saved.toInt(&numeric);
    if (numeric && index >= 0 && index < RhineGraphics::gpuDeviceCount()) {
        return QStringLiteral("显卡 ") + QString::number(index);
    }
    if (!saved.isEmpty()) {
        return QStringLiteral("默认（序号 ") + saved + QStringLiteral(" 不存在）");
    }
    if (RhineGraphics::gpuAppliedIndex() >= 0) {
        return QStringLiteral("显卡 ") + QString::number(RhineGraphics::gpuAppliedIndex()) +
               QStringLiteral("（RHINE_GPU_INDEX）");
    }
    return QStringLiteral("默认");
}

QString aaModeLabel(const SettingsContext &context, const SettingsValue &value) {
#if defined(Q_OS_DARWIN)
    if (!aaEnabled(context)) {
        return QStringLiteral("系统或设备不支持");
    }
#endif
    for (const auto &choice : aaChoices(context)) {
        if (choice.value == value.canonical) {
            return choice.label;
        }
    }
    return value.canonical;
}

// 关闭帧生成
#if 0
QString fgLabel(const SettingsContext &context, const SettingsValue &) {
    return frameGenerationState(context).value;
}
#endif

QString choiceLabel(const SettingDescriptor &descriptor, const SettingsContext &context,
                    const SettingsValue &value) {
    if (descriptor.label) {
        return descriptor.label(context, value);
    }
    for (const auto &choice : choices(descriptor, context)) {
        if (choice.value == value.canonical) {
            return choice.label;
        }
    }
    return value.canonical;
}

QString descriptorAction(const SettingDescriptor &descriptor) {
    return descriptor.binding.actionPrefix.isEmpty() ? descriptor.binding.action
                                                     : descriptor.binding.actionPrefix;
}

QString defaultFor(const SettingDescriptor &descriptor, const QString &fallback) {
    return descriptor.defaultValue.isEmpty() ? fallback : descriptor.defaultValue;
}

QString nearestStep(const QVector<int> &steps, int value) {
    if (steps.isEmpty()) {
        return QString::number(value);
    }
    auto nearest = steps.first();
    for (const auto step : steps) {
        if (std::abs(step - value) < std::abs(nearest - value)) {
            nearest = step;
        }
    }
    return QString::number(nearest);
}
}

const QVector<SettingDescriptor> &descriptors() {
    static const QVector<SettingDescriptor> values = [] {
        QVector<SettingDescriptor> list;
        auto add = [&list](SettingDescriptor descriptor) { list.append(std::move(descriptor)); };

        add({.id = "window",
             .section = SectionId::Preferences,
             .kind = SettingKind::Action,
             .binding = {.kind = BindingKind::Action, .action = "window:fullscreen"},
             .storage = StorageType::None,
             .order = 100,
             .titleEn = "WINDOW",
             .titleZh = "窗口显示",
             .actionLabel = "切换全屏 / F11",
             .visible = desktopWindowVisible});
        add({.id = "close-behavior",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::Preference,
                         .preferenceKey = "close-behavior",
                         .action = "close-behavior",
                         .actionPrefix = "setting:close-behavior:"},
             .storage = StorageType::TrayQuit,
             .order = 110,
             .titleEn = "CLOSE WINDOW",
             .titleZh = "点击关闭窗口",
             .defaultValue = "quit",
             .choices = trayQuitChoices(),
             .visible = closeVisible});
        add({.id = "theme",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::HudState, .action = "theme", .actionPrefix = "setting:theme:"},
             .storage = StorageType::Theme,
             .order = 120,
             .titleEn = "COLOR THEME",
             .titleZh = "界面配色",
             .defaultValue = "light",
             .choices = themeChoices(),
             .label = themeLabel});
        add({.id = "motion",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::HudState,
                         .action = "motion",
                         .actionPrefix = "setting:motion:"},
             .storage = StorageType::ReducedFull,
             .order = 130,
             .titleEn = "REDUCED MOTION",
             .titleZh = "动态效果",
             .defaultValue = "full",
             .choices = motionChoices()});
        add({.id = "startup-animation",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::HudState,
                         .action = "startup-animation",
                         .actionPrefix = "setting:startup-animation:"},
             .storage = StorageType::OnOff,
             .order = 140,
             .titleEn = "STARTUP ANIMATION",
             .titleZh = "初始化动画",
             .defaultValue = Off,
             .choices = onOffChoices()});
        add({.id = "replay",
             .section = SectionId::Preferences,
             .kind = SettingKind::Action,
             .binding = {.kind = BindingKind::Action, .action = "replay"},
             .storage = StorageType::None,
             .order = 150,
             .titleEn = "INITIALIZATION",
             .titleZh = "手动显示初始化页面",
             .actionLabel = "Reinitialize"});
        add({.id = "quality",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::Player, .action = "quality", .actionPrefix = "quality:set:"},
             .storage = StorageType::PlayerQuality,
             .order = 160,
             .titleEn = "AUDIO QUALITY",
             .titleZh = "音质",
             .defaultValue = "exhigh",
             .choicesFor = qualityChoices,
             .visible = qualityVisible});
        add({.id = "alternative",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::Player,
                         .action = "alternative",
                         .actionPrefix = "setting:alternative:"},
             .storage = StorageType::PlayerAlternative,
             .order = 170,
             .titleEn = "ALTERNATE SOURCE",
             .titleZh = "替代音源",
             .defaultValue = Off,
             .choices = alternativeChoices(),
             .visible = alternativeVisible});
        add({.id = "official-player",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::External,
                         .action = "music:activate",
                         .actionPrefix = "setting:official-player:"},
             .storage = StorageType::ExternalBool,
             .order = 180,
             .titleEn = "OFFICIAL PLAYER",
             .titleZh = "官方窗口",
             .defaultValue = Off,
             .choices = {{Off, QStringLiteral("尽量保持后台")}, {On, QStringLiteral("播放时显示")}},
             .visible = officialVisible});
        add({.id = "detail-autoplay",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::Preference,
                         .preferenceKey = "detail-autoplay",
                         .action = "detail-autoplay",
                         .actionPrefix = "setting:detail-autoplay:"},
             .storage = StorageType::OnOff,
             .order = 190,
             .titleEn = "ENTER AUTOPLAY",
             .titleZh = "进入详情自动播放",
             .defaultValue = Off,
             .choices = onOffChoices()});
        add({.id = "single-play-mode",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::Preference,
                         .preferenceKey = "single-play-mode",
                         .action = "single-play-mode",
                         .actionPrefix = "setting:single-play-mode:"},
             .storage = StorageType::AppendReplace,
             .order = 200,
             .titleEn = "PLAYLIST ON PLAY",
             .titleZh = "点击播放单曲",
             .defaultValue = "replace",
             .choices = appendReplaceChoices()});
        add({.id = "archive-mask",
             .section = SectionId::Preferences,
             .kind = SettingKind::Stepper,
             .binding = {.kind = BindingKind::HudState, .actionPrefix = "archive-mask:"},
             .storage = StorageType::HudCachedInt,
             .order = 210,
             .titleEn = "RIGHT MASK",
             .titleZh = "右侧画面遮罩",
             .defaultValue = "50",
             .minimum = 0,
             .maximum = 100,
             .step = 10,
             .label = archiveMaskLabel});
        add({.id = "graphics-backend",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::Preference,
                         .preferenceKey = "graphics-backend",
                         .action = "graphics-backend",
                         .actionPrefix = "setting:graphics-backend:"},
             .storage = StorageType::Enum,
             .order = 220,
#if defined(Q_OS_DARWIN)
             .titleEn = "METAL RENDERER",
             .titleZh = "渲染模式",
#else
             .titleEn = "GRAPHICS BACKEND",
             .titleZh = "图形后端",
             .restartHint = QStringLiteral("重启生效"),
#endif
             .choicesFor = graphicsChoices,
             .enabled = graphicsEnabled,
             .label = [](const SettingsContext &context, const SettingsValue &) {
                 return graphicsBackendLabel(context);
             }});
        add({.id = "gpu-index",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::Preference,
                         .preferenceKey = "gpu-index",
                         .actionPrefix = "gpu-index:"},
             .storage = StorageType::Enum,
             .order = 230,
             .titleEn = "GPU",
             .titleZh = "显卡",
             .restartHint = QStringLiteral("重启生效"),
             .choicesFor = gpuChoices,
             .visible = gpuVisible,
             .label = [](const SettingsContext &context, const SettingsValue &) {
                 return gpuIndexLabel(context);
             }});
        add({.id = "vsync",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::HudState, .action = "vsync", .actionPrefix = "setting:vsync:"},
             .storage = StorageType::HudCachedBool,
             .order = 240,
             .titleEn = "V-SYNC",
             .titleZh = "垂直同步",
             .restartHint = QStringLiteral("重启生效"),
             .defaultValue = On,
             .choices = onOffChoices(),
             .visible = vsyncVisible});
        add({.id = "render-scale",
             .section = SectionId::Preferences,
             .kind = SettingKind::Stepper,
             .binding = {.kind = BindingKind::Preference,
                         .preferenceKey = "render-scale",
                         .actionPrefix = "render-scale:"},
             .storage = StorageType::Integer,
             .order = 250,
             .titleEn = "RENDER SCALE",
             .titleZh = "渲染分辨率",
             .defaultValue = "100",
             .steps = {50, 60, 75, 90, 100},
             .label = renderScaleLabel});
        add({.id = "aa-mode",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::Preference,
                         .preferenceKey = "aa-mode",
                         .actionPrefix = "aa-mode:"},
             .storage = StorageType::Enum,
             .order = 260,
#if defined(Q_OS_DARWIN)
             .titleEn = "METALFX",
             .titleZh = "时域抗锯齿与超分辨率",
#else
             .titleEn = "AA & UPSCALING",
             .titleZh = "抗锯齿与超分辨率",
#endif
             .defaultValue = "off",
             .choicesFor = aaChoices,
             .enabled = aaEnabled,
             .label = aaModeLabel});
        add({.id = "aa-scale",
             .section = SectionId::Preferences,
             .kind = SettingKind::Stepper,
             .binding = {.kind = BindingKind::Preference,
                         .preferenceKey = "aa-scale",
                         .actionPrefix = "aa-scale:"},
             .storage = StorageType::Integer,
             .order = 270,
             .titleEn = "AA SCALE",
             .titleZh = "抗锯齿倍率",
             .defaultValue = "125",
             .minimum = 100,
             .maximum = 200,
             .step = 25,
             .visible = aaScaleVisible,
             .label = percentLabel});
        add({.id = "msaa",
             .section = SectionId::Preferences,
             .kind = SettingKind::Stepper,
             .binding = {.kind = BindingKind::Preference, .preferenceKey = "msaa", .actionPrefix = "msaa:"},
             .storage = StorageType::Integer,
             .order = 280,
             .titleEn = "MSAA SAMPLES",
             .titleZh = "多重采样倍率",
             .defaultValue = "4",
             .steps = {2, 4, 8},
             .wrap = true,
             .visible = msaaVisible,
             .label = msaaLabel});
        add({.id = "fsr-quality",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::Preference,
                         .preferenceKey = "fsr-quality",
                         .actionPrefix = "fsr-quality:"},
             .storage = StorageType::Enum,
             .order = 290,
             .titleEn = "FSR QUALITY",
             .titleZh = "FSR 档位",
             .defaultValue = "native",
             .choices = fsrChoices(),
             .visible = fsrVisible});
        add({.id = "fsr-sharpness",
             .section = SectionId::Preferences,
             .kind = SettingKind::Stepper,
             .binding = {.kind = BindingKind::Preference,
                         .preferenceKey = "fsr-sharpness",
                         .actionPrefix = "fsr-sharpness:"},
             .storage = StorageType::Integer,
             .order = 300,
             .titleEn = "FSR SHARPNESS",
             .titleZh = "FSR 锐化",
             .defaultValue = "50",
             .minimum = 0,
             .maximum = 100,
             .step = 10,
             .visible = fsrVisible,
             .label = percentLabel});

// 关闭帧生成
#if 0
        add({.id = "fg",
             .section = SectionId::Preferences,
             .kind = SettingKind::Choice,
             .binding = {.kind = BindingKind::Preference,
                         .preferenceKey = "fg",
                         .action = "fg",
                         .actionPrefix = "setting:fg:"},
             .storage = StorageType::OnOff,
             .order = 310,
             .titleEn = "METALFX",
             .titleZh = "帧生成",
             .defaultValue = Off,
             .choices = onOffChoices(),
             .enabled = fgEnabled,
             .label = fgLabel});
#endif

        const struct {
            const char *id;
            const char *action;
            const char *label;
        } projects[] = {{"project-home", "music:project-home", "本项目 / Rhine Music Database"},
                        {"project-author", "music:project-author", "网易云音乐 API / api-enhanced"},
                        {"project-player", "music:project-player", "QQ 音乐 API / qq-music-api"},
                        {"project-kugou", "music:project-kugou", "酷狗音乐 API / KuGouMusicApi"},
                        {"project-rhine", "music:project-rhine", "界面原项目 / RhineLabUI"},
                        {"project-lyricsx", "music:project-lyricsx", "歌词参考 / LyricsX"},
                        {"project-lyricskit", "music:project-lyricskit", "格式移植 / LyricsKit"},
                        {"project-lyrimuse", "music:project-lyrimuse", "同步与匹配参考 / Lyrimuse"}};
        for (int index = 0; index < int(std::size(projects)); ++index) {
            const auto &project = projects[index];
            add({.id = project.id,
                 .section = SectionId::Project,
                 .kind = SettingKind::Link,
                 .binding = {.kind = BindingKind::Action, .action = project.action},
                 .storage = StorageType::None,
                 .order = 10 + index,
                 .titleEn = project.label,
                 .titleZh = project.label,
                 .actionLabel = project.label});
        }
        return list;
    }();
    return values;
}

const QVector<SettingsSection> &sections() {
    static const QVector<SettingsSection> values{
        {SectionId::Provider, 1, 10, "PROVIDER ACCESS", "音乐平台", "provider-card", 160, alwaysVisible},
        {SectionId::Preferences, 2, 20, "TERMINAL PREFERENCES", "终端偏好", {}, 0, alwaysVisible},
        {SectionId::Performance, 3, 30, "PERFORMANCE", "性能与诊断", "performance", 220, alwaysVisible},
        {SectionId::Storage, 4, 40, "STORAGE", "存储与缓存", "storage", 105, alwaysVisible},
        {SectionId::Update, 5, 50, "SOFTWARE UPDATE", "软件更新", "update", 220, alwaysVisible},
        {SectionId::Project, 6, 60, "PROJECT", "项目与开源参考", {}, 0, alwaysVisible},
        {SectionId::Footer, 7, 70, "CONFIG", "配置管理", "defaults", 84, alwaysVisible}};
    return values;
}

const SettingDescriptor *find(const QString &id) {
    for (const auto &descriptor : descriptors()) {
        if (descriptor.id == id) {
            return &descriptor;
        }
    }
    return nullptr;
}

QVector<SettingChoice> choices(const SettingDescriptor &descriptor, const SettingsContext &context) {
    return descriptor.choicesFor ? descriptor.choicesFor(context) : descriptor.choices;
}

QString normalize(const SettingDescriptor &descriptor, const SettingsContext &context, const QString &raw) {
    const auto options = choices(descriptor, context);
    const auto fallback = descriptor.defaultValue;
    const auto firstChoice = options.isEmpty() ? QString() : options.first().value;
    auto hasChoice = [&options](const QString &value) {
        return std::any_of(options.cbegin(), options.cend(),
                           [&value](const SettingChoice &choice) { return choice.value == value; });
    };

    switch (descriptor.storage) {
    case StorageType::OnOff:
        return raw == On || raw == Off ? raw : (fallback.isEmpty() ? QString(Off) : fallback);
    case StorageType::ReducedFull:
        return raw == "reduced" || raw == "full" ? raw : defaultFor(descriptor, "full");
    case StorageType::Theme:
        return raw == "light" || raw == "dark" || raw == "system" ? raw : defaultFor(descriptor, "light");
    case StorageType::TrayQuit:
        return raw == "tray" || raw == "quit" ? raw : defaultFor(descriptor, "quit");
    case StorageType::AppendReplace:
        return raw == "append" || raw == "replace" ? raw : defaultFor(descriptor, "replace");
    case StorageType::PlayerQuality: {
        if (hasChoice(raw)) {
            return raw;
        }
        return hasChoice(fallback) ? fallback : firstChoice;
    }
    case StorageType::PlayerAlternative:
    case StorageType::ExternalBool:
    case StorageType::HudCachedBool:
    case StorageType::Capability:
    case StorageType::Updater:
        return raw == On || raw == Off ? raw : (fallback.isEmpty() ? QString(Off) : fallback);
    case StorageType::Integer:
    case StorageType::HudCachedInt: {
        bool ok = false;
        auto value = raw.toInt(&ok);
        if (!ok) {
            value = fallback.toInt(&ok);
        }
        if (!ok) {
            value = descriptor.minimum;
        }
        // 固定档位表（渲染倍率/MSAA）没有连续范围，先取最近档位再钳制。
        if (!descriptor.steps.isEmpty()) {
            return nearestStep(descriptor.steps, value);
        }
        value = std::clamp(value, descriptor.minimum, descriptor.maximum);
        return QString::number(value);
    }
    case StorageType::Enum: {
        auto value = raw;
        if (descriptor.id == "aa-mode" && (value == "fsr1" || value == "fsr3")) {
            value = "fsr";
        }
        if (descriptor.id == "graphics-backend" && value == "d3d11") {
            value.clear();
        }
        if (hasChoice(value)) {
            return value;
        }
        if (hasChoice(fallback)) {
            return fallback;
        }
        return firstChoice;
    }
    case StorageType::None:
        return raw.isEmpty() ? descriptor.defaultValue : raw;
    }
    return raw;
}

SettingsValue read(const SettingDescriptor &descriptor, const SettingsContext &context) {
    SettingsValue value;
    value.type = descriptor.storage;
    switch (descriptor.binding.kind) {
    case BindingKind::Preference:
        if (context.host) {
            value.raw = context.host->preference(descriptor.binding.preferenceKey);
        }
        break;
    case BindingKind::HudState:
        if (descriptor.storage == StorageType::Theme) {
            value.raw = context.themeMode;
        } else if (descriptor.storage == StorageType::ReducedFull) {
            value.raw = context.reduced ? "reduced" : "full";
        } else if (descriptor.id == "startup-animation") {
            value.raw = context.startupAnimation ? On : Off;
        } else if (descriptor.id == "vsync") {
            value.raw = context.vsync ? On : Off;
        } else if (descriptor.storage == StorageType::HudCachedInt) {
            value.raw = QString::number(context.archiveMaskStrength);
        }
        break;
    case BindingKind::Player:
        if (context.music) {
            if (descriptor.storage == StorageType::PlayerQuality) {
                value.raw = context.music->player.quality;
            } else if (descriptor.storage == StorageType::PlayerAlternative) {
                value.raw = context.music->player.alternative ? On : Off;
            }
        }
        break;
    case BindingKind::External:
        if (context.host) {
            value.raw = context.host->activates() ? On : Off;
        }
        break;
    case BindingKind::Capability:
    case BindingKind::Updater:
        if (context.host) {
            value.raw = context.host->preference(descriptor.binding.preferenceKey);
        }
        break;
    case BindingKind::Action:
    case BindingKind::CustomSection:
        return value;
    }
    value.isDefault = value.raw.isEmpty();
    value.canonical = normalize(descriptor, context, value.raw);
    value.boolean = value.canonical == On || value.canonical == "reduced" || value.canonical == "tray" ||
                    value.canonical == "append";
    bool ok = false;
    value.integer = value.canonical.toInt(&ok);
    value.valid = ok || !value.canonical.isEmpty();
    return value;
}

QString displayLabel(const SettingDescriptor &descriptor, const SettingsContext &context) {
    if (descriptor.kind == SettingKind::Action || descriptor.kind == SettingKind::Link) {
        return descriptor.actionLabel;
    }
    return choiceLabel(descriptor, context, read(descriptor, context));
}

bool visible(const SettingDescriptor &descriptor, const SettingsContext &context) {
    return descriptor.visible ? descriptor.visible(context) : true;
}

bool enabled(const SettingDescriptor &descriptor, const SettingsContext &context) {
    return descriptor.enabled ? descriptor.enabled(context) : true;
}

QString switchTarget(const SettingDescriptor &descriptor, const SettingsContext &context) {
    const auto value = read(descriptor, context);
    const auto options = choices(descriptor, context);
    if (options.size() >= 2) {
        int index = 0;
        for (int choice = 0; choice < options.size(); ++choice) {
            if (options.at(choice).value == value.canonical) {
                index = choice;
                break;
            }
        }
        return options.at((index + 1) % options.size()).value;
    }
    switch (descriptor.storage) {
    case StorageType::ReducedFull:
        return value.canonical == "reduced" ? "full" : "reduced";
    case StorageType::TrayQuit:
        return value.canonical == "tray" ? "quit" : "tray";
    case StorageType::AppendReplace:
        return value.canonical == "append" ? "replace" : "append";
    default:
        return value.canonical == On ? Off : On;
    }
}

QString nextValue(const SettingDescriptor &descriptor, const SettingsContext &context, int direction) {
    const auto value = read(descriptor, context);
    if (descriptor.kind == SettingKind::Choice) {
        const auto options = choices(descriptor, context);
        if (options.isEmpty()) {
            return value.canonical;
        }
        int index = 0;
        for (int choice = 0; choice < options.size(); ++choice) {
            if (options.at(choice).value == value.canonical) {
                index = choice;
                break;
            }
        }
        index = std::clamp(index + direction, 0, int(options.size()) - 1);
        return options.at(index).value;
    }
    if (descriptor.kind == SettingKind::Stepper || descriptor.kind == SettingKind::Slider) {
        if (!descriptor.steps.isEmpty()) {
            int index = 0;
            for (int step = 0; step < descriptor.steps.size(); ++step) {
                if (descriptor.steps.at(step) == value.integer) {
                    index = step;
                    break;
                }
            }
            const auto count = int(descriptor.steps.size());
            index = descriptor.wrap ? (index + direction + count) % count
                                    : std::clamp(index + direction, 0, count - 1);
            return QString::number(descriptor.steps.at(index));
        }
        const auto next = value.integer + direction * std::max(1, descriptor.step);
        return QString::number(std::clamp(next, descriptor.minimum, descriptor.maximum));
    }
    return value.canonical;
}

QStringList validateRegistry() {
    QStringList errors;
    QSet<QString> ids;
    QSet<QString> actions;
    QSet<int> sectionIds;
    for (const auto &section : sections()) {
        if (sectionIds.contains(int(section.id))) {
            errors.append("重复的分区 id: " + QString::number(int(section.id)));
        }
        sectionIds.insert(int(section.id));
        if (section.titleEn.isEmpty() || section.number <= 0) {
            errors.append("分区缺少标题或编号: " + section.titleEn);
        }
    }
    for (const auto &descriptor : descriptors()) {
        const auto prefix = descriptor.id + ": ";
        if (descriptor.id.isEmpty() || ids.contains(descriptor.id)) {
            errors.append("空或重复的 descriptor id: " + descriptor.id);
        }
        ids.insert(descriptor.id);
        if (!sectionIds.contains(int(descriptor.section))) {
            errors.append(prefix + "引用了不存在的分区");
        }
        if (descriptor.titleEn.isEmpty() || descriptor.titleZh.isEmpty()) {
            errors.append(prefix + "缺少标题");
        }
        if (descriptor.binding.kind == BindingKind::Preference &&
            !Host::isPreferenceKey(descriptor.binding.preferenceKey)) {
            errors.append(prefix +
                          "偏好 key 不在 Host::preferenceKeys() 中: " + descriptor.binding.preferenceKey);
        }
        if (descriptor.binding.kind == BindingKind::Action && descriptor.binding.action.isEmpty()) {
            errors.append(prefix + "Action 缺少 action");
        }
        if ((descriptor.kind == SettingKind::Choice || descriptor.kind == SettingKind::Stepper ||
             descriptor.kind == SettingKind::Slider) &&
            descriptorAction(descriptor).isEmpty()) {
            errors.append(prefix + "可编辑控件缺少 action/actionPrefix");
        }
        const auto action = descriptorAction(descriptor);
        if (!action.isEmpty()) {
            if (actions.contains(action)) {
                errors.append(prefix + "重复的 action: " + action);
            }
            actions.insert(action);
        }
        QSet<QString> choiceValues;
        for (const auto &choice : descriptor.choices) {
            if (choice.value.isEmpty() || choiceValues.contains(choice.value)) {
                errors.append(prefix + "选项值为空或重复: " + choice.value);
            }
            choiceValues.insert(choice.value);
        }
        if (!descriptor.choices.isEmpty() && !descriptor.defaultValue.isEmpty() &&
            !choiceValues.contains(descriptor.defaultValue)) {
            errors.append(prefix + "默认值不在静态选项中: " + descriptor.defaultValue);
        }
        if (descriptor.minimum > descriptor.maximum) {
            errors.append(prefix + "minimum 大于 maximum");
        }
        if (descriptor.step < 0) {
            errors.append(prefix + "step 为负数");
        }
        if (!descriptor.steps.isEmpty()) {
            auto steps = descriptor.steps;
            if (!std::is_sorted(steps.cbegin(), steps.cend())) {
                errors.append(prefix + "steps 未排序");
            }
            if (!descriptor.defaultValue.isEmpty() &&
                !std::any_of(steps.cbegin(), steps.cend(), [&descriptor](int step) {
                    return QString::number(step) == descriptor.defaultValue;
                })) {
                errors.append(prefix + "默认值不在 steps 中");
            }
        }
    }
    return errors;
}
}
