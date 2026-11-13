#include "WindowsTransitionPlayer.h"
#include "AppleTransitionAudio.h"
#include "AudioPlayer.h"
#include "AppStorage.h"
#include <QMediaDevices>
#include <cmath>

WindowsTransitionPlayer::WindowsTransitionPlayer(AudioPlayer *current) {
    if (current) {
        audio = current;
        paused = !audio->playbackRequested;
    } else {
        ownedAudio = std::make_unique<AudioPlayer>(nullptr, false);
        audio = ownedAudio.get();
    }
    startTimer.setTimerType(Qt::PreciseTimer);
    startTimer.setInterval(1);
    QObject::connect(&startTimer, &QTimer::timeout, &startTimer, [this] {
        if (!outgoing || !outgoing->isPlaying()) {
            startTimer.stop();
            outgoing = nullptr;
            return;
        }
        if (outgoing->playbackOffsetFrom(outgoingCue) >= 0) {
            setPaused(false);
        }
    });
    if (ownedAudio) {
        audio->spectrumChanged = [this](QJsonArray levels) {
            if (spectrumChanged) {
                spectrumChanged(levels);
            }
        };
        audio->diagnosticEvent = [this](const QString &event, const QJsonObject &values) {
            if (diagnosticEvent) {
                diagnosticEvent(event, values);
            }
        };
    }
}
WindowsTransitionPlayer::~WindowsTransitionPlayer() {
    startTimer.stop();
}
std::unique_ptr<WindowsTransitionPlayer> WindowsTransitionPlayer::borrow(AudioPlayer &current) {
    return std::unique_ptr<WindowsTransitionPlayer>(new WindowsTransitionPlayer(&current));
}

std::unique_ptr<WindowsTransitionPlayer>
WindowsTransitionPlayer::open(const QUrl &source, std::shared_ptr<const AppleTransitionAudio> prepared,
                              QString provider, bool alternative) {
    auto result = std::unique_ptr<WindowsTransitionPlayer>(new WindowsTransitionPlayer);
    result->prepared = std::move(prepared);
    const auto url = result->prepared ? result->prepared->playbackSource() : source;
    if (!result->audio->load(url.toString(QUrl::FullyEncoded), url.isLocalFile(), alternative, provider, 0,
                             true)) {
        return {};
    }
    return result;
}

