#include "IOSWindow.h"
#include "Engine.h"
#include <QGuiApplication>
#include <QPointer>
#include <QQuickWindow>
#include <QWindow>
#import <UIKit/UIKit.h>

/** iPhone 固定竖屏，iPad 固定横屏；与 InfoIOS.plist 声明的支持方向保持一致。 */
Qt::ScreenOrientation iosContentOrientation() {
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        return Qt::LandscapeOrientation;
    }
    return Qt::PortraitOrientation;
}

/** 按设备类型设定内容方向。Qt Quick 与独立呈现层分别管理自己的窗口生命周期。 */
void configureIOSWindow(QWindow *window, Engine *backend) {
    window->reportContentOrientationChange(iosContentOrientation());
    window->showFullScreen();
    if (auto *quick = qobject_cast<QQuickWindow *>(window)) {
        QObject::connect(qGuiApp, &QGuiApplication::applicationStateChanged, quick,
                         [engine = QPointer(backend)](Qt::ApplicationState state) {
                             if (!engine) {
                                 return;
                             }
                             engine->setVisible(state == Qt::ApplicationActive);
                             // 只释放可重建的 CPU 缓存。场景图与 GPU 由 Qt Quick 自己随窗口收束。
                             if (state == Qt::ApplicationSuspended) {
                                 engine->trimMemory();
                             }
                         });
        backend->setVisible(QGuiApplication::applicationState() == Qt::ApplicationActive);
    }
}
