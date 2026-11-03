#include "MetalFxBackend.h"
#include "MetalFrameQueue.h"
#include <array>
#include <atomic>
#include <deque>
#include <map>
#include <mutex>
#include <vector>
#import <dispatch/dispatch.h>

#import <Metal/Metal.h>
#if __has_include(<MetalFX/MetalFX.h>)
#import <MetalFX/MetalFX.h>
#define RHINE_HAS_METALFX 1
#else
#define RHINE_HAS_METALFX 0
#endif
#include <rhi/qrhi_platform.h>
#include <cmath>

namespace RhineRender {

#if RHINE_HAS_METALFX
namespace {
id<MTLDevice> device(QRhi *rhi) {
    return (id<MTLDevice>)static_cast<const QRhiMetalNativeHandles *>(rhi->nativeHandles())->dev;
}
id<MTLTexture> texture(QRhiTexture *value) {
    return value ? (__bridge id<MTLTexture>)(void *)value->nativeTexture().object : nil;
}
id<MTLCommandBuffer> commandBuffer(QRhiCommandBuffer *commands) {
    return (id<MTLCommandBuffer>)static_cast<const QRhiMetalCommandBufferNativeHandles *>(
               commands->nativeHandles())
        ->commandBuffer;
}
bool hasUsage(id<MTLTexture> value, MTLTextureUsage required) {
    return value && (value.usage & required) == required;
}
/** Qt 使用非保留式命令缓冲；原生 MetalFX 资源必须活到这次 GPU 提交完成。 */
void retainUntilCompleted(id resource, id<MTLCommandBuffer> buffer) {
    __block id retainedResource = resource;
    [buffer addCompletedHandler:^(id<MTLCommandBuffer>) {
      retainedResource = nil;
    }];
}
QRhiTexture *outputTexture(QRhi *rhi, QSize size, QRhiTexture::Format format) {
    auto output =
        rhi->newTexture(format, size, 1, QRhiTexture::RenderTarget | QRhiTexture::UsedWithLoadStore);
    if (!output->create()) {
        delete output;
        return nullptr;
    }
    return output;
}
} // namespace

struct MetalFxTemporal::Private {
    QRhi *rhi;
    id<MTLFXTemporalScaler> scaler = nil;
    QRhiTexture *output = nullptr;
    QSize inputSize;
    QSize displaySize;
    bool encoded = false;
    bool firstFrame = true;
    bool reportedFailure = false;

