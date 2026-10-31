#include <QtGlobal>
#include "SceneLayerHost.h"

#include <QColor>
#include <QDebug>
#ifdef Q_OS_LINUX
#include <QElapsedTimer>
#endif
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickGraphicsDevice>
#include <QQuickItem>
#include <QQuickRenderControl>
#include <QQuickRenderTarget>
#include <QQuickWindow>
#include <rhi/qrhi.h>

// Qt 的 Vulkan 类型同时受构建特性和 SDK 头文件可用性约束。
#if QT_CONFIG(vulkan) && __has_include(<vulkan/vulkan.h>) && !defined(Q_OS_DARWIN)
#include <QVulkanInstance>
#define RHINE_HAVE_VULKAN_TYPES 1
#else
#define RHINE_HAVE_VULKAN_TYPES 0
#endif

namespace {
/** 给离屏窗口提供真实宿主，供对话框定位、DPR 与输入法查询使用。 */
class LayerRenderControl final : public QQuickRenderControl {
  public:
    explicit LayerRenderControl(QWindow *window) : m_window(window) {
    }
    QWindow *renderWindow(QPoint *offset) override {
        if (offset) {
            *offset = {};
        }
        return m_window;
    }

  private:
    QWindow *m_window = nullptr;
};
} // namespace

namespace {

// 初始尺寸只作兜底（与 Main.qml 的 Window 默认尺寸一致）。离屏目标建好后再由调用方
// 用真实窗口尺寸 resize() 重建；这样 start() 的签名不必依赖窗口类型。
constexpr QSize kFallbackSize(1280, 720);

// 与 Main.qml 的 Window.color 一致：3D 层要带上应用底色。否则 FG 合成后
// 3D 纹理的透明区会变成黑色，而默认路径下窗口底色是 #e7e7e1。
const QColor kSceneClearColor(0xe7, 0xe7, 0xe1);

} // namespace

#ifdef Q_OS_LINUX
SceneLayerHost::SceneLayerHost() {
    if (qEnvironmentVariableIsSet("RHINE_LAYER_SAFETY_FRAMES")) {
        m_safetyFrames = qEnvironmentVariableIntValue("RHINE_LAYER_SAFETY_FRAMES");
        m_safetyCountdown = qMax(1, m_safetyFrames);
    }
    m_layerProbe = qEnvironmentVariableIsSet("RHINE_LAYER_PROBE");
    // A03：版本驱动的置脏默认是关的。理由：兜底间隔（20 帧）本来就是为"异步资源到达没有
    // 信号"准备的，把置脏切到版本号之后，这条兜底就是唯一的可见性保障；没有实机比对之前
    // 不能直接把默认路径换掉，所以做成"开关 + 可回退"，探针里能同时看到两种来源的计数。
    m_revisionMode = qEnvironmentVariableIntValue("RHINE_LAYER_REVISION") == 1;
}
#else
SceneLayerHost::SceneLayerHost() = default;
#endif

SceneLayerHost::~SceneLayerHost() {
    teardown();
}

bool SceneLayerHost::fail(const QString &message) {
    m_lastError = message;
    m_valid = false;
    qWarning().noquote() << "SceneLayerHost:" << message;
    return false;
}

bool SceneLayerHost::start(QQmlEngine &engine, const QUrl &scene3dUrl, const QUrl &overlayUrl, QRhi *rhi,
                           QVulkanInstance *vulkanInstance, QWindow *visibleWindow) {
#ifdef Q_OS_WIN
    m_visibleWindow = visibleWindow;
#else
    m_visibleWindow = rhi && rhi->backend() == QRhi::Metal ? visibleWindow : nullptr;
#endif
    // 失败时立刻回收半成品：调用方会回退到默认路径，本对象可能被直接丢弃，
    // 不能把还挂着 QRhi 引用的窗口/纹理留给析构时机不确定的路径。
    if (!startInternal(engine, scene3dUrl, overlayUrl, rhi, vulkanInstance)) {
        teardown();
        return false;
    }
    return true;
}

