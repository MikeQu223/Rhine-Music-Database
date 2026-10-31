#include <QtGlobal>
#ifdef Q_OS_LINUX
#include <ctime>
#endif
#include "Engine.h"
#include "DiscGeometry.h"
#include "RhiScene.h"
#include "render/MemoryProbe.h"
#include <QCoreApplication>
#include <QDir>
#include <QEvent>
#include <QEventLoop>
#include <QFile>
#include <QJsonDocument>
#include <QPainter>
#include <QQuickWindow>
#include <QThread>
#include <algorithm>
#include <cmath>
#include <cstring>
namespace {
// Halton(2,3) 低差异序列：8 个相位平移到 [-0.5, 0.5) 像素，覆盖 ±0.5 像素抖动范围。
QPointF haltonJitter(int phase) {
    const auto halton = [](int index, int base) {
        double fraction = 1.0;
        double result = 0.0;
        while (index > 0) {
            fraction /= base;
            result += fraction * (index % base);
            index /= base;
        }
        return result;
    };
    const int index = (phase % 8) + 1;
    return {halton(index, 2) - .5, halton(index, 3) - .5};
}
} // namespace
bool runNativeHostChecks(const QString &root);
bool runNativeMusicChecks(const QString &root);

/** 建立纯原生音乐、HUD 和场景状态；Qt 定时器只在输入或动画尚未收束时运行。 */
Engine::Engine(QString path, bool offline, QObject *parent, PlaybackConnection *connection)
    : QObject(parent), host(path, offline, nullptr, false, connection), scene(path), m_glyphs(path) {
    // FSR3 抖动默认关闭；环境变量在进程启动时读取一次，运行期不再变化。
    m_jitterEnabled = qEnvironmentVariableIntValue("RHINE_JITTER") == 1;
    const auto content = QJsonDocument::fromJson(host.read("slots.json").toUtf8()).object();
    app = std::make_unique<NativeApplication>(&host, &m_glyphs, &scene, content);
    connect(&app->music, &MusicLibrary::playbackInvalidated, this, &Engine::refreshPlayback);
    connect(&app->hud, &NativeHud::localImportRequested, this, &Engine::localImportRequested);
#ifdef Q_OS_DARWIN
    renderConfiguration.initialize([this](const QString &key) { return host.preference(key); });
    connect(&host, &Host::preferenceChanged, this, [this](const QString &key, const QString &value) {
        if (renderConfiguration.applyPreference(key, value)) {
            m_temporalFramesRemaining = 0;
            resetTemporalState();
            emit stateChanged();
        }
    });
#endif
    app->initialize();
    connect(QCoreApplication::instance(), &QCoreApplication::aboutToQuit, this,
            [this] { app->saveSession(); });
    connect(&host, &Host::invalidated, this, [this] { wake(WakeSource::Host); });
    connect(&host, &Host::mediaChanged, this, &Engine::pollMedia, Qt::QueuedConnection);
    connect(&host, &Host::mediaAction, this, [this](QString value) {
        app->mediaAction(value);
        wake();
    });
    clock.start();
    // B01：一次性定时器到点后只做一件事——核对焦点是否还稳定、到时，然后主动通知
    // 呈现层出一帧。不能靠"继续出帧等到期"：引擎静止时根本没有下一帧。
    m_admissionScheduler.setHandler([this](const QString &key, quint64 generation) {
        if (m_admission.expire(key, generation, clock.elapsed())) {
            requestSceneContent();
        }
    });
    timer.setTimerType(Qt::PreciseTimer);
    connect(&timer, &QTimer::timeout, this, &Engine::tick);
    mediaTimer.setInterval(1000);
    connect(&mediaTimer, &QTimer::timeout, this, &Engine::pollMedia);
    connect(&m_gamepad, &Gamepad::pressed, this, &Engine::gamepadPressed);
    // 节拍诊断（RHINE_PACE_DIAG=1）：每秒打印一次「引擎 tick 数 vs 实际渲染数」，
    // 用来判定帧率是被引擎定时器限住、还是被呈现侧限住。
    if (qEnvironmentVariableIsSet("RHINE_PACE_DIAG")) {
        auto *diag = new QTimer(this);
        diag->setInterval(1000);
        connect(diag, &QTimer::timeout, this, [this] {
            // C01：同一个窗口里同时给三种"帧"计数，均值一律用总量除以对应次数：
            //   tick   —— 引擎定时器回调次数（含被合并掉的空转）
            //   step   —— 真正跑完的完整 step 次数
            //   render —— 渲染线程上报的实际呈现/绘制次数
            static quint64 lastSteps = 0, lastSkipped = 0, lastScene = 0, lastHud = 0, lastRender = 0,
                           lastWakes = 0, lastRequests = 0, lastChanged = 0, lastResetInput = 0,
                           lastResetScene = 0, lastGpuSamples = 0;
            const quint64 render = m_renderFrames.load(std::memory_order_relaxed);
            const quint64 gpuMicros = m_gpuTimeMicros.load(std::memory_order_relaxed);
            const double avgGap = m_paceTicks > 1 ? double(m_paceGapSum) / (m_paceTicks - 1) / 1e6 : 0;
            const double avgStep = m_paceTicks > 0 ? double(m_paceStepSum) / m_paceTicks / 1e6 : 0;
            const quint64 published = m_pacing.published();
            const quint64 consumed = m_pacing.consumed();
            qInfo("节拍诊断: tick/s=%llu step/s=%llu skip/s=%llu sceneUpd/s=%llu hudUpd/s=%llu "
                  "render/s=%llu changed/s=%llu "
                  "wake/s=%llu(输入 %llu/Host %llu/媒体 %llu/其他 %llu) req/s=%llu "
                  "gpu=%.2fms(最近已完成帧,%s,n=%llu) sync场=%.2fms(n=%llu) "
                  "published=%llu consumed=%llu 未消费差=%llu "
                  "interval=%dms timerActive=%d sleeping=%d sceneSleeping=%d rotating=%d "
                  "hudAnimating=%d pendingAnim=%d stableFrames=%d "
                  "stableReset/s=%llu(输入 %llu/场景 %llu) | "
                  "间隔均=%.2fms 最大=%.2fms step均=%.2fms 最大=%.2fms",
                  qulonglong(m_steps) - lastSteps, qulonglong(m_pacing.skipped()) - lastSkipped,
                  qulonglong(m_sceneUpdates) - lastScene, qulonglong(m_hudUpdates) - lastHud,
                  qulonglong(render) - lastRender, qulonglong(m_changedSteps) - lastChanged,
                  qulonglong(m_wakes) - lastWakes, qulonglong(m_wakesInput), qulonglong(m_wakesHost),
                  qulonglong(m_wakesMedia), qulonglong(m_wakesOther),
                  qulonglong(m_sceneRequests) - lastRequests, gpuMicros / 1000.0,
                  RhineRender::gpuTimingStatusName(RhineRender::GpuTimingStatus(
                      m_gpuTiming.load(std::memory_order_relaxed))),
                  qulonglong(m_gpuSamples) - lastGpuSamples,
                  m_syncMicros.load(std::memory_order_relaxed) / 1000.0,
                  qulonglong(m_syncSamples.load(std::memory_order_relaxed)), qulonglong(published),
                  qulonglong(consumed), qulonglong(published > consumed ? published - consumed : 0),
                  timer.interval(), int(timer.isActive()), int(m_sleeping), int(m_sceneSleeping),
                  int(m_discRotating), int(app->hud.animating(m_animationTime)),
                  int(m_frame.value("pendingAnimations").toBool()), m_stableFrames,
                  qulonglong(m_stableResetInput) + qulonglong(m_stableResetScene) - lastResetInput -
                      lastResetScene,
                  qulonglong(m_stableResetInput) - lastResetInput,
                  qulonglong(m_stableResetScene) - lastResetScene, avgGap,
                  double(m_paceGapMax) / 1e6, avgStep, double(m_paceStepMax) / 1e6);
            lastSteps = qulonglong(m_steps);
            lastSkipped = qulonglong(m_pacing.skipped());
            lastWakes = m_wakes;
            lastChanged = m_changedSteps;
            lastRequests = m_sceneRequests;
            lastGpuSamples = m_gpuSamples;
            lastResetInput = m_stableResetInput;
            lastResetScene = m_stableResetScene;
            lastScene = qulonglong(m_sceneUpdates);
            lastHud = qulonglong(m_hudUpdates);
            lastRender = render;
            m_paceGapSum = m_paceGapMax = 0;
            m_paceStepSum = m_paceStepMax = 0;
            m_paceTicks = 0;
        });
        diag->start();
    }
    if (!offline) {
        start();
    }
}
Engine::~Engine() {
    timer.stop();
    mediaTimer.stop();
    m_gamepad.setEnabled(false);
    app.reset();
    host.shutdown();
}
bool Engine::ready() const {
    return scene.ready();
}
namespace {
// 鼠标滚轮一格的距离按设置页与歌词的行高换算，约一行内容；触控板保留系统给出的连续像素距离。
constexpr double WHEEL_DISTANCE_PER_NOTCH = 80;
// 鼠标滚轮的离散事件按帧衰减送出，约 0.1 秒内收束，避免整格内容瞬间跳变。
constexpr double WHEEL_SMOOTHING = 0.5;
// 尾段直接送出，避免浮点衰减无限拖延最后一次画面更新。
constexpr double WHEEL_DISTANCE_TAIL = 6;
// 只有低于实际显示精度的浮点尾差才可视为收束，时间和诊断计数不参与画面失效。
bool equivalent(const QJsonValue &a, const QJsonValue &b) {
    if (a.type() != b.type()) {
        return false;
    }
    if (a.isDouble()) {
        return qAbs(a.toDouble() - b.toDouble()) <= 0.00001;
    }
    if (a.isArray()) {
        auto x = a.toArray();
        auto y = b.toArray();
        if (x.size() != y.size()) {
            return false;
        }
        for (int i = 0; i < x.size(); ++i) {
            if (!equivalent(x[i], y[i])) {
                return false;
            }
        }
        return true;
    }
    if (a.isObject()) {
        auto x = a.toObject();
        auto y = b.toObject();
        if (x.keys() != y.keys()) {
            return false;
        }
        for (auto it = x.begin(); it != x.end(); ++it) {
            if (!equivalent(it.value(), y[it.key()])) {
                return false;
            }
        }
        return true;
    }
    return a == b;
}
bool equivalent(const QByteArray &a, const QByteArray &b) {
    if (a == b) {
        return true;
    }
    if (a.size() != b.size()) {
        return false;
    }
    for (qsizetype i = 0; i + 4 <= a.size(); i += 4) {
        float x;
        float y;
        memcpy(&x, a.constData() + i, 4);
        memcpy(&y, b.constData() + i, 4);
        if (qAbs(x - y) > 0.00001f) {
            return false;
        }
    }
    return true;
}
}
bool Engine::eventFilter(QObject *watched, QEvent *event) {
    // 原生文本框和滑块也属于用户输入，不能只依赖资料库 MouseArea 的事件。
    switch (event->type()) {
    case QEvent::MouseButtonPress:
        m_pressed = true;
        wake();
        break;
    case QEvent::MouseButtonRelease:
        m_pressed = false;
        wake();
        break;
    case QEvent::MouseMove:
    case QEvent::Wheel:
    case QEvent::KeyPress:
    case QEvent::TouchBegin:
    case QEvent::TouchUpdate:
    case QEvent::TouchEnd:
        wake();
        break;
    default:
        break;
    }
    return QObject::eventFilter(watched, event);
}
void Engine::start() {
    m_started = true;
    wake(false);
}
QVariantMap Engine::performance() const {
    QVariantMap result = {{"idle", m_sleeping},
                          {"sceneSleeping", m_sceneSleeping},
                          {"visible", m_visible},
                          {"steps", qulonglong(m_steps)},
                          {"sceneUpdates", qulonglong(m_sceneUpdates)},
                          {"hudUpdates", qulonglong(m_hudUpdates)},
                          {"renderFrames", qulonglong(m_renderFrames.load(std::memory_order_relaxed))},
                          {"gpuResources", qulonglong(m_gpuResources.load(std::memory_order_relaxed))},
                          {"bindingCreations", qulonglong(m_bindingCreations.load(std::memory_order_relaxed))},
                          {"gpuMusicTextureBytes", qulonglong(m_musicTextureBytes.load(std::memory_order_relaxed))},
                          {"coverUploads", qulonglong(m_coverUploads.load(std::memory_order_relaxed))},
                          {"gpuDrawCalls", qulonglong(m_lastDrawCalls.load(std::memory_order_relaxed))},
                          {"timerActive", timer.isActive()}};
    const quint64 gpuMicros = m_gpuTimeMicros.load(std::memory_order_relaxed);
    // 0 表示后端没有可用的时间戳；保留空值，避免把“未测量”显示成 0 ms。
    if (gpuMicros) {
        result.insert("gpuTimeMs", gpuMicros / 1000.0);
    }
    // 状态无条件发布：没有样本时它正是唯一能说明"为什么没有"的信息，而 gpuTimeMs 的
    // 缺省只表示"这次没测到"。两者语义不同，不能让前者被后者吞掉（A01）。
    result.insert("gpuTimingStatus",
                  QString::fromLatin1(RhineRender::gpuTimingStatusName(RhineRender::GpuTimingStatus(
                      m_gpuTiming.load(std::memory_order_relaxed)))));

    // ---- A11 整帧资源账本 ----
    // 下面这些键和上面的"当前快照"不是同一口径，命名与 CSV 列都带 ledger/peak 前缀，
    // 避免分析脚本把"窗口峰值"当成"本帧值"。峰值窗口 = 最近 kLedgerWindow 个渲染帧。
    const quint64 renderFrames = m_renderFrames.load(std::memory_order_relaxed);
    const quint64 coverUploads = m_coverUploads.load(std::memory_order_relaxed);
    result.insert("gpuResourcesPeak", qulonglong(m_resourcesPeak.load(std::memory_order_relaxed)));
    result.insert("gpuResourcesPeakFrame",
                  qulonglong(m_resourcesPeakFrame.load(std::memory_order_relaxed)));
    result.insert("gpuTextureBytesPeak",
                  qulonglong(m_textureBytesPeak.load(std::memory_order_relaxed)));
    result.insert("gpuTextureBytesPeakFrame",
                  qulonglong(m_textureBytesPeakFrame.load(std::memory_order_relaxed)));
    result.insert("frameBindings", qulonglong(m_frameBindings.load(std::memory_order_relaxed)));
    result.insert("frameCoverUploads",
                  qulonglong(m_frameCoverUploads.load(std::memory_order_relaxed)));
    result.insert("coverUploadsPerFrame",
                  m_coverUploadsPerFrameMilli.load(std::memory_order_relaxed) / 1000.0);
    // 重传率：累计封面上传次数按"每千个渲染帧"归一。用千帧而不是比值，是因为正常情况
    // 下每帧上传次数远小于 1，比值会长期贴在 0.0x 这种没有分辨率的刻度上。
    result.insert("coverRetransmitPerKFrame",
                  renderFrames ? coverUploads * 1000.0 / double(renderFrames) : 0.0);
    const quint64 budgetBytes = resourceBudgetBytes();
    result.insert("resourceBudgetMb", qulonglong(budgetBytes / (1024ull * 1024ull)));
    return result;
}

