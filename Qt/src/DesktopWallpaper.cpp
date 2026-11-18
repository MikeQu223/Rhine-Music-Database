#include "DesktopWallpaper.h"
#include "PlatformFeatures.h"
#include <QGuiApplication>
#include <QScreen>
#include <QCoreApplication>
#include <QCursor>
#include <QMouseEvent>
#include <algorithm>
#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <QtGui/qscreen_platform.h>

namespace {
struct InputRelay {
    DesktopWallpaper *owner = nullptr;
    QPointer<QWindow> window;
    HHOOK hook = nullptr;
    bool pressed = false;
    QRect region;
} input;

// Explorer owns the icon hit-test surface, even in empty desktop areas. Relay only mouse
// events over our small, visible control strip; never capture keys or events over applications.
LRESULT CALLBACK controlsMouse(int code, WPARAM message, LPARAM data) {
    if (code < 0 || !input.window || !input.window->isVisible()) {
        return CallNextHookEx(nullptr, code, message, data);
    }
    if (message != WM_MOUSEMOVE && message != WM_LBUTTONDOWN && message != WM_LBUTTONUP) {
        return CallNextHookEx(nullptr, code, message, data);
    }
    if (message == WM_LBUTTONUP && !input.pressed) {
        return CallNextHookEx(nullptr, code, message, data);
    }
    const auto &mouse = *reinterpret_cast<MSLLHOOKSTRUCT *>(data);
    RECT rect{};
    const auto window = input.window;
    if (!GetWindowRect(reinterpret_cast<HWND>(window->winId()), &rect)) {
        return CallNextHookEx(nullptr, code, message, data);
    }
    if (!input.pressed && (!input.region.contains(QPoint(mouse.pt.x, mouse.pt.y)) ||
                           !DesktopWallpaper::desktopUnderPointer())) {
        return CallNextHookEx(nullptr, code, message, data);
    }
    if (message == WM_LBUTTONDOWN) {
        input.pressed = true;
    }
    if (message == WM_LBUTTONUP) {
        input.pressed = false;
    }
    const QPointF local(
        (mouse.pt.x - rect.left) * double(window->width()) / std::max(1L, rect.right - rect.left),
        (mouse.pt.y - rect.top) * double(window->height()) / std::max(1L, rect.bottom - rect.top));
    const auto global = QPointF(QCursor::pos());
    const auto type = message == WM_MOUSEMOVE     ? QEvent::MouseMove
                      : message == WM_LBUTTONDOWN ? QEvent::MouseButtonPress
                                                  : QEvent::MouseButtonRelease;
    const auto button = message == WM_MOUSEMOVE ? Qt::NoButton : Qt::LeftButton;
    const auto buttons = input.pressed ? Qt::LeftButton : Qt::NoButton;
    const auto timestamp = mouse.time;
    QMetaObject::invokeMethod(
        window.data(),
        [window, local, global, type, button, buttons, timestamp] {
            if (!window || !window->isVisible()) {
                return;
            }
            QMouseEvent event(type, local, global, button, buttons, Qt::NoModifier);
            event.setTimestamp(timestamp);
            QCoreApplication::sendEvent(window, &event);
        },
        Qt::QueuedConnection);
    // Keep normal cursor motion; only consume the button gesture owned by the control strip.
    return message == WM_MOUSEMOVE ? CallNextHookEx(nullptr, code, message, data) : 1;
}
struct DesktopLayer {
    HWND host = nullptr;
    HWND icons = nullptr;
    bool raised = false;
};

DesktopLayer desktopLayer() {
    DesktopLayer layer;
    const auto progman = FindWindowW(L"Progman", nullptr);
    if (!progman) {
        return layer;
    }
    DWORD_PTR result = 0;
    // Explorer's private desktop-layer request; timeout keeps a hung shell from blocking the player.
    SendMessageTimeoutW(progman, 0x052c, 0x0d, 1, SMTO_ABORTIFHUNG, 250, &result);
    layer.raised = (GetWindowLongPtrW(progman, GWL_EXSTYLE) & WS_EX_NOREDIRECTIONBITMAP) != 0;
    if (layer.raised) {
        // Windows 11's raised desktop: our layered child sits just below the icon view.
        layer.icons = FindWindowExW(progman, nullptr, L"SHELLDLL_DefView", nullptr);
        if (layer.icons) {
            layer.host = progman;
        }
    } else {
        EnumWindows(
            [](HWND candidate, LPARAM value) -> BOOL {
                auto &found = *reinterpret_cast<DesktopLayer *>(value);
                if (FindWindowExW(candidate, nullptr, L"SHELLDLL_DefView", nullptr)) {
                    const auto worker = FindWindowExW(nullptr, candidate, L"WorkerW", nullptr);
                    if (worker) {
                        found.host = worker;
                        return FALSE;
                    }
                }
                return TRUE;
            },
            reinterpret_cast<LPARAM>(&layer));
    }
    return layer;
}

bool monitorRect(QScreen *screen, RECT *rect, RECT *work) {
    auto native = screen->nativeInterface<QNativeInterface::QWindowsScreen>();
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    if (!native || !GetMonitorInfoW(native->handle(), &info)) {
        return false;
    }
    *rect = info.rcMonitor;
    *work = info.rcWork;
    return true;
}
}
#endif

