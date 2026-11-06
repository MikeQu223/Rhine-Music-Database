#include "CrashDiagnostics.h"
#include "DiagnosticsDirectory.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QTimer>
#include <cstdio>
#include <cstdlib>
#include <exception>

#if defined(RHINE_CRASHPAD)
#include "BuildIdentity.h"
#include "client/annotation.h"
#include "client/crash_report_database.h"
#include "client/crashpad_client.h"
#include "client/settings.h"
#include "client/simulate_crash.h"
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QProcess>
#include <QQuickWindow>
#include <QSysInfo>
#include <QThread>
#include <QUuid>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <mutex>
#include <optional>
#include <sys/types.h>
#include <thread>
#include <rhi/qrhi.h>
#ifdef Q_OS_WIN
#include <windows.h>
#else
#include <pthread.h>
#endif

namespace {
constexpr long long HANG_THRESHOLD_MS = 5000;
constexpr long long SAMPLE_INTERVAL_MS = 2000;
constexpr int MAX_HANG_SAMPLES = 3;

long long monotonicMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

base::FilePath nativePath(const QString &path) {
#ifdef Q_OS_WIN
    return base::FilePath(path.toStdWString());
#else
    return base::FilePath(path.toStdString());
#endif
}

struct RenderSlot {
    std::atomic<long long> startedMs{0};
    const char *stage = "idle";
    std::source_location source;
    crashpad::StringAnnotation<512> current{"rhine.render.current"};
    crashpad::StringAnnotation<512> completed{"rhine.render.completed"};
    crashpad::StringAnnotation<2048> configuration{"rhine.render.config"};
    crashpad::StringAnnotation<1024> resource{"rhine.render.resource"};
    unsigned long long threadId = 0;
};

std::array<RenderSlot, 16> renderSlots;
std::atomic<unsigned int> nextRenderSlot{0};
std::atomic<bool> enabled{false};
std::atomic<bool> messageHandlerInstalled{false};
std::atomic<bool> guiVisible{true};
QPointer<QQuickWindow> attachedWindow;
crashpad::StringAnnotation<128> reportKind{"rhine.capture"};
crashpad::StringAnnotation<128> guiState{"rhine.gui"};
crashpad::StringAnnotation<128> graphicsBackend{"rhine.graphics.backend"};
crashpad::StringAnnotation<64> hangThread{"rhine.hang.thread"};
struct MessageSlot {
    crashpad::StringAnnotation<16384> text{"rhine.qt"};
};
std::array<MessageSlot, 16> recentMessages;
crashpad::StringAnnotation<16384> fatalMessage{"rhine.qt"};
std::atomic_flag messageBusy = ATOMIC_FLAG_INIT;
std::atomic_flag fatalCaptured = ATOMIC_FLAG_INIT;
std::atomic<quint64> messageSequence{0};
QtMessageHandler previousMessageHandler = nullptr;
std::terminate_handler previousTerminate = nullptr;
crashpad::StringAnnotation<2048> cppException{"rhine.cpp.exception"};
thread_local RenderSlot *activeRenderSlot = nullptr;

/** 在 C++ 终止路径保存异常原文，再交回原有终止处理，不尝试恢复进程。 */
[[noreturn]] void captureTermination() noexcept {
    try {
        if (const auto exception = std::current_exception()) {
            std::rethrow_exception(exception);
        }
        cppException.Set("std::terminate");
    } catch (const std::exception &exception) {
        cppException.Set(exception.what());
    } catch (...) {
        cppException.Set("non-standard C++ exception");
    }
    if (previousTerminate) {
        previousTerminate();
    }
    std::abort();
}

unsigned long long currentThreadId() {
#ifdef Q_OS_WIN
    return GetCurrentThreadId();
#else
    uint64_t threadId = 0;
    pthread_threadid_np(nullptr, &threadId);
    return threadId;
#endif
}

/** 在 Qt 输出错误、尚未进入 abort 前保留原文；固定容量记录不执行磁盘写入。 */
void captureMessage(QtMsgType type, const QMessageLogContext &context, const QString &message) {
    const bool rendering = activeRenderSlot && activeRenderSlot->startedMs.load() > 0;
    const QByteArray category(context.category ? context.category : "default");
    const bool renderCategory = category.startsWith("qt.rhi") || category.startsWith("qt.scenegraph");
    if (type == QtFatalMsg ||
        ((type == QtWarningMsg || type == QtCriticalMsg) && (rendering || renderCategory))) {
        const bool busy = messageBusy.test_and_set(std::memory_order_acquire);
        const bool capture = type == QtFatalMsg ? !fatalCaptured.test_and_set() : !busy;
        if (capture) {
            const auto sequence = messageSequence.fetch_add(1);
            const char *level = "WARN";
            if (type == QtFatalMsg) {
                level = "FATAL";
            } else if (type == QtCriticalMsg) {
                level = "ERROR";
            }
            const QJsonObject record{
                {"time", QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)},
                {"level", level},
                {"sequence", qint64(sequence)},
                {"thread_id", qint64(currentThreadId())},
                {"category", QString::fromUtf8(category)},
                {"message", message.left(1024)},
                {"file", QString::fromUtf8(context.file ? context.file : "").left(512)},
                {"line", context.line},
                {"function", QString::fromUtf8(context.function ? context.function : "").left(512)},
            };
            const auto bytes = QJsonDocument(record).toJson(QJsonDocument::Compact);
            auto &annotation =
                type == QtFatalMsg ? fatalMessage : recentMessages[sequence % recentMessages.size()].text;
            annotation.Set(bytes.constData());
        }
        if (!busy) {
            messageBusy.clear(std::memory_order_release);
        }
    }
    if (previousMessageHandler) {
        previousMessageHandler(type, context, message);
    } else {
        const auto text = qFormatLogMessage(type, context, message).toUtf8();
        std::fprintf(stderr, "%s\n", text.constData());
        std::fflush(stderr);
    }
}

