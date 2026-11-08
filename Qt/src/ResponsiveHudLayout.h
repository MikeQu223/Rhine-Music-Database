#pragma once
#include "ResponsiveHudCanvas.h"
#include "SongDetailCard.h"
#include "CollectionDetailCard.h"
#include "DiscoverMusicCard.h"
#include "ResponsiveHudContent.h"
#include "PlayerBar.h"
#include "PlaybackQueueCard.h"
#include "SettingsCard.h"
#include "UiMotion.h"
#include <optional>

// 宽屏不经过移动布局；共享卡片模型与已有路由是两个布局的唯一业务输入。
class ResponsiveHudLayout {
  public:
    static constexpr double BottomGestureInset = 34;
    static constexpr double SourceWidth = 1920;
    void resize(double stageWidth);
    bool compact() const {
        return m_compact;
    }
    double sourceWidth(double actual) const {
        return m_compact ? SourceWidth : actual;
    }
    void setPlayer(const PlayerBar::State &v) {
        m_player = v;
    }
    void setQueue(const PlaybackQueueCard::Model &v) {
        m_queue = v;
    }
    void setSong(const SongDetailCard::Model &v) {
        m_song = v;
    }
    void setCollection(const CollectionDetailCard::Model &v) {
        m_collection = v;
    }
    void setDiscover(const DiscoverMusicCard::Model &v) {
        m_discover = v;
    }
    void setSettings(const SettingsCard::Model &v) {
        m_settings = v;
    }
    QPair<int, int> resultWindow(int count, bool search, bool gallery, bool liked) const;
    QVector<int> discoverVisibleIndices(const DiscoverMusicCard::Model &model) const;
    void setAuxiliary(QVector<ResponsiveHudContent::Item> items) {
        m_auxiliary = std::move(items);
    }
    void setSettingsCustom(QString key, QVector<ResponsiveHudContent::Item> items) {
        m_settingsCustom[key] = std::move(items);
    }
    void prepare(const QString &scope, bool home);
    void arrange(QJsonArray &commands, QJsonArray &hits, const QJsonObject &source, const QString &scope,
                 Glyphs &glyphs);
    QJsonObject state(QJsonObject source) const;
    bool scroll(double distance);
    bool nearEnd() const;
    bool animating(double time) const;
    double tabIndicator(const QString &group, double target);
    // 主界面滚动结束后把固定在第二行的选中项交给音乐层应用。
    int takeArchiveSelection() {
        const int value = m_archiveSelection;
        m_archiveSelection = -1;
        return value;
    }
    void setMotion(double time, bool reduced) {
        m_time = time;
        m_reduced = reduced;
    }
    bool handleAction(const QString &action);

  private:
    bool m_compact = false;
    bool m_queueModesExpanded = false;
    bool m_savedOverview = true;
    bool m_songOptionsExpanded = false;
    bool m_lyricsPage = false;
    bool m_followLyrics = true;
    // 主界面 tab 槽：选中项固定在第二行，滚动时整列带阻尼移动。
    static constexpr double ArchiveRowHeight = 48.;
    bool m_archiveActive = false;
    int m_archiveCount = 0;
    double m_archiveOffset = 0;
    bool m_archiveDragging = false;
    bool m_archiveReleaseRequested = false;
    double m_archiveLastScroll = 0;
    std::optional<UiMotion::ReelCurve> m_archiveCurve;
    struct Indicator {
        double from = 0;
        double target = 0;
        double start = -1;
    };
    QHash<QString, Indicator> m_indicators;
    // 列表顶部在舞台坐标中的位置，供触摸手势判断从哪块区域开始滚动。
    double m_archiveListY = 0;
    int m_archiveSelection = -1;
    QString m_archiveKey;
    int m_archiveSelected = -1;
    double m_unit = 1;
    double m_height = 852;
    double m_scroll = 0;
    double m_maximum = 0;
    QString m_scope;
    bool m_scopeChanged = false;
    QJsonObject m_fields;
    // 歌词排版缓存：文档或可用宽度变化时才重新换行。
    struct LyricRow {
        double top = 0;
        QStringList text;
        QStringList translation;
    };
    QJsonObject m_lyricDocument;
    QVector<LyricRow> m_lyricRows;
    double m_lyricContentHeight = 0;
    // 复用的歌词滚动：与桌面歌词面板相同的曲线，不逐帧重排。
    double m_time = 0;
    bool m_reduced = false;
    double m_lyricScroll = 0;
    std::optional<double> m_lyricTarget;
    std::optional<UiMotion::ReelCurve> m_lyricCurve;
    PlayerBar::State m_player;
    PlaybackQueueCard::Model m_queue;
    std::optional<SongDetailCard::Model> m_song;
    std::optional<CollectionDetailCard::Model> m_collection;
    std::optional<DiscoverMusicCard::Model> m_discover;
    std::optional<SettingsCard::Model> m_settings;
    QVector<ResponsiveHudContent::Item> m_auxiliary;
    QHash<QString, QVector<ResponsiveHudContent::Item>> m_settingsCustom;
    void player(ResponsiveHudCanvas &c, bool immersive, const QString &active);
    void progressRow(ResponsiveHudCanvas &c, double y, bool current, const QJsonObject &source,
                     QString idleDuration);
    void transportRow(ResponsiveHudCanvas &c, double y, bool current);
    void volumeRow(ResponsiveHudCanvas &c, double y);
    void utilityRow(ResponsiveHudCanvas &c, double y, bool current);
    void optionsSheet(ResponsiveHudCanvas &c, const QJsonObject &source);
    double archive(ResponsiveHudCanvas &c, const QJsonObject &source);
    double archiveListTop() const;
    double song(ResponsiveHudCanvas &c, const QJsonObject &source);
    double collection(ResponsiveHudCanvas &c);
    double discover(ResponsiveHudCanvas &c);
    double queue(ResponsiveHudCanvas &c, bool newScope, const QJsonObject &source);
    double settings(ResponsiveHudCanvas &c, const QJsonObject &source);
    double library(ResponsiveHudCanvas &c, const QJsonObject &source);
    void lyricsPlayer(ResponsiveHudCanvas &c, const QJsonObject &source);
    double lyrics(ResponsiveHudCanvas &c, const QJsonObject &source);
    double commentsPage(ResponsiveHudCanvas &c, const QJsonObject &source);
};
