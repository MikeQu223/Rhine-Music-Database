#pragma once
#include <QString>
#include <algorithm>

namespace MacMenuBar {
inline constexpr auto EnabledPreference = "menu-bar-lyrics-enabled";
inline constexpr auto ControlsPreference = "menu-bar-lyrics-controls";
inline constexpr auto IconPreference = "menu-bar-lyrics-icon";
inline constexpr auto WidthPreference = "menu-bar-lyrics-width";

// 菜单栏歌词的可见宽度以 macOS 逻辑点计。
inline constexpr int DefaultLyricWidth = 200;
inline constexpr int MinimumLyricWidth = 100;
inline constexpr int MaximumLyricWidth = 360;
inline constexpr int LyricWidthStep = 10;

inline bool isEnabled(const QString &preference) {
    return preference != QLatin1String("off");
}

inline int parseLyricWidth(const QString &preference) {
    bool ok = false;
    const int width = preference.toInt(&ok);
    if (!ok) {
        return DefaultLyricWidth;
    }

    const int clamped = std::clamp(width, MinimumLyricWidth, MaximumLyricWidth);
    return ((clamped + LyricWidthStep / 2) / LyricWidthStep) * LyricWidthStep;
}
}