bool SceneLayerHost::startInternal(QQmlEngine &engine, const QUrl &scene3dUrl, const QUrl &overlayUrl,
                                   QRhi *rhi, QVulkanInstance *vulkanInstance) {
    if (m_valid) {
        return fail(QStringLiteral("start() 被重复调用"));
    }
    if (!rhi) {
        return fail(QStringLiteral("传入的 QRhi 为空，无法建立离屏目标"));
    }
    if (scene3dUrl.isEmpty() || overlayUrl.isEmpty()) {
        return fail(QStringLiteral("场景 URL 无效：scene3d=%1 overlay=%2")
                        .arg(scene3dUrl.toString(), overlayUrl.toString()));
    }

    m_rhi = rhi;
    m_size = kFallbackSize;
    m_lastError.clear();

    // 两个场景各自一个 QQuickRenderControl：一个 RenderControl 每帧换 render target
    // 会触发 Qt 重新初始化渲染目标（QQuickWindow::setRenderTarget 文档明确警告），
    // 拆成两个后各自固定一个 target，代价稳定，UI 层还能按需重渲。
    m_scene.control = std::make_unique<LayerRenderControl>(m_visibleWindow);
    m_overlay.control = std::make_unique<LayerRenderControl>(m_visibleWindow);
    m_scene.window = std::make_unique<QQuickWindow>(m_scene.control.get());
    m_overlay.window = std::make_unique<QQuickWindow>(m_overlay.control.get());

    // 关键：Qt 6.12 没有 initialize(QRhi*) 重载。共享同一个 QRhi 的公开入口是
    // setGraphicsDevice(fromRhi(rhi))；之后 initialize() 不会再自建 QRhi。
    // 两层必须共用同一个 QRhi，FG 才能直接采样 3D 纹理做插值。
    const QQuickGraphicsDevice device = QQuickGraphicsDevice::fromRhi(rhi);
    m_scene.window->setGraphicsDevice(device);
    m_overlay.window->setGraphicsDevice(device);

#if RHINE_HAVE_VULKAN_TYPES
    // QQuickRenderControl::initialize() 在 Vulkan 下强制要求窗口上有 QVulkanInstance
    // （Qt 内部要查实例级扩展/能力），只给 fromRhi(rhi) 是不够的。
    if (vulkanInstance) {
        m_scene.window->setVulkanInstance(vulkanInstance);
        m_overlay.window->setVulkanInstance(vulkanInstance);
    }
#else
    // Metal 等后端不需要 Vulkan 实例。
    Q_UNUSED(vulkanInstance);
#endif

    m_scene.window->setColor(kSceneClearColor);
    // UI 层必须透明清屏，否则 FG 合成时会把整帧盖住。
    m_overlay.window->setColor(Qt::transparent);

#ifdef Q_OS_LINUX
    // 各层分别接收 Qt 的正式更新信号；回调只标脏与安排下一步，不递归渲染。
    // Qt 的 renderRequested/sceneChanged 在本工程里是**噪音级**频率（实测每帧数十次），
    // 用它标脏等于退回"每帧重渲"。这里只让它把下一帧排上队，标脏交给两处：
    //   1) Engine 的真实内容信号 sceneUpdated / hudUpdated（PresentationShell 转发）
    //   2) renderFrame() 里的周期性兜底（覆盖异步资源加载等无信号的情况）
#else
    // 两层分别接收 Qt 的正式更新信号；回调只标脏与安排下一步，不递归渲染。
#endif
    const auto watch = [this](Layer &layer) {
        const auto invalidate = [this, &layer] {
#ifdef Q_OS_LINUX
            ++m_dirtyQt;
#else
            layer.dirty = true;
#endif
            if (requestRender) {
                requestRender();
            }
        };
        QObject::connect(layer.control.get(), &QQuickRenderControl::renderRequested, layer.window.get(),
                         invalidate);
        QObject::connect(layer.control.get(), &QQuickRenderControl::sceneChanged, layer.window.get(),
                         invalidate);
    };
    watch(m_scene);
    watch(m_overlay);

    // 两个窗口都不 show()：RenderControl 下没有原生窗口，show() 会破坏离屏语义。
    if (!m_scene.control->initialize()) {
        return fail(QStringLiteral("3D 场景 QQuickRenderControl::initialize() 失败"));
    }
    if (!m_overlay.control->initialize()) {
        return fail(QStringLiteral("UI 场景 QQuickRenderControl::initialize() 失败"));
    }

    // 如果 Qt 没有复用传入的 QRhi（例如图形后端不匹配），两张纹理就不在同一设备上，
    // FG 无法采样。宁可失败回退，也不要跑到合成阶段才炸。
    if (m_scene.control->rhi() != rhi || m_overlay.control->rhi() != rhi) {
        return fail(QStringLiteral("QQuickRenderControl 没有复用传入的 QRhi（图形后端可能不匹配）"));
    }

    applyLayerGeometry(m_scene);
    applyLayerGeometry(m_overlay);

    if (!createLayerTargets(m_scene, "3D")) {
        return false;
    }
    if (!createLayerTargets(m_overlay, "UI")) {
        return false;
    }

    if (!loadLayer(m_scene, engine, scene3dUrl, "3D")) {
        return false;
    }
    if (!loadLayer(m_overlay, engine, overlayUrl, "UI")) {
        return false;
    }

    m_valid = true;
    qInfo().noquote() << QStringLiteral("SceneLayerHost: 双场景宿主就绪，离屏尺寸 %1x%2")
                             .arg(m_size.width())
                             .arg(m_size.height());
    return true;
}

