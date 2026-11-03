#pragma once
#include <QJsonObject>
#include <QPoint>
#include <QRect>
#include <QSizeF>
#include <QString>
#include <QStringList>
#include <QVector>
#include <functional>
#include <optional>

namespace DesktopLyrics {

// 字号、透明度与描边范围；设置页、偏好模型和排版共用。
inline constexpr int MinimumLineSize = 20;
inline constexpr int MaximumLineSize = 60;
inline constexpr int DefaultLineSize = 32;
inline constexpr int MinimumTranslationSize = 16;
inline constexpr int MaximumTranslationSize = 48;
inline constexpr int DefaultTranslationSize = 24;
inline constexpr int MinimumOpacity = 20;
inline constexpr int MaximumOpacity = 100;
inline constexpr int DefaultOpacity = 100;
inline constexpr double MaximumOutline = 4;
inline constexpr double OutlineStep = 0.5;
inline constexpr double DefaultLineOutline = 1.5;
inline constexpr double DefaultTranslationOutline = 1;
inline constexpr auto DefaultLineColor = "#f5f6f2";
inline constexpr auto DefaultTranslationColor = "#f5f6f2";
inline constexpr auto DefaultOutlineColor = "#000000";
inline constexpr auto DefaultLineWeight = "bold";
inline constexpr auto DefaultTranslationWeight = "regular";

// 偏好键由设置页、渲染模型和 Host 白名单共用。
inline constexpr auto EnabledKey = "desktop-lyrics";
inline constexpr auto LineSizeKey = "desktop-lyrics-size";
inline constexpr auto TranslationSizeKey = "desktop-lyrics-translation-size";
inline constexpr auto OpacityKey = "desktop-lyrics-opacity";
inline constexpr auto LineColorKey = "desktop-lyrics-line-color";
inline constexpr auto TranslationColorKey = "desktop-lyrics-translation-color";
inline constexpr auto LineWeightKey = "desktop-lyrics-line-weight";
inline constexpr auto TranslationWeightKey = "desktop-lyrics-translation-weight";
inline constexpr auto LineOutlineKey = "desktop-lyrics-line-outline";
inline constexpr auto TranslationOutlineKey = "desktop-lyrics-translation-outline";
inline constexpr auto LineOutlineColorKey = "desktop-lyrics-line-outline-color";
inline constexpr auto TranslationOutlineColorKey = "desktop-lyrics-translation-outline-color";

// 悬浮歌词显示内容
struct Content {
    QString text;
    QString translation;
    bool operator==(const Content &) const = default;
};

// 可在设置页调整的外观参数
struct Appearance {
    int lineSize = DefaultLineSize;
    int translationSize = DefaultTranslationSize;
    int opacity = DefaultOpacity;
    QString lineColor = QString::fromLatin1(DefaultLineColor);
    QString translationColor = QString::fromLatin1(DefaultTranslationColor);
    QString lineWeight = QString::fromLatin1(DefaultLineWeight);
    QString translationWeight = QString::fromLatin1(DefaultTranslationWeight);
    double lineOutline = DefaultLineOutline;
    double translationOutline = DefaultTranslationOutline;
    QString lineOutlineColor = QString::fromLatin1(DefaultOutlineColor);
    QString translationOutlineColor = QString::fromLatin1(DefaultOutlineColor);
    bool operator==(const Appearance &) const = default;
};

// 从统一歌词文档中取当前行。空文本行沿用窗口内歌词页的「•••」占位符。
std::optional<Content> contentAt(const QJsonObject &document, int index);

// 排版
struct TextMetrics {
    std::function<QStringList(const QString &text, double width, double size, const QString &weight)> wrap;
    std::function<double(const QString &text, double size, const QString &weight)> width;
};

// 视觉参数
struct Style {
    double lineSize = DefaultLineSize;
    double translationSize = DefaultTranslationSize;
    double lineHeight = 44;
    double translationHeight = 35;
    double horizontalPadding = 28;
    double verticalPadding = 20;
    double translationGap = 6;
    double maximumWidth = 720;
    double horizontalMargin = 80;
    double bottomMargin = 64;
    int maximumLineRows = 4;
    int maximumTranslationRows = 2;
    QString lineColor = QString::fromLatin1(DefaultLineColor);
    QString translationColor = QString::fromLatin1(DefaultTranslationColor);
    QString lineWeight = QString::fromLatin1(DefaultLineWeight);
    QString translationWeight = QString::fromLatin1(DefaultTranslationWeight);
    double lineOutline = DefaultLineOutline;
    double translationOutline = DefaultTranslationOutline;
    QString lineOutlineColor = QString::fromLatin1(DefaultOutlineColor);
    QString translationOutlineColor = QString::fromLatin1(DefaultOutlineColor);
    double opacity = 1.0;
    bool operator==(const Style &) const = default;
};

struct Row {
    QString text;
    double width = 0;
};

// 一帧完整的绘制输入；绘制层不重新计算文字、折行或尺寸。
struct Frame {
    Style style;
    QVector<Row> lineRows;
    QVector<Row> translationRows;
    QSizeF size;
};

Frame buildFrame(const Content &content, const TextMetrics &metrics, double availableWidth,
                 const Style &style = {});
// 按正文和译文字号分别计算行高、内边距与译文间距。
Style styleFor(const Appearance &appearance);
QPoint placeBottomCenter(const QSizeF &size, const QRect &available, const Style &style = {});
Frame emptyFrame(const Style &style = {});

}
