#include "MusicLibrary.h"
#include "MusicData.h"
#include "ProviderRegistry.h"
#include <algorithm>

namespace {
QJsonArray without(const QJsonArray &values, const QString &field, const QJsonValue &key) {
    QJsonArray result;
    for (const auto &value : values) {
        const auto match = field.isEmpty() ? value : value.toObject().value(field);
        if (match != key) {
            result.append(value);
        }
    }
    return result;
}
}

bool MusicLibrary::supportsOperation(const QString &operation) const {
    return ProviderRegistry::instance().descriptor(provider)["operations"].toObject()[operation].toBool();
}

bool MusicLibrary::canMutate(const QString &route) const {
    if (isSiren()) {
        return QStringList{"/like", "/playlist/create", "/playlist/name/update", "/playlist/delete",
                           "/playlist/tracks"}
            .contains(route);
    }
    static const QHash<QString, QPair<QString, QString>> features{
        {"/like", {"mutations", "likeSong"}},
        {"/album/sub", {"mutations", "subscribeAlbum"}},
        {"/playlist/subscribe", {"mutations", "subscribePlaylist"}},
        {"/artist/sub", {"mutations", "subscribeArtist"}},
        {"/playlist/tracks", {"mutations", "updatePlaylistTracks"}},
        {"/playlist/create", {"playlistManagement", "createPlaylist"}},
        {"/playlist/name/update", {"playlistManagement", "renamePlaylist"}},
        {"/playlist/delete", {"playlistManagement", "deletePlaylist"}},
    };
    const auto feature = features.value(route);
    if (feature.first.isEmpty()) {
        return false;
    }
    const auto capabilities = ProviderRegistry::instance().descriptor(provider)["capabilities"].toObject();
    return capabilities[feature.first].toObject()[feature.second].toBool();
}

bool MusicLibrary::canEditPlaylist(const QJsonObject &value) const {
    if (isSiren()) {
        return collections && value["kind"] == "playlist" &&
               value["creatorID"].toString() == collections->creatorID();
    }
    // “我喜欢的音乐”由账号维护，不能改名、删除或按普通歌单处理。
    if (value["special"].toBool()) {
        return false;
    }
    if (!editable() || uid.isEmpty() || value["kind"] != "playlist" || value["creatorID"] != uid) {
        return false;
    }
    const auto library = ProviderRegistry::instance().descriptor(provider)["library"].toObject();
    const auto rule = library["playlistEditableRule"].toString("all");
    if (rule == "none") {
        return false;
    }
    if (rule == "owned-with-dir-range") {
        const auto range = library["dirIdRange"].toArray();
        bool parsed = false;
        const auto directoryId = value["dirId"].toString().toInt(&parsed);
        const auto minimum = range.size() == 2 ? range.at(0).toInt(0) : 0;
        const auto maximum = range.size() == 2 ? range.at(1).toInt(0) : 0;
        return value["owned"].toBool() && parsed && directoryId >= minimum && directoryId <= maximum;
    }
    return true;
}

/** 按当前账号与选中条目读取三态收藏信息。 */
void MusicLibrary::loadSubscriptionStatus(const QJsonObject &value) {
    const auto kind = value["kind"].toString();
    const auto operations = ProviderRegistry::instance().descriptor(provider)["operations"].toObject();
    if (!operations["subscriptionStatus"].toBool() || uid.isEmpty() || value["virtual"].toBool() ||
        !QStringList{"song", "album", "playlist"}.contains(kind)) {
        return;
    }
    const auto key = value["key"].toString();
    const auto token = ++m_subscriptionGeneration;
    const auto accountAlive = valid(m_accountGeneration, &m_accountGeneration);
    const auto selectionAlive = valid(token, &m_subscriptionGeneration);
    api.call(
        "subscriptionStatus", {kind, value["id"]},
        [this, key](MusicReply result) {
            if (current["key"] != key) {
                return;
            }
            subscriptionStates[key] = result.ok() ? result.value.toString("unknown") : "unknown";
            changed();
        },
        [accountAlive, selectionAlive] { return accountAlive() && selectionAlive(); });
}

/** 重置喜欢列表状态 */
void MusicLibrary::resetLikeState() {
    writeLoading = false;
    ++m_playbackLikeGeneration;
    m_playbackLikeContext.clear();
    likedIDs.reset();
    lists[1] = {};
    totals[1] = 0;
    likedCursor = 0;
    hasMore[1] = true;
    subscriptionStates.clear();
}

