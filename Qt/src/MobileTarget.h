#pragma once
#include <QtGlobal>

// 移动端（iOS / Android）共用的能力边界。
//
// 这两个平台在构建期需要区别对待的地方很多（框架、ABI、包格式），但在"应用架构"这一层
// 结论是一致的：只有一个进程、没有独立的后台播放服务、没有桌面窗口装饰、切到后台要停止
// GPU 提交。把这些判断收在一个宏里，避免每个站点各写一遍平台或运算——写两遍迟早漂移，
// 而漂移的后果是 Android 打包时悄悄编进 QProcess 分支、启动即失败。
//
// 仍然保留 Q_OS_IOS 的地方是真正的平台专有实现（钥匙串、UIKit、NodeMobile 框架）。
#if defined(Q_OS_IOS) || defined(Q_OS_ANDROID)
#define RHINE_MOBILE 1
#else
#define RHINE_MOBILE 0
#endif

// Android 也定义 Q_OS_LINUX（Qt 的 Q_OS_ANDROID 蕴含它），但它的图形栈和桌面 Linux 没有关系：
// 没有 X11/DRI3、没有 Vulkan 呈现路径、也没有「选第 N 块显卡」这种入口，本地音频/媒体目录同理。
// 凡是只对桌面 Linux 成立的判断都用这个宏，别直接写 Q_OS_LINUX——那会把 Android 一起圈进去，
// 轻则编进桌面代码，重则像 initializeLinuxGraphics() 那样在链接期报未定义符号。
#if defined(Q_OS_LINUX) && !defined(Q_OS_ANDROID)
#define RHINE_LINUX_DESKTOP 1
#else
#define RHINE_LINUX_DESKTOP 0
#endif
