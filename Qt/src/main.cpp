#include <QtGlobal>

// Android 的 native 崩溃捕获已交给 Bugly（ConsentStore 的 BUGLY_NATIVE_MONITOR）。
// 下面这套 RHINE-SIGNAL 诊断链也会接管 SIGSEGV/SIGBUS/SIGABRT，两套 handler 不能并存；
// 默认整体不编译。需要在不装 Bugly 的环境里抓崩溃现场时改成 1，并同时把
// BUGLY_NATIVE_MONITOR 改回 false。
#define RHINE_ANDROID_SIGNAL_DIAG 0

#include "AppIdentity.h"
#include "MobileTarget.h"
#include "AppStorage.h"
#include "storage/RenderCacheStorage.h"
#include "CrashDiagnostics.h"
#include "Engine.h"
#include "MvController.h"
#include <QQmlComponent>
#include "fg/FgCapability.h"
#if defined(Q_OS_LINUX) || defined(Q_OS_DARWIN)
#include "fg/FgConfig.h"
#endif
#ifdef Q_OS_ANDROID
// 注意：当前默认禁用（RHINE_ANDROID_SIGNAL_DIAG=0），native 崩溃由 Bugly 接管；
// 下面这套链只保留作离线排障的回退手段。include 保持不变，供文件后面的代码使用。
//
// 段错误诊断链 v2：真机后台死亡只留下 ApplicationExitInfo 的 SIGNALED/11，
// "Fatal signal" 与 tombstone 全部缺席。v1 的教训是只写 stderr——Android 应用
// 进程的 fd 2 通向 /dev/null（Qt 转发进 logcat 的是 qWarning 这类日志 API，
// 不是原生 fd 2），输出全部丢失。v2 = 两条确定性通道 + 两个静默死亡形态的封堵：
//   通道 1（logd）：__android_log_write 直接进 logcat；liblog 的写路径不做
//     内存分配，崩溃处理器内可用。
//   通道 2（文件）：QGuiApplication 构造后预打开 AppDataLocation/rhine-signal.log
//     （O_APPEND），handler 只 write 已持有的句柄；下次启动回读转发后清空——
//     logd 缓冲被无关刷屏覆盖时仍能拿回现场。
//   封堵 A：启动时在主线程 SIG_UNBLOCK 六个致命信号，此后创建的线程继承未屏蔽
//     掩码。同步 fault 撞上被屏蔽的信号时内核按默认处置直接强杀，任何 handler
//     都不运行——正是"无 Fatal signal、无 tombstone"的静默形态。
//   封堵 B：看门狗线程每 2 秒扫 /proc/self/task，点名任何屏蔽了致命信号的线程
//     （Node/V8/驱动若长期屏蔽 SIGSEGV，这里会直接暴露）。
// handler 本体 write-first：先落通道再收尾。收尾不再内联调用旧处理器（那会跳过
// 正常的信号分发语义，链路一断就是静默死亡），而是恢复旧处置后 tgkill 重投递：
// libc 的 debuggerd 照常打 "Fatal signal" 并产出 tombstone，没有旧处置就按默认
// 方式自杀，绝不能返回出错指令。/proc/self/maps 现场扫描把 pc/lr/sp 所在映射
// 连同文件内偏移一并写出，拿到输出即可用 llvm-symbolizer 对未 strip 的 .so
// 定位到函数。
#include <QDebug>
#include <QStandardPaths>
#include <QString>
#include <android/log.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <thread>
#include <unistd.h>
#include <ucontext.h>

// Bugly 接管 native 时整段不编译；include 留在外面给文件后面的代码用。
#if RHINE_ANDROID_SIGNAL_DIAG
namespace {

struct RhineSignalPrevious {
    struct sigaction action;
    bool valid;
};
RhineSignalPrevious rhineSignalPrevious[3]; // SIGSEGV / SIGBUS / SIGABRT 的旧处置
int rhineSignalLogFd = -1;                  // 预打开的现场日志；-1 表示 QGuiApplication 尚未就绪

// ---- 异步信号安全的小工具：手写拼装，绕开一切可能分配内存的路径。

struct RhineSignalEmitter {
    char *cursor;
    const char *end;
    void text(const char *value, size_t length) {
        if (static_cast<size_t>(end - cursor) > length) {
            memcpy(cursor, value, length);
            cursor += length;
        }
    }
    void text(const char *value) {
        text(value, strlen(value));
    }
    void hex(unsigned long value) { // 递减式十六进制
        char digits[16];
        int length = 0;
        do {
            digits[length++] = static_cast<char>("0123456789abcdef"[value & 0xF]);
            value >>= 4;
        } while (value != 0);
        while (length > 0 && cursor < end) {
            *cursor++ = digits[--length];
        }
    }
    void dec(unsigned long value) {
        char digits[20];
        int length = 0;
        do {
            digits[length++] = static_cast<char>('0' + value % 10);
            value /= 10;
        } while (value != 0);
        while (length > 0 && cursor < end) {
            *cursor++ = digits[--length];
        }
    }
};

// 三条通道一起发：logd、预打开文件、stderr（调试态 attach 时可见）。
void rhineSignalEmitLine(const char *line, size_t length) {
    __android_log_write(ANDROID_LOG_FATAL, "RHINE-SIGNAL", line);
    if (rhineSignalLogFd >= 0) {
        ssize_t toFile = ::write(rhineSignalLogFd, line, length);
        toFile = ::write(rhineSignalLogFd, "\n", 1);
        (void)toFile;
    }
    ssize_t toStderr = ::write(2, line, length);
    toStderr = ::write(2, "\n", 1);
    (void)toStderr;
}

void rhineSignalThreadName(int tid, char *out, size_t capacity) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/self/task/%d/comm", tid);
    out[0] = '\0';
    const int fd = ::open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return;
    }
    const ssize_t got = ::read(fd, out, capacity - 1);
    ::close(fd);
    if (got <= 0) {
        out[0] = '\0';
        return;
    }
    size_t length = static_cast<size_t>(got);
    while (length > 0 && (out[length - 1] == '\n' || out[length - 1] == '\r')) {
        --length;
    }
    out[length] = '\0';
}

