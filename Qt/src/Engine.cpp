#include "Engine.h"
#include "DiscGeometry.h"
#include "RhiScene.h"
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
bool runGpuReferenceCheck(const QImage &expected, const QImage &actual);

/** 建立纯原生音乐、HUD 和场景状态；Qt 定时器只在输入或动画尚未收束时运行。 */
Engine::Engine(QString path, bool offline, QObject *parent)
    : QObject(parent), host(path, offline), scene(path), m_glyphs(path) {
    // FSR3 抖动默认关闭；环境变量在进程启动时读取一次，运行期不再变化。
    m_jitterEnabled = qEnvironmentVariableIntValue("RHINE_JITTER") == 1;
    const auto content = QJsonDocument::fromJson(host.read("slots.json").toUtf8()).object();
    app = std::make_unique<NativeApplication>(&host, &m_glyphs, &scene, content);
    connect(&app->music, &MusicLibrary::playbackInvalidated, this, &Engine::refreshPlayback);
    connect(&app->hud, &NativeHud::localImportRequested, this, &Engine::localImportRequested);
#ifdef Q_OS_MACOS
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
    connect(&host, &Host::invalidated, this, [this] { wake(false); });
    connect(&host, &Host::mediaChanged, this, &Engine::pollMedia, Qt::QueuedConnection);
    connect(&host, &Host::mediaAction, this, [this](QString value) {
        app->mediaAction(value);
        wake();
    });
    clock.start();
    timer.setTimerType(Qt::PreciseTimer);
    connect(&timer, &QTimer::timeout, this, &Engine::tick);
    mediaTimer.setInterval(1000);
    connect(&mediaTimer, &QTimer::timeout, this, &Engine::pollMedia);
    // 节拍诊断（RHINE_PACE_DIAG=1）：每秒打印一次「引擎 tick 数 vs 实际渲染数」，
    // 用来判定帧率是被引擎定时器限住、还是被呈现侧限住。
    if (qEnvironmentVariableIsSet("RHINE_PACE_DIAG")) {
        auto *diag = new QTimer(this);
        diag->setInterval(1000);
        connect(diag, &QTimer::timeout, this, [this] {
            static quint64 lastSteps = 0, lastScene = 0, lastHud = 0, lastRender = 0;
            const quint64 render = m_renderFrames.load(std::memory_order_relaxed);
            const double avgGap = m_paceTicks > 1 ? double(m_paceGapSum) / (m_paceTicks - 1) / 1e6 : 0;
            const double avgStep = m_paceTicks > 0 ? double(m_paceStepSum) / m_paceTicks / 1e6 : 0;
            qInfo("节拍诊断: tick/s=%llu sceneUpd/s=%llu hudUpd/s=%llu render/s=%llu "
                  "interval=%dms timerActive=%d sleeping=%d sceneSleeping=%d rotating=%d "
                  "hudAnimating=%d | 间隔均=%.2fms 最大=%.2fms step均=%.2fms 最大=%.2fms",
                  qulonglong(m_steps) - lastSteps, qulonglong(m_sceneUpdates) - lastScene,
                  qulonglong(m_hudUpdates) - lastHud, qulonglong(render) - lastRender, timer.interval(),
                  int(timer.isActive()), int(m_sleeping), int(m_sceneSleeping), int(m_discRotating),
                  int(app->hud.animating(m_animationTime)), avgGap, double(m_paceGapMax) / 1e6, avgStep,
                  double(m_paceStepMax) / 1e6);
            lastSteps = qulonglong(m_steps);
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
    return {{"idle", m_sleeping},
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
}
/** 仅在画面变化时通知唯一场景，静止时保留按需休眠。 */
void Engine::notifySceneRenderers(bool visualChanged) {
    if (visualChanged) {
        emit sceneUpdated();
    }
}
void Engine::wake(bool input) {
    const bool wasSleeping = m_sleeping;
    const auto now = clock.elapsed();
    if (input) {
        m_lastInput = now;
        m_sceneSleeping = false;
        m_stableFrames = 0;
        scene.energyIdle(false);
    } else if (scene.changed()) {
        m_sceneSleeping = false;
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
void Engine::setVisible(bool value) {
    if (m_visible == value) {
        return;
    }
    m_visible = value;
    if (!value) {
        flushPointer();
        app->pointer("pointercancel", 0, 0);
        m_pressed = m_wheelPending = false;
        m_wheelDelta = m_wheelSteps = 0;
        m_wheelDistance = 0;
        m_wheelRemainingDistance = 0;
        timer.stop();
        m_sleeping = true;
    } else {
        host.restoreMemoryBudget();
#ifdef Q_OS_MACOS
        if (renderConfiguration.snapshot().temporal()) {
            resetTemporalState();
        }
#endif
        wake(false);
        notifySceneRenderers(true);
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
    // 排障/回归：冻结动画时钟，让两次抓图处于完全相同的动画相位。
    if (!qEnvironmentVariableIsSet("RHINE_FREEZE_TIME")) {
        m_animationTime += qMin<qint64>(now - m_lastTick, 50) / 1000.;
    }
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
    // 动态帧间隔：不设固定周期常数，帧率上限完全交给呈现侧（垂直同步/缓冲回收）。
    // 用本帧实测的「呈现阻塞时长」决定要不要让出时间：
    //   · 阻塞 > 2ms：呈现自己就在限速，连轴转（0ms），不额外加延迟；
    //   · 阻塞 ≤ 2ms：说明呈现不阻塞，继续连轴转只会空转烧 CPU，让出 1ms。
    // RHINE_TICK_MS 仍可作为排障时人为压帧的覆盖值（>0 时生效）。
    const qint64 frameNs = clock.nsecsElapsed() - enterNs;
    const qint64 blockedNs = frameNs - stepNs;
    const int fixedMs = frameIntervalMs();
    const bool rotationOnly = m_discRotating && m_sceneSleeping && !app->hud.animating(m_animationTime) &&
                              now - m_lastInput >= 750 && !m_pressed;
    int intervalMs = blockedNs > 2000000 ? 0 : 1;
    if (rotationOnly) {
        intervalMs = 33;
    }
    timer.setInterval(fixedMs > 0 ? fixedMs : intervalMs);
    // 排障专用：RHINE_DIAG_ANIMATE=1 时永不休眠。静止场景下引擎会主动休眠、
    // presented 不再增长，那时测出来的"帧率"是没有负载的数字，A/B 对比没有意义。
    static const bool forceAnimate = qEnvironmentVariableIsSet("RHINE_DIAG_ANIMATE");
    if (!forceAnimate && now - m_lastInput >= 750 && !m_pressed && m_sceneSleeping && !scene.changed() &&
        !app->hud.animating(m_animationTime) && !m_discRotating && m_frame["mode"] != "boot" &&
        m_temporalFramesRemaining == 0) {
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
void Engine::step(double time) {
    if (!ready()) {
        return;
    }
    QElapsedTimer frameTimer;
    if (scene.isProfiling()) {
        frameTimer.start();
        // 复用睡眠场景的帧不能沿用上次模拟耗时，否则现场日志会误报瓶颈。
        scene.timings = {};
    }
    ++m_steps;
    const bool reuse = m_sceneSleeping && !scene.changed();
    const auto object = app->step(time, m_width / (m_height / 1080), reuse);
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
#ifdef Q_OS_MACOS
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
    const auto identity = MusicPlayer::identity(player.current);
    if (identity != m_discIdentity) {
        m_discIdentity = identity;
        m_discAngle = 0;
    }
    const bool wasRotating = m_discRotating;
    m_discRotating = m_visible && app->hud.discRotation && !app->hud.reduced && app->hud.modal.isEmpty() &&
                     m_frame.value("mode") == "detail" && !m_frame.value("viewer").toBool() &&
                     current["kind"] == "song" && MusicPlayer::identity(current) == identity &&
                     !player.loading && !player.failed && player.state["playing"].toBool();
    if (wasRotating && m_discRotating) {
        // 20 秒一圈；接续可见视觉时钟，暂停或隐藏期间不补转。
        m_discAngle = std::fmod(m_discAngle + std::clamp(time - m_discTime, 0., .05) *
                                                  (2 * 3.14159265358979323846 / 20),
                                2 * 3.14159265358979323846);
    }
    m_discTime = time;
    const bool showDiscAngle = current["kind"] == "song" && MusicPlayer::identity(current) == identity;
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
    auto commands = object["commands"].toArray();
    if (commands != m_commands) {
        m_commands = commands;
        ++m_hudUpdates;
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
}
void Engine::snapshot(QString path) {
    if (m_frame.isEmpty()) {
        return;
    }
    QDir().mkpath(path);
    // 排障：允许按窗口尺寸生成参考图，便于与 GPU 输出（qt-window.png）同尺寸逐像素对比。
    QSize size(1920, 1080);
    // 排障：按指定尺寸生成参考图，便于与 GPU 输出（qt-window.png）同尺寸对比。
    if (qEnvironmentVariableIsSet("RHINE_REFERENCE_W") && qEnvironmentVariableIsSet("RHINE_REFERENCE_H")) {
        size = QSize(qEnvironmentVariableIntValue("RHINE_REFERENCE_W"),
                     qEnvironmentVariableIntValue("RHINE_REFERENCE_H"));
    }
#ifdef Q_OS_MACOS
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
    if (qEnvironmentVariableIntValue("RHINE_GPU_TEST") == 1) {
        const QSize size(960, 540);
        const auto actual =
            renderReference(root(), m_frame, m_current, host.image(m_cover), size, scene.drawBuffers);
        const auto original =
            renderReference(root(), legacy, m_current, host.image(m_cover), size, scene.drawBuffers);
        ok &= runGpuReferenceCheck(original, actual);
        if (!ok) {
            qCritical() << "Native GPU frame differs from original fixture";
        }
    }
    qInfo() << "Qt native scene, Host, music, playback and offline package checks:"
            << (ok ? "passed" : "FAILED");
    return ok ? 0 : 1;
}

int Engine::renderFixtures(QString source, QString output) {
    for (const auto &name : QDir(source).entryList({"*.json"}, QDir::Files, QDir::Name)) {
        QFile input(source + "/" + name);
        if (!input.open(QIODevice::ReadOnly)) {
            return 1;
        }
        const auto fixture = QJsonDocument::fromJson(input.readAll()).object();
        const auto store = fixture["store"].toObject();
        const auto settings = fixture["hud"].toObject();
        app->music.current = store["current"].toObject();
        const auto lists = store["lists"].toArray();
        const auto totals = store["totals"].toArray();
        const auto more = store["hasMore"].toArray();
        for (int lane = 0; lane < 5; ++lane) {
            app->music.lists[lane] = lists.at(lane).toArray();
            app->music.totals[lane] = totals.at(lane).toInt();
            app->music.hasMore[lane] = more.at(lane).toBool();
        }
        app->music.keyword = store["keyword"].toString();
        app->music.status = store["status"].toString();
        app->hud.modal = settings["modal"].toString();
        app->hud.dark = settings["dark"].toBool();
        app->hud.themeMode = settings["themeMode"].toString();
        app->hud.reduced = settings["reduced"].toBool();
        app->hud.motion.set(true, 0, true);
        m_frame = fixture["frame"].toObject();
        app->hud.draw(m_frame, 1920, 50);
        m_commands = app->hud.commands;
        m_current = app->music.current;
        m_cover.clear();
        m_coverImage = QImage();
        const auto folder = output + "/" + fixture["name"].toString();
        snapshot(folder);
        QFile hitsFile(folder + "/qt-hits.json");
        if (hitsFile.open(QIODevice::WriteOnly)) {
            hitsFile.write(QJsonDocument(app->hud.hits).toJson());
        }
    }
    return failure.isEmpty() ? 0 : 1;
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
