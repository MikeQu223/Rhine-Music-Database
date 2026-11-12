#pragma once
#include <QtTypes>
#include <memory>

class QJsonObject;
class QUrl;
class AppleTransitionAudio;

// AVPlayer 独占当前曲目的播放时钟；所有接口从播放服务线程调用。
class AppleAudioPlayer {
  public:
    enum class Status { Loading, Ready, Ended, Failed };
    enum class TransitionOutput { Unsupported, BuiltIn, Bluetooth, Wired };
    static std::unique_ptr<AppleAudioPlayer>
    open(const QUrl &url, std::shared_ptr<const AppleTransitionAudio> transitionAudio = {});
    ~AppleAudioPlayer();
    Status status() const;
    bool isPlaying() const;
    bool isPausedAtEnd() const;
    bool isSeeking() const;
    bool isSeekable() const;
    QJsonObject diagnosticState() const;
    qint64 duration() const;
    qint64 position() const;
    double playbackOffsetFrom(qint64 sourceMs) const;
    void seek(qint64 positionMs);
    void setPaused(bool paused);
    void setVolume(float volume);
    static TransitionOutput transitionOutput();
    bool preroll();
    bool isPrerolled() const;
    bool synchronizeWith(const AppleAudioPlayer &outgoing, qint64 outgoingMs, qint64 incomingMs);
    void completeTransition();
    bool takeTempoRestored();

  private:
    AppleAudioPlayer();
    struct Session;
    std::unique_ptr<Session> session;
};
