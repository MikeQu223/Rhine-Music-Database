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

/// Flutter 侧推来的渲染状态快照（JSON 字符串，见 lib/basic/qt_scene_view.dart 的
/// qtSceneStateSnapshot）。只在 Qt 主线程调用；重复/相同快照不会重复生效。
/// 语义：dark→theme、mode→setMode、index→select（-1 不动）、key→musicIdentity，
/// 没有 key 就 musicClear（不留上一首封面）。**不接收任何播放指令**。
void applySceneState(const QString &json);
// 销毁场景视图时清掉快照去重状态（同进程重建 Engine 后需要重新应用一次）。
void resetAppliedState();
// 只清选中相关（index/key），供 pointerdown 用；不要拿它替代 resetAppliedState()。
void resetSelectionState();
// 记住最后一份 Flutter 快照，并在场景就绪时补应用（首帧可能早于 qApp）。
void rememberState(const QString &json);
bool reapplyPendingState();
Engine *engine();
FrameProfiler *profiler();
QString fontFamily();
} // namespace RhineEmbedded
