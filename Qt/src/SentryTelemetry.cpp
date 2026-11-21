#include "SentryTelemetry.h"

#include "AppIdentity.h"
#include "AppStorage.h"
#include "AppUpdater.h"
#include "BuildIdentity.h"
#include "ProviderRegistry.h"
#include "SentryBuildConfig.h"
#include "SentryTelemetryPlatform.h"
#include "fg/FgConfig.h"
#include "render/RenderModePolicy.h"
#include <QCryptographicHash>
#include <QDir>
#include <QJsonArray>
#include <QLockFile>
#include <QRegularExpression>
#include <QStringList>
#include <QUrl>
#include <QUuid>
#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <utility>

namespace RhineSentry {
namespace {
QString databaseDirectory;
std::atomic_bool running = false;
void *startupTrace = nullptr;
double traceRate = 0.1;
bool attempted = false;
const char *lastPage = nullptr;
QJsonObject graphics;
constexpr auto settingKey = "panel/sentry-consent";
constexpr auto defaultPreference = "default";

QString dsn() {
    return qEnvironmentVariable("SENTRY_DSN", QStringLiteral(RHINE_SENTRY_DSN)).trimmed();
}

bool validDsn(const QString &value) {
    const QUrl url(value, QUrl::StrictMode);
    const auto project = url.path().section(u'/', -1);
    return url.isValid() && url.scheme() == QStringLiteral("https") && !url.host().isEmpty() &&
           !url.userName().isEmpty() && !url.hasQuery() && !url.hasFragment() &&
           !project.isEmpty() && std::all_of(project.begin(), project.end(), [](QChar character) {
               return character >= u'0' && character <= u'9';
           });
}

QString destination(const QString &endpoint) {
    return QString::fromLatin1(QCryptographicHash::hash(endpoint.toUtf8(), QCryptographicHash::Sha256).toHex());
}

QString grantFor(const QString &endpoint) {
    return QUuid::createUuid().toString(QUuid::WithoutBraces) + u':' + destination(endpoint);
}

QUuid authorizedGeneration(QStringView value, const QString &endpoint) {
    const auto separator = value.indexOf(u':');
    if (separator < 0 || value.sliced(separator + 1) != destination(endpoint)) {
        return {};
    }
    return QUuid::fromString(value.first(separator));
}

QString preferenceLockPath() {
    const auto directory = AppStorage::dataDirectory();
    if (directory.isEmpty() || !QDir().mkpath(directory)) {
        return {};
    }
    return QDir(directory).filePath(QStringLiteral("sentry-preference.lock"));
}

struct Action {
    QStringView input;
    const char *name;
};

constexpr Action hudActions[] = {
    {u"home", "home"},
    {u"menu", "menu"},
    {u"close-modal", "close_modal"},
    {u"saved", "open_library"},
    {u"settings", "open_settings"},
    {u"discover", "open_discover"},
    {u"search", "open_search"},
    {u"music:play", "play_selection"},
    {u"player:toggle", "play_pause"},
    {u"player:prev", "previous"},
    {u"player:next", "next"},
    {u"player:lyrics", "open_lyrics"},
    {u"player:lyrics-close", "close_lyrics"},
    {u"player:open", "open_player"},
    {u"music:comments", "open_comments"},
    {u"music:comments-close", "close_comments"},
};

QString graphicsBackendName(QStringView backend) {
    const auto name = backend.toString().toLower();
    static const QStringList names{"metal", "vulkan", "opengl", "opengles2", "d3d12", "d3d11", "null"};
    return names.contains(name) ? name : QStringLiteral("unknown");
}
}

bool configured() {
    return validDsn(dsn());
}

QString newConsent() {
    const auto endpoint = dsn();
    if (!validDsn(endpoint)) {
        return {};
    }
    return grantFor(endpoint);
}

QString preference() {
    return AppStorage::settings().value(QLatin1String(settingKey), QLatin1String(defaultPreference)).toString();
}

bool preferenceEnabled(QStringView value) {
    const auto endpoint = dsn();
    return validDsn(endpoint) &&
           (value == QLatin1String(defaultPreference) || !authorizedGeneration(value, endpoint).isNull());
}

bool savePreference(const QString &value) {
    const auto endpoint = dsn();
    if (value != QLatin1String(DisabledPreference) &&
        (!validDsn(endpoint) || authorizedGeneration(value, endpoint).isNull())) {
        return false;
    }
    const auto path = preferenceLockPath();
    if (path.isEmpty()) {
        return false;
    }
    QLockFile lock(path);
    if (!lock.tryLock(1000)) {
        return false;
    }
    auto settings = AppStorage::settings();
    settings.setValue(QLatin1String(settingKey), value);
    settings.sync();
    return settings.status() == QSettings::NoError;
}

bool active() {
    return running;
}

bool ownsCrashHandler() {
    // 初始化失败也可能留下平台异常钩子。换用本地 Crashpad 必须等到下一次启动。
    return attempted;
}

/** 正常构建默认开启，已保存的关闭选择和旧版空值优先。 */
void start(bool playbackService) {
    if (attempted) {
        return;
    }
    const auto endpoint = dsn();
    if (!validDsn(endpoint)) {
        return;
    }
    const auto path = preferenceLockPath();
    if (path.isEmpty()) {
        return;
    }
    // 两个进程可能同时启动。先在共享设置中落下唯一的标识，再初始化 SDK。
    QLockFile lock(path);
    if (!lock.tryLock(1000)) {
        return;
    }
    auto settings = AppStorage::settings();
    settings.sync();
    const QLatin1String key(settingKey);
    if (settings.status() != QSettings::NoError) {
        return;
    }
    if (!settings.contains(key)) {
        settings.setValue(key, grantFor(endpoint));
        settings.sync();
        if (settings.status() != QSettings::NoError) {
            return;
        }
    }
    const auto generation = authorizedGeneration(settings.value(key).toString(), endpoint);
    if (generation.isNull()) {
        return;
    }
    const QString role = playbackService ? QStringLiteral("playback-service") : QStringLiteral("interface");
    const auto cacheDirectory = AppStorage::cacheDirectory();
    if (cacheDirectory.isEmpty()) {
        return;
    }
    const QDir root(cacheDirectory + QStringLiteral("/sentry"));
    databaseDirectory = root.filePath(role + u'/' + generation.toString(QUuid::WithoutBraces));
    if (!QDir().mkpath(databaseDirectory)) {
        databaseDirectory.clear();
        return;
    }
    const auto version = AppUpdater::currentVersion();
    const auto release = QString::fromLatin1(AppIdentity::Id) + u'@' + version + u'+' + QStringLiteral(RHINE_COMMIT_SHA);
    const auto environment = qEnvironmentVariable("SENTRY_ENVIRONMENT", QStringLiteral(RHINE_SENTRY_ENVIRONMENT)).trimmed();
    bool validRate = false;
    const double configuredRate = qEnvironmentVariable("SENTRY_TRACES_SAMPLE_RATE").toDouble(&validRate);
    if (validRate && configuredRate >= 0.0 && configuredRate <= 1.0) {
        traceRate = configuredRate;
    }
    // 同一份授权在 GUI 和播放服务间共享，不依赖各自的 SDK 缓存。
    const auto userId = QString::fromLatin1(QCryptographicHash::hash(
        QByteArrayLiteral("rhine-sentry-user-v1:") + generation.toRfc4122(), QCryptographicHash::Sha256).toHex());
    attempted = true;
    running = Platform::start({endpoint, environment.isEmpty() ? QStringLiteral("production") : environment,
                               release, version, databaseDirectory, role, userId, traceRate});
    if (running) {
        Platform::setContext("rhine", {{"process", role}});
        Platform::record("lifecycle", "started");
        if (!playbackService && traceRate > 0.0) {
            startupTrace = Platform::beginTrace("Rhine startup", "app.start");
        }
    }
}

void stop() {
    if (running) {
        running = false;
        Platform::finishTrace(std::exchange(startupTrace, nullptr), false, false);
        Platform::stop(false);
    }
}

/** 先停止应用采集，再撤回 SDK 授权并清理该进程的授权目录。 */
void revoke() {
    if (running) {
        running = false;
        Platform::finishTrace(std::exchange(startupTrace, nullptr), false, false);
        Platform::stop(true);
    }
    if (!databaseDirectory.isEmpty()) {
        QDir(databaseDirectory).removeRecursively();
    }
}

void foreground() {
    if (running) {
        Platform::record("lifecycle", "foreground");
    }
}

void playbackActive() {
    if (running) {
        Platform::record("lifecycle", "playback_active");
    }
}

void playbackAction(PlaybackAction action) {
    static constexpr std::array names{"play", "resume", "pause", "next", "previous"};
    const auto index = size_t(action);
    if (running && index < names.size()) {
        Platform::record("playback", names[index]);
    }
}

void startup(qint64 milliseconds) {
    if (running) {
        Platform::startup(milliseconds);
        Platform::finishTrace(std::exchange(startupTrace, nullptr), true, true);
    }
}

void *beginPlaybackPreparation() {
    if (running && traceRate > 0.0) {
        return Platform::beginTrace("Rhine audio prepare", "audio.prepare");
    }
    return nullptr;
}

void finishPlaybackPreparation(void *trace, bool prepared) {
    Platform::finishTrace(trace, running, prepared);
}

void page(QStringView mode, QStringView modal, bool lyrics, bool comments, bool viewer) {
    if (!running) {
        return;
    }
    const char *name = nullptr;
    if (modal == u"settings") {
        name = "settings";
    } else if (modal == u"discover") {
        name = "discover";
    } else if (modal == u"search") {
        name = "search";
    } else if (modal == u"player") {
        name = "player";
    } else if (modal == u"saved") {
        name = "library";
    } else if (!modal.isEmpty()) {
        name = nullptr;
    } else if (comments) {
        name = "comments";
    } else if (lyrics) {
        name = "lyrics";
    } else if (viewer) {
        name = "player";
    } else if (mode == u"archive") {
        name = "library";
    } else if (mode == u"detail") {
        name = "detail";
    } else if (mode == u"boot") {
        name = "home";
    }
    if (name && (!lastPage || std::strcmp(name, lastPage) != 0)) {
        Platform::record("page", name);
    }
    lastPage = name;
}

void action(QStringView value) {
    if (!running) {
        return;
    }
    for (const auto &entry : hudActions) {
        if (value == entry.input) {
            Platform::record("action", entry.name);
            return;
        }
    }
}

void playbackFailure() {
    if (running) {
        Platform::failure();
    }
}

/** 只保存经过规范化的公开设置值，不发送环境变量原文或完整设置。 */
void renderSettings(QStringView backend) {
    if (!running) {
        return;
    }
    const auto frameGeneration = RhineFg::parseBool(qgetenv("RHINE_FG"), false);
    const auto mode = RhineRender::currentRenderMode(qEnvironmentVariable("RHINE_AA_MODE"), frameGeneration);
    static const QStringList modes{"off", "none", "fxaa", "msaa", "ssaa", "taa", "fsr", "fsr1", "fsr3",
                                   "metalfx"};
    const auto samples = qEnvironmentVariableIntValue("RHINE_MSAA");
    graphics["configured_backend"] = graphicsBackendName(backend);
    graphics["requested_antialiasing"] =
        modes.contains(mode.requestedAaMode) ? mode.requestedAaMode : QStringLiteral("unknown");
    graphics["render_scale_percent"] = mode.renderPercent;
    graphics["supersample_factor"] = mode.supersample;
    graphics["requested_msaa_samples"] = samples == 2 || samples == 4 || samples == 8 ? samples : 0;
    graphics["requested_frame_generation"] = mode.requestedFrameGeneration;
    graphics["vsync"] = RhineFg::parseBool(qgetenv("RHINE_VSYNC"), true);
    Platform::setContext("rhine_graphics", graphics);
}

/** PCI 型号与固定 Apple 芯片名称足以识别显卡，禁止发送任意驱动描述或设备序列号。 */
void renderDevice(QStringView backend, quint64 vendorId, quint64 deviceId, int deviceType,
                  QStringView appleModel) {
    if (!running) {
        return;
    }
    static const QRegularExpression publicAppleModel(
        QStringLiteral(R"(\AApple (M[1-9][0-9]?( (Pro|Max|Ultra))?|A[1-9][0-9]?( (Pro|X|Z))?)\z)"));
    graphics["backend"] = graphicsBackendName(backend);
    if (vendorId > 0 && vendorId <= 0xffff && deviceId <= 0xffff) {
        graphics["gpu_vendor_id"] = int(vendorId);
        graphics["gpu_device_id"] = int(deviceId);
    } else {
        graphics.remove("gpu_vendor_id");
        graphics.remove("gpu_device_id");
    }
    if (deviceType >= 0 && deviceType <= 5) {
        static const QStringList deviceTypes{"unknown", "integrated", "discrete", "external", "virtual", "cpu"};
        graphics["gpu_type"] = deviceTypes[deviceType];
    }
    if (appleModel.size() <= 24 && publicAppleModel.matchView(appleModel).hasMatch()) {
        graphics["gpu_model"] = appleModel.toString();
    } else {
        graphics.remove("gpu_model");
    }
    Platform::setContext("rhine_graphics", graphics);
}

void audioBackend(AudioBackend backend) {
    if (!running) {
        return;
    }
    static constexpr std::array names{"separate-process", "qt-multimedia", "qt-ffmpeg", "avplayer",
                                      "windows-transition"};
    static auto current = names.size();
    const auto index = size_t(backend);
    if (index < names.size() && current != index) {
        current = index;
        Platform::setContext("rhine_audio", {{"backend", QString::fromLatin1(names[index])}});
    }
}

/** 仅发送当前已加载插件中去重的数字版本，不发送插件名、ID、路径或配置。 */
void pluginVersions() {
    if (!running) {
        return;
    }
    static const QRegularExpression publicVersion(QStringLiteral(R"(\A[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}\z)"));
    auto &registry = ProviderRegistry::instance();
    QStringList versions;
    for (const auto &id : registry.ids()) {
        const auto version = registry.manifest(id).value("version").toString();
        if (version.size() <= 14 && publicVersion.match(version).hasMatch() && !versions.contains(version)) {
            versions.append(version);
        }
    }
    versions.sort();
    Platform::setContext("rhine_plugins", {{"versions", QJsonArray::fromStringList(versions.mid(0, 16))}});
}

}
