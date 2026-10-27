#pragma once

#include "FilamentContract.h"

#include <filament/Engine.h>
#include <filament/InstanceBuffer.h>
#include <filament/Scene.h>
#include <utils/Entity.h>
#include <utils/EntityManager.h>

#include <map>
#include <vector>

namespace RhineFilament {

class Assets;

/**
 * 实体池：同一个 (meshId, 材质键, 出现序号) 复用同一个 Renderable，
 * 每帧只更新实例变换与材质参数，连续两帧未出现才销毁——避免 T6/T7 的每帧重建与显存增长。
 */
class Collection {
  public:
    Collection(filament::Engine &engine, filament::Scene &scene, Assets &assets);
    ~Collection();
    void sync(const DrawBatch *batches, uint32_t batchCount, uint32_t generation,
              const FrameGlobals &globals, FrameStats *stats);
    uint32_t liveCount() const {
        return uint32_t(m_slots.size());
    }
    void clear();

  private:
    struct Slot {
        utils::Entity entity;
        filament::InstanceBuffer *instances = nullptr;
        uint32_t instanceCount = 0;
        int32_t meshId = -1;
        uint64_t materialKey = 0;
        uint32_t lastSeen = 0;
        bool alive = false;
    };
    Slot *acquire(uint64_t key, uint32_t occurrence, const DrawBatch &batch, uint32_t generation);
    bool configure(Slot &slot, const DrawBatch &batch);
    void syncChunk(const DrawBatch &batch, uint64_t key, uint32_t occurrence, uint32_t generation,
                   const FrameGlobals &globals, FrameStats *stats);
    void finishSync(uint32_t generation, FrameStats *stats);
    filament::Engine &m_engine;
    filament::Scene &m_scene;
    Assets &m_assets;
    std::map<uint64_t, std::vector<Slot>> m_slots;
    std::vector<float> m_transforms;
    uint32_t m_maxInstances = 64;
};

}  // namespace RhineFilament
