#include "AudioPlayer.h"
#include <QUrl>
#include <QMediaMetaData>
#include <QMediaFormat>
#include <QAudioBuffer>
#include <QRegularExpression>
#include <algorithm>
#include <cmath>
#if defined(Q_OS_WIN) && QT_VERSION < QT_VERSION_CHECK(6, 9, 0)
#include <QtMultimedia/private/qaudiodevice_p.h>
#endif

/**
 * 建立播放器与默认输出设备监听；不持久化设备 ID。
 * 每次设备通知重新读取当前默认设备，避免蓝牙连接或切换后继续输出到启动时的设备。
 */
AudioPlayer::AudioPlayer(std::function<void()> changed) : playbackChanged(std::move(changed)) {
    normalizeOutputLayout(defaultOutput());
    output.setVolume(.7f);
    decodeClock.start();
    createPlayer();
    playbackWatchdog.setInterval(250);
    QObject::connect(&playbackWatchdog, &QTimer::timeout, &devices, [this] { checkPlaybackHealth(); });
    QObject::connect(
        &devices, &QMediaDevices::audioOutputsChanged, &devices, [this] { followDefaultOutput(); },
        Qt::QueuedConnection);
    followDefaultOutput();
}
/**
 * 修正 Qt 6.8 Windows 设备枚举中的无效声道位置，保留真正的 WASAPI 设备对象。
 * 必须在设备交给解码线程前执行；不改动系统设备配置，也不保存任何设备属性。
 */
void AudioPlayer::normalizeOutputLayout(const QAudioDevice &device) {
#if defined(Q_OS_WIN) && QT_VERSION < QT_VERSION_CHECK(6, 9, 0)
    if (device.isNull()) {
        return;
    }
    const auto configuration = quint32(device.channelConfiguration());
    constexpr quint32 knownPositions = (1u << QAudioFormat::NChannelPositions) - 2u;
    if (configuration != 0 && (configuration & ~knownPositions) == 0) {
        return;
    }
    const auto preferred = device.preferredFormat();
    auto replacement = preferred.channelConfig();
    if (replacement == QAudioFormat::ChannelConfigUnknown || (quint32(replacement) & ~knownPositions) != 0) {
        // 驱动的最大声道数不代表当前混音格式；只使用 GetMixFormat 返回的实际声道数。
        const auto channels = preferred.channelCount();
        if (channels < 1 || channels > 8) {
            return;
        }
        replacement = QAudioFormat::defaultChannelConfigForChannelCount(channels);
    }
    // Qt 6.8 的描述符字段可变。保留其具体 Windows 类型和 IMMDevice，不能替换成通用描述符。
    // 未知位置位会被 FFmpeg 转成空掩码；Qt 未检查转换失败，随后使用未初始化的布局。
    auto *descriptor = const_cast<QAudioDevicePrivate *>(device.handle());
    descriptor->channelConfiguration = replacement;
#else
    Q_UNUSED(device);
#endif
}
/**
 * 创建独立媒体会话并重新连接状态通知；重建时彻底释放旧后端和未完成的回调。
 * 输出对象保持不变，保留用户音量与当前默认设备。
 */