DesktopWallpaper::~DesktopWallpaper() {
    detach();
}

bool DesktopWallpaper::supported() {
#ifdef Q_OS_WIN
    return PlatformFeatures::DesktopWallpaper && QGuiApplication::platformName() == QStringLiteral("windows");
#else
    return false;
#endif
}

bool DesktopWallpaper::healthy() const {
#ifdef Q_OS_WIN
    const auto host = reinterpret_cast<HWND>(m_host);
    return m_window && host && IsWindow(host) && (!m_icons || IsWindow(reinterpret_cast<HWND>(m_icons))) &&
           IsWindow(reinterpret_cast<HWND>(m_window->winId())) &&
           GetParent(reinterpret_cast<HWND>(m_window->winId())) == host;
#else
    return false;
#endif
}

bool DesktopWallpaper::attach(QWindow *window, QScreen *screen, QString *error) {
    if (error) {
        error->clear();
    }
    if (!supported() || !window || !screen) {
        if (error) {
            *error = QStringLiteral("当前系统不支持桌面壁纸模式");
        }
        return false;
    }
#ifdef Q_OS_WIN
    RECT monitor{}, work{};
    if (m_window && !IsWindow(reinterpret_cast<HWND>(m_window->winId()))) {
        auto stale = m_window;
        detach();
        stale->destroy();
    }
    const auto layer =
        healthy() && m_window == window
            ? DesktopLayer{reinterpret_cast<HWND>(m_host), reinterpret_cast<HWND>(m_icons), m_icons != 0}
            : desktopLayer();
    if (!layer.host || !monitorRect(screen, &monitor, &work)) {
        if (error) {
            *error = QStringLiteral("桌面暂不可用，已保留窗口播放，稍后自动重试");
        }
        return false;
    }
    if (m_window != window || m_host != reinterpret_cast<quintptr>(layer.host) || !healthy()) {
        detach();
        window->hide();
        window->setScreen(screen);
        window->setTransientParent(nullptr);
        m_parent.reset(QWindow::fromWinId(reinterpret_cast<WId>(layer.host)));
        if (!m_parent) {
            if (error) {
                *error = QStringLiteral("无法连接桌面窗口");
            }
            return false;
        }
        m_window = window;
        m_host = reinterpret_cast<quintptr>(layer.host);
        window->setParent(m_parent.get());
    }
    const auto handle = reinterpret_cast<HWND>(window->winId());
    m_icons = reinterpret_cast<quintptr>(layer.icons);
    if (!healthy()) {
        detach();
        if (error) {
            *error = QStringLiteral("桌面挂载失败，已保留窗口播放");
        }
        return false;
    }
    auto style = GetWindowLongPtrW(handle, GWL_EXSTYLE);
    style |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT;
    if (layer.raised) {
        style |= WS_EX_LAYERED;
    }
    SetWindowLongPtrW(handle, GWL_EXSTYLE, style);
    if (layer.raised) {
        SetLayeredWindowAttributes(handle, 0, BYTE(qRound(window->opacity() * 255)), LWA_ALPHA);
    }
    const auto scale = screen->devicePixelRatio();
    const int controlWidth = std::min(int(work.right - work.left), qRound(640 * scale));
    const int controlHeight = qRound(104 * scale);
    m_controlsPixels = QRect(work.left + (work.right - work.left - controlWidth) / 2,
                             work.bottom - qRound(16 * scale) - controlHeight, controlWidth, controlHeight);
    if (input.owner == this) {
        input.region = m_controlsPixels;
    }
    POINT origin{monitor.left, monitor.top};
    MapWindowPoints(HWND_DESKTOP, layer.host, &origin, 1);
    // Native monitor pixels handle mixed DPI, negative origins and portrait displays.
    if (!SetWindowPos(handle, layer.raised ? layer.icons : HWND_BOTTOM, origin.x, origin.y,
                      monitor.right - monitor.left, monitor.bottom - monitor.top,
                      SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
        detach();
        if (error) {
            *error = QStringLiteral("无法调整壁纸显示范围，已保留窗口播放");
        }
        return false;
    }
    return true;
#else
    return false;
#endif
}

void DesktopWallpaper::detach() {
    setInteractive(false);
    if (m_window) {
        m_window->hide();
        m_window->setParent(nullptr);
    }
    m_window = nullptr;
    m_parent.reset();
    m_host = 0;
    m_icons = 0;
}

bool DesktopWallpaper::setInteractive(bool enabled) {
#ifdef Q_OS_WIN
    if (!enabled) {
        if (input.owner == this) {
            if (input.hook) {
                UnhookWindowsHookEx(input.hook);
            }
            input = {};
        }
        return true;
    }
    if (!healthy()) {
        return false;
    }
    if (input.owner == this && input.hook) {
        return true;
    }
    if (input.owner) {
        return false;
    }
    input.owner = this;
    input.window = m_window;
    input.region = m_controlsPixels;
    input.hook = SetWindowsHookExW(WH_MOUSE_LL, controlsMouse, GetModuleHandleW(nullptr), 0);
    if (!input.hook) {
        input = {};
        return false;
    }
    return true;
#else
    return !enabled;
#endif
}

bool DesktopWallpaper::desktopUnderPointer() {
#ifdef Q_OS_WIN
    POINT point{};
    GetCursorPos(&point);
    const auto root = GetAncestor(WindowFromPoint(point), GA_ROOT);
    wchar_t name[64]{};
    GetClassNameW(root, name, 64);
    return wcscmp(name, L"Progman") == 0 || wcscmp(name, L"WorkerW") == 0;
#else
    return false;
#endif
}

void DesktopWallpaper::setVisible(bool visible) {
    if (!m_window) {
        return;
    }
#ifdef Q_OS_WIN
    if (!visible && input.owner == this) {
        input.pressed = false;
    }
    const bool changed = m_window->isVisible() != visible;
#endif
    m_window->setVisible(visible);
#ifdef Q_OS_WIN
    if (visible && changed && healthy()) {
        SetWindowPos(reinterpret_cast<HWND>(m_window->winId()),
                     m_icons ? reinterpret_cast<HWND>(m_icons) : HWND_BOTTOM, 0, 0, 0, 0,
                     SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE);
    }
#endif
}

QRectF DesktopWallpaper::controlsRect() const {
#ifdef Q_OS_WIN
    if (!m_window) {
        return {};
    }
    RECT bounds{};
    if (!GetWindowRect(reinterpret_cast<HWND>(m_window->winId()), &bounds) || bounds.right <= bounds.left ||
        bounds.bottom <= bounds.top) {
        return {};
    }
    const auto sx = double(m_window->width()) / (bounds.right - bounds.left);
    const auto sy = double(m_window->height()) / (bounds.bottom - bounds.top);
    return QRectF((m_controlsPixels.x() - bounds.left) * sx, (m_controlsPixels.y() - bounds.top) * sy,
                  m_controlsPixels.width() * sx, m_controlsPixels.height() * sy);
#else
    return {};
#endif
}
