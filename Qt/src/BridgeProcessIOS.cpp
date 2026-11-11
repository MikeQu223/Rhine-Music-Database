#include "BridgeProcess.h"
#include "AppStorage.h"
#include "IOSServerTrust.h"
#include <QCoreApplication>
#include <QFileInfo>
#include <QJsonDocument>
#include <QPointer>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <QUuid>
#include <atomic>
#include <cstring>
#include <utility>
#include <thread>

extern "C" int node_start(int argc, char *argv[]);

namespace {
/** Node 只初始化一次；Qt 主线程通过带随机令牌的回环连接控制独立 Worker。 */
class NodeRuntime : public QObject {
  public:
    QPointer<BridgeProcess> owner;
    QTcpServer server;
    QTcpSocket *socket = nullptr;
    QByteArray input;
    QByteArray queued;
    QString token = QUuid::createUuid().toString(QUuid::WithoutBraces);
    bool launched = false;
    bool authenticated = false;
    std::atomic<bool> exited{false};

    NodeRuntime() {
        connect(&server, &QTcpServer::newConnection, this, [this] {
            auto candidate = server.nextPendingConnection();
            if (socket) {
                candidate->abort();
                candidate->deleteLater();
                return;
            }
            socket = candidate;
            connect(socket, &QTcpSocket::readyRead, this, [this] { read(); });
            connect(socket, &QTcpSocket::disconnected, this, [this] {
                if (owner) {
                    owner->accept({{"type", "runtime-error"}});
                }
            });
        });
    }

    void read() {
        input += socket->readAll();
        if (input.size() > 48 * 1024 * 1024) {
            socket->abort();
            return;
        }
        qsizetype end;
        while ((end = input.indexOf('\n')) >= 0) {
            const auto message = QJsonDocument::fromJson(input.left(end)).object();
            input.remove(0, end + 1);
            if (!authenticated) {
                if (message["token"].toString() != token) {
                    socket->abort();
                    return;
                }
                authenticated = true;
                server.close();
                socket->write(queued);
                queued.clear();
            } else if (message["type"] == "system-trust") {
                const auto session = message["session"].toString();
                const auto id = message["id"].toString();
                evaluateIOSServerTrust(this, message, [this, session, id](bool trusted) {
                    send({{"type", "system-trust-result"},
                          {"session", session},
                          {"id", id},
                          {"trusted", trusted}});
                });
            } else if (owner) {
                owner->accept(message);
            }
        }
    }

    bool launch(const QString &root) {
        if (launched) {
            return !exited && (!socket || socket->state() == QAbstractSocket::ConnectedState);
        }
        if (!QFileInfo::exists(root + "/MusicBridge/ios-runtime.cjs") ||
            !server.listen(QHostAddress::LocalHost, 0)) {
            return false;
        }
        launched = true;
        const auto script = (root + "/MusicBridge/ios-runtime.cjs").toUtf8();
        const auto port = QByteArray::number(server.serverPort());
        const auto secret = token.toUtf8();
        std::thread([this, script, port, secret] {
            // Node 要求 argv 位于同一可写缓冲区，生命周期覆盖整个运行时。
            QByteArray arguments = QByteArray("node\0", 5) + script + '\0' + port + '\0' + secret + '\0';
            char *values[5]{};
            char *cursor = arguments.data();
            for (int index = 0; index < 4; ++index) {
                values[index] = cursor;
                cursor += std::strlen(cursor) + 1;
            }
            node_start(4, values);
            exited = true;
            QMetaObject::invokeMethod(this, [this] {
                if (owner) {
                    owner->accept({{"type", "runtime-error"}});
                }
            });
        }).detach();
        return true;
    }

    void send(const QJsonObject &message) {
        const auto bytes = QJsonDocument(message).toJson(QJsonDocument::Compact) + '\n';
        if (authenticated) {
            socket->write(bytes);
        } else {
            queued += bytes;
        }
    }
};

NodeRuntime &runtime() {
    // 运行时线程随应用进程结束，不在 Host 析构时释放仍被 Node 使用的内存。
    static auto instance = new NodeRuntime;
    return *instance;
}
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
    runtime().send({{"type", "stop"}, {"session", m_session}});
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
