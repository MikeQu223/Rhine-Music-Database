#pragma once

/**
 * 让 Qt 的 iOS 屏幕 DisplayLink 请求 ProMotion 高刷。
 * 必须在 QGuiApplication 构造前调用，否则 QIOSScreen 已按默认范围创建显示链接。
 */
void configureIOSDisplayLinkFrameRate();