bool SceneLayerHost::createLayerTargets(Layer &layer, const char *name) {
    if (!m_rhi || !layer.window) {
        return fail(QStringLiteral("%1 层离屏目标创建时状态无效").arg(QLatin1String(name)));
    }
    if (m_size.isEmpty()) {
        return fail(QStringLiteral("%1 层离屏目标尺寸为空").arg(QLatin1String(name)));
    }

    // RenderTarget 让纹理能作为颜色附件，UsedAsTransferSource 让 FG 能采样/拷贝它。
    layer.texture = m_rhi->newTexture(QRhiTexture::RGBA8, pixelSize(), 1,
                                      QRhiTexture::RenderTarget | QRhiTexture::UsedAsTransferSource);
    layer.texture->setName(QByteArray("fg-") + name + "-color");
    if (!layer.texture->create()) {
        releaseLayerTargets(layer);
        return fail(QStringLiteral("%1 层颜色纹理创建失败（%2x%3）")
                        .arg(QLatin1String(name))
                        .arg(pixelSize().width())
                        .arg(pixelSize().height()));
    }

    // Qt Quick 的二维批次仍会启用深度测试，裁剪也可能使用模板；目标必须提供对应附件。
    QRhiTextureRenderTargetDescription description{QRhiColorAttachment(layer.texture)};
    if (m_rhi->backend() == QRhi::Metal) {
        layer.depthStencil = m_rhi->newRenderBuffer(QRhiRenderBuffer::DepthStencil, pixelSize());
        if (!layer.depthStencil->create()) {
            releaseLayerTargets(layer);
            return fail(QStringLiteral("%1 层深度模板附件创建失败").arg(QLatin1String(name)));
        }
        description.setDepthStencilBuffer(layer.depthStencil);
    }
    layer.renderTarget = m_rhi->newTextureRenderTarget(description);
    layer.renderTarget->setName(QByteArray("fg-") + name + "-target");
    layer.renderPass = layer.renderTarget->newCompatibleRenderPassDescriptor();
    if (!layer.renderPass) {
        releaseLayerTargets(layer);
        return fail(QStringLiteral("%1 层 render pass 描述符创建失败").arg(QLatin1String(name)));
    }
    layer.renderTarget->setRenderPassDescriptor(layer.renderPass);
    if (!layer.renderTarget->create()) {
        releaseLayerTargets(layer);
        return fail(QStringLiteral("%1 层 QRhiTextureRenderTarget::create() 失败").arg(QLatin1String(name)));
    }

    // setRenderTarget 只能在渲染线程调用，且不要每帧换；这里只在 start()/resize() 里做。
    auto target = QQuickRenderTarget::fromRhiRenderTarget(layer.renderTarget);
#ifdef Q_OS_WIN
    target.setDevicePixelRatio(m_ratio);
#else
    target.setDevicePixelRatio(m_rhi->backend() == QRhi::Metal ? m_ratio : 1.0);
#endif
    layer.window->setRenderTarget(target);
    return true;
}

