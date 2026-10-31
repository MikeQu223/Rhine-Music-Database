#pragma once
#include <QtGlobal>

#include "../DeferredWindowTransition.h"
#include "../fg/FgStats.h"
#include "../fg/FgFrameTap.h"
#include "PresentationBackend.h"
#include "PresentationStartupProbe.h"
#include "FrameGenerator.h"

#include <QByteArray>
#include <QImage>
#include <QVariantMap>
#include <QElapsedTimer>
#include <QHash>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QSize>
#include <QString>
#include <array>
#include <memory>

QT_BEGIN_NAMESPACE
class QQmlEngine;
class QEvent;
class QRhi;
class QQuickItem;
class QQuickWindow;
class QRhiBuffer;
class QRhiCommandBuffer;
class QRhiGraphicsPipeline;
class QRhiRenderPassDescriptor;
class QRhiRenderTarget;
class QRhiSampler;
class QRhiResource;
class QRhiShaderResourceBindings;
class QRhiTexture;
class QRhiTextureRenderTarget;
class QTimer;
class QVulkanInstance;
class QWindow;
QT_END_NAMESPACE

class Engine;
class FgBackend;
class SceneLayerHost;

/**
 * 所有后端共用的呈现调度：分别更新场景与 UI，执行可选插值，再合成到后端目标。
 * 平台窗口、交换链、原生图像布局与同步由 PresentationBackend 负责。
 * 启动失败可回退到 Qt Quick 默认窗口；插值降级不影响普通呈现。
 */
class PresentationShell : public QObject {
    Q_OBJECT

  public:
    PresentationShell(QQmlEngine &engine, Engine &backend, QString backendName, QObject *parent = nullptr);
    ~PresentationShell() override;

    /// 编译期是否可能支持（Vulkan 后端 + FFX 已编入）。
    static bool compiledIn();
    static bool supportsBackend(const QString &name);

    /// 用户是否要求开启（RHINE_FG=on 或设置页 panel/fg）。
    bool requested() const;

    /// 建立实例/设备/窗口/离屏层/交换链并打开渲染循环。失败时 lastError() 给出原因。
    /**
     * @brief 退出前先拆呈现层：停掉呈现定时器、释放交换链资源与 VkSwapchainKHR。
     *
     * 必须先于窗口销毁调用。交换链还活着时窗口先没了，驱动的 WSI 会拿已销毁的
     * wl_surface（Windows 上是已销毁的 HWND）去做 roundtrip，退出即崩。
     * 幂等，析构路径会再调用一次。
     */
    void shutdown();
    void requestQuit();

    bool start();

    /// 启动后的收尾：返回给 main() 的退出码。渲染由事件循环里的定时器驱动。
    int run();

    QString lastError() const {
        return m_error;
    }
    bool frameGenerationActive() const {
        return m_fgAvailable;
    }
    QWindow *window() const;
    QImage grabFrame(bool interpolated = false);
    QVariantMap renderState() const;
    QQuickWindow *inputWindow() const;
    QQuickWindow *sceneWindow() const;

  signals:
    /// iOS 在原生事件循环内完成首帧自检，失败后由应用切回默认窗口。
    void startupFailed();

  protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

  private:
    /// 交换链要的物理像素尺寸（逻辑尺寸 × 设备像素比）。
    QSize pixelSize() const;
    /// 同步补焦点：按键到达时若没有焦点项就当场重建。
    void ensureOverlayFocus(QQuickWindow *overlay);
    void step();
    void scheduleNext(int delayMs = 0);
    void reportStats();
    /// 上一次统计时的帧数，用来把 ms/frame 算成"这一窗口内"的均值。
    int m_statsBase = 0;
    /// 设备像素比：交换链按 m_size*m_dpr 建，QML 仍按 m_size 逻辑像素排版。
    qreal m_dpr = 1.0;
    /// 真实窗口上次的 devicePixelRatio，用来发现屏幕/缩放变化。
    qreal m_windowDpr = 1.0;
    bool initializeBackend();
    bool initializeLayers();
    bool ensureSwapchainResources();
    void releaseSwapchainResources();
    bool ensureCompositeResources();
    QRhiShaderResourceBindings *bindingsFor(QRhiTexture *base, QRhiTexture *overlay);
    bool recreateSwapchain();
    void syncSizes();
    /// 帧外准备：按最新输入重建上下文并写入相机参数。必须在 beginOffscreenFrame 之前。
    bool armFrameGeneration();
    const RhineFg::FrameInputs &currentFrameInputs() const;
    /// 记录 FG 的命令，返回"本帧是否有可用的插值帧"。
    bool recordFrameGeneration(QRhiCommandBuffer *cb);
    /// 把 base（插值帧或当前帧）与 UI 合成到交换链图像，并转到 PRESENT_SRC。
    bool composite(QRhiCommandBuffer *cb, QRhiTexture *base, QRhiTexture *overlay, quint32 imageIndex,
                   QRhiRenderTarget *overrideTarget = nullptr);
    bool presentOne(const RhineRender::PresentationBackend::Frame &frame, bool allowInterpolation,
                    bool *interpolatedOut);
    QString resolveQmlUrl(const QString &file) const;

