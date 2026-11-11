#include "AudioPlayer.h"
#include <QCoreApplication>
#include <QDataStream>
#include <QJsonDocument>
#include <QTcpServer>
#include <QTcpSocket>
#include <QThread>
#include <QRegularExpression>
#include <cmath>
#include <cstdio>

namespace {
bool check(bool value, const char *message) {
    if (!value) {
        std::fprintf(stderr, "%s\n", message);
    }
    return value;
}

bool waitFor(const std::function<bool()> &ready, int timeoutMs = 12000) {
    QElapsedTimer clock;
    clock.start();
    while (!ready() && clock.elapsed() < timeoutMs) {
        QCoreApplication::processEvents();
        QThread::msleep(1);
    }
    return ready();
}

/** 提供非静音 PCM，长度与 HTTP 声明固定；截断时保留完整媒体头以模拟真实传输失败。 */
QByteArray tone(int seconds = 4) {
    QByteArray bytes;
    QDataStream stream(&bytes, QIODevice::WriteOnly);
    stream.setByteOrder(QDataStream::LittleEndian);
    const int frames = 48000 * seconds;
    stream.writeRawData("RIFF", 4);
    stream << quint32(36 + frames * 4);
    stream.writeRawData("WAVEfmt ", 8);
    stream << quint32(16) << quint16(1) << quint16(2) << quint32(48000) << quint32(192000) << quint16(4)
           << quint16(16);
    stream.writeRawData("data", 4);
    stream << quint32(frames * 4);
    for (int i = 0; i < frames; ++i) {
        const auto sample = qint16(std::sin(2 * 3.141592653589793 * 440 * i / 48000) * 4000);
        stream << sample << sample;
    }
    return bytes;
}
}