    explicit Private(QRhi *value) : rhi(value) {
    }
    ~Private() {
        if (output) {
            output->deleteLater();
        }
    }
};

MetalFxTemporal::MetalFxTemporal(QRhi *rhi) : d(std::make_unique<Private>(rhi)) {
}
MetalFxTemporal::~MetalFxTemporal() = default;
bool MetalFxTemporal::supported(QRhi *rhi) {
    if (@available(macOS 13.0, iOS 16.0, *)) {
        return rhi && rhi->backend() == QRhi::Metal &&
               [MTLFXTemporalScalerDescriptor supportsDevice:device(rhi)];
    }
    return false;
}
bool MetalFxTemporal::active() const {
    return d->encoded;
}
void *MetalFxTemporal::nativeScaler() const {
    return (__bridge void *)d->scaler;
}

/** 消费本帧线性 HDR、深度和去抖动运动矢量；SDK 自行累积历史，失效时退回当前颜色。 */
QRhiTexture *MetalFxTemporal::resolve(QRhiCommandBuffer *commands, QRhiTexture *color, QRhiTexture *depth,
                                      QRhiTexture *motion, QSize displaySize, QPointF jitter, bool reset) {
    d->encoded = false;
    if (@available(macOS 13.0, iOS 16.0, *)) {
        if (!supported(d->rhi) || !color || !depth || !motion ||
            color->pixelSize().width() > displaySize.width() ||
            color->pixelSize().height() > displaySize.height()) {
            return color;
        }
        if (d->inputSize != color->pixelSize() || d->displaySize != displaySize) {
            d->scaler = nil;
            if (d->output) {
                d->output->deleteLater();
            }
            d->output = outputTexture(d->rhi, displaySize, QRhiTexture::RGBA16F);
            if (!d->output) {
                return color;
            }
            auto descriptor = [[MTLFXTemporalScalerDescriptor alloc] init];
            descriptor.inputWidth = color->pixelSize().width();
            descriptor.inputHeight = color->pixelSize().height();
            descriptor.outputWidth = displaySize.width();
            descriptor.outputHeight = displaySize.height();
            descriptor.colorTextureFormat = texture(color).pixelFormat;
            descriptor.depthTextureFormat = texture(depth).pixelFormat;
            descriptor.motionTextureFormat = texture(motion).pixelFormat;
            descriptor.outputTextureFormat = texture(d->output).pixelFormat;
            // 场景已有稳定曝光；不启用自动曝光，避免 MetalFX 改变既有材质亮度。
            descriptor.autoExposureEnabled = NO;
            d->scaler = [descriptor newTemporalScalerWithDevice:device(d->rhi)];
            d->inputSize = color->pixelSize();
            d->displaySize = displaySize;
            d->firstFrame = true;
            d->reportedFailure = false;
        }
        auto scaler = d->scaler;
        if (!scaler || !hasUsage(texture(color), scaler.colorTextureUsage) ||
            !hasUsage(texture(depth), scaler.depthTextureUsage) ||
            !hasUsage(texture(motion), scaler.motionTextureUsage) ||
            !hasUsage(texture(d->output), scaler.outputTextureUsage)) {
            if (!d->reportedFailure) {
                qWarning() << "MetalFX temporal texture requirements" << bool(scaler)
                           << quint64(texture(color).usage) << quint64(scaler.colorTextureUsage)
                           << quint64(texture(depth).usage) << quint64(scaler.depthTextureUsage)
                           << quint64(texture(motion).usage) << quint64(scaler.motionTextureUsage)
                           << quint64(texture(d->output).usage) << quint64(scaler.outputTextureUsage);
                d->reportedFailure = true;
            }
            return color;
        }
        scaler.colorTexture = texture(color);
        scaler.depthTexture = texture(depth);
        scaler.motionTexture = texture(motion);
        scaler.outputTexture = texture(d->output);
        scaler.inputContentWidth = d->inputSize.width();
        scaler.inputContentHeight = d->inputSize.height();
        scaler.preExposure = 1.f;
        scaler.jitterOffsetX = float(jitter.x());
        scaler.jitterOffsetY = float(jitter.y());
        // 公共运动纹理为 current→previous 的屏幕 UV 位移；MetalFX 输入使用像素单位。
        scaler.motionVectorScaleX = d->inputSize.width();
        scaler.motionVectorScaleY = d->inputSize.height();
        scaler.depthReversed = NO;
        scaler.reset = reset || d->firstFrame;
        commands->beginExternal();
        auto buffer = commandBuffer(commands);
        if (buffer) {
            // resize 或关闭 AA 可以立即更换上下文，但不能提前销毁在飞帧的原生管线。
            retainUntilCompleted(scaler, buffer);
            [scaler encodeToCommandBuffer:buffer];
            d->encoded = true;
            d->firstFrame = false;
        }
        commands->endExternal();
    }
    return d->encoded ? d->output : color;
}

#if __has_include(<MetalFX/MTLFXFrameInterpolator.h>)
class API_AVAILABLE(macos(26.0), ios(26.0)) MetalFxFrameGenerator : public FrameGenerator {
  public:
    MetalFxFrameGenerator();
    ~MetalFxFrameGenerator() override;
    static bool supported(QRhi *rhi);
    bool available() const override;
    void setTemporalSource(void *source) override;
    bool resize(QRhi *rhi, QSize renderSize, QSize displaySize, QRhiTexture::Format format) override;
    void release() override;
    void setCamera(float nearPlane, float farPlane, float fovYRadians, float frameTimeMs) override;
    void setJitter(float x, float y) override;
    void requestReset() override;
    bool prepare(QRhi *rhi, QRhiCommandBuffer *commands, QRhiTexture *color, QRhiTexture *depth,
                 QRhiTexture *motion) override;
    bool dispatch(QRhi *rhi, QRhiCommandBuffer *commands, QRhiTexture *color, QRhiTexture *colorWithoutUi,
                  QRhiTexture *output) override;
    QRhiTexture *output() const override;
    bool lastFrameReset() const override;
    QString lastError() const override;

