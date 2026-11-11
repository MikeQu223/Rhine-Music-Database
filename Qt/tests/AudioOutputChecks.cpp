#include "AudioOutputFormat.h"
#include "AudioResampler.h"
#include "AudioPlayer.h"
#include "PlaybackDiagnostics.h"
#include <QCoreApplication>
#include <QDataStream>
#include <QFile>
#include <QTemporaryDir>
#include <QThread>
#ifdef Q_OS_MACOS
#include <QEventLoop>
#include <QGuiApplication>
#include <QRegularExpression>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#endif
#include <cmath>
#include <cstdio>
#include <cstring>
#include <numbers>

namespace {
bool check(bool condition, const char *message) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", message);
    }
    return condition;
}
QAudioFormat format(int rate, QAudioFormat::SampleFormat type = QAudioFormat::Float) {
    QAudioFormat value;
    value.setSampleRate(rate);
    value.setChannelConfig(QAudioFormat::ChannelConfigStereo);
    value.setSampleFormat(type);
    return value;
}
bool waitFor(const std::function<bool()> &ready, int milliseconds = 5000) {
    QElapsedTimer clock;
    clock.start();
    while (!ready() && clock.elapsed() < milliseconds) {
        QCoreApplication::processEvents();
        QThread::msleep(1);
    }
    return ready();
}
#ifdef Q_OS_MACOS
// AVFoundation 的异步回调依赖 macOS 主事件循环，不能只轮询 Qt 的队列。
bool waitForSpatial(const std::function<bool()> &ready) {
    QEventLoop loop;
    QTimer poll;
    QObject::connect(&poll, &QTimer::timeout, &loop, [&] {
        if (ready()) {
            loop.quit();
        }
    });
    QTimer::singleShot(12000, &loop, &QEventLoop::quit);
    poll.start(10);
    loop.exec();
    return ready();
}
#endif
QByteArray tone(int rate, double frequency, int frames) {
    QByteArray bytes(frames * 2 * sizeof(float), Qt::Uninitialized);
    auto *samples = reinterpret_cast<float *>(bytes.data());
    for (int frame = 0; frame < frames; ++frame) {
        samples[frame * 2] = float(.25 * std::sin(2 * std::numbers::pi * frequency * frame / rate));
        samples[frame * 2 + 1] = -samples[frame * 2];
    }
    return bytes;
}
bool converted(const QByteArray &bytes, int inputRate, int outputRate, int chunkFrames, QByteArray &result) {
    AudioResampler converter;
    if (!converter.configure(format(inputRate), format(outputRate))) {
        return false;
    }
    for (int byte = 0; byte < bytes.size(); byte += chunkFrames * 8) {
        QByteArray block;
        if (!converter.convert(QAudioBuffer(bytes.mid(byte, chunkFrames * 8), format(inputRate)), block)) {
            return false;
        }
        result += block;
    }
    QByteArray tail;
    if (!converter.finish(tail)) {
        return false;
    }
    result += tail;
    return true;
}
bool policyChecks() {
    const auto source = format(44100, QAudioFormat::Int32);
    const auto system = format(48000);
    auto supported = [](const QAudioFormat &f) {
        return f == format(48000) || f == format(44100, QAudioFormat::Int32);
    };
    bool ok = check(AudioOutputFormat::select(source, system, system, AudioOutputFormat::Policy::System,
                                              supported) == system,
                    "Shared policy selects system rate and a supported complete format");
    ok &= check(AudioOutputFormat::select(source, system, system, AudioOutputFormat::Policy::Source,
                                          supported) == source,
                "Source policy preserves integer PCM exactly when supported");
    ok &= check(!AudioOutputFormat::select(source, system, system, AudioOutputFormat::Policy::System,
                                           [](auto) { return false; })
                     .isValid(),
                "Unsupported format matrices fail explicitly");
    const auto safe = PlaybackDiagnostics::numericFields({{"outputSampleRateHz", 48000},
                                                          {"outputSampleFormatConverted", true},
                                                          {"outputResampleMeanMs", .03},
                                                          {"deviceName", "PRIVATE"}});
    ok &= check(safe.size() == 3 && !safe.contains("deviceName"),
                "Output diagnostics retain numeric facts without device identities");
    return ok;
}
bool signalChecks() {
    bool ok = check(AudioResampler::available(), "The deployed Qt FFmpeg SWR runtime must load");
    if (!ok) {
        return false;
    }
    for (int rate : {44100, 48000, 96000, 192000}) {
        const auto bytes = tone(rate, 1000, rate / 4);
        QByteArray whole, fragmented;
        ok &= check(converted(bytes, rate, 48000, rate, whole) &&
                        converted(bytes, rate, 48000, 257, fragmented),
                    "SWR converts complete and fragmented PCM");
        ok &= check(whole == fragmented, "Fragment boundaries must not change samples or lose FIR tails");
        ok &= check(std::abs(whole.size() / 8 - 12000) <= 1, "Drain retains the expected converted duration");
        if (whole.size() < 1000) {
            continue;
        }
        const auto *samples = reinterpret_cast<const float *>(whole.constData());
        double error = 0;
        for (int frame = 128; frame < whole.size() / 8 - 128; ++frame) {
            const double expected = .25 * std::sin(2 * std::numbers::pi * 1000 * frame / 48000);
            error = std::max(error, std::abs(double(samples[frame * 2]) - expected));
            ok &= check(samples[frame * 2] == -samples[frame * 2 + 1],
                        "Stereo phase and ordering survive conversion");
        }
        ok &= check(error < .0001, "1 kHz signal has bounded passband error");
    }
    QByteArray alias;
    ok &=
        check(converted(tone(96000, 30000, 24000), 96000, 48000, 311, alias), "Out-of-band fixture converts");
    double peak = 0;
    const auto *samples = reinterpret_cast<const float *>(alias.constData());
    for (int i = 256; i < alias.size() / 4 - 256; ++i) {
        peak = std::max(peak, std::abs(double(samples[i])));
    }
    ok &= check(peak < .0001, "Downsampling suppresses out-of-band aliasing");
    AudioResampler exact;
    QByteArray integer(8192, Qt::Uninitialized);
    for (int i = 0; i < integer.size(); ++i) {
        integer[i] = char((i * 71) & 255);
    }
    QByteArray output, tail;
    const auto integerFormat = format(44100, QAudioFormat::Int32);
    ok &= check(exact.configure(integerFormat, integerFormat) && exact.bypass() &&
                    exact.convert(QAudioBuffer(integer, integerFormat), output) && output == integer &&
                    exact.finish(tail) && tail.isEmpty(),
                "Int32 bypass is byte-exact, including low significant bits");
    ok &= check(exact.configure(format(48000), format(48000, QAudioFormat::Int16)) && exact.dithering(),
                "Float-to-Int16 quantization owns TPDF dither at the final conversion");
    return ok;
}
QString fixture(const QString &directory) {
    const auto path = directory + "/signal.wav";
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        return {};
    }
    const auto samples = tone(44100, 440, 44100 * 3);
    QDataStream stream(&file);
    stream.setByteOrder(QDataStream::LittleEndian);
    stream.writeRawData("RIFF", 4);
    stream << quint32(36 + samples.size());
    stream.writeRawData("WAVEfmt ", 8);
    stream << quint32(16) << quint16(3) << quint16(2) << quint32(44100) << quint32(44100 * 8) << quint16(8)
           << quint16(32);
    stream.writeRawData("data", 4);
    stream << quint32(samples.size());
    stream.writeRawData(samples.constData(), samples.size());
    return path;
}
}