void AudioPlayer::createPlayer() {
    releasePlayer();
    player = std::make_unique<QMediaPlayer>();
    decodedOutput = std::make_unique<QAudioBufferOutput>();
    const auto changed = playbackChanged;
    if (changed) {
        // 播放状态事件立即唤醒；进度无需依附 60Hz 的场景循环。
        QObject::connect(player.get(), &QMediaPlayer::playbackStateChanged, player.get(),
                         [changed] { changed(); });
        QObject::connect(player.get(), &QMediaPlayer::mediaStatusChanged, player.get(),
                         [changed] { changed(); });
        QObject::connect(player.get(), &QMediaPlayer::errorOccurred, player.get(), [changed] { changed(); });
        QObject::connect(player.get(), &QMediaPlayer::durationChanged, player.get(),
                         [changed] { changed(); });
    }
    if (diagnosticsEnabled || spectrumEnabled) {
        observeDecodedBuffers();
    }
    player->setAudioBufferOutput(diagnosticsEnabled || spectrumEnabled ? decodedOutput.get() : nullptr);
    QObject::connect(player.get(), &QMediaPlayer::metaDataChanged, player.get(),
                     [this] { diagnose("metadata"); });
    QObject::connect(player.get(), &QMediaPlayer::bufferProgressChanged, player.get(),
                     [this] { diagnose("buffer"); });
    QObject::connect(player.get(), &QMediaPlayer::playbackStateChanged, player.get(),
                     [this] { diagnose("playback-state"); });
    QObject::connect(player.get(), &QMediaPlayer::mediaStatusChanged, player.get(),
                     [this] { diagnose("media-status"); });
    QObject::connect(
        player.get(), &QMediaPlayer::errorOccurred, player.get(),
        [this](QMediaPlayer::Error code, const QString &message) { diagnoseError(code, message); });
    player->setAudioOutput(&output);
    QObject::connect(player.get(), &QMediaPlayer::positionChanged, player.get(), [this](qint64 position) {
        // 设备失效时原生后端可能先报 0；保留最后有效进度，主动换曲与跳转另行更新。
        if (!outputUnavailable && recoveryPosition < 0 && position > 0) {
            if (position != lastPosition) {
                progressClock.restart();
            }
            lastPosition = position;
        }
    });
    QObject::connect(
        player.get(), &QMediaPlayer::mediaStatusChanged, player.get(), [this] { restorePlaybackPosition(); },
        Qt::QueuedConnection);
    QObject::connect(
        player.get(), &QMediaPlayer::seekableChanged, player.get(), [this] { restorePlaybackPosition(); },
        Qt::QueuedConnection);
    QObject::connect(player.get(), &QMediaPlayer::mediaStatusChanged, player.get(), [this](auto status) {
        if (status == QMediaPlayer::EndOfMedia && !sourceEnded) {
            sourceEnded = true;
            pendingFailure = false;
            failureRecoverable = false;
            error.clear();
            playbackRequested = false;
            playbackWatchdog.stop();
            ++ended;
        }
    });
    QObject::connect(player.get(), &QMediaPlayer::errorOccurred, player.get(), [this](auto, const QString &) {
        // 不回显底层错误中的临时签名链接；只向界面反馈可操作的错误。
        if (!outputUnavailable && !sourceEnded) {
            pendingFailure = true;
        }
    });
}

/**
 * 检查播放是否卡住
 */
void AudioPlayer::checkPlaybackHealth() {
    if (outputUnavailable || recoveryPosition >= 0 || sourceEnded || !error.isEmpty() ||
        player->source().isEmpty()) {
        return;
    }
    const bool invalid = player->mediaStatus() == QMediaPlayer::InvalidMedia;
    if (!invalid && (!playbackRequested || !progressClock.isValid())) {
        return;
    }
    // 超时
    constexpr qint64 failureStallMs = 4000;
    constexpr qint64 networkStallMs = 15000;
    const auto timeoutMs = pendingFailure ? failureStallMs : networkStallMs;
    if (!invalid && progressClock.elapsed() < timeoutMs) {
        return;
    }
    failureRecoverable = lastPosition > 0 && !invalid;
    pendingFailure = false;
    error = QStringLiteral("音频读取失败，请重试或打开来源页面");
    playbackWatchdog.stop();
    // 暂停后端，由控制层决定是否恢复。
    player->pause();
    diagnose("stalled");
    if (playbackChanged) {
        playbackChanged();
    }
}

/** 在线音源使用可续传的字节流 */
void AudioPlayer::startMediaSource(const QUrl &url) {
    if (url.isLocalFile()) {
        player->setSource(url);
        if (playbackRequested && recoveryPosition < 0) {
            player->play();
        }
        return;
    }
    pendingSource = url;
    stream = std::make_unique<HttpAudioStream>(url);
    stream->ready = [this, url] {
        if (outputUnavailable) {
            return;
        }
        pendingSource.clear();
        progressClock.restart();
        player->setSourceDevice(stream.get(), url);
        if (playbackRequested && recoveryPosition < 0) {
            player->play();
        }
        if (playbackChanged) {
            playbackChanged();
        }
    };
    stream->transportChanged = [this] { diagnose("media-transfer"); };
    stream->failed = [this] {
        pendingFailure = true;
        if (player->source().isEmpty()) {
            error = QStringLiteral("音频连接失败，请重试或打开来源页面");
            pendingSource.clear();
            playbackRequested = false;
            playbackWatchdog.stop();
        }
        if (playbackChanged) {
            playbackChanged();
        }
    };
    if (!stream->start()) {
        error = QStringLiteral("无法创建音频缓冲，请检查临时目录空间");
        pendingSource.clear();
        playbackRequested = false;
        playbackWatchdog.stop();
    }
}
/**
 * 等待新会话可跳转后恢复实际播放位置；FFmpeg 可能直接进入 BufferedMedia。
 * 恢复前的临时进度不能覆盖断开前的位置，也不能取消用户的暂停意图。
 */
