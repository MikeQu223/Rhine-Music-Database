#include "MusicLibrary.h"
#include "MusicData.h"
#include "MusicDiscover.h"
#include <QJsonDocument>
#include <QPointer>
#include <QUrl>
#include <algorithm>

namespace {
int wrap(int value, int count) {
    return ((value % count) + count) % count;
}
}

/** 建立原生资料库和各类请求的独立代数，物理槽位保持原有五列八行映射。 */
MusicLibrary::MusicLibrary(Host *host, const QJsonObject &content, QObject *parent)
    : QObject(parent), host(host), api(host), player(host, &api), m_identityApi(host) {
    kugouEdition = host->preference("kugou-edition") == "lite" ? "lite" : "standard";
    provider = host->preference("provider");
    if (!QStringList{"netease", "qq", "kugou", "local", "siren"}.contains(provider)) {
        provider = "netease";
    }
    if (provider == "local" && !PlatformFeatures::LocalMusic) {
        provider = "netease";
    }
    if (provider == "siren") {
        columns = {"搜索结果", "喜欢的歌曲", "我的歌单", "全部歌曲", "全部专辑"};
        collections = std::make_unique<LocalCollections>(provider, QString(), this);
        reloadSirenCollections();
    }
    api.provider = provider;
    host->setProvider(provider);
    if (isSiren()) {
        loadSirenCatalog();
    }
    for (const auto &source : {"netease", "qq"}) {
        identityNames[source] = host->preference("welcome-name-" + QString::fromUtf8(source));
    }
    identityNames["kugou"] = host->preference("welcome-name-kugou-" + kugouEdition);
    restoreCachedAccount();
    local = std::make_unique<LocalMusicLibrary>(QString(), host->offline || !PlatformFeatures::LocalMusic);
    connect(local.get(), &LocalMusicLibrary::changed, this, [this] {
        if (isLocal()) {
            refreshLocal();
        }
    });
    if (isLocal()) {
        refreshLocal();
    }
    const auto categories = content["columns"].toArray();
    const auto records = content["records"].toArray();
    for (int lane = 0; lane < 5 && lane < categories.size(); ++lane) {
        for (qsizetype i = 0; i < records.size(); ++i) {
            if (records.at(i).toObject()["category"] == categories.at(lane)) {
                physicalSlots[lane].append(int(i));
            }
        }
    }
    const auto saved = QJsonDocument::fromJson(host->preference("search-history").toUtf8()).array();
    for (const auto &value : saved) {
        if (value.isString() && searchHistory.size() < 12) {
            searchHistory.append(value.toString());
        }
    }
    discover = std::make_unique<MusicDiscover>(this);
    // 播放进度与歌词通知只刷新可见播放界面，不作废资源库场景。
    connect(&player, &MusicPlayer::changed, this, [this] {
        if (isLocal() && current.value("key") == player.current.value("key") &&
            current.value("fingerprint") == player.current.value("fingerprint") &&
            !player.coverImage.isEmpty() && coverImage != player.coverImage) {
            coverImage = player.coverImage;
            coverKey = current.value("key").toString();
            current["cover"] = player.current.value("cover");
            details[coverKey] = current;
            changed();
        }
        refreshPlaybackLike();
        ++revision;
        emit playbackInvalidated();
    });
    connect(&player, &MusicPlayer::trackSelected, this, &MusicLibrary::followPlayback);
}

MusicLibrary::~MusicLibrary() = default;

MusicApi::Valid MusicLibrary::valid(quint64 token, const quint64 *counter) {
    return [owner = QPointer(this), token, counter] { return owner && *counter == token; };
}

void MusicLibrary::changed() {
    refreshPlaybackLike();
    ++revision;
    emit invalidated();
}

/** 清除可重建的缓存与本地记录；登录状态、账号设置和本地音乐库保持不变。 */
void MusicLibrary::clearCaches() {
    host->clearCache();
    player.clearCaches();
    searchHistory.clear();
    suggestions.clear();
    host->setPreference("search-history", "[]");
    changed();
}

QString MusicLibrary::providerName() const {
    if (provider == "kugou" && kugouEdition == "lite") {
        return QStringLiteral("酷狗概念版");
    }
    return MusicApi::providerName(provider);
}

