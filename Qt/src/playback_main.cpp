#include "AppIdentity.h"
#include "AppStorage.h"
#include "PlaybackService.h"
#include <QDir>
#include <QGuiApplication>
#include <QFileInfo>
#include <QIcon>
#include <QLockFile>
#include <QTimer>

#ifdef Q_OS_MACOS
void platformBackgroundService();
int runMacSpatialAudioProbe(const QString &filePath);
#endif

/** 后台入口仅初始化音频与本地 IPC，禁止在此创建窗口、托盘或渲染引擎。 */
int main(int argc, char **argv) {
#ifdef Q_OS_WIN
    const auto storageError = AppStorage::initializePortable(AppStorage::executableDirectory());
    if (!storageError.isEmpty()) {
        return 1;
    }
#endif
    if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND")) {
        qputenv("QT_MEDIA_BACKEND", "ffmpeg");
    }
#ifdef Q_OS_MACOS
    // Helper 自身从启动起就是独立 agent，不能先成为主应用的第二个 Dock 实例再切换身份。
    qputenv("QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM", "1");
    const QDir plugins(QFileInfo(QString::fromLocal8Bit(argv[0])).absolutePath() + "/../../../../PlugIns");
    if (plugins.exists("platforms/libqcocoa.dylib")) {
        qputenv("QT_PLUGIN_PATH", plugins.absolutePath().toUtf8());
    }
#endif
    QGuiApplication application(argc, argv);
    QCoreApplication::setApplicationVersion(AppUpdater::currentVersion());
    QCoreApplication::setOrganizationName(AppIdentity::Organization);
    QCoreApplication::setOrganizationDomain(AppIdentity::Id);
    QCoreApplication::setApplicationName(AppIdentity::Id);
    QGuiApplication::setApplicationDisplayName(AppIdentity::DisplayName);
    application.setWindowIcon(QIcon(":/icons/icon-256.png"));
    application.setQuitOnLastWindowClosed(false);
    const auto arguments = application.arguments();
    const bool test = arguments.contains("--offline-test");
    if (test) {
        const auto directory = arguments.value(arguments.indexOf("--offline-test") + 1);
        if (directory.isEmpty() || !AppStorage::initializePortable(directory).isEmpty()) {
            return 1;
        }
    }
#ifdef Q_OS_MACOS
    platformBackgroundService();
    // 探针使用正式 helper 的应用身份，但独立于播放服务的数据目录和 IPC。
    if (arguments.value(1) == QStringLiteral("--spatial-audio-probe")) {
        if (arguments.size() != 3) {
            return 2;
        }
        return runMacSpatialAudioProbe(arguments.at(2));
    }
#endif
    const auto root = arguments.value(arguments.indexOf("--resources") + 1);
    const auto gui = arguments.value(arguments.indexOf("--gui") + 1);
    if (!arguments.contains("--resources") || root.isEmpty() || (!test && gui.isEmpty())) {
        return 1;
    }
    if (!QDir().mkpath(AppStorage::dataDirectory())) {
        return 1;
    }
    QLockFile lock(AppStorage::dataDirectory() + "/playback-service.lock");
    if (!lock.tryLock(0)) {
        if (arguments.contains("--show-interface")) {
            PlaybackConnection existing;
            if (existing.connectToService(PlaybackConnection::endpoint())) {
                existing.call("show");
            }
        }
        return 0;
    }
    PlaybackService service(root, gui, test);
    if (!service.listen(PlaybackConnection::endpoint())) {
        return 1;
    }
    if (arguments.contains("--show-interface")) {
        QTimer::singleShot(0, &service, &PlaybackService::showInterface);
    }
    QObject::connect(&application, &QCoreApplication::aboutToQuit, &service, &PlaybackService::shutdown);
    return application.exec();
}
