#include "AudioPlayer.h"
#include "PlatformFeatures.h"
#include "AppStorage.h"
#include "ProviderRegistry.h"
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
#include "AppleAudioPlayer.h"
#include "AppleTransitionPlan.h"
#include "AppleTransitionMedia.h"
#include "AppleTransitionAudio.h"
#include <QNetworkAccessManager>
#include <QThreadPool>
#endif
#if defined(Q_OS_WIN) && QT_VERSION < QT_VERSION_CHECK(6, 9, 0)
#include <QtMultimedia/private/qaudiodevice_p.h>
#endif

namespace {
// CoreAudio/WASAPI 不会在系统采样率变化时通知 Qt，播放中仍需低频兜底重读。
constexpr qint64 OUTPUT_FORMAT_PROBE_INTERVAL_MS = 5000;
// 观测值超过一个探测周期加余量后不再可信：期间可能已经 seek、暂停或重建过输出。
constexpr qint64 OUTPUT_FORMAT_OBSERVATION_MAX_AGE_MS = 15000;

/** 正常起播和下一首预卷必须通过相同的媒体协议与主机校验。 */
bool allowsMediaEndpoint(const QUrl &url, bool alternative, const QJsonObject &media) {
    const auto host = url.host();
    const auto matchesHost = [&host](const QJsonArray &values) {
        for (const auto &value : values) {
            const auto pattern = value.toString();
            if (pattern == host || (pattern.startsWith("*.") && host.endsWith(pattern.mid(1)))) {
                return true;
            }
        }
        return false;
    };
    const bool trusted = matchesHost(media["hosts"].toArray());
    const bool alternateHost = alternative && matchesHost(media["alternativeHosts"].toArray());
    const bool httpAllowed =
        media["allowHttp"].toBool() || media["schemePolicy"].toString() == "http-or-https";
    const bool schemeAllowed = url.scheme() == "https" || (url.scheme() == "http" && httpAllowed);
    return (trusted || alternateHost) && schemeAllowed;
}

bool allowsPlaybackSource(const QUrl &url, bool offline, bool alternative, const QString &provider) {
    return offline || provider == "local"
               ? url.isLocalFile()
               : allowsMediaEndpoint(url, alternative, ProviderRegistry::instance().mediaPolicy(provider));
}
}

#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
namespace {
void useUnstretchedFade(AppleTransitionPlan &plan) {
    const auto overlap = std::min<qint64>(plan.overlapMs, 1800);
    plan.outgoingMs += plan.overlapMs - overlap;
    plan.kind = AppleTransitionPlan::Kind::Fade;
    plan.alignment = AppleTransitionPlan::Alignment::None;
    plan.incomingMs = 0;
    plan.incomingRate = 1.0;
    plan.overlapMs = overlap;
}
}

struct AudioPlayer::AppleTransition {
    struct Analysis {
        AppleTransitionPlan plan;
        std::shared_ptr<const AppleTransitionAudio> preparedAudio;
        std::shared_ptr<const QString> outgoingFile;
        std::shared_ptr<const QString> incomingFile;
        std::atomic_int pendingSources = 2;
        std::atomic_bool cancelled = false;
        std::atomic_bool ready = false;
        bool tempoFallback = false;
    };
    using Phase = AppleTransitionPlan::Phase;
    QUrl source;
    std::shared_ptr<Analysis> analysis = std::make_shared<Analysis>();
    AppleTransitionPlan plan;
    std::unique_ptr<AppleAudioPlayer> incoming;
    AppleAudioPlayer::TransitionOutput route = AppleAudioPlayer::TransitionOutput::Unsupported;
    QElapsedTimer routeClock;
    QElapsedTimer armedClock;
    QElapsedTimer fadeTailClock;
    qint64 armedLeadMs = 0;
    qint64 syncProblemSinceMs = -1;
    double fadeProgress = 0;
    double fadeTailStart = 0;
    double fadeTailDurationMs = 0;
    Phase phase = Phase::Analyzing;
    bool streaming = false;
    bool rejectedPreparedAudio = false;
    float outgoingGain = 1.0f;
    float incomingGain = 0.0f;
};
#endif

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
    output.setVolume(PlatformFeatures::NativeAppleAudio && !PlatformFeatures::ApplicationVolume ? 1.f : .7f);
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
#ifdef Q_OS_WIN
        error = QStringLiteral("音频输出失败，请检查输出设备、切换输出策略或关闭独占输出");
