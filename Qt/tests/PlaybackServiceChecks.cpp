#include "PlaybackConnection.h"
#include <QAudioDevice>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDataStream>
#include <QDir>
#include <QDirIterator>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QProcess>
#include <QProcessEnvironment>
#include <QTemporaryDir>
#include <QThread>
#include <QUrl>
#include <functional>
#include <memory>

namespace {
bool waitFor(const std::function<bool()> &ready, int timeoutMs = 10000) {
    QElapsedTimer elapsed;
    elapsed.start();
    while (!ready() && elapsed.elapsed() < timeoutMs) {
        QCoreApplication::processEvents();
        QThread::msleep(5);
    }
    return ready();
}

/** 静音 PCM 避免测试打扰用户，真实时长与 EOF 仍经过 FFmpeg 和输出设备。 */
bool writeWave(const QString &path) {
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }
    constexpr int sampleBytes = 8000 * 2 * 120;
    QDataStream stream(&file);
    stream.setByteOrder(QDataStream::LittleEndian);
    stream.writeRawData("RIFF", 4);
    stream << quint32(36 + sampleBytes);
    stream.writeRawData("WAVEfmt ", 8);
    stream << quint32(16) << quint16(1) << quint16(1) << quint32(8000) << quint32(16000) << quint16(2)
           << quint16(16);
    stream.writeRawData("data", 4);
    stream << quint32(sampleBytes);
    return file.write(QByteArray(sampleBytes, '\0')) == sampleBytes;
}
}

/**
 * 用真实服务与 GUI 进程验证核心生命周期：
 * 独立服务持有播放、GUI 可以挂接和崩溃、显式退出会回收服务。
 * 所有数据和套接字均限定在本轮临时目录。
 */
