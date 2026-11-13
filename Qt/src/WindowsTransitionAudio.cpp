#include "AppleTransitionAudio.h"
#include "AppleTransitionPlan.h"
#include "AudioTransitionTempo.h"
#include "TransitionPcm.h"

#include <QDataStream>
#include <QDir>
#include <QFile>
#include <QTemporaryFile>

struct AppleTransitionAudio::Data {
    QString renderedPath;
    AudioTransitionTempo::TempoCurve curve;
    double cueMs = 0, sourceEndMs = 0, playbackEndMs = 0;
};

AppleTransitionAudio::AppleTransitionAudio() : data(std::make_unique<Data>()) {
}
AppleTransitionAudio::~AppleTransitionAudio() {
    QFile::remove(data->renderedPath);
}

std::shared_ptr<const AppleTransitionAudio> AppleTransitionAudio::render(const QUrl &source,
                                                                         const AppleTransitionPlan &plan,
                                                                         const std::atomic_bool &cancelled) {
    using TransitionPcm::Action;
    if (!source.isLocalFile() || cancelled.load() || !std::isfinite(plan.incomingRate) ||
        plan.incomingRate < 0.80 || plan.incomingRate > 1.20 || plan.overlapMs <= 0 ||
        plan.overlapMs > AppleTransitionPlan::searchWindowMs || plan.incomingMs < 0) {
        return {};
    }
    auto input = TransitionPcm::read(source, plan.incomingMs, plan.overlapMs * 1.2 + 2000, false, cancelled);
    if (!input.valid()) {
        return {};
    }
    const auto availableMs = input.durationMs - input.offsetMs;
    const auto ramp = std::min(1800.0, (availableMs - plan.overlapMs * plan.incomingRate - 100) /
                                           ((plan.incomingRate + 1) / 2));
    if (ramp < 500) {
        return {};
    }
    const AudioTransitionTempo::TempoCurve curve{plan.incomingRate, double(plan.overlapMs), ramp};
    const auto frameAt = [&](double ms) { return qRound64(ms * input.sampleRate / 1000); };
    const auto outputFrames = frameAt(curve.overlap + curve.ramp);
    const auto sourceFrames = frameAt(curve.sourceOffset(curve.overlap + curve.ramp));
    const auto inputFrames = qint64(input.planes.front().size());
    if (sourceFrames > inputFrames || (inputFrames + outputFrames) * input.channels > 12 * 1024 * 1024) {
        return {};
    }
    std::vector<std::vector<float>> output(size_t(input.channels), std::vector<float>(size_t(outputFrames)));
    std::vector<const float *> in;
    std::vector<float *> out;
    for (int channel = 0; channel < input.channels; ++channel) {
        in.push_back(input.planes[size_t(channel)].data());
        out.push_back(output[size_t(channel)].data());
    }
    if (!AudioTransitionTempo::stretch(in.data(), out.data(), int(inputFrames), int(outputFrames),
                                       input.channels, input.sampleRate, curve, int(sourceFrames),
                                       cancelled)) {
        return {};
    }

    QTemporaryFile file(QDir::tempPath() + "/rhine-tempo-XXXXXX.wav");
    if (!file.open()) {
        return {};
    }
    QDataStream header(&file);
    header.setByteOrder(QDataStream::LittleEndian);
    header.writeRawData("RIFF", 4);
    header << quint32(0);
    header.writeRawData("WAVEfmt ", 8);
    header << quint32(16) << quint16(3) << quint16(input.channels) << quint32(input.sampleRate)
           << quint32(input.sampleRate * input.channels * sizeof(float))
           << quint16(input.channels * sizeof(float)) << quint16(32);
    header.writeRawData("data", 4);
    header << quint32(0);
    const auto cue = frameAt(input.offsetMs);
    const auto end = cue + sourceFrames;
    bool inserted = false;
    qint64 position = 0;
    std::vector<float> samples;
    const auto writeFrames = [&](const float *pcm, qint64 frames) {
        const auto bytes = frames * input.channels * qint64(sizeof(float));
        return file.size() + bytes <= 512LL * 1024 * 1024 &&
               file.write(reinterpret_cast<const char *>(pcm), bytes) == bytes;
    };
    const auto success = TransitionPcm::decode(source, cancelled, [&](const QAudioBuffer &buffer, qint64) {
        if (buffer.format().sampleRate() != input.sampleRate ||
            buffer.format().channelCount() != input.channels || !TransitionPcm::floats(buffer, samples)) {
            return Action::Fail;
        }
        const auto frames = buffer.frameCount();
        const auto before = std::clamp<qint64>(cue - position, 0, frames);
        if (before > 0 && !writeFrames(samples.data(), before)) {
            return Action::Fail;
        }
        if (!inserted && position + frames >= cue) {
            std::vector<float> interleaved(size_t(outputFrames * input.channels));
            for (qint64 frame = 0; frame < outputFrames; ++frame) {
                for (int channel = 0; channel < input.channels; ++channel) {
                    interleaved[size_t(frame * input.channels + channel)] =
                        output[size_t(channel)][size_t(frame)];
                }
            }
            if (!writeFrames(interleaved.data(), outputFrames)) {
                return Action::Fail;
            }
            inserted = true;
        }
        const auto after = std::clamp<qint64>(end - position, 0, frames);
        if (after < frames && !writeFrames(samples.data() + after * input.channels, frames - after)) {
            return Action::Fail;
        }
        position += frames;
        return Action::Continue;
    });
    if (!success || !inserted || position < end || header.status() != QDataStream::Ok) {
        return {};
    }
    const auto bytes = quint32(file.size() - 44);
    if (!file.seek(4)) {
        return {};
    }
    header << quint32(bytes + 36);
    if (!file.seek(40)) {
        return {};
    }
    header << bytes;
    if (header.status() != QDataStream::Ok || !file.flush()) {
        return {};
    }
    auto prepared = std::shared_ptr<AppleTransitionAudio>(new AppleTransitionAudio);
    prepared->data->curve = curve;
    prepared->data->cueMs = double(cue) * 1000 / input.sampleRate;
    prepared->data->sourceEndMs = double(end) * 1000 / input.sampleRate;
    prepared->data->playbackEndMs = double(cue + outputFrames) * 1000 / input.sampleRate;
    prepared->data->renderedPath = file.fileName();
    file.setAutoRemove(false);
    return prepared;
}