/** 统一各渠道的账号恢复、栏目等待、失败和空库文案，供场景与列表共用。 */
QString MusicLibrary::sourceMessage(int lane) const {
    if (lane < 0 || lane >= 5) {
        return {};
    }
    if (isLocal()) {
        if (local->busy) {
            return local->status;
        }
        if (local->songs().isEmpty()) {
            return QStringLiteral("暂无本地音乐，请在文件夹管理中导入");
        }
        return lane == 0 ? QStringLiteral("没有匹配的本地音乐") : QStringLiteral("暂无此类本地音乐");
    }
    if (lane == 0) {
        return searchLoading ? QStringLiteral("正在检索音乐，请稍候…") : status;
    }
    if (provider == "kugou" && lane == 4) {
        return QStringLiteral("此渠道暂不支持收藏专辑");
    }
    if (isSiren()) {
        if (sirenCatalogLoading) {
            return QStringLiteral("正在读取塞壬唱片曲库…");
        }
        if (personalLoading) {
            return QStringLiteral("正在读取") + columns[lane] + QStringLiteral("，请稍候…");
        }
        if (!m_sourceErrors[lane].isEmpty()) {
            return m_sourceErrors[lane] + QStringLiteral("，可点击加载更多重试");
        }
        if (lane == 1) {
            return QStringLiteral("暂无喜欢的歌曲，在歌曲详情或播放栏点击红心即可加入");
        }
        if (lane == 2) {
            return QStringLiteral("暂无本地歌单，点击上方“创建歌单”开始整理");
        }
        return QStringLiteral("暂无") + columns[lane];
    }
    if (restoringAccount) {
        return QStringLiteral("正在恢复") + providerName() + QStringLiteral("登录，请稍候…");
    }
    if (!m_accountError.isEmpty()) {
        return m_accountError;
    }
    if (uid.isEmpty()) {
        return QStringLiteral("登录后查看个人音乐");
    }
    if (personalLoading) {
        return QStringLiteral("正在读取") + columns[lane] + QStringLiteral("，请稍候…");
    }
    if (!m_sourceErrors[lane].isEmpty()) {
        return m_sourceErrors[lane] + QStringLiteral("，可点击加载更多重试");
    }
    return QStringLiteral("暂无") + columns[lane];
}

QString MusicLibrary::accountKey() const {
    return provider == "kugou" ? "kugou-" + kugouEdition : provider;
}

QString MusicLibrary::identityName() const {
    if (isSiren()) {
        return {};
    }
    for (const auto &source : {"netease", "qq", "kugou"}) {
        if (!identityNames.value(source).isEmpty()) {
            return identityNames.value(source);
        }
    }
    return {};
}

QVector<int> MusicLibrary::sourceOrder() const {
    return provider == "kugou" ? QVector<int>{1, 2, 3, 0} : QVector<int>{1, 2, 3, 4, 0};
}

QString MusicLibrary::libraryName() const {
    if (directory) {
        return directory->item["title"].toString();
    }
    return groupLane == selectedLane ? groupName : columns.value(selectedLane);
}

QJsonArray MusicLibrary::sourceItems(int lane) const {
    if (lane < 0 || lane >= 5) {
        return {};
    }
    if (groupLane != lane) {
        return lists[lane];
    }
    QJsonArray result;
    for (const auto index : groupIndices) {
        if (index >= 0 && index < lists[lane].size()) {
            result.append(lists[lane].at(index));
        }
    }
    return result;
}

QJsonArray MusicLibrary::libraryItems() const {
    return directory ? directory->orderedSongs() : sourceItems(selectedLane);
}

int MusicLibrary::libraryTotal() const {
    if (directory) {
        return std::max({int(directory->ids.size()), directory->item["trackCount"].toInt(),
                         int(directory->songs.size())});
    }
    return groupLane == selectedLane ? int(sourceItems(selectedLane).size()) : totals[selectedLane];
}

int MusicLibrary::libraryIndex() const {
    if (directory) {
        return directory->index;
    }
    const auto row = std::max(0, int(physicalSlots[selectedLane].indexOf(selectedPhysical)));
    return wrap(offsets[selectedLane] + row, std::max(1, int(sourceItems(selectedLane).size())));
}

void MusicLibrary::setGroupView(QString name, QVector<int> indices, int lane) {
    if (lane < 0 || lane >= 5) {
        return;
    }
    groupName = name;
    groupIndices = indices;
    groupLane = name.isEmpty() ? -1 : lane;
    offsets[lane] = 0;
    rowMemory[lane] = 0;
    showSource(lane);
}