class AudioPlayerRegression {
  public:
#ifdef Q_OS_MACOS
    static bool spatial(const QString &path) {
        if (QMediaDevices::defaultAudioOutput().isNull()) {
            std::fprintf(stderr, "SKIP: AVPlayer playback requires a system output\n");
            return true;
        }
        AudioPlayer audio;
        audio.control("volume", 0);
        const auto url = QUrl::fromLocalFile(path).toString();
        const auto position = [&] { return audio.state()["position"].toLongLong(); };
        const auto backend = [&] { return audio.diagnosticState()["outputBackend"].toInt(); };
        bool ok = check(audio.load(url, true, false, {}, 700, true) && backend() == 2,
                        "Apple stereo fixture selects AVPlayer by default");
        ok &= check(waitForSpatial([&] {
                        const auto state = audio.state();
                        return state["seekable"].toBool() && !state["buffering"].toBool();
                    }) &&
                        !audio.state()["playing"].toBool() && std::abs(position() - 700) < 30,
                    "AVPlayer restores a paused position");
        audio.control("resume");
        ok &= check(waitForSpatial([&] { return position() >= 900; }) && backend() == 2,
                    "AVPlayer resumes at the saved position");
        audio.control("pause");
        audio.control("seek", 2300);
        audio.control("seek", 2500);
        ok &= check(waitForSpatial([&] { return !audio.state()["buffering"].toBool(); }) &&
                        std::abs(position() - 2500) < 30 && !audio.state()["playing"].toBool(),
                    "The most recent seek wins and preserves pause");
        audio.control("resume");
        ok &= check(waitForSpatial([&] { return audio.ended == 1; }) && backend() == 2 && position() >= 2980,
                    "AVPlayer emits exactly one natural end at the final position");
        audio.control("resume");
        ok &=
            check(waitForSpatial([&] { return position() >= 150 && position() < 1000; }) && audio.ended == 1,
                  "Resuming at EOF starts the same item again");
        audio.control("pause");
        audio.control("seek", 1600);
        ok &= check(audio.load(url, true, false, {}, 400, true) &&
                        waitForSpatial([&] { return !audio.state()["buffering"].toBool(); }) &&
                        backend() == 2 && std::abs(position() - 400) < 30 && audio.ended == 1,
                    "Replacing the item isolates an in-flight seek and old EOF");
        const auto switchPosition = position();
        audio.setOutputPolicy(AudioOutputFormat::Policy::Source);
        ok &= check(backend() == 2 && !audio.state()["requested"].toBool() &&
                        std::abs(position() - switchPosition) < 50,
                    "Legacy output preference cannot override Apple playback");
        ok &= check(waitForSpatial([&] {
                        return audio.diagnosticState()["sourceSampleRateHz"].toInt() == 44100;
                    }) && audio.diagnosticState()["sourceChannels"].toInt() == 2 &&
                        audio.diagnosticState()["outputClientFormatStatus"].toInt() == 0,
                    "Native source metadata is distinct from a Qt PCM submission format");
        audio.control("stop");
        ok &= check(position() == 0 && !audio.state()["requested"].toBool(),
                    "Stop clears the local playback session");
        return ok;
    }

