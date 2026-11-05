#pragma once
#include <QPointer>
#include <QWindow>
#include <memory>

class QScreen;

// Owns only our child window's attachment, never an Explorer window or wallpaper setting.
class DesktopWallpaper {
  public:
    ~DesktopWallpaper();
    static bool supported();
    bool attach(QWindow *window, QScreen *screen, QString *error);
    void detach();
    void setVisible(bool visible);
    bool healthy() const;
    bool setInteractive(bool enabled);
    static bool desktopUnderPointer();
    QRectF controlsRect() const;

  private:
    QPointer<QWindow> m_window;
    std::unique_ptr<QWindow> m_parent;
    quintptr m_host = 0;
    quintptr m_icons = 0;
    QRect m_controlsPixels;
};