void MusicLibrary::observe(int selected) {
    if (directory) {
        observeDirectory(selected);
        return;
    }
    if (selectedPhysical == selected) {
        return;
    }
    int lane = -1;
    for (int i = 0; i < 5; ++i) {
        if (physicalSlots[i].contains(selected)) {
            lane = i;
            break;
        }
    }
    if (lane < 0) {
        return;
    }
    if (provider == "kugou" && lane == 4) {
        if (!physicalSlots[selectedLane].isEmpty()) {
            emit selectionRequested(physicalSlots[selectedLane].value(rowMemory[selectedLane]), {});
        }
        return;
    }
    selectedPhysical = selected;
    const auto row = int(physicalSlots[lane].indexOf(selected));
    selectedLane = lane;
    rowMemory[lane] = row;
    const auto values = sourceItems(lane);
    // 当前栏目选中单曲，替换队列。
    playContext = values;
    choose(values.isEmpty() ? QJsonObject{} : values.at(wrap(offsets[lane] + row, values.size())).toObject());
    if (lane > 0 && values.isEmpty()) {
        loadMoreSource(lane);
    }
}

/** 先发布当前选择，再延迟补齐详情；任何旧详情、封面或百科都由选择代数隔离。 */
void MusicLibrary::choose(QJsonObject input, bool containerDetails, std::optional<bool> showDetails) {
    const auto token = ++m_selectionGeneration;
    ++m_wikiGeneration;
    wantsSongDetails = showDetails.value_or(frame["mode"] == "detail");
    albumLoaded = false;
    trackCursor = 0;
    trackLoad = false;
    current = input;
    emit musicIdentityRequested(input.value("key").toString());
    tracks = {};
    trackIDs = {};
    if (coverKey != input.value("key").toString()) {
        coverImage.clear();
        coverKey.clear();
    }
    detailLoading = !input.isEmpty();
    changed();
    if (input.isEmpty()) {
        return;
    }
    current = details.value(input.value("key").toString(), input);
    loadCover(current);
    if (isLocal()) {
        detailLoading = false;
        details[input.value("key").toString()] = current;
        changed();
        return;
    }
    loadSubscriptionStatus(current);
    detailLoading = true;
    if (input.value("kind") != "song" && !containerDetails) {
        detailLoading = false;
        changed();
        return;
    }
    if (input.value("kind") == "song" && current.value("duration").toDouble() > 0 &&
        !current.value("albumID").toString().isEmpty() &&
        (!current.value("cover").toString().isEmpty() || details.contains(input.value("key").toString()))) {
        details[input.value("key").toString()] = current;
        detailLoading = false;
        if (wantsSongDetails) {
            loadSongWiki();
        }
        changed();
        return;
    }
    const auto alive = valid(token, &m_selectionGeneration);
    host->schedule(300, [this, input, alive] {
        if (!alive()) {
            return;
        }
        api.call(
            "detail", {input},
            [this, input, alive](MusicReply result) {
                const auto values = result.value.toArray();
                if (!result.ok() || values.isEmpty()) {
                    detailLoading = false;
                    status = QStringLiteral("读取失败：") +
                             (result.ok() ? QStringLiteral("元数据格式无效") : result.error);
                    changed();
                    return;
                }
                auto value = values.at(0).toObject();
                if (value["kind"] == "song") {
                    value["description"] = current.value("description").isUndefined()
                                               ? value["description"]
                                               : current.value("description");
                    value["wiki"] = current.value("wiki").toString();
                }
                if (!current.value("date").toString().isEmpty()) {
                    value["date"] = current.value("date");
                }
                // 详情接口可能不重复返回特殊歌单标记，沿用入口条目的判定结果。
                if (input.value("special").toBool()) {
                    value["special"] = true;
                }
                details[input.value("key").toString()] = value;
                for (qsizetype i = 0; i < lists[0].size(); ++i) {
                    if (lists[0].at(i).toObject()["key"] == input.value("key")) {
                        lists[0].replace(i, value);
                        break;
                    }
                }
                current = value;
                const auto songs = values.at(1).toArray();
                if (value["kind"] != "song" || !albumLoaded) {
                    tracks = songs;
                }
                trackIDs = values.at(2).toArray();
                trackCursor = MusicData::cursor(songs, trackIDs);
                detailLoading = false;
                if (status == "正在读取链接…") {
                    status = QStringLiteral("已读取：") + value["title"].toString();
                }
                loadCover(value);
                changed();
                if (value["kind"] == "song" && value["wiki"].toString().isEmpty() && wantsSongDetails) {
                    api.call(
                        "wiki", {value["id"]},
                        [this, input](MusicReply wiki) {
                            current["wiki"] = wiki.ok() ? wiki.value.toString()
                                                        : QStringLiteral("百科暂时无法读取：") + wiki.error;
                            if (wiki.ok()) {
                                details[input.value("key").toString()] = current;
                            }
                            changed();
                        },
                        alive);
                }
            },
            alive);
    });
}

