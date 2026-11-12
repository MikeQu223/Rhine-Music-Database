#include "MusicPlayer.h"
#include "ProviderRegistry.h"
#include <QFileInfo>
#include <QUrl>
#include <QJsonDocument>
#include <QPointer>
#include <QRegularExpression>
#include <algorithm>
#include <cmath>

/** 本地音质近似分级 */
QString MusicPlayer::localQuality(const QJsonObject &track) {
    const auto name = QFileInfo(track["path"].toString()).completeBaseName().toLower();
    const auto format = track["format"].toString().toLower();
    const auto bitrateKbps = track["bitrate"].toInt();
    const auto tiers = ProviderRegistry::instance()
                           .descriptor("local")["quality"]
                           .toObject()["localFilenameTiers"]
                           .toObject();
    for (auto it = tiers.begin(); it != tiers.end(); ++it) {
        if (name.contains(it.key().toLower())) {
            return it.value().toString();
        }
    }
    const bool lossless =
        QStringList{"flac", "ape", "wav", "aif", "aiff", "alac", "wv", "dsf", "dff"}.contains(format) ||
        (format == "m4a" && bitrateKbps >= 700);
    if (lossless) {
        const bool highResolution = name.contains("hi-res") || name.contains("hires") ||
                                    name.contains("高解析") || name.contains("24bit") ||
                                    name.contains("24-bit") || track["sampleRate"].toInt() > 48000 ||
                                    bitrateKbps > 1600;
        return highResolution ? "hires" : "lossless";
    }
    return bitrateKbps >= 192 || name.contains("320k") || name.contains("[hq]") ? "hq" : "standard";
}

/** 只识别本次可播放地址及其响应元数据；不读取偏好或歌曲可用音质列表。 */
QString MusicPlayer::sourceQuality(const QString &provider, const QJsonObject &audio, bool trial) {
    Q_UNUSED(provider)
    if (trial || audio["url"].toString().isEmpty()) {
        return {};
    }
    // 插件返回统一 tier；平台档位单独放在 providerTier，用于界面文案与徽章。
    const auto providerTier =
        audio["providerTier"].toString(audio["qualityId"].toString());
    if (!providerTier.isEmpty()) {
        return providerTier;
    }
    const auto tier = audio["tier"].toString();
    if (!tier.isEmpty()) {
        return tier;
    }
    const auto url = QUrl(audio["url"].toString());
    auto format = audio["type"].toString().toLower();
    if (format.isEmpty()) {
        format = audio["extName"].toString().toLower();
    }
    if (format.isEmpty()) {
        format = QFileInfo(url.path()).suffix().toLower();
    }
    const auto bitrate = audio["br"].toDouble();
    const bool lossy = format == "mp3" || format == "m4a" || format == "aac";
    if (lossy && bitrate > 0) {
        return bitrate >= 192000 ? "hq" : "standard";
    }
    const auto level = audio["level"].toString();
    const QStringList levels{"standard", "hq", "lossless", "hires", "master", "original"};
    if (levels.contains(level) && (!lossy || level == "standard" || level == "hq")) {
        return level;
    }
    if (format == "flac" || format == "ape" || format == "alac" || format == "wav") {
        // 无损码率高不能证明 Hi-Res；必须同时取得采样率与位深。
        if (audio["sampleRate"].toDouble() > 48000 && audio["bitDepth"].toInt() > 16) {
            return "hires";
        }
        return "lossless";
    }
    return {};
}

QVector<QPair<QString, QString>> MusicPlayer::qualityOptions(const QString &provider) {
    const auto options = ProviderRegistry::instance().qualityOptions(provider);
    if (!options.isEmpty()) {
        return options;
    }
    return {{"standard", "标准"}};
}

/** 共享音质偏好；换源保留队列、歌词、播放位置和暂停意图，迟到响应由播放代数隔离。 */
void MusicPlayer::setQuality(const QString &value) {
    if (remoteCommand("quality", {{"value", value}})) {
        return;
    }
    const auto options = qualityOptions(m_api->provider);
    const auto found = std::find_if(options.begin(), options.end(),
                                    [&value](const auto &option) { return option.first == value; });
    if (found == options.end() || quality == value) {
        return;
    }
    quality = value;
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    invalidateAppleTransition(true);
#endif
    m_recoveryAttempts = 0;
    m_host->setPreference("quality", value);
    if (current.isEmpty() || (loading && !m_resumePosition)) {
        emit changed();
        return;
    }
    if (!m_resumePosition) {
        m_resumePosition = state["position"].toDouble();
        m_resumePaused = !state["playing"].toBool();
    }
    const auto generation = ++m_generation;
    m_host->mediaControl("stop");
    actualQuality.clear();
    failed = false;
    trial = false;
    loading = true;
    status = QStringLiteral("正在切换音质…");
    emit changed();
    prepare(current, generation, true);
}

