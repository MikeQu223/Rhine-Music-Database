#include "BridgeProcess.h"
#include "AppStorage.h"
#include <QDebug>
#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QPointer>
#include <QStandardPaths>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <QUuid>
#include <atomic>
#include <cstring>
#include <pthread.h>
#include <utility>

// Android 的 libnode.so 不提供 iOS 那个 C 包装 node_start：动态符号表里只有导出的
// node::Start(int, char**)（_ZN4node5StartEiPPc），而 node_start 正是它的 C 包装。
// 直接声明命名空间函数即可，argc/argv 语义与 iOS 完全一致。
namespace node {
int Start(int argc, char *argv[]);
}

namespace {
class NodeRuntime;
/** 交给 Node 线程的启动参数；缓冲区的生命周期必须覆盖 node_start 全程。 */
struct NodeThreadStart {
    NodeRuntime *runtime;
    QByteArray arguments;
};
void *nodeThreadMain(void *context);

/** Node 只初始化一次；Qt 主线程通过带随机令牌的回环连接控制独立 Worker。
 *
 *  与 iOS 的实现保持逐条对应，只去掉系统信任评估（Android 走 Node 自带的 Mozilla
 *  CA 包，没有 Security.framework 那条通道）。两边协议必须一致：
 *  MusicBridge/ios-runtime.cjs 是同一份脚本，Qt 侧字段名改一处就会静默断链。 */
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
                // 只允许一个控制连接：多出来的来源直接拒绝，不猜哪个才是本进程连的。
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
                // 第一条消息必须是令牌：回环端口对本机任意进程可见，仅靠端口号不够。
                if (message["token"].toString() != token) {
                    socket->abort();
                    return;
                }
                authenticated = true;
                server.close();
                qInfo().noquote() << "node runtime connected over loopback";
                socket->write(queued);
                queued.clear();
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
        // Node 要求 argv 位于同一可写缓冲区，且生命周期覆盖整个运行时（node_start 直到
        // 进程结束才返回），所以参数跟着线程走，不能是 launch() 的局部变量。
        auto *start = new NodeThreadStart{
            this, QByteArray(QByteArray("node\0", 5) + script + '\0' + port + '\0' + secret + '\0')};
        // V8 的默认线程栈在 Android 上不够用（原生 pthread 默认只有 1 MB），
        // 必须显式给足，否则会在首次 GC 或深度解析时栈溢出。
        pthread_attr_t attributes;
        pthread_attr_init(&attributes);
        pthread_attr_setstacksize(&attributes, 8 * 1024 * 1024);
        pthread_t thread;
        const auto started = pthread_create(&thread, &attributes, &nodeThreadMain, start);
        pthread_attr_destroy(&attributes);
        if (started != 0) {
            delete start;
            return false;
        }
        pthread_detach(thread);
        return true;
    }

    void send(const QJsonObject &message) {
        const auto bytes = QJsonDocument(message).toJson(QJsonDocument::Compact) + '\n';
        if (authenticated) {
            socket->write(bytes);
        } else {
            // 连接与认证都是异步的，握手完成前先排队，否则第一条命令必然丢。
            queued += bytes;
        }
    }
};

/** Node 运行时的入口线程：node_start 内部就是 Node 的事件循环，返回即运行时结束。 */
void *nodeThreadMain(void *context) {
    auto *start = static_cast<NodeThreadStart *>(context);
    char *values[5]{};
    char *cursor = start->arguments.data();
    for (int index = 0; index < 4; ++index) {
        values[index] = cursor;
        cursor += std::strlen(cursor) + 1;
    }
    auto *runtime = start->runtime;
    // 退出码与脚本路径是设备上唯一的失败线索：没有控制台，node 的报错只能靠 logcat。
    const auto code = node::Start(4, values);
    runtime->exited = true;
    qWarning().noquote() << "node runtime exited, code" << code << "script" << QByteArray(values[1]);
    QMetaObject::invokeMethod(runtime, [runtime] {
        if (runtime->owner) {
            runtime->owner->accept({{"type", "runtime-error"}});
        }
    });
    delete start;
    return nullptr;
}

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
void BridgeProcess::start(const QString &root, const QString &temporary, const QString &edition) {
    // temporary 是宿主的会话临时目录（内部缓存）；worker 的 TMPDIR 改用外部缓存目录
    // （见下），这个参数只作为外部存储不可用时的回退锚点之一，不再直接使用。
    Q_UNUSED(temporary)
    m_state = Starting;
    m_session = QUuid::createUuid().toString(QUuid::WithoutBraces);
    runtime().owner = this;
    if (!runtime().launch(root)) {
        QTimer::singleShot(0, this, [this] { accept({{"type", "runtime-error"}}); });
        return;
    }
    // 临时目录用系统分配的外部缓存目录（getExternalCacheDir，即
    // /storage/emulated/0/Android/data/<包名>/cache——包名由系统填充，这里不写死；
    // Qt 的 CacheLocation 在 Android 上映射到它）。Android 没有 /tmp；外部缓存
    // 无需运行时权限，用户也能在系统设置里清理。外部存储不可用时退回内部缓存。
    const QString tmpRoot = [] {
        auto external = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
        if (external.isEmpty()) {
            external = AppStorage::temporaryDirectory();
        }
        return external;
    }();
    QDir().mkpath(tmpRoot);
    QJsonObject environment{
        {"TMPDIR", tmpRoot},
        {"RHINE_QQ_DEVICE_STATE_PATH", AppStorage::dataDirectory() + "/qq-device.json"},
        {"RHINE_KUGOU_DEVICE_STATE_PATH", AppStorage::dataDirectory() + "/kugou-device.json"},
        {"RHINE_KUGOU_EDITION", edition}};
    runtime().send({{"type", "start"},
                    {"session", m_session},
                    {"script", root + "/MusicBridge/worker.cjs"},
                    {"stderrLog", true},
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
    if (type == "stderr") {
        // worker 的 stderr：设备上没有控制台，这里落进 logcat 才能定位崩溃。
        qWarning().noquote() << "node worker:"
                             << QByteArray::fromBase64(message["data"].toString().toLatin1()).trimmed();
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
        // 运行时脚本会把 worker 的错误栈（detail）与退出码（exitCode）带上：设备上唯一的现场。
        if (message.contains("detail")) {
            qWarning().noquote() << "node worker error:" << message["detail"].toString();
        } else if (message.contains("exitCode")) {
            qWarning().noquote() << "node worker finished, exitCode" << message["exitCode"].toInt();
        }
        m_error = Crashed;
        m_state = NotRunning;
        emit finished();
    }
}