void SceneLayerHost::releaseLayerTargets(Layer &layer) {
    // 先摘掉窗口对 target 的引用，再销毁底层 QRhi 资源，避免窗口持有悬空指针。
    if (layer.window) {
        layer.window->setRenderTarget(QQuickRenderTarget());
    }
    delete layer.renderTarget;
    layer.renderTarget = nullptr;
    delete layer.renderPass;
    layer.renderPass = nullptr;
    delete layer.texture;
    layer.texture = nullptr;
    delete layer.depthStencil;
    layer.depthStencil = nullptr;
}

bool SceneLayerHost::loadLayer(Layer &layer, QQmlEngine &engine, const QUrl &url, const char *name) {
    QQmlComponent component(&engine, url);
    if (component.isError()) {
        for (const QQmlError &error : component.errors()) {
            qWarning().noquote() << "SceneLayerHost:" << name << "QML 错误:" << error.toString();
        }
        return fail(QStringLiteral("%1 层 QML 载入失败：%2").arg(QLatin1String(name), url.toString()));
    }

    QObject *object = component.create();
    if (!object) {
        return fail(QStringLiteral("%1 层 QML 根对象创建失败：%2").arg(QLatin1String(name), url.toString()));
    }

    QQuickItem *item = qobject_cast<QQuickItem *>(object);
    if (!item) {
        // 传进来的是 Window 之类的根节点：RenderControl 下没有原生窗口，不能挂载。
        qWarning().noquote() << "SceneLayerHost:" << name << "QML 根节点不是 Item，拒绝挂载";
        delete object;
        return fail(QStringLiteral("%1 层 QML 根节点不是 Item：%2").arg(QLatin1String(name), url.toString()));
    }

    item->setParent(layer.window->contentItem());
    item->setParentItem(layer.window->contentItem());
    item->setSize(QSizeF(m_size));
    item->setTransformOrigin(QQuickItem::TopLeft);
    item->setScale(1.0);
    layer.rootItem = item;
    return true;
}

QSize SceneLayerHost::pixelSize() const {
    return QSize(qMax(1, qRound(m_size.width() * m_ratio)), qMax(1, qRound(m_size.height() * m_ratio)));
}

void SceneLayerHost::setPixelRatio(qreal ratio) {
    if (!m_valid) {
        return;
    }
    ratio = qBound(1.0, ratio, 4.0);
    if (qFuzzyCompare(ratio, m_ratio)) {
        return;
    }
    m_ratio = ratio;
    m_scene.dirty = true;
    m_overlay.dirty = true;
    // 比例变了等于渲染目标尺寸变了，必须重建，否则 QML 只会画进纹理一角。
    releaseLayerTargets(m_scene);
    releaseLayerTargets(m_overlay);
    applyLayerGeometry(m_scene);
    applyLayerGeometry(m_overlay);
    if (!m_suspended) {
        createLayerTargets(m_scene, "3D");
        createLayerTargets(m_overlay, "UI");
    }
    qInfo().noquote() << "SceneLayerHost: 离屏层放大" << m_ratio << "倍，物理像素" << pixelSize();
}