bool runPlaybackServiceChecks(const QString &sourceResources, const QString &executable, const QString &gui) {
    QTemporaryDir directory;
    if (!directory.isValid() || !writeWave(directory.path() + "/silence.wav")) {
        return false;
    }
    // 恢复与跨进程用例只读取自身临时资源，不依赖终端的用户目录访问身份。
    const auto resources = directory.path() + "/resources";
    QDir().mkpath(resources);
    for (const auto &file : QDir(sourceResources).entryInfoList(QDir::Files)) {
        if (!QFile::copy(file.absoluteFilePath(), resources + '/' + file.fileName())) {
            return false;
        }
    }
    QDirIterator badges(sourceResources + "/quality", QDir::Files, QDirIterator::Subdirectories);
    while (badges.hasNext()) {
        const auto source = badges.next();
        const auto target =
            resources + "/quality/" + QDir(sourceResources + "/quality").relativeFilePath(source);
        QDir().mkpath(QFileInfo(target).absolutePath());
        if (!QFile::copy(source, target)) {
            return false;
        }
    }
    bool ok = true;
    auto check = [&](bool condition, const char *message) {
        if (!condition) {
            qCritical() << "FAIL:" << message;
            ok = false;
        }
    };
    const auto scope = QDir(directory.path()).absoluteFilePath("data").toUtf8();
    auto endpoint =
        "rhine-playback-" +
        QString::fromLatin1(QCryptographicHash::hash(scope, QCryptographicHash::Sha256).toHex().left(24));
#ifndef Q_OS_WIN
    endpoint.prepend("/tmp/");
#endif
    QProcess service;
    service.setProcessChannelMode(QProcess::MergedChannels);
    service.start(executable, {"--resources", resources, "--gui", gui, "--offline-test", directory.path()});
    if (!service.waitForStarted()) {
        qCritical() << service.errorString();
        return false;
    }
    auto connection = std::make_unique<PlaybackConnection>();
    if (!waitFor([&] { return connection->connectToService(endpoint, 50); })) {
        qCritical() << "Playback service did not listen:" << service.readAll();
        service.kill();
        service.waitForFinished();
        return false;
    }
    check(connection->call("hello")["protocol"] == PlaybackConnection::ProtocolVersion,
          "real helper accepts IPC handshake");
    check(connection->snapshot()["servicePid"].toInteger() == service.processId(),
          "playback owner is the separate helper process");
    connection->call("host.setProvider", {{"provider", "local"}});
    connection->call("player.volume", {{"value", 0}});
    connection->call("host.diagnostics", {{"enabled", true}});
    QJsonArray queue;
    for (int index = 0; index < 3; ++index) {
        queue.append(QJsonObject{{"kind", "song"},
                                 {"provider", "local"},
                                 {"id", QString::number(index)},
                                 {"title", "IPC fixture"},
                                 {"path", directory.path() + "/silence.wav"},
                                 {"url", QUrl::fromLocalFile(directory.path() + "/silence.wav").toString()}});
    }
    connection->call("player.play", {{"track", queue[0]}, {"source", queue}});
    connection->call("player.loadQueue", {{"ids", QJsonArray{}}, {"known", queue}});
    check(waitFor([&] {
              connection->call("hello");
              const auto snapshot = connection->snapshot();
              return snapshot["queue"].toArray().size() == 3 && snapshot["index"].toInt(-1) == 0 &&
                     snapshot["current"].toObject()["id"] == "0";
          }),
          "queue load command preserves the playback service queue");
    connection->call("player.mode", {{"value", "off"}});
    // 应用包自检校验服务的播放意图和 IPC，设备实际消耗由音频回归覆盖。
    check(waitFor([&] {
              connection->call("hello");
              return connection->snapshot()["state"].toObject()["requested"].toBool();
          }),
          "play request reaches the service before GUI starts");
    connection->call("player.pause", {{"paused", true}});
    check(waitFor([&] {
              connection->call("hello");
              return !connection->snapshot()["state"].toObject()["requested"].toBool();
          }),
          "pause reaches the playback service");
    connection->call("player.toggle");
    check(waitFor([&] {
              connection->call("hello");
              return connection->snapshot()["state"].toObject()["requested"].toBool();
          }),
          "resume reaches the playback service");
    auto launchGui = [&](QProcess &process, const QStringList &extra) {
        auto environment = QProcessEnvironment::systemEnvironment();
        environment.insert("RHINE_RESOURCES", resources);
#ifdef Q_OS_MACOS
        // 测试控制器保持辅助身份，正常 GUI 仍沿用用户启动时的应用身份。
        environment.remove("QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM");
#endif
        // 无显示服务器的默认测试不需要图形设备；真实 Metal 验收另外运行。
        if (environment.value("QT_QPA_PLATFORM") == "offscreen") {
            environment.insert("QT_QUICK_BACKEND", "software");
        }
        process.setProcessEnvironment(environment);
        process.setProcessChannelMode(QProcess::MergedChannels);
        process.start(gui, QStringList{"--playback-gui-test", directory.path()} + extra);
    };
    QProcess panel;
    launchGui(panel, {});
    QByteArray panelLog;
    const bool panelReady =
        panel.waitForStarted() && waitFor([&] {
            panelLog += panel.readAll();
            return panelLog.contains("PLAYBACK_GUI_READY") || panel.state() == QProcess::NotRunning;
        }) &&
        panelLog.contains("PLAYBACK_GUI_READY");
    check(panelReady, "real persistent GUI starts");
    if (!panelReady) {
        panelLog += panel.readAll();
        qCritical() << "GUI process state:" << panel.state() << "exit status:" << panel.exitStatus()
                    << "exit code:" << panel.exitCode() << "error:" << panel.errorString();
        qCritical().noquote() << panelLog;
    }
    check(waitFor([&] {
              connection->call("hello");
              return connection->snapshot()["interfaceConnected"].toBool() &&
                     connection->snapshot()["interfacePid"].toInteger() == panel.processId();
          }),
          "GUI attaches to the playback service");
    // 服务生命周期与界面绑定：界面进程结束（含崩溃）就必须停止播放并退出。
    panel.kill();
    panel.waitForFinished();
    check(service.waitForFinished(10000) && service.exitCode() == 0,
          "playback service exits with the GUI process");
    if (service.state() != QProcess::NotRunning) {
        service.kill();
        service.waitForFinished();
    }
    // 分别验证显式退出与真实关窗，服务都应随 GUI 断连结束。
    for (const auto &action :
         {QStringLiteral("--playback-test-quit"), QStringLiteral("--playback-test-close")}) {
        service.start(executable,
                      {"--resources", resources, "--gui", gui, "--offline-test", directory.path()});
        check(service.waitForStarted(), "playback service restarts");
        PlaybackConnection probe;
        check(waitFor([&] { return probe.connectToService(endpoint, 50); }),
              "restarted playback service accepts connections");
        QProcess exitInterface;
        launchGui(exitInterface, {action});
        const bool exited = exitInterface.waitForStarted() && exitInterface.waitForFinished(10000) &&
                            exitInterface.exitCode() == 0;
        check(exited, "quit and window close exit the interface");
        if (!exited) {
            qCritical() << action << exitInterface.readAll();
        }
        if (exitInterface.state() != QProcess::NotRunning) {
            exitInterface.kill();
            exitInterface.waitForFinished();
        }
        check(service.waitForFinished(10000) && service.exitCode() == 0,
              "quit and window close stop helper and playback");
        if (service.state() != QProcess::NotRunning) {
            service.kill();
            service.waitForFinished();
        }
    }
    if (!ok) {
        qCritical().noquote() << service.readAll();
        qCritical().noquote() << panelLog;
    }
    qInfo() << "Independent playback service and persistent window:" << ok;
    return ok;
}
