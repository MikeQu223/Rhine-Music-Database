#pragma once
#include "AudioOutputFormat.h"
#include <QJsonArray>
#include <QJsonObject>
#include <QTimer>
#include <QUrl>
#include <functional>
#include <memory>

class AudioPlayer;
class AppleTransitionAudio;

// A Qt decoder and existing PCM/WASAPI output, with preroll and source-clock mapping.
class WindowsTransitionPlayer {
  public:
    enum class Status { Loading, Ready, Ended, Failed };
    enum class TransitionOutput { Unsupported, BuiltIn, Bluetooth, Wired };
    static std::unique_ptr<WindowsTransitionPlayer>
    open(const QUrl &source, std::shared_ptr<const AppleTransitionAudio> prepared = {}, QString provider = {},
         bool alternative = false);
    static std::unique_ptr<WindowsTransitionPlayer> borrow(AudioPlayer &current);
    bool isBorrowed() const {
        return !ownedAudio;
    }
    ~WindowsTransitionPlayer();
    Status status() const;
    bool isPlaying() const;
    bool isPausedAtEnd() const;
    bool isSeeking() const;
    bool isSeekable() const;
    QJsonObject diagnosticState() const;
    qint64 duration() const;
    qint64 position() const;
    double playbackOffsetFrom(qint64 sourceMs) const;
    void seek(qint64 sourceMs);
    void setPaused(bool paused);
    void setVolume(float volume);
    void setOutputPolicy(AudioOutputFormat::Policy policy);
    void enableDiagnostics(bool enabled);
    void enableSpectrum(bool enabled);
    std::function<void(QJsonArray)> spectrumChanged;
    std::function<void(const QString &, const QJsonObject &)> diagnosticEvent;
    static TransitionOutput transitionOutput();
    bool preroll();
    bool isPrerolled() const;
    bool synchronizeWith(const WindowsTransitionPlayer &outgoing, qint64 outgoingMs, qint64 incomingMs);
    void completeTransition();
    bool takeTempoRestored();

  private:
    explicit WindowsTransitionPlayer(AudioPlayer *current = nullptr);
    double toPlayback(double sourceMs) const;
    double toSource(double playbackMs) const;
    std::shared_ptr<const AppleTransitionAudio> prepared;
    std::unique_ptr<AudioPlayer> ownedAudio;
    AudioPlayer *audio = nullptr;
    QTimer startTimer;
    const WindowsTransitionPlayer *outgoing = nullptr;
    qint64 outgoingCue = 0;
    bool paused = true, prerolled = false, tempoWasRestored = false;
};
