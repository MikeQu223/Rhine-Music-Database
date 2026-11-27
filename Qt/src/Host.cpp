#include "fg/FgConfig.h"
#include "Host.h"
#if RHINE_SENTRY
#include "SentryTelemetry.h"
#endif
#include "ProviderRegistry.h"
#include "PluginInstaller.h"
#include "AppStorage.h"
#ifdef Q_OS_MACOS
#include "MacMenuBarSettings.h"
#endif
#include <QBuffer>
#include <QClipboard>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QFutureWatcher>
#include <QThread>
#include <QGuiApplication>
#include <QImageReader>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkCookie>
#include <QNetworkReply>
#include <QNetworkInformation>
#include <QPainter>
#include <QPointer>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStyleHints>
#include <QUrlQuery>
#include <QUuid>
#include <QtConcurrentRun>
#include <algorithm>
#include <cmath>
#include <memory>
#include <mutex>

static QString hash(QByteArray value) {
    return QCryptographicHash::hash(value, QCryptographicHash::Sha256).toHex();
}

constexpr qint64 CoverCacheBudgetBytes = 256LL * 1024 * 1024;
constexpr qint64 CoverThumbnailCacheBudgetBytes = 32LL * 1024 * 1024;
constexpr qint64 CoverCacheEntryLimitBytes = 8LL * 1024 * 1024;
constexpr int CoverListRequestDimension = 512;
constexpr int CoverLargeRequestDimension = 1024;

/**
 * 封面写任务与清除缓存共用的代数状态。
 * 任务独立持有共享状态，Host 销毁后仍可安全判断并放弃过期写回。
 */
struct CoverCacheGenerationState {
    std::mutex mutex;
    quint64 generation = 0;
};

struct CoverCacheGenerationRegistry {
    std::mutex mutex;
    QHash<const Host *, std::shared_ptr<CoverCacheGenerationState>> states;
};

CoverCacheGenerationRegistry &coverCacheGenerationRegistry() {
    static CoverCacheGenerationRegistry registry;
    return registry;
}

std::shared_ptr<CoverCacheGenerationState> coverCacheGenerationState(const Host *host) {
    auto &registry = coverCacheGenerationRegistry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    auto &state = registry.states[host];
    if (!state) {
        state = std::make_shared<CoverCacheGenerationState>();
    }
    return state;
}

void forgetCoverCacheGeneration(const Host *host) {
    auto &registry = coverCacheGenerationRegistry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    registry.states.remove(host);
}

bool isCoverCacheGenerationCurrent(const std::shared_ptr<CoverCacheGenerationState> &state,
                                   quint64 expectedGeneration) {
    if (!state) {
        return false;
    }
    std::lock_guard<std::mutex> lock(state->mutex);
    return state->generation == expectedGeneration;
}

QString coverCacheDirectory() {
    const auto cache = AppStorage::cacheDirectory();
    return cache.isEmpty() ? QString() : cache + "/covers";
}

QString coverThumbnailCacheDirectory(int dimension) {
    const auto directory = coverCacheDirectory();
    return directory.isEmpty() ? QString() : directory + "/thumbnails/" + QString::number(dimension);
}

QString coverCachePath(const QString &key, bool thumbnail, int dimension) {
    const auto directory = thumbnail ? coverThumbnailCacheDirectory(dimension) : coverCacheDirectory();
    return directory.isEmpty() ? QString() : directory + "/" + hash(key.toUtf8());
}

/** 网易云 CDN 支持 param 尺寸参数；其他来源保持插件返回的最终地址。 */
static QUrl coverRequestUrl(const QUrl &url, int maximumDimension) {
    const auto host = url.host();
    if (host != QLatin1String("music.126.net") && !host.endsWith(QLatin1String(".music.126.net"))) {
        return url;
    }
    const auto dimension = maximumDimension <= CoverListRequestDimension
                               ? CoverListRequestDimension
                               : CoverLargeRequestDimension;
    auto requestUrl = url;
    QUrlQuery query(requestUrl);
    query.removeAllQueryItems(QStringLiteral("param"));
    query.addQueryItem(QStringLiteral("param"),
                       QString::number(dimension) + QLatin1Char('y') + QString::number(dimension));
    requestUrl.setQuery(query);
    return requestUrl;
}

void cleanupLegacyCoverCaches() {
    static std::once_flag once;
    std::call_once(once, [] {
        const auto directory = coverCacheDirectory();
        if (directory.isEmpty()) {
            return;
        }
        static const QRegularExpression namePattern("^[0-9a-f]{64}$");
        QDir root(directory);
        const auto files = root.entryInfoList({"*.img"}, QDir::Files | QDir::NoSymLinks);
        for (const auto &file : files) {
            const auto name = file.completeBaseName();
            if (!namePattern.match(name).hasMatch()) {
                continue;
            }
            QFile::remove(file.absoluteFilePath());
        }
    });
}

QImage decodeCover(const QByteArray &bytes, int dimension) {
    if (bytes.isEmpty() || bytes.size() >= CoverCacheEntryLimitBytes) {
        return {};
    }
    QBuffer buffer;
    buffer.setData(bytes);
    if (!buffer.open(QIODevice::ReadOnly)) {
        return {};
    }
    QImageReader reader(&buffer);
    reader.setAutoTransform(true);
    const auto size = reader.size();
    if (!size.isValid() || size.width() > 8192 || size.height() > 8192) {
        return {};
    }
    // 小图不在解码阶段放大，避免重复插值。
    if (size.width() > dimension || size.height() > dimension) {
        reader.setScaledSize(size.scaled(dimension, dimension, Qt::KeepAspectRatio));
    }
    return reader.read();
}

void pruneCoverCache(const QString &directory, qint64 budgetBytes) {
    QDir root(directory);
    static const QRegularExpression namePattern("^[0-9a-f]{64}$");
    const auto entries = root.entryInfoList(QDir::Files | QDir::NoSymLinks);
    QFileInfoList files;
    for (const auto &entry : entries) {
        if (namePattern.match(entry.fileName()).hasMatch()) {
            files.append(entry);
        }
    }
    qint64 total = 0;
    for (const auto &file : files) {
        total += file.size();
    }
    if (total <= budgetBytes) {
        return;
    }
    auto oldest = files;
    std::sort(oldest.begin(), oldest.end(), [](const QFileInfo &left, const QFileInfo &right) {
        return left.lastModified() < right.lastModified();
    });
    for (const auto &file : oldest) {
        if (total <= budgetBytes || !QFile::remove(file.absoluteFilePath())) {
            continue;
        }
        total -= file.size();
    }
}

void storeCoverCache(const QString &path, const QImage &image, qint64 budgetBytes,
                     const std::shared_ptr<CoverCacheGenerationState> &generationState,
                     quint64 expectedGeneration) {
    if (path.isEmpty() || image.isNull()) {
        return;
    }
    // 编码可能较慢，先排除已经过期的任务。
    // 最终落盘前还会在同步区内复核代数。
    if (!isCoverCacheGenerationCurrent(generationState, expectedGeneration)) {
        return;
    }
    QByteArray encoded;
    QBuffer buffer(&encoded);
    if (!buffer.open(QIODevice::WriteOnly) || !image.save(&buffer, "WEBP", 88)) {
        buffer.close();
        encoded.clear();
        // WebP 插件不可用时退回不透明 JPEG，封面本身通常是照片或插画。
        QImage opaque(image.size(), QImage::Format_RGB32);
        opaque.fill(Qt::white);
        QPainter painter(&opaque);
        painter.drawImage(0, 0, image);
        painter.end();
        buffer.open(QIODevice::WriteOnly);
        if (!opaque.save(&buffer, "JPG", 90)) {
            return;
        }
    }
    if (encoded.isEmpty() || encoded.size() >= CoverCacheEntryLimitBytes) {
        return;
    }
    const auto directory = QFileInfo(path).absolutePath();
    // 与清除缓存共用同一互斥边界：要么旧任务先提交后被整体删除，
    // 要么先清除再让旧任务放弃。
    std::lock_guard<std::mutex> lock(generationState->mutex);
    if (generationState->generation != expectedGeneration) {
        return;
    }
    if (!QDir().mkpath(directory)) {
        return;
    }
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) || file.write(encoded) != encoded.size() || !file.commit()) {
        return;
    }
    pruneCoverCache(directory, budgetBytes);
}

void touchCoverCache(const QString &path) {
    QFile file(path);
    if (file.open(QIODevice::ReadOnly)) {
        file.setFileTime(QDateTime::currentDateTime(), QFileDevice::FileModificationTime);
    }
}

// 插件清单声明可落盘的操作，响应还必须通过凭据和临时地址检查。
static bool isDiskCachePayload(const QJsonValue &value, int depth = 0) {
    if (depth > 32) {
        return false;
    }
    if (value.isObject()) {
        const auto object = value.toObject();
        for (auto item = object.constBegin(); item != object.constEnd(); ++item) {
            auto name = item.key().toLower();
            name.remove('_').remove('-');
            static const QRegularExpression sensitive(QStringLiteral(
                "cookie|token|password|passwd|secret|authorization|credential|sessionkey|apikey|signature"));
            if (name.contains(sensitive) || !isDiskCachePayload(item.value(), depth + 1)) {
                return false;
            }
        }
    } else if (value.isArray()) {
        for (const auto &item : value.toArray()) {
            if (!isDiskCachePayload(item, depth + 1)) {
                return false;
            }
        }
    } else if (value.isString()) {
        const auto string = value.toString();
        if (string.startsWith("https://", Qt::CaseInsensitive) ||
            string.startsWith("http://", Qt::CaseInsensitive)) {
            const QUrl url(string);
            if (!url.userInfo().isEmpty() || url.hasQuery() || url.hasFragment()) {
                return false;
            }
        }
    }
    return true;
}
// 按路由隔离插件的缓存、限流和账号范围；provider 由 Registry/路由段解析。
static QString routeProvider(const QString &route) {
    if (route.startsWith("/native/") || route.startsWith("/plugin/")) {
        const auto id = route.section('/', 2, 2);
        return id.isEmpty() ? QStringLiteral("other") : id;
    }
    const auto id = ProviderRegistry::instance().providerForRoute(route);
    return id.isEmpty() ? QStringLiteral("other") : id;
}