quint64 Engine::resourceBudgetBytes() {
    // 默认 0 = 关闭。只接受正数；写错（负数/非数字）按关闭处理，避免把预算误当 1 字节。
    static const quint64 bytes = [] {
        bool ok = false;
        const qlonglong mb = qEnvironmentVariable("RHINE_RESOURCE_BUDGET_MB").toLongLong(&ok);
        return ok && mb > 0 ? quint64(mb) * 1024ull * 1024ull : quint64(0);
    }();
    return bytes;
}

/** A11：渲染线程每帧调用一次，维护滚动窗口峰值、本帧增量与封面上传速率。 */
void Engine::noteFrameLedger(quint64 resources, quint64 bindings, quint64 textureBytes,
                             quint64 coverUploads) {
    // frame 已经是 ++ 之后的值：对外的帧号口径与 renderFrames 一致（1 基）。
    const quint64 frame = m_renderFrames.load(std::memory_order_relaxed);
    m_frameBindings.store(bindings, std::memory_order_relaxed);
    m_frameCoverUploads.store(coverUploads, std::memory_order_relaxed);

    // 封面上传速率用 EMA（alpha=0.05，约 20 帧窗口）：单帧样本抖动大，而"是不是每帧
    // 都在重传"恰恰要看持续水平。不用呈现层那套 0.15，是为了压住偶发的一两次上传。
    m_coverUploadsEma = m_coverUploadsEma <= 0.0
                            ? double(coverUploads)
                            : m_coverUploadsEma * 0.95 + double(coverUploads) * 0.05;
    m_coverUploadsPerFrameMilli.store(quint64(m_coverUploadsEma * 1000.0 + 0.5),
                                      std::memory_order_relaxed);

    const bool full = m_ledgerFilled >= kLedgerWindow;
    const LedgerSlot expired = m_ledgerWindow[m_ledgerCursor];
    m_ledgerWindow[m_ledgerCursor] = LedgerSlot{frame, resources, textureBytes};
    m_ledgerCursor = (m_ledgerCursor + 1) % kLedgerWindow;
    if (!full) {
        ++m_ledgerFilled;
    }

    // 三种情况必须重算：窗口还没填满（峰值帧号可能变）、出现更大的样本、或者刚被
    // 覆盖掉的旧样本正好是当前峰值的持有者（最大值离开了窗口）。其余情况沿用旧峰值，
    // 不用每帧扫 240 个槽——这是渲染线程上的热路径。
    const quint64 resourcesPeak = m_resourcesPeak.load(std::memory_order_relaxed);
    const quint64 texturePeak = m_textureBytesPeak.load(std::memory_order_relaxed);
    if (!full || resources >= resourcesPeak || textureBytes >= texturePeak ||
        expired.resources == resourcesPeak || expired.textureBytes == texturePeak) {
        recomputeLedgerPeaks();
    }

    // 预算告警：只打印一次，不改渲染行为。让预算触发降级会把"诊断"变成隐藏的
    // 质量开关，之后所有对比数据都失去可比性。
    const quint64 budgetBytes = resourceBudgetBytes();
    if (budgetBytes > 0 && textureBytes > budgetBytes &&
        !m_budgetWarned.exchange(true, std::memory_order_relaxed)) {
        const double currentMiB = double(textureBytes) / (1024.0 * 1024.0);
        const double budgetMiB = double(budgetBytes) / (1024.0 * 1024.0);
        qWarning().noquote()
            << QStringLiteral("资源预算超限：整帧驻留纹理 %1 MiB 超过上限 %2 MiB"
                              "（RHINE_RESOURCE_BUDGET_MB，第 %3 个渲染帧）。"
                              "建议：减少同时驻留的封面数或降低封面尺寸，"
                              "也可以把上限调到 %4 MiB 以上。本告警只打印一次，"
                              "不改变渲染行为。")
                   .arg(currentMiB, 0, 'f', 1)
                   .arg(budgetMiB, 0, 'f', 1)
                   .arg(frame)
                   .arg(currentMiB, 0, 'f', 0);
    }
}

