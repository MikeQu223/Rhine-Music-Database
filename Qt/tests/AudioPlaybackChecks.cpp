#include <QtGlobal>
#ifdef Q_OS_WIN
#include "WindowsAudioOutput.h"
#endif
#include <QAudioBufferOutput>
#include <QAudioDevice>
#include <QAudioSink>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QAudioBuffer>
#include <QCoreApplication>
#include <QDataStream>
#include <QElapsedTimer>
#include <QFile>
#include <QTemporaryDir>
#include <QThread>
#include <algorithm>
#include <cmath>
#include <cstdio>

namespace {
bool check(bool result, const char *message) {
    if (!result) {
        std::fprintf(stderr, "%s\n", message);
    }
    return result;
}

bool waitFor(const std::function<bool()> &ready) {
    QElapsedTimer timer;
    timer.start();
    while (!ready() && timer.elapsed() < 5000) {
        QCoreApplication::processEvents();
        QThread::msleep(1);
    }
    return ready();
}

// 生成非静音 PCM，覆盖不同采样率与位深；不把用户歌曲加入仓库或 CI 资源。
QString toneFile(const QString &directory, int sampleRate, int bitDepth) {
    const auto path = directory + QStringLiteral("/%1-%2.wav").arg(sampleRate).arg(bitDepth);
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        return {};
    }
    const int frames = sampleRate / 5;
    const int frameBytes = 2 * bitDepth / 8;
    const quint32 bytes = frames * frameBytes;
    QDataStream stream(&file);
    stream.setByteOrder(QDataStream::LittleEndian);
    stream.writeRawData("RIFF", 4);
    stream << quint32(36 + bytes);
    stream.writeRawData("WAVEfmt ", 8);
    stream << quint32(16) << quint16(1) << quint16(2) << quint32(sampleRate)
           << quint32(sampleRate * frameBytes) << quint16(frameBytes) << quint16(bitDepth);
    stream.writeRawData("data", 4);
    stream << bytes;
    for (int i = 0; i < frames; ++i) {
        const auto value = qint32(std::sin(2.0 * 3.141592653589793 * 440 * i / sampleRate) *
                                  ((1 << (bitDepth - 1)) - 1) * 0.125);
        for (int channel = 0; channel < 2; ++channel) {
            for (int byte = 0; byte < bitDepth / 8; ++byte) {
                stream << quint8(quint32(value) >> (8 * byte));
            }
        }
    }
    return stream.status() == QDataStream::Ok ? path : QString();
}

/** 验证真实 FFmpeg 解码与到设备常用格式的转换；不依赖 CI 是否存在物理声卡。 */
bool decodeSignal(const QString &path) {
    if (path.isEmpty()) {
        return check(false, "Non-silent fixture must exist");
    }
    QAudioFormat format;
    format.setSampleRate(48000);
    format.setChannelConfig(QAudioFormat::ChannelConfigStereo);
    format.setSampleFormat(QAudioFormat::Float);
    QAudioBufferOutput decoded(format);
    QMediaPlayer player;
    player.setAudioBufferOutput(&decoded);
    double peak = 0;
    QObject::connect(&decoded, &QAudioBufferOutput::audioBufferReceived, &player,
                     [&](const QAudioBuffer &buffer) {
                         if (!buffer.isValid() || buffer.format() != format) {
                             return;
                         }
                         for (int i = 0; i < buffer.sampleCount(); ++i) {
                             peak = std::max(peak, double(std::abs(buffer.constData<float>()[i])));
                         }
                     });
    player.setSource(QUrl::fromLocalFile(path));
    player.play();
    const bool decodedSignal =
        waitFor([&] { return peak > 0.01 || player.error() != QMediaPlayer::NoError; });
    player.stop();
    return check(decodedSignal && peak > 0.01 && player.error() == QMediaPlayer::NoError,
                 "Source must decode to non-silent 48 kHz float PCM");
}

