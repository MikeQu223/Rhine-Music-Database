#include "IOSWindow.h"
#include "Engine.h"
#include <QGuiApplication>
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

/** 按设备类型设定内容方向；允许后台释放图形资源 */
void configureIOSWindow(QWindow *window, Engine *backend) {
    window->reportContentOrientationChange(iosContentOrientation());
    window->showFullScreen();
    QObject::connect(qGuiApp, &QGuiApplication::applicationStateChanged, backend,
                     [backend, window](Qt::ApplicationState state) {
                         const bool active = state == Qt::ApplicationActive;
                         backend->setVisible(active);
                         if (!active) {
                             backend->trimMemory();
                             if (auto *quick = qobject_cast<QQuickWindow *>(window)) {
                                 quick->releaseResources();
                             }
                         }
                     });
}
