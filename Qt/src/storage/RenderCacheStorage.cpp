#include "RenderCacheStorage.h"
#include "AppStorage.h"
#include <QDir>
#include <QFileInfo>
#include <QLockFile>
#include <QSaveFile>

namespace {
const QStringList &categories() {
    static const QStringList values{"qml", "shaders"};
    return values;
}
}

/** 仅在 GUI 初始化渲染之前，且持有同一目录的渲染锁时兑现清理请求。 */
RenderCacheStorage::RenderCacheStorage() : m_root(AppStorage::cacheDirectory()) {
    if (m_root.isEmpty() || !QDir().mkpath(m_root)) {
        return;
    }
    m_lock = std::make_unique<QLockFile>(m_root + "/render-cache.lock");
    m_lock->setStaleLockTime(0);
    m_ownsCache = m_lock->tryLock(0);
    const auto marker = m_root + "/clear-render-cache";
    if (!m_ownsCache || !QFileInfo::exists(marker)) {
        return;
    }
    bool success = true;
    for (const auto &category : categories()) {
        const auto path = m_root + '/' + category;
        const QFileInfo info(path);
        if (info.isSymLink() || (info.exists() && (!info.isDir() || !QDir(path).removeRecursively()))) {
            success = false;
        }
    }
    if (success) {
        QFile::remove(marker);
    } else {
        qWarning("未能清理全部渲染缓存，保留清理标记");
    }
}

RenderCacheStorage::~RenderCacheStorage() = default;

QJsonArray RenderCacheStorage::scheduleClear() {
    QJsonArray results;
    const auto present = stats();
    if (present.isEmpty()) {
        return results;
    }
    QSaveFile marker(m_root + "/clear-render-cache");
    const bool scheduled =
        m_ownsCache && marker.open(QIODevice::WriteOnly) && marker.write("1") == 1 && marker.commit();
    for (const auto &item : present) {
        results.append(StorageCoordinator::result(
            item.toObject()["category"].toString(), scheduled ? "deferred" : "failed",
            scheduled ? QString() : QStringLiteral("无法安排渲染缓存清理")));
    }
    return results;
}

QJsonArray RenderCacheStorage::stats() const {
    QJsonArray results;
    if (!m_root.isEmpty()) {
        for (const auto &category : categories()) {
            if (QFileInfo::exists(m_root + '/' + category)) {
                results.append(StorageCoordinator::result(category, "active"));
            }
        }
    }
    return results;
}
