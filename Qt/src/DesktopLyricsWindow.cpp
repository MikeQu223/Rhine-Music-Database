#include "DesktopLyricsWindow.h"
#include "DesktopLyricsView.h"
#include <QPointF>
#include <QQuickWindow>
#include <QtGlobal>
#include <utility>

DesktopLyricsWindow::DesktopLyricsWindow(Glyphs *glyphs, std::unique_ptr<DesktopLyricsPlatform> platform,
                                         QObject *parent)
    : QObject(parent), m_glyphs(glyphs), m_platform(std::move(platform)) {
}

DesktopLyricsWindow::~DesktopLyricsWindow() = default;

void DesktopLyricsWindow::ensureCreated() {
    if (m_window) {
        return;
    }
    m_window = std::make_unique<QQuickWindow>();
    m_window->setFlags(Qt::Tool | Qt::FramelessWindowHint | Qt::WindowStaysOnTopHint |
                       Qt::WindowDoesNotAcceptFocus | Qt::WindowTransparentForInput |
                       Qt::NoDropShadowWindowHint);
    // 透明必须在 show() 前设置；Qt 会据此把 surface format 的 alpha buffer 设为 8。
    m_window->setColor(Qt::transparent);
    m_window->resize(1, 1);
    m_view = new DesktopLyricsView(m_glyphs, m_window->contentItem());
    m_view->setPosition(QPointF(0, 0));
    m_view->setSize(QSizeF(1, 1));
}

void DesktopLyricsWindow::show() {
    ensureCreated();
    if (m_window->isVisible()) {
        return;
    }
    m_window->show();
    // Qt 会按 Qt::Tool 恢复失焦隐藏，必须在 show() 之后重新应用平台属性。
    if (m_platform) {
        m_platform->attach(m_window.get());
    }
}

void DesktopLyricsWindow::hide() {
    if (m_window) {
        m_window->hide();
    }
}

void DesktopLyricsWindow::present(const DesktopLyrics::Frame &frame, const QPoint &topLeft) {
    ensureCreated();
    const int width = qMax(1, qRound(frame.size.width()));
    const int height = qMax(1, qRound(frame.size.height()));
    m_window->setGeometry(topLeft.x(), topLeft.y(), width, height);
    m_view->setSize(frame.size);
    m_view->setFrame(frame);
}
