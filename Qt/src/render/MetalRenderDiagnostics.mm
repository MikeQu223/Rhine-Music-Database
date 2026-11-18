#include "MetalRenderDiagnostics.h"

#include <QList>
#include <QQuickWindow>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>
#include <numeric>
#include <rhi/qrhi_platform.h>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <os/signpost.h>

namespace RhineRender {
namespace {
constexpr qsizetype MAX_SAMPLES = 2048;

struct CommandSamples {
    QList<double> durationsMs;
    int missing = 0;
    int dropped = 0;
};

struct Diagnostics {
    std::atomic<quint64> generation{0};
    std::mutex mutex;
    CommandSamples rendering;
    CommandSamples interpolation;
};

const auto diagnostics = std::make_shared<Diagnostics>();

/** 只观察应用已经录制的命令；回调不访问窗口，也不会延长 GPU 执行。 */
void observe(id<MTLCommandBuffer> commands, CommandSamples Diagnostics::*source) {
    const auto generation = diagnostics->generation.load(std::memory_order_relaxed);
    if (!(generation & 1)) {
        return;
    }
    if (!commands) {
        std::lock_guard lock(diagnostics->mutex);
        if (diagnostics->generation.load(std::memory_order_relaxed) == generation) {
            ++((*diagnostics).*source).missing;
        }
        return;
    }
    auto state = diagnostics;
    [commands addCompletedHandler:^(id<MTLCommandBuffer> completed) {
      const double start = completed.GPUStartTime;
      const double end = completed.GPUEndTime;
      std::lock_guard lock(state->mutex);
      if (state->generation.load(std::memory_order_relaxed) != generation) {
          return;
      }
      auto &samples = (*state).*source;
      if (completed.status != MTLCommandBufferStatusCompleted || start <= 0 || end <= start ||
          !std::isfinite(start) || !std::isfinite(end)) {
          ++samples.missing;
      } else if (samples.durationsMs.size() < MAX_SAMPLES) {
          samples.durationsMs.append((end - start) * 1000.);
      } else {
          ++samples.dropped;
      }
    }];
}

QVariantMap summarize(CommandSamples samples) {
    QVariantMap result{
        {QStringLiteral("samples"), samples.durationsMs.size()},
        {QStringLiteral("missing"), samples.missing},
        {QStringLiteral("dropped"), samples.dropped},
    };
    auto &durations = samples.durationsMs;
    if (!durations.isEmpty()) {
        std::sort(durations.begin(), durations.end());
        const auto percentile = [&durations](double fraction) {
            return durations.at(qsizetype(std::ceil(durations.size() * fraction)) - 1);
        };
        result.insert(QStringLiteral("medianMs"), percentile(0.5));
        result.insert(QStringLiteral("p95Ms"), percentile(0.95));
        result.insert(QStringLiteral("commandDurationSumMs"),
                      std::accumulate(durations.cbegin(), durations.cend(), 0.));
    }
    return result;
}
} // namespace

void setMetalDiagnosticsEnabled(bool enabled) {
    std::lock_guard lock(diagnostics->mutex);
    const auto generation = diagnostics->generation.load(std::memory_order_relaxed);
    if (bool(generation & 1) == enabled) {
        return;
    }
    diagnostics->rendering = {};
    diagnostics->interpolation = {};
    diagnostics->generation.store(generation + 1, std::memory_order_relaxed);
}

void markMetalDiagnosticsRecording(bool recording) {
    static const os_log_t log = os_log_create("com.rhine.music", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
    if (recording) {
        os_signpost_interval_begin(log, OS_SIGNPOST_ID_EXCLUSIVE, "Rhine Performance Recording");
    } else {
        os_signpost_interval_end(log, OS_SIGNPOST_ID_EXCLUSIVE, "Rhine Performance Recording");
    }
}

void observeMetalWindow(QQuickWindow *window) {
    auto *renderer = window->rendererInterface();
    if (renderer->graphicsApi() != QSGRendererInterface::Metal) {
        return;
    }
    // afterRendering 可能已退出场景图的录制上下文；交换链仍持有本帧的命令缓冲。
    auto *swapchain = window->swapChain();
    observeMetalCommands(swapchain ? swapchain->currentFrameCommandBuffer() : nullptr);
}

void observeMetalCommands(QRhiCommandBuffer *commands) {
    const auto *handles =
        commands ? static_cast<const QRhiMetalCommandBufferNativeHandles *>(commands->nativeHandles())
                 : nullptr;
    observe(handles ? (id<MTLCommandBuffer>)handles->commandBuffer : nil, &Diagnostics::rendering);
}

void observeMetalInterpolation(void *commandBuffer) {
    observe((__bridge id<MTLCommandBuffer>)commandBuffer, &Diagnostics::interpolation);
}

QVariantMap takeMetalDiagnostics() {
    CommandSamples rendering;
    CommandSamples interpolation;
    {
        std::lock_guard lock(diagnostics->mutex);
        std::swap(rendering, diagnostics->rendering);
        std::swap(interpolation, diagnostics->interpolation);
    }

    NSProcessInfo *process = NSProcessInfo.processInfo;
    return {
        {QStringLiteral("scope"), QStringLiteral("mainPresentation")},
        {QStringLiteral("rendering"), summarize(std::move(rendering))},
        {QStringLiteral("asyncInterpolation"), summarize(std::move(interpolation))},
        {QStringLiteral("thermalState"), int(process.thermalState)},
        {QStringLiteral("lowPowerMode"), bool(process.lowPowerModeEnabled)},
        {QStringLiteral("gpuPowerStatus"), QStringLiteral("unavailable")},
    };
}
} // namespace RhineRender
