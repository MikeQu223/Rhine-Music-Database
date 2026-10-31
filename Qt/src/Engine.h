#pragma once
#include "Gamepad.h"
#include "Glyphs.h"
#include "Host.h"
#include "NativeApplication.h"
#include "render/FramePacingPolicy.h"
#include "render/MusicTextureAdmission.h"
#include "render/RenderPolicy.h"
#ifdef Q_OS_DARWIN
#include "render/RenderConfiguration.h"
#include "fg/FgFrameTap.h"
#endif
#include <QElapsedTimer>
#include <QPointF>
#include <QVariantMap>
#include <QUrl>
#include <QQuickWindow>
#include <QPointer>
#include <array>
#include <atomic>
class Engine : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap state READ state NOTIFY stateChanged)
    Q_PROPERTY(QVariantList hits READ hits NOTIFY hitsChanged)
    Q_PROPERTY(QVariantMap performance READ performance NOTIFY stateChanged)
  public:
    Engine(QString root, bool offline = false, QObject *parent = nullptr,
           PlaybackConnection *connection = nullptr);
    ~Engine() override;
    QVariantMap state() const {
        return m_state;
    }
    QVariantList hits() const {
        return m_hits;
    }
    QJsonObject frame() const {
        return m_frame;
    }
    QJsonObject current() const {
        return m_current;
    }
    QImage cover() const {
        // 渲染线程读这里，不能直接访问 Host 的图片缓存（QCache 非线程安全）。
        // m_coverImage 在 GUI 线程的 update() 里同步，QImage 的隐式共享保证拷贝安全。
        return m_coverImage;
    }
    QJsonArray commands() const {
        return m_commands;
    }
    Glyphs *glyphs() {
        return &m_glyphs;
    }
    QString root() const {
        return host.root;
    }
    Q_INVOKABLE void importLocal(QList<QUrl> urls);
    Q_INVOKABLE void resize(double width, double height);
    Q_INVOKABLE void action(QString action);
    Q_INVOKABLE void submitForm(QString account, QString captcha);
    Q_INVOKABLE void sendLoginCode(QString phone);
    Q_INVOKABLE bool keyEvent(int key, int modifiers, QString text);
    /// 真正的按键处理；keyEvent 负责探针记录后转发。
    bool keyEventImpl(int key, int modifiers, QString text);
    Q_INVOKABLE void searchAccepted(QString text, int modifiers);
    Q_INVOKABLE void wheelInput(double x, double y, double pixelDelta, double angleDelta);
    Q_INVOKABLE void adjustPlayer(QString control, double x, double width);
    Q_INVOKABLE void toggleFullscreen();
    Q_INVOKABLE void minimizeWindow();
    // FG 路径呈现层是裸 QWindow（无 QQuickWindow），所以这里只要求 QWindow。
    void setWindow(QWindow *window);
    // 返回诊断帧间隔覆盖值，未指定时由呈现侧自适应限速。
    int frameIntervalMs() const;
    Q_INVOKABLE void query(QString query);
    Q_INVOKABLE void key(QString key, bool command);
    Q_INVOKABLE void settingEditText(QString text);
    Q_INVOKABLE void settingEditAccepted();
    Q_INVOKABLE void settingEditCancel();
    Q_INVOKABLE void pointer(QString type, double x, double y);
    Q_INVOKABLE void wheel(double x, double y, double delta, bool pixels = false);
    Q_INVOKABLE void snapshot(QString path);
    void step(double time);
    QVariantMap performance() const;
    SceneDrawBuffers drawBuffers() const {
        return scene.drawBuffers;
    }
    quint64 geometryRevision() const {
        return m_geometryRevision;
    }
    struct MusicTexture {
        QJsonObject item;
        QImage cover;
        /// B01：这个 key 是否已经通过冷资源准入（焦点稳定 100ms）。渲染线程据此决定
        /// 要不要创建标签／封面纹理；默认 true，让参考渲染与其他调用方不必关心准入。
        bool admitted = true;
    };
    using MusicTextures = QHash<QString, MusicTexture>;
    /**
     * C03：准入状态在 step() 里一次性写进快照，synchronize() 只做一次隐式共享的拷贝，
     * 不再逐项重写 admitted（那样每帧都要为每个条目 detach 一遍 QHash 节点）。
     */
    const MusicTextures &musicTextures() const {
        return m_musicTextureSnapshot;
    }
    /// 探针/诊断用：0 表示准入延迟已关闭。
    int textureAdmissionDelayMs() const {
        return m_admission.delayMs();
    }
    void trimMemory();