    /** 用同一个本机服务器验证网络读取、单声道和过期链接的恢复状态。 */
    static bool spatialStreaming(const QString &path) {
        if (QMediaDevices::defaultAudioOutput().isNull()) {
            return true;
        }
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) {
            return false;
        }
        const auto bytes = file.readAll();
        constexpr int monoSamples = 48000;
        const QByteArray silence(monoSamples * 2, '\0');
        QByteArray monoBytes;
        QDataStream monoHeader(&monoBytes, QIODevice::WriteOnly);
        monoHeader.setByteOrder(QDataStream::LittleEndian);
        monoHeader.writeRawData("RIFF", 4);
        monoHeader << quint32(36 + silence.size());
        monoHeader.writeRawData("WAVEfmt ", 8);
        monoHeader << quint32(16) << quint16(1) << quint16(1) << quint32(48000) << quint32(96000)
                   << quint16(2) << quint16(16);
        monoHeader.writeRawData("data", 4);
        monoHeader << quint32(silence.size());
        monoHeader.writeRawData(silence.constData(), silence.size());
        QTcpServer server;
        int managedRequests = 0;
        bool encodedQuerySeen = false;
        const QRegularExpression range(QStringLiteral("Range: bytes=([0-9]+)-([0-9]*)"),
                                       QRegularExpression::CaseInsensitiveOption);
        QObject::connect(&server, &QTcpServer::newConnection, &server, [&] {
            while (server.hasPendingConnections()) {
                auto *socket = server.nextPendingConnection();
                QObject::connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
                QObject::connect(socket, &QTcpSocket::readyRead, socket, [&, socket] {
                    const auto request = socket->property("request").toByteArray() + socket->readAll();
                    socket->setProperty("request", request);
                    if (!request.contains("\r\n\r\n") || socket->property("sent").toBool()) {
                        return;
                    }
                    socket->setProperty("sent", true);
                    encodedQuerySeen |= request.startsWith("GET /stereo.wav?ticket=a%2Bb%2Fc%3D ");
                    const bool native = request.contains("AppleCoreMedia");
                    if (!native) {
                        ++managedRequests;
                    }
                    if (request.contains(" /expired.wav ")) {
                        socket->write(
                            "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                        socket->disconnectFromHost();
                        return;
                    }
                    const auto &audioBytes = request.contains(" /mono.wav ") ? monoBytes : bytes;
                    const auto match = range.match(QString::fromLatin1(request));
                    const auto first = match.captured(1).toLongLong();
                    const auto last =
                        match.captured(2).isEmpty()
                            ? audioBytes.size() - 1
                            : std::min<qint64>(audioBytes.size() - 1, match.captured(2).toLongLong());
                    const auto body = audioBytes.mid(first, last - first + 1);
                    QByteArray header = "HTTP/1.1 200 OK\r\n";
                    if (match.hasMatch()) {
                        header = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes " +
                                 QByteArray::number(first) + '-' + QByteArray::number(last) + '/' +
                                 QByteArray::number(audioBytes.size()) + "\r\n";
                    }
                    header += "Content-Type: audio/wav\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
                              "Content-Length: " +
                              QByteArray::number(body.size()) + "\r\n\r\n";
                    socket->write(header);
                    if (!request.startsWith("HEAD ")) {
                        socket->write(body);
                    }
                    socket->disconnectFromHost();
                });
            }
        });
        if (!server.listen(QHostAddress::LocalHost)) {
            return false;
        }

        AudioPlayer audio;
        audio.control("volume", 0);
        const auto source = [&](const QString &name) {
            return QUrl(QStringLiteral("http://127.0.0.1:%1/%2.wav").arg(server.serverPort()).arg(name));
        };
        const auto position = [&] { return audio.state()["position"].toLongLong(); };
        bool ok = check(!audio.load(source("stereo").toString(), false),
                        "An unapproved URL is rejected before AVPlayer");
        // 只在测试中绕过来源准入，使用本机 HTTP 验证 AVPlayer 与托管传输的实际请求。
        auto stereoUrl = source("stereo");
        stereoUrl.setQuery(QStringLiteral("ticket=a%2Bb%2Fc%3D"));
        ok &= check(audio.startApplePlayback(stereoUrl, false) &&
                        waitForSpatial([&] { return position() >= 200; }) &&
                        audio.diagnosticState()["outputBackend"].toInt() == 2 && managedRequests == 0 &&
                        encodedQuerySeen,
                    "AVPlayer preserves the encoded query and streams stereo without a second downloader");
        audio.control("seek", 1500);
        ok &= check(waitForSpatial([&] { return position() > 1600; }),
                    "AVPlayer resumes streamed audio after seeking");
        audio.control("stop");

        ok &= check(audio.startApplePlayback(source("mono"), true) &&
                        waitForSpatial([&] { return audio.diagnosticState()["sourceChannels"].toInt() == 1; }) &&
                        audio.diagnosticState()["outputBackend"].toInt() == 2 && !audio.playbackRequested,
                    "Mono streams keep AVPlayer and preserve pause");
        audio.control("stop");

        audio.recoveryPosition = 700;
        ok &= check(audio.startApplePlayback(source("expired"), false) &&
                        waitForSpatial([&] { return !audio.error.isEmpty(); }) && audio.failureRecoverable &&
                        audio.playbackRequested && position() == 700,
                    "An expired URL preserves position and intent for provider refresh");
        audio.control("stop");
        return ok;
    }
#endif

