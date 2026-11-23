#include "BridgeProcess.h"
#include "IOSServerTrust.h"
#include <QEventLoop>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QHash>
#include <QList>
#include <QMessageAuthenticationCode>
#include <QPointer>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <QUuid>
#include <atomic>
#include <cstring>
#include <os/log.h>
#include <thread>
#include <utility>

extern "C" int node_start(int argc, char *argv[]);

namespace {
constexpr int HandshakeTimeoutMs = 2000;
constexpr qsizetype MaxHandshakeBytes = 4096;
constexpr qsizetype MaxMessageBytes = 48 * 1024 * 1024;

QString bridgeProof(const QString &token, const QString &role, const QString &nonce) {
    return QString::fromLatin1(QMessageAuthenticationCode::hash((role + ':' + nonce).toUtf8(), token.toUtf8(),
                                                                QCryptographicHash::Sha256)
                                   .toHex());
}

/** Node 只初始化一次，回环连接断开后由同一运行时重新认证。 */
class NodeRuntime : public QObject {
  public:
    QPointer<BridgeProcess> owner;
    QTcpServer server;
    QTcpSocket *socket = nullptr;
    QTcpSocket *candidate = nullptr;
    QString candidateNonce;
    quint16 listenPort = 0;
    QTimer listenerRetry;
    QByteArray input;
    QList<QJsonObject> queued;
    QHash<QString, BridgeProcess::ControlReply> controls;
    QString token = QUuid::createUuid().toString(QUuid::WithoutBraces);
    bool launched = false;
    bool wasSuspended = false;
    QString pendingProbe;
    std::atomic<bool> exited{false};

    NodeRuntime() {
        listenerRetry.setSingleShot(true);
        connect(&listenerRetry, &QTimer::timeout, this, [this] { refreshListener(); });
        connect(&server, &QTcpServer::acceptError, this, [this] {
            if (!listenerRetry.isActive()) {
                listenerRetry.start(250);
            }
        });
        connect(&server, &QTcpServer::newConnection, this, [this] {
            auto *peer = server.nextPendingConnection();
            if (candidate) {
                peer->abort();
                peer->deleteLater();
                return;
            }
            candidate = peer;
            peer->setReadBufferSize(MaxHandshakeBytes + 1);
            connect(peer, &QTcpSocket::readyRead, this, [this, peer] {
                if (peer == candidate) {
                    authenticate(peer);
                } else if (peer == socket) {
                    read(peer);
                }
            });
            connect(peer, &QTcpSocket::disconnected, this, [this, peer] {
                peer->deleteLater();
                if (peer == candidate) {
                    candidate = nullptr;
                    candidateNonce.clear();
                } else if (peer == socket) {
                    socket = nullptr;
                    input.clear();
                    pendingProbe.clear();
                    finishDisconnectedRequests();
                }
            });
            QTimer::singleShot(HandshakeTimeoutMs, peer, [this, peer] {
                if (candidate == peer) {
                    peer->abort();
                }
            });
        });
        connect(qGuiApp, &QGuiApplication::applicationStateChanged, this, [this](Qt::ApplicationState state) {
            if (state == Qt::ApplicationSuspended) {
                wasSuspended = true;
                pendingProbe.clear();
            } else if (state == Qt::ApplicationActive && std::exchange(wasSuspended, false)) {
                refreshListener();
                probeConnection();
            }
        });
    }

    /** iOS 可能回收监听器而不通知应用，回前台时在原地址重建监听。 */
    void refreshListener() {
        if (listenPort == 0 || exited) {
            return;
        }
        server.close();
        if (!server.listen(QHostAddress::LocalHost, listenPort)) {
            listenerRetry.start(1000);
        } else {
            listenerRetry.stop();
        }
    }