void MusicPlayer::refreshQualityPreference() {
    if (m_host->playbackConnection()) {
        return;
    }
    const auto saved = m_host->preference("quality");
    const auto options = ProviderRegistry::instance().qualityOptions(m_api->provider);
    if (m_api->provider.isEmpty()) {
        quality = saved;
        return;
    }
    const auto valid =
        std::any_of(options.begin(), options.end(),
                    [&saved](const auto &option) { return option.first == saved; });
    if (valid) {
        quality = saved;
        return;
    }
    quality = ProviderRegistry::instance().defaultQuality(m_api->provider);
    if (quality.isEmpty() && !options.isEmpty()) {
        quality = options.first().first;
    }
    if (quality.isEmpty()) {
        quality = "standard";
    }
}

MusicPlayer::MusicPlayer(Host *host, MusicApi *api, QObject *parent)
    : QObject(parent), lyrics(host), queue(api), m_host(host), m_api(api) {
    state = {{"playing", false}, {"position", 0}, {"duration", 0}, {"volume", 0.7}, {"seekable", false}};
    connect(&queue, &PlaybackQueue::changed, this, &MusicPlayer::changed);
    if (auto connection = m_host->playbackConnection()) {
        connect(connection, &PlaybackConnection::snapshotChanged, this, &MusicPlayer::applyPlaybackSnapshot,
                Qt::QueuedConnection);
        connect(connection, &PlaybackConnection::disconnected, this, [this] {
            loading = false;
            failed = true;
            state["playing"] = false;
            status = QStringLiteral("后台播放服务已断开，请重新打开应用");
            emit changed();
        });
        applyPlaybackSnapshot();
        // 等资料库完成来源初始化后再解码封面，避免初始化的账号代数作废首次加载。
        QTimer::singleShot(0, this, [this] {
            m_remoteCover.clear();
            applyPlaybackSnapshot();
        });
        return;
    }
    refreshQualityPreference();
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    m_appleTransitionsEnabled = host->preference("apple-smart-transition") == "on";
    connect(host, &Host::preferenceChanged, this, [this](const QString &key, const QString &value) {
        if (key == "apple-smart-transition") {
            m_appleTransitionsEnabled = value == "on";
            invalidateAppleTransition();
        }
    });
    connect(host, &Host::appleTransitionCommitted, this, &MusicPlayer::commitAppleTransition);
    connect(&queue, &PlaybackQueue::changed, this, [this] {
        const auto index = queue.nextIndex(mode);
        if (!m_appleIncomingKey.isEmpty() && PlaybackQueue::identity(queue.current()) == m_appleOutgoingKey &&
            PlaybackQueue::identity(queue.at(index)) == m_appleIncomingKey) {
            m_appleNextIndex = index;
            return;
        }
        invalidateAppleTransition();
    });
#endif
    localCovers = QJsonDocument::fromJson(host->preference("local-cover-cache").toUtf8()).object();
    alternative = host->preference("alternate-source") == "on";
    const auto saved = QJsonDocument::fromJson(host->preference("play-history").toUtf8()).array();
    const QRegularExpression identifier(QStringLiteral("^[a-zA-Z0-9_-]{1,80}$"));
    for (const auto &value : saved) {
        const auto track = value.toObject();
        if (track["kind"] == "song" && identifier.match(track["id"].toString()).hasMatch()) {
            history.append(track);
            if (history.size() == 200) {
                break;
            }
        }
    }
    connect(&lyrics, &LyricsController::changed, this, &MusicPlayer::changed);
    connect(&lyrics, &LyricsController::coverMatched, this, [this](QString key, QString url) {
        if (current["provider"] != "local" || LyricsController::trackKey(current) != key ||
            !current["cover"].toString().isEmpty()) {
            return;
        }
        const auto alive = valid(m_generation);
        m_host->loadCover(url, [this, alive, url](QString image) {
            if (alive() && !image.isEmpty()) {
                coverImage = image;
                current["cover"] = url;
                const auto key = current["id"].toString() + ':' + current["fingerprint"].toString();
                localCovers[key] = url;
                while (localCovers.size() > 200) {
                    localCovers.remove(localCovers.begin().key());
                }
                m_host->setPreference(
                    "local-cover-cache",
                    QString::fromUtf8(QJsonDocument(localCovers).toJson(QJsonDocument::Compact)));
                queue.updateCurrent(current);
                emit changed();
            }
        });
    });
}

