#include "FilamentConfig.h"

#include <QtGlobal>

#ifndef RHINE_FILAMENT_AVAILABLE
#define RHINE_FILAMENT_AVAILABLE 0
#endif

namespace RhineFilament {

const char *stateName(State state) noexcept {
    switch (state) {
    case State::Off:
        return "off";
    case State::Active:
        return "active";
    case State::Degraded:
        return "degraded";
    }
    return "off";
}

const char *errorCode(Error error) noexcept {
    switch (error) {
    case Error::None:
        return "E_NONE";
    case Error::Disabled:
        return "E_DISABLED";
    case Error::BackendUnsupported:
        return "E_BACKEND_UNSUPPORTED";
    case Error::SharedContext:
        return "E_SHARED_CONTEXT";
    case Error::EngineCreate:
        return "E_ENGINE_CREATE";
    case Error::SceneCreate:
        return "E_SCENE_CREATE";
    case Error::MaterialLoad:
        return "E_MATERIAL_LOAD";
    case Error::MaterialMissing:
        return "E_MATERIAL_MISSING";
    case Error::ImageHandoff:
        return "E_IMAGE_HANDOFF";
    case Error::FirstFrame:
        return "E_FIRST_FRAME";
    case Error::SizeInvalid:
        return "E_SIZE_INVALID";
    case Error::Sync:
        return "E_SYNC";
    case Error::Runtime:
        return "E_RUNTIME";
    }
    return "E_RUNTIME";
}

bool compiledIn() {
    return RHINE_FILAMENT_AVAILABLE != 0;
}

QString Config::describe() const {
    if (legacyForced) {
        return QStringLiteral("legacy-forced");
    }
    if (!requested) {
        return source;
    }
    return QStringLiteral("on:") + source;
}

Config resolveConfig(const QString &preferenceValue, bool legacyOnly) {
    Config config;
    // 【功能暂未完成】V3/V4 画面保真度未达标（场景色比 legacy 平坦约 2.2 倍，
    // face 分布错误导致图集只被采样一个面），因此这里无条件回退到 legacy 链路。
    // 判定顺序中的 CMake 开关、环境变量 RHINE_FILAMENT 与应用偏好全部被跳过，
    // 任何配置都无法进入 Filament 渲染路径。代码保留以便后续继续开发。
    config.legacyForced = legacyOnly;
    config.source = QStringLiteral("unimplemented");
    return config;
    // 以下为原判定逻辑，功能完成并验收通过后删除上面的 return 即可恢复。
    if (legacyOnly) {
        config.legacyForced = true;
        config.source = QStringLiteral("legacy-forced");
        return config;
    }
    if (!compiledIn()) {
        config.source = QStringLiteral("cmake-off");
        return config;
    }
    const auto env = qEnvironmentVariable("RHINE_FILAMENT").trimmed().toLower();
    if (env == QLatin1String("0") || env == QLatin1String("off") || env == QLatin1String("false")) {
        config.source = QStringLiteral("env-off");
        return config;
    }
    if (env == QLatin1String("1") || env == QLatin1String("on") || env == QLatin1String("force")) {
        config.requested = true;
        config.source = QStringLiteral("env");
        return config;
    }
    const auto pref = preferenceValue.trimmed().toLower();
    if (pref == QLatin1String("on") || pref == QLatin1String("1") || pref == QLatin1String("force")) {
        config.requested = true;
        config.source = QStringLiteral("preference");
        return config;
    }
    config.source = QStringLiteral("off");
    return config;
}

}  // namespace RhineFilament