    /// 读走 m_probe 的耗时并重新起表（毫秒）。
    double tookMs();
    /// 把一次测量并入滑动平均：单帧抖动大，面板要的是可读的趋势。
    static double blend(double previous, double sample);
    /// 记一次呈现间隔，并按需重算分位（呈现层的帧率统计全靠它，FG 路径没有 frameSwapped）。
    void recordGap(double gapMs);
    void refreshGapStats();
    /// A02：记一对 beginFrame/endFrame 原始耗时样本，并按需重算滚动分位。
    /// EMA 会把一次 20ms 的槽等待摊平，p95/p99 必须用原始样本算。
    void recordWaitSample(double beginMs, double endMs);
    void refreshWaitStats();
    /// 把 m_stats 的最新内容发给性能面板。
    void publishStats(bool interpolatedThisStep);

    DeferredWindowTransition m_quitTransition;
    bool m_quitRequested = false;
    QQmlEngine *m_engine = nullptr;
    Engine *m_backend = nullptr;

    QWindow *m_window = nullptr;
    QRhi *m_rhi = nullptr;
    QString m_backendName;
    std::unique_ptr<SceneLayerHost> m_host;
    std::unique_ptr<RhineRender::FrameGenerator> m_fg;
    std::unique_ptr<RhineRender::PresentationBackend> m_presenter;

    QRhiBuffer *m_compositeUbo = nullptr;
    QRhiSampler *m_sampler = nullptr;
    QRhiGraphicsPipeline *m_pipeline = nullptr;
    // 管线要求 SRB 布局已确定，所以用一张 1×1 占位纹理建一份"模板" SRB；
    // 逐帧真正用的 SRB 由 bindingsFor() 按实际输入纹理缓存。
    QRhiTexture *m_pipelineBase = nullptr;
    QRhiShaderResourceBindings *m_pipelineBindings = nullptr;
    QHash<quint64, QRhiShaderResourceBindings *> m_bindingCache;
    // 建在本类自己的 QRhi 上、需要显式释放的资源（UBO、采样器、占位纹理）。
    QList<QRhiResource *> m_ownedResources;

    QTimer *m_timer = nullptr;
    QTimer *m_releaseTimer = nullptr;
    RhineRender::PresentationStartupProbe m_startupProbe;
    QElapsedTimer m_frameClock;
    // QRhi 建的设备句柄：发自己的屏障时要用设备级函数表。
    QSize m_size;
    // 交换链包装纹理对应的真实尺寸；presenter 的 extent 变化就要重建。
    bool m_fgAvailable = false;
    bool m_fgArmed = false;
    bool m_needRecreate = false;
    quint64 m_lastEngineSteps = 0;
#ifdef Q_OS_LINUX
    // 内容代次：区分"引擎前进"与"画面真的变了"（RHINE_PRESENT_CONTENT_ONLY=1 使用）。
    quint64 m_lastEngineHud = 0;
    quint64 m_lastEngineScene = 0;
    /// 有一步正在排队时收到的唤醒：当前步结束后补跑，避免丢 tick（丢一次就少一帧）。
    bool m_wakePending = false;
#endif
    bool m_started = false;
    bool m_stopped = false;
    quint64 m_lastTapSerial = 0;
    quint64 m_presentedFrames = 0;
    quint64 m_interpolatedFrames = 0;
    // 场景真实重渲的帧数（不是呈现帧数）：面板里的"渲染 FPS"用它。
    quint64 m_renderedFrames = 0;
    QString m_error;

