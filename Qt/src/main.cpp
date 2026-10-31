#include <QtGlobal>
#include "AppIdentity.h"
#include "AppStorage.h"
#include "Engine.h"
#include "fg/FgCapability.h"
#ifdef Q_OS_LINUX
#include "fg/FgConfig.h"
#endif
#include "render/PresentationShell.h"
#include "render/RenderPolicy.h"
#include "FrameProfiler.h"
#include "GraphicsBackend.h"
#include "Hud.h"
#include "LinuxGraphics.h"
#include "RhiScene.h"
#ifndef Q_OS_IOS
#include "PlaybackConnection.h"
#endif
#ifdef Q_OS_MACOS
#include "InterfaceWindowMac.h"
#endif
#ifdef Q_OS_IOS
#include "IOSWindow.h"
#endif
#include <QDir>
#include <QFileInfo>
#include <QFontDatabase>
#include <QGuiApplication>
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
#include "DesktopTray.h"
#include <QApplication>
#endif
#include <QIcon>
#include <QLoggingCategory>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickGraphicsConfiguration>
#include <QQuickWindow>
#include <QSurfaceFormat>
#include <QSettings>
#include <QSGRendererInterface>
#include <QStandardPaths>
#include <QTimer>
#include <cstdio>
#include <cstring>
#ifndef Q_OS_IOS
#include <memory>
#endif
/* Qt 的 Vulkan 类型只在「Qt 带 Vulkan 特性」且「应用侧能看到 vulkan.h」时声明：
 *   qvulkaninstance.h:  #if QT_CONFIG(vulkan) || defined(Q_QDOC)
 *                      #if __has_include(<vulkan/vulkan.h>) || defined(Q_QDOC)
 *   qrhi_platform.h:    #if (QT_CONFIG(vulkan) && __has_include(<vulkan/vulkan.h>)) || defined(Q_QDOC)
 * 只判 QT_CONFIG(vulkan) 会在装了 Qt 但没装 Vulkan SDK 的机器上
 * （如 Windows runner：Qt 自带 Vulkan 特性、系统无 vulkan.h）编译出使用未声明类型的代码，
 * 表现为 QVulkanInstance 不完整类型与 VK_SUCCESS 未定义。守卫必须同时覆盖两半。 */
#if QT_CONFIG(vulkan) && __has_include(<vulkan/vulkan.h>) && !defined(Q_OS_DARWIN)
#include <QVulkanFunctions>
#include <QVulkanInstance>
#define RHINE_HAVE_VULKAN_TYPES 1
#else
#define RHINE_HAVE_VULKAN_TYPES 0
#endif
int makeIcon(const QString &directory);
#ifndef Q_OS_IOS
bool runPlaybackServiceChecks(const QString &resources, const QString &executable, const QString &gui);
bool runWindowTransitionChecks();
#endif
#ifdef Q_OS_WIN
#include "WindowsTaskbar.h"
bool runWindowsTaskbarChecks(Engine &engine);
void initializeWindowsGraphics();
#endif
#if !defined(Q_OS_DARWIN)
/**
 * 探测是否存在可用的 Vulkan 物理设备。
 * Qt 的 QSG_RHI_BACKEND 没有后端回退列表，强制指定失败会直接终止，因此必须先探测。
 */
static bool vulkanDeviceAvailable() {
#if RHINE_HAVE_VULKAN_TYPES
    QVulkanInstance probe;
    probe.setApiVersion(QVersionNumber(1, 0));
    if (!probe.create()) {
#ifdef Q_OS_LINUX
        qWarning() << "Vulkan: 无法创建探测实例（loader 缺失或驱动不可用）";
#endif
        return false;
    }
    // QVulkanInstance 不公开设备列表，直接按 Vulkan API 枚举，避免依赖 QVulkanWindow。
    quint32 devices = 0;
#ifdef Q_OS_LINUX
    const auto result =
        probe.functions()->vkEnumeratePhysicalDevices(probe.vkInstance(), &devices, nullptr);
    if (result != VK_SUCCESS) {
        // 只报"Vulkan 不可用"会把排障推回用户：这里必须区分驱动/loader 报错与根本没有设备。
        qWarning() << "Vulkan: vkEnumeratePhysicalDevices 失败，VkResult" << int(result);
        return false;
    }
    if (devices == 0) {
        qWarning() << "Vulkan: 物理设备数为 0（缺 /dev/dri、ICD 未安装或驱动被禁用）";
        return false;
    }
    return true;
#else
    return probe.functions()->vkEnumeratePhysicalDevices(probe.vkInstance(), &devices, nullptr) ==
               VK_SUCCESS &&
           devices > 0;
#endif
#else
    return false;
#endif
}
#endif
/**
 * 选择场景图后端：显式 RHINE_GRAPHICS 优先，否则可用时使用 Vulkan。
 * 3D 场景与全屏后处理链在 Vulkan 上可省去驱动侧的隐式状态验证，Windows 与 Linux 均适用。
 */
