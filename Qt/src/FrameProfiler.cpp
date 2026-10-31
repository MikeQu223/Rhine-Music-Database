#include <QtGlobal>
#include "FrameProfiler.h"

#include "fg/FgCapability.h"
#include "Engine.h"
#include "ProcessMetrics.h"
#include <QCoreApplication>
#include <QDesktopServices>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QSaveFile>
#include <QScreen>
#include <QStandardPaths>
#include <QSysInfo>
#include <QThread>
#include <QTimeZone>
#include <QUrl>
#include <QUuid>
#include <algorithm>
#include <cmath>
#include <rhi/qrhi.h>
#include <QDateTime>
#include <QJsonArray>
#include <QQuickWindow>

namespace {
/** 当前场景图使用的图形 API 名；性能面板、设置页与环境诊断共用同一份显示文本。 */
QString graphicsApiName(QQuickWindow *window) {
    if (!window || !window->rendererInterface()) {
        return {};
    }
    switch (window->rendererInterface()->graphicsApi()) {
    case QSGRendererInterface::Metal:
        return QStringLiteral("Metal");
    case QSGRendererInterface::Direct3D12:
        return QStringLiteral("Direct3D12");
    case QSGRendererInterface::Vulkan:
        return QStringLiteral("Vulkan");
    case QSGRendererInterface::OpenGL:
        return QStringLiteral("OpenGL");
    case QSGRendererInterface::Software:
        return QStringLiteral("Software");
    default:
        return {};
    }
}
} // namespace

/**
 * 复用原生计时与 Qt 渲染信号；关闭面板且没有录制时不运行采样定时器。
 * 命令行 CSV 保留原格式，用户诊断只记录白名单性能数值，不采集业务内容。
 */
FrameProfiler::FrameProfiler(Engine *engine, const QString &path, QObject *parent)
    : QObject(parent), m_engine(engine), file(path), stream(&file) {
    clock.start();
    epochMs = QDateTime::currentMSecsSinceEpoch();
    m_directory = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation) + "/RHINE Diagnostics";
    m_sampleTimer.setInterval(500);
    connect(&m_sampleTimer, &QTimer::timeout, this, &FrameProfiler::sample);
    connect(engine, &Engine::updated, this, &FrameProfiler::collectStep);
    connect(qApp, &QCoreApplication::aboutToQuit, this, [this] {
        if (m_recording) {
            saveRecording();
        }
    });
    if (!path.isEmpty()) {
        if (file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
            // 新列一律追加在末尾：旧分析脚本按列号读前 14 列，插在中间会让历史数据整体错位。
            // 新增列口径（A02/A11）：fg_* 取呈现层最近一次 publish 的值，ledger_* 来自
            // Engine::performance() 的异步快照——两者都不保证与同一行的 render_frames 属于
            // 同一帧；ledger_*_peak 是最近 240 个渲染帧的**滚动**峰值（不是 lifetime 峰值）。
            stream << "timestamp_ms,step_cpu_ms,scene_native_ms,scene_metadata_ms,scene_buffers_ms,"
                      "latest_present_gap_ms,latest_sync_cpu_ms,latest_submit_cpu_ms,presents,draws,"
                      "returning_cards,culled_cards,shadow_only_cards,latest_gpu_draw_calls,"
                      "gpu_timing_status,render_frames,fg_frame_id,fg_frame_ms,fg_swapchain_recreates,"
                      "fg_device_idle_waits,fg_resize_skips,"
                      "fg_submits_per_frame,fg_slot_wait_ms,fg_begin_p95_ms,fg_begin_p99_ms,"
                      "fg_end_p95_ms,fg_end_p99_ms,"
                      "ledger_resources_peak,ledger_resources_peak_frame,ledger_texture_bytes_peak,"
                      "ledger_texture_bytes_peak_frame,ledger_frame_bindings,ledger_frame_cover_uploads,"
                      "ledger_cover_uploads_per_frame,ledger_cover_retransmit_per_kframe\n";
        } else {
            qWarning() << "Cannot open frame profile:" << file.errorString();
        }
    }
    updateSampling();
}

/** 渲染线程只写原子计数与有界帧间隔队列，文件和业务状态始终由 GUI 线程访问。 */
void FrameProfiler::attach(QQuickWindow *window) {
    Q_ASSERT(!m_window);
    m_window = window;
    connect(
        window, &QQuickWindow::beforeSynchronizing, this,
        [this] {
            syncTimer.invalidate();
            if (m_enabled.load(std::memory_order_relaxed)) {
                syncTimer.start();
            }
        },
        Qt::DirectConnection);
    connect(
        window, &QQuickWindow::afterSynchronizing, this,
        [this] {
            if (m_enabled.load(std::memory_order_relaxed) && syncTimer.isValid()) {
                syncNs.store(syncTimer.nsecsElapsed(), std::memory_order_relaxed);
            }
        },
        Qt::DirectConnection);
    connect(
        window, &QQuickWindow::beforeRendering, this,
        [this] {
            renderTimer.invalidate();
            if (m_enabled.load(std::memory_order_relaxed)) {
                renderTimer.start();
                QMutexLocker lock(&m_gapMutex);
                if (m_adapterName.isEmpty() && m_window) {
                    auto *renderer = m_window->rendererInterface();
                    auto *rhi = static_cast<QRhi *>(
                        renderer->getResource(m_window, QSGRendererInterface::RhiResource));
                    if (rhi) {
                        m_adapterName = QString::fromUtf8(rhi->driverInfo().deviceName);
                    }
                    m_backendName = graphicsApiName(m_window);
                }
            }
        },
        Qt::DirectConnection);
    connect(
        window, &QQuickWindow::afterRendering, this,
        [this] {
            if (m_enabled.load(std::memory_order_relaxed) && renderTimer.isValid()) {
                submitNs.store(renderTimer.nsecsElapsed(), std::memory_order_relaxed);
            }
        },
        Qt::DirectConnection);
    connect(
        window, &QQuickWindow::frameSwapped, this,
        [this] {
            if (!m_enabled.load(std::memory_order_relaxed)) {
                return;
            }
            const auto now = clock.nsecsElapsed();
            const auto previous = presentNs.exchange(now, std::memory_order_relaxed);
            presentGapNs.store(previous ? now - previous : 0, std::memory_order_relaxed);
            presents.fetch_add(1, std::memory_order_relaxed);
            QMutexLocker lock(&m_gapMutex);
            if (previous && m_gapsMs.size() < 4096) {
                m_gapsMs.append((now - previous) / 1000000.);
            }
            if (m_capture.load(std::memory_order_relaxed)) {
                if (m_trace.size() < 36000) {
                    m_trace.append({now, previous ? now - previous : 0,
                                    syncNs.load(std::memory_order_relaxed),
                                    submitNs.load(std::memory_order_relaxed)});
                } else {
                    ++m_omittedTraceFrames;
                }
            }
        },
        Qt::DirectConnection);
    // 隐藏窗口暂停实时面板刷新；录制仍每秒两次采样，保留后台资源释放证据。
    connect(window, &QWindow::visibilityChanged, this, [this] { updateSampling(); });
    updateSampling();
}

