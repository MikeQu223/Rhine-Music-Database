#include "PluginInstaller.h"
#include "BridgeProcess.h"
#include <QDir>
#include <QDateTime>
#include <QDebug>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QLockFile>
#include <QPointer>
#include <QRegularExpression>
#include <QSaveFile>
#include <QTimer>
#include <memory>
#include <utility>

namespace PluginInstaller {
QString clientVersion() {
#if RHINE_RELEASE_BUILD
    return QStringLiteral(RHINE_VERSION);
#else
    return QStringLiteral(RHINE_PLUGIN_CLIENT_VERSION);
#endif
}

QString platform() {
#if defined(Q_OS_IOS)
    return QStringLiteral("ios");
#elif defined(Q_OS_ANDROID)
    return QStringLiteral("android");
#elif defined(Q_OS_MACOS)
    return QStringLiteral("macos");
#elif defined(Q_OS_WIN)
    return QStringLiteral("windows");
#else
    return QStringLiteral("linux");
#endif
}

bool validId(const QString &id) {
    static const QRegularExpression pattern(QStringLiteral("\\A[a-z0-9-]{1,40}\\z"));
    return pattern.match(id).hasMatch() && id != "local" && id != "siren" && relativePath(id);
}

bool relativePath(const QString &path) {
    static const QRegularExpression deviceName(
        QStringLiteral("\\A(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\\.|\\z)"),
        QRegularExpression::CaseInsensitiveOption);
    if (path.isEmpty() || path.size() > 240 || path.contains('\\') || path.contains(':') ||
        path.contains('%') || path.contains('?') || path.contains('#')) {
        return false;
    }
    for (const auto &part : path.split('/')) {
        if (part.isEmpty() || part == "." || part == ".." || part.endsWith('.') || part.endsWith(' ') ||
            deviceName.match(part).hasMatch()) {
            return false;
        }
        for (const QChar ch : part) {
            if (ch.unicode() < 32 || ch.unicode() == 127) {
                return false;
            }
        }
    }
    return true;
}

/** 调用随应用交付的校验器，使用与账号、音乐请求分开的控制通道。 */
void run(QObject *context, const QString &root, QJsonObject request, Reply reply) {
    request.insert("clientVersion", clientVersion());
    request.insert("platform", platform());
    const auto control = request["control"].toString();
    int timeout = 5000;
    if (control == "plugins.validate") {
        timeout = 30000;
    } else if (control == "plugins.initialize") {
        timeout = 8000;
    }
#if RHINE_MOBILE
    BridgeProcess::runPluginControl(context, root, request, timeout, std::move(reply));
#else
    const auto bridge = QDir(root).absoluteFilePath("MusicBridge");
#ifdef Q_OS_WIN
    const auto node = bridge + "/node.exe";
#else
    const auto node = bridge + "/node";
#endif
    auto *process = new QProcess(context);
    auto *timer = new QTimer(process);
    timer->setSingleShot(true);
    QProcessEnvironment environment;
#ifdef Q_OS_WIN
    const auto system = QProcessEnvironment::systemEnvironment();
    environment.insert("SystemRoot", system.value("SystemRoot"));
    environment.insert("WINDIR", system.value("WINDIR"));
#endif
    process->setProcessEnvironment(environment);
    process->setWorkingDirectory(bridge);
    process->setStandardErrorFile(QProcess::nullDevice());
    auto output = std::make_shared<QByteArray>();
    auto stopReason = std::make_shared<QString>();
    auto callback = std::make_shared<Reply>(std::move(reply));
    const auto finish = [process, timer, callback](QJsonObject result, QString error) {
        if (!*callback) {
            return;
        }
        timer->stop();
        auto done = std::exchange(*callback, {});
        process->deleteLater();
        done(std::move(result), std::move(error));
    };
    QObject::connect(process, &QProcess::started, process, [process, request] {
        process->write(QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n');
        process->closeWriteChannel();
    });
    QObject::connect(process, &QProcess::readyReadStandardOutput, process, [process, output, stopReason] {
        *output += process->readAllStandardOutput();
        if (output->size() > 16 * 1024 * 1024) {
            *stopReason = QStringLiteral("插件校验结果超出大小限制");
            process->kill();
        }
    });
    QObject::connect(process, &QProcess::errorOccurred, process, [finish](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
            finish({}, QStringLiteral("无法启动本地插件校验器，请重新安装客户端"));
        }
    });
    QObject::connect(
        process, &QProcess::finished, process,
        [process, output, stopReason, finish](int code, QProcess::ExitStatus status) {
            *output += process->readAllStandardOutput();
            if (!stopReason->isEmpty() || output->size() > 16 * 1024 * 1024) {
                finish({}, stopReason->isEmpty() ? QStringLiteral("插件校验结果超出大小限制") : *stopReason);
                return;
            }
            const auto response = QJsonDocument::fromJson(*output).object();
            if (response["error"].isObject()) {
                finish({}, response["error"].toObject()["message"].toString(QStringLiteral("插件校验失败")));
            } else if (code == 0 && status == QProcess::NormalExit && response["result"].isObject()) {
                finish(response["result"].toObject(), {});
            } else {
                finish({}, QStringLiteral("本地插件校验进程意外退出"));
            }
        });
    QObject::connect(timer, &QTimer::timeout, process, [process, stopReason, finish] {
        *stopReason = QStringLiteral("插件校验超时");
        process->kill();
        finish({}, *stopReason);
    });
    timer->start(timeout);
    process->start(node, {bridge + "/plugin-control-cli.cjs"});
#endif
}

QJsonObject runSynchronously(const QString &root, QJsonObject request, QString &error) {
    QEventLoop wait;
    QJsonObject result;
    bool completed = false;
    run(&wait, root, std::move(request), [&](QJsonObject response, QString problem) {
        result = std::move(response);
        error = std::move(problem);
        completed = true;
        wait.quit();
    });
    if (!completed) {
        wait.exec(QEventLoop::ExcludeUserInputEvents);
    }
    return result;
}

namespace {
constexpr auto TransactionFile = ".install-transaction.json";

bool directoryExists(const QDir &root, const QString &name) {
    const QFileInfo info(root.filePath(name));
    return info.isDir() && !info.isSymLink();
}

bool removeDirectory(const QDir &root, const QString &name) {
    const QFileInfo info(root.filePath(name));
    return (!info.exists() && !info.isSymLink()) ||
           (info.isDir() && !info.isSymLink() && QDir(info.filePath()).removeRecursively());
}

/** 恢复未完成的插件替换。目录改名成功后，备份保留上一版本。 */
QString recoverTransaction(QDir root) {
    QFile file(root.filePath(TransactionFile));
    if (!file.exists()) {
        return {};
    }
    if (!file.open(QIODevice::ReadOnly) || file.size() > 4096) {
        return QStringLiteral("无法读取插件安装恢复记录");
    }
    const auto journal = QJsonDocument::fromJson(file.readAll()).object();
    file.close();
    const auto id = journal["id"].toString();
    const auto saved = ".previous-" + id;
    const auto backup = ".backup-" + id;
    const bool hadPlugin = journal["hadPlugin"].toBool();
    const bool hadBackup = journal["hadBackup"].toBool();
    if (!validId(id) || !journal["hadPlugin"].isBool() || !journal["hadBackup"].isBool()) {
        return QStringLiteral("插件安装恢复记录无效");
    }
    if (hadPlugin && !directoryExists(root, id) && directoryExists(root, backup) &&
        (!hadBackup || directoryExists(root, saved)) && !root.rename(backup, id)) {
        return QStringLiteral("无法恢复上一版本插件");
    }
    if (directoryExists(root, saved)) {
        const bool restored =
            directoryExists(root, backup) ? removeDirectory(root, saved) : root.rename(saved, backup);
        if (!restored) {
            return QStringLiteral("无法恢复插件备份");
        }
    }
    return file.remove() ? QString() : QStringLiteral("无法清理插件安装恢复记录");
}
}

QString recover(const QString &pluginRoot) {
    const QDir root(pluginRoot);
    if (!root.exists() || QFileInfo(pluginRoot).isSymLink()) {
        return {};
    }
    // 上次进程异常退出后回收暂存目录，其他实例仍持有的租约继续有效。
    for (const auto &entry :
         root.entryInfoList({".staging-*"}, QDir::Dirs | QDir::Hidden | QDir::NoSymLinks)) {
        const auto lease = entry.filePath() + "/.owner.lock";
        if (!QFileInfo::exists(lease) && entry.lastModified().secsTo(QDateTime::currentDateTime()) < 86400) {
            continue;
        }
        QLockFile owner(lease);
        owner.setStaleLockTime(0);
        if (owner.tryLock()) {
            QDir(entry.filePath()).removeRecursively();
        }
    }
    if (!QFileInfo::exists(root.filePath(TransactionFile))) {
        return {};
    }
    QLockFile lock(root.filePath(".install.lock"));
    return lock.tryLock() ? recoverTransaction(root) : QStringLiteral("另一个窗口正在安装插件");
}

/** 候选目录与目标位于同一文件系统。改名失败时保留现有版本及恢复记录。 */
QString commit(const QString &pluginRoot, const QString &id, const QString &candidate,
               const std::function<QString()> &validate) {
    QDir root(pluginRoot);
    if (!validId(id) || QFileInfo(pluginRoot).isSymLink()) {
        return QStringLiteral("插件安装目录无效");
    }
    QLockFile lock(root.filePath(".install.lock"));
    if (!lock.tryLock()) {
        return QStringLiteral("另一个窗口正在安装插件");
    }
    const auto recoveryError = recoverTransaction(root);
    if (!recoveryError.isEmpty()) {
        return recoveryError;
    }
    const auto target = QFileInfo(root.filePath(id));
    const auto backup = ".backup-" + id;
    const auto saved = ".previous-" + id;
    const auto backupInfo = QFileInfo(root.filePath(backup));
    if (target.isSymLink() || backupInfo.isSymLink() || (target.exists() && !target.isDir()) ||
        (backupInfo.exists() && !backupInfo.isDir())) {
        return QStringLiteral("插件安装目录无效");
    }
    const auto validationError = validate();
    if (!validationError.isEmpty()) {
        return validationError;
    }
    const bool hasPlugin = directoryExists(root, id);
    const bool hasBackup = directoryExists(root, backup);
    const auto relativeCandidate = root.relativeFilePath(candidate);
    if (!relativeCandidate.startsWith(".staging-") || !relativePath(relativeCandidate) ||
        !directoryExists(root, relativeCandidate)) {
        return QStringLiteral("插件暂存目录无效");
    }
    QSaveFile journal(root.filePath(TransactionFile));
    const QJsonObject record{{"id", id}, {"hadPlugin", hasPlugin}, {"hadBackup", hasBackup}};
    const auto bytes = QJsonDocument(record).toJson(QJsonDocument::Compact);
    if (!journal.open(QIODevice::WriteOnly) || journal.write(bytes) != bytes.size() || !journal.commit()) {
        return QStringLiteral("无法记录插件安装事务");
    }
    if ((hasPlugin && hasBackup && !root.rename(backup, saved)) || (hasPlugin && !root.rename(id, backup)) ||
        !root.rename(relativeCandidate, id)) {
        const auto error = recoverTransaction(root);
        return error.isEmpty() ? QStringLiteral("无法替换插件，请关闭占用插件文件的程序后重试") : error;
    }
    const auto cleanup = recoverTransaction(root);
    if (!cleanup.isEmpty()) {
        qWarning().noquote() << cleanup;
    }
    return {};
}
}