MusicApi::Valid MusicPlayer::valid(quint64 generation) {
    return [owner = QPointer(this), generation] { return owner && owner->m_generation == generation; };
}

/** 去除非当前项中的同曲目，再插到队尾或当前项之后；不切歌、不改变暂停意图。 */
bool MusicPlayer::enqueue(const QJsonObject &track, bool next) {
    if (remoteCommand("enqueue", {{"track", track}, {"next", next}})) {
        if (!m_host->playbackConnection()->error().isEmpty()) {
            return false;
        }
        const auto key = PlaybackQueue::identity(track);
        if (next) {
            const auto position = std::max(0, queue.index() + 1);
            return position < queue.size() && PlaybackQueue::identity(queue.at(position)) == key;
        }
        return !queue.isEmpty() && PlaybackQueue::identity(queue.at(queue.size() - 1)) == key;
    }
    if (track["kind"] != "song") {
        return false;
    }
    return queue.enqueue(track, next);
}

/** 停止旧音源并推进代数，先完成元数据再交付播放；迟到的地址不能恢复旧曲目。 */
void MusicPlayer::play(QJsonObject track, std::optional<QJsonArray> source, std::optional<int> queueIndex,
                       bool preview, std::optional<QJsonObject> resume) {
    QJsonObject arguments{{"track", track}, {"preview", preview}};
    if (source) {
        arguments["source"] = *source;
    }
    if (queueIndex) {
        arguments["index"] = *queueIndex;
    }
    if (resume) {
        arguments["resume"] = *resume;
    }
    if (remoteCommand("play", arguments)) {
        return;
    }
    if (track["kind"] != "song" || (m_api->provider == "local" && track["provider"] != "local") ||
        (m_api->provider != "local" && track["provider"] == "local")) {
        return;
    }
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    invalidateAppleTransition();
#endif
    if (source) {
        queue.replace(*source);
    }
    queue.selectTrack(track);
    if (queueIndex) {
        queue.select(*queueIndex);
    }
    if (source && mode == "shuffle") {
        queue.shuffle();
    }
    const auto generation = ++m_generation;
    m_resumePosition = resume ? std::optional<double>(resume->value("position").toDouble()) : std::nullopt;
    m_resumePaused = resume && !resume->value("requested").toBool();
    m_restoringSession = resume.has_value();
    m_recoveryAttempts = 0;
    previewRequested = preview && ProviderRegistry::instance().capability(m_api->provider, "preview", false);
    m_host->mediaControl("stop");
    current = track;
    actualQuality.clear();
    lyrics.clear();
    coverImage.clear();
    loading = true;
    failed = false;
    trial = false;
    status = QStringLiteral("正在准备：") + track["title"].toString();
    emit changed();
    prepare(track, generation);
}

void MusicPlayer::loadQueue(const QJsonArray &ids, const QJsonArray &known) {
    if (remoteCommand("loadQueue", {{"ids", ids}, {"known", known}})) {
        return;
    }
    queue.load(ids, known);
}