void FrameProfiler::collectStep() {
    if (!m_enabled.load(std::memory_order_relaxed)) {
        return;
    }
    const auto &timings = m_engine->scene.timings;
    ++m_stepCount;
    m_stepTotalMs += timings.engineMs;
    m_stepMaxMs = qMax(m_stepMaxMs, timings.engineMs);
    if (!file.isOpen()) {
        return;
    }
    // GUI 和渲染线程采样不同步，最近一次呈现间隔不是 GPU 耗时。
    const auto frame = m_engine->frame();
    // performance() 只取一次：同一行里要读多个键，分开调用会跨帧、互相矛盾。
    const QVariantMap performance = m_engine->performance();
    // 帧号与整帧耗时只有呈现层知道（Engine 只记渲染帧数），所以单独取一份。
    const RhineFg::Stats fg = RhineFg::stats();
    stream << epochMs + clock.elapsed() << ',' << timings.engineMs << ',' << timings.simulateMs << ','
           << timings.metadataMs << ',' << timings.buffersMs << ','
           << presentGapNs.load(std::memory_order_relaxed) / 1000000. << ','
           << syncNs.load(std::memory_order_relaxed) / 1000000. << ','
           << submitNs.load(std::memory_order_relaxed) / 1000000. << ','
           << presents.load(std::memory_order_relaxed) << ',' << frame["draws"].toArray().size() << ','
           << frame["returningCards"].toInt() << ',' << frame["culledCards"].toInt() << ','
           << frame["shadowCards"].toInt() << ','
           << performance.value("gpuDrawCalls").toULongLong() << ','
           // "没测到"和"没请求"必须能分开：只写一个空的 gpu 时间，事后没法判断
           // 是驱动不给样本还是我们没开时间戳（A01 的验收就靠这一列）。
           << performance.value("gpuTimingStatus").toString() << ','
           << performance.value("renderFrames").toULongLong() << ',' << fg.frameId << ','
           << fg.frameMs << ',' << fg.swapchainRecreates << ',' << fg.deviceIdleWaits << ','
           << fg.resizeSkips << ','
           // A02：提交次数与两个离屏边界的等待（begin=帧槽等待，end=离屏收尾）。
           << fg.submitsPerFrame << ',' << fg.slotWaitMs << ',' << fg.beginP95Ms << ','
           << fg.beginP99Ms << ',' << fg.endP95Ms << ',' << fg.endP99Ms << ','
           // A11：整帧资源账本（峰值是滚动 240 帧，帧号对得上 render_frames）。
           << performance.value("gpuResourcesPeak").toULongLong() << ','
           << performance.value("gpuResourcesPeakFrame").toULongLong() << ','
           << performance.value("gpuTextureBytesPeak").toULongLong() << ','
           << performance.value("gpuTextureBytesPeakFrame").toULongLong() << ','
           << performance.value("frameBindings").toULongLong() << ','
           << performance.value("frameCoverUploads").toULongLong() << ','
           << performance.value("coverUploadsPerFrame").toDouble() << ','
           << performance.value("coverRetransmitPerKFrame").toDouble() << '\n';
}

FrameProfiler::~FrameProfiler() {
    m_enabled.store(false, std::memory_order_relaxed);
    m_capture.store(false, std::memory_order_relaxed);
    if (file.isOpen()) {
        stream.flush();
    }
}

void FrameProfiler::toggleVisible() {
    m_visible = !m_visible;
    updateSampling();
    emit changed();
}

void FrameProfiler::toggleRecording() {
    if (m_recording) {
        saveRecording();
    } else if (!m_samples.isEmpty()) {
        saveRecording();
    } else {
        startRecording();
    }
}

void FrameProfiler::setReportDirectory(const QString &directory) {
    if (!m_recording) {
        m_directory = directory;
    }
}

void FrameProfiler::openReportFolder() {
    if (QDir().mkpath(m_directory)) {
        QDesktopServices::openUrl(QUrl::fromLocalFile(m_directory));
    }
}

/** 只在需要时开启原生计时，重置统计基线，避免把暂停期间的时间当成卡顿。 */
bool FrameProfiler::windowShown() const {
    if (m_window) {
        return m_window->isVisible() && m_window->visibility() != QWindow::Minimized;
    }
    // FG 呈现层接管窗口时 attach() 从未被调用，这里没有 QQuickWindow 可问。
    // 退回看呈现层的统计，否则 shown 恒为 false、采样器永远不启动，
    // 面板就停在"等待采样"——帧生成模式下监视器全空就是这个原因。
    return RhineFg::stats().layerActive;
}