// maps 行首三个十六进制字段：起址-止址 权限 偏移，第三个就是文件内偏移。
bool rhineParseMapsHead(const char *&cursor, unsigned long &start, unsigned long &end,
                        unsigned long &offset) {
    const auto parse = [&cursor](unsigned long &value) {
        while (*cursor == ' ') {
            ++cursor;
        }
        value = 0;
        int digits = 0;
        while (*cursor && *cursor != ' ' && *cursor != '-') {
            const char c = *cursor;
            unsigned digit;
            if (c >= '0' && c <= '9') {
                digit = static_cast<unsigned>(c - '0');
            } else if (c >= 'a' && c <= 'f') {
                digit = static_cast<unsigned>(c - 'a' + 10);
            } else if (c >= 'A' && c <= 'F') {
                digit = static_cast<unsigned>(c - 'A' + 10);
            } else {
                return false;
            }
            value = value * 16 + digit;
            ++cursor;
            ++digits;
        }
        return digits > 0;
    };
    if (!parse(start) || *cursor != '-') {
        return false;
    }
    ++cursor;
    return parse(end) && parse(offset);
}

// 在 /proc/self/maps 里找包含 address 的映射：文件内偏移（llvm-symbolizer 的输入）
// 放在行首保证不被截断，映射行原样跟随（路径与权限都留着）。匿名映射也照发——
// JIT 代码区与线程栈的边界同样是信息。
void rhineSignalEmitMapping(unsigned long address, const char *what) {
    char line[512];
    char out[768];
    size_t filled = 0;
    bool matched = false;
    const int fd = ::open("/proc/self/maps", O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        char chunk[1024];
        ssize_t got;
        while (!matched && (got = ::read(fd, chunk, sizeof(chunk))) > 0) {
            for (ssize_t index = 0; index < got && !matched; ++index) {
                const char c = chunk[index];
                if (c != '\n') {
                    if (filled + 1 < sizeof(line)) {
                        line[filled++] = c;
                    }
                    continue;
                }
                line[filled] = '\0';
                filled = 0;
                const char *cursor = line;
                unsigned long start = 0, end = 0, offset = 0;
                if (!rhineParseMapsHead(cursor, start, end, offset) || address < start || address >= end) {
                    continue;
                }
                matched = true;
                RhineSignalEmitter emitter{out, out + sizeof(out) - 1};
                emitter.text("RHINE-SIGNAL map-");
                emitter.text(what);
                emitter.text("+0x");
                emitter.hex(address - start + offset);
                emitter.text(" | ");
                emitter.text(line);
                *emitter.cursor = '\0';
                rhineSignalEmitLine(out, static_cast<size_t>(emitter.cursor - out));
            }
        }
        ::close(fd);
    }
    if (!matched) {
        RhineSignalEmitter emitter{out, out + sizeof(out) - 1};
        emitter.text("RHINE-SIGNAL map-");
        emitter.text(what);
        emitter.text(": 0x");
        emitter.hex(address);
        emitter.text(" (no mapping)");
        *emitter.cursor = '\0';
        rhineSignalEmitLine(out, static_cast<size_t>(emitter.cursor - out));
    }
}

