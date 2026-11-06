#include "NativeHud.h"
#include "fg/FgCapability.h"
#include "fg/FgConfig.h"
#include "NativeApplication.h"
#include "NativeCards.h"
#include <cstring>
#include "MusicData.h"
#include "MusicDiscover.h"
#include "PlayerBar.h"
#include "DiscoverArtwork.h"
#include "DiscoverMusicCard.h"
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QThread>
#include <QDebug>
#include <QDir>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QPainter>
#include <QSet>
#include <QTemporaryDir>
#include <QUrl>
#include <algorithm>
#include <cmath>
#include <cstdio>

namespace {
QJsonObject song(int index) {
    auto value =
        MusicData::item("song", QString::number(index), "本地曲目 " + QString::number(index), "测试歌手");
    value["album"] = "测试专辑";
    value["albumID"] = "42";
    value["duration"] = 180000;
    value["wiki"] = "第一段百科\n第二段百科\n第三段百科\n第四段百科";
    value["artists"] = QJsonArray{QJsonObject{{"id", "7"}, {"name", "测试歌手"}}};
    return value;
}

// 辅助函数：检查 hits 中是否存在指定 action
bool hasAction(const QJsonArray &hits, const QString &action) {
    for (const auto &value : hits) {
        if (value.toObject()["action"].toString() == action) {
            return true;
        }
    }
    return false;
}

// 辅助函数：获取指定 action 的 hit 对象
QJsonObject getHit(const QJsonArray &hits, const QString &action) {
    for (const auto &value : hits) {
        auto hit = value.toObject();
        if (hit["action"].toString() == action) {
            return hit;
        }
    }
    return QJsonObject();
}

// 创建测试用的 MusicLibrary
MusicLibrary *createTestMusicLibrary(Host *host, const QString &provider, const QJsonObject &content) {
    MusicLibrary *music = new MusicLibrary(host, content);
    music->provider = provider;
    music->api.provider = provider;
    music->uid = "42";
    music->nickname = "测试账号";
    music->status = "离线固定时间校验";
    music->keyword = "本地";
    music->loginStatus = "等待确认";
    music->coverImage.clear();
    music->likedIDs = QJsonArray{"1"};

    QJsonArray songs;
    for (int index = 1; index <= 20; ++index) {
        songs.append(song(index));
    }
    music->current = songs.first().toObject();
    music->tracks = songs;
    for (int lane = 0; lane < 5; ++lane) {
        music->lists[lane] = songs;
        music->totals[lane] = songs.size();
        music->hasMore[lane] = false;
    }
    music->player.queue.replace(songs);
    music->player.current = music->current;
    music->player.queue.select(2);
    music->player.state = {
        {"playing", true}, {"position", 45678}, {"duration", 180000}, {"volume", 0.7}, {"seekable", true}};
    music->player.status = "原生播放器";
    music->player.quality = "exhigh";
    music->player.alternative = false;
    music->discover->items = songs;
    music->discover->status = "本地发现";
    music->discover->more = true;
    return music;
}
}

/**
 * Native HUD 核心功能回归测试
 *
 * 验证关键交互逻辑和状态管理，不依赖像素对比。
 */
