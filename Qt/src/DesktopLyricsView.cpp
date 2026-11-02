#include "DesktopLyricsView.h"
#include "Glyphs.h"
#include <QPainter>
#include <QPointF>

namespace {

const QColor LineColor(0xF5, 0xF6, 0xF2);
const QColor TranslationColor(0xF5, 0xF6, 0xF2, 140);
const QColor ShadowColor(0, 0, 0, 150);
constexpr double ShadowOffset = 1;

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
                                 const QString &weight, const QColor &color) {
    if (!m_glyphs) {
        return;
    }
    const QPointF offsets[] = {
        {-ShadowOffset, 0},
        {ShadowOffset, 0},
        {0, -ShadowOffset},
        {0, ShadowOffset},
    };
    for (const auto &offset : offsets) {
        m_glyphs->text(painter, text, x + offset.x(), y + offset.y(), size, weight, 0, ShadowColor);
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

    painter->setRenderHint(QPainter::Antialiasing);
    painter->setRenderHint(QPainter::TextAntialiasing);
    double y = frame.style.verticalPadding;
    for (const auto &row : frame.lineRows) {
        const double x = (frame.size.width() - row.width) / 2;
        paintRow(*painter, row.text, x, y, frame.style.lineSize, QStringLiteral("bold"), LineColor);
        y += frame.style.lineHeight;
    }
    if (frame.translationRows.isEmpty()) {
        return;
    }

    y += frame.style.translationGap;
    for (const auto &row : frame.translationRows) {
        const double x = (frame.size.width() - row.width) / 2;
        paintRow(*painter, row.text, x, y, frame.style.translationSize, QStringLiteral("regular"),
                 TranslationColor);
        y += frame.style.translationHeight;
    }
}
