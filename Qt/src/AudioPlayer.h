#pragma once
#include <QAudioDevice>
#include <QAudioBufferOutput>
#include <QAudioOutput>
#include <QByteArray>
#include <QMediaPlayer>
#include <QMediaDevices>
#include <QUrl>
#include <QJsonObject>
#include <QElapsedTimer>
#include <QTimer>
#include <QVariantMap>
#include <functional>
#include <memory>
#include "HttpAudioStream.h"
#include "AudioSpectrum.h"
#include "AudioPcmOutput.h"

#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
class AppleAudioPlayer;
#endif

// 在线模式只接收锁定上游的播放链接；本地模式只接收文件 URL
class AudioPlayer {
  public:
    explicit AudioPlayer(std::function<void()> changed = {});
    ~AudioPlayer();
    bool load(QString input, bool offline, bool alternative = false, QString provider = {},
              double position = 0, bool paused = false);
    void control(QString action, double value = 0);
    QVariantMap state() const;
    QJsonObject diagnosticState() const;
    void enableDiagnostics(bool enabled);
    void enableSpectrum(bool enabled);
    void setOutputPolicy(AudioOutputFormat::Policy policy);
    std::function<void(QJsonArray)> spectrumChanged;
    std::function<void(const QString &, const QJsonObject &)> diagnosticEvent;

  private:
    friend class AudioPlayerRegression;
    class OutputFormatProbe;
    QMediaDevices devices;
    QAudioOutput output;
    AudioPcmOutput pcm;
    AudioOutputFormat::Policy outputPolicy = AudioOutputFormat::Policy::System;
    bool pcmEnabled = true; // 解码器直通回归开关；非 FFmpeg 后端也回退到原生 QAudioOutput。
    bool decoderThrottled = false;
    bool decoderEnded = false;
    QAudioFormat devicePreferred;
    void completePlayback();
    qint64 playbackPosition() const;
    std::unique_ptr<QMediaPlayer> player;
    std::unique_ptr<QAudioBufferOutput> decodedOutput;
    std::unique_ptr<HttpAudioStream> stream;
    void startMediaSource(const QUrl &url);
    void releasePlayer();
    bool diagnosticsEnabled = false;
    QMetaObject::Connection decoderConnection;
    quint64 decoderObservation = 0;
    void observeDecodedBuffers();
    void clearSpectrum();
    AudioSpectrum spectrum;
    bool spectrumEnabled = false;
    QElapsedTimer spectrumClock;
    int sourceSerial = 0;
    int sourceKind = 0;
    int sourceProvider = 0;
    int backendFailureCategory = 0;
    int reportedHttpStatus = 0;
    qint64 decodedBuffers = 0;
    qint64 decodedBytes = 0;
    qint64 decodedFrames = 0;
    qint64 lastDecodedElapsedMs = -1;
    qint64 lastDecodedEndMs = -1;
    QAudioFormat decodedFormat;
    QElapsedTimer decodeClock;
    void diagnose(const QString &event);
    void diagnoseError(QMediaPlayer::Error code, const QString &message);
    std::function<void()> playbackChanged;
    std::function<QAudioDevice()> defaultOutput = QMediaDevices::defaultAudioOutput;
    // 探测函数的注入点：工作线程拿到的是副本，只接收设备 id 与默认标记。
    std::function<AudioOutputFormat::SystemFormat(const QByteArray &, bool)> readSystemOutputFormat =
        [](const QByteArray &deviceId, bool isDefault) {
            return AudioOutputFormat::systemFormat(deviceId, isDefault);
        };
    bool playbackRequested = false;
    bool outputUnavailable = false;
    qint64 lastPosition = 0;
    qint64 recoveryPosition = -1;
    QUrl pendingSource;
    int ended = 0;
    QString error;
    static void normalizeOutputLayout(const QAudioDevice &device);
    void restorePlaybackPosition();
    void createPlayer();
    void followDefaultOutput(bool refresh = false,
                             const AudioOutputFormat::SystemFormat *observedSystem = nullptr);
    void requestOutputFormatProbe();
    bool applyPendingOutputFormatObservation();
    QTimer playbackWatchdog;
    std::unique_ptr<OutputFormatProbe> outputFormatProbe;
    QElapsedTimer progressClock;
    QElapsedTimer outputFormatClock;
    bool pendingFailure = false;
    bool failureRecoverable = false;
    bool sourceEnded = false;
    void checkPlaybackHealth();
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    bool useApplePlayback = true; // Qt 输出回归使用独立的测试路径。
    QUrl appleSource;
    std::unique_ptr<AppleAudioPlayer> applePlayer;
    AudioOutputFormat::SystemFormat appleSystemFormat;
    void closeApplePlayback();
    bool startApplePlayback(const QUrl &source, bool paused);
    void checkApplePlayback();
    void failApplePlayback();
    void controlApplePlayback(const QString &action, double value);
#endif
};
