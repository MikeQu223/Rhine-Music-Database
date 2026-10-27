#pragma once
// Filament 适配的跨翻译单元契约。
//
// 两侧编译参数不同，必须只经由此头交接：
//  - Filament 侧（FilamentPlatform/FilamentAssets/FilamentScene/FilamentBridge 的实现）
//    以 -stdlib=libc++ -fno-rtti 编译，因为预编译的 Filament 静态库是 libc++ ABI；
//  - Qt 侧（RhiScene/Engine/NativeHudController）以默认 libstdc++ 编译。
// 因此本头不得包含 Qt、Vulkan 或任何 std 容器：只有 POD 与整型句柄。
#include <cstdint>

namespace RhineFilament {

/** 适配状态：提交给遥测与设置页。 */
enum class State : uint8_t { Off = 0, Active = 1, Degraded = 2 };
const char *stateName(State state) noexcept;

/** 失败码：写入偏好 filament-last-error，格式 "<code>: <detail>"。 */
enum class Error : uint8_t {
    None = 0,
    Disabled,
    BackendUnsupported,
    SharedContext,
    EngineCreate,
    SceneCreate,
    MaterialLoad,
    MaterialMissing,
    ImageHandoff,
    FirstFrame,
    SizeInvalid,
    Sync,
    Runtime,
};
const char *errorCode(Error error) noexcept;

/** 宿主 Vulkan 上下文。句柄由 QRhi 侧填写，Filament 侧只读。 */
struct SharedContext {
    uint64_t instance = 0;
    uint64_t physicalDevice = 0;
    uint64_t device = 0;
    uint32_t graphicsFamily = 0;
    uint32_t graphicsIndex = 0;
    bool multiview = false;
    bool valid() const noexcept {
        return instance != 0 && physicalDevice != 0 && device != 0 && graphicsFamily != 0xFFFFFFFFu;
    }
};

/** 图像交接结果：宿主自建镜像，Filament 渲染进它，Qt 侧用 QRhiTexture::createFrom 认领。 */
struct ImageHandoff {
    uint64_t image = 0;
    uint32_t format = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t sampledLayout = 0;
    bool valid() const noexcept {
        return image != 0 && width != 0 && height != 0;
    }
};

/** 每帧全局参数。矩阵按列主序 16 floats。 */
struct FrameGlobals {
    float view[16] = {};
    float projection[16] = {};
    float correction[16] = {};
    float emitterInverse[16] = {};
    float emitterWorld[16] = {};
    float eye[4] = {};
    float fogColor[4] = {};
    float fog[4] = {};
    float viewport[4] = {};
    float clip[4] = {};
    float opticalLight[4] = {};
    float emissionColor[4] = {};
    float background[3] = {};
    bool lighting = true;
};

/** 单个绘制批次。指针只在调用期有效，桥接必须在下一次调用前复制需要的数据。 */
struct DrawBatch {
    const void *vertices = nullptr;
    const void *indices = nullptr;
    uint32_t vertexCount = 0;
    uint32_t indexCount = 0;
    uint32_t indexStart = 0;
    uint32_t indexTotal = 0;  // 索引缓冲总长度（分块/偏移前），0 表示等于 indexCount
    const float *instances = nullptr;  // 每实例 20 floats：mat4 model + vec4 state
    uint32_t instanceCount = 0;
    const float *surface = nullptr;  // 32 floats：color/physical/optics/attenuation/extra/flags/darkColor/emission
    uint32_t surfaceWords = 0;
    float state[4] = {};  // quality/clarity/theme/mode：同一批次内必须一致（Qt 侧按此分桶）
    int32_t priority = 4;
    bool transparent = false;
    bool depthWrite = true;
    bool doubleSided = false;
    bool hashed = false;
    int32_t labelDraws = 0;
    uint64_t labelKey = 0;
    int32_t meshId = -1;
    // 封面/标签：RGBA8 预乘像素与内容版本号。为空时桥接绑白色占位纹理。
    const void *coverPixels = nullptr;
    uint32_t coverWidth = 0;
    uint32_t coverHeight = 0;
    uint64_t coverRevision = 0;
    const void *labelPixels = nullptr;
    uint32_t labelWidth = 0;
    uint32_t labelHeight = 0;
    uint64_t labelRevision = 0;
};

/** 桥接每帧统计。 */
struct FrameStats {
    uint32_t entities = 0;
    uint32_t draws = 0;
    uint32_t created = 0;
    uint32_t released = 0;
    float syncMs = 0.0f;
};

}  // namespace RhineFilament