/** 读取当前账号下的歌曲喜欢状态 */
std::optional<bool> MusicLibrary::songLiked(const QJsonObject &value) const {
    if (value["kind"] != "song" || value.value("provider").toString(provider) != provider) {
        return std::nullopt;
    }
    if (isSiren()) {
        return likedIDs ? std::optional<bool>(MusicData::indexOf(*likedIDs, value["id"]) >= 0) : std::nullopt;
    }
    if (uid.isEmpty() || !canMutate("/like")) {
        return std::nullopt;
    }
    const auto state = subscriptionStates.value(value["key"].toString());
    if (state == "subscribed" || state == "not-subscribed") {
        return state == "subscribed";
    }
    if (likedIDs) {
        return MusicData::indexOf(*likedIDs, value["id"]) >= 0;
    }
    if (MusicData::indexOfId(lists[1], value["id"].toString()) >= 0) {
        return true;
    }
    return std::nullopt;
}

/** 为正在播放的歌曲补齐喜欢状态 */
void MusicLibrary::refreshPlaybackLike() {
    if (isSiren()) {
        return;
    }
    const auto track = player.current;
    if (writeLoading || uid.isEmpty() || track["kind"] != "song" ||
        track.value("provider").toString(provider) != provider || !canMutate("/like")) {
        return;
    }
    const auto library = ProviderRegistry::instance().descriptor(provider)["library"].toObject();
    const auto likedModel = library["likedModel"].toString();
    const auto context = provider + ":" + uid + ":" + QString::number(m_accountGeneration) + ":" +
                         (likedModel == "likedIDs" ? QStringLiteral("likedIDs") : track["key"].toString());
    if (songLiked(track).has_value() || m_playbackLikeContext == context) {
        return;
    }
    m_playbackLikeContext = context;
    const auto token = ++m_playbackLikeGeneration;
    const auto accountAlive = valid(m_accountGeneration, &m_accountGeneration);
    const auto readAlive = valid(token, &m_playbackLikeGeneration);
    if (likedModel == "likedIDs") {
        api.call(
            "likedIDs", {uid},
            [this](MusicReply result) {
                if (result.ok() && result.value.isArray()) {
                    likedIDs = result.value.toArray();
                    changed();
                }
            },
            [accountAlive, readAlive] { return accountAlive() && readAlive(); });
        return;
    }
    const auto key = track["key"].toString();
    const auto id = track["id"].toString();
    api.call(
        "likedState", {QJsonArray{id}, uid},
        [this, key, id](MusicReply result) {
            if (!result.ok()) {
                return;
            }
            const auto state = result.value.toObject()[id].toString("unknown");
            subscriptionStates[key] = state;
            changed();
        },
        [accountAlive, readAlive] { return accountAlive() && readAlive(); });
}

/** 写操作串行化并核对账号代数；成功后才更新本地集合和失效元数据缓存。 */
void MusicLibrary::mutate(QString route, QJsonObject values, std::function<void(QJsonObject)> success,
                          Completion done) {
    if (isSiren() && route == "/playlist/delete") {
        const auto id = values["id"].toString();
        const bool ok = collections && collections->deletePlaylist(id);
        if (ok) {
            lists[2] = collections->playlists();
            totals[2] = int(lists[2].size());
            status = QStringLiteral("已删除歌单");
            if (success) {
                success({{"id", id}});
            }
        } else {
            status = QStringLiteral("无法删除歌单");
        }
        changed();
        if (done) {
            done(ok);
        }
        return;
    }
    if (!canMutate(route) || writeLoading || uid.isEmpty()) {
        if (!editable()) {
            status = providerName() + QStringLiteral("当前支持读取与播放");
        } else if (uid.isEmpty()) {
            status = QStringLiteral("请先登录") + providerName();
        } else if (!canMutate(route)) {
            status = QStringLiteral("当前服务未开放此编辑功能");
        }
        changed();
        if (done) {
            done(false);
        }
        return;
    }
    writeLoading = true;
    ++m_playbackLikeGeneration;
    m_playbackLikeContext.clear();
    ++m_subscriptionGeneration;
    changed();
    const auto complete = [this, success, done](MusicReply result) {
        // 写入期间启动的状态读取也必须作废，不能在确认结果后回填旧状态。
        ++m_subscriptionGeneration;
        bool ok = result.ok();
        const auto body = result.value.toObject();
        const auto nestedCode = body["body"].toObject()["code"].toInt(200);
        if (ok && nestedCode != 200) {
            ok = false;
            status = providerName() + QStringLiteral("返回 ") + QString::number(nestedCode);
        } else if (ok) {
            host->invalidateMetadata();
            if (success) {
                success(body);
            }
            status = QStringLiteral("已同步至") + providerName();
        } else {
            status = result.error;
            subscriptionStates.clear();
            // 写入可能已经生效；下次刷新必须绕开旧列表缓存，不能自动再写。
            host->invalidateMetadata();
        }
        writeLoading = false;
        changed();
        if (done) {
            done(ok);
        }
    };
    const auto alive = valid(m_accountGeneration, &m_accountGeneration);
    api.call("mutate", {route, values}, complete, alive);
}

