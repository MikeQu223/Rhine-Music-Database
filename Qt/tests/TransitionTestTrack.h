#pragma once
#include <QDataStream>
#include <QFile>
#include <array>
#include <cmath>
#include <numbers>

namespace TransitionTestTrack {
inline bool writePulseTrack(const QString &path, int bpm, int chordRoot = -1, bool accentBars = true,
                            double startSeconds = 0.12, double endSeconds = 32.3) {
    constexpr int sampleRate = 16000;
    constexpr int sampleCount = 323 * sampleRate / 10;
    constexpr int channels = 2;
    constexpr quint32 dataBytes = sampleCount * channels * sizeof(qint16);
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }
    QDataStream stream(&file);
    stream.setByteOrder(QDataStream::LittleEndian);
    stream.writeRawData("RIFF", 4);
    stream << quint32(36 + dataBytes);
    stream.writeRawData("WAVEfmt ", 8);
    stream << quint32(16) << quint16(1) << quint16(channels) << quint32(sampleRate)
           << quint32(sampleRate * channels * sizeof(qint16)) << quint16(channels * sizeof(qint16))
           << quint16(16);
    stream.writeRawData("data", 4);
    stream << dataBytes;
    constexpr std::array majorChord{0, 4, 7};
    std::array<double, majorChord.size()> chordFrequencies{};
    for (size_t index = 0; index < majorChord.size(); ++index) {
        chordFrequencies[index] = 130.813 * std::exp2((chordRoot + majorChord[index]) / 12.0);
    }
    for (int frame = 0; frame < sampleCount; ++frame) {
        const double time = double(frame) / sampleRate - startSeconds;
        const double beats = time * bpm / 60.0;
        const auto beat = int(std::floor(beats));
        const double sinceBeat = (beats - beat) * 60.0 / bpm;
        double sample = 0;
        if (time >= 0 && time < endSeconds && sinceBeat < 0.055) {
            const bool accented = accentBars && beat % 4 == 0;
            const auto amplitude = accented ? 22000.0 : 4500.0;
            sample = amplitude * std::sin(sinceBeat * 2 * std::numbers::pi * 135) * std::exp(-sinceBeat * 60);
        }
        if (chordRoot >= 0) {
            for (const auto frequency : chordFrequencies) {
                sample += 600 * std::sin(time * 2 * std::numbers::pi * frequency);
            }
        }
        stream << qint16(sample) << qint16(sample);
    }
    return stream.status() == QDataStream::Ok;
}

}