/** 按时间顺序扫一遍环形窗口，取资源个数/纹理字节的滚动峰值及其持有帧号。 */
void Engine::recomputeLedgerPeaks() {
    quint64 bestResources = 0, bestResourcesFrame = 0;
    quint64 bestTextureBytes = 0, bestTextureBytesFrame = 0;
    // 从最老的槽开始按时间顺序遍历，`>=` 让相同峰值取更新的那一帧（复查时更有意义）。
    for (int i = 0; i < m_ledgerFilled; ++i) {
        const LedgerSlot &slot = m_ledgerWindow[(m_ledgerCursor + i) % kLedgerWindow];
        if (slot.resources >= bestResources) {
            bestResources = slot.resources;
            bestResourcesFrame = slot.frame;
        }
        if (slot.textureBytes >= bestTextureBytes) {
            bestTextureBytes = slot.textureBytes;
            bestTextureBytesFrame = slot.frame;
        }
    }
    m_resourcesPeak.store(bestResources, std::memory_order_relaxed);
    m_resourcesPeakFrame.store(bestResourcesFrame, std::memory_order_relaxed);
    m_textureBytesPeak.store(bestTextureBytes, std::memory_order_relaxed);
    m_textureBytesPeakFrame.store(bestTextureBytesFrame, std::memory_order_relaxed);
}
/** 仅在画面变化时通知唯一场景，静止时保留按需休眠。 */
void Engine::notifySceneRenderers(bool visualChanged) {
    if (visualChanged) {
        // A03：版本只在真的推进内容时自增。呈现层拿它当"这一帧有没有新内容"的唯一判据，
        // 重复推同一个值不会造成重复重渲；而信号是没法这么用的——同一个内容变化会被
        // 场景帧、HUD、异步资源到达各触发一次。
        m_sceneRevision.fetch_add(1, std::memory_order_relaxed);
        emit sceneUpdated();
    }
}

