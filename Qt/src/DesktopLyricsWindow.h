#pragma once
#include "DesktopLyricsLayout.h"
#include <QObject>
#include <memory>

class DesktopLyricsView;
class Glyphs;
class QQuickWindow;
class QWindow;

// 平台窗口属性
class DesktopLyricsPlatform {
  public:
    virtual ~DesktopLyricsPlatform() = default;
    virtual void attach(QWindow *window) = 0;
};

std::unique_ptr<DesktopLyricsPlatform> createDesktopLyricsPlatform();

// 管理 QQuickWindow 的生命周期、几何和视图
class DesktopLyricsWindow : public QObject {
    Q_OBJECT

  public:
    DesktopLyricsWindow(Glyphs *glyphs, std::unique_ptr<DesktopLyricsPlatform> platform,
                        QObject *parent = nullptr);
    ~DesktopLyricsWindow() override;
    void show();
    void hide();
    void present(const DesktopLyrics::Frame &frame, const QPoint &topLeft);

  signals:
    void visibleChanged(bool visible);

  private:
    void ensureCreated();

    Glyphs *m_glyphs;
    std::unique_ptr<DesktopLyricsPlatform> m_platform;
    std::unique_ptr<QQuickWindow> m_window;
    DesktopLyricsView *m_view = nullptr;
};