namespace {
QJsonValue jsonValueAt(const QJsonObject &root, const QString &path) {
    QJsonValue value(root);
    for (const auto &part : path.split('.', Qt::SkipEmptyParts)) {
        if (!value.isObject()) {
            return {};
        }
        value = value.toObject().value(part);
    }
    return value;
}

void setJsonPath(QJsonObject &root, const QStringList &parts, int index, const QJsonValue &value) {
    if (index >= parts.size()) {
        return;
    }
    if (index == parts.size() - 1) {
        root[parts[index]] = value;
        return;
    }
    auto child = root[parts[index]].toObject();
    setJsonPath(child, parts, index + 1, value);
    root[parts[index]] = child;
}

bool nonEmptyJson(const QJsonValue &value) {
    if (value.isString()) {
        return !value.toString().isEmpty();
    }
    if (value.isArray()) {
        return !value.toArray().isEmpty();
    }
    if (value.isObject()) {
        return !value.toObject().isEmpty();
    }
    return !value.isUndefined() && !value.isNull();
}

bool authPredicateMatches(const QJsonObject &predicate, const QJsonObject &cookies,
                          const QJsonObject &secrets, const QString &variant) {
    if (predicate["allOf"].isArray()) {
        for (const auto &value : predicate["allOf"].toArray()) {
            if (!value.isObject() || !authPredicateMatches(value.toObject(), cookies, secrets, variant)) {
                return false;
            }
        }
        return !predicate["allOf"].toArray().isEmpty();
    }
    if (predicate["anyOf"].isArray()) {
        for (const auto &value : predicate["anyOf"].toArray()) {
            if (value.isObject() && authPredicateMatches(value.toObject(), cookies, secrets, variant)) {
                return true;
            }
        }
        return false;
    }
    if (predicate["cookie"].isString()) {
        const auto value = cookies.value(predicate["cookie"].toString());
        return predicate["nonEmpty"].toBool(true) ? nonEmptyJson(value) : value.isString();
    }
    if (predicate["secret"].isString()) {
        auto path = predicate["secret"].toString();
        path.replace("$variant", variant);
        const auto value = jsonValueAt(secrets, path);
        const auto kind = predicate["kind"].toString();
        if (kind == "string") {
            return value.isString();
        }
        if (kind == "number") {
            return value.isDouble();
        }
        if (kind == "positiveInteger") {
            return value.isDouble() && value.toDouble() > 0 &&
                   std::floor(value.toDouble()) == value.toDouble();
        }
        if (kind == "object") {
            return value.isObject();
        }
        if (kind == "array") {
            return value.isArray();
        }
        return predicate["nonEmpty"].toBool(true) ? nonEmptyJson(value) : !value.isUndefined();
    }
    return false;
}

bool authMatches(const QString &provider, const QJsonObject &cookies, const QJsonObject &secrets,
                 const QString &variant) {
    const auto policy = ProviderRegistry::instance().credentialPolicy(provider);
    const auto anyOf = policy["auth"].toObject()["anyOf"].toArray();
    for (const auto &value : anyOf) {
        if (value.isObject() && authPredicateMatches(value.toObject(), cookies, secrets, variant)) {
            return true;
        }
    }
    return false;
}
}

/**
 * 旧版扁平 cookie jar 按插件 manifest 的 credentials.legacy 映射迁移一次。
 * 未匹配的键保留在 credentials.legacy，插件随后安装时仍可继续迁移。
 */
QJsonObject Host::migrateCredential(const QJsonObject &legacy) {
    QJsonObject providers;
    QJsonObject pending;
    if (legacy["version"].toInt() == 2 && legacy["providers"].isObject()) {
        providers = legacy["providers"].toObject();
        pending = legacy["legacy"].toObject();
    } else {
        for (auto it = legacy.begin(); it != legacy.end(); ++it) {
            if (it.key() != "version" && it.key() != "providers") {
                pending.insert(it.key(), it.value());
            }
        }
    }
    const auto apply = [&](const QString &id, bool defaults) {
        const auto policy = ProviderRegistry::instance().credentialPolicy(id)["legacy"].toObject();
        if (policy["default"].toBool() != defaults) {
            return;
        }
        const auto cookieMap = policy["cookies"].toObject();
        const auto secretMap = policy["secrets"].toObject();
        auto entry = providers.value(id).toObject();
        auto cookies = entry["cookies"].toObject();
        auto secrets = entry["secrets"].toObject();
        bool changed = false;
        if (!defaults) {
            for (auto it = cookieMap.begin(); it != cookieMap.end(); ++it) {
                if (pending.contains(it.key())) {
                    cookies.insert(it.value().toString(), pending.take(it.key()));
                    changed = true;
                }
            }
            for (auto it = secretMap.begin(); it != secretMap.end(); ++it) {
                if (pending.contains(it.key())) {
                    const auto value = pending.take(it.key());
                    if (it.value().toString() == "$root" && value.isObject()) {
                        const auto object = value.toObject();
                        for (auto inner = object.begin(); inner != object.end(); ++inner) {
                            secrets.insert(inner.key(), inner.value());
                        }
                    } else if (!it.value().toString().isEmpty()) {
                        secrets.insert(it.value().toString(), value);
                    }
                    changed = true;
                }
            }
        } else {
            for (auto it = pending.begin(); it != pending.end();) {
                if (it.key().startsWith("__")) {
                    ++it;
                    continue;
                }
                cookies.insert(it.key(), it.value());
                it = pending.erase(it);
                changed = true;
            }
        }
        if (changed) {
            entry["cookies"] = cookies;
            if (!secrets.isEmpty()) {
                entry["secrets"] = secrets;
            }
            providers[id] = entry;
        }
    };
    // 显式映射优先，默认来源最后接收剩余扁平键，避免抢走其他来源的 cookie。
    for (const auto &id : ProviderRegistry::instance().ids()) {
        apply(id, false);
    }
    for (const auto &id : ProviderRegistry::instance().ids()) {
        apply(id, true);
    }
    QJsonObject result{{"version", 2}, {"providers", providers}};
    if (!pending.isEmpty()) {
        result["legacy"] = pending;
    }
    return result;
}

/** v2 结构原样保存；旧版降级投影已移除。 */
QJsonObject Host::storageCredential(const QJsonObject &credentials) {
    return credentials;
}

/** 返回单个插件可见的 cookie；secret 注入由 manifest credentials.inject 声明。 */
QJsonObject Host::credentialCookies(const QJsonObject &credentials, const QString &provider,
                                    const QString &variant) {
    const auto entry = credentials["providers"].toObject()[provider].toObject();
    auto cookies = entry["cookies"].toObject();
    const auto secrets = entry["secrets"].toObject();
    const auto inject = ProviderRegistry::instance().credentialPolicy(provider)["inject"].toObject();
    for (auto it = inject.begin(); it != inject.end(); ++it) {
        const auto rule = it.value().toObject();
        auto path = rule["secret"].toString();
        path.replace("$variant", variant);
        const auto value = jsonValueAt(secrets, path);
        if (value.isUndefined()) {
            continue;
        }
        cookies[it.key()] = rule["object"].toBool() ? QJsonValue(value.toObject()) : value;
    }
    return cookies;
}

