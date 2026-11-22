#pragma once

#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <QStringView>
#include <algorithm>

namespace RhineSentry {

struct RenderTelemetryState {
    QString phase = QStringLiteral("unknown");
    QString targetState = QStringLiteral("unknown");
    QString backend = QStringLiteral("unknown");
    int renderWidth = 0;
    int renderHeight = 0;
    int displayWidth = 0;
    int displayHeight = 0;
    qint64 resourceGeneration = 0;
    qint64 boundGeneration = 0;
    qint64 resizeSerial = 0;
    int framesInFlight = 0;
    bool frameGeneration = false;
    bool msaaResolve = false;
};

inline QJsonObject renderTelemetryContext(const RenderTelemetryState &state) {
    static const QStringList phases{"frame_begin",    "resize",    "pipeline_bind",
                                    "command_submit", "frame_end", "unknown"};
    static const QStringList targetStates{"valid", "out_of_date", "rebuilding", "destroyed", "unknown"};
    static const QStringList backends{"metal", "vulkan", "opengl", "opengles2",
                                      "d3d12", "d3d11",  "null",   "unknown"};
    const auto phase = phases.contains(state.phase) ? state.phase : QStringLiteral("unknown");
    const auto target =
        targetStates.contains(state.targetState) ? state.targetState : QStringLiteral("unknown");
    const auto backend = backends.contains(state.backend) ? state.backend : QStringLiteral("unknown");
    return {
        {QStringLiteral("phase"), phase},
        {QStringLiteral("targetState"), target},
        {QStringLiteral("backend"), backend},
        {QStringLiteral("renderWidth"), std::clamp(state.renderWidth, 0, 32768)},
        {QStringLiteral("renderHeight"), std::clamp(state.renderHeight, 0, 32768)},
        {QStringLiteral("displayWidth"), std::clamp(state.displayWidth, 0, 32768)},
        {QStringLiteral("displayHeight"), std::clamp(state.displayHeight, 0, 32768)},
        {QStringLiteral("resourceGeneration"),
         double(std::clamp<qint64>(state.resourceGeneration, 0, qint64(1000000000)))},
        {QStringLiteral("boundGeneration"),
         double(std::clamp<qint64>(state.boundGeneration, 0, qint64(1000000000)))},
        {QStringLiteral("resizeSerial"),
         double(std::clamp<qint64>(state.resizeSerial, 0, qint64(1000000000)))},
        {QStringLiteral("framesInFlight"), std::clamp(state.framesInFlight, 0, 16)},
        {QStringLiteral("frameGeneration"), state.frameGeneration},
        {QStringLiteral("msaaResolve"), state.msaaResolve},
    };
}

}
