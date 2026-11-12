#pragma once
#include "LyricsController.h"
#include "PlaybackQueue.h"
#include <optional>

class MusicPlayer : public QObject {
    Q_OBJECT
  public:
    MusicPlayer(Host *host, MusicApi *api, QObject *parent = nullptr);
    bool enqueue(const QJsonObject &track, bool next = false);
    void play(QJsonObject track, std::optional<QJsonArray> source = std::nullopt,
              std::optional<int> queueIndex = std::nullopt, bool preview = false,
              std::optional<QJsonObject> resume = std::nullopt);
    /// 按完整 ID 顺序补全队列；直接调用时同步补全，独立播放服务运行时交给服务。
    void loadQueue(const QJsonArray &ids, const QJsonArray &known);
    QJsonObject sessionState() const;
    void restoreSessionState(const QJsonObject &saved);
    void tick(double time, bool force = false);
    void toggle();
    void setPaused(bool paused);
    void seek(double fraction);
    void volume(double value);
    void next(int direction = 1, bool ended = false);
    void remove(int index);
    void clearUpcoming();
    void stop();
    void setQuality(const QString &value);
    void refreshQualityPreference();
    void setMode(const QString &value);
    void setAlternative(bool enabled);
    void clearHistory();
    void clearCaches();
    QJsonObject playbackSnapshot() const;
    void applyPlaybackSnapshot();
    static QVector<QPair<QString, QString>> qualityOptions(const QString &provider);
    static QString localQuality(const QJsonObject &track);
    static QString sourceQuality(const QString &provider, const QJsonObject &audio, bool trial = false);
    QString actualQuality;
    QJsonObject localCovers;
    LyricsController lyrics;
    PlaybackQueue queue;
    QJsonArray history;
    QJsonObject current;
    QJsonObject state;
    bool loading = false;
    bool failed = false;
    bool trial = false;
    QString coverImage;
    QString mode = "all";
    QString status;
    QString quality;
    bool alternative = false;
    bool previewRequested = false;
    std::function<void()> onEnd;

  signals:
    void changed();
    void trackSelected(QJsonObject track);

  private:
    Host *m_host;
    MusicApi *m_api;
    quint64 m_generation = 0;
    qint64 m_endSerial = 0;
    double m_lastPoll = -1;
    std::optional<double> m_resumePosition;
    bool m_resumePaused = false;
    bool m_restoringSession = false;
    int m_recoveryAttempts = 0;
    int m_selectionSerial = 0;
    bool m_receivedSnapshot = false;
    QString m_remoteCover;
    bool remoteCommand(const QString &method, QJsonObject arguments = {});
    void recoverPlayback();
    MusicApi::Valid valid(quint64 generation);
    void prepare(QJsonObject track, quint64 generation, bool reload = false, bool alreadyPlaying = false,
                 const QJsonObject &adoptedAudio = {});
    QString effectivePlaybackQuality() const;
    void finishOnlinePlayback(const QJsonObject &track, const QJsonObject &audio);
    void fail(QString error);
#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)
    bool m_appleTransitionsEnabled = false;
    bool m_appleTransitionAttempted = false;
    int m_appleNextIndex = -1;
    quint64 m_appleTransitionRevision = 0;
    int m_appleTransitionEpoch = -1;
    QJsonObject m_appleNextAudio;
    QString m_appleOutgoingKey;
    QString m_appleIncomingKey;
    void prepareAppleTransition();
    void invalidateAppleTransition(bool keepSelection = false);
    void commitAppleTransition();
#endif
};