Host::Host(QString path, bool test, QObject *parent, bool service, PlaybackConnection *connection,
           QString isolatedCachePath)
    : QObject(parent), updater(test), root(path), offline(test), remote(test ? nullptr : connection),
      playbackOnly(service) {
#ifdef Q_OS_ANDROID
    // 只在 Android 解读宿主的内嵌开关。应用和业务层共用本次初始化的结果。
    renderOnly = qEnvironmentVariableIntValue("RHINE_QT_EMBEDDED") == 1;
#endif
    if (renderOnly) {
        ProviderRegistry::instance().load(root);
    } else {
        const auto recovery = remote ? QString() : PluginInstaller::recover(pluginRoot());
        refreshPluginCatalog();
        if (!recovery.isEmpty()) {
            marketplaceStatus = recovery;
        }
    }
    provider = ProviderRegistry::instance().defaultId();
    if (provider.isEmpty()) {
        // core-only 时 local 也可能在 ids() 中排在最前；默认来源应优先非本地来源。
        provider = ProviderRegistry::instance().fallbackId("local");
    }
    if (provider.isEmpty()) {
        provider = ProviderRegistry::instance().fallbackId();
    }
    if (provider.isEmpty()) {
        provider = "siren";
    }
    connect(&updater, &AppUpdater::changed, this, &Host::invalidate);
    if (remote) {
        connect(remote, &PlaybackConnection::pluginRuntimeFailed, this, &Host::markPluginRuntimeFailure);
        connect(remote, &PlaybackConnection::storageInvalidated, this, [this] {
            clearNetworkImages();
        });
        connect(remote, &PlaybackConnection::spectrumChanged, this, &Host::audioSpectrumChanged);
        connect(remote, &PlaybackConnection::diagnosticEvent, this,
                [this](QString event, QJsonObject values) { playbackDiagnostics.record(event, values); });
#ifdef Q_OS_MACOS
        platformInterfaceMediaCommands([this](QString action) { emit mediaAction(action); });
        connect(
            remote, &PlaybackConnection::snapshotChanged, this,
            [this] { platformInterfaceMediaInfo(!remote->snapshot()["current"].toObject().isEmpty()); },
            Qt::QueuedConnection);
#endif
    }
    const auto variants = ProviderRegistry::instance().variants(provider);
    if (!variants.isEmpty()) {
        const auto preferenceKey = ProviderRegistry::instance().variantPreference(provider);
        const auto saved = preferenceKey.isEmpty() ? QString() : preference(preferenceKey);
        bool valid = false;
        for (const auto &value : variants) {
            if (value.toObject()["id"].toString() == saved) {
                valid = true;
                break;
            }
        }
        providerVariant = valid ? saved : variants.first().toObject()["id"].toString("standard");
    }
    if ((!offline && !remote) || (offline && !isolatedCachePath.isEmpty())) {
        const auto cacheRoot = AppStorage::cacheDirectory();
        if (!cacheRoot.isEmpty() || !isolatedCachePath.isEmpty()) {
            const auto database = isolatedCachePath.isEmpty() ? cacheRoot + "/cache.sqlite" : isolatedCachePath;
            m_cacheManager = std::make_unique<CacheManager>(database);
            const auto settings = AppStorage::settings();
            const auto quota = [&settings](const QString &name, int fallback, int maximum) {
                bool valid = false;
                const auto value = settings.value("storage/" + name + "-quota-mib", fallback).toInt(&valid);
                return qint64(valid ? std::clamp(value, 0, maximum) : fallback) * 1024 * 1024;
            };
            m_cacheManager->registerNamespace("lyrics", quota("lyrics", 64, 128));
            m_cacheManager->registerNamespace("metadata", quota("metadata", 256, 256));
            if (!offline) {
                clearLegacyMetadata([](QJsonArray items) {
                    const auto result = items.at(0).toObject();
                    if (result["status"] == "failed") {
                        qWarning().noquote() << result["error"].toString();
                    }
                });
            }
        }
    }
    // 内嵌模式下 Flutter 侧持有账号，Qt 不再自取凭据（main 的 credentials 迁移逻辑保留）。
    if (!offline && !remote && !renderOnly) {
        credentials = migrateCredential(QJsonDocument::fromJson(platformCredential()).object());
    } else {
        interval = 0;
    }
    if (!offline && !remote && !renderOnly) {
        platformMediaCommands([this](QString action) {
            QMetaObject::invokeMethod(
                this, [this, action] { emit mediaAction(action); }, Qt::QueuedConnection);
        });
    }
    connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, this,
            [this] { emit invalidated(); });
    connect(&child, &BridgeProcess::started, this, [this] {
        const auto keys = pending.values();
        pending.clear();
        for (const auto &key : keys) {
            send(key);
        }
    });
    connect(&child, &BridgeProcess::errorOccurred, this, [this](BridgeProcess::ProcessError error) {
        if (error != BridgeProcess::FailedToStart) {
            return;
        }
        const auto keys = pending.values();
        pending.clear();
        for (const auto &key : keys) {
            finish(key, {}, QStringLiteral("音乐服务组件缺失，请重新构建应用"));
        }
    });
    connect(&child, &BridgeProcess::readyReadStandardOutput, this, [this] {
        buffer += child.readAllStandardOutput();
        if (buffer.size() >= 32 * 1024 * 1024) {
            child.kill();
            buffer.clear();
            return;
        }
        qsizetype end;
        while ((end = buffer.indexOf('\n')) >= 0) {
            const auto line = buffer.left(end);
            buffer.remove(0, end + 1);
            const auto response = QJsonDocument::fromJson(line).object();
            const auto id = response["id"].toString();
            if (pending.contains(id)) {
                finish(pending.take(id), response);
            }
        }
    });
    connect(&child, &BridgeProcess::finished, this, [this] {
#ifdef Q_OS_IOS
        const bool disconnected = child.error() == BridgeProcess::TransportDisconnected;
#endif
        const auto keys = pending.values();
        pending.clear();
        buffer.clear();
        for (const auto &key : keys) {
#ifdef Q_OS_IOS
            auto request = flights.find(key);
            if (disconnected && request != flights.end() && !request->retriedAfterDisconnect &&
                !request->waiters.isEmpty() && request->waiters.first().epoch == epoch) {
                const auto &route = request->route;
                const auto operation = route.section('/', 3, 3);
                const bool canRetry = route == "/local/lyrics" || route == "/song/url" ||
                                      route == "/song/url/v1" ||
                                      (route.startsWith("/native/") &&
                                       QStringList{"playback", "preview", "search", "songs", "lyrics",
                                                   "comments", "commentReplies"}.contains(operation));
                if (canRetry) {
                    // 新请求 ID 隔离旧连接上的超时定时器，原有等待者继续等待结果。
                    request->retriedAfterDisconnect = true;
                    request->id = QUuid::createUuid().toString();
                    const auto requestId = request->id;
                    const auto requestEpoch = epoch;
                    QTimer::singleShot(0, this, [this, key, requestId, requestEpoch] {
                        const auto current = flights.constFind(key);
                        if (current == flights.cend() || current->id != requestId) {
                            return;
                        }
                        if (requestEpoch == epoch) {
                            send(key);
                        } else {
                            finish(key, {}, QStringLiteral("音乐服务已退出，请重试"));
                        }
                    });
                    continue;
                }
            }
#endif
            finish(key, {}, QStringLiteral("音乐服务已退出，请重试"));
        }
    });
}
Host::~Host() {
    shutdown();
    forgetCoverCacheGeneration(this);
}
int Host::lifetime(const QString &route) {
    const auto service = routeProvider(route);
    if (service.isEmpty() || service == "other") {
        return 0;
    }
    const auto cache = ProviderRegistry::instance().cachePolicy(service);
    const auto ttlByRoute = cache["ttlByRoute"].toObject();
    if (route.startsWith("/native/") || route.startsWith("/plugin/")) {
        const auto operation = route.section('/', 3, 3);
        const auto ttl = cache["ttlByOperation"].toObject();
        if (operation == "route") {
            const auto suffix = "/" + route.section('/', 4);
            for (auto it = ttlByRoute.begin(); it != ttlByRoute.end(); ++it) {
                if (suffix == it.key() || suffix.startsWith(it.key() + "/")) {
                    return it.value().toInt();
                }
            }
            return 0;
        }
        return ttl.value(operation).toInt();
    }
    for (auto it = ttlByRoute.begin(); it != ttlByRoute.end(); ++it) {
        if (route == it.key() || route.startsWith(it.key() + "/")) {
            return it.value().toInt();
        }
    }
    return 0;
}
QString Host::cacheKey(QString scope, QString route, QJsonObject params) {
    params.remove("timestamp");
    return hash(QJsonDocument(QJsonArray{scope, route, params}).toJson(QJsonDocument::Compact));
}
/**
 * 接收原生业务请求，在协议外层执行缓存、合并和限流。
 * 记录当前账号代数，异步结果只能交付给仍有效的请求。
 */
void Host::requestJson(QString route, QJsonObject values, JsonReply callback) {
    if (remote) {
        QPointer<Host> owner(this);
        remote->request("host.request", {{"route", route}, {"values", values}},
                        [owner, callback = std::move(callback)](QJsonObject result, QString error) {
                            if (owner && !owner->stopped) {
                                callback(result, error);
                            }
                        });
        return;
    }
    if (stopped) {
        return;
    }
    if (provider == "local" && route != "/local/lyrics" &&
        !(route.startsWith("/native/") &&
          QStringList{"search", "lyrics", "songs"}.contains(route.section('/', 3, 3)))) {
        callback({}, QStringLiteral("本地模式已禁用在线平台操作"));
        return;
    }
    const auto operation = route.section('/', 3, 3);
    const bool playbackRequest =
        (route.startsWith("/native/") && (operation == "playback" || operation == "preview")) ||
        route == "/song/url" || route == "/song/url/v1";
    if (audioDiagnosticsEnabled && playbackRequest) {
        const int serial = ++diagnosticRequestSerial;
        QElapsedTimer requestClock;
        requestClock.start();
        int operationCode = 3;
        if (route.startsWith("/native/")) {
            operationCode = operation == "preview" ? 2 : 1;
        }
        const int requestProvider = ProviderRegistry::instance().diagnosticsOrdinal(routeProvider(route), 0);
        recordPlaybackDiagnostic(
            "request-start",
            {{"requestSerial", serial}, {"operation", operationCode}, {"provider", requestProvider}});
        const int diagnosticSession = playbackDiagnostics.session();
        callback = [this, diagnosticSession, callback = std::move(callback), requestClock, serial,
                    operationCode, requestProvider](QJsonObject response, QString error) {
            const auto body = response["body"].toObject();
            QJsonObject values{{"requestSerial", serial},
                               {"operation", operationCode},
                               {"provider", requestProvider},
                               {"requestDurationMs", double(requestClock.elapsed())},
                               {"transportFailed", !error.isEmpty()},
                               {"stale", response["_epoch"].toInt() != epoch},
                               {"replyBytes", QJsonDocument(response).toJson(QJsonDocument::Compact).size()}};
            if (response["_playbackDiagnosticsOmitted"].isDouble()) {
                values["omittedUpstreamEvents"] = response["_playbackDiagnosticsOmitted"];
            }
            for (const auto *key : {"code", "upstreamHttpStatus", "upstreamCode"}) {
                if (body[key].isDouble()) {
                    values[QString(key) == "code" ? "serviceCode" : key] = body[key];
                }
            }
            if (diagnosticSession == playbackDiagnostics.session()) {
                recordPlaybackDiagnostic("request-finish", values);
            }
            for (const auto &entry : response["_playbackDiagnostics"].toArray()) {
                auto upstream = PlaybackDiagnostics::numericFields(entry.toObject());
                upstream["requestSerial"] = serial;
                if (diagnosticSession == playbackDiagnostics.session()) {
                    recordPlaybackDiagnostic("upstream", upstream);
                }
            }
            response.remove("_playbackDiagnostics");
            response.remove("_playbackDiagnosticsOmitted");
            callback(response, error);
        };
    }
    const auto service = routeProvider(route);
    const auto scopedCookies = cookieSlice(service);
    const auto scopedSecrets = secretsFor(service);
    const auto scope = (scopedCookies.isEmpty() && scopedSecrets.isEmpty())
                           ? QStringLiteral("guest")
                           : hash(QJsonDocument(scopedCookies).toJson(QJsonDocument::Compact) +
                                  QJsonDocument(scopedSecrets).toJson(QJsonDocument::Compact));
    const auto cached = lifetime(route) > 0;
    const auto manifest = ProviderRegistry::instance().manifest(service);
    const auto cachePolicy = ProviderRegistry::instance().cachePolicy(service);
    const auto cacheVersion =
        cachePolicy["version"].toString(manifest["version"].toString(QStringLiteral("0")));
    const auto cacheOperation = route.section('/', 3, 3);
    const auto variant = variantFor(service);
    const auto key =
        cached
            ? cacheKey(service + ":" + cacheVersion + ":" + variant + ":" + scope + ":" +
                           QString::number(metadataRevision),
                       route, values)
            : QUuid::createUuid().toString();
    const auto diskOperations = cachePolicy["diskOperations"].toArray();
    bool diskOperation = false;
    for (const auto &value : diskOperations) {
        if (value.isString() && (value.toString() == cacheOperation || value.toString() == route ||
                                 route.startsWith(value.toString() + "/"))) {
            diskOperation = true;
            break;
        }
    }
    Waiter waiter{std::move(callback), epoch};
    if (cached && cache.contains(key) && cache[key].expiry > QDateTime::currentMSecsSinceEpoch()) {
        auto body = cache[key].body;
        QTimer::singleShot(0, this, [=, this] { respond(waiter, {{"body", body}}, {}); });
        return;
    }
    if (flights.contains(key)) {
        flights[key].waiters.append(waiter);
        return;
    }
    std::optional<CacheKey> diskKey;
    quint64 diskGeneration = 0;
    if (m_cacheManager && !offline && cached && !playbackRequest && scope == "guest" &&
        cachePolicy["disk"].toString() == "guest" && diskOperation) {
        diskKey = CacheKey{"metadata", service, QStringLiteral("guest"), cacheVersion,
                           QByteArray::fromHex(cacheKey(variant, route, values).toLatin1())};
        diskGeneration = m_cacheManager->generation("metadata");
    }
    flights.insert(key, {QUuid::createUuid().toString(), route, key, values, scopedCookies, {waiter},
                         diskKey, diskGeneration, metadataRevision});
    if (diskKey) {
        m_cacheManager->lookup(*diskKey, diskGeneration, [this, key](std::optional<QJsonObject> hit) {
            if (stopped || !flights.contains(key)) {
                return;
            }
            const auto &flight = flights[key];
            if (hit && flight.cacheRevision == metadataRevision && !flight.waiters.isEmpty() &&
                flight.waiters.first().epoch == epoch) {
                const auto work = flights.take(key);
                for (const auto &waiting : work.waiters) {
                    respond(waiting, {{"body", *hit}}, {});
                }
                return;
            }
            dispatchRequest(key);
        });
        return;
    }
    dispatchRequest(key);
}

