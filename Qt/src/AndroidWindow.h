#pragma once
class QWindow;
class Engine;

// Android 的窗口形态由 Activity 决定：全屏、横屏、常亮三者都必须落到 Window/Activity 上，
// QML 的 Window 属性在这一层没有对应概念。声明里的 sensorLandscape 负责"启动即横屏"，
// 这里再请求一次是为了覆盖多窗口/分屏后系统把 Activity 改回竖屏的情况。
void configureAndroidWindow(QWindow *window, Engine *backend);
