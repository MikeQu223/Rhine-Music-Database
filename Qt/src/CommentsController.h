#pragma once
#include "MusicApi.h"
#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QStringList>
#include <QVector>

/**
 * 歌曲评论的只读数据源。
 * 网易云使用原生歌曲 ID；塞壬唱片复用歌词的搜索与录音校验，再读取对应网易云评论。
 */
class CommentsController : public QObject {
    Q_OBJECT
  public:
    explicit CommentsController(Host *host, QObject *parent = nullptr);
    void clear();
    void load(const QJsonObject &track, bool retry = false);
    void refresh();
    void loadMore();
    void setSort(const QString &value);
    void toggleExpanded(const QString &commentId);
    void toggleReplies(const QString &commentId);
    void loadMoreReplies(const QString &commentId);
    void ensureAvatar(const QString &url);
    QString avatar(const QString &url) const;
    QJsonObject state() const;

    static QString trackKey(const QJsonObject &track);
    static QString relativeTime(double milliseconds);
    static QString compactCount(int value);

    QString status = "idle";
    QString message;
    QString sort = "hot";
    QString sourceLabel;
    QString trackName;
    int total = 0;
    bool hasMore = false;
    bool loadingMore = false;
    QVector<QJsonObject> items;

  signals:
    void changed();

  private:
    Host *m_host;
    MusicApi m_api;
    QString m_trackKey;
    QString m_trackProvider;
    QString m_targetID;
    QString m_cursor;
    int m_pages = 0;
    quint64 m_generation = 0;
    QJsonObject m_track;
    QHash<QString, QString> m_matches;
    QSet<QString> m_avatarRequests;
    QHash<QString, QString> m_avatarKeys;

    MusicApi::Valid valid(quint64 generation);
    void resetItems();
    void resolveSiren(quint64 generation);
    void searchSiren(quint64 generation, const QStringList &queries, int query);
    void fetchPage(quint64 generation, bool first);
    void applyPage(const QJsonObject &body, bool first);
    void fetchFloor(quint64 generation, const QString &commentId, bool first);
    void applyFloor(const QString &commentId, const QJsonObject &body, bool first);
    void failFirstPage(const QString &error);
    int indexOf(const QString &commentId) const;
    QJsonObject normalizeComment(const QJsonObject &raw) const;
    QJsonObject normalizeReply(const QJsonObject &raw, bool nested) const;
};