/** A03：渲染线程上报"新资源已就位"。语义与一次真实的视觉变化相同，只是触发者不是帧字段。 */
void Engine::requestSceneContent() {
    ++m_sceneRequests;
    notifySceneRenderers(true);
    // C04：资源就绪也算一次"视觉快照发布"。它不推进模拟，但要让节拍知道
    // "还有一份没被消费"，否则下一拍会当成无事可做。
    m_pacing.publish(sceneRevision(), clock.elapsed());
}
/**
 * C04：渲染线程在 synchronize() 里调用。只写原子序号，再排一次队列回调；不在渲染线程
 * 等 GUI，也不做任何可能阻塞的分配。
 */
void Engine::noteSceneConsumed(quint64 revision) {
    if (revision == 0) {
        return;
    }
    const quint64 previous = m_sceneConsumed.load(std::memory_order_relaxed);
    if (revision <= previous) {
        return;
    }
    m_sceneConsumed.store(revision, std::memory_order_relaxed);
    // 同一个序号只排一次唤醒：渲染线程可能连续同步很多帧。
    quint64 notified = m_consumeNotified.load(std::memory_order_relaxed);
    if (revision > notified && m_consumeNotified.compare_exchange_strong(notified, revision)) {
        QMetaObject::invokeMethod(this, "sceneConsumed", Qt::QueuedConnection);
    }
}
void Engine::sceneConsumed() {
    m_pacing.consume(m_sceneConsumed.load(std::memory_order_relaxed));
    // 渲染线程已经取走上一份，待办动画／输入需要下一拍；不该靠 1ms 轮询自己撞上。
    if (m_started && m_visible && !timer.isActive()) {
        m_lastTick = clock.elapsed();
        timer.start(0);
    }
}
void Engine::wake(bool input) {
    wake(input ? WakeSource::Input : WakeSource::Other);
}
void Engine::wake(WakeSource source) {
    switch (source) {
    case WakeSource::Input:
        ++m_wakesInput;
        m_inputPending = true;
        break;
    case WakeSource::Host:
        ++m_wakesHost;
        break;
    case WakeSource::Media:
        ++m_wakesMedia;
        break;
    case WakeSource::Other:
        ++m_wakesOther;
        break;
    }
    ++m_wakes;
    const bool input = source == WakeSource::Input;
    const bool wasSleeping = m_sleeping;
    const auto now = clock.elapsed();
    if (input) {
        m_lastInput = now;
        m_sceneSleeping = false;
        if (m_stableFrames != 0) {
            ++m_stableResetInput;
        }
        m_stableFrames = 0;
        scene.energyIdle(false);
    } else if (scene.changed()) {
        m_sceneSleeping = false;
        if (m_stableFrames != 0) {
            ++m_stableResetScene;
        }
        m_stableFrames = 0;
    }
    m_sleeping = !m_visible;
    if (wasSleeping && !m_sleeping) {
        emit stateChanged();
    }
    if (m_started && m_visible && !timer.isActive()) {
        // 恢复时接续视觉时钟，不能把整段待机时间推进到弹簧和拖动惯性中。
        m_lastTick = now;
        const int resumeMs = frameIntervalMs();
        timer.start(resumeMs > 0 ? resumeMs : 0);
    }
}
void Engine::resetTemporalState() {
    // FSR 重置：抖动立即归零并回到第 0 相位；下一帧带 temporalReset 键，
    // 渲染器据此清空上一帧模型矩阵，速度目标输出 0，避免时间累积残影。
    m_jitterPhase = 0;
    m_jitterOffset = {};
    m_temporalResetPending = true;
    m_frame["temporalReset"] = true;
    m_frame.remove("jitter");
    // 重置必须立即产生一帧：否则场景休眠时渲染器收不到 temporalReset，历史会留到下次唤醒。
    m_sceneSleeping = false;
    m_stableFrames = 0;
    wake(false);
    notifySceneRenderers(true);
}
/**
 * B01：把当前列表焦点交给准入状态机。每帧调用，但只有焦点 key 真的换了才会重新计时；
 * 同 key 重复帧、封面晚到、revision 变化都不重计时（见 MusicTextureAdmission::focus）。
 */
void Engine::submitTextureAdmission(const QString &musicKey) {
    const auto status = m_admission.focus(musicKey, clock.elapsed());
    if (status.pending) {
        if (status.generation != m_admissionArmed) {
            // 代号变了才 arm：同一焦点若每帧 arm 一次，到期时间会被无限推后。
            m_admissionArmed = status.generation;
            m_admissionScheduler.arm(m_admission.delayMs(), m_admission.pendingKey(), status.generation);
        }
        return;
    }
    m_admissionArmed = status.generation;
    m_admissionScheduler.stop();
}
void Engine::setVisible(bool value) {
    if (m_visible == value) {
        return;
    }
    m_visible = value;
    m_gamepad.setEnabled(value);
    if (!value) {
        flushPointer();
        app->pointer("pointercancel", 0, 0);
        m_pressed = m_wheelPending = false;
        m_wheelDelta = m_wheelSteps = 0;
        m_wheelDistance = 0;
        m_wheelRemainingDistance = 0;
        timer.stop();
        m_sleeping = true;
        // 隐藏期间不创建 GPU 资源：作废"等到一半"的等待，恢复后重新计时。
        m_admission.setVisible(false, clock.elapsed());
        m_admissionScheduler.stop();
    } else {
        m_admission.setVisible(true, clock.elapsed());
        host.restoreMemoryBudget();
#ifdef Q_OS_DARWIN
        if (renderConfiguration.snapshot().temporal()) {
            resetTemporalState();
        }
#endif
        wake(false);
        notifySceneRenderers(true);
        m_hudRevision.fetch_add(1, std::memory_order_relaxed);
        emit hudUpdated();
    }
    emit stateChanged();
}
/**
 * 隐藏窗口持续一段时间后释放可重建缓存，不改变音乐、账号或尚未完成的动画。
 */
void Engine::trimMemory() {
    if (m_visible) {
        return;
    }
    QStringList retainedImages{m_cover};
    for (const auto &value : m_commands) {
        const auto command = value.toArray();
        if (command[0].toString() == "image") {
            retainedImages << command[1].toString();
        }
    }
    host.trimMemory(retainedImages);
    scene.trimMemory();
}
/** 播放栏按需重绘时保持资源库休眠；只有可见的旋转或歌词动画需要连续调度。 */
void Engine::refreshPlayback() {
    if (!m_visible) {
        return;
    }
    if (!m_sleeping || !m_sceneSleeping || scene.changed()) {
        wake(false);
        return;
    }
    step(m_animationTime);
    if (m_discRotating || app->hud.animating(m_animationTime)) {
        wake(false);
    }
}