void AudioPlayer::restorePlaybackPosition() {
    const auto status = player->mediaStatus();
    const bool ready = status == QMediaPlayer::LoadedMedia || status == QMediaPlayer::BufferedMedia;
    if (!ready || outputUnavailable || recoveryPosition < 0) {
        return;
    }
    // 不能跳转的实时流只能从当前起点恢复，不能因等待 seekable 而永久停住。
    const auto position = player->isSeekable() ? recoveryPosition : 0;
    recoveryPosition = -1;
    lastPosition = position;
    progressClock.restart();
    if (player->isSeekable()) {
        player->setPosition(position);
    }
    if (playbackRequested) {
        player->play();
    }
}
/**
 * 跟随系统默认设备，并在全部输出暂时消失时保留用户的播放意图。
 * 重连同一设备也重新绑定播放器；用户暂停或停止后不得因重连而自动播放。
 */
void AudioPlayer::followDefaultOutput() {
    const auto device = defaultOutput();
    if (diagnosticsEnabled && diagnosticEvent) {
        auto values = diagnosticState();
        values["outputCount"] = QMediaDevices::audioOutputs().size();
        values["outputChanged"] = output.device() != device;
        values["outputUnavailable"] = device.isNull();
        diagnosticEvent("output", values);
    }
    if (device.isNull()) {
        if (!outputUnavailable) {
            recoveryPosition = std::max(lastPosition, player->position());
            outputUnavailable = true;
            playbackWatchdog.stop();
            player->pause();
            player->setAudioOutput(nullptr);
            error.clear();
        }
        return;
    }
    normalizeOutputLayout(device);
    if (!outputUnavailable && output.device() == device) {
        return;
    }
    const bool wasUnavailable = outputUnavailable;
    const auto source = pendingSource.isEmpty() ? player->source() : pendingSource;
    const auto position = std::max<qint64>(0, recoveryPosition);
    if (wasUnavailable) {
        // 全部设备消失后旧 Media Foundation 会话可能保留失效拓扑，必须彻底释放。
        releasePlayer();
    }
    output.setDevice(device);
    if (wasUnavailable) {
        createPlayer();
    } else {
        player->setAudioOutput(&output);
    }
    outputUnavailable = false;
    if (playbackRequested) {
        progressClock.restart();
        playbackWatchdog.start();
    }
    if (wasUnavailable && !source.isEmpty()) {
        pendingSource.clear();
        error.clear();
        recoveryPosition = position;
        startMediaSource(source);
        // 先等新会话加载并恢复跳转，再开始播放，避免原生后端启动时覆盖待恢复的位置。
        return;
    }
    if (playbackRequested && recoveryPosition < 0) {
        player->play();
    }
}
/**
 * 校验音源并交给系统解码播放，沿用原生状态和错误反馈。
 */