void MusicPlayer::prepare(QJsonObject track, quint64 generation, bool reload, bool alreadyPlaying,
                          const QJsonObject &adoptedAudio) {
    if (track["provider"] == "local" && !alreadyPlaying) {
        const QUrl source(track["url"].toString());
        if (m_api->provider != "local" || !source.isLocalFile() ||
            !QFileInfo(source.toLocalFile()).isReadable()) {
            fail(QStringLiteral("本地文件无法访问，请检查文件位置或重新扫描"));
            return;
        }
    }
    if (track["provider"] == "local" && track["cover"].toString().isEmpty()) {
        const auto key = track["id"].toString() + ':' + track["fingerprint"].toString();
        if (localCovers.contains(key)) {
            track["cover"] = localCovers[key];
            current = track;
        }
    }
    if (!reload) {
        if (!track["cover"].toString().isEmpty()) {
            m_host->loadCover(track["cover"].toString(), [this, alive = valid(generation)](QString key) {
                if (!alive()) {
                    return;
                }
                coverImage = key;
                if (key.isEmpty() && current["provider"] == "local") {
                    current["cover"] = "";
                    const auto cacheKey = current["id"].toString() + ':' + current["fingerprint"].toString();
                    localCovers.remove(cacheKey);
                    m_host->setPreference(
                        "local-cover-cache",
                        QString::fromUtf8(QJsonDocument(localCovers).toJson(QJsonDocument::Compact)));
                    // 下一轮再补图，确保同步失败回调不会早于本次歌词初始化。
                    m_host->schedule(0, [this, alive] {
                        if (alive()) {
                            lyrics.matchCover(current);
                        }
                    });
                }
                emit changed();
            });
        }
        if (!m_restoringSession) {
            emit trackSelected(current);
        }
        lyrics.load(current);
    }
    if (track["provider"] == "local") {
        const auto url = QUrl(track["url"].toString());
        if (!alreadyPlaying && (m_api->provider != "local" || !url.isLocalFile() ||
                                !QFileInfo(url.toLocalFile()).isReadable())) {
            fail(QStringLiteral("本地文件无法访问，请检查文件位置或重新扫描"));
            return;
        }
        m_host->mediaMetadata(track["title"].toString(), track["artist"].toString(),
                              track["album"].toString(), track["cover"].toString());
        if (!alreadyPlaying && !m_host->mediaLoad(url.toString(), false, m_resumePosition.value_or(0),
                                                  m_resumePosition && m_resumePaused)) {
            fail(QStringLiteral("本地音频无法加载"));
            return;
        }
        m_resumePosition.reset();
        m_endSerial = m_host->mediaState().value("ended").toLongLong();
        actualQuality = localQuality(track);
        status = QStringLiteral("正在播放本地文件：") + track["format"].toString();
        loading = false;
        emit changed();
        return;
    }
    if (alreadyPlaying) {
        m_host->mediaMetadata(track["title"].toString(), track["artist"].toString(),
                              track["album"].toString(), track["cover"].toString());
        finishOnlinePlayback(track, adoptedAudio);
        return;
    }
    m_api->call(
        previewRequested ? "preview" : "playback", {track, effectivePlaybackQuality(), alternative},
        [this, track](MusicReply result) {
            if (!result.ok()) {
                fail(result.error);
                return;
            }
            const auto audio = result.value.toObject();
            const auto url = audio["url"].toString();
            if (url.isEmpty()) {
                fail(QStringLiteral("此歌曲暂无可用音源，请检查登录和歌曲权限"));
                return;
            }
            m_host->mediaMetadata(track["title"].toString(), track["artist"].toString(),
                                  track["album"].toString(), track["cover"].toString());
            if (!m_host->mediaLoad(url, alternative, m_resumePosition.value_or(0),
                                   m_resumePosition && m_resumePaused)) {
                fail(QStringLiteral("音频地址不可用"));
                return;
            }
            finishOnlinePlayback(track, audio);
        },
        valid(generation));
}

/** 按当前平台支持的档位解析正常播放和提前准备使用的音源。 */
QString MusicPlayer::effectivePlaybackQuality() const {
    auto effectiveQuality = quality;
    const auto options = ProviderRegistry::instance().qualityOptions(m_api->provider);
    const auto supported = std::any_of(options.begin(), options.end(),
                                       [this](const auto &option) { return option.first == quality; });
    if (!supported) {
        effectiveQuality = ProviderRegistry::instance().defaultQuality(m_api->provider);
        if (effectiveQuality.isEmpty() && !options.isEmpty()) {
            effectiveQuality = options.first().first;
        }
    }
    if (m_api->provider == "siren" && effectiveQuality.isEmpty()) {
        effectiveQuality = "original";
    }

    return effectiveQuality;
}

