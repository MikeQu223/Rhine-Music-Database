#include "DesktopTray.h"
#include "AppStorage.h"
#include "TrayIcon.h"
#ifdef Q_OS_MACOS
#include "DesktopLyricsSettings.h"
#endif
#include <QAction>
#include <QApplication>
#include <QCloseEvent>
#include <QCursor>
#include <QSignalBlocker>
#include <QWindow>

namespace {
// 未保存过关闭行为时按退出播放器处理；只有显式选择托盘才隐藏窗口。
bool closesToTray() {
    // 设置由后台服务写入同一个配置文件；读取前同步，避免用本进程缓存的旧值决定关闭方式。
    auto settings = AppStorage::settings();
    settings.sync();
    return settings.value("panel/close-behavior").toString() == QLatin1String("tray");
}
} // namespace

/**
 * 建立驻留图标与退出菜单
 */
DesktopTray::DesktopTray(QWindow *window, QObject *parent) : QObject(parent), m_window(window) {
    m_icon.setObjectName("desktopTrayIcon");
    m_icon.setParent(this);
    m_icon.setIcon(rhineTrayIcon());
    m_icon.setToolTip(QGuiApplication::applicationDisplayName());
    auto quit = m_menu.addAction(QStringLiteral("退出"));
    m_quit = quit;
    connect(quit, &QAction::triggered, this, &DesktopTray::quitApplication);
#ifdef Q_OS_WIN
    m_icon.setContextMenu(&m_menu);
#endif
    connect(&m_icon, &QSystemTrayIcon::activated, this, [this](QSystemTrayIcon::ActivationReason reason) {
        if (reason == QSystemTrayIcon::Trigger || reason == QSystemTrayIcon::DoubleClick) {
            restoreWindow();
        }
#ifdef Q_OS_MACOS
        if (reason == QSystemTrayIcon::Context) {
            m_menu.popup(QCursor::pos());
        }
#endif
    });
    m_icon.show();
    if (QSystemTrayIcon::isSystemTrayAvailable()) {
        QGuiApplication::setQuitOnLastWindowClosed(false);
    }
    m_window->installEventFilter(this);
    qApp->installEventFilter(this);
}

/** 拦截普通窗口关闭 */
bool DesktopTray::eventFilter(QObject *watched, QEvent *event) {
    if (watched == qApp && event->type() == QEvent::Quit) {
        m_quitting = true;
    }
    if (watched == m_window && event->type() == QEvent::Close && !m_quitting && !qApp->isSavingSession()) {
        if (closesToTray() && QSystemTrayIcon::isSystemTrayAvailable()) {
            QGuiApplication::setQuitOnLastWindowClosed(false);
            static_cast<QCloseEvent *>(event)->ignore();
            m_window->hide();
            return true;
        }
        // 关闭即退出：放行关闭事件，让 Qt 在最后一个窗口关闭后结束进程。
        QGuiApplication::setQuitOnLastWindowClosed(true);
    }
    return QObject::eventFilter(watched, event);
}

#ifdef Q_OS_MACOS
void DesktopTray::attachDesktopLyrics(DesktopLyricsSettings *settings) {
    if (!settings || m_desktopLyrics) {
        return;
    }
    auto *action = new QAction(QStringLiteral("桌面歌词"), this);
    action->setCheckable(true);
    action->setChecked(settings->enabled());
    connect(action, &QAction::toggled, settings, &DesktopLyricsSettings::setEnabled);
    connect(settings, &DesktopLyricsSettings::enabledChanged, action, [action](bool enabled) {
        const QSignalBlocker blocker(action);
        action->setChecked(enabled);
    });
    m_menu.insertAction(m_quit, action);
    m_desktopLyrics = action;
}
#endif

void DesktopTray::restoreWindow() {
    const auto restoredStates = m_window->windowStates() & ~Qt::WindowMinimized;
    m_window->setWindowStates(restoredStates);
    // show() 会按平台默认模式重置窗口状态；只恢复可见性以保留最大化与全屏。
    m_window->setVisible(true);
    // macOS 显示窗口时可能同步回报普通状态，显示后重新应用此前保留的标记。
    m_window->setWindowStates(restoredStates);
    m_window->raise();
    m_window->requestActivate();
}

void DesktopTray::quitApplication() {
    m_quitting = true;
    QCoreApplication::quit();
}
