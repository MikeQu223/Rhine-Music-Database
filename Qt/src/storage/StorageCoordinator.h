#pragma once
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <functional>

class PlaybackConnection;

class StorageCoordinator : public QObject {
  public:
    using Completion = std::function<void(QJsonArray)>;
    using Operation = std::function<void(Completion)>;

    explicit StorageCoordinator(PlaybackConnection *remote = nullptr);
    void addCacheOperation(Operation operation);
    void addStatsOperation(Operation operation);
    void clearCaches(Completion completion);
    void stats(Completion completion);
    static QJsonObject result(const QString &category, const QString &status, const QString &error = {});

  private:
    QList<Operation> m_operations;
    bool m_hasRemote = false;
    QList<Operation> m_stats;
    void collect(const QList<Operation> &operations, Completion completion);
};
