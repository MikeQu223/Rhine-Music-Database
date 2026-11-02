#pragma once
#include <QMenu>
#include <QObject>
#include <QSystemTrayIcon>

class QAction;
class QWindow;
#ifdef Q_OS_MACOS
class DesktopLyricsSettings;
#endif

/** 管理桌面驻留入口 */
class DesktopTray : public QObject {
  public:
    explicit DesktopTray(QWindow *window, QObject *parent = nullptr);
#ifdef Q_OS_MACOS
    void attachDesktopLyrics(DesktopLyricsSettings *settings);
#endif

  protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

  private:
    void restoreWindow();
    void quitApplication();
    QWindow *m_window;
    QMenu m_menu;
    QSystemTrayIcon m_icon;
    QAction *m_quit = nullptr;
#ifdef Q_OS_MACOS
    QAction *m_desktopLyrics = nullptr;
#endif
    bool m_quitting = false;
};