QUrl AppleTransitionAudio::playbackSource() const {
    return QUrl::fromLocalFile(data->renderedPath);
}
double AppleTransitionAudio::sourceMs(double playbackMs) const {
    if (playbackMs <= data->cueMs) {
        return playbackMs;
    }
    if (playbackMs >= data->playbackEndMs) {
        return data->sourceEndMs + playbackMs - data->playbackEndMs;
    }
    return data->cueMs + data->curve.sourceOffset(playbackMs - data->cueMs);
}
double AppleTransitionAudio::playbackMs(double sourceMs) const {
    if (sourceMs <= data->cueMs) {
        return sourceMs;
    }
    if (sourceMs >= data->sourceEndMs) {
        return data->playbackEndMs + sourceMs - data->sourceEndMs;
    }
    double low = data->cueMs, high = data->playbackEndMs;
    for (int index = 0; index < 18; ++index) {
        const auto middle = (low + high) / 2;
        if (this->sourceMs(middle) < sourceMs) {
            low = middle;
        } else {
            high = middle;
        }
    }
    return (low + high) / 2;
}
double AppleTransitionAudio::tempo(double playbackMs) const {
    return playbackMs < data->cueMs || playbackMs >= data->playbackEndMs
               ? 1
               : data->curve.tempo(playbackMs - data->cueMs);
}
double AppleTransitionAudio::rampProgress(double playbackMs) const {
    return data->curve.progress(playbackMs - data->cueMs);
}
double AppleTransitionAudio::restoredAtMs() const {
    return data->sourceEndMs;
}