/** 更新一次在线曲目状态；自然加载和接管已播放音源共用历史及音质处理。 */
void MusicPlayer::finishOnlinePlayback(const QJsonObject &track, const QJsonObject &audio) {
    m_resumePosition.reset();
    m_endSerial = m_host->mediaState().value("ended").toLongLong();
    auto entry = track;
    entry["wiki"] = "";
    entry["description"] = "";
    QJsonArray recent{entry};
    for (const auto &value : history) {
        if (PlaybackQueue::identity(value.toObject()) != PlaybackQueue::identity(track) &&
            recent.size() < 200) {
            recent.append(value);
        }
    }
    history = recent;
    m_host->setPreference("play-history",
                          QString::fromUtf8(QJsonDocument(history).toJson(QJsonDocument::Compact)));
    const auto freeTrial = audio["freeTrialInfo"];
    trial = audio["trial"].toBool() || audio["preview"].toBool() || freeTrial.isObject() ||
            freeTrial.isArray() ||
            (freeTrial.isString() && !freeTrial.toString().isEmpty() && freeTrial.toString() != "null") ||
            (freeTrial.isBool() && freeTrial.toBool()) || (freeTrial.isDouble() && freeTrial.toDouble() != 0);
    actualQuality = sourceQuality(m_api->provider, audio, trial);
    status = trial ? QStringLiteral("当前音源为试听片段")
                   : QStringLiteral("正在播放：") + track["title"].toString();
    if (!audio["qualityFallback"].toString().isEmpty()) {
        status +=
            QStringLiteral("（已切换为") + audio["qualityFallback"].toString() + QStringLiteral("音质）");
    }
    loading = false;
    emit changed();
}

void MusicPlayer::fail(QString error) {
    if (!m_restoringSession) {
        m_resumePosition.reset();
    }
    failed = true;
    actualQuality.clear();
    status = error;
    loading = false;
    emit changed();
}

/** 重新获取当前歌曲的地址并恢复位置 */
void MusicPlayer::recoverPlayback() {
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    invalidateAppleTransition(true);
#endif
    ++m_recoveryAttempts;
    const auto generation = ++m_generation;
    m_resumePosition = state["position"].toDouble();
    m_resumePaused = !state["requested"].toBool();
    loading = true;
    failed = false;
    actualQuality.clear();
    status = QStringLiteral("正在恢复播放（%1/2）…").arg(m_recoveryAttempts);
    m_host->mediaControl("stop");
    emit changed();
    prepare(current, generation, true);
}

#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
/** 当前曲目稳定起播后立即按队列顺序准备下一首，接管前保留当前曲目。 */
void MusicPlayer::prepareAppleTransition() {
    if (m_appleTransitionEpoch != m_host->epoch) {
        invalidateAppleTransition();
        m_appleTransitionEpoch = m_host->epoch;
    }
    if (!m_appleTransitionsEnabled || m_appleTransitionAttempted || loading || failed || current.isEmpty() ||
        !state["playing"].toBool() || state["buffering"].toBool()) {
        return;
    }
    const auto durationMs = state["duration"].toInteger();
    if (durationMs <= 0) {
        return;
    }
    if (mode == "one" || durationMs < 8000) {
        m_host->setAppleTransitionPreparation(AppleTransitionPreparation::Natural);
        return;
    }
    const bool local = m_api->provider == "local";
    m_appleTransitionAttempted = true;
    if (m_appleNextIndex < 0) {
        m_appleNextIndex = queue.nextIndex(mode);
    }
    const auto next = queue.at(m_appleNextIndex);
    if (next.isEmpty() || next["provider"].toString(m_api->provider) != m_api->provider ||
        PlaybackQueue::identity(next) == PlaybackQueue::identity(current)) {
        m_host->setAppleTransitionPreparation(AppleTransitionPreparation::Natural);
        return;
    }
    m_appleOutgoingKey = PlaybackQueue::identity(current);
    m_appleIncomingKey = PlaybackQueue::identity(next);
    if (local) {
        const QUrl url(next["url"].toString());
        if (url.isLocalFile() && QFileInfo(url.toLocalFile()).isReadable()) {
            m_host->prepareAppleTransition(url, false);
        } else {
            m_host->setAppleTransitionPreparation(AppleTransitionPreparation::SourceUnavailable);
        }
        return;
    }

    const auto stillPlaying = valid(m_generation);
    const auto revision = m_appleTransitionRevision;
    const auto epoch = m_host->epoch;
    m_host->setAppleTransitionPreparation(AppleTransitionPreparation::ResolvingSource);
    m_api->call(
        "playback", {next, effectivePlaybackQuality(), alternative},
        [this](MusicReply result) {
            const auto audio = result.value.toObject();
            const QUrl url(audio["url"].toString());
            if (!result.ok() || url.isEmpty()) {
                m_host->setAppleTransitionPreparation(AppleTransitionPreparation::SourceUnavailable);
            } else if (m_host->prepareAppleTransition(url, alternative)) {
                m_appleNextAudio = audio;
            }
        },
        [this, stillPlaying, revision, epoch] {
            return stillPlaying() && revision == m_appleTransitionRevision && epoch == m_host->epoch;
        });
}

