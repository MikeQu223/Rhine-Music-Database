#pragma once

#include "FilamentContract.h"

#include <filament/Engine.h>
#include <filament/IndexBuffer.h>
#include <filament/Material.h>
#include <filament/MaterialInstance.h>
#include <filament/Texture.h>
#include <filament/VertexBuffer.h>

#include <map>
#include <vector>
#include <string>

namespace RhineFilament {

/** 一份几何在 Filament 侧的资源。顶点布局与导出脚本一致：pos3+normal3+uv2，stride 32。 */
struct MeshBuffers {
    filament::VertexBuffer *vertices = nullptr;
    filament::IndexBuffer *indices = nullptr;
    uint32_t vertexCount = 0;
    uint32_t indexCount = 0;
};

/** 材质、图集与几何的装载与缓存。只在 Filament 侧（libc++）使用。 */
class Assets {
  public:
    Assets(filament::Engine &engine, std::string root);
    ~Assets();

    bool loadMaterials();
    bool loadAtlases();
    /** 该批次对应的材质实例：按表面参数 + 状态 + 混合模式缓存，参数在桥接里每帧刷新。 */
    filament::MaterialInstance *instance(const DrawBatch &batch, uint64_t *outKey = nullptr);
    /** 该批次对应的几何；首次出现时创建并上传。 */
    const MeshBuffers *mesh(const DrawBatch &batch);
    /** 排障用：覆盖 NDC 的三角形（不依赖相机与场景数据）。 */
    const MeshBuffers *probeMesh();
    filament::Texture *atlas(int index) const {
        return m_atlas[index];
    }
    /** 按内容版本缓存封面/标签纹理（RGBA8 预乘）。 */
    filament::Texture *imageTexture(uint64_t revision, const void *pixels, uint32_t width,
                                    uint32_t height);
    /** 1x1 白色占位：label/cover 缺失时避免采样到未定义内容。 */
    filament::Texture *placeholder() const {
        return m_placeholder;
    }
    filament::Material *material(bool blend) const {
        return blend ? m_blend : m_opaque;
    }
    bool loaded() const {
        return m_opaque != nullptr;
    }
    /** 同一指针只销毁一次：Filament 对重复销毁是硬断言。 */
    template <typename T>
    void destroyOnce(T *object) {
        if (object == nullptr) {
            return;
        }
        void *key = static_cast<void *>(object);
        for (void *existing : m_destroyed) {
            if (existing == key) {
                return;
            }
        }
        m_destroyed.push_back(key);
        m_engine.destroy(object);
    }

  private:
    filament::Material *loadMaterial(const std::string &name) const;
    filament::Engine &m_engine;
    std::string m_root;
    filament::Material *m_opaque = nullptr;
    filament::Material *m_blend = nullptr;
    filament::Material *m_variants[8] = {};
    filament::Texture *m_atlas[3] = {};
    filament::Texture *m_placeholder = nullptr;
    std::map<uint64_t, filament::Texture *> m_images;
    std::map<int32_t, MeshBuffers> m_meshes;
    std::map<uint64_t, filament::MaterialInstance *> m_instances;
    // Filament 会复制 BufferDescriptor，回调可能被多次触发；上传内存统一由 Assets 持有，
    // 引擎销毁时再释放，避免 double free。
    std::vector<void *> m_uploads;
    std::vector<void *> m_destroyed;  // 同一指针只销毁一次（Filament 对重复销毁是硬断言）
};

}  // namespace RhineFilament