bool AudioPlayer::load(QString input, bool offline, bool alternative, QString provider, double position,
                       bool paused) {
    if (!std::isfinite(position) || position < 0 || position > 1e12) {
        return false;
    }
    QUrl url(input);
    const auto host = url.host();
    const bool qq = provider == "qq" && (host == "qqmusic.qq.com" || host.endsWith(".qqmusic.qq.com"));
    const bool kugou = provider == "kugou" && (host.endsWith(".kugou.com") || host.endsWith(".kugou.net"));
    const bool siren = provider == "siren" && (host == "hycdn.cn" || host.endsWith(".hycdn.cn"));
    const bool trusted =
        qq || kugou || siren ||
        (provider == "netease" && (host == "music.126.net" || host.endsWith(".music.126.net") ||
                                   host == "music.163.com" || host.endsWith(".music.163.com")));
    const QStringList providers{"qq.com", "gtimg.com", "kuwo.cn", "kugou.com", "migu.cn"};
    const bool alternateHost =
        alternative && std::any_of(providers.begin(), providers.end(), [&](const auto &domain) {
            return host == domain || host.endsWith("." + domain);
        });
    if ((offline || provider == "local")
            ? !url.isLocalFile()
            : (!(trusted || alternateHost) || !QStringList{"http", "https"}.contains(url.scheme()))) {
        diagnose("load-rejected");
        return false;
    }
    // 酷狗音源沿用上游返回的协议与签名地址
    if (url.scheme() == "http" && !kugou) {
        url.setScheme("https");
    }
    ++sourceSerial;
    backendFailureCategory = 0;
    reportedHttpStatus = 0;
    sourceKind = 0;
    if (url.isLocalFile()) {
        sourceKind = 3;
    } else if (url.scheme() == "https") {
        sourceKind = 1;
    } else if (url.scheme() == "http") {
        sourceKind = 2;
    }
    sourceProvider = QStringList{"other", "netease", "qq", "kugou", "local", "siren"}.indexOf(provider);
    sourceProvider = std::max(0, sourceProvider);
    decodedBuffers = 0;
    decodedBytes = 0;
    decodedFrames = 0;
    lastDecodedElapsedMs = -1;
    lastDecodedEndMs = -1;
    decodedFormat = {};
    clearSpectrum();
    decodeClock.restart();
    // 每次加载隔离旧媒体会话，防止旧解码器的迟到错误污染新曲目。
    createPlayer();
    if (diagnosticsEnabled || spectrumEnabled) {
        observeDecodedBuffers();
    }
    playbackRequested = false;
    recoveryPosition = -1;
    lastPosition = 0;
    error.clear();
    pendingFailure = false;
    failureRecoverable = false;
    sourceEnded = false;
    progressClock.restart();
    pendingSource.clear();
    followDefaultOutput();
    recoveryPosition = position > 0 ? qint64(position) : -1;
    lastPosition = qint64(position);
    if (outputUnavailable) {
        // 没有设备时延后创建解码拓扑，避免启动后再连接耳机被误报为音源错误。
        pendingSource = url;
        player->setSource({});
        playbackRequested = !paused;
        diagnose("load");
        return true;
    }
    playbackRequested = !paused;
    startMediaSource(url);
    if (playbackRequested) {
        playbackWatchdog.start();
    }
    diagnose("load");
    followDefaultOutput();
    return true;
}
void AudioPlayer::control(QString action, double value) {
    if (!std::isfinite(value)) {
        return;
    }
    if (diagnosticsEnabled && diagnosticEvent) {
        auto values = diagnosticState();
        values["action"] = int(std::max<qsizetype>(
            0, QStringList{"other", "pause", "resume", "stop", "seek", "volume"}.indexOf(action)));
        diagnosticEvent("control", values);
    }
    if (action == "pause") {
        clearSpectrum();
        playbackRequested = false;
        playbackWatchdog.stop();
        player->pause();
    } else if (action == "resume") {
        playbackRequested = true;
        progressClock.restart();
        playbackWatchdog.start();
        if (sourceEnded) {
            sourceEnded = false;
        }
        followDefaultOutput();
        if (!outputUnavailable && recoveryPosition < 0) {
            player->play();
        }
    } else if (action == "stop") {
        clearSpectrum();
        playbackRequested = false;
        playbackWatchdog.stop();
        // 先唤醒可能等待网络的解码线程，再释放媒体会话与临时缓存。
        createPlayer();
        lastPosition = 0;
        recoveryPosition = -1;
        pendingSource.clear();
        error.clear();
        pendingFailure = false;
        failureRecoverable = false;
        progressClock.invalidate();
    } else if (action == "seek" && player->isSeekable()) {
        clearSpectrum();
        progressClock.restart();
        lastPosition = qint64(std::clamp(value, 0., double(player->duration())));
        if (recoveryPosition >= 0) {
            recoveryPosition = lastPosition;
        }
        player->setPosition(lastPosition);
    } else if (action == "volume") {
        output.setVolume(float(std::clamp(value, 0., 1.)));
    }
}
QVariantMap AudioPlayer::state() const {
    const auto position = recoveryPosition >= 0 ? recoveryPosition : player->position();
    return {{"playing", player->isPlaying()},
            {"position", position},
            {"duration", player->duration()},
            {"seekable", player->isSeekable()},
            {"volume", output.volume()},
            {"ended", ended},
            {"error", error},
            {"recoverable", failureRecoverable},
            {"requested", playbackRequested},
            {"buffering", player->mediaStatus() == QMediaPlayer::LoadingMedia ||
                              (!pendingSource.isEmpty() && !outputUnavailable) ||
                              player->mediaStatus() == QMediaPlayer::StalledMedia}};
}