void MusicLibrary::loadCover(const QJsonObject &value) {
    const auto alive = valid(m_selectionGeneration, &m_selectionGeneration);
    host->schedule(200, [this, value, alive] {
        if (alive()) {
            host->loadCover(value["cover"].toString(), [this, value, alive](QString key) {
                if (alive() && !key.isEmpty()) {
                    coverImage = key;
                    coverKey = value["key"].toString();
                    changed();
                }
            });
        }
    });
}

void MusicLibrary::search(QString text, QString kind, bool more) {
    if (isLocal()) {
        searchLocal(text, kind);
        return;
    }
    const auto link = provider == "netease" && !more ? host->fromLink(text) : QString();
    if (!link.isEmpty()) {
        const auto type = link.section(':', 0, 0);
        const auto value = MusicData::item(type, link.section(':', 1));
        ++m_generation;
        searchLoading = false;
        keyword = text;
        searchKind = type;
        lists[0] = {value};
        totals[0] = 1;
        offsets[0] = 0;
        hasMore[0] = false;
        rowMemory[0] = 0;
        status = QStringLiteral("正在读取链接…");
        showSource(0);
        wantsSongDetails = type == "song";
        emit modeRequested(type == "song" ? "detail" : "archive");
        return;
    }
    const auto query = text.trimmed();
    if (!more && query == keyword && (kind.isEmpty() || kind == searchKind) &&
        (!lists[0].isEmpty() || searchLoading)) {
        return;
    }
    const auto maximum = provider == "qq" ? 60 : 100;
    if (query.isEmpty() || query.toUcs4().size() > maximum) {
        // 输入被清空或越界后，旧结果已与当前关键词无关，必须一并清除。
        ++m_generation;
        searchLoading = false;
        keyword = query;
        groupLane = -1;
        groupName.clear();
        groupIndices.clear();
        lists[0] = {};
        totals[0] = 0;
        offsets[0] = 0;
        hasMore[0] = false;
        rowMemory[0] = 0;
        searchCursor = 0;
        status = QStringLiteral("请输入 1–") + QString::number(maximum) + QStringLiteral(" 字关键词");
        changed();
        return;
    }
    if (more && (searchLoading || !hasMore[0])) {
        return;
    }
    if (!kind.isEmpty()) {
        searchKind = kind;
    }
    keyword = query;
    const auto token = ++m_generation;
    const auto start = more ? searchCursor : 0;
    if (!more) {
        groupLane = -1;
        groupName.clear();
        groupIndices.clear();
        lists[0] = {};
        totals[0] = 0;
        offsets[0] = 0;
        searchCursor = 0;
        hasMore[0] = false;
        searchHistory.removeAll(query);
        searchHistory.prepend(query);
        while (searchHistory.size() > 12) {
            searchHistory.removeLast();
        }
        host->setPreference(
            "search-history",
            QString::fromUtf8(
                QJsonDocument(QJsonArray::fromStringList(searchHistory)).toJson(QJsonDocument::Compact)));
    }
    if (isSiren()) {
        searchSirenLocal(query, searchKind, start, more);
        return;
    }
    searchLoading = true;
    status = QStringLiteral("正在检索…");
    changed();
    api.call(
        "search", {query, searchKind, start},
        [this, start, more](MusicReply result) {
            searchLoading = false;
            if (!result.ok()) {
                status = QStringLiteral("检索失败：") + result.error;
                changed();
                return;
            }
            const auto page = result.value.toObject();
            const auto items = page["items"].toArray();
            lists[0] = more ? MusicData::unique(lists[0], items) : items;
            if (!more) {
                offsets[0] = 0;
            }
            searchCursor = start + page["rawCount"].toInt();
            hasMore[0] = page["more"].toBool();
            totals[0] = std::max(page["total"].toInt(), int(lists[0].size()));
            status = page["notice"].toString();
            if (status.isEmpty()) {
                status = items.isEmpty() ? QStringLiteral("没有匹配的音乐")
                                         : QStringLiteral("找到 ") + QString::number(totals[0]) +
                                               QStringLiteral(" 条结果");
            }
            if (!more) {
                showSource(0);
                emit modeRequested("archive");
                frame["mode"] = "archive";
            }
            changed();
        },
        valid(token, &m_generation));
}

