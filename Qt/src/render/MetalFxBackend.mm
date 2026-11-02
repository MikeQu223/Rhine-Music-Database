#include "MetalFxBackend.h"

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
void MetalFxFrameGenerator::release() {
    d->interpolator = nil;
    delete d->output;
    delete d->previous;
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
            d->format == format) {
            return true;
        }
        rhi->finish();
        release();
        d->output = outputTexture(rhi, displaySize, format);
        d->previous = outputTexture(rhi, displaySize, format);
        if (!d->output || !d->previous) {
            release();
            d->error = QStringLiteral("MetalFX 插帧纹理分配失败");
            return false;
        }
        auto descriptor = [[MTLFXFrameInterpolatorDescriptor alloc] init];
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
        effect.motionVectorScaleX = d->displaySize.width();
        effect.motionVectorScaleY = d->displaySize.height();
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
QRhiTexture *MetalFxTemporal::resolve(QRhiCommandBuffer *, QRhiTexture *color, QRhiTexture *, QRhiTexture *,
                                      QSize, QPointF, bool) {
    return color;
}
std::unique_ptr<FrameGenerator> createMetalFxFrameGenerator(QRhi *) {
    return {};
}
#endif

} // namespace RhineRender