namespace {
/** 固定分页输入验证全量排序、恢复原序与点击映射，不访问真实音乐服务。 */
bool checkSorting(const QString &root, Glyphs &glyphs, const QJsonObject &content) {
    Host host(root, true);
    MusicLibrary music(&host, content);
    music.provider = "qq";
    music.api.provider = "qq";
    music.uid = "42";
    const auto track = [](int id, QString title, QString album, QString artist) {
        auto value = song(id);
        value["title"] = title;
        value["album"] = album;
        value["artist"] = artist;
        return value;
    };
    const QJsonArray original{track(1, "Z", "B", "C"), track(2, "A10", "A", "B"), track(3, "A2", "A", "A"),
                              track(4, "A2", "", "A")};
    if (MusicData::sortOrder(original, "title") != QVector<int>{2, 3, 1, 0} ||
        MusicData::sortOrder(original, "album") != QVector<int>{1, 2, 0, 3} ||
        MusicData::sortOrder(original, "artist") != QVector<int>{2, 3, 1, 0}) {
        qCritical() << "Stable natural sorting or missing-name placement failed";
        return false;
    }
    int pages = 0;
    bool failed = false;
    host.fixture = [&](QString route, QJsonObject parameters) {
        QJsonValue value;
        if (route.endsWith("/songs")) {
            ++pages;
            if (failed) {
                return QJsonObject{{"body", QJsonObject{{"code", 500}, {"message", "测试补页失败"}}}};
            }
            QJsonArray values;
            for (const auto &id : parameters["args"].toArray().at(0).toArray()) {
                const auto index = id.toString().toInt() - 1;
                if (index >= 0 && index < original.size()) {
                    values.append(original.at(index));
                }
            }
            value = values;
        }
        return QJsonObject{{"body", QJsonObject{{"code", 200}, {"value", value}}}};
    };
    HudSceneActions scene;
    scene.mode = [](QString) {};
    scene.pointer = [](QString, double, double, double) {};
    NativeHud hud(&host, &glyphs, &music, scene);
    hud.reduced = true;
    QJsonObject frame{{"mode", "detail"}, {"selected", 0}, {"detail", 1}};
    const auto settle = [&] {
        QElapsedTimer elapsed;
        elapsed.start();
        while (hud.state()["sortLoading"].toBool() && elapsed.elapsed() < 3000) {
            QCoreApplication::processEvents();
            QThread::msleep(1);
        }
        return !hud.state()["sortLoading"].toBool();
    };
    music.directory = std::make_shared<MusicDirectory>();
    music.directory->item = MusicData::item("playlist", "8", "排序测试");
    music.directory->songs = QJsonArray{original.first()};
    music.directory->ids = QJsonArray{"1", "missing", "2", "3", "4"};
    music.directory->cursor = 1;
    music.current = music.directory->item;
    music.directoryInfo = true;
    frame["mode"] = "detail";
    hud.draw(frame, 1920, 50);
    const auto playButton = getHit(hud.hits, "music:play-loaded");
    const auto sortButton = getHit(hud.hits, "music:sort-menu");
    if (sortButton.isEmpty() || sortButton["y"] != playButton["y"] ||
        sortButton["height"] != playButton["height"] ||
        sortButton["x"].toDouble() <= playButton["x"].toDouble() + playButton["width"].toDouble() ||
        hasAction(hud.hits, "music:sort:detail:album")) {
        qCritical() << "Playlist sorting button is not collapsed or aligned with play-all";
        return false;
    }
    hud.action("music:sort-menu");
    hud.draw(frame, 1920, 51);
    for (const auto &field : {"none", "title", "album", "artist"}) {
        if (!hasAction(hud.hits, "music:sort:detail:" + QString(field))) {
            qCritical() << "Sorting menu is missing an option" << field;
            return false;
        }
    }
    hud.action("music:sort:detail:album");
    if (!hud.modal.isEmpty()) {
        qCritical() << "Sorting selection did not dismiss the menu";
        return false;
    }
    if (!settle() || music.directory->songs != original) {
        qCritical() << "Playlist sorting did not finish pagination";
        return false;
    }
    hud.draw(frame, 1920, 51);
    const auto sorted = QJsonArray{original.at(1), original.at(2), original.at(0), original.at(3)};
    const auto queueSource = music.directorySource();
    if (music.libraryItems() != sorted || MusicData::slice(queueSource.items, 0, 4) != sorted ||
        queueSource.ids.last().toString() != "missing" || music.directory->index != 2 ||
        music.directory->cursor != 5) {
        qCritical() << "Library, selection, queue or pagination did not follow detail sorting";
        return false;
    }
    const auto saved = music.sessionState();
    if (!music.restoreSessionState(saved) || music.libraryItems() != sorted ||
        music.directory->sortField != "album") {
        qCritical() << "Session restore lost playlist sorting";
        return false;
    }
    const auto first = getHit(hud.hits, "music:track:0");
    const auto last = getHit(hud.hits, "music:track:3");
    if (first.isEmpty() || last.isEmpty() || first["y"].toDouble() >= last["y"].toDouble()) {
        qCritical() << "Playlist sorted hits lost their canonical indices";
        return false;
    }
    hud.action("music:track:0");
    if (music.current["id"] != "2") {
        qCritical() << "Sorted playlist selected the wrong song";
        return false;
    }
    music.returnToDirectory();
    frame["mode"] = "archive";
    hud.draw(frame, 1920, 52);
    if (music.libraryItems() != sorted || hasAction(hud.hits, "music:sort-menu")) {
        qCritical() << "Archive did not retain sorted songs or exposed a sorting control";
        return false;
    }
    music.navigateDirectory(1);
    if (music.current["id"] != "3") {
        qCritical() << "Archive navigation did not follow sorted order";
        return false;
    }
    music.showDirectoryInfo();
    frame["mode"] = "detail";
    hud.draw(frame, 1920, 53);
    hud.action("music:sort-menu");
    hud.action("music:sort:detail:none");
    if (music.libraryItems() != original || music.directory->index != 2) {
        qCritical() << "Default order did not preserve the selected song";
        return false;
    }
    // 补页失败须停止重试，关闭页面须取消尚未发出的请求。
    music.directory->ids.append("5");
    failed = true;
    const auto beforeFailure = pages;
    hud.action("music:sort-menu");
    hud.action("music:sort:detail:artist");
    if (!settle() || pages != beforeFailure + 1 || !music.status.contains("未能补齐")) {
        qCritical() << "Sorting pagination did not stop after failure";
        return false;
    }
    const auto beforeClose = pages;
    hud.action("music:sort-menu");
    hud.action("music:sort:detail:album");
    hud.openModal("saved");
    hud.draw(frame, 1920, 54);
    QCoreApplication::processEvents();
    if (hud.state()["sortLoading"].toBool() || pages != beforeClose ||
        hasAction(hud.hits, "music:sort-menu") || hasAction(hud.hits, "music:sort:library:title")) {
        qCritical() << "Library exposed sorting controls or kept loading a closed detail page";
        return false;
    }
    return true;
}

/** 专辑/歌单详情卡改版只调整内部；外框、封面、播放/排序与曲目行仍沿用原坐标。 */
bool checkCollectionCard(const QString &root, Glyphs &glyphs, const QJsonObject &content) {
    Host host(root, true);
    MusicLibrary music(&host, content);
    music.provider = "netease";
    music.api.provider = "netease";
    music.uid = "42";
    music.current = MusicData::item("album", "165148405", "孤星 OST", "塞壬唱片-MSR");
    music.current["date"] = "2023-05-09";
    music.current["trackCount"] = 20;
    music.current["description"] = "从来没有人质疑日升月落，也没有人质疑万物生长。";
    QJsonArray songs;
    for (int index = 1; index <= 20; ++index) {
        songs.append(song(index));
    }
    music.tracks = songs;
    const QString coverKey = "file:///rhine-offline/collection-cover.png";
    QImage cover(64, 64, QImage::Format_RGB32);
    cover.fill(Qt::green);
    host.fixtureImage(coverKey, cover);
    music.coverImage = coverKey;
    HudSceneActions scene;
    scene.mode = [](QString) {};
    scene.pointer = [](QString, double, double, double) {};
    NativeHud hud(&host, &glyphs, &music, scene);
    hud.reduced = true;
    const QJsonObject frame{{"mode", "detail"}, {"detail", 1}};
    for (const double stageWidth : {1280.0, 1920.0, 2560.0}) {
        const QRectF expected(40, 260, stageWidth - 80, 696);
        if (hud.detailBounds(stageWidth) != expected) {
            qCritical() << "Collection card changed its external geometry" << stageWidth;
            return false;
        }
        const auto layout = hud.containerLayout(stageWidth);
        const auto sideWidth = layout.sidebar - 44;
        const auto coverSize = std::min(250.0, sideWidth - 16);
        const auto artX = layout.left + 22 + (sideWidth - coverSize) / 2;
        hud.draw(frame, stageWidth, 50);
        bool artwork = false;
        bool kicker = false;
        for (const auto &value : hud.commands) {
            const auto command = value.toArray();
            if (command.size() == 6 && command.first() == "image" && command.at(1) == coverKey) {
                artwork = command.at(2).toDouble() == artX && command.at(3).toDouble() == 352 &&
                          command.at(4).toDouble() == coverSize && command.at(5).toDouble() == coverSize;
            }
            if (command.size() > 2 && command.first() == "text" && command.at(1) == "03 / ALBUM RECORD") {
                kicker = true;
            }
        }
        const auto play = getHit(hud.hits, "music:play-loaded");
        const auto firstRow = getHit(hud.hits, "music:track:0");
        const auto secondRow = getHit(hud.hits, "music:track:1");
        if (!artwork || !kicker || play.isEmpty() || firstRow.isEmpty() || secondRow.isEmpty()) {
            qCritical() << "Collection card lost its archive artwork, header or principal actions"
                        << stageWidth << artwork << kicker;
            return false;
        }
        if (play["x"].toDouble() != layout.x || play["y"].toDouble() != 339 ||
            play["width"].toDouble() != 180 || play["height"].toDouble() != 44) {
            qCritical() << "Collection toolbar moved from its fixed layout" << stageWidth;
            return false;
        }
        bool sheetRule = false;
        for (const auto &value : hud.commands) {
            const auto command = value.toArray();
            if (command.size() == 6 && command.first() == "fill" &&
                command.at(3).toDouble() == expected.y() && command.at(5).toDouble() == 3) {
                sheetRule = command.at(2).toDouble() == layout.x - 18 &&
                            command.at(4).toDouble() == layout.width + 18;
            }
        }
        if (!sheetRule) {
            qCritical() << "Collection card top rule no longer reaches the sheet divider" << stageWidth;
            return false;
        }
        if (firstRow["x"].toDouble() != layout.x - 8 || firstRow["y"].toDouble() != layout.rowsY ||
            firstRow["width"].toDouble() != layout.width - 6 ||
            firstRow["height"].toDouble() != layout.rowHeight - 2 ||
            secondRow["y"].toDouble() - firstRow["y"].toDouble() != layout.rowHeight) {
            qCritical() << "Collection track rows changed their fixed geometry" << stageWidth;
            return false;
        }
        for (const auto &value : hud.hits) {
            const auto hit = value.toObject();
            const auto action = hit["action"].toString();
            const bool cardAction = action == "music:play-loaded" || action == "music:sort-menu" ||
                                    action == "music:artist-tab:songs" ||
                                    action == "music:artist-tab:albums" ||
                                    action == "music:rename-playlist" || action == "music:delete-playlist" ||
                                    action == "music:subscribe" || action == "music:source";
            if (!cardAction) {
                continue;
            }
            const QRectF rectangle(hit["x"].toDouble(), hit["y"].toDouble(), hit["width"].toDouble(),
                                   hit["height"].toDouble());
            if (!expected.contains(rectangle)) {
                qCritical() << "Collection action escaped the card bounds" << stageWidth << action;
                return false;
            }
        }
    }
    // 歌单管理入口与收藏/来源按钮保持原有槽位，改版后仍然可点击。
    music.current = MusicData::item("playlist", "8", "测试歌单", "测试账号");
    music.current["creatorID"] = "42";
    hud.draw(frame, 1920, 50);
    const auto sort = getHit(hud.hits, "music:sort-menu");
    const auto layout = hud.containerLayout(1920);
    if (sort["x"].toDouble() != layout.x + 195 || sort["y"].toDouble() != 339 ||
        sort["width"].toDouble() != 180 || sort["height"].toDouble() != 44) {
        qCritical() << "Playlist sort no longer aligns with the play-all button";
        return false;
    }
    for (const auto &action :
         {"music:rename-playlist", "music:delete-playlist", "music:subscribe", "music:source"}) {
        if (!hasAction(hud.hits, action)) {
            qCritical() << "Collection card lost a management action" << action;
            return false;
        }
    }
    // 收藏按钮需读取真实收藏集合，不能在已收藏时仍显示“＋ 收藏”。
    music.subscriptions.insert(music.current["key"].toString());
    hud.draw(frame, 1920, 50);
    bool subscribedLabel = false;
    for (const auto &value : hud.commands) {
        const auto command = value.toArray();
        if (command.size() > 2 && command.first() == "text" && command.at(1) == "✓ 已收藏歌单") {
            subscribedLabel = true;
        }
    }
    if (!subscribedLabel) {
        qCritical() << "Collection card did not reflect an existing subscription";
        return false;
    }
    // “我喜欢的音乐”是账号维护的特殊歌单，不提供改名、删除和收藏入口。
    music.subscriptions.remove(music.current["key"].toString());
    music.current["special"] = true;
    hud.draw(frame, 1920, 50);
    for (const auto &action : {"music:rename-playlist", "music:delete-playlist", "music:subscribe"}) {
        if (hasAction(hud.hits, action)) {
            qCritical() << "Liked playlist exposed a management action" << action;
            return false;
        }
    }
    // 歌手页仍保留歌曲/专辑切换，专辑页不再绘制歌曲控件。
    music.current = MusicData::item("artist", "7", "测试歌手", "测试歌手");
    hud.draw(frame, 1920, 50);
    if (!hasAction(hud.hits, "music:artist-tab:songs") || !hasAction(hud.hits, "music:artist-tab:albums")) {
        qCritical() << "Artist card lost its songs/albums switch";
        return false;
    }
    return true;
}

/** 歌曲详情里的同专辑曲目测试 */
bool checkAlbumTrackSelection(const QString &root, Glyphs &glyphs, const QJsonObject &content) {
    Host host(root, true);
    MusicLibrary music(&host, content);
    music.provider = "netease";
    music.api.provider = "netease";
    music.uid = "42";
    music.directory = std::make_shared<MusicDirectory>();
    music.directory->item = MusicData::item("playlist", "9", "目录");
    QJsonArray directorySongs;
    for (int index = 1; index <= 4; ++index) {
        directorySongs.append(song(index));
    }
    music.directory->songs = directorySongs;
    music.current = song(5);
    QJsonArray albumTracks;
    for (int index = 6; index <= 9; ++index) {
        albumTracks.append(song(index));
    }
    music.tracks = albumTracks;
    HudSceneActions scene;
    scene.mode = [](QString) {};
    scene.pointer = [](QString, double, double, double) {};
    NativeHud hud(&host, &glyphs, &music, scene);
    hud.tab = "history";
    const QJsonObject frame{{"mode", "detail"}, {"detail", 1}};
    hud.draw(frame, 1920, 50);
    if (!hasAction(hud.hits, "music:album-track:2") || hasAction(hud.hits, "music:track:2")) {
        qCritical() << "Album track rows do not use their own selection route";
        return false;
    }
    hud.action("music:album-track:2");
    if (music.current["id"] != "8") {
        qCritical() << "Album track row selected the directory song at the same index";
        return false;
    }
    return true;
}
}