    static bool production(const QString &path) {
        if (QMediaDevices::defaultAudioOutput().isNull()) {
            std::fprintf(stderr, "SKIP: no physical output; signal and policy checks still run\n");
            return true;
        }
        AudioPlayer audio;
#ifdef Q_OS_MACOS
        audio.useApplePlayback = false;
#endif
        // 静音跑生产路径，避免测试发出可听声音。
        audio.control("volume", 0);
        audio.enableDiagnostics(true);
        bool ok = check(audio.load(QUrl::fromLocalFile(path).toString(), true), "Production fixture loads");
        ok &= check(waitFor([&] { return audio.pcm.position() >= 200 || audio.pcm.failed(); }) &&
                        !audio.pcm.failed(),
                    "Production decoder supplies the negotiated sink and the device consumes PCM");
        const auto measured = audio.diagnosticState();
        ok &= check(measured["outputClientFormatStatus"].toInt() == 1 &&
                        measured["outputSampleRateHz"].toInt() > 0,
                    "Panel snapshot contains opened client format facts");
        audio.control("pause");
        const auto paused = audio.pcm.position();
        QElapsedTimer clock;
        clock.start();
        waitFor([&] { return clock.elapsed() >= 120; }, 200);
        ok &= check(std::abs(audio.pcm.position() - paused) < 10, "Pause freezes the device clock");
        const auto endpoint = QMediaDevices::defaultAudioOutput();
        audio.defaultOutput = [] { return QAudioDevice{}; };
        audio.followDefaultOutput();
        ok &= check(audio.outputUnavailable && !audio.pcm.active(), "Device loss releases queued PCM");
        audio.defaultOutput = [endpoint] { return endpoint; };
        audio.followDefaultOutput();
        ok &=
            check(!audio.playbackRequested && !audio.player->isPlaying(), "Reconnect preserves manual pause");
        audio.control("resume");
        ok &= check(waitFor([&] { return audio.pcm.position() >= paused + 100 || audio.pcm.failed(); }) &&
                        !audio.pcm.failed(),
                    "Reconnect restores position and resumes real device consumption");
        audio.control("pause");
        audio.control("seek", 1700);
        audio.setOutputPolicy(AudioOutputFormat::Policy::Source);
        ok &= check(!audio.playbackRequested, "Changing policy preserves manual pause");
        audio.control("resume");
        ok &= check(waitFor([&] { return audio.pcm.position() >= 1900 || audio.pcm.failed(); }) &&
                        !audio.pcm.failed(),
                    "Seek and policy reopen produce PCM at the new position");
        ok &= check(waitFor([&] { return audio.ended == 1 || !audio.error.isEmpty(); }) &&
                        audio.error.isEmpty() && audio.pcm.complete() && audio.pcm.position() >= 2980,
                    "Exactly one EOF follows device drain, including the resampler tail");
        audio.control("stop");
        ok &= check(!audio.pcm.active() && audio.diagnosticState()["outputClientFormatStatus"].toInt() == 0,
                    "Stop releases the output and clears current format observations");
        // 故意让生产者突发：一次 1 秒推送要同时超过 sink 环形缓冲（250 ms）
        // 和背压高水位（200 ms），才能覆盖与 QMediaPlayer 常规节奏无关的队列压力。
        // PCM 不得被静默丢弃。
        AudioPcmOutput burst;
        burst.setVolume(0);
        burst.reset(endpoint, AudioOutputFormat::Policy::System);
        int blocked = 0, resumed = 0, completions = 0;
        burst.backpressure = [&](bool pressure) { pressure ? ++blocked : ++resumed; };
        burst.completed = [&] { ++completions; };
        burst.pause(false);
        ok &= check(burst.push(QAudioBuffer(tone(44100, 1000, 44100), format(44100), 0)) && blocked == 1,
                    "Bursty decoding applies high-water backpressure");
        burst.finish();
        ok &= check(waitFor([&] { return burst.complete() || burst.failed(); }) && !burst.failed() &&
                        resumed == 1 && completions == 1 && burst.position() >= 990,
                    "Low-water resume and EOF drain consume the entire bounded queue exactly once");
        burst.reset(endpoint, AudioOutputFormat::Policy::System);
        burst.pause(false);
        ok &= check(
            !burst.push(QAudioBuffer(tone(44100, 1000, 44100 * 3), format(44100), 0)) && burst.failed(),
            "An uncooperative oversized producer fails instead of dropping PCM or growing indefinitely");
        return ok;
    }
};

int main(int argc, char **argv) {
    qputenv("QT_MEDIA_BACKEND", "ffmpeg");
#ifdef Q_OS_MACOS
    QGuiApplication app(argc, argv);
#else
    QCoreApplication app(argc, argv);
#endif
    QTemporaryDir directory;
    bool ok = policyChecks();
    ok &= signalChecks();
    const auto path = fixture(directory.path());
    ok &= AudioPlayerRegression::production(path);
#ifdef Q_OS_MACOS
    ok &= AudioPlayerRegression::spatial(path);
    ok &= AudioPlayerRegression::spatialStreaming(path);
#endif
    return ok ? 0 : 1;
}
