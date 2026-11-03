#pragma once
#include "DesktopLyricsLayout.h"
#include "Glyphs.h"
#include "HudScroll.h"
#include "MusicLibrary.h"
#include "SettingsSchema.h"
#include "UiMotion.h"
#include <QCache>
#include <QPointF>
#include <QRectF>
#include <map>
#include <optional>

// 场景边界只传递值和原生回调；界面控制器不持有脚本对象。
struct HudSceneActions {
    std::function<void(QString)> mode;
    std::function<void(bool)> theme;
    std::function<void(bool)> reduced;
    std::function<void(QString, double, double, double)> pointer;
    std::function<void(QString)> viewer;
    std::function<void(QString)> viewerKey;
    std::function<void()> openViewer;
    std::function<void(bool)> coverFront;
};

class DiscoverArtwork;

class NativeHud : public QObject {
    Q_OBJECT
  public:
    struct Row {
        int index = -1;
        QJsonObject value;
        QVector<int> indices;
    };
    struct Layout {
        double left = 40;
        double sidebar = 250;
        double x = 326;
        double width = 0;
        double top = 260;
        double rowsY = 434;
        double rowHeight = 54;
        int rowCount = 9;
        double bottom = 956;
    };
    NativeHud(Host *host, Glyphs *glyphs, MusicLibrary *music, HudSceneActions scene,
              QObject *parent = nullptr);
    void draw(QJsonObject frame, double width, double time);
    QJsonObject state() const;
    void action(QString action);
    void key(QString key, bool command);
    void wheel(double x, double y, double delta, std::optional<int> steps = std::nullopt,
               std::optional<double> distance = std::nullopt);
    void form(QJsonObject fields);
    void openModal(QString kind);
    void closeModal();
    void setQuery(QString value);
    void pageResults(int direction);
    // 重新测量设置页内容高度；会话恢复和展开下拉前必须调用。
    void refreshSettingsLayout();
    // 通用文本设置的编辑入口；QML 浮层通过这三个方法提交/取消。
    void beginSettingEdit(const QString &id);
    void setSettingEditText(const QString &text);
    void commitSettingEdit();
    void cancelSettingEdit();
    bool animating(double time) const;
    bool supportsTrackList() const;
    QVector<Row> rows(int lane);
    QRectF modalBounds(double width) const;
    QRectF detailBounds(double width) const;
    Layout containerLayout(double width) const;
    QJsonArray commands;
    QJsonArray hits;
    QJsonObject frame;
    QString tab = "overview";
    QString modal;
    QString query;
    QString formKind;
    QString formPID;
    QString confirmTitle;
    QString detailSort = "none";
    QString groupBy = "none";
    QString activeGroup;
    QString artistTab = "songs";
    bool categoryPicker = false;
    int categoryPage = 0;
    static constexpr int CategoryPageSize = 40;
    double discoverScroll = 0;
    double discoverScrollMaximum = 0;
    QString themeMode;
    int listOffset = 0;
    int musicCollection = 1;
    // 检索与个人库共用同一结果视口和行高。
    static constexpr double ResultListTop = 328;
    static constexpr double ResultListBottom = 758;
    static constexpr double ResultRowHeight = 72;
    double searchScroll = 0;
    int searchRowCount = 0;
    double savedScroll = 0;
    int savedRowCount = 0;
    // 通用文本设置的 QML 编辑浮层状态；清空 id 即隐藏。
    QString editingSettingId;
    QString editingSettingText;
    QRectF editingSettingRect;
    // 六行同专辑
    static constexpr int AlbumTrackRowCount = 6;
    static constexpr double AlbumTrackTop = 630;
    static constexpr double AlbumTrackRowHeight = 48;
    int trackOffset = 0;
    int bodyOffset = 0;
    int queueOffset = 0;
    // 设置沿用原舞台坐标与行高，只在固定标题下滚动内容。
    static constexpr double SettingsViewportTop = 176;
    static constexpr double SettingsViewportBottom = 836;
    double settingsContentBottom = 1600;
    double settingsScroll = 0;
    // 设置页下拉块：非空时该偏好行展开成选项列表。
    QString expandedPreference;
    // 清除缓存后的结果提示；重新打开设置页时清空。
    QString cacheMessage;
    // 从主设置页进入桌面歌词页时保留原滚动位置。
    double settingsReturnScroll = 0;
    // 桌面歌词样式页使用独立滚动区。
    static constexpr double DesktopLyricsViewportTop = 200;
    static constexpr double DesktopLyricsViewportBottom = 820;
    double desktopLyricsContentBottom = 1600;
    double desktopLyricsScroll = 0;
    DesktopLyrics::Appearance desktopLyricsAppearance;
    bool desktopLyricsAppearanceLoaded = false;
    double settingsScrollMaximum() const {
        return HudScroll::maximum(settingsContentBottom - SettingsViewportTop,
                                  SettingsViewportBottom - SettingsViewportTop);
    }
    double desktopLyricsScrollMaximum() const {
        return HudScroll::maximum(desktopLyricsContentBottom - DesktopLyricsViewportTop,
                                  DesktopLyricsViewportBottom - DesktopLyricsViewportTop);
    }
    bool dark = false;
    bool reduced = false;
    bool startupAnimation = false;
    bool discRotation = false;
    bool vsync = true;
    int archiveMaskStrength = 50;
    bool closing = false;
    bool lyricsMode = false;
    bool trackListMode = false;
    double width = 1920;
    double lastTime = 0;
    UiMotion::SurfaceMotion motion;
    std::optional<QRectF> playerBounds;
    std::optional<QRectF> playerSeekRect;
    std::optional<QRectF> playerVolumeRect;

