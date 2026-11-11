#pragma once
#include <QtTypes>
#include <memory>

class QJsonObject;
class QUrl;

// AVPlayer 独占当前曲目的播放时钟；所有接口从播放服务线程调用。
class AppleAudioPlayer {
  public:
    enum class Status { Loading, Ready, Ended, Failed };

    static std::unique_ptr<AppleAudioPlayer> open(const QUrl &url);
    ~AppleAudioPlayer();
    Status status() const;
    bool isPlaying() const;
    bool isSeeking() const;
    bool isSeekable() const;
    QJsonObject diagnosticState() const;
    qint64 duration() const;
    qint64 position() const;
    void seek(qint64 positionMs);
    void setPaused(bool paused);
    void setVolume(float volume);

  private:
    AppleAudioPlayer();
    struct Session;
    std::unique_ptr<Session> session;
};
