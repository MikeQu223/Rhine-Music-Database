#include "CacheDatabase.h"
#include <QDir>
#include <QFileInfo>
#include <QUuid>
#if RHINE_SQL_CACHE
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>

namespace {
constexpr auto KEY_CONDITION = "namespace=? AND provider=? AND scope=? AND version=? AND request=?";

void bindKey(QSqlQuery &query, const CacheKey &key) {
    query.addBindValue(key.nameSpace);
    query.addBindValue(key.provider);
    query.addBindValue(key.scope);
    query.addBindValue(key.version);
    query.addBindValue(key.request);
}
}
#endif

struct CacheDatabase::State {
    QString error;
#if RHINE_SQL_CACHE
    QSqlDatabase db;

    bool execute(QSqlQuery &query) {
        if (query.exec()) {
            return true;
        }
        error = query.lastError().text();
        return false;
    }

    bool execute(const QString &statement) {
        QSqlQuery query(db);
        if (query.exec(statement)) {
            return true;
        }
        error = query.lastError().text();
        return false;
    }

    bool finishTransaction(bool succeeded) {
        if (succeeded && db.commit()) {
            return true;
        }
        if (succeeded) {
            error = db.lastError().text();
        }
        db.rollback();
        return false;
    }

    void close() {
        if (!db.isValid()) {
            return;
        }
        const auto name = db.connectionName();
        db.close();
        db = {};
        QSqlDatabase::removeDatabase(name);
    }

    ~State() {
        close();
    }
#endif
};

CacheDatabase::CacheDatabase() : m_state(std::make_unique<State>()) {
}
CacheDatabase::~CacheDatabase() = default;

bool CacheDatabase::open(const QString &path) {
#if RHINE_SQL_CACHE
    auto &state = *m_state;
    if (state.db.isOpen()) {
        return true;
    }
    state.error.clear();
    if (QFileInfo(path).isSymLink() || QFileInfo(path + "-wal").isSymLink() ||
        QFileInfo(path + "-shm").isSymLink()) {
        state.error = QStringLiteral("缓存数据库路径包含符号链接");
        return false;
    }
    if (!QSqlDatabase::isDriverAvailable("QSQLITE")) {
        state.error = QStringLiteral("QSQLITE 驱动不可用");
        return false;
    }
    if (!QDir().mkpath(QFileInfo(path).absolutePath())) {
        state.error = QStringLiteral("无法创建缓存目录");
        return false;
    }
    state.db = QSqlDatabase::addDatabase("QSQLITE", QUuid::createUuid().toString());
    state.db.setDatabaseName(path);
    state.db.setConnectOptions("QSQLITE_BUSY_TIMEOUT=250");
    if (!state.db.open()) {
        state.error = state.db.lastError().text();
        state.close();
        return false;
    }
    const auto initialize = [&state] {
        QSqlQuery query(state.db);
        if (!query.exec("PRAGMA user_version") || !query.next() || query.value(0).toInt() > 1) {
            state.error = QStringLiteral("无法读取缓存版本或版本过新");
            return false;
        }
        const bool newDatabase = query.value(0).toInt() == 0;
        query.finish();
        if (newDatabase && !state.execute("PRAGMA auto_vacuum=INCREMENTAL")) {
            return false;
        }
        if (!query.exec("PRAGMA journal_mode=WAL") || !query.next() || query.value(0).toString() != "wal") {
            state.error = QStringLiteral("无法启用 SQLite WAL");
            return false;
        }
        query.finish();
        if (!state.execute("PRAGMA max_page_count=98304") ||
            !state.execute("PRAGMA journal_size_limit=4194304") || !state.db.transaction()) {
            if (state.error.isEmpty()) {
                state.error = state.db.lastError().text();
            }
            return false;
        }
        return state.finishTransaction(
            state.execute("CREATE TABLE IF NOT EXISTS cache_entry ("
                          "namespace TEXT NOT NULL, provider TEXT NOT NULL, scope TEXT NOT NULL,"
                          "version TEXT NOT NULL, request BLOB NOT NULL, payload BLOB NOT NULL,"
                          "bytes INTEGER NOT NULL, expires INTEGER NOT NULL, accessed INTEGER NOT NULL,"
                          "PRIMARY KEY(namespace,provider,scope,version,request))") &&
            state.execute("CREATE INDEX IF NOT EXISTS cache_expiry ON cache_entry(namespace,expires)") &&
            state.execute("CREATE INDEX IF NOT EXISTS cache_lru ON cache_entry(namespace,accessed)") &&
            state.execute("PRAGMA user_version=1"));
    };
    if (initialize()) {
        return true;
    }
    state.close();
#else
    Q_UNUSED(path)
    m_state->error = QStringLiteral("此构建未启用 SQLite 缓存");
#endif
    return false;
}

