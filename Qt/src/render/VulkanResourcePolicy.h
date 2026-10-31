#pragma once

#include <QtCore/QByteArray>
#include <QtCore/QHashFunctions>
#include <QtCore/QtGlobal>

namespace RhineRender {

/**
 * D02：动态 UBO arena 的纯策略。
 *
 * 只做算术与边界判断，不碰 QRhi，方便离线验证：这些公式错一位就是"越界读 GPU 内存"
 * 或者"驱动直接丢弃绑定"，而它们本来可以不出现在驱动里。
 */

/// 对齐后的元素步长。alignment 必须是 2 的幂（QRhi::ubufAlignment() 保证）；非法时返回 0，
/// 调用方据此回退到逐材质 buffer。
inline quint32 arenaStride(quint32 elementSize, quint32 alignment)
{
    if (elementSize == 0 || alignment == 0 || (alignment & (alignment - 1)) != 0) {
        return 0;
    }
    const quint64 stride = (quint64(elementSize) + alignment - 1) / alignment * alignment;
    if (stride > 0xffffffffull) {
        return 0;
    }
    return quint32(stride);
}

/**
 * 单次绑定的暴露范围是否合法：
 *  · range 不能超过 MaxUniformBufferRange（它限制的是"一次绑定暴露多少"，不是 arena 总量）；
 *  · offset 必须按对齐步长落位，offset + range 不能越过 buffer 容量，且加法不能溢出。
 */
inline bool dynamicOffsetFits(quint64 offset, quint64 range, quint64 capacity, quint64 maxRange,
                              quint64 alignment = 0)
{
    if (range == 0 || range > maxRange) {
        return false;
    }
    if (alignment > 1 && (offset % alignment) != 0) {
        return false;
    }
    if (offset > capacity || range > capacity - offset) {
        return false;
    }
    return true;
}

/// 至少装下 needSlots 个 stride 的容量（字节）；超过 maxBytes 返回 0，表示这一档不可用。
inline quint64 arenaCapacityFor(quint32 stride, quint32 needSlots, quint64 maxBytes)
{
    if (stride == 0 || needSlots == 0) {
        return 0;
    }
    const quint64 bytes = quint64(stride) * quint64(needSlots);
    if (bytes == 0 || bytes > maxBytes) {
        return 0;
    }
    return bytes;
}


/// 实例池的容量规划：现有容量够用就原样返回，不够就按需翻倍（至少 4 MiB），
/// 超过 maxBytes 返回 0 表示这一档不可用（调用方回退到逐 draw buffer）。
inline quint64 instancePoolBytes(quint64 needBytes, quint64 currentBytes, quint64 maxBytes = 64ull << 20)
{
    const quint64 floorBytes = 4ull << 20;
    if (needBytes > maxBytes) {
        return 0;
    }
    if (currentBytes >= needBytes && currentBytes > 0) {
        return currentBytes;
    }
    quint64 bytes = currentBytes > 0 ? currentBytes : floorBytes;
    while (bytes < needBytes && bytes < maxBytes) {
        bytes *= 2;
    }
    if (bytes < needBytes || bytes > maxBytes) {
        return 0;
    }
    return bytes;
}

/**
 * 池化写是否需要真正上传：内容没变且落点没变才可跳过。
 * 只比内容不比起始偏移会让"顺序变了但单块内容相同"的帧读到上一位的数据。
 */
inline bool poolWriteNeeded(bool contentEqual, quint64 offset, quint64 previousOffset)
{
    return !contentEqual || offset != previousOffset;
}


/**
 * D04：深度是否必须保留。
 *
 * 只有确定没人读时才允许 DoNotStore；任一消费者存在就照旧 store。这里刻意保守：
 * 判断不了就当有人读——一次错误的 DONT_CARE 表现为"某一帧之后深度/时域全花"，很难回查。
 */
inline bool depthStoreRequired(bool motionConfigured, bool temporal, bool warpProbe, bool metalFxActive)
{
    return motionConfigured || temporal || warpProbe || metalFxActive;
}


/// 把偏移对齐到 alignment（2 的幂）；对齐非法时原样返回，交给调用方发现配置错误。
inline quint64 alignTo(quint64 value, quint64 alignment)
{
    if (alignment <= 1) {
        return value;
    }
    return (value + alignment - 1) / alignment * alignment;
}

/**
 * 绑定是否必须重设。
 * 只看 SRB 指针会把"同一个 SRB 的两个动态偏移"混成一次绑定，第二个 draw 就会读到
 * 第一个 draw 的材质；静态 SRB 的偏移没有意义，不参与比较。
 */
inline bool bindingRebindRequired(bool sameBindings, bool dynamic, bool previousDynamic, quint32 offset,
                                quint32 previousOffset)
{
    if (!sameBindings || dynamic != previousDynamic) {
        return true;
    }
    return dynamic && offset != previousOffset;
}

/// 缓存的共享资源还能不能用：arena／设备代号换代后必须重建。
inline bool resourceGenerationMatches(quint64 cached, quint64 current)
{
    return cached == current;
}

/// 缓存项该不该退休：本帧没被引用，或者代号已经过期。
inline bool pruneRetireNeeded(bool usedThisFrame, bool generationMatches)
{
    return !usedThisFrame || !generationMatches;
}

/// 整块直写必须覆盖本帧所有被引用的槽位，否则会读到上一帧的残值。
inline bool directWriteCoversAllSlots(quint32 writtenSlots, quint32 usedSlots)
{
    return writtenSlots >= usedSlots;
}


/**
 * E02：材质槽的按帧规划。
 *
 * 输入是"本帧真正要用的键数""回收后仍映射着的键数""可复用的空闲槽数"和"历史最高水位"。
 * 输出只包含真正需要新增的槽数：旧实现用 `used + draws.size()` 预留，会把同一个材质键
 * 重复计数，还会把已经不再出现的键永久算进需求，最后撞上 256 槽上限。
 */
struct MaterialSlotPlan {
    quint32 active = 0;
    quint32 reused = 0;
    quint32 fresh = 0;
    quint32 needSlots = 0;
};

inline MaterialSlotPlan planMaterialSlots(quint32 activeKeys, quint32 stillMapped, quint32 freeSlots,
                                          quint32 highWater)
{
    MaterialSlotPlan plan;
    plan.active = activeKeys;
    const quint32 wantFresh = activeKeys > stillMapped ? activeKeys - stillMapped : 0;
    plan.reused = wantFresh < freeSlots ? wantFresh : freeSlots;
    plan.fresh = wantFresh - plan.reused;
    plan.needSlots = highWater + plan.fresh;
    return plan;
}

/// 规划出来的槽位需求是否还在允许的槽位上限内（超了就该回退，而不是继续加容量）。
inline bool materialSlotPlanFits(quint32 needSlots, quint32 maxSlots)
{
    return needSlots <= maxSlots;
}

/**
 * E03：这一次写是否必须落地。
 *
 * 整块直写映射的是"当前原生帧"的缓冲副本，内容与上一帧相同也必须写满本帧引用到的槽位；
 * 只有走 updateDynamicBuffer 的 batch 路径才允许按内容去重。
 */
inline bool materialWriteRequired(bool mappedDirectWrite, bool contentEqual)
{
    return mappedDirectWrite || !contentEqual;
}

/// E03：把一段实例字节按 alignment 落到 cursor 之后的末尾（用于两段列表一起规划容量）。
inline quint64 poolSliceEnd(quint64 cursor, quint64 bytes, quint64 alignment = 4)
{
    const quint64 step = alignment ? alignment : 1;
    const quint64 offset = (cursor + step - 1) / step * step;
    return offset + bytes;
}

/// E03：切片是否完全落在容量内（溢出安全：先比 offset 再比剩余空间）。
inline bool poolSliceFits(quint64 offset, quint64 bytes, quint64 capacity)
{
    return offset <= capacity && bytes <= capacity - offset;
}

/**
 * E05a：紧凑实例（model64 + state16 = 80 字节）只在本次管线确实没有运动矢量
 * 或其他历史消费者时可用；有 motion／TAA／warp 就必须保留 144 字节的 previousModel。
 */
inline bool compactInstanceAllowed(bool requested, bool hasMotionConsumers)
{
    return requested && !hasMotionConsumers;
}

/// 实例步长：紧凑 80 字节，完整版按平台（Linux 144、其余 80）。
inline quint32 instanceStride(bool compact, quint32 fullStride)
{
    return compact ? 80u : fullStride;
}

/// 紧凑实例省掉的实例载荷比例：44.4%（64/144）。只是载荷口径，不是带宽或 FPS 预测。
inline double instancePayloadSaving(bool compact, quint32 fullStride)
{
    if (!compact || fullStride == 0) {
        return 0.0;
    }
    return double(fullStride - quint32(80)) / double(fullStride);
}

/**
 * E05b：pipeline 的"布局身份"。
 *
 * 原生 binding 布局只取决于「材质槽是否走动态偏移 arena」和「实例是否紧凑」，
 * 与具体 buffer 地址／代号无关——arena 扩容换了 buffer 不代表布局变了。
 */
inline quint64 pipelineLayoutSignature(bool arenaDynamic, bool compact)
{
    return (arenaDynamic ? 1ull : 0ull) | (compact ? 2ull : 0ull);
}

/// 只有布局身份变化才需要重建 pipeline；buffer 换代不需要。
inline bool pipelineRebuildRequired(quint64 cached, quint64 current)
{
    return cached != current;
}

} // namespace RhineRender

