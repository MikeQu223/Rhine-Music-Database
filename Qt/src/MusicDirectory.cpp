#include "MusicLibrary.h"
#include "MusicData.h"
#include "MusicDiscover.h"
#include "ProviderRegistry.h"
#include <QRegularExpression>
#include <algorithm>
#include <cmath>

/** 详情与唱片资料库共享同一显示顺序，原始曲目和分页 ID 保持来源原序。 */
QJsonArray MusicDirectory::orderedSongs() const {
    if (cachedSongs != songs || cachedSortField != sortField) {
        cachedSongs = songs;
        cachedSortField = sortField;
        sortedSongs = {};
        for (const auto position : MusicData::sortOrder(songs, sortField)) {
            sortedSongs.append(songs.at(position));
        }
    }
    return sortedSongs;
}

/** 变更排序或补页时保留选中歌曲及物理槽位，避免索引变化选中另一首歌。 */
void MusicDirectory::updateSongs(QJsonArray values, QString field) {
    const auto selected = orderedSongs().at(index).toObject()["id"].toString();
    const auto cell = (index + anchor) % 40;
    songs = values;
    sortField = field;
    const auto position = MusicData::indexOfId(orderedSongs(), selected);
    index = position >= 0 ? position : std::clamp(index, 0, std::max(0, int(songs.size()) - 1));
    page = index / 40 * 40;
    anchor = (cell - index % 40 + 40) % 40;
}

void MusicLibrary::setDirectorySort(QString field) {
    if (!directory || directory->item["kind"] != "playlist" ||
        !QStringList{"none", "title", "album", "artist"}.contains(field)) {
        return;
    }
    directory->updateSongs(directory->songs, field);
    if (directoryInfo) {
        tracks = directory->orderedSongs();
    }
    changed();
}

/** 先建立可返回的目录状态，再加载内容；目录关闭或被替换后丢弃旧响应。 */
void MusicLibrary::enterDirectory(QJsonObject value) {
    if (value.isEmpty()) {
        return;
    }
    if (value["kind"] == "song") {
        choose(value);
        return;
    }
    const auto token = ++m_directoryGeneration;
    ++m_selectionGeneration;
    ++m_wikiGeneration;
    const auto physical = selectedPhysical >= 0
                              ? selectedPhysical
                              : frame["selected"].toInt(physicalSlots[selectedLane].value(0, -1));
    auto next = std::make_shared<MusicDirectory>();
    next->parent = directory;
    next->item = value;
    next->albumsMore = value["kind"] == "artist";
    next->parentPhysical = physical;
    next->parentLane = selectedLane;
    next->parentItem = value;
    directory = next;
    directoryInfo = false;
    directoryLoading = true;
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
    status = QStringLiteral("正在打开：") + value["title"].toString();
    changed();
    if (isLocal()) {
        next->songs = local->tracks(value);
        next->item["trackCount"] = next->songs.size();
        for (const auto &song : next->songs) {
            next->ids.append(song.toObject()["id"]);
        }
        next->cursor = next->ids.size();
        next->albumsMore = false;
        directoryLoading = false;
        if (!next->songs.isEmpty()) {
            choose(next->songs.first().toObject());
        }
        changed();
        return;
    }
    if (isSiren() && value["kind"] == "playlist" && value["localCollection"].toBool()) {
        next->ids = QJsonArray::fromStringList(collections ? collections->tracks(value["id"].toString())
                                                           : QStringList{});
        next->songs = {};
        next->cursor = 0;
        next->albumsMore = false;
        next->item["trackCount"] = int(next->ids.size());
        directoryLoading = false;
        if (next->ids.isEmpty()) {
            status = QStringLiteral("歌单暂无可读取曲目");
            changed();
        } else {
            loadDirectoryPage(std::optional<int>(0));
        }
        return;
    }
    api.call(
        "detail", {value},
        [this, next, value](MusicReply result) {
            if (!result.ok()) {
                directoryLoading = false;
                status = QStringLiteral("读取失败：") + result.error;
                changed();
                return;
            }
            const auto values = result.value.toArray();
            next->item = values.at(0).toObject();
            next->songs = values.at(1).toArray();
            next->ids = values.at(2).toArray();
            next->cursor = MusicData::cursor(next->songs, next->ids);
            details[next->item["key"].toString()] = next->item;
            directoryLoading = false;
            status = QStringLiteral("已打开：") + next->item["title"].toString();
            if (value["kind"] == "artist") {
                showDirectoryInfo();
            } else if (!next->songs.isEmpty()) {
                next->index = 0;
                choose(next->songs.first().toObject());
            } else {
                changed();
            }
        },
        valid(token, &m_directoryGeneration));
}

