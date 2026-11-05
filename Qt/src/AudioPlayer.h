#pragma once
#include <QAudioDevice>
#include <QAudioBufferOutput>
#include <QAudioOutput>
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

// 在线模式只接收锁定上游的播放链接；本地模式只接收文件 URL
class AudioPlayer {
  public:
    explicit AudioPlayer(std::function<void()> changed = {});
    ~AudioPlayer();
    bool load(QString input, bool offline, bool alternative = false, QString provider = "netease",
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
    void followDefaultOutput(bool refresh = false);
    void refreshOutputFormat();
    QTimer playbackWatchdog;
    QElapsedTimer progressClock;
    QElapsedTimer outputFormatClock;
    bool pendingFailure = false;
    bool failureRecoverable = false;
    bool sourceEnded = false;
    void checkPlaybackHealth();
};