void rhineSignalDiag(int signal, siginfo_t *info, void *context) {
    const int tid = static_cast<int>(gettid());
    char name[32];
    rhineSignalThreadName(tid, name, sizeof(name));

    unsigned long pc = 0, lr = 0, sp = 0;
#if defined(__aarch64__)
    const auto *machine = &static_cast<ucontext_t *>(context)->uc_mcontext;
    pc = static_cast<unsigned long>(machine->pc);
    lr = static_cast<unsigned long>(machine->regs[30]);
    sp = static_cast<unsigned long>(machine->sp);
#endif

    char line[384];
    RhineSignalEmitter emitter{line, line + sizeof(line) - 1};
    emitter.text("RHINE-SIGNAL sig=");
    emitter.dec(static_cast<unsigned long>(signal));
    emitter.text(" code=");
    emitter.dec(info ? static_cast<unsigned long>(info->si_code) : 0UL);
    emitter.text(" addr=0x");
    emitter.hex(info ? reinterpret_cast<unsigned long>(info->si_addr) : 0UL);
    emitter.text(" pc=0x");
    emitter.hex(pc);
    emitter.text(" lr=0x");
    emitter.hex(lr);
    emitter.text(" sp=0x");
    emitter.hex(sp);
    emitter.text(" tid=");
    emitter.dec(static_cast<unsigned long>(tid));
    emitter.text(" thread=");
    emitter.text(name);
    *emitter.cursor = '\0';
    rhineSignalEmitLine(line, static_cast<size_t>(emitter.cursor - line));

    // 栈溢出形态：出错地址落在 sp 下方 128KB 内，fault 大概率就是栈撞守卫页，
    // 此时 pc 已不可信，栈区间本身才是重点。
    const unsigned long address = info ? reinterpret_cast<unsigned long>(info->si_addr) : 0UL;
    if (sp != 0 && address < sp && sp - address < (1UL << 17)) {
        rhineSignalEmitLine("RHINE-SIGNAL stack-overflow suspected: addr below sp",
                            sizeof("RHINE-SIGNAL stack-overflow suspected: addr below sp") - 1);
    }

    rhineSignalEmitMapping(pc, "pc");
    if (lr != pc && lr != 0) {
        rhineSignalEmitMapping(lr, "lr");
    }
    rhineSignalEmitMapping(sp, "sp");

    // 收尾：恢复旧处置后由真正的信号分发重投递——libc 的 debuggerd 接手时照常
    // 打 "Fatal signal" 并产出 tombstone；没有可用旧处置（含 SIG_IGN，同步 fault
    // 撞上它只会无限重故障）就按默认方式自杀。末尾的死循环只为不返回出错指令。
    const auto slot = signal == SIGSEGV ? 0 : signal == SIGBUS ? 1 : 2;
    struct sigaction restore;
    bool usable =
        (signal == SIGSEGV || signal == SIGBUS || signal == SIGABRT) && rhineSignalPrevious[slot].valid;
    if (usable) {
        restore = rhineSignalPrevious[slot].action;
        if (restore.sa_handler == SIG_IGN) {
            usable = false;
        }
    }
    if (!usable) {
        memset(&restore, 0, sizeof(restore));
        restore.sa_handler = SIG_DFL;
    }
    sigaction(signal, &restore, nullptr);
    tgkill(getpid(), tid, signal);
    for (;;) {
        pause();
    }
}

// ---- SIGBLK 看门狗：致命同步信号 ILL(4) TRAP(5) ABRT(6) BUS(7) FPE(8) SEGV(11)
// 在掩码里对应位 3~10（信号 n 占位 n-1）。只报增量，避免刷屏。
void rhineScanThreadMasks(bool snapshot) {
    static unsigned long reported[64];
    static int reportedCount = 0;
    DIR *tasks = opendir("/proc/self/task");
    if (!tasks) {
        return;
    }
    char line[256];
    struct dirent *entry;
    while ((entry = readdir(tasks)) != nullptr) {
        const unsigned long tid = strtoul(entry->d_name, nullptr, 10);
        if (tid == 0) {
            continue;
        }
        char path[64];
        snprintf(path, sizeof(path), "/proc/self/task/%lu/status", tid);
        FILE *status = fopen(path, "r");
        if (!status) {
            continue;
        }
        char name[64] = "?";
        unsigned long blockedMask = 0;
        while (fgets(line, sizeof(line), status)) {
            if (strncmp(line, "Name:", 5) == 0) {
                const char *cursor = line + 5;
                while (*cursor == ' ' || *cursor == '\t') {
                    ++cursor;
                }
                size_t length = 0;
                while (cursor[length] && cursor[length] != '\n' && length < sizeof(name) - 1) {
                    name[length] = cursor[length];
                    ++length;
                }
                name[length] = '\0';
            } else if (strncmp(line, "SigBlk:", 7) == 0) {
                blockedMask = strtoul(line + 7, nullptr, 16);
            }
        }
        fclose(status);
        const unsigned long fatalBits =
            (1UL << 3) | (1UL << 4) | (1UL << 5) | (1UL << 6) | (1UL << 7) | (1UL << 10);
        const unsigned long blocked = blockedMask & fatalBits;
        if (blocked == 0) {
            continue;
        }
        bool isNew = true;
        for (int index = 0; index < reportedCount; ++index) {
            if (reported[index] == tid) {
                isNew = false;
                break;
            }
        }
        if (!isNew && !snapshot) {
            continue;
        }
        char message[192];
        snprintf(message, sizeof(message), "RHINE-SIGBLK tid=%lu thread=%s fatal=0x%lx", tid, name, blocked);
        __android_log_write(ANDROID_LOG_WARN, "RHINE-SIGNAL", message);
        if (isNew && reportedCount < 64) {
            reported[reportedCount++] = tid;
        }
    }
    closedir(tasks);
}

void rhineStartSigmaskWatchdog() {
    std::thread([] {
        __android_log_write(ANDROID_LOG_INFO, "RHINE-SIGNAL", "RHINE-SIGBLK watchdog started");
        rhineScanThreadMasks(true);
        for (;;) {
            std::this_thread::sleep_for(std::chrono::seconds(2));
            rhineScanThreadMasks(false);
        }
    }).detach();
}

