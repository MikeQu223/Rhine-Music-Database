#pragma once
#include <QAudioDevice>
#include <QAudioFormat>
#include <functional>

namespace AudioOutputFormat {
enum class Policy { System, Source };
struct SystemFormat {
    QAudioFormat format;
    // 0 = unavailable; 1 = current system stream/mix; 2 = rate/channels only.
    int status = 0;
};
SystemFormat systemFormat(const QAudioDevice &device);
QAudioFormat select(const QAudioFormat &source, const QAudioFormat &system, const QAudioFormat &preferred,
                    Policy policy, const std::function<bool(const QAudioFormat &)> &supported);
QString describe(int rate, int channels, int sampleFormat);
} // namespace AudioOutputFormat
