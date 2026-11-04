#include "AudioSpectrum.h"
#include <QCoreApplication>
#include <QDebug>
#include <algorithm>
#include <cmath>
#include <numbers>

QAudioBuffer tone(double frequency, bool opposite = false, int frames = AudioSpectrum::Size,
                  int rate = 48000) {
    QAudioFormat format;
    format.setSampleRate(rate);
    format.setChannelCount(2);
    format.setSampleFormat(QAudioFormat::Float);
    QByteArray bytes(frames * 2 * sizeof(float), Qt::Uninitialized);
    auto samples = reinterpret_cast<float *>(bytes.data());
    for (int i = 0; i < frames; ++i) {
        const float value = frequency > 0 ? .5f * std::sin(2 * std::numbers::pi * frequency * i / rate) : 0;
        samples[i * 2] = value;
        samples[i * 2 + 1] = opposite ? -value : value;
    }
    return QAudioBuffer(bytes, format);
}

int main(int argc, char **argv) {
    QCoreApplication application(argc, argv);
    bool passed = true;
    const auto check = [&](bool ok, const char *message) {
        if (!ok) {
            qCritical() << message;
            passed = false;
        }
    };
    auto peak = [](const QJsonArray &levels) {
        int index = 0;
        for (int i = 1; i < levels.size(); ++i) {
            if (levels[i].toDouble() > levels[index].toDouble()) {
                index = i;
            }
        }
        return index;
    };
    AudioSpectrum spectrum;
    check(spectrum.consume(tone(1000)), "full PCM window produces measured spectrum");
    const auto original = spectrum.levels();
    const int expected = int(std::log(1000. / 35) / std::log(16000. / 35) * AudioSpectrum::Bands);
    check(std::abs(peak(original) - expected) <= 1 && original[peak(original)].toDouble() > .5,
          "tone peaks in its logarithmic frequency band");
    spectrum.reset();
    spectrum.consume(tone(1000, true));
    check(spectrum.levels() == original, "opposite-phase stereo never cancels the spectrum");
    spectrum.consume(tone(6000));
    check(peak(spectrum.levels()) > peak(original) + 5, "higher tones move energy into higher bands");
    spectrum.consume(tone(0));
    for (auto value : spectrum.levels()) {
        check(value.toDouble() == 0, "silence has no artificial wave");
    }
    spectrum.reset();
    check(!spectrum.consume(tone(1000, false, 1024)), "partial window waits for enough samples");
    check(spectrum.consume(tone(1000, false, 1024)), "successive PCM buffers complete one FFT window");
    check(!spectrum.consume(tone(1000, false, 1024, 44100)),
          "sample rate changes discard the previous partial window");
    for (auto value : spectrum.levels()) {
        check(std::isfinite(value.toDouble()) && value.toDouble() >= 0 && value.toDouble() <= 1,
              "wire levels are finite and bounded");
    }
    check(!spectrum.consume(QAudioBuffer()), "invalid buffers are ignored");
    return passed ? 0 : 1;
}