/** 图形设置的持久化位置：与 Host::preference 相同（Windows 便携 data，其余平台为应用配置）。
 *  设置页经 Host::preference 写入 panel/graphics-backend，这里必须读同一个文件，
 *  否则设置页的切换在下次启动时读不到——上一轮正是败在这里。 */
static QSettings graphicsSettings() {
    return AppStorage::settings();
}
/** 应用命名后端；Vulkan 先探测物理设备，不可用时返回 false 由调用方回退。
 *  仅在非 macOS 下编译：macOS 只提供 Metal，本函数的两个调用点都在 #else 分支里，
 *  而 vulkanDeviceAvailable() 同样只在非 macOS 下定义。 */
#if !defined(Q_OS_DARWIN)
static bool applyNamedBackend(const QString &requested) {
#if defined(Q_OS_WIN) && RHINE_ENABLE_D3D12_BACKEND
    if (requested == "d3d12") {
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Direct3D12);
        RhineGraphics::setActiveBackend(QStringLiteral("d3d12"));
        return true;
    }
#endif
    if (requested == "opengl") {
        QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
        RhineGraphics::setActiveBackend(QStringLiteral("opengl"));
        return true;
    }
    if (requested == "vulkan") {
        if (!vulkanDeviceAvailable()) {
            qWarning() << "Vulkan is unavailable; falling back to Vulkan/OpenGL selection.";
            return false;
        }
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Vulkan);
        RhineGraphics::setActiveBackend(QStringLiteral("vulkan"));
        return true;
    }
    return false;
}
#endif
static void selectGraphicsBackend() {
    // 停用的 D3D 后端
    if (!qEnvironmentVariableIsEmpty("QSG_RHI_BACKEND")) {
        const auto overrideBackend = qEnvironmentVariable("QSG_RHI_BACKEND").trimmed().toLower();
#ifdef Q_OS_DARWIN
        RhineGraphics::setActiveBackend(overrideBackend);
        return;
#else
        if (applyNamedBackend(overrideBackend)) {
            return;
        }
        qWarning() << "QSG_RHI_BACKEND" << overrideBackend << "is unavailable; selecting Vulkan/OpenGL.";
        qunsetenv("QSG_RHI_BACKEND");
#endif
    }
#if defined(Q_OS_DARWIN)
    RhineGraphics::setActiveBackend(QStringLiteral("metal"));
    // Qt 在 macOS 只提供 Metal，Vulkan 需经 MoltenVK 转换层，性能低于原生 Metal。
    const auto requested = qEnvironmentVariable("RHINE_GRAPHICS").toLower();
    if (!requested.isEmpty() && requested != "auto" && requested != "metal") {
        qWarning() << "RHINE_GRAPHICS" << requested << "is unavailable on macOS; using Metal.";
    }
#else
    auto settings = graphicsSettings();
    const auto requested = qEnvironmentVariable("RHINE_GRAPHICS").toLower();
    // 显式设置的环境变量只对本次启动生效：写回配置会把一次诊断运行变成用户偏好，
    // 设置页随后就会显示成后端"自己改回去了"。
    if (!requested.isEmpty() && requested != "auto") {
        if (applyNamedBackend(requested)) {
            qInfo() << "RHINE_GRAPHICS" << requested << "applied for this launch only.";
            return;
        }
        // 已移除的 d3d11 或探测失败的 Vulkan 不能就此返回：Qt 在 Windows 的平台默认
        // 后端是 D3D11，返回等于把它又请回来，所以继续走下面的默认选择。
        qWarning() << "RHINE_GRAPHICS" << requested << "is unavailable; using the default backend.";
    }
    // 其次是设置页/上次启动保存的选择（与 Host::preference 的 "panel/" 前缀一致）。
    const auto saved = settings.value("panel/graphics-backend").toString().toLower();
    if (!saved.isEmpty()) {
        if (applyNamedBackend(saved)) {
            qInfo() << "Using saved graphics backend:" << saved;
            return;
        }
        // 旧配置里可能还留着已移除的 d3d11；同样不能直接返回，否则会落回 D3D11。
        qWarning() << "Saved graphics backend" << saved << "is unavailable; using the default backend.";
    }
    // Windows 与 Linux 共用 Vulkan 优先、OpenGL 回退；不能交给 Qt 的平台默认选择。
    if (vulkanDeviceAvailable()) {
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Vulkan);
        RhineGraphics::setActiveBackend(QStringLiteral("vulkan"));
        qInfo() << "No backend configured; Vulkan detected and selected as default.";
    } else {
#if defined(Q_OS_WIN) && RHINE_ENABLE_D3D12_BACKEND
        // 不能交给平台默认：Qt 在 Windows 的默认后端是 D3D11，本项目已彻底移除该后端，
        // 必须显式指定 D3D12，否则会把 D3D11 请回来。
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Direct3D12);
        RhineGraphics::setActiveBackend(QStringLiteral("d3d12"));
        qInfo() << "No backend configured; Vulkan unavailable, using Direct3D 12 on Windows.";
