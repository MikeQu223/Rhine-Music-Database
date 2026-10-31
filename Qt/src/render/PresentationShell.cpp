#include <QtGlobal>
#include "PresentationShell.h"
#ifdef Q_OS_DARWIN
#include "MetalFxBackend.h"
#endif

#include "../fg/FgBackend.h"
#include "../fg/FgCapability.h"
#include "../fg/FgConfig.h"
#include "../fg/FgFrameTap.h"
#include "PresentationWindow.h"
#include "SceneLayerHost.h"

#include "../Engine.h"

#include <QCoreApplication>
#include <QDebug>
#include <QElapsedTimer>
#include <QEvent>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QHoverEvent>
#include <QList>
#include <QMatrix4x4>
#include <QMouseEvent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTimer>
#include <QWheelEvent>
#include <QWindow>

#include <rhi/qrhi.h>
#include <rhi/qrhi_platform.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace {

// 合成通道的 uniform：clipSpaceCorrMatrix（64）+ params vec4（16）。
constexpr int kFgUniformSize = 64 + 16;
#ifdef Q_OS_LINUX

// 看门狗：连续跳过这么多步就强制两层重渲一次。按 60Hz 约半秒。
// 场景里出现"没人标脏但画面该变"的路径（新加的 QML 自驱更新、Qt 信号时序变化）时，
// 缺了它会永久冻住画面，而 CPU 很低、日志写着"正常跳过"，看起来像优化成功。
constexpr int kSkipWatchdogSteps = 30;
#endif

QShader loadShader(const QString &name) {
    QFile f(":/shaders/" + name + ".qsb");
    if (!f.open(QIODevice::ReadOnly)) {
        qWarning() << "FG: 缺少着色器" << name;
        return {};
    }
    return QShader::fromSerialized(f.readAll());
}

quint64 bindingKey(const QRhiTexture *a, const QRhiTexture *b) {
    return (quint64(quintptr(a)) * 0x9E3779B97F4A7C15ull) ^ quint64(quintptr(b));
}

/// 已排序样本取分位。呈现间隔（gapP*）与 A02 的 begin/end 分位共用同一套取整规则，
/// 避免两处"分位"因为四舍五入/向下取整不同而对不上。
double sortedQuantile(const QList<double> &sorted, double quantile) {
    const int last = sorted.size() - 1;
    const int index = std::clamp(int(std::lround(quantile * last)), 0, last);
    return sorted.at(index);
}

} // namespace

PresentationShell::PresentationShell(QQmlEngine &engine, Engine &backend, QString backendName,
                                     QObject *parent)
    : QObject(parent), m_quitTransition(
                           [this] {
                               shutdown();
                               QCoreApplication::quit();
                           },
                           this),
      m_engine(&engine), m_backend(&backend), m_backendName(std::move(backendName)) {
}

/** QML 快捷键与原生关闭统一等待当前回调返回，避免退出时删除正在执行的信号对象。 */
void PresentationShell::requestQuit() {
    if (m_quitRequested || m_stopped) {
        return;
    }
    m_quitRequested = true;
    if (m_timer) {
        m_timer->stop();
    }
    if (m_releaseTimer) {
        m_releaseTimer->stop();
    }
#ifdef Q_OS_WIN
    // 隐藏只改变可见性，原生窗口与 Vulkan surface 必须保留到交换链清理完成。
    if (m_window) {
        m_window->hide();
    }
#endif
    m_quitTransition.request();
}

/** 停调度并按 GPU 引用顺序释放资源；原生窗口留到析构，避免在自身事件处理中销毁。 */
void PresentationShell::shutdown() {
    m_quitTransition.cancel();
    if (m_stopped) {
        return;
    }
    m_stopped = true;
    if (m_timer) {
        m_timer->stop();
    }
    if (m_releaseTimer) {
        m_releaseTimer->stop();
    }
    RhineFg::setEnabled(false);
#ifdef Q_OS_DARWIN
    m_backend->metalFxInputs = {};
#endif
    if (m_rhi) {
        m_rhi->finish();
    }
    releaseSwapchainResources();
    m_fg.reset();
    // 离屏 QML 即将销毁，先断开更新与输入法焦点，避免清理期间重新访问旧宿主。
    m_backend->disconnect(this);
    // 把平台输入法接到离屏输入项上
    if (auto *inputWindow = qobject_cast<RhineRender::PresentationWindow *>(m_window)) {
        inputWindow->setInputWindow(nullptr);
    }
    m_host.reset();
    delete m_pipelineBindings;
    m_pipelineBindings = nullptr;
    for (auto *resource : std::as_const(m_ownedResources)) {
        delete resource;
    }
    m_ownedResources.clear();
    if (m_presenter) {
        m_presenter->release();
    }
    RhineFg::clear();
    m_backend->setWindow(nullptr);
    m_engine->rootContext()->setContextProperty(QStringLiteral("rhineHostWindow"),
                                                QVariant::fromValue(static_cast<QWindow *>(nullptr)));
}

PresentationShell::~PresentationShell() {
    shutdown();
    m_presenter.reset();
}

bool PresentationShell::compiledIn() {
#if defined(Q_OS_DARWIN) && __has_include(<MetalFX/MTLFXFrameInterpolator.h>)
    return true;
#elif defined(RHINE_FSR3_VULKAN) && RHINE_FSR3_VULKAN
    return FgBackend::compiledIn();
#else
    return false;
#endif
}

bool PresentationShell::supportsBackend(const QString &name) {
#if QT_CONFIG(metal)
    if (name == QLatin1String("metal")) {
        return true;
    }
#endif
#if defined(RHINE_VULKAN_PRESENTATION) && RHINE_VULKAN_PRESENTATION
    return name == QLatin1String("vulkan");
#else
    Q_UNUSED(name);
    return false;
#endif
}

bool PresentationShell::requested() const {
#ifdef Q_OS_DARWIN
    return m_backend->renderConfiguration.snapshot().interpolation;
#else
    return FgConfig::fromEnvironment().enabled;
#endif
}

QWindow *PresentationShell::window() const {
    return m_window;
}

QString PresentationShell::resolveQmlUrl(const QString &file) const {
    // qt_add_qml_module 的默认资源前缀是 /qt/qml；也兼容直接以 URI 命名的老布局。
    const QStringList candidates{
        QStringLiteral("qrc:/qt/qml/RhineMusic/") + file,
        QStringLiteral("qrc:/RhineMusic/") + file,
        QStringLiteral("qrc:/") + file,
    };
    for (const auto &candidate : candidates) {
        if (QFileInfo::exists(candidate)) {
            return candidate;
        }
    }
    return candidates.first();
}

bool PresentationShell::initializeBackend() {
    m_presenter = RhineRender::createPresentationBackend(m_backendName);
    if (!m_presenter || !m_presenter->initialize(m_size, FgConfig::fromEnvironment().vsync)) {
        m_error = m_presenter ? m_presenter->lastError() : QStringLiteral("当前呈现后端未编入");
        return false;
    }
    m_window = m_presenter->window();
    m_rhi = m_presenter->rhi();
    m_window->installEventFilter(this);
    m_size = m_window->size();
    return true;
}

bool PresentationShell::initializeLayers() {
    // Overlay.qml 的窗口行为（拖动/最大化/关闭/全屏）原来由 Main.qml 的 Window 提供；
    // FG 路径没有那个 Window，改为把真实的 QWindow 注入上下文。
    m_engine->rootContext()->setContextProperty(QStringLiteral("rhineHostWindow"),
                                                QVariant::fromValue(m_window));

    m_host = std::make_unique<SceneLayerHost>();
    m_host->requestRender = [this] { scheduleNext(); };
    if (!m_host->start(*m_engine, QUrl(resolveQmlUrl(QStringLiteral("Scene3D.qml"))),
                       QUrl(resolveQmlUrl(QStringLiteral("Overlay.qml"))), m_rhi,
                       m_presenter->vulkanInstance(), m_window)) {
        m_error = QStringLiteral("离屏场景建立失败：%1").arg(m_host->lastError());
        return false;
    }
    m_host->resize(m_size);
    // 纹理按物理尺寸分配；Qt Quick 的排版和输入始终保持逻辑像素。
    m_dpr = m_window->devicePixelRatio();
    m_windowDpr = m_dpr;
    m_host->setPixelRatio(m_dpr);
    // 键盘链路的第一环：焦点。
    //
    // 默认路径靠 Main.qml 的 Component.onCompleted → overlay.focusInputLayer() 把焦点
    // 交给 Overlay 里的 inputLayer；FG 路径不加载 Main.qml，没人做这件事。而
    // QQuickRenderControl 的离屏窗口没有平台窗口、永远不会被激活，Qt 也不会像真实
    // 窗口那样在激活时自动传播 activeFocus——实测此时 window.activeFocusItem() 为
    // null，QQuickWindow 收到 KeyPress 后无处投递，按键被直接丢弃。
    // 显式恢复当前面板的焦点；重建后可能仍在搜索框，不能统一交回快捷键层。
    if (QQuickItem *overlayRoot = m_host->overlayRootItem()) {
#ifdef Q_OS_WIN
        const bool focused =
            QMetaObject::invokeMethod(overlayRoot, "restoreInputFocus", Qt::DirectConnection);
#else
        const bool focused = QMetaObject::invokeMethod(overlayRoot, "focusInputLayer", Qt::DirectConnection);
#endif
        QQuickItem *focusItem = m_host->overlayWindow()->activeFocusItem();
        qInfo().noquote() << "FG: 覆盖层输入焦点" << (focused && focusItem ? "已建立" : "未建立")
                          << "activeFocusItem:"
                          << (focusItem ? focusItem->metaObject()->className() : "null");
    }
    // 把平台输入法接到离屏输入项上
    if (auto *inputWindow = qobject_cast<RhineRender::PresentationWindow *>(m_window)) {
        inputWindow->setInputWindow(m_host->overlayWindow());
    }
    // 只在这里打开每帧输入通道：RhiScene 的渲染器只在 tap 打开时才发布。
#ifdef Q_OS_DARWIN
    // Main.qml 未加载时仍需接上原窗口的资源统计清理，否则隐藏后会残留旧计数。
    QObject::connect(
        m_host->sceneWindow(), &QQuickWindow::sceneGraphInvalidated, m_backend,
        [this] { m_backend->recordResourceRelease(); }, Qt::DirectConnection);
    const bool temporalAvailable = RhineRender::MetalFxTemporal::supported(m_rhi);
    m_backend->renderConfiguration.setNativeTemporalAvailable(temporalAvailable);
    RhineFg::capabilityMutable().temporalAvailable = temporalAvailable;
    m_fg = RhineRender::createMetalFxFrameGenerator(m_rhi);
    m_fgAvailable = bool(m_fg);
#else
    m_fgAvailable = FgBackend::supported(m_rhi);
    if (m_fgAvailable) {
        m_fg = std::make_unique<FgBackend>();
    }
#endif
#ifdef Q_OS_DARWIN
    RhineFg::setEnabled(false);
    m_backend->metalFxInputs = {};
#else
    RhineFg::setEnabled(m_fgAvailable);
#endif
    return true;
}

