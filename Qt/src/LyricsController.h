#pragma once
#include "MusicApi.h"
#include <QHash>
#include <map>
#include <memory>

class LyricsController : public QObject {
    Q_OBJECT
  public:
    explicit LyricsController(Host *host, QObject *parent = nullptr);
    void clear();
    void clearCache();
    void load(const QJsonObject &track, bool retry = false);
    void matchCover(const QJsonObject &track);
    void selectLocalSource(const QJsonObject &track, const QString &source);
    QString localSource = "auto";
    void sync(double positionMs);
    void adjustOffset(double deltaMs);
    void resetOffset();
    void applyGlobalOffset();
    QJsonObject playbackSnapshot() const;
    void applyPlaybackSnapshot(const QJsonObject &snapshot);
    double globalOffsetMs() const {
        return m_globalOffsetMs;
    }
    const QJsonObject &document() const {
        return m_document;
    }
    QString status = "idle";
    QString message;
    QString currentKey;
    int index = -1;
    double offsetMs = 0;
    double positionMs = 0;
    static bool validDocument(const QJsonObject &document);
    static bool sameRecording(const QJsonObject &track, const QJsonObject &candidate);
    static QString trackKey(const QJsonObject &track);
    static int activeLineIndex(const QJsonObject &document, double positionMs, double offsetMs = 0);

  signals:
    void changed();
    void coverMatched(QString key, QString url);

  private:
    struct Load {
        quint64 generation = 0;
        QJsonObject track;
        QJsonObject native;
        bool networkFailed = false;
        int provider = 0;
        QStringList queries;
        int query = 0;
        QJsonArray candidates;
        int candidate = 0;
        bool needsLyrics = true;
        bool needsCover = false;
        QString lyricSource;
        QStringList coverRequests;
    };
    using Pending = std::shared_ptr<Load>;
    Host *m_host;
    QStringList m_providers;
    std::map<QString, std::unique_ptr<MusicApi>> m_apis;
    quint64 m_generation = 0;
    double m_globalOffsetMs = 0;
    QHash<QString, qint64> m_lyricBlockedUntil;
    QHash<QString, qint64> m_lastLyricRequest;
    QHash<QString, qint64> m_lyricsRetryAfter;
    QJsonObject m_document;
    QVector<double> m_starts;
    QJsonArray m_cache;
    QJsonObject m_localSources;
    bool remoteCommand(const QString &method, QJsonObject arguments = {});
    MusicApi &api(const QString &provider);
    MusicApi::Valid valid(const Pending &pending);
    void supplement(const Pending &pending);
    void loadLocal(const QJsonObject &track, const Pending &pending);
    void search(const Pending &pending);
    void fetchCandidate(const Pending &pending);
    void loadCandidateCover(const Pending &pending, const QJsonObject &candidate, const QString &provider);
    void tryCover(const Pending &pending, const QString &url);
    void finish(const Pending &pending);
    void accept(QJsonObject document, const QJsonObject &track);
    void persist();
};
