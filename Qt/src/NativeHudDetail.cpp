#include "NativeHud.h"
#include "CollectionDetailCard.h"
#include "MusicData.h"
#include "SongDetailCard.h"
#include <algorithm>
#include <cmath>

QString NativeHud::body() const {
    const auto item = m_music->current;
    if (m_music->isLocal()) {
        return item["path"].toString() + "\n" + item["format"].toString() + " / " +
               QString::number(item["sampleRate"].toInt()) + " Hz / " +
               QString::number(item["bitrate"].toInt()) + " kbps";
    }
    if (item.isEmpty()) {
        return {};
    }
    if (item["kind"] == "song") {
        if (tab == "overview") {
            const auto wiki = item["wiki"].toString();
            if (!wiki.isEmpty()) {
                return wiki;
            }
            return m_music->detailLoading ? "正在读取歌曲百科…" : "暂无歌曲百科";
        }
        auto date = item["date"].toString();
        auto description = item["description"].toString();
        if (date.isEmpty()) {
            date = "暂无";
        }
        if (description.isEmpty()) {
            description = "暂无专辑介绍";
        }
        return "专辑：" + item["album"].toString() + "\n歌手：" + item["artist"].toString() + "\n发行日期：" +
               date + "\n" + description;
    }
    if (tab == "overview") {
        const auto description = item["description"].toString();
        return description.isEmpty() ? "暂无简介" : description;
    }
    return "编号：" + item["id"].toString() + "\n名称：" + item["title"].toString() + "\n" +
           item["artist"].toString() + "\n已载入 " + QString::number(m_music->tracks.size()) + " 首";
}

