#include "MvController.h"
#include "MusicPlayer.h"
#include "ProviderRegistry.h"
#include "AppStorage.h"
#include <QGuiApplication>
#include <QDebug>
#include <limits>
#include <cstdio>
#include <QFile>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QTcpServer>
#include <QTcpSocket>
#include <QThread>
#include <QTemporaryDir>
#include <QVideoFrame>

int main(int argc, char **argv) {
    QGuiApplication application(argc, argv);
    QTemporaryDir storage;
    if (!storage.isValid() || !AppStorage::initializePortable(storage.path()).isEmpty()) {
        return 1;
    }
    Host host(argc > 1 ? QString::fromLocal8Bit(argv[1]) : QString(), true);
    MusicApi api(&host);
    MusicPlayer music(&host, &api);
    QList<MusicApi::Reply> pending;
    int requests = 0;
    auto resolve = [&](const QJsonObject &, MusicApi::Reply reply) {
        ++requests;
        pending.append(std::move(reply));
    };
    bool passed = true;
    QString mvProvider;
    for (const auto &id : ProviderRegistry::instance().ids()) {
        if (ProviderRegistry::instance()
                .descriptor(id)["operations"]
                .toObject()["mv"]
                .toBool()) {
            mvProvider = id;
            break;
        }
    }
    if (mvProvider.isEmpty()) {
        qInfo() << "MV checks skipped: no installed source declares MV support";
        return 0;
    }
    const auto check = [&](bool ok, const char *description) {
        if (!ok) {
            qCritical() << "MV regression:" << description;
            std::fprintf(stderr, "MV regression failed: %s\n", description);
            passed = false;
        }
    };
    auto song = [&mvProvider](const QString &id, const QString &provider = {}) {
        return QJsonObject{{"id", id},
                           {"kind", "song"},
                           {"provider", provider.isEmpty() ? mvProvider : provider},
                           {"title", id}};
    };
    MvController mv(&host, &music, nullptr, resolve);
    music.current = song("1");
    emit music.changed();
    check(!mv.enabled() && requests == 0, "disabled by default, with no video requests");
    mv.setEnabled(true);
    check(requests == 1, "enabling resolves the currently playing song");
    music.current = song("2");
    emit music.changed();
    check(requests == 2, "switching songs resolves the new association");
    const auto loading = mv.status();
    pending[0]({{}, "old request failed", {}});
    check(mv.status() == loading && mv.source().isEmpty(),
          "late old-song response cannot replace current MV");
    pending[1]({QJsonValue(QJsonValue::Null), {}, {}});
    check(mv.status().contains(QStringLiteral("没有关联")),
          "a missing association clears video and reports status");
    mv.retry();
    check(requests == 3, "manual retry fetches fresh metadata and URL");
    mv.setEnabled(false);
    const auto disabled = mv.status();
    pending[2]({{}, "late request", {}});
    check(mv.status() == disabled && mv.source().isEmpty(), "disabling invalidates outstanding work");
    music.current = song("3", "siren");
    mv.setEnabled(true);
    check(requests == 3 && mv.source().isEmpty(), "sources without MV support cannot reuse a stale video");
    music.current = song("4");
    emit music.changed();
    check(requests == 4, "returning to an MV source starts a fresh request");
    ++host.epoch;
    pending[3]({{}, "old account", {}});
    check(!mv.status().contains("old account"), "old-account response is discarded");
    mv.retry();
    pending[4]({QJsonObject{{"id", "99"}, {"url", "file:///private/video.mp4"}}, {}, {}});
    check(mv.source().isEmpty() && mv.status().contains(QStringLiteral("地址无效")),
          "invalid schemes never enter decoder");
    mv.setOpacity(0);
    check(mv.opacity() == .2, "opacity keeps a visible minimum");
    mv.setOpacity(2);
    check(mv.opacity() == 1., "opacity is clamped at full opacity");
    mv.setOpacity(std::numeric_limits<double>::quiet_NaN());
    check(mv.opacity() == 1., "non-finite preferences are rejected");
    check(MvController::videoPosition(2000, -3000, 10000) == 0, "negative offsets clamp at the video start");
    check(MvController::videoPosition(2000, 500, 10000) == 2500, "positive offsets advance the picture");
    check(MvController::videoPosition(12000, 500, 10000) == 10000, "video end is clamped without looping");
    check(MvController::videoPosition(std::numeric_limits<double>::infinity(), 0, 10000) == 0,
          "invalid positions cannot enter the decoder");
    QWindow window;
    mv.setWindow(&window);
    check(window.screen(), "independent window starts on a connected display");
    const auto screenCount = mv.screenLabels().size();
    mv.setScreenIndex(9999);
    check(mv.screenIndex() == 0 && screenCount > 0, "wallpaper display list ignores invalid indices");
    if (!mv.wallpaperSupported()) {
        mv.setWallpaper(true);
        check(!mv.wallpaper() && !mv.wallpaperActive() && !mv.presentationStatus().isEmpty(),
              "unsupported shells keep window mode and explain the unavailable wallpaper feature");
    }
    window.hide();
    mv.setEnabled(false);
    {
        MvController temporary(&host, &music, nullptr, resolve);
        temporary.setEnabled(true);
    }
    pending.last()({{}, "destroyed owner", {}});
    check(music.current["id"] == "4", "closing the video controller leaves the music unchanged");

    // Version selection is explicit, remembered per song and protected from stale list/URL replies.
    host.offline = false;
    host.setPreference("mv-versions", "{}");
    host.setPreference("mv-auto", "off");
    music.current = song("6");
    QList<MusicApi::Reply> versionReplies, sourceReplies;
    QList<QJsonObject> requestedTracks;
    auto versionResolver = [&](const QJsonObject &, MusicApi::Reply reply) {
        versionReplies.append(std::move(reply));
    };
    auto sourceResolver = [&](const QJsonObject &track, MusicApi::Reply reply) {
        requestedTracks.append(track);
        sourceReplies.append(std::move(reply));
    };
    const QJsonArray choices{QJsonObject{{"id", "101"}, {"title", "Original"}, {"associated", true}},
                             QJsonObject{{"id", "102"}, {"title", "Live"}}};
    {
        MvController versions(&host, &music, nullptr, sourceResolver, versionResolver);
        versions.setEnabled(true);
        versionReplies[0]({QJsonObject{{"versions", choices}}, {}, {}});
        check(versions.versionLabels().size() == 2 && !requestedTracks[0].contains("videoID"),
              "an explicit association takes priority over search candidates");
        versions.setVersionIndex(1);
        check(requestedTracks.last()["videoID"] == "102" && versions.versionIndex() == 1,
              "manual selection resolves the chosen MV and updates selection");
        sourceReplies[0]({{}, "stale original", {}});
        check(!versions.status().contains("stale original"), "old version URL response is ignored");
        versionReplies[0]({QJsonObject{{"versions", QJsonArray{}}}, {}, {}});
        check(versions.versionLabels().size() == 2, "old list cannot replace current versions");
        const int count = requestedTracks.size();
        versions.setVersionIndex(999);
        check(requestedTracks.size() == count, "invalid version index is ignored");
        sourceReplies.last()({{}, "restricted video", {}});
        check(versions.versionLabels().size() == 2, "failed version keeps alternatives available");
        versions.setEnabled(false);
        versionReplies.last()({QJsonObject{{"versions", QJsonArray{}}}, {}, {}});
        check(versions.versionLabels().size() == 2, "disabled controller discards late version lists");
    }
    {
        MvController restored(&host, &music, nullptr, sourceResolver, versionResolver);
        restored.setEnabled(true);
        check(requestedTracks.last()["videoID"] == "102", "per-song version survives controller restart");
        music.current = song("7");
        emit music.changed();
        check(!requestedTracks.last().contains("videoID") && restored.versionLabels().isEmpty(),
              "switching songs clears candidates and never inherits another song's version");
        restored.setEnabled(false);
    }

    host.offline = true;
    {
        QList<MusicApi::Reply> lists, sources;
        QList<QJsonObject> tracks;
        music.current = song("8");
        MvController automatic(
            &host, &music, nullptr,
            [&](const QJsonObject &track, MusicApi::Reply reply) {
                tracks.append(track);
                sources.append(std::move(reply));
            },
            [&](const QJsonObject &, MusicApi::Reply reply) { lists.append(std::move(reply)); });
        automatic.setEnabled(true);
        const QJsonArray results{QJsonObject{{"id", "201"}, {"title", "First result"}},
                                 QJsonObject{{"id", "202"}, {"title", "Second result"}}};
        lists[0]({QJsonObject{{"versions", results}}, {}, {}});
        check(tracks.size() == 2 && tracks.last()["videoID"] == "201" && automatic.versionIndex() == 0,
              "without an explicit association the first search result is selected automatically");
        const auto loading = automatic.status();
        sources[0]({QJsonValue(QJsonValue::Null), {}, {}});
        check(automatic.status() == loading,
              "late association lookup cannot overwrite the automatic candidate");
        automatic.setVersionIndex(1);
        const auto count = tracks.size();
        lists.last()({QJsonObject{{"versions", results}}, {}, {}});
        check(tracks.size() == count && tracks.last()["videoID"] == "202",
              "manual version always wins over first-result fallback");
        automatic.setPinned(true);
        automatic.setLocked(true);
        check(automatic.pinned() && automatic.locked(), "pin and lock are independent window controls");
        automatic.openWindow();
        check(automatic.enabled() && !automatic.locked() && !automatic.wallpaper(),
              "player MV entry opens an unlocked window without wallpaper mode");
        automatic.setEnabled(false);
    }
    // Exercise the real decoder and clock synchronization with synthetic video over local HTTP.
    QFile fixture(argc > 2 ? QString::fromLocal8Bit(argv[2]) : QString());
    check(fixture.open(QIODevice::ReadOnly), "synthetic video fixture is readable");
    const auto bytes = QByteArray::fromBase64(
        QJsonDocument::fromJson(fixture.readAll()).object()["base64"].toString().toLatin1());
    QTcpServer server;
    check(server.listen(QHostAddress::LocalHost), "local video fixture server starts");
    QObject::connect(&server, &QTcpServer::newConnection, &server, [&] {
        while (server.hasPendingConnections()) {
            auto socket = server.nextPendingConnection();
            QObject::connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
            QObject::connect(socket, &QTcpSocket::readyRead, socket, [socket, &bytes] {
                auto request = socket->property("request").toByteArray() + socket->readAll();
                socket->setProperty("request", request);
                if (!request.contains("\r\n\r\n")) {
                    return;
                }
                const auto match = QRegularExpression("Range: bytes=(\\d+)-(\\d*)",
                                                      QRegularExpression::CaseInsensitiveOption)
                                       .match(QString::fromLatin1(request));
                const auto start = match.hasMatch() ? match.captured(1).toInt() : 0;
                const auto end = match.captured(2).isEmpty()
                                     ? bytes.size() - 1
                                     : std::min(qsizetype(match.captured(2).toInt()), bytes.size() - 1);
                QByteArray header =
                    match.hasMatch() ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n";
                header += "Content-Type: video/mp4\r\nAccept-Ranges: bytes\r\nConnection: close\r\n";
                if (match.hasMatch()) {
                    header += "Content-Range: bytes " + QByteArray::number(start) + '-' +
                              QByteArray::number(end) + '/' + QByteArray::number(bytes.size()) + "\r\n";
                }
                header += "Content-Length: " + QByteArray::number(end - start + 1) + "\r\n\r\n";
                socket->write(header + bytes.mid(start, end - start + 1));
                socket->disconnectFromHost();
            });
        }
    });
    auto waitFor = [](auto predicate, int timeout = 8000) {
        QElapsedTimer clock;
        clock.start();
        while (!predicate() && clock.elapsed() < timeout) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
            QThread::msleep(10);
        }
        return predicate();
    };
    music.current = song("5");
    music.state = {{"playing", true}, {"position", 0}};
    QVideoSink sink;
    int frames = 0;
    QObject::connect(&sink, &QVideoSink::videoFrameChanged, &sink, [&](const QVideoFrame &frame) {
        if (frame.isValid()) {
            ++frames;
        }
    });
    MvController video(&host, &music, nullptr, [&](const QJsonObject &, MusicApi::Reply reply) {
        reply({QJsonObject{{"id", "test-video"},
                           {"title", "Synthetic PV"},
                           {"resolution", 64},
                           {"url", QString("http://127.0.0.1:%1/sample.mp4").arg(server.serverPort())}},
               {},
               {}});
    });
    video.attachVideo(&sink);
    video.setEnabled(true);
    check(waitFor([&] { return frames > 0 && video.ready(); }),
          "real H.264 frames are decoded from the associated URL");
    music.state["position"] = 2000;
    emit music.changed();
    check(waitFor([&] { return sink.videoFrame().startTime() >= 1800000; }),
          "music seek advances the real video");
    music.state["playing"] = false;
    music.state["position"] = 2200;
    emit music.changed();
    QElapsedTimer settle;
    settle.start();
    waitFor([&] { return settle.elapsed() >= 400; }, 1000);
    const int pausedFrames = frames;
    settle.restart();
    waitFor([&] { return settle.elapsed() >= 400; }, 1000);
    check(frames == pausedFrames, "paused music freezes video instead of leaving it running");
    music.state["playing"] = true;
    emit music.changed();
    check(waitFor([&] { return frames > pausedFrames; }, 3000), "resuming music resumes video");
    music.state["buffering"] = true;
    emit music.changed();
    settle.restart();
    waitFor([&] { return settle.elapsed() >= 400; }, 1000);
    const int stalledFrames = frames;
    settle.restart();
    waitFor([&] { return settle.elapsed() >= 400; }, 1000);
    check(frames == stalledFrames, "buffering music freezes video until audio can resume");
    if (argc > 3 && QString::fromLocal8Bit(argv[3]) == "--wallpaper" && video.wallpaperSupported()) {
        QWindow desktopWindow;
        desktopWindow.setFlags(Qt::Tool | Qt::FramelessWindowHint | Qt::WindowDoesNotAcceptFocus |
                               Qt::WindowTransparentForInput);
        QVideoSink desktopSink;
        video.attachWallpaperVideo(&desktopSink);
        video.setWallpaperWindow(&desktopWindow);
        music.state["buffering"] = false;
        music.state["position"] = 1000;
        emit music.changed();
        const auto source = video.source();
        video.setWallpaper(true);
        check(video.wallpaperActive() && desktopWindow.parent() &&
                  waitFor([&] { return desktopSink.videoFrame().isValid(); }),
              "desktop mode attaches behind Explorer and receives real decoded frames");
        video.setWallpaper(false);
        check(!video.wallpaperActive() && !desktopWindow.parent() && video.source() == source &&
                  waitFor([&] { return sink.videoFrame().isValid(); }),
              "returning to window mode restores the preview sink without restarting music or the MV");
    }
    video.exitWallpaper();
    check(video.source().isEmpty() && music.state["playing"].toBool(),
          "closing video releases its source and leaves audio playing");
    music.state = {{"playing", false}, {"position", 0}};
    // Exercise both ends of QJsonObject's key ordering when the saved-offset limit is reached.
    host.offline = false;
    for (const auto &id : {QString("100"), QString("9000")}) {
        QJsonObject savedOffsets;
        for (int i = 0; i < 256; ++i) {
            savedOffsets[QString::number(2000 + i)] = 1000;
        }
        host.setPreference("mv-offsets",
                           QString::fromUtf8(QJsonDocument(savedOffsets).toJson(QJsonDocument::Compact)));
        const auto saved = [&] {
            return QJsonDocument::fromJson(host.preference("mv-offsets").toUtf8()).object();
        };
        const auto offsetResolver = [&](const QJsonObject &, MusicApi::Reply reply) {
            reply({QJsonObject{{"id", id},
                               {"url", QString("http://127.0.0.1:%1/sample.mp4").arg(server.serverPort())}},
                   {},
                   {}});
        };
        {
            MvController offsets(&host, &music, nullptr, offsetResolver);
            offsets.setEnabled(true);
            offsets.adjustOffset(500);
            check(offsets.offset() == 500 && saved().size() == 256 && saved().value(id).toInt() == 500,
                  "full offset storage preserves and persists the active MV while evicting another entry");
            offsets.adjustOffset(500);
            check(offsets.offset() == 1000 && saved().value(id).toInt() == 1000 && saved().size() == 256,
                  "repeated adjustments accumulate after offset storage reaches its limit");
            offsets.setEnabled(false);
        }
        {
            MvController restored(&host, &music, nullptr, offsetResolver);
            restored.setEnabled(true);
            check(restored.offset() == 1000, "active MV offset is restored from full persisted storage");
            restored.resetOffset();
            check(restored.offset() == 0 && saved().contains(id) && saved().value(id).toInt() == 0 &&
                      saved().size() == 256,
                  "resetting an offset keeps the current entry within the storage limit");
            restored.setEnabled(false);
        }
    }
    host.setPreference("mv-offsets", "{}");
    host.offline = true;
    QVideoSink pausedSink;
    MvController paused(&host, &music, nullptr, [&](const QJsonObject &, MusicApi::Reply reply) {
        reply({QJsonObject{{"id", "paused"},
                           {"url", QString("http://127.0.0.1:%1/sample.mp4").arg(server.serverPort())}},
               {},
               {}});
    });
    paused.attachVideo(&pausedSink);
    paused.openWindow();
    check(waitFor([&] { return pausedSink.videoFrame().isValid(); }),
          "opening MV while music is paused displays its first frame");
    paused.setEnabled(false);

    // Default resolver must bind the controller's MusicApi to the current track's provider.
    if (!mvProvider.isEmpty()) {
        Host routeHost(host.root, true);
        MusicApi routeApi(&routeHost);
        MusicPlayer routeMusic(&routeHost, &routeApi);
        routeMusic.current = song("route", mvProvider);
        QStringList routes;
        routeHost.fixture = [&](QString route, QJsonObject) {
            routes.append(route);
            return QJsonObject{{"body", QJsonObject{{"code", 200}, {"value", QJsonValue::Null}}}};
        };
        MvController routed(&routeHost, &routeMusic);
        routed.setEnabled(true);
        check(waitFor([&] { return routes.contains("/native/" + mvProvider + "/mv"); }),
              "default MV resolver reaches the current provider");
        routed.setEnabled(false);
        routeHost.shutdown();
    }
    host.shutdown();
    return passed ? 0 : 1;
}
