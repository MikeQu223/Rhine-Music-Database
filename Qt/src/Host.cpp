#include "fg/FgConfig.h"
#include "Host.h"
#include "AppStorage.h"
#include <QBuffer>
#include <QClipboard>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
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

static QString hash(QByteArray value) {
    return QCryptographicHash::hash(value, QCryptographicHash::Sha256).toHex();
}
// 按路由隔离平台的缓存、限流和账号范围。
static QString routeProvider(const QString &route) {
    if (route.startsWith("/native/")) {
        return route.section('/', 2, 2);
    }
    if (route.startsWith("/qq/")) {
        return "qq";
    }
    if (route.startsWith("/kugou/")) {
        return "kugou";
    }
    return "netease";
}
Host::Host(QString path, bool test, QObject *parent)
    : QObject(parent), updater(test), root(path), offline(test) {
    connect(&updater, &AppUpdater::changed, this, &Host::invalidate);
    if (preference("kugou-edition") == "lite") {
        kugouEdition = "lite";
    }
    if (!offline) {
        cookies = QJsonDocument::fromJson(platformCredential()).object();
    } else {
        interval = 0;
    }
    if (!offline) {
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
    if (route.startsWith("/native/")) {
        const auto operation = route.section('/', 3, 3);
        if (operation == "songs" || operation == "wiki") {
            return 86400;
        }
        if (operation == "detail" || operation == "artistAlbums") {
            return 21600;
        }
        if (QStringList{"userPlaylists", "likedIDs", "likedSongs", "likedAlbums"}.contains(operation)) {
            return 60;
        }
        if (operation == "search" || operation == "categories") {
            return 900;
        }
        return 0;
    }
    if (route.startsWith("/kugou/")) {
        if (route.startsWith("/kugou/login/") || route == "/kugou/song/url" ||
            route == "/kugou/register/dev") {
            return 0;
        }
        return route.startsWith("/kugou/user/") ? 60 : 900;
    }
    if (route.startsWith("/qq/")) {
        if (QStringList{"/qq/user/song/like", "/qq/user/album/subscribe", "/qq/user/playlist/subscribe",
                        "/qq/user/playlist/tracks", "/qq/user/playlist/create", "/qq/user/playlist/rename",
                        "/qq/user/playlist/delete", "/qq/user/subscription-status"}
                .contains(route)) {
            return 0;
        }
        if (route.startsWith("/qq/login/") || route == "/qq/logout" || route == "/qq/getMusicPlay") {
            return 0;
        }
        return route.startsWith("/qq/user/") ? 60 : 900;
    }
    if (route == "/song/detail" || route == "/song/wiki/summary") {
        return 86400;
    }
    if (route == "/album" || route == "/artists" || route == "/artist/album") {
        return 21600;
    }
    if (QStringList{"/playlist/detail", "/user/playlist", "/likelist", "/album/sublist", "/artist/sublist"}
            .contains(route)) {
        return 600;
    }
    if (route == "/user/account") {
        return 1800;
    }
    if (QStringList{"/personalized", "/toplist", "/album/newest", "/top/playlist", "/playlist/catlist"}
            .contains(route)) {
        return 900;
    }
    if (route == "/recommend/songs") {
        return 60;
    }
    if (route == "/search" || route == "/search/suggest") {
        return 900;
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
        const int requestProvider = int(std::max<qsizetype>(
            0, QStringList{"other", "netease", "qq", "kugou", "local"}.indexOf(routeProvider(route))));
        playbackDiagnostics.record(
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
                playbackDiagnostics.record("request-finish", values);
            }
            for (const auto &entry : response["_playbackDiagnostics"].toArray()) {
                auto upstream = PlaybackDiagnostics::numericFields(entry.toObject());
                upstream["requestSerial"] = serial;
                if (diagnosticSession == playbackDiagnostics.session()) {
                    playbackDiagnostics.record("upstream", upstream);
                }
            }
            response.remove("_playbackDiagnostics");
            response.remove("_playbackDiagnosticsOmitted");
            callback(response, error);
        };
    }
    const auto service = routeProvider(route);
    auto token = cookies[service == "qq" ? "qqmusic_session" : "MUSIC_U"].toString();
    if (service == "kugou") {
        token = cookies["__kugou"].toObject()[kugouEdition].toObject()["token"].toString();
    }
    const auto scope = token.isEmpty() ? "guest" : hash(token.toUtf8());
    const bool cached = lifetime(route) > 0;
    const auto key =
        cached
            ? cacheKey("enhanced-4.41.1/qq-3.3.1/kugou-ba3645f2/" + scope + QString::number(metadataRevision),
                       route, values)
            : QUuid::createUuid().toString();
    const bool disk = !offline && scope == "guest" &&
                      QStringList{"/song/detail",  "/song/wiki/summary", "/album", "/artists",
                                  "/artist/album", "/playlist/detail",   "/search"}
                          .contains(route);
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
    flights.insert(
        key, {QUuid::createUuid().toString(), route, key, values, cookies, {waiter}, disk, metadataRevision});
    if (cached || route == "/song/url" || route == "/song/url/v1") {
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
#ifdef Q_OS_IOS
        pending.insert(work.id, key);
        child.start(root, temporary->path(), kugouEdition);
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
        // 设备身份独立于缓存与账号凭据，重启及切换来源后继续复用上游设备配置。
        env.insert("RHINE_QQ_DEVICE_STATE_PATH", AppStorage::dataDirectory() + "/qq-device.json");
        env.insert("RHINE_KUGOU_DEVICE_STATE_PATH", AppStorage::dataDirectory() + "/kugou-device.json");
        env.insert("RHINE_KUGOU_EDITION", kugouEdition);
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
    if (routeProvider(work.route) == "kugou" && !work.waiters.isEmpty() &&
        work.waiters.first().epoch == epoch) {
        // 同一账号排队期间完成设备注册或令牌刷新后，使用最新的私有凭据。
        work.cookies["__kugou"] = cookies["__kugou"].toObject()[kugouEdition];
    }
    QJsonObject envelope{
        {"id", work.id}, {"route", work.route}, {"params", work.params}, {"cookies", work.cookies}};
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
    // QQ 原始认证记录只经过 C++ 与子进程，禁止出现在界面回调中。
    if (response["qqSessions"].isArray() && response["qqSessions"] != cookies["__qqSessions"] &&
        !work.waiters.isEmpty() && work.waiters.first().epoch == epoch) {
        cookies["__qqSessions"] = response["qqSessions"];
        if (!cookies["qqmusic_session"].toString().isEmpty()) {
            saveCredential();
        }
    }
    response.remove("qqSessions");
    // 酷狗原始认证暂存，等待原生业务确认请求代数仍有效。
    if (response["kugouCredentials"].isObject() && !work.waiters.isEmpty() &&
        work.waiters.first().epoch == epoch) {
        const auto credentialKey = QUuid::createUuid().toString();
        privateCredentials[credentialKey] = response["kugouCredentials"].toObject();
        response["_credentialKey"] = credentialKey;
        QTimer::singleShot(30000, this, [this, credentialKey] { privateCredentials.remove(credentialKey); });
    }
    response.remove("kugouCredentials");
    const auto body = response["body"].toObject();
    const auto code = body["code"].toInt(200);
    if (lifetime(work.route) || work.route == "/song/url" || work.route == "/song/url/v1") {
        const auto message = body["message"].toString(body["msg"].toString());
        if (QList<int>{405, 429, 509}.contains(code) || message.contains("频繁")) {
            blockedUntil[routeProvider(work.route)] =
                QDateTime::currentMSecsSinceEpoch() + qMax(120000LL, qint64(body["retryAfterMs"].toDouble()));
        }
        if (work.cacheRevision == metadataRevision && lifetime(work.route) && error.isEmpty() &&
            response["body"].isObject() && code == 200) {
            Entry entry{QDateTime::currentMSecsSinceEpoch() + lifetime(work.route) * 1000LL, body};
            cache.insert(key, entry);
            if (cache.size() > 256) {
                for (auto it = cache.begin(); it != cache.end();) {
                    if (it->expiry <= QDateTime::currentMSecsSinceEpoch()) {
                        it = cache.erase(it);
                    } else {
                        ++it;
                    }
                }
                if (cache.size() > 256) {
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
void Host::acceptCookies(QString json, int responseEpoch, QString credentialKey) {
    if (responseEpoch != epoch || stopped) {
        return;
    }
    bool changed = false;
    if (privateCredentials.contains(credentialKey)) {
        const auto credential = privateCredentials.take(credentialKey);
        auto editions = cookies["__kugou"].toObject();
        changed = editions[kugouEdition] != credential;
        editions[kugouEdition] = credential;
        cookies["__kugou"] = editions;
    }
    for (auto line : QJsonDocument::fromJson(json.toUtf8()).array()) {
        for (auto cookie : QNetworkCookie::parseCookies(line.toString().toUtf8())) {
            const auto name = QString::fromUtf8(cookie.name());
            const auto value = QString::fromUtf8(cookie.value());
            changed |= cookies[name].toString() != value;
            cookies[name] = value;
        }
    }
    // 保存有效账号请求更新的 Cookie，避免重启恢复的是刷新前的凭据。
    if (changed && (hasCredential("qq") || hasCredential("netease") || hasCredential("kugou"))) {
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
    if (value != "qq" && value != "netease" && value != "kugou") {
        return false;
    }
    if (value == "kugou") {
        const auto credential = cookies["__kugou"].toObject()[kugouEdition].toObject();
        return !credential["token"].toString().isEmpty() && credential["userid"].toString().toULongLong() > 0;
    }
    return !cookies[value == "qq" ? "qqmusic_session" : "MUSIC_U"].toString().isEmpty();
}
/**
 * 切换音乐来源，保持各来源的凭据与缓存隔离。
 */
void Host::setProvider(QString value) {
    if (value != "qq" && value != "netease" && value != "kugou" && value != "local") {
        return;
    }
    if (provider == value) {
        return;
    }
    provider = value;
    ++epoch;
    privateCredentials.clear();
    ++metadataRevision;
    cache.clear();
    images.clear();
    coverFlights.clear();
}
/**
 * 切换酷狗标准版与概念版，按上游要求重启协议模块，隔离两个版本的令牌。
 * 设备身份保持不变；已取消或旧版本的请求不能保存认证记录。
 */
void Host::setKugouEdition(QString edition) {
    if (!QStringList{"standard", "lite"}.contains(edition) || edition == kugouEdition) {
        return;
    }
    kugouEdition = edition;
    setPreference("kugou-edition", edition);
    ++epoch;
    ++metadataRevision;
    privateCredentials.clear();
    cache.clear();
    images.clear();
    coverFlights.clear();
    if (child.state() != BridgeProcess::NotRunning) {
        child.kill();
        child.waitForFinished(1000);
    }
}
QString Host::saveCredential() {
    return offline ? QString()
                   : platformSaveCredential(QJsonDocument(cookies).toJson(QJsonDocument::Compact));
}
/**
 * 作废当前来源的请求并清理凭据，另一来源的账号保持独立。
 */
void Host::logout() {
    mediaControl("stop");
    if (provider == "qq") {
        cookies.remove("qqmusic_session");
        cookies.remove("__qqSessions");
    } else if (provider == "kugou") {
        auto editions = cookies["__kugou"].toObject();
        editions.remove(kugouEdition);
        if (editions.isEmpty()) {
            cookies.remove("__kugou");
        } else {
            cookies["__kugou"] = editions;
        }
    } else {
        const auto kugou = cookies.value("__kugou");
        const auto token = cookies.value("qqmusic_session");
        const auto sessions = cookies.value("__qqSessions");
        cookies = {};
        if (!kugou.isUndefined()) {
            cookies["__kugou"] = kugou;
        }
        if (!token.isUndefined()) {
            cookies["qqmusic_session"] = token;
        }
        if (!sessions.isUndefined()) {
            cookies["__qqSessions"] = sessions;
        }
    }
    ++epoch;
    privateCredentials.clear();
    // 结束进程同时关闭 QQ 的扫码长连接；另一平台的持久凭据仍保留。
    if (child.state() != BridgeProcess::NotRunning) {
        child.kill();
        child.waitForFinished(1000);
    }
    cache.clear();
    images.clear();
    coverFlights.clear();
    if (!offline) {
        if (cookies.isEmpty()) {
            platformDeleteCredential();
        } else {
            saveCredential();
        }
    }
}
QString Host::fromLink(QString input) const {
    input = input.remove('\\').trimmed();
    QUrl outer(input);
    if (!QStringList{"music.163.com", "y.music.163.com"}.contains(outer.host()) ||
        !QStringList{"http", "https"}.contains(outer.scheme())) {
        return {};
    }
    QUrl page = outer;
    if (outer.hasFragment()) {
        auto part = outer.fragment();
        page = QUrl("https://music.163.com" + (part.startsWith('/') ? part : "/" + part));
    }
    auto kind = page.path().split('/', Qt::SkipEmptyParts).last();
    auto id = QUrlQuery(page).queryItemValue("id");
    if (!QStringList{"song", "album", "playlist"}.contains(kind) ||
        !QRegularExpression("^[0-9]{1,20}$").match(id).hasMatch()) {
        return {};
    }
    return kind + ":" + id;
}
void Host::loadCover(QString input, TextReply callback) {
    const QUrl local(input);
    if (local.isLocalFile()) {
        if (provider != "local" && !offline) {
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
        watcher->setFuture(QtConcurrent::run([path = local.toLocalFile()] {
            QImageReader reader(path);
            const auto size = reader.size();
            if (!size.isValid() || size.width() > 8192 || size.height() > 8192) {
                return QImage();
            }
            if (size.width() > 1024 || size.height() > 1024) {
                reader.setScaledSize(size.scaled(1024, 1024, Qt::KeepAspectRatio));
            }
            return reader.read();
        }));
        return;
    }
    QUrl url(input.replace("http://", "https://"));
    const auto domain = url.host();
    if (!(domain == "music.126.net" || domain.endsWith(".music.126.net") || domain == "music.163.com" ||
          domain.endsWith(".music.163.com") || domain == "y.gtimg.cn" || domain == "qpic.y.qq.com" ||
          domain == "y.qq.com" || domain.endsWith(".kugou.com") || domain.endsWith(".kgimg.com"))) {
        callback({});
        return;
    }
    QUrlQuery query(url);
    query.removeAllQueryItems("param");
    query.addQueryItem("param", "1024y1024");
    url.setQuery(query);
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
        watcher->setFuture(QtConcurrent::run([bytes] {
            QBuffer buffer;
            buffer.setData(bytes);
            buffer.open(QIODevice::ReadOnly);
            QImageReader reader(&buffer);
            const auto size = reader.size();
            if (!size.isValid() || size.width() > 8192 || size.height() > 8192) {
                return QImage();
            }
            // 保留大封面的细节；小图不在解码阶段放大，避免重复插值。
            if (size.width() > 1024 || size.height() > 1024) {
                reader.setScaledSize(size.scaled(1024, 1024, Qt::KeepAspectRatio));
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
    const auto key = "qq-qr:" + hash(bytes);
    images.insert(key, new QImage(value), int(value.sizeInBytes() / 1024));
    return key;
}
QString Host::qr(QString key) {
    auto name = "qr:" + key;
    images.insert(name, new QImage(platformQR("https://music.163.com/login?codekey=" + key)), 1024);
    return name;
}
QImage Host::image(const QString &key) const {
    // 官方音质标识随包离线交付；限定文件名，防止图片键访问资源目录之外。
    static const QRegularExpression qualityKey(
        "^quality:(netease|qq|kugou)-(sq|hq|hires|jymaster|jyeffect|sky)$");
    if (key.startsWith("quality:") && qualityKey.match(key).hasMatch()) {
        static QCache<QString, QImage> badges(32);
        if (auto cached = badges.object(key)) {
            return *cached;
        }
        const QImage badge(root + "/quality/" + key.mid(8) + ".png");
        badges.insert(key, new QImage(badge));
        return badge;
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
    QPointer<Host> guarded(this);
    platformPlay(id, activates(), [guarded, callback](QString message) mutable {
        if (guarded && !guarded->stopped) {
            callback(message);
        }
    });
}
bool Host::mediaLoad(QString url, bool alternative, double position, bool paused) {
    if (!audio) {
        audio = std::make_unique<AudioPlayer>([this] { emit mediaChanged(); });
        audio->diagnosticEvent = [this](const QString &event, const QJsonObject &values) {
            playbackDiagnostics.record(event, values);
        };
        audio->enableDiagnostics(audioDiagnosticsEnabled);
    }
    return audio->load(url, offline, alternative, provider, position, paused);
}
void Host::mediaControl(QString action, double value) {
    if (action == "volume" && !PlatformFeatures::ApplicationVolume) {
        value = 1.0;
    }
    if (!audio && action == "volume") {
        audio = std::make_unique<AudioPlayer>([this] { emit mediaChanged(); });
        audio->diagnosticEvent = [this](const QString &event, const QJsonObject &values) {
            playbackDiagnostics.record(event, values);
        };
        audio->enableDiagnostics(audioDiagnosticsEnabled);
    }
    if (audio) {
        audio->control(action, value);
    }
    emit mediaChanged();
}
void Host::mediaMetadata(QString title, QString artist, QString album) {
    mediaTitle = title.left(256);
    mediaArtist = artist.left(256);
    mediaAlbum = album.left(256);
    lastMediaUpdate = 0;
}
QVariantMap Host::mediaState() const {
    auto state = audio ? audio->state() : QVariantMap();
    auto now = QDateTime::currentMSecsSinceEpoch();
    if (!offline && now - lastMediaUpdate >= 1000) {
        lastMediaUpdate = now;
        platformMediaInfo(mediaTitle, mediaArtist, mediaAlbum, state);
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
namespace {
// 可读写的偏好键。读取与写入必须共用同一份名单：两份名单一旦分叉，写入会成功但读回
// 为空，界面上的表现就是"设置完立刻跳回原值"。
const QStringList &preferenceKeys() {
    static const QStringList keys{
        "search-history", "play-history", "local-cover-cache", "theme", "motion", "startup-animation",
        "detail-autoplay", "single-play-mode", "disc-rotation", "scene-enhancement", "archive-mask-strength",
        "graphics-backend",
        // Filament 适配开关与最近一次失败原因（格式 "<code>: <detail>"）。
        "filament", "filament-last-error",
        // Linux 显卡选择：存的是 /sys/class/drm 里 cardN 的序号（0 基），不是型号。
        // 换卡后序号可能指向另一张卡或不存在，启动时由 initializeLinuxGraphics 校验并回退。
        "gpu-index", "vsync", "supersample", "render-scale", "aa-mode", "aa-scale", "msaa", "fsr-quality",
        "fsr-sharpness", "fg", "auto-update", "volume", "quality", "alternate-source", "provider",
        "lyrics-cache", "lyrics-global-offset-ms", "welcome-name-netease", "welcome-name-qq",
        "welcome-name-kugou", "account-id-netease", "account-id-qq", "account-id-kugou", "kugou-edition",
        "welcome-name-kugou-standard", "welcome-name-kugou-lite", "account-id-kugou-standard",
        "account-id-kugou-lite"};
    return keys;
}
} // namespace
QString Host::preference(QString key) const {
    if (offline || !preferenceKeys().contains(key)) {
        return {};
    }
    return AppStorage::settings().value("panel/" + key).toString();
}
void Host::setPreference(QString key, QString value) {
    if (!offline && value.size() < 262144 && preferenceKeys().contains(key)) {
        AppStorage::settings().setValue("panel/" + key, value);
        // 帧生成开关是唯一"不必重启也能生效"的偏好：呈现层每帧解析 RHINE_FG，
        // 所以这里写完磁盘再同步一次环境变量，设置页点一下就切换插值。
        // 具体转换在 RhineFg::applyInterpolationPreference（有单测）。
        if (key == QLatin1String("fg")) {
            RhineFg::applyInterpolationPreference(value);
        }
#ifdef Q_OS_MACOS
        emit preferenceChanged(key, value);
#endif
    }
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
    audioDiagnosticsEnabled = enabled;
    if (enabled && !QNetworkInformation::instance()) {
        QNetworkInformation::loadDefaultBackend();
    }
    if (audio) {
        audio->enableDiagnostics(enabled);
    }
}

QJsonObject Host::playbackSnapshot() const {
    auto values = audio ? audio->diagnosticState() : QJsonObject();
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
