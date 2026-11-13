#pragma once

#include <QAudioBuffer>
#include <QUrl>
#include <atomic>
#include <functional>
#include <vector>

namespace TransitionPcm {
enum class Action { Continue, Complete, Fail };
using Consume = std::function<Action(const QAudioBuffer &, qint64 durationMs)>;

// Local inputs only. The caller owns the event loop thread and cancellation token.
bool decode(const QUrl &source, const std::atomic_bool &cancelled, const Consume &consume);
bool floats(const QAudioBuffer &buffer, std::vector<float> &samples);

struct Window {
    int sampleRate = 0;
    int channels = 0;
    qint64 durationMs = 0;
    double offsetMs = 0;
    std::vector<std::vector<float>> planes;
    bool valid() const {
        return sampleRate > 0 && !planes.empty() && !planes.front().empty();
    }
};
Window read(const QUrl &source, double firstMs, double lengthMs, bool tail,
            const std::atomic_bool &cancelled);
}