void Engine::pollMedia() {
    app->poll(clock.elapsed() / 1000.0, true);
    const auto &player = app->music.player;
    const bool active = player.loading || player.state["playing"].toBool();
    if (active && !mediaTimer.isActive()) {
        mediaTimer.start();
    }
    if (!active) {
        mediaTimer.stop();
    }
}
void Engine::flushPointer() {
    if (!m_pointerPending) {
        return;
    }
    m_pointerPending = false;
    app->pointer("pointermove", m_pointerX, m_pointerY);
}
/**
 * 推进本帧动画并决定是否继续调度。
 * 状态收束后允许待机，输入和后台数据失效会重新唤醒。
 */
void Engine::tick() {
    const qint64 enterNs = clock.nsecsElapsed();
    if (m_paceEnterNs != 0) {
        const qint64 gap = enterNs - m_paceEnterNs;
        m_paceGapSum += gap;
        m_paceGapMax = qMax(m_paceGapMax, gap);
    }
    m_paceEnterNs = enterNs;
    const auto now = clock.elapsed();
    // C04：完整 step 只在"这一份快照还有机会被看到"时跑。渲染线程还没取走上一份，
    // 现在算出来的中间状态会被直接覆盖——这部分 CPU 在任何一帧上都看不到。
    const bool inputPending = m_inputPending || m_wheelPending || m_pressed || m_pointerPending;
    const bool workPending = inputPending || scene.changed() || !m_sceneSleeping || m_discRotating ||
                             app->hud.animating(m_animationTime) ||
                             m_frame.value("pendingAnimations").toBool() || m_temporalFramesRemaining > 0 ||
                             m_frame.value("mode") == "boot";
    if (!inputPending) {
        const auto decision = m_pacing.decide(workPending, false, now);
        if (decision.action == RhineRender::FramePacingPolicy::Action::Skip) {
            m_pacing.noteStep(true);
            ++m_stepsSkipped;
            ++m_paceTicks;
            // 1ms 只为尽早看到消费进度；这一次 tick 本身几乎不花钱。
            timer.setInterval(1);
            return;
        }
    }
    m_animationTime += qMin<qint64>(now - m_lastTick, 50) / 1000.;
    m_lastTick = now;
    flushPointer();
    // 鼠标滚轮一格的连续距离按帧衰减送出；列表行数仍按格立即推进。
    if (m_wheelRemainingDistance != 0) {
        const auto portion = std::abs(m_wheelRemainingDistance) < WHEEL_DISTANCE_TAIL
                                 ? m_wheelRemainingDistance
                                 : m_wheelRemainingDistance * WHEEL_SMOOTHING;
        m_wheelDistance += portion;
        m_wheelRemainingDistance -= portion;
        m_wheelPending = true;
    }
    if (m_wheelPending) {
        const int steps = int(m_wheelSteps);
        app->hud.wheel(m_wheelX, m_wheelY, m_wheelDelta, steps, m_wheelDistance);
        m_wheelSteps -= steps;
        m_wheelPending = false;
        m_wheelDelta = 0;
        m_wheelDistance = 0;
    }
    if (now - m_lastInput >= 750 && !m_pressed) {
        scene.energyIdle(true);
    }
    const qint64 stepStartNs = clock.nsecsElapsed();
    step(m_animationTime);
    const qint64 stepNs = clock.nsecsElapsed() - stepStartNs;
    m_paceStepSum += stepNs;
    m_paceStepMax = qMax(m_paceStepMax, stepNs);
    ++m_paceTicks;
    // C04：发布序号就是内容版本；没有视觉变化时这里不会前进，策略自然放行下一拍。
    m_pacing.publish(sceneRevision(), clock.elapsed());
    m_pacing.noteStep(false);
    m_inputPending = false;
    // 动态帧间隔：不设固定周期常数，帧率上限完全交给呈现侧（垂直同步/缓冲回收）。
#ifdef Q_OS_LINUX
    // 注意 blockedNs 的口径：它只覆盖 tick() 内部、step() 之外的微秒级开销（指针 flush、
    // 滚轮衰减、energyIdle），**测不到呈现阻塞**——呈现工作在 PresentationShell 的另一个
    // 定时器回调里，根本不在 tick() 的调用栈内。所以这里恒走 interval=1：渲染期间 GUI
    // 线程被占，定时器本来就投递不进来；渲染结束后的 1ms 是留给事件处理的余量，不是限速。
    // 若以后真要让引擎节拍感知呈现成本，必须由呈现层回传实测帧时长，不能靠这里算。
#else
    // 用本帧实测的「呈现阻塞时长」决定要不要让出时间：
    //   · 阻塞 > 2ms：呈现自己就在限速，连轴转（0ms），不额外加延迟；
    //   · 阻塞 ≤ 2ms：说明呈现不阻塞，继续连轴转只会空转烧 CPU，让出 1ms。
#endif
    // RHINE_TICK_MS 仍可作为排障时人为压帧的覆盖值（>0 时生效）。
    const int fixedMs = frameIntervalMs();
    const bool rotationOnly = m_discRotating && m_sceneSleeping && !app->hud.animating(m_animationTime) &&
                              now - m_lastInput >= 750 && !m_pressed;
    // C04：节奏只由"上一份快照有没有被消费"决定。tick() 内部量到的 frameNs-stepNs
    // 测不到呈现阻塞（呈现工作在别的回调里），原来用它推断节流只会恒定落到 1ms。
    int intervalMs = m_pacing.awaitingConsumption() ? 1 : 0;
    if (rotationOnly) {
        intervalMs = 33;
    }
    timer.setInterval(fixedMs > 0 ? fixedMs : intervalMs);
    // 排障专用：RHINE_DIAG_ANIMATE=1 时永不休眠。静止场景下引擎会主动休眠、
    // presented 不再增长，那时测出来的"帧率"是没有负载的数字，A/B 对比没有意义。
    static const bool forceAnimate = qEnvironmentVariableIsSet("RHINE_DIAG_ANIMATE");
    if (!forceAnimate && now - m_lastInput >= 750 && !m_pressed && m_sceneSleeping && !scene.changed() &&
        !app->hud.animating(m_animationTime) && !m_discRotating && m_frame["mode"] != "boot" &&
        m_temporalFramesRemaining == 0 && !m_pacing.awaitingConsumption()) {
        timer.stop();
        m_sleeping = true;
        emit stateChanged();
    }
}
void Engine::resize(double width, double height) {
    if (height <= 0 || (m_width == width && m_height == height)) {
        return;
    }
    m_width = width;
    m_height = height;
    scene.resize(width / (height / 1080), 1080);
    wake();
}
void Engine::action(QString value) {
    if (value == "performance:toggle") {
        emit performanceRequested();
        return;
    }
    // 窗口模式由 Qt 原生窗口处理，不进入音乐状态或场景动画。
    if (value == "window:fullscreen") {
        toggleFullscreen();
        return;
    }
    app->hud.action(value);
    pollMedia();
    wake();
}
/**
 * 将输入控件的原始数据转换为原生业务操作
 */