class AudioPlayerRegression {
  public:
    /** 使用真实 HTTP、FFmpeg 与生产播放器验证断流；不访问音乐平台，不播放可听声音。 */
    static bool stream(int percent, bool transientError, bool managed = false, bool chunked = false,
                       bool repair = true, bool slow = false, bool jump = false, bool cancel = false) {
        QTcpServer server;
        // 慢流覆盖超过 FFmpeg 探测窗口的音频，避免短文件探测本身必须读到 EOF。
        const int seconds = slow ? 12 : 4;
        const auto bytes = tone(seconds);
        int requests = 0;
        bool sentTail = false;
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
                    ++requests;
                    const QRegularExpression range("Range: bytes=([0-9]+)-",
                                                   QRegularExpression::CaseInsensitiveOption);
                    const auto offset = range.match(QString::fromLatin1(request)).captured(1).toLongLong();
                    const bool truncate = percent < 100 && (!managed || requests == 1 || !repair);
                    auto body = bytes.mid(offset);
                    if (truncate) {
                        body.truncate(body.size() * percent / 100);
                    }
                    QByteArray headers =
                        offset > 0 ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n";
                    headers += "Content-Type: audio/wav\r\nConnection: close\r\n";
                    if (offset > 0) {
                        headers += "Content-Range: bytes " + QByteArray::number(offset) + '-' +
                                   QByteArray::number(bytes.size() - 1) + '/' +
                                   QByteArray::number(bytes.size()) + "\r\n";
                    }
                    if (chunked) {
                        socket->write(headers + "Transfer-Encoding: chunked\r\n\r\n" +
                                      QByteArray::number(body.size(), 16) + "\r\n" + body + "\r\n0\r\n\r\n");
                    } else {
                        socket->write(headers + "Content-Length: " +
                                      QByteArray::number(bytes.size() - offset) + "\r\n\r\n");
                        if (slow && offset == 0) {
                            const auto prefix = body.size() / 2;
                            socket->write(body.left(prefix));
                            QTimer::singleShot(1500, socket, [&, socket, body, prefix] {
                                sentTail = true;
                                socket->write(body.mid(prefix));
                                socket->disconnectFromHost();
                            });
                            return;
                        }
                        socket->write(body);
                    }
                    sentTail = true;
                    socket->disconnectFromHost();
                });
            }
        });
        if (!check(server.listen(QHostAddress::LocalHost), "Local audio fixture must listen")) {
            return false;
        }
        AudioPlayer audio;
        // 只在测试中绕过 CDN 白名单与物理输出；真实 HTTP、解码、错误与健康检查仍走生产实现。
        // CI 枚举到声卡不代表设备能推进播放，改用解码缓冲输出；硬件消费由音频输出回归覆盖。
        audio.pcmEnabled = false;
        audio.player->setAudioOutput(nullptr);
        audio.outputUnavailable = false;
        audio.recoveryPosition = -1;
        audio.enableDiagnostics(true);
        int measuredSpectra = 0;
        audio.spectrumChanged = [&](const QJsonArray &levels) {
            for (auto value : levels) {
                if (value.toDouble() > .1) {
                    ++measuredSpectra;
                    break;
                }
            }
        };
        audio.enableSpectrum(transientError);
        audio.progressClock.start();
        audio.playbackRequested = true;
        const QUrl source(QString("http://127.0.0.1:%1/tone.wav").arg(server.serverPort()));
        if (managed) {
            audio.startMediaSource(source);
        } else {
            audio.player->setSource(source);
            audio.player->play();
        }
        audio.playbackWatchdog.start();
        if (slow) {
            const bool started = waitFor([&] { return audio.decodedFrames > 0 || sentTail; });
            if (!check(started && audio.decodedFrames > 0 && !sentTail,
                       "Playback must start before the server sends the second half")) {
                return false;
            }
            if (cancel) {
                QElapsedTimer stopping;
                stopping.start();
                audio.control("stop");
                return check(stopping.elapsed() < 1500 && !audio.stream && audio.player->source().isEmpty() &&
                                 !audio.player->isPlaying(),
                             "Stopping during a blocked network read must cancel and release the stream");
            }
            if (jump) {
                audio.control("seek", 10000);
                if (!check(waitFor([&] { return audio.lastDecodedEndMs >= 10000; }) && requests >= 2,
                           "Seeking beyond the cache must request the missing byte range")) {
                    return false;
                }
            }
        }
        if (transientError) {
            if (!check(waitFor([&] { return audio.player->position() > 250; }),
                       "Complete stream must begin playback")) {
                return false;
            }
            // 重放现场的局部 FormatError；错误后的真实输出和结束仍由 FFmpeg 驱动。
            audio.player->errorOccurred(QMediaPlayer::FormatError,
                                        "Invalid data found when processing input");
            if (!check(audio.pendingFailure && audio.error.isEmpty(),
                       "An advancing decoder error must not immediately fail playback")) {
                return false;
            }
        }
        const bool settled =
            waitFor([&] { return audio.ended > 0 || !audio.error.isEmpty(); }, slow ? 18000 : 12000);
        if (percent == 100 || (managed && repair)) {
            const auto ended = audio.ended;
            audio.player->mediaStatusChanged(QMediaPlayer::EndOfMedia);
            bool ok = check(settled && ended == 1 && audio.ended == 1 && audio.error.isEmpty() &&
                                !audio.pendingFailure && !audio.player->isPlaying(),
                            "A complete stream must drain to exactly one clean completion");
            if (transientError) {
                ok &= check(measuredSpectra > 0, "the production decoder supplies real non-silent FFT data "
                                                 "while diagnostics stay enabled");
                audio.enableSpectrum(false);
                ok &= check(audio.player->audioBufferOutput() == audio.decodedOutput.get(),
                            "disabling spectrum preserves decoder diagnostics");
            }
            if (managed) {
                const auto transport = audio.stream->diagnosticState();
                ok &= check(audio.player->error() == QMediaPlayer::NoError &&
                                (jump || audio.decodedFrames == 48000 * seconds),
                            "Managed streams must decode every frame without backend EOF errors");
                ok &= check(transport["mediaReconnects"].toInt() == (percent < 100 ? 1 : 0),
                            "Only interrupted transfers reconnect, without restarting the decoder");
                if (!jump) {
                    // 独立读取缓存，避免改变解码器游标；未知长度的分块流本身不支持 seek。
                    QFile cached(audio.stream->cache.fileName());
                    ok &= check(cached.open(QIODevice::ReadOnly) && cached.readAll() == bytes,
                                "The complete cached byte stream must match the original source exactly");
                }
            }
            return ok;
        }
        const auto position = audio.player->position();
        bool ok =
            check(settled && audio.ended == 0 && !audio.error.isEmpty() && audio.failureRecoverable &&
                      !audio.player->isPlaying() && audio.playbackRequested && position > 0 &&
                      position < audio.player->duration(),
                  "A truncated stream must leave fake playback and request recovery, never skip its tail");
        audio.control("stop");
        ok &= check(audio.error.isEmpty() && !audio.pendingFailure && !audio.failureRecoverable,
                    "Stopping discards all failure state");
        return ok;
    }

    static bool pausedError() {
        AudioPlayer audio;
        audio.defaultOutput = [] { return QAudioDevice(); };
        audio.followDefaultOutput();
        audio.load("https://music.126.net/fixture.wav", false);
        audio.control("pause");
        audio.pendingFailure = true;
        audio.checkPlaybackHealth();
        const bool ok = check(audio.error.isEmpty() && !audio.playbackRequested,
                              "Paused playback and missing outputs must not trigger recovery");
        audio.control("stop");
        return ok;
    }
};

int main(int argc, char **argv) {
    qputenv("QT_MEDIA_BACKEND", "ffmpeg");
    QCoreApplication app(argc, argv);
    // 只保留核心断流路径：完整流、截断恢复、托管重连、分块流、跳转与取消。
    bool ok = AudioPlayerRegression::pausedError();
    ok &= AudioPlayerRegression::stream(100, true);
    ok &= AudioPlayerRegression::stream(50, false);
    ok &= AudioPlayerRegression::stream(100, false, true, true);
    ok &= AudioPlayerRegression::stream(50, false, true);
    ok &= AudioPlayerRegression::stream(50, false, true, false, false);
    ok &= AudioPlayerRegression::stream(100, false, true, false, true, true, true);
    ok &= AudioPlayerRegression::stream(100, false, true, false, true, true, false, true);
    return ok ? 0 : 1;
}
