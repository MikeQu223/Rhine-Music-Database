#include "LyricsController.h"
#include "ProviderRegistry.h"
#include <QDateTime>
#include <QJsonDocument>
#include <QTimer>
#include <QFile>
#include <QFileInfo>
#include <QPointer>
#include <QRegularExpression>
#include <algorithm>
#include <cmath>

namespace {
constexpr int CACHE_LIMIT = 12;

QString comparable(QString value) {
    static const QRegularExpression remove(QStringLiteral("[\\s\\p{P}\\p{S}]"),
                                           QRegularExpression::UseUnicodePropertiesOption);
    return value.normalized(QString::NormalizationForm_KC).toLower().remove(remove);
}

QStringList artists(const QJsonObject &track) {
    QStringList values;
    for (const auto &artist : track["artists"].toArray()) {
        values.append(artist.toObject()["name"].toString());
    }
    if (values.isEmpty()) {
        values = track["artist"].toString().split(QRegularExpression(QStringLiteral("\\s*/\\s*")));
    }
    QStringList normalized;
    for (const auto &value : values) {
        const auto text = comparable(value);
        if (!text.isEmpty()) {
            normalized.append(text);
        }
    }
    normalized.sort();
    return normalized;
}

QString recordingVersion(const QJsonObject &track) {
    const auto text = (track["title"].toString() + " " + track["album"].toString()).toLower();
    QStringList versions;
    for (const auto &version :
         {"live", "remix", "demo", "acoustic", "instrumental", "伴奏", "翻唱", "现场", "重录"}) {
        if (text.contains(QString::fromUtf8(version))) {
            versions.append(QString::fromUtf8(version));
        }
    }
    versions.sort();
    return versions.join('/');
}
}

LyricsController::LyricsController(Host *host, QObject *parent) : QObject(parent), m_host(host) {
    const auto &registry = ProviderRegistry::instance();
    for (const auto &id : registry.ids()) {
        if (id == "local" || !registry.capability(id, "lyrics", false)) {
            continue;
        }
        m_providers.append(id);
        auto api = std::make_unique<MusicApi>(host);
        api->provider = id;
        m_apis.emplace(id, std::move(api));
    }
    bool validOffset = false;
    const auto savedOffset = host->preference("lyrics-global-offset-ms").toDouble(&validOffset);
    if (validOffset && std::isfinite(savedOffset)) {
        m_globalOffsetMs = std::clamp(savedOffset, -10000., 10000.);
    }
    offsetMs = m_globalOffsetMs;
    const auto cached = QJsonDocument::fromJson(host->preference("lyrics-cache").toUtf8()).array();
    for (const auto &value : cached) {
        const auto entry = value.toObject();
        if (entry["key"].isString() && validDocument(entry["document"].toObject())) {
            m_cache.append(QJsonObject{{"key", entry["key"]}, {"document", entry["document"]}});
            if (m_cache.size() == CACHE_LIMIT) {
                break;
            }
        }
    }
}

QString LyricsController::trackKey(const QJsonObject &track) {
    if (track.isEmpty()) {
        return {};
    }
    const auto key = track["provider"].toString() + ":" + track["id"].toString();
    return track["provider"] == "local" ? key + ':' + track["fingerprint"].toString() : key;
}

bool LyricsController::validDocument(const QJsonObject &document) {
    if (document["version"].toInt() != 1 ||
        !QStringList{"line", "word", "none"}.contains(document["timing"].toString()) ||
        !document["lines"].isArray() || document["lines"].toArray().size() > 5000 ||
        !document["plainText"].isString() || !document["offsetMs"].isDouble() ||
        !std::isfinite(document["offsetMs"].toDouble())) {
        return false;
    }
    for (const auto &value : document["lines"].toArray()) {
        const auto line = value.toObject();
        if (!line["startMs"].isDouble() || !std::isfinite(line["startMs"].toDouble()) ||
            !line["text"].isString()) {
            return false;
        }
    }
    return true;
}