QSize PresentationShell::pixelSize() const {
    return QSize(qMax(1, qRound(m_size.width() * m_dpr)), qMax(1, qRound(m_size.height() * m_dpr)));
}

bool PresentationShell::ensureCompositeResources() {
    if (m_compositeUbo && m_sampler) {
        return true;
    }

    if (!loadShader(QStringLiteral("fgComposite.vert")).isValid() ||
        !loadShader(QStringLiteral("fgComposite.frag")).isValid()) {
        m_error = QStringLiteral("fgComposite 着色器缺失");
        return false;
    }

    m_compositeUbo = m_rhi->newBuffer(QRhiBuffer::Dynamic, QRhiBuffer::UniformBuffer, kFgUniformSize);
    if (!m_compositeUbo->create()) {
        m_error = QStringLiteral("合成 uniform 缓冲创建失败");
        return false;
    }
    m_ownedResources.append(m_compositeUbo);

    m_sampler = m_rhi->newSampler(QRhiSampler::Linear, QRhiSampler::Linear, QRhiSampler::None,
                                  QRhiSampler::ClampToEdge, QRhiSampler::ClampToEdge);
    if (!m_sampler->create()) {
        m_error = QStringLiteral("合成采样器创建失败");
        return false;
    }
    m_ownedResources.append(m_sampler);

    // 管线只需要一份"形状正确"的 SRB 表达绑定布局；逐帧真正用的 SRB 由
    // bindingsFor() 按输入纹理缓存，布局一致所以共用同一条管线。
    // 1×1 占位纹理：管线必须在"布局已确定"的 SRB 上创建，而布局要求绑定真实资源。
    m_pipelineBase = m_rhi->newTexture(QRhiTexture::RGBA8, QSize(1, 1));
    if (!m_pipelineBase->create()) {
        m_error = QStringLiteral("合成占位纹理创建失败");
        return false;
    }
    m_ownedResources.append(m_pipelineBase);

    m_pipelineBindings = m_rhi->newShaderResourceBindings();
    m_pipelineBindings->setBindings({
        QRhiShaderResourceBinding::uniformBuffer(
            0, QRhiShaderResourceBinding::VertexStage | QRhiShaderResourceBinding::FragmentStage,
            m_compositeUbo),
        QRhiShaderResourceBinding::sampledTexture(1, QRhiShaderResourceBinding::FragmentStage, m_pipelineBase,
                                                  m_sampler),
        QRhiShaderResourceBinding::sampledTexture(2, QRhiShaderResourceBinding::FragmentStage, m_pipelineBase,
                                                  m_sampler),
    });
    if (!m_pipelineBindings->create()) {
        m_error = QStringLiteral("合成模板 SRB 创建失败");
        return false;
    }
    return true;
}

QRhiShaderResourceBindings *PresentationShell::bindingsFor(QRhiTexture *base, QRhiTexture *overlay) {
    const quint64 key = bindingKey(base, overlay);
    if (auto it = m_bindingCache.constFind(key); it != m_bindingCache.constEnd()) {
        return *it;
    }

    auto *srb = m_rhi->newShaderResourceBindings();
    srb->setBindings({
        QRhiShaderResourceBinding::uniformBuffer(
            0, QRhiShaderResourceBinding::VertexStage | QRhiShaderResourceBinding::FragmentStage,
            m_compositeUbo),
        QRhiShaderResourceBinding::sampledTexture(1, QRhiShaderResourceBinding::FragmentStage, base,
                                                  m_sampler),
        QRhiShaderResourceBinding::sampledTexture(2, QRhiShaderResourceBinding::FragmentStage, overlay,
                                                  m_sampler),
    });
    if (!srb->create()) {
        delete srb;
        return nullptr;
    }
    m_bindingCache.insert(key, srb);
    return srb;
}

bool PresentationShell::ensureSwapchainResources() {
    return m_presenter && m_presenter->ready();
}

void PresentationShell::releaseSwapchainResources() {
    delete m_pipeline;
    m_pipeline = nullptr;
    for (auto *binding : std::as_const(m_bindingCache)) {
        delete binding;
    }
    m_bindingCache.clear();
}

bool PresentationShell::recreateSwapchain() {
    // 强制重建：OutOfDate 的交换链即使窗口尺寸没变也已经不可用，不能走 resize() 里
    // "尺寸没变就返回"的捷径——以前就是被这条捷径吞掉，acquire 于是永远 OutOfDate。
    if (!m_presenter->resize(pixelSize(), true)) {
        m_error = QStringLiteral("交换链重建失败：%1").arg(m_presenter->lastError());
        return false;
    }
    // 重建能救活的情况：重建后马上有新帧上屏（presentOne 成功会清零这个计数）。
    // 救不活的情况：连续重建却一帧都上不去——那就是设备根本不能向这个 surface
    // 呈现（典型是没有直连显示输出的独显），继续重建只会白等 GPU 空闲，直接判死。
    if (++m_recreateStreak > 5) {
        m_failed = true;
        m_error =
            QStringLiteral("呈现层连续 %1 次重建都没有新帧上屏，判定这台设备无法呈现").arg(m_recreateStreak);
        return false;
    }
    m_needRecreate = false;
    // 重建后必须把"跨尺寸的旧状态"全部作废，否则第一帧就是垃圾：
    //   · m_pendingRealFrame：排队的那帧是按**旧尺寸**插出来的，贴到新交换链上
    //     就是满屏错色（实测每次 resize 后第一帧亮度从 71 跳到 131/136 再回落，
    //     用户看到的就是"改窗口大小闪一下"）；
    //   · 插值历史：上一对帧属于旧尺寸，跨尺寸插值没有意义，先复位成纯真实帧。
    m_pendingRealFrame = false;
    m_forcePresent = true;
    m_framesSinceRecreate = 0;
    if (m_fg) {
        m_fg->requestReset();
    }
    releaseSwapchainResources();
    return ensureSwapchainResources();
}

void PresentationShell::syncSizes() {
    // 设备像素比会在窗口被拖到另一块屏幕、或系统缩放变化时改变。
    // 它一变，交换链和离屏纹理的目标尺寸都变了，必须重建，否则会出现
    // "画面只占左上角一块"（纹理偏大）或"整体糊一层"（纹理偏小）。
    if (m_host && m_window) {
        const qreal windowDpr = m_window->devicePixelRatio();
        if (!qFuzzyCompare(windowDpr, m_windowDpr)) {
            m_windowDpr = windowDpr;
            m_dpr = windowDpr;
            m_host->setPixelRatio(m_dpr);
            m_needRecreate = true;
            m_forcePresent = true;
            qInfo().noquote() << "FG: 窗口设备像素比" << windowDpr << "离屏层实际比例" << m_dpr << "物理像素"
                              << pixelSize();
        }
    }
    const QSize windowSize = m_window->size();
    if (windowSize.isEmpty()) {
        return;
    }
    if (windowSize != m_size) {
        m_size = windowSize;
        m_host->resize(m_size);
        // 交换链是应用自己持有的，尺寸变了必须显式重建。
        m_needRecreate = true;
    }
    // 每帧都把真实窗口尺寸推给 Engine，不能只在"尺寸变化"时推。
    //
    // 为什么：FG 路径没有 Main.qml 的 Window（它的 onWidthChanged → rhine.resize()），
    // 而 Engine 默认停在 1280x720，HUD 舞台宽度是 width/(height/1080)=1920。而
    // initializeBackend() 在 show() 之后就已经把 m_size 读成真实尺寸（如 1262x1370）
    // 了，于是第一次 step() 时 windowSize == m_size，"尺寸没变"——同步永远不发生，
    // Engine 一直按 1920 的逻辑宽度布局 HUD：导航、歌曲列表、Tab Mode/COLLECTION、
    // 弹窗右列、播放条右半边这些按 width 相对定位的内容全被画到离屏层外面，看起来
    // 就是"UI 少了一整块"；同时 fit() 不再截断，文字也变长。
    // Engine::resize() 对相同尺寸会早退，所以这里每帧调用没有额外开销。
    m_backend->resize(m_size.width(), m_size.height());
    // GPU 侧的尺寸确认（只确认、不重建）：m_needRecreate 为真时下一步会走
    // recreateSwapchain()，只有那里才允许真正重建——它会作废跨尺寸的插值历史并强制
    // 重画一帧，抢在这里重建就会拿到按旧尺寸插出来的帧（画面闪一下）。所以这里只在
    // "没有待重建"且 presenter 的交换链尺寸已等于目标尺寸时把请求推下去；后端在这种
    // 情况下只做尺寸比较（A10 的 resizeSkips），一次 finish 都不会发生。
    // 这一句同时是"去重生效"在 CSV 里的证据：跳过数应随帧数增长，设备等待数不增长。
    if (m_presenter && !m_needRecreate && m_presenter->extent() == pixelSize()) {
        m_presenter->resize(pixelSize(), false);
    }
}