/**
 * 在资料库发现页的每日推荐
 */
bool MusicLibrary::openDaily() {
    if (!discover) {
        return false;
    }
    QJsonArray songs;
    for (const auto &value : discover->items) {
        if (value.toObject()["kind"] == "song") {
            songs.append(value);
        }
    }
    if (songs.isEmpty()) {
        status = QStringLiteral("每日推荐暂无可打开的歌曲");
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
        {"id", "daily"},
        {"key", provider + ":playlist:daily"},
        {"title", ProviderRegistry::instance().text(provider, "dailyTitle").isEmpty()
                      ? QStringLiteral("每日推荐")
                      : ProviderRegistry::instance().text(provider, "dailyTitle")},
        {"artist", providerName()},
        {"cover", songs.first().toObject()["cover"].toString()},
        {"description", QStringLiteral("来自发现音乐的每日推荐，打开后不会同步到账号歌单。")},
        {"trackCount", int(songs.size())},
    };
    next->songs = songs;
    for (const auto &value : songs) {
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
    status = QStringLiteral("已打开：") + next->item["title"].toString();
    next->index = 0;
    choose(next->songs.first().toObject());
    return true;
}

void MusicLibrary::loadArtistAlbums() {
    const auto folder = directory;
    if (isLocal() || !folder || folder->item["kind"] != "artist" || folder->albumsLoading ||
        !folder->albumsMore) {
        return;
    }
    folder->albumsLoading = true;
    changed();
    api.call(
        "artistAlbums", {folder->item["id"], folder->albumCursor},
        [this, folder](MusicReply result) {
            if (result.ok()) {
                const auto page = result.value.toObject();
                folder->albums = MusicData::unique(folder->albums, page["items"].toArray());
                folder->albumCursor += page["rawCount"].toInt();
                folder->albumsMore = page["more"].toBool();
            } else {
                status = QStringLiteral("专辑读取失败：") + result.error;
            }
            folder->albumsLoading = false;
            changed();
        },
        valid(m_directoryGeneration, &m_directoryGeneration));
}

void MusicLibrary::openSongArtist(int index) {
    if (isLocal()) {
        const auto artist = current.value("artists").toArray().at(index).toObject();
        enterDirectory({{"provider", "local"},
                        {"kind", "artist"},
                        {"id", artist["id"]},
                        {"key", "local:artist:" + artist["id"].toString()},
                        {"title", artist["name"]}});
        return;
    }
    const auto artists = current.value("artists").toArray();
    const auto artist = artists.at(index).toObject();
    static const QRegularExpression identifier(QStringLiteral("^[a-zA-Z0-9_-]{1,80}$"));
    if (!artist.isEmpty() && identifier.match(artist["id"].toString()).hasMatch()) {
        enterDirectory(
            MusicData::item("artist", artist["id"].toString(), artist["name"].toString(), {}, provider));
    }
}

void MusicLibrary::observeDirectory(int physical) {
    const auto folder = directory;
    if (!folder || directoryInfo || selectedPhysical == physical) {
        return;
    }
    int lane = -1;
    for (int i = 0; i < 5; ++i) {
        if (physicalSlots[i].contains(physical)) {
            lane = i;
            break;
        }
    }
    if (lane < 0) {
        return;
    }
    const auto row = int(physicalSlots[lane].indexOf(physical));
    if (folder->songs.isEmpty()) {
        selectedPhysical = physical;
        selectedLane = lane;
        folder->anchor = lane * 8 + row;
        return;
    }
    // 拖动跨越槽位边界时继续逻辑索引，并复用分页入口。
    const auto previousCell = (folder->index + folder->anchor) % 40;
    const auto movement = lane == previousCell / 8 ? (row - previousCell % 8 + 12) % 8 - 4
                                                   : (lane * 8 + row - previousCell + 60) % 40 - 20;
    if (movement != 0) {
        const auto target = folder->index + movement;
        const auto count = int(folder->songs.size());
        const auto index = target >= count && folder->cursor < folder->ids.size()
                               ? target
                               : (target % count + count) % count;
        // 行拖动重新对齐锚点
        folder->anchor = (lane * 8 + row - index % 40 + 40) % 40;
        selectedPhysical = physical;
        selectedLane = lane;
        if (target >= count && folder->cursor < folder->ids.size()) {
            loadDirectoryPage(target);
        } else {
            // 选中槽位后不再通知
            folder->index = index;
            folder->page = index / 40 * 40;
            choose(folder->orderedSongs().at(index).toObject());
        }
    }
}

void MusicLibrary::selectDirectory(int index, QString mode, QString axis, int direction) {
    if (!directory || index < 0 || index >= directory->songs.size()) {
        return;
    }
    directoryInfo = false;
    directory->index = index;
    directory->page = index / 40 * 40;
    const auto cell = (index + directory->anchor) % 40;
    selectedLane = cell / 8;
    const auto physical = physicalSlots[selectedLane].value(cell % 8, -1);
    const auto navigation =
        axis.isEmpty() ? QJsonObject{} : QJsonObject{{"axis", axis}, {"direction", direction}};
    emit selectionRequested(physical, navigation);
    selectedPhysical = physical;
    choose(directory->orderedSongs().at(index).toObject(), false, mode == "detail");
    emit modeRequested(mode);
    changed();
}

void MusicLibrary::navigateDirectory(int step, QString axis) {
    const auto folder = directory;
    if (!folder || folder->songs.isEmpty()) {
        return;
    }
    const auto target = folder->index + step;
    if (target >= folder->songs.size() && folder->cursor < folder->ids.size()) {
        loadDirectoryPage(target);
        return;
    }
    int direction = step > 0 ? 1 : -1;
    if (axis == "row") {
        direction = step;
    }
    if (axis.isEmpty()) {
        axis = std::abs(step) > 1 ? "lane" : "row";
    }
    const auto count = int(folder->songs.size());
    selectDirectory(((target % count) + count) % count, "archive", axis, direction);
}

/** 按完整 ID 分页补齐曲目，游标按已消费 ID 数推进，无法播放的条目不会重复请求。 */
void MusicLibrary::loadDirectoryPage(std::optional<int> selectAfter) {
    const auto folder = directory;
    if (!folder || directoryLoading || folder->cursor >= folder->ids.size()) {
        return;
    }
    directoryLoading = true;
    const auto ids = MusicData::slice(folder->ids, folder->cursor, 100);
    changed();
    api.call(
        "songs", {QJsonValue(ids)},
        [this, folder, ids, selectAfter](MusicReply result) {
            directoryLoading = false;
            if (!result.ok()) {
                status = result.error;
                changed();
                return;
            }
            folder->updateSongs(
                MusicData::unique(folder->songs, MusicData::ordered(ids, result.value.toArray())),
                folder->sortField);
            folder->cursor += ids.size();
            if (selectAfter && *selectAfter >= 0 && *selectAfter < folder->songs.size()) {
                selectDirectory(*selectAfter);
            } else if (selectAfter && *selectAfter >= folder->songs.size() &&
                       folder->cursor < folder->ids.size()) {
                // 大步滚动可能跨过多页，不能只补一页就丢弃待选目标。
                loadDirectoryPage(selectAfter);
            } else if (selectAfter && *selectAfter >= 0 && !folder->songs.isEmpty()) {
                selectDirectory(*selectAfter % folder->songs.size());
            } else {
                changed();
            }
        },
        valid(m_directoryGeneration, &m_directoryGeneration));
}

void MusicLibrary::showDirectoryInfo() {
    if (!directory) {
        return;
    }
    ++m_selectionGeneration;
    directoryInfo = true;
    current = directory->item;
    if (!isLocal()) {
        loadSubscriptionStatus(current);
    }
    detailLoading = false;
    tracks = directory->orderedSongs();
    trackIDs = directory->ids;
    coverImage.clear();
    coverKey.clear();
    emit musicIdentityRequested(directory->item["key"].toString());
    loadCover(directory->item);
    emit modeRequested("detail");
    changed();
}

/** 歌曲详情归位保留当前身份和物理槽位，只有目录资料页需要恢复歌曲选择。 */
void MusicLibrary::returnToDirectory() {
    if (directory) {
        if (directory->songs.isEmpty()) {
            leaveDirectory();
            return;
        }
        if (directoryInfo) {
            selectDirectory(directory->index);
        } else {
            wantsSongDetails = false;
            emit modeRequested("archive");
        }
    }
    changed();
}

void MusicLibrary::leaveDirectory(bool restore) {
    const auto folder = directory;
    if (!folder) {
        return;
    }
    ++m_directoryGeneration;
    directory = restore ? folder->parent : nullptr;
    directoryLoading = false;
    directoryInfo = false;
    ++m_selectionGeneration;
    ++m_wikiGeneration;
    tracks = {};
    trackIDs = {};
    coverImage.clear();
    coverKey.clear();
    detailLoading = false;
    if (restore) {
        selectedLane = folder->parentLane;
        selectedPhysical = folder->parentPhysical;
        current = details.value(folder->item["key"].toString(), folder->parentItem);
        emit selectionRequested(folder->parentPhysical, {{"axis", "lane"}, {"direction", -1}});
        emit modeRequested("archive");
        if (directory) {
            selectDirectory(directory->index);
            status = QStringLiteral("已返回：") + directory->item["title"].toString();
            changed();
            return;
        }
        if (!current.isEmpty()) {
            emit musicIdentityRequested(current.value("key").toString());
            loadCover(current);
        }
    }
    status = QStringLiteral("已返回：") + columns.value(selectedLane);
    changed();
}

/** 切歌沿用原物理选中与取出顺序，队列外曲目建立可返回的播放队列目录。 */
void MusicLibrary::followPlayback(QJsonObject value, bool showDetails) {
    if (current.value("key") == value["key"] && current.value("id") == value["id"]) {
        return;
    }
    const auto previous = current;
    const auto physical = selectedPhysical >= 0
                              ? selectedPhysical
                              : frame["selected"].toInt(physicalSlots[selectedLane].value(0, -1));
    auto folder = directory;
    auto index = folder ? MusicData::indexOfId(folder->orderedSongs(), value["id"].toString()) : -1;
    // 开启“切歌不打开详情”后，只有播放队列或已打开的曲目列表包含该曲目时才继续定位；
    // 其他视图保持用户当前选择，不跳转，也不建立播放队列目录。显式打开详情仍会定位。
    if (skipDetailOnSwitch && !showDetails && index < 0) {
        return;
    }
    if (index < 0) {
        ++m_directoryGeneration;
        directoryLoading = false;
        folder = std::make_shared<MusicDirectory>();
        folder->parent = directory;
        folder->item = {{"kind", "playlist"},
                        {"key", "playback:queue"},
                        {"id", ""},
                        {"title", "播放队列"},
                        {"trackCount", player.queue.size()}};
        folder->songs = player.queue.items();
        for (const auto &song : player.queue.items()) {
            folder->ids.append(song.toObject()["id"]);
        }
        folder->cursor = int(player.queue.size());
        index = player.queue.indexOfId(value["id"].toString());
        folder->index = index;
        const auto row = std::max(0, int(physicalSlots[selectedLane].indexOf(physical)));
        folder->anchor = selectedLane * 8 + row;
        folder->parentPhysical = physical;
        folder->parentLane = selectedLane;
        folder->parentItem = previous;
        directory = folder;
    }
    if (index < 0 || index >= folder->songs.size()) {
        return;
    }
    auto songs = folder->songs;
    const auto rawIndex = MusicData::indexOfId(songs, value["id"].toString());
    songs.replace(rawIndex, value);
    folder->updateSongs(songs, folder->sortField);
    index = MusicData::indexOfId(folder->orderedSongs(), value["id"].toString());
    const auto cell = (index + folder->anchor) % 40;
    const auto target = physicalSlots[cell / 8].value(cell % 8, -1);
    const QString mode = showDetails ? QStringLiteral("detail") : frame["mode"].toString("archive");
    selectDirectory(index, mode, target == physical ? "row" : "", target == physical ? 8 : 1);
    if (showDetails && !frame.isEmpty()) {
        frame["mode"] = "detail";
    }
}
