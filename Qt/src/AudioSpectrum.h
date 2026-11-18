#pragma once
#include <QAudioBuffer>
#include <QJsonArray>
#include <array>

// Small, bounded FFT over the music decoder's PCM; no microphone or system audio capture.
class AudioSpectrum {
  public:
    static constexpr int Size = 2048;
    static constexpr int Bands = 40;
    void reset();
    bool consume(const QAudioBuffer &buffer);
    QJsonArray levels() const;

  private:
    void transform();
    std::array<std::array<double, Size>, 2> m_samples{};
    std::array<double, Bands> m_levels{};
    int m_count = 0, m_rate = 0, m_channels = 0;
};
