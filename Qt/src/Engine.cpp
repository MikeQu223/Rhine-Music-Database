#include <QtGlobal>
#if defined(Q_OS_LINUX) || defined(Q_OS_DARWIN)
#include <ctime>
#endif
#include "Engine.h"
#include "PlatformFeatures.h"
#include "DiscGeometry.h"
// prefetchCover(): 内嵌模式的选中封面投影（RhineEmbedded::projectedCover）。
#include "EmbeddedSceneHost.h"
#include "RhiScene.h"
#include "fg/FgCapability.h"
#include "fg/FgStats.h"
#include "render/MemoryProbe.h"
#include "render/RenderModePolicy.h"
#if defined(Q_OS_ANDROID)
#include "render/HudDirtyRect.h"
#include "render/HudLayers.h"
#endif
#include <QCoreApplication>
#include <QDir>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QEvent>
#include <QEventLoop>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QMimeData>
#include <QPainter>
#include <QQuickWindow>
#include <QScreen>
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
Engine::Engine(QString path, bool offline, QObject *parent, PlaybackConnection *connection,
               RenderCacheStorage *renderCache)
    : QObject(parent), host(path, offline, nullptr, false, connection), scene(path), m_glyphs(path) {
    // FSR3 抖动默认关闭；环境变量在进程启动时读取一次，运行期不再变化。
    m_jitterEnabled = qEnvironmentVariableIntValue("RHINE_JITTER") == 1;
    const auto content = QJsonDocument::fromJson(host.read("slots.json").toUtf8()).object();
    app = std::make_unique<NativeApplication>(&host, &m_glyphs, &scene, content);
    if (renderCache) {
        app->music.registerRenderCache(*renderCache);
    }
    connect(&app->shortcuts, &GlobalShortcuts::activated, this, [this](const QString &action) {
        if (action != "window" || !m_window) {
            return;
        }
        if (m_window->isVisible() && m_window->isActive()) {
            m_window->hide();
        } else {
            m_window->setWindowStates(m_window->windowStates() & ~Qt::WindowMinimized);
            m_window->show();
            m_window->raise();
            m_window->requestActivate();
        }
    });
    connect(&app->music, &MusicLibrary::playbackInvalidated, this, &Engine::refreshPlayback);
    connect(&app->hud, &NativeHud::localImportRequested, this, &Engine::localImportRequested);
    connect(&app->hud, &NativeHud::pluginImportRequested, this, &Engine::pluginImportRequested);
    connect(&app->hud, &NativeHud::pluginPackageRequested, this, &Engine::pluginPackageRequested);
    connect(&host, &Host::pluginInstallFinished, this, [this] {
        QTimer::singleShot(0, this, &Engine::startNextPluginImport);
    });
    connect(&app->hud, &NativeHud::mvRequested, this, &Engine::mvRequested);
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
            if (compactLayout()) {
                // 静止时不再靠额外更新推进准入，直接同步保留曲目的状态。
                for (auto it = m_musicTextureSnapshot.begin(); it != m_musicTextureSnapshot.end(); ++it) {
                    it->admitted = m_admission.isAdmitted(it.key());
                }
            }
            requestSceneContent();
        }
    });
    timer.setTimerType(Qt::PreciseTimer);
    connect(&timer, &QTimer::timeout, this, &Engine::tick);
    mediaTimer.setInterval(1000);
    connect(&mediaTimer, &QTimer::timeout, this, &Engine::pollMedia);
#ifdef Q_OS_IOS
    // 恢复前台时先同步媒体状态，画面休眠期间也可能已经起播或换曲。
    connect(qGuiApp, &QGuiApplication::applicationStateChanged, this, [this](Qt::ApplicationState state) {
        if (state == Qt::ApplicationActive && QGuiApplication::applicationState() == Qt::ApplicationActive) {
            pollMedia();
        }
    }, Qt::QueuedConnection);
    QTimer::singleShot(0, this, &Engine::pollMedia);
#endif
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
                  // 格式串有 36 个转换符，实参也必须 36 个：这里少给过 tick/s 一项，
                  // 导致从第 2 项起整串错位（req/s 打印成被当 %llu 读的 double，
                  // gpu=%.2f 收到的是 const char*），读数全部作废。
                  qulonglong(m_paceTicks), qulonglong(m_steps) - lastSteps,
                  qulonglong(m_pacing.skipped()) - lastSkipped, qulonglong(m_sceneUpdates) - lastScene,
                  qulonglong(m_hudUpdates) - lastHud, qulonglong(render) - lastRender,
                  qulonglong(m_changedSteps) - lastChanged, qulonglong(m_wakes) - lastWakes,
                  qulonglong(m_wakesInput), qulonglong(m_wakesHost), qulonglong(m_wakesMedia),
                  qulonglong(m_wakesOther), qulonglong(m_sceneRequests) - lastRequests, gpuMicros / 1000.0,
                  RhineRender::gpuTimingStatusName(
                      RhineRender::GpuTimingStatus(m_gpuTiming.load(std::memory_order_relaxed))),
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
                  qulonglong(m_stableResetScene) - lastResetScene, avgGap, double(m_paceGapMax) / 1e6,
                  avgStep, double(m_paceStepMax) / 1e6);
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
// 连续像素累积多少舞台像素算一步（一行 / 一首歌）。Android 的手指滑动很容易误触切歌，
// 把「翻一首歌」需要的距离放大 5 倍：15 → 75。用编译期分支隔离，其它平台仍是原来的 15；
// 只影响 wheel() 的步进，m_wheelDistance 那条连续滚动通路不受影响。
#if defined(Q_OS_ANDROID)
constexpr double WHEEL_STEP_PIXELS = 75.;
#else
constexpr double WHEEL_STEP_PIXELS = 15.;
#endif
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
#if !RHINE_MOBILE
    if (event->type() == QEvent::DragEnter || event->type() == QEvent::DragMove ||
        event->type() == QEvent::Drop) {
        auto *drop = static_cast<QDropEvent *>(event);
        const auto urls = drop->mimeData()->urls();
        const auto isPackage = [](const QUrl &url) {
            return url.isLocalFile() && url.fileName().endsWith(".rhineplugin", Qt::CaseInsensitive);
        };
        if (drop->possibleActions().testFlag(Qt::CopyAction) &&
            std::any_of(urls.begin(), urls.end(), isPackage)) {
            drop->setDropAction(Qt::CopyAction);
            drop->accept();
            if (event->type() == QEvent::Drop) {
                for (const auto &url : urls) {
                    if (isPackage(url)) {
                        importPluginPackage(url);
                    }
                }
            }
            return true;
        }
    }
