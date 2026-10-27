// Filament 关闭（或 SDK 缺失）时提供同名符号的空实现：Qt 侧保持单一代码路径，
// 所有调用立即降级回 legacy 链路，避免 RhiScene 里散落条件编译。
#include "FilamentBridge.h"

namespace RhineFilament {

Bridge::Bridge() = default;
Bridge::~Bridge() = default;

Bridge *Bridge::create() {
    // 调用方在真正渲染前会走 initialize()，这里返回非空占位以便统一处理。
    static Bridge stub;
    return &stub;
}

void Bridge::destroy(Bridge *) {}

bool Bridge::initialize(const SharedContext &, const char *, char *detail, uint32_t detailSize) {
    if (detail != nullptr && detailSize > 0) {
        detail[0] = '\0';
    }
    return false;
}

bool Bridge::resize(uint32_t, uint32_t) {
    return false;
}

bool Bridge::renderFrame(const FrameGlobals &, const DrawBatch *, uint32_t, FrameStats *) {
    return false;
}

ImageHandoff Bridge::handoff() const {
    return ImageHandoff{};
}

const char *Bridge::detail() const {
    return "Filament 未编入本次构建";
}

void Bridge::shutdown() {}

}  // namespace RhineFilament