void Host::dispatchRequest(const QString &key) {
    const auto route = flights.value(key).route;
    const auto operation = route.section('/', 3, 3);
    const auto commentRequest =
        route.startsWith("/comment/") ||
        (route.startsWith("/native/") && QStringList{"comments", "commentReplies"}.contains(operation));
    if (lifetime(route) > 0 || route == "/song/url" || route == "/song/url/v1" || commentRequest) {
        queue.enqueue(key);
        pump();
    } else {
        send(key);
    }
}

void Host::pump() {
    if (stopped || !active.isEmpty() || queue.isEmpty()) {
        return;
    }
    active = queue.dequeue();
    const auto service = routeProvider(flights[active].route);
    if (blockedUntil[service] > QDateTime::currentMSecsSinceEpoch()) {
        const auto key = active;
        QTimer::singleShot(0, this, [=, this] {
            finish(key, {}, QStringLiteral("音乐服务提示访问频繁，已暂停该平台的新请求；缓存仍可浏览"));
        });
        return;
    }
    auto key = active;
    int wait = int(qMax<qint64>(0, interval - (QDateTime::currentMSecsSinceEpoch() - lastStart)));
    QTimer::singleShot(wait, this, [=, this] {
        if (!stopped) {
            lastStart = QDateTime::currentMSecsSinceEpoch();
            send(key);
        }
    });
}
void Host::send(QString key) {
    if (!flights.contains(key) || stopped) {
        return;
    }
    auto work = flights[key];
    if (offline) {
        QTimer::singleShot(0, this, [=, this] {
            if (fixture) {
                finish(key, fixture(work.route, work.params));
            } else {
                finish(key, {}, "Offline: no local fixture for " + work.route);
            }
        });
        return;
    }
    if (child.state() == BridgeProcess::NotRunning) {
        temporary = std::make_unique<QTemporaryDir>(AppStorage::temporaryDirectory() + "/rhine-music-XXXXXX");
        if (!temporary->isValid()) {
            finish(key, {}, "无法创建音乐服务临时目录");
            return;
        }
        const auto installedPlugins = pluginRoot();
        const auto userPlugins = QFileInfo(installedPlugins).isSymLink() ? QString() : installedPlugins;
#if RHINE_MOBILE
        // 移动端由进程内的 Node 运行时执行同一个 worker，路径必须是真实文件系统路径
        // （Android 侧已把内嵌资源解包到应用私有目录，root 指向解包结果）。
        pending.insert(work.id, key);
        child.start(root, temporary->path(),
                    {{"RHINE_USER_PLUGINS", userPlugins},
                     {"RHINE_DISABLED_PLUGINS", disabledPlugins().join(',')},
                     {"RHINE_CLIENT_VERSION", PluginInstaller::clientVersion()},
                     {"RHINE_PLATFORM", PluginInstaller::platform()}});
        return;
#else
        QProcessEnvironment env;
#ifdef Q_OS_WIN
        const auto system = QProcessEnvironment::systemEnvironment();
        for (const auto &name : {"SystemRoot", "WINDIR"}) {
            if (system.contains(name)) {
                env.insert(name, system.value(name));
            }
        }
        env.insert("PATH", system.value("SystemRoot") + "/System32");
        // 上游运行时的用户目录和临时目录也限定在绿色版目录，不继承旧版缓存位置。
        env.insert("USERPROFILE", AppStorage::dataDirectory());
        env.insert("APPDATA", AppStorage::dataDirectory());
        env.insert("LOCALAPPDATA", AppStorage::dataDirectory());
        env.insert("TEMP", temporary->path());
        env.insert("TMP", temporary->path());
#else
        env.insert("PATH", "/usr/bin:/bin");
#endif
        env.insert("TMPDIR", temporary->path());
        env.insert("LANG", "en_US.UTF-8");
        env.insert("RHINE_USER_PLUGINS", userPlugins);
        env.insert("RHINE_DISABLED_PLUGINS", disabledPlugins().join(','));
        env.insert("RHINE_CLIENT_VERSION", PluginInstaller::clientVersion());
        env.insert("RHINE_PLATFORM", PluginInstaller::platform());
        child.setProcessEnvironment(env);
        // 子进程的工作目录改到应用自己的系统临时目录
        child.setWorkingDirectory(temporary->path());
        child.setStandardErrorFile(BridgeProcess::nullDevice());
        // 平台选择放在宏调用外，避免 MSVC 将条件编译指令当作宏参数。
#ifdef Q_OS_WIN
        const auto nodeName = QStringLiteral("node.exe");
#else
        const auto nodeName = QStringLiteral("node");
#endif
        pending.insert(work.id, key);
        child.start(root + "/MusicBridge/" + nodeName, {root + "/MusicBridge/worker.cjs"});
#endif
        return;
    }
    if (child.state() == BridgeProcess::Starting) {
        pending.insert(work.id, key);
        return;
    }
    pending.insert(work.id, key);
    const auto service = routeProvider(work.route);
    const auto serviceVariant = variantFor(service);
    // 排队期间可能完成登录/设备注册；发送前重新读取最新凭据切片。
    work.cookies = cookieSlice(service);
    const auto dataDir = AppStorage::dataDirectory() + "/plugin-data/" + service;
    QDir().mkpath(dataDir);
    QJsonObject env;
    const auto runtimeEnv = ProviderRegistry::instance().runtimeConfig(service)["env"].toObject();
    for (auto it = runtimeEnv.begin(); it != runtimeEnv.end(); ++it) {
        auto value = it.value().toString();
        value.replace("$variant", serviceVariant);
        value.replace("$dataDir", dataDir);
        env.insert(it.key(), value);
    }
    QJsonObject envelope{
        {"id", work.id},
        {"route", work.route},
        {"params", work.params},
        {"cookies", work.cookies},
        {"env", env},
        {"authenticated", authMatches(service, work.cookies, secretsFor(service), serviceVariant)}};
    if (audioDiagnosticsEnabled && work.route.startsWith("/native/") &&
        QStringList{"playback", "preview"}.contains(work.route.section('/', 3, 3))) {
        envelope["_collectPlaybackDiagnostics"] = true;
    }
    child.write(QJsonDocument(envelope).toJson(QJsonDocument::Compact) + '\n');
    QTimer::singleShot(30000, this, [=, this] {
        if (pending.remove(work.id)) {
            finish(key, {}, "音乐请求超时，请重试");
        }
    });
}
void Host::finish(QString key, QJsonObject response, QString error) {
    if (!flights.contains(key)) {
        return;
    }
    const auto work = flights.take(key);
    const auto service = routeProvider(work.route);
    const auto failure = response.take("_pluginLoadFailure").toObject();
    if (failure["provider"] == service && failure["errorKey"] == "plugin.load-failed") {
        markPluginRuntimeFailure(service, failure["message"].toString());
    }
    // 插件私有 secret 由 manifest 声明，只持久化到当前 provider 切片，不进入 UI 回调。
    const auto responseSecrets =
        ProviderRegistry::instance().credentialPolicy(service)["responseSecrets"].toObject();
    bool secretsChanged = false;
    if (!responseSecrets.isEmpty() && !work.waiters.isEmpty() && work.waiters.first().epoch == epoch) {
        auto secrets = secretsFor(service);
        for (auto it = responseSecrets.begin(); it != responseSecrets.end(); ++it) {
            if (!response.contains(it.key())) {
                continue;
            }
            auto path = it.value().toString();
            path.replace("$variant", variantFor(service));
            setJsonPath(secrets, path.split('.', Qt::SkipEmptyParts), 0, response[it.key()]);
            secretsChanged = true;
        }
        if (secretsChanged) {
            setSecretsFor(service, secrets);
            saveCredential();
        }
    }
    for (auto it = responseSecrets.begin(); it != responseSecrets.end(); ++it) {
        response.remove(it.key());
    }
    response.remove("_credentialKey");
    const auto body = response["body"].toObject();
    const auto code = body["code"].toInt(200);
    const auto expiredCodes =
        ProviderRegistry::instance().credentialPolicy(service)["auth"].toObject()["expiredCodes"].toArray();
    if (expiredCodes.contains(QJsonValue(code))) {
        response["authExpired"] = true;
    }
    const auto commentRequest =
        work.route.startsWith("/comment/") ||
        (work.route.startsWith("/native/") &&
         QStringList{"comments", "commentReplies"}.contains(work.route.section('/', 3, 3)));
    if (lifetime(work.route) || work.route == "/song/url" || work.route == "/song/url/v1" || commentRequest) {
        const auto message = body["message"].toString(body["msg"].toString());
        if (QList<int>{405, 429, 509}.contains(code) || message.contains("频繁")) {
            blockedUntil[routeProvider(work.route)] =
                QDateTime::currentMSecsSinceEpoch() + qMax(120000LL, qint64(body["retryAfterMs"].toDouble()));
        }
        if (work.cacheRevision == metadataRevision && lifetime(work.route) && error.isEmpty() &&
            response["body"].isObject() && code == 200) {
            Entry entry{QDateTime::currentMSecsSinceEpoch() + lifetime(work.route) * 1000LL, body};
            cache.insert(key, entry);
            const int maxEntries =
                qMax(1, ProviderRegistry::instance().cachePolicy(service)["maxEntries"].toInt(256));
            if (cache.size() > maxEntries) {
                for (auto it = cache.begin(); it != cache.end();) {
                    if (it->expiry <= QDateTime::currentMSecsSinceEpoch()) {
                        it = cache.erase(it);
                    } else {
                        ++it;
                    }
                }
                if (cache.size() > maxEntries) {
                    cache.erase(cache.begin());
                }
            }
            if (work.diskKey && !work.waiters.isEmpty() && work.waiters.first().epoch == epoch &&
                cacheAccountScope(service) == "guest" && response["cookies"].toArray().isEmpty() &&
                !response.contains("cookie") && !response["authExpired"].toBool() && !secretsChanged) {
                m_cacheManager->store(*work.diskKey, work.diskGeneration, body,
                                      lifetime(work.route) * 1000LL, {},
                                      [](const QJsonObject &value) { return isDiskCachePayload(value); });
            }
        }
    }
    for (auto waiter : work.waiters) {
        respond(waiter, response, error);
    }
    if (active == key) {
        active.clear();
        pump();
    }
}
void Host::respond(const Waiter &waiter, QJsonObject response, QString error) {
    if (stopped) {
        return;
    }
    response["_epoch"] = waiter.epoch;
    waiter.callback(response, error);
}
/**
 * 只接受当前账号代数对应的 Cookie，避免过期请求覆盖新登录。
 */