void rhineInstallSignalDiag() {
    // 封堵 A：主线程解锁致命同步信号，此后创建的线程继承未屏蔽掩码。
    sigset_t fatal;
    sigemptyset(&fatal);
    sigaddset(&fatal, SIGSEGV);
    sigaddset(&fatal, SIGBUS);
    sigaddset(&fatal, SIGABRT);
    sigaddset(&fatal, SIGILL);
    sigaddset(&fatal, SIGTRAP);
    sigaddset(&fatal, SIGFPE);
    pthread_sigmask(SIG_UNBLOCK, &fatal, nullptr);

    // 备用信号栈：主线程栈溢出时 handler 仍有立足之地。子线程的 altstack 无法
    // 代管——栈溢出若发生在库线程上，只能靠看门狗与面包屑旁证。
    static char altStack[65536] __attribute__((aligned(16)));
    stack_t alternate;
    memset(&alternate, 0, sizeof(alternate));
    alternate.ss_sp = altStack;
    alternate.ss_size = sizeof(altStack);
    alternate.ss_flags = 0;
    sigaltstack(&alternate, nullptr);

    struct sigaction handler;
    memset(&handler, 0, sizeof(handler));
    handler.sa_sigaction = rhineSignalDiag;
    handler.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
    const int watchedSignals[] = {SIGSEGV, SIGBUS, SIGABRT};
    for (int index = 0; index < 3; ++index) {
        auto &previous = rhineSignalPrevious[index];
        previous.valid = sigaction(watchedSignals[index], &handler, &previous.action) == 0;
    }
    rhineStartSigmaskWatchdog();
}

// QGuiApplication 构造后调用：定位现场日志文件（AppDataLocation 依赖 JNI 上下文，
// 此刻才可用），并回读上次崩溃的记录转发到 logcat，然后清空等待新现场。
void rhineOpenSignalDiagFile() {
    const QString path = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) +
                         QStringLiteral("/rhine-signal.log");
    const int fd = ::open(path.toUtf8().constData(), O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd < 0) {
        qWarning().noquote() << "RHINE-SIGNAL: 现场日志文件不可用：" << path;
        return;
    }
    char chunk[1024];
    char line[640];
    size_t filled = 0;
    const auto flushLine = [&line, &filled] {
        if (filled == 0) {
            return;
        }
        line[filled] = '\0';
        filled = 0;
        __android_log_write(ANDROID_LOG_FATAL, "RHINE-SIGNAL-PREV", line);
        qWarning().noquote() << "RHINE-SIGNAL-PREV:" << line;
    };
    if (::lseek(fd, 0, SEEK_END) > 0) {
        ::lseek(fd, 0, SEEK_SET);
        qWarning().noquote() << "RHINE-SIGNAL: 发现上次运行的崩溃现场，转发到 logcat";
        ssize_t got;
        while ((got = ::read(fd, chunk, sizeof(chunk))) > 0) {
            for (ssize_t index = 0; index < got; ++index) {
                if (chunk[index] == '\n' || filled + 1 >= sizeof(line)) {
                    flushLine();
                    if (chunk[index] != '\n') {
                        line[filled++] = chunk[index];
                    }
                } else {
                    line[filled++] = chunk[index];
                }
            }
        }
        flushLine();
        ::ftruncate(fd, 0);
    }
    rhineSignalLogFd = fd;
}
} // namespace
#endif // RHINE_ANDROID_SIGNAL_DIAG
#endif // Q_OS_ANDROID
#include "render/AndroidRenderPolicy.h"
#include "render/PresentationShell.h"
#include "render/RenderPolicy.h"
#include "FrameProfiler.h"
#include "GraphicsBackend.h"
#include "Hud.h"
#if RHINE_LINUX_DESKTOP
#include "LinuxGraphics.h"
#include "LinuxX11.h"
#endif
#include "RhiScene.h"
#if !RHINE_MOBILE
#include "PlaybackConnection.h"
#endif
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
#include "DesktopLyricsController.h"
#include "DesktopLyricsSettings.h"
#endif
#ifdef Q_OS_MACOS
#include "InterfaceWindowMac.h"
#endif
#ifdef Q_OS_IOS
#include "IOSDisplayLink.h"
#include "IOSWindow.h"
#endif
#ifdef Q_OS_ANDROID
#include "AndroidAssets.h"
#include "AndroidWindow.h"
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
#include <memory>
/* Qt 的 Vulkan 类型只在「Qt 带 Vulkan 特性」且「应用侧能看到 vulkan.h」时声明：
 *   qvulkaninstance.h:  #if QT_CONFIG(vulkan) || defined(Q_QDOC)
 *                      #if __has_include(<vulkan/vulkan.h>) || defined(Q_QDOC)
 *   qrhi_platform.h:    #if (QT_CONFIG(vulkan) && __has_include(<vulkan/vulkan.h>)) || defined(Q_QDOC)
 * 只判 QT_CONFIG(vulkan) 会在装了 Qt 但没装 Vulkan SDK 的机器上
 * （如 Windows runner：Qt 自带 Vulkan 特性、系统无 vulkan.h）编译出使用未声明类型的代码，
 * 表现为 QVulkanInstance 不完整类型与 VK_SUCCESS 未定义。守卫必须同时覆盖两半。
 * Android 与桌面同路径：NDK 自带 vulkan.h，自编 Qt 的 QT_CONFIG(vulkan)=1，
 * .qsb 里本来就含 SPIR-V（GLSL 130,150,300es 只是附加的翻译产物），Vulkan 可直接消费。 */