namespace {
/** 验证同一展示组件在嵌入与浮窗组合下的交互边界，不复制绘制实现。 */
bool checkPlayerBar(Glyphs &glyphs) {
    PlayerBar::State state;
    state.title = "Control's Wishes / 很长的歌曲标题用于验证文本裁切边界";
    state.artist = "塞壬唱片-MSR";
    state.album = "孤星";
    state.hasTrack = true;
    state.canLike = true;
    state.musicVideo = true;
    state.likeKnown = true;
    state.seekable = true;
    state.durationMs = 195000;
    state.positionMs = 102000;
    for (const auto width : {1280.0, 1920.0, 2560.0}) {
        const QRectF row(0, 984, width, PlayerBar::RowHeight);
        const auto drawing = PlayerBar::render(state, row, false, glyphs);
        if (!drawing.seek || !drawing.volume || !drawing.inputBounds.contains(*drawing.seek) ||
            !row.contains(*drawing.volume) || !hasAction(drawing.hits, "player:lyrics") ||
            !hasAction(drawing.hits, "player:open") || !hasAction(drawing.hits, "player:mv")) {
            qCritical() << "Player bar lost seeking, volume, lyrics or queue";
            return false;
        }
        for (const auto &value : drawing.hits) {
            const auto hit = value.toObject();
            const QRectF bounds(hit["x"].toDouble(), hit["y"].toDouble(), hit["width"].toDouble(),
                                hit["height"].toDouble());
            if (!drawing.inputBounds.contains(bounds) || !hit["fixed"].toBool()) {
                qCritical() << "Player bar hit escaped its row";
                return false;
            }
        }
        const auto lyrics = getHit(drawing.hits, "player:lyrics");
        const auto mv = getHit(drawing.hits, "player:mv");
        if (mv["x"].toDouble() + mv["width"].toDouble() / 2 != row.right() - 435) {
            qCritical() << "MV action is missing or no longer centered beside the player controls"
                        << "row:" << row << "hit:" << mv << "expected center:" << row.right() - 435;
            return false;
        }
        const auto toggle = getHit(drawing.hits, "player:toggle");
        const QRectF toggleRect(toggle["x"].toDouble(), toggle["y"].toDouble(), toggle["width"].toDouble(),
                                toggle["height"].toDouble());
        if (drawing.seek->left() != row.left() || drawing.seek->width() != row.width() ||
            drawing.seek->top() >= row.top() || toggleRect.center() != row.center() ||
            lyrics["y"].toDouble() < drawing.seek->bottom()) {
            qCritical() << "Full-width boundary seek or centered player layout regressed";
            return false;
        }
    }
    // 新增操作不能压住歌曲入口，四种模式的命中中心与主播放键一致。
    for (const auto &mode : {QString("off"), QString("all"), QString("one"), QString("shuffle")}) {
        state.mode = mode;
        const auto drawing = PlayerBar::render(state, {0, 984, 1920, PlayerBar::RowHeight}, false, glyphs);
        for (const auto &action : {QString("music:like-current"), QString("player:mode")}) {
            const auto hit = getHit(drawing.hits, action);
            if (hit.isEmpty() || hit["y"].toDouble() + hit["height"].toDouble() / 2 != 1032) {
                qCritical() << "Player accessory lost its centered action";
                return false;
            }
        }
        int lyricsTargets = 0;
        for (const auto &value : drawing.hits) {
            lyricsTargets += value.toObject()["action"] == "player:lyrics" ? 1 : 0;
        }
        if (lyricsTargets != 2) {
            qCritical() << "Song and lyric button must share the lyrics action";
            return false;
        }
    }
    // 用实际字形绘制器确认进度竖线跨过交界线，而不是只检查命令坐标。
    const auto drawing = PlayerBar::render(state, {0, 984, 1920, PlayerBar::RowHeight}, false, glyphs);
    QImage image(1920, 1080, QImage::Format_ARGB32_Premultiplied);
    image.fill(Qt::transparent);
    QPainter painter(&image);
    glyphs.commands(painter, drawing.commands, [](QString) { return QImage(); });
    painter.end();
    const auto markerX = qRound(1920 * state.positionMs / state.durationMs);
    if (image.pixelColor(markerX, 981).alpha() == 0 || image.pixelColor(markerX, 989).alpha() == 0) {
        qCritical() << "Progress marker must remain visible above and below the boundary";
        return false;
    }
    state.hasTrack = false;
    state.canLike = false;
    state.seekable = false;
    state.applicationVolume = false;
    const auto empty = PlayerBar::render(state, {0, 0, 1920, PlayerBar::RowHeight}, true, glyphs);
    if (empty.seek || empty.volume || hasAction(empty.hits, "player:lyrics")) {
        qCritical() << "Unavailable player operations remained interactive";
        return false;
    }
    return true;
}

/** 留白输入不能触发详情返回、关闭弹窗或滚动后方队列。 */
bool checkPlayerInput(const QString &root, Glyphs &glyphs, const QJsonObject &content) {
    Host host(root, true);
    NativeScene scene(root);
    scene.review("detail");
    NativeApplication app(&host, &glyphs, &scene, content);
    app.music.current = song(1);
    const QJsonObject frame{{"mode", "detail"}, {"detail", 1}};
    app.hud.draw(frame, 1920, 50);
    for (const auto x : {600.0, 1350.0}) {
        app.pointer("pointermove", x, 1040);
        app.pointer("pointerdown", x, 1040);
        app.pointer("pointerup", x, 1040);
        if (scene.mode() != "detail") {
            qCritical() << "Player whitespace navigated the underlying library";
            return false;
        }
    }
    for (int index = 0; index < 20; ++index) {
        app.music.player.queue.enqueue(song(index));
    }
    app.hud.openModal("player");
    app.hud.draw(frame, 1920, 50);
    app.hud.queueOffset = 2;
    for (const auto x : {600.0, 1350.0}) {
        app.pointer("pointerdown", x, 1040);
        app.pointer("pointerup", x, 1040);
        app.hud.wheel(x, 1040, -120);
    }
    // 按下留白后移出播放栏再释放，同样不能构成弹窗外点击。
    app.pointer("pointerdown", 600, 1040);
    app.pointer("pointerup", 600, 100);
    if (app.hud.closing || app.hud.queueOffset != 2) {
        qCritical() << "Player whitespace closed or scrolled the underlying panel";
        return false;
    }
    app.hud.draw(frame, 393. * 1080 / 852, 50);
    app.pointer("pointerdown", 40, 400);
    app.pointer("pointerup", 40, 400);
    if (app.hud.closing) {
        qCritical() << "Mobile panel whitespace closed the panel";
        return false;
    }
    // 实际场景投影中，竖屏详情的左右上角应等高；横屏仍保留原有斜视角。
    scene.resize(393, 852);
    scene.reduced(true);
    scene.review("detail");
    QJsonObject settled;
    for (int step = 0; step < 240; ++step) {
        settled = scene.sample(100 + step / 60.);
    }
    const auto stats = settled["stats"].toObject();
    const auto left = stats["topLeft"].toArray();
    const auto right = stats["topRight"].toArray();
    if (left.size() != 2 || right.size() != 2 || left[1] != right[1]) {
        qCritical() << "Portrait album did not settle into a front view" << stats;
        return false;
    }
    scene.resize(1920, 1080);
    scene.setMode("detail");
    for (int step = 0; step < 240; ++step) {
        settled = scene.sample(110 + step / 60.);
    }
    const auto landscape = settled["stats"].toObject();
    if (landscape["topLeft"].toArray()[1] == landscape["topRight"].toArray()[1]) {
        qCritical() << "Portrait front view changed the landscape camera";
        return false;
    }
    app.hud.closeModal();
    app.hud.draw({{"mode", "boot"}}, 1920, 100);
    if (app.hud.playerBounds || !app.hud.state()["playerBounds"].isNull()) {
        qCritical() << "Hidden player retained its input shield";
        return false;
    }
    return true;
}
}

#ifdef Q_OS_DARWIN
/** 缓存命中仍须更新矩阵；身份、材质和模板变化不能串用上一代描述。 */
static bool checkCardMaterialCache() {
    NativeCards cached;
    const QJsonObject material{{"color", QJsonArray{.1, .2, .3}},
                               {"attenuation", QJsonArray{.8, .7, .6}},
                               {"transmission", .5},
                               {"thickness", .02}};
    QJsonArray local;
    for (int i = 0; i < 16; ++i) {
        local.append(i % 5 == 0 ? 1. : 0.);
    }
    local[12] = 2.;
    const QJsonObject part{{"base", material},     {"high", material},          {"low", material},
                           {"localMatrix", local}, {"name", "Frosted_Polymer"}, {"partIndex", 1},
                           {"castShadow", true}};
    QJsonObject card{{"id", 2}, {"musicKey", "first"}, {"selected", true}};
    double state[20]{};
    for (int i = 0; i < 16; ++i) {
        state[i] = i % 5 == 0 ? 1. : 0.;
    }
    state[16] = 1;
    state[17] = .7;
    for (int phase = 0; phase < 12; ++phase) {
        state[12] += 3;
        if (phase == 2) {
            state[16] = .25;
        } else if (phase == 3) {
            state[17] = .2;
        } else if (phase == 4) {
            state[18] = 1;
        } else if (phase == 5) {
            state[19] = .8;
        } else if (phase == 6) {
            card["musicKey"] = "second";
            card["selected"] = false;
        } else if (phase == 7) {
            card["shadowOnly"] = true;
        }
        const auto revision = phase < 8 ? 1 : 2;
        QJsonObject nextPart = part;
        if (revision == 2) {
            nextPart["name"] = "Changed";
            nextPart["high"] = QJsonObject();
        }
        const QJsonObject input{{"appearanceRevision", revision},
                                {"actorTemplate", QJsonArray{nextPart}},
                                {"actors", phase == 10 ? QJsonArray() : QJsonArray{card}},
                                {"globalSubdued", phase < 9 ? .1 : .9}};
        const QByteArray bytes =
            phase == 10 ? QByteArray() : QByteArray(reinterpret_cast<const char *>(state), sizeof(state));
        auto result = input;
        auto reference = input;
        NativeCards fresh;
        SceneDrawBuffers buffers;
        SceneDrawBuffers expected;
        if (!cached.expand(result, bytes, buffers).isEmpty() ||
            !fresh.expand(reference, bytes, expected).isEmpty() || result != reference ||
            buffers.keys() != expected.keys()) {
            qCritical() << "Card cache retained stale draw state" << phase;
            return false;
        }
        for (auto it = buffers.cbegin(); it != buffers.cend(); ++it) {
            if (it->matrices != expected[it.key()].matrices || it->ids != expected[it.key()].ids) {
                qCritical() << "Card cache lost current transform or identity" << phase;
                return false;
            }
        }
    }
    return true;
}

