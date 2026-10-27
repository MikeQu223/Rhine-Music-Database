#include "FilamentAssets.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace RhineFilament {
namespace {

uint64_t hashBytes(uint64_t seed, const void *data, size_t size) {
    const auto *bytes = static_cast<const unsigned char *>(data);
    for (size_t i = 0; i < size; ++i) {
        seed ^= bytes[i];
        seed *= 1099511628211ull;
    }
    return seed;
}

std::vector<unsigned char> readFile(const std::string &path) {
    std::vector<unsigned char> data;
    FILE *file = std::fopen(path.c_str(), "rb");
    if (file == nullptr) {
        return data;
    }
    std::fseek(file, 0, SEEK_END);
    const long size = std::ftell(file);
    std::fseek(file, 0, SEEK_SET);
    if (size > 0) {
        data.resize(size_t(size));
        if (std::fread(data.data(), 1, data.size(), file) != data.size()) {
            data.clear();
        }
    }
    std::fclose(file);
    return data;
}

/** 图集尺寸由文件字节数唯一确定，避免再引入一份配置。 */
struct AtlasSpec {
    const char *file;
    uint32_t width;
    uint32_t height;
};

constexpr AtlasSpec kAtlases[3] = {
    {"archive-baked-surface.bin", 2304, 768},
    {"archive-baked-light.bin", 768, 1024},
    {"archive-baked-normal.bin", 128, 256},
};

}  // namespace

Assets::Assets(filament::Engine &engine, std::string root) : m_engine(engine), m_root(std::move(root)) {}

Assets::~Assets() {
    for (void *upload : m_uploads) {
        std::free(upload);
    }
    m_uploads.clear();
    for (auto &entry : m_instances) {
        destroyOnce(entry.second);
    }
    for (auto &entry : m_meshes) {
        if (entry.second.vertices != nullptr) {
            destroyOnce(entry.second.vertices);
        }
        if (entry.second.indices != nullptr) {
            destroyOnce(entry.second.indices);
        }
    }
    for (auto *texture : m_atlas) {
        if (texture != nullptr) {
            destroyOnce(texture);
        }
    }
    for (int index = 0; index < 8; ++index) {
        filament::Material *material = m_variants[index];
        if (material == nullptr) {
            continue;
        }
        bool duplicate = false;
        for (int earlier = 0; earlier < index; ++earlier) {
            duplicate = duplicate || m_variants[earlier] == material;
        }
        if (!duplicate) {
            destroyOnce(material);
        }
        m_variants[index] = nullptr;
    }
    m_opaque = nullptr;
    m_blend = nullptr;
}

filament::Material *Assets::loadMaterial(const std::string &name) const {
    const auto bytes = readFile(m_root + "/" + name);
    if (bytes.empty()) {
        return nullptr;
    }
    return filament::Material::Builder().package(bytes.data(), bytes.size()).build(m_engine);
}

