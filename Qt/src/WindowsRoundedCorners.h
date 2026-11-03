#pragma once

class QWindow;

/** 请求 Windows 11 的 DWM 为无边框窗口绘制圆角；旧版系统忽略该请求。 */
void applyWindowsRoundedCorners(QWindow *window);