  signals:
    void localImportRequested(bool folder);
    void mvRequested();

  private:
    struct LyricRow {
        double top = 0;
        QStringList text;
        QStringList translation;
    };
    struct TrackRulerRow {
        double centerY = 0;
        double textRight = 0;
        double emphasis = 0;
        double opacity = 1;
    };
    struct SortRequest {
        QString provider;
        quint64 account;
        quint64 generation;
        QString key;
        std::shared_ptr<MusicDirectory> directory;
        int progress = -1;
    };
    void beginSort();
    void continueSort();
    std::optional<SortRequest> m_sortRequest;
    struct Page {
        QString modal;
        int lane;
        quint64 generation;
        int desired;
    };
    Host *m_host;
    Glyphs *m_glyphs;
    MusicLibrary *m_music;
    HudSceneActions m_scene;
    quint64 m_searchGeneration = 0;
    // 首屏不足一屏时自动补页，记录上次自动补页后的条数，避免空页循环请求。
    int m_searchAutoFillSize = -1;
    int m_savedAutoFillSize = -1;
    std::optional<Page> m_page;
    QString m_trackListScope;
    int m_trackListTarget = -1;
    std::optional<UiMotion::ReelCurve> m_trackListCurve;
    std::function<void()> m_confirm;
    QCache<QString, QString> m_fitCache{512};
    std::map<QString, UiMotion::RollingLabel> m_rolling;
    QString m_sortNotice;
    // QObject 子对象拥有生命周期，封面回调不跨越 HUD 销毁。
    DiscoverArtwork *m_discoverArtwork = nullptr;
    QString m_discoverScrollScope;
    QString m_songQueueFeedbackKey;
    QHash<QString, QString> m_songQueueFeedback;
    // 每个按钮独立计时，重复点击重启计时器；HUD 销毁时自动取消回调。
    QHash<QString, QTimer *> m_songQueueFeedbackTimers;
    QString m_sortContainerKey;
    QJsonArray m_sortTracks;
    QString m_sortField;
    QVector<int> m_trackOrder;
    QString m_rowsKey;
    QVector<Row> m_rows;
    QString m_resultSignature;
    double m_resultStart = 0;
    bool m_modalControls = false;
    QJsonObject m_lyricsDocument;
    double m_lyricsWidth = 0;
    QVector<LyricRow> m_lyricsLayout;
    double m_lyricsScroll = 0;
    std::optional<double> m_lyricsBrowse;
    int m_lyricsLastIndex = -1;
    int m_lyricsLineUpdates = 0;
    std::optional<double> m_lyricsTarget;
    std::optional<UiMotion::ReelCurve> m_lyricsCurve;
    int m_lyricsPlainOffset = 0;
    void finishPage();
    void musicAction(const QStringList &parts, const QString &action);
    void playerAction(const QStringList &parts);
    QJsonArray ink() const;
    void op(QJsonArray command);
    void save();
    void restore();
    void alpha(double value);
    void translate(double x, double y);
    void scale(double x, double y);
    void clip(double x, double y, double width, double height);
    void fill(double x, double y, double width, double height, QJsonArray color = {});
    void text(QString value, double x, double y, double size, QString weight = "regular", double tracking = 0,
              QJsonArray color = {});
    void aligned(QString value, double x, double y, double size, QString weight = "regular",
                 double tracking = 0);
    QString fit(QString value, double size, double width, QString weight = "regular");
    void limited(QString value, double x, double y, double size, double width, QString weight = "regular");
    void centeredText(QString value, double x, double cy, double size, QString weight = "regular",
                      bool horizontal = false);
    void rollingText(QString key, QString value, double x, double y, double size, QString weight = "regular",
                     double tracking = 0, bool numeric = false);
    void roll(QString key, QString value, double x, double y, double size, double width,
              QString weight = "regular", bool numeric = false);
    void hit(double x, double y, double width, double height, QString action, QString label = {});
    void button(QString label, double x, double y, double width, double height, QString action, double size,
                QString weight = "regular");
    void control(QString label, double x, double y, double width, QString action);
    void rule(double x, double y, double width, double opacity = 0.4);
    void image(QString key, double x, double y, double width, double height);
    void art(QString key, double x, double y, double size, int count = -1, double tracking = 0,
             QJsonArray color = {});
    void brand();
    static double navigationLeft(double width);
    void archiveMask(double width);
    void brandLine(int index);
    void navigation(double width);
    void footer(double width);
    void empty(double width);
    void archive(double width);
    void archiveTabButton(double width);
    void archiveTrackList(double x, double width);
    double archiveTrackPosition(int selected);
    void archiveTrackRuler(double x, double centerY, const QVector<TrackRulerRow> &rows);
    void actionButton(QString label, double x, double y, double width, QString action, bool primary = false);
    void detail(double width, double opacity);
    void lyricsPanel(double x, double width);
    QString body() const;
    void container(double width, double opacity);
    void viewer(double width);
    std::array<double, 2> rowMotion(const QString &signature, int index);
    void modalDraw(double width);
    void loginPanel(double x, double y, double width);
    void libraryPanel(double x, double y, double width);
    void savedPanel(double x, double y, double width);
    // 个人库沿用检索页的工具条、结果列表和页脚结构，外框几何仍由弹窗宿主决定。
    void libraryToolbar(double x, double y, double width);
    void libraryResultList(double x, double y, double width);
    void libraryFooter(double x, double y, double width);
    void libraryOutlineButton(const QRectF &rect, const QString &label, const QString &action, double size,
                              bool plus = false);
    double libraryToolbarActionWidth() const;
    double savedScrollMaximum() const;
    void ensureSavedFilled();
    // 检索面板按工具条、结果列表和页脚拆分，外框几何仍由弹窗宿主决定。
    void searchPanel(double x, double y, double width);
    void searchToolbar(double x, double y, double width);
    void searchResultList(double x, double y, double width);
    void resultListRow(const Row &entry, double x, double y, double width, const QString &query, int lane);
    void searchTitle(const QString &title, const QString &query, double x, double y, double size,
                     double width);
    void searchFooter(double x, double y, double width);
    double searchScrollMaximum() const;
    void resetResultViews();
    void ensureSearchFilled();
    void discoverPanel(double x, double y, double width);
    void localPanel(double x, double y, double width);
    void playerBar(double x, double y, double width);
    void playerPanel(double x, double y, double width);
    void platformChoices(double x, double y, double width, bool expanded = false);
    void platformPanel(double x, double y, double width);
    void settingsPanel(double x, double y, double width);
    void paintSettingsCustomSection(const QString &renderer, const QRectF &body, double scroll);
    SettingsSchema::SettingsContext settingsContext() const;
    void applySettingValue(const QString &id, const QString &value);
    void restoreSettingsDefaults();
    void refreshDesktopLyricsLayout();
    void refreshDesktopLyricsAppearance();
    void desktopLyricsPanel(double x, double y, double width);
    void applyDesktopLyricsAction(const QString &value);
    void qualityPanel(double x, double y, double width);
    void qualityChoice(const QString &id, int number, double x, double y, double width, bool featured);
    void logo(double x, double y, double width);
    void boot(double width);
    void scan(const QJsonObject &boot);
    static QString clock(double ms);
};
