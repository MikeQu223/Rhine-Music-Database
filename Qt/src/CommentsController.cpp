#include "CommentsController.h"
#include "LyricsController.h"
#include "ProviderRegistry.h"
#include <QDateTime>
#include <QJsonArray>
#include <QPointer>
#include <QRegularExpression>
#include <algorithm>
#include <cmath>

namespace {
constexpr int FloorSize = 20;
constexpr int MaximumContent = 4000;

QString scalar(const QJsonValue &value) {
    if (value.isString()) {
        return value.toString();
    }
    if (value.isDouble()) {
        const auto number = value.toDouble();
        if (std::isfinite(number)) {
            return QString::number(qint64(number));
        }
    }
    return {};
}

QString comparable(QString value) {
    static const QRegularExpression remove(QStringLiteral("[\\s\\p{P}\\p{S}]"),
                                           QRegularExpression::UseUnicodePropertiesOption);
    return value.normalized(QString::NormalizationForm_KC).toLower().remove(remove);
}

QString cleanContent(QString value) {
    value = value.trimmed();
    if (value.size() > MaximumContent) {
        value.truncate(MaximumContent);
    }
    return value;
}

bool sirenArtist(const QJsonObject &candidate) {
    const auto text = comparable(candidate["artist"].toString());
    return text.contains(QString::fromUtf8("塞壬")) || text.contains(QStringLiteral("siren")) ||
           text.contains(QStringLiteral("monstersiren"));
}

QString normalizedNickname(const QJsonObject &user) {
    const auto nickname = user["nickname"].toString().trimmed();
    return nickname.isEmpty() ? QStringLiteral("用户") : nickname;
}
}

QString CommentsController::trackKey(const QJsonObject &track) {
    if (track.isEmpty()) {
        return {};
    }
    return track["provider"].toString() + ":" + track["id"].toString();
}

QString CommentsController::commentsProvider(const QString &provider) {
    const auto &registry = ProviderRegistry::instance();
    const auto supported = [&](const QString &id) {
        return registry.descriptor(id)["operations"].toObject()["comments"].toBool();
    };
    if (provider != "siren" && supported(provider)) {
        return provider;
    }
    if (provider != "siren") {
        return {};
    }
    for (const auto &id : registry.ids()) {
        if (id != "local" && id != "siren" && supported(id)) {
            return id;
        }
    }
    return {};
}

QString CommentsController::relativeTime(double milliseconds) {
    if (!(milliseconds > 0) || !std::isfinite(milliseconds)) {
        return {};
    }
    const auto now = QDateTime::currentMSecsSinceEpoch();
    const auto gap = std::max<qint64>(0, now - qint64(milliseconds));
    if (gap < 60 * 1000) {
        return QStringLiteral("刚刚");
    }
    if (gap < 60 * 60 * 1000) {
        return QString::number(gap / (60 * 1000)) + QStringLiteral(" 分钟前");
    }
    if (gap < 24 * 60 * 60 * 1000) {
        return QString::number(gap / (60 * 60 * 1000)) + QStringLiteral(" 小时前");
    }
    if (gap < 30LL * 24 * 60 * 60 * 1000) {
        return QString::number(gap / (24 * 60 * 60 * 1000)) + QStringLiteral(" 天前");
    }
    return QDateTime::fromMSecsSinceEpoch(qint64(milliseconds)).toString(QStringLiteral("yyyy-MM-dd"));
}

QString CommentsController::compactCount(int value) {
    if (value < 10000) {
        return QString::number(value);
    }
    auto text = QString::number(value / 10000.0, 'f', 1);
    if (text.endsWith(QStringLiteral(".0"))) {
        text.chop(2);
    }
    return text + QStringLiteral(" 万");
}

CommentsController::CommentsController(Host *host, QObject *parent)
    : QObject(parent), m_host(host), m_api(host) {
}

MusicApi::Valid CommentsController::valid(quint64 generation) {
    return [owner = QPointer(this), generation] {
        return owner && owner->m_generation == generation;
    };
}

void CommentsController::clear() {
    ++m_generation;
    m_trackKey.clear();
    m_trackProvider.clear();
    m_track = {};
    m_targetID.clear();
    m_cursor.clear();
    m_pages = 0;
    m_matches.clear();
    m_avatarRequests.clear();
    m_avatarKeys.clear();
    resetItems();
    sort = "hot";
    status = "idle";
    message.clear();
    sourceLabel.clear();
    sourceName.clear();
    trackName.clear();
    total = 0;
    hasMore = false;
    loadingMore = false;
    emit changed();
}