bool Assets::loadMaterials() {
    if (std::getenv("RHINE_FILAMENT_PROBE_MAT") != nullptr) {
        // 排障：同一顶点着色器与参数，只把片元输出换成纯洋红，用来分清顶点与片元。
        filament::Material *probe = loadMaterial("opticalAtlas.filamat");
        if (probe != nullptr) {
            for (int index = 0; index < 8; ++index) {
                m_variants[index] = probe;
            }
            m_opaque = probe;
            m_blend = probe;
            return true;
        }
    }
    if (std::getenv("RHINE_FILAMENT_UNLIT") != nullptr) {
        // 排障：用极简 unlit 材质渲染同一批几何，用来判断问题在移植材质还是 draw 通路。
        filament::Material *probe = loadMaterial("probeUnlit.filamat");
        if (probe != nullptr) {
            for (int index = 0; index < 8; ++index) {
                m_variants[index] = probe;
            }
            m_opaque = probe;
            m_blend = probe;
            return true;
        }
    }
    // OpticalSurface.cmake 产出 6 个状态变体；按 (blend, depthWrite, doubleSided) 索引，
    // 缺哪个就回落到同混合模式的任意变体（C3：降级但仍能出画面）。
    static const struct {
        const char *file;
        bool blend;
        bool depthWrite;
        bool doubleSided;
    } kVariants[] = {
        {"OpticalSurface_opaque_depthwrite_1sided.filamat", false, true, false},
        {"OpticalSurface_opaque_depthwrite_2sided.filamat", false, true, true},
        {"OpticalSurface_opaque_nodepthwrite_1sided.filamat", false, false, false},
        {"OpticalSurface_blend_alpha_depthwrite_2sided.filamat", true, true, true},
        {"OpticalSurface_blend_alpha_nodepthwrite_2sided.filamat", true, false, true},
        {"OpticalSurface_blend_alpha_nodepthwrite_1sided.filamat", true, false, false},
    };
    for (const auto &variant : kVariants) {
        filament::Material *material = loadMaterial(variant.file);
        if (material == nullptr) {
            continue;
        }
        const int index = (variant.blend ? 4 : 0) | (variant.depthWrite ? 2 : 0) | (variant.doubleSided ? 1 : 0);
        if (m_variants[index] == nullptr) {
            m_variants[index] = material;
        } else {
            destroyOnce(material);
        }
    }
    // 回退材质：资源缺失时至少还能出几何（诊断材质只有 8 个表面参数）。
    if (m_variants[0] == nullptr) {
        m_variants[0] = loadMaterial("diagnosticSurface.filamat");
    }
    if (m_variants[2] == nullptr) {
        m_variants[2] = m_variants[0];
    }
    if (m_variants[4] == nullptr) {
        m_variants[4] = m_variants[0];
    }
    if (m_variants[6] == nullptr) {
        m_variants[6] = m_variants[4];
    }
    m_opaque = m_variants[0];
    m_blend = m_variants[4];
    if (m_opaque != nullptr && m_placeholder == nullptr) {
        m_placeholder = filament::Texture::Builder()
                            .width(1)
                            .height(1)
                            .levels(1)
                            .sampler(filament::Texture::Sampler::SAMPLER_2D)
                            .format(filament::Texture::InternalFormat::RGBA8)
                            .usage(filament::Texture::Usage::SAMPLEABLE | filament::Texture::Usage::UPLOADABLE)
                            .build(m_engine);
        if (m_placeholder != nullptr) {
            // 排障开关：占位纹理改成纯红，用来判断画面是否来自占位采样。
            const bool forceRed = std::getenv("RHINE_FILAMENT_FORCE_PLACEHOLDER_RED") != nullptr;
            const unsigned char kWhite[4] = {static_cast<unsigned char>(forceRed ? 255 : 255),
                                             0,
                                             0,
                                             255};
            void *copy = std::malloc(4);
            if (copy != nullptr) {
                std::memcpy(copy, kWhite, 4);
                m_placeholder->setImage(
                    m_engine, 0,
                    filament::Texture::PixelBufferDescriptor(
                        copy, 4, filament::Texture::PixelBufferDescriptor::PixelDataFormat::RGBA,
                        filament::Texture::PixelBufferDescriptor::PixelDataType::UBYTE,
                        [](void *, size_t, void *) {}));
                m_uploads.push_back(copy);
            }
        }
    }
    return m_opaque != nullptr;
}

bool Assets::loadAtlases() {
    using Texture = filament::Texture;
    // 排障开关：把三张图集换成纯红 2×2，用来判断画面颜色是否来自图集采样。
    if (std::getenv("RHINE_FILAMENT_FORCE_ATLAS_RED") != nullptr) {
        const uint16_t halfOne = 0x3C00;
        const uint16_t halfZero = 0x0000;
        const uint16_t pixel[4] = {halfOne, halfZero, halfZero, halfOne};
        for (int index = 0; index < 3; ++index) {
            m_atlas[index] = Texture::Builder()
                                 .width(2)
                                 .height(2)
                                 .levels(1)
                                 .sampler(Texture::Sampler::SAMPLER_2D)
                                 .format(Texture::InternalFormat::RGBA16F)
                                 .usage(Texture::Usage::SAMPLEABLE | Texture::Usage::UPLOADABLE)
                                 .build(m_engine);
            const size_t bytes = 2u * 2u * 4u * sizeof(uint16_t);
            auto *copy = static_cast<uint16_t *>(std::malloc(bytes));
            if (copy == nullptr) {
                continue;
            }
            for (size_t texel = 0; texel < 4; ++texel) {
                std::memcpy(copy + texel * 4, pixel, sizeof(pixel));
            }
            m_atlas[index]->setImage(
                m_engine, 0,
                Texture::PixelBufferDescriptor(copy, bytes,
                                               Texture::PixelBufferDescriptor::PixelDataFormat::RGBA,
                                               Texture::PixelBufferDescriptor::PixelDataType::HALF,
                                               [](void *, size_t, void *) {}));
            m_uploads.push_back(copy);
        }
        return true;
    }
    for (int index = 0; index < 3; ++index) {
        const auto bytes = readFile(m_root + "/" + kAtlases[index].file);
        const size_t expected = size_t(kAtlases[index].width) * kAtlases[index].height * 8u;
        if (bytes.size() != expected) {
            continue;
        }
        m_atlas[index] = Texture::Builder()
                             .width(kAtlases[index].width)
                             .height(kAtlases[index].height)
                             .levels(1)
                             .sampler(Texture::Sampler::SAMPLER_2D)
                             .format(Texture::InternalFormat::RGBA16F)
                             .usage(Texture::Usage::SAMPLEABLE | Texture::Usage::UPLOADABLE)
                             .build(m_engine);
        void *copy = std::malloc(bytes.size());
        if (copy == nullptr) {
            continue;
        }
        std::memcpy(copy, bytes.data(), bytes.size());
        m_atlas[index]->setImage(
            m_engine, 0,
            Texture::PixelBufferDescriptor(copy, bytes.size(),
                                           Texture::PixelBufferDescriptor::PixelDataFormat::RGBA,
                                           Texture::PixelBufferDescriptor::PixelDataType::HALF,
                                           [](void *, size_t, void *) {}));
        m_uploads.push_back(copy);
    }
    return m_atlas[0] != nullptr;
}

