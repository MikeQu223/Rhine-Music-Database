#include "AppStorage.h"
#include "Host.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>

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

void platformPlay(const QString &, bool, std::function<void(QString)> done) {
    done(QStringLiteral("Android 仅支持面板内播放"));
}

/**
 * 系统媒体会话（通知栏/锁屏控制）需要一层 Java 侧 MediaSession，
 * 当前构建没有随包 Java 源码，因此这里保持空实现：
 * 面板内的播放、暂停、上下曲不受影响，只是不会出现在系统媒体控件里。
 * 这条限制在 docs/ANDROID.md 里对用户明示，不要让它变成"看起来支持、实际没反应"。
 */
void platformMediaCommands(std::function<void(QString)> callback) {
    Q_UNUSED(callback)
}

void platformMediaInfo(QString title, QString artist, QString album, QVariantMap state) {
    Q_UNUSED(title)
    Q_UNUSED(artist)
    Q_UNUSED(album)
    Q_UNUSED(state)
}