bool LyricsController::sameRecording(const QJsonObject &track, const QJsonObject &candidate) {
    const auto sourceArtists = artists(track);
    const bool sameTitle = comparable(track["title"].toString()) == comparable(candidate["title"].toString());
    const bool sameVersion = recordingVersion(track) == recordingVersion(candidate);
    if (ProviderRegistry::instance().descriptor(track["provider"].toString())["lyrics"]
            .toObject()["matchMode"]
            .toString() == "fuzzy") {
        // 宽松匹配只核对标题与录音版本，适合缺少结构化歌手信息的来源。
        return sameTitle && sameVersion;
    }
    return sameTitle && !sourceArtists.isEmpty() && sourceArtists == artists(candidate) && sameVersion &&
           track["duration"].toDouble() > 0 && candidate["duration"].toDouble() > 0 &&
           std::abs(track["duration"].toDouble() - candidate["duration"].toDouble()) <= 2000;
}

int LyricsController::activeLineIndex(const QJsonObject &document, double positionMs, double offsetMs) {
    const auto lines = document["lines"].toArray();
    const auto position = positionMs + document["offsetMs"].toDouble() + offsetMs;
    qsizetype lower = 0;
    qsizetype upper = lines.size();
    while (lower < upper) {
        const auto middle = (lower + upper) / 2;
        if (lines.at(middle).toObject()["startMs"].toDouble() <= position) {
            lower = middle + 1;
        } else {
            upper = middle;
        }
    }
    return int(lower) - 1;
}

void LyricsController::clear() {
    if (remoteCommand("clear", {})) {
        return;
    }
    ++m_generation;
    currentKey.clear();
    m_document = {};
    m_starts.clear();
    status = "idle";
    message.clear();
    index = -1;
    offsetMs = m_globalOffsetMs;
    positionMs = 0;
}

/** 清除歌词缓存；当前文档由调用方决定是否按同一首歌重新读取。 */
void LyricsController::clearCache() {
    if (remoteCommand("clearCache", {})) {
        return;
    }
    m_cache = {};
    m_lyricsRetryAfter.clear();
    m_lyricBlockedUntil.clear();
    m_lastLyricRequest.clear();
    persist();
}

MusicApi &LyricsController::api(const QString &provider) {
    const auto hit = m_apis.find(provider);
    if (hit != m_apis.end()) {
        return *hit->second;
    }
    static std::unique_ptr<MusicApi> fallback;
    if (!fallback) {
        fallback = std::make_unique<MusicApi>(m_host);
    }
    return *fallback;
}

MusicApi::Valid LyricsController::valid(const Pending &pending) {
    return [owner = QPointer(this), generation = pending->generation] {
        return owner && owner->m_generation == generation;
    };
}

/** 本地歌曲封面匹配 */
void LyricsController::matchCover(const QJsonObject &track) {
    if (track["provider"] != "local" || trackKey(track) != currentKey) {
        return;
    }
    auto pending = std::make_shared<Load>();
    pending->generation = m_generation;
    pending->track = track;
    pending->needsLyrics = false;
    pending->needsCover = true;
    supplement(pending);
}

void LyricsController::tryCover(const Pending &pending, const QString &url) {
    if (!pending->needsCover || url.isEmpty() || pending->coverRequests.contains(url)) {
        return;
    }
    pending->coverRequests.append(url);
    m_host->loadCover(url, [this, pending, url, alive = valid(pending)](QString image) {
        if (alive() && pending->needsCover && !image.isEmpty()) {
            pending->needsCover = false;
            emit coverMatched(trackKey(pending->track), url);
        }
    });
}