    /** 双方先证明持有进程内令牌。新连接通过认证后才能接管旧会话。 */
    void authenticate(QTcpSocket *peer) {
        if (peer->bytesAvailable() > MaxHandshakeBytes) {
            peer->abort();
            return;
        }
        if (!peer->canReadLine()) {
            return;
        }
        const auto hello = QJsonDocument::fromJson(peer->readLine()).object();
        if (candidateNonce.isEmpty()) {
            const auto nonce = hello["nonce"].toString();
            if (hello["type"] != "hello" || QUuid(nonce).isNull()) {
                peer->abort();
                return;
            }
            candidateNonce = QUuid::createUuid().toString(QUuid::WithoutBraces);
            write(peer, {{"type", "challenge"},
                         {"nonce", candidateNonce},
                         {"proof", bridgeProof(token, QStringLiteral("server"), nonce)}});
            return;
        }
        if (hello["type"] != "proof" ||
            hello["proof"].toString() != bridgeProof(token, QStringLiteral("client"), candidateNonce)) {
            peer->abort();
            return;
        }
        candidate = nullptr;
        candidateNonce.clear();
        auto *previous = std::exchange(socket, peer);
        input.clear();
        pendingProbe.clear();
        peer->setReadBufferSize(0);
        write(peer, {{"type", "ready"}});
        if (previous) {
            previous->abort();
            finishDisconnectedRequests();
        } else {
            const auto pending = std::exchange(queued, {});
            for (const auto &command : pending) {
                if (socket != peer) {
                    return;
                }
                send(command);
            }
        }
        if (socket == peer) {
            read(peer);
        }
    }

    /** 唤醒后主动检测半开连接，避免播放请求等到 Worker 启动超时。 */
    void probeConnection() {
        auto *peer = socket;
        if (!peer) {
            return;
        }
        pendingProbe = QUuid::createUuid().toString(QUuid::WithoutBraces);
        const auto probe = pendingProbe;
        QTimer::singleShot(HandshakeTimeoutMs, peer, [this, peer, probe] {
            if (socket == peer && pendingProbe == probe) {
                os_log_error(OS_LOG_DEFAULT, "Rhine iOS bridge: foreground probe timed out");
                peer->abort();
            }
        });
        send({{"type", "ping"}, {"id", probe}});
    }

    /** 断线时结束旧请求。校验回调可能重入安装流程，必须排队执行。 */
    void finishDisconnectedRequests() {
        queued.clear();
        auto interrupted = std::exchange(controls, {});
        if (!interrupted.isEmpty()) {
            QMetaObject::invokeMethod(
                this,
                [interrupted = std::move(interrupted)] {
                    for (const auto &reply : interrupted) {
                        reply({}, QStringLiteral("音乐服务连接已断开，请重试"));
                    }
                },
                Qt::QueuedConnection);
        }
        if (owner) {
            owner->accept({{"type", "transport-disconnected"}});
        }
    }

    void read(QTcpSocket *peer) {
        if (socket != peer) {
            return;
        }
        input += peer->readAll();
        if (input.size() > MaxMessageBytes) {
            peer->abort();
            return;
        }
        qsizetype end;
        while (socket == peer && (end = input.indexOf('\n')) >= 0) {
            const auto message = QJsonDocument::fromJson(input.left(end)).object();
            input.remove(0, end + 1);
            if (message["type"] == "pong") {
                if (message["id"].toString() == pendingProbe) {
                    pendingProbe.clear();
                }
            } else if (message["type"] == "system-trust") {
                const auto session = message["session"].toString();
                const auto id = message["id"].toString();
                evaluateIOSServerTrust(this, message,
                                       [this, connection = QPointer(peer), session, id](bool trusted) {
                                           if (socket && socket == connection) {
                                               send({{"type", "system-trust-result"},
                                                     {"session", session},
                                                     {"id", id},
                                                     {"trusted", trusted}});
                                           }
                                       });
            } else if (message["type"] == "plugin-control-result") {
                const auto id = message["requestId"].toString();
                if (auto reply = controls.take(id)) {
                    // 安装回调会同步发起复验。先退出 readyRead，才能收到下一条回复。
                    const auto result = message["result"].toObject();
                    const auto error = message["error"].toObject()["message"].toString();
                    QMetaObject::invokeMethod(
                        this, [reply = std::move(reply), result, error] { reply(result, error); },
                        Qt::QueuedConnection);
                }
            } else if (owner) {
                owner->accept(message);
            }
        }
    }