RenderSlot *threadSlot() {
    thread_local RenderSlot *slot = []() -> RenderSlot * {
        const auto index = nextRenderSlot.fetch_add(1);
        if (index >= renderSlots.size()) {
            return nullptr;
        }
        auto &result = renderSlots[index];
        result.threadId = currentThreadId();
        return &result;
    }();
    return slot;
}

void annotateStage(RenderSlot &slot) {
    char text[512];
    std::snprintf(text, sizeof(text), "thread=%llu stage=%s source=%s:%u function=%s", slot.threadId,
                  slot.stage, slot.source.file_name(), slot.source.line(), slot.source.function_name());
    slot.current.Set(text);
}

/** 关闭调试模式时结束本进程启动的报告进程及其解析子进程。 */
void terminateReporter(qint64 processId) {
    if (processId <= 0) {
        return;
    }
#ifdef Q_OS_WIN
    const auto process = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, DWORD(processId));
    if (!process) {
        return;
    }
    TerminateProcess(process, 0);
    WaitForSingleObject(process, 2000);
    CloseHandle(process);
#else
    // startDetached 会让报告进程成为会话首进程，按进程组结束可同时停掉 minidump-stackwalk。
    const auto group = -pid_t(processId);
    if (::kill(group, SIGTERM) != 0 && errno == ESRCH) {
        ::kill(pid_t(processId), SIGTERM);
    }
    for (int attempt = 0; attempt < 20; ++attempt) {
        if (::kill(pid_t(processId), 0) != 0 && errno == ESRCH) {
            return;
        }
        QThread::msleep(100);
    }
#endif
}

/** 运行中关闭时 handler 仍持有数据库元数据，逐条删除现场；目录留到下次以关闭状态启动时整体移除。 */
void deleteDatabaseReports(const QString &databaseDirectory) {
    auto database = crashpad::CrashReportDatabase::InitializeWithoutCreating(nativePath(databaseDirectory));
    if (!database) {
        return;
    }
    std::vector<crashpad::CrashReportDatabase::Report> pending;
    std::vector<crashpad::CrashReportDatabase::Report> completed;
    database->GetPendingReports(&pending);
    database->GetCompletedReports(&completed);
    pending.insert(pending.end(), completed.begin(), completed.end());
    for (const auto &report : pending) {
        database->DeleteReport(report.uuid);
    }
}

void removeNativeReports() {
    const QDir directory(diagnosticsDirectory());
    for (const auto &entry : directory.entryInfoList({"native-*"}, QDir::Files)) {
        QFile::remove(entry.absoluteFilePath());
    }
}