/** 搜索条目缺图时复用同一平台的歌曲详情；仍以录音信息核对，避免套用同名异曲封面。 */
void LyricsController::loadCandidateCover(const Pending &pending, const QJsonObject &candidate,
                                          const QString &provider) {
    const auto cover = candidate["cover"].toString();
    if (!cover.isEmpty()) {
        tryCover(pending, cover);
        return;
    }
    const auto key = "detail:" + provider + ':' + candidate["id"].toString();
    if (pending->coverRequests.contains(key)) {
        return;
    }
    pending->coverRequests.append(key);
    api(provider).call(
        "songs", {QJsonValue(QJsonArray{candidate["id"]})},
        [this, pending](MusicReply reply) {
            if (!reply.ok() || !pending->needsCover) {
                return;
            }
            for (const auto &value : reply.value.toArray()) {
                const auto song = value.toObject();
                if (sameRecording(pending->track, song)) {
                    tryCover(pending, song["cover"].toString());
                }
            }
        },
        valid(pending));
}

/** 本地歌曲歌词来源选择 */
void LyricsController::selectLocalSource(const QJsonObject &track, const QString &source) {
    if (remoteCommand("source", {{"track", track}, {"source", source}})) {
        return;
    }
    if (track["provider"] != "local" || track["id"].toString().isEmpty() ||
        (!QStringList{"auto", "local"}.contains(source) && !m_providers.contains(source))) {
        return;
    }
    if (m_localSources.size() >= 200 && !m_localSources.contains(track["id"].toString())) {
        m_localSources = {};
    }
    m_localSources[track["id"].toString()] = source;
    load(track, true);
}

/** 切歌先清空显示，再读精确 ID；缺词时只接受同名、同歌手、同版本的录音补缺。 */
void LyricsController::load(const QJsonObject &track, bool retry) {
    if (remoteCommand("load", {{"track", track}, {"retry", retry}})) {
        return;
    }
    const auto key = trackKey(track);
    const bool sameTrack = key == currentKey;
    const auto position = sameTrack ? positionMs : 0;
    const auto offset = sameTrack ? offsetMs : m_globalOffsetMs;
    clear();
    offsetMs = offset;
    currentKey = key;
    positionMs = position;
    if (track["provider"] == "local") {
        localSource = m_localSources.value(track["id"].toString()).toString("auto");
        auto pending = std::make_shared<Load>();
        pending->generation = m_generation;
        pending->track = track;
        pending->needsCover = track["cover"].toString().isEmpty();
        loadLocal(track, pending);
        return;
    }
    if (!retry) {
        for (const auto &entry : m_cache) {
            if (entry.toObject()["key"].toString() != currentKey) {
                continue;
            }
            const auto document = entry.toObject()["document"].toObject();
            accept(document, track);
            return;
        }
    }
    if (track["provider"] == "siren") {
        if (m_lyricsRetryAfter.value(currentKey) > QDateTime::currentMSecsSinceEpoch()) {
            status = "empty";
            message = QStringLiteral("暂无歌词");
            emit changed();
            return;
        }
        status = "loading";
        message = QStringLiteral("正在匹配歌词来源…");
        emit changed();
        auto pending = std::make_shared<Load>();
        pending->generation = m_generation;
        pending->track = track;
        pending->needsCover = track["cover"].toString().isEmpty();
        supplement(pending);
        return;
    }
    status = "loading";
    message = QStringLiteral("正在读取歌词…");
    emit changed();
    auto pending = std::make_shared<Load>();
    pending->generation = m_generation;
    pending->track = track;
    pending->needsCover = track["cover"].toString().isEmpty();
    api(track["provider"].toString())
        .call(
            "lyrics", {track},
            [this, pending](MusicReply result) {
                pending->networkFailed = !result.ok();
                const auto document = result.value.toObject();
                if (result.ok() && validDocument(document)) {
                    pending->native = document;
                    if (!document["lines"].toArray().isEmpty()) {
                        accept(document, pending->track);
                        return;
                    }
                }
                supplement(pending);
            },
            valid(pending));
}

