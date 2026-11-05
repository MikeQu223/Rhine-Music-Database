#pragma once
#include <QtGlobal>

// 平台特性宏
namespace PlatformFeatures {
#if defined(Q_OS_WIN) || defined(Q_OS_LINUX) || defined(Q_OS_MACOS)
inline constexpr bool MusicVideo = true;
#else
inline constexpr bool MusicVideo = false;
#endif
#ifdef Q_OS_WIN
inline constexpr bool DesktopWallpaper = true;
#else
inline constexpr bool DesktopWallpaper = false;
#endif
#ifdef Q_OS_IOS
inline constexpr bool OfficialPlayback = false;
inline constexpr bool LocalMusic = false;
inline constexpr bool ApplicationVolume = false;
inline constexpr bool DesktopWindowControls = false;
#else
inline constexpr bool OfficialPlayback = true;
inline constexpr bool LocalMusic = true;
inline constexpr bool ApplicationVolume = true;
inline constexpr bool DesktopWindowControls = true;
#endif
// 桌面悬浮歌词
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
inline constexpr bool DesktopLyrics = true;
#else
inline constexpr bool DesktopLyrics = false;
#endif
}