#else
        QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
        RhineGraphics::setActiveBackend(QStringLiteral("opengl"));
        qInfo() << "Vulkan unavailable; using OpenGL.";
#endif
    }
#endif
}
/**
 * 垂直同步：关闭时把交换链的 swapInterval 设为 0，允许帧率超过屏幕刷新率。
 * 必须在创建任何 QQuickWindow 之前写入默认格式，Qt 的 RHI 交换链会据此选择呈现模式。
 * Apple 平台的 Metal 呈现由系统合成器按刷新率回收 drawable，该开关没有实际效果，
 * 因此固定按关闭写入，设置页也不再提供这一项。
 */
static void applyVSyncSetting() {
#ifdef Q_OS_DARWIN
    auto format = QSurfaceFormat::defaultFormat();
    format.setSwapInterval(0);
    QSurfaceFormat::setDefaultFormat(format);
#else
    if (!qEnvironmentVariableIsEmpty("RHINE_VSYNC")) {
        return;
    }
    if (graphicsSettings().value("panel/vsync").toString() != "off") {
        return;
    }
    auto format = QSurfaceFormat::defaultFormat();
    format.setSwapInterval(0);
    QSurfaceFormat::setDefaultFormat(format);
#endif
}
/** 超采样倍率持久化：配置里设 graphics/supersample=2 即渲染 2 倍分辨率再缩回窗口。 */
static void applySupersampleSetting() {
    if (!qEnvironmentVariableIsEmpty("RHINE_SUPERSAMPLE")) {
        return;
    }
    const auto sample = graphicsSettings().value("panel/supersample", 1).toInt();
    if (sample > 1) {
        qputenv("RHINE_SUPERSAMPLE", QByteArray::number(qMin(sample, 2)));
    }
}
/**
 * 抗锯齿模式：panel/aa-mode = off/fxaa/ssaa，默认关闭且互斥单选。
 * 倍率 panel/aa-scale 只对 SSAA 生效，与渲染分辨率相乘（75% × 125% = 93.75%）。
 */
static void applyAntialiasingSetting() {
    if (qEnvironmentVariableIsEmpty("RHINE_AA_MODE")) {
        qputenv("RHINE_AA_MODE", graphicsSettings().value("panel/aa-mode", "off").toString().toUtf8());
    }
    if (qEnvironmentVariableIsEmpty("RHINE_AA_SCALE")) {
        qputenv("RHINE_AA_SCALE",
                QByteArray::number(graphicsSettings().value("panel/aa-scale", 125).toInt()));
    }
    // FSR 专属的两档设置：超分档位决定内部渲染分辨率，锐化强度决定 RCAS 强度。
    // 两者都只在 FSR 模式下被渲染器读取，非 FSR 模式留着也不影响。
    if (qEnvironmentVariableIsEmpty("RHINE_FSR_QUALITY")) {
        qputenv("RHINE_FSR_QUALITY",
                graphicsSettings().value("panel/fsr-quality", "native").toString().toUtf8());
    }
    if (qEnvironmentVariableIsEmpty("RHINE_FSR_SHARPNESS")) {
        qputenv("RHINE_FSR_SHARPNESS",
                QByteArray::number(graphicsSettings().value("panel/fsr-sharpness", 50).toInt()));
    }
    // MSAA 采样数：只在设置里选过才写入，未选过则保持空，让渲染器走"目标 4x + 设备能力下取"。
    if (qEnvironmentVariableIsEmpty("RHINE_MSAA")) {
        const auto samples = graphicsSettings().value("panel/msaa", 0).toInt();
        if (samples > 1) {
            qputenv("RHINE_MSAA", QByteArray::number(samples));
        }
    }
}
/**
 * 帧生成：panel/fg = on 时开启。渲染器每帧读 RHINE_FG，与抗锯齿模式互相独立，
 * 所以单独持久化、单独下发，切换时不需要重启。
 */
static void applyFrameGenerationSetting() {
    // FSR 插帧（帧生成）已从设置界面下线：启动时不再读取配置里的 panel/fg，恒按"关"下发。
    // 显式 RHINE_FG=on 仍保留为排障对照（呈现层据此决定要不要接管窗口并插帧）。
    if (qEnvironmentVariableIsEmpty("RHINE_FG")) {
        qputenv("RHINE_FG", "off");
    }
#ifdef Q_OS_DARWIN
    // Apple 的窗口合成器始终按刷新率回收 drawable，垂直同步开关没有实际效果。
    // 固定关闭并在设置页隐藏；显式 RHINE_FG_VSYNC 仍留给排障对照。
    if (qEnvironmentVariableIsEmpty("RHINE_FG_VSYNC")) {
        qputenv("RHINE_FG_VSYNC", "off");
    }
#else
    // 呈现层的垂直同步也来自设置页：只有关掉 vsync，呈现层才会去选 MAILBOX。
    // 实测这台机器上 FIFO 只给到约半个刷新率（47.4fps），MAILBOX 能到 125fps。
    if (qEnvironmentVariableIsEmpty("RHINE_FG_VSYNC")) {
        const auto vsync = graphicsSettings().value("panel/vsync", "on").toString();
        qputenv("RHINE_FG_VSYNC", vsync.compare("off", Qt::CaseInsensitive) == 0 ? "off" : "on");
    }
#endif
}
/**
 * 渲染分辨率百分比：panel/render-scale=75 表示按窗口的 75% 渲染，再由最终合成通道放大。
 * 集成显卡上这是最直接的一档性能/画质交换，50 大致相当于像素数降到 1/4。
 */
