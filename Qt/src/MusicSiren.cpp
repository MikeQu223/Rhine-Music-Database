#include "MusicLibrary.h"
#include "MusicData.h"
#include <QVector>
#include <algorithm>

/** 本地收藏与歌单 */
void MusicLibrary::reloadSirenCollections() {
    if (!isSiren() || !collections) {
        return;
    }
    const auto ids = collections->likedIDs();
    replaceLikedIDs(QJsonArray::fromStringList(ids));
    likedCursor = 0;
    lists[1] = {};
    totals[1] = int(ids.size());
    hasMore[1] = !ids.isEmpty();
    lists[2] = collections->playlists();
    totals[2] = int(lists[2].size());
    hasMore[2] = false;
    m_sourceErrors[1].clear();
    m_sourceErrors[2].clear();
    changed();
}

/**
 * 每次启动只向官网取一次全量目录，之后搜索、播放全部和资料库浏览都使用这份本地数据
 */
void MusicLibrary::loadSirenCatalog() {
    if (!isSiren()) {
        return;
    }
    if (!sirenSongs.isEmpty()) {
        lists[3] = sirenSongs;
        lists[4] = sirenAlbums;
        totals[3] = int(lists[3].size());
        totals[4] = int(lists[4].size());
        hasMore[3] = false;
        hasMore[4] = false;
        if (m_pendingSirenSearch) {
            m_pendingSirenSearch = false;
            search(keyword, searchKind, false);
        }
        changed();
        return;
    }
    if (sirenCatalogLoading) {
        return;
    }
    sirenCatalogLoading = true;
    status = QStringLiteral("正在读取塞壬唱片曲库…");
    changed();
    const auto token = m_accountGeneration;
    api.call(
        "catalog", {},
        [this](MusicReply result) {
            sirenCatalogLoading = false;
            if (!result.ok()) {
                m_pendingSirenSearch = false;
                m_sourceErrors[3] = result.error;
                m_sourceErrors[4] = result.error;
                hasMore[3] = true;
                hasMore[4] = true;
                status = QStringLiteral("塞壬唱片曲库读取失败：") + result.error;
                changed();
                return;
            }
            const auto value = result.value.toObject();
            sirenSongs = value["songs"].toArray();
            sirenAlbums = value["albums"].toArray();
            lists[3] = sirenSongs;
            lists[4] = sirenAlbums;
            totals[3] = int(lists[3].size());
            totals[4] = int(lists[4].size());
            hasMore[3] = false;
            hasMore[4] = false;
            m_sourceErrors[3].clear();
            m_sourceErrors[4].clear();
            status = QStringLiteral("已加载塞壬唱片曲库：") + QString::number(totals[3]) +
                     QStringLiteral(" 首 / ") + QString::number(totals[4]) + QStringLiteral(" 张专辑");
            if (m_pendingSirenSearch) {
                m_pendingSirenSearch = false;
                search(keyword, searchKind, false);
            } else {
                changed();
            }
        },
        valid(token, &m_accountGeneration));
}

/** 塞壬唱片的本地搜索；曲库未就绪时先加载，完成后自动重放这次搜索。 */
void MusicLibrary::searchSirenLocal(QString query, QString kind, int start, bool more) {
    if (sirenSongs.isEmpty() && !lists[3].isEmpty()) {
        // 网络曲库尚未就绪时，用会话恢复的列表兜底。
        sirenSongs = lists[3];
        sirenAlbums = lists[4];
    }
    if (sirenSongs.isEmpty()) {
        m_pendingSirenSearch = true;
        searchLoading = false;
        status = QStringLiteral("正在读取塞壬唱片曲库…");
        loadSirenCatalog();
        changed();
        return;
    }
    const auto text = query.trimmed().toLower();
    const auto matches = [&text](const QString &value) {
        return text.isEmpty() || value.toLower().contains(text);
    };
    QJsonArray results;
    if (kind == "song") {
        for (const auto &value : sirenSongs) {
            const auto item = value.toObject();
            if (matches(item["title"].toString()) || matches(item["album"].toString()) ||
                matches(item["artist"].toString())) {
                results.append(item);
            }
        }
    } else if (kind == "album") {
        for (const auto &value : sirenAlbums) {
            const auto item = value.toObject();
            if (matches(item["title"].toString()) || matches(item["artist"].toString())) {
                results.append(item);
            }
        }
    } else if (kind == "artist") {
        QHash<QString, QJsonObject> artists;
        for (const auto &value : sirenSongs) {
            const auto song = value.toObject();
            for (const auto &entry : song["artists"].toArray()) {
                const auto artist = entry.toObject();
                const auto name = artist["name"].toString();
                if (name.isEmpty()) {
                    continue;
                }
                auto item = artists.value(name);
                if (item.isEmpty()) {
                    item = MusicData::item("artist", artist["id"].toString(), name, {}, provider);
                    item["artist"] = name;
                    item["artists"] = QJsonArray{artist};
                    item["cover"] = song["cover"];
                    item["trackCount"] = 0;
                }
                item["trackCount"] = item["trackCount"].toInt() + 1;
                artists.insert(name, item);
            }
        }
        QVector<QJsonObject> list;
        for (auto it = artists.cbegin(); it != artists.cend(); ++it) {
            if (matches(it.key())) {
                list.append(it.value());
            }
        }
        std::sort(list.begin(), list.end(), [](const QJsonObject &left, const QJsonObject &right) {
            if (left["trackCount"].toInt() != right["trackCount"].toInt()) {
                return left["trackCount"].toInt() > right["trackCount"].toInt();
            }
            return left["title"].toString() < right["title"].toString();
        });
        for (const auto &item : list) {
            results.append(item);
        }
    } else if (kind == "playlist") {
        for (const auto &value : lists[2]) {
            const auto item = value.toObject();
            if (matches(item["title"].toString())) {
                results.append(item);
            }
        }
    }
    constexpr int pageSize = 30;
    const auto total = int(results.size());
    const auto page = MusicData::slice(results, start, pageSize);
    lists[0] = more ? MusicData::unique(lists[0], page) : page;
    if (!more) {
        offsets[0] = 0;
    }
    searchCursor = start + int(page.size());
    hasMore[0] = !page.isEmpty() && start + int(page.size()) < total;
    totals[0] = total;
    searchLoading = false;
    status = page.isEmpty() ? (kind == "playlist" ? QStringLiteral("没有匹配的本地歌单")
                                                  : QStringLiteral("没有匹配的音乐"))
                            : QStringLiteral("找到 ") + QString::number(total) + QStringLiteral(" 条结果");
    if (!more) {
        showSource(0);
        emit modeRequested("archive");
        frame["mode"] = "archive";
    }
    changed();
}