#endif
namespace {
/** 同一控制器跨比例回归：桌面快照不变，窄屏命中与输入使用一致坐标。 */
bool checkResponsiveHud(const QString &root, Glyphs &glyphs, const QJsonObject &content) {
    ResponsiveHudLayout policy;
    for (const double aspect : {.54, .99, 1., 1.01, .999, 1.}) {
        policy.resize(1080 * aspect);
        if (policy.compact() != (aspect < 1)) {
            qCritical() << "Responsive layout must follow width < height" << aspect;
            return false;
        }
    }

    Host host(root, true);
    std::unique_ptr<MusicLibrary> music(createTestMusicLibrary(&host, "netease", content));
    HudSceneActions scene;
    scene.mode = [](QString) {};
    scene.pointer = [](QString, double, double, double) {};
    NativeHud hud(&host, &glyphs, music.get(), scene);
    hud.reduced = true;
    const QJsonObject frame{{"mode", "archive"}, {"detail", 1}, {"selected", 0}};
    hud.draw(frame, 1920, 50);
    const auto desktopCommands = hud.commands;
    const auto desktopHits = hud.hits;
    constexpr double width = 393. * 1080 / 852;
    hud.draw(frame, width, 50);
    if (!hud.state()["compactLayout"].toBool() || !hasAction(hud.hits, "open") ||
        hasAction(hud.hits, "column-prev") || hasAction(hud.hits, "column-next") ||
        !hasAction(hud.hits, "player:next")) {
        return false;
    }
    const auto captureRoot = qEnvironmentVariable("RHINE_HUD_CAPTURE_DIR");
    const auto capture = [&](const QString &name) {
        if (captureRoot.isEmpty()) {
            return;
        }
        QDir().mkpath(captureRoot);
        QImage image(393, 852, QImage::Format_ARGB32_Premultiplied);
        image.fill(QColor("#eeece4"));
        QPainter painter(&image);
        painter.scale(852. / 1080, 852. / 1080);
        glyphs.commands(painter, hud.commands, [&host](QString key) { return host.image(key); });
        painter.end();
        image.save(captureRoot + "/" + name + ".png");
    };
    const auto validHits = [&] {
        for (const auto &value : hud.hits) {
            const auto target = value.toObject();
            const QRectF area(target["x"].toDouble(), target["y"].toDouble(), target["width"].toDouble(),
                              target["height"].toDouble());
            if (!QRectF(0, 0, width + .01, 1080.01).contains(area) || area.width() <= 0 ||
                area.height() <= 0 || !target["fixed"].toBool()) {
                return false;
            }
        }
        return true;
    };
    if (!validHits()) {
        return false;
    }
    // 四条槽位不覆盖底栏，选中行始终位于第二条。
    const double listTop = hud.state()["archiveListY"].toDouble();
    const auto selectedHit = getHit(hud.hits, "open");
    const double unit = width / 393.;
    const double playerTop = hud.state()["playerBounds"].toObject()["y"].toDouble();
    if (std::abs(selectedHit["y"].toDouble() - (listTop + 48 * unit)) > .01 || listTop < 540 ||
        listTop + 4 * 48 * unit > playerTop + .01) {
        qCritical() << "Archive slots overlap the scene or player";
        return false;
    }
    capture("archive");
    bool brand = false;
    for (const auto &value : hud.commands) {
        const auto op = value.toArray();
        if (op[0] == "text" && op[1] == music->libraryName()) {
            brand = brand || (op[3] == 123 && op[4] == 23 && op[5] == "bold");
        }
    }
    const auto mini = hud.state()["playerBounds"].toObject();
    if (!brand || std::abs(mini["height"].toDouble() - 144 * width / 393) > 0.01) {
        return false;
    }
    // 底部保留 34 pt 手势区，导航命中不得进入系统的小白条区域。
    for (const auto &value : hud.hits) {
        const auto hit = value.toObject();
        if (hit["y"].toDouble() + hit["height"].toDouble() > (852 - 34) * width / 393 + .01) {
            qCritical() << "Mobile control entered the bottom gesture area" << hit;
            return false;
        }
    }
    for (const auto &route : {"player:toggle", "player:next", "player:detail"}) {
        if (!hasAction(hud.hits, route)) {
            return false;
        }
    }
    for (const auto &route :
         {"player:prev", "player:mode", "player:open", "music:like-current", "player:lyrics"}) {
        if (hasAction(hud.hits, route)) {
            qCritical() << "Mini player retained a full-page control" << route;
            return false;
        }
    }
    for (const auto &value : hud.hits) {
        const auto hit = value.toObject();
        const auto action = hit["action"].toString();
        // 页头栏目 tab 是固定控件，其余控件必须在 138 pt 以下。
        const bool headerControl = action == "mobile:play-archive" || action == "column-prev" ||
                                   action == "column-next" || action.startsWith("mobile:source:");
        if (hit["y"].toDouble() < 138 * width / 393 && !headerControl) {
            qCritical() << "Unexpected control above the mobile header" << action;
            return false;
        }
    }
    for (const auto &value : hud.commands) {
        const auto op = value.toArray();
        if (op[0] == "text" && (op[1].toString().startsWith("FILE NUMBER") || op[1] == "REFERENCE AREA")) {
            return false;
        }
        if (op[0] == "text" && op[1] == "资料库" && op[4] == 13) {
            const auto bounds = glyphs.bounds("资料库", 13, op[5].toString());
            const auto target = getHit(hud.hits, "home");
            const double center = op[2].toDouble() + bounds["x"].toDouble() + bounds["width"].toDouble() / 2;
            if (std::abs(center * width / 393 - target["x"].toDouble() - target["width"].toDouble() / 2) >
                .01) {
                return false;
            }
        }
    }
    hud.draw(frame, 1920, 50);
    if (hud.commands != desktopCommands || hud.hits != desktopHits || hud.state()["compactLayout"].toBool()) {
        qCritical() << "Responsive round trip changed desktop HUD";
        return false;
    }
    music->player.state["playing"] = false;
    hud.draw(frame, width, 50);
    if (getHit(hud.hits, "player:toggle")["label"] != "播放") {
        return false;
    }
    music->player.state["playing"] = true;
    // 主界面 tab 列表：滚动应切换固定槽位上的选中项。
    hud.draw(frame, width, 50);
    const int beforeScroll = hud.state()["archiveIndex"].toInt();
    const auto selectedTitle = music->libraryItems()[beforeScroll].toObject()["title"].toString();
    const auto selectedRowY = [&] {
        for (const auto &value : hud.commands) {
            const auto op = value.toArray();
            if (op[0] == "text" && op[1] == selectedTitle && op[4] == 18) {
                return op[3].toDouble();
            }
        }
        return -1.;
    };
    hud.action("mobile:archive-begin");
    const double originalY = selectedRowY();
    hud.wheel(width / 2, 700, -1, 0, 8);
    hud.draw(frame, width, 50.01);
    if (originalY < 0 || std::abs(selectedRowY() - originalY + 8 / (width / 393)) > .01) {
        qCritical() << "Archive drag rounded away sub-row finger movement";
        return false;
    }
    hud.action("mobile:archive-release");
    hud.draw(frame, width, 50.02);
    hud.draw(frame, width, 50.3);

    hud.wheel(width / 2, 700, -120, 1, 128);
    hud.draw(frame, width, 60);
    if (hud.state()["archiveIndex"].toInt() == beforeScroll) {
        qCritical() << "Mobile archive scroll did not move the fixed slot selection";
        return false;
    }
    // 重绘不能重复发出旧选择；慢速小幅拖动也必须能跨行，并保持栏目不变。
    const int movedIndex = music->libraryIndex();
    const int selectedLane = music->selectedLane;
    for (int repaint = 0; repaint < 6; ++repaint) {
        hud.draw(frame, width, 61 + repaint);
        if (music->libraryIndex() != movedIndex || music->selectedLane != selectedLane) {
            qCritical() << "Archive repaint changed the requested selection";
            return false;
        }
    }
    int requestedPhysical = -1;
    const auto request =
        QObject::connect(music.get(), &MusicLibrary::selectionRequested,
                         [&requestedPhysical](int physical, QJsonObject) { requestedPhysical = physical; });
    music->selectLibraryIndex(beforeScroll);
    QObject::disconnect(request);
    if (requestedPhysical != music->selectedPhysical) {
        qCritical() << "List selection was not committed to the scene";
        return false;
    }
    hud.draw(frame, width, 69);
    for (int drag = 0; drag < 20; ++drag) {
        hud.wheel(width / 2, 700, -1, 0, 4);
        hud.draw(frame, width, 70 + drag);
    }
    if (music->libraryIndex() == beforeScroll || music->selectedLane != selectedLane) {
        qCritical() << "Slow list drag stalled or switched columns";
        return false;
    }
    // 后续检查仍以原选中项为基准，滚动验证后恢复。
    music->selectLibraryIndex(beforeScroll);
    hud.draw(frame, width, 70);
    for (const QString &page :
         {QString("search"), QString("settings"), QString("discover"), QString("player")}) {
        hud.openModal(page);
        hud.draw(frame, width, 50);
        if (!validHits()) {
            qCritical() << "Out-of-bounds mobile target" << page;
            return false;
        }
        capture(page);
        if (page == "search" || page == "settings" || page == "discover") {
            bool opaquePaper = false;
            for (const auto &value : hud.commands) {
                const auto op = value.toArray();
                if (op[0] == "fill" && op[2] == 0 && op[3] == 0 && op[4] == 393 &&
                    std::abs(op[5].toDouble() - 852) < .01 && op[1].toArray()[3].toDouble() == 1) {
                    opaquePaper = true;
                }
            }
            const auto settingsNav = getHit(hud.hits, "settings");
            if (!opaquePaper || settingsNav["label"] != "设置" || hasAction(hud.hits, "saved")) {
                qCritical() << "Terminal page lost its opaque paper or settings navigation" << page;
                return false;
            }
        }
        if (page == "discover" && !hasAction(hud.hits, "discover:item:3")) {
            qCritical() << "Visible discovery cover lost its clipped hit target";
            return false;
        }
        if (page == "search" &&
            (!hud.state()["compactInputVisible"].toBool() || hud.state()["inputWidth"].toDouble() <= 0)) {
            return false;
        }
        if (page == "player") {
            if (!hasAction(hud.hits, "mobile:queue-modes")) {
                return false;
            }
            hud.action("mobile:queue-modes");
            hud.draw(frame, width, 50);
            for (const QString &mode : {QString("off"), QString("all"), QString("one"), QString("shuffle")}) {
                if (!hasAction(hud.hits, "player:mode:" + mode)) {
                    return false;
                }
            }
            if (!hasAction(hud.hits, "player:clear") || !hasAction(hud.hits, "player:queue:0") ||
                !hasAction(hud.hits, "player:remove:1") || hasAction(hud.hits, "player:remove:0")) {
                return false;
            }
            const auto seek = hud.state()["seek"].toObject();
            if (seek["width"].toDouble() <= 0) {
                return false;
            }
            const auto before = hud.commands;
            hud.wheel(width / 2, 1040, -120);
            hud.draw(frame, width, 50);
            if (hud.commands != before) {
                return false;
            }
            hud.wheel(width / 2, 650, -120, 1, 128);
            hud.draw(frame, width, 50);
            if (hud.commands == before || !validHits()) {
                return false;
            }
        }
        hud.closeModal();
        hud.draw(frame, 1920, 100);
    }
    hud.draw({{"mode", "detail"}, {"detail", 1}}, width, 100);
    capture("song");
    const auto closeSong = getHit(hud.hits, "back");
    const auto moreSong = getHit(hud.hits, "mobile:song-options");
    const auto queueSong = getHit(hud.hits, "player:open");
    if (closeSong["label"] != "关闭播放页面" || closeSong["width"].toDouble() < 56 * width / 393 ||
        moreSong["y"] != queueSong["y"] || moreSong["x"].toDouble() <= queueSong["x"].toDouble()) {
        qCritical() << "Song close and bottom more actions lost their requested placement";
        return false;
    }
    if (!validHits()) {
        return false;
    }
    for (const auto &route : {"player:prev", "player:toggle", "player:next", "player:mode", "player:open",
                              "player:lyrics", "music:like"}) {
        if (!hasAction(hud.hits, route)) {
            qCritical() << "Full player dropped a control" << route;
            return false;
        }
    }
    if (hasAction(hud.hits, "home") || hud.state()["seek"].toObject().isEmpty()) {
        return false;
    }
    if (!hud.state()["volume"].isNull()) {
        qCritical() << "Song HUD retained the removed volume slider";
        return false;
    }
    for (const auto &value : hud.commands) {
        const auto op = value.toArray();
        if (op[0] == "image") {
            return false;
        }
        if (op[0] == "fill" && op[3].toDouble() < 491.99 && op[5].toDouble() > 50) {
            qCritical() << "Full player obscured the live scene";
            return false;
        }
    }
    const auto originalPlaying = music->player.current;
    music->player.current = song(20);
    hud.draw({{"mode", "detail"}, {"detail", 1}}, width, 100);
    if (!hasAction(hud.hits, "music:play") || !hud.state()["seek"].isNull()) {
        return false;
    }
    music->player.current = originalPlaying;
    music->player.lyrics.applyPlaybackSnapshot(
        {{"document", QJsonObject{{"lines", QJsonArray{QJsonObject{{"text", "第一句测试歌词"},
                                                                   {"translation", "第一句译文"},
                                                                   {"startMs", 0}},
                                                       QJsonObject{{"text", "第二句测试歌词"},
                                                                   {"translation", "第二句译文"},
                                                                   {"startMs", 5000}}}}}},
         {"index", 0},
         {"status", "ready"}});
    hud.action("player:lyrics");
    hud.draw({{"mode", "detail"}, {"detail", 1}}, width, 100);
    capture("lyrics");
    bool opaqueLyrics = false;
    for (const auto &value : hud.commands) {
        const auto op = value.toArray();
        if (op[0] == "fill" && op[2] == 0 && op[3] == 0 && op[4] == 393 &&
            std::abs(op[5].toDouble() - 852) < .01 && op[1].toArray()[3] == 1) {
            opaqueLyrics = true;
        }
    }
    for (const auto &value : hud.hits) {
        if (value.toObject()["y"].toDouble() < 60 * width / 393 - .01) {
            qCritical() << "Lyrics control entered the Dynamic Island area";
            return false;
        }
    }
    if (!opaqueLyrics || !hasAction(hud.hits, "player:lyrics-close") || !validHits()) {
        return false;
    }
    hud.action("player:lyrics-close");
    for (const QString &kind : {QString("album"), QString("playlist"), QString("artist")}) {
        music->current =
            MusicData::item(kind, "42", kind == "artist" ? "塞壬唱片-MSR" : "音乐档案", "塞壬唱片-MSR");
        music->tracks = music->player.queue.items();
        hud.draw({{"mode", "detail"}, {"detail", 1}}, width, 100);
        capture(kind);
        if (!validHits()) {
            return false;
        }
        hud.wheel(width / 2, 700, -120, 1, 10000);
        hud.draw({{"mode", "detail"}, {"detail", 1}}, width, 101);
        if (!hasAction(hud.hits, "music:track:19")) {
            qCritical() << "Mobile collection lost tracks beyond the desktop viewport" << kind;
            return false;
        }
    }
    music->current = song(1);
    hud.openModal("saved");
    hud.draw(frame, width, 100);
    capture("mine");
    if (!hasAction(hud.hits, "music:collection:1")) {
        return false;
    }
    hud.action("music:collection:1");
    hud.draw(frame, width, 100);
    capture("liked");
    if (!hasAction(hud.hits, "mobile:play-liked")) {
        return false;
    }
    hud.action("mobile:mine");
    hud.draw(frame, width, 100);
    if (!hasAction(hud.hits, "music:collection:1")) {
        return false;
    }
    hud.openModal("player");
    music->player.current = music->player.queue.items().last().toObject();
    hud.draw(frame, width, 100);
    // 换页后当前尾曲也能作为第一条可见行，移除动作与播放动作保持分离。
    hud.closeModal();
    hud.draw(frame, width, 200);
    hud.openModal("player");
    hud.draw(frame, width, 200);
    if (!hasAction(hud.hits, "player:queue:19") || hasAction(hud.hits, "player:remove:19")) {
        return false;
    }
    hud.modal.clear();
    hud.draw({{"mode", "detail"}, {"viewer", true}, {"detail", 1}}, width, 200);
    if (!hasAction(hud.hits, "viewer:close") || !hasAction(hud.hits, "viewer:reset") || !validHits()) {
        return false;
    }
    hud.draw({{"mode", "boot"}}, width, 200);
    if (!hud.state()["playerBounds"].isNull()) {
        return false;
    }
    // 竖屏播放队列切歌只同步唱片选择，不强制进入详情；显式打开仍保留详情路由。
    music->frame = frame;
    hud.draw(frame, width, 210);
    QString requestedMode;
    const auto modeConnection =
        QObject::connect(music.get(), &MusicLibrary::modeRequested,
                         [&requestedMode](const QString &mode) { requestedMode = mode; });
    const auto nextTrack = music->player.queue.items().first().toObject();
    music->current = song(999);
    music->player.trackSelected(nextTrack);
    QObject::disconnect(modeConnection);
    if (music->current["id"] != nextTrack["id"] || requestedMode == "detail" ||
        music->frame["mode"] != "archive") {
        qCritical() << "Portrait track change unexpectedly opened song details";
        return false;
    }
    // 同一目录跨过八张唱片的物理列边界，页头仍须保持目录所属栏目。
    const int originLane = music->directory->parentLane;
    music->selectDirectory(9, "archive");
    hud.draw(frame, width, 220);
    bool sourceRetained = false;
    for (const auto &value : hud.commands) {
        const auto op = value.toArray();
        if (op[0] == "text" && op[3] == 76 && op[5] == "demibold") {
            sourceRetained = op[1] == music->columns.value(originLane);
        }
    }
    if (!sourceRetained || music->libraryIndex() != 9) {
        qCritical() << "Directory physical lane changed the active source tab";
        return false;
    }
    qInfo()
        << "Responsive HUD design anchors, desktop round trip, mobile input, cards, queue and scroll passed";
    return true;
}
}

