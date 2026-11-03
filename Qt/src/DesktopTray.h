#pragma once
#include <QMenu>
#include <QObject>
#include <QSystemTrayIcon>

class QAction;
class QWindow;
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
class DesktopLyricsSettings;
#endif

/** 管理桌面驻留入口 */
class DesktopTray : public QObject {
  public:
    explicit DesktopTray(QWindow *window, QObject *parent = nullptr);
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
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
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
    QAction *m_desktopLyrics = nullptr;
#endif
    bool m_quitting = false;
};