    // —— 性能面板用的运行时统计 ——
    // 复用同一个计时器串行测量，避免每帧构造 QElapsedTimer；
    // 面板要的是分项趋势，不是单帧精度，所以一律走滑动平均。
    QElapsedTimer m_probe;
    // 整帧计时：presentOne 里三段耗时会各自 restart m_probe，只有单独的计时器
    // 才能给出"这一帧从开始到上屏一共多久"（含 begin/end 离屏帧的隐式等待）。
    QElapsedTimer m_frameProbe;
    RhineFg::Stats m_stats;
    // 呈现间隔环形缓冲：FG 路径不经过 QQuickWindow，拿不到 frameSwapped 事件，
    // 所以分位与卡顿计数自己算。600 个样本在 60Hz 下约 10 秒。
    static constexpr int kGapCapacity = 600;
    std::array<double, kGapCapacity> m_gapRing{};
    int m_gapCursor = 0;
    int m_gapFilled = 0;
    // A02：beginFrame/endFrame 的原始耗时环，120 个样本（60Hz 下约 2 秒）。
    // 窗口不取 600：这两个数要能快速反映"换了驱动/开了读回之后槽等待有没有变"，
    // 10 秒窗口太钝；120 帧足够算 p99（约 1~2 个尾部样本），也够快跟上变化。
    static constexpr int kWaitCapacity = 120;
    std::array<double, kWaitCapacity> m_beginRing{};
    std::array<double, kWaitCapacity> m_endRing{};
    int m_waitCursor = 0;
    int m_waitFilled = 0;
    quint64 m_waitSamples = 0;
    // A02：离屏提交计数。呈现层取后端累计数（在真正提交处 +1）；QML 场景层/UI 层没有
    // 计数接口可改（不在本次范围），只能对 SceneLayerHost 的两个公开计数取差分。
    quint64 m_layerSubmits = 0;
    // 呈现层自己也数一遍 beginFrame 成功次数：RhiPresentationBackend 没有后端计数器
    // （offscreenSubmits() 默认 0），只用后端数字会把呈现层这一次凭空漏掉。
    quint64 m_presenterSubmits = 0;
    // 上次 publishStats 时的快照，用来算"自上次发布以来"发生了多少次提交。
    quint64 m_lastPresenterSubmits = 0;
    quint64 m_lastLayerSubmits = 0;
    QElapsedTimer m_presentClock;
    // 两步之间的空档（定时器等待 + 事件循环排队）单独计时：它和 endOffscreenFrame
    // 是仅有的两个"没被分项计时覆盖"的时间块，排障时要能把它们和渲染成本分开看。
    QElapsedTimer m_stepClock;
    qint64 m_stepEndNs = 0;
    /// 插值帧先上屏、真实帧留到下一步：一步只做一次 present。
    bool m_pendingRealFrame = false;
    /// 交换链重建/窗口尺寸变化后必须无条件重画一次（纹理内容已失效）。
    bool m_forcePresent = true;
    /// 连续跳过的步数：引擎在推进却一直没有脏标记时用它兜底，避免画面冻住。
    /// 累计跳过的步数，写进统计日志，便于确认"静止时确实没在空转"。
    quint64 m_skippedSteps = 0;
#ifdef Q_OS_LINUX
    /// 连续跳过的步数：超过阈值就强制两层重渲一次（看门狗）。
    /// 删掉原先"引擎 steps 变了就重渲"那个隐式兜底之后，这是唯一的漏标脏保险。
    int m_consecutiveSkips = 0;
#else
    /// 上次渲染时引擎的步进计数：它变了才说明场景状态真的推进了。
#endif
    /// 排障计数：acquire 超时 / OutOfDate 的次数（空转时靠它们判断卡在哪条提前返回）。
    quint64 m_acquireTimeoutCount = 0;
    quint64 m_outOfDateCount = 0;
    /// 连续强制重建的次数（有一帧成功上屏就清零）。用来区分"重建能救活"和
    /// "这台设备就是不能呈现"：后者重建多少次都没用，要尽快判定失败让上层回退。
    int m_recreateStreak = 0;
    /// 距上次交换链重建成功上屏了多少帧。重建后前两帧不做插值：
    /// 那时离屏层可能还在按旧尺寸排版，跨尺寸插出来的帧会整屏错色。
    int m_framesSinceRecreate = 99;
    /// 判定呈现层无法工作。自检循环据此提前结束，不再白等超时。
    bool m_failed = false;
};
