#pragma once

#include <QDir>
#include <QUrl>

namespace PluginOpenRequest {
constexpr qsizetype MaxPendingFiles = 16;

// 这是入口筛选。实际容器格式与文件内容由统一安装器验证。
inline bool isPackagePath(const QString &path) {
    return path.size() <= 32768 && !path.contains(QChar::Null) && !path.startsWith(':') &&
           QDir::isAbsolutePath(path) && path.endsWith(".rhineplugin", Qt::CaseInsensitive);
}

inline bool isPackageUrl(const QUrl &url) {
    return url.isLocalFile() && isPackagePath(url.toLocalFile());
}
}
