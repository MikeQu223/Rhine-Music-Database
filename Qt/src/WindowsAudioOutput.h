#pragma once
#include <QtGlobal>
#ifdef Q_OS_WIN
#include <QAudioBuffer>
#include <QAudioFormat>
#include <QByteArray>
#include <atomic>
#include <memory>

// WASAPI objects belong to a dedicated MMCSS thread. Decoder callbacks only
// copy PCM into a bounded queue; GUI rendering never services the device.
class WindowsAudioOutput {
  public:
    WindowsAudioOutput();
    ~WindowsAudioOutput();
    bool open(const QByteArray &deviceId, bool exclusive, const QAudioFormat &requested = {});
    QAudioFormat format() const;
    void enqueue(const QAudioBuffer &buffer);
    void reset(bool paused = false);
    void setPaused(bool paused);
    void finish();
    bool drained() const;
    void setVolume(float volume);
    long error() const;
    quint64 consumedFrames() const;
    qint64 processedUSecs() const;
    int underrunCount() const;
    qsizetype queuedBytes() const;
    qsizetype bytesFree() const;

  private:
    struct State;
    std::unique_ptr<State> state;
};
#endif
