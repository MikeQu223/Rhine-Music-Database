#include "AudioPlayer.h"
#include <QUrl>
#include <QMediaMetaData>
#include <QMediaFormat>
#include <QAudioBuffer>
#include <QRegularExpression>
#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <utility>
#if defined(Q_OS_WIN) && QT_VERSION < QT_VERSION_CHECK(6, 9, 0)
#include <QtMultimedia/private/qaudiodevice_p.h>
#endif

namespace {
// CoreAudio/WASAPI 不会在系统采样率变化时通知 Qt，播放中仍需低频兜底重读。
constexpr qint64 OUTPUT_FORMAT_PROBE_INTERVAL_MS = 5000;
// 观测值超过一个探测周期加余量后不再可信：期间可能已经 seek、暂停或重建过输出。
constexpr qint64 OUTPUT_FORMAT_OBSERVATION_MAX_AGE_MS = 15000;
}

/**
 * 系统输出格式的后台探测线程。
 * Windows COM 与 CoreAudio HAL 调用最长可阻塞数百毫秒，不能占用音频泵线程；
 * 工作线程只接收设备 id 与默认标记，绝不持有 QAudioDevice。
 * 请求与结果都只保留最新一份，探测跟不上时丢弃过期数据而不是排队。
 */
class AudioPlayer::OutputFormatProbe {
  public:
    using Probe = std::function<AudioOutputFormat::SystemFormat(const QByteArray &, bool)>;
    struct Observation {
        QByteArray deviceId;
        AudioOutputFormat::SystemFormat system;
    };

    OutputFormatProbe() {
        m_thread = std::thread([this] { run(); });
    }

    ~OutputFormatProbe() {
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_stopping = true;
        }
        m_wake.notify_all();
        if (m_thread.joinable()) {
            m_thread.join();
        }
    }

    void request(QByteArray deviceId, bool isDefault, Probe probe) {
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            if (m_stopping) {
                return;
            }
            m_requestId = std::move(deviceId);
            m_requestIsDefault = isDefault;
            m_requestProbe = std::move(probe);
            m_hasRequest = true;
        }
        m_wake.notify_one();
    }

    bool take(Observation &observation) {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (!m_hasObservation) {
            return false;
        }
        observation = std::move(m_observation);
        m_observation = {};
        m_hasObservation = false;
        return true;
    }

  private:
    void run() {
        for (;;) {
            QByteArray deviceId;
            bool isDefault = false;
            Probe probe;
            {
                std::unique_lock<std::mutex> lock(m_mutex);
                m_wake.wait(lock, [this] { return m_hasRequest || m_stopping; });
                if (m_stopping) {
                    return;
                }
                deviceId = std::move(m_requestId);
                m_requestId.clear();
                isDefault = m_requestIsDefault;
                probe = std::move(m_requestProbe);
                m_requestProbe = {};
                m_hasRequest = false;
            }
            if (!probe) {
                continue;
            }
            auto system = probe(deviceId, isDefault);
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                if (m_stopping) {
                    return;
                }
                m_observation.deviceId = std::move(deviceId);
                m_observation.system = std::move(system);
                m_hasObservation = true;
            }
        }
    }

    std::thread m_thread;
    std::mutex m_mutex;
    std::condition_variable m_wake;
    QByteArray m_requestId;
    bool m_requestIsDefault = false;
    bool m_hasRequest = false;
    Probe m_requestProbe;
    Observation m_observation;
    bool m_hasObservation = false;
    bool m_stopping = false;
};

/**
 * 建立播放器与默认输出设备监听；不持久化设备 ID。
 * 每次设备通知重新读取当前默认设备，避免蓝牙连接或切换后继续输出到启动时的设备。
 */
