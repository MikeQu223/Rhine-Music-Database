#include "AndroidWindow.h"
#include "AndroidMediaSession.h"
#include "Engine.h"
#include <QCoreApplication>
#include <QDebug>
#include <QGuiApplication>
#include <QJniObject>
#include <QQuickWindow>
#include <QWindow>

namespace {
// android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE。
// 用数值而不是新加一层 Java 常量：Android 的这组常量是稳定 ABI，不会随版本变化。
constexpr jint kSensorLandscape = 6;
// WindowManager.LayoutParams.FLAG_FULLSCREEN | FLAG_KEEP_SCREEN_ON。
constexpr jint kWindowFlags = 0x00000400 | 0x00000080;
// View 的 systemUiVisibility：沉浸式粘滞 + 隐藏状态栏/导航栏 + 两种布局扩展。
// API 30 起官方推荐 WindowInsetsController，但旧标志在兼容模式下仍然生效，
// 且不需要按 SDK 版本分叉。
constexpr jint kImmersiveSticky = 0x00000002 | 0x00000004 | 0x00000100 | 0x00000200 | 0x00000400 | 0x00001000;

/** 把横屏与全屏请求落到 Activity 上；任何一步失败都只降级、不中断启动。 */
void applyWindowShape() {
    // View/Window 的标志与方向只能由 Android UI 线程改：Qt 主线程直接调 JNI 会抛
    // CalledFromWrongThreadException（logcat 实测：Window.setFlags 与
    // View.setSystemUiVisibility 都在 checkThread 处拒绝）。runOnAndroidMainThread 把
    // 整段投递到 UI 线程，异步即可——失败也只是丢一次沉浸式设置。
    QNativeInterface::QAndroidApplication::runOnAndroidMainThread([]() -> QVariant {
        // context() 返回 QtJniTypes::Context（QJniObject 的派生类型）。显式构造成
        // QJniObject，不依赖那个类型在各 Qt 版本里的具体形态。
        const QJniObject activity(QNativeInterface::QAndroidApplication::context());
        if (!activity.isValid()) {
            qWarning("Android: 取不到 Activity，横屏与沉浸式设置未下发");
            return {};
        }
        activity.callMethod<void>("setRequestedOrientation", "(I)V", kSensorLandscape);
        const QJniObject window = activity.callObjectMethod("getWindow", "()Landroid/view/Window;");
        if (!window.isValid()) {
            qWarning("Android: 取不到 Window，全屏标志未下发");
            return {};
        }
        window.callMethod<void>("addFlags", "(I)V", kWindowFlags);
        const QJniObject decor = window.callObjectMethod("getDecorView", "()Landroid/view/View;");
        if (decor.isValid()) {
            decor.callMethod<void>("setSystemUiVisibility", "(I)V", kImmersiveSticky);
        }
        return {};
    });
}
}

void configureAndroidWindow(QWindow *window, Engine *backend) {
    if (!window) {
        return;
    }
    // 应用一启动就拉起前台服务（待机通知）：保活窗口覆盖整个生命周期，
    // 而不是等第一次播放才受保护——厂商管控在启动后几秒内就可能冻结后台进程。
    AndroidMediaSession::ensureStarted();
    // 首帧之前下发：先竖屏建表面再转横屏会让第一帧按竖屏尺寸渲染，出现一次可见的重排。
    applyWindowShape();
    window->showFullScreen();
    // 从后台回到前台时系统可能重建 Activity（进程被回收后恢复、分屏切换），
    // 重建出来的窗口是竖屏的；这里重新请求一次，避免要用户手动转屏。
    QObject::connect(qGuiApp, &QGuiApplication::applicationStateChanged, window,
                     [window](Qt::ApplicationState state) {
                         if (state == Qt::ApplicationActive) {
                             applyWindowShape();
                             window->showFullScreen();
                         }
                     });
    QObject::connect(qGuiApp, &QGuiApplication::applicationStateChanged, backend,
                     [backend, window](Qt::ApplicationState state) {
                         const bool active = state == Qt::ApplicationActive;
                         backend->setVisible(active);
                         if (auto *quick = qobject_cast<QQuickWindow *>(window)) {
                             // 退后台时系统销毁 Surface 的时机在 onStop，若 QML 场景图的
                             // 渲染线程那时还在 present 自己的交换链，就是对已释放
                             // ANativeWindow 的 use-after-free（tombstone：queueBuffer 命中
                             // 已销毁互斥量 → SIGABRT，进程死亡连带前台服务消失）。
                             // 在 onPause 时机主动停摆 QQuickWindow：Qt 按自己的受控路径
                             // 停渲染线程并释放表面，赶在系统销毁之前，竞态关闭。
                             quick->setVisible(active);
                         }
                         if (!active) {
                             // 切后台继续持有 GPU 设备会被系统直接杀掉；先还资源再等系统决定。
                             // 不能在这里 releaseResources()：主线程调用会与渲染线程的在途帧竞争。
                             backend->trimMemory();
                         }
                     });
}