namespace RhineRender {

/// F03：烘焙批次的类型化键。
///
/// 旧实现每个候选 draw 都拼一条 `"baked/" + 8 个 QByteArray::number + ":" + 128 字节材质`，
/// 仅为了分组就要做八次数字转字符串与多次 append。这里改成逐字段比较：指针与整数直接比，
/// 材质仍是精确的 128 字节（不做浮点近似），相等与哈希出自同一组字段。
struct BatchKey {
    quintptr vertices = 0;
    quintptr indices = 0;
    quint32 start = 0;
    quint32 count = 0;
    int side = 0;
    int order = 0;
    quintptr label = 0;
    quintptr cover = 0;
    /// 材质按字节精确比较；长度固定为 sizeof(Surface)。
    QByteArray material;
    /// 实例 stride：紧凑与完整两种布局不能合并到同一批次。
    quint32 instanceStride = 0;

    bool operator==(const BatchKey &other) const
    {
        return vertices == other.vertices && indices == other.indices && start == other.start
               && count == other.count && side == other.side && order == other.order && label == other.label
               && cover == other.cover && material == other.material
               && instanceStride == other.instanceStride;
    }
    bool operator!=(const BatchKey &other) const { return !(*this == other); }
};

inline size_t qHash(const BatchKey &key, size_t seed = 0)
{
    return qHashMulti(seed, key.vertices, key.indices, key.start, key.count, key.side, key.order, key.label,
                      key.cover, qHash(key.material, seed), key.instanceStride);
}

/// 批次缓冲区身份：同上但不含材质（材质插值每帧变化，缓冲区按几何与槽位复用）。
struct BatchSlotKey {
    quintptr vertices = 0;
    quintptr indices = 0;
    quint32 start = 0;
    quint32 count = 0;
    int side = 0;
    int order = 0;
    quintptr label = 0;
    quintptr cover = 0;
    int slot = 0;