void FrameProfiler::updateSampling() {
    const bool shown = windowShown();
    const bool enabled = (m_visible && shown) || m_recording || file.isOpen();
    m_engine->host.enablePlaybackDiagnostics((m_visible && shown) || m_recording);
    const bool previous = m_enabled.exchange(enabled, std::memory_order_relaxed);
    if (enabled != previous) {
        if (enabled) {
            m_previousProfiling = m_engine->scene.isProfiling();
            m_engine->scene.profileFrames(true);
            m_previousSampleNs = clock.nsecsElapsed();
            m_previousCpuNs = readProcessMetrics().cpuNanoseconds;
            m_previousPresents = presents.load(std::memory_order_relaxed);
            m_previousSceneFrames = m_engine->performance().value("renderFrames").toULongLong();
        } else {
            m_engine->scene.profileFrames(m_previousProfiling);
        }
        presentNs.store(0, std::memory_order_relaxed);
        QMutexLocker lock(&m_gapMutex);
        m_gapsMs.clear();
        m_stepCount = 0;
        m_stepTotalMs = m_stepMaxMs = 0;
    }
    // 纯命令行 CSV 沿用事件驱动写入，不额外唤醒窗口。
    if ((m_visible && shown) || m_recording) {
        m_sampleTimer.start();
    } else {
        m_sampleTimer.stop();
    }
}

