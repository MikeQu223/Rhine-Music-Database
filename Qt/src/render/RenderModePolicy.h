#pragma once

#include "AndroidRenderPolicy.h"

#include <QSize>
#include <QString>
#include <QtGlobal>

#include <algorithm>

namespace RhineRender {

constexpr int MinimumRenderPercent = 50;
constexpr int MaximumRenderPercent = 200;
constexpr int MinimumSupersample = 1;
constexpr int MaximumSupersample = 2;

/**
 * 用户请求的 AA/帧生成与最终生效值。
 * 基础渲染倍率与旧版超采样因子的乘积超过 100% 时，超采样独占画质路径。
 * 保留 AA 和帧生成请求，乘积降回 100% 或以下时恢复。
 */
struct RenderMode {
    int renderPercent = 100;
    int supersample = 1;
    QString requestedAaMode = QStringLiteral("off");
    bool requestedFrameGeneration = false;
    bool supersampling = false;
    QString aaMode = QStringLiteral("off");
    bool frameGeneration = false;
};

inline int normalizedRenderPercent(int value, int fallback = 100) {
    const int usable = value > 0 ? value : fallback;
    return std::clamp(usable, MinimumRenderPercent, MaximumRenderPercent);
}

inline int normalizedSupersample(int value) {
    return std::clamp(value > 0 ? value : MinimumSupersample, MinimumSupersample, MaximumSupersample);
}

inline bool supersamplingEnabled(int renderPercent, int supersample) {
    const int percent = normalizedRenderPercent(renderPercent);
    const int factor = normalizedSupersample(supersample);
    return factor * percent > 100;
}

/** 设备纹理轴长有限时等比收缩离屏目标，保留请求倍率与窗口尺寸。 */
inline QSize fitRenderTextureSize(QSize requested, int maxTextureDimension) {
    if (maxTextureDimension <= 0 ||
        std::max(requested.width(), requested.height()) <= maxTextureDimension) {
        return requested;
    }
    return requested.scaled(maxTextureDimension, maxTextureDimension, Qt::KeepAspectRatio)
        .expandedTo(QSize(1, 1));
}

inline RenderMode resolveRenderMode(int renderPercent, int supersample, const QString &requestedAaMode,
                                    bool requestedFrameGeneration) {
    RenderMode result;
    result.renderPercent = normalizedRenderPercent(renderPercent);
    result.supersample = normalizedSupersample(supersample);
    result.supersampling = result.supersample * result.renderPercent > 100;
    result.requestedAaMode = requestedAaMode.trimmed().toLower();
    if (result.requestedAaMode.isEmpty()) {
        result.requestedAaMode = QStringLiteral("off");
    }
    result.requestedFrameGeneration = requestedFrameGeneration;
    result.aaMode = result.supersampling ? QStringLiteral("off") : result.requestedAaMode;
    result.frameGeneration = result.requestedFrameGeneration && !result.supersampling;
    return result;
}

inline RenderMode currentRenderMode(const QString &requestedAaMode, bool requestedFrameGeneration) {
    const int renderPercent = qEnvironmentVariableIntValue("RHINE_RENDER_SCALE");
    return resolveRenderMode(renderPercent > 0 ? renderPercent : androidDefaultRenderScale(),
                             qEnvironmentVariableIntValue("RHINE_SUPERSAMPLE"), requestedAaMode,
                             requestedFrameGeneration);
}

} // namespace RhineRender