void MusicLibrary::suggest(QString text) {
    const auto token = ++m_suggestGeneration;
    suggestions.clear();
    if (text.trimmed().isEmpty() || provider == "kugou" || isLocal() || isSiren()) {
        return;
    }
    const auto qq = provider == "qq";
    api.request(
        "/search/suggest",
        qq ? QJsonObject{{"keyword", text}} : QJsonObject{{"keywords", text}, {"type", "mobile"}},
        [this, qq](MusicReply result) {
            if (!result.ok()) {
                return;
            }
            const auto body = result.value.toObject();
            // QQ 直接给搜索词字符串，网易云仍是带 keyword 字段的条目。
            const auto values =
                qq ? body["suggestions"].toArray() : body["result"].toObject()["allMatch"].toArray();
            for (const auto &value : values) {
                const auto keyword = qq ? value : value.toObject()["keyword"];
                if (keyword.isString() && suggestions.size() < 4) {
                    suggestions.append(keyword.toString());
                }
            }
        },
        valid(token, &m_suggestGeneration));
}

void MusicLibrary::showSource(int lane) {
    if (lane < 0 || lane >= 5) {
        return;
    }
    if (provider == "kugou" && lane == 4) {
        status = QStringLiteral("酷狗 API 未提供收藏专辑，此栏目已禁用");
        changed();
        return;
    }
    privateSelection = lane > 0 && !isLocal() && !isSiren();
    if (directory) {
        leaveDirectory(false);
    }
    selectedLane = lane;
    selectedPhysical = -1;
    const auto physical = physicalSlots[lane].value(rowMemory[lane], -1);
    emit selectionRequested(physical, {});
    observe(physical);
    if (isSiren()) {
        if (lane > 0 && lists[lane].isEmpty()) {
            loadMoreSource(lane);
        }
    } else if (lane > 0 && !isLocal()) {
        if (restoringAccount) {
            loadMoreSource(lane);
        } else if (uid.isEmpty()) {
            status = QStringLiteral("登录后查看") + columns[lane];
        } else if (lists[lane].isEmpty()) {
            loadMoreSource(lane);
        }
    }
    changed();
}

/** 串行读回当前 QQ 个人库，清理旧缓存与分页游标。 */
void MusicLibrary::refreshPersonal(int lane) {
    if (provider != "qq" || uid.isEmpty() || lane < 1 || lane > 4 || personalLoading || writeLoading ||
        accountLoading) {
        return;
    }
    host->invalidateMetadata();
    const auto reset = [this](int source) {
        lists[source] = {};
        totals[source] = 0;
        hasMore[source] = true;
    };
    reset(lane);
    if (lane == 1) {
        likedCursor = 0;
        likedIDs.reset();
    } else if (lane == 4) {
        albumCursor = 0;
    } else {
        reset(2);
        reset(3);
        playlistCursor = 0;
    }
    loadMoreSource(lane);
}

void MusicLibrary::selectResult(int index, int lane, bool open) {
    if (lane < 0 || lane >= 5 || index < 0 || index >= lists[lane].size()) {
        return;
    }
    if (directory) {
        leaveDirectory(false);
    }
    auto viewIndex = index;
    if (groupLane == lane) {
        viewIndex = groupIndices.indexOf(index);
        if (viewIndex < 0) {
            groupLane = -1;
            viewIndex = index;
        }
    }
    offsets[lane] = viewIndex / 8 * 8;
    selectedPhysical = -1;
    // 点击结果列表时同步播放上下文
    playContext = sourceItems(lane);
    const auto physical = physicalSlots[lane].value(viewIndex % 8, -1);
    emit selectionRequested(physical, {});
    const auto mode = open && lists[lane].at(index).toObject()["kind"] == "song" ? "detail" : "archive";
    emit modeRequested(mode);
    frame["mode"] = mode;
    observe(physical);
    if (open && current.value("kind") != "song") {
        enterDirectory(current);
    }
}

