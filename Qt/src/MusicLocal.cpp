#include "MusicLibrary.h"
#include "ProviderRegistry.h"
#include <QFileInfo>
#include <algorithm>

/** 更新本地栏目并清理已移除歌曲的队列引用；后台索引不会切换在线平台的界面状态。 */
void MusicLibrary::refreshLocal() {
    if (!isLocal()) {
        return;
    }
    const auto descriptorColumns = ProviderRegistry::instance().columns("local");
    if (!descriptorColumns.isEmpty()) {
        columns = descriptorColumns;
    }
    lists[1] = local->songs();
    lists[2] = local->collections("folder");
    lists[3] = local->collections("album");
    lists[4] = local->collections("artist");
    lists[0] = local->search(keyword, searchKind);
    for (int lane = 0; lane < 5; ++lane) {
        totals[lane] = lists[lane].size();
        hasMore[lane] = false;
    }
    if (!local->busy) {
        details.clear();
        QHash<QString, QJsonObject> indexed;
        for (const auto &entry : lists[1]) {
            const auto song = entry.toObject();
            indexed.insert(song["path"].toString(), song);
        }
        if (current.value("kind") == "song" && indexed.contains(current.value("path").toString())) {
            const auto replacement = indexed.value(current.value("path").toString());
            if (current.value("fingerprint") != replacement["fingerprint"]) {
                ++m_selectionGeneration;
                current = replacement;
                coverImage.clear();
                coverKey.clear();
                loadCover(current);
            }
        }
        for (int index = int(player.queue.size()) - 1; index >= 0; --index) {
            const auto track = player.queue.at(index);
            const auto path = track["path"].toString();
            // GUI 重新连接时本地索引可能尚未恢复；仍可读的后台曲目不能因此被停止。
            const bool missing =
                !indexed.contains(path) && (!host->playbackConnection() || !QFileInfo(path).isReadable());
            if (track["provider"] == "local" && missing) {
                if (index == player.queue.index()) {
                    player.stop();
                    break;
                }
                player.remove(index);
            }
        }
        if (directory && directory->item["key"] != "playback:queue") {
            directory->updateSongs(local->tracks(directory->item), directory->sortField);
            directory->ids = {};
            for (const auto &entry : directory->songs) {
                directory->ids.append(entry.toObject()["id"]);
            }
            directory->cursor = directory->ids.size();
            directory->index = std::min(directory->index, std::max(0, int(directory->songs.size()) - 1));
            directory->item["trackCount"] = directory->songs.size();
        }
        if (!current.isEmpty() && current.value("kind") == "song" &&
            !local->contains(current.value("path").toString())) {
            choose({});
        }
    }
    status = local->status;
    changed();
}
void MusicLibrary::importLocal(const QStringList &paths) {
    if (isLocal()) {
        local->importPaths(paths);
    }
}
void MusicLibrary::searchLocal(QString text, QString kind) {
    ++m_generation;
    if (!kind.isEmpty()) {
        searchKind = kind;
    }
    keyword = text.trimmed();
    searchLoading = false;
    groupLane = -1;
    groupIndices.clear();
    groupName.clear();
    lists[0] = local->search(keyword, searchKind);
    totals[0] = lists[0].size();
    hasMore[0] = false;
    offsets[0] = 0;
    rowMemory[0] = 0;
    showSource(0);
    status = QStringLiteral("本地检索：%1 条结果").arg(totals[0]);
    emit modeRequested("archive");
    changed();
}