std::optional<QByteArray> CacheDatabase::lookup(const CacheKey &key, qint64 nowMs) {
#if RHINE_SQL_CACHE
    auto &state = *m_state;
    QSqlQuery query(state.db);
    query.prepare(QString("SELECT payload,accessed FROM cache_entry WHERE %1 AND expires>?")
                      .arg(QLatin1String(KEY_CONDITION)));
    bindKey(query, key);
    query.addBindValue(nowMs);
    if (!state.execute(query) || !query.next()) {
        return {};
    }
    const auto payload = query.value(0).toByteArray();
    const auto accessed = query.value(1).toLongLong();
    query.finish();
    // 每条记录最多每分钟写一次访问时间，避免连续读取反复写 WAL。
    if (nowMs - accessed >= 60000) {
        query.prepare(
            QString("UPDATE cache_entry SET accessed=? WHERE %1").arg(QLatin1String(KEY_CONDITION)));
        query.addBindValue(nowMs);
        bindKey(query, key);
        state.execute(query);
    }
    return payload;
#else
    Q_UNUSED(key)
    Q_UNUSED(nowMs)
    return {};
#endif
}

bool CacheDatabase::store(const CacheKey &key, const QByteArray &payload, qint64 expiresMs, qint64 nowMs,
                          qint64 quotaBytes) {
#if RHINE_SQL_CACHE
    auto &state = *m_state;
    state.error.clear();
    if (payload.isEmpty() || payload.size() > qMin<qint64>(quotaBytes, 8 * 1024 * 1024) ||
        expiresMs <= nowMs) {
        return false;
    }
    if (!state.db.transaction()) {
        state.error = state.db.lastError().text();
        return false;
    }
    QSqlQuery query(state.db);
    query.prepare("DELETE FROM cache_entry WHERE namespace=? AND expires<=?");
    query.addBindValue(key.nameSpace);
    query.addBindValue(nowMs);
    if (!state.execute(query)) {
        return state.finishTransaction(false);
    }
    query.prepare("INSERT OR REPLACE INTO cache_entry VALUES (?,?,?,?,?,?,?,?,?)");
    bindKey(query, key);
    query.addBindValue(payload);
    query.addBindValue(payload.size());
    query.addBindValue(expiresMs);
    query.addBindValue(nowMs);
    if (!state.execute(query)) {
        return state.finishTransaction(false);
    }
    query.prepare("SELECT COALESCE(SUM(bytes),0) FROM cache_entry WHERE namespace=?");
    query.addBindValue(key.nameSpace);
    if (!state.execute(query) || !query.next()) {
        return state.finishTransaction(false);
    }
    auto bytes = query.value(0).toLongLong();
    query.finish();
    while (bytes > quotaBytes) {
        query.prepare(
            "SELECT rowid,bytes FROM cache_entry WHERE namespace=? ORDER BY accessed,rowid LIMIT 1");
        query.addBindValue(key.nameSpace);
        if (!state.execute(query) || !query.next()) {
            return state.finishTransaction(false);
        }
        const auto row = query.value(0);
        bytes -= query.value(1).toLongLong();
        query.finish();
        query.prepare("DELETE FROM cache_entry WHERE rowid=?");
        query.addBindValue(row);
        if (!state.execute(query)) {
            return state.finishTransaction(false);
        }
    }
    return state.finishTransaction(true);
#else
    Q_UNUSED(key)
    Q_UNUSED(payload)
    Q_UNUSED(expiresMs)
    Q_UNUSED(nowMs)
    Q_UNUSED(quotaBytes)
    return false;
#endif
}

bool CacheDatabase::erase(const CacheKey &key) {
#if RHINE_SQL_CACHE
    QSqlQuery query(m_state->db);
    query.prepare(QString("DELETE FROM cache_entry WHERE %1").arg(QLatin1String(KEY_CONDITION)));
    bindKey(query, key);
    return m_state->execute(query);
#else
    Q_UNUSED(key)
    return false;
#endif
}

std::optional<CacheRemoval> CacheDatabase::clear(const QString &nameSpace) {
#if RHINE_SQL_CACHE
    auto &state = *m_state;
    if (!state.db.transaction()) {
        state.error = state.db.lastError().text();
        return {};
    }
    const auto removed = stats(nameSpace);
    if (!removed) {
        state.finishTransaction(false);
        return {};
    }
    QSqlQuery query(state.db);
    query.prepare("DELETE FROM cache_entry WHERE namespace=?");
    query.addBindValue(nameSpace);
    if (!state.finishTransaction(state.execute(query))) {
        return {};
    }
    state.execute("PRAGMA incremental_vacuum(256)");
    state.execute("PRAGMA wal_checkpoint(TRUNCATE)");
    return removed;
#else
    Q_UNUSED(nameSpace)
    return {};
#endif
}

std::optional<CacheRemoval> CacheDatabase::stats(const QString &nameSpace) {
#if RHINE_SQL_CACHE
    QSqlQuery query(m_state->db);
    query.prepare("SELECT COUNT(*), COALESCE(SUM(bytes),0) FROM cache_entry WHERE namespace=?");
    query.addBindValue(nameSpace);
    if (m_state->execute(query) && query.next()) {
        return CacheRemoval{query.value(0).toLongLong(), query.value(1).toLongLong()};
    }
#else
    Q_UNUSED(nameSpace)
#endif
    return {};
}

QString CacheDatabase::error() const {
    return m_state->error;
}
