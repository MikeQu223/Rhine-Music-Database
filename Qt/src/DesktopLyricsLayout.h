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

// 悬浮歌词显示内容
struct Content {
    QString text;
    QString translation;
    bool operator==(const Content &) const = default;
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
    double lineSize = 32;
    double translationSize = 18;
    double lineHeight = 44;
    double translationHeight = 26;
    double horizontalPadding = 28;
    double verticalPadding = 20;
    double translationGap = 6;
    double maximumWidth = 720;
    double horizontalMargin = 80;
    double bottomMargin = 64;
    int maximumLineRows = 4;
    int maximumTranslationRows = 2;
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
QPoint placeBottomCenter(const QSizeF &size, const QRect &available, const Style &style = {});
Frame emptyFrame(const Style &style = {});

}
