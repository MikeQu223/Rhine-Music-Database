#pragma once
#include "CacheDatabase.h"
#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QThread>
#include <functional>

class CacheManager : public QObject {
  public:
    using Lookup = std::function<void(std::optional<QJsonObject>)>;
    using Completion = std::function<void(QJsonObject)>;

    explicit CacheManager(QString path);
    ~CacheManager() override;
    void registerNamespace(QString nameSpace, qint64 quotaBytes);
    quint64 generation(const QString &nameSpace) const;
    void lookup(CacheKey key, quint64 generation, Lookup done);
    void store(CacheKey key, quint64 generation, QJsonObject value, qint64 ttlMs,
               std::function<void(bool)> verified = {},
               std::function<bool(const QJsonObject &)> admissible = {});
    void clear(QString nameSpace, Completion done);
    void stats(std::function<void(QJsonArray)> done);

  private:
    struct Policy {
        qint64 quotaBytes = 0;
        quint64 generation = 0;
        int clearsPending = 0;
        bool clearFailed = false;
    };
    class Worker;
    QHash<QString, Policy> m_policies;
    QThread m_thread;
    Worker *m_worker;
};