void MusicLibrary::next(int direction) {
    if (directory) {
        navigateDirectory(direction, "row");
        return;
    }
    const auto row = int(physicalSlots[selectedLane].indexOf(selectedPhysical));
    const auto count = int(sourceItems(selectedLane).size());
    if (row < 0 || count == 0) {
        return;
    }
    const auto absolute = wrap(offsets[selectedLane] + row, count);
    const auto raw = absolute + direction;
    if (raw >= count && hasMore[selectedLane] && groupLane != selectedLane) {
        loadMoreSource(selectedLane);
        return;
    }
    const auto next = wrap(raw, count);
    const auto target = wrap(row + direction, 8);
    offsets[selectedLane] = next - target;
    emit navigationRequested("row", direction);
    selectedPhysical = -1;
    changed();
}

/** 收束串行个人库请求，并接续等待期间用户最后选择的栏目，失败不自动重试。 */
void MusicLibrary::completePersonal(int lane, QString error) {
    personalLoading = false;
    m_sourceErrors[lane] = error;
    if (lane == 2 || lane == 3) {
        m_sourceErrors[2] = error;
        m_sourceErrors[3] = error;
    }
    status = error.isEmpty() ? QStringLiteral("已读取个人音乐") : error;
    const auto selectedPlaylists = (lane == 2 || lane == 3) && (selectedLane == 2 || selectedLane == 3);
    if (error.isEmpty() && (selectedLane == lane || selectedPlaylists) && current.isEmpty()) {
        selectedPhysical = -1;
        observe(frame["selected"].toInt(physicalSlots[selectedLane].value(0, -1)));
    }
    const auto pending = m_pendingLane;
    m_pendingLane = -1;
    const auto samePlaylists = (lane == 2 || lane == 3) && (pending == 2 || pending == 3);
    if (pending > 0 && pending != lane && !samePlaylists && lists[pending].isEmpty()) {
        loadMoreSource(pending);
    }
    if (lane == 1 && m_playLiked) {
        m_playLiked = false;
        if (error.isEmpty() && selectedLane == 1 && !directory) {
            playDirectory();
        }
    }
    changed();
}

void MusicLibrary::loadLikedIDs(int lane, quint64 token, QString user) {
    const auto alive = valid(token, &m_accountGeneration);
    const auto fetch = [this, lane, user, alive](QJsonArray ids) {
        const auto chunk = MusicData::slice(ids, likedCursor, 100);
        api.call(
            "songs", {QJsonValue(chunk)},
            [this, lane, user, ids, chunk](MusicReply result) {
                if (uid != user) {
                    return;
                }
                if (!result.ok()) {
                    completePersonal(lane, result.error);
                    return;
                }
                likedIDs = ids;
                likedCursor += chunk.size();
                lists[1] = MusicData::unique(lists[1], MusicData::ordered(chunk, result.value.toArray()));
                totals[1] = int(ids.size());
                hasMore[1] = likedCursor < ids.size();
                completePersonal(lane);
            },
            alive);
    };
    if (likedIDs) {
        fetch(*likedIDs);
    } else {
        api.call(
            "likedIDs", {user},
            [this, lane, fetch](MusicReply result) {
                if (!result.ok()) {
                    completePersonal(lane, result.error);
                    return;
                }
                fetch(result.value.toArray());
            },
            alive);
    }
}

