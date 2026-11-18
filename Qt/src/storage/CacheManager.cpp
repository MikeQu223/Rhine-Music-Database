#include "CacheManager.h"
#include "StorageCoordinator.h"
#include <QDateTime>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonArray>
#include <QLockFile>
#include <QDir>
#include <utility>

class CacheManager::Worker : public QObject {
  public:
    explicit Worker(QString path) : path(std::move(path)) {
    }

    bool open() {
#if !RHINE_SQL_CACHE
        return false;
#endif
        const auto now = QDateTime::currentMSecsSinceEpoch();
        if (!available && now >= retryAtMs) {
            retryAtMs = now + 30000;
            if (QDir().mkpath(QFileInfo(path).absolutePath())) {
                lock = std::make_unique<QLockFile>(path + ".lock");
                lock->setStaleLockTime(0);
                available = lock->tryLock(0) && database.open(path);
            }
            if (!available) {
                lock.reset();
                qWarning().noquote() << "缓存数据库不可用：" << error();
            }
        }
        return available;
    }

    QString error() const {
#if !RHINE_SQL_CACHE
        return QStringLiteral("此构建未启用 SQLite 缓存");
#endif
        return database.error().isEmpty() ? QStringLiteral("无法取得缓存目录的独占写入权") : database.error();
    }

    qint64 fileBytes() const {
        return QFileInfo(path).size() + QFileInfo(path + "-wal").size() + QFileInfo(path + "-shm").size();
    }

    QString path;
    std::unique_ptr<QLockFile> lock;
    CacheDatabase database;
    qint64 retryAtMs = 0;
    bool available = false;
    QString lastWriteError;
};

CacheManager::CacheManager(QString path) : m_worker(new Worker(std::move(path))) {
    m_worker->moveToThread(&m_thread);
    connect(&m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
    m_thread.start(QThread::LowPriority);
}

CacheManager::~CacheManager() {
    m_thread.quit();
    m_thread.wait();
}

void CacheManager::registerNamespace(QString nameSpace, qint64 quotaBytes) {
    m_policies[nameSpace].quotaBytes = quotaBytes;
}

quint64 CacheManager::generation(const QString &nameSpace) const {
    return m_policies.value(nameSpace).generation;
}

void CacheManager::lookup(CacheKey key, quint64 generation, Lookup done) {
    const auto policy = m_policies.value(key.nameSpace);
    if (policy.generation != generation || policy.clearsPending || policy.clearFailed ||
        policy.quotaBytes <= 0) {
        done({});
        return;
    }
    QMetaObject::invokeMethod(m_worker, [this, key = std::move(key), generation, done = std::move(done)] {
        std::optional<QJsonObject> value;
        if (m_worker->open()) {
            const auto bytes = m_worker->database.lookup(key, QDateTime::currentMSecsSinceEpoch());
            if (bytes) {
                const auto parsed = QJsonDocument::fromJson(*bytes);
                if (parsed.isObject()) {
                    value = parsed.object();
                } else {
                    m_worker->database.erase(key);
                }
            }
        }
        QMetaObject::invokeMethod(this, [this, key, generation, value, done] {
            const auto current = m_policies.value(key.nameSpace);
            done(current.generation == generation && !current.clearsPending && !current.clearFailed
                     ? value
                     : std::nullopt);
        });
    });
}

void CacheManager::store(CacheKey key, quint64 generation, QJsonObject value, qint64 ttlMs,
                         std::function<void(bool)> verified,
                         std::function<bool(const QJsonObject &)> admissible) {
    const auto policy = m_policies.value(key.nameSpace);
    if (policy.generation != generation || policy.clearsPending || policy.clearFailed ||
        policy.quotaBytes <= 0 || ttlMs <= 0) {
        if (verified) {
            verified(false);
        }
        return;
    }
    QMetaObject::invokeMethod(m_worker, [this, key = std::move(key), value = std::move(value), policy, ttlMs,
                                         verified = std::move(verified), admissible = std::move(admissible)] {
        bool success = false;
        if ((!admissible || admissible(value)) && m_worker->open()) {
            const auto now = QDateTime::currentMSecsSinceEpoch();
            const auto bytes = QJsonDocument(value).toJson(QJsonDocument::Compact);
            success = m_worker->database.store(key, bytes, now + ttlMs, now, policy.quotaBytes);
            if (!success) {
                const auto error = m_worker->database.error();
                if (!error.isEmpty() && error != m_worker->lastWriteError) {
                    m_worker->lastWriteError = error;
                    qWarning().noquote() << "无法写入缓存数据库：" << error;
                }
            }
            if (success && verified) {
                success = m_worker->database.lookup(key, now) == bytes;
            }
        }
        if (verified) {
            QMetaObject::invokeMethod(this, [this, key, policy, success, verified] {
                verified(success && this->generation(key.nameSpace) == policy.generation);
            });
        }
    });
}

/** 在调用线程先推进代数，工作线程按入队顺序完成删除事务。 */
void CacheManager::clear(QString nameSpace, Completion done) {
    auto &policy = m_policies[nameSpace];
    ++policy.generation;
    ++policy.clearsPending;
    QMetaObject::invokeMethod(m_worker, [this, nameSpace = std::move(nameSpace), done = std::move(done)] {
        const auto before = m_worker->fileBytes();
        QJsonObject result;
        if (!m_worker->open()) {
            result = before == 0 ? StorageCoordinator::result(nameSpace, "cleared")
                                 : StorageCoordinator::result(nameSpace, "unavailable", m_worker->error());
        } else if (const auto removed = m_worker->database.clear(nameSpace)) {
            result = StorageCoordinator::result(nameSpace, "cleared");
            result["entries"] = removed->entries;
            result["logicalBytes"] = removed->logicalBytes;
            result["releasedFileBytes"] = qMax<qint64>(0, before - m_worker->fileBytes());
        } else {
            result = StorageCoordinator::result(nameSpace, "failed", m_worker->database.error());
        }
        QMetaObject::invokeMethod(this, [this, nameSpace, result, done] {
            auto &policy = m_policies[nameSpace];
            --policy.clearsPending;
            policy.clearFailed = result["status"] != "cleared";
            done(result);
        });
    });
}

void CacheManager::stats(std::function<void(QJsonArray)> done) {
    const auto policies = m_policies;
    QMetaObject::invokeMethod(m_worker, [this, policies, done = std::move(done)] {
        QJsonArray results;
        const bool available = m_worker->open();
        auto files = StorageCoordinator::result("cache.sqlite", available ? "available" : "unavailable",
                                                available ? QString() : m_worker->error());
        files["fileBytes"] = m_worker->fileBytes();
        results.append(files);
        if (available) {
            for (auto policy = policies.constBegin(); policy != policies.constEnd(); ++policy) {
                const auto totals = m_worker->database.stats(policy.key());
                auto result = StorageCoordinator::result(policy.key(), totals ? "available" : "failed",
                                                         totals ? QString() : m_worker->database.error());
                result["quotaBytes"] = policy->quotaBytes;
                if (totals) {
                    result["entries"] = totals->entries;
                    result["logicalBytes"] = totals->logicalBytes;
                }
                results.append(result);
            }
        }
        QMetaObject::invokeMethod(this, [results, done] { done(results); });
    });
}