AudioPlayer::AudioPlayer(std::function<void()> changed) : playbackChanged(std::move(changed)) {
    normalizeOutputLayout(defaultOutput());
    output.setVolume(.7f);
    QObject::connect(&output, &QAudioOutput::volumeChanged, &devices,
                     [this](float volume) { pcm.setVolume(volume); });
    pcm.backpressure = [this](bool blocked) {
        decoderThrottled = blocked;
        if (!player || !playbackRequested || outputUnavailable || decoderEnded || !error.isEmpty()) {
            return;
        }
        if (blocked) {
            player->pause();
        } else {
            player->play();
        }
    };
    pcm.completed = [this] {
        if (decoderEnded) {
            completePlayback();
        }
    };
    pcm.errorOccurred = [this] {
        if (!player || outputUnavailable) {
            return;
        }
        error = QStringLiteral("音频输出失败，请检查输出设备或切换输出策略");
        failureRecoverable = player->isSeekable();
        player->pause();
        playbackWatchdog.stop();
        diagnose("output");
        if (playbackChanged) {
            playbackChanged();
        }
    };
    // 非 FFmpeg 后端没有 QAudioBufferOutput，保留原生 QAudioOutput 路径用于兼容性对照。
    const auto mediaBackend = qEnvironmentVariable("QT_MEDIA_BACKEND");
    pcmEnabled = mediaBackend.isEmpty() || mediaBackend == "ffmpeg";
    decodeClock.start();
    outputFormatClock.start();
    // 平台格式探测走独立线程，播放器与 PCM 泵所在线程不做任何设备枚举。
    outputFormatProbe = std::make_unique<OutputFormatProbe>();
    createPlayer();
    playbackWatchdog.setInterval(250);
    QObject::connect(&playbackWatchdog, &QTimer::timeout, &devices, [this] {
        checkPlaybackHealth();
        // 后台结果只在主线程比较；比较与重建顺序保持原样。
        applyPendingOutputFormatObservation();
        // 系统采样率变化不会触发 Qt 的设备通知，播放中定期重读；实际平台调用在工作线程。
        if (outputFormatClock.elapsed() >= OUTPUT_FORMAT_PROBE_INTERVAL_MS) {
            outputFormatClock.restart();
            requestOutputFormatProbe();
        }
    });
    QObject::connect(
        &devices, &QMediaDevices::audioOutputsChanged, &devices, [this] { followDefaultOutput(true); },
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
    observeDecodedBuffers();
    player->setAudioBufferOutput(decodedOutput.get());
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
    player->setAudioOutput(pcmEnabled ? nullptr : &output);
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
        if (status == QMediaPlayer::EndOfMedia && !sourceEnded && !decoderEnded) {
            decoderEnded = true;
            if (pcmEnabled) {
                pcm.finish();
            } else {
                completePlayback();
            }
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
    if (outputUnavailable || recoveryPosition >= 0 || sourceEnded || decoderEnded || decoderThrottled ||
        !error.isEmpty() || player->source().isEmpty()) {
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
    pcm.pause(true);
    diagnose("stalled");
    if (playbackChanged) {
        playbackChanged();
    }
}

/** 在线音源使用可续传的字节流 */
void AudioPlayer::startMediaSource(const QUrl &url) {
#ifdef Q_OS_ANDROID
    // Android 后端的 setMedia 会忽略 QIODevice、直接把 URL 交给系统播放器流式播放
    // （qandroidmediaplayer.cpp 的 setMedia 只取 URL）；若仍启动 HttpAudioStream 预下载，
    // 只会产生一份用不上的流量。Range 续传与 seek 由系统播放器自己处理。
    player->setSource(url);
    if (playbackRequested && recoveryPosition < 0) {
        player->play();
    }
    return;
#endif
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
    } else {
        // 不可 seek 只能从头播放；同步清除旧恢复位置的时间过滤，否则开头音频会被全部丢弃。
        pcm.reset(output.device(), outputPolicy, 0);
        pcm.pause(!playbackRequested);
    }
    if (playbackRequested) {
        player->play();
    }
}
/**
 * 跟随系统默认设备，并在全部输出暂时消失时保留用户的播放意图。
 * 重连同一设备也重新绑定播放器；用户暂停或停止后不得因重连而自动播放。
 */
void AudioPlayer::followDefaultOutput(bool refresh, const AudioOutputFormat::SystemFormat *observedSystem) {
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
            // 尚未消费的续播位置优先；异步加载期间设备消失时不能把它覆盖成当前解码位置。
            if (recoveryPosition < 0) {
                recoveryPosition = playbackPosition();
            }
            outputUnavailable = true;
            pcm.pause(true);
            pcm.reset({}, outputPolicy, recoveryPosition);
            playbackWatchdog.stop();
            player->pause();
            player->setAudioOutput(nullptr);
            error.clear();
        }
        return;
    }
    normalizeOutputLayout(device);
    if (!outputUnavailable && output.device() == device && devicePreferred == device.preferredFormat()) {
        if (!refresh) {
            return;
        }
        // 后台已经观测到变化时直接复用；设备通知路径仍在主线程现场探测。
        const auto observed = observedSystem ? *observedSystem : AudioOutputFormat::systemFormat(device);
        const auto current = pcm.snapshot();
        if (current["outputSystemFormatStatus"].toInt() == observed.status &&
            current["outputSystemSampleRateHz"].toInt() == observed.format.sampleRate() &&
            current["outputSystemChannels"].toInt() == observed.format.channelCount() &&
            current["outputSystemSampleFormat"].toInt() == int(observed.format.sampleFormat())) {
            return;
        }
    }
    const bool wasUnavailable = outputUnavailable;
    const auto previousPosition = playbackPosition();
    const auto source = pendingSource.isEmpty() ? player->source() : pendingSource;
    const auto position = std::max<qint64>(0, recoveryPosition);
    if (wasUnavailable) {
        // 全部设备消失后旧 Media Foundation 会话可能保留失效拓扑，必须彻底释放。
        releasePlayer();
    }
    output.setDevice(device);
    devicePreferred = device.preferredFormat();
    if (wasUnavailable) {
        createPlayer();
    } else if (!player->source().isEmpty() && player->isSeekable()) {
        observeDecodedBuffers();
        player->setPosition(previousPosition);
    }
    pcm.reset(device, outputPolicy, wasUnavailable ? position : previousPosition, observedSystem);
    decoderThrottled = false;
    pcm.pause(!playbackRequested);
    // 排空期间重建输出会清掉 drain 状态；源已经结束时补发完成事件，否则 ended 永远不会递增。
    if (decoderEnded) {
        completePlayback();
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
 * 把系统格式重读交给后台线程。
 * CoreAudio/WASAPI 不会在设备采样率变化时通知 Qt；主线程只拷贝设备 id 与探测函数，
 * 平台枚举本身不在这里执行。
 */
void AudioPlayer::requestOutputFormatProbe() {
    if (!outputFormatProbe) {
        return;
    }
    const auto device = output.device();
    if (outputUnavailable || device.isNull()) {
        return;
    }
    outputFormatProbe->request(device.id(), device.isDefault(), readSystemOutputFormat);
}
/**
 * 消费后台最新观测值；只有观测到的格式与当前输出记录不一致时才重建，避免无谓重置 PCM 队列。
 * 返回 false 表示这一拍没有可消费的结果。
 */
bool AudioPlayer::applyPendingOutputFormatObservation() {
    if (!outputFormatProbe) {
        return false;
    }
    OutputFormatProbe::Observation observation;
    if (!outputFormatProbe->take(observation)) {
        return false;
    }
    // 设备已经切换或消失、或者结果已经过时（暂停/seek 期间攒下的）时丢弃。
    if (outputUnavailable || output.device().isNull() || observation.deviceId != output.device().id() ||
        outputFormatClock.elapsed() > OUTPUT_FORMAT_OBSERVATION_MAX_AGE_MS) {
        return true;
    }
    // status 0 表示这次平台读取失败；不能据此重建，保留当前输出等下一轮探测。
    if (observation.system.status == 0) {
        return true;
    }
    const auto current = pcm.snapshot();
    if (observation.system.status == current["outputSystemFormatStatus"].toInt() &&
        observation.system.format.sampleRate() == current["outputSystemSampleRateHz"].toInt() &&
        observation.system.format.channelCount() == current["outputSystemChannels"].toInt() &&
        int(observation.system.format.sampleFormat()) == current["outputSystemSampleFormat"].toInt()) {
        return true;
    }
    followDefaultOutput(true, &observation.system);
    return true;
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
    decoderEnded = false;
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
    pcm.reset(output.device(), outputPolicy, qint64(position));
    pcm.pause(paused);
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
        pcm.pause(true);
    } else if (action == "resume") {
        playbackRequested = true;
        progressClock.restart();
        playbackWatchdog.start();
        // 已自然播完时按播放要重新武装解码器；只清 sourceEnded 会让界面显示在播却没有声音。
        const bool restart = sourceEnded || (decoderEnded && pcm.complete());
        sourceEnded = false;
        if (restart) {
            decoderEnded = false;
            pcm.reset(output.device(), outputPolicy, 0);
            observeDecodedBuffers();
            if (player->isSeekable()) {
                player->setPosition(0);
            }
        }
        pcm.pause(false);
        followDefaultOutput();
        if (!outputUnavailable && recoveryPosition < 0 && !decoderThrottled && !decoderEnded) {
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
        decoderEnded = false;
        sourceEnded = false;
        pcm.pause(true);
        pcm.reset(output.device(), outputPolicy, lastPosition);
        decoderThrottled = false;
        observeDecodedBuffers();
        player->setPosition(lastPosition);
        pcm.pause(!playbackRequested);
        if (playbackRequested && !outputUnavailable && recoveryPosition < 0) {
            player->play();
        }
    } else if (action == "volume") {
        output.setVolume(float(std::clamp(value, 0., 1.)));
    }
}
QVariantMap AudioPlayer::state() const {
    const auto position = recoveryPosition >= 0 ? recoveryPosition : playbackPosition();
    return {{"playing", playbackRequested && !outputUnavailable && error.isEmpty() &&
                            (player->isPlaying() || decoderThrottled || (decoderEnded && !sourceEnded))},
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
    const auto outputValues = pcm.snapshot();
    for (auto it = outputValues.begin(); it != outputValues.end(); ++it) {
        values[it.key()] = it.value();
    }
    const QJsonObject playback{
        {"sourceSerial", sourceSerial},
        {"sourceKind", sourceKind},
        {"provider", sourceProvider},
        {"mediaStatus", int(player->mediaStatus())},
        {"playbackState", int(player->playbackState())},
        {"errorCode", int(player->error())},
        {"backendFailureCategory", backendFailureCategory},
        {"reportedHttpStatus", reportedHttpStatus},
        {"playing", state()["playing"].toBool()},
        {"latchedError", !error.isEmpty()},
        {"pendingFailure", pendingFailure},
        {"recoverable", failureRecoverable},
        {"hasActiveSource", !player->source().isEmpty() || !pendingSource.isEmpty()},
        {"positionMs", double(playbackPosition())},
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
            decodedFormat = buffer.format();
            if (pcmEnabled && !outputUnavailable && !pcm.push(buffer)) {
                return;
            }
            if (spectrumEnabled && playbackRequested && spectrum.consume(buffer) &&
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
    // 先停探测线程再释放播放器与 PCM：退出最多等一次在途的平台调用。
    outputFormatProbe.reset();
    releasePlayer();
}

/** 先释放解码观察对象，再释放媒体会话 */
void AudioPlayer::releasePlayer() {
    ++decoderObservation;
    QObject::disconnect(decoderConnection);
    pcm.pause(true);
    pcm.reset(output.device(), outputPolicy);
    decoderThrottled = decoderEnded = false;
    decodedFormat = {};
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

qint64 AudioPlayer::playbackPosition() const {
    return pcmEnabled && pcm.active() ? pcm.position() : player->position();
}

void AudioPlayer::completePlayback() {
    if (sourceEnded) {
        return;
    }
    sourceEnded = true;
    pendingFailure = failureRecoverable = false;
    error.clear();
    playbackRequested = false;
    playbackWatchdog.stop();
    ++ended;
    if (playbackChanged) {
        playbackChanged();
    }
}

void AudioPlayer::setOutputPolicy(AudioOutputFormat::Policy policy) {
    if (outputPolicy == policy) {
        return;
    }
    const auto position = playbackPosition();
    // 错误提示要求用户切换输出策略；重建输出后解除上一次输出错误，否则界面会一直停在失败状态。
    const bool outputFailed = pcm.failed();
    outputPolicy = policy;
    pcm.pause(true);
    pcm.reset(output.device(), policy, position);
    if (outputFailed) {
        error.clear();
        pendingFailure = false;
        failureRecoverable = false;
    }
    decoderThrottled = false;
    if (player->isSeekable()) {
        decoderEnded = false;
        observeDecodedBuffers();
        player->setPosition(position);
    }
    pcm.pause(!playbackRequested);
    if (playbackRequested && !outputUnavailable && recoveryPosition < 0 && !decoderEnded) {
        player->play();
    }
    diagnose("output");
}