  private:
    struct Private;
    std::unique_ptr<Private> d;
};

struct MetalFxFrameGenerator::Private {
    id<MTLFXFrameInterpolator> interpolator = nil;
    id<MTLFXFrameInterpolatableScaler> sourceScaler = nil;
    id<MTLFXFrameInterpolatableScaler> configuredScaler = nil;
    QRhiTexture *output = nullptr;
    QRhiTexture *previous = nullptr;
    QSize renderSize;
    QSize displaySize;
    QRhiTexture::Format format = QRhiTexture::UnknownFormat;
    bool reset = true;
    bool lastReset = true;
    QString error;
};
MetalFxFrameGenerator::MetalFxFrameGenerator() : d(std::make_unique<Private>()) {
}
MetalFxFrameGenerator::~MetalFxFrameGenerator() {
    release();
}
bool MetalFxFrameGenerator::supported(QRhi *rhi) {
    if (@available(macOS 26.0, iOS 26.0, *)) {
        return rhi && rhi->backend() == QRhi::Metal &&
               [MTLFXFrameInterpolatorDescriptor supportsDevice:device(rhi)];
    }
    return false;
}
bool MetalFxFrameGenerator::available() const {
    return d->interpolator != nil;
}
void MetalFxFrameGenerator::setTemporalSource(void *source) {
    d->sourceScaler = (__bridge id<MTLFXFrameInterpolatableScaler>)source;
}
void MetalFxFrameGenerator::release() {
    d->interpolator = nil;
    d->configuredScaler = nil;
    if (d->output) {
        d->output->deleteLater();
    }
    if (d->previous) {
        d->previous->deleteLater();
    }
    d->output = nullptr;
    d->previous = nullptr;
    d->reset = true;
}

/** 帧外重建原生插帧上下文；MetalFX 的接口要求调用者保留上一张无 UI 颜色。 */
bool MetalFxFrameGenerator::resize(QRhi *rhi, QSize renderSize, QSize displaySize,
                                   QRhiTexture::Format format) {
    if (@available(macOS 26.0, iOS 26.0, *)) {
        if (!supported(rhi)) {
            d->error = QStringLiteral("当前系统或设备不支持 MetalFX 帧生成");
            return false;
        }
        if (available() && d->renderSize == renderSize && d->displaySize == displaySize &&
            d->format == format && d->configuredScaler == d->sourceScaler) {
            return true;
        }
        release();
        d->output = outputTexture(rhi, displaySize, format);
        d->previous = outputTexture(rhi, displaySize, format);
        if (!d->output || !d->previous) {
            release();
            d->error = QStringLiteral("MetalFX 插帧纹理分配失败");
            return false;
        }
        auto descriptor = [[MTLFXFrameInterpolatorDescriptor alloc] init];
        descriptor.scaler = d->sourceScaler;
        descriptor.inputWidth = renderSize.width();
        descriptor.inputHeight = renderSize.height();
        descriptor.outputWidth = displaySize.width();
        descriptor.outputHeight = displaySize.height();
        descriptor.colorTextureFormat = texture(d->output).pixelFormat;
        descriptor.outputTextureFormat = texture(d->output).pixelFormat;
        descriptor.depthTextureFormat = MTLPixelFormatDepth32Float;
        descriptor.motionTextureFormat = MTLPixelFormatRGBA16Float;
        d->interpolator = [descriptor newFrameInterpolatorWithDevice:device(rhi)];
        if (!available()) {
            d->error = QStringLiteral("MetalFX 插帧上下文创建失败");
            release();
            return false;
        }
        d->configuredScaler = d->sourceScaler;
        d->renderSize = renderSize;
        d->displaySize = displaySize;
        d->format = format;
        d->error.clear();
        return true;
    }
    return false;
}
void MetalFxFrameGenerator::setCamera(float nearPlane, float farPlane, float fovYRadians, float frameTimeMs) {
    if (@available(macOS 26.0, iOS 26.0, *)) {
        d->interpolator.nearPlane = nearPlane;
        d->interpolator.farPlane = farPlane;
        d->interpolator.fieldOfView = fovYRadians * 180.f / float(M_PI);
        d->interpolator.aspectRatio = float(d->displaySize.width()) / d->displaySize.height();
        d->interpolator.deltaTime = frameTimeMs / 1000.f;
    }
}
void MetalFxFrameGenerator::setJitter(float x, float y) {
    if (@available(macOS 26.0, iOS 26.0, *)) {
        d->interpolator.jitterOffsetX = x;
        d->interpolator.jitterOffsetY = y;
    }
}
void MetalFxFrameGenerator::requestReset() {
    d->reset = true;
}
bool MetalFxFrameGenerator::prepare(QRhi *, QRhiCommandBuffer *, QRhiTexture *color, QRhiTexture *depth,
                                    QRhiTexture *motion) {
    if (@available(macOS 26.0, iOS 26.0, *)) {
        auto effect = d->interpolator;
        if (!effect || !hasUsage(texture(d->output), effect.outputTextureUsage) ||
            !hasUsage(texture(color), effect.colorTextureUsage) ||
            !hasUsage(texture(depth), effect.depthTextureUsage) ||
            !hasUsage(texture(motion), effect.motionTextureUsage)) {
            d->error = QStringLiteral("MetalFX 插帧输入纹理不符合原生要求");
            return false;
        }
        effect.colorTexture = texture(color);
        effect.depthTexture = texture(depth);
        effect.motionTexture = texture(motion);
        effect.prevColorTexture = texture(d->previous);
        effect.outputTexture = texture(d->output);
        effect.motionVectorScaleX = d->renderSize.width();
        effect.motionVectorScaleY = d->renderSize.height();
        effect.depthReversed = NO;
        effect.uiTextureComposited = NO;
        return true;
    }
    return false;
}
bool MetalFxFrameGenerator::dispatch(QRhi *, QRhiCommandBuffer *commands, QRhiTexture *color, QRhiTexture *,
                                     QRhiTexture *) {
    if (@available(macOS 26.0, iOS 26.0, *)) {
        auto buffer = commandBuffer(commands);
        if (!available() || !buffer) {
            return false;
        }
        d->lastReset = d->reset;
        d->interpolator.shouldResetHistory = d->reset;
        retainUntilCompleted(d->interpolator, buffer);
        [d->interpolator encodeToCommandBuffer:buffer];
        // 保留当前颜色给下一次官方插帧调用；不实现历史重投影或颜色混合。
        auto blit = [buffer blitCommandEncoder];
        [blit copyFromTexture:texture(color)
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(d->displaySize.width(), d->displaySize.height(), 1)
                    toTexture:texture(d->previous)
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        d->reset = false;
        return true;
    }
    return false;
}
QRhiTexture *MetalFxFrameGenerator::output() const {
    return d->output;
}
bool MetalFxFrameGenerator::lastFrameReset() const {
    return d->lastReset;
}
QString MetalFxFrameGenerator::lastError() const {
    return d->error;
}

#endif

std::unique_ptr<FrameGenerator> createMetalFxFrameGenerator(QRhi *rhi) {
#if __has_include(<MetalFX/MTLFXFrameInterpolator.h>)
    if (@available(macOS 26.0, iOS 26.0, *)) {
        if (MetalFxFrameGenerator::supported(rhi)) {
            return std::make_unique<MetalFxFrameGenerator>();
        }
    }
#else
    Q_UNUSED(rhi);
#endif
    return {};
}

#if __has_include(<MetalFX/MTLFXFrameInterpolator.h>)
namespace {
constexpr int kMetalQueueSlots = 5;
struct MetalQueueSlot {
    std::atomic<int> users{0};
    id<MTLTexture> real = nil;
    id<MTLTexture> working = nil;
    id<MTLTexture> depth = nil;
    id<MTLTexture> motion = nil;
    id<MTLTexture> output = nil;
    RhineFg::FrameInputs inputs;
    quint64 sequence = 0;
};

/** 只保存原生纹理及值类型参数；后台队列不调用 QRhi 或 Engine。 */
struct MetalQueueState {
    std::array<MetalQueueSlot, kMetalQueueSlots> packets;
    id<MTLCommandQueue> queue = nil;
    id effect = nil;
    dispatch_queue_t worker = nullptr;
    std::atomic<bool> cancelled{false};
    std::atomic<bool> failed{false};
    std::atomic<int> inFlight{0};
    std::atomic<int> readyCount{0};
    std::atomic<quint64> generated{0};
    std::atomic<quint64> gpuNanoseconds{0};
    std::atomic<quint64> completedBuffers{0};
    std::mutex mutex;
    std::deque<int> ready;
    QString error;
    std::map<quint64, int> completed;
    quint64 expectedSequence = 1;
    int previous = -1;
    QSize input;
    QSize working;
};

void failMetalQueue(const std::shared_ptr<MetalQueueState> &state, const QString &message) {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->error = message;
    state->failed.store(true);
}

/** 同一串行队列记录 SDK 工作；GPU 与窗口使用不同队列，只消费已经完成的快照。 */
void encodeMetalQueue(const std::shared_ptr<MetalQueueState> &shared, int index) {
    // 完成回调在 GPU 线程异步执行；参数是引用，块会把它当指针捕获，函数返回后即悬空。
    // 先复制成局部值，让块按值持有 shared_ptr。
    auto state = shared;
    if (@available(macOS 26.0, iOS 26.0, *)) {
        auto &slot = state->packets[index];
        if (state->cancelled.load() || state->failed.load()) {
            slot.users.fetch_sub(1);
            state->inFlight.fetch_sub(1);
            return;
        }
        const int previous = state->previous;
        const bool reset = previous < 0 || slot.inputs.reset;
        id<MTLFXFrameInterpolator> effect = state->effect;
        auto buffer = [state->queue commandBuffer];
        if (!buffer) {
            failMetalQueue(state, QStringLiteral("原生插帧命令缓冲创建失败"));
            slot.users.fetch_sub(1);
            state->inFlight.fetch_sub(1);
            return;
        }
        effect.colorTexture = slot.working;
        effect.prevColorTexture = previous >= 0 ? state->packets[previous].working : slot.working;
        effect.depthTexture = slot.depth;
        effect.motionTexture = slot.motion;
        effect.outputTexture = slot.output;
        effect.motionVectorScaleX = state->input.width();
        effect.motionVectorScaleY = state->input.height();
        effect.nearPlane = slot.inputs.nearPlane;
        effect.farPlane = slot.inputs.farPlane;
        effect.fieldOfView = slot.inputs.fovYRadians * 180.f / float(M_PI);
        effect.aspectRatio = float(state->working.width()) / state->working.height();
        effect.deltaTime = slot.inputs.frameTimeMs / 1000.f;
        effect.jitterOffsetX = float(slot.inputs.jitter.x());
        effect.jitterOffsetY = float(slot.inputs.jitter.y());
        effect.depthReversed = NO;
        effect.uiTextureComposited = NO;
        effect.shouldResetHistory = reset;
        [effect encodeToCommandBuffer:buffer];
        // 当前快照还要作为下一次插值的 previous，独立于待显示的引用。
        slot.users.fetch_add(1);
        state->previous = index;
        [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
          @autoreleasepool {
              if (completed.status != MTLCommandBufferStatusCompleted) {
                  failMetalQueue(state, QString::fromNSString(completed.error.localizedDescription));
              }
              if (!reset && !state->cancelled.load() && !state->failed.load()) {
                  std::lock_guard<std::mutex> lock(state->mutex);
                  state->ready.push_back(index);
                  state->readyCount.fetch_add(1);
                  state->generated.fetch_add(1);
              } else {
                  state->packets[index].users.fetch_sub(1);
              }
              if (previous >= 0) {
                  state->packets[previous].users.fetch_sub(1);
              }
              state->inFlight.fetch_sub(1);
          }
        }];
        [buffer commit];
    }
}
} // namespace

struct MetalFrameQueue::Private {
    struct Textures {
        QRhiTexture *real = nullptr;
        QRhiTexture *working = nullptr;
        QRhiTexture *depth = nullptr;
        QRhiTexture *motion = nullptr;
        QRhiTexture *output = nullptr;
    };
    std::array<Textures, kMetalQueueSlots> textures;
    std::vector<QRhiTexture *> resources;
    std::shared_ptr<MetalQueueState> state;
    quint64 sequence = 0;
};

MetalFrameQueue::MetalFrameQueue(QRhi *rhi, QSize render, QSize display, QSize working)
    : d(std::make_unique<Private>()) {
    if (@available(macOS 26.0, iOS 26.0, *)) {
        auto state = std::make_shared<MetalQueueState>();
        d->state = state;
        state->input = render;
        state->working = working;
        state->queue = [device(rhi) newCommandQueue];
        state->worker = dispatch_queue_create(
            "rhine.metalfx.frames",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        auto descriptor = [[MTLFXFrameInterpolatorDescriptor alloc] init];
        descriptor.inputWidth = render.width();
        descriptor.inputHeight = render.height();
        descriptor.outputWidth = working.width();
        descriptor.outputHeight = working.height();
        descriptor.colorTextureFormat = MTLPixelFormatRGBA8Unorm;
        descriptor.outputTextureFormat = MTLPixelFormatRGBA8Unorm;
        descriptor.depthTextureFormat = MTLPixelFormatDepth32Float;
        descriptor.motionTextureFormat = MTLPixelFormatRGBA16Float;
        state->effect = [descriptor newFrameInterpolatorWithDevice:device(rhi)];
        if (!state->queue || !state->effect) {
            failMetalQueue(state, QStringLiteral("异步原生插帧上下文创建失败"));
            return;
        }
        const auto allocate = [&](QSize size, QRhiTexture::Format format) {
            QRhiTexture::Flags flags = QRhiTexture::RenderTarget;
            if (format != QRhiTexture::D32F) {
                flags |= QRhiTexture::UsedWithLoadStore;
            }
            auto result = rhi->newTexture(format, size, 1, flags);
            d->resources.push_back(result);
            if (!result->create()) {
                failMetalQueue(state, QStringLiteral("异步插帧快照纹理创建失败"));
            }
            return result;
        };
        for (int index = 0; index < kMetalQueueSlots; ++index) {
            auto &targets = d->textures[index];
            auto &native = state->packets[index];
            targets.real = allocate(display, QRhiTexture::RGBA8);
            targets.working = working == display ? targets.real : allocate(working, QRhiTexture::RGBA8);
            targets.depth = allocate(render, QRhiTexture::D32F);
            targets.motion = allocate(render, QRhiTexture::RGBA16F);
            targets.output = allocate(working, QRhiTexture::RGBA8);
            if (state->failed.load()) {
                return;
            }
            native.real = texture(targets.real);
            native.working = texture(targets.working);
            native.depth = texture(targets.depth);
            native.motion = texture(targets.motion);
            native.output = texture(targets.output);
        }
    }
}
MetalFrameQueue::~MetalFrameQueue() {
    if (d->state) {
        d->state->cancelled.store(true);
    }
    // 在飞工作持有原生纹理，QRhi 包装在所属渲染线程延迟退役。
    for (auto value : d->resources) {
        value->deleteLater();
    }
}
bool MetalFrameQueue::available() const {
    return d->state && d->state->queue && d->state->effect && d->state->worker && !d->state->failed.load() &&
           !d->state->cancelled.load();
}
int MetalFrameQueue::reserve() {
    if (!available()) {
        return -1;
    }
    for (int index = 0; index < kMetalQueueSlots; ++index) {
        int expected = 0;
        if (d->state->packets[index].users.compare_exchange_strong(expected, 1)) {
            d->state->packets[index].sequence = ++d->sequence;
            d->state->inFlight.fetch_add(1);
            return index;
        }
    }
    return -1;
}
void MetalFrameQueue::capture(QRhiCommandBuffer *commands, int index, QRhiTexture *real, QRhiTexture *working,
                              const RhineFg::FrameInputs &inputs) {
    auto state = d->state;
    auto &slot = state->packets[index];
    slot.inputs = inputs;
    slot.inputs.depth = nullptr;
    slot.inputs.motionVectors = nullptr;
    auto buffer = commandBuffer(commands);
    auto blit = [buffer blitCommandEncoder];
    const auto copy = [&](id<MTLTexture> source, id<MTLTexture> destination) {
        [blit copyFromTexture:source
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(source.width, source.height, 1)
                    toTexture:destination
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
    };
    copy(texture(real), slot.real);
    if (working != real) {
        copy(texture(working), slot.working);
    }
    copy(texture(inputs.depth), slot.depth);
    copy(texture(inputs.motionVectors), slot.motion);
    [blit endEncoding];
    const quint64 sequence = slot.sequence;
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
      @autoreleasepool {
          if (completed.status != MTLCommandBufferStatusCompleted) {
              failMetalQueue(state, QString::fromNSString(completed.error.localizedDescription));
          }
          dispatch_async(state->worker, ^{
            @autoreleasepool {
                if (state->cancelled.load()) {
                    state->packets[index].users.fetch_sub(1);
                    state->inFlight.fetch_sub(1);
                    return;
                }
                state->completed.emplace(sequence, index);
                auto next = state->completed.find(state->expectedSequence);
                while (next != state->completed.end()) {
                    const int ready = next->second;
                    state->completed.erase(next);
                    ++state->expectedSequence;
                    encodeMetalQueue(state, ready);
                    next = state->completed.find(state->expectedSequence);
                }
            }
          });
      }
    }];
}
MetalFrameQueue::Frame MetalFrameQueue::take() {
    if (!available()) {
        return {};
    }
    std::lock_guard<std::mutex> lock(d->state->mutex);
    if (d->state->ready.empty()) {
        return {};
    }
    const int index = d->state->ready.front();
    d->state->ready.pop_front();
    d->state->readyCount.fetch_sub(1);
    return {d->textures[index].output, d->textures[index].real, index};
}
void MetalFrameQueue::release(QRhiCommandBuffer *commands, int index) {
    if (index < 0 || !d->state) {
        return;
    }
    auto state = d->state;
    auto buffer = commandBuffer(commands);
    [buffer addCompletedHandler:^(id<MTLCommandBuffer>) {
      state->packets[index].users.fetch_sub(1);
    }];
}
void MetalFrameQueue::cancel(QRhiCommandBuffer *commands, int index) {
    if (index < 0 || !d->state) {
        return;
    }
    auto state = d->state;
    auto buffer = commandBuffer(commands);
    [buffer addCompletedHandler:^(id<MTLCommandBuffer>) {
      state->packets[index].users.fetch_sub(1);
      state->inFlight.fetch_sub(1);
    }];
}
int MetalFrameQueue::inFlight() const {
    return d->state ? d->state->inFlight.load() + d->state->readyCount.load() : 0;
}
QVariantMap MetalFrameQueue::telemetry() const {
    if (!d->state) {
        return {{"asyncError", QStringLiteral("设备不支持异步原生插帧")}};
    }
    std::lock_guard<std::mutex> lock(d->state->mutex);
    return {{"asyncGenerated", qulonglong(d->state->generated.load())},
            {"asyncGpuNs", qulonglong(d->state->gpuNanoseconds.load())},
            {"asyncCompletedBuffers", qulonglong(d->state->completedBuffers.load())},
            {"asyncInFlight", d->state->inFlight.load()},
            {"asyncReady", d->state->readyCount.load()},
            {"asyncError", d->state->error}};
}
#else
struct MetalFrameQueue::Private {};
MetalFrameQueue::MetalFrameQueue(QRhi *, QSize, QSize, QSize) : d(std::make_unique<Private>()) {
}
MetalFrameQueue::~MetalFrameQueue() = default;
bool MetalFrameQueue::available() const {
    return false;
}
int MetalFrameQueue::reserve() {
    return -1;
}
void MetalFrameQueue::capture(QRhiCommandBuffer *, int, QRhiTexture *, QRhiTexture *,
                              const RhineFg::FrameInputs &) {
}
MetalFrameQueue::Frame MetalFrameQueue::take() {
    return {};
}
void MetalFrameQueue::release(QRhiCommandBuffer *, int) {
}
void MetalFrameQueue::cancel(QRhiCommandBuffer *, int) {
}
int MetalFrameQueue::inFlight() const {
    return 0;
}
QVariantMap MetalFrameQueue::telemetry() const {
    return {};
}

#endif

#else
// iOS 模拟器 SDK 不提供 MetalFX；保持同一呈现/配置接口，能力检测明确返回不可用。
struct MetalFxTemporal::Private {};
MetalFxTemporal::MetalFxTemporal(QRhi *) : d(std::make_unique<Private>()) {
}
MetalFxTemporal::~MetalFxTemporal() = default;
bool MetalFxTemporal::supported(QRhi *) {
    return false;
}
bool MetalFxTemporal::active() const {
    return false;
}
void *MetalFxTemporal::nativeScaler() const {
    return nullptr;
}
QRhiTexture *MetalFxTemporal::resolve(QRhiCommandBuffer *, QRhiTexture *color, QRhiTexture *, QRhiTexture *,
                                      QSize, QPointF, bool) {
    return color;
}
std::unique_ptr<FrameGenerator> createMetalFxFrameGenerator(QRhi *) {
    return {};
}
struct MetalFrameQueue::Private {};
MetalFrameQueue::MetalFrameQueue(QRhi *, QSize, QSize, QSize) : d(std::make_unique<Private>()) {
}
MetalFrameQueue::~MetalFrameQueue() = default;
bool MetalFrameQueue::available() const {
    return false;
}
int MetalFrameQueue::reserve() {
    return -1;
}
void MetalFrameQueue::capture(QRhiCommandBuffer *, int, QRhiTexture *, QRhiTexture *,
                              const RhineFg::FrameInputs &) {
}
MetalFrameQueue::Frame MetalFrameQueue::take() {
    return {};
}
void MetalFrameQueue::release(QRhiCommandBuffer *, int) {
}
void MetalFrameQueue::cancel(QRhiCommandBuffer *, int) {
}
int MetalFrameQueue::inFlight() const {
    return 0;
}
QVariantMap MetalFrameQueue::telemetry() const {
    return {};
}

#endif

} // namespace RhineRender