WindowsTransitionPlayer::Status WindowsTransitionPlayer::status() const {
    const auto state = audio->state();
    if (!state["error"].toString().isEmpty() || audio->player->mediaStatus() == QMediaPlayer::InvalidMedia) {
        return Status::Failed;
    }
    if (state["ended"].toInt() > 0) {
        return Status::Ended;
    }
    const auto media = audio->player->mediaStatus();
    return media == QMediaPlayer::LoadedMedia || media == QMediaPlayer::BufferedMedia ||
                   media == QMediaPlayer::BufferingMedia || media == QMediaPlayer::EndOfMedia
               ? Status::Ready
               : Status::Loading;
}
bool WindowsTransitionPlayer::isPlaying() const {
    return !paused && audio->state()["playing"].toBool();
}
bool WindowsTransitionPlayer::isPausedAtEnd() const {
    return status() == Status::Ended;
}
bool WindowsTransitionPlayer::isSeeking() const {
    return audio->recoveryPosition >= 0;
}
bool WindowsTransitionPlayer::isSeekable() const {
    return audio->state()["seekable"].toBool();
}
double WindowsTransitionPlayer::toPlayback(double ms) const {
    return prepared ? prepared->playbackMs(ms) : ms;
}
double WindowsTransitionPlayer::toSource(double ms) const {
    return prepared ? prepared->sourceMs(ms) : ms;
}
qint64 WindowsTransitionPlayer::position() const {
    return qRound64(toSource(audio->playbackPosition()));
}
qint64 WindowsTransitionPlayer::duration() const {
    return qRound64(toSource(audio->player->duration()));
}
double WindowsTransitionPlayer::playbackOffsetFrom(qint64 ms) const {
    return audio->playbackPosition() - toPlayback(ms);
}
void WindowsTransitionPlayer::seek(qint64 ms) {
    setPaused(true);
    prerolled = false;
    audio->control("seek", toPlayback(ms));
}
void WindowsTransitionPlayer::setPaused(bool value) {
    startTimer.stop();
    outgoing = nullptr;
    if (paused == value && !prerolled) {
        return;
    }
    paused = value;
    prerolled = false;
    audio->control(value ? "pause" : "resume");
}
void WindowsTransitionPlayer::setVolume(float value) {
    // A borrowed session shares the user's volume holder; fade only its PCM output gain.
    if (isBorrowed()) {
        audio->pcm.setVolume(value);
    } else {
        audio->control("volume", value);
    }
}
void WindowsTransitionPlayer::setOutputPolicy(AudioOutputFormat::Policy policy) {
    audio->setOutputPolicy(policy);
}
void WindowsTransitionPlayer::enableDiagnostics(bool enabled) {
    audio->enableDiagnostics(enabled);
}
void WindowsTransitionPlayer::enableSpectrum(bool enabled) {
    audio->enableSpectrum(enabled);
}
WindowsTransitionPlayer::TransitionOutput WindowsTransitionPlayer::transitionOutput() {
    const auto backend = qEnvironmentVariable("QT_MEDIA_BACKEND");
    if (!backend.isEmpty() && backend != "ffmpeg") {
        return TransitionOutput::Unsupported;
    }
    return QMediaDevices::defaultAudioOutput().isNull() ||
                   AppStorage::settings().value("panel/audio-exclusive").toString() == "on"
               ? TransitionOutput::Unsupported
               : TransitionOutput::Wired;
}
bool WindowsTransitionPlayer::preroll() {
    if (status() != Status::Ready || !paused) {
        return false;
    }
    prerolled = true;
    audio->playbackRequested = true;
    audio->pcm.pause(true);
    audio->player->play();
    return true;
}
bool WindowsTransitionPlayer::isPrerolled() const {
    return prerolled && status() == Status::Ready && audio->pcm.active() &&
           audio->pcm.snapshot()["outputBufferMs"].toDouble() >= 20;
}
bool WindowsTransitionPlayer::synchronizeWith(const WindowsTransitionPlayer &current, qint64 cue,
                                              qint64 incomingMs) {
    const auto lead = -current.playbackOffsetFrom(cue);
    if (!isPrerolled() || !current.isPlaying() || lead < 55 || lead > 550 ||
        std::abs(playbackOffsetFrom(incomingMs)) > 40) {
        return false;
    }
    outgoing = &current;
    outgoingCue = cue;
    startTimer.start();
    return true;
}
void WindowsTransitionPlayer::completeTransition() {
    startTimer.stop();
    outgoing = nullptr;
}
bool WindowsTransitionPlayer::takeTempoRestored() {
    const bool restored = prepared && isPlaying() && position() >= prepared->restoredAtMs();
    const bool changed = restored && !tempoWasRestored;
    tempoWasRestored = restored;
    return changed;
}
QJsonObject WindowsTransitionPlayer::diagnosticState() const {
    auto values = ownedAudio ? audio->diagnosticState() : audio->pcm.snapshot();
    const auto playback = audio->playbackPosition();
    const auto ramp = prepared ? prepared->rampProgress(playback) : 0;
    values["nativePlayingRate"] = isPlaying() ? 1.0 : 0.0;
    values["nativeRenderedTempo"] = prepared ? prepared->tempo(playback) : 1.0;
    values["nativeTempoPrepared"] = prepared != nullptr;
    values["nativeRateRestoring"] = prepared && ramp > 0 && ramp < 1;
    values["nativeRateRestored"] = prepared && ramp >= 1;
    values["nativeRateRestoreWrites"] = 0;
    values["nativeRateRestoreCueMs"] = prepared ? prepared->restoredAtMs() : -1.0;
    values["nativeRateRestoreProgress"] = ramp;
    return values;
}