#ifdef Q_OS_WIN
QString werModulePath() {
    return QDir::toNativeSeparators(QCoreApplication::applicationDirPath() + "/crashpad_wer.dll");
}

void removeWerModule(const QString &path) {
    if (path.isEmpty()) {
        return;
    }
    const auto name = path.toStdWString();
    RegDeleteKeyValueW(
        HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\Windows Error Reporting\\RuntimeExceptionHelperModules",
        name.c_str());
}
#endif

} // namespace

struct CrashDiagnostics::State {
    crashpad::CrashpadClient client;
    std::atomic<long long> guiPulseMs{0};
    std::atomic<bool> loopStarted{false};
    std::atomic<bool> quitting{false};
    std::atomic<int> applicationState{int(Qt::ApplicationActive)};
    std::atomic<bool> stopped{false};
    std::mutex mutex;
    std::condition_variable wake;
    std::thread watchdog;
    QTimer heartbeat;
    qint64 reporterPid = 0;
    unsigned long long guiThreadId = 0;
    QString werPath;

    /** 独立于 GUI 和渲染线程检测阻塞；由 Crashpad 的进程外 handler 保存全部线程。 */
    void monitor();
};

void CrashDiagnostics::State::monitor() {
    long long previousTick = monotonicMs();
    long long graceUntil = 0;
    long long lastSample = 0;
    int samples = 0;
    std::unique_lock lock(mutex);
    while (!wake.wait_for(lock, std::chrono::milliseconds(250), [this] { return stopped.load(); })) {
        // 退出流程不再判定卡死，避免慢关闭被记录成异常。
        if (quitting.load()) {
            return;
        }
        const auto now = monotonicMs();
        // 系统休眠、调试暂停或严重调度延迟后留恢复窗口，不把停机时间当作卡死。
        if (now - previousTick > SAMPLE_INTERVAL_MS) {
            graceUntil = now + HANG_THRESHOLD_MS;
        }
        previousTick = now;
        // 事件循环启动前的加载时间不计入 GUI 心跳。
        if (!loopStarted.load() || now < graceUntil) {
            continue;
        }
        bool renderHung = false;
        unsigned long long renderThreadId = 0;
        long long oldestStart = 0;
        for (const auto &slot : renderSlots) {
            const auto started = slot.startedMs.load(std::memory_order_acquire);
            if (started > 0 && now - started >= HANG_THRESHOLD_MS &&
                (oldestStart == 0 || started < oldestStart)) {
                oldestStart = started;
                renderThreadId = slot.threadId;
                renderHung = true;
            }
        }
        // 应用隐藏、挂起或窗口不可见时系统会节流定时器，这种心跳间隔不是卡死。
        const int appState = applicationState.load();
        const bool guiHung = guiVisible.load() && appState != int(Qt::ApplicationHidden) &&
                             appState != int(Qt::ApplicationSuspended) &&
                             now - guiPulseMs.load() >= HANG_THRESHOLD_MS;
        if (!guiHung && !renderHung) {
            samples = 0;
            continue;
        }
        if (samples >= MAX_HANG_SAMPLES || now - lastSample < SAMPLE_INTERVAL_MS) {
            continue;
        }
        const auto threadText = QByteArray::number(renderHung ? renderThreadId : guiThreadId);
        hangThread.Set(threadText.constData());
        reportKind.Set(renderHung ? "hang.render" : "hang.gui");
        guiState.Set(quitting.load() ? "shutdown" : "running");
        CRASHPAD_SIMULATE_CRASH();
        hangThread.Clear();
        reportKind.Set("crash");
        lastSample = monotonicMs();
        previousTick = lastSample;
        ++samples;
    }
}
#else
struct CrashDiagnostics::State {};
#endif

CrashDiagnostics::CrashDiagnostics() = default;

CrashDiagnostics::~CrashDiagnostics() {
    stopInternal(false);
    m_state.reset();
}