void MusicLibrary::like(QJsonObject value) {
    if (value.isEmpty()) {
        value = current;
    }
    if (value["kind"] != "song") {
        return;
    }
    if (isSiren()) {
        if (!collections) {
            return;
        }
        const auto id = value["id"].toString();
        const bool enabled = !collections->isLiked(id);
        if (!collections->setLiked(id, enabled)) {
            status = QStringLiteral("无法写入本地收藏");
            changed();
            return;
        }
        const auto ids = collections->likedIDs();
        likedIDs = QJsonArray::fromStringList(ids);
        if (enabled) {
            // 收藏列表从新到旧
            lists[1] = MusicData::unique(QJsonArray{value}, lists[1]);
            likedCursor = std::min(likedCursor + 1, int(ids.size()));
        } else {
            const int index = MusicData::indexOfId(lists[1], id);
            lists[1] = without(lists[1], "id", id);
            if (index >= 0 && index < likedCursor) {
                --likedCursor;
            }
        }
        totals[1] = int(ids.size());
        hasMore[1] = likedCursor < totals[1];
        status = enabled ? QStringLiteral("已加入喜欢的歌曲") : QStringLiteral("已从喜欢的歌曲移除");
        changed();
        return;
    }
    if (uid.isEmpty()) {
        status = QStringLiteral("请先登录") + providerName();
        changed();
        return;
    }
    const auto update = [this, value](bool enabled) {
        subscriptionStates[value["key"].toString()] = enabled ? "subscribed" : "not-subscribed";
        if (!enabled) {
            lists[1] = without(lists[1], "id", value["id"]);
            if (likedIDs) {
                *likedIDs = without(*likedIDs, {}, value["id"]);
            }
        } else {
            lists[1] = MusicData::unique(lists[1], {value});
            if (likedIDs && MusicData::indexOf(*likedIDs, value["id"]) < 0) {
                likedIDs->append(value["id"]);
            }
        }
        totals[1] = int(likedIDs ? likedIDs->size() : lists[1].size());
        likedCursor = int(lists[1].size());
    };
    const auto operations = ProviderRegistry::instance().descriptor(provider)["operations"].toObject();
    if (!likedIDs && operations["likedIDs"].toBool()) {
        api.call(
            "likedIDs", {uid},
            [this, value](MusicReply result) {
                if (result.ok()) {
                    likedIDs = result.value.toArray();
                    like(value);
                } else {
                    status = result.error;
                    changed();
                }
            },
            valid(m_accountGeneration, &m_accountGeneration));
        return;
    }
    const auto liked = (likedIDs && MusicData::indexOf(*likedIDs, value["id"]) >= 0) ||
                       MusicData::indexOfId(lists[1], value["id"].toString()) >= 0;
    const bool enabled = !liked;
    mutate("/like", {{"id", value["id"]}, {"like", enabled}},
           [update, enabled](QJsonObject body) {
               const auto state = body["state"].toString();
               update(state == "subscribed" ? true
                    : state == "not-subscribed" ? false
                                                : enabled);
           });
}

/** 判断专辑、歌单或歌手是否已收藏；本次会话写入与已载入的收藏列表都算已收藏。 */
bool MusicLibrary::isSubscribed(const QJsonObject &value) const {
    const auto key = value["key"].toString();
    if (key.isEmpty()) {
        return false;
    }
    if (subscriptions.contains(key)) {
        return true;
    }
    const auto kind = value["kind"].toString();
    if (kind != "playlist" && kind != "album") {
        return false;
    }
    const auto lane = kind == "album" ? 4 : 3;
    for (const auto &entry : lists[lane]) {
        if (entry.toObject()["key"] == key) {
            return true;
        }
    }
    return false;
}

