#pragma once

#include <QtCore/QString>

namespace RhineRender {

/**
 * D01：Vulkan 资源账本的窗口增量。
 *
 * 只做计数与格式化，不碰 QRhi，方便离线验证格式化逻辑。创建次数与稳态存量必须分开：
 * 前者说明"这个窗口新建了多少原生对象"（冷加载、扩容、resize 的信号），后者说明
 * "此刻一共有多少对象在活"（内存与绑定成本）。混在一起看时，一次 resize 造成的
 * 批量创建会被误读成每帧开销。
 */
struct VulkanResourceWindow {
    /// 本窗口新建的 Dynamic buffer 数（UBO 与实例 buffer 合计）。
    quint64 dynamicBufferCreates = 0;
    /// 本窗口真正提交的 updateDynamicBuffer 次数与复制字节。
    quint64 dynamicBufferUpdates = 0;
    quint64 dynamicBufferBytes = 0;
    /// 本窗口新建的 SRB 数；bindAborts 是"指针不同但绑定被去重"的次数。
    quint64 srbCreates = 0;
    quint64 srbBinds = 0;
    quint64 srbReuseSkips = 0;
    quint64 pipelineBinds = 0;
    /// 本窗口 beginPass 次数，以及其中深度内容被保留／显式丢弃的 pass 数。
    quint64 passes = 0;
    quint64 depthStorePasses = 0;
    quint64 depthDiscardPasses = 0;

    void clear() { *this = VulkanResourceWindow{}; }
};

/**
 * 某一时刻的稳态存量。usedBytes 只统计"按当前内容实际需要"的字节，capacityBytes 是
 * 分配到的容量上限：两者差得越多，说明 padding／翻倍扩容有多浪费。
 *
 * E01：arena 槽位与 pipeline 存量单列。它们才是"滚动轮次越多越慢"的可疑载体——
 * 增量计数只能证明创建过，必须看到历史槽位与仍被 sized 持有的对象数才能判断是否堆着。
 */
struct VulkanResourceLive {
    quint64 dynamicBuffers = 0;
    quint64 capacityBytes = 0;
    quint64 usedBytes = 0;
    quint64 shaderResourceBindings = 0;
    /// arena 里"本帧仍活跃"的槽位数 / 分配过的历史槽位数 / 容量槽位数。
    quint64 arenaSlots = 0;
    quint64 arenaHistoricSlots = 0;
    quint64 arenaCapacitySlots = 0;
    /// 实例池容量与镜像条数（镜像条数 = 本帧真正登记进池的切片数）。
    quint64 poolCapacityBytes = 0;
    quint64 poolMirror = 0;
    /// 活着的 pipeline／布局 SRB 对象数（创建减退休，能看出 clear() 是否只清了 map）。
    quint64 pipelines = 0;
    quint64 pipelineLayouts = 0;
    /// "store"／"discard"／"mixed"：主场景深度附件在本窗口的策略。
    QString depthPolicy = QStringLiteral("store");
};

/**
 * E01：本轮实验的有效配置。
 *
 * 请求值与生效值必须分开记录：arena／直写都会在碰到边界时永久回退，日志里只写"开了"
 * 会把一次静默回退读成仍在走优化路径。fallback 为空表示没回退。
 */
struct VulkanResourceConfig {
    bool arenaRequested = false;
    bool arenaEffective = false;
    bool directWriteRequested = false;
    bool directWriteEffective = false;
    bool poolRequested = false;
    bool poolEffective = false;
    bool discardDepthRequested = false;
    bool discardDepthEffective = false;
    bool layoutOnlyRequested = false;
    bool layoutOnlyEffective = false;
    bool compactInstanceRequested = false;
    bool compactInstanceEffective = false;
    /// 回退原因；空串表示该路径没有发生回退。
    QString arenaFallback;
    QString directWriteFallback;
    QString poolFallback;
    /// 与帧形态相关、会改变上述路径有效性的外部条件。
    QString aaMode;
    QString host;
    bool motionConfigured = false;
    bool motionTarget = false;
    int samples = 1;
};

inline QString formatVulkanConfigLine(const VulkanResourceConfig &config)
{
    const auto state = [](bool requested, bool effective) {
        if (!requested) {
            return QStringLiteral("关");
        }
        return effective ? QStringLiteral("开") : QStringLiteral("请求开→已回退");
    };
    const auto reason = [](const QString &text) {
        return text.isEmpty() ? QStringLiteral("-") : text;
    };
    return QStringLiteral(
               "资源账本配置: 宿主 %1 | AA %2 | samples %3 | motion 配置 %4 / 目标 %5 | "
               "arena %6（回退 %7） | 直写 %8（回退 %9） | 实例池 %10（回退 %11） | 深度不保留 %12 | "
               "紧凑实例 %13 | 布局复用 %14")
        .arg(config.host, config.aaMode.isEmpty() ? QStringLiteral("-") : config.aaMode)
        .arg(config.samples)
        .arg(config.motionConfigured ? QStringLiteral("需要") : QStringLiteral("不需要"))
        .arg(config.motionTarget ? QStringLiteral("分配") : QStringLiteral("不分配"))
        .arg(state(config.arenaRequested, config.arenaEffective), reason(config.arenaFallback),
             state(config.directWriteRequested, config.directWriteEffective),
             reason(config.directWriteFallback),
             state(config.poolRequested, config.poolEffective), reason(config.poolFallback),
             state(config.discardDepthRequested, config.discardDepthEffective),
             state(config.compactInstanceRequested, config.compactInstanceEffective),
             state(config.layoutOnlyRequested, config.layoutOnlyEffective));
}

inline QString formatVulkanResourceLine(const VulkanResourceWindow &window,
                                        const VulkanResourceLive &live, qint64 frames)
{
    const double perFrame = frames > 0 ? 1.0 / double(frames) : 0.0;
    return QStringLiteral(
               "资源账本: 窗口 %1 帧 | 新建 buffer %2 次 | 更新 %3 次 / %4 B（每帧 %5 次） | "
               "SRB 新建 %6 次 / 绑定 %7 次（省 %8） | pipeline 绑定 %9 次 | pass %10 次"
               "（深度 store %11 / discard %12） | 存量 buffer %13 个 / 容量 %14 B / 有效 %15 B | "
               "SRB 存量 %16 个 | 深度策略 %17 | arena 槽 %18 活 / %19 历史 / %20 容量 | "
               "实例池 %21 B / 镜像 %22 条 | pipeline 活 %23 / 布局活 %24")
        .arg(frames)
        .arg(window.dynamicBufferCreates)
        .arg(window.dynamicBufferUpdates)
        .arg(window.dynamicBufferBytes)
        .arg(double(window.dynamicBufferUpdates) * perFrame, 0, 'f', 2)
        .arg(window.srbCreates)
        .arg(window.srbBinds)
        .arg(window.srbReuseSkips)
        .arg(window.pipelineBinds)
        .arg(window.passes)
        .arg(window.depthStorePasses)
        .arg(window.depthDiscardPasses)
        .arg(live.dynamicBuffers)
        .arg(live.capacityBytes)
        .arg(live.usedBytes)
        .arg(live.shaderResourceBindings)
        .arg(live.depthPolicy)
        .arg(live.arenaSlots)
        .arg(live.arenaHistoricSlots)
        .arg(live.arenaCapacitySlots)
        .arg(live.poolCapacityBytes)
        .arg(live.poolMirror)
        .arg(live.pipelines)
        .arg(live.pipelineLayouts);
}

} // namespace RhineRender
