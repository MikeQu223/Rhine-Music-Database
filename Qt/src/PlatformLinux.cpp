#include "Host.h"
#include "AppStorage.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <QDesktopServices>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>
#include <QUrl>

namespace {
// 凭据与 Windows 版一样留在应用数据目录，只是改用文件权限约束；不依赖桌面密钥环进程。
QString credentialPath() {
    return AppStorage::dataDirectory() + "/account.credential";
}

// 按 XDG 顺序查找桌面条目；用户目录优先，系统目录兜底。
QStringList desktopDirectories() {
    QStringList directories;
    for (const auto &base : QStandardPaths::standardLocations(QStandardPaths::GenericDataLocation)) {
        directories << base + "/applications";
    }
    directories << QStringLiteral("/usr/local/share/applications")
                << QStringLiteral("/usr/share/applications");
    directories.removeDuplicates();
    return directories;
}

// 只按桌面条目判断协议是否已注册，不猜测客户端安装路径，也不自行解析启动命令。
bool schemeRegistered(const QString &scheme) {
    const auto handler = QStringLiteral("x-scheme-handler/") + scheme;
    for (const auto &directory : desktopDirectories()) {
        QDirIterator iterator(directory, {"*.desktop"}, QDir::Files);
        while (iterator.hasNext()) {
            QFile file(iterator.next());
            if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
                continue;
            }
            if (file.readAll().contains(handler.toUtf8())) {
                return true;
            }
        }
    }
    return false;
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
    const auto directory = QFileInfo(credentialPath()).absolutePath();
    if (!QDir().mkpath(directory)) {
        return QStringLiteral("登录成功，但 Linux 凭据当前不可写");
    }
    // 创建时就限定 0600，避免登录态在写入期间对其他用户可读。
    const auto path = QFile::encodeName(credentialPath());
    const auto handle = ::open(path.constData(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (handle < 0) {
        return QStringLiteral("登录成功，但 Linux 凭据当前不可写");
    }
    // 已有的旧文件不受创建模式位影响，登录前遗留的宽权限同样收紧。
    ::fchmod(handle, 0600);
    const auto written = ::write(handle, bytes.constData(), size_t(bytes.size()));
    ::close(handle);
    return written == bytes.size() ? QString() : QStringLiteral("登录成功，但 Linux 凭据当前不可写");
}

void platformDeleteCredential() {
    QFile::remove(credentialPath());
}

void platformPlay(const QString &id, const QJsonObject &config, bool activate,
                  std::function<void(QString)> done) {
    Q_UNUSED(activate)
    const auto scheme = config["scheme"].toString();
    if (!schemeRegistered(scheme)) {
        done(config["application"]
                 .toObject()["missingMessage"]
                 .toString(QStringLiteral("未安装或未注册官方客户端")));
        return;
    }
    auto payload = config["payload"].toString();
    payload.replace("{id}", id);
    const auto encoding = config["encoding"].toString();
    if (encoding == "base64") {
        payload = QString::fromLatin1(payload.toUtf8().toBase64());
    } else if (encoding == "percent") {
        payload = QString::fromLatin1(QUrl::toPercentEncoding(payload));
    }
    const auto url = QUrl(scheme + "://" + payload);
    if (QDesktopServices::openUrl(url)) {
        done(config["successMessage"].toString(QStringLiteral("已交给官方客户端")));
    } else {
        done(config["failureMessage"].toString(QStringLiteral("交付失败")));
    }
}
