#pragma once

#include <QJsonObject>
#include <QString>
#include <functional>

class QObject;

namespace PluginInstaller {
inline constexpr qint64 MaxExtractedBytes = 256LL * 1024 * 1024;
inline constexpr qint64 MaxPackageBytes = MaxExtractedBytes + 8LL * 1024 * 1024;
inline constexpr qint64 MaxFileBytes = 64LL * 1024 * 1024;
using Reply = std::function<void(QJsonObject, QString)>;

QString clientVersion();
QString platform();
bool validId(const QString &id);
bool relativePath(const QString &path);
void run(QObject *context, const QString &root, QJsonObject request, Reply reply);
QJsonObject runSynchronously(const QString &root, QJsonObject request, QString &error);
QString recover(const QString &pluginRoot);
QString commit(const QString &pluginRoot, const QString &id, const QString &candidate,
               const std::function<QString()> &validate);
}