void NativeHud::detail(double width, double opacity) {
    auto &music = *m_music;
    const auto item = music.current;
    if (item.isEmpty()) {
        archive(width);
        return;
    }
    if (item["kind"] != "song") {
        container(width, opacity);
        return;
    }
    const auto x = width * 0.56;
    if (lyricsMode && PlaybackQueue::identity(item) != PlaybackQueue::identity(music.player.current)) {
        lyricsMode = false;
    }
    const auto usable = width - x - 59;
    constexpr double gap = 12;
    const auto buttonWidth = (usable - gap * 2) / 3;
    if (!m_responsive.compact()) {
        save();
        alpha(opacity);
        if (!lyricsMode) {
            const auto bounds = detailBounds(width);
            fill(bounds.x(), bounds.y(), bounds.width(), bounds.height(),
                 dark ? QJsonArray{0.08, 0.095, 0.09, 0.96} : QJsonArray{0.973, 0.969, 0.933, 0.96});
        }
        button("← 返回资料库   ESC", 59, 211, 360, 54, "back", 20, "demibold");
        limited(item["id"].toString(), 60, 845, 37, 330);
        text("MUSIC DATABASE", 60, 893, 10);
        text("DRAG TO INSPECT", 60, 917, 10);
        button("查看封面 ↗", 60, 944, 260, 35, "viewer", 14);
        if (lyricsMode) {
            lyricsPanel(x, usable);
            restore();
            return;
        }
    }
    // 控制器只整理真实数据与可用动作，独立卡片组件只负责绘制。
    SongDetailCard::Model card;
    card.x = x;
    card.width = usable;
    card.dark = dark;
    card.local = music.isLocal();
    card.id = item["id"].toString();
    card.title = item["title"].toString();
    const auto titleLines =
        m_responsive.compact() ? QStringList{} : m_glyphs->wrap(card.title, usable, 32, "bold");
    card.titleLines = titleLines.mid(0, 2);
    if (titleLines.size() > 2) {
        card.titleLines[1] += "…";
    }
    card.artist = item["artist"].toString();
    card.album = item["album"].toString();
    card.duration = MusicData::time(item);
    card.tab = tab;
    card.trackCount = music.tracks.size();
    card.playback = "面板内播放";
    if (PlatformFeatures::OfficialPlayback) {
        card.playback = music.isLocal() ? "本地文件 / 面板内播放" : "面板内播放 / 官方入口";
    }
    const auto &player = music.player;
    const bool isCurrent = PlaybackQueue::identity(item) == PlaybackQueue::identity(player.current) &&
                           !player.loading && !player.failed;
    auto quality = isCurrent ? player.actualQuality : QString();
    if (music.isLocal()) {
        quality = MusicPlayer::localQuality(item);
    }
    const auto badgeProvider = music.isLocal() ? QStringLiteral("netease") : music.provider;
    card.badgeKey = "quality:" + badgeProvider + "-" + quality;
    const auto badge = quality.isEmpty() ? QImage() : m_host->image(card.badgeKey);
    if (!badge.isNull()) {
        card.badgeWidth = std::min(22.0 * badge.width() / badge.height(), (usable - gap) / 2 - 12);
    }
    if (!quality.isEmpty()) {
        card.quality = quality == "standard" ? "标准" : "高品质";
    }
    card.primaryActions = {{"▶ 播放歌曲", "music:play"}, {}, {}};
    const auto playlist = openedPlaylistContext();
    const bool hasPlaylistFeedback = m_playlistFeedbackKey == music.uid + ":" + PlaybackQueue::identity(item);
    if (music.canMutate("/like") && (!music.isSiren() || item["kind"] == "song")) {
        bool liked = (music.likedIDs && MusicData::indexOf(*music.likedIDs, item["id"]) >= 0) ||
                     MusicData::indexOfId(music.lists[1], item["id"].toString()) >= 0;
        QString label = liked ? "♥ 已喜欢" : "♡ 喜欢";
        if (music.provider == "qq") {
            const auto state = music.subscriptionStates.value(item["key"].toString(), "unknown");
            liked = state == "subscribed";
            label = liked ? "♥ 已喜欢" : "♡ 喜欢";
            if (state == "unknown") {
                label = "红心 / 核实后切换";
            }
        }
        card.primaryActions[1] = {label, "music:like"};
        QString addLabel = playlist && playlist->contained ? "＋ 加入其他歌单" : "＋ 加入歌单";
        if (hasPlaylistFeedback) {
            addLabel = m_playlistFeedback.value("add", addLabel);
        }
        card.primaryActions[2] = {addLabel, "music:add-to-playlist"};
    }
    card.secondaryActions = {{"＋ 加入队列", "music:enqueue"}, {"▷ 下一首播放", "music:play-next"}, {}};
    if (m_songQueueFeedbackKey == music.uid + ":" + PlaybackQueue::identity(item)) {
        card.secondaryActions[0].label = m_songQueueFeedback.value("enqueue", "＋ 加入队列");
        card.secondaryActions[1].label = m_songQueueFeedback.value("play-next", "▷ 下一首播放");
    }
    if (!item["artists"].toArray().isEmpty()) {
        card.secondaryActions[2] = {"↗ 歌手作品", "music:artist:0"};
    }
    if (!m_responsive.compact()) {
        for (auto &action : card.primaryActions) {
            const auto weight = action.route == "music:play" ? "demibold" : "regular";
            action.label = fit(action.label, 14, buttonWidth - 24, weight);
        }
        for (auto &action : card.secondaryActions) {
            action.label = fit(action.label, 14, buttonWidth - 24);
        }
    }
    const SongDetailCard::Canvas canvas{
        [this](double x, double y, double width, double height, QJsonArray color) {
            fill(x, y, width, height, color);
        },
        [this](QString value, double x, double y, double size, QString weight, QJsonArray color) {
            text(value, x, y, size, weight, 0, color);
        },
        [this](QString value, double x, double y, double size, double width, QString weight) {
            limited(value, x, y, size, width, weight);
        },
        [this](double x, double y, double width, double height, QString action, QString label) {
            hit(x, y, width, height, action, label);
        },
        [this](QString key, double x, double y, double width, double height) {
            image(key, x, y, width, height);
        }};
    if (m_responsive.compact()) {
        m_responsive.setSong(card);
        return;
    }
    SongDetailCard::paint(card, canvas);
    const bool albumTracks = tab == "history";
    if (albumTracks) {
        trackOffset = std::clamp(trackOffset, 0, std::max(0, int(music.tracks.size()) - AlbumTrackRowCount));
        const auto songs = MusicData::slice(music.tracks, trackOffset, AlbumTrackRowCount);
        for (int index = 0; index < songs.size(); ++index) {
            const auto song = songs.at(index).toObject();
            const auto yy = AlbumTrackTop + index * AlbumTrackRowHeight;
            text(MusicData::pad(trackOffset + index + 1), x, yy, 11);
            limited(song["title"].toString() + " / " + song["artist"].toString(), x + 35, yy, 16,
                    usable - 115);
            text(MusicData::time(song), x + usable - 65, yy, 12);
            rule(x, yy + 36, usable, 0.2);
            hit(x, yy - 4, usable, 42, "music:album-track:" + QString::number(trackOffset + index),
                song["title"].toString());
        }
        if (music.tracks.size() > AlbumTrackRowCount) {
            const auto height = AlbumTrackRowCount * AlbumTrackRowHeight - 12;
            auto color = ink();
            color[3] = 0.12;
            fill(x + usable + 10, AlbumTrackTop - 4, 2, height, color);
            const auto thumb = std::max(28.0, height * AlbumTrackRowCount / music.tracks.size());
            const auto fraction = double(trackOffset) / (music.tracks.size() - AlbumTrackRowCount);
            color[3] = 0.6;
            fill(x + usable + 10, AlbumTrackTop - 4 + fraction * (height - thumb), 2, thumb, color);
        }
        if (music.tracks.isEmpty()) {
            text(music.detailLoading ? "正在载入曲目…" : "暂无曲目信息", x, AlbumTrackTop, 17);
        }
    } else {
        const auto lines = m_glyphs->wrap(body(), usable, 16);
        bodyOffset = std::min(bodyOffset, std::max(0, int(lines.size()) - 3));
        for (int index = 0; index < std::min(3, int(lines.size()) - bodyOffset); ++index) {
            text(lines.at(bodyOffset + index), x, 790 + index * 31, 16);
        }
        hit(x, 786, usable, std::min(3, int(lines.size()) - bodyOffset) * 31, "detail:copy",
            "点击复制完整内容");
    }
    rule(x, 898, usable, 0.18);
    if (PlatformFeatures::OfficialPlayback && !music.isLocal()) {
        button(music.provider != "netease" ? music.providerName() + " ↗" : "官方客户端 ↗", x, 910,
               buttonWidth, 44, "music:official", 13);
    }
    if (music.provider == "qq") {
        button("试听片段", x + buttonWidth + gap, 910, buttonWidth, 44, "music:preview", 13);
    }
    if (playlist && playlist->contained) {
        auto label = QStringLiteral("从歌单移除");
        if (hasPlaylistFeedback) {
            label = m_playlistFeedback.value("remove", label);
        }
        button(fit(label, 13, buttonWidth - 12), x + (buttonWidth + gap) * 2, 910, buttonWidth, 44,
               "music:remove-track", 13);
    }
    restore();
}