/** 页面快照保留到过渡结束，歌词拖动阈值与回弹不会更改正文的选择状态。 */
static bool checkResponsiveTransitions() {
    // 平台差异导致的失败必须能定位到具体断言，不能只留下总数。
    const auto fail = [](const char *reason) {
        qCritical() << "Responsive transition check failed:" << reason;
        return false;
    };
    ResponsiveHudTransition transition;
    QJsonArray commands{QJsonArray{"text", "archive"}};
    QJsonArray hits{QJsonObject{{"action", "open"}}};
    transition.apply(commands, hits, "archive", 10, 1080, false);
    commands = QJsonArray{QJsonArray{"text", "detail"}};
    transition.apply(commands, hits, "detail", 10.1, 1080, false);
    if (transition.active(10.2) || hits.isEmpty() || commands.size() != 1) {
        return fail("tab switch kept a stale snapshot or cleared hits");
    }
    commands = QJsonArray{QJsonArray{"text", "detail"}};
    hits = QJsonArray{QJsonObject{{"action", "back"}}};
    transition.apply(commands, hits, "detail", 10.8, 1080, false);
    if (transition.active(10.8) || hits.isEmpty()) {
        return fail("repeated page apply restarted the transition");
    }
    transition.apply(commands, hits, "lyrics", 11, 1080, false);
    transition.drag(40);
    if (transition.release()) {
        return fail("short lyric drag was treated as a dismissal");
    }
    transition.drag(120);
    if (!transition.release()) {
        return fail("long lyric drag did not reach the dismissal threshold");
    }
    transition.apply(commands, hits, "detail", 12, 1080, false);
    if (!transition.active(12.1) || !hits.isEmpty()) {
        return fail("lyric page did not keep its entrance transition");
    }
    ResponsiveHudLayout indicator;
    indicator.resize(393. * 1080 / 852);
    indicator.setMotion(1, false);
    indicator.tabIndicator("navigation", 0);
    indicator.setMotion(1.1, false);
    if (indicator.tabIndicator("navigation", 100) != 0) {
        return fail("tab indicator skipped its first frame");
    }
    indicator.setMotion(1.2, false);
    const double middle = indicator.tabIndicator("navigation", 100);
    if (middle <= 0 || middle >= 100 || !indicator.animating(1.2)) {
        return fail("tab indicator did not animate between slots");
    }
    if (std::abs(indicator.tabIndicator("navigation", 30) - middle) > .001) {
        return fail("tab indicator retarget changed the sampled frame");
    }
    ResponsiveHudTransition synchronized;
    synchronized.apply(commands, hits, ":archive:1", 20, 1080, false, 0);
    synchronized.apply(commands, hits, ":detail:track", 20.1, 1080, false, 0);
    synchronized.apply(commands, hits, ":detail:track", 21, 1080, false, .3);
    if (!synchronized.active(21.1)) {
        return fail("scene-follow transition ended before the scene settled");
    }
    synchronized.apply(commands, hits, ":detail:track", 21.2, 1080, false, 1);
    if (synchronized.active(21.7)) {
        return fail("scene-follow transition outlived the scene progress");
    }
    return true;
}