/** 聚合半秒内的实际呈现事件，保留帧间隔尾部和峰值；采样本身不请求场景绘制。 */
void FrameProfiler::sample() {
    const auto now = clock.nsecsElapsed();
    const auto elapsedNs = qMax<qint64>(1, now - m_previousSampleNs);
    const auto process = readProcessMetrics();
    const auto count = presents.load(std::memory_order_relaxed);
    const auto resources = m_engine->performance();
    const auto sceneFrames = resources.value("renderFrames").toULongLong();
    QList<double> gaps;
    {
        QMutexLocker lock(&m_gapMutex);
        gaps.swap(m_gapsMs);
    }
    std::sort(gaps.begin(), gaps.end());
    const auto percentile = [&gaps](double fraction) {
        if (gaps.isEmpty()) {
            return 0.;
        }
        return gaps[qBound<qsizetype>(0, qsizetype(std::ceil(gaps.size() * fraction)) - 1, gaps.size() - 1)];
    };
    const auto over = [&gaps](double milliseconds) {
        return int(std::count_if(gaps.begin(), gaps.end(),
                                 [milliseconds](double gap) { return gap > milliseconds; }));
    };
    const double cpu = process.cpuNanoseconds >= 0 && m_previousCpuNs >= 0
                           ? qMax(0., (process.cpuNanoseconds - m_previousCpuNs) * 100. / elapsedNs)
                           : -1.;
    m_metrics.clear();
    for (const auto *key : {"idle", "sceneSleeping", "visible", "steps", "sceneUpdates", "hudUpdates",
                            "renderFrames", "gpuResources", "bindingCreations", "gpuMusicTextureBytes",
                            "coverUploads", "gpuDrawCalls", "timerActive",
                            // A11 整帧资源账本：峰值是最近 240 个渲染帧的滚动峰值，
                            // *_peak_frame 是持有该峰值的渲染帧号（与 renderFrames 同口径）。
                            "gpuResourcesPeak", "gpuResourcesPeakFrame", "gpuTextureBytesPeak",
                            "gpuTextureBytesPeakFrame", "frameBindings", "frameCoverUploads",
                            "coverUploadsPerFrame", "coverRetransmitPerKFrame", "resourceBudgetMb"}) {
        m_metrics.insert(QString::fromLatin1(key), resources.value(QString::fromLatin1(key)));
    }
    m_metrics.insert("elapsedMs", clock.elapsed() - m_recordStartedMs);
    m_metrics.insert("sampleDurationMs", elapsedNs / 1000000.);
    m_metrics.insert("qtFps", (count - m_previousPresents) * 1000000000. / elapsedNs);
    m_metrics.insert("sceneFps", (sceneFrames - m_previousSceneFrames) * 1000000000. / elapsedNs);
    m_metrics.insert("presentCount", qulonglong(count));
    m_metrics.insert("gapSamples", gaps.size());
    m_metrics.insert("gapP50Ms", percentile(.5));
    m_metrics.insert("gapP95Ms", percentile(.95));
    m_metrics.insert("gapP99Ms", percentile(.99));
    m_metrics.insert("gapMaxMs", gaps.isEmpty() ? 0. : gaps.last());
    m_metrics.insert("over33ms", over(33.333));
    m_metrics.insert("over50ms", over(50));
    m_metrics.insert("over100ms", over(100));
    m_metrics.insert("mainProcessResidentBytes", process.residentBytes);
    m_metrics.insert("mainProcessCpuOneCorePercent", cpu);
    m_metrics.insert("stepSamples", qulonglong(m_stepCount));
    m_metrics.insert("stepMeanCpuMs", m_stepCount ? m_stepTotalMs / m_stepCount : 0.);
    m_metrics.insert("stepMaxCpuMs", m_stepMaxMs);
    m_metrics.insert("latestSyncCpuMs", syncNs.load(std::memory_order_relaxed) / 1000000.);
    m_metrics.insert("latestSubmitCpuMs", submitNs.load(std::memory_order_relaxed) / 1000000.);
    m_metrics.insert("gpuTimeMs", resources.value("gpuTimeMs"));
    // 状态与数值分开透传：面板要在"没有样本"时说明是没样本、没请求还是设备不支持。
    m_metrics.insert("gpuTimingStatus", resources.value("gpuTimingStatus"));
    {
        QMutexLocker lock(&m_gapMutex);
        m_metrics.insert("gpuAdapter", m_adapterName);
        m_metrics.insert("gpuBackend", m_backendName);
    }
    // —— 帧生成呈现层 ——
    // FG 路径把 present 收归呈现层自己，Qt 的 frameSwapped 永远不会触发：上面的
    // qtFps / 帧间隔在那种模式下恒定是 0。所以这里改成读呈现层自己的统计，
    // 并在它接管时用它的数字覆盖同一批字段，保持下面 formatMetrics 的写法不变。
    const RhineFg::Stats fg = RhineFg::stats();
    const double fgPresentedFps = (fg.presented - m_previousFgPresented) * 1000000000. / elapsedNs;
    const double fgInterpolatedFps = (fg.interpolated - m_previousFgInterpolated) * 1000000000. / elapsedNs;
    const double fgRenderFps = (fg.rendered - m_previousFgRendered) * 1000000000. / elapsedNs;
    m_previousFgPresented = fg.presented;
    m_previousFgInterpolated = fg.interpolated;
    m_previousFgRendered = fg.rendered;
    m_metrics.insert("fgLayerActive", fg.layerActive);
    m_metrics.insert("fgPresentedFps", fgPresentedFps);
    m_metrics.insert("fgInterpolatedFps", fgInterpolatedFps);
    m_metrics.insert("fgRenderFps", fgRenderFps);
    m_metrics.insert("fgInterpolationWanted", fg.interpolationWanted);
    m_metrics.insert("fgInterpolationAvailable", fg.interpolationAvailable);
    m_metrics.insert("fgInterpolationActive", fg.interpolationActive);
    m_metrics.insert("fgAcquireMs", fg.acquireMs);
    m_metrics.insert("fgSceneMs", fg.sceneMs);
    m_metrics.insert("fgPrepareMs", fg.prepareMs);
    m_metrics.insert("fgDispatchMs", fg.dispatchMs);
    m_metrics.insert("fgCompositeMs", fg.compositeMs);
    // 整帧耗时取代原来的"上屏"耗时：后者在 endFrame 之后重新起表，只量到记账语句，
    // 恒≈0 却占着一列指标，会让人误以为上屏不要钱。
    m_metrics.insert("fgFrameMs", fg.frameMs);
    m_metrics.insert("fgFrameId", fg.frameId);
    m_metrics.insert("fgSwapchainRecreates", fg.swapchainRecreates);
    m_metrics.insert("fgDeviceIdleWaits", fg.deviceIdleWaits);
    m_metrics.insert("fgResizeSkips", fg.resizeSkips);
    // A02：帧槽等待 / 离屏收尾的 EMA 与原始分位分开暴露。面板要能回答"每帧提交几次、
    // begin 等槽多久、end 收尾多久"，而不是只有一个含混的"起始/收尾"。
    m_metrics.insert("fgSubmitsPerFrame", fg.submitsPerFrame);
    m_metrics.insert("fgSlotWaitMs", fg.slotWaitMs);
    m_metrics.insert("fgBeginMs", fg.beginMs);
    m_metrics.insert("fgEndMs", fg.endMs);
    m_metrics.insert("fgBeginP95Ms", fg.beginP95Ms);
    m_metrics.insert("fgBeginP99Ms", fg.beginP99Ms);
    m_metrics.insert("fgEndP95Ms", fg.endP95Ms);
    m_metrics.insert("fgEndP99Ms", fg.endP99Ms);
    m_metrics.insert("fgSwapchainImages", fg.swapchainImages);
    m_metrics.insert("fgSwapchainFormat", fg.swapchainFormat);
    // 呈现模式决定帧率上限：FG 层自己建的交换链知道确切值；走默认路径时交换链归 Qt，
    // 拿不到真实值，这里如实写"自管"而不是猜一个（实测默认路径是 FIFO ≈ 半刷新率）。
    m_metrics.insert("fgPresentMode", fg.layerActive && !fg.presentMode.isEmpty()
                                          ? fg.presentMode
                                          : QStringLiteral("Qt 自管"));
    m_metrics.insert("fgAdapter", fg.adapterName);
    m_metrics.insert("fgBackend", fg.backendName);
    m_metrics.insert("fgDepthReady", fg.depthReady);
    m_metrics.insert("fgMotionVectorsReady", fg.motionVectorsReady);
    m_metrics.insert("fgRenderSize", fg.renderSize);
    m_metrics.insert("fgDisplaySize", fg.displaySize);
    if (fg.layerActive) {
        // 呈现层接管时，屏幕上真正发生的事只有它知道：用它的间隔与计数覆盖。
#ifdef Q_OS_LINUX
        // qtFps 在这里只是"场景渲染帧"：呈现计数含插值帧与重复帧，直接当帧率会让人
        // 误判 Vulkan 比 OpenGL 快，而动画推进其实更慢。标题上的数字另由下面的
        // headlineFps 决定，呈现/渲染/插值三个数在帧生成详情块里都能看到。
        m_metrics.insert("qtFps", m_metrics.value("sceneFps"));
#else
        m_metrics.insert("qtFps", fgPresentedFps);
#endif
        m_metrics.insert("presentCount", qulonglong(fg.presented));
        m_metrics.insert("gapSamples", fg.sampleCount);
        m_metrics.insert("gapP50Ms", fg.gapP50Ms);
        m_metrics.insert("gapP95Ms", fg.gapP95Ms);
        m_metrics.insert("gapP99Ms", fg.gapP99Ms);
        m_metrics.insert("gapMaxMs", fg.gapMaxMs);
        m_metrics.insert("over33ms", fg.over33);
        m_metrics.insert("over50ms", fg.over50);
        m_metrics.insert("over100ms", fg.over100);
        if (!fg.adapterName.isEmpty())
            m_metrics.insert("gpuAdapter", fg.adapterName);
        if (!fg.backendName.isEmpty())
            m_metrics.insert("gpuBackend", fg.backendName);
    }
#ifdef Q_OS_LINUX
    // 标题帧率的口径在这里定：插帧真的在出帧时，屏幕上每秒多出来的那些画面就是插值帧，
    // 只报渲染帧会明显低于肉眼所见。取渲染+插值而不是呈现计数——呈现还含强制重渲的
    // 重复帧，用它当帧率会虚高。其余情况沿用原口径（未接管即 Qt 帧率，接管即场景渲染帧）。
    const bool interpolating = fg.layerActive && fg.interpolationAvailable && fg.interpolationWanted;
    m_metrics.insert("headlineFps", interpolating ? fgRenderFps + fgInterpolatedFps
                                                  : m_metrics.value("qtFps").toDouble());
#endif
    m_previousSampleNs = now;
    m_previousCpuNs = process.cpuNanoseconds;
    m_previousPresents = count;
    m_previousSceneFrames = sceneFrames;
    m_stepCount = 0;
    m_stepTotalMs = m_stepMaxMs = 0;
    auto audio = m_engine->host.playbackSnapshot();
    if (m_engine->app) {
        const auto &player = m_engine->app->music.player;
        audio["controllerFailed"] = player.failed;
        audio["controllerLoading"] = player.loading;
        audio["controllerPlaying"] = player.state["playing"].toBool();
    }
    m_metrics.insert("audio", audio.toVariantMap());
    formatMetrics();
    if (m_recording) {
        m_samples.append(QJsonObject::fromVariantMap(m_metrics));
        m_status =
            QStringLiteral("正在收集 %1 秒 · 最长 10 分钟").arg((clock.elapsed() - m_recordStartedMs) / 1000);
        if (!m_saving && (m_samples.size() >= 1200 || clock.elapsed() - m_recordStartedMs >= 600000)) {
            saveRecording();
        }
    }
    emit changed();
}