void MusicLibrary::subscribe(QJsonObject value) {
    if (value.isEmpty()) {
        value = current;
    }
    const auto kind = value["kind"].toString();
    if (!QStringList{"album", "playlist", "artist"}.contains(kind)) {
        return;
    }
    if (value["special"].toBool()) {
        status = QStringLiteral("“我喜欢的音乐”不支持收藏操作");
        changed();
        return;
    }
    const auto lane = kind == "album" ? 4 : 3;
    const auto key = value["key"].toString();
    const bool subscribed = isSubscribed(value);
    mutate(kind == "playlist" ? "/playlist/subscribe" : "/" + kind + "/sub",
           {{"id", value["id"]}, {"t", subscribed ? 2 : 1}},
           [this, value, kind, lane, key](QJsonObject body) {
               const auto state = body["state"].toString();
               const auto enabled = state == "subscribed"
                                        ? true
                                        : (state == "not-subscribed" ? false : !isSubscribed(value));
               subscriptionStates[key] = enabled ? "subscribed" : "not-subscribed";
               if (!enabled) {
                   subscriptions.remove(key);
                   if (kind != "artist") {
                       lists[lane] = without(lists[lane], "key", key);
                   }
               } else {
                   subscriptions.insert(key);
                   if (kind != "artist") {
                       lists[lane] = MusicData::unique(lists[lane], {value});
                   }
               }
               if (kind != "artist") {
                   totals[lane] = int(lists[lane].size());
               }
           });
}

void MusicLibrary::playlistForm(QString kind, QString name, QString id, Completion done) {
    name = name.trimmed();
    const auto library = ProviderRegistry::instance().descriptor(provider)["library"].toObject();
    const auto maximum = library["playlistNameMaxLength"].toInt(100);
    if (name.isEmpty() || name.toUcs4().size() > maximum) {
        status = QStringLiteral("请输入 1–") + QString::number(maximum) + QStringLiteral(" 字歌单名称");
        changed();
        if (done) {
            done(false);
        }
        return;
    }
    if (isSiren()) {
        if (!collections) {
            if (done) {
                done(false);
            }
            return;
        }
        bool ok = false;
        if (kind == "create") {
            ok = !collections->createPlaylist(name).isEmpty();
            if (ok) {
                lists[2] = collections->playlists();
                totals[2] = int(lists[2].size());
                status = QStringLiteral("已创建歌单：") + name;
            } else {
                status = QStringLiteral("无法创建歌单，请检查名称或数量上限");
            }
        } else if (kind == "rename") {
            ok = collections->renamePlaylist(id, name);
            if (ok) {
                lists[2] = collections->playlists();
                totals[2] = int(lists[2].size());
                if (directory && directory->item["id"] == id) {
                    directory->item["title"] = name;
                }
                status = QStringLiteral("已重命名歌单");
            } else {
                status = QStringLiteral("无法重命名歌单");
            }
        }
        changed();
        if (done) {
            done(ok);
        }
        return;
    }
    if (kind == "rename" && MusicData::indexOfId(lists[2], id) < 0 &&
        !(directory && directory->item["id"] == id && directory->item["creatorID"] == uid)) {
        status = QStringLiteral("只能编辑自己创建的歌单");
        changed();
        if (done) {
            done(false);
        }
        return;
    }
    mutate(
        kind == "create" ? "/playlist/create" : "/playlist/name/update",
        kind == "create" ? QJsonObject{{"name", name}} : QJsonObject{{"id", id}, {"name", name}},
        [this, kind, name, id](QJsonObject body) {
            if (kind == "create" && (body["item"].isObject() || body["playlist"].isObject())) {
                const auto raw = body["item"].isObject() ? body["item"].toObject()
                                                         : body["playlist"].toObject();
                auto value = MusicData::parse(raw, "playlist");
                if (raw["provider"].toString() == provider) {
                    value = raw;
                }
                if (!value.isEmpty()) {
                    value["creatorID"] = uid;
                    lists[2] = MusicData::unique(lists[2], {value});
                }
            }
            if (kind == "rename") {
                const auto verifiedName = body["name"].toString(name);
                for (qsizetype i = 0; i < lists[2].size(); ++i) {
                    auto value = lists[2].at(i).toObject();
                    if (value["id"] == id) {
                        value["title"] = verifiedName;
                        lists[2].replace(i, value);
                    }
                }
                if (directory && directory->item["id"] == id) {
                    directory->item["title"] = verifiedName;
                }
            }
            totals[2] = int(lists[2].size());
        },
        done);
}

