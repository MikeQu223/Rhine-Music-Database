#pragma once
#include "DesktopLyricsLayout.h"
#include <QColor>
#include <QMutex>
#include <QQuickPaintedItem>

class Glyphs;
class QPainter;

// 绘制
class DesktopLyricsView final : public QQuickPaintedItem {
  public:
    explicit DesktopLyricsView(Glyphs *glyphs, QQuickItem *parent = nullptr);
    void setFrame(const DesktopLyrics::Frame &frame);
    void paint(QPainter *painter) override;

  private:
    void paintRow(QPainter &painter, const QString &text, double x, double y, double size,
                  const QString &weight, const QColor &color, double outline, const QColor &outlineColor);

    Glyphs *m_glyphs;
    mutable QMutex m_mutex;
    DesktopLyrics::Frame m_frame;
};
