#include "FilamentScene.h"

#include "FilamentAssets.h"

#include <filament/RenderableManager.h>
#include <filament/TransformManager.h>
#include <filament/TextureSampler.h>
#include <math/mat4.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <chrono>

namespace RhineFilament {
namespace {

uint64_t slotKey(const DrawBatch &batch, uint32_t chunk) {
    uint64_t key = 1469598103934665603ull;
    auto mix = [&key](uint64_t value) {
        key ^= value;
        key *= 1099511628211ull;
    };
    mix(uint64_t(uint32_t(batch.meshId)));
    mix(uint64_t(chunk));
    mix(uint64_t(batch.transparent));
    mix(uint64_t(batch.doubleSided));
    mix(uint64_t(batch.depthWrite));
    mix(uint64_t(batch.priority));
    for (float value : batch.state) {
        mix(uint64_t(*reinterpret_cast<const uint32_t *>(&value)));
    }
    if (batch.surface != nullptr) {
        for (uint32_t word = 0; word < batch.surfaceWords; ++word) {
            mix(uint64_t(*reinterpret_cast<const uint32_t *>(&batch.surface[word])));
        }
    }
    return key;
}

}  // namespace

Collection::Collection(filament::Engine &engine, filament::Scene &scene, Assets &assets)
    : m_engine(engine), m_scene(scene), m_assets(assets) {
    // Filament 用 InstanceBuffer 提供变换时的上限（本机 64）；超过就必须分块。
    const size_t limit = engine.getMaxAutomaticInstances();
    m_maxInstances = uint32_t(limit > 0 ? limit : 1);
}

Collection::~Collection() {
    clear();
}

void Collection::clear() {
    for (auto &entry : m_slots) {
        for (auto &slot : entry.second) {
            if (!slot.alive) {
                continue;
            }
            m_scene.remove(slot.entity);
            m_engine.destroy(slot.entity);
            if (slot.instances != nullptr) {
                m_engine.destroy(slot.instances);
                slot.instances = nullptr;
            }
            slot.alive = false;
        }
    }
    m_slots.clear();
}

Collection::Slot *Collection::acquire(uint64_t key, uint32_t occurrence, const DrawBatch &batch,
                                      uint32_t generation) {
    auto &slots = m_slots[key];
    while (slots.size() <= occurrence) {
        Slot slot;
        slot.entity = utils::EntityManager::get().create();
        slots.push_back(slot);
    }
    Slot &slot = slots[occurrence];
    slot.lastSeen = generation;
    if (!slot.alive || slot.instanceCount != batch.instanceCount || slot.meshId != batch.meshId) {
        if (!configure(slot, batch)) {
            return nullptr;
        }
    }
    return &slot;
}

bool Collection::configure(Slot &slot, const DrawBatch &batch) {
    const MeshBuffers *mesh = batch.meshId == -12345 ? m_assets.probeMesh() : m_assets.mesh(batch);
    uint64_t materialKey = 0;
    filament::MaterialInstance *material = m_assets.instance(batch, &materialKey);
    if (mesh == nullptr || material == nullptr || batch.instanceCount == 0) {
        return false;
    }
    if (slot.alive) {
        m_scene.remove(slot.entity);
        m_engine.destroy(slot.entity);
        slot.alive = false;
    }
    if (slot.instances != nullptr) {
        m_engine.destroy(slot.instances);
        slot.instances = nullptr;
    }
    slot.instances = filament::InstanceBuffer::Builder(batch.instanceCount).build(m_engine);
    if (slot.instances == nullptr) {
        return false;
    }
    if (std::getenv("RHINE_FILAMENT_DEBUG") != nullptr) {
        static int logged = 0;
        if (logged < 6) {
            ++logged;
            const auto *first = static_cast<const float *>(batch.vertices);
            std::fprintf(stderr,
                         "[filament] draw mesh=%d verts=%u idxTotal=%u idxStart=%u idxCount=%u "
                         "instances=%u pos0=(%.2f,%.2f,%.2f)\n",
                         batch.meshId, mesh->vertexCount, mesh->indexCount, batch.indexStart,
                         batch.indexCount, batch.instanceCount, double(first[0]), double(first[1]),
                         double(first[2]));
            std::fflush(stderr);
        }
    }
    filament::RenderableManager::Builder builder(1);
    builder.boundingBox({{-400.0f, -400.0f, -400.0f}, {400.0f, 400.0f, 400.0f}})
        .material(0, material)
        .geometry(0, filament::RenderableManager::PrimitiveType::TRIANGLES, mesh->vertices,
                  mesh->indices, batch.indexStart, batch.indexCount)
        .instances(batch.instanceCount, slot.instances)
        .priority(uint8_t(batch.priority < 0 ? 0 : (batch.priority > 7 ? 7 : batch.priority)))
        .culling(false)
        .castShadows(false)
        .receiveShadows(false);
    builder.build(m_engine, slot.entity);
    m_scene.addEntity(slot.entity);
    slot.instanceCount = batch.instanceCount;
    slot.meshId = batch.meshId;
    slot.materialKey = materialKey;
    slot.alive = true;
    return true;
}

void Collection::sync(const DrawBatch *batches, uint32_t batchCount, uint32_t generation,
                      const FrameGlobals &globals, FrameStats *stats) {
    const auto started = std::chrono::steady_clock::now();
    if (std::getenv("RHINE_FILAMENT_PROBE_QUAD") != nullptr) {
        // 排障：只用探针三角形，画不出就说明 draw/材质通路本身有问题。
        DrawBatch probe{};
        probe.meshId = -12345;
        probe.instanceCount = 1;
        static const float identity[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
        probe.instances = identity;
        probe.indexCount = 3;
        probe.indexTotal = 3;
        batchCount = 1;
        batches = &probe;
    }
    if (stats != nullptr) {
        stats->created = 0;
        stats->released = 0;
    }
    std::map<uint64_t, uint32_t> occurrences;
    for (uint32_t index = 0; index < batchCount; ++index) {
        const DrawBatch &batch = batches[index];
        if (batch.instanceCount == 0) {
            continue;
        }
        // 超过 Engine::getMaxAutomaticInstances() 的批次必须切块，否则 Filament 断言失败。
        for (uint32_t offset = 0; offset < batch.instanceCount; offset += m_maxInstances) {
            DrawBatch chunk = batch;
            const uint32_t chunkCount = std::min(m_maxInstances, batch.instanceCount - offset);
            chunk.instances = batch.instances + size_t(offset) * 20u;
            chunk.instanceCount = chunkCount;
            const uint32_t chunkIndex = offset / m_maxInstances;
            const uint64_t chunkKey = slotKey(chunk, chunkIndex);
            const uint32_t occurrence = occurrences[chunkKey]++;
            syncChunk(chunk, chunkKey, occurrence, generation, globals, stats);
        }
    }
    finishSync(generation, stats);
    if (stats != nullptr) {
        const auto finished = std::chrono::steady_clock::now();
        stats->syncMs = std::chrono::duration<float, std::milli>(finished - started).count();
    }
}

void Collection::syncChunk(const DrawBatch &batch, uint64_t key, uint32_t occurrence,
                           uint32_t generation, const FrameGlobals &globals, FrameStats *stats) {
    {
        Slot *slot = acquire(key, occurrence, batch, generation);
        if (slot == nullptr) {
            return;
        }
        static const bool unlitProbe = std::getenv("RHINE_FILAMENT_UNLIT") != nullptr;
        uint64_t materialKey = 0;
        filament::MaterialInstance *material = m_assets.instance(batch, &materialKey);
        if (material != nullptr && slot->materialKey != materialKey) {
            // 首帧建 renderable 时可能还没有曲目表面参数，键与后来不同：这里把绑定纠正过来，
            // 否则 setParameter 全部落在未被使用的实例上（画面永远是材质默认值）。
            auto &manager = m_engine.getRenderableManager();
            const auto instance = manager.getInstance(slot->entity);
            manager.setMaterialInstanceAt(instance, 0, material);
            slot->materialKey = materialKey;
        }
        if (material != nullptr && unlitProbe) {
            // 探针材质只有 color 一个参数：其余参数名不存在会触发 Filament 断言。
            material->setParameter("color", filament::math::float4{1.0f, 0.0f, 1.0f, 1.0f});
        } else if (material != nullptr) {
            const auto *surface = reinterpret_cast<const float *>(batch.surface);
            if (std::getenv("RHINE_FILAMENT_DEBUG") != nullptr) {
                static int logged = 0;
                if (logged < 3) {
                    ++logged;
                    std::fprintf(stderr,
                                 "[filament] surface w=%u color=(%.3f,%.3f,%.3f,%.3f) flags=(%.3f,"
                                 "%.3f,%.3f,%.3f) dark=(%.3f,%.3f,%.3f,%.3f)\n",
                                 batch.surfaceWords, double(surface[0]), double(surface[1]),
                                 double(surface[2]), double(surface[3]), double(surface[20]),
                                 double(surface[21]), double(surface[22]), double(surface[23]),
                                 double(surface[24]), double(surface[25]), double(surface[26]),
                                 double(surface[27]));
                    std::fprintf(stderr, "[filament] extra=(%.3f,%.3f,%.3f,%.3f) emission=(%.3f,%.3f,%.3f,%.3f)\n",
                                 double(surface[16]), double(surface[17]), double(surface[18]),
                                 double(surface[19]), double(surface[28]), double(surface[29]),
                                 double(surface[30]), double(surface[31]));
                    std::fflush(stderr);
                }
            }
            if (surface != nullptr && batch.surfaceWords >= 32u) {
                auto set4 = [&material, surface](const char *name, int index) {
                    material->setParameter(
                        name, filament::math::float4{surface[index * 4 + 0], surface[index * 4 + 1],
                                                     surface[index * 4 + 2], surface[index * 4 + 3]});
                };
                set4("surfaceColor", 0);
                set4("surfacePhysical", 1);
                set4("surfaceOptics", 2);
                set4("surfaceAttenuation", 3);
                set4("surfaceExtra", 4);
                set4("surfaceFlags", 5);
                set4("surfaceDarkColor", 6);
                set4("surfaceEmission", 7);
            }
            // 排障开关：强制红色用来判断画面发白是出在图集采样还是表面参数上。
            if (std::getenv("RHINE_FILAMENT_FORCE_WHITE") != nullptr) {
                static const filament::math::float4 white{1.0f, 1.0f, 1.0f, 1.0f};
                material->setParameter("surfaceColor", white);
                material->setParameter("surfaceDarkColor", white);
                material->setParameter("surfaceEmission", white);
            }
            if (std::getenv("RHINE_FILAMENT_FORCE_RED") != nullptr) {
                static const filament::math::float4 red{1.0f, 0.0f, 0.0f, 1.0f};
                material->setParameter("surfaceColor", red);
            }
            if (std::getenv("RHINE_FILAMENT_DEBUG") != nullptr) {
                static int stateLogged = 0;
                if (stateLogged < 3) {
                    ++stateLogged;
                    std::fprintf(stderr, "[filament] state q=%.3f clarity=%.3f theme=%.3f mode=%.3f\n",
                                 double(batch.state[0]), double(batch.state[1]),
                                 double(batch.state[2]), double(batch.state[3]));
                    std::fflush(stderr);
                }
            }
            // 排障：hashed 分支按 stateQuality 抖动剔除，quality=0 会把整片丢弃。
            material->setParameter("stateQuality",
                                   std::getenv("RHINE_FILAMENT_FORCE_QUALITY") != nullptr
                                       ? 1.0f
                                       : batch.state[0]);
            material->setParameter("stateClarity", batch.state[1]);
            material->setParameter("stateTheme", batch.state[2]);
            material->setParameter("stateMode", batch.state[3]);
            material->setDepthWrite(batch.depthWrite);
            material->setDoubleSided(batch.doubleSided);
            // 排障：强制双面 + 不剔除，用来判断绕序与 Filament 期望是否相反。
            const bool noCull = std::getenv("RHINE_FILAMENT_NO_CULL") != nullptr;
            if (noCull) {
                material->setDoubleSided(true);
                material->setCullingMode(filament::MaterialInstance::CullingMode::NONE);
            } else {
                material->setCullingMode(batch.doubleSided
                                             ? filament::MaterialInstance::CullingMode::NONE
                                             : filament::MaterialInstance::CullingMode::BACK);
            }
            // 帧级 uniform：不设置的话材质用默认 0，雾混合会把整片颜色压成黑色。
            {
                auto setVec4 = [&material](const char *name, const float *value) {
                    material->setParameter(
                        name, filament::math::float4{value[0], value[1], value[2], value[3]});
                };
                setVec4("eye", globals.eye);
                setVec4("fog", globals.fog);
                setVec4("fogColor", globals.fogColor);
                setVec4("viewport", globals.viewport);
                {
                    // 色彩标定系数。扫描实测（确定性合成图，3D 区 PSNR / 梯度能量比）：
                    //   1.0 → 21.30 dB / 0.39    1.15 → 22.14 / 0.32
                    //   1.3 → 22.34 dB / 0.26    1.5 → 22.19 / 0.19
                    // 取 PSNR 最优的 1.3；更高增益会把亮部夹到纯白，边缘能量显著下降。
                    // 仍可用 RHINE_FILAMENT_GAIN 覆盖以复测。
                    const char *gainText = std::getenv("RHINE_FILAMENT_GAIN");
                    const float gain = gainText != nullptr ? float(std::atof(gainText)) : 1.3f;
                    material->setParameter("gain", gain);
                }
                if (std::getenv("RHINE_FILAMENT_DEBUG") != nullptr) {
                    static int fl = 0;
                    if (fl < 2) {
                        ++fl;
                        std::fprintf(stderr,
                                     "[filament] viewport=(%.3f,%.3f,%.3f,%.3f) fog=(%.2f,%.2f,%.2f,%.2f) "
                                     "eye=(%.1f,%.1f,%.1f)\n",
                                     double(globals.viewport[0]), double(globals.viewport[1]),
                                     double(globals.viewport[2]), double(globals.viewport[3]),
                                     double(globals.fog[0]), double(globals.fog[1]),
                                     double(globals.fog[2]), double(globals.fog[3]),
                                     double(globals.eye[0]), double(globals.eye[1]),
                                     double(globals.eye[2]));
                        std::fprintf(stderr,
                                     "[filament] opticalLight=(%.3f,%.3f,%.3f,%.3f) "
                                     "emission=(%.3f,%.3f,%.3f,%.3f) fogColor=(%.2f,%.2f,%.2f,%.2f)\n",
                                     double(globals.opticalLight[0]), double(globals.opticalLight[1]),
                                     double(globals.opticalLight[2]), double(globals.opticalLight[3]),
                                     double(globals.emissionColor[0]), double(globals.emissionColor[1]),
                                     double(globals.emissionColor[2]), double(globals.emissionColor[3]),
                                     double(globals.fogColor[0]), double(globals.fogColor[1]),
                                     double(globals.fogColor[2]), double(globals.fogColor[3]));
                        std::fflush(stderr);
                        std::fflush(stderr);
                    }
                }
                setVec4("clip", globals.clip);
                setVec4("opticalLight", globals.opticalLight);
                setVec4("emissionColor", globals.emissionColor);
                auto toMat4 = [](const float *values) {
                    filament::math::mat4f matrix;
                    std::memcpy(&matrix, values, sizeof(float) * 16);
                    return matrix;
                };
                material->setParameter("emitterInverse", toMat4(globals.emitterInverse));
                if (std::getenv("RHINE_FILAMENT_DEBUG") != nullptr) {
                    static int em = 0;
                    if (em < 2) {
                        ++em;
                        std::fprintf(stderr,
                                     "[filament] emitterInverse = [%.3f %.3f %.3f %.3f] [%.3f %.3f %.3f %.3f]\n",
                                     double(globals.emitterInverse[0]), double(globals.emitterInverse[1]),
                                     double(globals.emitterInverse[2]), double(globals.emitterInverse[3]),
                                     double(globals.emitterInverse[4]), double(globals.emitterInverse[5]),
                                     double(globals.emitterInverse[6]), double(globals.emitterInverse[7]));
                        std::fflush(stderr);
                    }
                }
                material->setParameter("emitterWorld", toMat4(globals.emitterWorld));
            }
            // 封面/标签按内容版本取纹理；缺失时回落白色占位，避免未定义采样。
            filament::Texture *coverTexture =
                m_assets.imageTexture(batch.coverRevision, batch.coverPixels, batch.coverWidth,
                                      batch.coverHeight);
            filament::Texture *labelTexture =
                m_assets.imageTexture(batch.labelRevision, batch.labelPixels, batch.labelWidth,
                                      batch.labelHeight);
            filament::Texture *placeholder = m_assets.placeholder();
            if (coverTexture == nullptr) {
                coverTexture = placeholder;
            }
            if (labelTexture == nullptr) {
                labelTexture = placeholder;
            }
            if (coverTexture != nullptr) {
                material->setParameter("cover", coverTexture, filament::TextureSampler());
            }
            if (labelTexture != nullptr) {
                material->setParameter("label", labelTexture, filament::TextureSampler());
            }
            for (int atlas = 0; atlas < 3; ++atlas) {
                if (filament::Texture *texture = m_assets.atlas(atlas)) {
                    static const char *const names[3] = {"surfaceAtlas", "lightAtlas", "normalAtlas"};
                    material->setParameter(names[atlas], texture, filament::TextureSampler());
                }
            }
        }
        // 每实例 20 floats：前 16 是模型矩阵，后 4 是 state（本批次内一致，已用于材质参数）。
        m_transforms.assign(size_t(batch.instanceCount) * 16u, 0.0f);
        for (uint32_t instance = 0; instance < batch.instanceCount; ++instance) {
            const float *source = batch.instances + size_t(instance) * 20u;
            for (int word = 0; word < 16; ++word) {
                m_transforms[size_t(instance) * 16u + size_t(word)] = source[word];
            }
        }
        if (std::getenv("RHINE_FILAMENT_DEBUG") != nullptr) {
            static int dumped = 0;
            if (dumped < 1) {
                ++dumped;
                const auto *raw = reinterpret_cast<const float *>(batch.instances);
                std::fprintf(stderr,
                             "[filament] inst raw f12..f19 = %.3f %.3f %.3f %.3f | %.3f %.3f %.3f %.3f\n",
                             double(raw[12]), double(raw[13]), double(raw[14]), double(raw[15]),
                             double(raw[16]), double(raw[17]), double(raw[18]), double(raw[19]));
                std::fflush(stderr);
            }
        }
        if (std::getenv("RHINE_FILAMENT_DEBUG") != nullptr) {
            static int logged = 0;
            if (logged < 3) {
                ++logged;
                const float *m = m_transforms.data();
                std::fprintf(stderr,
                             "[filament] inst0 m[0]=%.3f m[5]=%.3f m[10]=%.3f t=(%.2f,%.2f,%.2f)\n",
                             double(m[0]), double(m[5]), double(m[10]), double(m[12]), double(m[13]),
                             double(m[14]));
                std::fflush(stderr);
            }
        }
        if (std::getenv("RHINE_FILAMENT_DEBUG") != nullptr) {
            static int logged = 0;
            if (logged < 2) {
                ++logged;
                const auto *base = reinterpret_cast<const float *>(batch.instances);
                std::fprintf(stderr, "[filament] chunk insts=%u t0=(%.2f,%.2f,%.2f) t1=(%.2f,%.2f,%.2f) t2=(%.2f,%.2f,%.2f)\n",
                             batch.instanceCount, double(base[12]), double(base[13]), double(base[14]),
                             double(base[32]), double(base[33]), double(base[34]),
                             double(base[52]), double(base[53]), double(base[54]));
                std::fflush(stderr);
            }
        }
        slot->instances->setLocalTransforms(
            reinterpret_cast<const filament::math::mat4f *>(m_transforms.data()), batch.instanceCount, 0);
        if (stats != nullptr) {
            ++stats->draws;
        }
    }
}

void Collection::finishSync(uint32_t generation, FrameStats *stats) {
    // 连续两帧未出现才销毁，避免相机切换时的抖动式重建。
    for (auto it = m_slots.begin(); it != m_slots.end();) {
        auto &slots = it->second;
        for (auto &slot : slots) {
            if (slot.alive && generation - slot.lastSeen > 1) {
                m_scene.remove(slot.entity);
                m_engine.destroy(slot.entity);
                if (slot.instances != nullptr) {
                    m_engine.destroy(slot.instances);
                    slot.instances = nullptr;
                }
                slot.alive = false;
                if (stats != nullptr) {
                    ++stats->released;
                }
            }
        }
        slots.erase(std::remove_if(slots.begin(), slots.end(), [](const Slot &slot) { return !slot.alive; }),
                    slots.end());
        it = slots.empty() ? m_slots.erase(it) : std::next(it);
    }
    if (stats != nullptr) {
        stats->entities = liveCount();
    }
}

}  // namespace RhineFilament
