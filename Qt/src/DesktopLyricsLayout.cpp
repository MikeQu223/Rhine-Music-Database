#include "DesktopLyricsLayout.h"
#include <QJsonArray>
#include <QtGlobal>
#include <algorithm>
#include <cmath>

namespace {

QString ellipsisRow(const QString &row, const DesktopLyrics::TextMetrics &metrics, double limit, double size,
                    const QString &weight) {
    const QString suffix = QStringLiteral("…");
    QString visible = row;
    while (!visible.isEmpty() && metrics.width(visible + suffix, size, weight) > limit) {
        visible.chop(1);
    }
    return visible + suffix;
}

QStringList fitRows(QStringList rows, int maximum, const DesktopLyrics::TextMetrics &metrics, double limit,
                    double size, const QString &weight) {
    if (maximum <= 0) {
        return {};
    }
    if (rows.size() <= maximum) {
        return rows;
    }
    rows = rows.mid(0, maximum);
    rows.last() = ellipsisRow(rows.last(), metrics, limit, size, weight);
    return rows;
}

QVector<DesktopLyrics::Row> measureRows(const QStringList &rows, const DesktopLyrics::TextMetrics &metrics,
                                        double size, const QString &weight) {
    QVector<DesktopLyrics::Row> measured;
    measured.reserve(rows.size());
    for (const auto &row : rows) {
        measured.append({row, metrics.width(row, size, weight)});
    }
    return measured;
}

}

namespace DesktopLyrics {

std::optional<Content> contentAt(const QJsonObject &document, int index) {
    if (document.value("timing").toString() == QLatin1String("none")) {
        return std::nullopt;
    }
    const auto lines = document.value("lines").toArray();
    if (index < 0 || index >= lines.size()) {
        return std::nullopt;
    }
    const auto line = lines.at(index).toObject();
    auto text = line.value("text").toString().trimmed();
    if (text.isEmpty()) {
        text = QStringLiteral("•••");
    }
    return Content{text, line.value("translation").toString().trimmed()};
}

Frame buildFrame(const Content &content, const TextMetrics &metrics, double availableWidth,
                 const Style &style) {
    const double width = std::max(1.0, std::min(style.maximumWidth, availableWidth - style.horizontalMargin));
    const double textWidth = std::max(1.0, width - style.horizontalPadding * 2);
    const auto lineRows =
        fitRows(metrics.wrap(content.text, textWidth, style.lineSize, style.lineWeight),
                style.maximumLineRows, metrics, textWidth, style.lineSize, style.lineWeight);
    QStringList translationRows;
    if (!content.translation.isEmpty()) {
        translationRows = fitRows(
            metrics.wrap(content.translation, textWidth, style.translationSize, style.translationWeight),
            style.maximumTranslationRows, metrics, textWidth, style.translationSize, style.translationWeight);
    }

    Frame frame;
    frame.style = style;
    frame.lineRows = measureRows(lineRows, metrics, style.lineSize, style.lineWeight);
    frame.translationRows =
        measureRows(translationRows, metrics, style.translationSize, style.translationWeight);
    double height = style.verticalPadding * 2 + frame.lineRows.size() * style.lineHeight;
    if (!frame.translationRows.isEmpty()) {
        height += style.translationGap + frame.translationRows.size() * style.translationHeight;
    }
    frame.size = QSizeF(width, height);
    return frame;
}

Style styleFor(const Appearance &appearance) {
    Style style;
    style.lineSize = std::clamp(appearance.lineSize, MinimumLineSize, MaximumLineSize);
    style.translationSize =
        std::clamp(appearance.translationSize, MinimumTranslationSize, MaximumTranslationSize);
    const double scale = style.lineSize / double(DefaultLineSize);
    style.lineHeight = std::round(style.lineSize * 1.375);
    style.translationHeight = std::round(style.translationSize * 1.45);
    style.horizontalPadding *= scale;
    style.verticalPadding *= scale;
    style.translationGap *= scale;
    style.lineColor = appearance.lineColor;
    style.translationColor = appearance.translationColor;
    style.lineWeight = appearance.lineWeight;
    style.translationWeight = appearance.translationWeight;
    style.lineOutline = std::clamp(appearance.lineOutline, 0.0, MaximumOutline);
    style.translationOutline = std::clamp(appearance.translationOutline, 0.0, MaximumOutline);
    style.lineOutlineColor = appearance.lineOutlineColor;
    style.translationOutlineColor = appearance.translationOutlineColor;
    style.opacity = std::clamp(appearance.opacity, MinimumOpacity, MaximumOpacity) / 100.0;
    return style;
}

QPoint placeBottomCenter(const QSizeF &size, const QRect &available, const Style &style) {
    const int width = std::max(1, qRound(size.width()));
    const int height = std::max(1, qRound(size.height()));
    int x = available.x() + (available.width() - width) / 2;
    int y = available.y() + available.height() - qRound(style.bottomMargin) - height;
    // 窗口比可用区域大时贴住左上角，顺序保持先取上限再取下限。
    x = std::clamp(x, available.x(), std::max(available.x(), available.x() + available.width() - width));
    y = std::clamp(y, available.y(), std::max(available.y(), available.y() + available.height() - height));
    return {x, y};
}

Frame emptyFrame(const Style &style) {
    Frame frame;
    frame.style = style;
    frame.size = QSizeF(1, 1);
    return frame;
}

}