void SceneLayerHost::applyLayerGeometry(Layer &layer) {
    if (!layer.window) {
        return;
    }
    // Windows 启用逻辑尺寸修复
#ifdef Q_OS_WIN
    const bool logicalCoordinates = true;
#else
    const bool logicalCoordinates = m_rhi->backend() == QRhi::Metal;
#endif
    const QSize windowSize = logicalCoordinates ? m_size : pixelSize();
    layer.window->resize(windowSize);
    if (QQuickItem *content = layer.window->contentItem()) {
        content->setSize(QSizeF(windowSize));
    }
    if (layer.rootItem) {
        layer.rootItem->setSize(QSizeF(m_size));
        layer.rootItem->setTransformOrigin(QQuickItem::TopLeft);
        layer.rootItem->setScale(logicalCoordinates ? 1.0 : m_ratio);
    }
}

bool SceneLayerHost::renderLayer(Layer &layer, const char *name) {
    QQuickRenderControl *control = layer.control.get();
    if (!control || !layer.renderTarget) {
        return fail(QStringLiteral("%1 层尚未就绪就调用了 renderFrame()").arg(QLatin1String(name)));
    }

    // 官方推荐的顺序：polishItems() 在 beginFrame() 之前，sync()/render() 必须在
    // beginFrame()/endFrame() 之间（QQuickRenderControl 文档的更新步骤示例）。
    layer.dirty = false;
#ifdef Q_OS_LINUX
    const auto blendMs = [](double prev, qint64 ns) { return prev * 0.8 + double(ns) / 1e6 * 0.2; };
    QElapsedTimer stage;
    stage.start();
#endif
    control->polishItems();
#ifdef Q_OS_LINUX
    layer.polishMs = blendMs(layer.polishMs, stage.nsecsElapsed());
    stage.restart();
#endif
    control->beginFrame();
#ifdef Q_OS_LINUX
    layer.beginMs = blendMs(layer.beginMs, stage.nsecsElapsed());
    stage.restart();
#endif
    // beginFrame() 不返回状态；command buffer 为空是最直接的失败信号（例如设备丢失）。
    if (!control->commandBuffer()) {
        control->endFrame();
        return fail(QStringLiteral("%1 层 beginFrame() 没有拿到 command buffer").arg(QLatin1String(name)));
    }
    // 注意：Qt 6 的 sync() 在成功路径上无条件返回 true（只有"没有窗口/未 beginFrame/
    // 没有 command buffer"三条错误路径才返回 false），所以它的返回值**不能**用来判断
    // "这一层本帧是否真的产出了新内容"。是否重渲只由 dirty 标记决定，上层用
    // sceneRenderCount() 的差分判断"有没有新场景"，这里保持无条件累加。
    control->sync();
#ifdef Q_OS_LINUX
    // 三段计时：sync 是 CPU（同步场景图），render 是 CPU（录制命令），endFrame 是
    // 提交并等 GPU。三段谁大，决定了 18ms 该从 CPU 侧还是 GPU 侧下手。
    layer.syncMs = blendMs(layer.syncMs, stage.nsecsElapsed());
    stage.restart();
#endif
    control->render();
#ifdef Q_OS_LINUX
    layer.recordMs = blendMs(layer.recordMs, stage.nsecsElapsed());
    stage.restart();
#endif
    control->endFrame();
#ifdef Q_OS_LINUX
    layer.submitMs = blendMs(layer.submitMs, stage.nsecsElapsed());
#endif
    return true;
}

/** 隐藏超过宽限期后释放场景图与目标，QML 和业务状态继续保留。 */
void SceneLayerHost::releaseGraphics() {
    if (!m_valid || m_suspended) {
        return;
    }
    m_rhi->finish();
    for (Layer *layer : {&m_scene, &m_overlay}) {
        releaseLayerTargets(*layer);
        layer->control->invalidate();
        layer->dirty = true;
    }
    m_suspended = true;
}

