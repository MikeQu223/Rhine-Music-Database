#include "AndroidMediaSession.h"
#include "AppStorage.h"
#include "Host.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QVariantMap>
#include <functional>

namespace {
/** 凭据落在应用私有目录。Android 的 per-app 沙箱已经隔离了其它应用，
 *  0600 只是把同一 uid 下的其它进程（理论上存在的）也挡在外面。 */
QString credentialPath() {
    return AppStorage::dataDirectory() + "/account.credential";
}
}

QByteArray platformCredential() {
    QFile file(credentialPath());
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }
    return file.readAll();
}

QString platformSaveCredential(const QByteArray &bytes) {
    const auto note = QStringLiteral("登录成功，但 Android 凭据当前不可写");
    const auto directory = QFileInfo(credentialPath()).absolutePath();
    if (!QDir().mkpath(directory)) {
        return note;
    }
    QFile file(credentialPath());
    // QFile 在 Android 上等价于 fopen(..., 0666 & ~umask)，umask 通常是 077，
    // 但这里不依赖默认值：写完之后显式收紧一次权限。
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        return note;
    }
    const auto written = file.write(bytes);
    file.close();
    QFile::setPermissions(credentialPath(), QFile::ReadOwner | QFile::WriteOwner);
    return written == bytes.size() ? QString() : note;
}

void platformDeleteCredential() {
    QFile::remove(credentialPath());
}

void platformPlay(const QString &, const QJsonObject &, bool, std::function<void(QString)> done) {
    done(QStringLiteral("Android 仅支持面板内播放"));
}

/**
 * 系统媒体控件（通知栏/锁屏/耳机按键）由 AndroidMediaSession 驱动：
 * Host 注册动作回调，mediaState 每秒上报一次状态，Java 侧的 MediaSession
 * 把耳机/通知栏的命令经同一条通路送回 Host::mediaAction。
 * 动作字符串与 iOS 的 MPRemoteCommandCenter 完全一致（resume/pause/toggle/next/prev）。
 */
void platformMediaCommands(std::function<void(QString)> callback) {
    AndroidMediaSession::setCommandCallback(std::move(callback));
}

void platformMediaInfo(QString title, QString artist, QString album, QVariantMap state,
                       const QString &coverPath) {
    if (title.isEmpty() || state.value("duration").toLongLong() <= 0) {
        // 转待机而非撤岗：前台服务保持运行，防止系统在无播放时回收进程（可随时续播）。
        AndroidMediaSession::stop();
        return;
    }
    AndroidMediaSession::ensureStarted();
    AndroidMediaSession::update(state.value("playing").toBool(), state.value("position").toLongLong(),
                                state.value("duration").toLongLong(), title, artist, album, coverPath);
}