#if QT_CONFIG(vulkan) && __has_include(<vulkan/vulkan.h>) && !defined(Q_OS_DARWIN)
#include <QVulkanFunctions>
#include <QVulkanInstance>
#define RHINE_HAVE_VULKAN_TYPES 1
#else
#define RHINE_HAVE_VULKAN_TYPES 0
#endif
int makeIcon(const QString &directory);
#if !RHINE_MOBILE
bool runPlaybackServiceChecks(const QString &resources, const QString &executable, const QString &gui);
bool runWindowTransitionChecks();
#endif
#ifdef Q_OS_WIN
#include "WindowsRoundedCorners.h"
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
#if RHINE_LINUX_DESKTOP
        qWarning() << "Vulkan: 无法创建探测实例（loader 缺失或驱动不可用）";
#endif
        return false;
    }
    // QVulkanInstance 不公开设备列表，直接按 Vulkan API 枚举，避免依赖 QVulkanWindow。
    quint32 devices = 0;
    const auto result = probe.functions()->vkEnumeratePhysicalDevices(probe.vkInstance(), &devices, nullptr);
    if (result != VK_SUCCESS) {
#if RHINE_LINUX_DESKTOP
        // 只报"Vulkan 不可用"会把排障推回用户：这里必须区分驱动/loader 报错与根本没有设备。
        qWarning() << "Vulkan: vkEnumeratePhysicalDevices 失败，VkResult" << int(result);
#endif
        return false;
    }
    if (devices == 0) {
#if RHINE_LINUX_DESKTOP
        qWarning() << "Vulkan: 物理设备数为 0（缺 /dev/dri、ICD 未安装或驱动被禁用）";
#endif
        return false;
    }
    return true;
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
#if RHINE_LINUX_DESKTOP
/**
 * 当前显示服务器上 Vulkan 能不能呈现。设备枚举判不出这件事：Mesa 在创建交换链时才查 DRI3，
 * 缺了就 abort 而不是返回错误（详见 LinuxX11.h）。结果只探一次，日志同样只打一次。
 */
static bool vulkanPresentationAvailable() {
    static const bool verdict = [] {
        const auto platform = QGuiApplication::platformName();
        const bool overrideRequested = qEnvironmentVariableIntValue("RHINE_X11_ALLOW_VULKAN") > 0;
        const auto dri3 =
            platform == QLatin1String("xcb") ? RhineLinux::probeDri3() : RhineLinux::Dri3::Unknown;
        const bool allowed = RhineLinux::vulkanAllowedOn(platform, dri3, overrideRequested);
        if (!allowed) {
            qWarning().noquote() << "Vulkan:" << RhineLinux::describeVulkanBlock(platform, dri3);
        }
        return allowed;
    }();
    return verdict;
}
#endif
/** 应用命名后端；Vulkan 先探测物理设备，不可用时返回 false 由调用方回退。
 *  仅在非 macOS 下编译：macOS 只提供 Metal，本函数的两个调用点都在 #else 分支里，
 *  而 vulkanDeviceAvailable() 同样只在非 macOS 下定义。 */
#if !defined(Q_OS_DARWIN)
/** Vulkan 既要有设备、也要能呈现到当前显示服务器。
 *  Linux 桌面要额外过 DRI3 探测；Windows 与 Android 只要设备存在即可。 */