static void applyRenderScaleSetting() {
    if (!qEnvironmentVariableIsEmpty("RHINE_RENDER_SCALE")) {
        return;
    }
    const auto percent = graphicsSettings().value("panel/render-scale", 100).toInt();
    if (percent > 0 && percent != 100) {
        qputenv("RHINE_RENDER_SCALE", QByteArray::number(qBound(50, percent, 100)));
    }
}

/** 服务请求打开界面：恢复最小化状态并请求激活，不改变窗口归属。 */
static void activateWindow(QWindow *window) {
    if (!window) {
        return;
    }
    const auto states = window->windowStates() & ~Qt::WindowMinimized;
    window->setWindowStates(states);
    window->setVisible(true);
    window->setWindowStates(states);
    window->raise();
    window->requestActivate();
}
/**
 * 建立应用身份、Qt 引擎和原生窗口。
 * 离线测试与正式播放沿用同一入口，资源只从独立应用读取。
 */
int main(int argc, char **argv) {
#ifdef Q_OS_WIN
    const auto storageError = AppStorage::initializePortable(AppStorage::executableDirectory());
    if (!storageError.isEmpty()) {
        std::fprintf(stderr, "%s\n", storageError.toUtf8().constData());
        return 1;
    }
#endif
    // 两个平台都明确使用 FFmpeg，设备切换和重连由播放器独立处理。
    // 必须在 Qt 初始化多媒体前选择后端，显式环境变量仍可用于兼容性对照。
    if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND")) {
        qputenv("QT_MEDIA_BACKEND", "ffmpeg");
    }
    // Windows GUI 子系统默认可能将 Qt 日志送到调试器；测试必须写入 CTest 的标准错误管道。
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--self-test") == 0 || std::strcmp(argv[i], "--playback-gui-test") == 0 ||
            std::strcmp(argv[i], "--taskbar-self-test") == 0) {
            qInstallMessageHandler(
                [](QtMsgType type, const QMessageLogContext &context, const QString &message) {
                    const auto text = qFormatLogMessage(type, context, message).toUtf8();
                    std::fprintf(stderr, "%s\n", text.constData());
                    std::fflush(stderr);
                });
            break;
        }
    }
    QLoggingCategory::setFilterRules("qt.qml.usedbeforedeclared=false");
#ifdef Q_OS_MACOS
    // Qt 需在创建 QGuiApplication 前找到包内平台插件；某些 kit 会忽略资源目录里的 qt.conf。
    const QDir bundledPlugins(QFileInfo(QString::fromLocal8Bit(argv[0])).absolutePath() + "/../PlugIns");
    if (bundledPlugins.exists("platforms/libqcocoa.dylib")) {
        qputenv("QT_PLUGIN_PATH", bundledPlugins.absolutePath().toUtf8());
    }
#endif
    // 组织名与程序名决定 QSettings 的落点。Linux 选显卡要在创建应用实例之前读
    // panel/gpu-index，因此这三个静态设置必须提前落位（它们不依赖 QCoreApplication 实例）。
    QCoreApplication::setOrganizationName(AppIdentity::Organization);
    QCoreApplication::setOrganizationDomain(AppIdentity::Id);
    QCoreApplication::setApplicationName(AppIdentity::Id);
#ifdef Q_OS_WIN
    initializeWindowsGraphics();
#endif
#ifdef Q_OS_LINUX
    // Linux 没有 QT_D3D_ADAPTER_INDEX 那样的单一入口，选择只能落成厂商环境变量，
    // 所以同样要早于任何 QQuickWindow——RHI 在创建窗口时就定下了用哪块卡。
    initializeLinuxGraphics();
#endif
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
    QApplication application(argc, argv);
#else
    QGuiApplication application(argc, argv);
#endif
    application.setWindowIcon(QIcon(":/icons/icon-256.png"));
    QCoreApplication::setApplicationVersion(AppUpdater::currentVersion());
    QGuiApplication::setApplicationDisplayName(AppIdentity::DisplayName);
    const auto args = application.arguments();
