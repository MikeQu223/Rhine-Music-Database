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
    // 清除缓存只删除可重建数据：元数据、歌词与记录清空，登录状态和本地音乐库保留。
    {
        Host cacheHost(root, true);
        MusicLibrary cached(&cacheHost, {});
        cacheHost.offline = false;
        cached.provider = "alpha";
        cached.api.provider = "alpha";
        cached.searchHistory = {QStringLiteral("旧检索")};
        cacheHost.setPreference("search-history", QStringLiteral("[\"旧检索\"]"));
        cacheHost.setPreference("play-history", QStringLiteral("[{\"id\":\"1\"}]"));
        cacheHost.setPreference("local-cover-cache", QStringLiteral("{\"1:1\":\"cover\"}"));
        cacheHost.setPreference("lyrics-cache", QStringLiteral("[{\"key\":\"alpha:1\"}]"));
        cacheHost.setPreference("theme", QStringLiteral("dark"));
        cacheHost.setPreference("account-id-alpha", QStringLiteral("42"));
        const QDir cache(AppStorage::cacheDirectory());
        const auto metadata = cache.filePath("metadata");
        const auto library = AppStorage::dataDirectory() + "/local-library";
        QDir().mkpath(metadata);
        QDir().mkpath(cache.filePath("qml"));
        QDir().mkpath(cache.filePath("shaders"));
        QDir().mkpath(library);
        for (const auto &path : {metadata + "/entry.json", cache.filePath("qml/entry.bin"),
                                 cache.filePath("shaders/pipeline.cache"), library + "/index.json"}) {
            QFile file(path);
            if (file.open(QIODevice::WriteOnly)) {
                file.write("fixture");
            }
        }
        cached.clearCaches();
        ok &= check(!QFile::exists(metadata + "/entry.json") && !QDir(cache.filePath("qml")).exists() &&
                        !QDir(cache.filePath("shaders")).exists(),
                    "cache directories removed");
        ok &= check(QFile::exists(library + "/index.json"), "local library preserved");
        ok &= check(cacheHost.preference("lyrics-cache") == "[]" &&
                        cacheHost.preference("play-history") == "[]" &&
                        cacheHost.preference("search-history") == "[]" &&
                        cacheHost.preference("local-cover-cache") == "{}" && cached.searchHistory.isEmpty(),
                    "lyrics, history and cover caches cleared");
        ok &= check(cacheHost.preference("theme") == "dark" &&
                        cacheHost.preference("account-id-alpha") == "42",
                    "settings and account preserved");
        // 清掉本用例写入的偏好，避免影响后续会话恢复检查。
        AppStorage::settings().clear();
    }
    NativeApplication original(&host, &glyphs, &scene, content);
    auto &music = original.music;
    music.selectedLane = 1;
    music.selectedPhysical = music.physicalSlots[1].value(3);
    scene.select(music.selectedPhysical);
    scene.setMode("detail");
    scene.sample(1);
    music.keyword = "恢复检索";
    music.searchCursor = 235;
    music.groupName = "测试分组";
    music.groupLane = 1;
    music.groupIndices = {3, 140, 234};
    music.offsets[1] = 136;
    music.rowMemory[1] = 3;
    music.likedCursor = 235;
    music.likedIDs = QJsonArray{"1", "2"};
    for (int i = 0; i < 235; ++i) {
        auto song = MusicData::item("song", QString::number(i), "歌曲 " + QString::number(i));
        music.lists[1].append(song);
    }
    music.totals[1] = 500;
    music.hasMore[1] = true;
    music.directory = std::make_shared<MusicDirectory>();
    music.directory->item = MusicData::item("playlist", "parent", "父目录");
    auto folder = std::make_shared<MusicDirectory>();
    folder->parent = music.directory;
    folder->item = MusicData::item("album", "child", "子目录");
    folder->songs = music.lists[1];
    for (int i = 0; i < 500; ++i) {
        folder->ids.append(QString::number(i));
    }
    folder->cursor = 235;
    folder->index = 234;
    folder->anchor = 3;
    folder->parentPhysical = music.selectedPhysical;
    folder->parentLane = 1;
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
    ok &= check(restored.music.keyword == music.keyword && restored.music.offsets[1] == 136 &&
                    restored.music.rowMemory[1] == 3 && restored.music.lists[1].size() == 235 &&
                    restored.music.totals[1] == 500 && restored.music.hasMore[1] &&
                    restored.music.groupIndices == music.groupIndices && restored.music.likedCursor == 235,
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

    // 用实际 QMediaPlayer 验证暂停恢复的底层位置，以及播放恢复后进度继续增长。
    auto track = MusicData::item("song", "resume", "恢复播放");
    restoredHost.fixture = [&](QString route, QJsonObject) {
        QJsonValue value;
        if (route.endsWith("/playback")) {
            value = QJsonObject{{"url", audioURL}};
        }
        return QJsonObject{{"body", QJsonObject{{"code", 200}, {"value", value}}}};
    };
    restored.music.player.volume(0);
    QJsonObject playback{{"current", track}, {"queue", QJsonArray{track, music.current}},
                         {"index", 99},      {"mode", "shuffle"},
                         {"position", 2500}, {"requested", false}};
    restored.music.player.restoreSessionState(playback);
    // 设备可用性不能只采样一次：macOS runner 上 CoreAudio 会在恢复播放的瞬间短暂报
    // "无默认输出"，随后又回来。判定时重新采样，避免把设备抖动误报成播放回归。
    const auto audioOutputPresent = [] { return !QMediaDevices::defaultAudioOutput().isNull(); };
    const bool hasOutput = audioOutputPresent();
    ok &= check(waitFor([&] {
                    if (!audioOutputPresent()) {
                        return !restored.music.player.loading;
                    }
                    return !restored.music.player.loading && restoredHost.mediaState()["seekable"].toBool() &&
                           restoredHost.mediaState()["position"].toLongLong() >= 2400;
                }),
                "paused audio loads and seeks");
    ok &= check(!restoredHost.mediaState()["requested"].toBool() &&
                    !restoredHost.mediaState()["playing"].toBool() &&
                    restored.music.player.queue.index() == 0 && restored.music.player.queue.size() == 2 &&
                    restored.music.player.mode == "shuffle" && restored.music.current == music.current,
                "paused intent, queue and browsing independent of playing song");
    playback["requested"] = true;
    restored.music.player.restoreSessionState(playback);
    // 这个断言在 macOS runner 上偶发失败。playing / position / buffering 三个量足以
    // 区分三种成因：媒体始终没进 ready（recoveryPosition 被钉住、看门狗同时失效）、
    // 进了 ready 但输出设备不推进时钟、以及仅仅启动得慢。失败时把整段等待的轨迹打
    // 出来，否则只能看到一句 FAILED 而无从判断。
    QString resumeTrace;
    qint64 sampled = -1;
    QElapsedTimer resumeClock;
    resumeClock.start();
    const bool resumed = waitFor([&] {
        const auto state = restoredHost.mediaState();
        const auto elapsed = resumeClock.elapsed();
        if (elapsed / 200 != sampled) {
            sampled = elapsed / 200;
            resumeTrace += QStringLiteral("%1:%2/%3%4%5 ")
                               .arg(elapsed)
                               .arg(state["playing"].toBool() ? QChar('P') : QChar('-'))
                               .arg(state["position"].toLongLong())
                               .arg(state["seekable"].toBool() ? QChar('S') : QChar('-'))
                               .arg(state["buffering"].toBool() ? QChar('B') : QChar('-'));
        }
        if (!audioOutputPresent()) {
            // 设备一直在时要求播放真正开始并越过恢复点；恢复途中设备消失则只
            // 校验播放意图保住了——没有输出时位置推进无法验收。
            return !restored.music.player.loading && state["requested"].toBool() &&
                   (!hasOutput || state["position"].toLongLong() == 2500);
        }
        return state["playing"].toBool() && state["position"].toLongLong() > 2800;
    });
    if (!resumed) {
        std::fprintf(stderr, "DIAG: resume trace (ms:playing/position/seekable/buffering) %s\n",
                     resumeTrace.toUtf8().constData());
    }
    ok &= check(resumed, "playing audio resumes and advances from saved position");
    restored.music.player.stop();
    if (!hasOutput) {
        std::fprintf(stderr, "SKIP: no audio output; verified retained position and intent, actual playback "
                             "requires a device\n");
    } else if (!audioOutputPresent()) {
        std::fprintf(stderr, "SKIP: audio output disappeared during restore; verified retained intent, "
                             "actual playback requires a device\n");
    }
    std::fprintf(stderr, "Session regression: %s\n", ok ? "passed" : "FAILED");
    return ok;
}