bool runNativeHudChecks(const QString &root, Glyphs &glyphs) {
    Host host(root, true);
    const auto content = QJsonDocument::fromJson(host.read("slots.json").toUtf8()).object();
    // 单项检查失败时输出名称，避免回归报告只剩总数而无法定位。
    const auto record = [](const char *name, bool passed) {
        if (!passed) {
            qCritical() << "Native HUD check failed:" << name;
        }
        return passed;
    };
    bool ok = record("responsive transitions", checkResponsiveTransitions());
    ok &= record("playlist sorting", checkSorting(root, glyphs, content));
    ok &= record("responsive hud", checkResponsiveHud(root, glyphs, content));
#ifdef Q_OS_DARWIN
    ok &= record("card material cache", checkCardMaterialCache());
#endif
    ok &= record("collection card", checkCollectionCard(root, glyphs, content));
    ok &= record("album track selection", checkAlbumTrackSelection(root, glyphs, content));
    ok &= record("player bar", checkPlayerBar(glyphs));
    ok &= record("player input", checkPlayerInput(root, glyphs, content));
    {
        // 快速切换可见页时，迟到的封面不能重新写回新页；只保留当前页的键。
        QTemporaryDir directory;
        QImage red(24, 24, QImage::Format_RGB32);
        red.fill(Qt::red);
        QImage green(24, 24, QImage::Format_RGB32);
        green.fill(Qt::green);
        const auto redPath = directory.path() + "/first.png";
        const auto greenPath = directory.path() + "/second.png";
        if (!directory.isValid() || !red.save(redPath) || !green.save(greenPath)) {
            qCritical() << "Cannot prepare discovery artwork fixture";
            return false;
        }
        DiscoverArtwork artwork(&host);
        const auto first = QUrl::fromLocalFile(redPath).toString();
        const auto second = QUrl::fromLocalFile(greenPath).toString();
        artwork.show("old-account", {first});
        artwork.show("new-account", {second});
        QElapsedTimer elapsed;
        elapsed.start();
        while (artwork.image(second).isEmpty() && elapsed.elapsed() < 3000) {
            QCoreApplication::processEvents();
            QThread::msleep(5);
        }
        if (!artwork.image(first).isEmpty() || host.image(artwork.image(second)).isNull()) {
            qCritical() << "Discovery artwork accepted stale data or lost the current image";
            ok = false;
        }
        artwork.show("new-account", {});
        if (!artwork.image(second).isEmpty()) {
            qCritical() << "Discovery artwork retained a hidden-page image";
            ok = false;
        }
    }
    int testCount = 0;

    // 测试所有平台和主题组合
    for (const auto &provider : {QString("netease"), QString("qq"), QString("kugou")}) {
        for (const bool dark : {false, true}) {
            testCount++;

            MusicLibrary *music = createTestMusicLibrary(&host, provider, content);
            HudSceneActions scene;
            QString requestedMode;
            scene.mode = [&](QString mode) { requestedMode = mode; };
            scene.theme = [](bool) {};
            NativeHud hud(&host, &glyphs, music, scene);
            hud.dark = dark;
            hud.themeMode = dark ? "dark" : "light";
            hud.motion.set(true, 0, true);

            // === 测试 1: 基础面板渲染 ===
            QJsonObject archiveFrame{{"mode", "archive"}, {"selected", 0}, {"detail", 1}, {"viewer", false}};
            hud.draw(archiveFrame, 1920, 50);

            // 封面与名称共享歌词入口，动作必须沿用现有页面迁移。
            const auto lyricsTarget = getHit(hud.hits, "player:lyrics");
            hud.action(lyricsTarget["action"].toString());
            if (lyricsTarget.isEmpty() || !hud.lyricsMode || requestedMode != "detail") {
                qCritical() << "Player song target failed to open lyrics";
                ok = false;
            }
            hud.lyricsMode = false;
            hud.draw(archiveFrame, 1920, 50);

            if (hud.commands.isEmpty()) {
                qCritical() << "Archive panel commands empty" << provider << (dark ? "dark" : "light");
                ok = false;
            }
            if (hud.hits.isEmpty()) {
                qCritical() << "Archive panel hits empty" << provider << (dark ? "dark" : "light");
                ok = false;
            }

            // 关闭遮罩必须恢复原绘制和命中；开启后只增加一个右侧遮罩。
            hud.action("archive-mask:0");
            hud.draw(archiveFrame, 1920, 50);
            const auto unmaskedCommands = hud.commands;
            const auto unmaskedHits = hud.hits;
            hud.action("archive-mask:100");
            hud.draw(archiveFrame, 1920, 50);
            int maskCount = 0;
            QJsonArray maskCommand;
            for (const auto &command : hud.commands) {
                const auto values = command.toArray();
                if (values.first() == "right-mask") {
                    ++maskCount;
                    maskCommand = values;
                }
            }
            if (maskCount == 1) {
                const auto maskStart = maskCommand.at(2).toDouble();
                const auto maskEnd = maskStart + maskCommand.at(3).toDouble();
                const auto discoverLeft = getHit(hud.hits, "discover")["x"].toDouble() + 10;
                const auto expectedEnd = discoverLeft;
                // 默认回归检查遮罩职责，不冻结渐变宽度、采样像素或渲染器的透明度舍入。
                const auto placed =
                    maskStart >= 0 && maskStart < maskEnd && std::abs(maskEnd - expectedEnd) <= 0.01;
                const auto color = maskCommand.at(1).toArray();
                const auto valid = color.size() >= 4 && color.at(3).toDouble() == 1 &&
                                   maskCommand.at(4).toDouble() >= maskEnd &&
                                   maskCommand.at(5).toDouble() > 0;
                if (!placed || !valid) {
                    qCritical() << "Mask must cover the right side from the discover entry";
                    ok = false;
                }
            }
            hud.action("archive-mask:0");
            hud.draw(archiveFrame, 1920, 50);
            if (maskCount != 1 || hud.commands != unmaskedCommands || hud.hits != unmaskedHits) {
                qCritical() << "Information mask did not restore original HUD";
                ok = false;
            }
            hud.action("archive-mask:150");
            if (hud.archiveMaskStrength != 100) {
                qCritical() << "Mask strength exceeded upper bound";
                ok = false;
            }
            hud.action("archive-mask:-10");
            if (hud.archiveMaskStrength != 0) {
                qCritical() << "Mask strength exceeded lower bound";
                ok = false;
            }
            hud.action("archive-mask:50");
            const auto originalItem = music->current;
            for (const auto &kind : {"song", "playlist", "album", "artist"}) {
                music->current["kind"] = kind;
                hud.draw(archiveFrame, 1920, 50);
                int informationMasks = 0;
                for (const auto &command : hud.commands) {
                    if (command.toArray().first() == "right-mask") {
                        ++informationMasks;
                    }
                }
                if (informationMasks != 1) {
                    qCritical() << "Information mask missing for archive kind" << kind;
                    ok = false;
                }
            }
            music->current = originalItem;

            // === 测试 2: Settings 面板功能 ===
#ifdef Q_OS_DARWIN
            // Apple 的帧生成行只在 MetalFX 能力可用时出现；测试里先落一份可用快照。
            RhineFg::publishCapability(true, true, true);
#endif
            hud.openModal("settings");
            hud.draw(archiveFrame, 1920, 50);
            const auto settingsCloseHit = getHit(hud.hits, "close-modal");
            // 验证 settings 面板渲染
            if (!hasAction(hud.hits, "close-modal")) {
                qCritical() << "Settings panel missing close button" << provider << (dark ? "dark" : "light");
                ok = false;
            }

            if (!hasAction(hud.hits, "window:fullscreen") || hasAction(hud.hits, "music:project-home")) {
                qCritical() << "Settings section order failed" << provider << dark;
                ok = false;
            }

            // Schema 的 setting:<id>:<value> 路由必须真实更新 HUD 缓存与场景主题。
            const bool settingsInitialDark = hud.dark;
            hud.action("setting:theme:dark");
            if (!hud.dark) {
                qCritical() << "Schema theme setting did not switch to dark";
                ok = false;
            }
            hud.action("setting:theme:light");
            if (hud.dark) {
                qCritical() << "Schema theme setting did not switch to light";
                ok = false;
            }
            hud.action(settingsInitialDark ? "setting:theme:dark" : "setting:theme:light");
            hud.draw(archiveFrame, 1920, 50);

            const QStringList requiredSettings{"theme",
                                               "motion",
                                               "startup-animation",
                                               "detail-autoplay",
                                               "single-play-mode",
                                               "quality",
                                               "disc-rotation",
                                               "performance:toggle",
                                               "update:check",
                                               "replay",
                                               "settings:restore-defaults"};
            QStringList reachableSettings = requiredSettings;
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
            // 关闭行为只在持有托盘入口的桌面平台出现。
            reachableSettings.append("close-behavior");
#endif
#ifdef Q_OS_DARWIN
            // 帧生成开关仅 Apple 可见；能力可用时标题区应能命中切换动作。
            reachableSettings.append("fg");
#endif
            QSet<QString> visibleSettings;
            for (double offset = 0;; offset += 400) {
                hud.settingsScroll = std::min(offset, hud.settingsScrollMaximum());
                hud.draw(archiveFrame, 1920, 50);
                for (const auto &value : hud.hits) {
                    visibleSettings.insert(value.toObject()["action"].toString());
                }
                if (hud.settingsScroll == hud.settingsScrollMaximum()) {
                    break;
                }
            }
            for (const auto &setting : reachableSettings) {
                if (!visibleSettings.contains(setting)) {
                    qCritical() << "Missing reachable setting:" << setting << provider << dark;
                    ok = false;
                }
            }
#ifdef Q_OS_DARWIN
            // Apple 默认同步呈现；设置页仍隐藏该行，诊断覆盖由启动配置负责。
            if (hud.vsync != RhineFg::metalVSyncEnabled() || visibleSettings.contains("vsync")) {
                qCritical() << "Apple platforms should hide the vsync setting" << provider << dark;
                ok = false;
            }
#endif

            const QStringList projectActions{"project-home",      "project-author",  "project-player",
                                             "project-kugou",     "project-rhine",   "project-lyricsx",
                                             "project-lyricskit", "project-lyrimuse"};
            // 链接应可滚动到达；列数、按钮高度和间距属于可调整的视觉设计。
            for (const auto &action : projectActions) {
                if (!visibleSettings.contains("music:" + action)) {
                    qCritical() << "Missing reachable project link:" << action << provider << dark;
                    ok = false;
                }
            }

            // 滚动回顶部继续其他测试
            {
                const auto bounds = hud.modalBounds(1920);
                hud.wheel(bounds.center().x(), bounds.top() + 500, 120, -1, -10000.);
                hud.draw(archiveFrame, 1920, 50);
            }

            // === 测试 3: 设置项切换功能 ===
            const bool initialStartupAnim = hud.startupAnimation;
            hud.action("startup-animation");
            const bool toggledStartupAnim = hud.startupAnimation;
            hud.action("startup-animation");
            const bool restoredStartupAnim = hud.startupAnimation;

            if (initialStartupAnim == toggledStartupAnim || restoredStartupAnim != initialStartupAnim) {
                qCritical() << "Startup animation toggle failed" << provider << (dark ? "dark" : "light");
                ok = false;
            }

            const auto startupPreference = host.preference("startup-animation");
            hud.action("replay");
            if (requestedMode != "boot" || !hud.modal.isEmpty() || hud.closing ||
                hud.startupAnimation != initialStartupAnim ||
                host.preference("startup-animation") != startupPreference) {
                qCritical()
                    << "Manual initialization must close settings without changing startup preference";
                ok = false;
            }
            hud.openModal("settings");
            hud.draw(archiveFrame, 1920, 50);

            // === 测试 4: 设置面板滚动功能 ===
            const auto bounds = hud.modalBounds(1920);

            // 向下滚动到底部
            hud.wheel(bounds.center().x(), bounds.top() + 500, -120, 1, 10000.);
            hud.draw(archiveFrame, 1920, 50);

            // 验证滚动到最大值
            const bool atEnd = hud.settingsScroll == hud.settingsScrollMaximum();
            if (!atEnd) {
                qCritical() << "Settings scroll to bottom failed" << provider << (dark ? "dark" : "light")
                            << "scroll:" << hud.settingsScroll << "max:" << hud.settingsScrollMaximum();
                ok = false;
            }

            // 验证标题固定、内容裁剪
            bool headerFixed = false;
            bool contentClipped = true;
            for (const auto &value : hud.hits) {
                const auto hit = value.toObject();
                const auto action = hit["action"].toString();
                if (action == "close-modal") {
                    headerFixed = hit == settingsCloseHit;
                } else if (!action.startsWith("settings:scroll-") && !hit["fixed"].toBool()) {
                    const double hitTop = hit["y"].toDouble();
                    const double hitBottom = hitTop + hit["height"].toDouble();
                    const double viewportTop = bounds.top() + NativeHud::SettingsViewportTop;
                    const double viewportBottom = bounds.top() + NativeHud::SettingsViewportBottom;
                    contentClipped &= (hitTop >= viewportTop && hitBottom <= viewportBottom);
                }
            }

            if (!headerFixed) {
                qCritical() << "Settings header not fixed" << provider << (dark ? "dark" : "light");
                ok = false;
            }
            if (!contentClipped) {
                qCritical() << "Settings content not clipped" << provider << (dark ? "dark" : "light");
                ok = false;
            }

            // 向上滚动回顶部
            hud.wheel(bounds.center().x(), bounds.top() + 500, 120, -1, -10000.);
            const bool atStart = hud.settingsScroll == 0;
            if (!atStart) {
                qCritical() << "Settings scroll to top failed" << provider << (dark ? "dark" : "light");
                ok = false;
            }

            // 平滑滚轮的后续帧只补送距离，不再带有角度增量，仍需继续滚动。
            hud.wheel(bounds.center().x(), bounds.top() + 500, 0, 0, 75.);
            if (hud.settingsScroll != 75.) {
                qCritical() << "Settings smoothed wheel frame failed" << provider << (dark ? "dark" : "light")
                            << "scroll:" << hud.settingsScroll;
                ok = false;
            }

            // 测试滚动按钮
            hud.action("settings:scroll-down");
            const bool scrolledDown = hud.settingsScroll > 0;
            if (!scrolledDown) {
                qCritical() << "Settings scroll-down action failed" << provider << (dark ? "dark" : "light");
                ok = false;
            }

            // 重新打开 settings 应该重置滚动位置
            hud.openModal("settings");
            const bool reset = hud.settingsScroll == 0;
            if (!reset) {
                qCritical() << "Settings scroll reset failed" << provider << (dark ? "dark" : "light");
                ok = false;
            }

            // === 测试 5: Detail 面板 ===
            QJsonObject detailFrame{{"mode", "detail"}, {"selected", 1}, {"detail", 1}, {"viewer", false}};
            hud.modal.clear();
            hud.draw(detailFrame, 1920, 50);

            // 卡片改版只能调整内部；不同宽度与标签页仍沿用原外框和动作路由。
            for (const double stageWidth : {1280.0, 1920.0, 2560.0}) {
                const auto left = stageWidth * 0.56 - 24;
                const QRectF expected(left, 260, stageWidth - left - 35, 696);
                if (hud.detailBounds(stageWidth) != expected) {
                    qCritical() << "Song card changed its external geometry" << stageWidth;
                    ok = false;
                }
                for (const auto &detailTab : {"overview", "notes", "history"}) {
                    hud.tab = detailTab;
                    hud.draw(detailFrame, stageWidth, 50);
                    const QStringList cardActions{"music:play",     "music:enqueue", "music:play-next",
                                                  "music:artist:0", "tab:overview",  "tab:notes",
                                                  "tab:history"};
                    for (const auto &action : cardActions) {
                        const auto target = getHit(hud.hits, action);
                        const QRectF rectangle(target["x"].toDouble(), target["y"].toDouble(),
                                               target["width"].toDouble(), target["height"].toDouble());
                        if (target.isEmpty() || !expected.contains(rectangle)) {
                            qCritical() << "Song card lost or moved an action outside its bounds" << action;
                            ok = false;
                        }
                    }
                    if (hud.tab == "history" && !hasAction(hud.hits, "music:album-track:0")) {
                        qCritical() << "Song card lost same-album navigation";
                        ok = false;
                    }
                    const auto playTarget = getHit(hud.hits, "music:play");
                    const auto queueTarget = getHit(hud.hits, "music:enqueue");
                    const auto tabTarget = getHit(hud.hits, "tab:overview");
                    if (playTarget["height"] != queueTarget["height"] ||
                        queueTarget["y"].toDouble() + queueTarget["height"].toDouble() >
                            tabTarget["y"].toDouble()) {
                        qCritical() << "Song button rows differ in height or overlap the album tabs";
                        ok = false;
                    }
                }
            }
            hud.tab = "overview";
            hud.draw(detailFrame, 1920, 50);

            // 入队反馈必须对应真实结果；下一首同时完成入队或移动，且不打断当前播放。
            const auto savedQueue = music->player.queue.items();
            const auto savedPlaying = music->player.current;
            const auto savedIndex = music->player.queue.index();
            const auto savedSelection = music->current;
            music->player.queue.replace(QJsonArray{song(1), song(2), song(3)});
            music->player.current = song(2);
            music->player.queue.select(1);
            music->current = song(4);
            const auto playbackState = music->player.state;
            hud.action("music:enqueue");
            hud.draw(detailFrame, 1920, 50);
            if (music->player.queue.at(music->player.queue.size() - 1)["id"] != "4" ||
                !getHit(hud.hits, "music:enqueue")["label"].toString().contains("已加入队列")) {
                qCritical() << "Queue append did not confirm the actual result";
                ok = false;
            }
            hud.action("music:play-next");
            hud.draw(detailFrame, 1920, 50);
            if (music->player.queue.size() != 4 || music->player.queue.at(2)["id"] != "4" ||
                !getHit(hud.hits, "music:play-next")["label"].toString().contains("已设为下一首")) {
                qCritical() << "Play-next did not move an existing item and confirm it";
                ok = false;
            }
            if (provider == "netease" && !dark) {
                const auto waitFeedback = [](int milliseconds) {
                    QElapsedTimer elapsed;
                    elapsed.start();
                    while (elapsed.elapsed() < milliseconds) {
                        QCoreApplication::processEvents();
                        QThread::msleep(5);
                    }
                    QCoreApplication::processEvents();
                };
                // 第二次点击应从头计时；另一个按钮仍按自己的期限恢复。
                waitFeedback(1200);
                hud.action("music:enqueue");
                waitFeedback(1100);
                hud.draw(detailFrame, 1920, 50);
                if (!getHit(hud.hits, "music:enqueue")["label"].toString().contains("已加入队列") ||
                    getHit(hud.hits, "music:play-next")["label"].toString() != "▷ 下一首播放") {
                    qCritical() << "Song action feedback timers interfere with repeated clicks";
                    ok = false;
                }
                waitFeedback(1100);
                hud.draw(detailFrame, 1920, 50);
                if (getHit(hud.hits, "music:enqueue")["label"].toString() != "＋ 加入队列") {
                    qCritical() << "Queue action feedback did not restore its original icon and label";
                    ok = false;
                }
                // 恢复下一个队列断言的前置顺序。
                hud.action("music:play-next");
            }
            music->current = song(5);
            hud.action("music:play-next");
            music->current = song(1);
            hud.action("music:play-next");
            if (music->player.queue.size() != 5 || music->player.queue.index() != 0 ||
                music->player.queue.at(1)["id"] != "1" || music->player.queue.at(2)["id"] != "5" ||
                music->player.current["id"] != "2" || music->player.state != playbackState) {
                qCritical() << "Play-next failed new insertion or preserved-current semantics";
                ok = false;
            }
            music->player.queue.replace(savedQueue);
            music->player.queue.select(savedIndex);
            music->player.current = savedPlaying;
            music->current = savedSelection;

            if (hud.commands.isEmpty()) {
                qCritical() << "Detail panel commands empty" << provider << (dark ? "dark" : "light");
                ok = false;
            }

            // === 测试 6: 其他关键面板存在性检查 ===
            const QStringList criticalPanels = {"search", "login", "player", "confirm"};
            for (const auto &panel : criticalPanels) {
                hud.openModal(panel);
                hud.draw(archiveFrame, 1920, 50);

                if (panel == "login" && provider == "netease") {
                    if (!hasAction(hud.hits, "music:login-method:phone") ||
                        hasAction(hud.hits, "music:login-method:email")) {
                        qCritical() << "NetEase login must offer SMS without email password";
                        ok = false;
                    }
                    hud.action("music:login-method:phone");
                    hud.action("music:login-method:email");
                    if (music->loginMethod != "phone") {
                        qCritical() << "Disabled email login action was accepted";
                        ok = false;
                    }
                }

                if (hud.commands.isEmpty()) {
                    qCritical() << "Panel commands empty:" << panel << provider << (dark ? "dark" : "light");
                    ok = false;
                }
                if (!hasAction(hud.hits, "close-modal") && panel != "player") {
                    qCritical() << "Panel missing close button:" << panel << provider
                                << (dark ? "dark" : "light");
                    ok = false;
                }
            }

            // === 测试 7: 每日推荐资料库入口 ===
            // 固定外框内连续滚动：首屏两个特殊卡加五列方形档案，底部可访问最后一项。
            music->discover->tab = "playlists";
            const auto originalMore = music->discover->more;
            music->discover->more = false;
            hud.openModal("discover");
            for (const double stageWidth : {1280.0, 1920.0, 2560.0}) {
                hud.discoverScroll = 0;
                hud.draw(archiveFrame, stageWidth, 50);
                const auto modalWidth = std::min(1260.0, stageWidth - 100);
                const QRectF expected((stageWidth - modalWidth) / 2, 122, modalWidth, 836);
                if (hud.modalBounds(stageWidth) != expected) {
                    qCritical() << "Discovery redesign changed its external bounds";
                    ok = false;
                }
                QVector<QRectF> cards;
                for (int index = 0; index < 7; ++index) {
                    const auto target = getHit(hud.hits, "discover:item:" + QString::number(index));
                    const QRectF rectangle(target["x"].toDouble(), target["y"].toDouble(),
                                           target["width"].toDouble(), target["height"].toDouble());
                    if (target.isEmpty() || !expected.contains(rectangle)) {
                        qCritical() << "Discovery card missing or outside panel" << index << stageWidth;
                        ok = false;
                    }
                    for (const auto &previous : cards) {
                        if (previous.intersects(rectangle)) {
                            qCritical() << "Discovery item hit targets overlap";
                            ok = false;
                        }
                    }
                    if (index >= 2 && (!cards.isEmpty() && index > 2) && rectangle.y() != cards.last().y()) {
                        qCritical() << "Discovery archive must have five cards per row";
                        ok = false;
                    }
                    cards.append(rectangle);
                }
                if (hasAction(hud.hits, "discover:next") || hasAction(hud.hits, "discover:prev")) {
                    qCritical() << "Discovery content still uses pagination controls";
                    ok = false;
                }
                const auto viewport =
                    DiscoverMusicCard::layout(expected, music->discover->items.size()).viewport;
                // 标题和面板之外的滚动不应移动档案，触控板的连续距离则应精确累计。
                hud.wheel(expected.center().x(), expected.top() + 150, -120, 1, 75.);
                if (hud.discoverScroll != 0) {
                    qCritical() << "Discovery header intercepted archive scrolling";
                    ok = false;
                }
                hud.wheel(viewport.center().x(), viewport.center().y(), 0, 0, 75.);
                if (hud.discoverScroll != 75) {
                    qCritical() << "Discovery lost continuous trackpad distance";
                    ok = false;
                }
                hud.wheel(viewport.center().x(), viewport.center().y(), -120, 1, 10000.);
                hud.draw(archiveFrame, stageWidth, 50);
                const auto last = music->discover->items.size() - 1;
                if (!hasAction(hud.hits, "discover:item:" + QString::number(last)) ||
                    hasAction(hud.hits, "discover:item:0") ||
                    hud.discoverScroll != hud.discoverScrollMaximum) {
                    qCritical() << "Discovery scrolling lost the last archive or retained special cards";
                    ok = false;
                }
                for (const auto &value : hud.hits) {
                    const auto target = value.toObject();
                    if (!target["action"].toString().startsWith("discover:item:")) {
                        continue;
                    }
                    const QRectF rectangle(target["x"].toDouble(), target["y"].toDouble(),
                                           target["width"].toDouble(), target["height"].toDouble());
                    if (!viewport.contains(rectangle)) {
                        qCritical() << "Scrolled archive hit target escaped its viewport";
                        ok = false;
                    }
                }
                hud.wheel(viewport.center().x(), viewport.center().y(), 120, -1, -10000.);
            }
            music->discover->more = originalMore;
            const auto originalFirst = music->discover->items.first();
            const auto originalThird = music->discover->items.at(2);
            const QString coverKey = "file:///rhine-offline/discovery-cover.png";
            QImage wideCover(200, 100, QImage::Format_RGB32);
            wideCover.fill(Qt::green);
            host.fixtureImage(coverKey, wideCover);
            auto covered = originalFirst.toObject();
            covered["cover"] = coverKey;
            music->discover->items[0] = covered;
            const QString squareKey = "file:///rhine-offline/discovery-square.png";
            QImage squareCover(100, 100, QImage::Format_RGB32);
            squareCover.fill(Qt::blue);
            host.fixtureImage(squareKey, squareCover);
            auto squareEntry = originalThird.toObject();
            squareEntry["cover"] = squareKey;
            music->discover->items[2] = squareEntry;
            hud.draw(archiveFrame, 1920, 50);
            bool aspectPreserved = false;
            bool squarePreserved = false;
            bool framedCover = false;
            bool centeredTab = false;
            const auto selectedTab = getHit(hud.hits, "discover:tab:playlists");
            const auto tabCenter = selectedTab["x"].toDouble() + selectedTab["width"].toDouble() / 2;
            for (const auto &value : hud.commands) {
                const auto command = value.toArray();
                if (command.first() == "rotate") {
                    framedCover = std::abs(command.at(1).toDouble() - 0.0872664626) < 0.00001;
                }
                if (command.first() == "text" && command.at(1) == "推荐歌单") {
                    const auto center = command.at(2).toDouble() + glyphs.width("推荐歌单", 12) / 2;
                    centeredTab = std::abs(center - tabCenter) < 0.01;
                }
                if (command.size() == 6 && command.first() == "image" && command.at(1) == squareKey) {
                    squarePreserved = std::abs(command.at(4).toDouble() - command.at(5).toDouble()) < 0.01;
                }
                if (command.size() == 6 && command.first() == "image" && command.at(1) == coverKey) {
                    aspectPreserved =
                        std::abs(command.at(4).toDouble() / command.at(5).toDouble() - 2) < 0.001;
                }
            }
            if (!aspectPreserved || !squarePreserved || !framedCover || !centeredTab) {
                qCritical() << "Discovery cover or centered tabs regressed" << aspectPreserved
                            << squarePreserved << framedCover << centeredTab;
                ok = false;
            }
            music->discover->items[0] = originalFirst;
            music->discover->items[2] = originalThird;
            music->discover->tab = "daily";
            hud.openModal("discover");
            hud.draw(archiveFrame, 1920, 50);
            if (!hasAction(hud.hits, "discover:open")) {
                qCritical() << provider << "daily discover missing library button"
                            << (dark ? "dark" : "light");
                ok = false;
            }
            hud.action("discover:open");
            if (!music->directory || music->directory->songs.size() != music->discover->items.size()) {
                qCritical() << provider << "daily discover did not open as playlist directory"
                            << (dark ? "dark" : "light");
                ok = false;
            }
            music->leaveDirectory(false);

            // === 测试 8: 分类歌单列表选择 ===
            music->discover->tab = "categories";
            music->discover->category = "1";
            music->discover->categories = QJsonArray{
                QJsonObject{{"id", "1"}, {"name", "甲"}},
                QJsonObject{{"id", "2"}, {"name", "乙"}},
            };
            hud.openModal("discover");
            hud.draw(archiveFrame, 1920, 50);
            if (!hasAction(hud.hits, "discover:categories")) {
                qCritical() << provider << "category selector missing" << (dark ? "dark" : "light");
                ok = false;
            }
            hud.action("discover:categories");
            hud.draw(archiveFrame, 1920, 50);
            if (!hasAction(hud.hits, "discover:category:1") || !hasAction(hud.hits, "discover:category:2")) {
                qCritical() << provider << "category list missing choices" << (dark ? "dark" : "light");
                ok = false;
            }
            if (provider == "netease") {
                music->discover->categories = {};
                for (int index = 0; index < NativeHud::CategoryPageSize; ++index) {
                    music->discover->categories.append(QJsonObject{{"id", "edge-" + QString::number(index)},
                                                                   {"name", QString::number(index)}});
                }
                hud.categoryPage = 0;
                hud.action("discover:category-page:next");
                hud.draw(archiveFrame, 1920, 50);
                if (!hasAction(hud.hits, "discover:category:edge-39")) {
                    qCritical() << "Discovery category pagination omitted the final entry after All";
                    ok = false;
                }
            }

            // 队列卡片
            ++testCount;
            hud.openModal("player");
            const auto queueBounds = hud.modalBounds(1920);
            hud.draw(archiveFrame, 1920, 50);
            if (queueBounds != QRectF(330, 122, 1260, 836)) {
                qCritical() << "Queue card changed geometry or exposed transport controls";
                ok = false;
            }
            for (const auto &mode : {QString("off"), QString("all"), QString("one"), QString("shuffle")}) {
                const auto action = "player:mode:" + mode;
                if (!hasAction(hud.hits, action)) {
                    qCritical() << "Queue playback mode missing" << mode;
                    ok = false;
                }
                hud.action(action);
                if (music->player.mode != mode) {
                    qCritical() << "Queue mode selection did not reach player" << mode;
                    ok = false;
                }
            }
            for (const auto &value : hud.hits) {
                const auto hit = value.toObject();
                const QRectF rect(hit["x"].toDouble(), hit["y"].toDouble(), hit["width"].toDouble(),
                                  hit["height"].toDouble());
                // 底部全局播放栏仍保留，不能把它误判为卡片内部控件。
                if (rect.top() > queueBounds.bottom()) {
                    continue;
                }
                if (!queueBounds.contains(rect) || hit["action"] == "player:toggle" ||
                    hit["action"] == "player:seek") {
                    qCritical() << "Queue action escaped the original card or exposed transport";
                    ok = false;
                }
            }

            const auto captureDirectory = qEnvironmentVariable("RHINE_QUEUE_CAPTURE_DIR");
            if (provider == "netease" && !captureDirectory.isEmpty()) {
                // 等待原弹窗入场结束，截图不能把透明首帧误当成最终界面。
                hud.draw(archiveFrame, 1920, 1000);
                QImage queueImage(1920, 1080, QImage::Format_ARGB32_Premultiplied);
                queueImage.fill(Qt::transparent);
                QPainter painter(&queueImage);
                glyphs.commands(painter, hud.commands, [](QString) { return QImage(); });
                painter.end();
                queueImage.save(captureDirectory + "/queue-card-" + (dark ? "dark" : "light") + ".png");
            }

            // 尾曲也必须出现在首行，不能为了填满七行把它推回页尾。
            QJsonArray localQueue;
            for (const auto &value : music->player.queue.items()) {
                auto track = value.toObject();
                track["provider"] = "local";
                track["url"] = "file:///rhine-queue-test-missing.wav";
                localQueue.append(track);
            }
            music->provider = "local";
            music->api.provider = "local";
            music->player.queue.replace(localQueue);
            const auto lastIndex = music->player.queue.size() - 1;
            music->player.current = music->player.queue.at(lastIndex);
            music->player.queue.select(lastIndex);
            hud.openModal("player");
            hud.draw(archiveFrame, 1920, 1100);
            const auto tailHit = getHit(hud.hits, "player:queue:" + QString::number(lastIndex));
            if (hud.queueOffset != lastIndex || tailHit["y"].toDouble() != queueBounds.y() + 358) {
                qCritical() << "Opening queue did not put the current final track first";
                ok = false;
            }
            hud.queueOffset = 3;
            hud.draw(archiveFrame, 1920, 1150);
            if (hud.queueOffset != 3) {
                qCritical() << "Queue repaint stole manual scrolling";
                ok = false;
            }
            const auto selectedHit = getHit(hud.hits, "player:queue:4");
            const auto removeHit = getHit(hud.hits, "player:remove:4");
            if (selectedHit.isEmpty() || removeHit.isEmpty() ||
                selectedHit["x"].toDouble() + selectedHit["width"].toDouble() > removeHit["x"].toDouble()) {
                qCritical() << "Queue selection and removal targets overlap or are missing";
                ok = false;
            }
            const auto queueBeforeClick = music->player.queue.items();
            const auto modeBeforeClick = music->player.mode;
            // 无效本地文件只验证播放分发与索引，不发起真实音乐 API 请求。
            hud.action("player:queue:4");
            if (music->player.queue.index() != 4 ||
                music->player.current != queueBeforeClick.at(4).toObject() ||
                music->player.queue.items() != queueBeforeClick || music->player.mode != modeBeforeClick) {
                qCritical() << "Queue click changed order or did not start the selected track";
                ok = false;
            }
            hud.openModal("player");
            if (hud.queueOffset != 4) {
                qCritical() << "Reopening queue did not follow the new current track";
                ok = false;
            }
            music->player.queue.clear();
            music->player.current = {};
            hud.openModal("player");
            hud.draw(archiveFrame, 1920, 1200);
            if (hud.queueOffset != 0 || hasAction(hud.hits, "player:queue:0")) {
                qCritical() << "Empty queue retained a song target or invalid scroll offset";
                ok = false;
            }

            delete music;
        }
    }

    qInfo() << "Native HUD core functionality tests:" << testCount << (ok ? "passed" : "FAILED");
    return ok;
}

#ifdef RHINE_HUD_REGRESSION_TEST_MAIN
int main(int argc, char **argv) {
    // Windows 的 Qt 日志可能只送到调试器，回归失败必须输出到 CTest 标准错误。
    qInstallMessageHandler([](QtMsgType type, const QMessageLogContext &context, const QString &message) {
        const auto text = qFormatLogMessage(type, context, message).toUtf8();
        std::fprintf(stderr, "%s\n", text.constData());
        std::fflush(stderr);
    });
    QGuiApplication application(argc, argv);
    const auto root = application.arguments().value(1);
    Glyphs glyphs(root);
    return runNativeHudChecks(root, glyphs) ? 0 : 1;
}
#endif
