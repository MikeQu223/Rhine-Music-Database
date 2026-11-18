#include "IOSWindow.h"
#include "Engine.h"
#include <QGuiApplication>
#include <QPointer>
#include <QQuickWindow>
#include <QString>
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

namespace {
UIWindow *nativeWindow(QWindow *window) {
    if (!window || !window->isExposed() || !window->handle()) {
        return nil;
    }
    UIView *view = (__bridge UIView *)reinterpret_cast<void *>(window->winId());
    return view.window;
}
} // namespace

/** 从真正上屏的 Qt 窗口展示分享面板，兼容使用离屏 QML 的 Metal 呈现层。 */
bool shareIOSFile(const QString &path, std::function<void()> finished) {
    if (QGuiApplication::applicationState() != Qt::ApplicationActive) {
        return false;
    }

    UIWindow *window = nativeWindow(QGuiApplication::focusWindow());
    if (!window) {
        for (auto *candidate : QGuiApplication::topLevelWindows()) {
            window = nativeWindow(candidate);
            if (window) {
                break;
            }
        }
    }

    UIViewController *presenter = window.rootViewController;
    while (presenter.presentedViewController) {
        presenter = presenter.presentedViewController;
    }
    if (!presenter.viewIfLoaded.window || presenter.isBeingDismissed || presenter.isBeingPresented ||
        [presenter isKindOfClass:UIActivityViewController.class]) {
        return false;
    }

    NSURL *file = [NSURL fileURLWithPath:path.toNSString() isDirectory:NO];
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[ file ]
                                                                        applicationActivities:nil];
    sheet.completionWithItemsHandler = ^(UIActivityType, BOOL, NSArray *, NSError *) {
      dispatch_async(dispatch_get_main_queue(), ^{
        finished();
      });
    };
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        sheet.modalPresentationStyle = UIModalPresentationPopover;
        UIPopoverPresentationController *popover = sheet.popoverPresentationController;
        popover.sourceView = presenter.view;
        const CGRect bounds = presenter.view.bounds;
        popover.sourceRect = CGRectMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds), 1, 1);
        popover.permittedArrowDirections = 0;
    }
    [presenter presentViewController:sheet animated:YES completion:nil];
    return true;
}
