#include "NativeHud.h"
#include "MusicData.h"
#include "ProviderRegistry.h"
#include <QPointer>
#include <QUrl>
#include <QTimer>
#include <algorithm>

namespace {
constexpr int SongActionFeedbackDurationMs = 2000;

int wrap(int value, int count) {
    return count > 0 ? (value % count + count) % count : 0;
}
QString decode(QString value) {
    return QUrl::fromPercentEncoding(value.toUtf8());
}
}

/**
 * 判断当前歌曲是否从可编辑歌单中打开，并确认它是否仍属于该歌单。
 * 搜索、专辑或歌手入口不满足目录条件，避免误删歌单曲目。
 */
auto NativeHud::openedPlaylistContext() const -> std::optional<PlaylistContext> {
    const auto &music = *m_music;
    const auto &folder = music.directory;
    if (!folder || music.current["kind"] != "song" || !music.canEditPlaylist(folder->item)) {
        return std::nullopt;
    }
    const auto songID = music.current["id"].toString();
    if (songID.isEmpty()) {
        return std::nullopt;
    }
    PlaylistContext context;
    context.id = folder->item["id"].toString();
    context.contained =
        MusicData::indexOfId(folder->songs, songID) >= 0 || MusicData::indexOf(folder->ids, songID) >= 0;
    return context;
}

/**
 * 在当前歌曲的按钮上显示歌单增删结果。
 * holdMs 后自动恢复原文案；重复调用会重启计时器，避免旧结果覆盖新操作。
 */
void NativeHud::showPlaylistFeedback(const QString &action, const QString &text, int holdMs) {
    const auto key = m_music->uid + ":" + PlaybackQueue::identity(m_music->current);
    if (m_playlistFeedbackKey != key) {
        m_playlistFeedbackKey = key;
        m_playlistFeedback.clear();
    }
    m_playlistFeedback[action] = text;
    auto timer = m_playlistFeedbackTimers.value(action);
    if (!timer) {
        timer = new QTimer(this);
        timer->setSingleShot(true);
        timer->setTimerType(Qt::PreciseTimer);
        connect(timer, &QTimer::timeout, this, [this, action] {
            m_playlistFeedback.remove(action);
            // 主动唤醒静止界面，让按钮恢复状态文案。
            m_host->invalidate();
        });
        m_playlistFeedbackTimers.insert(action, timer);
    }
    timer->start(holdMs);
    m_host->invalidate();
}

