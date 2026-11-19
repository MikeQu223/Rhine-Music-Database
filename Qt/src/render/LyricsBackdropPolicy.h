#pragma once

#include <QSize>
#include <QSizeF>
#include <QtGlobal>
#include <algorithm>
#include <cmath>

namespace RhineRender {

// 低频刷新足以表现缓慢流动，也能避免歌词页为了背景重新进入 60Hz 调度。
constexpr int LyricsBackdropIntervalMs = 66;
constexpr int LyricsBackdropTargetHeight = 480;
constexpr int LyricsBackdropMaximumWidth = 854;

/** 背景只在目标页可见、实际播放且未减少动效时推进。 */
inline bool lyricsBackdropShouldAnimate(bool visible, bool playbackActive, bool reducedMotion,
                                        bool engineVisible) {
    return visible && playbackActive && !reducedMotion && engineVisible;
}

/** 固定背景高度并按宽屏上限收缩，所有平台用同一尺寸口径。 */
inline QSize lyricsBackdropTargetSize(QSizeF logicalSize) {
    if (!logicalSize.isValid() || logicalSize.width() <= 0 || logicalSize.height() <= 0) {
        return {};
    }
    const double scale = std::min({1.0, double(LyricsBackdropTargetHeight) / logicalSize.height(),
                                   double(LyricsBackdropMaximumWidth) / logicalSize.width()});
    return {qMax(1, qRound(logicalSize.width() * scale)), qMax(1, qRound(logicalSize.height() * scale))};
}

} // namespace RhineRender
