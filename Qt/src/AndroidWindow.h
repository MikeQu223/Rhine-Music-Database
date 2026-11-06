#pragma once
class QWindow;
class Engine;

// Android 的窗口形态由 Activity 决定：全屏、横屏、常亮三者都必须落到 Window/Activity 上，
// QML 的 Window 属性在这一层没有对应概念。声明里的 sensorLandscape 负责"启动即横屏"，
// 这里再请求一次是为了覆盖多窗口/分屏后系统把 Activity 改回竖屏的情况。
void configureAndroidWindow(QWindow *window, Engine *backend);

/**
 * 关闭 Qt 的 Android 无障碍桥。必须在 QGuiApplication 创建之后、加载任何 QML 场景之前调用。
 *
 * 系统里只要有一个无障碍服务处于启用状态，Qt 就会把每次 QML 对象的显示/隐藏转发给 Java 侧的
 * QtAccessibilityDelegate；后者用 BlockingQueuedConnection 同步回 Qt 主线程，
 * 递归遍历整棵 QAccessibleQuickWindow 可访问树。滑动时高频触发，主线程被打满，
 * 5 秒内无法消费 MotionEvent → Input dispatching timed out → 系统按 ANR 杀掉进程，
 * 观感就是「前台闪退」。本应用是 GPU 自绘面板，没有原生可访问控件，关掉这条桥
 * 不影响任何功能，也不影响 Clarity（它重画 View 树，不读 QAccessible 节点）。
 *
 * 设 RHINE_ANDROID_ACCESSIBILITY=1 可保留原行为，供 TalkBack 场景或 A/B 对照。
 */
void configureAndroidAccessibility();
