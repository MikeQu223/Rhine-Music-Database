#pragma once
#include <QAudioBuffer>
#include <memory>

// Uses the public, opaque libswresample/AVOption ABI shipped with Qt. No private
// FFmpeg structures or Qt plugin implementation symbols cross this boundary.
class AudioResampler {
  public:
    AudioResampler();
    ~AudioResampler();
    bool configure(const QAudioFormat &input, const QAudioFormat &output);
    bool convert(const QAudioBuffer &input, QByteArray &output);
    bool finish(QByteArray &output);
    bool bypass() const;
    bool dithering() const;
    static bool available();

  private:
    struct Impl;
    std::unique_ptr<Impl> d;
};