void Host::acceptCookies(QString json, int responseEpoch, QString credentialKey, QString provider) {
    const auto target = provider.isEmpty() ? this->provider : provider;
    if (remote) {
        remote->call("host.acceptCookies", {{"json", json},
                                            {"epoch", responseEpoch},
                                            {"credentialKey", credentialKey},
                                            {"provider", target}});
        return;
    }
    if (responseEpoch != epoch || stopped) {
        return;
    }
    Q_UNUSED(credentialKey)
    bool changed = false;
    auto cookies = cookiesFor(target);
    for (auto line : QJsonDocument::fromJson(json.toUtf8()).array()) {
        for (auto cookie : QNetworkCookie::parseCookies(line.toString().toUtf8())) {
            const auto name = QString::fromUtf8(cookie.name());
            const auto value = QString::fromUtf8(cookie.value());
            changed |= cookies[name].toString() != value;
            cookies[name] = value;
        }
    }
    if (changed) {
        setCookiesFor(target, cookies);
    }
    // 登录/刷新后的 cookie 或 secret 更新才落盘；guest cookie 不污染账号存储。
    if (changed && authMatches(target, cookies, secretsFor(target), variantFor(target))) {
        saveCredential();
    }
}
void Host::schedule(int ms, std::function<void()> callback) {
    QTimer::singleShot(qMax(0, ms), this, [this, callback = std::move(callback)] {
        if (!stopped) {
            callback();
        }
    });
}
bool Host::authenticated() const {
    return hasCredential(provider);
}
bool Host::hasCredential(QString value) const {
    if (remote) {
        return remote->snapshot()["credentials"].toObject()[value].toBool();
    }
    if (!ProviderRegistry::instance().contains(value)) {
        return false;
    }
    return authMatches(value, cookiesFor(value), secretsFor(value), variantFor(value));
}
/**
 * 登录成功、重置登录或切换账号后作废所有旧代数请求；
 * GUI 与服务必须同步递增，否则后续 Cookie 会被服务端当作过期响应丢弃。
 */
void Host::bumpEpoch() {
    if (remote) {
        remote->call("host.bumpEpoch");
    }
    ++epoch;
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS) || defined(Q_OS_WIN)
    cancelAppleTransition();
#endif
}
QJsonObject Host::cookiesFor(const QString &value) const {
    return credentials["providers"].toObject()[value].toObject()["cookies"].toObject();
}
void Host::setCookiesFor(const QString &value, const QJsonObject &cookies) {
    if (!credentials.contains("version")) {
        credentials["version"] = 2;
    }
    auto providers = credentials["providers"].toObject();
    auto entry = providers[value].toObject();
    entry["cookies"] = cookies;
    providers[value] = entry;
    credentials["providers"] = providers;
}
QJsonObject Host::secretsFor(const QString &value) const {
    return credentials["providers"].toObject()[value].toObject()["secrets"].toObject();
}
void Host::setSecretsFor(const QString &value, const QJsonObject &secrets) {
    if (!credentials.contains("version")) {
        credentials["version"] = 2;
    }
    auto providers = credentials["providers"].toObject();
    auto entry = providers[value].toObject();
    if (secrets.isEmpty()) {
        entry.remove("secrets");
    } else {
        entry["secrets"] = secrets;
    }
    providers[value] = entry;
    credentials["providers"] = providers;
}
QJsonObject Host::cookieSlice(const QString &value) const {
    return credentialCookies(credentials, value, variantFor(value));
}
QString Host::variantFor(const QString &value) const {
    if (value == provider) {
        return providerVariant;
    }
    const auto variants = ProviderRegistry::instance().variants(value);
    const auto preferenceKey = ProviderRegistry::instance().variantPreference(value);
    if (!preferenceKey.isEmpty()) {
        const auto saved = preference(preferenceKey);
        for (const auto &variant : variants) {
            if (variant.toObject()["id"].toString() == saved) {
                return saved;
            }
        }
    }
    return variants.isEmpty() ? QString() : variants.first().toObject()["id"].toString("standard");
}
/**
 * 切换音乐来源，保持各来源的凭据与缓存隔离。
 */
void Host::setProvider(QString value) {
    if (!ProviderRegistry::instance().contains(value)) {
        return;
    }
    if (remote) {
        remote->call("host.setProvider", {{"provider", value}});
    }
    if (provider == value) {
        return;
    }
    provider = value;
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS) || defined(Q_OS_WIN)
    cancelAppleTransition();
#endif
    const auto variants = ProviderRegistry::instance().variants(provider);
    if (!variants.isEmpty()) {
        const auto preferenceKey = ProviderRegistry::instance().variantPreference(provider);
        const auto saved = preferenceKey.isEmpty() ? QString() : preference(preferenceKey);
        bool valid = false;
        for (const auto &item : variants) {
            if (item.toObject()["id"].toString() == saved) {
                valid = true;
                break;
            }
        }
        providerVariant = valid ? saved : variants.first().toObject()["id"].toString("standard");
    }
    ++epoch;
    ++metadataRevision;
    cache.clear();
    images.clear();
    thumbnailImages.clear();
    coverFlights.clear();
}
/**
 * 切换插件变体；具体变体语义由插件 manifest/凭据槽决定，core 只负责隔离请求代数。
 */
void Host::setProviderVariant(QString variant) {
    const auto variants = ProviderRegistry::instance().variants(provider);
    if (!variants.isEmpty()) {
        bool valid = false;
        for (const auto &value : variants) {
            if (value.toObject()["id"].toString() == variant) {
                valid = true;
                break;
            }
        }
        if (!valid) {
            return;
        }
    }
    if (variant == providerVariant) {
        return;
    }
    if (remote) {
        remote->call("host.setProviderVariant", {{"variant", variant}});
    }
    providerVariant = variant;
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS) || defined(Q_OS_WIN)
    cancelAppleTransition();
#endif
    const auto preference = ProviderRegistry::instance().variantPreference(provider);
    if (!preference.isEmpty()) {
        setPreference(preference, variant);
    }
    ++epoch;
    ++metadataRevision;
    cache.clear();
    images.clear();
    thumbnailImages.clear();
    coverFlights.clear();
    if (child.state() != BridgeProcess::NotRunning) {
        child.kill();
        child.waitForFinished(1000);
    }
}
void Host::reloadPlugins() {
    refreshPluginCatalog(true);
    updateMarketplaceComparisons();
    if (!remote && child.state() != BridgeProcess::NotRunning) {
        child.kill();
        child.waitForFinished(1000);
    }
    const auto variants = ProviderRegistry::instance().variants(provider);
    if (!variants.isEmpty()) {
        bool validVariant = false;
        for (const auto &value : variants) {
            if (value.toObject()["id"].toString() == providerVariant) {
                validVariant = true;
                break;
            }
        }
        if (!validVariant) {
            const auto preferenceKey = ProviderRegistry::instance().variantPreference(provider);
            const auto saved = preferenceKey.isEmpty() ? QString() : preference(preferenceKey);
            bool selectedSaved = false;
            for (const auto &value : variants) {
                if (value.toObject()["id"].toString() == saved) {
                    providerVariant = saved;
                    selectedSaved = true;
                    break;
                }
            }
            if (!selectedSaved) {
                providerVariant = variants.first().toObject()["id"].toString("standard");
            }
        }
    }
    // 插件版本变化后旧元数据、封面和限流状态不再代表当前实现。
    const auto generationState = coverCacheGenerationState(this);
    {
        std::lock_guard<std::mutex> lock(generationState->mutex);
        ++imageCacheGeneration;
        generationState->generation = imageCacheGeneration;
    }
    cache.clear();
    images.clear();
    thumbnailImages.clear();
    coverFlights.clear();
    blockedUntil.clear();
    ++metadataRevision;
    emit pluginsReloaded();
    emit invalidated();
}
QString Host::saveCredential() {
    if (remote) {
        return remote->call("host.saveCredential")["value"].toString();
    }
    return offline ? QString()
                   : platformSaveCredential(
                         QJsonDocument(storageCredential(credentials)).toJson(QJsonDocument::Compact));
}
/**
 * 作废当前来源的请求并清理凭据，另一来源的账号保持独立。
 */
