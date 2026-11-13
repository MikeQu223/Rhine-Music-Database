#include "../src/AppleTransitionAudio.h"
#include "../src/AppleTransitionPlan.h"
#include "../src/TransitionPcm.h"
#include <QDataStream>
#include <QDebug>
#include <QFile>
#include <cmath>
#include <numbers>

namespace {
constexpr int rate = 16000, sourceFrames = rate * 9;
constexpr double frequency = 440, amplitude = 0.35;
bool writeTone(const QUrl &url) {
    QFile file(url.toLocalFile());
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }
    QDataStream stream(&file);
    stream.setByteOrder(QDataStream::LittleEndian);
    stream.writeRawData("RIFF", 4);
    stream << quint32(36 + sourceFrames * 8);
    stream.writeRawData("WAVEfmt ", 8);
    stream << quint32(16) << quint16(3) << quint16(2) << quint32(rate) << quint32(rate * 8) << quint16(8)
           << quint16(32);
    stream.writeRawData("data", 4);
    stream << quint32(sourceFrames * 8);
    std::vector<float> samples(sourceFrames * 2);
    for (int frame = 0; frame < sourceFrames; ++frame) {
        samples[size_t(frame * 2)] =
            float(amplitude * std::sin(2 * std::numbers::pi * frequency * frame / rate));
        samples[size_t(frame * 2 + 1)] = -samples[size_t(frame * 2)];
    }
    return file.write(reinterpret_cast<const char *>(samples.data()),
                      qint64(samples.size() * sizeof(float))) == qint64(samples.size() * sizeof(float));
}
bool checkSamples(const AppleTransitionAudio &audio) {
    const std::atomic_bool cancelled = false;
    int frames = 0, crossings = 0;
    float previous = 0;
    double energy = 0, minimumRms = 1, largestJump = 0, pitchError = 0, tailError = 0, channelError = 0;
    std::vector<float> samples;
    const auto success =
        TransitionPcm::decode(audio.playbackSource(), cancelled, [&](const QAudioBuffer &buffer, qint64) {
            if (buffer.format().sampleRate() != rate || buffer.format().channelCount() != 2 ||
                !TransitionPcm::floats(buffer, samples) ||
                std::abs(buffer.startTime() * rate / 1000000.0 - frames) > 1) {
                return TransitionPcm::Action::Fail;
            }
            for (int i = 0; i < buffer.frameCount(); ++i) {
                const auto sample = samples[size_t(i * 2)];
                channelError = std::max(channelError, double(std::abs(sample + samples[size_t(i * 2 + 1)])));
                if (frames > 0) {
                    largestJump = std::max(largestJump, double(std::abs(sample - previous)));
                    crossings += previous <= 0 && sample > 0;
                }
                previous = sample;
                const auto sourceMs = audio.sourceMs(double(frames) * 1000 / rate);
                if (sourceMs > 6500) {
                    const auto sourceFrame = qRound64(sourceMs * rate / 1000);
                    tailError = std::max(
                        tailError,
                        std::abs(amplitude * std::sin(2 * std::numbers::pi * frequency * sourceFrame / rate) -
                                 sample));
                }
                ++frames;
                energy += double(sample) * sample;
                if (frames % (rate / 100) == 0) {
                    minimumRms = std::min(minimumRms, std::sqrt(energy / (rate / 100)));
                    energy = 0;
                }
                if (frames % (rate / 4) == 0) {
                    pitchError = std::max(pitchError, std::abs(4.0 * crossings - frequency));
                    crossings = 0;
                }
            }
            return TransitionPcm::Action::Continue;
        });
    qInfo("Windows PCM frames=%d rms=%.3f jump=%.3f pitch_error=%.1f tail_error=%.5f", frames, minimumRms,
          largestJump, pitchError, tailError);
    return success && std::abs(audio.sourceMs(double(frames) * 1000 / rate) - 9000) < 0.2 &&
           minimumRms > 0.1 && largestJump < 0.09 && pitchError <= 8 && tailError < 0.0001 &&
           channelError < 0.000001;
}
}

bool checkAppleTransitionAudio(const QUrl &url) {
    if (!writeTone(url)) {
        return false;
    }
    const std::atomic_bool cancelled = false;
    for (double speed : {1.153, 0.858}) {
        const AppleTransitionPlan plan{AppleTransitionPlan::Kind::BeatMatch, 0, 960, 2329, speed};
        const auto audio = AppleTransitionAudio::render(url, plan, cancelled);
        if (!audio || std::abs(audio->tempo(1000) - speed) > 0.001 ||
            std::abs(audio->tempo(4190) - (1 + speed) / 2) > 0.001 ||
            std::abs(audio->sourceMs(audio->playbackMs(3800)) - 3800) > 0.1 || !checkSamples(*audio)) {
            return false;
        }
    }
    const std::atomic_bool stopped = true;
    return !AppleTransitionAudio::render(url, {}, stopped) &&
           !TransitionPcm::read(url, 0, 1000, false, stopped).valid();
}
