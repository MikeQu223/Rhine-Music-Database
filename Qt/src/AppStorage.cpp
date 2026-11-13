#include "AppStorage.h"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>
#include <QTemporaryFile>
#include <cstdlib>
#ifdef Q_OS_WIN
#include <windows.h>
#include <array>
#endif

namespace {
QString portableRoot;

bool setPathEnvironment(const char *name, const QString &value) {
#ifdef Q_OS_WIN
    // 窄字符 CRT 环境变量会破坏中文路径；同时更新 CRT 与 Windows 的 Unicode 环境。
    const auto key = QString::fromLatin1(name);
    return _wputenv_s(reinterpret_cast<const wchar_t *>(key.utf16()),
                      reinterpret_cast<const wchar_t *>(value.utf16())) == 0;
#else
    return qputenv(name, value.toUtf8());
#endif
}
}

/**
 * 在初始化 Qt 引擎前建立绿色版目录，并限定本进程的临时文件与 QML 缓存路径。
 * 目录不可写时明确失败，禁止回退到用户目录或读取旧版注册表配置。
 */
QString AppStorage::initializePortable(const QString &applicationDirectory) {
    if (applicationDirectory.isEmpty()) {
        return QStringLiteral("无法确定应用目录");
    }
    const auto directory = QDir(applicationDirectory).absoluteFilePath("data");
    for (const auto &suffix : {"", "/temp"}) {
        if (!QDir().mkpath(directory + suffix)) {
            return QStringLiteral("应用目录不可写，请将完整文件夹移到可写的位置");
        }
    }
    QTemporaryFile probe(directory + "/write-check-XXXXXX");
    if (!probe.open()) {
        return QStringLiteral("应用目录不可写，请将完整文件夹移到可写的位置");
    }
    portableRoot = directory;
    QDir().mkpath(cacheDirectory() + "/qml");
    QDir().mkpath(cacheDirectory() + "/shaders");
    const auto temporary = QDir::toNativeSeparators(temporaryDirectory());
    if (!setPathEnvironment("TEMP", temporary) || !setPathEnvironment("TMP", temporary) ||
        !setPathEnvironment("TMPDIR", temporary) ||
        !setPathEnvironment("QML_DISK_CACHE_PATH", cacheDirectory() + "/qml")) {
        return QStringLiteral("无法设置绿色版缓存目录，请重试");
    }
    // OpenGL 回退后端没有自定义缓存路径；禁用其磁盘缓存，D3D 管线缓存另存于应用目录。
    qputenv("QT_DISABLE_SHADER_DISK_CACHE", "1");
    return {};
}

QString AppStorage::executableDirectory() {
#ifdef Q_OS_WIN
    // 使用系统给出的 Unicode 模块路径，避免工作目录和含中文的 argv 路径影响存储位置。
    std::array<wchar_t, 32768> filename{};
    const auto length = GetModuleFileNameW(nullptr, filename.data(), DWORD(filename.size()));
    if (length == 0 || length >= filename.size()) {
        return {};
    }
    return QFileInfo(QString::fromWCharArray(filename.data(), int(length))).absolutePath();
#else
    return QCoreApplication::applicationDirPath();
#endif
}

QString AppStorage::dataDirectory() {
    if (!portableRoot.isEmpty()) {
        return portableRoot;
    }
#ifdef Q_OS_WIN
    return QDir(executableDirectory()).absoluteFilePath("data");
#else
    return QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation);
#endif
}

QString AppStorage::cacheDirectory() {
#ifdef Q_OS_WIN
    return dataDirectory() + "/cache";
#else
    if (!portableRoot.isEmpty()) {
        return portableRoot + "/cache";
    }
    return QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
#endif
}

QString AppStorage::temporaryDirectory() {
    if (!portableRoot.isEmpty()) {
        return portableRoot + "/temp";
    }
#ifdef Q_OS_WIN
    return dataDirectory() + "/temp";
#else
    return QDir::tempPath();
#endif
}

QSettings AppStorage::settings() {
#ifdef Q_OS_WIN
    return QSettings(dataDirectory() + "/settings.ini", QSettings::IniFormat);
#else
    if (!portableRoot.isEmpty()) {
        return QSettings(portableRoot + "/settings.ini", QSettings::IniFormat);
    }
    return QSettings();
#endif
}
