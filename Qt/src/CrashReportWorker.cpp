#include "client/crash_report_database.h"
#include "snapshot/minidump/process_snapshot_minidump.h"
#include "util/file/file_reader.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLockFile>
#include <QProcess>
#include <QSaveFile>
#include <QSet>
#include <QTextStream>
#include <QThread>
#include <algorithm>
#include <cerrno>
#ifdef Q_OS_WIN
#include <windows.h>
#else
#include <csignal>
#include "util/mach/exception_types.h"
#include "util/mach/mach_extensions.h"
#endif

namespace {
base::FilePath nativePath(const QString &path) {
#ifdef Q_OS_WIN
    return base::FilePath(path.toStdWString());
#else
    return base::FilePath(path.toStdString());
#endif
}

QString qtPath(const base::FilePath &path) {
#ifdef Q_OS_WIN
    return QString::fromStdWString(path.value());
#else
    return QString::fromStdString(path.value());
#endif
}

QString threadIdText(const QJsonValue &value) {
    if (value.isString()) {
        return value.toString();
    }
    if (value.isDouble()) {
        return QString::number(qint64(value.toDouble()));
    }
    return {};
}

// logfmt：每行一个事件；值按 JSON 字面值转义，避免错误消息中的换行破坏记录边界。
void writeEvent(QTextStream &text, const QString &time, const QString &level, const QString &event,
                const QJsonObject &fields = {}) {
    text << time << ' ' << level << " event=" << event;
    for (auto it = fields.begin(); it != fields.end(); ++it) {
        if (!it.value().isNull() && !it.value().isUndefined()) {
            const auto encoded = QJsonDocument(QJsonArray{it.value()}).toJson(QJsonDocument::Compact);
            auto value = encoded.mid(1, encoded.size() - 2);
            if (it.value().isArray() || it.value().isObject()) {
                const auto quoted =
                    QJsonDocument(QJsonArray{QString::fromUtf8(value)}).toJson(QJsonDocument::Compact);
                value = quoted.mid(1, quoted.size() - 2);
            }
            text << ' ' << it.key() << '=' << value;
        }
    }
    text << '\n';
}

/** 读取转储内的原始异常、配置及 Qt 错误记录，不访问已经退出的应用对象。 */
QString writeSnapshot(QTextStream &text, const QString &time,
                      const crashpad::ProcessSnapshotMinidump &snapshot) {
    if (const auto exception = snapshot.Exception()) {
#ifdef Q_OS_WIN
        constexpr uint32_t SIMULATED_EXCEPTION = 0x517a7ed;
#else
        constexpr uint32_t SIMULATED_EXCEPTION = crashpad::kMachExceptionSimulated;
#endif
        const bool simulated = exception->Exception() == SIMULATED_EXCEPTION;
        QJsonArray codes;
        for (const auto code : exception->Codes()) {
            codes.append("0x" + QString::number(code, 16));
        }
        QJsonObject fields{
            {"thread_id", qint64(exception->ThreadID())},
            {"code", "0x" + QString::number(exception->Exception(), 16)},
            {"address", "0x" + QString::number(exception->ExceptionAddress(), 16)},
            {"parameters", codes},
            {"simulated", simulated},
        };
#ifdef Q_OS_MACOS
        const auto &raw = exception->Codes();
        if (raw.size() >= 2 && raw[0] == EXC_CRASH) {
            int signal = 0;
            crashpad::ExcCrashRecoverOriginalException(raw[1], nullptr, &signal);
            fields["signal"] = signal;
        }
#endif
        writeEvent(text, time, simulated ? "WARN" : "ERROR", "exception", fields);
    }
    QJsonObject context;
    for (const auto &[name, value] : snapshot.AnnotationsSimpleMap()) {
        context[QString::fromStdString(name)] = QString::fromStdString(value);
    }
    writeEvent(text, time, "INFO", "session", context);
    QString hangThreadId;
    QList<QJsonObject> messages;
    for (const auto module : snapshot.Modules()) {
        for (const auto &annotation : module->AnnotationObjects()) {
            if (!annotation.name.starts_with("rhine.")) {
                continue;
            }
            const auto value = QByteArray::fromRawData(
                reinterpret_cast<const char *>(annotation.value.data()), annotation.value.size());
            if (annotation.name == "rhine.hang.thread") {
                hangThreadId = QString::fromUtf8(value).trimmed();
            }
            auto fields = QJsonDocument::fromJson(value).object();
            if (annotation.name == "rhine.qt" && !fields.isEmpty()) {
                messages.append(fields);
            } else {
                if (fields.isEmpty()) {
                    fields["value"] = QString::fromUtf8(value);
                }
                const auto level = annotation.name == "rhine.cpp.exception" ? "ERROR" : "INFO";
                writeEvent(text, time, level, QString::fromStdString(annotation.name), fields);
            }
        }
    }
    std::sort(messages.begin(), messages.end(), [](const auto &left, const auto &right) {
        return left.value("sequence").toInteger() < right.value("sequence").toInteger();
    });
    for (auto message : messages) {
        const auto capturedTime = message.take("time").toString(time);
        const auto level = message.take("level").toString("WARN");
        writeEvent(text, capturedTime, level, "qt.message", message);
    }
    return hangThreadId;
}

/** 保留解析器提供的帧置信度、内联帧、寄存器及模块标识，避免把扫描结果当成确定调用链。 */
void writeStack(QTextStream &text, const QString &time, const QJsonObject &report,
                const QString &hangThreadId) {
    writeEvent(text, time, "INFO", "system", report.value("system_info").toObject());
    writeEvent(text, time, "ERROR", "crash", report.value("crash_info").toObject());
    const auto threads = report.value("threads").toArray();
    const auto captured = report.value("crash_info").toObject().value("crashing_thread").toInt(-1);
    qsizetype preferred = -1;
    if (!hangThreadId.isEmpty()) {
        for (qsizetype index = 0; index < threads.size(); ++index) {
            if (threadIdText(threads[index].toObject().value("thread_id")) == hangThreadId) {
                preferred = index;
                break;
            }
        }
    }
    // 卡死报告先展示被阻塞的线程，避免把 watchdog 误读成崩溃点。
    QList<qsizetype> order;
    if (preferred >= 0) {
        order.append(preferred);
    }
    if (captured >= 0 && captured < threads.size() && captured != preferred) {
        order.append(captured);
    }
    for (qsizetype index = 0; index < threads.size(); ++index) {
        if (index != preferred && index != captured) {
            order.append(index);
        }
    }
    for (const auto index : order) {
        auto thread = threads[index].toObject();
        auto frames = thread.take("frames").toArray();
        if (index == captured) {
            frames = report.value("crashing_thread").toObject().value("frames").toArray();
        }
        writeEvent(text, time, "INFO", "thread", thread);
        for (const auto &value : frames) {
            auto frame = value.toObject();
            frame["thread_id"] = thread.value("thread_id");
            writeEvent(text, time, "INFO", "stack.frame", frame);
        }
    }
    for (const auto &module : report.value("modules").toArray()) {
        writeEvent(text, time, "INFO", "module", module.toObject());
    }
}

/** 成功日志与对应转储按相同前缀保留最近二十份；未成功解析的数据库现场不删除。 */
void pruneReports(const QDir &directory) {
    const auto reports = directory.entryInfoList({"native-*.log"}, QDir::Files, QDir::Time);
    for (qsizetype i = 20; i < reports.size(); ++i) {
        const auto prefix = reports[i].absolutePath() + '/' + reports[i].completeBaseName();
        QFile::remove(prefix + ".log");
        QFile::remove(prefix + ".dmp");
        QFile::remove(prefix + ".dmp.part");
    }
}

/** 先写临时文件再改名；残留的旧文件按大小校验后重拷，避免把截断转储当成完整现场。 */
bool ensureDumpCopy(const QString &source, const QString &dump) {
    const qint64 sourceSize = QFileInfo(source).size();
    if (sourceSize > 0 && QFileInfo(dump).size() == sourceSize) {
        return true;
    }
    QFile::remove(dump);
    const auto partial = dump + ".part";
    QFile::remove(partial);
    if (!QFile::copy(source, partial)) {
        return false;
    }
    if (!QFile::rename(partial, dump)) {
        QFile::remove(partial);
        return false;
    }
    return true;
}

/** 在独立进程调用现成栈解析器，原子保存统一文本；目标进程即使被强杀也不影响此处。 */
bool exportReport(crashpad::CrashReportDatabase &database,
                  const crashpad::CrashReportDatabase::Report &report, const QDir &directory) {
    const auto name = "native-" +
                      QDateTime::fromSecsSinceEpoch(report.creation_time).toString("yyyyMMdd-HHmmss") + '-' +
                      QString::fromStdString(report.uuid.ToString());
    const auto dump = directory.filePath(name + ".dmp");
    if (!ensureDumpCopy(qtPath(report.file_path), dump)) {
        return false;
    }
    const auto binaries = QCoreApplication::applicationDirPath();
#ifdef Q_OS_WIN
    const QString suffix = ".exe";
    const auto parserPath = binaries + "/crash-tools/minidump-stackwalk" + suffix;
    const auto symbolPath = binaries + "/crash-symbols";
#else
    const auto parserPath = binaries + "/minidump-stackwalk";
    const auto symbolPath = QDir(binaries).absoluteFilePath("../Resources/crash-symbols");
#endif
    QProcess parser;
    parser.setProgram(parserPath);
    parser.setArguments({"--json", "--use-local-debuginfo", dump, symbolPath});
    parser.start();
    bool parsed = parser.waitForStarted(5000) && parser.waitForFinished(60000);
    if (parser.state() != QProcess::NotRunning) {
        parser.kill();
        parser.waitForFinished(5000);
    }
    parsed = parsed && parser.exitStatus() == QProcess::NormalExit && parser.exitCode() == 0;
    QJsonParseError error;
    const auto decoded = QJsonDocument::fromJson(parser.readAllStandardOutput(), &error).object();
    parsed = parsed && error.error == QJsonParseError::NoError && decoded.value("status") == "OK";
    QString log;
    QTextStream text(&log);
    crashpad::FileReader reader;
    crashpad::ProcessSnapshotMinidump snapshot;
    const bool snapshotRead = reader.Open(nativePath(dump)) && snapshot.Initialize(&reader);
    qint64 capturedMs = qint64(report.creation_time) * 1000;
    if (snapshotRead) {
        timeval capturedTime{};
        snapshot.SnapshotTime(&capturedTime);
        capturedMs = qint64(capturedTime.tv_sec) * 1000 + capturedTime.tv_usec / 1000;
    }
    const auto time = QDateTime::fromMSecsSinceEpoch(capturedMs).toUTC().toString(Qt::ISODateWithMs);
    writeEvent(text, time, "INFO", "native.report",
               {
                   {"id", QString::fromStdString(report.uuid.ToString())},
                   {"dump", QFileInfo(dump).fileName()},
                   {"uptime_seconds", decoded.value("process_uptime")},
               });
    QString hangThreadId;
    if (snapshotRead) {
        hangThreadId = writeSnapshot(text, time, snapshot);
    } else {
        writeEvent(text, time, "ERROR", "snapshot.read", {{"status", "failed"}});
    }
    if (parsed) {
        writeStack(text, time, decoded, hangThreadId);
    } else {
        writeEvent(text, time, "ERROR", "stack.parse",
                   {
                       {"status", "failed"},
                       {"error", parser.errorString()},
                       {"stderr", QString::fromUtf8(parser.readAllStandardError())},
                       {"json_error", error.errorString()},
                   });
    }
    const auto bytes = log.toUtf8();
    QSaveFile file(directory.filePath(name + ".log"));
    if (!file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size() || !file.commit()) {
        return false;
    }
    QFile::setPermissions(file.fileName(), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    QFile::setPermissions(dump, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    if (parsed) {
        // 删除失败时本会话不再重试，避免每秒重复解析；日志已经保存。
        if (database.DeleteReport(report.uuid) != crashpad::CrashReportDatabase::kNoError) {
            return false;
        }
        pruneReports(directory);
    }
    return parsed;
}

/** 导出数据库中的待处理现场；本进程已失败过的 UUID 不再每秒重试。 */
void processReports(crashpad::CrashReportDatabase &database, const QDir &directory, QSet<QString> &failed) {
    std::vector<crashpad::CrashReportDatabase::Report> pending;
    std::vector<crashpad::CrashReportDatabase::Report> completed;
    database.GetPendingReports(&pending);
    database.GetCompletedReports(&completed);
    pending.insert(pending.end(), completed.begin(), completed.end());
    for (const auto &report : pending) {
        const auto id = QString::fromStdString(report.uuid.ToString());
        if (failed.contains(id)) {
            continue;
        }
        if (!exportReport(database, report, directory)) {
            failed.insert(id);
        }
    }
}
} // namespace

/** 只处理本地 Crashpad 数据库；不初始化 GUI、播放、遥测上传或渲染后端。 */
int main(int argc, char **argv) {
    QCoreApplication application(argc, argv);
    const auto arguments = application.arguments();
    if (arguments.size() != 4) {
        return 2;
    }
    const QDir directory(arguments[1]);
    const auto databasePath = QFileInfo(arguments[2]).absoluteFilePath();
    if (databasePath != QDir(directory).absoluteFilePath(".crashpad")) {
        return 2;
    }
    bool validPid = false;
    const auto processId = arguments[3].toULongLong(&validPid);
    if (!validPid || processId == 0) {
        return 2;
    }
#ifdef Q_OS_WIN
    const auto process = OpenProcess(SYNCHRONIZE, FALSE, DWORD(processId));
#endif
    // 恢复上次报告进程异常结束后尚未解析的现场；锁在进程存活期间一直持有。
    auto database = crashpad::CrashReportDatabase::InitializeWithoutCreating(nativePath(databasePath));
    QLockFile exportLock(directory.filePath(".crashpad/export.lock"));
    exportLock.setStaleLockTime(0);
    bool locked = false;
    QSet<QString> failed;
    int exitedChecks = 0;
    while (exitedChecks < 5) {
        if (!locked) {
            locked = exportLock.tryLock(0);
        }
        if (locked && database) {
            processReports(*database, directory, failed);
        }
#ifdef Q_OS_WIN
        const bool alive = process && WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
#else
        const bool alive = kill(pid_t(processId), 0) == 0 || errno == EPERM;
#endif
        exitedChecks = alive ? 0 : exitedChecks + 1;
        QThread::msleep(1000);
    }
#ifdef Q_OS_WIN
    if (process) {
        CloseHandle(process);
    }
#endif
    return 0;
}