/** 歌词换文档或宽度时排版；进度更新只采样原生曲线并绘制可见行。 */
void NativeHud::lyricsPanel(double x, double width) {
    auto &player = m_music->player;
    auto &lyrics = player.lyrics;
    auto muted = ink();
    muted[3] = 0.45;
    limited(player.current.value("title").toString(), x, 278, 20, width - 85, "demibold");
    limited(player.current.value("artist").toString(), x, 310, 13, width - 85);
    button("关闭", x + width - 60, 278, 60, 40, "player:lyrics-close", 14);
    if (m_music->isLocal() && player.current.value("provider") == "local") {
        button("歌词来源 ⌃", x + 156, 914, 120, 32, "player:lyrics-sources", 13);
    }
    constexpr double top = 360;
    constexpr double bottom = 889;
    const auto document = lyrics.document();
    const auto lines = document["lines"].toArray();
    if (lines.isEmpty()) {
        save();
        clip(x, top, width, bottom - top);
        const auto plain = document["plainText"].toString();
        auto message = plain.isEmpty() ? lyrics.message : plain;
        if (message.isEmpty()) {
            message = "播放歌曲后显示歌词";
        }
        const auto size = plain.isEmpty() ? 24 : 27;
        const auto rows = m_glyphs->wrap(message, width - 24, size);
        m_lyricsPlainOffset = std::min(m_lyricsPlainOffset, std::max(0, int(rows.size()) - 9));
        for (int index = 0; index < std::min(9, int(rows.size()) - m_lyricsPlainOffset); ++index) {
            text(rows.at(m_lyricsPlainOffset + index), x, top + 55 + index * 48, size, "bold", 0, muted);
        }
        restore();
        if (lyrics.status == "error" || lyrics.status == "empty") {
            button("重新查找歌词 ↗", x, 909, 170, 36, "player:lyrics-retry", 14);
        }
        return;
    }
    constexpr double size = 34;
    if (m_lyricsDocument != document || m_lyricsWidth != width) {
        m_lyricsDocument = document;
        m_lyricsWidth = width;
        m_lyricsLayout.clear();
        double height = 0;
        for (const auto &value : lines) {
            const auto line = value.toObject();
            auto original = line["text"].toString();
            if (original.isEmpty()) {
                original = "•••";
            }
            const auto wrapped = m_glyphs->wrap(original, width - 24, size, "bold");
            const auto translation = line["translation"].toString();
            QStringList translated;
            if (!translation.isEmpty()) {
                translated = m_glyphs->wrap(translation, width - 24, 17);
            }
            m_lyricsLayout.append({height, wrapped, translated});
            height += std::max(1, int(wrapped.size())) * 47 + translated.size() * 26 + 32;
        }
        m_lyricsBrowse.reset();
        m_lyricsLastIndex = lyrics.index;
        m_lyricsLineUpdates = 0;
        m_lyricsPlainOffset = 0;
        m_lyricsTarget.reset();
        m_lyricsCurve.reset();
        m_lyricsScroll = m_lyricsLayout.at(std::clamp(lyrics.index, 0, int(m_lyricsLayout.size()) - 1)).top;
    }
    // 每更新两行歌词重置歌词位置
    if (lyrics.index != m_lyricsLastIndex) {
        m_lyricsLastIndex = lyrics.index;
        if (lyrics.index >= 0 && ++m_lyricsLineUpdates >= 2) {
            m_lyricsLineUpdates = 0;
            m_lyricsBrowse.reset();
        }
    }
    const auto active = std::clamp(lyrics.index, 0, int(m_lyricsLayout.size()) - 1);
    const auto target = m_lyricsBrowse.value_or(m_lyricsLayout.at(active).top);
    const auto sample =
        m_lyricsCurve ? m_lyricsCurve->sample(lastTime) : std::array<double, 2>{m_lyricsScroll, 0};
    m_lyricsScroll = sample[0];
    if (!m_lyricsTarget || target != *m_lyricsTarget) {
        m_lyricsTarget = target;
        if (reduced) {
            m_lyricsScroll = target;
            m_lyricsCurve.reset();
        } else {
            m_lyricsCurve.emplace(sample[0], target, sample[1], lastTime, m_lyricsBrowse ? 0.18 : 0.42);
        }
    }
    constexpr double focusY = top + 155;
    const auto activeTime = lyrics.index >= 0 ? lines.at(active).toObject()["startMs"] : QJsonValue();
    save();
    clip(x - 4, top, width + 8, bottom - top);
    for (int index = 0; index < lines.size(); ++index) {
        const auto line = lines.at(index).toObject();
        const auto &row = m_lyricsLayout.at(index);
        const auto y = focusY + row.top - m_lyricsScroll;
        const double height = row.text.size() * 47 + row.translation.size() * 26;
        if (y + height < top || y > bottom) {
            continue;
        }
        auto color = ink();
        const bool isActive = lyrics.index >= 0 && line["startMs"] == activeTime;
        const auto edge = std::clamp(std::min((y + height - top) / 55, (bottom - y) / 55), 0.0, 1.0);
        color[3] = (isActive ? 1 : 0.28) * edge;
        for (int rowIndex = 0; rowIndex < row.text.size(); ++rowIndex) {
            text(row.text.at(rowIndex), x, y + rowIndex * 47, size, "bold", 0, color);
        }
        color[3] = color.at(3).toDouble() * 0.65;
        for (int rowIndex = 0; rowIndex < row.translation.size(); ++rowIndex) {
            text(row.translation.at(rowIndex), x, y + row.text.size() * 47 + rowIndex * 26, 17, "regular", 0,
                 color);
        }
        if (player.state["seekable"].toBool()) {
            const auto hitY = std::max(top, y);
            const auto label = line["text"].toString();
            hit(x, hitY, width, std::max(0.0, std::min(bottom, y + height + 20) - hitY),
                "player:lyric-line:" + QString::number(index), label.isEmpty() ? "间奏" : label);
        }
    }
    restore();
    button("歌词偏移 ⌃", x, 914, 144, 32, "player:lyrics-offset", 13);
    button("回到当前句", x + width - 125, 914, 125, 32, "player:lyrics-follow", 13);
}

