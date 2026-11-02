#include "DesktopLyricsWindow.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <QDebug>
#include <QWindow>
#include <memory>

namespace {

class MacDesktopLyricsPlatform final : public DesktopLyricsPlatform {
  public:
    void attach(QWindow *window) override {
        if (!window) {
            return;
        }
        NSView *view = (__bridge NSView *)(reinterpret_cast<void *>(window->winId()));
        NSWindow *panel = view.window;
        if (!panel) {
            qWarning() << "Desktop lyrics: native window is not available";
            return;
        }

        // 透明 shaped 窗口由 AppKit 自己合成，不能依赖 Qt 的默认不透明层。
        panel.opaque = NO;
        panel.backgroundColor = NSColor.clearColor;
        panel.hasShadow = NO;
        panel.level = NSFloatingWindowLevel;
        // 跨 Space 与全屏应用显示；Stationary 避免 Mission Control 把歌词窗口带走。
        panel.collectionBehavior =
            NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary |
            NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
        panel.ignoresMouseEvents = YES;
        panel.hidesOnDeactivate = NO;
        panel.releasedWhenClosed = NO;
        panel.excludedFromWindowsMenu = YES;
        panel.movableByWindowBackground = NO;
        if ([panel isKindOfClass:[NSPanel class]]) {
            NSPanel *lyricsPanel = (NSPanel *)panel;
            lyricsPanel.becomesKeyOnlyIfNeeded = YES;
        }
        view.wantsLayer = YES;
        view.layer.opaque = NO;
    }
};

}

std::unique_ptr<DesktopLyricsPlatform> createDesktopLyricsPlatform() {
    return std::make_unique<MacDesktopLyricsPlatform>();
}