void CommentsController::resetItems() {
    items.clear();
}

int CommentsController::indexOf(const QString &commentId) const {
    for (int index = 0; index < items.size(); ++index) {
        if (items.at(index)["id"].toString() == commentId) {
            return index;
        }
    }
    return -1;
}

QJsonObject CommentsController::normalizeReply(const QJsonObject &raw, bool nested) const {
    const auto user = raw["user"].toObject();
    auto content = cleanContent(raw["content"].toString());
    if (content.isEmpty()) {
        return {};
    }
    const auto id = raw["id"].toString().isEmpty() ? scalar(raw["commentId"]) : scalar(raw["id"]);
    QJsonObject reply{{"id", id},
                      {"content", content},
                      {"nickname", raw["nickname"].toString().isEmpty()
                                       ? normalizedNickname(user)
                                       : raw["nickname"].toString().trimmed()},
                      {"userId", raw["userId"].toString().isEmpty() ? scalar(user["userId"])
                                                                   : scalar(raw["userId"])},
                      {"time", raw["time"].toDouble()}};
    if (reply["id"].toString().isEmpty()) {
        return {};
    }
    auto replyTo = raw["replyTo"].toString().trimmed();
    if (replyTo.isEmpty() && nested) {
        const auto replied = raw["beReplied"].toArray();
        if (!replied.isEmpty()) {
            replyTo = replied.first().toObject()["user"].toObject()["nickname"].toString().trimmed();
        }
    }
    if (!replyTo.isEmpty()) {
        reply["replyTo"] = replyTo;
    }
    return reply;
}

QJsonObject CommentsController::normalizeComment(const QJsonObject &raw) const {
    const auto user = raw["user"].toObject();
    auto content = cleanContent(raw["content"].toString());
    if (content.isEmpty()) {
        const bool media = !raw["contentPicUrl"].toString().isEmpty() || raw["contentStickerExt"].isObject() ||
                           raw["contentStickerExt"].isArray();
        if (!media) {
            return {};
        }
        content = QStringLiteral("图片评论");
    }
    const auto id = raw["id"].toString().isEmpty() ? scalar(raw["commentId"]) : scalar(raw["id"]);
    if (id.isEmpty()) {
        return {};
    }
    QJsonObject item{{"id", id},
                     {"content", content},
                     {"nickname", raw["nickname"].toString().isEmpty()
                                      ? normalizedNickname(user)
                                      : raw["nickname"].toString().trimmed()},
                     {"userId", raw["userId"].toString().isEmpty() ? scalar(user["userId"])
                                                                  : scalar(raw["userId"])},
                     {"avatarUrl", raw["avatarUrl"].toString().isEmpty() ? user["avatarUrl"].toString()
                                                                        : raw["avatarUrl"].toString()},
                     {"time", raw["time"].toDouble()},
                     {"likedCount", raw["likedCount"].toInt()},
                     {"replyCount", raw["replyCount"].toInt()},
                     {"expanded", false},
                     {"replies", QJsonArray{}},
                     {"repliesExpanded", false},
                     {"repliesHasMore", false},
                     {"repliesLoading", false},
                     {"repliesTime", QString()}};
    QJsonArray inlineReplies;
    const auto inlineValues = raw["inlineReplies"].isArray() ? raw["inlineReplies"].toArray()
                                                             : raw["beReplied"].toArray();
    for (const auto &value : inlineValues) {
        const auto reply = normalizeReply(value.toObject(), false);
        if (!reply.isEmpty() && inlineReplies.size() < 2) {
            inlineReplies.append(reply);
        }
    }
    item["inlineReplies"] = inlineReplies;
    auto location = raw["location"].toString().trimmed();
    if (location.isEmpty()) {
        location = raw["ipLocation"].toObject()["location"].toString().trimmed();
    }
    if (!location.isEmpty()) {
        item["location"] = location;
    }
    return item;
}

