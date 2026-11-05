#include "AudioPcmOutput.h"
#include <algorithm>

AudioPcmOutput::AudioPcmOutput() {
    timer.setInterval(5);
    timer.setTimerType(Qt::PreciseTimer);
    QObject::connect(&timer, &QTimer::timeout, &timer, [this] { pump(); });
}
AudioPcmOutput::~AudioPcmOutput() {
    backpressure = {};
    reset({}, policy);
}

void AudioPcmOutput::reset(const QAudioDevice &next, AudioOutputFormat::Policy nextPolicy,
                           qint64 positionMs) {
    ++generation;
    timer.stop();
    if (sink) {
        sink->blockSignals(true);
        sink->reset();
    }
    sink.reset();
    writer = nullptr;
    resampler.reset();
    pending.clear();
    offset = 0;
    writtenBytes = 0;
    consumedUs = 0;
    consumptionClock.invalidate();
    baseMs = minimumMs = positionMs;
    failure = underruns = 0;
    conversionNs = conversionMaxNs = conversionCalls = 0;
    ending = drained = heard = false;
    pressured = false;
    device = next;
    policy = nextPolicy;
    system = AudioOutputFormat::systemFormat(device);
    input = submitted = {};
}

bool AudioPcmOutput::open(const QAudioFormat &source) {
    input = source;
    submitted = AudioOutputFormat::select(
        source, system.format, device.preferredFormat(), policy,
        [this](const QAudioFormat &format) { return device.isFormatSupported(format); });
    if (!submitted.isValid()) {
        fail(1);
        return false;
    }
    resampler = std::make_unique<AudioResampler>();
    if (!resampler->configure(source, submitted)) {
        fail(2);
        return false;
    }
    sink = std::make_unique<QAudioSink>(device, submitted);
    sink->setVolume(volume);
    sink->setBufferSize(submitted.bytesForDuration(100000));
    // The selected format is the actual client submission format. Hardware and
    // system conversion remain separate, potentially unavailable observations.
    QObject::connect(sink.get(), &QAudioSink::stateChanged, &timer, [this](QtAudio::State state) {
        if (!sink) {
            return;
        }
        if (sink->error() != QtAudio::NoError) {
            // Queue failure handling: never destroy a sink inside its state signal.
            QTimer::singleShot(0, &timer, [this, session = generation] {
                if (session == generation) {
                    fail(3);
                }
            });
        } else if (state == QtAudio::IdleState && heard && !ending && !paused) {
            ++underruns;
        } else if (state == QtAudio::ActiveState) {
            heard = true;
        }
    });
    writer = sink->start();
    if (!writer || sink->error() != QtAudio::NoError) {
        fail(3);
        return false;
    }
    ++rebuilds;
    consumptionClock.start();
    if (paused) {
        sink->suspend();
    }
    return true;
}

bool AudioPcmOutput::push(const QAudioBuffer &buffer) {
    if (failure || ending || !buffer.isValid()) {
        return false;
    }
    QAudioBuffer accepted = buffer;
    if (buffer.startTime() >= 0) {
        const qint64 skipUs = minimumMs * 1000 - buffer.startTime();
        const auto skipFrames =
            std::min<qint64>(buffer.frameCount(),
                             std::max<qint64>(0, (skipUs * buffer.format().sampleRate() + 999999) / 1000000));
        if (skipFrames >= buffer.frameCount()) {
            return true;
        }
        if (skipFrames > 0) {
            const auto bytes = skipFrames * buffer.format().bytesPerFrame();
            accepted = QAudioBuffer(QByteArray(buffer.constData<char>() + bytes, buffer.byteCount() - bytes),
                                    buffer.format(), minimumMs * 1000);
        }
    }
    if (!sink) {
        if (accepted.startTime() >= 0) {
            baseMs = accepted.startTime() / 1000;
        }
        if (!open(accepted.format())) {
            return false;
        }
    }
    // Mid-stream format changes must be handled by reopening the media session;
    // never reinterpret old queued PCM using a new format.
    if (accepted.format() != input) {
        fail(4);
        return false;
    }
    QByteArray converted;
    QElapsedTimer clock;
    clock.start();
    const bool success = resampler->convert(accepted, converted);
    const auto elapsed = clock.nsecsElapsed();
    conversionNs += elapsed;
    conversionMaxNs = std::max(conversionMaxNs, elapsed);
    ++conversionCalls;
    if (!success) {
        fail(2);
        return false;
    }
    if (offset) {
        pending.remove(0, offset);
        offset = 0;
    }
    // Pause the decoder well before this hard cap. If a backend ignores pressure,
    // fail explicitly instead of dropping PCM or growing memory without bound.
    if (qint64(pending.size()) + converted.size() > submitted.bytesForDuration(2000000)) {
        fail(5);
        return false;
    }
    pending += converted;
    if (!paused) {
        timer.start();
    }
    pump();
    return !failure;
}

