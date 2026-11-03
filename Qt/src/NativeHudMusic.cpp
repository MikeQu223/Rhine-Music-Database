#include "NativeHud.h"
#include "MusicData.h"
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

/** 将音乐界面动作交给原生资料库；写入确认捕获账号代数，避免切换后修改另一个账号。 */
void NativeHud::musicAction(const QStringList &parts, const QString &value) {
    auto &music = *m_music;
    const auto name = parts.value(1);
    const auto last = parts.constLast().toInt();
    // 塞壬唱片本地操作
    if (music.isSiren() && QStringList{"login", "logout", "qr", "login-method", "kugou-edition", "subscribe",
                                       "refresh-personal", "activate"}
                               .contains(name)) {
        return;
    }
    if (music.isLocal() &&
        QStringList{"login", "logout", "qr", "login-method", "kugou-edition", "like", "like-current",
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
    } else if (name == "preview" && music.provider == "qq") {
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
        if (music.directory) {
            music.playlistTrack(music.directory->item["id"].toString(), music.current, true);
        }
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
            {"project-author", "https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced"},
            {"project-player", "https://github.com/yakult-green-tea/qq-music-api"},
            {"project-kugou", "https://github.com/MakcRe/KuGouMusicApi"},
            {"project-rhine", "https://github.com/LBEILC/RhineLabUI"},
            {"project-lyricsx", "https://github.com/MxIris-LyricsX-Project/LyricsX"},
            {"project-lyricskit", "https://github.com/MxIris-LyricsX-Project/LyricsKit"},
            {"project-lyrimuse", "https://github.com/Yudaotor/lyrimuse"}};
        if (links.contains(name)) {
            m_host->open(links[name]);
        }
    } else if (name == "login") {
        openModal("login");
        music.loginMethod = "qr";
        music.startLogin();
    } else if (name == "kugou-edition") {
        const QPointer<NativeHud> owner(this);
        const auto token = m_searchGeneration;
        music.switchProvider("kugou", parts.value(2), [owner, token](bool ok) {
            if (ok && owner && owner->modal == "login" && owner->m_searchGeneration == token) {
                owner->m_music->startLogin();
            }
        });
    } else if (name == "login-method") {
        const auto method = parts.value(2);
        const bool supported = method == "qr" || (music.provider == "netease" && method == "phone") ||
                               (music.provider == "qq" && method == "wechat");
        if (!supported) {
            return;
        }
        music.cancelLogin();
        music.loginMethod = method;
        music.loginStatus.clear();
        if (QStringList{"qr", "wechat"}.contains(music.loginMethod)) {
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
        const QPointer<NativeHud> owner(this);
        const auto token = m_searchGeneration;
        music.playlistTrack(parts.value(2), {}, false, [owner, token](bool ok) {
            if (ok && owner && owner->m_searchGeneration == token && owner->modal == "playlist-picker") {
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