/** 建立本地数据库、注册 Crashpad 并启动独立报告进程；重复启用直接复用当前实例。 */
bool CrashDiagnostics::start(QCoreApplication &application) {
#if defined(RHINE_CRASHPAD)
    if (enabled.load()) {
        return true;
    }
    const auto reportDirectory = diagnosticsDirectory();
    const auto databaseDirectory = QDir(reportDirectory).filePath(".crashpad");
    if (!QDir().mkpath(databaseDirectory)) {
        qCritical("Crashpad: cannot create diagnostics directory");
        return false;
    }
    const auto session = QUuid::createUuid().toString(QUuid::WithoutBraces);
    auto database = crashpad::CrashReportDatabase::Initialize(nativePath(databaseDirectory));
    if (!database || !database->GetSettings()->SetUploadsEnabled(false)) {
        qCritical("Crashpad: cannot initialize local database");
        return false;
    }
    const auto binaries = QCoreApplication::applicationDirPath();
#ifdef Q_OS_WIN
    const QString suffix = ".exe";
#else
    const QString suffix;
#endif
    const bool firstStart = !m_state;
    auto state = firstStart ? std::make_shared<State>() : m_state;
    if (firstStart) {
        const std::map<std::string, std::string> annotations{
            {"rhine.version", QCoreApplication::applicationVersion().toStdString()},
            {"rhine.commit", RHINE_COMMIT_SHA},
            {"rhine.session", session.toStdString()},
            {"rhine.system", QSysInfo::prettyProductName().toStdString()},
        };
        if (!state->client.StartHandler(nativePath(binaries + "/crashpad_handler" + suffix),
                                        nativePath(databaseDirectory), nativePath(databaseDirectory), "", "",
                                        annotations, {"--no-periodic-tasks"}, true, false)) {
            qCritical("Crashpad: handler startup failed");
            return false;
        }
        state->guiThreadId = currentThreadId();
        state->heartbeat.setInterval(1000);
        QObject::connect(&state->heartbeat, &QTimer::timeout, &application,
                         [weak = std::weak_ptr<State>(state)] {
                             if (const auto current = weak.lock()) {
                                 const auto window = attachedWindow.data();
                                 guiVisible.store(!window || window->isExposed());
                                 current->applicationState.store(int(QGuiApplication::applicationState()));
                                 current->guiPulseMs.store(monotonicMs());
                             }
                         });
        QObject::connect(&application, &QCoreApplication::aboutToQuit, &application,
                         [weak = std::weak_ptr<State>(state)] {
                             if (const auto current = weak.lock()) {
                                 current->quitting.store(true);
                                 current->heartbeat.stop();
                             }
                         });
        // handler 只在首次启用时注册；之后关闭再打开复用同一进程和异常端口。
        m_state = state;
    }
#ifdef Q_OS_WIN
    // 每次启用都登记 WER 模块，关闭时移除；fast-fail 不经过普通 SEH。
    state->werPath = werModulePath();
    const DWORD registration = 1;
    const auto werStatus = RegSetKeyValueW(
        HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\Windows Error Reporting\\RuntimeExceptionHelperModules",
        state->werPath.toStdWString().c_str(), REG_DWORD, &registration, sizeof(registration));
    if (werStatus != ERROR_SUCCESS || !state->client.RegisterWerModule(state->werPath.toStdWString())) {
        qWarning("Crashpad: WER registration failed; fast-fail coverage is unavailable");
    }
#endif
    QProcess worker;
    worker.setProgram(binaries + "/RhineCrashReporter" + suffix);
    worker.setArguments(
        {reportDirectory, databaseDirectory, QString::number(QCoreApplication::applicationPid())});
    worker.setStandardOutputFile(QProcess::nullDevice());
    worker.setStandardErrorFile(QProcess::nullDevice());
    qint64 reporterPid = 0;
    if (!worker.startDetached(&reporterPid)) {
        qCritical("Crashpad: text report worker startup failed; minidumps remain available");
        return false;
    }
    state->reporterPid = reporterPid;
    state->stopped.store(false);
    state->quitting.store(false);
    state->loopStarted.store(false);
    state->guiPulseMs.store(0);
    reportKind.Set("crash");
    if (!messageHandlerInstalled.exchange(true)) {
        previousMessageHandler = qInstallMessageHandler(captureMessage);
        previousTerminate = std::set_terminate(captureTermination);
    }
    // 事件循环已经运行时立即触发；启动阶段则等到 exec 开始后才恢复心跳判定。
    QTimer::singleShot(0, &application, [weak = std::weak_ptr<State>(state)] {
        if (const auto current = weak.lock()) {
            const auto window = attachedWindow.data();
            guiVisible.store(!window || window->isExposed());
            current->loopStarted.store(true);
            current->guiPulseMs.store(monotonicMs());
            current->applicationState.store(int(QGuiApplication::applicationState()));
        }
    });
    state->heartbeat.start();
    state->watchdog = std::thread([state] { state->monitor(); });
    m_state = state;
    enabled.store(true);
    return true;
#else
    Q_UNUSED(application);
    return false;
#endif
}

