#pragma once
#include "DesktopLyricsLayout.h"
#include "SettingsCard.h"
#include <QRectF>

// 桌面歌词独立设置页
namespace DesktopLyricsSettingsPage {
struct Model {
    QRectF viewport;
    double scroll = 0;
    bool enabled = false;
    DesktopLyrics::Appearance appearance;
    double offsetMs = 0;
    double globalOffsetMs = 0;
};

struct Layout {
    double contentHeight = 0;
    double maximumScroll = 0;
};

Layout measure(const Model &model);
void paint(const Model &model, const SettingsCard::Colors &colors, const SettingsCard::Canvas &canvas);
}