void LyricsController::supplement(const Pending &pending) {
    const auto source = pending->track["provider"].toString();
    while (pending->provider < m_providers.size() &&
           (m_providers[pending->provider] == source || m_providers[pending->provider] == "siren" ||
            (!pending->lyricSource.isEmpty() &&
             m_providers[pending->provider] != pending->lyricSource))) {
        ++pending->provider;
    }
    if (pending->provider >= m_providers.size()) {
        finish(pending);
        return;
    }
    pending->queries = {pending->track["title"].toString() + " " + pending->track["artist"].toString(),
                        pending->track["title"].toString()};
    pending->queries.removeDuplicates();
    pending->query = 0;
    search(pending);
}

void LyricsController::search(const Pending &pending) {
    if (pending->query >= pending->queries.size()) {
        ++pending->provider;
        supplement(pending);
        return;
    }
    const auto provider = m_providers[pending->provider];
    const auto now = QDateTime::currentMSecsSinceEpoch();
    if (m_lyricBlockedUntil.value(provider) > now) {
        ++pending->provider;
        supplement(pending);
        return;
    }
    const auto lyricsPolicy =
        ProviderRegistry::instance().descriptor(provider)["lyrics"].toObject();
    const auto sourcePolicy = ProviderRegistry::instance()
                                  .descriptor(pending->track["provider"].toString())["lyrics"]
                                  .toObject();
    const auto interval =
        qMax(lyricsPolicy["rateLimitMs"].toInt(0), sourcePolicy["fallbackRateLimitMs"].toInt(0));
    if (interval > 0) {
        const auto wait = interval - (now - m_lastLyricRequest.value(provider));
        if (wait > 0) {
            QTimer::singleShot(int(wait), this, [this, pending] {
                if (valid(pending)()) {
                    search(pending);
                }
            });
            return;
        }
        m_lastLyricRequest[provider] = now;
    }
    api(provider)
        .call(
            "search", {pending->queries[pending->query], "song", 0},
            [this, pending, provider](MusicReply result) {
                if (!result.ok()) {
                    pending->networkFailed = true;
                    if (pending->track["provider"].toString() == "siren") {
                        m_lyricBlockedUntil[provider] =
                            QDateTime::currentMSecsSinceEpoch() + 60000;
                    }
                    ++pending->provider;
                    supplement(pending);
                    return;
                }
                pending->candidates = {};
                for (const auto &candidate : result.value.toObject()["items"].toArray()) {
                    if (sameRecording(pending->track, candidate.toObject())) {
                        pending->candidates.append(candidate);
                        if (pending->candidates.size() == 2) {
                            break;
                        }
                    }
                }
                if (pending->needsCover) {
                    for (const auto &entry : pending->candidates) {
                        loadCandidateCover(pending, entry.toObject(), provider);
                    }
                }
                if (!pending->needsLyrics && !pending->needsCover) {
                    return;
                }
                if (!pending->needsLyrics) {
                    ++pending->query;
                    search(pending);
                    return;
                }
                pending->candidate = 0;
                fetchCandidate(pending);
            },
            valid(pending));
}

void LyricsController::fetchCandidate(const Pending &pending) {
    if (pending->candidate >= pending->candidates.size()) {
        ++pending->query;
        search(pending);
        return;
    }
    const auto candidate = pending->candidates.at(pending->candidate).toObject();
    const auto provider = m_providers[pending->provider];
    api(provider)
        .call(
            "lyrics", {candidate},
            [this, pending, candidate, provider](MusicReply result) {
                if (!result.ok()) {
                    pending->networkFailed = true;
                    if (pending->track["provider"].toString() == "siren") {
                        m_lyricBlockedUntil[provider] =
                            QDateTime::currentMSecsSinceEpoch() + 60000;
                    }
                    ++pending->provider;
                    supplement(pending);
                    return;
                }
                auto document = result.value.toObject();
                if (validDocument(document) && !document["lines"].toArray().isEmpty()) {
                    document["sourceTrackId"] = candidate["id"];
                    accept(document, pending->track);
                    pending->needsLyrics = false;
                    // 找到歌词后仍补齐缺失封面，避免首个平台缺封面时过早结束。
                    if (pending->needsCover) {
                        pending->lyricSource.clear();
                        pending->provider = 0;
                        supplement(pending);
                    }
                    return;
                }
                ++pending->candidate;
                fetchCandidate(pending);
            },
            valid(pending));
}

