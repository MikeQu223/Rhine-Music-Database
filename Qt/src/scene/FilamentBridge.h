#pragma once

#include "FilamentContract.h"

namespace RhineFilament {

/**
 * Filament 渲染链路的唯一入口。
 *
 * 这个类由 libc++ 编译（Filament 预编译库是 libc++ ABI），Qt 侧只能通过这里声明的
 * POD 接口访问：不暴露任何 Filament 或 std 类型，避免两套 C++ 运行库在边界上交叠。
 */
class Bridge {
  public:
    static Bridge *create();
    static void destroy(Bridge *bridge);

    /** 探测并初始化：共享上下文 → 引擎 → 场景 → 材质 → 镜像交接。失败返回 false 并写明 detail。 */
    bool initialize(const SharedContext &context, const char *assetRoot, char *detail, uint32_t detailSize);
    /** 尺寸变化；下一帧重建宿主镜像。 */
    bool resize(uint32_t width, uint32_t height);
    /** 渲染一帧并同步等待完成；成功返回 true。 */
    bool renderFrame(const FrameGlobals &globals, const DrawBatch *batches, uint32_t batchCount, FrameStats *stats);
    /** 宿主镜像交接结果（QRhi 侧用 createFrom 认领）。 */
    ImageHandoff handoff() const;
    State state() const;
    Error error() const;
    const char *detail() const;
    /** 释放顺序：材质/缓冲 → 场景 → 视图 → 引擎 → 平台。 */
    void shutdown();

  private:
    Bridge();
    ~Bridge();
    Bridge(const Bridge &) = delete;
    Bridge &operator=(const Bridge &) = delete;
    void *m_impl = nullptr;
};

}  // namespace RhineFilament