void MusicPlayer::invalidateAppleTransition(bool keepSelection) {
    ++m_appleTransitionRevision;
    if (!keepSelection) {
        m_appleNextIndex = -1;
    }
    m_appleNextAudio = {};
    m_appleOutgoingKey.clear();
    m_appleIncomingKey.clear();
    m_appleTransitionAttempted = false;
    m_host->cancelAppleTransition();
}

/** 已预卷曲目接管时提交选曲、歌词和平台音质，避免重复请求或从零重新打开。 */
void MusicPlayer::commitAppleTransition() {
    const auto selected = m_appleNextIndex;
    const auto next = queue.at(selected);
    if (next.isEmpty()) {
        return;
    }
    const auto generation = ++m_generation;
    m_resumePosition.reset();
    m_restoringSession = false;
    m_recoveryAttempts = 0;
    previewRequested = false;
    trial = false;
    coverImage.clear();
    current = next;
    const auto audio = m_appleNextAudio;
    state = QJsonObject::fromVariantMap(m_host->mediaState());
    queue.select(selected);
    prepare(next, generation, false, true, audio);
    lyrics.sync(state["position"].toDouble());
}
#endif

void MusicPlayer::tick(double time, bool force) {
    if (m_host->playbackConnection()) {
        return;
    }
    if (!force && time - m_lastPoll < 0.1) {
        return;
    }
    m_lastPoll = time;
    const auto previous = state;
    const auto update = QJsonObject::fromVariantMap(m_host->mediaState());
    for (auto it = update.begin(); it != update.end(); ++it) {
        state[it.key()] = it.value();
    }
    if (m_resumePosition && !loading && state["seekable"].toBool()) {
        const auto position = std::clamp(*m_resumePosition, 0., state["duration"].toDouble());
        m_resumePosition.reset();
        m_host->mediaControl("seek", position);
        if (m_resumePaused) {
            m_host->mediaControl("pause");
        }
    }
    lyrics.sync(state["position"].toDouble());
    // 播放结束或错误状态只在播放中或加载完成后触发
    if (!current.isEmpty() && !loading && state.contains("ended") &&
        state["ended"].toInteger() != m_endSerial) {
        m_endSerial = state["ended"].toInteger();
        qInfo().noquote() << "曲目结束，推进下一首";
        if (onEnd) {
            onEnd();
        } else {
            next(1, true);
        }
        return;
    }
    const auto playbackError = state["error"].toString();
    if (!loading && !current.isEmpty() && !playbackError.isEmpty() &&
        (!failed || !actualQuality.isEmpty() || status != playbackError)) {
        constexpr int maxRecoveryAttempts = 2;
        if (!failed && state["recoverable"].toBool() && m_recoveryAttempts < maxRecoveryAttempts &&
            current["provider"] != "local") {
            recoverPlayback();
            return;
        }
        fail(playbackError);
    } else if (state != previous) {
        emit changed();
    }
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    prepareAppleTransition();
#endif
}

void MusicPlayer::toggle() {
    if (remoteCommand("toggle", {})) {
        return;
    }
    if (failed && !current.isEmpty()) {
        const auto resume = m_resumePosition ? std::optional<QJsonObject>(sessionState()) : std::nullopt;
        play(current, std::nullopt, queue.index(), previewRequested, resume);
        return;
    }
    if (m_resumePosition) {
        setPaused(!m_resumePaused);
        return;
    }
    if (!loading && !current.isEmpty()) {
        setPaused(state["playing"].toBool());
    }
}