#ifndef Q_OS_IOS
    // 界面回归使用隔离的用户目录；必须在读取任何偏好之前建立。
    const bool playbackGuiTest = args.contains("--playback-gui-test");
    if (playbackGuiTest) {
        const auto directory = args.value(args.indexOf("--playback-gui-test") + 1);
        if (directory.isEmpty() || !AppStorage::initializePortable(directory).isEmpty()) {
            return 1;
        }
    }
#endif
    // 必须在创建任何 QQuickWindow 之前确定后端；组织名先落位，配置路径才能落到应用数据目录。
    selectGraphicsBackend();
    applyVSyncSetting();
    applySupersampleSetting();
    applyRenderScaleSetting();
    applyAntialiasingSetting();
    applyFrameGenerationSetting();
    // 写给设置界面的能力快照：先按"没编进来"落盘，下面的 FG 分支真正接管后再改写。
    // 设置界面在 RhineCore 里，不能反向 include 依赖 vulkan.h 的实现，只能读这份结论。
#if defined(RHINE_FSR3_VULKAN) && RHINE_FSR3_VULKAN
    RhineFg::publishCapability(true, false, false);
#else
    RhineFg::publishCapability(false, false, false, QStringLiteral("此构建未编入 Vulkan 帧生成"));
#endif
    if (args.contains("--make-icon")) {
        return makeIcon(args.value(args.indexOf("--make-icon") + 1));
    }
    QString root = qEnvironmentVariable("RHINE_RESOURCES");
    if (root.isEmpty()) {
        // iOS 使用专用资源目录
        const auto base = QCoreApplication::applicationDirPath();
#ifdef Q_OS_MACOS
        const QStringList candidates{base + "/../Resources"};
#elif defined(Q_OS_IOS)
        const QStringList candidates{base + "/RhineAssets"};
#else
        const QStringList candidates{base + "/resources", base + "/../resources"};
#endif
        for (const auto &candidate : candidates) {
            if (QFileInfo(candidate + "/slots.json").exists()) {
                root = QDir(candidate).absolutePath();
                break;
            }
        }
        if (root.isEmpty()) {
            root = QDir::currentPath() + "/output/resources";
        }
    }
    const bool test = args.contains("--self-test");
    const bool offline =
        test || args.contains("--offline") || qEnvironmentVariableIntValue("RHINE_OFFLINE") == 1;
#ifdef Q_OS_WIN
    if (args.contains("--taskbar-self-test")) {
        Engine direct(root, true);
        return runWindowsTaskbarChecks(direct) ? 0 : 1;
    }
#endif
    if (test) {
#ifndef Q_OS_IOS
#ifdef Q_OS_MACOS
        if (QGuiApplication::platformName() == "cocoa") {
            // 无窗口的测试控制器不能占据第二个 Dock 身份或参与被测的调度组。
            qputenv("QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM", "1");
            configureTestControllerAsAccessory();
        }
#endif
        const auto service = PlaybackConnection::serviceExecutable();
        // 进程生命周期回归先于会话回归，使用原始隔离环境。
        if (!runWindowTransitionChecks() ||
            !runPlaybackServiceChecks(root, service, application.applicationFilePath())) {
            return 1;
        }
#endif
        Engine direct(root, offline);
        return direct.selfTest();
    }
    QString profilePath;
    if (args.contains("--frame-profile")) {
        profilePath = args.value(args.indexOf("--frame-profile") + 1);
        if (profilePath.isEmpty() || profilePath.startsWith("--")) {
            qWarning() << "--frame-profile requires an output CSV path";
            return 1;
        }
    }
    // 桌面版：音频、账号与播放队列由独立后台服务持有，界面进程只负责渲染。
    // 服务随界面启动并与其生命周期绑定：界面退出或崩溃都会停止播放并结束服务。
    std::unique_ptr<PlaybackConnection> playback;
#ifndef Q_OS_IOS
    if (!offline) {
        playback = std::make_unique<PlaybackConnection>();
        QString error;
        if (!connectPlaybackService(*playback, root, error)) {
            qCritical().noquote() << error;
            return 1;
        }
        if (playbackGuiTest && !playback->call("hello")["offlineTest"].toBool()) {
            qCritical("GUI 回归只允许连接隔离的离线服务");
            return 1;
        }
#ifdef Q_OS_LINUX
        // 带上本次已经解析出的后端：后台服务据此判断在跑的界面进程是否还符合当前配置。
        const auto attached =
            playback->call("attach", {{"pid", double(application.applicationPid())},
                                      {"backend", RhineGraphics::activeBackend()}});
        if (attached["existing"].toBool()) {
            // 这两条分支都只让本进程退出；不打日志的话，"点了没有窗口"与启动失败无法区分。
            if (attached["restarted"].toBool()) {
                qInfo().noquote() << "图形后端已变更，后台服务正在按新配置重建界面进程。";
            } else {
                qInfo().noquote() << "已有界面进程在运行，本次启动只激活该窗口（后端"
                                  << RhineGraphics::activeBackend() << "）。";
            }
            return 0;
        }
#else
        const auto attached = playback->call("attach", {{"pid", double(application.applicationPid())}});
        if (attached["existing"].toBool()) {
            return 0;
        }
#endif
        // 服务在界面连接断开时自行停止，退出流程里不再发送可能阻塞的同步命令。
        QObject::connect(playback.get(), &PlaybackConnection::quitRequested, &application,
                         &QCoreApplication::quit, Qt::QueuedConnection);
#ifdef Q_OS_LINUX
        // 图形后端切换后由服务要求重建界面。挂在 application 上而不是某个窗口对象上：
        // 呈现层路径和直接 QML 路径都要能退出，只挂 PlaybackSessionWindow 会漏掉后者。
        QObject::connect(
            playback.get(), &PlaybackConnection::restartRequested, &application,
            [] { QCoreApplication::quit(); }, Qt::QueuedConnection);
#endif
        QTimer::singleShot(0, playback.get(), [raw = playback.get()] { raw->call("interface.ready"); });
    }