void MusicLibrary::loadMoreSource(int lane) {
    if (isLocal()) {
        return;
    }
    if (lane < 0 || lane >= 5) {
        return;
    }
    if (isSiren()) {
        if (lane == 0) {
            search(keyword, {}, true);
        } else {
            loadSirenSource(lane);
        }
        return;
    }
    if (provider == "kugou" && lane == 4) {
        hasMore[4] = false;
        status = QStringLiteral("酷狗 API 未提供收藏专辑，此栏目已禁用");
        changed();
        return;
    }
    if (lane > 0 && (restoringAccount || personalLoading)) {
        m_pendingLane = lane;
        changed();
        return;
    }
    if (!hasMore[lane]) {
        return;
    }
    if (lane == 0) {
        search(keyword, {}, true);
        return;
    }
    if (!m_accountError.isEmpty() && host->authenticated()) {
        m_pendingLane = lane;
        restoreAccount();
        return;
    }
    if (uid.isEmpty()) {
        status = QStringLiteral("请登录") + providerName();
        changed();
        return;
    }
    personalLoading = true;
    m_sourceErrors[lane].clear();
    const auto token = m_accountGeneration;
    const auto user = uid;
    changed();
    if (lane == 1 && provider == "netease") {
        loadLikedIDs(lane, token, user);
        return;
    }
    QString operation;
    QJsonArray arguments;
    if (lane == 1) {
        operation = "likedSongs";
        arguments = {likedCursor};
    } else if (lane == 4) {
        operation = "likedAlbums";
        arguments = {albumCursor};
    } else {
        operation = "userPlaylists";
        arguments = {user};
    }
    api.call(
        operation, arguments,
        [this, lane, user](MusicReply result) {
            if (uid != user) {
                return;
            }
            if (!result.ok()) {
                completePersonal(lane, result.error);
                return;
            }
            const auto page = result.value.toObject();
            const auto items = page["items"].toArray();
            if (lane == 1) {
                likedCursor += page["rawCount"].toInt();
                lists[1] = MusicData::unique(lists[1], items);
                QJsonArray ids;
                for (const auto &value : lists[1]) {
                    ids.append(value.toObject()["id"]);
                }
                likedIDs = ids;
                totals[1] = page["total"].toInt();
                hasMore[1] = page["more"].toBool();
            } else if (lane == 4) {
                albumCursor += page["rawCount"].toInt();
                lists[4] = MusicData::unique(lists[4], items);
                totals[4] = std::max(page["total"].toInt(), int(lists[4].size()));
                hasMore[4] = page["more"].toBool();
            } else {
                playlistCursor += page["rawCount"].toInt();
                QJsonArray owned;
                QJsonArray collected;
                for (const auto &value : items) {
                    if (value.toObject()["creatorID"] == user) {
                        owned.append(value);
                    } else {
                        collected.append(value);
                    }
                }
                lists[2] = MusicData::unique(lists[2], owned);
                lists[3] = MusicData::unique(lists[3], collected);
                for (const auto index : {2, 3}) {
                    totals[index] = int(lists[index].size());
                    hasMore[index] = page["more"].toBool();
                }
            }
            completePersonal(lane);
            if (page["incomplete"].toBool()) {
                status = QStringLiteral("已读取部分歌单，上游未提供可靠的后续页，请稍后刷新");
                changed();
            }
        },
        valid(token, &m_accountGeneration));
}

void MusicLibrary::loadTrackPage(int start) {
    if (isLocal()) {
        return;
    }
    if (current.isEmpty() || trackLoad || start + 3 < tracks.size() || trackCursor >= trackIDs.size()) {
        return;
    }
    trackLoad = true;
    const auto ids = MusicData::slice(trackIDs, trackCursor, 100);
    api.call(
        "songs", {QJsonValue(ids)},
        [this, ids](MusicReply result) {
            if (result.ok()) {
                trackCursor += ids.size();
                tracks = MusicData::unique(tracks, MusicData::ordered(ids, result.value.toArray()));
            } else {
                status = result.error;
            }
            trackLoad = false;
            changed();
        },
        valid(m_selectionGeneration, &m_selectionGeneration));
}

void MusicLibrary::sameAlbum() {
    if (isLocal()) {
        tracks = local->tracks({{"kind", "album"}, {"id", current.value("albumID")}});
        albumLoaded = true;
        changed();
        return;
    }
    const auto song = current;
    if (song["kind"] != "song" || detailLoading || song["albumID"].toString().isEmpty() || albumLoaded) {
        return;
    }
    albumLoaded = true;
    api.call(
        "detail",
        {MusicData::item("album", song["albumID"].toString(), song["album"].toString(),
                         song["artist"].toString(), provider)},
        [this](MusicReply result) {
            if (result.ok()) {
                const auto values = result.value.toArray();
                const auto album = values.at(0).toObject();
                current["description"] = album["description"];
                current["date"] = album["date"];
                tracks = values.at(1).toArray();
            } else {
                albumLoaded = false;
                status = result.error;
            }
            changed();
        },
        valid(m_selectionGeneration, &m_selectionGeneration));
}

void MusicLibrary::loadSongWiki() {
    if (isLocal()) {
        return;
    }
    wantsSongDetails = true;
    const auto value = current;
    if (value["kind"] != "song" || detailLoading || !value["wiki"].toString().isEmpty()) {
        return;
    }
    const auto token = m_selectionGeneration;
    const auto wikiToken = ++m_wikiGeneration;
    const auto selected = valid(token, &m_selectionGeneration);
    const auto wiki = valid(wikiToken, &m_wikiGeneration);
    api.call(
        "wiki", {value["id"]},
        [this, value](MusicReply result) {
            if (result.ok()) {
                current["wiki"] = result.value;
                details[value["key"].toString()] = current;
            } else {
                status = QStringLiteral("百科暂不可读取：") + result.error;
            }
            changed();
        },
        [selected, wiki] { return selected() && wiki(); });
}