/** 将音乐界面动作交给原生资料库；写入确认捕获账号代数，避免切换后修改另一个账号。 */
void NativeHud::musicAction(const QStringList &parts, const QString &value) {
    auto &music = *m_music;
    const auto name = parts.value(1);
    const auto last = parts.constLast().toInt();
    // 塞壬唱片本地操作
    if (music.isSiren() && QStringList{"login", "logout", "qr", "login-method", "variant", "subscribe",
                                       "refresh-personal", "activate"}
                               .contains(name)) {
        return;
    }
    if (music.isLocal() &&
        QStringList{"login", "logout", "qr", "login-method", "variant", "like", "like-current",
                    "subscribe", "create-playlist", "delete-playlist", "rename-playlist", "add-to-playlist",
                    "playlist-pick", "refresh-personal", "activate", "remove-track"}
            .contains(name)) {
        return;
    }
    if (music.isLocal() && (name == "source" || name == "official")) {
        return;
    }
    if (name == "sort-menu") {
        if (music.current["kind"] == "playlist" && frame["mode"] == "detail") {
            openModal("detail-sort");
        }
    } else if (name == "sort") {
        const auto field = parts.value(3);
        if (!QStringList{"none", "title", "album", "artist"}.contains(field)) {
            return;
        }
        if (parts.value(2) == "detail" && frame["mode"] == "detail" && music.current["kind"] == "playlist") {
            // 先收起菜单再补页，排序请求才能绑定仍然打开的歌单详情。
            if (modal == "detail-sort") {
                modal.clear();
                closing = false;
                ++m_searchGeneration;
            }
            detailSort = field;
            trackOffset = 0;
            music.setDirectorySort(field);
            beginSort();
        }
    } else if (name == "slot") {
        const auto directory = music.directory;
        if (directory && !directory->songs.isEmpty()) {
            const auto index = directory->page + wrap(music.selectedLane * 8 + last - directory->anchor, 40);
            if (index >= directory->songs.size() && directory->cursor < directory->ids.size()) {
                music.loadDirectoryPage(index);
            } else {
                music.selectDirectory(wrap(index, directory->songs.size()));
            }
            return;
        }
        const auto count = music.libraryItems().size();
        if (count > 0) {
            const auto index = wrap(music.offsets[music.selectedLane] + last, count);
            const auto raw = music.groupLane == music.selectedLane ? music.groupIndices.value(index) : index;
            music.selectResult(raw, music.selectedLane, false);
            m_scene.mode("archive");
        }
    } else if (name == "index") {
        // 列表命中使用完整资料库索引，跨列选择仍由既有资料库维护物理唱片位置。
        const auto values = music.libraryItems();
        if (!trackListMode || frame["mode"] != "archive" || last < 0 || last >= values.size() ||
            values.at(last).toObject()["kind"] != "song") {
            return;
        }
        if (music.directory) {
            music.selectDirectory(last);
        } else {
            const auto raw = music.groupLane == music.selectedLane ? music.groupIndices.value(last) : last;
            music.selectResult(raw, music.selectedLane, false);
        }
    } else if (name == "result") {
        music.selectResult(parts.value(3).toInt(), parts.value(2).toInt());
        tab = "overview";
        trackOffset = 0;
        bodyOffset = 0;
        closeModal();
    } else if (name == "album-track") {
        // 同专辑列表
        if (last >= 0 && last < music.tracks.size()) {
            music.playContext = music.tracks;
            music.choose(music.tracks.at(last).toObject());
        }
        tab = "overview";
        trackOffset = 0;
        bodyOffset = 0;
    } else if (name == "track") {
        if (music.directory && last >= 0 && last < music.directory->songs.size()) {
            music.selectDirectory(last, "detail");
        } else if (last >= 0 && last < music.tracks.size()) {
            // 详情页曲目列表就是当前单曲所在的歌曲列表。
            music.playContext = music.tracks;
            music.choose(music.tracks.at(last).toObject());
        }
        tab = "overview";
        trackOffset = 0;
        bodyOffset = 0;
    } else if (name == "parent") {
        music.leaveDirectory();
    } else if (name == "directory-more") {
        if (music.directory) {
            music.loadDirectoryPage();
        } else {
            music.loadTrackPage(trackOffset);
        }
    } else if (name == "directory-info") {
        music.showDirectoryInfo();
        trackOffset = 0;
    } else if (name == "directory") {
        if (music.directory) {
            music.returnToDirectory();
        } else if (!music.current.isEmpty()) {
            music.enterDirectory(music.current);
        }
    } else if (name == "first-track") {
        if (trackOffset >= 0 && trackOffset < music.tracks.size()) {
            music.playContext = music.tracks;
            music.choose(music.tracks.at(trackOffset).toObject());
        }
        tab = "overview";
        trackOffset = 0;
        bodyOffset = 0;
    } else if (name == "hint") {
        query = decode(value.mid(11));
        listOffset = 0;
        resetResultViews();
        music.search(query);
    } else if (name == "kind") {
        ++m_searchGeneration;
        listOffset = 0;
        resetResultViews();
        activeGroup.clear();
        const auto kind = QStringList{"song", "album", "playlist", "artist"}.value(last, "song");
        const auto text = query.isEmpty() ? music.keyword : query;
        if (text.isEmpty()) {
            music.searchKind = kind;
        } else {
            music.search(text, kind);
        }
    } else if (name == "group") {
        music.setGroupView({}, {}, modal == "saved" ? musicCollection : 0);
        ++m_searchGeneration;
        groupBy = QStringList{"none", "artist", "album"}.value(last, "none");
        activeGroup.clear();
        listOffset = 0;
        resetResultViews();
    } else if (name == "expand") {
        ++m_searchGeneration;
        const auto lane = modal == "saved" ? musicCollection : 0;
        const auto key = decode(value.mid(13));
        const auto groups = rows(lane);
        const auto group = std::find_if(groups.cbegin(), groups.cend(),
                                        [&key](const Row &row) { return row.value["key"] == key; });
        activeGroup = key;
        listOffset = 0;
        resetResultViews();
        if (group != groups.cend()) {
            music.setGroupView(group->value["title"].toString(), group->indices, lane);
        }
    } else if (name == "group-back") {
        music.setGroupView({}, {}, modal == "saved" ? musicCollection : 0);
        ++m_searchGeneration;
        activeGroup.clear();
        listOffset = 0;
        resetResultViews();
    } else if (name == "artist") {
        music.openSongArtist(last);
        artistTab = "songs";
    } else if (name == "artist-tab") {
        artistTab = parts.value(2);
        trackOffset = 0;
        if (artistTab == "albums") {
            music.loadArtistAlbums();
        }
    } else if (name == "artist-album") {
        if (music.directory && last >= 0 && last < music.directory->albums.size()) {
            music.enterDirectory(music.directory->albums.at(last).toObject());
        }
        artistTab = "songs";
    } else if (name == "artist-more") {
        music.loadArtistAlbums();
    } else if (name == "collection") {
        if (last < 0 || last >= 5) {
            return;
        }
        activeGroup.clear();
        ++m_searchGeneration;
        musicCollection = last;
        listOffset = 0;
        resetResultViews();
        if (music.lists[last].isEmpty()) {
            music.loadMoreSource(last);
        }
    } else if (name == "more") {
        if (last >= 0 && last < 5) {
            music.loadMoreSource(last);
        }
    } else if (name == "page-prev" || name == "page-next") {
        pageResults(name == "page-prev" ? -1 : 1);
    } else if (name == "play") {
        music.play();
    } else if (name == "preview" && ProviderRegistry::instance().capability(music.provider, "preview", false)) {
        music.player.play(music.current, std::nullopt, std::nullopt, true);
    } else if (name == "play-next" || name == "enqueue") {
        const auto key = music.uid + ":" + PlaybackQueue::identity(music.current);
        if (m_songQueueFeedbackKey != key) {
            m_songQueueFeedbackKey = key;
            m_songQueueFeedback.clear();
        }
        const bool queued = music.player.enqueue(music.current, name == "play-next");
        QString notice = "未能加入，请重试";
        if (queued) {
            notice = name == "play-next" ? "✓ 已设为下一首" : "✓ 已加入队列";
        }
        m_songQueueFeedback[name] = notice;
        auto timer = m_songQueueFeedbackTimers.value(name);
        if (!timer) {
            timer = new QTimer(this);
            timer->setSingleShot(true);
            timer->setTimerType(Qt::PreciseTimer);
            connect(timer, &QTimer::timeout, this, [this, name] {
                m_songQueueFeedback.remove(name);
                // 主动唤醒静止界面，不依赖鼠标移动或持续动画来恢复按钮。
                m_host->invalidate();
            });
            m_songQueueFeedbackTimers.insert(name, timer);
        }
        timer->start(SongActionFeedbackDurationMs);
    } else if (name == "play-loaded") {
        music.playDirectory();
    } else if (name == "remove-track") {
        const auto context = openedPlaylistContext();
        if (!context) {
            return;
        }
        if (!context->contained) {
            // 同专辑等入口可能沿用歌单目录；成员关系不符时不发送删除请求。
            showPlaylistFeedback("remove", "不在当前歌单", 2500);
            return;
        }
        if (music.writeLoading) {
            showPlaylistFeedback("remove", "正在处理…", 1200);
            return;
        }
        const auto folder = music.directory;
        const auto songID = music.current["id"].toString();
        const auto key = music.uid + ":" + PlaybackQueue::identity(music.current);
        const auto position = MusicData::indexOfId(folder->orderedSongs(), songID);
        showPlaylistFeedback("remove", "正在移除…", 10000);
        const QPointer<NativeHud> owner(this);
        music.playlistTrack(context->id, music.current, true, [owner, key, context, position](bool ok) {
            if (!owner) {
                return;
            }
            if (!ok) {
                owner->showPlaylistFeedback("remove", "移除失败，请重试", 2500);
                return;
            }
            auto &library = *owner->m_music;
            // 请求期间可能已经切歌或离开歌单，只处理仍停留在原歌曲上的结果。
            if (library.uid + ":" + PlaybackQueue::identity(library.current) != key ||
                !library.wantsSongDetails) {
                return;
            }
            const auto folder = library.directory;
            if (!folder || folder->item["id"] != context->id) {
                return;
            }
            const auto songs = folder->orderedSongs();
            // 下一首
            owner->tab = "overview";
            owner->trackOffset = 0;
            owner->bodyOffset = 0;
            if (songs.isEmpty()) {
                // 删除最后一首后没有下一首，回到歌单详情。
                library.showDirectoryInfo();
                return;
            }
            auto next = position;
            if (next < 0) {
                next = folder->index;
            }
            library.selectDirectory(std::min(next, int(songs.size()) - 1), "detail");
        });
    } else if (name == "picker-prev" || name == "picker-next") {
        const auto maximum = std::max(0, int(music.lists[2].size()) - 7);
        listOffset = std::clamp(listOffset + (name == "picker-prev" ? -7 : 7), 0, maximum);
    } else if (name == "official") {
        music.playOfficial();
    } else if (name == "copy") {
        if (!music.current.isEmpty()) {
            m_host->copy(music.current.value("id").toString());
            music.status = "已复制" + music.providerName() + " ID";
            music.changed();
        }
    } else if (name == "source") {
        if (!music.current.isEmpty()) {
            m_host->open(music.sourceURL());
        }
    } else if (name.startsWith("project-")) {
        static const QHash<QString, QString> links{
            {"project-home", "https://github.com/MikeQu223/Rhine-Music-Database"},
            {"project-rhine", "https://github.com/LBEILC/RhineLabUI"},
            {"project-lyricsx", "https://github.com/MxIris-LyricsX-Project/LyricsX"},
            {"project-lyricskit", "https://github.com/MxIris-LyricsX-Project/LyricsKit"},
            {"project-lyrimuse", "https://github.com/Yudaotor/lyrimuse"}};
        if (links.contains(name)) {
            m_host->open(links[name]);
        }
    } else if (name == "login") {
        openModal("login");
        const auto methods = ProviderRegistry::instance().loginMethods(music.provider);
        music.loginMethod = methods.isEmpty() ? QStringLiteral("qr")
                                              : methods.first().toObject()["id"].toString("qr");
        music.startLogin();
    } else if (name == "variant") {
        const QPointer<NativeHud> owner(this);
        const auto token = m_searchGeneration;
        music.switchProvider(music.provider, parts.value(2), [owner, token](bool ok) {
            if (ok && owner && owner->modal == "login" && owner->m_searchGeneration == token) {
                owner->m_music->startLogin();
            }
        });
    } else if (name == "login-method") {
        const auto method = parts.value(2);
        QJsonObject descriptor;
        for (const auto &value : ProviderRegistry::instance().loginMethods(music.provider)) {
            if (value.toObject()["id"].toString() == method) {
                descriptor = value.toObject();
                break;
            }
        }
        if (descriptor.isEmpty()) {
            return;
        }
        music.cancelLogin();
        music.loginMethod = method;
        music.loginStatus.clear();
        if (descriptor["type"].toString() == "qr") {
            music.startLogin();
        }
    } else if (name == "refresh-personal") {
        music.refreshPersonal(musicCollection);
    } else if (name == "like" || name == "like-current") {
        music.like(name == "like" ? QJsonObject() : music.player.current);
    } else if (name == "subscribe") {
        music.subscribe();
    } else if (name == "create-playlist") {
        formKind = "create";
        formPID.clear();
        openModal("playlist-form");
    } else if (name == "delete-playlist") {
        if (!music.directory || !music.canEditPlaylist(music.directory->item)) {
            return;
        }
        const auto item = music.directory->item;
        confirmTitle = "删除歌单：" + item["title"].toString();
        const QPointer<MusicLibrary> owner(&music);
        const auto generation = music.accountGeneration();
        m_confirm = [owner, generation, item]() {
            if (!owner || owner->accountGeneration() != generation) {
                return;
            }
            owner->mutate("/playlist/delete", {{"id", item["id"]}}, [owner, item](QJsonObject) {
                if (!owner) {
                    return;
                }
                QJsonArray values;
                for (const auto &entry : owner->lists[2]) {
                    if (entry.toObject()["id"] != item["id"]) {
                        values.append(entry);
                    }
                }
                owner->lists[2] = values;
                owner->totals[2] = values.size();
                owner->leaveDirectory();
            });
        };
        confirmMessage.clear();
        confirmLabel.clear();
        openModal("confirm");
    } else if (name == "rename-playlist") {
        if (music.directory && music.canEditPlaylist(music.directory->item)) {
            formKind = "rename";
            formPID = music.directory->item["id"].toString();
            openModal("playlist-form");
        }
    } else if (name == "add-to-playlist") {
        openModal("playlist-picker");
        if (music.lists[2].isEmpty()) {
            music.loadMoreSource(2);
        }
    } else if (name == "playlist-pick") {
        const auto playlistID = parts.value(2);
        const auto songID = music.current["id"].toString();
        const auto folder = music.directory;
        if (folder && folder->item["id"] == playlistID &&
            (MusicData::indexOfId(folder->songs, songID) >= 0 ||
             MusicData::indexOf(folder->ids, songID) >= 0)) {
            // 打开的歌单已经包含这首歌，拒绝重复写入并把状态直接显示在按钮上。
            showPlaylistFeedback("add", "✓ 已在当前歌单", 2500);
            music.status = QStringLiteral("这首歌已在当前歌单");
            music.changed();
            return;
        }
        if (music.writeLoading) {
            showPlaylistFeedback("add", "正在处理…", 1200);
            return;
        }
        const QPointer<NativeHud> owner(this);
        const auto token = m_searchGeneration;
        const auto key = music.uid + ":" + PlaybackQueue::identity(music.current);
        showPlaylistFeedback("add", "正在添加…", 10000);
        music.playlistTrack(playlistID, {}, false, [owner, token, key](bool ok) {
            if (!owner) {
                return;
            }
            auto &library = *owner->m_music;
            // 请求期间可能已经切歌，旧歌单的结果不能显示到新歌曲的按钮上。
            if (library.uid + ":" + PlaybackQueue::identity(library.current) != key) {
                return;
            }
            if (!ok) {
                owner->showPlaylistFeedback("add", "加入失败，请重试", 2500);
                return;
            }
            owner->showPlaylistFeedback("add", "✓ 已加入歌单", 2500);
            if (owner->m_searchGeneration == token && owner->modal == "playlist-picker") {
                owner->closeModal();
            }
        });
    } else if (name == "open-all-siren") {
        if (!modal.isEmpty()) {
            closeModal();
        }
        music.openSirenAllSongs();
    } else if (name == "qr") {
        music.startLogin();
    } else if (name == "logout") {
        music.logout();
    } else if (name == "cover-front" || name == "cover-back") {
        m_scene.coverFront(name == "cover-front");
    } else if (name == "activate") {
        m_host->setActivates(!m_host->activates());
    }
}