/** 接收解码缓冲的数值统计 */
void AudioPlayer::enableDiagnostics(bool enabled) {
    if (diagnosticsEnabled == enabled) {
        return;
    }
    diagnosticsEnabled = enabled;
    if (enabled || spectrumEnabled) {
        observeDecodedBuffers();
    } else {
        ++decoderObservation;
        QObject::disconnect(decoderConnection);
    }
    player->setAudioBufferOutput(enabled || spectrumEnabled ? decodedOutput.get() : nullptr);
}

void AudioPlayer::clearSpectrum() {
    spectrum.reset();
    spectrumClock.invalidate();
    if (spectrumEnabled && spectrumChanged) {
        spectrumChanged(spectrum.levels());
    }
}

void AudioPlayer::enableSpectrum(bool enabled) {
    if (spectrumEnabled == enabled) {
        return;
    }
    spectrumEnabled = enabled;
    clearSpectrum();
    if (enabled || diagnosticsEnabled) {
        observeDecodedBuffers();
    } else {
        ++decoderObservation;
        QObject::disconnect(decoderConnection);
    }
    player->setAudioBufferOutput(enabled || diagnosticsEnabled ? decodedOutput.get() : nullptr);
}

void AudioPlayer::diagnose(const QString &event) {
    if (diagnosticsEnabled && diagnosticEvent) {
        diagnosticEvent(event, diagnosticState());
    }
}

QJsonObject AudioPlayer::diagnosticState() const {
    const auto metadata = player->metaData();
    const auto outputFormat = output.device().preferredFormat();
    bool codecConverted = false;
    auto codec = metadata.value(QMediaMetaData::AudioCodec).toInt(&codecConverted);
    if (!codecConverted || codec < int(QMediaFormat::AudioCodec::Unspecified) ||
        codec > int(QMediaFormat::AudioCodec::LastAudioCodec)) {
        codec = int(QMediaFormat::AudioCodec::Unspecified);
    }
    auto values = stream ? stream->diagnosticState() : QJsonObject{};
    const QJsonObject playback{
        {"sourceSerial", sourceSerial},
        {"sourceKind", sourceKind},
        {"provider", sourceProvider},
        {"mediaStatus", int(player->mediaStatus())},
        {"playbackState", int(player->playbackState())},
        {"errorCode", int(player->error())},
        {"backendFailureCategory", backendFailureCategory},
        {"reportedHttpStatus", reportedHttpStatus},
        {"playing", player->isPlaying()},
        {"latchedError", !error.isEmpty()},
        {"pendingFailure", pendingFailure},
        {"recoverable", failureRecoverable},
        {"hasActiveSource", !player->source().isEmpty() || !pendingSource.isEmpty()},
        {"positionMs", double(player->position())},
        {"durationMs", double(player->duration())},
        {"seekable", player->isSeekable()},
        {"bufferProgress", double(player->bufferProgress())},
        {"requested", playbackRequested},
        {"volume", double(output.volume())},
        {"muted", output.isMuted()},
        {"endedSerial", ended},
        {"recoveryPositionMs", double(recoveryPosition)},
        {"outputUnavailable", outputUnavailable},
        {"outputCount", QMediaDevices::audioOutputs().size()},
        {"outputPreferredSampleRateHz", outputFormat.sampleRate()},
        {"outputPreferredChannels", outputFormat.channelCount()},
        {"outputPreferredSampleFormat", int(outputFormat.sampleFormat())},
        {"outputChannelConfig", double(quint32(output.device().channelConfiguration()))},
        {"codec", codec},
        {"bitrate", metadata.value(QMediaMetaData::AudioBitRate).toDouble()},
        {"sampleRateHz", decodedFormat.sampleRate()},
        {"channels", decodedFormat.channelCount()},
        {"sampleFormat", int(decodedFormat.sampleFormat())},
        {"decodedBuffers", double(decodedBuffers)},
        {"decodedBytes", double(decodedBytes)},
        {"decodedFrames", double(decodedFrames)},
        {"lastDecodedElapsedMs", double(lastDecodedElapsedMs)},
        {"lastDecodedEndMs", double(lastDecodedEndMs)}};
    for (auto it = playback.begin(); it != playback.end(); ++it) {
        values[it.key()] = it.value();
    }
    return values;
}

