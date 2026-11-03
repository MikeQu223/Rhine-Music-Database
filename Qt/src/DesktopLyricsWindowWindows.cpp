#include "DesktopLyricsWindow.h"
#include <QDebug>
#include <QWindow>
#include <qt_windows.h>
#include <memory>

namespace {

class WindowsDesktopLyricsPlatform final : public DesktopLyricsPlatform {
  public:
    void attach(QWindow *window) override {
        if (!window) {
            return;
        }
        const HWND panel = reinterpret_cast<HWND>(window->winId());
        const LONG_PTR currentStyle = GetWindowLongPtrW(panel, GWL_EXSTYLE);
        const LONG_PTR style =
            (currentStyle | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT) &
            ~WS_EX_APPWINDOW;
        SetLastError(ERROR_SUCCESS);
        if (!SetWindowLongPtrW(panel, GWL_EXSTYLE, style) && GetLastError() != ERROR_SUCCESS) {
            qWarning() << "Desktop lyrics: cannot apply native window styles" << GetLastError();
        }

        // 不传原生像素坐标，避免在高 DPI 或跨屏时重复缩放 Qt 的逻辑几何。
        if (!SetWindowPos(panel, HWND_TOPMOST, 0, 0, 0, 0,
                          SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
            qWarning() << "Desktop lyrics: cannot keep native window on top" << GetLastError();
        }
    }
};

}

std::unique_ptr<DesktopLyricsPlatform> createDesktopLyricsPlatform() {
    return std::make_unique<WindowsDesktopLyricsPlatform>();
}