const RhineFg::FrameInputs &PresentationShell::currentFrameInputs() const {
#ifdef Q_OS_DARWIN
    return m_backend->metalFxInputs;
#else
    return RhineFg::latest();
#endif
}

bool PresentationShell::armFrameGeneration() {
    if (!m_fg) {
        return false;
    }
    const RhineFg::FrameInputs &inputs = currentFrameInputs();
    if (!inputs.depth || !inputs.motionVectors || inputs.renderSize.isEmpty() ||
        inputs.displaySize.isEmpty()) {
        return false;
    }
    // 只有场景真的重渲了才有新的光流输入；相机参数（列表页与详情页 near/far 不同）
    // 每帧都要写，纹理新鲜度用 serial 判断。
    if (inputs.serial == m_lastTapSerial && m_fg->available()) {
        return m_fgArmed;
    }
    m_lastTapSerial = inputs.serial;

    // 注意：resize() 会销毁/重建 GPU 资源并等设备空闲，必须在任何 QRhi 帧之外调用，
    // 不能在 beginOffscreenFrame 之后——那样会卡死在设备等待上。
    // SceneLayerHost 的场景纹理是 RGBA8（Qt 的渲染目标格式），FG 的三张主纹理格式必须一致，
    // 所以这里显式传 RGBA8，而不是用 FgBackend 的默认 RGBA16F。
    // displaySize 必须是**物理像素**：插帧的输出要直接铺满交换链。若沿用逻辑尺寸，
    // 高 DPI 下 FG 输出小于合成目标，画面会被拉伸而发糊。renderSize 保持原值——
    // 那是运动矢量/深度的分辨率，跟着 3D 渲染尺寸走，与设备像素比无关。
    const QSize fgDisplaySize = pixelSize().isEmpty() ? inputs.displaySize : pixelSize();
    if (!m_fg->resize(m_rhi, inputs.renderSize, fgDisplaySize, QRhiTexture::RGBA8)) {
        return false;
    }
    m_fg->setCamera(inputs.nearPlane, inputs.farPlane, inputs.fovYRadians, inputs.frameTimeMs);
    m_fg->setJitter(float(inputs.jitter.x()), float(inputs.jitter.y()));
    if (inputs.reset) {
        m_fg->requestReset();
    }
    m_fgArmed = true;
    RhineFg::publishCapability(true, true, m_fg->available());
    return true;
}

bool PresentationShell::recordFrameGeneration(QRhiCommandBuffer *cb) {
    if (!m_fg || !m_fgArmed) {
        return false;
    }

    QRhiTexture *color = m_host->sceneTexture();
    cb->beginExternal();
    m_probe.restart();
    // prepare 里跑的是光流（ffxOpticalflowContextDispatch）与深度重建，
    // dispatch 里跑的是帧插值本身——两者的成本差一个数量级，分开计才有诊断价值。
    const bool prepared =
        m_fg->prepare(m_rhi, cb, color, currentFrameInputs().depth, currentFrameInputs().motionVectors);
    m_stats.prepareMs = blend(m_stats.prepareMs, tookMs());
    bool dispatched = false;
    if (prepared) {
        // 3D 层不带 UI，所以"含 UI 的颜色"与"无 UI 的颜色"是同一张：UI 由合成通道
        // 在插值之后单独叠加（UI 不该跟着插值动，否则文字会重影）。
        dispatched = m_fg->dispatch(m_rhi, cb, color, color, nullptr);
        m_stats.dispatchMs = blend(m_stats.dispatchMs, tookMs());
    }
    cb->endExternal();

    if (!dispatched) {
        qWarning().noquote() << "FG:" << m_fg->lastError();
        return false;
    }
    // reset 帧的插值结果不可用（SDK 跳过了准备 pass），这一帧直接呈现当前帧。
    return !m_fg->lastFrameReset();
}

double PresentationShell::tookMs() {
    if (!m_probe.isValid()) {
        return 0.0;
    }
    const double ms = double(m_probe.nsecsElapsed()) / 1e6;
    m_probe.restart();
    return ms;
}

double PresentationShell::blend(double previous, double sample) {
    // 指数滑动平均：单帧耗时会被排队与调度拉出几倍抖动，面板要的是趋势不是尖峰。
    // 前 1/0.15 ≈ 7 帧就能跟上真实水平，切换插值开关后不到 0.15 秒就稳定下来。
    constexpr double kAlpha = 0.15;
    if (previous <= 0.0) {
        return sample;
    }
    return previous * (1.0 - kAlpha) + sample * kAlpha;
}

void PresentationShell::recordGap(double gapMs) {
    m_gapRing[size_t(m_gapCursor)] = gapMs;
    m_gapCursor = (m_gapCursor + 1) % kGapCapacity;
    if (m_gapFilled < kGapCapacity) {
        m_gapFilled++;
    }
    // 每次呈现都排序 600 个数没必要，但要够新：面板每 500ms 采一次样，
    // 每 8 帧刷一次（60Hz 下约 130ms）既保证新鲜，成本也可以忽略。
    if (m_presentedFrames % 8 == 0) {
        refreshGapStats();
    }
}

void PresentationShell::refreshGapStats() {
    if (m_gapFilled < 2) {
        return;
    }
    QList<double> sorted;
    sorted.reserve(m_gapFilled);
    for (int index = 0; index < m_gapFilled; ++index) {
        sorted.append(m_gapRing[size_t(index)]);
    }
    std::sort(sorted.begin(), sorted.end());
    m_stats.gapP50Ms = sortedQuantile(sorted, 0.50);
    m_stats.gapP95Ms = sortedQuantile(sorted, 0.95);
    m_stats.gapP99Ms = sortedQuantile(sorted, 0.99);
    m_stats.gapMaxMs = sorted.last();
    const auto over = [&sorted](double limit) {
        return int(
            std::count_if(sorted.cbegin(), sorted.cend(), [limit](double gap) { return gap > limit; }));
    };
    m_stats.over33 = over(33.0);
    m_stats.over50 = over(50.0);
    m_stats.over100 = over(100.0);
    m_stats.sampleCount = int(sorted.size());
}

void PresentationShell::recordWaitSample(double beginMs, double endMs) {
    m_beginRing[size_t(m_waitCursor)] = beginMs;
    m_endRing[size_t(m_waitCursor)] = endMs;
    m_waitCursor = (m_waitCursor + 1) % kWaitCapacity;
    if (m_waitFilled < kWaitCapacity) {
        ++m_waitFilled;
    }
    // 120 个样本排序成本可以忽略，但仍在每帧热路径上：每 8 个样本刷一次，
    // 面板 500ms 采一次样，约 130ms 的刷新延迟看不出来。
    if ((m_waitSamples % 8) == 0) {
        refreshWaitStats();
    }
    ++m_waitSamples;
}

void PresentationShell::refreshWaitStats() {
    if (m_waitFilled < 2) {
        return;
    }
    QList<double> beginSorted;
    QList<double> endSorted;
    beginSorted.reserve(m_waitFilled);
    endSorted.reserve(m_waitFilled);
    for (int index = 0; index < m_waitFilled; ++index) {
        beginSorted.append(m_beginRing[size_t(index)]);
        endSorted.append(m_endRing[size_t(index)]);
    }
    std::sort(beginSorted.begin(), beginSorted.end());
    std::sort(endSorted.begin(), endSorted.end());
    m_stats.beginP95Ms = sortedQuantile(beginSorted, 0.95);
    m_stats.beginP99Ms = sortedQuantile(beginSorted, 0.99);
    m_stats.endP95Ms = sortedQuantile(endSorted, 0.95);
    m_stats.endP99Ms = sortedQuantile(endSorted, 0.99);
}