static bool vulkanUsable() {
#if RHINE_LINUX_DESKTOP
    return vulkanDeviceAvailable() && vulkanPresentationAvailable();
#else
    return vulkanDeviceAvailable();
#endif
}
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
        if (!vulkanUsable()) {
            qWarning() << "Vulkan is unavailable; falling back to the default backend.";
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
    // Android 与桌面 Linux 走同一条链：显式环境变量 → 设置页偏好 → Vulkan 优先、GLES 回退。
    // .qsb 里自带 SPIR-V（GLSL 130,150,300es 只是附加翻译产物），两个后端都有管线可用；
    // 老版本构建里保存的 opengl 偏好在 Vulkan 可用的设备上仍然生效，这是用户自己的选择。
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
    if (vulkanUsable()) {
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
 * macOS 的 CAMetalLayer 确实受该设置影响；默认同步，诊断环境可显式关闭。
 * 普通窗口与自建呈现层使用相同的环境优先级，避免切换宿主后同步状态变化。
 */
static void applyVSyncSetting() {
#ifdef Q_OS_DARWIN
    const bool synchronized = RhineFg::metalVSyncEnabled();
    auto format = QSurfaceFormat::defaultFormat();
    format.setSwapInterval(synchronized ? 1 : 0);
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
#ifndef Q_OS_DARWIN
    // 插帧（帧生成）已从 Windows/Linux 设置界面下线：启动时恒按"关"下发，
    // 显式 RHINE_FG=on 仍保留为排障对照（呈现层据此决定要不要接管窗口并插帧）。
    if (qEnvironmentVariableIsEmpty("RHINE_FG")) {
        qputenv("RHINE_FG", "off");
    }
#endif
#ifdef Q_OS_DARWIN
    // Apple 的 MetalFX 帧生成由设置页的 panel/fg 驱动，RenderConfiguration 启动时直接读偏好；
    // 显式 RHINE_FG 仍然优先。这里只规范化呈现后端读取的垂直同步。
    qputenv("RHINE_FG_VSYNC", RhineFg::metalVSyncEnabled() ? "on" : "off");
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
    // 默认值与设置页描述符共用 AndroidRenderPolicy.h 里的同一个函数：Android 取 90%，
    // 其它平台仍是 100。用户显式设过 preference / 环境变量时这两条分支都不参与。
    const auto percent =
        graphicsSettings().value("panel/render-scale", RhineRender::androidDefaultRenderScale()).toInt();
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
#if defined(Q_OS_ANDROID) && RHINE_ANDROID_SIGNAL_DIAG
    // 段错误诊断链必须抢在一切组件（Qt 插件、Node、GPU 驱动）可能安装的处理之前。
    rhineInstallSignalDiag();
#endif
    // 诊断对象必须比应用实例更晚析构，保留窗口与 GPU 资源销毁阶段的崩溃采集。
    CrashDiagnostics crashDiagnostics;
#ifdef Q_OS_WIN
    const auto storageError = AppStorage::initializePortable(AppStorage::executableDirectory());
    if (!storageError.isEmpty()) {
        std::fprintf(stderr, "%s\n", storageError.toUtf8().constData());
        return 1;
    }
#endif
    // 两个平台都明确使用 FFmpeg，设备切换和重连由播放器独立处理。
    // 必须在 Qt 初始化多媒体前选择后端，显式环境变量仍可用于兼容性对照。
    // Android 例外：随包的 Android 插件是系统 MediaPlayer 后端，强制 ffmpeg 会找不到插件，
    // 表现为"点了播放没反应"。
#if !defined(Q_OS_ANDROID)
    if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND")) {
        qputenv("QT_MEDIA_BACKEND", "ffmpeg");
    }
#endif
    // 平台插件必须在 QGuiApplication 构造时定下，晚一步就只能重启进程。
    // RHINE_QPA_PLATFORM 是给用户与打包脚本的稳定入口（等价于 QT_QPA_PLATFORM，但不受
    // 用户原有环境变量冲突影响）；纯 Xorg / XWayland 上写 xcb，Wayland 上写 wayland。
    if (!qEnvironmentVariableIsEmpty("RHINE_QPA_PLATFORM")) {
        qputenv("QT_QPA_PLATFORM", qgetenv("RHINE_QPA_PLATFORM"));
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
#if RHINE_LINUX_DESKTOP
    // Linux 没有 QT_D3D_ADAPTER_INDEX 那样的单一入口，选择只能落成厂商环境变量，
    // 所以同样要早于任何 QQuickWindow——RHI 在创建窗口时就定下了用哪块卡。
    initializeLinuxGraphics();
#endif
#ifdef Q_OS_IOS
    // ProMotion 的 plist 只放开上限；Qt 的 DisplayLink 还要显式请求 80–120Hz。
    configureIOSDisplayLinkFrameRate();
#endif
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
    QApplication application(argc, argv);
#else
    QGuiApplication application(argc, argv);
#endif
#if defined(Q_OS_ANDROID)
    // 必须早于任何 QML 场景：系统无障碍服务一旦激活，Qt 会把每次对象显示/隐藏
    // 同步回主线程递归遍历可访问树，滑动时能把主线程打满并触发前台 ANR。
    configureAndroidAccessibility();
#endif
#if defined(Q_OS_ANDROID) && RHINE_ANDROID_SIGNAL_DIAG
    // 现场日志此刻才能定位（AppDataLocation 依赖 JNI 上下文）；上次崩溃的记录
    // 也在这里回读转发到 logcat，之后清空文件等待新现场。
    rhineOpenSignalDiagFile();
#endif
    QCoreApplication::setApplicationVersion(AppUpdater::currentVersion());
    application.setWindowIcon(QIcon(":/icons/icon-256.png"));
    QGuiApplication::setApplicationDisplayName(AppIdentity::DisplayName);
    const auto args = application.arguments();
#if !RHINE_MOBILE
    // 界面回归使用隔离的用户目录；必须在读取任何偏好之前建立。
    const bool playbackGuiTest = args.contains("--playback-gui-test");
    if (playbackGuiTest) {
        const auto directory = args.value(args.indexOf("--playback-gui-test") + 1);
        if (directory.isEmpty() || !AppStorage::initializePortable(directory).isEmpty()) {
            return 1;
        }
    }
#endif
    // 调试模式默认关闭；关闭时不注册 Crashpad，也不保留上次会话的诊断数据。
    const bool debugMode = AppStorage::settings().value("panel/debug-mode").toString() == QLatin1String("on");
    if (debugMode && CrashDiagnostics::supported()) {
        crashDiagnostics.start(application);
    } else if (!debugMode) {
        CrashDiagnostics::clearHistory();
    }
    // 必须在创建任何 QQuickWindow 之前确定后端；组织名先落位，配置路径才能落到应用数据目录。
    selectGraphicsBackend();
    CrashDiagnostics::setGraphicsBackend(RhineGraphics::activeBackend());
    qInfo().noquote() << "Display:" << QGuiApplication::platformName()
                      << "backend:" << RhineGraphics::activeBackend();
    applyVSyncSetting();
    applySupersampleSetting();
    applyRenderScaleSetting();
    applyAntialiasingSetting();
    applyFrameGenerationSetting();
    // 写给设置界面的能力快照：先按"没编进来"落盘，下面的 FG 分支真正接管后再改写。
    // 设置界面在 RhineCore 里，不能反向 include 依赖 vulkan.h 的实现，只能读这份结论。
#if (defined(RHINE_FSR3_VULKAN) && RHINE_FSR3_VULKAN) || defined(Q_OS_DARWIN)
    // Apple 的 MetalFX 补帧不依赖 Vulkan 构建开关；真正可用性稍后由渲染线程/呈现层刷新。
    RhineFg::publishCapability(true, false, false);
#else
    RhineFg::publishCapability(false, false, false, QStringLiteral("此构建未编入 Vulkan 帧生成"));
#endif
    if (args.contains("--make-icon")) {
        return makeIcon(args.value(args.indexOf("--make-icon") + 1));
    }
    QString root = qEnvironmentVariable("RHINE_RESOURCES");
    if (root.isEmpty()) {
#if defined(Q_OS_ANDROID)
        // 随包资源要先从二进制里解出来：Node 与 QFontDatabase 都需要真实路径，
        // APK 内路径只有 Qt 的 qrc 引擎认得。
        const QStringList candidates{androidResourceRoot()};
#else
        // iOS 使用专用资源目录
        const auto base = QCoreApplication::applicationDirPath();
#ifdef Q_OS_MACOS
        const QStringList candidates{base + "/../Resources"};
#elif defined(Q_OS_IOS)
        const QStringList candidates{base + "/RhineAssets"};
#else
        const QStringList candidates{base + "/resources", base + "/../resources"};
#endif
#endif
        for (const auto &candidate : candidates) {
            if (QFileInfo(candidate + "/slots.json").exists()) {
                root = QDir(candidate).absolutePath();
                break;
            }
        }
        if (root.isEmpty()) {
            // 走到这里说明随包资源没找到：Android 上通常是解包失败（私有目录不可写或
            // 二进制里没有内嵌资源），打一行明确日志，别让它表现为"界面全黑"。
            qWarning().noquote() << "找不到随包资源，回退到" << QDir::currentPath() + "/output/resources";
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
#if !RHINE_MOBILE
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
#if !RHINE_MOBILE
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
        const auto attached = playback->call("attach", {{"pid", double(application.applicationPid())},
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
    std::optional<RenderCacheStorage> renderCache;
    if (!offline) {
        renderCache.emplace();
    }
    auto backend = std::make_unique<Engine>(root, offline, nullptr, playback.get(),
                                            renderCache ? &*renderCache : nullptr);
    auto profiler = std::make_unique<FrameProfiler>(backend.get(), profilePath);
    QObject::connect(backend.get(), &Engine::performanceRequested, profiler.get(),
                     &FrameProfiler::toggleVisible);
    backend->start();
    // 设置页的调试模式开关直接驱动采集生命周期；关闭会同时清空已有诊断数据。
    QObject::connect(
        &backend->host, &Host::preferenceChanged, &application,
        [&crashDiagnostics, &application, host = &backend->host](const QString &key, const QString &value) {
            if (key != QLatin1String("debug-mode")) {
                return;
            }
            if (value == QLatin1String("on")) {
                // 启动失败时回写关闭，避免界面显示已开启但实际没有采集。
                if (!crashDiagnostics.start(application)) {
                    host->setPreference(QStringLiteral("debug-mode"), QStringLiteral("off"));
                }
            } else {
                crashDiagnostics.stop();
            }
        });
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
#if !RHINE_MOBILE
    MvController mv(&backend->host, &backend->app->music.player);
    engine.rootContext()->setContextProperty("rhineMv", &mv);
    QObject::connect(backend.get(), &Engine::mvRequested, &mv, &MvController::openWindow);
    std::unique_ptr<QObject> mvWindow;
    std::unique_ptr<QObject> mvWallpaper;
    const auto initializeMvWindows = [&] {
        if (offline) {
            return;
        }
        QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/RhineMusic/MvWindow.qml")));
        mvWindow.reset(component.create());
        if (auto window = qobject_cast<QWindow *>(mvWindow.get())) {
            QQmlEngine::setObjectOwnership(window, QQmlEngine::CppOwnership);
            mv.setWindow(window);
        } else {
            qWarning() << "MV window:" << component.errors();
        }
        if (mv.wallpaperSupported()) {
            QQmlComponent wallpaperComponent(&engine,
                                             QUrl(QStringLiteral("qrc:/qt/qml/RhineMusic/MvWallpaper.qml")));
            mvWallpaper.reset(wallpaperComponent.create());
            if (auto window = qobject_cast<QWindow *>(mvWallpaper.get())) {
                QQmlEngine::setObjectOwnership(window, QQmlEngine::CppOwnership);
                mv.setWallpaperWindow(window);
            } else {
                qWarning() << "MV wallpaper:" << wallpaperComponent.errors();
                mv.setWallpaper(false);
            }
        }
    };
#endif
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
    // Apple Metal 使用默认 QQuickWindow；桌面 Vulkan 复用受控呈现。插值能力独立于呈现路径。
    // RHINE_FG_LAYER=off 可强制使用 Qt Quick 默认窗口；启动失败同样回退。
    const bool fgLayerDisabled =
        qEnvironmentVariable("RHINE_FG_LAYER").compare("off", Qt::CaseInsensitive) == 0;
    // 离屏与最小平台没有原生窗口系统，呈现层无法创建交换链；必须直接走 Qt Quick 默认路径。
    // 否则无显示环境（CI、--playback-gui-test）会在接管 Metal 窗口时崩溃。
    // Android 的"窗口"就是全屏 Activity：没有第二窗口、没有悬浮歌词、没有呈现层接管，
    // 桌面歌词与 FG 的入口必须整体排除，而不是等到创建窗口时才报错。
#if defined(Q_OS_ANDROID)
    // Android 的"窗口"就是全屏 Activity：没有第二窗口、没有悬浮歌词、没有呈现层接管，
    // 桌面歌词与 FG 的入口必须整体置为不可用，而不是等到创建窗口时才报错。
    const bool hasNativeWindowSystem = false;
#elif !defined(Q_OS_IOS)
    const auto platformName = QGuiApplication::platformName();
    const bool hasNativeWindowSystem =
        platformName != QStringLiteral("offscreen") && platformName != QStringLiteral("minimal");
#endif
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
    // 悬浮歌词只在有原生窗口系统的桌面路径创建；窗口本身延迟到首次开启。
    std::unique_ptr<DesktopLyricsSettings> desktopLyricsSettings;
    std::unique_ptr<DesktopLyricsController> desktopLyricsController;
    if (!test && !playbackGuiTest && !args.contains("--capture") && hasNativeWindowSystem) {
        desktopLyricsSettings = std::make_unique<DesktopLyricsSettings>(&backend->host);
        desktopLyricsController =
            std::make_unique<DesktopLyricsController>(backend.get(), desktopLyricsSettings.get());
    }
#endif
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
    const bool interpolationWanted = fgForced || RhineFg::parseBool(qgetenv("RHINE_FG"), false);
#endif
    const bool fgCandidate =
#if defined(Q_OS_DARWIN)
        // Apple 的 MetalFX 补帧在普通 QQuickWindow 内完成，macOS/iOS 共用同一条管线。
        false;
#else
        !test && !args.contains("--capture") && !fgLayerDisabled && hasNativeWindowSystem &&
#ifdef Q_OS_LINUX
        interpolationWanted &&
#endif
        PresentationShell::supportsBackend(RhineGraphics::activeBackend());
#endif
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
#if !RHINE_MOBILE
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
            if (tray && desktopLyricsSettings) {
                tray->attachDesktopLyrics(desktopLyricsSettings.get());
            }
#endif
            QObject::connect(&application, &QCoreApplication::aboutToQuit, shell.get(),
                             [raw = shell.get()] { raw->shutdown(); });
#if !RHINE_MOBILE
            // Establish the primary presentation window before an enabled MV can show.
            QTimer::singleShot(0, &engine, initializeMvWindows);
#endif
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
    CrashDiagnostics::attach(window);
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
#if !RHINE_MOBILE
    // A saved MV preference must not make the auxiliary window the first rendered window.
    // frameSwapped comes from the render thread; create QML windows on the GUI thread afterwards.
    QObject::connect(window, &QQuickWindow::frameSwapped, &engine, initializeMvWindows,
                     Qt::ConnectionType(Qt::QueuedConnection | Qt::SingleShotConnection));
#endif
#ifdef Q_OS_WIN
    taskbar.bindWindow(window);
    window->show();
    // 无边框主窗口创建后补一次 DWM 圆角请求
    applyWindowsRoundedCorners(window);
#endif
    backend->setWindow(window);
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
    std::unique_ptr<DesktopTray> tray;
    tray = std::make_unique<DesktopTray>(window, &application);
    if (tray && desktopLyricsSettings) {
        tray->attachDesktopLyrics(desktopLyricsSettings.get());
    }
#endif
#ifdef Q_OS_IOS
    configureIOSWindow(window, backend.get());
#elif defined(Q_OS_ANDROID)
    configureAndroidWindow(window, backend.get());
#endif
    window->installEventFilter(backend.get());
    profiler->attach(window);
#if !RHINE_MOBILE
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
#ifndef Q_OS_IOS
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
#endif
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
