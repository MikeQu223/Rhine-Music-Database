#include "AudioPcmOutput.h"
#include <algorithm>

namespace {
// 设备环形缓冲的目标时长：主线程偶发停顿由它吸收，解码队列帮不上忙。
constexpr qint64 SINK_BUFFER_MS = 250;
// 背压只统计尚未写进设备的应用队列，不含 sink 环形缓冲，阈值不随平台缓冲漂移。
constexpr qint64 PRESSURE_HIGH_MS = 200;
constexpr qint64 PRESSURE_LOW_MS = 50;
// 未写入队列的硬上限：解码器忽略背压时显式失败，不丢样本也不无限增长。
constexpr qint64 QUEUE_LIMIT_MS = 2000;
// 设备连续这么久没有消费、解码时钟却仍在推进，就判定设备停滞。
constexpr qint64 STALL_TIMEOUT_MS = 5000;
}

AudioPcmOutput::AudioPcmOutput() {
    timer.setInterval(5);
    timer.setTimerType(Qt::PreciseTimer);
    QObject::connect(&timer, &QTimer::timeout, &timer, [this] { pump(); });
}
AudioPcmOutput::~AudioPcmOutput() {
    backpressure = {};
    reset({}, policy);
}

void AudioPcmOutput::reset(const QAudioDevice &next, AudioOutputFormat::Policy nextPolicy, qint64 positionMs,
                           const AudioOutputFormat::SystemFormat *observedSystem) {
    ++generation;
    timer.stop();
    if (sink) {
        sink->blockSignals(true);
        sink->reset();
    }
    sink.reset();
#ifdef Q_OS_WIN
    native.reset();
#endif
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
    // 后台已经观测过系统格式时直接复用，不在音频泵线程重新枚举设备。
    system = observedSystem ? *observedSystem : AudioOutputFormat::systemFormat(device);
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
#ifdef Q_OS_WIN
    native = std::make_unique<WindowsAudioOutput>();
    if (!native->open(device.id(), exclusive, submitted)) {
        native.reset();
        fail(3);
        return false;
    }
    submitted = native->format();
#endif
    resampler = std::make_unique<AudioResampler>();
    if (!resampler->configure(source, submitted)) {
        fail(2);
        return false;
    }
#ifdef Q_OS_WIN
    native->setVolume(volume);
    native->setPaused(paused);
    ++rebuilds;
    consumptionClock.start();
    return true;
#endif
    sink = std::make_unique<QAudioSink>(device, submitted);
    sink->setVolume(volume);
    sink->setBufferSize(submitted.bytesForDuration(SINK_BUFFER_MS * 1000));
    // 选定格式就是实际提交给客户端的格式；硬件与系统转换是另一层观测，可能不可用。
    QObject::connect(sink.get(), &QAudioSink::stateChanged, &timer, [this](QtAudio::State state) {
        if (!sink) {
            return;
        }
        if (sink->error() != QtAudio::NoError) {
            // 队列故障延后处理：绝不能在 sink 自己的状态信号里销毁它。
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
    if (!active()) {
        if (accepted.startTime() >= 0) {
            baseMs = accepted.startTime() / 1000;
        }
        if (!open(accepted.format())) {
            return false;
        }
    }
    // 流内格式变化必须重开媒体会话；绝不能用新格式解释已经排队的旧 PCM。
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
    // 在硬上限之前很早就暂停解码；后端无视背压时显式失败，而不是丢 PCM 或无限占内存。
    if (qint64(pending.size()) + converted.size() > submitted.bytesForDuration(QUEUE_LIMIT_MS * 1000)) {
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
#ifdef Q_OS_WIN
    if (native) {
        native->setPaused(paused);
    }
#endif
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
#ifdef Q_OS_WIN
    if (native) {
        native->setVolume(volume);
    }
#endif
    if (sink) {
        sink->setVolume(volume);
    }
}
qint64 AudioPcmOutput::position() const {
    if (!active() || !submitted.isValid()) {
        return baseMs;
    }
    const auto duration = writtenBytes * 1000000 / submitted.bytesPerFrame() / submitted.sampleRate();
#ifdef Q_OS_WIN
    if (native) {
        return baseMs + std::clamp<qint64>(native->processedUSecs(), 0, duration) / 1000;
    }
#endif
    return baseMs + std::clamp<qint64>(sink->processedUSecs(), 0, duration) / 1000;
}
void AudioPcmOutput::fail(int code) {
    if (failure) {
        return;
    }
    failure = code;
    timer.stop();
#ifdef Q_OS_WIN
    if (native) {
        native->setPaused(true);
    }
#endif
    if (sink) {
        sink->suspend();
    }
    // 延后通知：push()/stateChanged 绝不能重入会话拆除流程。
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
    auto bytes = pending.size() - offset;
#ifdef Q_OS_WIN
    if (native) {
        bytes += native->queuedBytes();
    }
#endif
    qint64 reserveMs = 0;
#ifdef Q_OS_WIN
    // The native queue also supplies the device's prefill; do not throttle the
    // decoder before that prefill can start the client.
    if (native) {
        reserveMs = SINK_BUFFER_MS;
    }
#endif
    const bool next = pressured ? bytes > submitted.bytesForDuration((PRESSURE_LOW_MS + reserveMs) * 1000)
                                : bytes > submitted.bytesForDuration((PRESSURE_HIGH_MS + reserveMs) * 1000);
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
#ifdef Q_OS_WIN
    if (native) {
        if (native->error() != 0) {
            fail(3);
            return;
        }
        auto count = std::min<qsizetype>(pending.size() - offset, native->bytesFree());
        count -= count % submitted.bytesPerFrame();
        if (count > 0) {
            native->enqueue(QAudioBuffer(pending.mid(offset, count), submitted));
            offset += count;
            writtenBytes += count;
        }
        if (offset == pending.size()) {
            pending.clear();
            offset = 0;
        }
        updatePressure();
        const auto consumed = native->processedUSecs();
        if (consumed != consumedUs || native->queuedBytes() == 0) {
            consumedUs = consumed;
            consumptionClock.restart();
        } else if (consumptionClock.isValid() && consumptionClock.elapsed() > STALL_TIMEOUT_MS) {
            fail(6);
            return;
        }
        if (ending && pending.isEmpty()) {
            native->finish();
            if (native->drained()) {
                drained = true;
                timer.stop();
                if (completed) {
                    completed();
                }
            }
        }
        return;
    }
#endif
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
    if (sink && consumptionClock.isValid() && consumptionClock.elapsed() > STALL_TIMEOUT_MS &&
        (offset < pending.size() || sink->state() == QtAudio::ActiveState)) {
        // 解码时钟仍在推进，设备却停止消费。
        fail(6);
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
    const bool open = active() && !failure && !drained;
    const bool rate = input.isValid() && submitted.isValid() && input.sampleRate() != submitted.sampleRate();
    const bool format =
        input.isValid() && submitted.isValid() && input.sampleFormat() != submitted.sampleFormat();
    const bool channels = input.isValid() && submitted.isValid() &&
                          (input.channelCount() != submitted.channelCount() ||
                           input.channelConfig() != submitted.channelConfig());
    // 缓冲 = 尚未写进设备的应用队列 + 已占用的 sink 环形缓冲，统一按提交格式换算。
    auto buffered = sink ? sink->bufferSize() - sink->bytesFree() : qsizetype(0);
#ifdef Q_OS_WIN
    if (native && submitted.isValid()) {
        const auto submittedBytes = native->consumedFrames() * submitted.bytesPerFrame();
        const auto playedBytes =
            native->processedUSecs() * submitted.sampleRate() / 1000000 * submitted.bytesPerFrame();
        buffered = native->queuedBytes() + std::max<qint64>(0, qint64(submittedBytes) - playedBytes);
    }
#endif
    const auto bytes = pending.size() - offset + buffered;
    // outputBackend 只描述应用侧 QAudioSink 客户端，不推断平台服务选择。
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
            {"outputUnderruns",
#ifdef Q_OS_WIN
             native ? native->underrunCount() :
#endif
                    underruns},
            {"outputError", failure},
            {"outputRebuilds", rebuilds},
            {"outputBackpressure", pressured},
            {"outputDraining", ending && !drained},
            {"outputProcessedMs", double(position())},
            {"outputFallback",
             policy == AudioOutputFormat::Policy::Source && input.isValid() && submitted != input},
            {"outputBackend",
#ifdef Q_OS_WIN
             native ? 3 :
#endif
                    1}};
}