const MeshBuffers *Assets::mesh(const DrawBatch &batch) {
    auto found = m_meshes.find(batch.meshId);
    if (found != m_meshes.end()) {
        return &found->second;
    }
    if (batch.vertices == nullptr || batch.indices == nullptr || batch.vertexCount == 0 ||
        batch.indexCount == 0) {
        return nullptr;
    }
    MeshBuffers buffers;
    buffers.vertexCount = batch.vertexCount;
    buffers.indexCount = batch.indexTotal > 0 ? batch.indexTotal : batch.indexCount;
    // 顶点布局与导出脚本一致：pos3 + normal3 + uv2（stride 32）。
    // Filament 没有独立法线属性：法线按 CUSTOM0 绑定，材质用 requires:["custom0","uv0"] 读取。
    using Attribute = filament::VertexBuffer::AttributeType;
    buffers.vertices = filament::VertexBuffer::Builder()
                           .vertexCount(batch.vertexCount)
                           .bufferCount(1)
                           .attribute(filament::VertexAttribute::POSITION, 0, Attribute::FLOAT3, 0, 32)
                           .attribute(filament::VertexAttribute::CUSTOM0, 0, Attribute::FLOAT3, 12, 32)
                           .attribute(filament::VertexAttribute::UV0, 0, Attribute::FLOAT2, 24, 32)
                           .build(m_engine);
    buffers.indices = filament::IndexBuffer::Builder()
                          .indexCount(buffers.indexCount)
                          .bufferType(filament::IndexBuffer::IndexType::UINT)
                          .build(m_engine);

    const size_t vertexBytes = size_t(batch.vertexCount) * 32u;
    const size_t indexBytes = size_t(buffers.indexCount) * 4u;
    void *vertexCopy = std::malloc(vertexBytes);
    void *indexCopy = std::malloc(indexBytes);
    if (vertexCopy == nullptr || indexCopy == nullptr) {
        std::free(vertexCopy);
        std::free(indexCopy);
        m_engine.destroy(buffers.vertices);
        m_engine.destroy(buffers.indices);
        return nullptr;
    }
    std::memcpy(vertexCopy, batch.vertices, vertexBytes);
    std::memcpy(indexCopy, batch.indices, indexBytes);
    // 上传是异步的：缓冲区必须活到 Filament 回调，故用堆副本 + 回调释放。
    buffers.vertices->setBufferAt(
        m_engine, 0,
        filament::VertexBuffer::BufferDescriptor(vertexCopy, vertexBytes,
                                                 [](void *, size_t, void *) {}));
    m_uploads.push_back(vertexCopy);
    buffers.indices->setBuffer(
        m_engine,
        filament::IndexBuffer::BufferDescriptor(indexCopy, indexBytes,
                                                [](void *, size_t, void *) {}));
    m_uploads.push_back(indexCopy);
    auto inserted = m_meshes.emplace(batch.meshId, buffers);
    return &inserted.first->second;
}