#else
        error = QStringLiteral("音频输出失败，请检查输出设备或切换输出策略");
#endif
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
        if (applePlayer) {
#ifdef Q_OS_MACOS
            if (diagnosticsEnabled) {
                applyPendingOutputFormatObservation();
                if (outputFormatClock.elapsed() >= OUTPUT_FORMAT_PROBE_INTERVAL_MS) {
                    outputFormatClock.restart();
                    requestOutputFormatProbe();
                }
            }
#endif
            checkApplePlayback();
            return;
        }
#endif
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    // Qt 播放器只保留空闲状态接口。换歌时复用它，AVPlayer 会话独立释放。
    if (useApplePlayback && player) {
        closeApplePlayback();
        return;
    }
#endif
    releasePlayer();
#ifdef Q_OS_WIN
    pcm.setExclusive(AppStorage::settings().value("panel/audio-exclusive", "off").toString() == "on");
#endif
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    if (applePlayer) {
#ifdef Q_OS_MACOS
        // AVPlayer 自己跟随默认路由；全部输出消失时保留当前曲目与播放意图。
        outputUnavailable = device.isNull();
        if (output.device() != device) {
            resetAppleTransitionSchedule();
            output.setDevice(device);
            appleSystemFormat = {};
            if (diagnosticsEnabled) {
                requestOutputFormatProbe();
            }
        }
        if (outputUnavailable) {
            applePlayer->setPaused(true);
        }
        progressClock.restart();
#endif
        return;
    }
#endif
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    if (applePlayer) {
        appleSystemFormat = observation.system;
        return true;
    }