bool SceneLayerHost::resumeGraphics() {
    if (!m_suspended) {
        return m_valid;
    }
    for (Layer *layer : {&m_scene, &m_overlay}) {
        if (!layer->control->initialize()) {
            return fail(QStringLiteral("恢复离屏场景图失败"));
        }
        applyLayerGeometry(*layer);
        if (!createLayerTargets(*layer, "恢复")) {
            return false;
        }
        layer->dirty = true;
    }
    m_suspended = false;
    return true;
}

bool SceneLayerHost::renderFrame() {
    // 失败原因已经在 fail() 里打印过一次，这里直接返回，避免每帧刷屏。
    if (!m_valid || !resumeGraphics()) {
        return false;
    }
#ifdef Q_OS_LINUX
    // GPU 探针（RHINE_GPU_PROBE=1）：把"CPU 花在录制"和"等 GPU 归还"分开。
    // 每 30 帧抽一次：进入前先排空队列量出积压，交出本帧后再排空量出本帧 GPU 成本。
    // 必须抽样：finish() 会打断流水，每帧都调会改变被测对象。
    static const bool gpuProbe = qEnvironmentVariableIntValue("RHINE_GPU_PROBE") == 1;
    static int probeFrame = 0;
    const bool sampling = gpuProbe && (++probeFrame % 30) == 0;
    double backlogMs = 0.0;
    QElapsedTimer probeTimer;
    if (sampling) {
        probeTimer.start();
        m_rhi->finish();
        backlogMs = double(probeTimer.nsecsElapsed()) / 1e6;
    }
    // 非 Metal 后端过去是**每帧强制置脏**：模型/纹理异步加载完成后引擎不一定发出带
    // visualChanged 的 sceneUpdated，一旦完全按脏标记剔除，3D 房间几何就会永远不出现
    // （实机验证过：去掉后背景模型缺失，改回立即恢复）。代价是静止画面也每帧重渲两层
    // （3D 约 6~9ms + UI 约 5~7ms），而主界面这类页面的内容每秒只变二三十次。
    //
    // 这里改成「周期性兜底」：每 m_safetyFrames 帧补脏一次，把异步资源的最坏可见延迟
    // 压到 ~0.3s，其余帧完全交给 Qt 的 renderRequested/sceneChanged 与显式标脏。
    // 兜底间隔可用 RHINE_LAYER_SAFETY_FRAMES 调（<=0 表示恢复每帧置脏）。
#endif
    if (m_rhi->backend() != QRhi::Metal) {
#ifdef Q_OS_LINUX
        if (m_safetyFrames <= 0) {
            // 排障开关：恢复"每帧强制置脏"的旧行为（RHINE_LAYER_SAFETY_FRAMES=0）
            m_scene.dirty = true;
            m_overlay.dirty = true;
        } else if (--m_safetyCountdown <= 0) {
            m_safetyCountdown = m_safetyFrames;
            ++m_dirtySafety;
            m_scene.dirty = true;
            m_overlay.dirty = true;
        }
#else
        m_scene.dirty = true;
        m_overlay.dirty = true;
#endif
    }
#ifdef Q_OS_LINUX
    // 挂起释放后 control 可能为空，与 dirty 一起判断，避免对空控制对象录制。
    if (m_scene.dirty && m_scene.control) {
        QElapsedTimer layerTimer;
        layerTimer.start();
#else
    if (m_scene.dirty) {
#endif
        if (!renderLayer(m_scene, "3D")) {
            return false;
        }
#ifdef Q_OS_LINUX
        // 分层计时：单帧 17ms 到底花在 3D 层还是 UI 层，是决定优化方向的唯一依据。
        m_sceneLayerMs = m_sceneLayerMs * 0.8 + layerTimer.nsecsElapsed() / 1e6 * 0.2;
#endif
        ++m_sceneRenders;
    }
    if (m_overlay.dirty) {
#ifdef Q_OS_LINUX
        QElapsedTimer layerTimer;
        layerTimer.start();
#endif
        if (!renderLayer(m_overlay, "UI")) {
            return false;
        }
#ifdef Q_OS_LINUX
        m_overlayLayerMs = m_overlayLayerMs * 0.8 + layerTimer.nsecsElapsed() / 1e6 * 0.2;
#endif
        ++m_overlayRenders;
    }
#ifdef Q_OS_LINUX
    // 置脏来源探针（RHINE_LAYER_PROBE=1）：判断"每帧重渲"到底是 Qt 信号还是兜底。
    if (m_layerProbe) {
        static quint64 lastQt = 0, lastSafety = 0, lastScene = 0, lastOverlay = 0;
        static quint64 lastSceneDirty = 0, lastOverlayDirty = 0, lastRevision = 0;
        if (++m_probeFrames % 60 == 0) {
            // A03：把"版本推进"单列一栏。总和（源 场景/HUD/兜底/qt/版本）就是这 60 帧的
            // 置脏次数，重渲次数应当不大于它——两者相差多少，就说明有多少置脏被合并了。
            qWarning("图层探针: 近60帧 3D重渲 %llu 次 / UI重渲 %llu 次 | 置脏来源 场景 %llu HUD %llu "
                     "兜底 %llu qt噪音 %llu 版本 %llu | 版本模式 %s | 场景版本 %llu HUD版本 %llu",
                     m_sceneRenders - lastScene, m_overlayRenders - lastOverlay,
                     m_dirtyScene - lastSceneDirty, m_dirtyOverlay - lastOverlayDirty,
                     m_dirtySafety - lastSafety, m_dirtyQt - lastQt, m_dirtyRevision - lastRevision,
                     m_revisionMode ? "开" : "关", m_resourceRevision, m_hudResourceRevision);
            lastSceneDirty = m_dirtyScene;
            lastOverlayDirty = m_dirtyOverlay;
            lastQt = m_dirtyQt;
            lastSafety = m_dirtySafety;
            lastRevision = m_dirtyRevision;
            lastScene = m_sceneRenders;
            lastOverlay = m_overlayRenders;
        }
    }
    if (sampling) {
        probeTimer.restart();
        m_rhi->finish();
        const double frameGpuMs = double(probeTimer.nsecsElapsed()) / 1e6;
        qInfo().noquote() << QStringLiteral(
                                 "GPU探针: 进入前积压 %1 ms | 本帧 GPU %2 ms | 3D层 %3 ms | UI层 %4 ms")
                                 .arg(backlogMs, 0, 'f', 1)
                                 .arg(frameGpuMs, 0, 'f', 1)
                                 .arg(m_sceneLayerMs, 0, 'f', 1)
                                 .arg(m_overlayLayerMs, 0, 'f', 1);
    }
#endif
    return true;
}

QQuickWindow *SceneLayerHost::overlayWindow() const {
    return m_overlay.window.get();
}

QQuickWindow *SceneLayerHost::sceneWindow() const {
    return m_scene.window.get();
}

QQuickItem *SceneLayerHost::overlayRootItem() const {
    return m_overlay.rootItem;
}

void SceneLayerHost::resize(QSize size) {
    if (!m_valid) {
        qWarning().noquote() << "SceneLayerHost: resize() 在宿主未就绪时被调用，已忽略";
        return;
    }
    if (size.isEmpty()) {
        qWarning().noquote() << "SceneLayerHost: resize() 收到空尺寸，已忽略";
        return;
    }
    if (size == m_size) {
        return;
    }

    // 先释放旧目标再建新的：窗口不能指向已销毁的 QRhiRenderTarget。
    releaseLayerTargets(m_scene);
    releaseLayerTargets(m_overlay);
    m_size = size;
    applyLayerGeometry(m_scene);
    applyLayerGeometry(m_overlay);
    if (m_suspended) {
        return;
    }
    if (!createLayerTargets(m_scene, "3D")) {
        return; // fail() 已把 m_valid 置 false，调用方应回退并销毁本对象
    }
    if (!createLayerTargets(m_overlay, "UI")) {
        return;
    }
    qInfo().noquote()
        << QStringLiteral("SceneLayerHost: 离屏目标已重建为 %1x%2").arg(m_size.width()).arg(m_size.height());
    // 换了渲染目标，两张纹理的内容都是新的（未定义），必须重画一次。
    m_scene.dirty = true;
    m_overlay.dirty = true;
}

#ifdef Q_OS_LINUX
void SceneLayerHost::requestSceneContent() {
    if (!m_valid) {
        return;
    }
    ++m_dirtyScene;
    m_scene.dirty = true;
    if (requestRender) {
        requestRender();
    }
}

void SceneLayerHost::requestOverlayContent() {
    if (!m_valid) {
        return;
    }
    ++m_dirtyOverlay;
    m_overlay.dirty = true;
    if (requestRender) {
        requestRender();
    }
}

#endif

/**
 * A03：按内容版本置脏。
 *
 * 与 requestSceneContent()/requestOverlayContent() 的区别只在于"要不要重复置脏"：
 * 版本没前进就说明这一轮没有新内容，直接返回；前进一次只置脏一次。注意它不会自己
 * 触发 requestRender()——调用方（PresentationShell）每帧本来就会来问一次脏标记，
 * 再从这里回调一次只会把同一帧的渲染请求叠成两份。
 *
 * 默认（RHINE_LAYER_REVISION 未开）只记录版本，不改变任何置脏行为，等价于优化前；
 * 非 Linux 后端沿用原有的"每帧强制置脏"，这里同样只记录。
 */
void SceneLayerHost::setResourceRevision(quint64 sceneRevision, quint64 hudRevision) {
#ifdef Q_OS_LINUX
    if (m_revisionMode && m_valid) {
        // 两路分开置脏：HUD 每帧都变的时候不能顺手把 3D 层也拖去重渲。
        // 版本相同就直接返回——同一份内容被推第二次不该再多画一帧。
        if (sceneRevision != m_resourceRevision) {
            m_resourceRevision = sceneRevision;
            m_scene.dirty = true;
            ++m_dirtyRevision;
        }
        if (hudRevision != m_hudResourceRevision) {
            m_hudResourceRevision = hudRevision;
            m_overlay.dirty = true;
            ++m_dirtyRevision;
        }
        return;
    }
#endif
    m_resourceRevision = sceneRevision;
    m_hudResourceRevision = hudRevision;
}
QRhiTexture *SceneLayerHost::sceneTexture() const {
    return m_scene.texture;
}

QRhiTexture *SceneLayerHost::overlayTexture() const {
    return m_overlay.texture;
}

void SceneLayerHost::teardown() {
    // 先解绑 target，再让 Qt 释放场景图，最后销毁自建 QRhi 资源。
    // 逆序销毁（overlay 在前）没有语义依赖，只是让日志顺序与创建顺序对称。
    for (Layer *layer : {&m_overlay, &m_scene}) {
        if (layer->window) {
            layer->window->setRenderTarget(QQuickRenderTarget());
        }
        // rhi() 在 initialize() 成功前恒为 null；用它判断"确实初始化过"，
        // 避免在 start() 中途失败时对未初始化的 control 调 invalidate()。
        if (layer->control && layer->control->rhi()) {
            layer->control->invalidate();
        }
        // 根 Item 的父项是 contentItem，随窗口析构一起销毁，这里只清观察指针。
        layer->rootItem = nullptr;
        layer->window.reset();
        layer->control.reset();
        delete layer->renderTarget;
        layer->renderTarget = nullptr;
        delete layer->renderPass;
        layer->renderPass = nullptr;
        delete layer->texture;
        layer->texture = nullptr;
        delete layer->depthStencil;
        layer->depthStencil = nullptr;
    }
    m_rhi = nullptr;
    m_valid = false;
}
