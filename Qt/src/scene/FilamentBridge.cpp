#include "FilamentBridge.h"

#include "FilamentAssets.h"
#include "FilamentPlatform.h"
#include "FilamentScene.h"

#include <filament/Camera.h>
#include <filament/Engine.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/SwapChain.h>
#include <filament/View.h>
#include <filament/Viewport.h>

#include <backend/platforms/VulkanPlatform.h>
#include <math/mat4.h>
#include <math/norm.h>
#include <utils/EntityManager.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>

namespace RhineFilament {
namespace {

filament::math::mat4f toMatrix(const float *values) {
    filament::math::mat4f matrix;
    std::memcpy(&matrix, values, sizeof(float) * 16);
    return matrix;
}

}  // namespace

struct BridgeImpl {
    State state = State::Off;
    Error error = Error::None;
    std::string detail;

    std::unique_ptr<Platform> platform;
    filament::Engine *engine = nullptr;
    filament::Renderer *renderer = nullptr;
    filament::Scene *scene = nullptr;
    filament::View *view = nullptr;
    filament::Camera *camera = nullptr;
    filament::SwapChain *swapChain = nullptr;
    utils::Entity cameraEntity;

    std::unique_ptr<Assets> assets;
    std::unique_ptr<Collection> collection;

    uint32_t generation = 0;
    bool ready = false;
    int32_t width = 0;
    int32_t height = 0;