/** 将后端错误映射为有限类别；禁止把错误原文传入诊断记录。 */
void AudioPlayer::diagnoseError(QMediaPlayer::Error code, const QString &message) {
    if (diagnosticsEnabled && diagnosticEvent) {
        // 原文可能包含签名链接或文件路径；只匹配固定故障类别，不保存原文。
        const auto lower = message.toLower();
        const QList<QStringList> categories{{"timed out", "timeout"},
                                            {"resolve", "name or service not known"},
                                            {"connection reset"},
                                            {"invalid data"},
                                            {"decoder", "codec"},
                                            {"audio output", "audio device"},
                                            {"permission denied", "access denied"},
                                            {"ssl", "tls", "certificate"},
                                            {"end of file", "eof"},
                                            {"not found", "no such file"},
                                            {"server returned", "http error"}};
        backendFailureCategory = 0;
        for (int i = 0; i < categories.size() && backendFailureCategory == 0; ++i) {
            for (const auto &pattern : categories[i]) {
                if (lower.contains(pattern)) {
                    backendFailureCategory = i + 1;
                    break;
                }
            }
        }
        const QRegularExpression httpStatus(
            QStringLiteral("(?:http error|server returned)\\s+([45][0-9]{2})(?:\\D|$)"));
        reportedHttpStatus = httpStatus.match(lower).captured(1).toInt();
        auto values = diagnosticState();
        values["errorCode"] = int(code);
        diagnosticEvent("error", values);
    }
}

/** 重新绑定统计代数，旧音源已经排队的解码回调不能计入新音源或新采集区间。 */
void AudioPlayer::observeDecodedBuffers() {
    QObject::disconnect(decoderConnection);
    ++decoderObservation;
    decoderConnection = QObject::connect(
        decodedOutput.get(), &QAudioBufferOutput::audioBufferReceived, decodedOutput.get(),
        [this, observation = decoderObservation, generation = sourceSerial](const QAudioBuffer &buffer) {
            if (observation != decoderObservation || generation != sourceSerial || !buffer.isValid()) {
                return;
            }
            if (spectrumEnabled && player->isPlaying() && spectrum.consume(buffer) &&
                (!spectrumClock.isValid() || spectrumClock.elapsed() >= 50)) {
                spectrumClock.restart();
                if (spectrumChanged) {
                    spectrumChanged(spectrum.levels());
                }
            }
            if (!diagnosticsEnabled) {
                return;
            }
            ++decodedBuffers;
            decodedBytes += buffer.byteCount();
            decodedFrames += buffer.frameCount();
            decodedFormat = buffer.format();
            lastDecodedElapsedMs = decodeClock.elapsed();
            lastDecodedEndMs = buffer.startTime() >= 0 ? (buffer.startTime() + buffer.duration()) / 1000 : -1;
        });
}

AudioPlayer::~AudioPlayer() {
    playbackWatchdog.stop();
    releasePlayer();
}

/** 先释放解码观察对象，再释放媒体会话 */
void AudioPlayer::releasePlayer() {
    ++decoderObservation;
    QObject::disconnect(decoderConnection);
    if (stream) {
        stream->cancel();
    }
    if (player) {
        // 销毁旧会话期间不再发送状态快照，避免访问正在释放的成员。
        player->blockSignals(true);
    }
    decodedOutput.reset();
    player.reset();
    stream.reset();
}