void CommentsController::load(const QJsonObject &track, bool retry) {
    const auto key = trackKey(track);
    if (key.isEmpty() || track["kind"] != "song") {
        return;
    }
    if (key == m_trackKey && !retry && status != "error" && status != "empty" && status != "idle") {
        return;
    }
    const bool sameTrack = key == m_trackKey;
    const auto provider = track["provider"].toString();
    const auto commentProvider = commentsProvider(provider);
    if (commentProvider.isEmpty()) {
        ++m_generation;
        m_trackKey = key;
        m_trackProvider = provider;
        m_commentProvider.clear();
        m_track = track;
        trackName = track["title"].toString();
        sourceName = ProviderRegistry::instance().name(provider);
        resetItems();
        m_targetID.clear();
        m_pages = 0;
        m_cursor.clear();
        total = 0;
        hasMore = false;
        loadingMore = false;
        status = "empty";
        message = QStringLiteral("当前来源不支持歌曲评论");
        emit changed();
        return;
    }
    ++m_generation;
    m_trackKey = key;
    m_trackProvider = provider;
    m_commentProvider = commentProvider;
    m_track = track;
    trackName = track["title"].toString();
    sourceName = ProviderRegistry::instance().name(commentProvider);
    m_api.provider = commentProvider;
    if (!sameTrack) {
        sourceLabel.clear();
        m_avatarRequests.clear();
        m_avatarKeys.clear();
    }
    resetItems();
    m_targetID.clear();
    m_pages = 0;
    m_cursor.clear();
    total = 0;
    hasMore = false;
    loadingMore = false;
    message.clear();
    if (m_host->offline && !m_host->fixture) {
        status = "error";
        message = QStringLiteral("离线状态下无法读取评论");
        emit changed();
        return;
    }
    status = "loading";
    if (provider == "siren") {
        if (m_matches.contains(key)) {
            m_targetID = m_matches.value(key);
            message = QStringLiteral("正在读取评论…");
            emit changed();
            fetchPage(m_generation, true);
            return;
        }
        message = QStringLiteral("正在匹配评论来源…");
        emit changed();
        resolveSiren(m_generation);
        return;
    }
    m_targetID = track["id"].toString();
    if (m_targetID.isEmpty()) {
        status = "error";
        message = QStringLiteral("歌曲标识无效");
        emit changed();
        return;
    }
    message = QStringLiteral("正在读取评论…");
    emit changed();
    fetchPage(m_generation, true);
}

void CommentsController::resolveSiren(quint64 generation) {
    QStringList queries{m_track["title"].toString().trimmed() + " " + m_track["artist"].toString().trimmed(),
                        m_track["title"].toString().trimmed()};
    queries.removeAll(QString());
    queries.removeDuplicates();
    if (queries.isEmpty()) {
        status = "empty";
        message = QStringLiteral("未找到可用的评论来源");
        emit changed();
        return;
    }
    searchSiren(generation, queries, 0);
}

void CommentsController::searchSiren(quint64 generation, const QStringList &queries, int query) {
    if (!valid(generation)()) {
        return;
    }
    if (query >= queries.size()) {
        status = "empty";
        message = QStringLiteral("未找到可用的评论来源");
        emit changed();
        return;
    }
    m_api.call(
        "search", {queries.at(query), "song", 0},
        [this, generation, queries, query](MusicReply reply) {
            if (!valid(generation)()) {
                return;
            }
            if (!reply.ok()) {
                status = "error";
                message = QStringLiteral("匹配评论来源失败，请重试");
                emit changed();
                return;
            }
            const auto candidates = reply.value.toObject()["items"].toArray();
            QJsonObject best;
            for (const auto &value : candidates) {
                const auto candidate = value.toObject();
                if (!LyricsController::sameRecording(m_track, candidate)) {
                    continue;
                }
                if (best.isEmpty() || (!sirenArtist(best) && sirenArtist(candidate))) {
                    best = candidate;
                }
            }
            if (best.isEmpty()) {
                searchSiren(generation, queries, query + 1);
                return;
            }
            m_targetID = best["id"].toString();
            if (m_targetID.isEmpty()) {
                searchSiren(generation, queries, query + 1);
                return;
            }
            m_matches.insert(m_trackKey, m_targetID);
            const auto title = best["title"].toString();
            const auto artist = best["artist"].toString();
            sourceLabel = artist.isEmpty() ? title : title + " / " + artist;
            message = QStringLiteral("正在读取评论…");
            emit changed();
            fetchPage(generation, true);
        },
        valid(generation));
}