void MusicPlayer::setPaused(bool paused) {
    if (remoteCommand("pause", {{"paused", paused}})) {
        return;
    }
    if (m_resumePosition) {
        m_resumePaused = paused;
    }
    m_host->mediaControl(paused ? "pause" : "resume");
}

void MusicPlayer::seek(double fraction) {
    if (remoteCommand("seek", {{"value", fraction}})) {
        return;
    }
    if (m_resumePosition) {
        m_resumePosition = std::clamp(fraction, 0., 1.) * state["duration"].toDouble();
        return;
    }
    if (state["seekable"].toBool()) {
        m_host->mediaControl("seek", std::clamp(fraction, 0., 1.) * state["duration"].toDouble());
    }
}

void MusicPlayer::volume(double value) {
    if (remoteCommand("volume", {{"value", value}})) {
        return;
    }
    if (!PlatformFeatures::ApplicationVolume) {
        value = 1.0;
    }
    const auto volume = std::clamp(value, 0., 1.);
    m_host->mediaControl("volume", volume);
    m_host->setPreference("volume", QString::number(volume));
}

void MusicPlayer::next(int direction, bool ended) {
    if (remoteCommand("next", {{"direction", direction}, {"ended", ended}})) {
        return;
    }
    if (queue.isEmpty()) {
        return;
    }
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    invalidateAppleTransition();
#endif
    const auto selected = queue.navigate(direction, mode);
    if (selected < 0) {
        status = QStringLiteral("队列已播放完");
        emit changed();
        return;
    }
    play(queue.at(selected), std::nullopt, selected);
}

void MusicPlayer::remove(int selected) {
    if (remoteCommand("remove", {{"index", selected}})) {
        return;
    }
    queue.remove(selected);
}

void MusicPlayer::clearUpcoming() {
    if (remoteCommand("clear", {})) {
        return;
    }
    queue.clearUpcoming(current);
}

/** 停止播放并作废音源与歌词请求；保留音量和历史等可恢复偏好。 */
void MusicPlayer::stop() {
    if (remoteCommand("stop", {})) {
        return;
    }
    ++m_generation;
    m_resumePosition.reset();
    m_recoveryAttempts = 0;
    lyrics.clear();
    loading = false;
    failed = false;
    status.clear();
    actualQuality.clear();
    coverImage.clear();
    current = {};
    queue.clear();
    m_host->mediaControl("stop");
    m_host->mediaMetadata({}, {}, {});
    state["playing"] = false;
    state["position"] = 0;
    state["duration"] = 0;
    emit changed();
}

/** GUI 播放操作统一交给服务；服务不可用时明确报错，不能回退到第二个本地播放器。 */
bool MusicPlayer::remoteCommand(const QString &method, QJsonObject arguments) {
    auto connection = m_host->playbackConnection();
    if (!connection) {
        return false;
    }
    connection->call("player." + method, arguments);
    applyPlaybackSnapshot();
    if (!connection->error().isEmpty()) {
        failed = true;
        status = connection->error();
        emit changed();
    }
    return true;
}

void MusicPlayer::setMode(const QString &value) {
    if (remoteCommand("mode", {{"value", value}})) {
        return;
    }
    if (QStringList{"off", "all", "one", "shuffle"}.contains(value)) {
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
        if (mode != value) {
            invalidateAppleTransition();
        }
#endif
        const bool modeChanged = mode != value;
        mode = value;
        if (modeChanged) {
            queue.setShuffle(mode == "shuffle");
        }
        emit changed();
    }
}

void MusicPlayer::setAlternative(bool enabled) {
    if (remoteCommand("alternative", {{"enabled", enabled}})) {
        return;
    }
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    if (alternative != enabled) {
        invalidateAppleTransition();
    }
#endif
    alternative = enabled;
    m_host->setPreference("alternate-source", enabled ? "on" : "off");
    emit changed();
}

void MusicPlayer::clearHistory() {
    if (remoteCommand("clearHistory")) {
        return;
    }
    history = {};
    m_host->setPreference("play-history", "[]");
    emit changed();
}

/** 清除歌词、播放记录与本地封面缓存；登录状态、队列和播放位置保持不变。 */
void MusicPlayer::clearCaches() {
    if (remoteCommand("clearCaches", {})) {
        return;
    }
    lyrics.clearCache();
    clearHistory();
    localCovers = {};
    m_host->setPreference("local-cover-cache", "{}");
    // 当前歌词可能来自刚清掉的缓存，按同一首歌重新读取才能看到修正后的解析结果。
    if (!current.isEmpty()) {
        lyrics.load(current, true);
    }
}

