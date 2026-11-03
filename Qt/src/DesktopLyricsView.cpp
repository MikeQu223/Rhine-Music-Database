#include "DesktopLyricsView.h"
#include "Glyphs.h"
#include <QColor>
#include <QPainter>
#include <QPointF>
#include <algorithm>
#include <array>
#include <cmath>

namespace {

const QColor FallbackColor(0xF5, 0xF6, 0xF2);
const QColor FallbackOutline(0, 0, 0);
constexpr double OutlineOpacity = 0.72;
constexpr int OutlineDirections = 16;

const std::array<QPointF, OutlineDirections> &outlineDirections() {
    static const auto directions = [] {
        std::array<QPointF, OutlineDirections> values;
        for (int index = 0; index < OutlineDirections; ++index) {
            const double angle = 2.0 * std::acos(-1.0) * index / OutlineDirections;
            values[index] = QPointF(std::cos(angle), std::sin(angle));
        }
        return values;
    }();
    return directions;
}

QColor colorOr(const QString &value, const QColor &fallback) {
    const QColor color(value);
    return color.isValid() ? color : fallback;
}
}

DesktopLyricsView::DesktopLyricsView(Glyphs *glyphs, QQuickItem *parent)
    : QQuickPaintedItem(parent), m_glyphs(glyphs) {
    setOpaquePainting(false);
    setAntialiasing(true);
}

void DesktopLyricsView::setFrame(const DesktopLyrics::Frame &frame) {
    {
        const QMutexLocker locker(&m_mutex);
        m_frame = frame;
    }
    update();
}

void DesktopLyricsView::paintRow(QPainter &painter, const QString &text, double x, double y, double size,
                                 const QString &weight, const QColor &color, double outline,
                                 const QColor &outlineColor) {
    if (!m_glyphs) {
        return;
    }
    if (outline > 0.01) {
        QColor stroke = outlineColor;
        stroke.setAlphaF(OutlineOpacity);
        for (const auto &direction : outlineDirections()) {
            m_glyphs->text(painter, text, x + direction.x() * outline, y + direction.y() * outline, size,
                           weight, 0, stroke);
        }
    }
    m_glyphs->text(painter, text, x, y, size, weight, 0, color);
}

void DesktopLyricsView::paint(QPainter *painter) {
    DesktopLyrics::Frame frame;
    {
        const QMutexLocker locker(&m_mutex);
        frame = m_frame;
    }
    if (frame.lineRows.isEmpty()) {
        return;
    }

    const QColor lineColor = colorOr(frame.style.lineColor, FallbackColor);
    const QColor translationColor = colorOr(frame.style.translationColor, FallbackColor);
    const QColor lineOutline = colorOr(frame.style.lineOutlineColor, FallbackOutline);
    const QColor translationOutline = colorOr(frame.style.translationOutlineColor, FallbackOutline);

    painter->setRenderHint(QPainter::Antialiasing);
    painter->setRenderHint(QPainter::TextAntialiasing);
    painter->save();
    painter->setOpacity(std::clamp(frame.style.opacity, 0.0, 1.0));
    double y = frame.style.verticalPadding;
    for (const auto &row : frame.lineRows) {
        const double x = (frame.size.width() - row.width) / 2;
        paintRow(*painter, row.text, x, y, frame.style.lineSize, frame.style.lineWeight, lineColor,
                 frame.style.lineOutline, lineOutline);
        y += frame.style.lineHeight;
    }
    if (!frame.translationRows.isEmpty()) {
        y += frame.style.translationGap;
        for (const auto &row : frame.translationRows) {
            const double x = (frame.size.width() - row.width) / 2;
            paintRow(*painter, row.text, x, y, frame.style.translationSize, frame.style.translationWeight,
                     translationColor, frame.style.translationOutline, translationOutline);
            y += frame.style.translationHeight;
        }
    }
    painter->restore();
}