    bool operator==(const BatchSlotKey &other) const
    {
        return vertices == other.vertices && indices == other.indices && start == other.start
               && count == other.count && side == other.side && order == other.order && label == other.label
               && cover == other.cover && slot == other.slot;
    }
};

inline size_t qHash(const BatchSlotKey &key, size_t seed = 0)
{
    return qHashMulti(seed, key.vertices, key.indices, key.start, key.count, key.side, key.order, key.label,
                      key.cover, key.slot);
}

} // namespace RhineRender

namespace RhineRender {

/// 实例池身份：逐 draw 用引擎的 draw id，批次用几何+槽位键。
///
/// 旧实现把两者压成一条 QByteArray（`"d123"` / `"baked/..." + slot`），池镜像表因此每帧
/// 都要为每个 draw 拼字符串。类型化之后身份直接比较字段，池镜像与批次缓冲区共用同一套键。
struct PoolKey {
    bool valid = false;
    bool batch = false;
    int drawId = 0;
    BatchSlotKey slot;

    bool operator==(const PoolKey &other) const
    {
        if (valid != other.valid || batch != other.batch) {
            return false;
        }
        return batch ? slot == other.slot : drawId == other.drawId;
    }
};

inline size_t qHash(const PoolKey &key, size_t seed = 0)
{
    return key.batch ? qHashMulti(seed, key.batch, key.slot) : qHashMulti(seed, key.batch, key.drawId);
}

} // namespace RhineRender
