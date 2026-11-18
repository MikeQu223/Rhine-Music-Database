#include "NativeApplication.h"
#include "AppStorage.h"
#include "MusicData.h"
#include <QCoreApplication>
#include <QDir>
#include <QMediaDevices>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonDocument>
#include <QTemporaryDir>
#include <QThread>
#include <cstdio>

namespace {
bool waitFor(const std::function<bool()> &ready) {
    QElapsedTimer timer;
    timer.start();
    while (!ready() && timer.elapsed() < 5000) {
        QCoreApplication::processEvents();
        QThread::msleep(1);
    }
    return ready();
}
bool check(bool value, const char *message) {
    if (!value) {
        std::fprintf(stderr, "Session regression: %s\n", message);
    }
    return value;
}
}

bool runNativeSessionChecks(const QString &root, const QString &audioURL) {
    QTemporaryDir storage;
    bool ok = check(AppStorage::initializePortable(storage.path()).isEmpty(), "isolated storage");
    Host host(root, true);
    Glyphs glyphs(root);
    NativeScene scene(root);
    const auto content = QJsonDocument::fromJson(host.read("slots.json").toUtf8()).object();
    // 实际写入配置和 session.json，再重建应用对象，覆盖开关关闭 -> 开启 -> 重启的路径。
    {
        Host startupHost(root, true);
        startupHost.offline = false;
        startupHost.fixture = [](QString, QJsonObject) {
            return QJsonObject{{"body", QJsonObject{{"code", 200}}}};
        };
        {
            NativeScene firstScene(root);
            NativeApplication first(&startupHost, &glyphs, &firstScene, content);
            first.initialize();
            ok &= check(firstScene.mode() == "boot" && startupHost.preference("startup-animation") == "off",
                        "first launch shows initialization once by default");
            first.hud.action("skip");
            first.music.keyword = "startup-session";
            first.hud.openModal("settings");
            first.hud.action("startup-animation");
            first.saveSession();
        }
        for (const bool enabled : {true, false, true}) {
            NativeScene restartedScene(root);
            NativeApplication restarted(&startupHost, &glyphs, &restartedScene, content);
            restarted.initialize();
            ok &= check(restarted.hud.startupAnimation == enabled &&
                            restartedScene.mode() == (enabled ? "boot" : "archive") &&
                            restarted.music.keyword == "startup-session",
                        "startup preference wins over restored view while preserving browsing state");
            ok &= check(enabled ? restarted.hud.modal.isEmpty() : restarted.hud.modal == "settings",
                        "restored settings never cover initialization");
            restarted.hud.action("skip");
            restarted.hud.openModal("settings");
            restarted.hud.action("startup-animation");
            restarted.saveSession();
        }
        QFile::remove(AppStorage::dataDirectory() + "/session.json");
        AppStorage::settings().clear();
    }
    NativeApplication original(&host, &glyphs, &scene, content);
    auto &music = original.music;
    // 搜索列走会话恢复，收藏列可能由当前平台从独立存储重建。
    music.selectedLane = 0;
    music.selectedPhysical = music.physicalSlots[0].value(3);
    scene.select(music.selectedPhysical);
    scene.setMode("detail");
    scene.sample(1);
    music.keyword = "恢复检索";
    music.searchCursor = 235;
    music.groupName = "测试分组";
    music.groupLane = 0;
    music.groupIndices = {3, 140, 234};
    music.offsets[0] = 136;
    music.rowMemory[0] = 3;
    for (int i = 0; i < 235; ++i) {
        auto song = MusicData::item("song", QString::number(i), "歌曲 " + QString::number(i));
        music.lists[0].append(song);
    }
    music.totals[0] = 500;
    music.hasMore[0] = true;
    music.directory = std::make_shared<MusicDirectory>();
    music.directory->item = MusicData::item("playlist", "parent", "父目录");
    auto folder = std::make_shared<MusicDirectory>();
    folder->parent = music.directory;
    folder->item = MusicData::item("album", "child", "子目录");
    folder->songs = music.lists[0];
    for (int i = 0; i < 500; ++i) {
        folder->ids.append(QString::number(i));
    }
    folder->cursor = 235;
    folder->index = 234;
    folder->anchor = 3;
    folder->parentPhysical = music.selectedPhysical;
    folder->parentLane = 0;
    music.directory = folder;
    music.current = folder->songs[234].toObject();
    music.playContext = folder->songs;
    music.wantsSongDetails = true;
    original.hud.openModal("saved");
    original.hud.query = "过滤";
    original.hud.listOffset = 100;
    original.hud.trackOffset = 220;
    original.hud.tab = "history";
    original.hud.trackListMode = true;
    original.hud.lyricsMode = true;
    // 离线运行不能覆盖保存的会话；正式保存走同一个原子写入入口。
    original.saveSession();
    ok &= check(!QFile::exists(AppStorage::dataDirectory() + "/session.json"), "offline isolation");
    host.offline = false;
    original.saveSession();
    host.offline = true;
    QFile file(AppStorage::dataDirectory() + "/session.json");
    ok &= check(file.open(QIODevice::ReadOnly), "session file saved");
    const auto saved = QJsonDocument::fromJson(file.readAll()).object();
    file.close();
    Host restoredHost(root, true);
    NativeScene restoredScene(root);
    NativeApplication restored(&restoredHost, &glyphs, &restoredScene, content);
    ok &= check(restored.restoreSessionState(saved), "disk round trip");
    ok &= check(restored.music.keyword == music.keyword && restored.music.offsets[0] == 136 &&
                    restored.music.rowMemory[0] == 3 && restored.music.lists[0].size() == 235 &&
                    restored.music.totals[0] == 500 && restored.music.hasMore[0] &&
                    restored.music.groupIndices == music.groupIndices && restored.music.searchCursor == 235,
                "library columns, grouping and pagination restored");
    ok &= check(restored.music.directory && restored.music.directory->parent &&
                    restored.music.directory->index == 234 && restored.music.directory->cursor == 235 &&
                    restored.music.directory->ids.size() == 500 && restored.music.current == music.current,
                "nested directory and logical selection beyond 100 restored");
    ok &= check(restored.hud.lyricsMode, "lyrics view restored before selection validation");
    restored.step(2, 1920);
    ok &= check(restored.music.current == music.current && restored.music.directory->index == 234 &&
                    restoredScene.selection() == music.selectedPhysical,
                "first UI frame keeps restored selection");
    ok &= check(restored.hud.modal == "saved" && restored.hud.query == "过滤" &&
                    restored.hud.tab == "history" && restored.hud.trackListMode && !restored.hud.lyricsMode,
                "library panel, filter and view restored");
    auto invalid = saved;
    auto invalidLibrary = invalid["library"].toObject();
    invalidLibrary["provider"] = "beta";
    invalid["library"] = invalidLibrary;
    ok &= check(!restored.restoreSessionState(invalid), "provider isolation");

    // 核对暂停会话的定位、队列和独立浏览状态。
    Host playbackHost(root, true);
    playbackHost.setProvider("local");
    MusicApi playbackApi(&playbackHost);
    playbackApi.provider = "local";
    MusicPlayer player(&playbackHost, &playbackApi);
    player.volume(0);
    auto track = MusicData::item("song", "resume", "恢复播放", {}, "local");
    track["url"] = audioURL;
    auto nextTrack = MusicData::item("song", "next", "下一首", {}, "local");
    nextTrack["url"] = audioURL;
    QJsonObject playback{{"current", track}, {"queue", QJsonArray{track, nextTrack}},
                         {"index", 99},      {"mode", "shuffle"},
                         {"position", 2500}, {"requested", false}};
    player.restoreSessionState(playback);
    // 设备可用性不能只采样一次：macOS runner 上 CoreAudio 会在恢复播放的瞬间短暂报
    // "无默认输出"，随后又回来。判定时重新采样，避免把设备抖动误报成播放回归。
    const auto audioOutputPresent = [] { return !QMediaDevices::defaultAudioOutput().isNull(); };
    ok &= check(waitFor([&] {
                    if (!audioOutputPresent()) {
                        return !player.loading;
                    }
                    return !player.loading && playbackHost.mediaState()["seekable"].toBool() &&
                           playbackHost.mediaState()["position"].toLongLong() >= 2400;
                }),
                "paused audio loads and seeks");
    ok &= check(!playbackHost.mediaState()["requested"].toBool() &&
                    !playbackHost.mediaState()["playing"].toBool() && !player.failed &&
                    player.queue.index() == 0 && player.queue.size() == 2 && player.mode == "shuffle" &&
                    restored.music.current == music.current,
                "paused intent, queue and browsing independent of playing song");
    // 在播放请求交给后端前检查恢复状态，输出设备与时钟由音频回归单独覆盖。
    playback["requested"] = true;
    QJsonObject pendingResume;
    const auto observeResume = QObject::connect(&player, &MusicPlayer::changed, &playbackHost, [&] {
        if (player.loading && pendingResume.isEmpty()) {
            pendingResume = player.sessionState();
        }
    });
    player.restoreSessionState(playback);
    QObject::disconnect(observeResume);
    ok &= check(pendingResume["requested"].toBool() &&
                    pendingResume["position"].toInteger() == playback["position"].toInteger(),
                "playing session retains saved position and playback intent");
    player.stop();
    std::fprintf(stderr, "Session regression: %s\n", ok ? "passed" : "FAILED");
    return ok;
}
