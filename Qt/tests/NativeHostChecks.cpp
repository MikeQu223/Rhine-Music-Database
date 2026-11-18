#include "Host.h"
#include "AppStorage.h"
#include "ProviderRegistry.h"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QUrl>
#include <QElapsedTimer>
#include <QJsonArray>
#include <QThread>

#ifdef Q_OS_IOS
bool runIOSBridgeChecks(const QString &root);
#endif

namespace {
bool waitFor(const std::function<bool()> &ready) {
    QElapsedTimer elapsed;
    elapsed.start();
    while (!ready() && elapsed.elapsed() < 2000) {
        QCoreApplication::processEvents();
        QThread::msleep(1);
    }
    return ready();
}
}

/** 不创建脚本引擎，验证原生业务可直接使用缓存、账号代数、封面和官方播放边界。 */
bool runNativeHostChecks(const QString &root) {
    Host host(root, true);
    int requests = 0;
    host.fixture = [&](QString, QJsonObject parameters) {
        ++requests;
        return QJsonObject{{"body", QJsonObject{{"code", 200}, {"query", parameters["keywords"]}}}};
    };
    int replies = 0;
    bool ok = true;
    // descriptor 在桥启动前加载；core-only 时仍保留 siren/local。
    const auto &registry = ProviderRegistry::instance();
    ok &= registry.contains("siren") && registry.contains("local");
    ok &= registry.sessionLabel("siren") == "MONSTER SIREN";
    ok &= registry.columns("siren").size() == 5;
    ok &= registry.qualityOptions("siren").size() == 1;
    for (const auto &id : registry.ids()) {
        if (id == "local" || id == "siren") {
            continue;
        }
        ok &= !registry.name(id).isEmpty();
        ok &= !registry.columns(id).isEmpty();
        ok &= registry.maxQueryLength(id) > 0;
    }
    QTemporaryDir emptyRoot;
    ProviderRegistry::instance().load(emptyRoot.path());
    ok &= ProviderRegistry::instance().ids() == QStringList{"siren", "local"};
    ok &= ProviderRegistry::instance().defaultId().isEmpty();
    ok &= ProviderRegistry::instance().fallbackId() == "siren";
    ProviderRegistry::instance().load(root);

    // 插件市场：本地 file:// 索引、下载、安装与启用/禁用。
    QTemporaryDir market;
    ok &= market.isValid();
    QDir().mkpath(market.path() + "/plugins/fixture");
    const QJsonObject fixtureManifest{
        {"schemaVersion", 2},
        {"apiVersion", "2.0"},
        {"id", "fixture"},
        {"version", "1.0.0"},
        {"entry", QJsonObject{{"file", "plugin.cjs"}}},
        {"display", QJsonObject{{"name", "Fixture"}}},
        {"capabilities", QJsonObject{{"search", true}}},
    };
    {
        QFile file(market.path() + "/plugins/fixture/manifest.json");
        ok &= file.open(QIODevice::WriteOnly | QIODevice::Truncate);
        ok &= file.write(QJsonDocument(fixtureManifest).toJson()) > 0;
    }
    {
        QFile file(market.path() + "/plugins/fixture/plugin.cjs");
        ok &= file.open(QIODevice::WriteOnly | QIODevice::Truncate);
        ok &= file.write("module.exports = { create() { return {}; } };\n") > 0;
    }
    {
        const QJsonObject index{
            {"schemaVersion", 1},
            {"plugins", QJsonArray{QJsonObject{
                            {"id", "fixture"},
                            {"name", "Fixture"},
                            {"version", "1.0.0"},
                            {"path", "plugins/fixture"},
                            {"entry", QJsonObject{{"file", "plugin.cjs"}}},
                            {"files", QJsonArray{"plugin.cjs"}},
                        }}},
        };
        QFile file(market.path() + "/index.json");
        ok &= file.open(QIODevice::WriteOnly | QIODevice::Truncate);
        ok &= file.write(QJsonDocument(index).toJson()) > 0;
    }
    qputenv("RHINE_PLUGIN_MARKETPLACE_URL",
            QUrl::fromLocalFile(market.path() + "/index.json").toString().toUtf8());
    Host marketplaceHost(root, true);
    int pluginReloads = 0;
    QObject::connect(&marketplaceHost, &Host::pluginsReloaded, [&] { ++pluginReloads; });
    marketplaceHost.refreshPluginMarketplace();
    ok &= waitFor([&] {
        const auto state = marketplaceHost.pluginMarketplaceState();
        return !state["loading"].toBool() && state["plugins"].toArray().size() == 1;
    });
    ok &= marketplaceHost.installMarketplacePlugin("fixture").isEmpty();
    ok &= waitFor(
        [&] { return marketplaceHost.pluginMarketplaceState()["status"].toString().startsWith("已安装"); });
    ok &= QFile::exists(AppStorage::dataDirectory() + "/plugins/fixture/plugin.cjs");
    if (pluginReloads != 1) {
        qCritical() << "Marketplace install reload count" << pluginReloads;
        ok = false;
    }
    ok &= marketplaceHost.pluginEnabled("fixture");
    marketplaceHost.setPluginEnabled("fixture", false);
    ok &= !marketplaceHost.pluginEnabled("fixture");
    ok &= !ProviderRegistry::instance().contains("fixture");
    marketplaceHost.setPluginEnabled("fixture", true);
    ok &= ProviderRegistry::instance().contains("fixture");
    {
        auto updatedManifest = fixtureManifest;
        updatedManifest["version"] = "2.0.0";
        QFile file(market.path() + "/plugins/fixture/manifest.json");
        ok &= file.open(QIODevice::WriteOnly | QIODevice::Truncate);
        ok &= file.write(QJsonDocument(updatedManifest).toJson()) > 0;
    }
    {
        const QJsonObject index{
            {"schemaVersion", 1},
            {"plugins", QJsonArray{QJsonObject{
                            {"id", "fixture"},
                            {"name", "Fixture"},
                            {"version", "2.0.0"},
                            {"path", "plugins/fixture"},
                            {"entry", QJsonObject{{"file", "plugin.cjs"}}},
                            {"files", QJsonArray{"plugin.cjs"}},
                        }}},
        };
        QFile file(market.path() + "/index.json");
        ok &= file.open(QIODevice::WriteOnly | QIODevice::Truncate);
        ok &= file.write(QJsonDocument(index).toJson()) > 0;
    }
    marketplaceHost.checkPluginUpdates();
    ok &= waitFor([&] { return !marketplaceHost.pluginMarketplaceState()["loading"].toBool(); });
    const auto beforeUpdate = marketplaceHost.pluginMarketplaceState();
    bool managerDetectedUpdate = false;
    for (const auto &entry : marketplaceHost.pluginManagerState()) {
        if (entry.toObject()["id"].toString() == "fixture") {
            managerDetectedUpdate = entry.toObject()["updateAvailable"].toBool();
            break;
        }
    }
    if (beforeUpdate["updatesAvailable"].toInt() != 1 || !managerDetectedUpdate) {
        qCritical() << "Plugin update was not detected" << beforeUpdate["status"].toString()
                    << beforeUpdate["updatesAvailable"].toInt();
        ok = false;
    }
    ok &= marketplaceHost.installMarketplacePlugin("fixture").isEmpty();
    ok &= waitFor([&] {
        return marketplaceHost.pluginMarketplaceState()["status"].toString().startsWith("已安装") &&
               ProviderRegistry::instance().manifest("fixture")["version"].toString() == "2.0.0";
    });
    if (pluginReloads != 4) {
        qCritical() << "Marketplace update reload count" << pluginReloads;
        ok = false;
    }
    qInfo() << "market re-enabled" << ok << ProviderRegistry::instance().contains("fixture");
    qunsetenv("RHINE_PLUGIN_MARKETPLACE_URL");
    QDir(AppStorage::dataDirectory() + "/plugins/.backup-fixture").removeRecursively();
    QDir(AppStorage::dataDirectory() + "/plugins/fixture").removeRecursively();
    marketplaceHost.reloadPlugins();
#ifdef Q_OS_IOS
    ok &= runIOSBridgeChecks(root);
#endif
    const auto receive = [&](QJsonObject response, QString error) {
        ++replies;
        ok &= error.isEmpty() && response["body"].toObject()["query"] == "native" &&
              response["_epoch"].toInt() == host.epoch;
    };
    host.requestJson("/native/siren/search", {{"keywords", "native"}}, receive);
    host.requestJson("/native/siren/search", {{"keywords", "native"}}, receive);
    ok &= waitFor([&] { return replies == 2; }) && requests == 1;
    host.requestJson("/native/siren/search", {{"keywords", "native"}}, receive);
    ok &= waitFor([&] { return replies == 3; }) && requests == 1;

    const auto originalEpoch = host.epoch;
    bool staleReceived = false;
    host.requestJson("/login/qr/check", {}, [&](QJsonObject response, QString error) {
        staleReceived = error.isEmpty() && response["_epoch"].toInt() == originalEpoch &&
                        response["_epoch"].toInt() != host.epoch;
    });
    host.logout();
    ok &= waitFor([&] { return staleReceived; });

    // v2 凭据原样保存；旧扁平 jar 的迁移映射由插件 manifest 声明。
    const QJsonObject credentials{{"version", 2},
                                  {"providers", QJsonObject{{"alpha", QJsonObject{{"cookies", QJsonObject{{"a", "1"}}}}}}}};
    ok &= Host::storageCredential(credentials) == credentials;
    const auto migrated = Host::migrateCredential(credentials);
    ok &= migrated["version"].toInt() == 2 && migrated["providers"].isObject();
    const bool idempotent = Host::migrateCredential(migrated) == migrated;
    ok &= idempotent;

    // Cookie 按 provider 写入不同切片；旧代数的响应不能覆盖新登录。
    const auto available = ProviderRegistry::instance().ids();
    if (available.size() >= 2) {
        const auto first = available.at(0);
        const auto second = available.at(1);
        Host scoped(root, true);
        scoped.setProvider(first);
        scoped.acceptCookies(R"(["alpha=one; Path=/"])", scoped.epoch, {}, first);
        scoped.setProvider(second);
        scoped.acceptCookies(R"(["beta=two; Path=/"])", scoped.epoch, {}, second);
        const auto firstCookies = Host::credentialCookies(scoped.credentials, first);
        const auto secondCookies = Host::credentialCookies(scoped.credentials, second);
        ok &= firstCookies["alpha"].toString() == "one" && !firstCookies.contains("beta");
        ok &= secondCookies["beta"].toString() == "two" && !secondCookies.contains("alpha");
        const auto staleEpoch = scoped.epoch;
        scoped.bumpEpoch();
        ok &= scoped.epoch == staleEpoch + 1;
        scoped.acceptCookies(R"(["beta=stale; Path=/"])", staleEpoch, {}, second);
        ok &= Host::credentialCookies(scoped.credentials, second)["beta"].toString() == "two";
        // 跨命名空间写入只落在当前来源，不能改写其他来源的账号。
        scoped.acceptCookies(R"(["alpha=leak; Path=/"])", scoped.epoch, {}, second);
        ok &= Host::credentialCookies(scoped.credentials, first)["alpha"].toString() == "one";
        scoped.logout();
        ok &= Host::credentialCookies(scoped.credentials, first)["alpha"].toString() == "one";
        scoped.setProvider(first);
        scoped.logout();
        ok &= Host::credentialCookies(scoped.credentials, first).isEmpty();
    }
    qInfo() << "host check scoped" << ok;

    QImage image(2, 2, QImage::Format_RGBA8888);
    image.fill(Qt::red);
    const QString cover = "https://hycdn.cn/native-fixture.jpg";
    host.fixtureImage(cover, image);
    bool coverReady = false;
    host.loadCover(cover, [&](QString key) { coverReady = key == cover && host.image(key) == image; });
    ok &= coverReady;
    QImage largeCover(1024, 1024, QImage::Format_RGBA8888);
    largeCover.fill(Qt::blue);
    host.fixtureImage("current-cover", largeCover);
    host.fixtureImage("playing-cover", largeCover);
    host.trimMemory({"current-cover", "playing-cover"});
    ok &= host.image("current-cover") == largeCover && host.image("playing-cover") == largeCover;
    bool invalidId = false;
    bool official = false;
#ifdef Q_OS_IOS
    host.playOfficial("invalid", [&](QString error) { invalidId = error == "当前平台仅支持面板内播放"; });
    host.playOfficial("42", [&](QString value) { official = value == "当前平台仅支持面板内播放"; });
    host.mediaControl("volume", 0.2);
    ok &= host.mediaState()["volume"].toDouble() == 1.0;
#else
    host.playOfficial("invalid", [&](QString error) { invalidId = error == "请先选择一首歌曲"; });
    host.playOfficial("42", [&](QString value) { official = value == "OFFLINE_PLAY:42"; });
#endif
    ok &= invalidId && official;
    bool delayed = false;
    host.schedule(0, [&] { delayed = true; });
    ok &= !delayed && waitFor([&] { return delayed; });
    bool afterShutdown = false;
    host.schedule(0, [&] { afterShutdown = true; });
    host.shutdown();
    QCoreApplication::processEvents();
    ok &= !afterShutdown;
    qInfo() << "Native Host callbacks, request merging, cache, epoch, images and shutdown:"
            << (ok ? "passed" : "FAILED");
    return ok;
}