const MeshBuffers *Assets::probeMesh() {
    constexpr int kProbeId = -12345;
    auto found = m_meshes.find(kProbeId);
    if (found != m_meshes.end()) {
        return &found->second;
    }
    // pos3 + normal3 + uv2，覆盖整个 NDC 的大三角形。
    static const float kVertices[3 * 8] = {
        -1.0f, -1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f,
        3.0f,  -1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 2.0f, 0.0f,
        -1.0f, 3.0f,  0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 2.0f,
    };
    static const unsigned int kIndices[3] = {0, 1, 2};
    MeshBuffers buffers;
    buffers.vertexCount = 3;
    buffers.indexCount = 3;
    using Attribute = filament::VertexBuffer::AttributeType;
    buffers.vertices = filament::VertexBuffer::Builder()
                           .vertexCount(3)
                           .bufferCount(1)
                           .attribute(filament::VertexAttribute::POSITION, 0, Attribute::FLOAT3, 0, 32)
                           .attribute(filament::VertexAttribute::CUSTOM0, 0, Attribute::FLOAT3, 12, 32)
                           .attribute(filament::VertexAttribute::UV0, 0, Attribute::FLOAT2, 24, 32)
                           .build(m_engine);
    buffers.indices = filament::IndexBuffer::Builder()
                          .indexCount(3)
                          .bufferType(filament::IndexBuffer::IndexType::UINT)
                          .build(m_engine);
    auto *vertexCopy = static_cast<float *>(std::malloc(sizeof(kVertices)));
    auto *indexCopy = static_cast<unsigned int *>(std::malloc(sizeof(kIndices)));
    std::memcpy(vertexCopy, kVertices, sizeof(kVertices));
    std::memcpy(indexCopy, kIndices, sizeof(kIndices));
    buffers.vertices->setBufferAt(
        m_engine, 0,
        filament::VertexBuffer::BufferDescriptor(vertexCopy, sizeof(kVertices),
                                                 [](void *, size_t, void *) {}));
    buffers.indices->setBuffer(
        m_engine,
        filament::IndexBuffer::BufferDescriptor(indexCopy, sizeof(kIndices),
                                                [](void *, size_t, void *) {}));
    m_uploads.push_back(vertexCopy);
    m_uploads.push_back(indexCopy);
    auto inserted = m_meshes.emplace(kProbeId, buffers);
    return &inserted.first->second;
}

filament::Texture *Assets::imageTexture(uint64_t revision, const void *pixels, uint32_t width,
                                      uint32_t height) {
    if (revision == 0 || pixels == nullptr || width == 0 || height == 0) {
        return nullptr;
    }
    auto found = m_images.find(revision);
    if (found != m_images.end()) {
        return found->second;
    }
    using Texture = filament::Texture;
    Texture *texture = Texture::Builder()
                           .width(width)
                           .height(height)
                           .levels(1)
                           .sampler(Texture::Sampler::SAMPLER_2D)
                           .format(Texture::InternalFormat::RGBA8)
                           .usage(Texture::Usage::SAMPLEABLE | Texture::Usage::UPLOADABLE)
                           .build(m_engine);
    if (texture == nullptr) {
        return nullptr;
    }
    const size_t bytes = size_t(width) * height * 4u;
    void *copy = std::malloc(bytes);
    if (copy == nullptr) {
        m_engine.destroy(texture);
        return nullptr;
    }
    std::memcpy(copy, pixels, bytes);
    texture->setImage(m_engine, 0,
                      Texture::PixelBufferDescriptor(
                          copy, bytes, Texture::PixelBufferDescriptor::PixelDataFormat::RGBA,
                          Texture::PixelBufferDescriptor::PixelDataType::UBYTE,
                          [](void *, size_t, void *) {}));
    m_uploads.push_back(copy);
    m_images.emplace(revision, texture);
    return texture;
}

filament::MaterialInstance *Assets::instance(const DrawBatch &batch, uint64_t *outKey) {
    uint64_t key = 1469598103934665603ull;
    // 排障：强制走不透明变体，用来判断画面是否被 alpha 混合"透明化"。
    const bool transparent = batch.transparent && std::getenv("RHINE_FILAMENT_FORCE_OPAQUE") == nullptr;
    // 排障：强制选 2-sided 变体，用来判断三角形绕序是否与 Filament 期望相反。
    const bool doubleSided = batch.doubleSided || std::getenv("RHINE_FILAMENT_FORCE_TWOSIDED") != nullptr;
    key = hashBytes(key, &transparent, sizeof(transparent));
    key = hashBytes(key, &doubleSided, sizeof(doubleSided));
    key = hashBytes(key, batch.state, sizeof(batch.state));
    key = hashBytes(key, &batch.coverRevision, sizeof(batch.coverRevision));
    key = hashBytes(key, &batch.labelRevision, sizeof(batch.labelRevision));
    if (batch.surface != nullptr && batch.surfaceWords >= 8u) {
        key = hashBytes(key, batch.surface, size_t(batch.surfaceWords) * sizeof(float));
    }
    if (outKey != nullptr) {
        *outKey = key;
    }
    auto found = m_instances.find(key);
    if (found != m_instances.end()) {
        return found->second;
    }
    const int variantIndex = (transparent ? 4 : 0) | (batch.depthWrite ? 2 : 0) | (doubleSided ? 1 : 0);
    filament::Material *material = m_variants[variantIndex];
    if (material == nullptr) {
        material = m_opaque;
    }
    if (material == nullptr) {
        return nullptr;
    }
    filament::MaterialInstance *instance = material->createInstance();
    m_instances.emplace(key, instance);
    return instance;
}

}  // namespace RhineFilament