    void fail(Error code, const std::string &text) {
        error = code;
        detail = text;
        state = State::Degraded;
        std::fprintf(stderr, "[filament] %s: %s\n", errorCode(code), text.c_str());
    }
};

Bridge::Bridge() : m_impl(new BridgeImpl()) {}

Bridge::~Bridge() {
    delete static_cast<BridgeImpl *>(m_impl);
    m_impl = nullptr;
}

Bridge *Bridge::create() {
    return new Bridge();
}

void Bridge::destroy(Bridge *bridge) {
    if (bridge == nullptr) {
        return;
    }
    bridge->shutdown();
    delete bridge;
}

bool Bridge::initialize(const SharedContext &context, const char *assetRoot, char *detail,
                        uint32_t detailSize) {
    auto *impl = static_cast<BridgeImpl *>(m_impl);
    auto publish = [detail, detailSize](const std::string &text) {
        if (detail != nullptr && detailSize > 0) {
            std::snprintf(detail, detailSize, "%s", text.c_str());
        }
    };
    if (!context.valid()) {
        impl->fail(Error::SharedContext, "invalid shared Vulkan context");
        publish(impl->detail);
        return false;
    }
    if (assetRoot == nullptr || assetRoot[0] == 0) {
        impl->fail(Error::MaterialMissing, "empty asset root");
        publish(impl->detail);
        return false;
    }

    impl->platform = std::make_unique<Platform>(context);
    impl->platform->setSize(uint32_t(impl->width > 0 ? impl->width : 16),
                            uint32_t(impl->height > 0 ? impl->height : 16));

    // 共享上下文必须是 VulkanPlatform 自己的那份结构体，Filament 依据它取设备与队列。
    filament::backend::VulkanPlatform::VulkanSharedContext shared{};
    shared.instance = (VkInstance) context.instance;
    shared.physicalDevice = (VkPhysicalDevice) context.physicalDevice;
    shared.logicalDevice = (VkDevice) context.device;
    shared.graphicsQueueFamilyIndex = context.graphicsFamily;
    shared.graphicsQueueIndex = context.graphicsIndex;
    shared.multiviewSupported = context.multiview;

    impl->engine = filament::Engine::Builder()
                       .backend(filament::Engine::Backend::VULKAN)
                       .platform(impl->platform.get())
                       .sharedContext(&shared)
                       .build();
    if (impl->engine == nullptr) {
        impl->fail(Error::EngineCreate, "Engine::build() returned null");
        publish(impl->detail);
        return false;
    }

    impl->scene = impl->engine->createScene();
    impl->view = impl->engine->createView();
    impl->cameraEntity = utils::EntityManager::get().create();
    impl->camera = impl->engine->createCamera(impl->cameraEntity);
    impl->renderer = impl->engine->createRenderer();
    if (impl->scene == nullptr || impl->view == nullptr || impl->camera == nullptr ||
        impl->renderer == nullptr) {
        impl->fail(Error::SceneCreate, "scene/view/camera/renderer creation failed");
        publish(impl->detail);
        return false;
    }

    impl->view->setScene(impl->scene);
    impl->view->setCamera(impl->camera);
    // 关闭 Filament 的全部后处理默认值：色调映射/FXAA/AO 都必须由本仓库自己的链路负责。
    impl->view->setPostProcessingEnabled(false);
    impl->view->setAntiAliasing(filament::View::AntiAliasing::NONE);
    impl->view->setDithering(filament::View::Dithering::NONE);
    impl->view->setColorGrading(nullptr);
    impl->view->setAmbientOcclusionOptions({});
    impl->view->setBloomOptions({});
    impl->view->setBlendMode(filament::View::BlendMode::OPAQUE);

    impl->assets = std::make_unique<Assets>(*impl->engine, std::string(assetRoot));
    if (!impl->assets->loadMaterials()) {
        impl->fail(Error::MaterialLoad, "no usable material package under the asset root");
        publish(impl->detail);
        return false;
    }
    if (!impl->assets->loadAtlases()) {
        impl->detail = "atlases missing; shading falls back to flat colours";
    }
    impl->collection = std::make_unique<Collection>(*impl->engine, *impl->scene, *impl->assets);

    impl->swapChain =
        impl->engine->createSwapChain(uint32_t(impl->width > 0 ? impl->width : 16),
                                      uint32_t(impl->height > 0 ? impl->height : 16), 0);
    if (impl->swapChain == nullptr) {
        impl->fail(Error::ImageHandoff, "Engine::createSwapChain returned null");
        publish(impl->detail);
        return false;
    }
    // 让异步创建落到驱动线程，随后就能取到宿主镜像的交接结果。
    impl->engine->flushAndWait();
    const ImageHandoff handoff = impl->platform->handoff();
    if (!handoff.valid()) {
        impl->fail(Error::ImageHandoff, "host image was not created");
        publish(impl->detail);
        return false;
    }
    impl->ready = true;
    impl->state = State::Active;
    impl->error = Error::None;
    publish(impl->detail);
    return true;
}

bool Bridge::resize(uint32_t width, uint32_t height) {
    auto *impl = static_cast<BridgeImpl *>(m_impl);
    if (width == 0 || height == 0) {
        impl->fail(Error::SizeInvalid, "zero-sized render target");
        return false;
    }
    impl->width = int32_t(width);
    impl->height = int32_t(height);
    if (impl->platform == nullptr) {
        return true;
    }
    impl->platform->setSize(width, height);
    if (impl->swapChain != nullptr) {
        // Engine 没有原地重建接口：销毁后按新尺寸重开，宿主镜像由平台在创建时重建。
        impl->engine->destroy(impl->swapChain);
        impl->swapChain = impl->engine->createSwapChain(width, height, 0);
        impl->engine->flushAndWait();
    }
    if (impl->view != nullptr) {
        impl->view->setViewport(filament::Viewport(0, 0, width, height));
    }
    return true;
}

bool Bridge::renderFrame(const FrameGlobals &globals, const DrawBatch *batches, uint32_t batchCount,
                         FrameStats *stats) {
    auto *impl = static_cast<BridgeImpl *>(m_impl);
    if (!impl->ready) {
        return false;
    }
    if (std::getenv("RHINE_FILAMENT_DEBUG") != nullptr) {
        static int vlog = 0;
        if (vlog < 2) {
            ++vlog;
            std::fprintf(stderr, "[filament] view t=(%.3f,%.3f,%.3f) m00=%.3f m01=%.3f m02=%.3f proj0=%.3f proj5=%.3f\n",
                         double(globals.view[12]), double(globals.view[13]), double(globals.view[14]),
                         double(globals.view[0]), double(globals.view[1]), double(globals.view[2]),
                         double(globals.projection[0]), double(globals.projection[5]));
            std::fflush(stderr);
        }
    }
    const filament::math::mat4f viewMatrix = filament::math::details::matrix::inverse(toMatrix(globals.view));
    impl->camera->setModelMatrix(filament::math::mat4(viewMatrix));
    if (std::getenv("RHINE_FILAMENT_DEBUG") != nullptr) {
        static int logged = 0;
        if (logged < 2) {
            ++logged;
            std::fprintf(stderr,
                         "[filament] eye=(%.2f,%.2f,%.2f) fwd=(%.2f,%.2f,%.2f) "
                         "P0=%.3f P5=%.3f P10=%.4f P11=%.3f P14=%.3f\n",
                         double(viewMatrix[3][0]), double(viewMatrix[3][1]), double(viewMatrix[3][2]),
                         double(-viewMatrix[2][0]), double(-viewMatrix[2][1]), double(-viewMatrix[2][2]),
                         double(globals.projection[0]), double(globals.projection[5]),
                         double(globals.projection[10]), double(globals.projection[11]),
                         double(globals.projection[14]));
            std::fflush(stderr);
        }
    }
    // 应用侧的投影是 Qt/Vulkan 裁剪空间（含 Y 翻转与 0..1 深度），与 Filament 期望的
    // GL 裁剪空间不同：必须折入 correction，否则几何全部落在可视范围外（实测只有清屏色）。
    if (std::getenv("RHINE_FILAMENT_FIXED_CAMERA") != nullptr) {
        // 排障：固定相机（在原点前方 800 处看向原点）。几何若出现，说明应用传入的
        // view/projection 与 Filament 的期望不兼容；仍空白则是几何/材质本身的问题。
        // 相机在 (0,0,800) 看向 -Z：view = translate(0,0,-800)，模型矩阵是其逆。
        const filament::math::mat4f translation =
            filament::math::mat4f::translation(filament::math::float3{0.0f, 0.0f, 800.0f});
        impl->camera->setModelMatrix(filament::math::mat4(translation));
        const double aspect =
            impl->height > 0 ? double(impl->width) / double(impl->height) : 1.0;
        impl->camera->setProjection(45.0, aspect, 1.0, 20000.0,
                                    filament::Camera::Fov::VERTICAL);
    } else {
        // 默认走纯投影（与 legacy 取景一致）；折入 correction 反而让整体变小。
        // 保留开关以便回归时 A/B。
        const filament::math::mat4f projection =
            std::getenv("RHINE_FILAMENT_WITH_CORRECTION") != nullptr
                ? toMatrix(globals.correction) * toMatrix(globals.projection)
                : toMatrix(globals.projection);
        impl->camera->setCustomProjection(filament::math::mat4(projection), 0.0, 10000.0);
    }
    impl->camera->setExposure(1.0f, 1.0f, 1.0f);

    float clearR = globals.background[0];
    float clearG = globals.background[1];
    float clearB = globals.background[2];
    if (std::getenv("RHINE_FILAMENT_DUMP") != nullptr) {
        // 排障：洋红清屏色——回读到洋红说明渲染管线在写，黑屏则是几何/相机不可见。
        clearR = 1.0f;
        clearG = 0.0f;
        clearB = 1.0f;
    }
    impl->renderer->setClearOptions({.clearColor = {clearR, clearG, clearB, 1.0},
                                     .clear = true,
                                     .discard = true});
    impl->view->setViewport(filament::Viewport(0, 0, uint32_t(impl->width), uint32_t(impl->height)));

    ++impl->generation;
    if (stats != nullptr) {
        *stats = {};
    }
    impl->collection->sync(batches, batchCount, impl->generation, globals, stats);

    if (!impl->renderer->beginFrame(impl->swapChain)) {
        impl->fail(Error::FirstFrame, "beginFrame returned false");
        return false;
    }
    impl->renderer->render(impl->view);
    if (std::getenv("RHINE_FILAMENT_DEBUG") != nullptr) {
        static int logged = 0;
        if (logged < 3) {
            ++logged;
            std::fprintf(stderr, " [filament] view visible=%d\n",
                         impl->view->getVisibleRenderableCount());
            std::fflush(stderr);
        }
    }
    impl->renderer->endFrame();
    // 串行化：QRhi 与本引擎共用同一个 graphics 队列，提交前必须等 Filament 彻底完成，
    // 同时保证宿主镜像已经切到可采样布局。
    impl->engine->flushAndWait();
    if (!impl->platform->ensureSampleable()) {
        impl->fail(Error::Sync, "host image could not be moved to a sampleable layout");
        return false;
    }
    return true;
}

ImageHandoff Bridge::handoff() const {
    const auto *impl = static_cast<const BridgeImpl *>(m_impl);
    return impl->platform != nullptr ? impl->platform->handoff() : ImageHandoff{};
}

State Bridge::state() const {
    return static_cast<const BridgeImpl *>(m_impl)->state;
}

Error Bridge::error() const {
    return static_cast<const BridgeImpl *>(m_impl)->error;
}

const char *Bridge::detail() const {
    return static_cast<const BridgeImpl *>(m_impl)->detail.c_str();
}

void Bridge::shutdown() {
    auto *impl = static_cast<BridgeImpl *>(m_impl);
    if (impl == nullptr) {
        return;
    }
    impl->ready = false;
    impl->collection.reset();
    impl->assets.reset();
    if (impl->engine != nullptr) {
        if (impl->swapChain != nullptr) {
            impl->engine->destroy(impl->swapChain);
            impl->swapChain = nullptr;
        }
        if (impl->renderer != nullptr) {
            impl->engine->destroy(impl->renderer);
            impl->renderer = nullptr;
        }
        if (impl->view != nullptr) {
            impl->engine->destroy(impl->view);
            impl->view = nullptr;
        }
        if (impl->scene != nullptr) {
            impl->engine->destroy(impl->scene);
            impl->scene = nullptr;
        }
        if (impl->camera != nullptr) {
            impl->engine->destroy(impl->cameraEntity);
            impl->camera = nullptr;
        }
        impl->engine->flushAndWait();
        // 引擎必须先于宿主 VkDevice 销毁（计划陷阱 T5）。
        filament::Engine::destroy(&impl->engine);
        impl->engine = nullptr;
    }
    impl->platform.reset();
    impl->state = State::Off;
    impl->error = Error::None;
    impl->detail.clear();
}

}  // namespace RhineFilament