void CommentsController::fetchPage(quint64 generation, bool first) {
    if (m_targetID.isEmpty()) {
        return;
    }
    if (first) {
        resetItems();
        m_pages = 0;
        m_cursor.clear();
        total = 0;
        hasMore = false;
        status = "loading";
        loadingMore = false;
        message = m_trackProvider == "siren" ? QStringLiteral("正在读取评论…") : message;
        emit changed();
    }
    const QJsonArray arguments{QJsonValue(m_track), QJsonValue(m_targetID), QJsonValue(sort),
                               QJsonValue(m_pages), QJsonValue(m_cursor)};
    m_api.call(
        "comments", arguments,
        [this, generation, first](MusicReply reply) {
            if (!valid(generation)()) {
                return;
            }
            if (!reply.ok()) {
                if (first) {
                    failFirstPage(reply.error.isEmpty() ? QStringLiteral("评论暂不可用，请重试")
                                                        : reply.error);
                } else {
                    loadingMore = false;
                    message = QStringLiteral("加载更多失败，请重试");
                    emit changed();
                }
                return;
            }
            applyPage(reply.value.toObject(), first);
        },
        valid(generation));
}

void CommentsController::applyPage(const QJsonObject &body, bool first) {
    const auto data = body["data"].toObject();
    const auto values = body["comments"].isArray() ? body["comments"].toArray()
                                                  : data["comments"].toArray();
    if (first) {
        resetItems();
    }
    QSet<QString> seen;
    for (const auto &item : items) {
        seen.insert(item["id"].toString());
    }
    for (const auto &value : values) {
        const auto item = normalizeComment(value.toObject());
        const auto id = item["id"].toString();
        if (id.isEmpty() || seen.contains(id)) {
            continue;
        }
        seen.insert(id);
        items.append(item);
        ensureAvatar(item["avatarUrl"].toString());
    }
    ++m_pages;
    const auto reportedTotal =
        body.contains("totalCount") ? body["totalCount"].toInt()
                                    : (data.contains("totalCount") ? data["totalCount"].toInt()
                                                                   : body["total"].toInt(total));
    total = std::max(total, reportedTotal);
    hasMore = body.contains("hasMore") ? body["hasMore"].toBool()
                                       : (data.contains("hasMore") ? data["hasMore"].toBool()
                                                                   : data["more"].toBool(false));
    m_cursor = body["cursor"].toString(scalar(data["cursor"]));
    loadingMore = false;
    status = items.isEmpty() ? "empty" : "ready";
    message.clear();
    emit changed();
}

void CommentsController::failFirstPage(const QString &error) {
    status = "error";
    message = error;
    loadingMore = false;
    emit changed();
}

void CommentsController::refresh() {
    if (m_trackKey.isEmpty()) {
        return;
    }
    load(m_track, true);
}

void CommentsController::loadMore() {
    if (status != "ready" || !hasMore || loadingMore || m_targetID.isEmpty()) {
        return;
    }
    loadingMore = true;
    message.clear();
    emit changed();
    fetchPage(m_generation, false);
}

void CommentsController::setSort(const QString &value) {
    if ((value != "hot" && value != "new") || value == sort) {
        return;
    }
    sort = value;
    if (m_trackKey.isEmpty() || m_targetID.isEmpty()) {
        return;
    }
    ++m_generation;
    resetItems();
    m_pages = 0;
    m_cursor.clear();
    total = 0;
    hasMore = false;
    loadingMore = false;
    status = "loading";
    message = QStringLiteral("正在读取评论…");
    emit changed();
    fetchPage(m_generation, true);
}

void CommentsController::toggleExpanded(const QString &commentId) {
    const auto index = indexOf(commentId);
    if (index < 0) {
        return;
    }
    auto item = items.at(index);
    item["expanded"] = !item["expanded"].toBool();
    items[index] = item;
    emit changed();
}

void CommentsController::toggleReplies(const QString &commentId) {
    const auto index = indexOf(commentId);
    if (index < 0) {
        return;
    }
    auto item = items.at(index);
    if (item["repliesExpanded"].toBool()) {
        item["repliesExpanded"] = false;
        items[index] = item;
        emit changed();
        return;
    }
    if (!item["replies"].toArray().isEmpty()) {
        item["repliesExpanded"] = true;
        items[index] = item;
        emit changed();
        return;
    }
    if (item["repliesLoading"].toBool()) {
        return;
    }
    item["repliesLoading"] = true;
    item["repliesError"] = QString();
    items[index] = item;
    emit changed();
    fetchFloor(m_generation, commentId, true);
}

