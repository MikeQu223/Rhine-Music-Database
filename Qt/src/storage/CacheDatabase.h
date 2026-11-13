#pragma once
#include <QByteArray>
#include <QString>
#include <optional>
#include <memory>

struct CacheKey {
    QString nameSpace;
    QString provider;
    QString scope;
    QString version;
    QByteArray request;
};

struct CacheRemoval {
    qint64 entries = 0;
    qint64 logicalBytes = 0;
};

class CacheDatabase {
  public:
    CacheDatabase();
    ~CacheDatabase();
    bool open(const QString &path);
    std::optional<QByteArray> lookup(const CacheKey &key, qint64 nowMs);
    bool store(const CacheKey &key, const QByteArray &payload, qint64 expiresMs, qint64 nowMs,
               qint64 quotaBytes);
    bool erase(const CacheKey &key);
    std::optional<CacheRemoval> clear(const QString &nameSpace);
    std::optional<CacheRemoval> stats(const QString &nameSpace);
    QString error() const;

  private:
    struct State;
    std::unique_ptr<State> m_state;
};
