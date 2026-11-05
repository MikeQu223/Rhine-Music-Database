#pragma once

#include "Glyphs.h"
#include <QJsonArray>
#include <QRectF>
#include <optional>

namespace PlayerBar {
// 展示快照不持有播放器、账号或页面控制器，便于主窗口和浮窗共享。
struct State {
    QString title;
    QString artist;
    QString album;
    QString cover;
    QString status;
    QString mode;
    double positionMs = 0;
    double durationMs = 0;
    double volume = 1;
    bool playing = false;
    bool loading = false;
    bool failed = false;
    bool hasTrack = false;
    bool seekable = false;
    bool applicationVolume = true;
    bool liked = false;
    bool likeKnown = false;
    bool canLike = false;
    bool musicVideo = false;
};

enum class Surface { Embedded, Floating };

struct Drawing {
    QJsonArray commands;
    QJsonArray hits;
    QRectF inputBounds;
    std::optional<QRectF> seek;
    std::optional<QRectF> volume;
};

// 高度以 HUD 舞台坐标为单位；浮窗额外组合独立的品牌头与状态尾。
constexpr double RowHeight = 96;
constexpr double HeaderHeight = 44;
constexpr double FooterHeight = 28;
Drawing render(const State &state, const QRectF &bounds, bool dark, Glyphs &glyphs,
               Surface surface = Surface::Embedded);
}