void PresentationShell::publishStats(bool interpolatedThisStep) {
    const RhineFg::FrameInputs &inputs = currentFrameInputs();
    m_stats.layerActive = m_started && m_window && m_window->isVisible();
    m_stats.interpolationAvailable = m_fgAvailable;
    m_stats.interpolationWanted = requested();
    m_stats.interpolationActive = interpolatedThisStep;
    m_stats.depthReady = inputs.depth != nullptr;
    m_stats.motionVectorsReady = inputs.motionVectors != nullptr;
    m_stats.presented = m_presentedFrames;
    m_stats.interpolated = m_interpolatedFrames;
    m_stats.rendered = m_renderedFrames;
    m_stats.renderSize = inputs.renderSize;
#ifdef Q_OS_DARWIN
    if (m_stats.renderSize.isEmpty()) {
        const auto telemetry = m_backend->renderTelemetry.snapshot();
        m_stats.renderSize = {telemetry.value("renderWidth").toInt(),
                              telemetry.value("renderHeight").toInt()};
    }
#endif
    m_stats.displaySize = m_presenter ? m_presenter->extent() : QSize();
    m_stats.imageReuseMs = m_presenter ? m_presenter->imageReuseMs() : 0.0;
    // 交换链重建/设备等待/尺寸去重是计数器，每帧都要带上：只靠帧率看不出
    // "这一帧慢是因为又等了 GPU 空闲"，而那正是 A10 要证明的事。
    m_stats.swapchainRecreates = m_presenter ? m_presenter->swapchainRecreates() : 0;
    m_stats.deviceIdleWaits = m_presenter ? m_presenter->deviceIdleWaits() : 0;
    m_stats.resizeSkips = m_presenter ? m_presenter->resizeSkips() : 0;
    // A02：离屏提交按"实际调用"计——呈现层取后端累计数（在真正 begin 成功处 +1），
    // QML 场景层/UI 层由 step() 对 SceneLayerHost 的两个公开计数取差分后累加。
    // 发布值 = 自上次 publishStats 以来发生的 beginFrame/endFrame 对数：正常一帧 3 次
    // （场景层 + UI 层 + 呈现层），空闲跳帧 0 次；失败步的计数顺延到下一次发布。
    const quint64 backendSubmits = m_presenter ? m_presenter->offscreenSubmits() : 0;
    // 没有后端计数器的路径（RhiPresentationBackend 默认返回 0）退回呈现层自己的
    // 成功计数，否则会只剩 QML 的两层、凭空少掉呈现层这一次。
    const quint64 presenterTotal = backendSubmits > 0 ? backendSubmits : m_presenterSubmits;
    // 后端重建会让累计数归零：夹住下溢，宁可在切换那一帧低估，也不要报出一个天文数字。
    const quint64 presenterDelta =
        presenterTotal >= m_lastPresenterSubmits ? presenterTotal - m_lastPresenterSubmits
                                                 : presenterTotal;
    m_lastPresenterSubmits = presenterTotal;
    const quint64 layerDelta = m_layerSubmits - m_lastLayerSubmits;
    m_lastLayerSubmits = m_layerSubmits;
    m_stats.submitsPerFrame = int(presenterDelta + layerDelta);
    ++m_stats.serial;
    RhineFg::publish(m_stats);
}

bool PresentationShell::composite(QRhiCommandBuffer *cb, QRhiTexture *base, QRhiTexture *overlay,
                                  quint32 imageIndex, QRhiRenderTarget *overrideTarget) {
    const RhineRender::PresentationBackend::Frame frame{imageIndex};
    QRhiRenderTarget *target = overrideTarget ? overrideTarget : m_presenter->target(frame);
    if (!target) {
        return false;
    }
    QRhiShaderResourceBindings *srb = bindingsFor(base, overlay);
    if (!srb) {
        return false;
    }

    if (!m_pipeline) {
        m_pipeline = m_rhi->newGraphicsPipeline();
        m_pipeline->setShaderStages({{QRhiShaderStage::Vertex, loadShader("fgComposite.vert")},
                                     {QRhiShaderStage::Fragment, loadShader("fgComposite.frag")}});
        m_pipeline->setVertexInputLayout({});
        m_pipeline->setTopology(QRhiGraphicsPipeline::TriangleStrip);
        m_pipeline->setCullMode(QRhiGraphicsPipeline::None);
        m_pipeline->setDepthTest(false);
        m_pipeline->setShaderResourceBindings(m_pipelineBindings);
        m_pipeline->setRenderPassDescriptor(target->renderPassDescriptor());
        if (!m_pipeline->create()) {
            m_error = QStringLiteral("合成管线创建失败");
            return false;
        }
    }

    QMatrix4x4 correction = m_rhi->clipSpaceCorrMatrix();
    float uniforms[kFgUniformSize / 4] = {};
    std::memcpy(uniforms, correction.constData(), 64);
    // 与 common.glsl 的 rtUV() 同口径：帧缓冲原点在上方时纹理坐标要翻转 v。
    uniforms[16] = m_rhi->isYUpInFramebuffer() ? 1.0f : 0.0f;

    QRhiResourceUpdateBatch *batch = m_rhi->nextResourceUpdateBatch();
    batch->updateDynamicBuffer(m_compositeUbo, 0, kFgUniformSize, uniforms);

    const QSize pixelSize = target->pixelSize();
    cb->beginPass(target, Qt::black, {1.0f, 0}, batch);
    cb->setGraphicsPipeline(m_pipeline);
    cb->setShaderResources(srb);
    cb->setViewport({0, 0, float(pixelSize.width()), float(pixelSize.height())});
    cb->draw(3);
    cb->endPass();

    return overrideTarget || m_presenter->finishTarget(cb, frame);
}

bool PresentationShell::presentOne(const RhineRender::PresentationBackend::Frame &frame,
                                   bool allowInterpolation, bool *interpolatedOut) {
    if (interpolatedOut) {
        *interpolatedOut = false;
    }

    QRhiCommandBuffer *cb = nullptr;
    m_probe.restart();
    m_frameProbe.restart();
    const QRhi::FrameOpResult begun = m_presenter->beginFrame(frame, &cb);
    // A02：beginMs 的语义是"帧槽等待"——beginFrame 要等上一帧的命令缓冲/围栏归还。
    // EMA 只能看趋势，原始样本单独留在 slotWaitMs/分位环里作为证据。
    const double beginSample = tookMs();
    m_stats.beginMs = blend(m_stats.beginMs, beginSample);
    // 后端（Vulkan）在自己真正调用 beginOffscreenFrame 的地方量了一份；负数表示该
    // 后端不提供，退回呈现层的计时（Metal 等路径）。两者差的是虚函数调用开销。
    const double backendSlotWait = m_presenter->slotWaitMs();
    m_stats.slotWaitMs = backendSlotWait >= 0.0 ? backendSlotWait : beginSample;
    if (begun != QRhi::FrameOpSuccess) {
        m_error = QStringLiteral("beginOffscreenFrame 失败（%1）").arg(int(begun));
        return false;
    }
    // A02：begin 成功即计一次离屏提交（与后端 offscreenSubmits() 同一判据）。
    ++m_presenterSubmits;

    // FG 的算法命令必须和合成落在同一个离屏帧里：先插值、再合成、最后注入信号量，
    // 三者由同一次提交保证顺序与可见性。
    const bool interpolated = allowInterpolation && recordFrameGeneration(cb);
    QRhiTexture *base = interpolated ? m_fg->output() : m_host->sceneTexture();
    m_probe.restart();
    const bool composed = composite(cb, base, m_host->overlayTexture(), frame.imageIndex);
    m_stats.compositeMs = blend(m_stats.compositeMs, tookMs());
    m_probe.restart();
    const bool presented = m_presenter->endFrame(frame, composed);
    // A02：endMs 的语义是"离屏收尾"——只做提交与呈现，没有读回时不应有同步等待。
    const double endSample = tookMs();
    m_stats.endMs = blend(m_stats.endMs, endSample);
    // 成对样本只记 begin/end 都走完的帧：失败的 begin 没有 end，混进分位会把
    // "槽等待"与"提交失败前的那段等待"搅在一起。
    recordWaitSample(m_stats.slotWaitMs, endSample);
    if (!presented) {
        m_error = m_presenter->lastError();
        return false;
    }
    ++m_presentedFrames;
    if (interpolated) {
        ++m_interpolatedFrames;
    }
    if (interpolatedOut) {
        *interpolatedOut = interpolated;
    }
    // 呈现间隔与整帧耗时都按"真的上屏了"来记，失败的那次不计入，免得把
    // 交换链重建的停顿算成 FG 的成本。
    if (presented) {
        // 整帧 = 从 beginFrame 之前到 endFrame 返回之后。以前这里记的是"上屏耗时"，
        // 但它在 endFrame 之后重新起表，只有几条记账语句那么长（恒≈0），
        // 白白占掉一列指标；换成全程耗时后，"帧间隔 30ms 但分项都是 1ms"这类
        // 缺口才有唯一可对的数（A01 的计时去重）。
        m_stats.frameMs = blend(m_stats.frameMs, m_frameProbe.nsecsElapsed() / 1e6);
        ++m_stats.frameId;
        if (m_presentClock.isValid()) {
            recordGap(double(m_presentClock.nsecsElapsed()) / 1e6);
        }
        m_presentClock.restart();
        // 真的上屏了，说明重建是有效的：清掉"连续重建次数"，别让偶发的
        // 一两次 OutOfDate 累积成误判。
        m_recreateStreak = 0;
        if (m_framesSinceRecreate < 1000) {
            ++m_framesSinceRecreate;
        }
    }
    return presented;
}

