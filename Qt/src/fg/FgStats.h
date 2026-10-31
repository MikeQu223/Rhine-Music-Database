#pragma once

#include <QSize>
#include <QString>

namespace RhineFg {

/**
 * 呈现层每帧写一次、性能面板读的运行时统计。
 *
 * 与 FgCapability 同样必须 header-only 且不 include 任何 Vulkan 头：读它的 FrameProfiler
 * 属于 RhineCore，在没有 Vulkan 的平台上也要能编译。写入方（FgShell）跑在 GUI 线程，
 * 读取方（FrameProfiler::sample）也在 GUI 线程，所以不加锁，只保证结构体拷贝是整体的。
 *
 * 时间单位统一为毫秒。计数器是累计值，面板自己取差值算 FPS。
 */
struct Stats {
    /// 呈现层是否在跑（false 时其余字段无意义）。
    bool layerActive = false;
    /// 本次启动的插值上下文是否可用。
    bool interpolationAvailable = false;
    /// 设置里的开关是否要求插值（每帧重读偏好，热切换靠它）。
    bool interpolationWanted = false;
    /// 这一帧是否真的插入了补偿帧（开关、空闲节流、reset 帧都会影响它）。
    bool interpolationActive = false;
    /// 场景深度 / 运动矢量这一帧是否拿到了（FG 的输入前提）。
    bool depthReady = false;
    bool motionVectorsReady = false;

    /// 累计计数：呈现的帧数（含插值帧）、其中插值帧数、场景真实渲染帧数。
    quint64 presented = 0;
    quint64 interpolated = 0;
    quint64 rendered = 0;

    /// 分项耗时（近若干帧的滑动平均）。
    double acquireMs = 0.0;
    double sceneMs = 0.0;
    double prepareMs = 0.0;
    double dispatchMs = 0.0;
    double compositeMs = 0.0;
    /// 一次 presentOne 的全程（beginFrame 之前 → present 之后），含离屏帧收尾的隐式等待。
    /// 以前这里另有一个"上屏"耗时：它在 endFrame 之后重新起表，实际只量到记账语句自己，
    /// 恒≈0；而真正能回答"这一帧到底多久"的只有全程计时，所以合并成一个数。
    double frameMs = 0.0;
    /// 每成功上屏一帧 +1。只靠帧率无法把一次卡顿/重建对上具体帧，这个 id 是 CSV 里
    /// 把 fg_frame_ms 与 fg_swapchain_recreates 关联起来的锚点。
    quint64 frameId = 0;
    /// 交换链真正重建 / 重建时等待设备空闲 / 尺寸没变被跳过的次数。
    /// 三个数一起看才能证明"resize 去重"生效：跳过数应该远多于重建数（A10）。
    quint64 swapchainRecreates = 0;
    quint64 deviceIdleWaits = 0;
    quint64 resizeSkips = 0;
    /// 已弃用，呈现层不再写它（量的是 endFrame 之后那几条记账语句，恒≈0）。
    /// 字段暂时保留是因为 Qt/tests/FgCapabilityChecks.cpp 直接给它赋值；删掉会连带
    /// 打断不在本次改动范围内的 RhineFgCapabilityRegression，等测试那行清掉后可移除。
    double presentMs = 0.0;
    /// QRhi 的离屏帧边界：这两处会隐式等 GPU 完成，之前的计时刚好把它们漏掉了，
    /// 于是出现"各项耗时都 <1ms、帧间隔却 30ms+"的怪现象。
    /// A02 起语义写死（两者都是 EMA，alpha=0.15）：
    ///   beginMs = **帧槽等待**：beginFrame 要等上一帧的命令缓冲/围栏归还，可能包含
    ///             上一帧 endFrame 提交后的隐式同步；它衡量的是"帧槽什么时候空出来"。
    ///   endMs   = **离屏收尾**：endFrame 只做提交与呈现；没有读回时这里不应该出现
    ///             同步等待，一旦 p95 明显抬升，说明存在回读或队列被塞满。
    double beginMs = 0.0;
    double endMs = 0.0;
    /// 最近一次 beginFrame 的原始耗时（ms），即本次"帧槽等待"，未做 EMA。
    /// beginMs 只能看趋势，这个样本才能对上具体帧；配合 beginP95Ms/beginP99Ms
    /// 判断是不是偶发的槽复用等待。
    double slotWaitMs = 0.0;
    /// beginMs / endMs 的滚动分位（最近 120 个**原始样本**，不是 EMA 值）。
    /// 均值和 EMA 会把一次 20ms 的等待摊平到看不见，p95/p99 才能证明"偶发但致命"
    /// 的槽等待/收尾等待确实存在（A02 的证据要求）。
    double beginP95Ms = 0.0;
    double beginP99Ms = 0.0;
    double endP95Ms = 0.0;
    double endP99Ms = 0.0;
    /// 本帧（自上次 publishStats 以来）实际发生的离屏 beginFrame/endFrame 对数：
    /// 呈现层 1 次 + QML 场景层/UI 层各 0~1 次（只有 dirty 才提交）。正常一帧是 3 次，
    /// 空闲跳帧是 0 次；它是"每帧到底提交了几次离屏帧"的直接证据（A02）。
    int submitsPerFrame = 0;
    /// 两步之间（定时器等待 + 事件循环排队）花掉的时间。
    double idleGapMs = 0.0;

    /// 呈现间隔统计（由呈现层自己的环形缓冲算出，FG 路径下没有 frameSwapped 可用）。
    double gapP50Ms = 0.0;
    double gapP95Ms = 0.0;
    double gapP99Ms = 0.0;
    double gapMaxMs = 0.0;
    int over33 = 0;
    int over50 = 0;
    int over100 = 0;
    int sampleCount = 0;

    /// 交换链与设备信息（启动时填一次）。
    int swapchainImages = 0;
    QString swapchainFormat;
    /// 真正生效的呈现模式（FIFO / MAILBOX / IMMEDIATE）。帧率上限几乎全由它决定，
    /// 性能面板要显示出来，否则用户没法判断"这次跑得快是因为换对了呈现模式"。
    QString presentMode;
    /// 同一张交换链图像两次上屏的平均间隔（ms）。与 presentMode 配合判断瓶颈：
    /// 贴着刷新周期=合成器限速，忽大忽小且远大于刷新周期=渲染/提交跟不上。
    double imageReuseMs = 0.0;
    QString adapterName;
    QString backendName;

    QSize renderSize;
    QSize displaySize;

    /// 每次 publish 自增；读方可据此判断数据是否还在更新。
    quint64 serial = 0;
};

inline Stats &statsMutable()
{
    static Stats value;
    return value;
}

inline const Stats &stats()
{
    return statsMutable();
}

inline void publish(const Stats &value)
{
    auto &slot = statsMutable();
    const quint64 serial = slot.serial + 1;
    slot = value;
    slot.serial = serial;
}

/// 呈现层退出或从未启动时把状态清掉，避免面板继续显示上一轮的旧数字。
inline void clear()
{
    const quint64 serial = statsMutable().serial + 1;
    statsMutable() = Stats{};
    statsMutable().serial = serial;
}

} // namespace RhineFg