#ifdef Q_OS_DARWIN
    RhineRender::RenderConfiguration renderConfiguration;
    RhineRender::RenderTelemetry renderTelemetry;
    RhineFg::FrameInputs metalFxInputs;
#endif
    void recordResourceRelease() {
        m_gpuResources.store(0, std::memory_order_relaxed);
        m_musicTextureBytes.store(0, std::memory_order_relaxed);
    }
    Q_INVOKABLE void setVisible(bool value);
    // FSR3 接入接口：本帧投影使用的亚像素抖动（单位像素，屏幕坐标 x 向右、y 向下）。
    // RHINE_JITTER=1 时按 Halton(2,3) 的 8 个相位循环；默认关闭且恒为 (0,0)。
    QPointF jitterOffset() const {
        return m_jitterOffset;
    }
    bool jitterEnabled() const {
        return m_jitterEnabled;
    }
    // FSR 重置（画质切换、设备重建、分辨率变化）时调用：抖动归零、相位回到 0，
    // 并让下一帧携带 temporalReset 键，渲染器据此丢弃上一帧运动矢量历史。
    Q_INVOKABLE void resetTemporalState();
    /// 唤醒来源只影响诊断计数，不改变行为。
    enum class WakeSource { Input, Host, Media, Other };
    void wake(bool input = true);
    void wake(WakeSource source);
    void start();
    /// A03：内容版本。呈现层用它代替"按信号重复置脏"——版本前进一次只重渲一层，
    /// 重复推同一个值只在两个整数上比较一次。主线程写、渲染线程读，用 relaxed 原子
    /// 即可：这里要的是"值变了/没变"，不是用它同步任何内存。
    quint64 sceneRevision() const {
        return m_sceneRevision.load(std::memory_order_relaxed);
    }
    quint64 hudRevision() const {
        return m_hudRevision.load(std::memory_order_relaxed);
    }
    /// A03：渲染线程发现"新 GPU 资源已就位"（异步封面/模型上传完成）时，经队列连接
    /// 回到主线程调用这里。这类变化在场景帧字段里看不出来，notifySceneRenderers 的
    /// 自然触发点（帧签名比较）捕捉不到，只能由发现者自己上报一次。
    Q_INVOKABLE void requestSceneContent();
    /// C01：渲染线程在 synchronize() 里量到的"自定义快照同步"耗时。它不是 Qt Quick 的
    /// sync 总时长，只是我们自己那一段，单独记才能分清钱花在哪。
    void recordSceneSync(double ms) {
        m_syncMicros.store(quint64(ms * 1000.0 + 0.5), std::memory_order_relaxed);
        m_syncSamples.fetch_add(1, std::memory_order_relaxed);
    }
    /**
     * C04：渲染线程在 synchronize() 里报告"这一份快照已被取走"。写入原子序号后经队列
     * 回到主线程唤醒节拍；渲染线程不等 GUI，也不在这里做任何分配。
     */
    void noteSceneConsumed(quint64 revision);
    /// 队列回调：主线程看到消费进度后，若有待办就立刻恢复节拍。
    Q_INVOKABLE void sceneConsumed();
    void recordRender(quint64 resources, quint64 bindings = 0, quint64 textureBytes = 0,
                      quint64 coverUploads = 0, quint64 drawCalls = 0, double gpuTimeMs = 0,
                      RhineRender::GpuTimingStatus gpuTiming =
                          RhineRender::GpuTimingStatus::Unsupported) {
        m_renderFrames.fetch_add(1, std::memory_order_relaxed);
        m_gpuResources.store(resources, std::memory_order_relaxed);
        m_bindingCreations.fetch_add(bindings, std::memory_order_relaxed);
        m_musicTextureBytes.store(textureBytes, std::memory_order_relaxed);
        m_coverUploads.fetch_add(coverUploads, std::memory_order_relaxed);
        m_lastDrawCalls.store(drawCalls, std::memory_order_relaxed);
        // 状态与数值必须分开传：同一个 0 ms 可能是"没请求""没样本"或"真的很快"，
        // 只靠数值无法区分，而面板与 CSV 的诊断结论完全取决于这个区分（A01）。
        m_gpuTiming.store(int(gpuTiming), std::memory_order_relaxed);
        // 数值保留原有语义：0 不当作一次测量，避免用 0 覆盖掉上一个可信样本。
        if (gpuTimeMs > 0) {
            m_gpuTimeMicros.store(quint64(gpuTimeMs * 1000.0 + 0.5), std::memory_order_relaxed);
            // C01：数值与样本数分开记——0 不是一次测量，窗口均值要用样本数做分母。
            ++m_gpuSamples;
        }
        // A11：整帧资源账本必须在这里聚合。performance() 只看得到"最近一次快照"，
        // 既无法判断峰值出现在哪一帧，也无法把"本帧新增绑定/上传"与累计值分开；
        // 而 recordRender 是唯一同时拿到本帧全部资源入参的地方（渲染线程调用）。
        noteFrameLedger(resources, bindings, textureBytes, coverUploads);
    }
    bool ready() const;
    int selfTest();
    Host host;
    NativeScene scene;
    std::unique_ptr<NativeApplication> app;
    QString failure;
  signals:
    void updated();
    void sceneUpdated();
    void hudUpdated();
    void stateChanged();
    void hitsChanged();
    void clearCredentials();
    void performanceRequested();
    void localImportRequested(bool folder);

  protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

  private:
    void notifySceneRenderers(bool visualChanged);
    void gamepadPressed(const QString &button);
    Gamepad m_gamepad;
    quint64 m_geometryRevision = 0;
    /// C04：发布／消费序号对账。m_sceneRevision 就是发布序号，渲染线程回填消费序号。
    RhineRender::FramePacingPolicy m_pacing;
    std::atomic<quint64> m_sceneConsumed{0};
    /// 已经为哪个序号排过唤醒，避免渲染线程每帧都投递一次队列调用。
    std::atomic<quint64> m_consumeNotified{0};
    /// 输入优先于消费反馈：置位后下一次 tick 不跳过完整 step。
    bool m_inputPending = false;
    /// C03：准入状态随 musicTextures 一起在 GUI 线程生成，渲染线程只读这份快照。
    MusicTextures m_musicTextureSnapshot;
    /// C01：按来源分开计数，避免把"输入唤醒"和"Host 失效唤醒"混成一个数字。
    quint64 m_wakesInput = 0, m_wakesHost = 0, m_wakesMedia = 0, m_wakesOther = 0;
    /// C01：requestSceneContent 与 stableFrames 复位的次数／原因。
    quint64 m_sceneRequests = 0;
    quint64 m_stableResetInput = 0, m_stableResetScene = 0;
    /// C04：被合并掉的完整 step。
    quint64 m_stepsSkipped = 0;
    /// C01：GPU 样本数（数值为 0 的成功采样不计数）。
    quint64 m_gpuSamples = 0;
    /// 探针：唤醒次数与"场景真的变了"的拍数。空闲仍空转时，这两条决定往哪查。
    quint64 m_wakes = 0;
    quint64 m_changedSteps = 0;
    /// A03：内容版本，只在内容真的变了时自增（见 notifySceneRenderers/requestSceneContent）。
    std::atomic<quint64> m_sceneRevision{0};
    std::atomic<quint64> m_hudRevision{0};
    std::atomic<quint64> m_renderFrames{0}, m_gpuResources{0};
    std::atomic<quint64> m_bindingCreations{0};
    std::atomic<quint64> m_musicTextureBytes{0};
    std::atomic<quint64> m_coverUploads{0};
    std::atomic<quint64> m_lastDrawCalls{0};
    std::atomic<quint64> m_gpuTimeMicros{0};
    // 存 int 而不是枚举：原子量只要一个字的读写，转回枚举时不必担心填充或对齐差异。
    std::atomic<int> m_gpuTiming{int(RhineRender::GpuTimingStatus::Unsupported)};
    std::atomic<quint64> m_syncMicros{0};
    std::atomic<quint64> m_syncSamples{0};

    // ---- A11 整帧资源账本 ----
    // 口径（不要混用）：
    //   resources   = 本帧驻留资源**个数**（RhiScene 把 resources/sized/transient 相加）；
    //   textureBytes= 本帧驻留音乐纹理**字节**快照（不是本帧增量，见 RhiScene.cpp:1865）；
    //   bindings    = 本帧新建 SRB 个数（RhiScene 已做差分）；
    //   coverUploads= 本帧封面纹理上传**次数**（RhiScene 只提供次数，没有字节数）。
    // 峰值窗口 = 最近 kLedgerWindow 个渲染帧的滚动最大值，不是"自启动以来的 lifetime
    // 峰值"：启动期一次性上传会把 lifetime 峰值永久抬高，之后再贵也看不出来；滚动窗口
    // 才能回答"当前这一段帧到底占多少"。窗口约 240 帧 ≈ 60fps 下 4 秒。
    static constexpr int kLedgerWindow = 240;
    struct LedgerSlot {
        quint64 frame = 0;
        quint64 resources = 0;
        quint64 textureBytes = 0;
    };
    // 环形窗口只由渲染线程写（recordRender 的调用方），其他线程只读原子峰值。
    std::array<LedgerSlot, kLedgerWindow> m_ledgerWindow{};
    int m_ledgerCursor = 0;
    int m_ledgerFilled = 0;
    std::atomic<quint64> m_resourcesPeak{0};
    std::atomic<quint64> m_resourcesPeakFrame{0};
    std::atomic<quint64> m_textureBytesPeak{0};
    std::atomic<quint64> m_textureBytesPeakFrame{0};
    std::atomic<quint64> m_frameBindings{0};
    std::atomic<quint64> m_frameCoverUploads{0};
    // 每帧封面平均上传次数（EMA，千分整数发布）。用整数原子避免 std::atomic<double>
    // 在 32 位目标上退化成锁；performance() 再除以 1000 还原。
    std::atomic<quint64> m_coverUploadsPerFrameMilli{0};
    // 写侧只在渲染线程累加，读侧不直接碰它。
    double m_coverUploadsEma = 0.0;
    // 预算告警只打一次：这个开关是诊断用的，每帧刷屏会淹没真正要看的日志。
    std::atomic<bool> m_budgetWarned{false};
    void noteFrameLedger(quint64 resources, quint64 bindings, quint64 textureBytes,
                         quint64 coverUploads);
    void recomputeLedgerPeaks();
    // RHINE_RESOURCE_BUDGET_MB 解析结果（字节，0=关闭）。缓存成静态量：环境变量在进程
    // 生命周期内不变，每帧重新 getenv 只会给渲染线程添无谓的字符串分配。
    static quint64 resourceBudgetBytes();
    MusicTextures m_musicTextures;
    // B01：冷纹理准入。判定在纯逻辑类里（可离线测），定时器只负责到点喊一声。
    // 计时基准是构造时启动的单调时钟，与帧号无关——引擎休眠不出帧时定时器照样到期。
    RhineRender::MusicTextureAdmission m_admission = RhineRender::MusicTextureAdmission::fromEnvironment();
    RhineRender::AdmissionScheduler m_admissionScheduler;
    // 已 arm 的焦点代号：同一 key 的重复帧不能反复 start，否则到期时间被无限推后。
    quint64 m_admissionArmed = 0;
    void submitTextureAdmission(const QString &musicKey);
    Glyphs m_glyphs;
    QTimer timer, mediaTimer;
    bool m_started = false;
    bool m_visible = true;
    bool m_sleeping = false;
    bool m_sceneSleeping = false;
    bool m_pointerPending = false;
    bool m_pressed = false;
    bool m_wheelPending = false;
    double m_pointerX = 0;
    double m_pointerY = 0;
    double m_wheelX = 0;
    double m_wheelY = 0;
    double m_wheelDelta = 0;
    double m_wheelSteps = 0;
    double m_wheelDistance = 0;
    // 鼠标滚轮一格的距离，按帧衰减送入，触控板不经过这里。
    double m_wheelRemainingDistance = 0;
    qint64 m_lastTick = 0, m_lastInput = 0;
    // 节拍诊断（RHINE_PACE_DIAG=1）：tick 间隔与 step 耗时的累计量。
    qint64 m_paceEnterNs = 0, m_paceGapSum = 0, m_paceGapMax = 0;
    qint64 m_paceStepSum = 0, m_paceStepMax = 0;
    int m_paceTicks = 0;
    double m_animationTime = 0;
    double m_discAngle = 0;
    double m_discTime = 0;
    bool m_discRotating = false;
    QString m_discIdentity;
    quint64 m_steps = 0, m_sceneUpdates = 0, m_hudUpdates = 0;
    int m_stableFrames = 0;
    int m_temporalFramesRemaining = 0;
    // FSR3 亚像素抖动：默认关闭；开启后每帧推进一个相位，重置时归零。
    bool m_jitterEnabled = false;
    int m_jitterPhase = 0;
    QPointF m_jitterOffset;
    bool m_temporalResetPending = false;
    QJsonObject m_sceneSignature;
    SceneDrawBuffers m_previousBuffers;
    void tick();
    void flushPointer();
    void pollMedia();
    void refreshPlayback();
    QElapsedTimer clock;
    double m_width = 1280;
    double m_height = 720;
    QVariantMap m_state;
    QVariantList m_hits;
    QJsonObject m_frame, m_current;
    QJsonArray m_commands;
    QPointer<QWindow> m_window;
    QWindow::Visibility m_windowedVisibility = QWindow::Windowed;
    QString m_loginMethod;
    QString m_cover;
    QImage m_coverImage;
    qint64 m_coverRevision = 0;
};
