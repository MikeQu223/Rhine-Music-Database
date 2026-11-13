#include "AppStorage.h"
#include "MusicLibrary.h"
#include "storage/RenderCacheStorage.h"
#include <QElapsedTimer>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QTemporaryDir>
#include <QThread>

namespace {
bool check(bool value, const char *message) {
    if (!value) {
        qCritical() << message;
    }
    return value;
}

bool writeFixture(const QString &path) {
    QFile file(path);
    return QDir().mkpath(QFileInfo(path).path()) && file.open(QIODevice::WriteOnly) &&
           file.write("fixture") == 7;
}

bool databaseChecks(const QString &root) {
#if RHINE_SQL_CACHE
    CacheDatabase database;
    if (!check(database.open(root + "/database-probe.sqlite"), "open SQLite cache")) {
        qCritical() << database.error();
        return false;
    }
    const CacheKey first{"lyrics", "alpha", "guest", "1", "same"};
    const CacheKey second{"lyrics", "beta", "guest", "1", "same"};
    const CacheKey account{"lyrics", "alpha", "account", "1", "same"};
    const CacheKey version{"lyrics", "alpha", "guest", "2", "same"};
    const CacheKey expired{"lyrics", "alpha", "guest", "1", "expires"};
    bool ok = check(database.store(first, "one", 1000000, 1000, 9) &&
                        database.store(second, "two", 1000000, 2000, 9) &&
                        database.store(expired, "old", 3000, 2500, 9),
                    "write independent records");
    ok &= check(database.lookup(first, 80000) == QByteArray("one") &&
                    database.lookup(second, 80000) == QByteArray("two") && !database.lookup(account, 80000) &&
                    !database.lookup(version, 80000) && !database.lookup(expired, 80000),
                "provider, scope, version and expiry");
    ok &= check(database.store(version, "new", 1000000, 81000, 6) && !database.lookup(first, 81000) &&
                    database.lookup(second, 81000) && database.lookup(version, 81000),
                "expired records precede LRU eviction");
    ok &= check(!database.store(account, "oversized", 1000000, 81000, 6) && database.erase(second) &&
                    !database.lookup(second, 81000),
                "quota boundary and independent delete");
    const auto removed = database.clear("lyrics");
    ok &= check(removed && removed->entries == 1 && removed->logicalBytes == 3, "logical deletion count");
    const auto corrupt = root + "/broken.sqlite";
    CacheDatabase failed;
    ok &= check(writeFixture(corrupt) && !failed.open(corrupt) && QFileInfo(corrupt).size() == 7,
                "invalid database degrades without removing original file");
    return ok;
#else
    Q_UNUSED(root)
    return true;
#endif
}

bool renderCacheChecks(const QString &root) {
    const auto fixture = root + "/qml/test.bin";
    bool ok = check(writeFixture(fixture), "render cache fixture");
    {
        RenderCacheStorage current;
        const auto scheduled = current.scheduleClear();
        ok &= check(!scheduled.isEmpty() && scheduled.at(0).toObject()["status"] == "deferred" &&
                        QFileInfo::exists(fixture),
                    "running renderer keeps cache and persists cleanup request");
        RenderCacheStorage another;
        ok &= check(QFileInfo::exists(fixture), "second renderer cannot delete active cache");
    }
    RenderCacheStorage restarted;
    ok &= check(!QFileInfo::exists(fixture) && !QFileInfo::exists(root + "/clear-render-cache"),
                "renderer clears marked cache before engine creation");
    return ok;
}

bool generationChecks(const QString &root) {
#if RHINE_SQL_CACHE
    CacheManager manager(root + "/generation.sqlite");
    manager.registerNamespace("lyrics", 4096);
    const CacheKey key{"lyrics", "test", "guest", "1", "record"};
    const auto oldGeneration = manager.generation("lyrics");
    manager.store(key, oldGeneration, {{"text", "old"}}, 60000);
    bool completed = false;
    bool ok = true;
    manager.clear("lyrics", [&](QJsonObject result) {
        ok &= check(result["status"] == "cleared", "clear barrier commits");
        manager.store(key, oldGeneration, {{"text", "late"}}, 60000);
        manager.lookup(key, manager.generation("lyrics"), [&](std::optional<QJsonObject> hit) {
            ok &= check(!hit, "old producer cannot restore cleared data");
            completed = true;
        });
    });
    QElapsedTimer timer;
    timer.start();
    while (!completed && timer.elapsed() < 5000) {
        QCoreApplication::processEvents();
        QThread::msleep(1);
    }
    return ok && check(completed, "generation regression completed");
#else
    Q_UNUSED(root)
    return true;
#endif
}

bool migrationChecks(const QString &resources) {
#if RHINE_SQL_CACHE
    const QString track = "local:1:fingerprint";
    const QJsonObject document{{"trackKey", track},      {"source", "local"}, {"version", 1},
                               {"plainText", "fixture"}, {"timing", "none"},  {"offsetMs", 0},
                               {"lines", QJsonArray{}}};
    const QJsonObject retained{{"key", "alpha:1"}, {"document", document}};
    auto settings = AppStorage::settings();
    settings.setValue(
        "panel/lyrics-cache",
        QString::fromUtf8(
            QJsonDocument(QJsonArray{QJsonObject{{"key", track}, {"document", document}}, retained})
                .toJson(QJsonDocument::Compact)));
    settings.sync();
    Host owner(resources, true, nullptr, false, nullptr,
               AppStorage::cacheDirectory() + "/migration.sqlite");
    owner.offline = false;
    LyricsController lyrics(&owner);
    const CacheKey key{"lyrics", "local", "legacy-local", "1",
                       QCryptographicHash::hash(track.toUtf8(), QCryptographicHash::Sha256)};
    bool verified = false;
    bool complete = false;
    auto manager = owner.cacheManager();
    manager->lookup(key, manager->generation("lyrics"), [&](std::optional<QJsonObject> value) {
        verified = value && value->value("plainText") == "fixture";
        complete = true;
    });
    QElapsedTimer timer;
    timer.start();
    while (!complete && timer.elapsed() < 5000) {
        QCoreApplication::processEvents();
        QThread::msleep(1);
    }
    const auto remaining = QJsonDocument::fromJson(owner.preference("lyrics-cache").toUtf8()).array();
    return check(verified && remaining == QJsonArray{retained},
                 "migration verifies committed local record before removing just that entry");
#else
    Q_UNUSED(resources)
    return true;
#endif
}
}

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    QTemporaryDir root;
    if (!root.isValid() || !AppStorage::initializePortable(root.path()).isEmpty()) {
        return 1;
    }
    Host host(app.arguments().value(1), true);
    MusicLibrary library(&host, {});
    host.offline = false;
    const auto accountKey = "account-id-" + library.provider;
    const QString search = QStringLiteral("[\"旧检索\"]");
    const QString play = QStringLiteral("[{\"id\":\"1\"}]");
    const QString covers = QStringLiteral("{\"1:1\":\"cover\"}");
    library.searchHistory = {QStringLiteral("旧检索")};
    library.player.history = {QJsonObject{{"id", "1"}}};
    host.setPreference("search-history", search);
    host.setPreference("play-history", play);
    host.setPreference("local-cover-cache", covers);
    host.setPreference("lyrics-cache", QStringLiteral("[{\"key\":\"alpha:1\"}]"));
    host.setPreference("theme", QStringLiteral("dark"));
    host.setPreference(accountKey, QStringLiteral("42"));
    // 清除缓存只删除可重建数据，登录状态、本地音乐库与历史保持原样。
    const auto cache = AppStorage::cacheDirectory();
    const auto metadata = cache + "/metadata/" + QString(64, 'a') + ".json";
    const auto data = AppStorage::dataDirectory();
    const QStringList preserved{cache + "/metadata/unknown.json",
                                cache + "/qml/entry.bin",
                                cache + "/shaders/pipeline.cache",
                                data + "/local-library/index.json",
                                data + "/local-library/covers/cover",
                                data + "/collections/fixture.json",
                                data + "/session.json",
                                data + "/playback-session.json",
                                data + "/plugins/fixture/manifest.json",
                                data + "/plugin-data/fixture/private",
                                data + "/account.dpapi",
                                data + "/account.credential"};
    bool ok = databaseChecks(root.path());
    ok &= generationChecks(root.path());

    ok &= check(writeFixture(metadata), "metadata fixture");
    for (const auto &path : preserved) {
        ok &= check(writeFixture(path), "preserved fixture");
    }
    library.player.current = QJsonObject{{"id", "playing"}};
    library.player.state["position"] = 12;
    const auto playback = library.player.sessionState();
    bool completed = false;
    QJsonArray results;
    library.clearCaches([&](QJsonArray items) {
        completed = true;
        results = items;
    });
    QElapsedTimer timer;
    timer.start();
    while (!completed && timer.elapsed() < 5000) {
        app.processEvents();
        QThread::msleep(1);
    }
    ok &= check(completed && !QFile::exists(metadata), "cache clear completes");
    bool counted = false;
    for (const auto &item : results) {
        const auto result = item.toObject();
        if (result["category"] == "legacy-metadata") {
            counted = result["status"] == "cleared" && result["removedFileBytes"].toInteger() == 7;
        }
    }
    ok &= check(counted, "metadata result reports removed bytes");
    for (const auto &path : preserved) {
        QFile file(path);
        ok &= check(file.open(QIODevice::ReadOnly) && file.readAll() == "fixture", "user data preserved");
    }
    ok &= check(host.preference("lyrics-cache") == "[]" && host.preference("theme") == "dark" &&
                    host.preference(accountKey) == "42" && host.preference("play-history") == play &&
                    host.preference("search-history") == search &&
                    host.preference("local-cover-cache") == covers &&
                    library.player.sessionState() == playback && !library.searchHistory.isEmpty(),
                "cache clear preserves preferences, history and playback");
    QJsonArray historyResult;
    library.clearHistory([&](QJsonArray items) { historyResult = items; });
    ok &= check(historyResult.size() == 2 && host.preference("search-history") == "[]" &&
                    host.preference("play-history") == "[]" && library.searchHistory.isEmpty() &&
                    library.player.history.isEmpty() && library.player.sessionState() == playback,
                "independent history clear preserves playback");
    ok &= renderCacheChecks(cache);
    ok &= migrationChecks(app.arguments().value(1));
    return ok ? 0 : 1;
}