QJsonObject MusicPlayer::playbackSnapshot() const {
    return {{"current", current},
            {"queue", queue.toJson()},
            {"history", history},
            {"index", queue.index()},
            {"mode", mode},
            {"state", state},
            {"loading", loading},
            {"failed", failed},
            {"trial", trial},
            {"preview", previewRequested},
            {"status", status},
            {"quality", quality},
            {"actualQuality", actualQuality},
            {"alternative", alternative},
            {"lyrics", lyrics.playbackSnapshot()}};
}

/** 从服务同步显示副本；封面像素只在 GUI 中加载，旧曲目的异步封面不能覆盖新曲目。 */
void MusicPlayer::applyPlaybackSnapshot() {
    auto connection = m_host->playbackConnection();
    if (!connection) {
        return;
    }
    const auto snapshot = connection->snapshot();
    current = snapshot["current"].toObject();
    queue.syncSnapshot(snapshot["queue"].toArray(), snapshot["index"].toInt(-1));
    history = snapshot["history"].toArray();
    mode = snapshot["mode"].toString("all");
    state = snapshot["state"].toObject();
    loading = snapshot["loading"].toBool();
    failed = snapshot["failed"].toBool();
    trial = snapshot["trial"].toBool();
    previewRequested = snapshot["preview"].toBool();
    status = snapshot["status"].toString();
    quality = snapshot["quality"].toString();
    actualQuality = snapshot["actualQuality"].toString();
    alternative = snapshot["alternative"].toBool();
    lyrics.applyPlaybackSnapshot(snapshot["lyrics"].toObject());
    const auto cover = current["cover"].toString();
    if (m_remoteCover != cover) {
        m_remoteCover = cover;
        coverImage.clear();
        if (!cover.isEmpty()) {
            m_host->loadCover(cover, [this, owner = QPointer(this), cover](QString key) {
                if (owner && m_remoteCover == cover) {
                    coverImage = key;
                    emit changed();
                }
            });
        }
    }
    const auto serial = snapshot["selectionSerial"].toInt();
    const bool selected = m_receivedSnapshot && serial != m_selectionSerial;
    m_receivedSnapshot = true;
    m_selectionSerial = serial;
    emit changed();
    if (selected) {
        emit trackSelected(snapshot["selectedTrack"].toObject());
    }
}

/** 会话存档属于播放核心；后台服务不链接 MusicSession.cpp，入口必须留在本文件。 */
QJsonObject MusicPlayer::sessionState() const {
    const auto live = m_host->mediaState();
    const auto position =
        m_resumePosition.value_or(live.value("position", state["position"].toVariant()).toDouble());
    const bool requested = m_resumePosition
                               ? !m_resumePaused
                               : loading || live.value("requested", state["playing"].toVariant()).toBool();
    return {{"current", current},   {"queue", queue.toJson()}, {"index", queue.index()},     {"mode", mode},
            {"position", position}, {"requested", requested},  {"preview", previewRequested}};
}

void MusicPlayer::restoreSessionState(const QJsonObject &saved) {
    const auto position = saved["position"].toDouble(-1);
    if (!std::isfinite(position) || position < 0 || position > 1e12) {
        return;
    }
    const auto savedMode = saved["mode"].toString();
    mode = QStringList{"all", "one", "off", "shuffle"}.contains(savedMode) ? savedMode : "all";
    queue.setShuffle(mode == "shuffle", false);
    const auto track = saved["current"].toObject();
    const auto savedQueue = saved["queue"].toArray();
    if (track.isEmpty()) {
        queue.restore(savedQueue, saved["index"].toInt(-1), !m_host->playbackConnection());
        emit changed();
        return;
    }
    if (track["kind"] != "song" || track["provider"].toString(m_api->provider) != m_api->provider) {
        return;
    }
    // 先恢复队列再按身份选曲，损坏的旧索引不能使下一首跳到无关位置。
    queue.restore(savedQueue, saved["index"].toInt(-1), !m_host->playbackConnection());
    play(track, std::nullopt, std::nullopt, saved["preview"].toBool(), saved);
}