void LyricsController::finish(const Pending &pending) {
    if (!pending->needsLyrics) {
        return;
    }
    if (!pending->native["plainText"].toString().isEmpty()) {
        accept(pending->native, pending->track);
        return;
    }
    status = pending->networkFailed ? "error" : "empty";
    if (pending->track["provider"] == "siren") {
        const auto delay = pending->networkFailed ? 60000 : 10 * 60 * 1000;
        m_lyricsRetryAfter.insert(trackKey(pending->track), QDateTime::currentMSecsSinceEpoch() + delay);
    }
    if (pending->networkFailed) {
        message = QStringLiteral("歌词暂不可用，点击重试");
    } else {
        message = QStringLiteral("暂无歌词 / 纯音乐");
    }
    emit changed();
}

void LyricsController::accept(QJsonObject document, const QJsonObject &track) {
    document["trackKey"] = trackKey(track);
    m_document = document;
    m_starts.clear();
    for (const auto &line : document["lines"].toArray()) {
        m_starts.append(line.toObject()["startMs"].toDouble());
    }
    status = m_starts.isEmpty() ? "plain" : "ready";
    message = m_starts.isEmpty() ? QStringLiteral("此歌词没有时间信息") : QString();
    index = activeLineIndex(document, positionMs, offsetMs);
    QJsonArray cache{QJsonObject{{"key", currentKey}, {"document", document}}};
    for (const auto &entry : m_cache) {
        if (entry.toObject()["key"].toString() != currentKey && cache.size() < CACHE_LIMIT) {
            cache.append(entry);
        }
    }
    m_cache = cache;
    m_lyricsRetryAfter.remove(currentKey);
    persist();
    emit changed();
}

void LyricsController::persist() {
    auto serialized = QString::fromUtf8(QJsonDocument(m_cache).toJson(QJsonDocument::Compact));
    while (serialized.size() >= 240000 && !m_cache.isEmpty()) {
        m_cache.removeLast();
        serialized = QString::fromUtf8(QJsonDocument(m_cache).toJson(QJsonDocument::Compact));
    }
    m_host->setPreference("lyrics-cache", serialized);
}

void LyricsController::sync(double position) {
    positionMs = position;
    const auto time = position + m_document["offsetMs"].toDouble() + offsetMs;
    const auto next = int(std::upper_bound(m_starts.begin(), m_starts.end(), time) - m_starts.begin()) - 1;
    if (next != index) {
        index = next;
        emit changed();
    }
}

void LyricsController::adjustOffset(double deltaMs) {
    if (remoteCommand("offset", {{"value", deltaMs}})) {
        return;
    }
    offsetMs = std::clamp(offsetMs + deltaMs, -10000., 10000.);
    sync(positionMs);
    emit changed();
}

// 重置当前歌曲歌词偏移量
void LyricsController::resetOffset() {
    if (remoteCommand("reset", {})) {
        return;
    }
    if (offsetMs == 0) {
        return;
    }
    offsetMs = 0;
    sync(positionMs);
    emit changed();
}

// 将当前歌曲歌词偏移量应用到全局
void LyricsController::applyGlobalOffset() {
    if (remoteCommand("global", {})) {
        return;
    }
    if (offsetMs == m_globalOffsetMs) {
        return;
    }
    m_globalOffsetMs = offsetMs;
    m_host->setPreference("lyrics-global-offset-ms", QString::number(m_globalOffsetMs));
    emit changed();
}