void Host::logout() {
    if (remote) {
        remote->call("host.logout");
        ++epoch;
        cache.clear();
        images.clear();
        thumbnailImages.clear();
        coverFlights.clear();
        return;
    }
    mediaControl("stop");
    auto providers = credentials["providers"].toObject();
    const auto variants = ProviderRegistry::instance().variants(provider);
    if (variants.isEmpty()) {
        providers.remove(provider);
    } else {
        // 变体凭据按 variant 分槽；退出当前变体不能清除同来源的其他变体登录态。
        auto entry = providers.value(provider).toObject();
        auto secrets = entry["secrets"].toObject();
        secrets.remove(providerVariant);
        entry["cookies"] = QJsonObject{};
        if (secrets.isEmpty()) {
            providers.remove(provider);
        } else {
            entry["secrets"] = secrets;
            providers[provider] = entry;
        }
    }
    credentials["providers"] = providers;
    ++epoch;
    // 结束进程同时关闭插件的长连接；其他来源的持久凭据仍保留。
    if (child.state() != BridgeProcess::NotRunning) {
        child.kill();
        child.waitForFinished(1000);
    }
    cache.clear();
    images.clear();
    thumbnailImages.clear();
    coverFlights.clear();
    if (!offline) {
        bool any = false;
        for (auto it = providers.begin(); it != providers.end(); ++it) {
            const auto entry = it.value().toObject();
            any |= !entry["cookies"].toObject().isEmpty() || !entry["secrets"].toObject().isEmpty();
        }
        if (any) {
            saveCredential();
        } else {
            platformDeleteCredential();
        }
    }
}
void Host::loadCover(QString input, TextReply callback, int maximumDimension, bool allowPlaybackOnly) {
    const bool thumbnail = maximumDimension <= CoverThumbnailDimension;
    const auto dimension = std::clamp(maximumDimension, CoverThumbnailDimension, 1024);
    // 后台默认只保留封面地址；系统媒体控件需要封面文件时显式放行解码。
    if (playbackOnly && !allowPlaybackOnly) {
        schedule(0, [input, callback] { callback(input); });
        return;
    }
    const QUrl local(input);
    if (local.isLocalFile()) {
        if (provider != "local" && !offline &&
            !(remote && remote->snapshot()["current"].toObject()["provider"] == "local")) {
            return;
        }
        const auto key =
            thumbnail ? "cover-thumb:" + hash(input.toUtf8()) + ":" + QString::number(dimension) : input;
        auto &memoryCache = thumbnail ? thumbnailImages : images;
        if (memoryCache.contains(key)) {
            callback(key);
            return;
        }
        const auto generation = epoch;
        auto watcher = new QFutureWatcher<QImage>(this);
        connect(watcher, &QFutureWatcher<QImage>::finished, this,
                [this, watcher, generation, key, thumbnail, callback] {
                    const auto image = watcher->result();
                    watcher->deleteLater();
                    if (generation == epoch && !stopped) {
                        if (!image.isNull()) {
                            auto &target = thumbnail ? thumbnailImages : images;
                            target.insert(key, new QImage(image), qMax(1, int(image.sizeInBytes() / 1024)));
                        }
                        callback(image.isNull() ? QString() : key);
                    }
                });
        watcher->setFuture(QtConcurrent::run([path = local.toLocalFile(), dimension] {
            QImageReader reader(path);
            const auto size = reader.size();
            if (!size.isValid() || size.width() > 8192 || size.height() > 8192) {
                return QImage();
            }
            if (size.width() > dimension || size.height() > dimension) {
                reader.setScaledSize(size.scaled(dimension, dimension, Qt::KeepAspectRatio));
            }
            return reader.read();
        }));
        return;
    }
    QUrl url(input.replace("http://", "https://"));
    const auto domain = url.host();
    const auto patterns = ProviderRegistry::instance().coverHosts();
    const auto allowed = [&domain, &patterns] {
        for (const auto &pattern : patterns) {
            if (pattern == domain) {
                return true;
            }
            if (pattern.startsWith("*.") && domain.endsWith(pattern.mid(1))) {
                return true;
            }
        }
        return false;
    }();
    if (!allowed) {
        callback({});
        return;
    }
    // 解码尺寸保持调用方要求；网易云网络请求统一使用 512/1024 两档缩略图。
    const auto requestUrl = coverRequestUrl(url, dimension);
    const auto urlKey = requestUrl.toString();
    const auto key =
        thumbnail ? "cover-thumb:" + hash(urlKey.toUtf8()) + ":" + QString::number(dimension) : urlKey;
    auto &memoryCache = thumbnail ? thumbnailImages : images;
    if (memoryCache.contains(key)) {
        callback(key);
        return;
    }
    const auto imageEpoch = epoch;
    const auto imageGeneration = imageCacheGeneration;
    const auto generationState = coverCacheGenerationState(this);
    // epoch 也进入 flight 键，账号切换后不能复用上一账号仍在进行的封面请求。
    const auto flightKey = QString::number(imageGeneration) + ':' + QString::number(imageEpoch) + ':' + key;
    if (coverFlights.contains(flightKey)) {
        coverFlights[flightKey].append({callback, epoch});
        return;
    }
    coverFlights[flightKey] = {{callback, epoch}};
    cleanupLegacyCoverCaches();
    const auto cachePath = coverCachePath(urlKey, thumbnail, dimension);
    const auto failFlight = [this, flightKey] {
        const auto waiters = coverFlights.take(flightKey);
        for (const auto &waiter : waiters) {
            if (waiter.epoch == epoch) {
                waiter.callback({});
            }
        }
    };
    const auto completeFlight = [this, key, cachePath, flightKey, imageEpoch, imageGeneration, generationState,
                                 thumbnail](QImage image, QByteArray sourceBytes = {}) {
        const auto waiters = coverFlights.take(flightKey);
        // 账号切换后旧响应既不能进入内存缓存，也不能通知当前账号的 waiter。
        if (stopped || imageEpoch != epoch || imageGeneration != imageCacheGeneration || image.isNull()) {
            for (const auto &waiter : waiters) {
                if (waiter.epoch == epoch) {
                    waiter.callback({});
                }
            }
            return;
        }
        auto &target = thumbnail ? thumbnailImages : images;
        target.insert(key, new QImage(image), qMax(1, int(image.sizeInBytes() / 1024)));
        if (!sourceBytes.isEmpty() && !cachePath.isEmpty()) {
            const auto budget = thumbnail ? CoverThumbnailCacheBudgetBytes : CoverCacheBudgetBytes;
            (void)QtConcurrent::run([cachePath, image, budget, generationState, imageGeneration] {
                storeCoverCache(cachePath, image, budget, generationState, imageGeneration);
            });
        }
        for (const auto &waiter : waiters) {
            if (waiter.epoch == epoch) {
                waiter.callback(key);
            }
        }
    };
    const auto requestNetwork = [this, requestUrl, cachePath, dimension, failFlight, completeFlight] {
        if (offline) {
            failFlight();
            return;
        }
        QNetworkRequest request(requestUrl);
        request.setTransferTimeout(20000);
        request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                             QNetworkRequest::NoLessSafeRedirectPolicy);
        auto reply = network.get(request);
        connect(reply, &QNetworkReply::downloadProgress, reply, [reply](qint64 size, qint64) {
            if (size >= CoverCacheEntryLimitBytes) {
                reply->abort();
            }
        });
        connect(reply, &QNetworkReply::finished, this,
                [this, reply, cachePath, dimension, failFlight, completeFlight]() {
                    const auto bytes = reply->readAll();
                    const bool valid =
                        reply->error() == QNetworkReply::NoError &&
                        reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 200 &&
                        bytes.size() < CoverCacheEntryLimitBytes;
                    reply->deleteLater();
                    if (!valid) {
                        failFlight();
                        return;
                    }
                    // 解码在工作线程执行，结果和持久化仍由 Host 生命周期内完成。
                    auto watcher = new QFutureWatcher<QImage>(this);
                    connect(watcher, &QFutureWatcher<QImage>::finished, this,
                            [watcher, bytes, completeFlight] {
                                const auto image = watcher->result();
                                watcher->deleteLater();
                                completeFlight(image, bytes);
                            });
                    watcher->setFuture(
                        QtConcurrent::run([bytes, dimension] { return decodeCover(bytes, dimension); }));
                });
    };
    if (!cachePath.isEmpty() && QFileInfo::exists(cachePath)) {
        auto watcher = new QFutureWatcher<QImage>(this);
        connect(watcher, &QFutureWatcher<QImage>::finished, this,
                [this, watcher, cachePath, dimension, completeFlight, requestNetwork] {
                    const auto image = watcher->result();
                    watcher->deleteLater();
                    if (image.isNull()) {
                        QFile::remove(cachePath);
                        requestNetwork();
                        return;
                    }
                    touchCoverCache(cachePath);
                    completeFlight(image);
                });
        watcher->setFuture(QtConcurrent::run([cachePath, dimension] {
            QFile file(cachePath);
            if (!file.open(QIODevice::ReadOnly) || file.size() >= CoverCacheEntryLimitBytes) {
                return QImage();
            }
            return decodeCover(file.readAll(), dimension);
        }));
        return;
    }
    requestNetwork();
}
QString Host::qrImage(QString data) {
    if (data.size() > 8 * 1024 * 1024 ||
        !QRegularExpression("^data:image/(png|jpeg|gif|webp);base64,").match(data).hasMatch()) {
        return {};
    }
    const auto bytes = QByteArray::fromBase64(data.mid(data.indexOf(',') + 1).toLatin1());
    auto value = QImage::fromData(bytes);
    if (value.isNull() || value.width() > 4096 || value.height() > 4096) {
        return {};
    }
    const auto key = "login-qr:" + hash(bytes);
    images.insert(key, new QImage(value), int(value.sizeInBytes() / 1024));
    return key;
}
QString Host::qr(QString text) {
    auto name = "qr:" + hash(text.toUtf8());
    images.insert(name, new QImage(platformQR(text)), 1024);
    return name;
}
QImage Host::image(const QString &key) const {
    // 质量徽章由插件 manifest quality.badges 指向插件内相对资产；core 不写平台文件名。
    static const QRegularExpression qualityKey("^quality:([a-z0-9-]{1,40}):([A-Za-z0-9_-]{1,40})$");
    const auto match = qualityKey.match(key);
    if (match.hasMatch()) {
        static QCache<QString, QImage> badges(32);
        if (auto cached = badges.object(key)) {
            return *cached;
        }
        const auto provider = match.captured(1);
        const auto badge = match.captured(2);
        const auto quality = ProviderRegistry::instance().descriptor(provider)["quality"].toObject();
        auto relative = quality["badges"].toObject()[badge].toString();
        if (relative.isEmpty()) {
            relative = "assets/quality/" + badge + ".png";
        }
        if (!PluginInstaller::relativePath(relative)) {
            return {};
        }
        const QStringList roots{AppStorage::dataDirectory() + "/plugins/" + provider,
                                root + "/MusicBridge/local-plugins/" + provider};
        QImage image;
        for (const auto &base : roots) {
            image = QImage(base + "/" + relative);
            if (!image.isNull()) {
                break;
            }
        }
        if (image.isNull()) {
            image = QImage(root + "/quality/" + provider + "-" + badge + ".png");
        }
        badges.insert(key, new QImage(image), 32);
        return image;
    }
    auto p = key.startsWith(QLatin1String("cover-thumb:")) ? thumbnailImages.object(key) : images.object(key);
    return p ? *p : QImage();
}
void Host::trimMemory(const QStringList &retainedImages) {
    QHash<QString, QImage> retained;
    for (const auto &key : retainedImages) {
        const auto pixels = image(key);
        if (!pixels.isNull()) {
            retained.insert(key, pixels);
        }
    }
    // 请求结果仍可从磁盘按需读取；保留当前 HUD 图片，避免恢复后二维码或封面空白。
    cache.clear();
    images.clear();
    thumbnailImages.clear();
    int retainedCost = 0;
    int thumbnailCost = 0;
    for (auto it = retained.cbegin(); it != retained.cend(); ++it) {
        const auto cost = qMax(1, int(it->sizeInBytes() / 1024));
        if (it.key().startsWith(QLatin1String("cover-thumb:"))) {
            thumbnailCost += cost;
        } else {
            retainedCost += cost;
        }
    }
    // 渲染预算
    images.setMaxCost(qMax(4 * 1024, retainedCost));
    thumbnailImages.setMaxCost(qMax(2 * 1024, thumbnailCost));
    for (auto it = retained.begin(); it != retained.end(); ++it) {
        auto &target = it.key().startsWith(QLatin1String("cover-thumb:")) ? thumbnailImages : images;
        target.insert(it.key(), new QImage(it.value()), qMax(1, int(it->sizeInBytes() / 1024)));
    }
}
void Host::fixtureImage(const QString &key, const QImage &image) {
    // 仅离线窗口验收可注入本地封面，不读取账号或访问封面服务器。
    if (offline && !image.isNull()) {
        auto &target = key.startsWith(QLatin1String("cover-thumb:")) ? thumbnailImages : images;
        target.insert(key, new QImage(image), int(image.sizeInBytes() / 1024));
    }
}
void Host::playOfficial(QString id, TextReply callback) {
    if (!PlatformFeatures::OfficialPlayback) {
        callback(QStringLiteral("当前平台仅支持面板内播放"));
        return;
    }
    if (!QRegularExpression("^[0-9]{1,20}$").match(id).hasMatch()) {
        callback("请先选择一首歌曲");
        return;
    }
    if (offline) {
        callback("OFFLINE_PLAY:" + id);
        return;
    }
    const auto config = ProviderRegistry::instance().externalPlayback(provider);
    if (config["type"].toString() != "url-scheme" || config["scheme"].toString().isEmpty()) {
        callback(QStringLiteral("当前来源不支持官方客户端"));
        return;
    }
    QPointer<Host> guarded(this);
    platformPlay(id, config, activates(), [guarded, callback](QString message) mutable {
        if (guarded && !guarded->stopped) {
            callback(message);
        }
    });
}
bool Host::mediaLoad(QString url, bool alternative, double position, bool paused) {
    if (renderOnly) {
        // 内嵌：Flutter 的 BasicAudioChannel 是唯一播放通道，这里连 AudioPlayer 都不建，
        // 否则会在内嵌进程里多出一个 QMediaPlayer（及其 Android MediaPlayer 的 mContext 根）。
        return false;
    }
    if (remote) {
        return remote
            ->call("host.mediaLoad", {{"url", url},
                                      {"alternative", alternative},
                                      {"position", position},
                                      {"paused", paused}})["value"]
            .toBool();
    }
    if (!audio) {
        audio = std::make_unique<AudioPlayer>([this] { emit mediaChanged(); });
        audio->diagnosticEvent = [this](const QString &event, const QJsonObject &values) {
            recordPlaybackDiagnostic(event, values);
        };
        if constexpr (!PlatformFeatures::NativeAppleAudio) {
            audio->setOutputPolicy(preference("audio-output-policy") == "source"
                                       ? AudioOutputFormat::Policy::Source
                                       : AudioOutputFormat::Policy::System);
        }
        audio->enableDiagnostics(audioDiagnosticsEnabled);
        audio->spectrumChanged = [this](QJsonArray levels) { emit audioSpectrumChanged(levels); };
        audio->enableSpectrum(audioSpectrumEnabled);
    }
#if RHINE_SENTRY
    auto *trace = RhineSentry::beginPlaybackPreparation();
    const bool prepared = audio->load(url, offline, alternative, provider, position, paused);
    RhineSentry::finishPlaybackPreparation(trace, prepared);
    return prepared;
#else
    return audio->load(url, offline, alternative, provider, position, paused);
#endif
}
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS) || defined(Q_OS_WIN)
void Host::setAppleTransitionPreparation(AppleTransitionPreparation preparation) {
    if (appleTransitionPreparation == preparation) {
        return;
    }
    appleTransitionPreparation = preparation;
    if (audioDiagnosticsEnabled) {
        recordPlaybackDiagnostic("transition-prepare", playbackSnapshot());
    }
}