void Engine::submitForm(QString account, QString captcha) {
    QJsonObject values;
    if (app->hud.modal == "login") {
        values = {{"account", account}, {"captcha", captcha}};
    } else {
        values = {{"name", account}};
    }
    app->hud.form(values);
    wake();
}
void Engine::setWindow(QWindow *window) {
    m_window = window;
}
int Engine::frameIntervalMs() const {
    // 返回 >0 表示「人为覆盖帧间隔」；返回 -1 表示交给 tick() 里的动态自适应。
    // 刻意不设固定周期：任何常数都会把帧周期变成「工作量 + 常数」，机器再快也上不去。
    // 也不从屏幕刷新率推导：上限应该由呈现侧决定，而不是先给自己设一道墙。
    // RHINE_TICK_MS 仅保留为排障旋钮：想人为压低帧率时设 4..100。
    static const int overrideMs = qEnvironmentVariableIntValue("RHINE_TICK_MS");
    if (overrideMs >= 4 && overrideMs <= 100) {
        return overrideMs;
    }
    return -1;
}

void Engine::sendLoginCode(QString phone) {
    if (app->hud.modal == "login" && app->music.loginMethod == "phone") {
        app->music.sendLoginCode(phone);
        wake();
    }
}
/**
 * 最小化时保留最大化或全屏标记
 */
void Engine::minimizeWindow() {
    if (!m_window) {
        return;
    }
    m_window->setWindowStates(m_window->windowStates() | Qt::WindowMinimized);
    m_window->setVisible(true);
}
void Engine::toggleFullscreen() {
    if (!m_window) {
        return;
    }
    if (m_window->visibility() == QWindow::FullScreen) {
        m_window->setVisibility(m_windowedVisibility);
    } else {
        m_windowedVisibility =
            m_window->visibility() == QWindow::Maximized ? QWindow::Maximized : QWindow::Windowed;
        m_window->showFullScreen();
    }
}
void Engine::gamepadPressed(const QString &button) {
    if (button == "up") {
        key("ArrowUp", false);
    } else if (button == "down") {
        key("ArrowDown", false);
    } else if (button == "left") {
        key("ArrowLeft", false);
    } else if (button == "right") {
        key("ArrowRight", false);
    } else if (button == "a") {
        key("Enter", false);
    } else if (button == "b") {
        key("Escape", false);
    } else if (button == "select") {
        action("menu");
    } else if (button == "start") {
        action("home");
    } else if (button == "lb") {
        action("column-prev");
    } else if (button == "rb") {
        action("column-next");
    } else if (button == "lt") {
        action("player:prev");
    } else if (button == "rt") {
        action("player:next");
    } else if (button == "ls") {
        action("player:toggle");
    } else if (button == "rs") {
        action("player:open");
    }
}

bool Engine::keyEvent(int keyCode, int modifiers, QString text) {
    const bool accepted = keyEventImpl(keyCode, modifiers, text);
    // 探针：确认按键真的走进了 QML 输入层，以及有没有被消费掉（RHINE_KEY_PROBE=1）。
    if (qEnvironmentVariableIntValue("RHINE_KEY_PROBE") == 1) {
        qInfo().noquote() << "按键到达输入层: 键" << keyCode << "接受" << accepted;
    }
    return accepted;
}

bool Engine::keyEventImpl(int keyCode, int modifiers, QString text) {
    switch (keyCode) {
    case Qt::Key_MediaTogglePlayPause:
    case Qt::Key_MediaPlay:
    case Qt::Key_MediaPause:
        action("player:toggle");
        return true;
    case Qt::Key_MediaNext:
        action("player:next");
        return true;
    case Qt::Key_MediaPrevious:
        action("player:prev");
        return true;
    case Qt::Key_Left:
        text = "ArrowLeft";
        break;
    case Qt::Key_Right:
        text = "ArrowRight";
        break;
    case Qt::Key_Up:
        text = "ArrowUp";
        break;
    case Qt::Key_Down:
        text = "ArrowDown";
        break;
    case Qt::Key_Return:
    case Qt::Key_Enter:
        text = "Enter";
        break;
    case Qt::Key_Escape:
        text = "Escape";
        break;
    case Qt::Key_Tab:
        text = "Tab";
        break;
    default:
        break;
    }
    if (text.isEmpty()) {
        return false;
    }
    // Qt 在 macOS 将 ControlModifier 映射到命令键。
    key(text, modifiers & Qt::ControlModifier);
    return true;
}
void Engine::searchAccepted(QString text, int modifiers) {
    if (modifiers & Qt::ControlModifier) {
        key("Enter", true);
    } else {
        query(text);
    }
}
void Engine::wheelInput(double x, double y, double pixelDelta, double angleDelta) {
    wheel(x, y, pixelDelta != 0 ? pixelDelta : angleDelta / 8, pixelDelta != 0);
}
void Engine::adjustPlayer(QString control, double x, double width) {
    if (width <= 0 || (control != "seek" && control != "volume")) {
        return;
    }
    action("player:" + control + "-fraction:" + QString::number(std::clamp(x / width, 0., 1.), 'g', 16));
}
void Engine::query(QString value) {
    app->hud.setQuery(value);
    wake();
}
void Engine::key(QString value, bool command) {
    app->hud.key(value, command);
    wake();
}
void Engine::settingEditText(QString text) {
    app->hud.setSettingEditText(text);
    wake();
}
void Engine::settingEditAccepted() {
    app->hud.commitSettingEdit();
    wake();
}
void Engine::settingEditCancel() {
    app->hud.cancelSettingEdit();
    wake();
}
void Engine::pointer(QString type, double x, double y) {
    if (type == "pointermove") {
        if (m_pointerX == x && m_pointerY == y && !m_pointerPending) {
            return;
        }
        m_pointerX = x;
        m_pointerY = y;
        m_pointerPending = true;
    } else {
        flushPointer();
        app->pointer(type, x, y);
        if (type == "pointerdown") {
            m_pressed = true;
        }
        if (type == "pointerup" || type == "pointercancel" || type == "pointerleave") {
            m_pressed = false;
        }
    }
    wake();
}
void Engine::wheel(double x, double y, double delta, bool pixels) {
    if (!std::isfinite(delta) || delta == 0) {
        return;
    }
    m_wheelX = x;
    m_wheelY = y;
    m_wheelDelta += delta;
    if (pixels) {
        m_wheelSteps += -delta / 15.;
        // 单独保留连续舞台位移，避免触控板不足一行的输入被整数行索引吞掉。
        m_wheelDistance += -delta / (m_height / 1080.);
    } else {
        // 列表按格立即推进一行，只有设置页和歌词需要平滑的连续距离。
        m_wheelSteps += delta < 0 ? 1 : -1;
        const auto distance = -delta / 15. * WHEEL_DISTANCE_PER_NOTCH;
        if (app->hud.reduced) {
            m_wheelDistance += distance;
        } else {
            m_wheelRemainingDistance += distance;
        }
    }
    m_wheelPending = true;
    wake();
}
/**
 * 按顺序同步场景、音乐和 HUD 帧数据，保持绘制与命中区域一致。
 */
