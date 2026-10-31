#pragma once

#include <QFile>

#include <atomic>

#ifdef __GLIBC__
#include <malloc.h>
#endif
#include <QString>
#include <QtGlobal>

namespace RhineRender {

/**
 * 诊断用内存快照。
 *
 * 字段刻意选「随翻动次数增长」的容器规模：RSS 涨而这些计数不变，说明是分配器/驱动
 * 高位不降；某个计数跟着翻动一起涨，说明那个容器没有淘汰路径，可以直接定位。
 */
struct MemorySample
{
    qint64 rssBytes = -1;
    qint64 heapBytes = -1;       // malloc 在用字节（glibc mallinfo2().uordblks）
    int labels = 0;              // 标签纹理数（labelRevisions 同源）
    int covers = 0;              // 已绑定到曲目的封面纹理数
    int coverTextures = 0;       // 封面纹理池（按 revision）
    qint64 textureBytes = 0;     // 标签+封面纹理的估算占用
    int materials = 0;           // 材质状态（含 SRB 与 uniform buffer）
    int staticInstances = 0;     // 按 draw id 常驻的实例 buffer
    int batchInstances = 0;      // 批处理实例 buffer
    int shaderResourceBindings = 0;
    int liveResources = 0;       // 常驻池（纹理、buffer）
    int liveSized = 0;           // 随 resize 回收的对象（pipeline、布局）
    int liveTransient = 0;       // 单帧临时对象
    int engineMusicTextures = 0; // Engine 侧按曲目保留的 MusicTexture 条目
    qint64 engineCoverBytes = 0; // 其中封面 QImage 的字节数
};

/// Engine 侧持有量：GUI 线程每步写一次，渲染线程只读。用来判断「按曲目累积的封面图」是不是元凶。
struct EngineMemoryCounters
{
    std::atomic<int> musicTextures{0};
    std::atomic<qint64> coverBytes{0};
};

inline EngineMemoryCounters &engineMemoryCounters()
{
    static EngineMemoryCounters counters;
    return counters;
}

/// glibc 堆在用字节；其他平台返回 -1。用来区分「宿主堆里有人抓着」和「驱动/分配器高位不降」。
inline qint64 heapInUseBytes()
{
#ifdef __GLIBC__
    return qint64(mallinfo2().uordblks);
#else
    return -1;
#endif
}

/// 读 /proc/self/statm 的常驻页数；非 Linux 或读取失败返回 -1。
inline qint64 residentBytes()
{
#ifdef Q_OS_LINUX
    QFile statm(QStringLiteral("/proc/self/statm"));
    if (statm.open(QIODevice::ReadOnly)) {
        const auto fields = statm.readAll().simplified().split(' ');
        if (fields.size() > 1) {
            bool ok = false;
            const auto pages = fields.at(1).toLongLong(&ok);
            if (ok) {
                return pages * 4096;
            }
        }
    }
#endif
    return -1;
}

inline QString formatMemoryLine(const MemorySample &sample)
{
    const auto mib = [](qint64 bytes) { return bytes < 0 ? -1.0 : bytes / (1024.0 * 1024.0); };
    return QStringLiteral("内存 rss=%1 MiB 堆=%2 MiB | 标签 %3 封面 %4 封面池 %5 纹理 %6 MiB"
                          " | 材质 %7 静态实例 %8 批次实例 %9 | SRB %10 | 存活 %11/%12/%13"
                          " | 曲目 %14(封面 %15 MiB)")
        .arg(mib(sample.rssBytes), 0, 'f', 1)
        .arg(mib(sample.heapBytes), 0, 'f', 1)
        .arg(sample.labels)
        .arg(sample.covers)
        .arg(sample.coverTextures)
        .arg(sample.textureBytes / (1024.0 * 1024.0), 0, 'f', 1)
        .arg(sample.materials)
        .arg(sample.staticInstances)
        .arg(sample.batchInstances)
        .arg(sample.shaderResourceBindings)
        .arg(sample.liveResources)
        .arg(sample.liveSized)
        .arg(sample.liveTransient)
        .arg(sample.engineMusicTextures)
        .arg(sample.engineCoverBytes / (1024.0 * 1024.0), 0, 'f', 1);
}

} // namespace RhineRender
