#include "IOSDisplayLink.h"

#include <QtDebug>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

namespace {
using DisplayLinkBlock = void (^)(CADisplayLink *);
using DisplayLinkFactory = CADisplayLink *(*)(id, SEL, DisplayLinkBlock);

// method_setImplementation 返回的 Qt 原始实现；替换实现必须回调它，不能递归。
IMP qtDisplayLinkWithBlock = nullptr;

/** 在 Qt 创建屏幕 DisplayLink 后写入高刷请求范围，其余行为保持原样。 */
CADisplayLink *displayLinkWithHighRefreshRange(id self, SEL command, DisplayLinkBlock block) {
    const auto factory = reinterpret_cast<DisplayLinkFactory>(qtDisplayLinkWithBlock);
    CADisplayLink *displayLink = factory(self, command, block);
    // iPhone 的 ProMotion 默认仍按 60Hz 调度；只有显式请求 80–120Hz 才会被系统采用。
    // 60Hz 设备、低电量模式和过热状态由系统自行降档。
    displayLink.preferredFrameRateRange = CAFrameRateRangeMake(80.0, 120.0, 120.0);
    return displayLink;
}
}

void configureIOSDisplayLinkFrameRate() {
    const auto screen = [UIScreen mainScreen];
    NSNumber *proMotionOptIn =
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CADisableMinimumFrameDurationOnPhone"];
    const bool plistEnabled = proMotionOptIn ? proMotionOptIn.boolValue : false;
    qInfo() << "iOS ProMotion: maximumFramesPerSecond"
            << static_cast<qint64>(screen.maximumFramesPerSecond) << "plist opt-in" << plistEnabled;
    if (screen.maximumFramesPerSecond < 120) {
        // 非 ProMotion 设备没有 120Hz 可选，保持 Qt 的默认调度。
        return;
    }
    Method method = class_getInstanceMethod([UIScreen class], @selector(displayLinkWithBlock:));
    if (!method) {
        // Qt 6.12 的 QIOSScreen 用该工厂创建屏幕显示链接；方法缺失时保持默认帧率。
        qWarning() << "iOS ProMotion: Qt display link factory not found; keep system default.";
        return;
    }
    qtDisplayLinkWithBlock =
        method_setImplementation(method, reinterpret_cast<IMP>(displayLinkWithHighRefreshRange));
    qInfo() << "iOS ProMotion: requested 80-120 Hz for Qt display link.";
}