bool Host::prepareAppleTransition(const QUrl &next, bool alternative) {
    if (!audio || !audio->prepareAppleTransition(next, offline, alternative, provider)) {
        setAppleTransitionPreparation(AppleTransitionPreparation::PlaybackUnavailable);
        return false;
    }
    setAppleTransitionPreparation(AppleTransitionPreparation::Accepted);
    audio->appleTransitionCommitted = [this] { emit appleTransitionCommitted(); };
    return true;
}

void Host::cancelAppleTransition() {
    if (audio) {
        audio->cancelAppleTransition();
    }
    setAppleTransitionPreparation(AppleTransitionPreparation::WaitingForPlayback);
}
#endif

void Host::mediaControl(QString action, double value) {
    if (renderOnly) {
        return;
    }
    if (remote) {
        remote->call("host.mediaControl", {{"action", action}, {"value", value}});
        return;
    }
    if (action == "volume" && !PlatformFeatures::ApplicationVolume) {
        value = 1.0;
    }
    if (action == "spectrum") {
        audioSpectrumEnabled = value > 0;
        if (audio) {
            audio->enableSpectrum(audioSpectrumEnabled);
        }
        return;
    }
    if (!audio && action == "volume") {
        audio = std::make_unique<AudioPlayer>([this] { emit mediaChanged(); });
        audio->diagnosticEvent = [this](const QString &event, const QJsonObject &values) {
            recordPlaybackDiagnostic(event, values);
        };
        if constexpr (!PlatformFeatures::NativeAppleAudio) {
            audio->setOutputPolicy(preference("audio-output-policy") == "source"
                                       ? AudioOutputFormat::Policy::Source
                                       : AudioOutputFormat::Policy::System);
        }
        audio->enableDiagnostics(audioDiagnosticsEnabled);
        audio->spectrumChanged = [this](QJsonArray levels) { emit audioSpectrumChanged(levels); };
        audio->enableSpectrum(audioSpectrumEnabled);
    }
    if (audio) {
        audio->control(action, value);
    }
    emit mediaChanged();
}
void Host::mediaMetadata(QString title, QString artist, QString album, const QString &coverUrl) {
    mediaTitle = title.left(256);
    mediaArtist = artist.left(256);
    mediaAlbum = album.left(256);
    if (coverUrl != mediaCoverUrl) {
        mediaCoverUrl = coverUrl;
        refreshMediaCover();
    }
    lastMediaUpdate = 0;
}

/** 把当前曲目的封面取到本地（系统媒体控件的 artwork 需要真实文件/位图，不能是远端地址）。
 *  复用 loadCover 的下载与去重，把回调拿到的键反查回 QImage 缓存再落盘。 */
void Host::refreshMediaCover() {
    if (renderOnly) {
        return;
    }
    mediaCoverPath.clear();
    if (mediaCoverUrl.isEmpty()) {
        lastMediaUpdate = 0;
        return;
    }
    loadCover(
        mediaCoverUrl,
        [this](QString key) {
            const QImage *image = key.isEmpty() ? nullptr : images.object(key);
            if (!image || image->isNull()) {
                return;
            }
            const auto path = AppStorage::cacheDirectory() + "/media-cover.png";
            if (image->save(path, "PNG")) {
                mediaCoverPath = path;
                // 下一秒的常规上报会把封面带给平台媒体控件。
                lastMediaUpdate = 0;
            }
        },
        512, true);
}
bool Host::isMusicPlaybackRequested() const {
    if (remote) {
        const auto &snapshot = remote->snapshot();
        const auto state = snapshot.value("state").toObject();
        const bool preparing = snapshot.value("preparingPlayback").toBool(snapshot.value("loading").toBool());
        return preparing || state.value("playing").toBool() ||
               state.value("requested").toBool();
    }
    return audio && audio->isPlaybackRequested();
}

QVariantMap Host::mediaState() const {
    if (remote) {
        return remote->snapshot()["state"].toObject().toVariantMap();
    }
    auto state = audio ? audio->state() : QVariantMap();
    auto now = QDateTime::currentMSecsSinceEpoch();
    if (!offline && now - lastMediaUpdate >= 1000) {
        lastMediaUpdate = now;
        platformMediaInfo(mediaTitle, mediaArtist, mediaAlbum, state, mediaCoverPath);
    }
    return state;
}
void Host::copy(QString text) {
    QGuiApplication::clipboard()->setText(text);
}
void Host::open(QString url) {
    if (!offline && QUrl(url).scheme() == "https") {
        QDesktopServices::openUrl(QUrl(url));
    }
}
bool Host::systemDark() const {
    return QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark;
}
void Host::invalidateMetadata() {
    if (remote) {
        remote->call("host.invalidateMetadata");
        return;
    }
    clearMetadata([](QJsonArray) {});
}

/** 先作废内存请求，再在后台清理旧版磁盘缓存。清理期间暂停磁盘读写。 */
void Host::clearMetadata(StorageCoordinator::Completion done) {
    ++metadataRevision;
    cache.clear();
    if (offline) {
        done({StorageCoordinator::result("metadata", "cleared")});
        return;
    }
    if (m_cacheManager) {
        m_cacheManager->clear("metadata", [this, done](QJsonObject database) {
            clearLegacyMetadata([done, database](QJsonArray results) {
                results.append(database);
                done(results);
            });
        });
        return;
    }
    clearLegacyMetadata(std::move(done));
}

void Host::clearLegacyMetadata(StorageCoordinator::Completion done) {
    auto *watcher = new QFutureWatcher<QJsonObject>(this);
    connect(watcher, &QFutureWatcher<QJsonObject>::finished, this, [this, watcher, done] {
        const auto result = watcher->result();
        watcher->deleteLater();
        done({result});
    });
    watcher->setFuture(QtConcurrent::run([path = AppStorage::cacheDirectory() + "/metadata"] {
        const QFileInfo directory(path);
        if (directory.isSymLink() || (directory.exists() && !directory.isReadable())) {
            return StorageCoordinator::result("legacy-metadata", "failed", QStringLiteral("无法读取缓存目录"));
        }
        const QDir metadata(path);
        const QRegularExpression key(QStringLiteral("^[0-9a-f]{64}\\.json$"));
        qint64 releasedBytes = 0;
        int removed = 0;
        int failed = 0;
        for (const auto &entry : metadata.entryInfoList(QDir::Files | QDir::NoSymLinks)) {
            if (!key.match(entry.fileName()).hasMatch()) {
                continue;
            }
            // Linux 删除目录项后 QFileInfo::size() 可能已变为 0，必须在落盘删除前记录释放量。
            const auto fileBytes = entry.size();
            if (QFile::remove(entry.absoluteFilePath())) {
                releasedBytes += fileBytes;
                ++removed;
            } else if (QFileInfo::exists(entry.absoluteFilePath())) {
                ++failed;
            }
        }
        auto result = StorageCoordinator::result(
            "legacy-metadata", failed ? "failed" : "cleared",
            failed ? QStringLiteral("无法移除 %1 个元数据文件").arg(failed) : QString());
        result["entries"] = removed;
        result["removedFileBytes"] = releasedBytes;
        return result;
    }));
}