void CommentsController::loadMoreReplies(const QString &commentId) {
    const auto index = indexOf(commentId);
    if (index < 0) {
        return;
    }
    auto item = items.at(index);
    if (!item["repliesHasMore"].toBool() || item["repliesLoading"].toBool()) {
        return;
    }
    item["repliesLoading"] = true;
    item["repliesError"] = QString();
    items[index] = item;
    emit changed();
    fetchFloor(m_generation, commentId, false);
}

void CommentsController::fetchFloor(quint64 generation, const QString &commentId, bool first) {
    const auto index = indexOf(commentId);
    if (index < 0 || m_targetID.isEmpty()) {
        return;
    }
    const auto item = items.at(index);
    const auto time = first ? QStringLiteral("-1") : item["repliesTime"].toString();
    const QJsonArray arguments{QJsonValue(m_track), QJsonValue(m_targetID), QJsonValue(commentId),
                               QJsonValue(time.isEmpty() ? QStringLiteral("-1") : time),
                               QJsonValue(FloorSize)};
    m_api.call(
        "commentReplies", arguments,
        [this, generation, commentId, first](MusicReply reply) {
            if (!valid(generation)()) {
                return;
            }
            const auto index = indexOf(commentId);
            if (index < 0) {
                return;
            }
            auto item = items.at(index);
            if (!reply.ok()) {
                item["repliesLoading"] = false;
                item["repliesError"] = reply.error.isEmpty() ? QStringLiteral("回复加载失败") : reply.error;
                items[index] = item;
                emit changed();
                return;
            }
            applyFloor(commentId, reply.value.toObject(), first);
        },
        valid(generation));
}

void CommentsController::applyFloor(const QString &commentId, const QJsonObject &body, bool first) {
    const auto index = indexOf(commentId);
    if (index < 0) {
        return;
    }
    auto item = items.at(index);
    const auto data = body["data"].toObject();
    const auto values = body["comments"].isArray() ? body["comments"].toArray()
                                                  : data["comments"].toArray();
    QJsonArray replies = first ? QJsonArray{} : item["replies"].toArray();
    QSet<QString> seen;
    for (const auto &value : replies) {
        seen.insert(value.toObject()["id"].toString());
    }
    for (const auto &value : values) {
        const auto reply = normalizeReply(value.toObject(), true);
        const auto id = reply["id"].toString();
        if (id.isEmpty() || seen.contains(id)) {
            continue;
        }
        seen.insert(id);
        replies.append(reply);
    }
    item["replies"] = replies;
    item["repliesExpanded"] = true;
    item["repliesLoading"] = false;
    item["repliesError"] = QString();
    item["repliesHasMore"] = body["hasMore"].toBool(data["hasMore"].toBool(false));
    item["repliesTime"] = body["time"].toString(scalar(data["time"]));
    items[index] = item;
    emit changed();
}

void CommentsController::ensureAvatar(const QString &url) {
    if (url.isEmpty() || m_avatarKeys.contains(url) || m_avatarRequests.contains(url)) {
        return;
    }
    m_avatarRequests.insert(url);
    m_host->loadCover(
        url,
        [owner = QPointer(this), url](QString key) {
            if (!owner) {
                return;
            }
            if (!key.isEmpty()) {
                owner->m_avatarKeys.insert(url, key);
            }
            owner->m_host->invalidate();
        },
        128);
}

QString CommentsController::avatar(const QString &url) const {
    return m_avatarKeys.value(url);
}

QJsonObject CommentsController::state() const {
    QJsonArray list;
    for (const auto &item : items) {
        auto value = item;
        const auto url = value["avatarUrl"].toString();
        value["avatarKey"] = m_avatarKeys.value(url);
        value["timeLabel"] = relativeTime(value["time"].toDouble());
        value["likedLabel"] = compactCount(value["likedCount"].toInt());
        list.append(value);
    }
    return {{"status", status},
            {"message", message},
            {"sort", sort},
            {"total", total},
            {"totalLabel", compactCount(total)},
            {"hasMore", hasMore},
            {"loadingMore", loadingMore},
            {"sourceLabel", sourceLabel},
            {"sourceName", sourceName},
            {"trackName", trackName},
            {"items", list}};
}
