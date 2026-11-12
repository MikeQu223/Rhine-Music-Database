#include "fg/FgConfig.h"
#include "Host.h"
#include "ProviderRegistry.h"
#include "AppStorage.h"
#include <QBuffer>
#include <QClipboard>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
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
#include <QPointer>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStyleHints>
#include <QUrlQuery>
#include <QUuid>
#include <QtConcurrentRun>
#include <cmath>

static QString hash(QByteArray value) {
    return QCryptographicHash::hash(value, QCryptographicHash::Sha256).toHex();
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
static bool reservedPluginId(const QString &id) {
    return id == "local" || id == "siren";
}
static bool validPluginId(const QString &id) {
    static const QRegularExpression pattern("^[a-z0-9-]{1,40}$");
    return pattern.match(id).hasMatch() && !reservedPluginId(id);
}
static bool pluginRelativeFile(const QString &file) {
    return !file.isEmpty() && !QDir::isAbsolutePath(file) && !file.contains("..") && !file.contains('\\');
}
static bool compatiblePluginApi(const QString &version) {
    static const QRegularExpression pattern("^(\\d+)\\.(\\d+)$");
    const auto match = pattern.match(version);
    return match.hasMatch() && match.captured(1).toInt() == 2 && match.captured(2).toInt() <= 0;
}
/** 市场安装前按 worker Registry 的同一组硬性条件校验 manifest。 */
static bool validPluginManifest(const QJsonObject &manifest) {
    if (manifest["schemaVersion"].toInt() != 2) {
        return false;
    }
    if (!validPluginId(manifest["id"].toString()) || manifest["version"].toString().isEmpty() ||
        !compatiblePluginApi(manifest["apiVersion"].toString())) {
        return false;
    }
    const auto display = manifest["display"].toObject();
    if (display["name"].toString().isEmpty() || !manifest["capabilities"].isObject()) {
        return false;
    }
    if (!pluginRelativeFile(manifest["entry"].toObject()["file"].toString())) {
        return false;
    }
    const auto routes = manifest["routes"].toObject();
    for (const auto *key : {"legacyRoutes", "prefixes"}) {
        const auto values = routes[key];
        if (values.isUndefined()) {
            continue;
        }
        if (!values.isArray()) {
            return false;
        }
        for (const auto &value : values.toArray()) {
            if (!value.isString() || !value.toString().startsWith('/')) {
                return false;
            }
        }
    }
    return true;
}
static bool copyPluginDirectory(const QString &source, const QString &destination) {
    QDir sourceDirectory(source);
    if (!QDir().mkpath(destination)) {
        return false;
    }
    const auto entries = sourceDirectory.entryInfoList(
        QDir::Dirs | QDir::Files | QDir::Hidden | QDir::NoDotAndDotDot, QDir::Name);
    for (const auto &entry : entries) {
        if (entry.fileName() == ".git") {
            continue;
        }
        const auto target = destination + "/" + entry.fileName();
        if (entry.isDir()) {
            if (!copyPluginDirectory(entry.absoluteFilePath(), target)) {
                return false;
            }
        } else if (entry.isFile() && !QFile::copy(entry.absoluteFilePath(), target)) {
            return false;
        }
    }
    return true;
}

/** 插件目录改名；Windows 上杀毒或索引服务可能短暂持有刚写入的文件，失败时重试。 */
static bool movePluginDirectory(const QString &source, const QString &target) {
    if (QDir().rename(source, target)) {
        return true;
    }
    for (int attempt = 0; attempt < 20; ++attempt) {
        QThread::msleep(100);
        if (QDir().rename(source, target)) {
            return true;
        }
    }
    return false;
}

/** 提交 staging 目录；改名持续被占用时退化为逐文件复制，避免 Windows 上安装直接失败。 */
static bool commitPluginDirectory(const QString &staging, const QString &target) {
    if (movePluginDirectory(staging, target)) {
        return true;
    }
    // 目录已存在时不能覆盖，交给上层保留原安装。
    if (QDir(target).exists()) {
        return false;
    }
    for (int attempt = 0; attempt < 5; ++attempt) {
        QDir(target).removeRecursively();
        if (copyPluginDirectory(staging, target)) {
            QDir(staging).removeRecursively();
            return true;
        }
        QThread::msleep(200);
    }
    QDir(target).removeRecursively();
    return false;
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
Host::Host(QString path, bool test, QObject *parent, bool service, PlaybackConnection *connection)
    : QObject(parent), updater(test), root(path), offline(test), remote(test ? nullptr : connection),
      playbackOnly(service) {
    ProviderRegistry::instance().load(root, AppStorage::dataDirectory() + "/plugins", disabledPlugins());
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
    if (!offline && !remote) {
        credentials = migrateCredential(QJsonDocument::fromJson(platformCredential()).object());
    } else {
        interval = 0;
    }
    if (!offline && !remote) {
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
        const auto keys = pending.values();
        pending.clear();
        buffer.clear();
        for (const auto &key : keys) {
            finish(key, {}, QStringLiteral("音乐服务已退出，请重试"));
        }
    });
}
Host::~Host() {
    shutdown();
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
    return hash((scope + route).toUtf8() + QJsonDocument(params).toJson(QJsonDocument::Compact));
}
QString Host::diskPath(QString key) const {
    return AppStorage::cacheDirectory() + "/metadata/" + key + ".json";
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
        const int requestProvider =
            ProviderRegistry::instance().diagnosticsOrdinal(routeProvider(route), 0);
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
    const auto scope =
        (scopedCookies.isEmpty() && scopedSecrets.isEmpty())
            ? QStringLiteral("guest")
            : hash(QJsonDocument(scopedCookies).toJson(QJsonDocument::Compact) +
                   QJsonDocument(scopedSecrets).toJson(QJsonDocument::Compact));
    const auto cached = lifetime(route) > 0;
    const auto manifest = ProviderRegistry::instance().manifest(service);
    const auto cachePolicy = ProviderRegistry::instance().cachePolicy(service);
    const auto cacheVersion =
        cachePolicy["version"].toString(manifest["version"].toString(QStringLiteral("0")));
    const auto cacheOperation = route.section('/', 3, 3);
    const auto key =
        cached
            ? cacheKey(service + ":" + cacheVersion + ":" + scope + QString::number(metadataRevision),
                       route, values)
            : QUuid::createUuid().toString();
    const auto diskOperations = cachePolicy["diskOperations"].toArray();
    bool diskOperation = false;
    for (const auto &value : diskOperations) {
        if (value.isString() &&
            (value.toString() == cacheOperation || value.toString() == route ||
             route.startsWith(value.toString() + "/"))) {
            diskOperation = true;
            break;
        }
    }
    const bool disk = !offline && scope == QStringLiteral("guest") &&
                      cachePolicy["disk"].toString(QStringLiteral("none")) == QStringLiteral("guest") &&
                      diskOperation;
    Waiter waiter{std::move(callback), epoch};
    if (disk && !cache.contains(key)) {
        QFile f(diskPath(key));
        if (f.open(QIODevice::ReadOnly)) {
            auto obj = QJsonDocument::fromJson(f.readAll()).object();
            cache.insert(key, {qint64(obj["expiry"].toDouble()), obj["body"].toObject()});
        }
    }
    if (cached && cache.contains(key) && cache[key].expiry > QDateTime::currentMSecsSinceEpoch()) {
        auto body = cache[key].body;
        QTimer::singleShot(0, this, [=, this] { respond(waiter, {{"body", body}}, {}); });
        return;
    }
    if (flights.contains(key)) {
        flights[key].waiters.append(waiter);
        return;
    }
    flights.insert(key, {QUuid::createUuid().toString(),
                         route,
                         key,
                         values,
                         scopedCookies,
                         {waiter},
                         disk,
                         metadataRevision});
    const auto commentRequest =
        route.startsWith("/comment/") ||
        (route.startsWith("/native/") && QStringList{"comments", "commentReplies"}.contains(operation));
    if (cached || route == "/song/url" || route == "/song/url/v1" || commentRequest) {
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
#if RHINE_MOBILE
        // 移动端由进程内的 Node 运行时执行同一个 worker，路径必须是真实文件系统路径
        // （Android 侧已把内嵌资源解包到应用私有目录，root 指向解包结果）。
        pending.insert(work.id, key);
        child.start(root, temporary->path(),
                    {{"RHINE_USER_PLUGINS", AppStorage::dataDirectory() + "/plugins"},
                     {"RHINE_DISABLED_PLUGINS", disabledPlugins().join(',')}});
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
        env.insert("RHINE_USER_PLUGINS", AppStorage::dataDirectory() + "/plugins");
        env.insert("RHINE_DISABLED_PLUGINS", disabledPlugins().join(','));
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
    QJsonObject envelope{{"id", work.id},
                         {"route", work.route},
                         {"params", work.params},
                         {"cookies", work.cookies},
                         {"env", env},
                         {"authenticated",
                          authMatches(service, work.cookies, secretsFor(service), serviceVariant)}};
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
    const auto expiredCodes = ProviderRegistry::instance()
                                  .credentialPolicy(service)["auth"]
                                  .toObject()["expiredCodes"]
                                  .toArray();
    if (expiredCodes.contains(QJsonValue(code))) {
        response["authExpired"] = true;
    }
    const auto commentRequest =
        work.route.startsWith("/comment/") ||
        (work.route.startsWith("/native/") &&
         QStringList{"comments", "commentReplies"}.contains(work.route.section('/', 3, 3)));
    if (lifetime(work.route) || work.route == "/song/url" || work.route == "/song/url/v1" ||
        commentRequest) {
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
            if (work.disk) {
                auto path = diskPath(key);
                QDir().mkpath(QFileInfo(path).path());
                QFile::setPermissions(QFileInfo(path).path(),
                                      QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
                QSaveFile f(path);
                if (f.open(QIODevice::WriteOnly)) {
                    f.setPermissions(QFile::ReadOwner | QFile::WriteOwner);
                    f.write(QJsonDocument(QJsonObject{{"expiry", double(entry.expiry)}, {"body", body}})
                                .toJson(QJsonDocument::Compact));
                    f.commit();
                }
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
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
    return variants.isEmpty() ? QString()
                              : variants.first().toObject()["id"].toString("standard");
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
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
    coverFlights.clear();
    if (child.state() != BridgeProcess::NotRunning) {
        child.kill();
        child.waitForFinished(1000);
    }
}
QJsonArray Host::installedPluginManifests() const {
    QMap<QString, QJsonObject> byId;
    const QStringList roots{AppStorage::dataDirectory() + "/plugins",
                            QDir(root).absoluteFilePath("MusicBridge/local-plugins")};
    for (const auto &directory : roots) {
        QDir plugins(directory);
        if (!plugins.exists()) {
            continue;
        }
        for (const auto &entry : plugins.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name)) {
            if (entry.fileName().startsWith('.')) {
                continue;
            }
            QFile manifestFile(entry.absoluteFilePath() + "/manifest.json");
            if (!manifestFile.open(QIODevice::ReadOnly)) {
                continue;
            }
            const auto manifest = QJsonDocument::fromJson(manifestFile.readAll()).object();
            const auto id = manifest["id"].toString();
            if (id.isEmpty() || id == "local" || id == "siren" || byId.contains(id)) {
                continue;
            }
            byId.insert(id, manifest);
        }
    }
    QJsonArray values;
    for (const auto &manifest : byId) {
        values.append(manifest);
    }
    return values;
}
QStringList Host::disabledPlugins() const {
    QFile file(AppStorage::dataDirectory() + "/plugins-state.json");
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }
    const auto document = QJsonDocument::fromJson(file.readAll()).object();
    const auto disabled = document["disabled"].toArray();
    QStringList values;
    for (const auto &value : disabled) {
        if (value.isString()) {
            values.append(value.toString());
        }
    }
    return values;
}
void Host::writeDisabledPlugins(const QStringList &disabled) {
    const auto directory = AppStorage::dataDirectory();
    if (!QDir().mkpath(directory)) {
        return;
    }
    const auto path = directory + "/plugins-state.json";
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        return;
    }
    file.write(QJsonDocument(QJsonObject{{"disabled", QJsonArray::fromStringList(disabled)}})
                   .toJson(QJsonDocument::Compact));
    file.close();
    QFile::setPermissions(path, QFile::ReadOwner | QFile::WriteOwner);
}
QJsonArray Host::pluginManagerState() const {
    const auto disabled = disabledPlugins();
    QJsonArray values;
    for (const auto &manifest : installedPluginManifests()) {
        const auto value = manifest.toObject();
        const auto id = value["id"].toString();
        values.append(QJsonObject{
            {"id", id},
            {"name", value["display"].toObject()["name"].toString(id)},
            {"version", value["version"].toString()},
            {"publisher", value["publisher"].toString()},
            {"license", value["license"].toString()},
            {"enabled", !disabled.contains(id)},
            {"userInstalled", QDir(AppStorage::dataDirectory() + "/plugins/" + id).exists()},
        });
    }
    return values;
}
QJsonObject Host::pluginDetail(QString id) const {
    for (const auto &manifest : installedPluginManifests()) {
        const auto value = manifest.toObject();
        if (value["id"].toString() == id) {
            auto result = value;
            result["enabled"] = !disabledPlugins().contains(id);
            result["installed"] = true;
            result["userInstalled"] = QDir(AppStorage::dataDirectory() + "/plugins/" + id).exists();
            return result;
        }
    }
    for (const auto &entry : marketplacePlugins) {
        const auto value = entry.toObject();
        if (value["id"].toString() == id) {
            auto result = value;
            result["enabled"] = true;
            result["installed"] = false;
            return result;
        }
    }
    return {};
}
QString Host::marketplaceUrl() const {
    static const QString fallback =
        QStringLiteral("https://raw.githubusercontent.com/MikeQu223/Rhine-Plugin-Market/main/index.json");
    const auto configured = qEnvironmentVariable("RHINE_PLUGIN_MARKETPLACE_URL");
    return configured.isEmpty() ? fallback : configured;
}
QJsonObject Host::pluginMarketplaceState() const {
    return {{"url", marketplaceUrl()},
            {"loading", marketplaceLoading},
            {"installing", marketplaceInstalling},
            {"installId", marketplaceInstallId},
            {"installFile", marketplaceInstallFile},
            {"installFilesDone", marketplaceInstallFilesDone},
            {"installFilesTotal", marketplaceInstallFilesTotal},
            {"installBytes", double(marketplaceInstallBytes)},
            {"installSpeed", marketplaceInstallSpeed},
            {"installProgress", marketplaceInstallProgress},
            {"status", marketplaceStatus},
            {"plugins", marketplacePlugins}};
}
void Host::updateMarketplaceInstallProgress(bool force) {
    if (!marketplaceInstalling) {
        return;
    }
    const auto now = QDateTime::currentMSecsSinceEpoch();
    const auto elapsed = qMax<qint64>(1, now - marketplaceInstallStartedAt);
    marketplaceInstallSpeed = marketplaceInstallBytes * 1000.0 / elapsed;
    const double current =
        marketplaceInstallFileTotal > 0
            ? qBound(0.0, double(marketplaceInstallFileBytes) / marketplaceInstallFileTotal, 1.0)
            : 0.0;
    marketplaceInstallProgress =
        marketplaceInstallFilesTotal > 0
            ? qBound(0.0, (marketplaceInstallFilesDone + current) / marketplaceInstallFilesTotal, 1.0)
            : 0.0;
    if (force || now - marketplaceInstallLastEmit >= 200) {
        marketplaceInstallLastEmit = now;
        emit invalidated();
    }
}
void Host::refreshPluginMarketplace() {
    const auto url = marketplaceUrl();
    if (url.isEmpty()) {
        marketplaceStatus = QStringLiteral("未配置插件市场地址");
        emit invalidated();
        return;
    }
    if (marketplaceLoading) {
        return;
    }
    marketplaceLoading = true;
    marketplaceStatus = QStringLiteral("正在读取插件市场…");
    emit invalidated();
    const auto apply = [this](const QByteArray &bytes) {
        const auto document = QJsonDocument::fromJson(bytes).object();
        QJsonArray plugins;
        for (const auto &entry : document["plugins"].toArray()) {
            const auto value = entry.toObject();
            const auto id = value["id"].toString();
            const auto path = value["path"].toString();
            if (!value["id"].isString() || !validPluginId(id) || !value["path"].isString() ||
                !pluginRelativeFile(path)) {
                continue;
            }
            plugins.append(value);
        }
        marketplacePlugins = plugins;
        marketplaceStatus =
            QStringLiteral("已载入 ") + QString::number(plugins.size()) + QStringLiteral(" 个插件");
        marketplaceLoading = false;
        emit invalidated();
    };
    if (url.startsWith("file:")) {
        QFile file(QUrl(url).toLocalFile());
        if (!file.open(QIODevice::ReadOnly)) {
            marketplaceLoading = false;
            marketplaceStatus = QStringLiteral("插件市场读取失败");
            emit invalidated();
            return;
        }
        apply(file.readAll());
        return;
    }
    QNetworkRequest request{QUrl(url)};
    request.setTransferTimeout(20000);
    auto reply = network.get(request);
    QTimer::singleShot(20000, reply, [reply] {
        if (!reply->isFinished()) {
            reply->abort();
        }
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, apply] {
        const auto bytes = reply->readAll();
        const auto ok = reply->error() == QNetworkReply::NoError &&
                        reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 200 &&
                        bytes.size() < 8 * 1024 * 1024;
        reply->deleteLater();
        marketplaceLoading = false;
        if (!ok) {
            marketplaceStatus = QStringLiteral("插件市场读取失败");
            emit invalidated();
            return;
        }
        apply(bytes);
    });
}
void Host::downloadPluginFile(const QString &url, const QString &path, std::function<void(QString)> done) {
    if (url.startsWith("file:")) {
        QFile source(QUrl(url).toLocalFile());
        if (!source.open(QIODevice::ReadOnly)) {
            done(QStringLiteral("插件文件缺失"));
            return;
        }
        const auto bytes = source.readAll();
        QDir().mkpath(QFileInfo(path).path());
        QSaveFile file(path);
        if (!file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size() || !file.commit()) {
            done(QStringLiteral("写入插件文件失败"));
            return;
        }
        marketplaceInstallFileBytes = bytes.size();
        marketplaceInstallFileTotal = bytes.size();
        marketplaceInstallBytes += bytes.size();
        updateMarketplaceInstallProgress(true);
        done({});
        return;
    }
    QNetworkRequest request{QUrl(url)};
    request.setTransferTimeout(30000);
    auto reply = network.get(request);
    connect(reply, &QNetworkReply::downloadProgress, this, [this](qint64 received, qint64 total) {
        if (!marketplaceInstalling) {
            return;
        }
        if (total > 0) {
            marketplaceInstallFileTotal = total;
        }
        if (received > marketplaceInstallFileBytes) {
            marketplaceInstallBytes += received - marketplaceInstallFileBytes;
            marketplaceInstallFileBytes = received;
        }
        updateMarketplaceInstallProgress();
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, path, done] {
        const auto bytes = reply->readAll();
        const auto code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const auto ok =
            reply->error() == QNetworkReply::NoError && code == 200 && bytes.size() < 64 * 1024 * 1024;
        reply->deleteLater();
        if (!ok) {
            done(QStringLiteral("下载失败：") + QUrl(path).fileName());
            return;
        }
        if (bytes.size() > marketplaceInstallFileBytes) {
            marketplaceInstallBytes += bytes.size() - marketplaceInstallFileBytes;
            marketplaceInstallFileBytes = bytes.size();
        }
        updateMarketplaceInstallProgress(true);
        QDir().mkpath(QFileInfo(path).path());
        QSaveFile file(path);
        if (!file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size() || !file.commit()) {
            done(QStringLiteral("写入插件文件失败"));
            return;
        }
        done({});
    });
}
void Host::downloadPluginFiles(QStringList files, QString base, QString directory, QString id,
                               std::function<void(QString)> done) {
    auto step = std::make_shared<std::function<void(int)>>();
    auto finish = [step, done](const QString &error) {
        done(error);
        QTimer::singleShot(0, [step] { *step = nullptr; });
    };
    *step = [this, files = std::move(files), base = std::move(base), directory = std::move(directory),
             id = std::move(id), step, finish](int index) {
        if (index >= files.size()) {
            finish({});
            return;
        }
        Q_UNUSED(id)
        const auto name = files.at(index);
        if (name.isEmpty() || QDir::isAbsolutePath(name) || name.contains("..") || name.contains('\\')) {
            finish(QStringLiteral("插件文件路径无效"));
            return;
        }
        marketplaceInstallFile = name;
        marketplaceInstallFileBytes = 0;
        marketplaceInstallFileTotal = 0;
        updateMarketplaceInstallProgress(true);
        downloadPluginFile(base + "/" + name, directory + "/" + name,
                           [this, step, finish, index](QString error) {
                               if (!error.isEmpty()) {
                                   finish(error);
                               } else {
                                   marketplaceInstallFileBytes = 0;
                                   marketplaceInstallFileTotal = 0;
                                   ++marketplaceInstallFilesDone;
                                   updateMarketplaceInstallProgress(true);
                                   (*step)(index + 1);
                               }
                           });
    };
    (*step)(0);
}
QString Host::installMarketplacePlugin(QString id) {
    QJsonObject entry;
    for (const auto &value : marketplacePlugins) {
        if (value.toObject()["id"].toString() == id) {
            entry = value.toObject();
            break;
        }
    }
    if (entry.isEmpty()) {
        return QStringLiteral("插件市场中没有该插件");
    }
    if (marketplaceInstalling) {
        return QStringLiteral("正在安装插件，请稍候");
    }
    const auto url = marketplaceUrl();
    const auto base = url.left(url.lastIndexOf('/'));
    const auto folder = entry["path"].toString("plugins/" + id);
    QStringList files{QStringLiteral("manifest.json")};
    const auto entryFile = entry["entry"].toObject()["file"].toString();
    if (!entryFile.isEmpty()) {
        files.append(entryFile);
    }
    for (const auto &value : entry["files"].toArray()) {
        const auto name = value.isString() ? value.toString() : value.toObject()["path"].toString();
        if (!name.isEmpty()) {
            files.append(name);
        }
    }
    files.removeDuplicates();
    const auto userDirectory = AppStorage::dataDirectory() + "/plugins";
    const auto staging = userDirectory + "/.staging-" + id + "-" + QUuid::createUuid().toString();
    QDir().mkpath(staging);
    marketplaceInstalling = true;
    marketplaceInstallId = id;
    marketplaceInstallFile.clear();
    marketplaceInstallFilesDone = 0;
    marketplaceInstallFilesTotal = files.size();
    marketplaceInstallBytes = 0;
    marketplaceInstallFileBytes = 0;
    marketplaceInstallFileTotal = 0;
    marketplaceInstallStartedAt = QDateTime::currentMSecsSinceEpoch();
    marketplaceInstallLastEmit = 0;
    marketplaceInstallSpeed = 0;
    marketplaceInstallProgress = 0;
    marketplaceStatus = QStringLiteral("正在安装 ");
    marketplaceStatus += entry["name"].toString(id);
    updateMarketplaceInstallProgress(true);
    downloadPluginFiles(files, base + "/" + folder, staging, id,
                        [this, id, staging, userDirectory, entry](QString error) {
                            if (!error.isEmpty()) {
                                marketplaceInstalling = false;
                                QDir(staging).removeRecursively();
                                marketplaceStatus = error;
                                emit invalidated();
                                return;
                            }
                            QFile manifestFile(staging + "/manifest.json");
                            if (!manifestFile.open(QIODevice::ReadOnly)) {
                                marketplaceInstalling = false;
                                QDir(staging).removeRecursively();
                                marketplaceStatus = QStringLiteral("插件 manifest 缺失");
                                emit invalidated();
                                return;
                            }
                            const auto manifest = QJsonDocument::fromJson(manifestFile.readAll()).object();
                            const auto manifestEntry = manifest["entry"].toObject()["file"].toString();
                            const auto indexEntry = entry["entry"].toObject()["file"].toString();
                            if (manifest["id"].toString() != id || !validPluginManifest(manifest) ||
                                (!indexEntry.isEmpty() && indexEntry != manifestEntry) ||
                                !QFile::exists(staging + "/" + manifestEntry)) {
                                marketplaceInstalling = false;
                                QDir(staging).removeRecursively();
                                marketplaceStatus = QStringLiteral("插件 manifest 与市场条目不一致");
                                emit invalidated();
                                return;
                            }
                            const auto target = userDirectory + "/" + id;
                            const auto backup = userDirectory + "/.backup-" + id;
                            QDir().mkpath(userDirectory);
                            QDir(backup).removeRecursively();
                            bool moved = false;
                            if (QDir(target).exists()) {
                                if (!movePluginDirectory(target, backup)) {
                                    marketplaceInstalling = false;
                                    QDir(staging).removeRecursively();
                                    marketplaceStatus = QStringLiteral("无法替换已安装插件");
                                    emit invalidated();
                                    return;
                                }
                                moved = true;
                            }
                            if (!commitPluginDirectory(staging, target)) {
                                if (moved) {
                                    movePluginDirectory(backup, target);
                                }
                                marketplaceInstalling = false;
                                QDir(staging).removeRecursively();
                                marketplaceStatus = QStringLiteral("插件安装失败");
                                emit invalidated();
                                return;
                            }
                            marketplaceInstallProgress = 1;
                            marketplaceInstallSpeed = 0;
                            marketplaceInstalling = false;
                            marketplaceStatus = QStringLiteral("已安装 ") + entry["name"].toString(id);
                            reloadPlugins();
                        });
    return {};
}
bool Host::pluginEnabled(QString id) const {
    return !disabledPlugins().contains(id);
}
void Host::setPluginEnabled(QString id, bool enabled) {
    auto disabled = disabledPlugins();
    if (enabled) {
        disabled.removeAll(id);
    } else if (!disabled.contains(id)) {
        disabled.append(id);
    }
    writeDisabledPlugins(disabled);
    reloadPlugins();
}
void Host::reloadPlugins() {
    ProviderRegistry::instance().load(root, AppStorage::dataDirectory() + "/plugins", disabledPlugins());
    if (remote) {
        remote->call("host.reloadPlugins");
    } else if (child.state() != BridgeProcess::NotRunning) {
        child.kill();
        child.waitForFinished(1000);
    }
    emit invalidated();
}
QString Host::rollbackPlugin(QString id) {
    if (!validPluginId(id)) {
        return QStringLiteral("插件 id 无效");
    }
    const auto directory = AppStorage::dataDirectory() + "/plugins";
    const auto target = directory + "/" + id;
    const auto backup = directory + "/.backup-" + id;
    const auto staging = directory + "/.rollback-" + id + "-" + QUuid::createUuid().toString();
    if (!QDir(backup).exists()) {
        return QStringLiteral("没有可回滚的版本");
    }
    const bool moved = QDir(target).exists() && movePluginDirectory(target, staging);
    if (QDir(target).exists() && !moved) {
        return QStringLiteral("插件回滚失败");
    }
    if (!commitPluginDirectory(backup, target)) {
        if (moved) {
            movePluginDirectory(staging, target);
        }
        return QStringLiteral("插件回滚失败");
    }
    QDir(staging).removeRecursively();
    reloadPlugins();
    return {};
}
QString Host::uninstallPlugin(QString id) {
    if (marketplaceInstalling) {
        return QStringLiteral("正在安装插件，请稍候");
    }
    if (!validPluginId(id)) {
        return QStringLiteral("插件 id 无效");
    }
    if (id == provider) {
        return QStringLiteral("请先切换到其他来源后再卸载插件");
    }
    const auto directory = AppStorage::dataDirectory() + "/plugins";
    const auto target = directory + "/" + id;
    if (!QDir(target).exists()) {
        return QStringLiteral("内置插件不能卸载");
    }
    if (!QDir(target).removeRecursively()) {
        return QStringLiteral("插件卸载失败");
    }
    QDir(directory + "/.backup-" + id).removeRecursively();
    const auto staging = QDir(directory).entryInfoList({QStringLiteral(".staging-") + id + "-*"},
                                                       QDir::Dirs | QDir::Hidden, QDir::Name);
    for (const auto &entry : staging) {
        QDir(entry.absoluteFilePath()).removeRecursively();
    }
    auto disabled = disabledPlugins();
    disabled.removeAll(id);
    writeDisabledPlugins(disabled);
    marketplaceStatus = QStringLiteral("已卸载 ") + id;
    reloadPlugins();
    return {};
}
QString Host::importPlugin(QString directory) {
    if (marketplaceInstalling) {
        return QStringLiteral("正在安装插件，请稍候");
    }
    if (directory.isEmpty()) {
        return QStringLiteral("插件目录无效");
    }
    const QFileInfo sourceInfo(directory);
    if (!sourceInfo.isDir()) {
        return QStringLiteral("插件目录无效");
    }
    const auto source = sourceInfo.canonicalFilePath();
    if (source.isEmpty()) {
        return QStringLiteral("插件目录无效");
    }
    QFile manifestFile(source + "/manifest.json");
    if (!manifestFile.open(QIODevice::ReadOnly)) {
        return QStringLiteral("插件 manifest 缺失");
    }
    const auto manifest = QJsonDocument::fromJson(manifestFile.readAll()).object();
    if (!validPluginManifest(manifest)) {
        return QStringLiteral("插件 manifest 无效");
    }
    const auto id = manifest["id"].toString();
    const auto entry = manifest["entry"].toObject()["file"].toString();
    if (!QFileInfo(source + "/" + entry).isFile()) {
        return QStringLiteral("插件入口文件缺失");
    }
    const auto userDirectory = AppStorage::dataDirectory() + "/plugins";
    const auto target = userDirectory + "/" + id;
    const auto targetInfo = QFileInfo(target);
    if (targetInfo.exists()) {
        const auto targetPath = targetInfo.canonicalFilePath();
        if (source == targetPath || source.startsWith(targetPath + "/") ||
            targetPath.startsWith(source + "/")) {
            return QStringLiteral("不能从当前安装目录导入插件");
        }
    }
    const auto staging = userDirectory + "/.staging-" + id + "-" + QUuid::createUuid().toString();
    if (!copyPluginDirectory(source, staging)) {
        QDir(staging).removeRecursively();
        return QStringLiteral("复制插件文件失败");
    }
    QDir().mkpath(userDirectory);
    const auto backup = userDirectory + "/.backup-" + id;
    QDir(backup).removeRecursively();
    bool moved = false;
    if (QDir(target).exists()) {
        if (!movePluginDirectory(target, backup)) {
            QDir(staging).removeRecursively();
            return QStringLiteral("无法替换已安装插件");
        }
        moved = true;
    }
    if (!commitPluginDirectory(staging, target)) {
        if (moved) {
            movePluginDirectory(backup, target);
        }
        QDir(staging).removeRecursively();
        return QStringLiteral("插件导入失败");
    }
    auto disabled = disabledPlugins();
    disabled.removeAll(id);
    writeDisabledPlugins(disabled);
    marketplaceStatus = QStringLiteral("已导入 ") + manifest["display"].toObject()["name"].toString(id);
    reloadPlugins();
    return {};
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
    const auto dimension = std::clamp(maximumDimension, 128, 1024);
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
        const auto key = input;
        if (images.contains(key)) {
            callback(key);
            return;
        }
        const auto generation = epoch;
        auto watcher = new QFutureWatcher<QImage>(this);
        connect(watcher, &QFutureWatcher<QImage>::finished, this, [this, watcher, generation, key, callback] {
            const auto image = watcher->result();
            watcher->deleteLater();
            if (generation == epoch && !stopped) {
                if (!image.isNull()) {
                    images.insert(key, new QImage(image), qMax(1, int(image.sizeInBytes() / 1024)));
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
    // 封面尺寸由插件返回最终 URL；core 不再追加平台专用查询参数。
    auto key = url.toString();
    if (images.contains(key)) {
        callback(key);
        return;
    }
    if (offline) {
        callback({});
        return;
    }
    if (coverFlights.contains(key)) {
        coverFlights[key].append({callback, epoch});
        return;
    }
    coverFlights[key] = {{callback, epoch}};
    const auto imageEpoch = epoch;
    QNetworkRequest request(url);
    request.setTransferTimeout(20000);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    auto reply = network.get(request);
    connect(reply, &QNetworkReply::downloadProgress, reply, [reply](qint64 size, qint64) {
        if (size >= 8 * 1024 * 1024) {
            reply->abort();
        }
    });
    connect(reply, &QNetworkReply::finished, this, [=, this]() {
        const auto bytes = reply->readAll();
        if (imageEpoch != epoch || stopped) {
            reply->deleteLater();
            return;
        }
        const bool valid = reply->error() == QNetworkReply::NoError &&
                           reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 200 &&
                           bytes.size() < 8 * 1024 * 1024;
        reply->deleteLater();
        if (!valid) {
            const auto waiters = coverFlights.take(key);
            for (const auto &waiter : waiters) {
                if (waiter.epoch == epoch) {
                    waiter.callback({});
                }
            }
            return;
        }
        // 工作者只接触不可变字节和 QImage；回调与缓存仍在 Host 所在线程执行。
        auto watcher = new QFutureWatcher<QImage>(this);
        connect(watcher, &QFutureWatcher<QImage>::finished, this, [this, watcher, key, imageEpoch] {
            const auto image = watcher->result();
            watcher->deleteLater();
            if (imageEpoch != epoch || stopped) {
                return;
            }
            const auto waiters = coverFlights.take(key);
            bool current = false;
            for (const auto &waiter : waiters) {
                current |= waiter.epoch == epoch;
            }
            if (stopped || !current) {
                return;
            }
            if (image.isNull()) {
                for (const auto &waiter : waiters) {
                    if (waiter.epoch == epoch) {
                        waiter.callback({});
                    }
                }
                return;
            }
            // QCache 按内存预算逐项淘汰，不再在第 32 张封面清空所有命中。
            images.insert(key, new QImage(image), qMax(1, int(image.sizeInBytes() / 1024)));
            for (const auto &waiter : waiters) {
                if (waiter.epoch == epoch) {
                    waiter.callback(key);
                }
            }
        });
        watcher->setFuture(QtConcurrent::run([bytes, dimension] {
            QBuffer buffer;
            buffer.setData(bytes);
            buffer.open(QIODevice::ReadOnly);
            QImageReader reader(&buffer);
            const auto size = reader.size();
            if (!size.isValid() || size.width() > 8192 || size.height() > 8192) {
                return QImage();
            }
            // 小图不在解码阶段放大，避免重复插值。
            if (size.width() > dimension || size.height() > dimension) {
                reader.setScaledSize(size.scaled(dimension, dimension, Qt::KeepAspectRatio));
            }
            return reader.read();
        }));
    });
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
        if (!pluginRelativeFile(relative)) {
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
    auto p = images.object(key);
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
    int retainedCost = 0;
    for (const auto &pixels : retained) {
        retainedCost += qMax(1, int(pixels.sizeInBytes() / 1024));
    }
    // 渲染预算
    images.setMaxCost(qMax(4 * 1024, retainedCost));
    for (auto it = retained.begin(); it != retained.end(); ++it) {
        images.insert(it.key(), new QImage(it.value()), qMax(1, int(it->sizeInBytes() / 1024)));
    }
}
void Host::fixtureImage(const QString &key, const QImage &image) {
    // 仅离线窗口验收可注入本地封面，不读取账号或访问封面服务器。
    if (offline && !image.isNull()) {
        images.insert(key, new QImage(image), int(image.sizeInBytes() / 1024));
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
    return audio->load(url, offline, alternative, provider, position, paused);
}
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
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
    ++metadataRevision;
    cache.clear();
    if (offline) {
        return;
    }
    QDir metadata(AppStorage::cacheDirectory() + "/metadata");
    for (const auto &name : metadata.entryList({"*.json"}, QDir::Files)) {
        metadata.remove(name);
    }
}
/** 清除可重建的缓存；登录凭据、账号设置与本地音乐库保持不变。 */
void Host::clearCache() {
    if (remote) {
        remote->call("host.clearCache");
        return;
    }
    invalidateMetadata();
    // QML 与渲染管线的磁盘缓存由框架按需重建；删除失败（如 Windows 文件占用）不影响本次清理。
    const QDir cacheDirectory(AppStorage::cacheDirectory());
    for (const auto &name : {"qml", "shaders"}) {
        QDir(cacheDirectory.filePath(QString::fromLatin1(name))).removeRecursively();
    }
}
namespace {
// 可读写的偏好键。读取与写入必须共用同一份名单：两份名单一旦分叉，写入会成功但读回
// 为空，界面上的表现就是"设置完立刻跳回原值"。
const QStringList &preferenceKeys() {
    static const QStringList keys{
        "search-history", "play-history", "local-cover-cache", "theme", "motion", "startup-animation",
        "detail-autoplay", "skip-detail-on-switch", "single-play-mode", "disc-rotation", "scene-enhancement",
        "archive-mask-strength", "debug-mode", "audio-exclusive", "graphics-backend", "mv-auto", "mv-opacity", "mv-screen",
        "mv-offsets", "mv-versions", "mv-mode",
        // Linux 显卡选择：存的是 /sys/class/drm 里 cardN 的序号（0 基），不是型号。
        // 换卡后序号可能指向另一张卡或不存在，启动时由 initializeLinuxGraphics 校验并回退。
        "gpu-index", "vsync", "supersample", "render-scale", "aa-mode", "aa-scale", "msaa", "fsr-quality",
        "fsr-sharpness", "fg", "close-behavior", "auto-update", "volume", "quality", "alternate-source",
#if !defined(Q_OS_MACOS) && !defined(Q_OS_IOS)
        "audio-output-policy",
#else
        "apple-smart-transition",
#endif
        "provider", "lyrics-cache", "lyrics-global-offset-ms", "desktop-lyrics",
        "desktop-lyrics-size", "desktop-lyrics-translation-size", "desktop-lyrics-opacity",
        "desktop-lyrics-line-color", "desktop-lyrics-translation-color", "desktop-lyrics-line-weight",
        "desktop-lyrics-translation-weight", "desktop-lyrics-line-outline",
        "desktop-lyrics-translation-outline", "desktop-lyrics-line-outline-color",
        "desktop-lyrics-translation-outline-color"};
    return keys;
}
}
QString Host::preference(QString key) const {
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
void Host::setPreference(QString key, QString value) {
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
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