/** 有设备时验证高采样率真正启动并消耗 PCM；无声卡的 CI 明确跳过硬件验收。 */
bool outputRegression() {
    const auto device = QMediaDevices::defaultAudioOutput();
    if (device.isNull()) {
        std::fprintf(stderr, "SKIP: no physical audio output; decoder checks still run\n");
        return true;
    }
    bool ok = true;
    for (const int sampleRate : {44100, 48000, 96000, 192000}) {
        QAudioFormat format;
        format.setSampleRate(sampleRate);
        format.setChannelConfig(QAudioFormat::ChannelConfigStereo);
        format.setSampleFormat(QAudioFormat::Int32);
        QAudioSink sink(device, format);
        // 使用非零 PCM 验证输出消费，但不让自动回归在用户机器上发声。
        sink.setVolume(0);
        auto *stream = sink.start();
        if (!check(stream && sink.error() == QtAudio::NoError, "PCM audio output must open")) {
            std::fprintf(stderr, "Failed rate: %d Hz\n", sampleRate);
            ok = false;
            continue;
        }
        QByteArray samples(format.bytesForDuration(100000), '\0');
        for (qsizetype i = 0; i < samples.size(); ++i) {
            samples[i] = char((i % 127) + 1);
        }
        const auto written = stream->write(samples);
        ok &= check(written > 0 && waitFor([&] { return sink.processedUSecs() > 0; }),
                    "Audio output must consume PCM instead of only advancing player position");
        ok &= check(sink.error() == QtAudio::NoError, "PCM output must not fail after opening");
        sink.reset();
    }
    return ok;
}
}

int main(int argc, char **argv) {
    qputenv("QT_MEDIA_BACKEND", "ffmpeg");
    QCoreApplication app(argc, argv);
    QTemporaryDir directory;
    bool ok = check(directory.isValid(), "Audio fixture directory must exist");
    ok &= outputRegression();
#ifdef Q_OS_WIN
    const auto device = QMediaDevices::defaultAudioOutput();
    if (!device.isNull()) {
        for (bool exclusive : {false, true}) {
            WindowsAudioOutput output;
            const bool opened = output.open(device.id(), exclusive);
            ok &= check(opened, "WASAPI shared/exclusive endpoint must open");
            if (!opened) {
                continue;
            }
            output.setVolume(0);
            const auto format = output.format();
            QAudioBuffer buffer(QByteArray(format.bytesForDuration(300000), '\0'), format);
            output.enqueue(buffer);
            // Deliberately block the GUI: native consumption must continue.
            QThread::msleep(180);
            ok &= check(output.consumedFrames() > 0 && output.error() == 0,
                        "WASAPI consumes PCM while GUI event processing is blocked");
            output.setPaused(true);
            QThread::msleep(50);
            const auto paused = output.consumedFrames();
            output.enqueue(buffer);
            QThread::msleep(50);
            ok &= check(output.consumedFrames() == paused, "Paused output discards late PCM");
            output.setPaused(false);
            ok &= check(waitFor([&] { return output.consumedFrames() > paused; }),
                        "WASAPI resumes with preserved buffered PCM");
            output.reset();
            const auto beforeTail = output.consumedFrames();
            const QAudioBuffer tail(QByteArray(format.bytesForDuration(20000), '\0'), format);
            output.enqueue(tail);
            output.finish();
            ok &= check(waitFor([&] { return output.drained(); }) &&
                            output.consumedFrames() >= beforeTail + quint64(tail.frameCount()),
                        "Sub-prefill final packets drain completely");
        }
    }
#endif
    for (const int sampleRate : {44100, 48000, 96000, 192000}) {
        for (const int bitDepth : {16, 24}) {
            ok &= decodeSignal(toneFile(directory.path(), sampleRate, bitDepth));
        }
    }
    if (app.arguments().size() > 1) {
        ok &= decodeSignal(app.arguments().at(1));
    }
    return ok ? 0 : 1;
}