    bool launch(const QString &root) {
        if (launched) {
            return !exited;
        }
        if (!QFileInfo::exists(root + "/MusicBridge/ios-runtime.cjs") ||
            !server.listen(QHostAddress::LocalHost, 0)) {
            return false;
        }
        launched = true;
        listenPort = server.serverPort();
        const auto script = (root + "/MusicBridge/ios-runtime.cjs").toUtf8();
        const auto port = QByteArray::number(server.serverPort());
        const auto secret = token.toUtf8();
        std::thread([this, script, port, secret] {
            // Node 要求 argv 位于同一可写缓冲区，生命周期覆盖整个运行时。
            QByteArray arguments =
                QByteArray("node\0", 5) + script + '\0' + port + '\0' + secret + '\0' + "--reconnect" + '\0';
            constexpr int argumentCount = 5;
            char *values[argumentCount + 1]{};
            char *cursor = arguments.data();
            for (int index = 0; index < argumentCount; ++index) {
                values[index] = cursor;
                cursor += std::strlen(cursor) + 1;
            }
            node_start(argumentCount, values);
            exited = true;
            QMetaObject::invokeMethod(this, [this] { finishDisconnectedRequests(); });
        }).detach();
        return true;
    }

    void send(const QJsonObject &message) {
        if (socket) {
            write(socket, message);
        } else {
            queued.append(message);
        }
    }

    static void write(QTcpSocket *peer, const QJsonObject &message) {
        peer->write(QJsonDocument(message).toJson(QJsonDocument::Compact) + '\n');
    }

    /** 取消尚未发送的请求，避免重连后执行已经超时的操作。 */
    void cancel(const QJsonObject &message, QLatin1String requestField) {
        if (socket) {
            send(message);
        } else {
            const auto request = message[requestField];
            queued.removeIf([&](const QJsonObject &pending) { return pending[requestField] == request; });
        }
    }
};

NodeRuntime &runtime() {
    // 运行时线程随应用进程结束，不在 Host 析构时释放仍被 Node 使用的内存。
    static auto instance = new NodeRuntime;
    return *instance;
}
}

/** 现有 iOS 自检通过真实连接验证重新握手。 */
bool disconnectIOSBridgeForTest() {
    auto &node = runtime();
    if (!node.socket) {
        return false;
    }
    node.socket->abort();
    return !node.socket;
}

/** 用自检连接接管仍在线的旧 socket，再让真实 Node 重新连接。 */
bool replaceIOSBridgeConnectionForTest(QEventLoop *loop, std::function<void(bool)> complete) {
    auto &node = runtime();
    if (!node.socket) {
        return false;
    }
    const QPointer previous(node.socket);
    auto *peer = new QTcpSocket(loop);
    const auto nonce = QUuid::createUuid().toString(QUuid::WithoutBraces);
    QObject::connect(peer, &QTcpSocket::connected, loop,
                     [peer, nonce] { NodeRuntime::write(peer, {{"type", "hello"}, {"nonce", nonce}}); });
    QObject::connect(
        peer, &QTcpSocket::readyRead, loop, [peer, nonce, previous, complete = std::move(complete)] {
            while (peer->canReadLine()) {
                const auto message = QJsonDocument::fromJson(peer->readLine()).object();
                auto &current = runtime();
                if (message["type"] == "challenge" &&
                    message["proof"].toString() ==
                        bridgeProof(current.token, QStringLiteral("server"), nonce)) {
                    NodeRuntime::write(peer, {{"type", "proof"},
                                              {"proof", bridgeProof(current.token, QStringLiteral("client"),
                                                                    message["nonce"].toString())}});
                } else if (message["type"] == "ready") {
                    complete((!previous || previous->state() == QAbstractSocket::UnconnectedState) &&
                             disconnectIOSBridgeForTest());
                    return;
                } else {
                    complete(false);
                    return;
                }
            }
        });
    peer->connectToHost(QHostAddress::LocalHost, node.listenPort);
    return true;
}

