#include "LinuxX11.h"

#include <QtGlobal>

#if defined(Q_OS_LINUX)
#include <cstdint>
#include <cstdlib>
#include <dlfcn.h>
#endif

namespace RhineLinux {

#if defined(Q_OS_LINUX)
namespace {

// libxcb 的符号签名（与 xcb.h 一致）。cookie 是 4 字节结构体，按值返回/传参，
// 直接声明成 uint32_t 才是正确的调用约定；声明成指针会在 x86-64 上读到高位垃圾。
using ConnectFn = void *(*)(const char *displayname, int *screenp);
using HasErrorFn = int (*)(void *connection);
using DisconnectFn = void (*)(void *connection);
using QueryExtensionFn = std::uint32_t (*)(void *connection, std::uint16_t name_len, const char *name);
using QueryExtensionReplyFn = void *(*)(void *connection, std::uint32_t cookie, void **error);

/** 启动期只探测一次：探测失败同样缓存，避免反复连 X 服务器。 */
Dri3 probeOnce() {
    static const Dri3 result = [] {
        if (qEnvironmentVariableIsEmpty("DISPLAY")) {
            return Dri3::Unknown;
        }
        // 只取符号，不引头文件：AppImage 里 libxcb 一定在，开发机没装 xcb 开发包也能编译。
        void *library = dlopen("libxcb.so.1", RTLD_NOW | RTLD_LOCAL);
        if (!library) {
            return Dri3::Unknown;
        }
        auto connect = reinterpret_cast<ConnectFn>(dlsym(library, "xcb_connect"));
        auto hasError = reinterpret_cast<HasErrorFn>(dlsym(library, "xcb_connection_has_error"));
        auto disconnect = reinterpret_cast<DisconnectFn>(dlsym(library, "xcb_disconnect"));
        auto query = reinterpret_cast<QueryExtensionFn>(dlsym(library, "xcb_query_extension"));
        auto reply = reinterpret_cast<QueryExtensionReplyFn>(dlsym(library, "xcb_query_extension_reply"));
        if (!connect || !hasError || !disconnect || !query || !reply) {
            return Dri3::Unknown;
        }
        int screen = 0;
        void *connection = connect(nullptr, &screen);
        if (!connection || hasError(connection)) {
            if (connection) {
                disconnect(connection);
            }
            return Dri3::Unknown;
        }
        Dri3 verdict = Dri3::Unknown;
        const std::uint32_t cookie = query(connection, 4, "DRI3");
        if (void *raw = reply(connection, cookie, nullptr)) {
            // xcb_query_extension_reply_t: response_type, pad0, sequence(2), length(4),
            //                               present, major_opcode, first_event, first_error
            const auto *bytes = static_cast<const unsigned char *>(raw);
            verdict = bytes[8] ? Dri3::Present : Dri3::Absent;
            std::free(raw);
        }
        disconnect(connection);
        // 不 dlclose：libxcb 连过服务器后带线程局部状态，宿主进程可能还在用。
        return verdict;
    }();
    return result;
}

} // namespace

Dri3 probeDri3() {
    return probeOnce();
}

#else

Dri3 probeDri3() {
    return Dri3::Unknown;
}

#endif

bool vulkanAllowedOn(const QString &platformName, Dri3 dri3, bool overrideRequested) {
    if (overrideRequested) {
        return true;
    }
    // 只对 xcb 平台插件下结论：Wayland 的呈现能力由 wl_drm/dmabuf 决定，探测方式不同；
    // offscreen/minimal 只用于无头冒烟，Vulkan 在那里自会失败而不影响退出码。
    if (platformName != QLatin1String("xcb")) {
        return true;
    }
    return dri3 != Dri3::Absent;
}

QString describeVulkanBlock(const QString &platformName, Dri3 dri3) {
    if (vulkanAllowedOn(platformName, dri3, false)) {
        return QString();
    }
    return QStringLiteral("当前 X11 连接没有 DRI3 扩展，Vulkan 无法呈现到屏幕（Mesa 会在创建交换链时"
                          "直接 abort），已回退 OpenGL。需要在 Xorg 侧启用 DRI3；若确认驱动另有呈现"
                          "路径，可设 RHINE_X11_ALLOW_VULKAN=1 跳过该判断。");
}

} // namespace RhineLinux