/** 把全量歌曲作为一个虚拟歌单打开到资料库 */
bool MusicLibrary::openSirenAllSongs() {
    if (!isSiren() || lists[3].isEmpty()) {
        status = QStringLiteral("塞壬唱片曲库尚未加载");
        changed();
        return false;
    }
    ++m_directoryGeneration;
    ++m_selectionGeneration;
    ++m_wikiGeneration;
    const auto physical = selectedPhysical >= 0
                              ? selectedPhysical
                              : frame["selected"].toInt(physicalSlots[selectedLane].value(0, -1));
    auto next = std::make_shared<MusicDirectory>();
    next->parent = directory;
    next->item = QJsonObject{
        {"provider", provider},
        {"kind", "playlist"},
        {"virtual", true},
        {"id", "siren-all"},
        {"key", "siren:playlist:all"},
        {"title", QStringLiteral("全部歌曲")},
        {"artist", providerName()},
        {"cover", lists[3].first().toObject()["cover"].toString()},
        {"description", QStringLiteral("塞壬唱片全部歌曲")},
        {"trackCount", int(lists[3].size())},
    };
    next->songs = lists[3];
    for (const auto &value : lists[3]) {
        next->ids.append(value.toObject()["id"]);
    }
    next->cursor = next->ids.size();
    next->parentPhysical = physical;
    next->parentLane = selectedLane;
    next->parentItem = current;
    directory = next;
    directoryInfo = false;
    directoryLoading = false;
    wantsSongDetails = false;
    current = {};
    tracks = {};
    trackIDs = {};
    coverImage.clear();
    coverKey.clear();
    detailLoading = false;
    emit modeRequested("archive");
    emit navigationRequested("lane", 1);
    const auto destination = (selectedLane + 1) % 5;
    next->anchor = destination * 8 + rowMemory[destination];
    selectedPhysical = -1;
    status = QStringLiteral("已打开：全部歌曲");
    next->index = 0;
    choose(next->songs.first().toObject());
    return true;
}

/**
 * 喜欢与歌单读取本地存储
 */
void MusicLibrary::loadSirenSource(int lane) {
    if (!isSiren() || lane < 1 || lane > 4) {
        return;
    }
    if (lane == 2) {
        lists[2] = collections ? collections->playlists() : QJsonArray{};
        totals[2] = int(lists[2].size());
        hasMore[2] = false;
        m_sourceErrors[2].clear();
        status = lists[2].isEmpty() ? QStringLiteral("暂无本地歌单，可点击创建歌单")
                                    : QStringLiteral("已读取本地歌单");
        changed();
        return;
    }
    if (lane == 3 || lane == 4) {
        if (lists[lane].isEmpty()) {
            loadSirenCatalog();
        } else {
            hasMore[lane] = false;
        }
        return;
    }
    if (personalLoading) {
        m_pendingLane = lane;
        return;
    }
    if (!hasMore[lane]) {
        return;
    }
    personalLoading = true;
    m_sourceErrors[lane].clear();
    changed();
    const auto token = m_accountGeneration;
    const auto all = collections ? collections->likedIDs() : QStringList{};
    const auto page = all.mid(likedCursor, 100);
    if (page.isEmpty()) {
        personalLoading = false;
        hasMore[1] = false;
        totals[1] = int(all.size());
        status = all.isEmpty() ? QStringLiteral("暂无喜欢的歌曲") : QStringLiteral("已读取喜欢的歌曲");
        if (m_playLiked) {
            m_playLiked = false;
            playDirectory();
        }
        changed();
        return;
    }
    api.call(
        "songs", {QJsonArray::fromStringList(page)},
        [this, page](MusicReply result) {
            personalLoading = false;
            if (!result.ok()) {
                m_playLiked = false;
                m_sourceErrors[1] = result.error;
                status = result.error;
                changed();
                return;
            }
            lists[1] = MusicData::unique(lists[1], result.value.toArray());
            likedCursor += int(page.size());
            const auto total = collections ? int(collections->likedIDs().size()) : likedCursor;
            totals[1] = total;
            hasMore[1] = likedCursor < total;
            status = QStringLiteral("已读取喜欢的歌曲");
            if (m_playLiked) {
                if (hasMore[1]) {
                    loadMoreSource(1);
                } else {
                    m_playLiked = false;
                    playDirectory();
                }
            }
            if (selectedLane == 1 && current.isEmpty() && !lists[1].isEmpty()) {
                selectedPhysical = -1;
                observe(frame["selected"].toInt(physicalSlots[1].value(0, -1)));
            }
            const auto pending = m_pendingLane;
            m_pendingLane = -1;
            if (pending > 0 && pending != 1 && lists[pending].isEmpty()) {
                loadMoreSource(pending);
            }
            changed();
        },
        valid(token, &m_accountGeneration));
}
