#include "BridgeProcess.h"
#include <QDir>
#include <QDirIterator>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QTemporaryDir>
#include <QTimer>

namespace {
/** 启动一次会话并发送单条请求；超时或传输失败时返回空对象。 */
QJsonObject exchange(BridgeProcess &bridge, const QString &root, const QString &temporary,
                     const QJsonObject &environment, const QJsonObject &request) {
    QEventLoop loop;
    QTimer timeout;
    timeout.setSingleShot(true);
    QByteArray output;
    bool received = false;
    QObject::connect(&timeout, &QTimer::timeout, &loop, &QEventLoop::quit);
    const auto started = QObject::connect(&bridge, &BridgeProcess::started, &loop, [&] {
        bridge.write(QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n');
    });
    const auto ready = QObject::connect(&bridge, &BridgeProcess::readyReadStandardOutput, &loop, [&] {
        output += bridge.readAllStandardOutput();
        if (output.contains('\n')) {
            received = true;
            loop.quit();
        }
    });
    const auto finished = QObject::connect(&bridge, &BridgeProcess::finished, &loop, &QEventLoop::quit);
    timeout.start(30000);
    bridge.start(root, temporary, environment);
    loop.exec();
    QObject::disconnect(started);
    QObject::disconnect(ready);
    QObject::disconnect(finished);
    bridge.kill();
    if (!received) {
        return {};
    }
    return QJsonDocument::fromJson(output.trimmed()).object();
}

/** 把随包 fixture 插件复制进用户插件目录，复现市场安装后的目录布局。 */
bool installFixturePlugin(const QString &root, const QString &plugins) {
    const auto fixture = root + "/MusicBridge/plugins/sdk/fixtures/plugins/alpha";
    QDirIterator files(fixture, QDir::Files, QDirIterator::Subdirectories);
    while (files.hasNext()) {
        const auto source = files.next();
        const auto target = plugins + "/alpha/" + QDir(fixture).relativeFilePath(source);
        if (!QDir().mkpath(QFileInfo(target).path()) || !QFile::copy(source, target)) {
            return false;
        }
    }
    return true;
}
}

/**
 * 在 iOS 宿主中加载真实协议 bundle，验证嵌入式 Node、传输、会话重建与用户插件加载。
 * 请求只走本地 fixture 路由，不访问网络。
 */
bool runIOSBridgeChecks(const QString &root) {
    QTemporaryDir temporary;
    if (!temporary.isValid()) {
        return false;
    }
    BridgeProcess bridge;
    bool ok = true;
    const QJsonObject lyricsRequest{{"id", "embedded-check"},
                                    {"route", "/local/lyrics"},
                                    {"params", QJsonObject{{"content", "[00:01.00]嵌入式运行时"}}}};
    for (int session = 0; session < 2; ++session) {
        const auto response = exchange(bridge, root, temporary.path(), {}, lyricsRequest);
        ok &= response["id"] == "embedded-check" && response["body"].toObject()["code"].toInt() == 200;
        if (!ok) {
            break;
        }
    }
    // 市场插件装在数据目录；内嵌运行时必须按宿主传入的用户插件根发现并加载同一个包。
    const auto plugins = temporary.path() + "/plugins";
    QJsonObject pluginResponse;
    ok &= installFixturePlugin(root, plugins);
    if (ok) {
        const QJsonObject pluginRequest{{"id", "plugin-check"},
                                        {"route", "/native/alpha/search"},
                                        {"params", QJsonObject{{"args", QJsonArray{"embedded", "song"}}}}};
        pluginResponse =
            exchange(bridge, root, temporary.path(), {{"RHINE_USER_PLUGINS", plugins}}, pluginRequest);
        ok &= pluginResponse["id"] == "plugin-check" &&
              pluginResponse["body"].toObject()["code"].toInt() == 200;
    }
    if (!ok) {
        qInfo().noquote() << "iOS bridge response:"
                          << QJsonDocument(pluginResponse).toJson(QJsonDocument::Compact);
    }
    qInfo() << "iOS embedded Node, packaged Worker, session replacement and user plugins:"
            << (ok ? "passed" : "FAILED");
    return ok;
}
