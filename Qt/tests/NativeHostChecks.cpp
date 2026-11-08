#include "Host.h"
#include "ProviderRegistry.h"
#include <QCoreApplication>
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
    if (registry.contains("netease")) {
        ok &= registry.name("netease") == "网易云音乐";
        ok &= registry.label("netease") == "NETEASE";
        ok &= registry.columns("netease").size() == 5;
        ok &= registry.maxQueryLength("netease") == 100;
        ok &= registry.qualityOptions("netease").size() >= 5;
        ok &= registry.loginMethods("netease").size() == 2;
    }
    QTemporaryDir emptyRoot;
    ProviderRegistry::instance().load(emptyRoot.path());
    ok &= ProviderRegistry::instance().ids() == QStringList{"siren", "local"};
    ok &= ProviderRegistry::instance().defaultId().isEmpty();
    ok &= ProviderRegistry::instance().fallbackId() == "siren";
    ProviderRegistry::instance().load(root);
#ifdef Q_OS_IOS
    ok &= runIOSBridgeChecks(root);
#endif
    const auto receive = [&](QJsonObject response, QString error) {
        ++replies;
        ok &= error.isEmpty() && response["body"].toObject()["query"] == "native" &&
              response["_epoch"].toInt() == host.epoch;
    };
    host.requestJson("/search", {{"keywords", "native"}}, receive);
    host.requestJson("/search", {{"keywords", "native"}}, receive);
    ok &= waitFor([&] { return replies == 2; }) && requests == 1;
    host.requestJson("/search", {{"keywords", "native"}}, receive);
    ok &= waitFor([&] { return replies == 3; }) && requests == 1;

    const auto originalEpoch = host.epoch;
    bool staleReceived = false;
    host.requestJson("/login/qr/check", {}, [&](QJsonObject response, QString error) {
        staleReceived = error.isEmpty() && response["_epoch"].toInt() == originalEpoch &&
                        response["_epoch"].toInt() != host.epoch;
    });
    host.logout();
    ok &= waitFor([&] { return staleReceived; });

    // 旧扁平 jar 迁移到按来源隔离的 v2 封装，迁移幂等。
    const QJsonObject legacy{
        {"MUSIC_U", "netease-token"},
        {"qqmusic_session", "qq-token"},
        {"__qqSessions", QJsonArray{QJsonObject{{"token", "qq-token"}}}},
        {"__kugou", QJsonObject{{"standard", QJsonObject{{"token", "kugou-token"}, {"userid", "42"}}}}},
        {"legacy-extra", "value"}};
    const auto migrated = Host::migrateCredential(legacy);
    const auto qqCookies = Host::credentialCookies(migrated, "qq");
    const auto neteaseCookies = Host::credentialCookies(migrated, "netease");
    const auto kugouCookies = Host::credentialCookies(migrated, "kugou", "standard");
    ok &= migrated["version"].toInt() == 2;
    ok &= qqCookies["qqmusic_session"].toString() == "qq-token" &&
          qqCookies["__qqSessions"].toArray().size() == 1 && !qqCookies.contains("MUSIC_U");
    ok &= neteaseCookies["MUSIC_U"].toString() == "netease-token" &&
          neteaseCookies["legacy-extra"].toString() == "value" && !neteaseCookies.contains("qqmusic_session");
    ok &= kugouCookies["__kugou"].toObject()["token"].toString() == "kugou-token";
    ok &= Host::migrateCredential(migrated) == migrated;
    // 保存时保留旧扁平投影，降级版本仍能读回账号。
    const auto storage = Host::storageCredential(migrated);
    ok &= storage["version"].toInt() == 2 && storage["MUSIC_U"].toString() == "netease-token" &&
          storage["qqmusic_session"].toString() == "qq-token" &&
          storage["__qqSessions"].toArray().size() == 1 &&
          storage["__kugou"].toObject()["standard"].toObject()["token"].toString() == "kugou-token";

    // Cookie 按 provider 写入不同切片；旧代数的响应不能覆盖新登录。
    Host scoped(root, true);
    scoped.setProvider("qq");
    scoped.acceptCookies(R"(["qqmusic_session=qq-slice; Path=/"])", scoped.epoch, {}, "qq");
    scoped.setProvider("netease");
    scoped.acceptCookies(R"(["MUSIC_U=netease-slice; Path=/"])", scoped.epoch, {}, "netease");
    const auto storedQQ = Host::credentialCookies(scoped.credentials, "qq");
    const auto storedNetease = Host::credentialCookies(scoped.credentials, "netease");
    ok &= storedQQ["qqmusic_session"].toString() == "qq-slice" && !storedQQ.contains("MUSIC_U");
    ok &=
        storedNetease["MUSIC_U"].toString() == "netease-slice" && !storedNetease.contains("qqmusic_session");
    const auto staleEpoch = scoped.epoch;
    scoped.bumpEpoch();
    ok &= scoped.epoch == staleEpoch + 1;
    scoped.acceptCookies(R"(["MUSIC_U=stale; Path=/"])", staleEpoch, {}, "netease");
    ok &= Host::credentialCookies(scoped.credentials, "netease")["MUSIC_U"].toString() == "netease-slice";
    // 跨命名空间写入只落在当前来源，不能改写其他来源的账号。
    scoped.acceptCookies(R"(["qqmusic_session=leak; Path=/"])", scoped.epoch, {}, "netease");
    ok &= Host::credentialCookies(scoped.credentials, "qq")["qqmusic_session"].toString() == "qq-slice";
    scoped.logout();
    ok &= !scoped.hasCredential("netease") && scoped.hasCredential("qq");
    scoped.setProvider("qq");
    scoped.logout();
    ok &= !scoped.hasCredential("qq");

    QImage image(2, 2, QImage::Format_RGBA8888);
    image.fill(Qt::red);
    const QString cover = "https://music.126.net/native-fixture.jpg?param=1024y1024";
    host.fixtureImage(cover, image);
    bool coverReady = false;
    host.loadCover("https://music.126.net/native-fixture.jpg?param=128y128",
                   [&](QString key) { coverReady = key == cover && host.image(key) == image; });
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