void NativeHud::container(double width, double opacity) {
    auto &music = *m_music;
    const auto item = music.current;
    const auto layout = containerLayout(width);
    const auto sideWidth = layout.sidebar - 44;
    const auto coverSize = std::min(250.0, sideWidth - 16);
    const bool albums = item["kind"] == "artist" && artistTab == "albums";
    QJsonArray songs = music.tracks;
    if (albums) {
        songs = music.directory ? music.directory->albums : QJsonArray();
    } else if (music.directory) {
        songs = music.directory->orderedSongs();
    }
    const auto containerKey = item["key"].toString();
    if (containerKey != m_sortContainerKey) {
        m_sortContainerKey = containerKey;
        detailSort = "none";
        m_sortNotice.clear();
    }
    if (music.directory) {
        detailSort = music.directory->sortField;
    }
    const auto sortField =
        !music.directory && !albums && item["kind"] == "playlist" ? detailSort : QString("none");
    if (songs != m_sortTracks || sortField != m_sortField) {
        m_sortTracks = songs;
        m_sortField = sortField;
        m_trackOrder = MusicData::sortOrder(songs, sortField);
    }
    trackOffset = std::min(trackOffset, std::max(0, int(songs.size()) - layout.rowCount));
    // 控制器只整理真实数据与可用动作，独立卡片组件负责内部排版与绘制。
    CollectionDetailCard::Model card;
    card.bounds = detailBounds(width);
    card.left = layout.left;
    card.sidebar = layout.sidebar;
    card.x = layout.x;
    card.width = layout.width;
    card.rowsY = layout.rowsY;
    card.rowHeight = layout.rowHeight;
    card.rowCount = layout.rowCount;
    card.dark = dark;
    card.kind = item["kind"].toString();
    card.provider = music.providerName();
    card.title = item["title"].toString();
    card.artist = item["artist"].toString();
    card.coverKey = music.coverImage;
    card.coverSize = coverSize;
    const QHash<QString, QString> prefixes{
        {"qq", "QQ MID / "}, {"kugou", "KUGOU ID / "}, {"netease", "NETEASE ID / "}};
    if (item["virtual"].toBool()) {
        card.archiveId = music.providerName() + " / " + item["title"].toString();
    } else {
        card.archiveId = prefixes.value(music.provider) + item["id"].toString();
    }
    const auto ids = music.directory ? music.directory->ids.size() : 0;
    card.totalCount = std::max({item["trackCount"].toInt(), int(ids), int(songs.size())});
    card.loadedCount = songs.size();
    const auto date = item["date"].toString();
    card.facts = {{"RELEASE / 发行日期", date.isEmpty() ? QString("暂无") : date},
                  {"FORMAT / 收录", QString::number(card.totalCount) + " TRACKS / 曲目"}};
    const auto description = item["description"].toString();
    card.quote = description.isEmpty() ? "暂无简介" : description;
    if (!albums) {
        card.playAll = {"▶  播放全部", "music:play-loaded"};
    }
    if (item["kind"] == "playlist") {
        card.sort = {"排序方式 ▾", "music:sort-menu"};
    }
    if (item["kind"] == "artist") {
        card.tabs = {{"热门歌曲", "music:artist-tab:songs", artistTab == "songs"},
                     {"发行专辑", "music:artist-tab:albums", artistTab == "albums"}};
    }
    if (music.canEditPlaylist(item)) {
        card.rename = {"修改名称", "music:rename-playlist"};
        card.remove = {"删除歌单", "music:delete-playlist"};
    }
    const auto subscribeRoute =
        item["kind"] == "playlist" ? "/playlist/subscribe" : "/" + item["kind"].toString() + "/sub";
    if (!item["virtual"].toBool() && !item["special"].toBool() && music.canMutate(subscribeRoute)) {
        const auto subject = item["kind"] == "artist"     ? QString("歌手")
                             : item["kind"] == "playlist" ? QString("歌单")
                                                          : QString("专辑");
        QString label = "＋ 收藏" + subject;
        bool subscribed = false;
        if (music.provider == "qq") {
            const auto state = music.subscriptionStates.value(item["key"].toString(), "unknown");
            label = "＋ 收藏 / 核实";
            if (state == "subscribed") {
                label = "✓ 已收藏" + subject;
                subscribed = true;
            } else if (state == "not-subscribed") {
                label = "＋ 收藏" + subject;
            }
        } else {
            // 网络来源的收藏状态与写入按钮共用同一判断，避免显示和实际动作相反。
            subscribed = music.isSubscribed(item);
            if (subscribed) {
                label = "✓ 已收藏" + subject;
            }
        }
        card.subscribe = {label, "music:subscribe", subscribed};
    }
    if (!music.isLocal() && !item["virtual"].toBool() && !item["localCollection"].toBool()) {
        card.source = {music.providerName() + " ↗", "music:source"};
    }
    if (albums && music.directory && music.directory->albumsMore) {
        card.more = {music.directory->albumsLoading ? "载入中…" : "更多专辑 ↓", "music:artist-more"};
    } else if (!albums && songs.size() < card.totalCount) {
        card.more = {music.directoryLoading ? "载入中…" : "加载更多 ↓", "music:directory-more"};
    }
    if (songs.isEmpty()) {
        card.emptyMessage =
            music.directoryLoading || music.detailLoading ? "正在载入曲目…" : "暂无可读取曲目";
    }
    card.hint = "滚轮浏览曲目 · 点击查看歌曲";
    if (m_sortRequest) {
        card.hint = "正在补齐曲目以排序…";
    } else if (!m_sortNotice.isEmpty()) {
        card.hint = m_sortNotice;
    }
    const int directoryIndex = music.directory ? music.directory->index : -1;
    const auto playingIdentity =
        music.player.current.isEmpty() ? QString() : PlaybackQueue::identity(music.player.current);
    const auto rowAt = [songs, order = m_trackOrder, albums, directoryIndex, playingIdentity](int index) {
        const int rawIndex = order.at(index);
        const auto song = songs.at(rawIndex).toObject();
        CollectionDetailCard::Row entry;
        entry.number = MusicData::pad(index + 1);
        entry.title = song["title"].toString();
        entry.artist = song["artist"].toString();
        entry.stamp = MusicData::time(song);
        if (albums) {
            entry.stamp = song["date"].toString("专辑");
            if (entry.stamp.isEmpty()) {
                entry.stamp = "专辑";
            }
        }
        entry.current = directoryIndex == rawIndex ||
                        (!playingIdentity.isEmpty() && PlaybackQueue::identity(song) == playingIdentity);
        entry.action = (albums ? "music:artist-album:" : "music:track:") + QString::number(rawIndex);
        entry.label = entry.title;
        return entry;
    };
    if (m_responsive.compact()) {
        card.rowAt = rowAt;
    } else {
        for (int row = 0; row < layout.rowCount && trackOffset + row < songs.size(); ++row) {
            card.rows.append(rowAt(trackOffset + row));
        }
    }
    if (songs.size() > layout.rowCount) {
        card.scrollFraction = double(trackOffset) / std::max(1, int(songs.size()) - layout.rowCount);
        card.scrollThumb = double(layout.rowCount) / songs.size();
    }
    const CollectionDetailCard::Canvas canvas{
        [this](double x, double y, double width, double height, QJsonArray color) {
            fill(x, y, width, height, color);
        },
        [this](QString value, double x, double y, double size, QString weight, double tracking,
               QJsonArray color) { text(value, x, y, size, weight, tracking, color); },
        [this](QString value, double size, double width, QString weight) {
            return fit(value, size, width, weight);
        },
        [this](QString value, double width, double size, QString weight) {
            return m_glyphs->wrap(value, width, size, weight);
        },
        [this](QString value, double size, QString weight) { return m_glyphs->width(value, size, weight); },
        [this](double x, double y, double width, double height, QString action, QString label) {
            hit(x, y, width, height, action, label);
        },
        [this](QString key, double x, double y, double width, double height) {
            image(key, x, y, width, height);
        }};
    if (m_responsive.compact()) {
        m_responsive.setCollection(card);
        return;
    }
    save();
    alpha(opacity);
    button("← 返回曲目资料库   ESC", layout.left + 19, 211, sideWidth, 54, "music:directory", 20, "demibold");
    CollectionDetailCard::paint(card, canvas);
    restore();
}

void NativeHud::viewer(double width) {
    const auto item = m_music->current;
    if (item.isEmpty()) {
        return;
    }
    button("← 返回音乐   ESC", 59, 69, 300, 54, "viewer:close", 20, "demibold");
    text("RHINE LAB / MUSIC DATABASE / COVER", width / 2 - 145, 70, 11, "regular", 1.5);
    limited(item["title"].toString() + " / 封面", width / 2 - 145, 95, 28, width / 2 - 250, "demibold");
    text(item["id"].toString(), width / 2 - 145, 139, 12);
    text("360°", width - 185, 72, 55, "light");
    button("清晰", width - 247, 189, 84, 38, "viewer:clear", 14);
    button("磨砂", width - 147, 189, 84, 38, "viewer:frosted", 14);
    text("拖动旋转     ↑ ↓ ← → 平移     滚轮缩放", 59, 965, 13);
    button("原始视角", width / 2 - 165, 914, 154, 46, "viewer:reset", 15);
    button("封面正面", width / 2 + 18, 914, 154, 46, "music:cover-front", 15);
    button("复位视角 ↗", width - 194, 914, 135, 46, "viewer:reset", 14);
}