void MusicLibrary::playlistTrack(QString id, QJsonObject value, bool remove, Completion done) {
    if (value.isEmpty()) {
        value = current;
    }
    if (value["kind"] != "song") {
        if (done) {
            done(false);
        }
        return;
    }
    if (isSiren()) {
        if (!collections) {
            if (done) {
                done(false);
            }
            return;
        }
        const auto songID = value["id"].toString();
        const bool existed = collections->tracks(id).contains(songID);
        const bool ok = remove ? collections->removeTrack(id, songID) : collections->addTrack(id, songID);
        if (!ok) {
            status = QStringLiteral("无法写入本地歌单");
            changed();
            if (done) {
                done(false);
            }
            return;
        }
        const auto previous = lists[2];
        auto updated = collections->playlists();
        for (qsizetype row = 0; row < updated.size(); ++row) {
            auto item = updated.at(row).toObject();
            for (const auto &old : previous) {
                const auto object = old.toObject();
                if (object["id"] == item["id"] && !object["cover"].toString().isEmpty()) {
                    item["cover"] = object["cover"];
                    break;
                }
            }
            updated.replace(row, item);
        }
        lists[2] = updated;
        totals[2] = int(lists[2].size());
        if (directory && directory->item["id"] == id && (remove ? existed : !existed)) {
            const auto contained = MusicData::indexOfId(directory->songs, songID) >= 0;
            // 歌单曲目从新到旧
            const auto songs = remove ? without(directory->songs, "id", songID)
                                      : MusicData::unique(QJsonArray{value}, directory->songs);
            directory->updateSongs(songs, directory->sortField);
            if (remove) {
                const auto old = MusicData::indexOf(directory->ids, songID);
                if (old >= 0 && old < directory->cursor) {
                    --directory->cursor;
                }
                directory->ids = without(directory->ids, {}, songID);
                directory->item["trackCount"] = std::max(0, directory->item["trackCount"].toInt() - 1);
                directory->index = std::min(directory->index, std::max(0, int(directory->songs.size()) - 1));
            } else {
                if (!contained) {
                    directory->item["trackCount"] = directory->item["trackCount"].toInt() + 1;
                }
                if (MusicData::indexOf(directory->ids, songID) < 0) {
                    directory->ids.prepend(songID);
                    ++directory->cursor;
                }
            }
        }
        status = remove ? QStringLiteral("已从歌单移除") : QStringLiteral("已加入歌单");
        changed();
        if (done) {
            done(true);
        }
        return;
    }
    if (MusicData::indexOfId(lists[2], id) < 0 &&
        !(directory && directory->item["id"] == id && directory->item["creatorID"] == uid)) {
        status = QStringLiteral("请选择自己创建的歌单");
        changed();
        if (done) {
            done(false);
        }
        return;
    }
    mutate(
        "/playlist/tracks", {{"pid", id}, {"tracks", value["id"]}, {"op", remove ? "del" : "add"}},
        [this, id, value, remove](QJsonObject) {
            if (!directory || directory->item["id"] != id) {
                return;
            }
            const auto contained = MusicData::indexOfId(directory->songs, value["id"].toString()) >= 0;
            const auto songs = remove ? without(directory->songs, "id", value["id"])
                                      : MusicData::unique(directory->songs, {value});
            directory->updateSongs(songs, directory->sortField);
            if (remove) {
                const auto old = MusicData::indexOf(directory->ids, value["id"]);
                if (old >= 0 && old < directory->cursor) {
                    directory->cursor = std::max(0, directory->cursor - 1);
                }
                directory->ids = without(directory->ids, {}, value["id"]);
                directory->item["trackCount"] = std::max(0, directory->item["trackCount"].toInt() - 1);
                directory->index = std::min(directory->index, std::max(0, int(directory->songs.size()) - 1));
            } else if (!contained) {
                directory->item["trackCount"] = directory->item["trackCount"].toInt() + 1;
            }
        },
        done);
}
