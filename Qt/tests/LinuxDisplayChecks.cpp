// X11 呈现能力判定里能离线验证的那一半：DRI3 探测结论 + 平台插件名 → 是否还该试着上 Vulkan。
// 判错的后果很重且不对称：放行缺 DRI3 的连接会让 Qt 在创建交换链时直接 abort（带核心转储），
// 无条件退回 OpenGL 又会把本来能跑 Vulkan 的机器降级，所以两个方向都要钉住。
// 真实 DRI3 探测（连 X 服务器）不在用例里，只在"没有 DISPLAY 时必须报未知"这一条上做冒烟。
#include "LinuxX11.h"

#include <QString>
#include <cstdio>

using RhineLinux::Dri3;

namespace {

bool check(bool result, const char *message)
{
    if (!result) {
        std::fprintf(stderr, "%s\n", message);
    }
    return result;
}

// 缺 DRI3 的 xcb 连接：必须拒绝 Vulkan，这是启动崩溃的唯一已知成因。
bool absentDri3OnXcbIsRejected()
{
    return check(!RhineLinux::vulkanAllowedOn(QStringLiteral("xcb"), Dri3::Absent, false),
                 "xcb without DRI3 must not attempt Vulkan");
}

// 有 DRI3 的 xcb 连接（真 Xorg、XWayland）：照常上 Vulkan。
bool presentDri3OnXcbIsAllowed()
{
    return check(RhineLinux::vulkanAllowedOn(QStringLiteral("xcb"), Dri3::Present, false),
                 "xcb with DRI3 should keep Vulkan");
}

// 连不上 X 服务器、缺 libxcb、协议异常都落到 Unknown：不确定就不能替用户降级。
bool unknownDri3KeepsVulkan()
{
    return check(RhineLinux::vulkanAllowedOn(QStringLiteral("xcb"), Dri3::Unknown, false),
                 "unknown DRI3 must not downgrade the backend");
}

// Wayland 的呈现能力由 wl_drm/dmabuf 决定，DRI3 结论与它无关，不能被误伤。
bool waylandIgnoresDri3()
{
    return check(RhineLinux::vulkanAllowedOn(QStringLiteral("wayland"), Dri3::Absent, false),
                 "wayland must not be affected by X11 DRI3 probe");
}

// 无头冒烟（offscreen/minimal）同样不该被这条规则拦住。
bool offscreenIgnoresDri3()
{
    return check(RhineLinux::vulkanAllowedOn(QStringLiteral("offscreen"), Dri3::Absent, false),
                 "offscreen must not be affected by X11 DRI3 probe");
}

// 明确的逃生开关：驱动另有呈现路径时用户可以自己担责。
bool overrideWins()
{
    return check(RhineLinux::vulkanAllowedOn(QStringLiteral("xcb"), Dri3::Absent, true),
                 "RHINE_X11_ALLOW_VULKAN must override the DRI3 verdict");
}

// 拒绝时要给得出人话，且必须点名 DRI3 与逃生开关——日志是用户唯一的线索。
bool reasonIsActionable()
{
    const auto reason = RhineLinux::describeVulkanBlock(QStringLiteral("xcb"), Dri3::Absent);
    bool ok = check(!reason.isEmpty(), "blocked Vulkan must explain itself");
    ok &= check(reason.contains(QStringLiteral("DRI3")), "reason must name DRI3");
    ok &= check(reason.contains(QStringLiteral("RHINE_X11_ALLOW_VULKAN")),
                "reason must name the escape hatch");
    ok &= check(RhineLinux::describeVulkanBlock(QStringLiteral("xcb"), Dri3::Present).isEmpty(),
                "allowed Vulkan must not print a block reason");
    return ok;
}

// 没有 DISPLAY 时探测必须是 Unknown（而不是 Abort/崩溃）：这条路径在容器、无头 CI 里天天走。
bool probeWithoutDisplayIsUnknown()
{
    qunsetenv("DISPLAY");
    return check(RhineLinux::probeDri3() == Dri3::Unknown, "probe without DISPLAY must be Unknown");
}

} // namespace

int main()
{
    bool ok = true;
    ok &= absentDri3OnXcbIsRejected();
    ok &= presentDri3OnXcbIsAllowed();
    ok &= unknownDri3KeepsVulkan();
    ok &= waylandIgnoresDri3();
    ok &= offscreenIgnoresDri3();
    ok &= overrideWins();
    ok &= reasonIsActionable();
    ok &= probeWithoutDisplayIsUnknown();
    return ok ? 0 : 1;
}
