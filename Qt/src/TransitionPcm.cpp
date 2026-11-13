#include "TransitionPcm.h"

#include <QAudioDecoder>
#include <QEventLoop>
#include <QFileInfo>
#include <QTimer>
#include <algorithm>
#include <cmath>

namespace TransitionPcm {
bool decode(const QUrl &source, const std::atomic_bool &cancelled, const Consume &consume) {
    if (!source.isLocalFile() || !QFileInfo(source.toLocalFile()).isFile() || cancelled.load()) {
        return false;
    }
    QEventLoop loop;
    QAudioDecoder decoder;
    QTimer deadline, cancellation;
    bool done = false, success = false;
    const auto finish = [&](bool result) {
        if (!done) {
            done = true;
            success = result;
            loop.quit();
        }
    };
    QObject::connect(&decoder, &QAudioDecoder::bufferReady, &decoder, [&] {
        if (done || cancelled.load()) {
            finish(false);
            return;
        }
        const auto buffer = decoder.read();
        if (!buffer.isValid()) {
            finish(false);
            return;
        }
        const auto action = consume(buffer, decoder.duration());
        if (action != Action::Continue) {
            finish(action == Action::Complete);
        }
    });
    QObject::connect(&decoder, &QAudioDecoder::finished, &decoder, [&] { finish(true); });
    QObject::connect(&decoder, QOverload<QAudioDecoder::Error>::of(&QAudioDecoder::error), &decoder,
                     [&](QAudioDecoder::Error) { finish(false); });
    deadline.setSingleShot(true);
    QObject::connect(&deadline, &QTimer::timeout, &decoder, [&] { finish(false); });
    QObject::connect(&cancellation, &QTimer::timeout, &decoder, [&] {
        if (cancelled.load()) {
            finish(false);
        }
    });
    deadline.start(15000);
    cancellation.start(10);
    decoder.setSource(source);
    decoder.start();
    if (!done) {
        loop.exec();
    }
    decoder.stop();
    return success && !cancelled.load();
}

bool floats(const QAudioBuffer &buffer, std::vector<float> &samples) {
    const auto format = buffer.format();
    if (format.sampleRate() < 8000 || format.sampleRate() > 192000 || format.channelCount() < 1 ||
        format.channelCount() > 8 || buffer.sampleCount() <= 0 || buffer.sampleCount() > 4 * 1024 * 1024) {
        return false;
    }
    samples.resize(size_t(buffer.sampleCount()));
    for (size_t i = 0; i < samples.size(); ++i) {
        switch (format.sampleFormat()) {
        case QAudioFormat::UInt8:
            samples[i] = (int(buffer.constData<quint8>()[i]) - 128) / 128.f;
            break;
        case QAudioFormat::Int16:
            samples[i] = buffer.constData<qint16>()[i] / 32768.f;
            break;
        case QAudioFormat::Int32:
            samples[i] = float(buffer.constData<qint32>()[i] / 2147483648.0);
            break;
        case QAudioFormat::Float:
            samples[i] = buffer.constData<float>()[i];
            break;
        default:
            return false;
        }
        if (!std::isfinite(samples[i])) {
            return false;
        }
    }
    return true;
}

Window read(const QUrl &source, double firstMs, double lengthMs, bool tail,
            const std::atomic_bool &cancelled) {
    constexpr qint64 maximumValues = 12 * 1024 * 1024;
    Window result;
    qint64 position = 0, kept = 0;
    std::vector<float> samples;
    const bool success = decode(source, cancelled, [&](const QAudioBuffer &buffer, qint64 durationMs) {
        const auto format = buffer.format();
        if (!floats(buffer, samples) || durationMs <= 0 || durationMs > 24LL * 3600 * 1000) {
            return Action::Fail;
        }
        if (result.sampleRate == 0) {
            result.sampleRate = format.sampleRate();
            result.channels = format.channelCount();
            result.durationMs = durationMs;
            result.planes.resize(size_t(result.channels));
        } else if (result.sampleRate != format.sampleRate() || result.channels != format.channelCount()) {
            return Action::Fail;
        }
        const auto startMs = tail ? std::max(0.0, double(durationMs) - lengthMs) : firstMs;
        const auto first = qRound64(startMs * result.sampleRate / 1000);
        const auto last = first + qRound64(lengthMs * result.sampleRate / 1000);
        const auto at =
            buffer.startTime() >= 0 ? qRound64(buffer.startTime() * result.sampleRate / 1000000.0) : position;
        position = at + buffer.frameCount();
        const auto begin = std::clamp<qint64>(first - at, 0, buffer.frameCount());
        const auto end = std::clamp<qint64>(last - at, begin, buffer.frameCount());
        if ((kept + end - begin) * result.channels > maximumValues) {
            return Action::Fail;
        }
        if (end > begin && kept == 0) {
            result.offsetMs = double(at + begin) * 1000 / result.sampleRate;
        }
        for (qint64 frame = begin; frame < end; ++frame) {
            for (int channel = 0; channel < result.channels; ++channel) {
                result.planes[size_t(channel)].push_back(samples[size_t(frame * result.channels + channel)]);
            }
        }
        kept += end - begin;
        return position >= last ? Action::Complete : Action::Continue;
    });
    return success && result.valid() ? result : Window{};
}
}