void FrameProfiler::formatMetrics() {
    const auto number = [this](const char *key, int precision = 1) {
        return QString::number(m_metrics.value(key).toDouble(), 'f', precision);
    };
    const bool shown = m_metrics.value("visible").toBool();
    const bool idle = m_metrics.value("idle").toBool();
    const auto residentBytes = m_metrics.value("mainProcessResidentBytes").toLongLong();
    const auto cpu = m_metrics.value("mainProcessCpuOneCorePercent").toDouble();
    const bool fgActive = m_metrics.value("fgLayerActive").toBool();
#ifdef Q_OS_LINUX
    // 帧率口径由 sample() 的 headlineFps 决定：插帧真的在出帧时是"渲染+插值"，其余情况
    // 是场景渲染帧。这里只负责让"%2"的状态说明和那个数字对得上，别再自己挑数字。
    const bool fgAvailable = fgActive && m_metrics.value("fgInterpolationAvailable").toBool();
    const bool interpolating = fgAvailable && m_metrics.value("fgInterpolationWanted").toBool();
#else
    // 呈现层接管后 qtFps 已经被替换成它的实测呈现帧率（见 sample()），所以 headline
    // 的结构不用变，变的只是"%2"那段状态说明要讲清楚现在是不是在插值。
#endif
    QString stateLabel;
    if (!fgActive) {
        stateLabel = shown ? (idle ? QStringLiteral("按需休眠") : QStringLiteral("活动"))
                           : QStringLiteral("后台");
#ifdef Q_OS_LINUX
    } else if (!fgAvailable) {
#else
    } else if (!m_metrics.value("fgInterpolationAvailable").toBool()) {
#endif
        stateLabel = QStringLiteral("帧生成 · 仅合成");
#ifdef Q_OS_LINUX
    } else if (!interpolating) {
#else
    } else if (!m_metrics.value("fgInterpolationWanted").toBool()) {
#endif
        stateLabel = QStringLiteral("帧生成 · 插值关");
    } else if (!shown) {
        stateLabel = QStringLiteral("后台");
    } else if (idle) {
        stateLabel = QStringLiteral("帧生成 · 按需休眠");
    } else {
#ifdef Q_OS_LINUX
        // 插值帧已经算进前面的数字里了，标签必须写清楚，否则会看成纯渲染帧率。
        stateLabel = QStringLiteral("渲染+插值");
#else
        stateLabel = QStringLiteral("帧生成 · 插值中");
#endif
    }
    m_headline = QStringLiteral("%1 FPS · %2 · %3")
#ifdef Q_OS_LINUX
                     .arg(number("headlineFps"), stateLabel,
#else
                     .arg(number("qtFps"), stateLabel,
#endif
                          m_metrics.value("fgPresentMode").toString());
    const auto memory = residentBytes < 0 ? QStringLiteral("不可用")
                                          : QString::number(residentBytes / 1048576., 'f', 1) + " MiB";
    // 帧生成块排在最前：接管呈现后，屏幕上真正发生的是什么只有这几行说得清。
    QString fgDetails;
    if (!fgActive && RhineFg::capability().compiledIn) {
        // 没接管时也给一行：否则用户看不出"这台机器本可以插帧，只是这次走了默认路径"。
        const auto &capability = RhineFg::capability();
        const auto note = !capability.presentLayerActive
                              ? (capability.reason.isEmpty() ? QStringLiteral("默认呈现路径")
                                                             : capability.reason)
                              : QStringLiteral("暂不可用");
        fgDetails = QStringLiteral("帧生成        未接管 · %1\n\n").arg(note);
    } else if (fgActive) {
        const auto ready = [this](const char *key) {
            return m_metrics.value(key).toBool() ? QStringLiteral("就绪") : QStringLiteral("等待");
        };
        const auto sizeText = [this](const char *key) {
            const auto size = m_metrics.value(key).toSize();
            return QStringLiteral("%1×%2").arg(size.width()).arg(size.height());
        };
        const auto millis = [&number](const char *key) {
            return number(key, 2);
        };
        const auto interpolationState =
            !m_metrics.value("fgInterpolationAvailable").toBool()
                ? QStringLiteral("插值 不可用")
                : (m_metrics.value("fgInterpolationWanted").toBool() ? QStringLiteral("插值 开")
                                                                    : QStringLiteral("插值 关"));
        fgDetails =
            QStringLiteral("帧生成        %1 · %2\n呈现 / 渲染    %3 / %4 FPS · 插值 %5 FPS\n")
                .arg(QStringLiteral("已接管"), interpolationState, number("fgPresentedFps"),
                     number("fgRenderFps"), number("fgInterpolatedFps"))
            + QStringLiteral("每帧耗时      取图 %1 · 场景 %2 · 光流+重建 %3 · 插值 %4 ms\n")
                  .arg(millis("fgAcquireMs"), millis("fgSceneMs"), millis("fgPrepareMs"),
                       millis("fgDispatchMs"))
            + QStringLiteral("              合成 %1 ms · 整帧 %2 ms\n")
                  .arg(millis("fgCompositeMs"), millis("fgFrameMs"))
            + QStringLiteral("交换链        %1 张 · %2 · %3 → %4 · 呈现 %5\n")
                  .arg(number("fgSwapchainImages", 0), m_metrics.value("fgSwapchainFormat").toString(),
                       sizeText("fgRenderSize"), sizeText("fgDisplaySize"),
                       m_metrics.value("fgPresentMode").toString())
            // 重建/等待/去重三个数要一起看才算证据：跳过数随帧数增长、等待数不增长，
            // 才说明同尺寸的尺寸同步没有再去等 GPU 空闲（A10）。
            + QStringLiteral("重建 / 设备等待 / 尺寸去重  %1 / %2 / %3 次\n")
                  .arg(number("fgSwapchainRecreates", 0), number("fgDeviceIdleWaits", 0),
                       number("fgResizeSkips", 0))
            + QStringLiteral("深度 / 运动矢量  %1 / %2\n\n")
                  .arg(ready("fgDepthReady"), ready("fgMotionVectorsReady"));
    }
    m_details = fgDetails + QStringLiteral("场景提交      %1 FPS\nQt 帧间隔 P50 / P95  %2 / %3 ms\n"
                       "P99 / 峰值    %4 / %5 ms\n>33 / 50 / 100 ms   %6 / %7 / %8\n"
                       "逻辑 CPU 均值 / 峰值  %9 / %10 ms\n同步 / 提交 CPU  %11 / %12 ms\n"
                       "主进程 CPU    %13%\n主进程常驻内存  %14\n"
                       "Draw calls / GPU 资源  %15 / %16\n封面 GPU 纹理  %17 MiB")
            .arg(number("sceneFps"), number("gapP50Ms"), number("gapP95Ms"), number("gapP99Ms"))
            .arg(number("gapMaxMs"), number("over33ms", 0), number("over50ms", 0), number("over100ms", 0))
            .arg(number("stepMeanCpuMs", 2), number("stepMaxCpuMs", 2), number("latestSyncCpuMs", 2),
                 number("latestSubmitCpuMs", 2))
            .arg(cpu < 0 ? QStringLiteral("不可用") : number("mainProcessCpuOneCorePercent"), memory,
                 number("gpuDrawCalls", 0), number("gpuResources", 0))
            .arg(QString::number(m_metrics.value("gpuMusicTextureBytes").toDouble() / 1048576., 'f', 1));
    // A02：提交/等待放在始终显示的详情区，而不是只在 FG 接管时才出现的 fgDetails——
    // 默认呈现路径同样有 begin 等槽与 end 收尾，少一次提交也要能看见。
    m_details += QStringLiteral("\n提交 / 等待    每帧提交 %1 次 · 帧槽等待 %2 ms（P95/P99 %3/%4）\n"
                                "              离屏收尾 %5 ms（P95/P99 %6/%7）")
                     .arg(number("fgSubmitsPerFrame", 0), number("fgSlotWaitMs", 2),
                          number("fgBeginP95Ms", 2), number("fgBeginP99Ms", 2))
                     .arg(number("fgEndMs", 2), number("fgEndP95Ms", 2), number("fgEndP99Ms", 2));
    // A11：整帧资源账本（本帧 + 滚动峰值 + 重传率 + 预算）。峰值带帧号，便于回查 CSV 的
    // render_frames；预算开关只告警不降级，所以这里显示"上限"而不是"是否已降级"。
    const quint64 budgetMb = m_metrics.value("resourceBudgetMb").toULongLong();
    m_details += QStringLiteral("\n整帧资源      本帧 资源 %1 个 · 纹理 %2 MiB\n"
                                "              峰值（滚动 240 帧） 资源 %3 个 @帧 %4 · "
                                "纹理 %5 MiB @帧 %6\n"
                                "              SRB 新建 %7 个/帧 · 封面纹理上传 %8 次/帧 · "
                                "封面重传率 %9 次/千帧\n"
                                "              预算 %10")
                     .arg(number("gpuResources", 0),
                          QString::number(m_metrics.value("gpuMusicTextureBytes").toDouble() / 1048576.,
                                          'f', 1),
                          number("gpuResourcesPeak", 0), number("gpuResourcesPeakFrame", 0))
                     .arg(QString::number(m_metrics.value("gpuTextureBytesPeak").toDouble() / 1048576.,
                                          'f', 1),
                          number("gpuTextureBytesPeakFrame", 0), number("frameBindings", 0),
                          number("frameCoverUploads", 0))
                     .arg(number("coverRetransmitPerKFrame", 2),
                          budgetMb ? QStringLiteral("%1 MiB").arg(budgetMb)
                                   : QStringLiteral("关（RHINE_RESOURCE_BUDGET_MB）"));
    // GPU 计时状态必须显式写出来：状态不是 ok 时数值列是空的（或上一个可信样本），
    // 只显示数字会让读者把"没测到"当成"GPU 不花时间"——A01 要修的就是这个坑。
    const QString gpuTiming = m_metrics.value("gpuTimingStatus").toString();
    QString gpuTimingText;
    if (gpuTiming == QLatin1String("ok")) {
        gpuTimingText = QStringLiteral("%1 ms").arg(number("gpuTimeMs", 2));
    } else if (gpuTiming == QLatin1String("disabled")) {
        gpuTimingText = QStringLiteral("未启用 · 后端支持时间戳，但创建 QRhi / 图形配置时没请求");
    } else if (gpuTiming == QLatin1String("noSample")) {
        gpuTimingText = QStringLiteral("无样本 · 已请求时间戳，这一帧还没有已完成的查询结果");
    } else if (gpuTiming == QLatin1String("unsupported")) {
        gpuTimingText = QStringLiteral("不支持 · 当前图形后端没有时间戳查询能力");
    } else {
        gpuTimingText = QStringLiteral("未知（%1）")
                            .arg(gpuTiming.isEmpty() ? QStringLiteral("没有状态字段") : gpuTiming);
    }
    m_details += QStringLiteral("\n\nGPU 时间  %1").arg(gpuTimingText);
    const auto audio = m_metrics.value("audio").toMap();
    m_details += QStringLiteral("\n\n音频状态 / 错误码  %1 / %2\n进度 / 时长  %3 / %4 ms\n"
                                "缓冲  %5% · 解码缓冲  %6\n解码格式  %7 Hz / %8 声道\n"
                                "输出设备数  %9 · 系统网络状态  %10")
                     .arg(audio.value("mediaStatus").toInt())
                     .arg(audio.value("errorCode").toInt())
                     .arg(audio.value("positionMs").toLongLong())
                     .arg(audio.value("durationMs").toLongLong())
                     .arg(audio.value("bufferProgress").toDouble() * 100, 0, 'f', 0)
                     .arg(audio.value("decodedBuffers").toLongLong())
                     .arg(audio.value("sampleRateHz").toInt())
                     .arg(audio.value("channels").toInt())
                     .arg(audio.value("outputCount").toInt())
                     .arg(audio.contains("networkReachability")
                              ? QString::number(audio.value("networkReachability").toInt())
                              : QStringLiteral("未采集"));
    // 当前渲染配置：后端取自窗口实际使用的图形 API（不是启动时的选择，回退后也能看出来），
    // 其余取自运行时环境变量——RhiScene 读的是同一份值，所以这里显示的就是真正生效的配置。
    const auto adapter = m_metrics.value("gpuAdapter").toString();
    auto backend = m_metrics.value("gpuBackend").toString();
    if (backend.isEmpty()) {
        backend = graphicsApiName(m_window);
    }
    if (backend.isEmpty()) {
        backend = QStringLiteral("未知");
    }
#ifdef Q_OS_DARWIN
    const auto aaMode = m_engine->renderConfiguration.snapshot().modeName;
#else
    const auto aaMode = qEnvironmentVariable("RHINE_AA_MODE").toLower();
#endif
    const auto aaName = [&aaMode]() -> QString {
        if (aaMode.isEmpty() || aaMode == "off") {
            return QStringLiteral("关闭");
        }
        if (aaMode == "fxaa") {
            return QStringLiteral("FXAA");
        }
        if (aaMode == "ssaa") {
            return QStringLiteral("SSAA 超采样");
        }
        if (aaMode == "msaa") {
            return QStringLiteral("MSAA 多重采样");
        }
        if (aaMode == "taa") {
            return QStringLiteral("TAA 时间抗锯齿");
        }
        // 设置页只有一个 FSR 选项；实际跑的是 FSR3 计算后端还是 EASU/RCAS 片元实现，
        // 由下面附加的引擎标记区分，用户仍然能一眼看出走的是哪一代。
        if (aaMode == "fsr" || aaMode == "fsr1" || aaMode == "fsr3") {
            return QStringLiteral("FSR");
        }
        return aaMode;
    }();
    QString aaLine = aaName;
    if (aaMode == "msaa") {
        // 与 RhiScene::msaaSampleCount() 保持同一套默认值：未设置时目标 4x，
        // 实际采样数由设备能力下取（这里只显示目标值，实际值要看画面）。
        const int configured = qEnvironmentVariableIntValue("RHINE_MSAA");
        const int wanted = configured > 1 ? qBound(2, configured, 8) : 4;
        aaLine += QStringLiteral(" %1x").arg(wanted);
        if (configured <= 1) {
            aaLine += QStringLiteral("（自动）");
        }
    } else if (aaMode == "ssaa") {
        aaLine += QStringLiteral(" · 倍率 %1%").arg(qEnvironmentVariableIntValue("RHINE_AA_SCALE"));
    } else if (aaMode == "fsr" || aaMode == "fsr1" || aaMode == "fsr3") {
        // 引擎由渲染器写入：fsr3 = FFX 计算后端，shader = EASU/RCAS 片元实现。
        const auto engine = qEnvironmentVariable("RHINE_FSR_ENGINE");
        aaLine += engine == "fsr3" ? QStringLiteral("（FSR3）")
                                   : QStringLiteral("（FSR1 EASU/RCAS）");
        // 档位和锐化都直接改变画面，放进监视窗方便和眼睛看到的对照。
        const auto quality = qEnvironmentVariable("RHINE_FSR_QUALITY");
        QString qualityName = QStringLiteral("原生 AA");
        double divisor = 1.;
        if (quality == "super") {
            qualityName = QStringLiteral("超级性能");
            divisor = 3.;
        } else if (quality == "performance") {
            qualityName = QStringLiteral("性能");
            divisor = 2.;
        } else if (quality == "balanced") {
            qualityName = QStringLiteral("平衡");
            divisor = 1.7;
        } else if (quality == "quality") {
            qualityName = QStringLiteral("高质量");
            divisor = 1.5;
        }
        aaLine += QStringLiteral(" · %1 %2x").arg(qualityName).arg(divisor, 0, 'g', 3);
        const int sharpness = qEnvironmentVariableIsEmpty("RHINE_FSR_SHARPNESS")
                                  ? 50
                                  : qEnvironmentVariableIntValue("RHINE_FSR_SHARPNESS");
        aaLine += QStringLiteral(" · 锐化 %1%").arg(sharpness);
    }
#ifdef Q_OS_DARWIN
    if (aaMode == "metalfx") {
        const auto actual = m_engine->renderTelemetry.snapshot().value("implementation").toString();
        aaLine = actual == "metalfx-temporal" ? QStringLiteral("MetalFX 时域抗锯齿 / 超分")
                                             : QStringLiteral("MetalFX 未运行（系统或设备不支持）");
    }
#endif
    const int renderScale =
        qEnvironmentVariableIsEmpty("RHINE_RENDER_SCALE") ? 100 : qEnvironmentVariableIntValue("RHINE_RENDER_SCALE");
    const int supersample =
        qEnvironmentVariableIsEmpty("RHINE_SUPERSAMPLE") ? 1 : qEnvironmentVariableIntValue("RHINE_SUPERSAMPLE");
    QString renderLine = QStringLiteral("渲染 %1%").arg(renderScale);
    if (supersample > 1) {
        renderLine += QStringLiteral(" · 超采样 %1x").arg(supersample);
    }
    // 这一行既有抗锯齿也有 FSR 超分，所以叫"画质模式"；与上面"渲染后端"等宽以便对齐。
    m_details.prepend(QStringLiteral("渲染后端  %1 · GPU 设备  %2\n画质模式  %3 · %4\n")
                          .arg(backend, adapter.isEmpty() ? QStringLiteral("未知") : adapter, aaLine,
                               renderLine));
}

QJsonObject FrameProfiler::environment() const {
    auto backend = graphicsApiName(m_window);
    if (backend.isEmpty()) {
        backend = QStringLiteral("unknown");
    }
    return {{"os", QSysInfo::prettyProductName()},
            {"architecture", QSysInfo::currentCpuArchitecture()},
            {"qt", qVersion()},
            {"logicalCpuCount", QThread::idealThreadCount()},
            {"graphicsApi", backend},
            {"gpuAdapter", m_metrics.value("gpuAdapter").toString()},
            {"windowWidth", m_window ? m_window->width() : 0},
            {"windowHeight", m_window ? m_window->height() : 0},
            {"devicePixelRatio", m_window ? m_window->devicePixelRatio() : 0},
            {"screenRefreshHz", m_window && m_window->screen() ? m_window->screen()->refreshRate() : 0}};
}

/** 手动开启有界采集；与界面可见性解耦，便于记录最小化后的内存释放。 */
bool FrameProfiler::startRecording() {
    if (m_recording || !m_samples.isEmpty()) {
        return false;
    }
    if (!QDir().mkpath(m_directory)) {
        m_status = QStringLiteral("无法创建诊断目录，请检查文稿目录权限。");
        emit changed();
        return false;
    }
    // 丢弃打开面板时已有的半个采样区间，让录制从用户按下按钮时开始。
    sample();
    m_recordStartedMs = clock.elapsed();
    m_recordStoppedMs = 0;
    presentNs.store(0, std::memory_order_relaxed);
    {
        QMutexLocker lock(&m_gapMutex);
        m_trace.clear();
        m_omittedTraceFrames = 0;
        m_capture.store(true, std::memory_order_relaxed);
    }
    m_engine->host.playbackDiagnostics.start();
    m_audioReport = {};
    m_recording = true;
    m_status = QStringLiteral("正在收集性能与音频诊断，请复现问题后停止并导出。");
    updateSampling();
    m_engine->host.playbackDiagnostics.record("snapshot", m_engine->host.playbackSnapshot());
    emit changed();
    return true;
}

/** 原子保存有界数值采样；失败时保留内存中的记录，允许用户再次导出。 */
bool FrameProfiler::saveRecording() {
    if (!m_recording && m_samples.isEmpty()) {
        return false;
    }
    if (m_saving) {
        return false;
    }
    m_saving = true;
    if (m_recording) {
        sample();
        m_recordStoppedMs = clock.elapsed();
        m_engine->host.playbackDiagnostics.record("snapshot", m_engine->host.playbackSnapshot());
        m_engine->host.playbackDiagnostics.stop();
        m_audioReport = m_engine->host.playbackDiagnostics.report();
    }
    m_recording = false;
    QJsonArray trace;
    quint64 omitted = 0;
    {
        QMutexLocker lock(&m_gapMutex);
        m_capture.store(false, std::memory_order_relaxed);
        omitted = m_omittedTraceFrames;
        for (const auto &frame : m_trace) {
            trace.append(QJsonArray{(frame.timestampNs / 1000000.) - m_recordStartedMs,
                                    frame.gapNs / 1000000., frame.syncCpuNs / 1000000.,
                                    frame.submitCpuNs / 1000000.});
        }
    }
    const auto name = "rhine-performance-" + QDateTime::currentDateTimeUtc().toString("yyyyMMdd-HHmmss-zzz") +
                      "-" + QUuid::createUuid().toString(QUuid::WithoutBraces) + ".json";
    QSaveFile report(QDir(m_directory).filePath(name));
    const QJsonObject document{
        {"schema", 2},
        {"startedUtc", QDateTime::fromMSecsSinceEpoch(epochMs + m_recordStartedMs, QTimeZone::UTC)
                           .toString(Qt::ISODateWithMs)},
        {"durationMs", m_recordStoppedMs - m_recordStartedMs},
        {"environment", environment()},
        {"notes", "Qt FPS includes overlay repaints. Gaps include idle intervals. CPU is main-process "
                  "single-core percent; RSS excludes Node. Sync/submit are CPU wall time, not GPU time. No "
                  "account, request payload, track, screenshot, URL, IP, raw error, device identity or "
                  "environment-variable content is collected. Audio fields use numeric allowlists."},
        {"samples", m_samples},
        {"audioPlayback", m_audioReport},
        {"frameColumns", QJsonArray{"elapsedMs", "presentGapMs", "syncCpuMs", "submitCpuMs"}},
        {"frames", trace},
        {"omittedTraceFrames", qint64(omitted)}};
    const auto bytes = QJsonDocument(document).toJson(QJsonDocument::Compact);
    if (!report.open(QIODevice::WriteOnly) || report.write(bytes) != bytes.size() || !report.commit()) {
        m_status = QStringLiteral("导出失败，记录已保留；请检查目录权限后点击“重试导出”。");
        m_saving = false;
        updateSampling();
        emit changed();
        return false;
    }
    m_saving = false;
    m_samples = {};
    m_audioReport = {};
    m_engine->host.playbackDiagnostics.clear();
    {
        QMutexLocker lock(&m_gapMutex);
        QList<FrameEvent>().swap(m_trace);
    }
    m_status = QStringLiteral("已保存：%1").arg(QFileInfo(report.fileName()).fileName());
    updateSampling();
    emit changed();
    return true;
}