void AudioPcmOutput::finish() {
    if (ending || failure) {
        return;
    }
    ending = true;
    if (resampler) {
        QByteArray tail;
        if (!resampler->finish(tail)) {
            fail(2);
            return;
        }
        pending += tail;
    }
    if (!paused) {
        timer.start();
    }
    pump();
}
void AudioPcmOutput::pause(bool value) {
    paused = value;
    if (!paused) {
        consumptionClock.start();
    }
    if (sink) {
        if (paused) {
            sink->suspend();
        } else {
            sink->resume();
        }
    }
    if (paused) {
        timer.stop();
    } else if (!failure && !drained) {
        timer.start();
        pump();
    }
}
void AudioPcmOutput::setVolume(float value) {
    volume = std::clamp(value, 0.f, 1.f);
    if (sink) {
        sink->setVolume(volume);
    }
}
qint64 AudioPcmOutput::position() const {
    if (!sink || !submitted.isValid()) {
        return baseMs;
    }
    const auto duration = writtenBytes * 1000000 / submitted.bytesPerFrame() / submitted.sampleRate();
    return baseMs + std::clamp<qint64>(sink->processedUSecs(), 0, duration) / 1000;
}
void AudioPcmOutput::fail(int code) {
    if (failure) {
        return;
    }
    failure = code;
    timer.stop();
    if (sink) {
        sink->suspend();
    }
    // Deferred so push()/stateChanged never reenter a session teardown.
    QTimer::singleShot(0, &timer, [this, code, session = generation] {
        if (session == generation && failure == code && errorOccurred) {
            errorOccurred();
        }
    });
}
void AudioPcmOutput::updatePressure() {
    if (!submitted.isValid()) {
        return;
    }
    const auto bytes = pending.size() - offset;
    const bool next =
        pressured ? bytes > submitted.bytesForDuration(50000) : bytes > submitted.bytesForDuration(200000);
    if (next == pressured) {
        return;
    }
    pressured = next;
    if (backpressure) {
        backpressure(next);
    }
}
void AudioPcmOutput::pump() {
    if (paused || failure || drained) {
        return;
    }
    if (writer && offset < pending.size()) {
        auto count = std::min<qint64>(pending.size() - offset, sink->bytesFree());
        count -= count % submitted.bytesPerFrame();
        if (count > 0) {
            const auto written = writer->write(pending.constData() + offset, count);
            if (written < 0 || written % submitted.bytesPerFrame()) {
                fail(3);
                return;
            }
            offset += written;
            writtenBytes += written;
        }
        if (offset == pending.size()) {
            pending.clear();
            offset = 0;
        }
    }
    updatePressure();
    if (sink && sink->processedUSecs() != consumedUs) {
        consumedUs = sink->processedUSecs();
        consumptionClock.restart();
    } else if (sink && sink->state() != QtAudio::ActiveState) {
        // 设备空闲时没有数据可消费，不能算停滞；否则网络缓冲后的第一帧会被误报为设备故障。
        consumptionClock.restart();
    }
    if (sink && consumptionClock.isValid() && consumptionClock.elapsed() > 5000 &&
        (offset < pending.size() || sink->state() == QtAudio::ActiveState)) {
        fail(6); // Device stopped consuming even though the decoder clock advanced.
        return;
    }
    if (ending && pending.isEmpty() && (!sink || sink->state() == QtAudio::IdleState)) {
        drained = true;
        timer.stop();
        if (completed) {
            completed();
        }
    }
}

QJsonObject AudioPcmOutput::snapshot() const {
    const bool open = sink && writer && !failure && !drained;
    const bool rate = input.isValid() && submitted.isValid() && input.sampleRate() != submitted.sampleRate();
    const bool format =
        input.isValid() && submitted.isValid() && input.sampleFormat() != submitted.sampleFormat();
    const bool channels = input.isValid() && submitted.isValid() &&
                          (input.channelCount() != submitted.channelCount() ||
                           input.channelConfig() != submitted.channelConfig());
    const auto buffered = sink ? sink->bufferSize() - sink->bytesFree() : 0;
    const auto bytes = pending.size() - offset + buffered;
    return {{"outputPolicy", int(policy)},
            {"outputClientFormatStatus", open ? 1 : 0},
            {"outputSampleRateHz", open ? submitted.sampleRate() : 0},
            {"outputChannels", open ? submitted.channelCount() : 0},
            {"outputSampleFormat", open ? int(submitted.sampleFormat()) : 0},
            {"outputSystemFormatStatus", system.status},
            {"outputSystemSampleRateHz", system.format.sampleRate()},
            {"outputSystemChannels", system.format.channelCount()},
            {"outputSystemSampleFormat", int(system.format.sampleFormat())},
            {"outputHardwareFormatStatus", 0},
            {"outputSampleRateConverted", rate},
            {"outputSampleFormatConverted", format},
            {"outputChannelLayoutConverted", channels},
            {"outputResampler", resampler ? (resampler->bypass() ? 0 : 1) : -1},
            {"outputDither", resampler && resampler->dithering()},
            {"outputResampleMeanMs", conversionCalls ? double(conversionNs) / conversionCalls / 1e6 : 0},
            {"outputResampleMaxMs", double(conversionMaxNs) / 1e6},
            {"outputBufferMs", submitted.isValid()
                                   ? double(bytes) * 1000 / submitted.bytesPerFrame() / submitted.sampleRate()
                                   : 0},
            {"outputUnderruns", underruns},
            {"outputError", failure},
            {"outputRebuilds", rebuilds},
            {"outputBackpressure", pressured},
            {"outputDraining", ending && !drained},
            {"outputProcessedMs", double(position())},
            {"outputFallback",
             policy == AudioOutputFormat::Policy::Source && input.isValid() && submitted != input},
            {"outputBackend", 1}}; // QAudioSink client; platform service selection is not inferred.
}
