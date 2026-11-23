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
    static constexpr double TopSafeInset = 60;
    static constexpr double NavigationHitHeight = 48;
    static constexpr double SongInfoGap = 8;
    static constexpr double SongInfoHeight = 48;
    static constexpr double SourceWidth = 1920;
    void resize(double stageWidth);
    bool compact() const {
        return m_compact;
    }
    bool showsSongPage() const {
        return m_fields.value("songPanelTop").isDouble();
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
    QVector<QPair<int, int>> discoverVisibleEntries(const DiscoverMusicCard::Model &model) const;
    void focusDiscoverSection(const QString &id);
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
        const int value = m_archiveSourceIndices.value(m_archiveSelection, m_archiveSelection);
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
    QVector<int> m_archiveSourceIndices;
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
    // 竖屏发现页的横向轨道状态只存在于移动布局；桌面共享卡片不读取这些字段。
    static constexpr double DiscoverFeatureWidth = 236.;
    static constexpr double DiscoverFeatureGap = 12.;
    static constexpr double DiscoverCardWidth = 146.;
    static constexpr double DiscoverCardGap = 12.;
    QHash<QString, double> m_discoverHorizontal;
    QHash<QString, double> m_discoverHorizontalMaximum;
    QJsonArray m_discoverSwipeZones;
    QString m_discoverTabKey;
    // 歌词排版缓存：文档或可用宽度变化时才重新换行。
    struct LyricRow {
        double top = 0;
        QStringList text;
        QStringList translation;
    };
    QJsonObject m_lyricDocument;
    int m_lyricLastIndex = -1;
    int m_lyricLineUpdates = 0;
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
    struct SongLayout {
        double panelTop = 260;
        double panelTransition = 32;
        double infoTop = 116;
        double lyricsTop = 172;
        double progressTop = 382;
        double transportTop = 458;
        double utilityTop = 570;
        double bodyOffset = 0;
    };
    SongLayout songLayout(Glyphs &glyphs) const;
    SongLayout m_songLayout;
    void player(ResponsiveHudCanvas &c, bool immersive, const QString &active);
    void optionsSheet(ResponsiveHudCanvas &c, const QJsonObject &source);
    double archive(ResponsiveHudCanvas &c, const QJsonObject &source);
    double archiveListTop() const;
    double song(ResponsiveHudCanvas &c, const QJsonObject &source);
    double collection(ResponsiveHudCanvas &c);
    double discover(ResponsiveHudCanvas &c);
    double queue(ResponsiveHudCanvas &c, bool newScope, const QJsonObject &source);
    double settings(ResponsiveHudCanvas &c, const QJsonObject &source);
    double providerPage(ResponsiveHudCanvas &c, const QJsonObject &source);
    double pluginsPage(ResponsiveHudCanvas &c, const QJsonObject &source);
    double pluginDetailPage(ResponsiveHudCanvas &c, const QJsonObject &source);
    double pluginInstallPage(ResponsiveHudCanvas &c, const QJsonObject &source);
    double library(ResponsiveHudCanvas &c, const QJsonObject &source);
    double lyrics(ResponsiveHudCanvas &c, const QJsonObject &source, double viewTop, double viewBottom);
    double commentsPage(ResponsiveHudCanvas &c, const QJsonObject &source);
};
