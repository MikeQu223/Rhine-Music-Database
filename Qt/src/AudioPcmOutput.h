#pragma once
#include "AudioOutputFormat.h"
#include "AudioResampler.h"
#include <QAudioSink>
#include <QElapsedTimer>
#include <QJsonObject>
#include <QTimer>
#include <functional>
#include <memory>

// Control-thread-owned output queue. QAudioSink owns the platform render thread;
// decoded buffers and control actions are serialized on the player's thread.
class AudioPcmOutput {
  public:
    AudioPcmOutput();
    ~AudioPcmOutput();
    void reset(const QAudioDevice &device, AudioOutputFormat::Policy policy, qint64 positionMs = 0);
    bool push(const QAudioBuffer &buffer);
    void finish();
    void pause(bool paused);
    void setVolume(float volume);
    qint64 position() const;
    QJsonObject snapshot() const;
    bool active() const {
        return bool(sink);
    }
    bool complete() const {
        return drained;
    }
    bool failed() const {
        return failure != 0;
    }
    std::function<void(bool)> backpressure;
    std::function<void()> completed;
    std::function<void()> errorOccurred;

  private:
    bool open(const QAudioFormat &source);
    void pump();
    void fail(int code);
    void updatePressure();
    QAudioDevice device;
    AudioOutputFormat::Policy policy = AudioOutputFormat::Policy::System;
    AudioOutputFormat::SystemFormat system;
    QAudioFormat input, submitted;
    std::unique_ptr<AudioResampler> resampler;
    std::unique_ptr<QAudioSink> sink;
    QIODevice *writer = nullptr;
    QTimer timer;
    QElapsedTimer consumptionClock;
    qint64 consumedUs = 0;
    QByteArray pending;
    qsizetype offset = 0;
    qint64 writtenBytes = 0, baseMs = 0, minimumMs = 0;
    qint64 conversionNs = 0, conversionMaxNs = 0, conversionCalls = 0;
    int failure = 0, underruns = 0, rebuilds = 0;
    quint64 generation = 0;
    float volume = .7f;
    bool paused = true, ending = false, drained = false, pressured = false, heard = false;
};