/** 调试模式关闭时停止本实例的采样、报告进程和全局钩子，并清空已有诊断数据。 */
void CrashDiagnostics::stop() {
    stopInternal(true);
}

void CrashDiagnostics::stopInternal(bool clearData) {
#if defined(RHINE_CRASHPAD)
    enabled.store(false);
    const auto state = m_state;
    if (state) {
        if (messageHandlerInstalled.exchange(false)) {
            qInstallMessageHandler(previousMessageHandler);
            previousMessageHandler = nullptr;
            std::set_terminate(previousTerminate);
            previousTerminate = nullptr;
        }
        state->heartbeat.stop();
        {
            std::lock_guard lock(state->mutex);
            state->stopped.store(true);
        }
        state->wake.notify_all();
        if (state->watchdog.joinable()) {
            state->watchdog.join();
        }
#ifdef Q_OS_WIN
        removeWerModule(state->werPath);
        state->werPath.clear();
#endif
        if (clearData) {
            terminateReporter(state->reporterPid);
            state->reporterPid = 0;
        }
    }
    if (clearData) {
        // 运行中 handler 仍持有数据库元数据，逐条清空现场；数据库目录留到下次关闭状态启动时移除。
        removeNativeReports();
        deleteDatabaseReports(QDir(diagnosticsDirectory()).filePath(".crashpad"));
    }
#else
    Q_UNUSED(clearData);
#endif
}

bool CrashDiagnostics::supported() {
#if defined(RHINE_CRASHPAD)
    return true;
#else
    return false;
#endif
}

/** 只删除崩溃诊断产物，保留性能面板写入同一目录的报告。 */
void CrashDiagnostics::clearHistory() {
#if defined(RHINE_CRASHPAD)
    removeNativeReports();
    const QDir directory(diagnosticsDirectory());
    QDir database(directory.filePath(".crashpad"));
#ifdef Q_OS_WIN
    removeWerModule(werModulePath());
#endif
    // 启动阶段没有本进程的 handler 占用，可以整体删除；被其他实例占用时退回逐条清空。
    if (!database.removeRecursively()) {
        deleteDatabaseReports(database.absolutePath());
    }
#endif
}

void CrashDiagnostics::setGraphicsBackend(const QString &backend) {
#if defined(RHINE_CRASHPAD)
    graphicsBackend.Set(backend.toStdString());
#else
    Q_UNUSED(backend);
#endif
}

/** 尺寸或模式变化时保存配置与实际设备身份，不在逐帧路径查询驱动。 */
void CrashDiagnostics::setRenderContext(QRhi *rhi, QSize render, QSize display, const QString &mode) {
#if defined(RHINE_CRASHPAD)
    if (!enabled.load()) {
        return;
    }
    auto slot = threadSlot();
    if (!slot) {
        return;
    }
    const auto device = rhi ? rhi->driverInfo() : QRhiDriverInfo{};
    const QJsonObject context{
        {"thread_id", qint64(slot->threadId)},
        {"backend", rhi ? rhi->backendName() : "unknown"},
        {"device", QString::fromUtf8(device.deviceName)},
        {"vendor_id", qint64(device.vendorId)},
        {"device_id", qint64(device.deviceId)},
        {"device_type", int(device.deviceType)},
        {"render_width", render.width()},
        {"render_height", render.height()},
        {"display_width", display.width()},
        {"display_height", display.height()},
        {"aa", mode.isEmpty() ? "none" : mode},
        {"fsr_quality_requested", qEnvironmentVariable("RHINE_FSR_QUALITY")},
        {"msaa_requested", qEnvironmentVariableIntValue("RHINE_MSAA")},
        {"supersample_requested", qEnvironmentVariableIntValue("RHINE_SUPERSAMPLE")},
        {"render_scale_requested", qEnvironmentVariableIntValue("RHINE_RENDER_SCALE")},
        {"qt_version", qVersion()},
    };
    slot->configuration.Set(QJsonDocument(context).toJson(QJsonDocument::Compact).constData());
#else
    Q_UNUSED(rhi);
    Q_UNUSED(render);
    Q_UNUSED(display);
    Q_UNUSED(mode);
#endif
}