#endif
    auto backend = std::make_unique<Engine>(root, offline, nullptr, playback.get());
    auto profiler = std::make_unique<FrameProfiler>(backend.get(), profilePath);
    QObject::connect(backend.get(), &Engine::performanceRequested, profiler.get(),
                     &FrameProfiler::toggleVisible);
    backend->start();
    // 声明顺序决定析构顺序：QML 引擎必须晚于业务引擎，才能先销毁 QML 对象。
    QQmlApplicationEngine engine;
    qmlRegisterType<RhiScene>("Rhine.Native", 1, 0, "RhiScene");
    qmlRegisterType<Hud>("Rhine.Native", 1, 0, "Hud");
    qmlRegisterUncreatableType<Engine>("Rhine.Native", 1, 0, "Engine", "Provided by application");
    // 无边框
    if (qEnvironmentVariableIntValue("RHINE_FRAMELESS_PREVIEW") == 1) {
        engine.setInitialProperties({{"windowsFrameless", true}});
    }
#ifdef Q_OS_WIN
    // 创建窗口时先保持隐藏，配置管线缓存后再显示，避免首次渲染写到系统缓存。
    engine.setInitialProperties({{"visible", false}, {"windowsFrameless", true}});
#endif
    const auto fontId = QFontDatabase::addApplicationFont(root + "/RhineMiSans-regular.otf");
    const auto families = QFontDatabase::applicationFontFamilies(fontId);
    engine.rootContext()->setContextProperty("rhineFontFamily",
                                             families.isEmpty() ? QString("sans-serif") : families.first());
    engine.rootContext()->setContextProperty("rhine", backend.get());
    engine.rootContext()->setContextProperty("profiler", profiler.get());
    if (!offline && RHINE_RELEASE_BUILD) {
        QTimer::singleShot(8000, backend.get(), [raw = backend.get()] {
            if (raw->host.preference("auto-update") != "off") {
                raw->host.updater.check();
            }
        });
    }

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &application,
        [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    // Apple Metal 与桌面 Vulkan 复用受控呈现，插值能力独立于呈现路径。
    // RHINE_FG_LAYER=off 可强制使用 Qt Quick 默认窗口；启动失败同样回退。
    const bool fgLayerDisabled =
        qEnvironmentVariable("RHINE_FG_LAYER").compare("off", Qt::CaseInsensitive) == 0;
    // 离屏与最小平台没有原生窗口系统，呈现层无法创建交换链；必须直接走 Qt Quick 默认路径。
    // 否则无显示环境（CI、--playback-gui-test）会在接管 Metal 窗口时崩溃。
    const auto platformName = QGuiApplication::platformName();
    const bool hasNativeWindowSystem =
        platformName != QStringLiteral("offscreen") && platformName != QStringLiteral("minimal");
#ifdef Q_OS_LINUX
    // 插帧关闭时不接管呈现层（RHINE_FG_LAYER=on 可强制接管做对照）。
    // 依据：全屏 2560x1440、主界面列表页长按 ↓ 的实测内容帧（引擎 render/s）——
    //   接管呈现层 20.3/s（间隔均 51~74ms）vs Qt 默认路径 27.5/s（间隔均 33.8ms），
    //   Qt 路径高 35%，已与 OpenGL 的 31.5/s 接近。
    // 原因：呈现层在 fg=off 时唯一做的事就是"每帧重渲重上屏"，而它把两层离屏录制、
    // 合成与 present 全压在 GUI 线程上（QQuickRenderControl 的 render() 在调用线程执行），
    // 直接挤掉了引擎节拍。不开插帧时它没有收益，只有成本。
    // 代价：切换插帧从此需要重启应用才生效（呈现层在启动时决定是否接管）。
    const bool fgForced = qEnvironmentVariable("RHINE_FG_LAYER").compare("on", Qt::CaseInsensitive) == 0;
    const bool interpolationWanted =
        fgForced || RhineFg::parseBool(qgetenv("RHINE_FG"), false);
#endif
    const bool fgCandidate = !test && !args.contains("--capture") && !fgLayerDisabled &&
#ifdef Q_OS_LINUX
                             hasNativeWindowSystem && interpolationWanted &&
#else
                             hasNativeWindowSystem &&
#endif
                             PresentationShell::supportsBackend(RhineGraphics::activeBackend());
#ifdef Q_OS_WIN
    // 呈现层启动会显示窗口并处理原生消息，必须提前接收 Explorer 的任务栏就绪通知。
    WindowsTaskbar taskbar(backend.get());
#endif
    // 排障：接管与否只看这一行。之前出现过"设了 RHINE_FG_LAYER=on 才接管"的怪现象，
    // 把每个输入的实测值打出来，比逐条读代码猜快得多。
    qWarning().noquote() << "FG gate: candidate" << fgCandidate << "layerDisabled" << fgLayerDisabled
                         << "test" << test << "backend" << RhineGraphics::activeBackend() << "compiledIn"
                         << PresentationShell::compiledIn();
    if (fgCandidate) {
        // FG 路径从不调用 QQmlApplicationEngine::load()（Main.qml 不加载，两个离屏层
        // 都是手工用 QQuickRenderControl 建的），而"QML 里的 Qt.quit() 真能退出进程"
        // 正是 load() 内部接的那根线。少了它，Overlay.qml 的 Ctrl+Q 会打出
        // "Signal QQmlEngine::quit() emitted, but no receivers connected to handle it."
        // 然后什么都不发生——快捷键看着触发了，进程却不退。
        auto shell = std::make_unique<PresentationShell>(engine, *backend, RhineGraphics::activeBackend());
        // 退出顺序有讲究：先拆呈现层（VkSwapchainKHR / VkSurfaceKHR），再让事件循环退出。
        // 反过来的话窗口先被关闭，驱动 WSI 会对已销毁的 wl_surface 做 roundtrip，
        // 退出时 SIGABRT/SIGSEGV（实测两条都复现过）。Win32 的 HWND、X11 的 Window
        // 是同一类问题，所以这条顺序修在公共路径，不进平台分支。
        QObject::connect(&engine, &QQmlEngine::quit, shell.get(), &PresentationShell::requestQuit);
        if (shell->start() && shell->run() == 0) {
#ifdef Q_OS_IOS
            configureIOSWindow(shell->window(), backend.get());
            // 自检在 UIKit 完成启动后运行；排队回退，确保退出呈现回调后才释放 GPU 资源。
            QObject::connect(
                shell.get(), &PresentationShell::startupFailed, &application,
                [&, raw = shell.get()] {
                    const auto error = raw->lastError();
                    qWarning().noquote() << "FG: 呈现层启动失败，回退默认路径：" << error;
                    raw->shutdown();
                    raw->window()->hide();
                    RhineFg::publishInactive(error);
                    engine.loadFromModule("RhineMusic", "Main");
                    if (engine.rootObjects().isEmpty()) {
                        application.exit(1);
                        return;
                    }
                    auto *fallbackWindow = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
                    backend->setWindow(fallbackWindow);
                    fallbackWindow->installEventFilter(backend.get());
                    configureIOSWindow(fallbackWindow, backend.get());
                    profiler->attach(fallbackWindow);
                    QObject::connect(
                        fallbackWindow, &QQuickWindow::sceneGraphInvalidated, backend.get(),
                        [raw = backend.get()] { raw->recordResourceRelease(); }, Qt::DirectConnection);
                },
                Qt::QueuedConnection);
#endif
#ifndef Q_OS_IOS
            if (playbackGuiTest) {
                qInfo("PLAYBACK_GUI_READY");
                if (args.contains("--playback-test-quit")) {
                    QTimer::singleShot(700, &application, &QCoreApplication::quit);
                } else if (args.contains("--playback-test-close")) {
                    // 真实窗口关闭路径：验证关窗即退出，并由服务断连检测回收音频进程。
                    auto *target = shell->window();
                    QTimer::singleShot(700, target, [target] {
                        qInfo("PLAYBACK_GUI_CLOSE_REQUESTED");
                        target->close();
                    });
                }
            }
            if (playback) {
                QObject::connect(
                    playback.get(), &PlaybackConnection::activateRequested, shell->window(),
                    [window = shell->window()] { activateWindow(window); }, Qt::QueuedConnection);
            }
#endif
            // FG 使用独立的 QWindow，也必须保留任务栏控制和关闭后驻留托盘的行为。
#ifdef Q_OS_WIN
            taskbar.bindWindow(shell->window());
#endif
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
            std::unique_ptr<DesktopTray> tray;
            tray = std::make_unique<DesktopTray>(shell->window(), &application);
#endif
            QObject::connect(&application, &QCoreApplication::aboutToQuit, shell.get(),
                             [raw = shell.get()] { raw->shutdown(); });
            return application.exec();
        }
        qWarning().noquote() << "FG: 呈现层启动失败，回退默认路径：" << shell->lastError();
        RhineFg::publishInactive(shell->lastError());
    }
    engine.loadFromModule("RhineMusic", "Main");
    if (engine.rootObjects().isEmpty()) {
        return 1;
    }
    auto window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    QQuickGraphicsConfiguration graphics;
#ifdef Q_OS_WIN
    graphics.setAutomaticPipelineCache(false);
    const auto pipelineCache = AppStorage::cacheDirectory() + "/shaders/pipeline.cache";
    if (QFileInfo::exists(pipelineCache)) {
        graphics.setPipelineCacheLoadFile(pipelineCache);
    }
    graphics.setPipelineCacheSaveFile(pipelineCache);
#endif
    // 让 Qt Quick 的 RHI 开启时间戳查询；渲染器在每帧结束时读取
    // lastCompletedGpuTime() 并发布到性能面板。后端不支持时该值保持为空。
    graphics.setTimestamps(true);
    // 登记"已经请求过时间戳"：渲染器据此把"支持但没请求"和"请求了但没样本"分开报。
    // 这里和 VulkanPresentationBackend 各登记一次，因为存在只走其中一条路径的启动方式。
    RhineRender::requestTimestamps();
    window->setGraphicsConfiguration(graphics);
#ifdef Q_OS_WIN
    taskbar.bindWindow(window);
    window->show();
#endif
    backend->setWindow(window);
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
    std::unique_ptr<DesktopTray> tray;
    tray = std::make_unique<DesktopTray>(window, &application);
#endif
#ifdef Q_OS_IOS
    configureIOSWindow(window, backend.get());
#endif
    window->installEventFilter(backend.get());
    profiler->attach(window);
#ifndef Q_OS_IOS
    if (playbackGuiTest) {
        qInfo("PLAYBACK_GUI_READY");
        if (args.contains("--playback-test-quit")) {
            QTimer::singleShot(700, &application, &QCoreApplication::quit);
        } else if (args.contains("--playback-test-close")) {
            QTimer::singleShot(700, window, [window] {
                qInfo("PLAYBACK_GUI_CLOSE_REQUESTED");
                window->close();
            });
        }
    }
    if (playback) {
        QObject::connect(
            playback.get(), &PlaybackConnection::activateRequested, window,
            [window] { activateWindow(window); }, Qt::QueuedConnection);
    }
#endif
    // 短暂切换窗口继续复用 GPU；隐藏或最小化超过两秒才释放图形设备和可重建缓存。
    auto backgroundRelease = new QTimer(window);
    backgroundRelease->setSingleShot(true);
    backgroundRelease->setInterval(2000);
    QObject::connect(backgroundRelease, &QTimer::timeout, window, [raw = backend.get(), window] {
        if (window->isVisible() && window->visibility() != QWindow::Minimized) {
            return;
        }
        raw->trimMemory();
        window->setPersistentSceneGraph(false);
        window->setPersistentGraphics(false);
        window->releaseResources();
    });
    QObject::connect(window, &QWindow::visibilityChanged, window,
                     [window, backgroundRelease](QWindow::Visibility visibility) {
                         if (visibility == QWindow::Hidden || visibility == QWindow::Minimized) {
                             backgroundRelease->start();
                         } else {
                             backgroundRelease->stop();
                             window->setPersistentSceneGraph(true);
                             window->setPersistentGraphics(true);
                         }
                     });
    QObject::connect(
        window, &QQuickWindow::sceneGraphInvalidated, backend.get(),
        [raw = backend.get()] { raw->recordResourceRelease(); }, Qt::DirectConnection);
    if (args.contains("--capture")) {
        const auto index = args.indexOf("--capture");
        const auto path = args.value(index + 1);
        // 第三个参数可选场景模式（archive / detail），便于直接验证某个状态的渲染输出。
        const auto captureMode = args.value(index + 2);
        if (path.isEmpty()) {
            return 1;
        }
        auto poll = new QTimer(backend.get());
        poll->setInterval(200);
        bool *reviewed = new bool(false);
        QObject::connect(poll, &QTimer::timeout, backend.get(), [&, path, captureMode, poll, reviewed] {
            if (!backend->ready()) {
                return;
            }
            if (!*reviewed) {
                *reviewed = true;
                backend->scene.review(captureMode.isEmpty() || captureMode.startsWith("--")
                                          ? QStringLiteral("archive")
                                          : captureMode);
                return;
            }
            backend->step(50);
            if (backend->frame().isEmpty()) {
                return;
            }
            poll->stop();
            delete reviewed;
            backend->snapshot(path);
            auto window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
            if (window) {
                window->grabWindow().save(path + "/qt-window.png");
            }
            application.quit();
        });
        poll->start();
    }
    return application.exec();
}
