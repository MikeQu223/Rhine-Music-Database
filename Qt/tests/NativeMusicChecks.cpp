#include "MusicLibrary.h"
#include "MusicData.h"
#include "MusicDiscover.h"
#include "ProviderRegistry.h"
#include <QCoreApplication>
#include <QDataStream>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonDocument>
#include <QThread>
#include <QTemporaryDir>
#include <QUrl>
#include <QDebug>

/**
 * 音乐库核心功能测试
 *
 * 验证关键音乐功能：播放、切换、状态管理、登录/登出。
 * 移除了冗余的边缘案例和复杂的异步状态测试。
 */

namespace {
bool waitFor(const std::function<bool()> &ready, int timeout = 3000) {
    QElapsedTimer elapsed;
    elapsed.start();
    while (!ready() && elapsed.elapsed() < timeout) {
        QCoreApplication::processEvents();
        QThread::msleep(1);
    }
    return ready();
}

QJsonObject song(QString id, QString title = "测试歌曲") {
    auto value = MusicData::item("song", id, title, "测试歌手");
    value["albumID"] = "7";
    value["album"] = "测试专辑";
    value["duration"] = 180000;
    value["cover"] = "https://music.126.net/fixture.jpg";
    return value;
}

QJsonObject lyrics() {
    return {{"version", 1},
            {"timing", "line"},
            {"offsetMs", 0},
            {"plainText", "第一句\n第二句"},
            {"lines", QJsonArray{QJsonObject{{"startMs", 1000}, {"text", "第一句"}},
                                 QJsonObject{{"startMs", 3000}, {"text", "第二句"}}}}};
}

// 创建测试用的静音音频文件
QString createTestAudio(QTemporaryDir &dir) {
    QFile audio(dir.filePath("test-silent.wav"));
    if (!audio.open(QIODevice::WriteOnly)) {
        return QString();
    }
    QDataStream wav(&audio);
    wav.setByteOrder(QDataStream::LittleEndian);
    constexpr quint32 bytes = 8000 * 2 * 4;
    wav.writeRawData("RIFF", 4);
    wav << quint32(36 + bytes);
    wav.writeRawData("WAVEfmt ", 8);
    wav << quint32(16) << quint16(1) << quint16(1) << quint32(8000) << quint32(16000) << quint16(2)
        << quint16(16);
    wav.writeRawData("data", 4);
    wav << bytes;
    wav.writeRawData(QByteArray(bytes, '\0').constData(), bytes);
    audio.close();
    return QUrl::fromLocalFile(audio.fileName()).toString();
}

/** 固定响应覆盖首次读取、切歌、写入失败、重复点击及退出账号的过期回包。 */
bool checkPlaybackLikes(const QString &root) {
    Host host(root, true);
    MusicLibrary music(&host, {});
    music.provider = "netease";
    music.api.provider = "netease";
    music.uid = "42";
    int reads = 0;
    int writes = 0;
    bool fail = false;
    host.fixture = [&](QString route, QJsonObject) {
        if (route.endsWith("/likedIDs")) {
            ++reads;
            return QJsonObject{{"body", QJsonObject{{"code", 200}, {"value", QJsonArray{"1"}}}}};
        }
        if (route.endsWith("/mutate")) {
            ++writes;
            return QJsonObject{{"body", QJsonObject{{"code", fail ? 500 : 200}}}};
        }
        return QJsonObject{{"body", QJsonObject{{"code", 200}}}};
    };
    music.player.current = song("1");
    music.player.changed();
    music.player.current = song("2");
    music.player.changed();
    if (!waitFor([&] { return music.songLiked(song("2")).has_value(); }) || reads != 1 ||
        !music.songLiked(song("1")).value_or(false) || music.songLiked(song("2")).value_or(true)) {
        qCritical() << "Playback likes failed initial lookup or track switch";
        return false;
    }
    music.like(music.player.current);
    music.like(music.player.current);
    music.player.current = song("1");
    music.player.changed();
    if (!waitFor([&] { return !music.writeLoading; }) || writes != 1 ||
        !music.songLiked(song("2")).value_or(false)) {
        qCritical() << "Playback like write changed the wrong track or accepted duplicate click";
        return false;
    }
    fail = true;
    music.like(song("2"));
    if (!waitFor([&] { return !music.writeLoading; }) || !music.songLiked(song("2")).value_or(false)) {
        qCritical() << "Failed unlike changed the confirmed heart";
        return false;
    }
    fail = false;
    music.like(song("1"));
    music.logout();
    if (!waitFor([&] { return writes == 3; }) || !music.lists[1].isEmpty() ||
        music.songLiked(song("1")).has_value()) {
        qCritical() << "Old account like response contaminated logged-out state";
        return false;
    }
    return true;
}

/** QQ 单曲状态必须按当前播放曲目隔离，写入结果优先于写入前的状态读取。 */
bool checkQQPlaybackLikes(const QString &root) {
    Host host(root, true);
    MusicLibrary music(&host, {});
    music.provider = "qq";
    music.api.provider = "qq";
    music.uid = "42";
    const auto first = MusicData::item("song", "1", "歌曲一", "歌手", "qq");
    const auto second = MusicData::item("song", "2", "歌曲二", "歌手", "qq");
    host.fixture = [&](QString route, QJsonObject parameters) {
        QJsonValue value;
        if (route.endsWith("/likedState")) {
            const auto id = parameters["args"].toArray().at(0).toArray().at(0).toString();
            value = QJsonObject{{id, id == "1" ? "subscribed" : "not-subscribed"}};
        } else if (route.endsWith("/subscriptionStatus")) {
            value = parameters["args"].toArray().at(1) == "1" ? "subscribed" : "not-subscribed";
        } else if (route.endsWith("/mutate")) {
            value = QJsonObject{{"liked", true}};
        }
        return QJsonObject{{"body", QJsonObject{{"code", 200}, {"value", value}}}};
    };
    music.player.current = first;
    music.player.changed();
    music.player.current = second;
    music.player.changed();
    if (!waitFor([&] { return music.songLiked(second).has_value(); }) ||
        music.songLiked(second).value_or(true)) {
        qCritical() << "QQ old track response replaced current heart";
        return false;
    }
    music.subscriptionStates.clear();
    music.player.current = first;
    music.player.changed();
    music.player.current = second;
    music.player.changed();
    music.like(second);
    if (!waitFor([&] { return !music.writeLoading; }) || !music.songLiked(second).value_or(false)) {
        qCritical() << "QQ stale status read replaced successful like";
        return false;
    }
    return true;
}

}

