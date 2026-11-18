#include "WindowsRoundedCorners.h"

#include <QWindow>
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <dwmapi.h>

namespace {
// 33 是 DWMWA_WINDOW_CORNER_PREFERENCE 的稳定取值；该属性从 Windows 11 SDK 才开始提供，
// 直接写数值可以让同一份代码在旧 SDK 上照常编译。
constexpr DWORD WINDOW_CORNER_PREFERENCE = 33;
// DWMWCP_ROUND：按系统默认的 8px 半径绘制；最大化、贴边和全屏时由系统自动跳过。
constexpr int CORNER_PREFERENCE_ROUND = 2;
}

void applyWindowsRoundedCorners(QWindow *window) {
    if (!window) {
        return;
    }
    const auto handle = reinterpret_cast<HWND>(window->winId());
    int preference = CORNER_PREFERENCE_ROUND;
    // 无边框窗口没有标准窗口框架，Win11 不会自动圆角，需要显式请求 DWM 裁剪四角。
    // Windows 10 及更早系统不认识该属性，调用失败时保持原有方角外观。
    DwmSetWindowAttribute(handle, WINDOW_CORNER_PREFERENCE, &preference, sizeof(preference));
}
