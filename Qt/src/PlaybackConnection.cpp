#include <QtGlobal>
#include "PlaybackConnection.h"
#include "AppStorage.h"
#include <QCoreApplication>
#include <QDir>
#include <QCryptographicHash>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QJsonDocument>
#ifndef Q_OS_IOS
#include <QProcess>
#endif
#include <QThread>
#include <QTimer>
#include <memory>
#include <utility>

#ifndef Q_OS_IOS
/** 桌面端连接同一用户的唯一服务；iOS 不允许拉起独立音频服务进程。 */
bool connectPlaybackService(PlaybackConnection &connection, const QString &root, QString &error) {
    const auto endpoint = PlaybackConnection::endpoint();
    if (!connection.connectToService(endpoint, 100)) {
        const auto executable = PlaybackConnection::serviceExecutable();
        if (!QFileInfo::exists(executable) ||
            !QProcess::startDetached(
                executable, {"--resources", root, "--gui", QCoreApplication::applicationFilePath()})) {
            error = QStringLiteral("无法启动后台播放服务，请重新构建或安装完整应用");
            return false;
        }
        QElapsedTimer elapsed;
        elapsed.start();
        while (!connection.connectToService(endpoint, 100)) {
            if (elapsed.elapsed() >= 10000) {
                error = QStringLiteral("后台播放服务启动超时：") + connection.error();
                return false;
            }
            QThread::msleep(50);
        }
    }
    const auto hello = connection.call("hello");
    if (hello["protocol"] != PlaybackConnection::ProtocolVersion ||
        hello["version"].toString() != QCoreApplication::applicationVersion()) {
        error = QStringLiteral("后台播放服务版本不一致，请从托盘退出旧版后重新启动");
        return false;
    }
    return true;
}
#endif

PlaybackConnection::PlaybackConnection(QObject *parent) : QObject(parent) {
    connect(&m_socket, &QLocalSocket::readyRead, this, &PlaybackConnection::readMessages);
    connect(&m_socket, &QLocalSocket::disconnected, this, [this] {
        m_error = QStringLiteral("后台播放服务已断开，请重新打开应用");
        failPending(m_error);
        emit disconnected();
    });
}

PlaybackConnection::~PlaybackConnection() {
    m_socket.disconnect(this);
    m_socket.abort();
}

QString PlaybackConnection::endpoint() {
    const auto scope = AppStorage::dataDirectory().toUtf8();
    const auto name =
        "rhine-playback-" +
        QString::fromLatin1(QCryptographicHash::hash(scope, QCryptographicHash::Sha256).toHex().left(24));
#ifdef Q_OS_WIN
    return name;
#else
    // 使用短的绝对套接字路径，避免各进程 TMPDIR 不同或超过 Unix 路径长度限制。
    return "/tmp/" + name;
#endif
}

QString PlaybackConnection::serviceExecutable() {
    const auto directory = QCoreApplication::applicationDirPath();
#ifdef Q_OS_MACOS
    return QDir(directory).absoluteFilePath(
        "../Helpers/RhinePlaybackService.app/Contents/MacOS/RhinePlaybackService");
#elif defined(Q_OS_WIN)
    return directory + "/RhinePlaybackService.exe";
#else
    return directory + "/RhinePlaybackService";
#endif
}

bool PlaybackConnection::connectToService(const QString &endpoint, int timeoutMs) {
    m_socket.abort();
    m_buffer.clear();
    m_socket.connectToServer(endpoint);
    if (!m_socket.waitForConnected(timeoutMs)) {
        m_error = m_socket.errorString();
        return false;
    }
    m_error.clear();
    return true;
}

void PlaybackConnection::request(const QString &method, QJsonObject arguments, Reply reply) {
    if (m_socket.state() != QLocalSocket::ConnectedState) {
        reply({}, QStringLiteral("后台播放服务未连接"));
        return;
    }
    const auto id = QString::number(++m_serial);
    m_pending.insert(id, std::move(reply));
    const QJsonObject message{{"id", id}, {"method", method}, {"arguments", arguments}};
    m_socket.write(QJsonDocument(message).toJson(QJsonDocument::Compact) + '\n');
    m_socket.flush();
    // 在线请求的排队、限流和超时继续由 Host 负责，IPC 不能把排队时间算入网络期限。
    if (method != "host.request") {
        QTimer::singleShot(30000, this, [this, id] {
            if (m_pending.contains(id)) {
                m_pending.take(id)({}, QStringLiteral("后台播放服务请求超时"));
            }
        });
    }
}

/** 同步操作仅用于本地状态与命令确认；在线请求使用异步通道，不阻塞 GUI 等待网络。 */
QJsonObject PlaybackConnection::call(const QString &method, QJsonObject arguments, int timeoutMs) {
    struct Result {
        bool done = false;
        QJsonObject value;
        QString error;
    };
    auto result = std::make_shared<Result>();
    request(method, arguments, [result](QJsonObject value, QString error) {
        result->done = true;
        result->value = value;
        result->error = error;
    });
    QElapsedTimer elapsed;
    elapsed.start();
    while (!result->done && elapsed.elapsed() < timeoutMs &&
           m_socket.state() == QLocalSocket::ConnectedState) {
        if (m_socket.bytesAvailable() > 0 || m_socket.waitForReadyRead(timeoutMs - int(elapsed.elapsed()))) {
            readMessages();
        }
    }
    if (!result->done) {
        m_error = QStringLiteral("后台播放服务响应超时");
    } else {
        m_error = result->error;
    }
    return result->value;
}

/** 合并有序快照；通知排队交给 GUI，避免同步命令等待期间重入正在构造的业务对象。 */
void PlaybackConnection::readMessages() {
    m_buffer += m_socket.readAll();
    if (m_buffer.size() > 64 * 1024 * 1024) {
        m_socket.abort();
        return;
    }
    qsizetype end;
    while ((end = m_buffer.indexOf('\n')) >= 0) {
        const auto message = QJsonDocument::fromJson(m_buffer.left(end)).object();
        m_buffer.remove(0, end + 1);
        if (message.contains("snapshot")) {
            m_snapshot = message["snapshot"].toObject();
            emit snapshotChanged();
        }
        if (message.contains("patch")) {
            const auto patch = message["patch"].toObject();
            for (auto it = patch.begin(); it != patch.end(); ++it) {
                m_snapshot[it.key()] = it.value();
            }
            emit snapshotChanged();
        }
        if (message["event"] == "activate") {
            emit activateRequested();
        } else if (message["event"] == "quit") {
            emit quitRequested();
#ifdef Q_OS_LINUX
        } else if (message["event"] == "restart") {
            emit restartRequested();
#endif
        } else if (message["event"] == "diagnostic") {
            emit diagnosticEvent(message["name"].toString(), message["values"].toObject());
        } else if (message["event"] == "spectrum" && message["levels"].isArray() &&
                   message["levels"].toArray().size() == 40) {
            emit spectrumChanged(message["levels"].toArray());
        }
        const auto id = message["id"].toString();
        if (m_pending.contains(id)) {
            m_pending.take(id)(message["result"].toObject(), message["error"].toString());
        }
    }
}

void PlaybackConnection::failPending(const QString &message) {
    const auto pending = std::exchange(m_pending, {});
    for (const auto &reply : pending) {
        reply({}, message);
    }
}

const QJsonObject &PlaybackConnection::snapshot() const {
    return m_snapshot;
}

QString PlaybackConnection::error() const {
    return m_error;
}