/** 本地歌词归一化器以及匹配逻辑 */
void LyricsController::loadLocal(const QJsonObject &track, const Pending &pending) {
    if (m_providers.contains(localSource)) {
        pending->lyricSource = localSource;
        status = "loading";
        message = QStringLiteral("正在从所选来源匹配歌词…");
        emit changed();
        supplement(pending);
        return;
    }
    const QFileInfo audio(track["path"].toString());
    const auto content = track["localLyrics"].toString();
    QByteArray sidecarBytes;
    const auto basename = audio.absolutePath() + '/' + audio.completeBaseName();
    for (const auto &suffix : {".lrc", ".LRC"}) {
        QFile file(basename + suffix);
        if (file.open(QIODevice::ReadOnly) && file.size() <= 1000000) {
            const auto sidecar = file.readAll();
            if (!sidecar.trimmed().isEmpty()) {
                sidecarBytes = sidecar;
                break;
            }
        }
    }
    if (sidecarBytes.isEmpty() && content.trimmed().isEmpty()) {
        if (localSource == "local") {
            pending->needsLyrics = false;
            status = "empty";
            message = QStringLiteral("没有本地歌词文件或内嵌歌词，可选择其他来源");
            emit changed();
            if (pending->needsCover) {
                supplement(pending);
            }
            return;
        }
        status = "loading";
        message = QStringLiteral("本地缺少歌词，正在匹配…");
        emit changed();
        for (const auto &entry : m_cache) {
            const auto cached = entry.toObject();
            const auto document = cached["document"].toObject();
            if (cached["key"] == currentKey && document["source"] != "local" && validDocument(document)) {
                accept(document, track);
                pending->needsLyrics = false;
                break;
            }
        }
        if (pending->needsLyrics || pending->needsCover) {
            supplement(pending);
        }
        return;
    }
    status = "loading";
    emit changed();
    // 原始字节交给桥接统一识别编码；内嵌歌词已由标签库转换为 Unicode，作为回退保留。
    QJsonObject parameters{{"content", content}};
    if (!sidecarBytes.isEmpty()) {
        parameters["contentBase64"] = QString::fromLatin1(sidecarBytes.toBase64());
    }
    m_host->requestJson(
        "/local/lyrics", parameters,
        [this, pending, alive = valid(pending)](QJsonObject response, QString error) {
            if (!alive()) {
                return;
            }
            const auto document = response["body"].toObject()["document"].toObject();
            if (error.isEmpty() && validDocument(document) &&
                (!document["lines"].toArray().isEmpty() || !document["plainText"].toString().isEmpty())) {
                accept(document, pending->track);
                pending->needsLyrics = false;
            }
            if (pending->needsLyrics && localSource == "local") {
                pending->needsLyrics = false;
                status = "empty";
                message = QStringLiteral("本地歌词无法读取，可选择其他来源");
                emit changed();
            }
            if (pending->needsLyrics || pending->needsCover) {
                supplement(pending);
            }
        });
}

bool LyricsController::remoteCommand(const QString &method, QJsonObject arguments) {
    auto connection = m_host->playbackConnection();
    if (!connection) {
        return false;
    }
    connection->call("lyrics." + method, arguments);
    applyPlaybackSnapshot(connection->snapshot()["lyrics"].toObject());
    return true;
}

QJsonObject LyricsController::playbackSnapshot() const {
    return {{"document", m_document},
            {"status", status},
            {"message", message},
            {"key", currentKey},
            {"index", index},
            {"offsetMs", offsetMs},
            {"positionMs", positionMs},
            {"globalOffsetMs", m_globalOffsetMs},
            {"localSource", localSource}};
}

void LyricsController::applyPlaybackSnapshot(const QJsonObject &snapshot) {
    m_document = snapshot["document"].toObject();
    status = snapshot["status"].toString("idle");
    message = snapshot["message"].toString();
    currentKey = snapshot["key"].toString();
    index = snapshot["index"].toInt(-1);
    offsetMs = snapshot["offsetMs"].toDouble();
    positionMs = snapshot["positionMs"].toDouble();
    m_globalOffsetMs = snapshot["globalOffsetMs"].toDouble();
    localSource = snapshot["localSource"].toString("auto");
}
