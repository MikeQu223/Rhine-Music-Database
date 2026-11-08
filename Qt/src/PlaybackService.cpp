#include <QtGlobal>
#include "PlaybackService.h"
#include "ProviderRegistry.h"
#include "AppStorage.h"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QSaveFile>
#include <QFileInfo>

namespace {
InterfaceLaunch interfaceLaunch(const QString &root, const QString &executable, bool offline) {
    InterfaceLaunch launch;
    launch.executable = executable;
    launch.environment = QProcessEnvironment::systemEnvironment();
    launch.environment.insert("RHINE_RESOURCES", root);
    if (offline) {
        launch.arguments = {"--playback-gui-test", QFileInfo(AppStorage::dataDirectory()).absolutePath()};
        if (launch.environment.value("QT_QPA_PLATFORM") == "offscreen") {
            launch.environment.insert("QT_QUICK_BACKEND", "software");
        }
    }
    return launch;
}
}

/**
 * 建立没有渲染依赖的播放循环；
 * 自动切歌、恢复和系统媒体键始终由服务驱动。
 */
PlaybackService::PlaybackService(QString root, QString guiExecutable, bool offline, QObject *parent)
    : QObject(parent), m_host(root, offline, nullptr, true), m_api(&m_host), m_player(&m_host, &m_api),
      m_interfaceSession(interfaceLaunch(root, guiExecutable, offline)) {
    connect(&m_interfaceSession, &InterfaceSession::activationRequested, this,
            [this] { send(m_gui, {{"event", "activate"}}); });
    connect(&m_interfaceSession, &InterfaceSession::stateChanged, this, &PlaybackService::publish);
    auto provider = m_host.preference("provider");
    if (!ProviderRegistry::instance().contains(provider)) {
        provider = ProviderRegistry::instance().defaultId();
    }
    if (provider.isEmpty()) {
        provider = ProviderRegistry::instance().fallbackId();
    }
    if (provider.isEmpty()) {
        provider = "siren";
    }
    m_api.provider = provider;
    m_host.setProvider(provider);
    connect(&m_host, &Host::playbackDiagnostic, this, [this](QString event, QJsonObject values) {
        for (auto socket : m_clients.keys()) {
            send(socket, {{"event", "diagnostic"}, {"name", event}, {"values", values}});
        }
    });
    connect(&m_host, &Host::audioSpectrumChanged, this, [this](QJsonArray levels) {
        if (m_gui) {
            send(m_gui, {{"event", "spectrum"}, {"levels", levels}});
        }
    });
    connect(&m_player, &MusicPlayer::trackSelected, this, [this](QJsonObject track) {
        ++m_selectionSerial;
        m_selectedTrack = track;
    });
    connect(&m_host, &Host::mediaAction, this, [this](QString action) {
        if (action == "resume" || action == "pause") {
            m_player.setPaused(action == "pause");
        } else if (action == "toggle") {
            m_player.toggle();
        } else if (action == "prev" || action == "previous" || action == "next") {
            m_player.next(action == "next" ? 1 : -1);
        }
        publish();
    });
    connect(&m_server, &QLocalServer::newConnection, this, [this] {
        while (m_server.hasPendingConnections()) {
            auto socket = m_server.nextPendingConnection();
            m_clients.insert(socket, {});
            connect(socket, &QLocalSocket::readyRead, this, [this, socket] { read(socket); });
            connect(socket, &QLocalSocket::disconnected, this, [this, socket] {
                const bool guiDisconnected = m_gui == socket;
#ifdef Q_OS_LINUX
                const bool restarting = m_gui == socket && m_restartingInterface;
#endif
                if (guiDisconnected) {
                    m_gui.clear();
#ifdef Q_OS_LINUX
                    m_guiBackend.clear();
#endif
                    m_interfaceSession.detach();
                }
#ifdef Q_OS_LINUX
                if (restarting) {
                    // 旧界面退出是切换后端触发的：立刻按新配置拉起新界面，
                    // 否则用户只会看到窗口消失，比后端没换更糟。
                    // 要等到新界面 attach（那时才说明重建成功）再解除。
                    m_interfaceSession.show();
                }
#endif
                m_clients.remove(socket);
                socket->deleteLater();
#ifdef Q_OS_LINUX
                if (guiDisconnected && !restarting) {
#else
                if (guiDisconnected) {
#endif
                    // 服务生命周期与界面绑定：界面正常退出或崩溃都立即停止播放并结束服务。
                    QTimer::singleShot(0, this, &PlaybackService::shutdown);
                    return;
                }
                // 其他客户端断开后清理浏览缓存；播放地址、队列和账号继续有效。
                if (m_clients.isEmpty()) {
                    m_host.trimMemory({});
                    m_host.enablePlaybackDiagnostics(false);
                }
            });
        }
    });
    m_clock.start();
    m_poll.setInterval(250);
    connect(&m_poll, &QTimer::timeout, this, [this] {
        m_player.tick(m_clock.elapsed() / 1000.0, true);
        publish();
    });
    m_poll.start();
    m_save.setInterval(5000);
    connect(&m_save, &QTimer::timeout, this, &PlaybackService::saveSession);
    m_save.start();
    bool valid = false;
    const auto volume = m_host.preference("volume").toDouble(&valid);
    m_player.volume(valid ? volume : 0.7);
    restoreSession();
}

/** 套接字先于客户端表断开信号，防止成员析构期间回调访问已经释放的状态。 */
PlaybackService::~PlaybackService() {
    m_interfaceSession.stop();
    m_interfaceSession.disconnect(this);
    m_server.disconnect(this);
    m_host.disconnect(this);
    for (auto socket : m_clients.keys()) {
        socket->disconnect(this);
        socket->abort();
    }
    m_clients.clear();
    m_server.close();
}

bool PlaybackService::listen(const QString &endpoint) {
    m_server.setSocketOptions(QLocalServer::UserAccessOption);
    // 调用者先取得用户数据目录的进程锁，才允许清除崩溃留下的套接字。
    QLocalServer::removeServer(endpoint);
    return m_server.listen(endpoint);
}

void PlaybackService::send(QLocalSocket *socket, const QJsonObject &message) {
    if (!socket || socket->state() != QLocalSocket::ConnectedState) {
        return;
    }
    if (socket->bytesToWrite() > 64 * 1024 * 1024) {
        socket->abort();
        return;
    }
    socket->write(QJsonDocument(message).toJson(QJsonDocument::Compact) + '\n');
    socket->flush();
}

void PlaybackService::read(QLocalSocket *socket) {
    m_clients[socket].buffer += socket->readAll();
    if (m_clients[socket].buffer.size() > 64 * 1024 * 1024) {
        socket->abort();
        return;
    }
    // 分发可能同步断开客户端，不能跨分发保存哈希表内元素的引用。
    while (m_clients.contains(socket)) {
        auto &buffer = m_clients[socket].buffer;
        const auto end = buffer.indexOf('\n');
        if (end < 0) {
            break;
        }
        const auto request = QJsonDocument::fromJson(buffer.left(end)).object();
        buffer.remove(0, end + 1);
        dispatch(socket, request);
    }
}

/** 每个客户端只收到变化字段；无人连接时不组装队列、歌词或诊断快照。 */
void PlaybackService::publish() {
    if (m_clients.isEmpty()) {
        return;
    }
    auto snapshot = m_player.playbackSnapshot();
    snapshot["provider"] = m_api.provider;
    snapshot["accountEpoch"] = m_host.epoch;
    snapshot["selectionSerial"] = m_selectionSerial;
    snapshot["selectedTrack"] = m_selectedTrack;
    snapshot["servicePid"] = double(QCoreApplication::applicationPid());
    const auto &interface = m_interfaceSession.state();
    snapshot["interfaceConnected"] = interface.connected;
    snapshot["interfaceWanted"] = interface.wanted;
    snapshot["interfacePid"] = double(interface.processId);
    snapshot["interfaceReady"] = interface.ready;
    snapshot["credentials"] = QJsonObject{{"netease", m_host.hasCredential("netease")},
                                          {"qq", m_host.hasCredential("qq")},
                                          {"kugou", m_host.hasCredential("kugou")}};
    snapshot["diagnostics"] = m_host.playbackSnapshot();
    const auto clients = m_clients.keys();
    for (auto socket : clients) {
        if (!m_clients.contains(socket)) {
            continue;
        }
        const auto previous = m_clients.value(socket).previous;
        if (previous.isEmpty()) {
            send(socket, {{"snapshot", snapshot}});
        } else {
            QJsonObject patch;
            for (auto field = snapshot.begin(); field != snapshot.end(); ++field) {
                if (previous[field.key()] != field.value()) {
                    patch[field.key()] = field.value();
                }
            }
            if (!patch.isEmpty()) {
                send(socket, {{"patch", patch}});
            }
        }
        if (m_clients.contains(socket)) {
            m_clients[socket].previous = snapshot;
        }
    }
}

/**
 * 分发本地命令；网络响应只交付仍连接的客户端，
 * 后台播放不依赖客户端回调。
 */
void PlaybackService::dispatch(QLocalSocket *socket, const QJsonObject &request) {
    const auto id = request["id"].toString();
    const auto method = request["method"].toString();
    const auto arguments = request["arguments"].toObject();
    QJsonObject result;
    QString error;
    if (method == "hello") {
        result = {{"protocol", PlaybackConnection::ProtocolVersion},
                  {"version", QCoreApplication::applicationVersion()},
                  {"offlineTest", m_host.offline}};
    } else if (method == "attach") {
#ifdef Q_OS_LINUX
        // 图形后端只在进程启动时生效，所以"切换后端后重新打开应用"必须换掉界面进程：
        // 只激活旧窗口等于让设置静默失效，用户看到的后端会永远停在第一次启动的那个。
        const auto backend = arguments["backend"].toString();
#endif
        if (m_gui && m_gui != socket) {
#ifdef Q_OS_LINUX
            if (!m_host.offline && !backend.isEmpty() && !m_guiBackend.isEmpty() && backend != m_guiBackend) {
                // 服务不持有外部启动的界面进程句柄，所以改为通知它自行退出，断开后再按新配置
                // 重新拉起（见 disconnected 分支）。
                qInfo().noquote() << "图形后端" << m_guiBackend << "->" << backend << "：重建界面进程";
                m_restartingInterface = true;
                m_interfaceSession.overrideBackend(backend);
                send(m_gui, {{"event", "restart"}});
                result["existing"] = true;
                result["restarted"] = true;
            } else {
                m_interfaceSession.show();
                result["existing"] = true;
            }
#else
            m_interfaceSession.show();
            result["existing"] = true;
#endif
        } else {
            m_gui = socket;
#ifdef Q_OS_LINUX
            m_guiBackend = backend;
            m_restartingInterface = false;
#endif
            m_interfaceSession.attach(arguments["pid"].toInteger());
            result["existing"] = false;
        }
    } else if (method == "interface.ready" && m_gui == socket) {
        m_interfaceSession.ready();
    } else if (method == "quit") {
        QTimer::singleShot(0, this, &PlaybackService::shutdown);
    } else if (method == "show") {
        showInterface();
    } else if (method == "host.request") {
        QPointer<QLocalSocket> target(socket);
        m_host.requestJson(arguments["route"].toString(), arguments["values"].toObject(),
                           [this, target, id](QJsonObject response, QString error) {
                               if (target) {
                                   send(target, {{"id", id}, {"result", response}, {"error", error}});
                               }
                           });
        return;
    } else if (method.startsWith("host.")) {
        bool known = true;
        result = hostCommand(method.mid(5), arguments, known);
        if (!known) {
            error = QStringLiteral("未知后台服务命令");
        }
    } else if (method.startsWith("player.")) {
        if (!playerCommand(method.mid(7), arguments)) {
            error = QStringLiteral("未知播放命令");
        }
    } else if (method.startsWith("lyrics.")) {
        if (!lyricsCommand(method.mid(7), arguments)) {
            error = QStringLiteral("未知歌词命令");
        }
    } else {
        error = QStringLiteral("未知后台服务命令");
    }
    m_player.tick(m_clock.elapsed() / 1000.0, true);
    publish();
    send(socket, {{"id", id}, {"result", result}, {"error", error}});
}

QJsonObject PlaybackService::hostCommand(const QString &method, const QJsonObject &arguments, bool &known) {
    QJsonObject result;
    if (method == "preference") {
        const auto key = arguments["key"].toString();
        result["value"] = m_host.offline && key == "provider" ? m_api.provider : m_host.preference(key);
    } else if (method == "setPreference") {
        m_host.setPreference(arguments["key"].toString(), arguments["value"].toString());
    } else if (method == "hasCredential") {
        result["value"] = m_host.hasCredential(arguments["provider"].toString());
    } else if (method == "saveCredential") {
        result["value"] = m_host.saveCredential();
    } else if (method == "acceptCookies") {
        m_host.acceptCookies(arguments["json"].toString(), arguments["epoch"].toInt(),
                             arguments["credentialKey"].toString(), arguments["provider"].toString());
    } else if (method == "bumpEpoch") {
        m_host.bumpEpoch();
    } else if (method == "reloadPlugins") {
        m_host.reloadPlugins();
    } else if (method == "logout") {
        m_player.stop();
        m_player.clearHistory();
        m_host.logout();
    } else if (method == "setProvider") {
        const auto provider = arguments["provider"].toString();
        if (ProviderRegistry::instance().contains(provider) && m_api.provider != provider) {
            m_player.stop();
            m_host.setProvider(provider);
            m_api.provider = provider;
        }
    } else if (method == "setEdition") {
        m_host.setKugouEdition(arguments["edition"].toString());
    } else if (method == "mediaControl") {
        m_host.mediaControl(arguments["action"].toString(), arguments["value"].toDouble());
    } else if (method == "mediaLoad") {
        result["value"] = m_host.mediaLoad(arguments["url"].toString(), arguments["alternative"].toBool(),
                                           arguments["position"].toDouble(), arguments["paused"].toBool());
    } else if (method == "invalidateMetadata") {
        m_host.invalidateMetadata();
    } else if (method == "clearCache") {
        m_host.clearCache();
    } else if (method == "diagnostics") {
        m_host.enablePlaybackDiagnostics(arguments["enabled"].toBool());
    } else {
        known = false;
    }
    return result;
}

bool PlaybackService::playerCommand(const QString &method, const QJsonObject &arguments) {
    if (method == "play") {
        m_player.play(
            arguments["track"].toObject(),
            arguments.contains("source") ? std::optional(arguments["source"].toArray()) : std::nullopt,
            arguments.contains("index") ? std::optional(arguments["index"].toInt()) : std::nullopt,
            arguments["preview"].toBool(),
            arguments.contains("resume") ? std::optional(arguments["resume"].toObject()) : std::nullopt);
    } else if (method == "enqueue") {
        m_player.enqueue(arguments["track"].toObject(), arguments["next"].toBool());
    } else if (method == "loadQueue") {
        m_player.loadQueue(arguments["ids"].toArray(), arguments["known"].toArray());
    } else if (method == "toggle") {
        m_player.toggle();
    } else if (method == "pause") {
        m_player.setPaused(arguments["paused"].toBool());
    } else if (method == "seek") {
        m_player.seek(arguments["value"].toDouble());
    } else if (method == "volume") {
        m_player.volume(arguments["value"].toDouble());
    } else if (method == "next") {
        m_player.next(arguments["direction"].toInt(1), arguments["ended"].toBool());
    } else if (method == "remove") {
        m_player.remove(arguments["index"].toInt(-1));
    } else if (method == "clear") {
        m_player.clearUpcoming();
    } else if (method == "stop") {
        m_player.stop();
    } else if (method == "quality") {
        m_player.setQuality(arguments["value"].toString());
    } else if (method == "mode") {
        m_player.setMode(arguments["value"].toString());
    } else if (method == "alternative") {
        m_player.setAlternative(arguments["enabled"].toBool());
    } else if (method == "clearHistory") {
        m_player.clearHistory();
    } else if (method == "clearCaches") {
        m_player.clearCaches();
    } else {
        return false;
    }
    return true;
}

bool PlaybackService::lyricsCommand(const QString &method, const QJsonObject &arguments) {
    auto &lyrics = m_player.lyrics;
    if (method == "load") {
        lyrics.load(arguments["track"].toObject(), arguments["retry"].toBool());
    } else if (method == "source") {
        lyrics.selectLocalSource(arguments["track"].toObject(), arguments["source"].toString());
    } else if (method == "offset") {
        lyrics.adjustOffset(arguments["value"].toDouble());
    } else if (method == "reset") {
        lyrics.resetOffset();
    } else if (method == "global") {
        lyrics.applyGlobalOffset();
    } else if (method == "clear") {
        lyrics.clear();
    } else if (method == "clearCache") {
        lyrics.clearCache();
    } else {
        return false;
    }
    return true;
}

void PlaybackService::showInterface() {
    m_interfaceSession.show();
}

void PlaybackService::restoreSession() {
    if (m_host.offline) {
        return;
    }
    QFile file(AppStorage::dataDirectory() + "/playback-session.json");
    bool legacy = false;
    if (!file.exists()) {
        file.setFileName(AppStorage::dataDirectory() + "/session.json");
        legacy = true;
    }
    if (file.open(QIODevice::ReadOnly) && file.size() <= 64 * 1024 * 1024) {
        auto saved = QJsonDocument::fromJson(file.readAll()).object();
        if (legacy) {
            saved = saved["player"].toObject();
        }
        m_player.restoreSessionState(saved);
    }
}

void PlaybackService::saveSession() {
    if (m_host.offline) {
        return;
    }
    QSaveFile file(AppStorage::dataDirectory() + "/playback-session.json");
    const auto bytes = QJsonDocument(m_player.sessionState()).toJson(QJsonDocument::Compact);
    if (bytes.size() <= 64 * 1024 * 1024 && file.open(QIODevice::WriteOnly) &&
        file.write(bytes) == bytes.size()) {
        file.commit();
    }
}

/** 显式退出才停止播放；普通窗口关闭或 IPC 断开不会进入此路径。 */
void PlaybackService::shutdown() {
    if (m_stopping) {
        return;
    }
    m_stopping = true;
    m_poll.stop();
    m_save.stop();
    m_interfaceSession.stop();
    saveSession();
    for (auto socket : m_clients.keys()) {
        send(socket, {{"event", "quit"}});
        if (socket->state() == QLocalSocket::ConnectedState && socket->bytesToWrite() > 0) {
            socket->waitForBytesWritten(100);
        }
    }
    m_host.shutdown();
    QCoreApplication::quit();
}
