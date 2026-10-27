#pragma once
#include "Glyphs.h"
#include "Host.h"
#include "NativeApplication.h"
#ifdef Q_OS_MACOS
#include "render/RenderConfiguration.h"
#include "fg/FgFrameTap.h"
#endif
#include <QElapsedTimer>
#include <QPointF>
#include <QVariantMap>
#include <QUrl>
#include <QQuickWindow>
#include <QPointer>
#include <atomic>
class Engine : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap state READ state NOTIFY stateChanged)
    Q_PROPERTY(QVariantList hits READ hits NOTIFY hitsChanged)
    Q_PROPERTY(QVariantMap performance READ performance NOTIFY stateChanged)
  public:
    Engine(QString root, bool offline = false, QObject *parent = nullptr);
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
    /** 只读的偏好访问：渲染侧据此解析 Filament 开关（离线/自检时 Host 会返回空）。 */
    QString preference(const QString &key) const {
        return host.preference(key);
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
    };
    using MusicTextures = QHash<QString, MusicTexture>;
    MusicTextures musicTextures() const {
        return m_musicTextures;
    }
    void trimMemory();
#ifdef Q_OS_MACOS
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
    void wake(bool input = true);
    void start();
    void recordRender(quint64 resources, quint64 bindings = 0, quint64 textureBytes = 0,
                      quint64 coverUploads = 0, quint64 drawCalls = 0) {
        m_renderFrames.fetch_add(1, std::memory_order_relaxed);
        m_gpuResources.store(resources, std::memory_order_relaxed);
        m_bindingCreations.fetch_add(bindings, std::memory_order_relaxed);
        m_musicTextureBytes.store(textureBytes, std::memory_order_relaxed);
        m_coverUploads.fetch_add(coverUploads, std::memory_order_relaxed);
        m_lastDrawCalls.store(drawCalls, std::memory_order_relaxed);
    }
    bool ready() const;
    int selfTest();
    int renderFixtures(QString source, QString output);
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
    quint64 m_geometryRevision = 0;
    std::atomic<quint64> m_renderFrames{0}, m_gpuResources{0};
    std::atomic<quint64> m_bindingCreations{0};
    std::atomic<quint64> m_musicTextureBytes{0};
    std::atomic<quint64> m_coverUploads{0};
    std::atomic<quint64> m_lastDrawCalls{0};
    MusicTextures m_musicTextures;
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