/**
 * 播放当前单曲。
 * 用当前单曲所在的歌曲列表替换播放队列；未加载的 ID 由队列模块补全，不会生成占位曲目。
 */
void MusicLibrary::play(bool byUser) {
    if (current.value("kind") != "song") {
        status = QStringLiteral("请先选择一首歌曲");
        changed();
        return;
    }
    const bool replaceQueue = byUser && host->preference("single-play-mode") != "append";
    if (!replaceQueue) {
        player.play(current);
        return;
    }
    const auto source = currentSource();
    player.play(current, source.items);
    player.loadQueue(source.ids, source.items);
}

/** 当前单曲所在的歌曲列表；目录外优先使用选中上下文。 */
MusicLibrary::QueueSource MusicLibrary::currentSource() const {
    auto source = directorySource();
    const auto id = current.value("id").toString();
    const bool loaded = MusicData::indexOfId(source.items, id) >= 0;
    const bool listed = !source.ids.isEmpty() && source.ids.contains(QJsonValue(id));
    if (loaded || listed) {
        return source;
    }
    if (!playContext.isEmpty() && MusicData::indexOfId(playContext, id) >= 0) {
        return {QJsonArray{}, playContext};
    }
    return {QJsonArray{}, libraryItems()};
}

/** 目录或喜欢列表的完整 ID 顺序与已加载曲目。 */
MusicLibrary::QueueSource MusicLibrary::directorySource() const {
    QueueSource source;
    if (directory) {
        source.items = directory->orderedSongs();
        if (directory->sortField == "none") {
            source.ids = directory->ids;
            return source;
        }
        QSet<QString> loaded;
        for (const auto &song : source.items) {
            const auto id = song.toObject()["id"].toString();
            source.ids.append(id);
            loaded.insert(id);
        }
        for (const auto &id : directory->ids) {
            if (!loaded.contains(id.toString())) {
                source.ids.append(id);
            }
        }
        return source;
    }
    if (isSiren() && selectedLane == 3) {
        source.items = lists[3];
        for (const auto &value : lists[3]) {
            source.ids.append(value.toObject()["id"]);
        }
        return source;
    }
    if (selectedLane == 1) {
        source.items = lists[1];
        if (likedIDs) {
            source.ids = *likedIDs;
        }
    }
    return source;
}

/** 一键播放 */
void MusicLibrary::playDirectory() {
    if (!directory && selectedLane != 1 && !(isSiren() && selectedLane == 3)) {
        return;
    }
    // 补全喜欢的歌曲后再播放
    if (!directory && selectedLane == 1 && !isLocal() && hasMore[1]) {
        m_playLiked = true;
        loadMoreSource(1);
        return;
    }
    const auto source = directorySource();
    if (source.items.isEmpty()) {
        return;
    }
    player.play(source.items.first().toObject(), source.items);
    player.loadQueue(source.ids, source.items);
}

void MusicLibrary::playOfficial(QJsonObject value) {
    if (!PlatformFeatures::OfficialPlayback) {
        return;
    }
    if (isLocal()) {
        return;
    }
    if (value.isEmpty()) {
        value = current;
    }
    if (value["kind"] != "song") {
        return;
    }
    if (value["provider"].toString(provider) != "netease") {
        host->open(sourceURL(value));
        return;
    }
    host->playOfficial(value["id"].toString(), [owner = QPointer(this)](QString message) {
        if (owner) {
            owner->status = message;
            owner->changed();
        }
    });
}

QString MusicLibrary::sourceURL(QJsonObject value) const {
    if (isLocal()) {
        return {};
    }
    if (value.isEmpty()) {
        value = current;
    }
    if (value.isEmpty()) {
        return {};
    }
    const auto source = value["provider"].toString(provider);
    if (source == "netease") {
        return "https://music.163.com/#/" + value["kind"].toString() + "?id=" + value["id"].toString();
    }
    if (source == "kugou") {
        return QStringLiteral("https://www.kugou.com/");
    }
    if (source == "siren") {
        return QStringLiteral("https://monster-siren.hypergryph.com/music");
    }
    const QHash<QString, QString> paths{{"song", "songDetail"},
                                        {"album", "albumDetail"},
                                        {"artist", "singer"},
                                        {"playlist", value["chart"].toBool() ? "toplist" : "playlist"}};
    return "https://y.qq.com/n/ryqq/" + paths.value(value["kind"].toString()) + "/" +
           QString::fromLatin1(QUrl::toPercentEncoding(value["id"].toString(), "!'()*"));
}