void PresentationShell::step() {
#ifdef Q_OS_IOS
    if (QGuiApplication::applicationState() != Qt::ApplicationActive) {
        return;
    }
#endif
    if (m_stopped || m_quitRequested || m_failed || !m_window || !m_host) {
        return;
    }
    if (!m_frameClock.isValid()) {
        m_frameClock.start();
    }
    // 两步之间的空档：定时器排队 + 事件循环。和渲染成本分开统计，否则"各项都 <1ms、
    // 帧间隔 30ms+"根本看不出钱花在哪。
    if (!m_stepClock.isValid()) {
        m_stepClock.start();
    } else if (m_stepEndNs > 0) {
        m_stats.idleGapMs = blend(m_stats.idleGapMs, double(m_stepClock.nsecsElapsed() - m_stepEndNs) / 1e6);
    }
    if (!m_window->isVisible() || !m_window->isExposed() || m_window->visibility() == QWindow::Minimized) {
        return;
    }
    const bool idle = m_backend->performance().value(QStringLiteral("idle")).toBool();
    const bool interpolationWanted = requested();
    syncSizes();

    if (!m_host->resumeGraphics()) {
        m_error = m_host->lastError();
        m_failed = true;
        return;
    }
    if (m_needRecreate && !recreateSwapchain()) {
        qWarning().noquote() << "FG:" << m_error;
        m_needRecreate = false;
        scheduleNext();
        return;
    }
    if (!ensureSwapchainResources() || !ensureCompositeResources()) {
        qWarning().noquote() << "FG:" << m_error;
        scheduleNext();
        return;
    }

    // 引擎每走一拍就放行一次渲染。这条**不能删**：模型/纹理是异步加载的，加载完成
    // 不一定伴随 sceneUpdated，一旦只看脏标记，3D 房间几何就会永远不出现（实测如此）。
    // 用 steps 的意义就是"引擎前进了"，代价是没变也要重渲——这是正确性的前提。
    // 引擎计时推进不等于画面改变。两层都无更新且没有待呈现帧时让事件循环休眠。
#ifdef Q_OS_LINUX
    const auto engineSteps =
        m_backend ? m_backend->performance().value(QStringLiteral("steps")).toULongLong() : 0;
    // 内容代次精细化：引擎"步进"不等于"画面变了"。m_steps 每拍都涨，但 HUD 命令
    // 列表与场景内容只在真正变化时才涨 hudUpdates/sceneUpdates。用这两个代次判断
    // 是否需要上屏，才能既不丢帧也不做无内容变化的重复上屏。
    // RHINE_PRESENT_CONTENT_ONLY=1 启用（默认仍用旧的 engineAdvanced 判据）。
    static const bool contentOnly =
        qEnvironmentVariableIntValue("RHINE_PRESENT_CONTENT_ONLY") == 1;
    const auto engineHud =
        m_backend ? m_backend->performance().value(QStringLiteral("hudUpdates")).toULongLong() : 0;
    const auto engineScene =
        m_backend ? m_backend->performance().value(QStringLiteral("sceneUpdates")).toULongLong() : 0;
    const bool contentAdvanced = contentOnly
                                     ? (engineHud != m_lastEngineHud || engineScene != m_lastEngineScene)
                                     : (engineSteps != m_lastEngineSteps);
    const bool engineAdvanced = m_backendName == "vulkan" && contentAdvanced;
    // 重渲已经由内容代次剔除，但"上屏"仍然每步都做：合成一次缓存纹理很便宜，而把
    // 上屏也一起砍掉会让 presented 从 46/s 掉到 31/s（实测），用户看到的出帧反而更少。
    // RHINE_PRESENT_ALWAYS=0 可退回"没有新内容就不上屏"的省电行为。
    static const bool presentAlways =
        qEnvironmentVariableIsSet("RHINE_PRESENT_ALWAYS")
            ? qEnvironmentVariableIntValue("RHINE_PRESENT_ALWAYS") != 0
            : true;
    if (!presentAlways && !m_host->contentDirty() && !engineAdvanced && !m_forcePresent &&
         !m_pendingRealFrame) {
#else
    const auto engineSteps = m_backend->performance().value(QStringLiteral("steps")).toULongLong();
    const bool engineAdvanced = m_backendName == "vulkan" && engineSteps != m_lastEngineSteps;
    if (!m_host->contentDirty() && !engineAdvanced && !m_forcePresent && !m_pendingRealFrame) {
#endif
        ++m_skippedSteps;
        publishStats(false);
        if (m_backendName == "vulkan") {
#ifdef Q_OS_LINUX
            // 看门狗：连续跳过太久说明可能有人漏标脏，强制补渲一次把画面拉回来。
            if (++m_consecutiveSkips >= kSkipWatchdogSteps) {
                m_consecutiveSkips = 0;
                m_host->markSceneDirty();
                m_host->markOverlayDirty();
            }
            // 兜底轮询而已，主通路是 watch() 接上的 renderRequested/sceneChanged。
            // 固定 4ms：不由屏幕刷新率推导，出帧上限只由每帧工作量决定。
#endif
            scheduleNext(idle ? 100 : 4);
        }
        return;
    }
    m_lastEngineSteps = engineSteps;
#ifdef Q_OS_LINUX
    m_lastEngineHud = engineHud;
    m_lastEngineScene = engineScene;
    m_consecutiveSkips = 0;
#endif

    // 上一步留下的真实帧还没上屏：这一步只做它的呈现。
    // 插值帧与真实帧因此拆进相邻的两个调度步——一步一次 present，事件循环在两者
    // 之间能拿回执行权；以前两步的活在一步里做完，输入和窗口事件会被整段吞掉。
    if (m_pendingRealFrame) {
        m_pendingRealFrame = false;
        RhineRender::PresentationBackend::Frame frame;
        m_probe.start();
        const auto acquired = m_presenter->acquire(&frame);
        m_stats.acquireMs = blend(m_stats.acquireMs, tookMs());
        if (acquired == RhineRender::PresentationBackend::AcquireResult::OutOfDate) {
            m_needRecreate = true;
            scheduleNext();
            return;
        }
        if (acquired == RhineRender::PresentationBackend::AcquireResult::Ok ||
            acquired == RhineRender::PresentationBackend::AcquireResult::Suboptimal) {
            if (!presentOne(frame, false, nullptr)) {
                qWarning().noquote() << "FG: present 失败" << m_presenter->lastError();
                m_needRecreate = true;
            }
        }
        // Timeout/Error：插值帧已经上屏，少补一帧即可，不必重建整条交换链。
        publishStats(false);
        reportStats();
        scheduleNext(0);
        return;
    }

    if (m_backendName == "vulkan") {
        armFrameGeneration();
    }
    RhineRender::PresentationBackend::Frame frame;
    m_probe.start();
    const auto acquired = m_presenter->acquire(&frame);
    m_stats.acquireMs = blend(m_stats.acquireMs, tookMs());
    // Suboptimal 只表示"这张图能呈现，但交换链不再最优"。以前这里把图一起丢掉并整链重建
    // （deviceWaitIdle + 5 张 image/view/semaphore + 全部纹理与管线），代价是掉几帧、
    // 画面还会闪一下。重建只由 OutOfDate 与窗口 Resize/Expose 驱动。
    if (acquired == RhineRender::PresentationBackend::AcquireResult::OutOfDate) {
        m_needRecreate = true;
        if (++m_outOfDateCount % 100 == 1) {
            qWarning().noquote() << "FG: acquire 返回 OutOfDate，累计" << m_outOfDateCount;
        }
        scheduleNext();
        return;
    }
    if (acquired == RhineRender::PresentationBackend::AcquireResult::Suboptimal) {
        static bool warnedSuboptimal = false;
        if (!warnedSuboptimal) {
            warnedSuboptimal = true;
            qWarning().noquote() << "FG: 交换链 suboptimal，继续使用（等 OutOfDate 或窗口事件再重建）";
        }
    } else if (acquired != RhineRender::PresentationBackend::AcquireResult::Ok) {
        // Timeout：窗口最小化或设备忙，跳过这一帧即可，重建没有意义。
        if (++m_acquireTimeoutCount % 100 == 1) {
            qWarning().noquote() << "FG: acquire 超时（窗口不可见/合成器未取图），累计"
                                 << m_acquireTimeoutCount;
        }
        // 立即重试：出帧优先。acquire 超时通常意味着窗口不可见或合成器未取图，
        // 这里不做节流，避免把上限压在人为延迟上。
        scheduleNext();
        return;
    }

    m_probe.restart();
    // A03：把引擎侧内容版本推进到本帧。必须在 renderFrame() 之前——脏标记是在那一刻
    // 被消费的，晚一行就要等到下一帧才生效。默认（RHINE_LAYER_REVISION 未开）这里只
    // 记录版本，置脏仍由 sceneUpdated/hudUpdated 信号驱动，行为与优化前一致。
    m_host->setResourceRevision(m_backend->sceneRevision(), m_backend->hudRevision());
    const auto previousSceneFrames = m_host->sceneRenderCount();
    const auto previousOverlayFrames = m_host->overlayRenderCount();
    const bool sceneRendered = m_host->renderFrame();
    m_stats.sceneMs = blend(m_stats.sceneMs, tookMs());
    // A02：QML 场景层/UI 层每次真正渲染都是一次 QQuickRenderControl 的 beginFrame/endFrame。
    // SceneLayerHost 没有提交计数接口（不在本次改动范围），只能对两个公开计数取差分；
    // 立即累加，后面的早退路径（渲染失败/呈现失败）也能把它们算进去。
    m_layerSubmits += (m_host->sceneRenderCount() - previousSceneFrames) +
                      (m_host->overlayRenderCount() - previousOverlayFrames);
    if (!sceneRendered) {
        qWarning().noquote() << "FG: 离屏渲染失败" << m_host->lastError();
        scheduleNext();
        return;
    }
    const bool newScene = m_host->sceneRenderCount() != previousSceneFrames;
    m_renderedFrames +=
        m_host->sceneRenderCount() - previousSceneFrames; // 场景真的重渲了一帧（FG 的输入新鲜度就看它）

    bool interpolated = false;
    // 重建后的前两帧只呈现真实帧：那时 QML 可能还在按旧尺寸排版、交换链也是全新的，
    // 跨尺寸插出来的帧就是满屏错色（改窗口大小时"闪一下"的来源）。
    // 在离屏提交结束后读取这一帧输入；UI 单独更新不能再次插值同一帧场景。
    const bool interpolationAllowed = newScene && !idle && interpolationWanted &&
                                      m_framesSinceRecreate >= 2 &&
                                      (m_backendName == "vulkan" || armFrameGeneration());
    if (!presentOne(frame, interpolationAllowed, &interpolated)) {
        qWarning().noquote() << "FG: present 失败" << m_presenter->lastError();
        m_needRecreate = true;
        scheduleNext();
        return;
    }

    // 插值帧已经上屏，同一帧的真实版本留到下一步再上屏（见上面的 pendingRealFrame）。
    m_pendingRealFrame = interpolated;
    publishStats(interpolated);
    m_forcePresent = false;
    reportStats();
    // 新更新和待呈现的真实帧继续排队；其余情况等待下一次内容更新。
    if (m_backendName == "vulkan") {
        // 尾部立刻自续：关掉 vsync 时这个应用要的是"能跑多快跑多快"，限速会把帧率
        // 钉死在刷新率上，与设计意图相反。
        // 空转（同一画面反复提交）不再靠限速解决，而是靠 SceneLayerHost 的脏帧剔除：
        // 没有新内容时这里会自动落进上面的跳过分支，不会再重复渲染。
        scheduleNext(idle ? 100 : 0);
    } else if (m_pendingRealFrame || m_host->contentDirty()) {
        scheduleNext();
    }
}

void PresentationShell::reportStats() {
    // 第一行要在启动后很快出现：空闲时呈现节奏会降到 10Hz，等"每 300 帧一行"
    // 要半分钟才看得到第一条，冒烟测试和现场排障都等不起。
    const bool firstWindow = m_presentedFrames == 60;
    if (!firstWindow && (m_presentedFrames < 60 || m_presentedFrames % 300 != 0)) {
        return;
    }
    const RhineFg::FrameInputs &inputs = currentFrameInputs();
    qWarning().noquote()
        << "FG stats: presented" << m_presentedFrames << "interpolated" << m_interpolatedFrames << "tapSerial"
        << inputs.serial << "depth" << (inputs.depth ? "ok" : "null") << "mv"
        << (inputs.motionVectors ? "ok" : "null") << "render" << inputs.renderSize << "display"
        << inputs.displaySize << "gapP50" << QString::number(m_stats.gapP50Ms, 'f', 1)
        << "ms/frame"
        // 分项：取图 / 场景 / 合成 / 整帧。原来的"上屏"耗时在 endFrame 之后重新起表，
        // 只量到几条记账语句（恒≈0），已经删掉；能回答"这一帧到底多久"的是整帧。
        << "取图" << QString::number(m_stats.acquireMs, 'f', 2) << "场景"
        << QString::number(m_stats.sceneMs, 'f', 2)
        // 光流+深度重建（prepare）与插值本身（dispatch）必须分开看：
        // 两者的优化手段完全不同，混在一起就不知道该调哪个。
        << "光流" << QString::number(m_stats.prepareMs, 'f', 2) << "插值"
        << QString::number(m_stats.dispatchMs, 'f', 2) << "合成"
        << QString::number(m_stats.compositeMs, 'f', 2) << "整帧"
        << QString::number(m_stats.frameMs, 'f', 2) << "复用"
        << QString::number(m_stats.imageReuseMs, 'f', 1)
        // A02 语义写死：begin = 帧槽等待（等上一帧提交的槽），end = 离屏收尾。
        << "帧槽" << QString::number(m_stats.beginMs, 'f', 2)
        << "离屏收尾" << QString::number(m_stats.endMs, 'f', 2) << "空档"
        << QString::number(m_stats.idleGapMs, 'f', 2) << "跳过" << m_skippedSteps
        // 重建 / 设备等待 / 尺寸去重：A10 的现场证据，一行看得出有没有白等 GPU。
        << "重建" << m_stats.swapchainRecreates << "等待" << m_stats.deviceIdleWaits << "尺寸跳过"
        << m_stats.resizeSkips
        << (m_frameClock.isValid() ? m_frameClock.restart() / double(m_presentedFrames - m_statsBase) : 0.0);
    // A02：把两个"离屏边界"的语义写成一行，避免以后又把帧槽等待和收尾等待混成一个数。
    qWarning().noquote()
        << "FG 提交/等待: 提交" << m_stats.submitsPerFrame
        << "次/帧（QML 场景层 + UI 层 + 呈现层，各一次 beginFrame/endFrame）" << "帧槽等待"
        << QString::number(m_stats.slotWaitMs, 'f', 2)
        << "ms（beginFrame 等上一帧提交的槽/围栏归还；原始样本，P95"
        << QString::number(m_stats.beginP95Ms, 'f', 2) << "P99"
        << QString::number(m_stats.beginP99Ms, 'f', 2) << "）" << "离屏收尾"
        << QString::number(m_stats.endMs, 'f', 2)
        << "ms（endFrame 只提交与呈现，无读回时不应同步等待；EMA，P95"
        << QString::number(m_stats.endP95Ms, 'f', 2) << "P99"
        << QString::number(m_stats.endP99Ms, 'f', 2) << "）";
    m_statsBase = m_presentedFrames;
}

void PresentationShell::scheduleNext(int delayMs) {
    // 单次定时器串起来而不是固定间隔：FIFO present 自带节流，让事件循环在两次
    // 呈现之间拿到执行权（输入、窗口事件），比追着刷新率跑更稳。
#ifdef Q_OS_IOS
    if (QGuiApplication::applicationState() != Qt::ApplicationActive) {
        return;
    }
#endif
    if (!m_timer || m_stopped || m_quitRequested || m_failed) {
        return;
    }
#ifdef Q_OS_LINUX
    if (delayMs == 0 && m_timer->isActive()) {
        // 已经排着一步：不重启定时器，只记下这次唤醒，等当前步跑完再补。
        m_wakePending = true;
        return;
    }
#endif
    if (m_stepClock.isValid()) {
        m_stepEndNs = m_stepClock.nsecsElapsed(); // 空档计时的起点
    }
    m_timer->setSingleShot(true);
    m_timer->start(delayMs);
}

bool PresentationShell::eventFilter(QObject *watched, QEvent *event) {
    if (watched != m_window) {
        return QObject::eventFilter(watched, event);
    }

    const bool visible = m_window->isVisible() && m_window->visibility() != QWindow::Minimized
#ifdef Q_OS_IOS
                         && QGuiApplication::applicationState() == Qt::ApplicationActive
#endif
        ;
    if (event->type() == QEvent::Show || event->type() == QEvent::Hide ||
        event->type() == QEvent::WindowStateChange || event->type() == QEvent::Expose) {
        m_backend->setVisible(visible);
        if (visible) {
            if (m_releaseTimer) {
                m_releaseTimer->stop();
            }
            m_forcePresent = true;
            scheduleNext();
        } else {
            m_startupProbe.reset();
            if (m_timer) {
                m_timer->stop();
            }
            if (m_releaseTimer) {
                m_releaseTimer->start(2000);
            }
        }
    }
    switch (event->type()) {
    case QEvent::Close:
        // 关闭可能来自 QML 按钮；先拦截原生销毁，再在输入栈退出后拆交换链并结束进程。
        event->ignore();
        requestQuit();
        return true;
    case QEvent::Expose:
        if (m_window->isExposed()) {
            m_needRecreate = true;
            m_forcePresent = true;
            scheduleNext();
        }
        break;
#ifdef Q_OS_WIN
    case QEvent::DevicePixelRatioChange:
    case QEvent::ScreenChangeInternal:
#endif
    case QEvent::Resize:
        m_needRecreate = true;
        m_forcePresent = true;
        scheduleNext();
        break;
    default:
        break;
    }

    // 探针（RHINE_KEY_PROBE=1）：打印真正到达可见窗口的按键。
    // 被 Qt 快捷键地图（QShortcutMap）消费掉的按键不会出现在这里——用它区分
    // "快捷键没匹配上"与"快捷键已触发、但动作没生效"。
    if (qEnvironmentVariableIntValue("RHINE_KEY_PROBE") == 1 &&
        (event->type() == QEvent::KeyPress || event->type() == QEvent::ShortcutOverride)) {
        auto *key = static_cast<QKeyEvent *>(event);
        qInfo().noquote() << "按键探针:"
                          << (event->type() == QEvent::KeyPress ? "KeyPress" : "ShortcutOverride")
                          << QKeySequence(key->keyCombination()).toString()
                          << "修饰键=" << int(key->modifiers());
    }

    // QQuickRenderControl 没有自己的事件来源：可见窗口收到的输入必须原样转发给
    // 离屏的 UI 窗口，否则按钮、滚轮、快捷键全部失效。
    if (QQuickWindow *overlay = m_host ? m_host->overlayWindow() : nullptr) {
#ifdef Q_OS_WIN
        const qreal inputRatio = 1.0;
#else
        // 非 Windows 原样保留补丁前的输入坐标规则。
        const qreal inputRatio = m_backendName == "metal" ? 1.0 : m_dpr;
#endif
        switch (event->type()) {
        case QEvent::KeyPress:
            // 兜底且是真正的保障：按键到达时离屏窗口若没有焦点项，KeyPress 会被
            // QQuickWindow 直接丢弃（F 键不受影响是因为 Shortcut 走 QShortcutMap，
            // 与焦点项无关）。事件循环的顺序不可控，所以这里同步补一次，绝不依赖
            // FocusIn 的排队恢复。
            ensureOverlayFocus(overlay);
            QCoreApplication::sendEvent(overlay, event);
            break;
        case QEvent::KeyRelease:
            QCoreApplication::sendEvent(overlay, event);
            break;
        case QEvent::MouseButtonPress:
        case QEvent::MouseButtonRelease:
        case QEvent::MouseButtonDblClick:
        case QEvent::MouseMove: {
            auto *mouseEvent = static_cast<QMouseEvent *>(event);
            if (qFuzzyCompare(inputRatio, 1.0)) {
                QCoreApplication::sendEvent(overlay, event);
            } else {
                QMouseEvent scaled(mouseEvent->type(), mouseEvent->position() * inputRatio,
                                   mouseEvent->scenePosition() * inputRatio, mouseEvent->globalPosition(),
                                   mouseEvent->button(), mouseEvent->buttons(), mouseEvent->modifiers(),
                                   mouseEvent->pointingDevice());
                QCoreApplication::sendEvent(overlay, &scaled);
            }
            break;
        }
        case QEvent::Wheel: {
            auto *wheelEvent = static_cast<QWheelEvent *>(event);
            if (qFuzzyCompare(inputRatio, 1.0)) {
                QCoreApplication::sendEvent(overlay, event);
            } else {
                QWheelEvent scaled(wheelEvent->position() * inputRatio, wheelEvent->globalPosition(),
                                   wheelEvent->pixelDelta(), wheelEvent->angleDelta(), wheelEvent->buttons(),
                                   wheelEvent->modifiers(), wheelEvent->phase(), wheelEvent->inverted(),
                                   wheelEvent->source(), wheelEvent->pointingDevice());
                QCoreApplication::sendEvent(overlay, &scaled);
            }
            break;
        }
        case QEvent::HoverEnter:
        case QEvent::HoverLeave:
        case QEvent::HoverMove: {
            auto *hoverEvent = static_cast<QHoverEvent *>(event);
            if (qFuzzyCompare(inputRatio, 1.0)) {
                QCoreApplication::sendEvent(overlay, event);
            } else {
                QHoverEvent scaled(hoverEvent->type(), hoverEvent->position() * inputRatio,
                                   hoverEvent->globalPosition(), hoverEvent->oldPos() * inputRatio,
                                   hoverEvent->modifiers(), hoverEvent->pointingDevice());
                QCoreApplication::sendEvent(overlay, &scaled);
            }
            break;
        }
        case QEvent::TouchBegin:
        case QEvent::TouchUpdate:
        case QEvent::TouchEnd:
        case QEvent::TouchCancel:
            QCoreApplication::sendEvent(overlay, event);
            break;
        case QEvent::FocusOut:
        case QEvent::FocusIn:
            // 故意不转发 FocusIn/FocusOut。
            //
            // 为什么：离屏窗口没有平台窗口，isActive() 恒为 false，靠 Qt 自己的
            // 激活流程永远拿不回焦点。而 QQuickWindow::focusOutEvent 会立刻把
            // activeFocusItem 清空——转发出去就等于亲手把 QML 焦点打掉，且再也
            // 恢复不了（实测切走再切回后 activeFocusItem 恒为 null，于是 KeyPress
            // 到了窗口却被 QQuickWindow 丢弃：ESC/方向键全部失效，而 F 键因为是
            // Shortcut、不经过焦点项，所以照常好用）。
            // 焦点由"可见窗口"这唯一真实来源决定：启动时建立一次，按键到达时兜底。
            break;
        case QEvent::ShortcutOverride:
            QCoreApplication::sendEvent(overlay, event);
            break;
        default:
            break;
        }
    }
    if (m_host && (event->isInputEvent() || event->type() == QEvent::InputMethod)) {
        m_host->markOverlayDirty();
        scheduleNext();
    }
    return QObject::eventFilter(watched, event);
}

// 同步版：立刻把 QML 焦点补回来（排队恢复会被后续事件搅掉，实测重新聚焦后仍为 null）。
void PresentationShell::ensureOverlayFocus(QQuickWindow *overlay) {
    if (!overlay || !m_host) {
        return;
    }
#ifdef Q_OS_WIN
    auto *focusItem = overlay->activeFocusItem();
    if (focusItem && focusItem != overlay->contentItem() && focusItem != m_host->overlayRootItem()) {
        return;
    }
    if (QQuickItem *root = m_host->overlayRootItem()) {
        QMetaObject::invokeMethod(root, "restoreInputFocus", Qt::DirectConnection);
    }
#else
    if (overlay->activeFocusItem()) {
        return;
    }
    if (QQuickItem *root = m_host->overlayRootItem()) {
        QMetaObject::invokeMethod(root, "focusInputLayer", Qt::DirectConnection);
    }
#endif
}

bool PresentationShell::start() {
    if (!supportsBackend(m_backendName)) {
        m_error = QStringLiteral("这个构建未编入所选呈现后端");
        return false;
    }
    m_size = QSize(1280, 720);
    if (!initializeBackend()) {
        return false;
    }
    if (!initializeLayers()) {
        return false;
    }

    m_timer = new QTimer(this);
    m_timer->setTimerType(Qt::PreciseTimer);
#ifdef Q_OS_LINUX
    // 跑完一步后，如果期间又有唤醒被压住，立刻补一步：丢唤醒会让出帧数直接减半
    // （实测 tick 22/s 只出 10.6 帧，正是这里把相邻两次唤醒合并掉了）。
    connect(m_timer, &QTimer::timeout, this, [this] {
        step();
        if (m_wakePending) {
            m_wakePending = false;
            scheduleNext(0);
        }
    });
#else
    connect(m_timer, &QTimer::timeout, this, &PresentationShell::step);
#endif
    // 内容代次：引擎真的产出了新场景/新 HUD 时才让图层重渲。
    // Qt 自己的 renderRequested/sceneChanged 每帧有数十次噪音，不能用来判脏。
    connect(m_backend, &Engine::sceneUpdated, this, [this] {
#ifdef Q_OS_LINUX
        m_host->requestSceneContent();
#else
        m_host->markSceneDirty();
#endif
        scheduleNext();
    });
    connect(m_backend, &Engine::hudUpdated, this, [this] {
#ifdef Q_OS_LINUX
        m_host->requestOverlayContent();
#else
        m_host->markOverlayDirty();
#endif
        scheduleNext();
    });

#ifdef Q_OS_DARWIN
    m_releaseTimer = new QTimer(this);
    m_releaseTimer->setSingleShot(true);
    const auto releaseBackgroundGraphics = [this] {
        if (m_rhi && (!m_window->isVisible() || m_window->visibility() == QWindow::Minimized
#ifdef Q_OS_IOS
                      || QGuiApplication::applicationState() != Qt::ApplicationActive
#endif
                      )) {
            if (m_backend) {
                m_backend->metalFxInputs = {};
            }
            m_rhi->finish();
            if (m_fg) {
                m_fg->release();
            }
            releaseSwapchainResources();
            if (m_host) {
                m_host->releaseGraphics();
            }
            if (m_backend) {
                m_backend->trimMemory();
            }
        }
    };
    connect(m_releaseTimer, &QTimer::timeout, this, releaseBackgroundGraphics);
#endif
#ifdef Q_OS_IOS
    // iOS 切后台时窗口可以仍是 visible；必须按应用状态停掉 GPU 提交并释放离屏资源。
    connect(qGuiApp, &QGuiApplication::applicationStateChanged, this,
            [this, releaseBackgroundGraphics](Qt::ApplicationState state) {
                const bool active = state == Qt::ApplicationActive;
                if (m_backend) {
                    m_backend->setVisible(active);
                }
                m_pendingRealFrame = false;
                if (active) {
                    m_releaseTimer->stop();
                    m_needRecreate = true;
                    m_forcePresent = true;
                    scheduleNext();
                } else {
                    // 后台可能立即冻结定时器；不能等下一次自检回调才暂停计时。
                    m_startupProbe.reset();
                    m_timer->stop();
                    // 同步释放，不能依赖进入后台后可能不再执行的定时器。
                    releaseBackgroundGraphics();
                }
            });
#endif
    // 预检：有些设备能建出交换链，却撑不住持续上屏（典型是"没有直连显示输出"的独显
    // ——surface 由跑在集显上的合成器管理）。实测独显上会先成功呈现 4 帧，随后
    // OutOfDate 一路涨到几万次、再也没出过一帧（白窗 + 空转）。
    // 判据要贴着"真坏了"写，不能贴"慢了"：首帧编译着色器本来就是慢的。
    //   · OutOfDate 超过 200 次 → 交换链撑不住，判死；
    //   · 3 秒过去一帧都没上屏 → 判死；
    //   · 按适配器要求检查连续呈现；预检结束后恢复按需调度。
    // 判死后由 main.cpp 干净回退到默认 QQuickWindow 路径。这比
    // vkGetPhysicalDeviceSurfaceSupportKHR 靠谱：后者对这类设备仍返回支持。
#ifndef Q_OS_IOS
    {
        QElapsedTimer probeClock;
        probeClock.start();
        const auto probeFrames = quint64(qMax(1, m_presenter->startupProbeFrames()));
        while (probeClock.elapsed() < 3000 && m_presentedFrames < probeFrames && !m_failed &&
               m_outOfDateCount <= 200) {
            m_forcePresent = true;
            step();
            QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
        }
        if (m_failed || m_outOfDateCount > 200 || m_presentedFrames == 0) {
            m_error = QStringLiteral("呈现层自检失败：接管窗口后只上屏 %1 帧"
                                     "（acquire 超时 %2 次、OutOfDate %3 次、重建 %4 次），"
                                     "这台设备撑不住持续呈现，回退默认呈现路径。")
                          .arg(m_presentedFrames)
                          .arg(m_acquireTimeoutCount)
                          .arg(m_outOfDateCount)
                          .arg(m_recreateStreak);
            return false;
        }
    }
#endif

    // 排障：RHINE_FG_DIAG=1 时每秒打一行真实计数。presented 只在每 300 帧打印，
    // 现场判断"到底是在跑还是在空转"时等不起，这个小计时器直接给答案。
    if (qEnvironmentVariableIsSet("RHINE_FG_DIAG")) {
        auto *diag = new QTimer(this);
        diag->setInterval(1000);
        connect(diag, &QTimer::timeout, this, [this] {
            qWarning().noquote() << "FG diag: presented" << m_presentedFrames << "rendered"
                                 << m_renderedFrames << "skipped" << m_skippedSteps << "acqTimeout"
                                 << m_acquireTimeoutCount << "outOfDate" << m_outOfDateCount << "visible"
                                 << (m_window && m_window->isVisible()) << "pendingReal" << m_pendingRealFrame
                                 << "gapP50" << QString::number(m_stats.gapP50Ms, 'f', 1) << "复用"
                                 << QString::number(m_stats.imageReuseMs, 'f', 1) << "dirty"
#ifdef Q_OS_LINUX
                                 << (m_host ? m_host->contentDirty() : false) << "force" << m_forcePresent
                                 << "| 3D层" << QString::number(m_host->sceneLayerMs(), 'f', 1) << "ms"
                                 << "(打磨" << QString::number(m_host->scenePolishMs(), 'f', 1)
                                 << "起帧" << QString::number(m_host->sceneBeginMs(), 'f', 1)
                                 << "同步" << QString::number(m_host->sceneSyncMs(), 'f', 1)
                                 << "录制" << QString::number(m_host->sceneRecordMs(), 'f', 1)
                                 << "提交等待" << QString::number(m_host->sceneSubmitMs(), 'f', 1) << ")"
                                 << "UI层" << QString::number(m_host->overlayLayerMs(), 'f', 1) << "ms";
#else
                                 << (m_host ? m_host->contentDirty() : false) << "force" << m_forcePresent;
#endif
        });
        diag->start();
    }

    if (m_backend) {
        m_backend->setWindow(m_window);
        m_window->installEventFilter(m_backend);
    }
    m_started = true;
    publishStats(false);
    // 交换链与设备信息整个生命周期不变，这里写一次就够，之后 publishStats 带出去。
    m_stats.swapchainImages = int(m_presenter->imageCount());
    m_stats.swapchainFormat = m_presenter->formatName();
    m_stats.presentMode = m_presenter->presentModeName();
    m_stats.adapterName = QString::fromUtf8(m_rhi->driverInfo().deviceName);
    m_stats.backendName = m_presenter->backendName();
    RhineFg::publishCapability(compiledIn(), true, m_fgAvailable,
                               m_backendName == "metal" && !m_fgAvailable
                                   ? QStringLiteral("当前构建、系统或设备不支持 MetalFX 帧生成")
                                   : QString());
    qWarning().noquote() << "FG: 呈现层已启动；插值" << (m_fgAvailable ? "可用" : "不可用") << "，"
                         << m_presenter->imageCount() << "张交换链图像" << m_presenter->extent()
                         << "，呈现模式" << m_presenter->presentModeName();
    return true;
}

int PresentationShell::run() {
    if (!m_started) {
        return 1;
    }
#ifdef Q_OS_IOS
    // UIKit 必须先从 Qt 的主事件循环取得执行权，才能完成启动、激活和窗口暴露。
    // processEvents 的同步轮询无法替代这一过程，不能在 start() 中等待首帧。
    auto *probeTimer = new QTimer(this);
    probeTimer->setInterval(16);
    QElapsedTimer clock;
    clock.start();
    connect(probeTimer, &QTimer::timeout, this, [this, probeTimer, clock] {
        if (m_stopped) {
            probeTimer->stop();
            return;
        }
        const bool ready = QGuiApplication::applicationState() == Qt::ApplicationActive &&
                           m_window->isVisible() && m_window->isExposed() &&
                           m_window->visibility() != QWindow::Minimized;
        const auto result = m_startupProbe.update(clock.elapsed(), ready, m_presentedFrames,
                                                  m_failed || m_outOfDateCount > 200);
        using Result = RhineRender::PresentationStartupProbe::Result;
        if (result == Result::Passed || result == Result::Failed) {
            probeTimer->stop();
            probeTimer->deleteLater();
            if (result == Result::Failed) {
                m_failed = true;
                m_error = QStringLiteral("呈现层自检失败：前台窗口就绪后只上屏 %1 帧"
                                         "（acquire 超时 %2 次、OutOfDate %3 次、重建 %4 次）")
                              .arg(m_presentedFrames)
                              .arg(m_acquireTimeoutCount)
                              .arg(m_outOfDateCount)
                              .arg(m_recreateStreak);
                emit startupFailed();
            } else {
                qInfo() << "FG: iOS 呈现层首帧自检通过";
            }
            return;
        }
        if (result == Result::Running) {
            m_forcePresent = true;
            scheduleNext();
        }
    });
    probeTimer->start();
#endif
    scheduleNext();
    return 0;
}

QQuickWindow *PresentationShell::inputWindow() const {
    return m_host ? m_host->overlayWindow() : nullptr;
}

QQuickWindow *PresentationShell::sceneWindow() const {
    return m_host ? m_host->sceneWindow() : nullptr;
}

QVariantMap PresentationShell::renderState() const {
    return {{"sceneFrames", qulonglong(m_host ? m_host->sceneRenderCount() : 0)},
            {"overlayFrames", qulonglong(m_host ? m_host->overlayRenderCount() : 0)},
            {"presented", qulonglong(m_presentedFrames)},
            {"interpolated", qulonglong(m_interpolatedFrames)},
            {"timerActive", m_timer && m_timer->isActive()},
            {"graphicsDevice", m_rhi != nullptr},
#ifdef Q_OS_DARWIN
            {"renderer", m_backend ? m_backend->renderTelemetry.snapshot() : QVariantMap{}},
#endif
#ifdef Q_OS_WIN
            {"windowDpr", m_window ? m_window->devicePixelRatio() : 0.0},
            {"sceneDpr", sceneWindow() ? sceneWindow()->effectiveDevicePixelRatio() : 0.0},
            {"overlayDpr", inputWindow() ? inputWindow()->effectiveDevicePixelRatio() : 0.0},
            {"logicalWidth", m_size.width()},
            {"logicalHeight", m_size.height()},
            {"targetWidth", m_host ? m_host->pixelSize().width() : 0},
            {"targetHeight", m_host ? m_host->pixelSize().height() : 0},
            {"swapchainWidth", m_presenter ? m_presenter->extent().width() : 0},
            {"swapchainHeight", m_presenter ? m_presenter->extent().height() : 0},
#endif
            {"backend", m_backendName}};
}

/** 从现有两层纹理抓取同一合成结果，不推进动画或重画场景。 */
QImage PresentationShell::grabFrame(bool interpolated) {
    if (!m_rhi || !m_host || !m_host->sceneTexture() || !m_host->overlayTexture()) {
        return {};
    }
    std::unique_ptr<QRhiTexture> texture(m_rhi->newTexture(
        QRhiTexture::RGBA8, pixelSize(), 1, QRhiTexture::RenderTarget | QRhiTexture::UsedAsTransferSource));
    if (!texture->create()) {
        return {};
    }
    std::unique_ptr<QRhiTextureRenderTarget> target(
        m_rhi->newTextureRenderTarget({QRhiColorAttachment(texture.get())}));
    std::unique_ptr<QRhiRenderPassDescriptor> pass(target->newCompatibleRenderPassDescriptor());
    target->setRenderPassDescriptor(pass.get());
    if (!target->create()) {
        return {};
    }
    QRhiCommandBuffer *commands = nullptr;
    if (m_rhi->beginOffscreenFrame(&commands) != QRhi::FrameOpSuccess) {
        return {};
    }
    // 读回目标为 RGBA8，交换链可能是 BGRA8，不能复用两者的 render pass 管线。
    releaseSwapchainResources();
    auto base = interpolated && m_fg && !m_fg->lastFrameReset() ? m_fg->output() : m_host->sceneTexture();
    const bool composed = composite(commands, base, m_host->overlayTexture(), 0, target.get());
    QRhiReadbackResult result;
    auto updates = m_rhi->nextResourceUpdateBatch();
    updates->readBackTexture(QRhiReadbackDescription(texture.get()), &result);
    commands->resourceUpdate(updates);
    m_rhi->endOffscreenFrame();
    m_rhi->finish();
    releaseSwapchainResources();
    if (!composed || result.data.isEmpty()) {
        return {};
    }
    QImage image(reinterpret_cast<const uchar *>(result.data.constData()), result.pixelSize.width(),
                 result.pixelSize.height(), QImage::Format_RGBA8888);
    image = image.copy();
    return m_rhi->isYUpInFramebuffer() ? image.flipped(Qt::Vertical) : image;
}