#ifdef Q_OS_LINUX
// RHINE_STEP_PROBE=1：拆开引擎每拍成本，并区分"干活"与"等待"。
// 墙钟远大于线程 CPU 时间 => 这一拍是在阻塞（锁、GPU、内存回读），不是算得多。
static double stepWallSum = 0, stepCpuSum = 0, stepAppSum = 0, stepRestSum = 0;
static int stepProbeFrames = 0;

static double threadCpuMs() {
    timespec ts{};
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    return double(ts.tv_sec) * 1e3 + double(ts.tv_nsec) / 1e6;
}

#endif
void Engine::step(double time) {
    if (!ready()) {
        return;
#ifdef Q_OS_LINUX
    }
    const bool stepProbe = qEnvironmentVariableIntValue("RHINE_STEP_PROBE") == 1;
    const double stepT0 = stepProbe ? threadCpuMs() : 0.0;
    const qint64 stepWall0 = stepProbe ? clock.nsecsElapsed() : 0;
    QElapsedTimer stepAppTimer;
    if (stepProbe) {
        stepAppTimer.start();
#endif
    }
    QElapsedTimer frameTimer;
    if (scene.isProfiling()) {
        frameTimer.start();
        // 复用睡眠场景的帧不能沿用上次模拟耗时，否则现场日志会误报瓶颈。
        scene.timings = {};
    }
    ++m_steps;
    if (scene.changed()) {
        ++m_changedSteps;
    }
    const bool reuse = m_sceneSleeping && !scene.changed();
    const auto object = app->step(time, m_width / (m_height / 1080), reuse);
#ifdef Q_OS_LINUX
    const double stepAppMs = stepProbe ? double(stepAppTimer.nsecsElapsed()) / 1e6 : 0.0;
#endif
    if (object.isEmpty()) {
        return;
    }
    const auto previousDiscAngle = m_frame.value("discAngle").toDouble();
    m_frame = scene.frame;
    auto signature = m_frame;
    for (const auto &key : {"time", "stats", "labels", "boot", "pointerCursor", "jitter", "temporalReset"}) {
        signature.remove(key);
    }
    // FSR3 亚像素抖动：默认关闭；关闭时 frame 里没有 jitter 键，渲染路径与之前完全一致。
    // 相位只在真正产生帧的 step 里推进，按 8 帧循环。
    // 但时间性抗锯齿（FSR3/TAA）本身就是靠相位差累积历史，没有抖动它们只会反复混合
    // 同一张图、等于白做，所以这两者开启时无条件打开。AA 模式每帧读环境变量，切换免重启。
#ifdef Q_OS_DARWIN
    const bool metalFxTemporal = m_frame.value("mode") != "boot" && renderConfiguration.snapshot().temporal();
    if (!metalFxTemporal) {
        m_temporalFramesRemaining = 0;
    }
    const bool temporal = metalFxTemporal;
#else
    const auto aaMode = qEnvironmentVariable("RHINE_AA_MODE");
    // 空间 FSR 回退不累积历史，不能继续投影抖动，否则静止画面会逐帧闪动。
    const bool computeFsr =
        (aaMode == "fsr" || aaMode == "fsr3") && qEnvironmentVariable("RHINE_FSR_ENGINE") == "fsr3";
    const bool temporal = aaMode == "taa" || computeFsr;
#endif
    if (m_jitterEnabled || temporal) {
        m_jitterOffset = haltonJitter(m_jitterPhase);
        m_jitterPhase = (m_jitterPhase + 1) % 8;
        m_frame["jitter"] = QJsonArray{m_jitterOffset.x(), m_jitterOffset.y()};
    } else {
        m_jitterOffset = {};
    }
    if (m_temporalResetPending) {
        m_frame["temporalReset"] = true;
        m_temporalResetPending = false;
    }
    bool stable =
        equivalent(signature, m_sceneSignature) && m_previousBuffers.size() == scene.drawBuffers.size();
    for (auto it = scene.drawBuffers.begin(); stable && it != scene.drawBuffers.end(); ++it) {
        const auto old = m_previousBuffers.value(it.key());
        stable = equivalent(it->matrices, old.matrices) && equivalent(it->themes, old.themes);
    }
    m_stableFrames = stable ? m_stableFrames + 1 : 0;
    if (!stable) {
        ++m_geometryRevision;
    }
    if (!stable || scene.changed()) {
        m_sceneSleeping = false;
    }
    m_sceneSignature = signature;
    m_previousBuffers = scene.drawBuffers;
    if (m_stableFrames >= 4 && !scene.changed() && m_frame.value("mode") != "boot" &&
        !m_frame.value("pendingAnimations").toBool()) {
        m_sceneSleeping = true;
    }
    const auto current = object["current"].toObject();
    const auto cover = object["cover"].toString();
    const auto coverRevision = host.image(cover).cacheKey();
    const auto &player = app->music.player;
    const auto identity = PlaybackQueue::identity(player.current);
    if (identity != m_discIdentity) {
        m_discIdentity = identity;
        m_discAngle = 0;
    }
    const bool wasRotating = m_discRotating;
    m_discRotating = m_visible && app->hud.discRotation && !app->hud.reduced && app->hud.modal.isEmpty() &&
                     m_frame.value("mode") == "detail" && !m_frame.value("viewer").toBool() &&
                     current["kind"] == "song" && PlaybackQueue::identity(current) == identity &&
                     !player.loading && !player.failed && player.state["playing"].toBool();
    if (wasRotating && m_discRotating) {
        // 20 秒一圈；接续可见视觉时钟，暂停或隐藏期间不补转。
        m_discAngle = std::fmod(m_discAngle + std::clamp(time - m_discTime, 0., .05) *
                                                  (2 * 3.14159265358979323846 / 20),
                                2 * 3.14159265358979323846);
    }
    m_discTime = time;
    const bool showDiscAngle = current["kind"] == "song" && PlaybackQueue::identity(current) == identity;
    m_frame["discAngle"] = showDiscAngle ? m_discAngle : 0;
    const bool discChanged = m_discRotating || previousDiscAngle != m_frame.value("discAngle").toDouble();
    bool visualChanged = discChanged || !stable || current != m_current || cover != m_cover ||
                         coverRevision != m_coverRevision;
    if (!temporal) {
        m_temporalFramesRemaining = 0;
    }
    if (temporal && (visualChanged || m_frame["temporalReset"].toBool())) {
        m_temporalFramesRemaining = 8;
    }
    if (temporal && m_temporalFramesRemaining > 0) {
        --m_temporalFramesRemaining;
        visualChanged = true;
    }
    m_coverRevision = coverRevision;
    m_current = current;
    m_cover = object["cover"].toString();
    // 图片缓存只在 GUI 线程读取，渲染线程通过 cover() 拿这份副本。
    m_coverImage = host.image(m_cover);
    // 图形设备在后台可销毁；仅保存当前与可见归位卡片的图片，供恢复时重建纹理。
    const auto musicKey = current["key"].toString("empty");
    submitTextureAdmission(musicKey);
    m_musicTextures[musicKey] = {current, m_coverImage};
    QSet<QString> retainedKeys{musicKey};
    for (const auto &key : m_frame.value("returningMusicKeys").toArray()) {
        retainedKeys.insert(key.toString());
    }
    for (const auto &value : m_frame.value("draws").toArray()) {
        const auto key = value.toObject()["musicKey"].toString();
        if (!key.isEmpty()) {
            retainedKeys.insert(key);
        }
    }
    for (auto it = m_musicTextures.begin(); it != m_musicTextures.end();) {
        if (!retainedKeys.contains(it.key())) {
            it = m_musicTextures.erase(it);
        } else {
            ++it;
        }
    }
    // 诊断：把「按曲目保留的 MusicTexture 数与其封面字节」交给渲染线程的内存探针打印。
    {
        auto &counters = RhineRender::engineMemoryCounters();
        qint64 coverBytes = 0;
        for (const auto &entry : m_musicTextures) {
            coverBytes += entry.cover.sizeInBytes();
        }
        counters.musicTextures.store(int(m_musicTextures.size()), std::memory_order_relaxed);
        counters.coverBytes.store(coverBytes, std::memory_order_relaxed);
    }
    // C03：准入状态只在这里写一次。synchronize() 拿到的就是这份快照，不再对每个条目
    // 重新赋值 admitted——那会让整块 QHash 每帧 detach 一遍。
    m_musicTextureSnapshot.clear();
    for (auto it = m_musicTextures.cbegin(); it != m_musicTextures.cend(); ++it) {
        auto entry = it.value();
        entry.admitted = m_admission.isAdmitted(it.key());
        m_musicTextureSnapshot.insert(it.key(), entry);
    }
    auto commands = object["commands"].toArray();
    if (commands != m_commands) {
        m_commands = commands;
        ++m_hudUpdates;
        m_hudRevision.fetch_add(1, std::memory_order_relaxed);
        emit hudUpdated();
    }
    if (visualChanged) {
        ++m_sceneUpdates;
    }
    notifySceneRenderers(visualChanged);
    auto state = object["state"].toObject().toVariantMap();
    if (state != m_state) {
        m_state = state;
        const auto loginMethod = m_state.value("loginMethod").toString();
        if (loginMethod != m_loginMethod) {
            m_loginMethod = loginMethod;
            emit clearCredentials();
        }
        emit stateChanged();
    }
    auto hits = object["hits"].toArray().toVariantList();
    if (hits != m_hits) {
        m_hits = hits;
        emit hitsChanged();
    }
    if (scene.isProfiling()) {
        scene.timings.engineMs = frameTimer.nsecsElapsed() / 1000000.;
    }
    emit updated();
#ifdef Q_OS_LINUX
    if (stepProbe) {
        const double wall = double(clock.nsecsElapsed() - stepWall0) / 1e6;
        const double cpu = threadCpuMs() - stepT0;
        stepWallSum += wall;
        stepCpuSum += cpu;
        stepAppSum += stepAppMs;
        stepRestSum += wall - stepAppMs;
        if (++stepProbeFrames >= 60) {
            const double n = stepProbeFrames;
            qInfo().noquote()
                << QStringLiteral("拍成本: 合计 %1 ms = app->step %2 + 其余 %3 | 线程CPU %4 ms | 等待 %5 ms")
                       .arg(stepWallSum / n, 0, 'f', 2)
                       .arg(stepAppSum / n, 0, 'f', 2)
                       .arg(stepRestSum / n, 0, 'f', 2)
                       .arg(stepCpuSum / n, 0, 'f', 2)
                       .arg((stepWallSum - stepCpuSum) / n, 0, 'f', 2);
            stepWallSum = stepCpuSum = stepAppSum = stepRestSum = 0;
            stepProbeFrames = 0;
        }
    }
#endif
}
void Engine::snapshot(QString path) {
    if (m_frame.isEmpty()) {
        return;
    }
    QDir().mkpath(path);
    const QSize size(1920, 1080);
#ifdef Q_OS_DARWIN
    const auto settings = renderConfiguration.snapshot();
    auto metal =
        renderReference(root(), m_frame, m_current, cover(), size, scene.drawBuffers, nullptr, &settings);
#else
    auto metal = renderReference(root(), m_frame, m_current, cover(), size, scene.drawBuffers);
#endif
    saveImageNative(metal, path + "/qt-metal.png");
    QImage hud(size, QImage::Format_RGBA8888_Premultiplied);
    hud.fill(Qt::transparent);
    QPainter hudPainter(&hud);
    m_glyphs.commands(hudPainter, m_commands, [this](QString key) { return host.image(key); });
    hudPainter.end();
    saveImageNative(hud, path + "/qt-panel.png");
    QPainter painter(&metal);
    painter.drawImage(0, 0, hud);
    painter.end();
    metal.save(path + "/qt-composite.png");
    QFile file(path + "/qt-state.json");
    if (file.open(QIODevice::WriteOnly)) {
        file.write(QJsonDocument(m_frame).toJson());
    }
}
/** 独立包离线验收直接检查原生状态、原始模型与实际 QRhi 输出，不创建脚本引擎。 */
int Engine::selfTest() {
    bool ok =
        ready() && DiscGeometry::validate() && runNativeHostChecks(root()) && runNativeMusicChecks(root());
    // 首帧尚未生成时，渲染通知不能通过非 const JSON 读取插入空字段。
    const auto savedFrame = m_frame;
    m_frame = {};
    notifySceneRenderers(true);
    ok &= m_frame.isEmpty();
    m_frame = savedFrame;
    notifySceneRenderers(true);
    scene.review("archive");
    step(2.101);
    ok &= !m_frame.value("draws").toArray().isEmpty() &&
          m_frame.value("stats").toObject()["archiveCount"].toInt() > 0;
    QFile fixture(root() + "/scene-fixture.json");
    if (!fixture.open(QIODevice::ReadOnly)) {
        qCritical() << "Missing offline scene fixture";
        return 1;
    }
    const auto expected = QJsonDocument::fromJson(fixture.readAll()).object();
    const auto legacy = expected["frame"].toObject();
    ok &= equivalent(m_frame.value("view"), legacy["view"]) &&
          equivalent(m_frame.value("projection"), legacy["projection"]);
    for (const auto &entry : expected["rays"].toArray()) {
        const auto ray = entry.toObject();
        const auto hit = scene.pick(ray["x"].toDouble(), ray["y"].toDouble());
        const auto cell = ray["hit"].toObject();
        if (cell.isEmpty()) {
            ok &= !hit;
        } else {
            ok &= hit && hit->lane == cell["lane"].toInt() && hit->row == cell["row"].toInt();
        }
    }
    qInfo() << "Qt native scene, Host, music, playback and offline package checks:"
            << (ok ? "passed" : "FAILED");
    return ok ? 0 : 1;
}

void Engine::importLocal(QList<QUrl> urls) {
    QStringList paths;
    for (const auto &url : urls) {
        if (url.isLocalFile()) {
            paths.append(url.toLocalFile());
        }
    }
    app->music.importLocal(paths);
    wake();
}