#endif
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
    if (!allowsPlaybackSource(url, offline, alternative, provider)) {
        diagnose("load-rejected");
        return false;
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
    sourceProvider = ProviderRegistry::instance().diagnosticsOrdinal(provider, 0);
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    if (useApplePlayback) {
#ifdef Q_OS_IOS
        // 音频会话激活前，Qt 的设备列表可能为空；路由和中断由 AVAudioSession 管理。
        outputUnavailable = false;
#endif
        const bool opened = startApplePlayback(url, paused);
        diagnose(opened ? "load" : "load-rejected");
        return opened;
    }
#endif
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    if (applePlayer && action != "stop") {
        controlApplePlayback(action, value);
        return;
    }
#endif
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    if (applePlayer) {
        const auto status = applePlayer->status();
        const auto duration = applePlayer->duration();
        return {{"playing", playbackRequested && !outputUnavailable && error.isEmpty() &&
                                status == AppleAudioPlayer::Status::Ready && applePlayer->isPlaying()},
                {"position", recoveryPosition >= 0 && duration > 0 ? std::min(position, duration) : position},
                {"duration", duration},
                {"seekable", applePlayer->isSeekable()},
                {"volume", output.volume()},
                {"ended", ended},
                {"error", error},
                {"recoverable", failureRecoverable},
                {"requested", playbackRequested},
                {"buffering", error.isEmpty() &&
                                  (status == AppleAudioPlayer::Status::Loading || recoveryPosition >= 0 ||
                                   applePlayer->isSeeking() ||
                                   (playbackRequested && !outputUnavailable && !applePlayer->isPlaying()))}};
    }
#endif
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    if (applePlayer) {
        const auto spatialState = state();
        const auto nativeValues = applePlayer->diagnosticState();
        for (auto it = nativeValues.begin(); it != nativeValues.end(); ++it) {
            values[it.key()] = it.value();
        }
        values["outputBackend"] = 2;
        values["outputSystemFormatStatus"] = appleSystemFormat.status;
        values["outputSystemSampleRateHz"] = appleSystemFormat.format.sampleRate();
        values["outputSystemChannels"] = appleSystemFormat.format.channelCount();
        values["outputSystemSampleFormat"] = int(appleSystemFormat.format.sampleFormat());
        values["hasActiveSource"] = true;
        values["durationMs"] = double(applePlayer->duration());
        values["seekable"] = spatialState["seekable"].toBool();
        auto mediaStatus = spatialState["buffering"].toBool() ? QMediaPlayer::LoadingMedia
                                                             : QMediaPlayer::LoadedMedia;
        if (!error.isEmpty()) {
            mediaStatus = QMediaPlayer::InvalidMedia;
        } else if (sourceEnded) {
            mediaStatus = QMediaPlayer::EndOfMedia;
        }
        values["mediaStatus"] = int(mediaStatus);
        values["playbackState"] =
            int(spatialState["playing"].toBool() ? QMediaPlayer::PlayingState : QMediaPlayer::PausedState);
        if (appleTransition) {
            const auto &transition = *appleTransition;
            values["transitionPhase"] = int(transition.phase);
            if (transition.phase != AppleTransition::Phase::Analyzing) {
                const auto &plan = transition.plan;
                const auto &incoming = plan.incomingAnalysis;
                values["transitionKind"] = int(plan.kind);
                values["transitionAtMs"] = plan.outgoingMs;
                values["transitionIncomingMs"] = plan.incomingMs;
                values["transitionOverlapMs"] = plan.overlapMs;
                values["transitionRate"] = plan.incomingRate;
                values["transitionAlignment"] = int(plan.alignment);
                values["transitionOutgoingBpm"] = plan.outgoingBpm;
                values["transitionSpectralScore"] = plan.spectralScore;
                values["transitionIncomingTonic"] = incoming.tonic;
                values["transitionIncomingMinor"] = incoming.minor;
                values["transitionIncomingBpm"] = incoming.bpm;
                values["transitionIncomingBarMs"] = incoming.firstBarMs;
                values["transitionIncomingBeatsPerBar"] = incoming.beatsPerBar;
            }
            if (transition.phase == AppleTransition::Phase::Armed) {
                values["transitionIncomingPlaying"] =
                    transition.fadeProgress > 0 && transition.incoming->isPlaying();
            }
            if (transition.phase == AppleTransition::Phase::Armed ||
                transition.phase == AppleTransition::Phase::Recovering) {
                values["transitionOutgoingGain"] = transition.outgoingGain;
                values["transitionIncomingGain"] = transition.incomingGain;
            }
        }
    }
#endif
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    closeApplePlayback();
#endif
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    if (applePlayer) {
        return applePlayer->position();
    }
#endif
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
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    if (useApplePlayback) {
        return;
    }
#endif
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

#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
void AudioPlayer::closeApplePlayback() {
    cancelAppleTransition();
    if (!applePlayer) {
        return;
    }
    playbackWatchdog.stop();
    applePlayer.reset();
    appleAnalysisFile.reset();
    appleSource.clear();
    appleSystemFormat = {};
    playbackWatchdog.setInterval(250);
}

bool AudioPlayer::startApplePlayback(const QUrl &source, bool paused) {
    applePlayer = AppleAudioPlayer::open(source);
    if (!applePlayer) {
        return false;
    }
    appleSource = source;
    playbackRequested = !paused;
    applePlayer->setVolume(output.volume());
#ifdef Q_OS_MACOS
    if (diagnosticsEnabled) {
        outputFormatClock.restart();
        requestOutputFormatProbe();
    }
#endif
    progressClock.restart();
    playbackWatchdog.setTimerType(Qt::PreciseTimer);
    playbackWatchdog.start(100);
    return true;
}

/** 播放开始后立即准备两首曲目的分析输入，并在输入齐备时计算过渡。 */
bool AudioPlayer::prepareAppleTransition(const QUrl &next, bool offline, bool alternative,
                                         const QString &provider) {
    if (appleTransition || !applePlayer || sourceEnded || appleSource == next ||
        !allowsPlaybackSource(next, offline, alternative, provider)) {
        return false;
    }
    const auto route = AppleAudioPlayer::transitionOutput();
    if (route == AppleAudioPlayer::TransitionOutput::Unsupported) {
        return false;
    }
    appleTransition = std::make_unique<AppleTransition>();
    appleTransition->source = next;
    appleTransition->route = route;
    auto &transition = *appleTransition;
    const bool streaming = !appleSource.isLocalFile() || !next.isLocalFile();
    transition.streaming = streaming;
    transition.routeClock.start();
    const auto durationMs = applePlayer->duration();
    const auto remainingMs = durationMs - applePlayer->position();
    const auto policy = ProviderRegistry::instance().mediaPolicy(provider);
    const auto downloadBudgetMs = int(std::clamp<qint64>(remainingMs - 4900, 500, 14000));
    const auto result = transition.analysis;
    const auto analyze = [outgoing = appleSource, next, result, streaming, durationMs] {
        if (--result->pendingSources != 0 || result->cancelled.load()) {
            return;
        }
        const auto outgoingAnalysis =
            result->outgoingFile ? QUrl::fromLocalFile(*result->outgoingFile) : outgoing;
        const auto incomingAnalysis =
            result->incomingFile ? QUrl::fromLocalFile(*result->incomingFile) : next;
        result->plan = AppleTransitionPlan::analyze(outgoingAnalysis, incomingAnalysis, result->cancelled);
        result->outgoingFile.reset();
        if (std::abs(result->plan.incomingRate - 1.0) > 0.001) {
            result->preparedAudio =
                AppleTransitionAudio::render(incomingAnalysis, result->plan, result->cancelled);
            if (!result->preparedAudio) {
                useUnstretchedFade(result->plan);
                result->tempoFallback = true;
            }
        }
        if (streaming && result->plan.kind == AppleTransitionPlan::Kind::Original) {
            result->incomingFile.reset();
            const auto overlapMs = std::clamp<qint64>(durationMs / 65, 900, 2300);
            result->plan.kind = AppleTransitionPlan::Kind::Fade;
            result->plan.outgoingMs = durationMs - overlapMs;
            result->plan.overlapMs = overlapMs;
        }
        result->ready.store(true);
    };
    const auto copy = [policy, alternative, downloadBudgetMs, result](const QUrl &source) {
        if (source.isLocalFile() || result->cancelled.load()) {
            return std::shared_ptr<const QString>{};
        }
        QNetworkAccessManager network;
        const auto allowsUrl = [&policy, alternative](const QUrl &url) {
            return allowsMediaEndpoint(url, alternative, policy);
        };
        return AppleTransitionMedia::copy(network, source, allowsUrl, downloadBudgetMs, result->cancelled);
    };
    QThreadPool::globalInstance()->start([next, result, copy, analyze] {
        result->incomingFile = copy(next);
        analyze();
    });
    QThreadPool::globalInstance()->start(
        [outgoing = appleSource, cached = appleAnalysisFile, result, copy, analyze] {
            result->outgoingFile = cached ? cached : copy(outgoing);
            analyze();
        });
    return true;
}

void AudioPlayer::cancelAppleTransition() {
    if (!appleTransition) {
        return;
    }
    appleTransition->analysis->cancelled.store(true);
    if (appleTransition->outgoingGain < 1.0f) {
        applePlayer->setVolume(output.volume());
    }
    appleTransition.reset();
    playbackWatchdog.setInterval(100);
}

/** 清除播放器上的预卷和定时起播，保留同一歌对的取址、分析和缓存。 */
void AudioPlayer::resetAppleTransitionSchedule() {
    if (!appleTransition || appleTransition->phase == AppleTransition::Phase::Analyzing) {
        return;
    }
    auto &transition = *appleTransition;
    transition.incoming.reset();
    transition.fadeProgress = 0;
    transition.fadeTailClock.invalidate();
    transition.syncProblemSinceMs = -1;
    if (transition.outgoingGain < 1.0f) {
        applePlayer->setVolume(output.volume());
    }
    transition.outgoingGain = 1.0f;
    transition.incomingGain = 0.0f;
    transition.plan = transition.analysis->plan;
    if (transition.rejectedPreparedAudio) {
        useUnstretchedFade(transition.plan);
    }
    transition.phase = AppleTransition::Phase::Waiting;
}

/** 两个播放器均由同一播放线程控制。B 未确认起播前，A 的会话仍有自然结束权。 */
void AudioPlayer::advanceAppleTransition() {
    using Phase = AppleTransition::Phase;
    using Status = AppleAudioPlayer::Status;
    using Kind = AppleTransitionPlan::Kind;
    if (!appleTransition) {
        return;
    }
    auto &transition = *appleTransition;
    if (applePlayer->status() == Status::Failed) {
        cancelAppleTransition();
        return;
    }
    if (!transition.analysis->ready.load()) {
        return;
    }
    if (transition.phase == Phase::Analyzing) {
        transition.plan = transition.analysis->plan;
        transition.phase = Phase::Waiting;
        diagnose("transition-planned");
        if (transition.analysis->tempoFallback) {
            diagnose("transition-tempo-fallback");
        }
    }
    if (!playbackRequested || applePlayer->isSeeking() || transition.phase == Phase::Unavailable) {
        return;
    }
    if (transition.routeClock.elapsed() >= 250) {
        transition.routeClock.restart();
        const auto route = AppleAudioPlayer::transitionOutput();
        if (route != transition.route) {
            resetAppleTransitionSchedule();
            transition.route = route;
        }
    }
    if (outputUnavailable || transition.route == AppleAudioPlayer::TransitionOutput::Unsupported) {
        return;
    }
    auto &plan = transition.plan;
    const auto position = applePlayer->position();
    if (plan.kind == Kind::Original) {
        return;
    }
    auto leadMs = qRound64(-applePlayer->playbackOffsetFrom(plan.outgoingMs));
    const bool mixing = transition.phase == Phase::Armed || transition.phase == Phase::Recovering;
    if (transition.streaming && plan.kind == Kind::Fade && !mixing && leadMs < 100) {
        // 在线预卷耗时波动时，若仍有足够曲尾就缩短叠播。
        constexpr qint64 scheduleLeadMs = 210;
        constexpr qint64 minimumOverlapMs = 360;
        const auto remainingMs = applePlayer->duration() - position;
        if (remainingMs >= scheduleLeadMs + minimumOverlapMs) {
            plan.outgoingMs = position + scheduleLeadMs;
            plan.overlapMs = remainingMs - scheduleLeadMs;
            leadMs = scheduleLeadMs;
        }
    }
    if (!mixing && (leadMs < 70 || plan.outgoingMs > applePlayer->duration() + 40)) {
        resetAppleTransitionSchedule();
        transition.phase = Phase::Unavailable;
        diagnose("transition-fallback");
        return;
    }
    if (transition.incoming && transition.incoming->status() == Status::Failed &&
        transition.phase != Phase::Recovering) {
        if (!mixing && transition.analysis->preparedAudio && !transition.rejectedPreparedAudio) {
            transition.rejectedPreparedAudio = true;
            resetAppleTransitionSchedule();
            diagnose("transition-tempo-fallback");
            return;
        }
        abandonAppleTransitionMix(applePlayer->status() == Status::Ended);
        return;
    }
    const qint64 preloadLeadMs = transition.streaming ? 14500 : 6500;
    switch (transition.phase) {
    case Phase::Analyzing:
    case Phase::Unavailable:
        return;
    case Phase::Waiting:
        // 解码分析可以尽早完成，第二个 AVPlayer 只在换曲前一小段时间占用资源。
        if (leadMs <= preloadLeadMs) {
            const auto &file = transition.analysis->incomingFile;
            const auto url = file ? QUrl::fromLocalFile(*file) : transition.source;
            transition.incoming = AppleAudioPlayer::open(
                url, transition.rejectedPreparedAudio ? nullptr : transition.analysis->preparedAudio);
            if (!transition.incoming) {
                cancelAppleTransition();
                return;
            }
            transition.incoming->setVolume(0);
            transition.phase = Phase::Loading;
        }
        return;
    case Phase::Loading:
        if (transition.incoming->status() == Status::Ready) {
            const auto incomingDurationMs = transition.incoming->duration();
            if (plan.kind == Kind::Fade && incomingDurationMs > 0 &&
                incomingDurationMs < 4 * plan.overlapMs) {
                plan.overlapMs = std::max<qint64>(250, incomingDurationMs / 4);
                plan.outgoingMs = applePlayer->duration() - plan.overlapMs;
            }
            // 新 AVPlayer 已在开头，避免对 HLS 发出多余跳转。
            if (plan.incomingMs > 0) {
                transition.incoming->seek(plan.incomingMs);
            }
            transition.phase = Phase::Seeking;
        }
        return;
    case Phase::Seeking:
        if (transition.incoming->preroll()) {
            transition.phase = Phase::Prerolling;
        }
        return;
    case Phase::Prerolling:
        if (transition.incoming->isPrerolled()) {
            transition.phase = Phase::Ready;
        }
        return;
    case Phase::Ready:
        if (leadMs > 450 || !applePlayer->isPlaying()) {
            return;
        }
        if (!transition.incoming->synchronizeWith(*applePlayer, plan.outgoingMs, plan.incomingMs)) {
            abandonAppleTransitionMix(false);
            return;
        }
        transition.phase = Phase::Armed;
        transition.armedLeadMs = leadMs;
        transition.armedClock.start();
        diagnose("transition-armed");
        return;
    case Phase::Armed:
    case Phase::Recovering:
        updateAppleTransitionMix();
        return;
    }
}

/** S 曲线在首尾以零斜率衔接，两个音轨共用进度，混合增益之和始终为一。 */
void AudioPlayer::setAppleTransitionMix(double progress) {
    auto &transition = *appleTransition;
    if (transition.fadeProgress == progress) {
        return;
    }
    transition.fadeProgress = progress;
    transition.incomingGain = float(progress * progress * (3 - 2 * progress));
    transition.outgoingGain = 1.0f - transition.incomingGain;
    applePlayer->setVolume(output.volume() * transition.outgoingGain);
    transition.incoming->setVolume(output.volume() * transition.incomingGain);
}

void AudioPlayer::abandonAppleTransitionMix(bool outgoingEnded) {
    auto &transition = *appleTransition;
    diagnose("transition-fallback");
    if (transition.fadeProgress > 0 && !outgoingEnded) {
        transition.fadeTailStart = transition.fadeProgress;
        transition.fadeTailClock.start();
        transition.phase = AppleTransition::Phase::Recovering;
        return;
    }
    resetAppleTransitionSchedule();
    transition.phase = AppleTransition::Phase::Unavailable;
}

/** 以两路实际推进的进度淡化。到达淡化终点后才交接，掉拍时平滑退回当前曲目。 */
void AudioPlayer::updateAppleTransitionMix() {
    using Phase = AppleTransition::Phase;
    constexpr double tailFadeMs = 150;
    auto &transition = *appleTransition;
    const auto &plan = transition.plan;
    if (transition.phase == Phase::Recovering) {
        const double remaining = std::max(0.0, 1.0 - transition.fadeTailClock.elapsed() / tailFadeMs);
        setAppleTransitionMix(transition.fadeTailStart * remaining);
        if (remaining == 0) {
            resetAppleTransitionSchedule();
            transition.phase = Phase::Unavailable;
        }
        return;
    }

    const auto outgoingPosition = applePlayer->position();
    const auto outgoingElapsed = applePlayer->playbackOffsetFrom(plan.outgoingMs);
    const auto incomingElapsed = transition.incoming->playbackOffsetFrom(plan.incomingMs);
    const bool incomingPlaying = transition.incoming->isPlaying() && incomingElapsed >= 12;
    const auto elapsedSinceCue = transition.armedClock.elapsed() - transition.armedLeadMs;
    const bool outgoingEnded =
        applePlayer->status() == AppleAudioPlayer::Status::Ended || isApplePlaybackStoppedAtEnd();
    if (incomingPlaying) {
        const auto elapsedMs = std::min(outgoingElapsed, incomingElapsed);
        auto progress = std::clamp(elapsedMs / std::max<qint64>(1, plan.overlapMs), 0.0, 1.0);
        const auto remainingMs = applePlayer->duration() - outgoingPosition;
        const bool atEnd = outgoingEnded || (remainingMs > 0 && remainingMs <= tailFadeMs);
        if (atEnd && progress < 1 && !transition.fadeTailClock.isValid()) {
            // 旧曲即将到达文件末尾时，用短尾段收完淡化，避免 B 稍迟时 A 带音量被截断。
            transition.fadeTailStart = std::max(progress, transition.fadeProgress);
            transition.fadeTailDurationMs = outgoingEnded ? tailFadeMs : std::max(100.0, double(remainingMs));
            transition.fadeTailClock.start();
        }
        if (transition.fadeTailClock.isValid()) {
            const auto tail =
                std::min(1.0, transition.fadeTailClock.elapsed() / transition.fadeTailDurationMs);
            progress = std::max(progress, std::lerp(transition.fadeTailStart, 1.0, tail));
        }
        setAppleTransitionMix(std::max(progress, transition.fadeProgress));
        if (transition.fadeProgress == 1) {
            diagnose("transition-fade-completed");
            commitAppleTransition();
            return;
        }
        if (outgoingEnded || transition.fadeTailClock.isValid()) {
            return;
        }
    }

    const bool drifting = elapsedSinceCue > 130 && plan.kind == AppleTransitionPlan::Kind::BeatMatch &&
                          incomingPlaying &&
                          std::abs(incomingElapsed - outgoingElapsed) > 110;
    const bool syncProblem = drifting || (!incomingPlaying && transition.fadeProgress > 0);
    if (!syncProblem) {
        transition.syncProblemSinceMs = -1;
    } else if (transition.syncProblemSinceMs < 0) {
        transition.syncProblemSinceMs = elapsedSinceCue;
    }
    const bool lostSync = syncProblem && elapsedSinceCue - transition.syncProblemSinceMs >= 150;
    const qint64 startupAllowanceMs = transition.streaming ? 650 : 250;
    const bool missedStart =
        !incomingPlaying && transition.fadeProgress == 0 && elapsedSinceCue > startupAllowanceMs;
    if (missedStart || lostSync || elapsedSinceCue > plan.overlapMs + startupAllowanceMs) {
        abandonAppleTransitionMix(outgoingEnded);
    }
}

void AudioPlayer::commitAppleTransition() {
    auto &transition = *appleTransition;
    // 交接后仅保留 B。A 的结束观察与旧媒体会话一并销毁，不再触发队列前进。
    applePlayer = std::move(transition.incoming);
    appleAnalysisFile = transition.analysis->incomingFile;
    appleSource = transition.source;
    sourceKind = appleSource.isLocalFile() ? 3 : (appleSource.scheme() == "https" ? 1 : 2);
    applePlayer->completeTransition();
    appleTransition.reset();
    ++sourceSerial;
    sourceEnded = false;
    lastPosition = applePlayer->position();
    progressClock.restart();
    diagnose("transition-committed");
    if (appleTransitionCommitted) {
        appleTransitionCommitted();
    }
    if (playbackChanged) {
        playbackChanged();
    }
}

bool AudioPlayer::isApplePlaybackStoppedAtEnd() const {
    constexpr qint64 endPauseMs = 350;
    return playbackRequested && !outputUnavailable && recoveryPosition < 0 &&
           progressClock.elapsed() >= endPauseMs && applePlayer->position() == lastPosition &&
           applePlayer->isPausedAtEnd();
}

/** 由服务心跳推进 AVPlayer 的加载、跳转、播放和自然结束。 */
void AudioPlayer::checkApplePlayback() {
    using Status = AppleAudioPlayer::Status;
    advanceAppleTransition();
    if (!applePlayer) {
        return;
    }
    if (applePlayer->takeTempoRestored()) {
        diagnose("transition-rate-restored");
    }
    const bool mixing = appleTransition && (appleTransition->phase == AppleTransition::Phase::Armed ||
                                            appleTransition->phase == AppleTransition::Phase::Recovering);
    const int intervalMs = mixing ? 12 : 100;
    if (playbackWatchdog.interval() != intervalMs) {
        playbackWatchdog.setInterval(intervalMs);
    }
    const auto status = applePlayer->status();
    if (status == Status::Failed) {
        failApplePlayback();
        return;
    }
    const bool stoppedAtEnd = isApplePlaybackStoppedAtEnd();
    if (playbackRequested && recoveryPosition < 0 && (status == Status::Ended || stoppedAtEnd)) {
        if (mixing) {
            // A 正好在接拍处到达 EOF 时，给已调度的 B 留出有限的起播确认时间。
            return;
        }
        cancelAppleTransition();
        applePlayer->setPaused(true);
        completePlayback();
        diagnose(status == Status::Ended ? "end-native" : "end-clock");
        return;
    }
    if (outputUnavailable) {
        return;
    }
    if (status == Status::Loading || applePlayer->isSeeking()) {
        if (progressClock.elapsed() >= 10000) {
            failApplePlayback();
        }
        return;
    }
    if (recoveryPosition >= 0) {
        const auto position = std::min(recoveryPosition, applePlayer->duration());
        recoveryPosition = -1;
        if (applePlayer->isSeekable() && position > 0) {
            applePlayer->seek(position);
            lastPosition = position;
            progressClock.restart();
            return;
        }
    }
    const auto position = applePlayer->position();
    if (position != lastPosition) {
        lastPosition = position;
        progressClock.restart();
    }
    if (playbackRequested && progressClock.elapsed() >= 15000) {
        failApplePlayback();
        return;
    }
    applePlayer->setPaused(!playbackRequested);
}

/** 锁存原生播放失败；远端音源交给现有有界恢复流程重新取地址。 */
void AudioPlayer::failApplePlayback() {
    applePlayer->setPaused(true);
    failureRecoverable = !appleSource.isLocalFile();
    error = QStringLiteral("AVPlayer 无法播放此音源，请检查文件格式或重试");
    playbackWatchdog.stop();
    diagnose("error");
    if (playbackChanged) {
        playbackChanged();
    }
}

void AudioPlayer::controlApplePlayback(const QString &action, double value) {
    if (action == "volume") {
        output.setVolume(float(std::clamp(value, 0., 1.)));
        const auto outgoingGain = appleTransition ? appleTransition->outgoingGain : 1.0f;
        applePlayer->setVolume(output.volume() * outgoingGain);
        if (appleTransition && appleTransition->incoming) {
            appleTransition->incoming->setVolume(output.volume() * appleTransition->incomingGain);
        }
    } else if (action == "pause") {
        playbackRequested = false;
        applePlayer->setPaused(true);
        if (appleTransition && (appleTransition->phase == AppleTransition::Phase::Armed ||
                                appleTransition->phase == AppleTransition::Phase::Recovering)) {
            resetAppleTransitionSchedule();
        }
    } else if (action == "resume") {
        playbackRequested = true;
        progressClock.restart();
        if (sourceEnded) {
            sourceEnded = false;
            applePlayer->seek(0);
            lastPosition = 0;
        }
        playbackWatchdog.start();
    } else if (action == "seek" && state()["seekable"].toBool()) {
        resetAppleTransitionSchedule();
        recoveryPosition = -1;
        sourceEnded = false;
        lastPosition = qint64(std::clamp(value, 0., double(applePlayer->duration())));
        applePlayer->seek(lastPosition);
        progressClock.restart();
        playbackWatchdog.start();
    }
}
#endif