#endif
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
        wake();
        break;
    case QEvent::TouchEnd:
        if (compactLayout()) {
            m_pressed = false;
        }
        wake();
        break;
    case QEvent::TouchCancel:
        if (compactLayout()) {
            m_pressed = false;
            wake();
        }
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
    QVariantMap result = {
        {"idle", m_sleeping},
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
    // 缺省只表示"这次没测到"。两者语义不同，不能让前者被后者吞掉。
    result.insert("gpuTimingStatus",
                  QString::fromLatin1(RhineRender::gpuTimingStatusName(
                      RhineRender::GpuTimingStatus(m_gpuTiming.load(std::memory_order_relaxed)))));

    // 整帧资源账本
    // 下面这些键和上面的"当前快照"不是同一口径，命名与 CSV 列都带 ledger/peak 前缀，
    // 避免分析脚本把"窗口峰值"当成"本帧值"。峰值窗口 = 最近 kLedgerWindow 个渲染帧。
    const quint64 renderFrames = m_renderFrames.load(std::memory_order_relaxed);
    const quint64 coverUploads = m_coverUploads.load(std::memory_order_relaxed);
    result.insert("gpuResourcesPeak", qulonglong(m_resourcesPeak.load(std::memory_order_relaxed)));
    result.insert("gpuResourcesPeakFrame", qulonglong(m_resourcesPeakFrame.load(std::memory_order_relaxed)));
    result.insert("gpuTextureBytesPeak", qulonglong(m_textureBytesPeak.load(std::memory_order_relaxed)));
    result.insert("gpuTextureBytesPeakFrame",
                  qulonglong(m_textureBytesPeakFrame.load(std::memory_order_relaxed)));
    result.insert("frameBindings", qulonglong(m_frameBindings.load(std::memory_order_relaxed)));
    result.insert("frameCoverUploads", qulonglong(m_frameCoverUploads.load(std::memory_order_relaxed)));
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

/** 渲染线程每帧调用一次，维护滚动窗口峰值、本帧增量与封面上传速率。 */
void Engine::noteFrameLedger(quint64 resources, quint64 bindings, quint64 textureBytes,
                             quint64 coverUploads) {
    // frame 已经是 ++ 之后的值：对外的帧号口径与 renderFrames 一致（1 基）。
    const quint64 frame = m_renderFrames.load(std::memory_order_relaxed);
    m_frameBindings.store(bindings, std::memory_order_relaxed);
    m_frameCoverUploads.store(coverUploads, std::memory_order_relaxed);

    // 封面上传速率用 EMA（alpha=0.05，约 20 帧窗口）：单帧样本抖动大，而"是不是每帧
    // 都在重传"恰恰要看持续水平。不用呈现层那套 0.15，是为了压住偶发的一两次上传。
    m_coverUploadsEma = m_coverUploadsEma <= 0.0 ? double(coverUploads)
                                                 : m_coverUploadsEma * 0.95 + double(coverUploads) * 0.05;
    m_coverUploadsPerFrameMilli.store(quint64(m_coverUploadsEma * 1000.0 + 0.5), std::memory_order_relaxed);

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
        qWarning().noquote() << QStringLiteral("资源预算超限：整帧驻留纹理 %1 MiB 超过上限 %2 MiB"
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
        if (!sceneLayerVisible()) {
            m_hiddenSceneDirty = true;
            return;
        }
        // 版本只在真的推进内容时自增。呈现层拿它当"这一帧有没有新内容"的唯一判据，
        // 重复推同一个值不会造成重复重渲；而信号是没法这么用的——同一个内容变化会被
        // 场景帧、HUD、异步资源到达各触发一次。
        m_sceneRevision.fetch_add(1, std::memory_order_relaxed);
        if (compactLayout()) {
            // 首次显示与封面就绪也能在 tick() 之外发布快照。
            m_pacing.publish(sceneRevision(), clock.elapsed());
        }
        emit sceneUpdated();
    }
}

/** 渲染线程上报"新资源已就位"。语义与一次真实的视觉变化相同，只是触发者不是帧字段。 */
void Engine::requestSceneContent() {
    if (!sceneLayerVisible()) {
        m_hiddenSceneDirty = true;
        return;
    }
    ++m_sceneRequests;
    notifySceneRenderers(true);
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
    if (compactLayout()) {
        // 消费确认只恢复正在等待的动画，不唤醒已经休眠的竖屏页面。
        if (m_waitingForScene && !m_pacing.awaitingConsumption()) {
            m_waitingForScene = false;
            if (timer.isActive()) {
                timer.start(0);
            }
        }
        return;
    }
    // 渲染线程已经取走上一份，待办动画／输入需要下一拍；不该靠 1ms 轮询自己撞上。
    if (m_started && m_visible && !timer.isActive()) {
        m_lastTick = clock.elapsed();
        timer.start(0);
    }
}
void Engine::wake(bool input) {
    wake(input ? WakeSource::Input : WakeSource::Other);
}
QImage Engine::coverImageOf(const QString &url) const {
    if (url.isEmpty()) {
        return QImage();
    }
    if (QImage direct = host.image(url); !direct.isNull()) {
        return direct;
    }
    const auto resolved = m_coverKeys.constFind(url);
    if (resolved == m_coverKeys.constEnd()) {
        return QImage();
    }
    return host.image(*resolved);
}

void Engine::prefetchCover(const QString &url) {
    // 选中身份切换后旧请求没有意义；已请求过、或缓存里已有像素就不再重复。
    if (url.isEmpty() || !coverImageOf(url).isNull() || m_coverRequests.contains(url)) {
        return;
    }
    m_coverRequests.insert(url);
    qInfo("RHINE_QT_COVER_REQUEST len=%d url=%.96s", int(url.size()), qPrintable(url));
    // Host::image() 只是缓存查找，缓存键是 loadCover 给 URL 补 `param=NyN` 之后的字符串，
    // 所以必须用回调**返回**的键去取图；直接用原始 URL 查必然 miss。
    host.loadCover(
        url,
        [this, url](QString loaded) {
            qInfo("RHINE_QT_COVER_RESULT len=%d key=%.96s", int(loaded.size()), qPrintable(loaded));
            if (loaded.isEmpty()) {
                // 失败要能重试：把这条记录撤掉，下次快照/切歌还会再试（否则一次瞬时失败
                // 就永久压掉这首的封面，和「已请求过」的初衷相反）。
                m_coverRequests.remove(url);
                return;
            }
            if (RhineEmbedded::projectedCover() != url) {
                return; // 期间换了选中：旧的那首不回填
            }
            const QImage pixels = host.image(loaded);
            if (pixels.isNull()) {
                qWarning("RHINE_QT_COVER_DECODE miss key=%.96s", qPrintable(loaded));
                m_coverRequests.remove(url);
                return;
            }
            qInfo("RHINE_QT_COVER_READY %dx%d", pixels.width(), pixels.height());
            // 记住解析后的缓存键，之后每帧都靠它取像素（有界：见下面的淘汰）。
            m_coverKeys.insert(url, loaded);
            while (m_coverKeys.size() > 96) {
                m_coverKeys.erase(m_coverKeys.begin());
            }
            m_coverImage = pixels;
            m_coverRefresh = true;
            // 醒来一帧：m_coverRefresh 只在 step() 里被消费，而 step() 可能正被 pacing Skip
            // 挡着。这条路径和页面过渡期用的是同一个放行窗口。
            m_sceneSleeping = false;
            m_hudTransitionUntilMs = clock.elapsed() + 600;
            timer.start(0);
        },
        1024);
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
        // 竖屏详情的输入只操作 HUD，不能反复重置镜头收束计数。
        if (!compactLayout() || scene.mode() != "detail" || scene.viewerOpen()) {
            m_sceneSleeping = false;
            if (m_stableFrames != 0) {
                ++m_stableResetInput;
            }
            m_stableFrames = 0;
        }
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
    if (m_waitingForScene && timer.isActive()) {
        m_waitingForScene = false;
        timer.start(0);
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
#ifdef Q_OS_DARWIN
void Engine::publishFrameGenerationCapability(bool available, const QString &reason) {
    // Apple 不再接管呈现层，但默认窗口内的补帧能力对设置页而言等价于“已接管”。
    RhineFg::publishCapability(true, true, available, reason);
    if (qEnvironmentVariableIsSet("RHINE_METAL_FG_DIAG")) {
        qInfo().noquote() << "MetalFX FG capability:" << (available ? "可用" : "不可用") << reason;
    }
    emit stateChanged();
}
void Engine::publishFrameGenerationStats(quint64 presented, quint64 interpolated, quint64 rendered,
                                         bool available, bool wanted, bool active, bool depthReady,
                                         bool motionReady, QSize renderSize, QSize displaySize) {
    auto stats = RhineFg::stats();
    const bool running = active && sceneLayer() == SceneLayer::Live;
    stats.layerActive = running;
    stats.defaultWindow = true;
    stats.interpolationAvailable = available;
    stats.interpolationWanted = wanted;
    stats.interpolationActive = running;
    stats.depthReady = depthReady;
    stats.motionVectorsReady = motionReady;
    stats.presented = presented;
    stats.interpolated = interpolated;
    stats.rendered = rendered;
    stats.renderSize = renderSize;
    stats.displaySize = displaySize;
    stats.presentMode = QStringLiteral("Qt Quick 默认窗口");
    RhineFg::publish(stats);
}
#endif
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
/**
 *  的主入口：把一份"真的 apply 过的" Flutter 快照投影成原生可见格的业务资源。
 *
 * 三条边界写在这里，别在别处偷偷放宽：
 *   - 只有解析出真实身份（siren:<kind>:<id>）的格才会被投影；没身份的格继续是占位档案壳。
 *   - 同一份签名重复 apply 完全不动状态：不会重置准入计时，也不会把已经热的封面打回冷态。
 *   - 这里只登记"这一格该显示什么"，不取图、不建纹理——取图在 step() 的泵里按准入做。
 */
void Engine::projectEmbeddedCells(const QJsonArray &cells, quint64 contextGeneration, bool scrolling) {
    const auto projection = RhineRender::projectEmbeddedCells(cells, contextGeneration);
    const bool wasScrolling = m_embeddedCellScrolling;
    m_embeddedCellContext = contextGeneration;
    m_embeddedCellScrolling = scrolling;
    if (scrolling) {
        // 与宿主 payload 里的 450ms 判定同源：到期后自己失效，不需要下一份快照。
        m_embeddedCellScrollingUntilMs = clock.elapsed() + 450;
    }
    if (projection.signature == m_embeddedCellSignature) {
        // 同一份窗口内容重复上报（每次 apply 都会来一次）：不动准入，也不重置计时。
        // 但"滚动结束"是一次真实的边界事件：内容没变也要醒一次去结算待定项，否则
        // 拖动中压下的那些格会一直停在占位（引擎这时可能已经休眠，没人来推进准入）。
        if (wasScrolling && !scrolling) {
            m_embeddedCellAdmission.setVisible(m_visible, clock.elapsed());
            m_sceneSleeping = false;
            m_inputPending = true;
            if (m_started && m_visible && !timer.isActive()) {
                timer.start(0);
            }
        }
        return;
    }
    m_embeddedCellSignature = projection.signature;
    m_embeddedCells = projection.cells;
    m_embeddedCellByKey.clear();
    QHash<quint32, QString> sceneKeys;
    sceneKeys.reserve(m_embeddedCells.size());
    for (const auto &cell : m_embeddedCells) {
        m_embeddedCellByKey.insert(cell.key, cell);
        sceneKeys.insert(RhineRender::embeddedCellId(cell.lane, cell.row), cell.key);
        // 已经在这个 key 上的条目跟着新元数据走：标题/歌手变了，标签要按新 revision 重画。
        auto entry = m_musicTextures.find(cell.key);
        if (entry != m_musicTextures.end()) {
            const auto item = embeddedCellItem(cell);
            if (entry->item != item) {
                // 封面地址变了必须把旧像素丢掉：条目上的图是按上一个地址取的，留着它
                // 等于把旧封面贴到新元数据上（泵看到 cover 非空就不会再请求了）。
                if (entry->item.value("cover").toString() != cell.cover) {
                    entry->cover = QImage();
                }
                entry->item = item;
                m_coverRefresh = true;
            }
        }
    }
    // 身份表整块替换：掉队的格回到占位壳，绝不让旧图留在新格上。
    scene.projectEmbeddedCellKeys(sceneKeys);
    m_embeddedCellAdmission.setVisible(m_visible, clock.elapsed());
    m_sceneSleeping = false;
    m_inputPending = true;
    // 与其它唤醒点同一套守卫：页面不可见时不许把整台引擎从后台叫起来（那会在后台
    // 持续步进 + 出图）。可见性由 Engine::setVisible 负责，这里只跟着走。
    if (m_started && m_visible && !timer.isActive()) {
        timer.start(0);
    }
}

const RhineRender::EmbeddedCell *Engine::embeddedCellFor(const QString &key) const {
    const auto it = m_embeddedCellByKey.constFind(key);
    return it == m_embeddedCellByKey.constEnd() ? nullptr : &it.value();
}

QJsonObject Engine::embeddedCellItem(const RhineRender::EmbeddedCell &cell) const {
    // 只放这一格真的有的字段：缺歌手就留空，由标签生成器显示"暂无歌手"，
    // 绝不从当前曲目借文字（B02 的规矩同样适用于可见格）。
    QJsonObject item{{"key", cell.key}, {"kind", cell.kind}, {"id", cell.id}, {"title", cell.title}};
    if (!cell.artist.isEmpty()) {
        item["artist"] = cell.artist;
    }
    if (!cell.album.isEmpty()) {
        item["album"] = cell.album;
    }
    if (!cell.cover.isEmpty()) {
        item["cover"] = cell.cover;
    }
    return item;
}

/**
 * 每帧一次的准入上报与封面泵。
 *
 * 顺序是刻意：先上报（滚动中一个都不准入），再取图。取图只针对"这一帧真的被画出来"
 * 的格（retained），这样滚动时不会有为屏外格白下载的请求，资源量天然跟着可见窗口走。
 */
void Engine::pumpEmbeddedCells(const QSet<QString> &retained, bool scrolling) {
    QStringList visible;
    visible.reserve(m_embeddedCells.size());
    for (const auto &cell : m_embeddedCells) {
        // 只上报这一帧真的画出来的格：把整份 40 格投影都当"可见"，屏外格会占住准入名额
        // 变成 starved，唤醒逻辑也会永远有活干（归档页就再也不会休眠）。
        if (!retained.contains(cell.key)) {
            continue;
        }
        visible.append(cell.key);
    }
    // 宿主的 scrolling 与原生拖动/惯性取并集。宿主侧带衰减（列表停下后没有快照回来），
    // 单独靠它会让准入窗口永远处于滚动中。
    const bool hostScrolling = scrolling && clock.elapsed() < m_embeddedCellScrollingUntilMs;
    const bool moving = hostScrolling || scene.archiveScrolling();
    const auto report =
        m_embeddedCellAdmission.report(visible, m_embeddedCellContext, moving, clock.elapsed());
    m_embeddedCellAdmitted = report.admitted;
    m_embeddedCellPending = report.pending;
    m_embeddedCellStarved = report.starved;
    if (moving || !m_visible) {
        return;
    }
    for (const auto &key : m_embeddedCellAdmission.admittedKeys()) {
        const auto cell = embeddedCellFor(key);
        if (cell == nullptr) {
            continue;
        }
        auto entry = m_musicTextures.find(key);
        if (entry == m_musicTextures.end()) {
            if (!retained.contains(key)) {
                // 这一帧没画它：不给屏外格占资源，等它真的进画面再建。
                continue;
            }
            entry = m_musicTextures.insert(key, {embeddedCellItem(*cell), {}});
        }
        if (!entry->cover.isNull() || cell->cover.isEmpty()) {
            continue;
        }
        // 热复用：同一个 URL 的另一格已经把图取回来了，直接共享像素，标签仍按 key 隔离。
        if (const auto image = coverImageOf(cell->cover); !image.isNull()) {
            entry->cover = image;
            m_coverRefresh = true;
            continue;
        }
        if (m_coverRequests.contains(cell->cover)) {
            continue;
        }
        if (m_embeddedCoverAttempts.value(cell->cover) >= RhineRender::EmbeddedCellCoverAttempts) {
            continue;
        }
        m_embeddedCoverAttempts.insert(cell->cover, m_embeddedCoverAttempts.value(cell->cover) + 1);
        while (m_embeddedCoverAttempts.size() > 256) {
            m_embeddedCoverAttempts.erase(m_embeddedCoverAttempts.begin());
        }
        const auto requested = cell->cover;
        const auto requestedKey = key;
        m_coverRequests.insert(requested);
        host.loadCover(
            requested,
            [this, requested, requestedKey](QString loaded) {
                m_coverRequests.remove(requested);
                if (loaded.isEmpty()) {
                    return; // 失败已记账：有限次之后停手，不刷屏
                }
                // 迟到结果的唯一判据：这一格还在投影里，且它现在要的仍是这个地址。
                // A→B→A 时中间那次 B 的结果会被这一条丢掉。
                if (!RhineRender::embeddedCellCoverStillWanted(embeddedCellFor(requestedKey),
                                                              requested)) {
                    return;
                }
                const auto image = host.image(loaded);
                if (image.isNull()) {
                    return;
                }
                // 记下 URL -> host.loadCover 真正返回的 cache key：同 URL 的其它格之后走
                // coverImageOf() 热复用，既不重复下载，也不会把同一张图算成多次尝试。
                m_coverKeys.insert(requested, loaded);
                while (m_coverKeys.size() > 96) {
                    m_coverKeys.erase(m_coverKeys.begin());
                }
                // 成功一次就把该 URL 的尝试额度还回去：额度只该记失败，不该记命中。
                m_embeddedCoverAttempts.remove(requested);
                auto entry = m_musicTextures.find(requestedKey);
                if (entry != m_musicTextures.end() && entry->cover.isNull()) {
                    entry->cover = image;
                    m_coverRefresh = true;
                    m_sceneSleeping = false;
                    m_hudTransitionUntilMs = clock.elapsed() + 600;
                    if (m_started && m_visible && !timer.isActive()) {
                        timer.start(0);
                    }
                }
            },
            512);
    }
}

/**
 * 诊断：本帧真的画出来的格的真实/占位拆分。
 *
 * 只数这一帧进过画面的格；整份投影的数量单独报 projected。labels 故意留空。
 */
void Engine::publishEmbeddedCells(const QSet<QString> &retained) {
    QStringList order;
    order.reserve(m_embeddedCells.size());
    QSet<QString> coverKeys;
    for (const auto &cell : m_embeddedCells) {
        if (!retained.contains(cell.key)) {
            continue;
        }
        order.append(cell.key);
        const auto entry = m_musicTextures.constFind(cell.key);
        if (entry != m_musicTextures.constEnd() && !entry->cover.isNull()) {
            coverKeys.insert(cell.key);
        }
    }
    QSet<QString> admitted;
    for (const auto &key : m_embeddedCellAdmission.admittedKeys()) {
        admitted.insert(key);
    }
    const auto binding = RhineRender::embeddedCellBinding(order, admitted, coverKeys, {});
    m_frame["embeddedCells"] = QJsonObject{{"visible", binding.visible},
                                           {"projected", int(m_embeddedCells.size())},
                                           {"admitted", binding.admitted},
                                           {"covers", binding.covers},
                                           {"placeholders", binding.placeholders},
                                           {"pending", m_embeddedCellPending},
                                           {"starved", m_embeddedCellStarved},
                                           {"context", double(m_embeddedCellContext)},
                                           {"scrolling", m_embeddedCellScrolling}};
}

void Engine::setVisible(bool value) {
#ifdef Q_OS_IOS
    value = value && QGuiApplication::applicationState() == Qt::ApplicationActive;
#endif
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
        m_waitingForScene = false;
        m_sleeping = true;
        // 隐藏期间不创建 GPU 资源：作废"等到一半"的等待，恢复后重新计时。
        m_admission.setVisible(false, clock.elapsed());
        m_admissionScheduler.stop();
        // 可见格也一样：待定项作废，但已准入的 key 保留（回来时还是热的）。
        m_embeddedCellAdmission.setVisible(false, clock.elapsed());
    } else {
        m_admission.setVisible(true, clock.elapsed());
        m_embeddedCellAdmission.setVisible(true, clock.elapsed());
        host.restoreMemoryBudget();
#ifdef Q_OS_DARWIN
        if (renderConfiguration.snapshot().temporal()) {
            resetTemporalState();
        }
#endif
        wake(false);
        notifySceneRenderers(sceneLayerVisible());
        m_hudRevision.fetch_add(1, std::memory_order_relaxed);
        // 重新显示时纹理可能已经被丢弃，命令流没有差异也必须整块重画。
        m_hudStaticChanged = true;
        m_hudDynamicChanged = true;
        m_hudDirtyFull = true;
        m_hudStaticDirtyFull = true;
        publishHudFrame();
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
    // Host 把封面像素丢了，引擎这边记录的"已请求过"也必须一起忘掉，
    // 否则回到前台后这些唱片再也不会去补图。
    m_coverRequests.clear();
    scene.trimMemory();
    m_glyphs.clearBlurCache();
#ifdef Q_OS_DARWIN
    m_glyphs.clearRasterCache();
#endif
}
/** 播放栏按需重绘时保持资源库休眠；只有可见的旋转或歌词动画需要连续调度。 */
void Engine::refreshPlayback() {
    if (!m_visible) {
        return;
    }
    if (!m_sleeping || (!compactScenePaused() && (!m_sceneSleeping || scene.changed()))) {
        wake(false);
        return;
    }
    step(m_animationTime);
    if (m_discRotating || app->hud.animating(m_animationTime)) {
        wake(false);
    }
}

bool Engine::compactLayout() const {
    // 与 ResponsiveHudLayout 的 1080 舞台宽阈值一致。
    return m_width > 0 && m_height > 0 && m_width < m_height;
}
bool Engine::compactSceneObscured() const {
    if (scene.mode() == "boot" || scene.viewerOpen()) {
        return false;
    }
    const auto &hud = app->hud;
    return !hud.modal.isEmpty() || hud.lyricsMode || hud.commentsMode ||
           (scene.mode() == "detail" && app->music.current.value("kind") != "song");
}
/** 隐藏与已停稳页面继续推进 HUD，场景只在路由、选中曲目或可见视口变化时恢复。 */
bool Engine::compactScenePaused() const {
    const auto layer = sceneLayer();
    if (!compactLayout() || layer == SceneLayer::Live || scene.viewerOpen() ||
        scene.mode() != m_frame.value("mode") || scene.selection() != m_frame.value("selected").toInt()) {
        return false;
    }
    return canReuseFrozenScene() || (layer == SceneLayer::Hidden && compactSceneObscured());
}
bool Engine::canReuseFrozenScene() const {
    return m_hasFrozenScene && scene.mode() == "detail" && !scene.viewerOpen() &&
           scene.selection() == m_frame.value("selected").toInt() && !m_sceneViewportDirty &&
           scene.themeSettled() && app->hud.dark == m_sceneDark &&
           app->music.current.value("key") == m_current.value("key");
}
void Engine::setSceneLayer(SceneLayer layer) {
    const auto previous = m_sceneLayer.exchange(layer, std::memory_order_relaxed);
    if (previous == layer) {
        return;
    }
    if (layer == SceneLayer::Live) {
        // 隐藏层可能没有收到渲染回调；恢复后的首帧仍必须丢弃旧补帧历史。
        m_frame["temporalReset"] = true;
    }
#ifdef Q_OS_MACOS
    if (layer != SceneLayer::Live) {
        auto stats = RhineFg::stats();
        if (stats.defaultWindow) {
            stats.layerActive = false;
            stats.interpolationActive = false;
            RhineFg::publish(stats);
        }
    }
#endif
    if ((previous == SceneLayer::Hidden) != (layer == SceneLayer::Hidden)) {
        emit sceneLayerVisibilityChanged();
    }
}

void Engine::pollMedia() {
    // 后台排障心跳：mediaTimer 由事件循环驱动，这条日志能证明（或证伪）后台事件循环
    // 是否仍在运转——「后台不切歌、控件失灵」的定位全靠它划界。
    if (QGuiApplication::applicationState() != Qt::ApplicationActive) {
        static qint64 lastHeartbeat = -100000;
        if (clock.elapsed() - lastHeartbeat >= 10000) {
            lastHeartbeat = clock.elapsed();
            qInfo("background media poll alive");
        }
    }
    app->poll(clock.elapsed() / 1000.0, true);
    const auto &player = app->music.player;
    const bool waitingOrPlaying = player.state["requested"].toBool() || player.state["playing"].toBool() ||
                                  player.state["buffering"].toBool();
    const bool active = player.loading || (waitingOrPlaying && player.state["error"].toString().isEmpty());
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
void Engine::updateDetailGrace(qint64 nowMs) {
    const bool inDetail = m_frame.value("mode").toString() == "detail";
    if (inDetail && m_detailEnterWallMs < 0) {
        m_detailEnterWallMs = nowMs;
    } else if (!inDetail) {
        m_detailEnterWallMs = -1;
    }
    // 覆盖完整淡入 + 余量；墙钟不受休眠/pacing 影响，稳态零开销。
    m_detailGrace = m_detailEnterWallMs >= 0 && nowMs - m_detailEnterWallMs < 1200;
}
void Engine::publishHudFrame() {
#if defined(Q_OS_ANDROID)
    // 标脏与「允许连轴转」必须互斥。HUD 命令流变了但渲染线程还没画进纹理时，
    // tick() 的 0/1ms QTimer 会一直抢在 Qt Quick 的 render sync 之前重新投递，
    // GUI 事件循环里那个 update request 永远排不上队。置位后 tick() 让出时间，
    // 直到 Hud::updatePaintNode() 真正跑过再清位。
    m_hudFramePending.store(true, std::memory_order_relaxed);
    m_hudFramePendingSinceMs = clock.elapsed();
    // HUDFLOW 诊断（第六轮，默认开、限流）：命令流发布的节律与宽限状态。
    static int publishCount = 0;
    if (++publishCount % 120 == 1) {
        qWarning("HUDFLOW 发布 #%d: grace=%d 过渡窗口=%d", publishCount, int(m_detailGrace),
                 int(clock.elapsed() < m_hudTransitionUntilMs));
    }
#endif
    emit hudUpdated();
}
void Engine::tick() {
    const qint64 enterNs = clock.nsecsElapsed();
    if (m_paceEnterNs != 0) {
        const qint64 gap = enterNs - m_paceEnterNs;
        m_paceGapSum += gap;
        m_paceGapMax = qMax(m_paceGapMax, gap);
    }
    m_paceEnterNs = enterNs;
    const auto now = clock.elapsed();
    // 详情淡入宽限期：用真实墙钟（clock.elapsed）判定，必须在 tick() 层。
    // 死锁成因：scene.changed() 只在 sample() 末尾更新，sample() 只在 reuse==false 时
    // 被调用，reuse 却又依赖 scene.changed()；一旦引擎休眠就再也出不来。而 m_detail
    // 挂在 m_animationTime 这个「每帧最多 +50ms、休眠即停」的伪时钟上，于是
    // frame["detail"] 永远停在淡入中间值，HUD 的 alpha() 就一直是半透明。
    // 前三轮把判据写在 step() 里全部无效——step() 被 pacing Skip / 休眠跳过时，
    // m_hudTransitionUntilMs 连初始值都不会被设置，所有保护都不触发。
    // 判据放在 tick() 层，并在 step() 更新 m_frame 后再重算一次（见 updateDetailGrace）。
    updateDetailGrace(now);
    // C04：完整 step 只在"这一份快照还有机会被看到"时跑。渲染线程还没取走上一份，
    // 现在算出来的中间状态会被直接覆盖——这部分 CPU 在任何一帧上都看不到。
    const bool compact = compactLayout();
    m_waitingForScene = false;
    qint64 displayPeriodNs = 0;
    if (compact) {
        const auto screen = m_window ? m_window->screen() : QGuiApplication::primaryScreen();
        const double refreshRate = screen ? screen->refreshRate() : 60.0;
        const bool validRefreshRate = std::isfinite(refreshRate) && refreshRate >= 1.0;
        displayPeriodNs = qint64(1e9 / (validRefreshRate ? refreshRate : 60.0));
    }
    const quint64 previousSceneRevision = sceneRevision();
    const bool inputPending = m_inputPending || m_wheelPending || m_pointerPending || (!compact && m_pressed);
    // 页面过渡期视为「有工作」：否则 pacing 会因为上一份快照还没被消费而 Skip 掉整帧，
    // 引擎也可能直接休眠，HUD 的命令流就停在这一帧（开唱片旋转能绕过正是这个道理）。
    // hudFramePending 必须一并算进来：过渡窗口结束后若 HUD 还没被场景图画过，
    // 这里一放行就会把最后一次纹理上传也吃掉。
#if defined(Q_OS_ANDROID)
    const bool hudNeedsPresent = hudFramePending();
#else
    const bool hudNeedsPresent = false;
#endif
    const bool scenePaused = compactScenePaused();
    const bool sceneTransition = !scenePaused && (now < m_hudTransitionUntilMs || m_detailGrace);
    const bool hudTransition = sceneTransition || hudNeedsPresent;
    const bool sceneWork = !scenePaused &&
                           (scene.changed() || !m_sceneSleeping || m_frame.value("pendingAnimations").toBool());
    const bool workPending = inputPending || m_pressed || sceneWork || m_discRotating ||
                             app->hud.animating(m_animationTime) || hudTransition ||
                             m_temporalFramesRemaining > 0 ||
                             // 可见格还在等准入：这不是"动画"，但必须有一帧去把它接下来。
                             // 被名额卡住的那部分（starved）等的是窗口变化，不算这件事。
                             (host.renderOnly && m_embeddedCellPending > m_embeddedCellStarved) ||
                             m_frame.value("mode") == "boot";
    if (!inputPending && !hudTransition && !scenePaused) {
        const auto decision = m_pacing.decide(workPending, false, now);
        if (decision.action == RhineRender::FramePacingPolicy::Action::Skip) {
            m_pacing.noteStep(true);
            ++m_stepsSkipped;
            ++m_paceTicks;
            if (compact) {
                const int overrideMs = frameIntervalMs();
                m_waitingForScene = overrideMs <= 0;
                timer.setInterval(overrideMs > 0 ? overrideMs : int(qMax<qint64>(1, displayPeriodNs / 1000000)));
            } else {
                timer.setInterval(1);
            }
            return;
        }
    }
#ifdef Q_OS_MACOS
    // 毫秒时钟尚未前进时不重算同一动画状态；输入与时域收敛帧仍立即处理。
    if (!inputPending && now == m_lastTick && !scene.changed() && m_temporalFramesRemaining == 0) {
        m_pacing.noteStep(true);
        ++m_stepsSkipped;
        ++m_paceTicks;
        timer.setInterval(1);
        return;
    }
#endif
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
    // 横屏在 step 后登记内容版本；竖屏的异步资源也可独立发布。
    if (!compact) {
        m_pacing.publish(sceneRevision(), clock.elapsed());
    }
    m_pacing.noteStep(false);
    m_inputPending = false;
    // 动态帧间隔：不设固定周期常数，帧率上限完全交给呈现侧（垂直同步/缓冲回收）。
#if defined(Q_OS_LINUX) || defined(Q_OS_DARWIN)
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
    if (compact && (hudTransition || sceneRevision() == previousSceneRevision)) {
        // HUD 动画没有场景消费回调。按显示周期扣除本次工作耗时，避免无变化时连轴转。
        const qint64 remainingNs = displayPeriodNs - (clock.nsecsElapsed() - enterNs);
        intervalMs = int(qMax<qint64>(1, remainingNs / 1000000));
    }
    if (rotationOnly) {
        intervalMs = 33;
    }
#if defined(Q_OS_ANDROID)
    // 命令流已发布但渲染线程还没消费时不能连轴转：0/1ms 定时器会抢在 update request 之前，
    // render sync 永远排不上队，纹理停在上一页。
    // 这里让出 4ms（一帧预算）给事件循环，稳态恢复 0/1ms；2 秒兜底防止窗口不可见时永不让步。
    if (m_hudFramePending.load(std::memory_order_relaxed)) {
        if (now - m_hudFramePendingSinceMs > 2000) {
            m_hudFramePending.store(false, std::memory_order_relaxed);
        } else {
            intervalMs = qMax(intervalMs, 4);
        }
    }
#endif
    // 可见格准入只差时间：按时到期醒一次就够，不必为了等它连续烧帧。
    if (m_embeddedCellPending > m_embeddedCellStarved) {
        const int remaining = m_embeddedCellAdmission.nextAdmissionInMs(clock.elapsed());
        intervalMs = qMax(intervalMs, qMax(16, remaining < 0 ? 0 : remaining));
    }
    timer.setInterval(fixedMs > 0 ? fixedMs : intervalMs);
    // 排障专用：RHINE_DIAG_ANIMATE=1 时永不休眠。静止场景下引擎会主动休眠、
    // presented 不再增长，那时测出来的"帧率"是没有负载的数字，A/B 对比没有意义。
    static const bool forceAnimate = qEnvironmentVariableIsSet("RHINE_DIAG_ANIMATE");
#if defined(Q_OS_ANDROID)
    // 不能用 tick 开头的 hudTransition 快照：step() 里可能刚 publish 了一份新的 HUD
    // 命令流，那一刻过渡窗口已过但纹理还没画。停掉 timer 会把这次呈现一起吞掉。
    const bool hudStillPending = hudFramePending();
#else
    const bool hudStillPending = false;
#endif
    const bool nowPaused = compactScenePaused();
    const bool canStopTimer = compact || (now - m_lastInput >= 750 && !m_pacing.awaitingConsumption());
    // 用实时成员而非 tick 开头的局部快照：step() 里可能刚把 m_detailGrace 置真。
    const bool settled = nowPaused || (m_sceneSleeping && !scene.changed() && !m_detailGrace);
    // 有待定的可见格：睡着就没人再推进准入，封面会永远停在占位。
    // starved 的格等的是"窗口变化"而不是时间：拿它当唤醒理由会让静止的归档页永远醒着。
    const bool embeddedCellsNeedAdmission =
        host.renderOnly && m_embeddedCellPending > m_embeddedCellStarved;
    if (!forceAnimate && canStopTimer && !m_pressed && settled &&
        !app->hud.animating(m_animationTime) && !m_discRotating && (!hudTransition || nowPaused) &&
        !hudStillPending && m_frame["mode"] != "boot" && m_temporalFramesRemaining == 0 &&
        !embeddedCellsNeedAdmission) {
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
    m_sceneViewportDirty = true;
    scene.resize(width / (height / 1080), 1080);
    wake();
}
void Engine::action(QString value) {
    // 性能面板停用：performance:toggle 动作不再分发。
    // 窗口模式由 Qt 原生窗口处理，不进入音乐状态或场景动画。
    if (value == "window:fullscreen") {
        toggleFullscreen();
        return;
    }
    app->hud.action(value);
    // 连续拖动只更新页面位置，不反复同步查询后台播放服务。
    const bool scrollGesture =
        value.startsWith("mobile:lyrics-") || value == "mobile:archive-begin" ||
        value == "mobile:archive-release" || value.startsWith("mobile:comments-drag:") ||
        value == "mobile:comments-release" || value.startsWith("mobile:discover-scroll");
    if (!app->hud.compactLayout() || !scrollGesture) {
        pollMedia();
    }
    // 所有 HUD 动作保留输入唤醒语义，横屏和移动布局都要退出场景休眠。
    wake();
}

void Engine::playSurfaceSound(bool opened) {
    if (!compactLayout()) {
        app->hud.playSurfaceSound(opened);
    }
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
        m_wheelSteps += -delta / WHEEL_STEP_PIXELS;
        // 单独保留连续舞台位移，避免触控板不足一行的输入被整数行索引吞掉。
        m_wheelDistance += -delta / (m_height / 1080.);
    } else {
        // 列表按格立即推进一行，只有设置页和歌词需要平滑的连续距离。
        m_wheelSteps += delta < 0 ? 1 : -1;
        // 这里的 15 是「一格滚轮 = 15 个步进单位」的距离换算，和上面的舞台像素除数无关。
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
#if defined(Q_OS_LINUX) || defined(Q_OS_DARWIN)
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
#if defined(Q_OS_LINUX) || defined(Q_OS_DARWIN)
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
    // 页面过渡期间不能复用上一份 scene.frame：detail 过渡值逐帧变化，复用会让
    // NativeHud::draw 拿到旧 frame、命令流冻结，hudUpdated 自然也不发。
    const bool hudTransition = clock.elapsed() < m_hudTransitionUntilMs || m_detailGrace;
    // 详情淡入期间绝不复用旧 scene.frame：复用会让 sample() 不被调用，
    // m_detail / m_changed 都停住，正是那个自锁环的入口。
    const bool compact = compactLayout();
    const bool scenePaused = compactScenePaused();
    const bool keepFrozen = compact && canReuseFrozenScene();
    const bool mustRefreshLayer = sceneLayer() != SceneLayer::Live && !scenePaused;
    const bool reuse = scenePaused || (!mustRefreshLayer && m_sceneSleeping && !scene.changed() && !hudTransition);
    if (!reuse) {
        m_sceneViewportDirty = false;
        m_sceneDark = app->hud.dark;
    }
    const auto object = app->step(time, m_width / (m_height / 1080), reuse);
#if defined(Q_OS_LINUX) || defined(Q_OS_DARWIN)
    const double stepAppMs = stepProbe ? double(stepAppTimer.nsecsElapsed()) / 1e6 : 0.0;
#endif
    if (object.isEmpty()) {
        return;
    }
    const auto previousDiscAngle = m_frame.value("discAngle").toDouble();
#ifdef Q_OS_DARWIN
    const auto previousOrigin = m_frame.value("stats").toObject().value("coordinateOrigin");
#endif
    const auto previousPanelTop = m_frame.value("songPanelTop");
    const auto previousPanelTransition = m_frame.value("songPanelTransition");
    m_frame = scene.frame;
    const auto hudState = object["state"].toObject();
    if (hudState["compactLayout"].toBool()) {
        m_frame["mobileHud"] = true;
        const bool retainPanelMask = keepFrozen && !hudState.value("songPanelTop").isDouble();
        m_frame["songPanelTop"] = retainPanelMask ? previousPanelTop : hudState.value("songPanelTop");
        m_frame["songPanelTransition"] = retainPanelMask ? previousPanelTransition
                                                        : hudState.value("songPanelTransition");
    }
    // 本帧刚切进 detail 时，tick() 开头看到的还是上一帧的 archive；不在这里重算，
    // 帧末的休眠判定就会用 false 把 timer 停掉，再也没有下一帧。
    updateDetailGrace(clock.elapsed());
    // HUD 换页 / 详情过渡的判据：mode、viewer 或 detail 过渡值任一变化，就把接下来
    // 一段窗口标成「HUD 连续刷新期」。detail 是 SceneMotion::smooth 的输出，逐帧在变；
    // 少了这段标记，pacing Skip、引擎休眠和上面的 reuse 会把整段动画吃掉。
    const auto pageMode = m_frame.value("mode").toString();
    const bool pageViewer = m_frame.value("viewer").toBool();
    const double pageDetail = m_frame.value("detail").toDouble();
    const bool pageSwitch = pageMode != m_hudPageMode || pageViewer != m_hudPageViewer;
    const bool detailMoving = std::abs(pageDetail - m_hudPageDetail) > 1e-4;
    // 只看「值有没有变」是不够的：引擎休眠时 detail 会冻结在 0，永远不产生变化，
    // 过渡窗口 600 ms 一过就又睡回去。改成「没收敛就一直续期」——
    // frame["detail"] 是详情 HUD 的 alpha，<0.99 时整页还是透明的，必须继续出帧。
    const bool detailPending = pageMode == "detail" && pageDetail < 0.99;
    if (pageSwitch || detailMoving || detailPending) {
        m_hudPageMode = pageMode;
        m_hudPageViewer = pageViewer;
        m_hudPageDetail = pageDetail;
        // 动画本身约半秒；留一点余量让最后一帧稳定值也能被整窗画出来。
        m_hudTransitionUntilMs = clock.elapsed() + 600;
    }
    auto signature = m_frame;
    for (const auto &key : {"time", "stats", "labels", "boot", "pointerCursor", "jitter", "temporalReset"}) {
        signature.remove(key);
    }
    // FSR3 亚像素抖动：默认关闭；关闭时 frame 里没有 jitter 键，渲染路径与之前完全一致。
    // 相位只在真正产生帧的 step 里推进，按 8 帧循环。
    // 但时间性抗锯齿（FSR3/TAA）本身就是靠相位差累积历史，没有抖动它们只会反复混合
    // 同一张图、等于白做，所以这两者开启时无条件打开。AA 模式每帧读环境变量，切换免重启。
#ifdef Q_OS_DARWIN
    const auto renderSettings = renderConfiguration.snapshot();
    const bool metalFxTemporal = m_frame.value("mode") != "boot" && renderSettings.temporal();
    if (!metalFxTemporal) {
        m_temporalFramesRemaining = 0;
    }
    const bool temporal = metalFxTemporal && !scenePaused;
    // 仅开 FG 插值时渲染器同样消费实例运动历史，原点变化必须一并重置。
    const bool usesMotionHistory = temporal || renderSettings.frameGeneration();
    if (usesMotionHistory && previousOrigin != m_frame.value("stats").toObject().value("coordinateOrigin")) {
        // 原点平移会重新编码实例 ID；历史不能跨坐标系继续配对，MetalFX 也须一起重置。
        m_jitterPhase = 0;
        m_temporalResetPending = true;
    }
#else
    const auto aaMode = RhineRender::currentRenderMode(qEnvironmentVariable("RHINE_AA_MODE"), false).aaMode;
    // 空间 FSR 回退不累积历史，不能继续投影抖动，否则静止画面会逐帧闪动。
    const bool computeFsr =
        (aaMode == "fsr" || aaMode == "fsr3") && qEnvironmentVariable("RHINE_FSR_ENGINE") == "fsr3";
    const bool temporal = !scenePaused && (aaMode == "taa" || computeFsr);
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
    const bool compactSong = compact && hudState.value("songPanelTop").isDouble();
    const bool dedicatedScene = m_frame.value("viewer").toBool() || m_frame.value("mode") == "boot";
    const bool compactHome = compact && m_frame.value("mode") == "archive" && !compactSceneObscured();
    const auto current = object["current"].toObject();
    const auto cover = object["cover"].toString();
    const auto coverRevision = host.image(cover).cacheKey();
    const auto &player = app->music.player;
    // render-only（Flutter 内嵌）：Qt 的 MusicLibrary/播放器是空壳——NativeApplication.cpp:166-177
    // 只把 Flutter 的选中身份投影进 frame["current"]，从不建播放器、也不写 playing。所以
    // 唱片旋转的 identity 与 playing 只能读投影真值（lib/basic/qt_scene_view.dart 的
    // current.playing 来自唯一播放器）。读 Qt 播放器会让唱片永远不转：identity 恒为空、
    // loading/playing 恒为 false——这正是"开启后封面不旋转"的根，且不需要第二个播放器。
    const bool projectedPlayback = host.renderOnly;
    const auto identity = projectedPlayback ? PlaybackQueue::identity(current)
                                            : PlaybackQueue::identity(player.current);
    if (identity != m_discIdentity) {
        m_discIdentity = identity;
        m_discAngle = 0;
    }
    const bool wasRotating = m_discRotating;
    const bool playing = projectedPlayback
                             ? current.value("playing").toBool(false)
                             : (!player.loading && !player.failed && player.state["playing"].toBool());
    m_discRotating = m_visible && app->hud.discRotation && PlatformFeatures::discRotationAvailable() &&
                     !app->hud.reduced && app->hud.modal.isEmpty() &&
                     (projectedPlayback || !compact || (compactSong && !app->hud.lyricsMode)) &&
                     m_frame.value("mode") == "detail" && !m_frame.value("viewer").toBool() &&
                     current["kind"] == "song" && PlaybackQueue::identity(current) == identity && playing;
    SceneLayer layer = SceneLayer::Live;
    if (!projectedPlayback && compact && !dedicatedScene) {
        if (compactSong) {
            // 等原有镜头、唱片解密与归位收束，停稳后把最后一张场景纹理留在详情顶部。
            const bool settled = (keepFrozen && scene.themeSettled()) || scene.detailSettled();
            if (settled && !m_discRotating) {
                layer = SceneLayer::Frozen;
            } else if (!settled) {
                m_sceneSleeping = false;
            }
        } else if (!compactHome) {
            layer = SceneLayer::Hidden;
        }
    }
    const bool layerNeedsDraw = m_hiddenSceneDirty ||
                                (sceneLayer() != layer && !(layer == SceneLayer::Frozen && keepFrozen));
    setSceneLayer(layer);
    m_hasFrozenScene = layer == SceneLayer::Frozen || (layer == SceneLayer::Hidden && keepFrozen);
    if (sceneLayerVisible()) {
        m_hiddenSceneDirty = false;
    }
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
    // 封面解码完成时命令流是逐字相同的（image 命令只带 key），单靠命令流比对
    // 会以为"什么都没变"，HUD 上那张图就永远不刷新。这里单独记一笔。
    [[maybe_unused]] const bool coverArrived = coverRevision != m_coverRevision;
    bool visualChanged = discChanged || !stable || current != m_current || cover != m_cover ||
                         coverRevision != m_coverRevision || m_coverRefresh;
    m_coverRefresh = false;
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
    m_coverImage = coverImageOf(m_cover);
    // Host::image() 只按 loadCover 补过 param 的键命中，原始 URL 必然 miss；
    // miss 时重新 loadCover，并用回调返回的键取图。
    if (!m_cover.isEmpty() && m_coverImage.isNull() && !m_coverRequests.contains(m_cover)) {
        m_coverRequests.insert(m_cover);
        const QString requested = m_cover;
        qInfo("RHINE_QT_COVER_REQUEST len=%d url=%.96s", int(requested.size()),
              qPrintable(requested));
        host.loadCover(
            requested,
            [this, requested](QString loaded) {
                qInfo("RHINE_QT_COVER_RESULT len=%d key=%.96s", int(loaded.size()),
                      qPrintable(loaded));
                if (loaded.isEmpty() || m_cover != requested) {
                    return; // 期间换了选中/换了视图：旧的这首不再回填
                }
                const QImage pixels = host.image(loaded);
                if (pixels.isNull()) {
                    qWarning("RHINE_QT_COVER_DECODE miss key=%.96s", qPrintable(loaded));
                    return;
                }
                qInfo("RHINE_QT_COVER_READY %dx%d", pixels.width(), pixels.height());
                m_coverImage = pixels;
                m_coverRefresh = true;
            },
            1024);
    }
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
            // 条目没了，"已请求过封面"的记录也一并作废：它下次回到视野时值得再试一次。
            m_coverRequests.remove(it.key());
            it = m_musicTextures.erase(it);
        } else {
            ++it;
        }
    }
    // 可见格的准入上报与封面泵。放在 prune 之后：只给真正留下来的条目做事。
    pumpEmbeddedCells(retainedKeys, m_embeddedCellScrolling);
    publishEmbeddedCells(retainedKeys);
#if defined(Q_OS_ANDROID)
    // 归档页会同时画 7 张唱片，但每个条目的封面图只在"它成为当前曲目"的那一帧取一次
    // （上面的 `m_musicTextures[musicKey] = {current, m_coverImage}`），切歌瞬间
    // host.image() 往往还没解码完，条目里就留下空 QImage，之后永不回填 —— 表现为
    // 就是非当前唱片的盘面全是 placeholderCover（TEXDIAG: mt=7 adm=2 gated=5 discO=6
    // covers=2，C++ 侧补建因为 `!it->cover.isNull()` 一个都过不去）。
    //
    // 不能只查 host.image()：缓存键是 loadCover 里加过 `param=512y512` 的改写 URL，拿
    // item["cover"] 的原始地址去查永远 miss。所以要主动 loadCover，回调里再按返回的键取图。
    // 512 像素够远看，一张约 1 MB，是当前曲目 1024 封面的四分之一。
    // 放在 prune 之后：只给真正留下来的条目请求，别为马上就丢的 key 白下载。
    for (auto it = m_musicTextures.begin(); it != m_musicTextures.end(); ++it) {
        if (!it->cover.isNull() || it->item.isEmpty()) {
            continue;
        }
        const auto url = it->item["cover"].toString();
        // 可见格那条通道是按 URL 记账的（同一个地址可能被多格共享），两个键都要查。
        if (url.isEmpty() || m_coverRequests.contains(it.key()) || m_coverRequests.contains(url)) {
            continue;
        }
        const auto key = it.key();
        m_coverRequests.insert(key);
        host.loadCover(
            url,
            [this, key](QString loaded) {
                if (loaded.isEmpty()) {
                    return;
                }
                // 回调是异步的：期间条目可能已被 prune 掉，用 find 而不是 operator[]，
                // 否则会给一个已经没人要的 key 重新建条目。
                auto entry = m_musicTextures.find(key);
                if (entry != m_musicTextures.end() && entry->cover.isNull()) {
                    entry->cover = host.image(loaded);
                }
            },
            512);
    }
#endif
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
        // 选中焦点通道与可见格通道各管一半：任一准入就让渲染侧建这一格的标签/封面。
        entry.admitted = m_admission.isAdmitted(it.key()) || m_embeddedCellAdmission.isAdmitted(it.key());
        m_musicTextureSnapshot.insert(it.key(), entry);
    }
    auto commands = object["commands"].toArray();
    bool hudChanged = true;
#if defined(Q_OS_ANDROID)
    // 只比对一次：hudDirtyRect 内部的「公共前缀 + 公共后缀」顺带就能判出「逐条相同」，
    // 不必再跑一遍 `commands != m_commands` 的深比较——那是同一条命令流的第二遍遍历。
    const double stageWidth = m_height > 0 ? m_width / (m_height / 1080) : 1920;
    const QSizeF stageSize(stageWidth, 1080);
    const bool transition = clock.elapsed() < m_hudTransitionUntilMs || m_detailGrace;
    // 分层（见 render/HudLayers.h）：静态前缀（遮罩 / 品牌 / 导航 / footer）一条都没变时，
    // 两张纹理只有动态层要重画。滑列表时静态遮罩是一条覆盖整个播放列表条带的渐变，
    // 它和滚动内容相交，于是单层的脏区每次都退化成整屏——分层就是为这条遮罩做的。
    // RHINE_HUD_LAYERED=0 退回单层，方便 A/B（默认开）。
    static const bool layeredEnabled = [] {
        const auto value = qEnvironmentVariable("RHINE_HUD_LAYERED");
        return value.isEmpty() || value != QLatin1String("0");
    }();
    const auto layers = layeredEnabled
                            ? RhineRender::hudSplitLayers(commands, app->hud.staticCommandCount())
                            : RhineRender::HudLayerSplit();
    if (layers.layered) {
        const auto staticDirty =
            RhineRender::hudDirtyRect(m_hudStaticCommands, layers.staticCommands, stageSize);
        const auto dirty =
            RhineRender::hudDirtyRect(m_hudDynamicCommands, layers.dynamicCommands, stageSize);
        m_hudStaticChanged = !staticDirty.equal;
        m_hudDynamicChanged = !dirty.equal;
        hudChanged = m_hudStaticChanged || m_hudDynamicChanged;
        if (m_hudStaticChanged) {
            m_hudStaticDirtyStage = staticDirty.rect;
            // 过渡窗口（详情淡入）里 alpha 会包住整条命令流，任何局部归因都可能漏像素：
            // 两层都整块重画。
            m_hudStaticDirtyFull = staticDirty.full || transition;
            m_hudStaticCommands = layers.staticCommands;
        }
        if (m_hudDynamicChanged) {
            m_hudDirtyStage = dirty.rect;
            m_hudDirtyFull = dirty.full || transition;
            m_hudDynamicCommands = layers.dynamicCommands;
        }
        if (!m_hudLayered) {
            // 单层 → 分层：两张纹理都是新建的，各自整块画一次。
            m_hudLayered = true;
            m_hudStaticDirtyFull = true;
            m_hudDirtyFull = true;
            m_hudStaticChanged = true;
            m_hudDynamicChanged = true;
            hudChanged = true;
        }
    } else {
        const auto dirty = RhineRender::hudDirtyRect(m_commands, commands, stageSize);
        hudChanged = !dirty.equal;
        m_hudStaticChanged = false;
        m_hudDynamicChanged = hudChanged;
        if (hudChanged) {
            m_hudDirtyStage = dirty.rect;
            m_hudDirtyFull = dirty.full;
            // 淡入时唯一逐帧变化的是 alpha，没有包围盒可归因；
            // 过渡期一律整窗重绘，漏画就是 HUD 停在上一页。
            if (transition) {
                m_hudDirtyFull = true;
            }
        }
        if (m_hudLayered) {
            // 分层 → 单层（启动动画 / 全屏播放页 / 前缀不自成作用域）：节点形态变了，
            // 必须整块重建，两张纹理都作废。
            m_hudLayered = false;
            m_hudStaticCommands = {};
            m_hudDynamicCommands = {};
            m_hudStaticDirtyFull = true;
            m_hudDirtyFull = true;
            m_hudStaticChanged = false;
            m_hudDynamicChanged = true;
            hudChanged = true;
        }
    }
#else
    hudChanged = commands != m_commands;
    if (hudChanged) {
        m_hudDirtyFull = true;
    }
#endif
    if (pageSwitch) {
        // 整页换内容：局部重绘会留下上一页的残影，强制整窗且必须发一次更新。
        // 换页时静态前缀也变了（主题色、导航选中态、footer 文案），两层都整块重画。
        hudChanged = true;
        m_hudStaticChanged = true;
        m_hudDynamicChanged = true;
        m_hudDirtyFull = true;
        m_hudStaticDirtyFull = true;
    }
    if (hudChanged) {
        m_commands = commands;
        ++m_hudUpdates;
        m_hudRevision.fetch_add(1, std::memory_order_relaxed);
    }
    if (compact && coverArrived) {
        m_hudDirtyFull = true;
    }
    // 自管呈现的横屏过渡仍沿用连续提交；竖屏 HUD 只提交命令或图片发生变化的帧。
    if (hudChanged || (compact && coverArrived) ||
        (!compact && (clock.elapsed() < m_hudTransitionUntilMs || m_detailGrace))) {
        publishHudFrame();
    }
#if defined(Q_OS_ANDROID)
    if (coverArrived && (!compact || (m_hudLayered && !m_hudDynamicChanged))) {
        // 命令流没变但 HUD 上的像素变了（封面异步到位）：补一次整块重画。
        // 封面只出现在动态层，静态前缀不受影响，不要连带把静态层也整块重画。
        m_hudDynamicChanged = true;
        m_hudDirtyFull = true;
        publishHudFrame();
    }
#endif
    if (visualChanged && sceneLayerVisible()) {
        ++m_sceneUpdates;
    }
    // 横屏保留 HUD 对呈现的原有联动；竖屏由 HUD 独立申请窗口合成。
    notifySceneRenderers(sceneLayerVisible() &&
                         (visualChanged || layerNeedsDraw || (!compact && (hudChanged || m_detailGrace))));
    if constexpr (PlatformFeatures::InterfaceSounds) {
        // 自然结束、跳过和关闭动画均从第一个已提交的内容帧触发。
        if (m_startupSoundPending && m_started && m_visible && (pageMode == "archive" || pageMode == "detail")) {
            m_startupSoundPending = false;
            app->hud.playStartupSound();
        }
    }
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
#if defined(Q_OS_LINUX) || defined(Q_OS_DARWIN)
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

void Engine::importPluginFolder(QUrl url) {
    if (!url.isLocalFile()) {
        return;
    }
    const auto error = host.importPlugin(url.toLocalFile());
    app->hud.pluginManagerMessage = error;
    host.invalidate();
    wake();
}

void Engine::importPluginPackage(QUrl url) {
#ifndef Q_OS_ANDROID
    if (!m_pluginImports.contains(url) && m_pluginImports.size() < 16) {
        m_pluginImports.enqueue(std::move(url));
        startNextPluginImport();
    }
#else
    Q_UNUSED(url)
#endif
}

void Engine::startNextPluginImport() {
    if (host.pluginInstallPending() || m_pluginImports.isEmpty()) {
        return;
    }
    const auto url = m_pluginImports.dequeue();
    // 从系统打开文件时进入本地确认流程，无需刷新网络市场。
    app->hud.openModal("plugins");
    app->hud.pluginManagerMessage = host.importPluginPackage(url);
    if (!app->hud.pluginManagerMessage.isEmpty()) {
        QTimer::singleShot(0, this, &Engine::startNextPluginImport);
    }
    wake();
}