QJsonObject Host::clearNetworkImages() {
    const auto generationState = coverCacheGenerationState(this);
    std::lock_guard<std::mutex> generationLock(generationState->mutex);
    ++imageCacheGeneration;
    generationState->generation = imageCacheGeneration;
    const auto costBefore = images.totalCost() + thumbnailImages.totalCost();
    int removed = 0;
    for (const auto &key : images.keys()) {
        if (key.startsWith(QLatin1String("https://")) && images.remove(key)) {
            ++removed;
        }
    }
    removed += thumbnailImages.size();
    thumbnailImages.clear();
    qint64 diskBytes = 0;
    const auto coverCache = coverCacheDirectory();
    if (!coverCache.isEmpty()) {
        QDir directory(coverCache);
        if (directory.exists()) {
            QDirIterator files(coverCache, QDir::Files | QDir::NoSymLinks, QDirIterator::Subdirectories);
            while (files.hasNext()) {
                files.next();
                diskBytes += files.fileInfo().size();
            }
            directory.removeRecursively();
        }
    }
    auto result = StorageCoordinator::result("network-images", "cleared");
    result["entries"] = removed;
    result["memoryBytes"] = (costBefore - images.totalCost() - thumbnailImages.totalCost()) * 1024LL;
    result["diskBytes"] = diskBytes;
    return result;
}
/** 清除可重建的缓存；登录凭据、账号设置与本地音乐库保持不变。 */
void Host::clearCache() {
    clearNetworkImages();
    if (remote) {
        remote->request("host.clearCache", {}, [](QJsonObject, QString) {});
        return;
    }
    invalidateMetadata();
    // QML 与渲染管线的磁盘缓存由框架按需重建，交给持有渲染生命周期的界面处理。
}
namespace {
// 可读写的偏好键。读取与写入必须共用同一份名单：两份名单一旦分叉，写入会成功但读回
// 为空，界面上的表现就是"设置完立刻跳回原值"。
const QStringList &preferenceKeys() {
    static const QStringList keys{
#if RHINE_SENTRY
        QString::fromLatin1(RhineSentry::ConsentKey),
#endif
        "search-history", "play-history", "local-cover-cache", "theme", "motion", "startup-animation",
        "detail-autoplay", "skip-detail-on-switch", "single-play-mode", "disc-rotation", "scene-enhancement",
        "play-button-style", "ui-sounds", "text-scale",
        "archive-mask-strength", "debug-mode", "audio-exclusive", "graphics-backend", "mv-auto", "mv-opacity",
        "mv-screen", "mv-offsets", "mv-versions", "mv-mode", "global-shortcuts", "global-shortcuts-enabled",
        // Linux 显卡选择：存的是 /sys/class/drm 里 cardN 的序号（0 基），不是型号。
        // 换卡后序号可能指向另一张卡或不存在，启动时由 initializeLinuxGraphics 校验并回退。
        "gpu-index", "vsync", "supersample", "render-scale", "aa-mode", "aa-scale", "msaa", "fsr-quality",
        "fsr-sharpness", "fg", "close-behavior", "auto-update", "volume", "quality", "alternate-source",
#if !defined(Q_OS_MACOS) && !defined(Q_OS_IOS)
        "audio-output-policy",
#endif
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS) || defined(Q_OS_WIN)
        "apple-smart-transition",
#endif
        "provider", "lyrics-cache", "lyrics-global-offset-ms", "desktop-lyrics", "desktop-lyrics-size",
        "desktop-lyrics-translation-size", "desktop-lyrics-opacity", "desktop-lyrics-line-color",
        "desktop-lyrics-translation-color", "desktop-lyrics-line-weight", "desktop-lyrics-translation-weight",
        "desktop-lyrics-line-outline", "desktop-lyrics-translation-outline",
        "desktop-lyrics-line-outline-color", "desktop-lyrics-translation-outline-color",
#if defined(Q_OS_MACOS)
        "menu-bar-layout",
        MacMenuBar::EnabledPreference, MacMenuBar::ControlsPreference, MacMenuBar::IconPreference,
        MacMenuBar::WidthPreference, MacMenuBar::TranslationPreference,
#endif
    };
    return keys;
}
}
QString Host::preference(QString key) const {
#if RHINE_SENTRY
    if (key == QLatin1String(RhineSentry::ConsentKey)) {
        return offline ? QString() : RhineSentry::preference();
    }
#endif
    if (remote) {
        if (!remotePreferences.contains(key)) {
            const auto value = remote->call("host.preference", {{"key", key}})["value"].toString();
            if (remote->error().isEmpty()) {
                remotePreferences.insert(key, value);
            }
            return value;
        }
        return remotePreferences.value(key);
    }
    if (offline || !isPreferenceKey(key)) {
        return {};
    }
    return AppStorage::settings().value("panel/" + key).toString();
}

void Host::readPreferenceAsync(const QString &key, TextReply callback) {
    if (!remote || remotePreferences.contains(key)) {
        callback(preference(key));
        return;
    }
    remote->request("host.preference", {{"key", key}},
                    [owner = QPointer(this), key, callback = std::move(callback)](const QJsonObject &result,
                                                                                const QString &error) {
        if (!owner) {
            return;
        }
        if (error.isEmpty() && !owner->remotePreferences.contains(key)) {
            owner->remotePreferences.insert(key, result.value("value").toString());
        }
        callback(owner->remotePreferences.value(key));
    });
}

void Host::setPreference(QString key, QString value) {
#if RHINE_SENTRY
    if (key == QLatin1String(RhineSentry::ConsentKey)) {
        if (offline || !RhineSentry::savePreference(value)) {
            return;
        }
        // 先保存共享开关，后台连接中断也不能让遥测在下次启动时恢复。
        if (remote && value == QLatin1String(RhineSentry::DisabledPreference)) {
            remote->request("host.stopSentry", {}, [](QJsonObject, QString) {});
        }
        emit preferenceChanged(key, value);
        return;
    }
#endif
    if (remote) {
        remote->call("host.setPreference", {{"key", key}, {"value", value}});
        if (!remote->error().isEmpty()) {
            return;
        }
        remotePreferences.remove(key);
        // 后台服务只负责持久化；GUI 进程仍要应用渲染配置的热切换，否则设置页读到了新值，
        // 性能面板与渲染器却还停留在旧状态。
        if (key == QLatin1String("fg")) {
            RhineFg::applyInterpolationPreference(value);
        }
        emit preferenceChanged(key, value);
        return;
    }
    if (key == "audio-output-policy") {
        if (PlatformFeatures::NativeAppleAudio || (value != "system" && value != "source")) {
            return;
        }
        if (audio) {
            audio->setOutputPolicy(value == "source" ? AudioOutputFormat::Policy::Source
                                                     : AudioOutputFormat::Policy::System);
        }
    }
    if (!offline && value.size() < 262144 && isPreferenceKey(key)) {
        AppStorage::settings().setValue("panel/" + key, value);
        // 帧生成开关是唯一"不必重启也能生效"的偏好：呈现层每帧解析 RHINE_FG，
        // 所以这里写完磁盘再同步一次环境变量，设置页点一下就切换插值。
        // 具体转换在 RhineFg::applyInterpolationPreference（有单测）。
        if (key == QLatin1String("fg")) {
            RhineFg::applyInterpolationPreference(value);
        }
        emit preferenceChanged(key, value);
    }
}
QString Host::writeStoragePreference(const QString &key, const QString &value) {
    if (offline) {
        return {};
    }
    if (remote || !isPreferenceKey(key)) {
        return QStringLiteral("当前进程无法写入此存储项");
    }
    auto settings = AppStorage::settings();
    settings.setValue("panel/" + key, value);
    settings.sync();
    if (settings.status() != QSettings::NoError) {
        return QStringLiteral("无法保存存储项 %1").arg(key);
    }
    emit preferenceChanged(key, value);
    return {};
}

void Host::forgetPreference(const QString &key) {
    remotePreferences.remove(key);
}

CacheManager *Host::cacheManager() const {
    return m_cacheManager.get();
}

QString Host::cacheAccountScope(const QString &service) const {
    const auto cookies = cookieSlice(service);
    const auto secrets = secretsFor(service);
    if (cookies.isEmpty() && secrets.isEmpty() && !hasCredential(service)) {
        return QStringLiteral("guest");
    }
    return QStringLiteral("account");
}

QString Host::cacheVariant(const QString &service) const {
    return variantFor(service);
}

QByteArray Host::cacheScopeIdentity(const QString &service) const {
    const QJsonArray state{cookieSlice(service), secretsFor(service)};
    return QCryptographicHash::hash(QJsonDocument(state).toJson(QJsonDocument::Compact),
                                    QCryptographicHash::Sha256);
}

bool Host::isPreferenceKey(const QString &key) {
    if (preferenceKeys().contains(key)) {
        return true;
    }
    for (const auto *prefix : {"welcome-name-", "account-id-", "provider-variant-", "provider-option-"}) {
        const QString head = QString::fromLatin1(prefix);
        if (!key.startsWith(head)) {
            continue;
        }
        const auto suffix = key.mid(head.size());
        for (const auto &id : ProviderRegistry::instance().ids()) {
            if (suffix == id || suffix.startsWith(id + "-")) {
                return true;
            }
        }
    }
    return false;
}
bool Host::activates() const {
    return offline ? false : platformActivates();
}
void Host::setActivates(bool value) {
    if (!offline) {
        platformSetActivates(value);
    }
}
QString Host::asset(QString name) const {
    return QUrl::fromLocalFile(root + "/" + name).toString();
}
QString Host::read(QString name) const {
    QFile f(root + "/" + name);
    if (!f.open(QIODevice::ReadOnly)) {
        return {};
    }
    return QString::fromUtf8(f.readAll());
}
/**
 * 停止桥接子进程并释放等待请求，避免退出后仍有回调。
 */
void Host::shutdown() {
    if (remote) {
#ifdef Q_OS_MACOS
        platformInterfaceMediaCommands({});
#endif
        stopped = true;
        return;
    }
    if (stopped) {
        return;
    }
    stopped = true;
    coverFlights.clear();
    if (!offline) {
        platformMediaCommands({});
        platformMediaInfo({}, {}, {}, {});
    }
    audio.reset();
    disconnect(&child, nullptr, this, nullptr);
    child.closeWriteChannel();
    if (child.state() != BridgeProcess::NotRunning) {
        child.terminate();
        if (!child.waitForFinished(2000)) {
            child.kill();
            child.waitForFinished(2000);
        }
    }
    flights.clear();
    pending.clear();
    queue.clear();
    temporary.reset();
}

/** 性能面板按需开启解码统计，网络只读取系统公开的枚举状态，不枚举地址或网络名称。 */
void Host::enablePlaybackDiagnostics(bool enabled) {
    if (remote) {
        remote->call("host.diagnostics", {{"enabled", enabled}});
        return;
    }
    audioDiagnosticsEnabled = enabled;
    if (enabled && !QNetworkInformation::instance()) {
        QNetworkInformation::loadDefaultBackend();
    }
    if (audio) {
        audio->enableDiagnostics(enabled);
    }
}

QJsonObject Host::playbackSnapshot() const {
    if (remote) {
        return remote->snapshot()["diagnostics"].toObject();
    }
    auto values = audio ? audio->diagnosticState() : QJsonObject();
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS) || defined(Q_OS_WIN)
    values["transitionPreparation"] = int(appleTransitionPreparation);
#endif
    values["bridgeState"] = int(child.state());
    values["bridgeError"] = int(child.error());
    const auto *information = QNetworkInformation::instance();
    if (information) {
        if (information->supports(QNetworkInformation::Feature::Reachability)) {
            values["networkReachability"] = int(information->reachability());
        }
        if (information->supports(QNetworkInformation::Feature::TransportMedium)) {
            values["networkTransport"] = int(information->transportMedium());
        }
        if (information->supports(QNetworkInformation::Feature::Metered)) {
            values["networkMetered"] = information->isMetered();
        }
        if (information->supports(QNetworkInformation::Feature::CaptivePortal)) {
            values["networkCaptive"] = information->isBehindCaptivePortal();
        }
    }
    return PlaybackDiagnostics::numericFields(values);
}

void Host::recordPlaybackDiagnostic(const QString &event, const QJsonObject &values) {
    const auto safe = PlaybackDiagnostics::numericFields(values);
    playbackDiagnostics.record(event, safe);
    emit playbackDiagnostic(event, safe);
}
