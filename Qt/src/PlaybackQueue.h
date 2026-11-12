#pragma once
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QString>

class MusicApi;

/**
 * 播放队列的唯一状态源。
 * 负责曲目顺序、当前索引、入队/移除/切歌、元数据补全和会话存档。
 * 队列只保存完整曲目；缺少元数据的 ID 先补全再发布，界面不会出现占位歌曲。
 */
class PlaybackQueue : public QObject {
    Q_OBJECT
  public:
    explicit PlaybackQueue(MusicApi *api, QObject *parent = nullptr);

    static QString identity(const QJsonObject &track);

    const QJsonArray &items() const;
    int size() const;
    bool isEmpty() const;
    QJsonObject at(int row) const;
    int index() const;
    QJsonObject current() const;
    int indexOf(const QJsonObject &track) const;
    int indexOfId(const QString &id) const;
    bool isLoading() const;

    /// 用完整曲目替换队列；selected 非空时按歌曲身份选中。
    void replace(const QJsonArray &values, const QJsonObject &selected = {});
    /// 同步服务端快照；调用方负责通知界面，避免中间状态被提前绘制。
    void syncSnapshot(const QJsonArray &values, int row);
    void select(int row);
    /// 保持已选中的同一首歌，否则查找或追加到队尾。
    void selectTrack(const QJsonObject &track);
    bool enqueue(const QJsonObject &track, bool next = false);
    bool remove(int row);
    /// 用同一首歌的新元数据刷新当前项，身份不一致时忽略。
    void updateCurrent(const QJsonObject &track);
    void clearUpcoming(const QJsonObject &current);
    void clear();
    void setShuffle(bool enabled, bool reshuffle = true);
    void shuffle();
    // 预选下一首，实际切换时由调用方提交；不提前改索引或播放历史。
    int nextIndex(const QString &mode) const;
    /// 按可见顺序切换，随机模式使用已经打乱的队列。-1 表示顺序播放已经结束。
    int navigate(int direction, const QString &mode);

    /// 按 ID 顺序补全缺失元数据后发布；ids 为空时直接使用 known。
    void load(const QJsonArray &ids, const QJsonArray &known);
    /// 恢复会话；只有完整曲目会立即进入队列，占位 ID 在后台补全。
    void restore(const QJsonArray &saved, int savedIndex, bool hydrate);

    QJsonArray toJson() const;

  signals:
    void changed();

  private:
    void cancelLoad();
    void publish(const QJsonArray &values, const QString &selectedKey);
    void publishResolved();
    void fetchNext();
    QJsonArray orderedResolved() const;
    void moveTo(int row);
    void orderShuffleIds(const QJsonArray &known);

    MusicApi *m_api;
    QJsonArray m_items;
    QJsonArray m_ids;
    QJsonArray m_missing;
    QHash<QString, QJsonObject> m_resolved;
    QString m_provider;
    QString m_selectedKey;
    int m_index = -1;
    quint64 m_generation = 0;
    bool m_loading = false;
    bool m_shuffle = false;
};