/** 在调用 create 前保存资源参数，失败路径可同时取得调用位置与 Qt 的错误原文。 */
void CrashDiagnostics::recordResource(QRhiResource *resource) {
#if defined(RHINE_CRASHPAD)
    if (!enabled.load()) {
        return;
    }
    auto slot = threadSlot();
    if (!slot) {
        return;
    }
    QJsonObject fields{{"thread_id", qint64(slot->threadId)}};
    if (!resource) {
        fields["type"] = "null";
    } else {
        static constexpr const char *names[] = {
            "buffer",           "texture",        "sampler",          "render_buffer",     "render_pass",
            "swapchain_target", "texture_target", "bindings",         "graphics_pipeline", "swapchain",
            "compute_pipeline", "command_buffer", "shading_rate_map",
        };
        const auto type = resource->resourceType();
        fields["type"] = names[int(type)];
        if (resource->resourceType() == QRhiResource::Buffer) {
            const auto buffer = static_cast<QRhiBuffer *>(resource);
            fields["bytes"] = qint64(buffer->size());
            fields["usage"] = int(buffer->usage());
            fields["buffer_type"] = int(buffer->type());
        } else if (resource->resourceType() == QRhiResource::Texture) {
            const auto texture = static_cast<QRhiTexture *>(resource);
            fields["width"] = texture->pixelSize().width();
            fields["height"] = texture->pixelSize().height();
            fields["format"] = int(texture->format());
            fields["samples"] = texture->sampleCount();
            fields["flags"] = int(texture->flags());
        } else if (type == QRhiResource::RenderBuffer) {
            const auto buffer = static_cast<QRhiRenderBuffer *>(resource);
            fields["width"] = buffer->pixelSize().width();
            fields["height"] = buffer->pixelSize().height();
            fields["samples"] = buffer->sampleCount();
            fields["render_buffer_type"] = int(buffer->type());
        }
    }
    slot->resource.Set(QJsonDocument(fields).toJson(QJsonDocument::Compact).constData());
#else
    Q_UNUSED(resource);
#endif
}

/** 默认 Qt Quick 路径覆盖整个帧周期，包含自定义绘制之外的交换链提交和 GPU 等待。 */
void CrashDiagnostics::attach(QQuickWindow *window) {
#if defined(RHINE_CRASHPAD)
    if (!window) {
        return;
    }
    attachedWindow = window;
    // 两个信号在同一渲染线程成对发出；线程退出也会清理尚未结束的作用域。
    static thread_local std::optional<CrashRenderScope> frameScope;
    QObject::connect(
        window, &QQuickWindow::beforeFrameBegin, window,
        [] {
            frameScope.reset();
            frameScope.emplace("qt.quick.frame");
        },
        Qt::DirectConnection);
    QObject::connect(
        window, &QQuickWindow::afterFrameEnd, window, [] { frameScope.reset(); }, Qt::DirectConnection);
#else
    Q_UNUSED(window);
#endif
}

CrashRenderScope::CrashRenderScope(const char *stage, std::source_location source) {
#if defined(RHINE_CRASHPAD)
    if (!enabled.load(std::memory_order_relaxed)) {
        return;
    }
    auto slot = threadSlot();
    if (!slot) {
        return;
    }
    m_slot = slot;
    activeRenderSlot = slot;
    m_previousStage = slot->stage;
    m_previousSource = slot->source;
    m_previousStartedMs = slot->startedMs.load();
    slot->stage = stage;
    slot->source = source;
    annotateStage(*slot);
    slot->startedMs.store(monotonicMs(), std::memory_order_release);
#else
    Q_UNUSED(stage);
    Q_UNUSED(source);
#endif
}

CrashRenderScope::~CrashRenderScope() {
#if defined(RHINE_CRASHPAD)
    auto slot = static_cast<RenderSlot *>(m_slot);
    if (!slot) {
        return;
    }
    slot->completed.Set(slot->current.value());
    slot->stage = m_previousStage;
    slot->source = m_previousSource;
    annotateStage(*slot);
    slot->startedMs.store(m_previousStartedMs, std::memory_order_release);
#endif
}
