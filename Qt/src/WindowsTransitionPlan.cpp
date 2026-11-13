#include "AudioTransitionAnalysis.h"
#include "TransitionPcm.h"

namespace {
AudioWindow readWindow(const QUrl &source, bool tail, const std::atomic_bool &cancelled) {
    std::unique_ptr<WindowAnalyzer> analyzer;
    std::vector<float> samples;
    qint64 position = 0;
    const auto success =
        TransitionPcm::decode(source, cancelled, [&](const QAudioBuffer &buffer, qint64 duration) {
            if (duration < 8000 || duration > 24LL * 3600 * 1000) {
                return TransitionPcm::Action::Fail;
            }
            const auto format = buffer.format();
            const auto rate = format.sampleRate();
            const auto channels = format.channelCount();
            if (rate < 8000 || rate > 192000 || channels < 1 || channels > maximumAnalysisChannels) {
                return TransitionPcm::Action::Fail;
            }
            const auto first =
                tail ? qRound64(std::max<qint64>(0, duration - AppleTransitionPlan::searchWindowMs) * rate /
                                1000.0)
                     : 0;
            const auto last = first + qRound64(AppleTransitionPlan::searchWindowMs * rate / 1000.0);
            const auto at =
                buffer.startTime() >= 0 ? qRound64(buffer.startTime() * rate / 1000000.0) : position;
            position = at + buffer.frameCount();
            const auto begin = std::clamp<qint64>(first - at, 0, buffer.frameCount());
            const auto end = std::clamp<qint64>(last - at, begin, buffer.frameCount());
            if (end > begin) {
                if (!analyzer) {
                    analyzer = std::make_unique<WindowAnalyzer>(duration);
                }
                if (!TransitionPcm::floats(buffer, samples) ||
                    !analyzer->append(samples.data() + begin * channels, (end - begin) * channels, rate,
                                      channels, double(at + begin) * 1000 / rate)) {
                    return TransitionPcm::Action::Fail;
                }
            }
            return position >= last ? TransitionPcm::Action::Complete : TransitionPcm::Action::Continue;
        });
    return success && analyzer ? analyzer->finish() : AudioWindow{};
}
}

AppleTransitionPlan AppleTransitionPlan::analyze(const QUrl &outgoing, const QUrl &incoming,
                                                 const std::atomic_bool &cancelled) {
    return analyzeTransitionFiles(outgoing, incoming, cancelled);
}
