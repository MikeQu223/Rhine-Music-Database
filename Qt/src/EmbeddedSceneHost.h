#pragma once

#include <QString>

class Engine;
class FrameProfiler;

/**
 * Flutter 内嵌模式（RHINE_QT_EMBEDDED=1）的进程级入口。
 *
 * 与默认启动路径的唯一区别：Qt 不创建自己的 Window，也不加载 Main.qml。
 * 场景仍然由这一份 Qt 进程持有——Engine（材质/模型/相机/归档布局）、
 * FrameProfiler 与节点桥在 main() 里照常启动，QML 注册也照常完成；
 * 之后由宿主（Flutter PlatformView）通过 RhineQtView 的 native 入口
 * 在自己的父窗口上创建 QQuickView，并把 Embedded.qml 作为场景根。
 *
 * 之所以要经过 publish()：上下文属性 rhine / profiler / rhineFontFamily
 * 只在 main() 里算得出来（Engine 与字体族都是进程级单例），而 QQuickView
 * 的引擎是后来才创建的，只能从这里取。
 */
namespace RhineEmbedded {
/** 环境变量 RHINE_QT_EMBEDDED=1 时为真。宿主在构造 QtView 之前设置。 */
bool requested();
/** main() 在返回 application.exec() 之前发布进程级指针与字体族。 */
void publish(Engine *engine, FrameProfiler *profiler, const QString &fontFamily);
Engine *engine();
FrameProfiler *profiler();
QString fontFamily();
} // namespace RhineEmbedded
