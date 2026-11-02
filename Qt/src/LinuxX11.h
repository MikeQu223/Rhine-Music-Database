#pragma once
#include <QString>

/**
 * X11 相关的启动期探测。
 *
 * 只做一件事：判断"这个 X11 连接能不能让 Vulkan 呈现到屏幕上"。
 * 起因：Mesa 的 Vulkan WSI 在创建交换链时要求 DRI3（`No DRI3 support detected - required for
 * presentation`），而 Qt 拿不到交换链时走 QSGRenderLoop::handleContextCreationFailure → qFatal，
 * 直接 SIGABRT 带核心转储。设备枚举（vkEnumeratePhysicalDevices）与
 * QVulkanInstance::supportsPresent() 都判不出这种连接——实测 Xvfb（无 DRI3）上
 * supportsPresent 仍返回 true，所以只能问 X 服务器要 DRI3 扩展。
 * 探测只用 libxcb 的稳定 C API，通过 dlopen 取符号：不新增构建依赖，缺库时退化成"未知"。
 */
namespace RhineLinux {

/** X11 的 DRI3 扩展是否存在。Unknown 表示"没探到"（连不上、缺库、非 X11），不是"确定没有"。 */
enum class Dri3 { Unknown, Present, Absent };

/** 探测当前 DISPLAY 的 DRI3 扩展；非 X11 平台、无 DISPLAY 或缺少 libxcb 时返回 Unknown。 */
Dri3 probeDri3();

/**
 * 纯决策，便于离线用例覆盖：当前显示服务器上是否允许尝试 Vulkan。
 *
 * 只有"运行在 xcb 平台插件上、且确定没有 DRI3"才判 false，其余情况一律放行——
 * 探测不确定时替用户退回 OpenGL 会把本来能用的机器降级。
 * overrideRequested 对应 RHINE_X11_ALLOW_VULKAN=1：用户明确要求时照办。
 */
bool vulkanAllowedOn(const QString &platformName, Dri3 dri3, bool overrideRequested);

/** 把探测结论拼成一句人话，给启动日志用（不打印任何环境变量细节）。 */
QString describeVulkanBlock(const QString &platformName, Dri3 dri3);

} // namespace RhineLinux
