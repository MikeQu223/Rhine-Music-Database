#pragma once

#include "EmbeddedSceneOrigin.h"

#include <QJsonObject>
#include <QString>

class Engine;
class FrameProfiler;

/**
 * Flutter 内嵌模式（RHINE_QT_EMBEDDED=1）的进程级入口。
 *
 * 与默认启动路径的唯一区别：Qt 不创建自己的 Window，也不加载 Main.qml。
 * 场景仍然由这一份 Qt 进程持有——Engine（材质/模型/相机/归档布局）、
 * 节点桥在 main() 里照常启动，QML 注册也照常完成；
 * （性能面板停用：FrameProfiler 实例不再创建、不再采样。）
 * 之后由宿主（Flutter PlatformView）通过 RhineQtView 的 native 入口
 * 在自己的父窗口上创建 QQuickView，并把 Embedded.qml 作为场景根。
 *
 * 之所以要经过 publish()：上下文属性 rhine / rhineFontFamily
 * 只在 main() 里算得出来（Engine 与字体族都是进程级单例），而 QQuickView
 * 的引擎是后来才创建的，只能从这里取。
 * （性能面板停用：profiler 上下文属性不再注册，指针恒为空。）
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
///
/// origin 是这份快照的**产出者**（Dart 的 viewId/ctx），必须由调用方按值传入：apply 成功
/// 之后它才成为"当前画面来源"，排队中的旧输入/动作随后会被 OriginLedger 判旧。
void applySceneState(const QString &json, const ProducerOrigin &origin);

/// 应用点账本（Qt 线程独占）。诊断与测试用它证明"哪一帧是第几次成功 apply 之后来的"。
OriginLedger &originLedger();
/// 场景世代账本：Java 侧每次 create 请求的世代号在这里 adopt，destroy 只允许拆自己那一代。
SceneEpoch &sceneEpoch();

/// 内嵌模式下**当前选中**条目的封面地址与身份（来自 Flutter 快照的 cover/kind/id）。
///
/// 为什么必须由 Flutter 给：内嵌模式里 Qt 侧的 MusicLibrary 是空壳（renderOnly，
/// 不建第二份曲库、不建第二个播放器），`music.coverImage` 永远是空串；封面只能来自
/// 「Flutter 选中的那一首」的 cover。Engine 拿这个值当 cache key 查 host.image()，
/// miss 时按 URL 走 Host::loadCover（异步，回调里用的是 loadCover **返回**的 cache
/// key，因为 image 查询会给 URL 补上 `param=NyN`）。没有选中时是空串 → 清旧图。
QString projectedCover();
/// 选中身份对象 {kind, key, id, cover}；没有选中时为空对象。
QJsonObject projectedCurrent();
// 销毁场景视图时清掉快照去重状态（同进程重建 Engine 后需要重新应用一次）。
//
// sceneEpoch 是调用方以为自己在拆的那一代：对不上就整段跳过——旧 host（比如上一轮
// Activity 的 RhineQtView）的 destroy 不许把新 host 的已应用 origin 抹掉，否则新 host
// 的输入会因为"账本已关闭"被一直丢弃。0 = 不带世代（内部路径），无条件生效。
void resetAppliedState(quint64 sceneEpoch);
// 只清选中相关（index/key），供 pointerdown 用；不要拿它替代 resetAppliedState()。
void resetSelectionState();
// 记住最后一份 Flutter 快照（连同它的 origin），并在场景就绪时带着同一份 origin 补应用
// （首帧可能早于 qApp）。补应用的 origin 必须来自这里，而不是"当前是谁"。
void rememberState(const QString &json, const ProducerOrigin &origin);
bool reapplyPendingState();
Engine *engine();
FrameProfiler *profiler();
QString fontFamily();
} // namespace RhineEmbedded
