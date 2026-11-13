#include "../src/AudioPlayer.h"
#include "../src/AppStorage.h"
#include "../src/AppleTransitionPlan.h"
#include "../src/WindowsTransitionPlayer.h"
#include "../src/Host.h"
#include "../src/MusicApi.h"
#include "../src/MusicPlayer.h"
#include "TransitionTestTrack.h"
#include <QCoreApplication>
#include <QDebug>
#include <QElapsedTimer>
#include <QMediaDevices>
#include <QTemporaryDir>
#include <QThread>
#include <QTimer>

namespace {
bool waitFor(const std::function<bool()> &predicate, int timeout = 8000) {
    QElapsedTimer clock;
    clock.start();
    while (!predicate() && clock.elapsed() < timeout) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
        QThread::msleep(2);
    }
    return predicate();
}
int failure(int line) {
    qCritical() << "WASAPI regression failed at line" << line;
    return 1;
}
bool check(bool result, const char *message) {
    if (!result) {
        qCritical() << message;
    }
    return result;
}
}

int main(int argc, char **argv) {
    QCoreApplication application(argc, argv);
    QTemporaryDir directory;
    if (!directory.isValid() || !AppStorage::initializePortable(directory.path()).isEmpty()) {
        return failure(__LINE__);
    }
    {
        AudioPlayer volumeHolder(nullptr, false);
        volumeHolder.control("volume", 0.7);
        const auto borrowed = WindowsTransitionPlayer::borrow(volumeHolder);
        borrowed->setVolume(0.2f);
        if (!check(std::abs(volumeHolder.state()["volume"].toDouble() - 0.7) < 0.001,
                   "Crossfade output gain must not change the user's base volume")) {
            return failure(__LINE__);
        }
    }
    if (QMediaDevices::defaultAudioOutput().isNull()) {
        qInfo("WASAPI integration requires an output endpoint");
        return 77;
    }
    auto settings = AppStorage::settings();
    settings.setValue("panel/apple-smart-transition", "off");
    settings.setValue("panel/audio-exclusive", "off");
    settings.sync();
    const auto a = directory.path() + "/a.wav", b = directory.path() + "/b.wav";
    if (!TransitionTestTrack::writePulseTrack(a, 120) || !TransitionTestTrack::writePulseTrack(b, 124)) {
        return failure(__LINE__);
    }
    AudioPlayer player;
    player.control("volume", 0); // Exercise real device clocks without audible test tones.
    player.enableDiagnostics(true);
    int committed = 0;
    player.appleTransitionCommitted = [&] { ++committed; };
    if (!player.load(QUrl::fromLocalFile(a).toString(), true, false, "local") ||
        !waitFor([&] { return player.state()["playing"].toBool(); })) {
        qCritical() << "WASAPI start failed" << player.state();
        return failure(__LINE__);
    }
    if (!waitFor([&] { return player.diagnosticState()["outputBackend"].toInt() == 3; })) {
        qCritical() << "Smart playback must keep WASAPI output" << player.diagnosticState();
        return failure(__LINE__);
    }
    const auto beforeEnable = player.state()["position"].toLongLong();
    settings.setValue("panel/apple-smart-transition", "on");
    settings.sync();
    if (!player.prepareAppleTransition(QUrl::fromLocalFile(b), true, false, "local")) {
        return failure(__LINE__);
    }
    if (!check(player.state()["position"].toLongLong() >= beforeEnable,
               "Enabling transitions must borrow the active decoder without restarting it")) {
        return failure(__LINE__);
    }
    if (!waitFor([&] { return player.diagnosticState().contains("transitionKind"); })) {
        return failure(__LINE__);
    }
    player.control("pause");
    const auto paused = player.state()["position"].toLongLong();
    QElapsedTimer settle;
    settle.start();
    waitFor([&] { return settle.elapsed() > 220; }, 1000);
    if (!check(!player.state()["playing"].toBool() && committed == 0 &&
                   std::abs(player.state()["position"].toLongLong() - paused) < 60,
               "Paused preparation must not start or commit incoming media")) {
        return failure(__LINE__);
    }
    player.cancelAppleTransition();
    player.control("resume");
    if (!waitFor([&] { return player.state()["playing"].toBool(); })) {
        return failure(__LINE__);
    }
    if (!player.prepareAppleTransition(QUrl::fromLocalFile(b), true, false, "local") ||
        !waitFor([&] { return player.diagnosticState().contains("transitionKind"); })) {
        return failure(__LINE__);
    }
    const auto plan = player.diagnosticState();
    if (!check(plan["transitionKind"].toInt() == int(AppleTransitionPlan::Kind::BeatMatch),
               "Stable beats should produce a beat-matched WASAPI handoff")) {
        return failure(__LINE__);
    }
    player.control("seek", plan["transitionAtMs"].toDouble() - 1700);
    if (!waitFor([&] { return committed > 0; }, 10000)) {
        qCritical() << "WASAPI handoff failed" << player.diagnosticState();
        return failure(__LINE__);
    }
    if (!check(committed == 1 && player.state()["ended"].toInt() == 0 && player.state()["playing"].toBool() &&
                   player.diagnosticState()["nativeTempoPrepared"].toBool() &&
                   std::abs(player.state()["duration"].toLongLong() - 32300) < 3,
               "Handoff must commit once, retain prepared audio, and preserve the original duration")) {
        return failure(__LINE__);
    }
    if (!waitFor([&] { return player.diagnosticState()["nativeRateRestored"].toBool(); }, 4000)) {
        return failure(__LINE__);
    }
    player.control("seek", 15000);
    if (!waitFor([&] { return player.state()["position"].toLongLong() >= 15000; })) {
        return failure(__LINE__);
    }
    if (!check(player.state()["position"].toLongLong() < 15500 && committed == 1,
               "Seeking after the handoff must use original-song coordinates")) {
        return failure(__LINE__);
    }
    player.control("stop");
    if (!check(!player.state()["requested"].toBool() && committed == 1, "Stopping must not commit again")) {
        return failure(__LINE__);
    }
    if (!player.load(QUrl::fromLocalFile(a).toString(), true, false, "local") ||
        !waitFor([&] { return player.state()["playing"].toBool(); })) {
        return failure(__LINE__);
    }
    player.control("stop");
    qInfo("WASAPI transition, pause/cancel, tempo restoration, seek and single-commit checks passed");
    {
        Host host({}, true);
        // Keep credentials isolated during construction, then read preferences from the temporary store.
        host.offline = false;
        host.setProvider("local");
        host.enablePlaybackDiagnostics(true);
        MusicApi api(&host);
        api.provider = "local";
        MusicPlayer music(&host, &api);
        music.volume(0);
        const auto track = [](const QString &path, const QString &id) {
            return QJsonObject{{"kind", "song"},
                               {"provider", "local"},
                               {"id", id},
                               {"title", id},
                               {"path", path},
                               {"format", "wav"},
                               {"url", QUrl::fromLocalFile(path).toString()}};
        };
        const auto first = track(a, "first"), second = track(b, "second");
        int handoffs = 0, selections = 0;
        QObject::connect(&host, &Host::appleTransitionCommitted, &host, [&] { ++handoffs; });
        QObject::connect(&music, &MusicPlayer::trackSelected, &host,
                         [&](const QJsonObject &) { ++selections; });
        QElapsedTimer elapsed;
        elapsed.start();
        QTimer poll;
        QObject::connect(&poll, &QTimer::timeout, &host,
                         [&] { music.tick(elapsed.elapsed() / 1000., true); });
        poll.start(20);
        music.play(first, QJsonArray{first, second});
        if (!check(waitFor([&] { return host.playbackSnapshot().contains("transitionKind"); }),
                   "The local queue must automatically prepare its next track")) {
            return failure(__LINE__);
        }
        host.mediaControl("seek", host.playbackSnapshot()["transitionAtMs"].toDouble() - 1700);
        if (!check(waitFor([&] { return handoffs > 0; }, 10000),
                   "The queue must receive the WASAPI handoff")) {
            return failure(__LINE__);
        }
        if (!check(
                handoffs == 1 && selections == 2 && music.current["id"] == "second" &&
                    music.queue.index() == 1 && !music.loading && !music.failed &&
                    host.mediaState()["playing"].toBool() && host.mediaState()["ended"].toInt() == 0 &&
                    host.mediaState()["position"].toLongLong() > 0,
                "The queue must adopt the already-playing incoming song exactly once without reopening it")) {
            return failure(__LINE__);
        }
        music.setMode("one");
        music.play(first, QJsonArray{first, second});
        if (!check(waitFor([&] { return music.state["playing"].toBool(); }) &&
                       !host.playbackSnapshot().contains("transitionKind"),
                   "Single-track repeat must retain natural playback")) {
            return failure(__LINE__);
        }
        music.stop();
        qInfo("Local queue preloading, single handoff, adopted playback and repeat exclusion checks passed");
    }
    return 0;
}