bool runNativeSessionChecks(const QString &root, const QString &audioURL);

bool runNativeMusicChecks(const QString &root) {
    if (!ProviderRegistry::instance().contains("netease")) {
        qInfo() << "Native online music checks skipped: third-party provider not installed";
        return true;
    }
    QFile file(root + "/slots.json");
    if (!file.open(QIODevice::ReadOnly)) {
        return false;
    }

    Host host(root, true);
    MusicLibrary library(&host, QJsonDocument::fromJson(file.readAll()).object());
    QTemporaryDir audioFixture;
    const auto audioURL = createTestAudio(audioFixture);
    if (audioURL.isEmpty()) {
        return false;
    }
    host.mediaControl("volume", 0);
    int smsRequests = 0;
    int captchaLogins = 0;
    bool loginParametersValid = true;
    // 只保留核心业务所需的最小离线响应，不模拟未覆盖的边缘路由。
    host.fixture = [&](QString route, QJsonObject parameters) {
        const auto args = parameters.value("args").toArray();
        QJsonValue value;
        if (route.endsWith("/search")) {
            value = QJsonObject{{"items", QJsonArray{song("1", args.at(0).toString())}},
                                {"total", 1},
                                {"rawCount", 1},
                                {"more", false}};
        } else if (route.endsWith("/lyrics")) {
            value = lyrics();
        } else if (route.endsWith("/songs")) {
            QJsonArray songs;
            for (const auto &id : args.at(0).toArray()) {
                if (id != "missing") {
                    songs.append(song(id.toString()));
                }
            }
            value = songs;
        } else if (route.endsWith("/playback") || route.endsWith("/preview")) {
            value =
                QJsonObject{{"url", audioURL}, {"level", "exhigh"}, {"preview", route.endsWith("/preview")}};
        } else if (route.endsWith("/account")) {
            value = QJsonObject{{"uid", "42"}, {"nickname", "本地账号"}};
        } else if (route.endsWith("/likedState")) {
            QJsonObject states;
            for (const auto &id : args.at(0).toArray()) {
                states[id.toString()] = "subscribed";
            }
            value = states;
        } else if (route.endsWith("/likedIDs")) {
            value = QJsonArray{"1", "missing", "2"};
        } else if (route.endsWith("/userPlaylists")) {
            auto owned = MusicData::item("playlist", "8", "本人歌单");
            owned["creatorID"] = "42";
            value = QJsonObject{{"items", QJsonArray{owned}}, {"rawCount", 1}, {"more", false}};
        } else if (route.endsWith("/loginSms")) {
            ++smsRequests;
            loginParametersValid &= args == QJsonArray{"13800000000"};
            return QJsonObject{{"body", QJsonObject{{"code", 200}, {"data", true}}}};
        } else if (route.endsWith("/loginSubmit")) {
            ++captchaLogins;
            loginParametersValid &= args == QJsonArray{"13800000000", "123456"};
            return QJsonObject{{"body", QJsonObject{{"code", 200}}},
                               {"cookies", QJsonArray{"MUSIC_U=fixture-native"}}};
        } else if (route.endsWith("/discover")) {
            value = QJsonObject{
                {"items", QJsonArray{MusicData::item("playlist", "8", "原生推荐")}},
                {"rawCount", 1},
                {"more", false},
            };
        } else if (route.endsWith("/suggest")) {
            value = QJsonArray{"原生建议"};
        } else if (route == "/personalized") {
            return QJsonObject{
                {"body", QJsonObject{{"code", 200},
                                     {"result", QJsonArray{QJsonObject{{"id", 8}, {"name", "原生推荐"}}}}}}};
        } else if (route == "/like" || route.endsWith("/mutate")) {
            value = QJsonObject{{"liked", true}, {"subscribed", true}};
        }
        return QJsonObject{{"body", QJsonObject{{"code", 200}, {"value", value}}}};
    };

    bool ok = true;
    int testCount = 0;
    const auto check = [&](bool value, const char *name) {
        testCount++;
        if (!value) {
            qCritical() << "Native music test failed:" << name;
            ok = false;
        }
    };

    // === 测试 1: 基础选择 ===
    check(MusicPlayer::sourceQuality("netease", QJsonObject{{"url", "https://x/a.mp3"}, {"tier", "hires"}}) ==
              "hires",
          "plugin tier wins over legacy fields");
    check(MusicPlayer::sourceQuality("qq", QJsonObject{{"url", "https://x/a.flac"}, {"level", "lossless"}}) ==
              "sq",
          "legacy level fallback still resolves");
    library.choose({});
    check(library.current.isEmpty() && !library.detailLoading, "empty selection does not load metadata");

    auto testSong = song("1");
    library.choose(testSong);
    check(library.current["id"] == "1", "song selection");

    // === 测试 2: 播放控制 ===
    library.player.play(testSong);
    check(waitFor([&] { return !library.player.loading; }), "playback starts");
    check(!library.player.current.isEmpty(), "player has current song");

    library.player.stop();
    check(library.player.current.isEmpty(), "stop clears current song");

    // === 测试 3: 播放队列 ===
    QJsonArray queue;
    for (int i = 1; i <= 5; ++i) {
        queue.append(song(QString::number(i)));
    }
    library.player.queue.replace(queue);
    check(library.player.queue.size() == 5, "queue initialization");

    library.player.play(queue.first().toObject());
    check(waitFor([&] { return !library.player.loading; }), "queue playback starts");

    library.player.next(1);
    check(waitFor([&] { return !library.player.loading; }), "next track loads");
    check(library.player.current["id"] == "2", "next track");

    library.player.next(-1);
    check(waitFor([&] { return !library.player.loading; }), "previous track loads");
    check(library.player.current["id"] == "1", "previous track");

    library.player.stop();

    // === 测试 4: 搜索功能 ===
    library.search("测试");
    check(waitFor([&] { return !library.searchLoading; }), "search completes");
    check(library.totals[0] == 1, "search results counted");
    check(!library.lists[0].isEmpty(), "search returns tracks");

    // 删除全部关键词后必须清空旧结果，不能继续显示上一次搜索内容。
    library.search(QString());
    check(library.lists[0].isEmpty(), "clearing query clears search results");
    check(library.totals[0] == 0, "clearing query resets result count");

    // === 测试 5: 歌词加载 ===
    library.player.play(song("2"));
    check(waitFor([&] { return !library.player.loading; }), "song with lyrics loads");
    check(waitFor([&] { return library.player.lyrics.status == "ready"; }), "lyrics finish");
    library.player.stop();

    // === 测试 6: 账号登录/登出 ===
    library.sendLoginCode("invalid-phone");
    check(smsRequests == 0, "invalid phone does not send SMS");
    library.sendLoginCode("13800000000");
    check(waitFor([&] { return !library.accountLoading; }), "SMS send completes");
    check(smsRequests == 1 && library.smsRetrySeconds() > 0, "SMS send starts resend cooldown");
    library.sendLoginCode("13800000000");
    check(smsRequests == 1, "SMS cooldown prevents duplicate sends");
    library.captchaLogin("13800000000", "invalid-code");
    check(captchaLogins == 0, "invalid captcha does not attempt login");
    library.captchaLogin("13800000000", "123456");
    const auto cancelEpoch = host.epoch;
    library.cancelLogin();
    check(host.epoch > cancelEpoch, "login reset bumps credential epoch");
    library.loginStatus = "cancelled-login";
    check(waitFor([&] { return captchaLogins == 1; }), "cancelled captcha request returns");
    check(library.uid.isEmpty() && library.loginStatus == "cancelled-login" && !host.authenticated(),
          "cancelled captcha response cannot log in or accept cookies");
    const auto loginEpoch = host.epoch;
    library.captchaLogin("13800000000", "123456");
    check(waitFor([&] { return !library.accountLoading; }), "login completes");
    check(host.epoch > loginEpoch, "login success bumps credential epoch");
    check(captchaLogins == 2 && loginParametersValid, "SMS login uses upstream parameters without password");
    check(library.uid == "42", "login sets uid");

    // === 测试 7: 喜欢功能 ===
    library.like(song("3"));
    // 首次喜欢要先读取 likedIDs 再写入，等待集合真正更新。
    check(waitFor([&] { return MusicData::indexOfId(library.lists[1], "3") >= 0; }),
          "liked song enters collection");
    check(!library.writeLoading, "like operation completes");

    library.logout();
    check(library.uid.isEmpty(), "logout clears uid");
    check(library.lists[1].isEmpty() && library.lists[2].isEmpty(), "logout clears private collections");

    // === 测试 8: 平台切换 ===
    const QString initialProvider = library.provider;
    library.switchProvider("qq");
    check(library.provider == "qq", "provider switches to qq");
    check(library.player.queue.isEmpty(), "provider switch clears queue");

    library.switchProvider("kugou");
    check(library.provider == "kugou", "provider switches to kugou");

    library.switchProvider(initialProvider);
    check(library.provider == initialProvider, "provider restores");

    // === 测试 9: 发现功能 ===
    library.discover->load("playlists");
    check(waitFor([&] { return !library.discover->loading; }), "discovery loads");
    check(library.discover->items.size() == 1, "discovery normalizes results");

    // === 测试 10: 收藏加载 ===
    library.uid = "42";
    library.showSource(1);
    check(waitFor([&] { return !library.personalLoading; }), "collection loads");
    check(library.lists[1].size() == 2, "collection filters missing songs");

    // === 测试 11: 主动播放与自动播放的队列行为 ===
    library.playContext = library.lists[1];
    library.choose(library.lists[1].at(1).toObject());
    const auto queuedSong = song("9");
    library.player.queue.replace(QJsonArray{queuedSong});
    library.player.queue.select(0);
    library.play();
    check(library.player.queue.size() == 2, "active play replaces queue with the current song list");
    check(library.player.queue.indexOfId("2") >= 0, "active play keeps selected song");
    library.player.queue.replace(QJsonArray{queuedSong});
    library.player.queue.select(0);
    library.play(false);
    check(library.player.queue.size() == 2 && library.player.queue.at(0)["id"] == "9",
          "automatic play keeps existing queue");

    // === 测试 12: 音乐数据规范化 ===
    auto normalizedSong = MusicData::item("song", "test-id", "测试标题", "测试歌手");
    check(normalizedSong.contains("id") && normalizedSong.contains("title"), "music data structure");

    library.player.stop();
    ok &= checkPlaybackLikes(root);
    ok &= checkQQPlaybackLikes(root);
    ok &= runNativeSessionChecks(root, audioURL);
    host.shutdown();
    qInfo() << "Native music core tests:" << testCount << (ok ? "passed" : "FAILED");
    return ok;
}