/** 校验任务独立于当前音乐 Worker，不替换正在运行的会话。 */
void BridgeProcess::runPluginControl(QObject *context, const QString &root, const QJsonObject &request,
                                     int timeout, ControlReply reply) {
    auto &node = runtime();
    if (!node.launch(root)) {
        reply({}, QStringLiteral("无法启动本地插件校验器"));
        return;
    }
    const auto id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const QPointer<QObject> guard(context);
    node.controls.insert(id, [guard, reply = std::move(reply)](QJsonObject result, QString error) {
        if (guard) {
            reply(std::move(result), std::move(error));
        }
    });
    node.send({{"type", "plugin-control"},
               {"requestId", id},
               {"script", root + "/MusicBridge/plugin-control-cli.cjs"},
               {"request", request}});
    QTimer::singleShot(timeout, &node, [id] {
        auto &pending = runtime();
        if (auto callback = pending.controls.take(id)) {
            pending.cancel({{"type", "plugin-control-cancel"}, {"requestId", id}},
                           QLatin1String("requestId"));
            callback({}, QStringLiteral("插件校验超时"));
        }
    });
}

BridgeProcess::BridgeProcess(QObject *parent) : QObject(parent) {
}
BridgeProcess::~BridgeProcess() {
    kill();
    if (runtime().owner == this) {
        runtime().owner.clear();
    }
}
void BridgeProcess::start(const QString &root, const QString &temporary,
                          const QJsonObject &extraEnvironment) {
    m_error = UnknownError;
    m_state = Starting;
    m_session = QUuid::createUuid().toString(QUuid::WithoutBraces);
    runtime().owner = this;
    if (!runtime().launch(root)) {
        QTimer::singleShot(0, this, [this] { accept({{"type", "runtime-error"}}); });
        return;
    }
    QJsonObject environment{{"TMPDIR", temporary}};
    for (auto it = extraEnvironment.begin(); it != extraEnvironment.end(); ++it) {
        environment.insert(it.key(), it.value());
    }
    runtime().send({{"type", "start"},
                    {"session", m_session},
                    {"script", root + "/MusicBridge/worker.cjs"},
                    {"env", environment}});
    const auto session = m_session;
    QTimer::singleShot(30000, this, [this, session] {
        if (m_session == session && m_state == Starting) {
            os_log_error(OS_LOG_DEFAULT, "Rhine iOS bridge: Worker startup timed out, connected=%{public}d",
                         int(runtime().socket != nullptr));
            kill();
        }
    });
}
void BridgeProcess::write(const QByteArray &bytes) {
    runtime().send(
        {{"type", "input"}, {"session", m_session}, {"data", QString::fromLatin1(bytes.toBase64())}});
}
QByteArray BridgeProcess::readAllStandardOutput() {
    return std::exchange(m_output, {});
}
void BridgeProcess::kill() {
    if (m_state == NotRunning) {
        return;
    }
    runtime().cancel({{"type", "stop"}, {"session", m_session}}, QLatin1String("session"));
    m_error = UnknownError;
    m_state = NotRunning;
    m_session.clear();
    m_output.clear();
    emit finished();
}
void BridgeProcess::terminate() {
    kill();
}
void BridgeProcess::closeWriteChannel() {
    // Worker 的退出统一通过 stop 命令串行完成，不关闭共享运行时的传输连接。
}
bool BridgeProcess::waitForFinished(int) {
    // 下一会话由 Node 等待旧 Worker 终止后才创建，Qt 主线程无需阻塞。
    return m_state == NotRunning;
}
void BridgeProcess::accept(const QJsonObject &message) {
    const auto type = message["type"].toString();
    if (type == "transport-disconnected") {
        if (m_state != NotRunning) {
            m_error = TransportDisconnected;
            m_state = NotRunning;
            m_session.clear();
            m_output.clear();
            emit finished();
        }
        return;
    }
    if (type == "runtime-error") {
        m_error = FailedToStart;
        m_state = NotRunning;
        emit errorOccurred(m_error);
        emit finished();
        return;
    }
    if (m_state == NotRunning || message["session"].toString() != m_session) {
        return;
    }
    if (type == "started") {
        m_state = Running;
        emit started();
    } else if (type == "output") {
        m_output += QByteArray::fromBase64(message["data"].toString().toLatin1());
        emit readyReadStandardOutput();
    } else if (type == "error" || type == "finished") {
        m_error = Crashed;
        m_state = NotRunning;
        emit finished();
    }
}
