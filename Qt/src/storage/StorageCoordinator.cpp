#include "StorageCoordinator.h"
#include "PlaybackConnection.h"
#include <QPointer>
#include <memory>
#include <utility>

StorageCoordinator::StorageCoordinator(PlaybackConnection *remote) : m_hasRemote(remote != nullptr) {
    if (remote) {
        addStatsOperation([connection = QPointer(remote)](Completion done) {
            if (!connection) {
                done({result("shared", "unavailable", QStringLiteral("后台播放服务未连接"))});
                return;
            }
            connection->request("storage.stats", {}, [done](QJsonObject response, QString error) {
                if (!error.isEmpty()) {
                    done({result("shared", "unavailable", error)});
                    return;
                }
                done(response["items"].toArray());
            });
        });
        m_operations.append([connection = QPointer(remote)](Completion done) {
            if (!connection) {
                done({result("shared", "unavailable", QStringLiteral("后台播放服务未连接"))});
                return;
            }
            connection->request("storage.clearCaches", {}, [done](QJsonObject response, QString error) {
                const auto items = response["items"].toArray();
                if (!error.isEmpty() || items.isEmpty()) {
                    done({result("shared", "failed",
                                 error.isEmpty() ? QStringLiteral("未收到清理结果") : error)});
                    return;
                }
                done(items);
            });
        });
    }
}

void StorageCoordinator::addCacheOperation(Operation operation) {
    m_operations.insert(m_operations.size() - (m_hasRemote ? 1 : 0), std::move(operation));
}

void StorageCoordinator::addStatsOperation(Operation operation) {
    m_stats.append(std::move(operation));
}

void StorageCoordinator::stats(Completion completion) {
    collect(m_stats, std::move(completion));
}

void StorageCoordinator::clearCaches(Completion completion) {
    collect(m_operations, std::move(completion));
}

/** 同时启动已注册的清理操作，收齐各所有者的结果后再答复。 */
void StorageCoordinator::collect(const QList<Operation> &registered, Completion completion) {
    if (registered.isEmpty()) {
        completion({});
        return;
    }
    struct Pending {
        qsizetype remaining;
        QJsonArray items;
        Completion completion;
    };
    auto pending = std::make_shared<Pending>(Pending{registered.size(), {}, std::move(completion)});
    const auto operations = registered;
    for (const auto &operation : operations) {
        operation([owner = QPointer(this), pending](QJsonArray items) {
            if (!owner) {
                return;
            }
            for (const auto &item : items) {
                pending->items.append(item);
            }
            if (--pending->remaining == 0) {
                pending->completion(pending->items);
            }
        });
    }
}

QJsonObject StorageCoordinator::result(const QString &category, const QString &status, const QString &error) {
    QJsonObject value{{"category", category}, {"status", status}};
    if (!error.isEmpty()) {
        value.insert("error", error);
    }
    return value;
}
