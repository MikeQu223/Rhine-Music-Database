//  候选 A（PlatformView 切片）的 Flutter 半边：宿主契约 + 真实的 AndroidView 端口。
//
// 设计铁律（来自本文件 的任务约束与计划  段）：
//   1. 绝不用占位 View 假装 Qt。本文件在宿主未就绪时渲染的是「诊断面板」，不是任何
//      看起来像 Qt 画面的东西；平台侧（QtPlatformViewHost.kt）在同一条约束下只画空白。
//   2. 契约字段/阈值必须有 Qt 源证据，证据在注释里逐条给出（文件:行）。
//   3. 不改 main/manifest/注册：本文件只提供可注入的端口，装配留给宿主。
//
// 证据（仓库内 Qt 源，行号为该文件真实行号）：
//   QtView.java:19            abstract class QtView extends ViewGroup implements QtNative.AppStateDetailsListener
//   QtQuickView.java:27       public class QtQuickView extends QtView（qtdeclarative 的 android jar）
//                             （QtView.java:27 是空行；QtQuickView 只在 qtdeclarative 的 android jar 里）
//   QtView.java:50-69         QtView(Context)：注册 app state 监听 + QtEmbeddedViewInterfaceFactory.create(context)
//   QtView.java:54-66         addOnLayoutChangeListener → native resizeWindow(windowReference, l, t, w, h)
//   QtView.java:77-84         QtView(Context, appLibName)：appLibName 为空即抛 InvalidParameterException
//   QtView.java:140-161       QtEmbeddedLoader.getEmbeddedLoader() → loadQtLibraries() → startQtApplication()
//   QtView.java:214-229       addQtWindow：MATCH_PARENT 加入 index 0，setWindowVisible(true)（:225），
//                             回调 onQtWindowLoaded（:226-227）
//   QtView.java:239-246       onAppStateDetailsChanged：!details.isStarted 时把自己从父容器摘掉
//   QtQuickView.java:59-89    QtQuickView(Context, qmlUri, appName[, qmlImportPaths])：qmlUri 空即抛
//   QtEmbeddedDelegate.java:33-64  ActivityLifecycleCallbacks → setApplicationState(Active/Inactive/Suspended)
//   QtLoader.java:73-76       ContextWrapper.baseContext 不是 Activity/Service 即抛 IllegalArgumentException
//   QtLoader.java:159         resolvePreferredAbi 读 resources array "qt_libs"
//   QtLoader.java:109-127      extractContextMetaData(context)：只读环境变量 + android.app.arguments（:118，可空）
//                              —— 不读 android.app.lib_name；lib_name 仅在 :524-525 作 null 回退
//   QtNative.java:224-229     ApplicationState { Suspended=0x0, Hidden=0x1, Inactive=0x2, Active=0x4 }
//   Qt/android/AndroidManifest.xml:99,103  QtActivity + screenOrientation="sensorLandscape"
//   Qt/src/AndroidWindow.cpp:16            kSensorLandscape = 6
//   Qt/src/AndroidWindow.cpp:18            kWindowFlags = 0x00000400 | 0x00000080
//   Qt/src/AndroidWindow.cpp:22            kImmersiveSticky = 0x2|0x4|0x100|0x200|0x400|0x1000
//   Qt/src/AndroidWindow.cpp:63-71         Qt 无障碍桥默认关闭（前台 ANR 兜底）
//   Qt/src/AndroidWindow.cpp:92-118        applicationStateChanged → setVisible / trimMemory
//
// ──  补充证据（五个面逐项；行号按仓库真实文件核对过）──────────────────
//   触摸：QtWindow.java:246-266 onTouchEvent —— windowFocusChanged(true,getId())
//         → m_inputConnectionListener.onEditTextChanged(m_editText)
//         → QtInputDelegate.sendTouchEvent(event, getId())（:262）
//         → m_gestureDetector.onTouchEvent(event)（:264）→ return true（:265）。
//         event 的坐标就是 MotionEvent 相对本视图的局部坐标，Qt 直接消费；
//         宿主不得再自算一次映射（再映射一次 = 双重缩放/偏移）。
//         TouchInput.qml:19-25 把触摸拖动换算成 backend.wheelInput(...)（与滚轮同一条
//         通路），说明手势语义在 QML 层已有归属，宿主不应另开一套。
//   缩放：QtView.java:39-43 声明 static native resizeWindow(long,int,int,int,int)；
//         QtView.java:50-69 QtView(Context) 注册 addOnLayoutChangeListener，
//         windowReference != 0 且尺寸/位置变化时调 resizeWindow（:63）。
//         resize 的发起者是 QtView 自己的 layout listener，宿主只提供布局尺寸。
//         QtWindow.java:338-345 setGeometry 只在 getContext() instanceof QtActivityBase
//         时 setLayoutParams（:342-343）——Flutter 宿主的 Context 不是 QtActivityBase。
//   表面：QtWindow.java:303-325 createSurface(onTop, imageDepth, isOpaque, surfaceContainerType)：
//         surfaceContainerType == 0 → new QtSurface(...)（:313），否则 new QtTextureView(...)
//         （:316），MATCH_PARENT，addView(m_surfaceContainer, 0)（:323）。
//         QtSurface.java:14 class QtSurface extends SurfaceView；构造器 :18-28
//         （:23 setZOrderMediaOverlay(onTop)，:26 holder.setFormat(imageDepth==16?RGB_565:RGBA_8888)）。
//         QtTextureView.java:14 class QtTextureView extends TextureView；构造器 :20-29
//         （:26 setSurfaceTextureListener(this)，:27 setOpaque(isOpaque)，:28 new SurfaceTexture(false)）。
//         → 容器种类由 Qt 选，宿主只能观测（surfaceContainerKind / viewCompositionRequired）。
//   IME：  QtInputDelegate.java:214-240 showSoftwareKeyboard(Activity,x,y,w,h,hints,enterKeyType)
//         是唯一软键盘入口，由 Qt C++ 侧经 QtInputInterface 调用；QtEditText.java:24
//         class QtEditText extends View（包内可见），:111-133 onCreateInputConnection。
//         softInputMode 来自 manifest：QtActivityDelegateBase.java:83-104 initMembers 读
//         pm.getActivityInfo(...).softInputMode → m_inputDelegate.setSoftInputMode(...)（:97-98）。
//         → 宿主不得自行 show/hide keyboard，也不得改 softInputMode（会与 Qt 抢同一条窗口属性）。
//   无障碍：AndroidWindow.cpp:63-71 configureAndroidAccessibility()：
//         QAccessible::installUpdateHandler(&swallowAccessibilityUpdate)（:68）
//         + QAccessible::setActive(false)（:69），注释说明这是防前台滑动 ANR 的闸门。
//         → 宿主不得主动开启/改写无障碍桥，也不调用任何无障碍 API；本文件一处都没有。
//   生命周期：QtEmbeddedDelegate.java:33-82 registerActivityLifecycleCallbacks：
//         onActivityResumed → setApplicationState(ApplicationActive)+QtWindow.updateWindows()
//         （:42-45），onActivityPaused → ApplicationInactive（:50-54），
//         onActivityStopped → ApplicationSuspended（:60-62），
//         onActivityDestroyed → terminateQtNativeApplication()（:70-82）。
//         → 状态由 Qt 驱动，我们只观测（applyLifecycleObservation）。
//   窗口形状：AndroidWindow.cpp:16 kSensorLandscape=6 / :18 kWindowFlags / :22 kImmersiveSticky；
//         运行期 applyWindowShape()（:25-51）在 runOnAndroidMainThread 里 setRequestedOrientation/
//         addFlags/setSystemUiVisibility（:38/:44/:47；:27-28 注释说明为何不能在 Qt 线程直接 JNI）。
//         清单侧：Qt/android/AndroidManifest.xml:89（ConsentActivity）与 :103（QtActivity）
//         都是 screenOrientation="sensorLandscape"。
//   合成：  flutter/lib/src/services/platform_views.dart:131-133 initAndroidView 走 TLHC/纹理，
//         不支持时回落 Virtual Display；:190-194 initExpensiveAndroidView 恒为 HC；
//         :1458-1488 _HybridAndroidViewControllerInternals（:1465 requiresViewComposition => true）。
//         widgets/platform_view.dart:1485-1551 AndroidViewSurface 依据 requiresViewComposition
//         在 _PlatformLayerBased / _TextureBased 之间二选一；:1155-1181 PlatformViewCreationParams
//         只有 id/viewType/onPlatformViewCreated/onFocusChanged；:1236-1261 PlatformViewLink。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
// PlatformViewHitTestBehavior 定义在 rendering/platform_view.dart（:21），
// widgets.dart 只 show 了 TextSelectionHandleType（flutter/lib/widgets.dart:19），
// 所以要显式引入，且只取这一个符号以免与 material 的导出歧义。
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

/// 平台侧 PlatformView 的 viewType，必须与 QtPlatformViewHost.kt 的常量逐字相同。
const String qtPlatformViewType = 'rhine.music.database.porting/qt_platform_view';

/// Dart → 平台的控制通道（生命周期观测、探针刷新、诊断）。
const String qtPlatformControlChannel =
    'rhine.music.database/qt_platform_view/control';

/// 平台 → Dart 的事件通道（宿主状态、表面尺寸、输入回执）。
const String qtPlatformEventChannel =
    'rhine.music.database/qt_platform_view/events';

/// 组合模式：Qt 表面交给 Flutter 的纹理管线（TLHC / texture layer）。
const String qtPlatformCompositionTextureLayer = 'texture-layer';

/// 组合模式：平台视图直接进 Android 视图层级（Hybrid Composition / View Composition）。
const String qtPlatformCompositionViewComposition = 'view-composition';

/// Qt 表面容器 × Flutter 合成模式的组合契约（冻结契约 v2 第 (1) 条）。
///
/// 为什么必须显式而不能靠默认值：容器种类是 **Qt 自己选的** ——
/// QtWindow.java:303-325 中 surfaceContainerType == 0 时 new QtSurface(...)（:313，
/// SurfaceView），否则 new QtTextureView(...)（:316，TextureView）。而 Flutter 侧
/// initAndroidView 只走 TLHC/纹理（services/platform_views.dart:131-133），
/// SurfaceView 无法被纹理化；能承载它的只有 initExpensiveAndroidView 的
/// Hybrid Composition（同文件 :190-194，:1458-1488 里 requiresViewComposition => true）。
/// 所以「用哪种合成」是宿主的选择，且必须能被探针（surfaceContainerKind /
/// viewCompositionRequired）对账。
enum QtPlatformCompositionMode {
  /// 现有路径：AndroidView（TLHC/纹理）。只适用于 Qt 选 TextureView 的场合。
  textureLayer(qtPlatformCompositionTextureLayer),

  /// PlatformViewLink + initExpensiveAndroidView + AndroidViewSurface。
  /// SurfaceView 需要它才能正确合成（见 qtCompositionWarning）。
  viewComposition(qtPlatformCompositionViewComposition);

  const QtPlatformCompositionMode(this._wireName);

  final String _wireName;

  /// Dart 侧自有的线名/落盘字符串。平台侧目前不消费 composition 词表
  /// （Kotlin 没有任何 composition 常量或读取点），这里只用于宿主自检、报告与告警；
  /// 改这两个字符串等于改线上契约，必须同步 integration_test 与消费方。
  String get wireName => _wireName;

  /// null / 未知值一律回落到 textureLayer：那是现有 AndroidView 路径，
  /// 不会因为一条坏数据就把视图悄悄升级成昂贵的 Hybrid Composition。
  static QtPlatformCompositionMode fromWire(String? value) {
    for (final QtPlatformCompositionMode mode
        in QtPlatformCompositionMode.values) {
      if (mode._wireName == value) {
        return mode;
      }
    }
    return QtPlatformCompositionMode.textureLayer;
  }
}

/// 表面容器种类词表（冻结契约 v2 第 (3) 条），与 QtPlatformViewHost.kt 的
/// SURFACE_* 常量逐字相同。取值来源是 QtWindow.java:303-325 的二选一。
abstract final class QtSurfaceContainerKind {
  static const String surfaceView = 'surface-view';
  static const String textureView = 'texture-view';
  static const String none = 'none';
  static const String unknown = 'unknown';
}

/// 归属方词表（冻结契约 v2 第 (3) 条），与 QtPlatformViewHost.kt 的
/// IME_OWNER_* / RESIZE_OWNER_* / SAFE_AREA_OWNER_* 逐字相同。
///
/// 三个归属都是 Qt 的内部事实，宿主只读、不改写：
///   · IME 归 QtInputDelegate：唯一入口 showSoftwareKeyboard（QtInputDelegate.java:214-240），
///     InputConnection 由 QtEditText.onCreateInputConnection 提供（QtEditText.java:24、:111-133），
///     softInputMode 来自 manifest（QtActivityDelegateBase.java:83-104，:97-98）。
///   · resize 归 QtView 的 layout listener：QtView.java:39-43 声明 native resizeWindow，
///     :50-69 注册 addOnLayoutChangeListener（:63 调 resizeWindow）。
///   · safe area 归 QtWindow 的 inset listener，但它只在 Context 是 QtActivityBase 时注册
///     （QtWindow.java:90-150，:92 直接 return）——Flutter 宿主下必然不可用，因此取值是
///     'unavailable-no-qactivitybase'。
abstract final class QtOwnerVocabulary {
  static const String unknown = 'unknown';
  static const String imeQtInputDelegate = 'qt-input-delegate';
  static const String resizeQtViewLayoutListener = 'qtview-layout-listener';
  static const String safeAreaQtWindow = 'qtwindow-safe-area-listener';
  static const String safeAreaUnavailable = 'unavailable-no-qactivitybase';
}

/// Qt 的应用状态位。数值直接抄 QtNative.java:224-229（注释明确写着
/// "Keep in sync with src/corelib/global/qnamespace.h"，即这是稳定 ABI，不要自己发明）。
enum QtAppState {
  suspended(0x0),
  hidden(0x1),
  inactive(0x2),
  active(0x4);

  const QtAppState(this.wireValue);

  final int wireValue;

  static QtAppState? fromWire(int? value) {
    for (final QtAppState state in QtAppState.values) {
      if (state.wireValue == value) return state;
    }
    return null;
  }
}

/// Qt 的宿主裁决。ready 表示平台侧真的拿到了 QtQuickView 实例；
/// 其余两种是**如实上报的失败**，绝不允许被上层当作可用。
enum QtHostVerdict {
  /// 真 Qt 视图已在视图树里（QtQuickView 实例存在）。
  ready,

  /// 构建期/装配期就无法成立：缺 Qt android jar、缺 androiddeployqt 的 qt_libs 清单、
  /// "use_local_qt_libs" 未置 1、或 Context 不是 Activity（QtLoader.java:73-76 /
  /// QtLoader.java:466-469 三条硬前置）；宿主 meta-data 不在此列，只作观测值上报。
  archBlocked,

  /// 装配齐了但当前设备/构建产物不满足（本地 native 库缺失、GLES 版本等）。
  deviceBlocked,
}

/// 宿主探针的稳定 key。与 QtPlatformViewHost.kt 的 probe() 输出一一对应。
abstract final class QtProbeKeys {
  static const String qtClassesPresent = 'qtClassesPresent';
  static const String missing = 'missing';
  static const String qtLibsArrayPresent = 'qtLibsArrayPresent';
  static const String hostMetaDataPresent = 'hostMetaDataPresent';
  static const String nativeQtLibsPresent = 'nativeQtLibsPresent';
  static const String activityContextUsable = 'activityContextUsable';
  static const String surfaceOwner = 'surfaceOwner';
  static const String inputOwner = 'inputOwner';
  static const String lifecycleOwner = 'lifecycleOwner';

  // ── 冻结契约 v2 新增（平台侧产出，Dart 只读）───────────────────────────────
  /// QtWindow 是否真的进了宿主视图树（平台侧 probeQtSubtree 按类名判定，无反射）。
  static const String qtWindowAttached = 'qtWindowAttached';

  /// Qt 自己选的表面容器：'surface-view' | 'texture-view' | 'none' | 'unknown'。
  static const String surfaceContainerKind = 'surfaceContainerKind';

  /// 触摸是否原样穿透给 Qt（宿主只计数后 super 转发，不消费、不改坐标）。
  static const String touchPassthrough = 'touchPassthrough';

  /// IME 归属，唯一合法值 'qt-input-delegate'。
  static const String imeOwner = 'imeOwner';

  /// resize 归属，唯一合法值 'qtview-layout-listener'。
  static const String resizeOwner = 'resizeOwner';

  /// safe area 归属：'qtwindow-safe-area-listener' | 'unavailable-no-qactivitybase'。
  static const String safeAreaOwner = 'safeAreaOwner';

  /// 传给 QtQuickView 的 Context 是否 QtActivityBase（Flutter 宿主下恒 false）。
  static const String activityIsQtActivityBase = 'activityIsQtActivityBase';

  /// surfaceContainerKind == 'surface-view' 的派生结论：必须用 view composition。
  static const String viewCompositionRequired = 'viewCompositionRequired';
}

/// 平台侧 probe() 的结构化结果。
///
/// 解析刻意容忍字段缺失：平台侧版本落后时给出 archBlocked + 缺失清单，
/// 而不是抛异常或者乐观默认为 ready。
@immutable
class QtHostStatus {
  const QtHostStatus({
    required this.verdict,
    required this.reason,
    this.missing = const <String>[],
    this.qtClassesPresent = const <String, bool>{},
    this.qtLibsArrayPresent = false,
    this.hostMetaDataPresent = false,
    this.nativeQtLibsPresent = false,
    this.activityContextUsable = false,
    this.surfaceOwner = 'unknown',
    this.inputOwner = 'unknown',
    this.lifecycleOwner = 'unknown',
    this.qtWindowAttached = false,
    this.surfaceContainerKind = QtSurfaceContainerKind.unknown,
    this.touchPassthrough = false,
    this.imeOwner = QtOwnerVocabulary.imeQtInputDelegate,
    this.resizeOwner = QtOwnerVocabulary.resizeQtViewLayoutListener,
    this.safeAreaOwner = QtOwnerVocabulary.unknown,
    this.activityIsQtActivityBase = false,
    this.viewCompositionRequired = false,
  });

  /// 平台侧在能安全判定之前给出的占位：未就绪且原因不明。
  static const QtHostStatus unknown = QtHostStatus(
    verdict: QtHostVerdict.archBlocked,
    reason: 'platform host has not reported a probe result yet',
    missing: <String>['probe'],
  );

  final QtHostVerdict verdict;
  final String reason;
  final List<String> missing;
  final Map<String, bool> qtClassesPresent;
  final bool qtLibsArrayPresent;
  final bool hostMetaDataPresent;
  final bool nativeQtLibsPresent;
  final bool activityContextUsable;
  final String surfaceOwner;
  final String inputOwner;
  final String lifecycleOwner;

  // ── 冻结契约 v2 新增的 8 个观测字段（全部来自平台探针，Dart 不推断）──────────
  /// QtWindow 是否真的挂在宿主视图树里（QtWindow.java:28 class QtWindow；
  /// 平台侧 probeQtSubtree 递归按 Class.getName() 判定，不做成员反射）。
  final bool qtWindowAttached;

  /// Qt 选的表面容器，见 QtWindow.java:303-325：
  /// surfaceContainerType == 0 → QtSurface（:313，SurfaceView）；否则 QtTextureView（:316）。
  final String surfaceContainerKind;

  /// 触摸是否原样穿透：QtWindow.java:246-266 onTouchEvent 直接消费 MotionEvent 的
  /// 视图局部坐标，宿主的 dispatchTouchEvent 只计数后 super 转发（不消费/不改坐标）。
  final bool touchPassthrough;

  /// IME 归属：QtInputDelegate.java:214-240 + QtEditText.java:111-133。
  final String imeOwner;

  /// resize 归属：QtView.java:39-43 声明、:50-69 注册的 layout listener → native resizeWindow。
  final String resizeOwner;

  /// safe area 归属：QtWindow.java:92（方法体 :90-150；非 QtActivityBase 直接不注册 inset listener）。
  final String safeAreaOwner;

  /// Context 是否 QtActivityBase：决定 setGeometry 路径是否生效
  /// （QtWindow.java:338-345 的 :342 判断）。Flutter 宿主下恒 false。
  final bool activityIsQtActivityBase;

  /// surfaceContainerKind == 'surface-view' 的派生结论：SurfaceView 不能被 TLHC
  /// 纹理化（services/platform_views.dart:131-133），只有 HC/view composition 能承载
  /// （:190-194）。
  final bool viewCompositionRequired;

  bool get isReady => verdict == QtHostVerdict.ready;

  /// 只有真正 ready 才允许把像素当 Qt 画面。未 ready 且 platformViewId >= 0 时
  /// 一律走诊断面板（platformViewId < 0 的那一帧仍要挂 AndroidView 触发 creation）；
  /// 该合取守卫在 _QtPlatformViewBody.build:809，是分支而非 assert。
  bool get mayRenderQtPixels => isReady;

  static QtHostStatus fromMap(Object? raw) {
    if (raw is! Map) return QtHostStatus.unknown;
    final Map<Object?, Object?> map = raw;
    final String verdictName =
        map['verdict'] is String ? map['verdict']! as String : 'archBlocked';
    final QtHostVerdict verdict = QtHostVerdict.values.firstWhere(
      (QtHostVerdict v) => v.name == verdictName,
      orElse: () => QtHostVerdict.archBlocked,
    );
    final Map<String, bool> classes = <String, bool>{};
    final Object? rawClasses = map[QtProbeKeys.qtClassesPresent];
    if (rawClasses is Map) {
      rawClasses.forEach((Object? k, Object? v) {
        if (k is String) classes[k] = v == true;
      });
    }
    return QtHostStatus(
      verdict: verdict,
      reason: map['reason'] is String
          ? map['reason']! as String
          : 'platform host reported no reason',
      missing: _stringList(map[QtProbeKeys.missing]),
      qtClassesPresent: classes,
      qtLibsArrayPresent: map[QtProbeKeys.qtLibsArrayPresent] == true,
      hostMetaDataPresent: map[QtProbeKeys.hostMetaDataPresent] == true,
      nativeQtLibsPresent: map[QtProbeKeys.nativeQtLibsPresent] == true,
      activityContextUsable: map[QtProbeKeys.activityContextUsable] == true,
      surfaceOwner: _stringOr(map[QtProbeKeys.surfaceOwner], 'unknown'),
      inputOwner: _stringOr(map[QtProbeKeys.inputOwner], 'unknown'),
      lifecycleOwner: _stringOr(map[QtProbeKeys.lifecycleOwner], 'unknown'),
      // 缺字段时用契约默认值，绝不乐观猜成 ready 的依据：这些字段只描述
      // 「谁在负责」，不参与 verdict 判定。
      qtWindowAttached: map[QtProbeKeys.qtWindowAttached] == true,
      surfaceContainerKind: _stringOr(
        map[QtProbeKeys.surfaceContainerKind],
        QtSurfaceContainerKind.unknown,
      ),
      touchPassthrough: map[QtProbeKeys.touchPassthrough] == true,
      imeOwner: _stringOr(
        map[QtProbeKeys.imeOwner],
        QtOwnerVocabulary.imeQtInputDelegate,
      ),
      resizeOwner: _stringOr(
        map[QtProbeKeys.resizeOwner],
        QtOwnerVocabulary.resizeQtViewLayoutListener,
      ),
      safeAreaOwner: _stringOr(
        map[QtProbeKeys.safeAreaOwner],
        QtOwnerVocabulary.unknown,
      ),
      activityIsQtActivityBase:
          map[QtProbeKeys.activityIsQtActivityBase] == true,
      viewCompositionRequired:
          map[QtProbeKeys.viewCompositionRequired] == true,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'verdict': verdict.name,
    'reason': reason,
    QtProbeKeys.missing: missing,
    QtProbeKeys.qtClassesPresent: qtClassesPresent,
    QtProbeKeys.qtLibsArrayPresent: qtLibsArrayPresent,
    QtProbeKeys.hostMetaDataPresent: hostMetaDataPresent,
    QtProbeKeys.nativeQtLibsPresent: nativeQtLibsPresent,
    QtProbeKeys.activityContextUsable: activityContextUsable,
    QtProbeKeys.surfaceOwner: surfaceOwner,
    QtProbeKeys.inputOwner: inputOwner,
    QtProbeKeys.lifecycleOwner: lifecycleOwner,
    // 全量写出：切片报告/事件通道用同一 schema，缺一个字段就会让对账行漂移。
    QtProbeKeys.qtWindowAttached: qtWindowAttached,
    QtProbeKeys.surfaceContainerKind: surfaceContainerKind,
    QtProbeKeys.touchPassthrough: touchPassthrough,
    QtProbeKeys.imeOwner: imeOwner,
    QtProbeKeys.resizeOwner: resizeOwner,
    QtProbeKeys.safeAreaOwner: safeAreaOwner,
    QtProbeKeys.activityIsQtActivityBase: activityIsQtActivityBase,
    QtProbeKeys.viewCompositionRequired: viewCompositionRequired,
  };

  @override
  String toString() =>
      'QtHostStatus($verdict.name, missing=$missing, reason=$reason)';
}

List<String> _stringList(Object? raw) {
  if (raw is List) {
    return raw.whereType<String>().toList(growable: false);
  }
  return const <String>[];
}

String _stringOr(Object? raw, String fallback) =>
    raw is String && raw.isNotEmpty ? raw : fallback;

/// 创建平台视图时下发的参数。校验条件复刻 Qt 自己的入口检查，避免把明显非法的
/// 参数送过 JNI 之后再从 tombstone 里读错误。
@immutable
class QtPlatformViewArgs {
  const QtPlatformViewArgs({
    required this.qmlUri,
    required this.qtAppLibraryName,
    this.qmlImportPaths = const <String>[],
    this.applicationParameters = '',
  });

  /// QML 入口，对应 QtQuickView 构造参数 qmlUri。
  final String qmlUri;

  /// Qt app 库名（CMake target 名），对应 QtQuickView 构造参数 appName；
  /// 实例化 QtQuickView 会**加载 Qt 库并启动 Qt 应用**（QtView.java:140-161），
  /// 所以整个进程只允许一个（Node 进程单例约束在平台侧由 QtNative 自己保证）。
  final String qtAppLibraryName;

  /// 额外 QML import path，对应 QtQuickView 的 qmlImportPaths。
  final List<String> qmlImportPaths;

  /// 对应 Qt 的 android.app.arguments（QtLoader.java:118）。
  final String applicationParameters;

  /// 返回空列表表示合法；否则每项是一条与 Qt 源一一对应的拒绝理由。
  ///
  /// 对照：QtQuickView.java:83-86 对 qmlUri 抛
  /// "QtQuickView: argument 'qmlUri' may not be empty or null"；
  /// QtView.java:79-82 对 appLibName 抛 "QtView: argument 'appLibName' may not be empty or null"。
  List<String> validate() {
    final List<String> errors = <String>[];
    if (qmlUri.trim().isEmpty) {
      errors.add("argument 'qmlUri' may not be empty or null");
    }
    if (qtAppLibraryName.trim().isEmpty) {
      errors.add("argument 'appLibName' may not be empty or null");
    }
    for (final String path in qmlImportPaths) {
      if (path.trim().isEmpty) {
        errors.add('qmlImportPaths contains an empty entry');
        break;
      }
    }
    return errors;
  }

  Map<String, Object?> toCreationParams() => <String, Object?>{
    'qmlUri': qmlUri,
    'qtAppLibraryName': qtAppLibraryName,
    'qmlImportPaths': qmlImportPaths,
    'applicationParameters': applicationParameters,
  };
}

/// 窗口形状的 Qt 侧事实。数值来自 Qt 源，Flutter 侧只做「对齐/校验」，
/// 不再自己实现一遍 QtActivity 那套窗口设置（那会和 Flutter 抢窗口，见 archNotes）。
abstract final class QtWindowShape {
  /// Qt/src/AndroidWindow.cpp:16 —— android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
  static const int sensorLandscape = 6;

  /// Qt/src/AndroidWindow.cpp:18 —— FLAG_FULLSCREEN | FLAG_KEEP_SCREEN_ON
  static const int windowFlags = 0x00000400 | 0x00000080;

  /// Qt/src/AndroidWindow.cpp:22 —— 沉浸式粘滞组合位
  static const int immersiveSticky =
      0x00000002 | 0x00000004 | 0x00000100 | 0x00000200 | 0x00000400 | 0x00001000;

  /// Qt 面板是固定横屏（manifest:103 sensorLandscape，运行期 AndroidWindow.cpp:38 再请求一次）。
  /// 宿主切片必须自己保证横屏；竖屏是 P2 的响应式新语义，不是把横屏画面拉伸。
  static bool isLandscape(Size size) => size.width >= size.height;
}

/// 把 Flutter 生命周期映射到 Qt 的应用状态。
///
/// 重要：这不是「驱动 Qt」的映射。真正的 Qt 应用状态由 QtEmbeddedDelegate 自己
/// 通过 Application.ActivityLifecycleCallbacks 驱动
/// （QtEmbeddedDelegate.java:33-64：onActivityResumed→ApplicationActive、
/// onActivityPaused→ApplicationInactive、onActivityStopped→ApplicationSuspended），
/// 宿主**重复驱动会双写状态**。这里的映射只用于观测/对账：
/// Dart 侧把 Flutter 认为的状态与 Qt 的应有状态并排记录，供切片报告比对。
QtAppState qtAppStateForFlutterLifecycle(AppLifecycleState state) {
  switch (state) {
    case AppLifecycleState.resumed:
      return QtAppState.active;
    case AppLifecycleState.inactive:
      return QtAppState.inactive;
    case AppLifecycleState.hidden:
    case AppLifecycleState.paused:
    case AppLifecycleState.detached:
      return QtAppState.suspended;
  }
}

/// 宿主控制器：给上层（ 装配、切片脚本）一个稳定的观测面。
class QtPlatformViewController extends ChangeNotifier {
  QtHostStatus _status = QtHostStatus.unknown;
  QtAppState _lastFlutterAppState = QtAppState.suspended;
  Size _surfaceSize = Size.zero;
  int _platformViewId = -1;
  String? _lastError;
  String? _lastLifecycleObservation;
  QtPlatformCompositionMode _compositionMode =
      QtPlatformCompositionMode.textureLayer;

  QtHostStatus get status => _status;
  QtAppState get lastFlutterAppState => _lastFlutterAppState;
  Size get surfaceSize => _surfaceSize;
  int get platformViewId => _platformViewId;
  String? get lastError => _lastError;
  String? get lastLifecycleObservation => _lastLifecycleObservation;

  /// 当前记录的合成模式。它只是宿主的**选择**，不是对 Qt 的观测：
  /// 「Qt 用了 SurfaceView」这一事实在 [status] 的 surfaceContainerKind /
  /// viewCompositionRequired 里（QtWindow.java:303-325）。
  QtPlatformCompositionMode get compositionMode => _compositionMode;

  void applyStatus(QtHostStatus status) {
    _status = status;
    notifyListeners();
  }

  void applySurfaceSize(Size size) {
    _surfaceSize = size;
    notifyListeners();
  }

  void applyFlutterAppState(QtAppState state) {
    _lastFlutterAppState = state;
    notifyListeners();
  }

  void applyError(String message) {
    _lastError = message;
    notifyListeners();
  }

  /// 记录宿主的合成模式选择（冻结契约 v2 第 (10) 条）。
  ///
  /// 只写状态、不动视图：模式切换要等下一次 build 才生效，已挂载的平台视图
  /// 不会被这里销毁或重建 —— 切片报告需要区分「声明」与「实际」，所以不在这里
  /// 做任何假装已切换的动作。
  void applyCompositionMode(QtPlatformCompositionMode mode) {
    if (_compositionMode == mode) return;
    _compositionMode = mode;
    notifyListeners();
  }

  /// 记录宿主回报的生命周期观测（事件通道 type=lifecycleObservation）。
  /// 纯观测：Qt 的应用状态由 QtEmbeddedDelegate 自己通过 ActivityLifecycleCallbacks
  /// 驱动（QtEmbeddedDelegate.java:33-64），Dart 侧绝不调用 QtNative.setApplicationState，
  /// 否则 Flutter 与 Qt 会交替双写同一个进程级状态。
  void applyLifecycleObservation(Object? observation) {
    _lastLifecycleObservation = observation?.toString();
    notifyListeners();
  }
}

/// 候选 A 的 Flutter 入口 widget。
///
/// 平台不支持 / 平台侧拒绝时，本 widget 渲染 [QtPlatformViewUnavailablePanel]——
/// 一块明确写着裁决与缺失项的诊断面板。这不是幌子：它不模仿 Qt 画面、
/// 不假装加载，且文字直接来自平台探针（QtHostStatus.reason / missing）。
class QtPlatformView extends StatefulWidget {
  const QtPlatformView({
    super.key,
    required this.args,
    this.controller,
    this.onStatus,
    this.onSurfaceSize,
    this.compositionMode = QtPlatformCompositionMode.textureLayer,
  });

  final QtPlatformViewArgs args;
  final QtPlatformViewController? controller;
  final ValueChanged<QtHostStatus>? onStatus;
  final ValueChanged<Size>? onSurfaceSize;

  /// 合成模式（冻结契约 v2 第 (9) 条），默认 textureLayer = 现有 AndroidView 路径。
  ///
  /// 选择依据只能来自平台探针：Qt 在 surfaceContainerType==0 时用 QtSurface
  /// （SurfaceView，QtWindow.java:313、QtSurface.java:14），SurfaceView 无法被
  /// TLHC 纹理化（services/platform_views.dart:131-133），此时必须用
  /// viewComposition（initExpensiveAndroidView，:190-194）。选错了不会「稍微难看」，
  /// 而是拿不到任何 Qt 像素 —— 所以这条不变量由 [qtCompositionWarning] 显式暴露。
  final QtPlatformCompositionMode compositionMode;

  @override
  State<QtPlatformView> createState() => _QtPlatformViewState();
}

class _QtPlatformViewState extends State<QtPlatformView>
    with WidgetsBindingObserver {
  static const MethodChannel _control = MethodChannel(qtPlatformControlChannel);
  static const EventChannel _events = EventChannel(qtPlatformEventChannel);

  StreamSubscription<dynamic>? _eventSub;
  late QtPlatformViewController _controller;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? QtPlatformViewController();
    _ownsController = widget.controller == null;
    // 把 widget 的选择同步进控制器，供切片脚本在 build 之前就能读到。
    _controller.applyCompositionMode(widget.compositionMode);
    WidgetsBinding.instance.addObserver(this);
    _control.setMethodCallHandler(_onPlatformCall);
    _eventSub = _events.receiveBroadcastStream().listen(
      _onPlatformEvent,
      onError: _onPlatformError,
    );
  }

  @override
  void didUpdateWidget(QtPlatformView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.compositionMode != widget.compositionMode) {
      _controller.applyCompositionMode(widget.compositionMode);
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _control.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final QtAppState qtState = qtAppStateForFlutterLifecycle(state);
    _controller.applyFlutterAppState(qtState);
    // 只上报观测值，不去驱动 Qt（见 qtAppStateForFlutterLifecycle 的说明）。
    _control.invokeMethod<void>('flutterLifecycle', <String, Object?>{
      'flutterState': state.name,
      'qtAppState': qtState.wireValue,
      'observabilityOnly': true,
    }).catchError((Object error) {
      _controller.applyError('flutterLifecycle failed: $error');
    });
  }

  Future<dynamic> _onPlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'hostStatus':
        _publishStatus(QtHostStatus.fromMap(call.arguments));
        return null;
      case 'surfaceSize':
        final Object? args = call.arguments;
        if (args is Map) {
          final double w = (args['width'] as num?)?.toDouble() ?? 0;
          final double h = (args['height'] as num?)?.toDouble() ?? 0;
          _controller.applySurfaceSize(Size(w, h));
          widget.onSurfaceSize?.call(Size(w, h));
        }
        return null;
      case 'hostError':
        _controller.applyError('$call.arguments');
        return null;
      default:
        return null;
    }
  }

  void _onPlatformEvent(dynamic event) {
    if (event is! Map) {
      return;
    }
    switch (event['type']) {
      case 'hostStatus':
        // 事件通道送 {type, status}，方法通道送扁平 status（同一份 schema）。
        // 两种形状都接受：onListen 与 refreshProbe 各送一次，谁先到都要能解析。
        final Object? raw = event['status'] ?? event;
        _publishStatus(QtHostStatus.fromMap(raw));
        return;
      case 'surfaceSize':
        final double w = (event['width'] as num?)?.toDouble() ?? 0;
        final double h = (event['height'] as num?)?.toDouble() ?? 0;
        _controller.applySurfaceSize(Size(w, h));
        widget.onSurfaceSize?.call(Size(w, h));
        return;
      case 'lifecycleObservation':
        // 纯观测：Qt 应用状态归 QtEmbeddedDelegate（见 applyLifecycleObservation）。
        _controller.applyLifecycleObservation(event);
        return;
      case 'hostError':
        // 保留：当前宿主把失败写进 hostStatus 的 verdict/reason；将来宿主直报异常时
        // 这里同样落到 lastError，不必再改协议。
        _controller.applyError((event['message'] ?? event).toString());
        return;
      default:
        return;
    }
  }

  void _onPlatformError(Object error) {
    _controller.applyError('event channel error: $error');
  }

  void _publishStatus(QtHostStatus status) {
    _controller.applyStatus(status);
    widget.onStatus?.call(status);
  }

  void _onPlatformViewCreated(int id) {
    _controller._platformViewId = id;
    // 平台侧创建完视图后主动报一次探针结果；这里再补一次刷新，防止 race。
    _control.invokeMethod<dynamic>('refreshProbe', <String, Object?>{
      'viewId': id,
      'qmlUri': widget.args.qmlUri,
    }).catchError((Object error) {
      _controller.applyError('refreshProbe failed: $error');
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<String> argErrors = widget.args.validate();
    if (argErrors.isNotEmpty) {
      return QtPlatformViewUnavailablePanel(
        title: '主机参数不合法',
        verdict: QtHostVerdict.archBlocked,
        detail: argErrors.join('; '),
        missing: argErrors,
      );
    }

    // 只有 Android 真机/模拟器上才存在 QtQuickView 的宿主。其它平台一律面板：
    // widget 测试里 defaultTargetPlatform 会被强制成 android（_platform_io.dart:29-34），
    // 所以测试必须用 debugDefaultTargetPlatformOverride 明确指定宿主平台。
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const QtPlatformViewUnavailablePanel(
        title: 'Qt 平台视图仅在 Android 上成立',
        verdict: QtHostVerdict.archBlocked,
        detail:
            'QtQuickView 是 Android 专有视图（QtView/QtQuickView 位于 Qt 的 Android jar），'
            '本平台没有对应实现，也不会用占位 View 冒充 Qt。',
        missing: <String>['org.qtproject.qt.android.QtQuickView (Android only)'],
      );
    }

    return _QtPlatformViewBody(
      args: widget.args,
      controller: _controller,
      compositionMode: widget.compositionMode,
      onPlatformViewCreated: _onPlatformViewCreated,
    );
  }
}

class _QtPlatformViewBody extends StatelessWidget {
  const _QtPlatformViewBody({
    required this.args,
    required this.controller,
    required this.compositionMode,
    required this.onPlatformViewCreated,
  });

  final QtPlatformViewArgs args;
  final QtPlatformViewController controller;
  final QtPlatformCompositionMode compositionMode;
  final ValueChanged<int> onPlatformViewCreated;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        final QtHostStatus status = controller.status;
        if (qtCompositionMismatch(compositionMode, status)) {
          // probe=ready 只说明宿主前置条件齐了，不代表当前合成模式画得出 Qt 画面：
          // QtSurface 是 SurfaceView（QtWindow.java:303-325 / QtSurface.java:14），
          // textureLayer 走 initAndroidView 的 TLHC/纹理（platform_views.dart:131-133），
          // 拿不到 SurfaceView 的像素。这里必须显式不可用，不能静默走 AndroidView
          // 把一块空白当成 Qt 画面（MF-D14-1）。
          return QtPlatformViewUnavailablePanel(
            title: 'Qt 组合模式不匹配',
            verdict: status.verdict,
            detail: status.reason,
            missing: status.missing,
            archNotes: _archNotesFor(status),
            compositionMode: compositionMode,
            platformStatus: status,
          );
        }
        if (!status.isReady && controller.platformViewId >= 0) {
          // 平台侧明确拒绝：不渲染 AndroidView / PlatformViewLink（那会把一个空白
          // View 当成 Qt 贴上来），渲染诊断面板。
          return QtPlatformViewUnavailablePanel(
            title: 'Qt 宿主未就绪（$status.verdict.name）',
            verdict: status.verdict,
            detail: status.reason,
            missing: status.missing,
            archNotes: _archNotesFor(status),
            compositionMode: compositionMode,
            platformStatus: status,
          );
        }
        if (compositionMode == QtPlatformCompositionMode.viewComposition) {
          return _buildViewComposition(context);
        }
        // textureLayer：保持原路径不变（TLHC/纹理，services/platform_views.dart:131-133）。
        return AndroidView(
          viewType: qtPlatformViewType,
          onPlatformViewCreated: onPlatformViewCreated,
          creationParams: args.toCreationParams(),
          creationParamsCodec: const StandardMessageCodec(),
          // 输入桥接的第一环：把整块区域的手势全量交给平台视图，
          // 否则 Flutter 的 arena 会把拖动/长按吞掉，Qt 收不到完整触摸序列。
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(
              () => EagerGestureRecognizer(),
            ),
          },
        );
      },
    );
  }

  /// 契约 (9)：View Composition 路径。
  ///
  /// 只换「平台视图怎么合成进 Flutter」，不换平台侧那颗 Qt 视图本身：
  /// viewType 与 creationParams 与 textureLayer 分支完全相同，触摸仍由
  /// EagerGestureRecognizer 全量交出（QtWindow.java:246-266 自己消费 MotionEvent
  /// 的视图局部坐标，宿主不再映射一次）。
  ///
  /// 为什么需要它：Qt 在 surfaceContainerType == 0 时用 QtSurface
  /// （QtWindow.java:313 → QtSurface.java:14 extends SurfaceView），而 Flutter 的
  /// initAndroidView 只会把平台视图纹理化（services/platform_views.dart:131-133），
  /// SurfaceView 走不了纹理管线；initExpensiveAndroidView 恒为 Hybrid Composition
  /// （:190-194，:1458-1488 requiresViewComposition => true），才能承载 SurfaceView。
  /// 代价是真实的：Android 9(api 28) 及更低或低端设备上有性能损失（:190-192）。
  Widget _buildViewComposition(BuildContext context) {
    return PlatformViewLink(
      viewType: qtPlatformViewType,
      onCreatePlatformView: (PlatformViewCreationParams params) {
        return PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: qtPlatformViewType,
          layoutDirection: Directionality.of(context),
          creationParams: args.toCreationParams(),
          creationParamsCodec: const StandardMessageCodec(),
        )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          // 第二个监听器只做观测（记录 viewId + 触发 refreshProbe），与 textureLayer
          // 分支里 AndroidView.onPlatformViewCreated 的行为对齐；不改变创建时序。
          ..addOnPlatformViewCreatedListener(onPlatformViewCreated)
          ..create();
      },
      surfaceFactory: (
        BuildContext surfaceContext,
        PlatformViewController controller,
      ) {
        // controller 一定由上面的 onCreatePlatformView 返回，PlatformViewsService
        // 只生产 AndroidViewController 这一族实现（services/platform_views.dart:737）。
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(
              () => EagerGestureRecognizer(),
            ),
          },
        );
      },
    );
  }

  List<String> _archNotesFor(QtHostStatus status) {
    final List<String> notes = <String>[];
    if (!status.activityContextUsable) {
      notes.add(
        'Context 不是 Activity：QtLoader.java:73-76 要求 baseContext 是 Activity/Service，'
        '否则 QtLoader 构造器抛 IllegalArgumentException，QtView.loadQtLibraries 捕获后放弃启动'
        '（QtView.java:144-148）——视图会建出来但 Qt 起不来。',
      );
    }
    if (!status.qtLibsArrayPresent) {
      notes.add(
        '缺 resources array "qt_libs"（androiddeployqt 生成）：QtLoader.java:369-377 缺失时被容忍为'
        '空表，:192-194 另有主 ABI 回退；但空表意味着 Qt 自身的 .so 不会被 System.load，'
        'loadMainLibrary（QtLoader.java:533-536）必失败。另：装载总闸是 resources string '
        '"use_local_qt_libs" 解析为 1（QtLoader.java:379-387、:466-469）。',
      );
    }
    if (!status.hostMetaDataPresent) {
      notes.add(
        '宿主 meta-data 缺失（仅观测，不参与裁决）：QtView.loadQtLibraries 先用构造器参数 '
        'setMainLibraryName（QtView.java:150），QtLoader 仅在 m_mainLibName == null 时回退读 '
        'android.app.lib_name（:524-525）；android.app.arguments 可空（:118 → :242-245 提前返回）。',
      );
    }
    if (!status.nativeQtLibsPresent) {
      notes.add('缺 Qt 的 .so：没有 native 侧就无法产生任何 Qt 表面。');
    }
    return notes;
  }
}

/// 纯决策：宿主已 ready 且观测到需要 View Composition，但当前仍是纹理路径。
///
/// 这是 MF-D14-1 的最小判定面：不看 widget 树、不看平台，只由状态与模式决定，
/// 因此可以在纯 Dart 测试里直接锁定（不需要 Linux/Android 面板路径）。
bool qtCompositionMismatch(
  QtPlatformCompositionMode mode,
  QtHostStatus status,
) {
  return status.isReady &&
      status.viewCompositionRequired &&
      mode != QtPlatformCompositionMode.viewComposition;
}

/// 组合模式约束的唯一判据（冻结契约 v2 第 (2)(3)(9) 条）。
///
/// 返回 null 表示当前组合自洽；否则返回一行给用户看的警示。
///
/// 依据是真实的 Qt 行为：surfaceContainerType == 0 时 Qt 用 QtSurface
/// （QtWindow.java:303-325，:313；QtSurface.java:14 class QtSurface extends SurfaceView），
/// 而 SurfaceView 无法被 Flutter 的 TLHC/纹理管线合成
/// （flutter/lib/src/services/platform_views.dart:131-133 的 initAndroidView 说明），
/// 只有 Hybrid/View Composition 能承载它（:190-194 initExpensiveAndroidView 恒为 HC，
/// :1458-1488 _HybridAndroidViewControllerInternals 的 requiresViewComposition => true）。
///
/// 注意：这条函数只说「组合模式与观测到的容器不匹配」，**不**声称切换后画面就一定
/// 正确——像素与性能只有真机才能裁决。
String? qtCompositionWarning(
  QtPlatformCompositionMode mode,
  QtHostStatus status,
) {
  if (!status.viewCompositionRequired) {
    return null;
  }
  if (mode == QtPlatformCompositionMode.viewComposition) {
    return null;
  }
  return '当前 compositionMode=${mode.wireName}，但 Qt 侧表面容器是 surfaceContainerKind=${status.surfaceContainerKind}：QtSurface 是 SurfaceView（QtWindow.java:303-325 / QtSurface.java:14），Flutter 的 initAndroidView 只走 TLHC/纹理（platform_views.dart:131-133），SurfaceView 无法被纹理化；必须切到 viewComposition（initExpensiveAndroidView 恒为 Hybrid Composition，platform_views.dart:193-194）。在切换并经过真机验证之前，这里保持「不可用」，不会把空白当作 Qt 画面。';
}

/// 明确的「不可用」面板。它就是反幌子的实现：文案里带裁决与缺失项，
/// 并且**不含**任何 Qt 画面、纹理或伪 3D。
class QtPlatformViewUnavailablePanel extends StatelessWidget {
  const QtPlatformViewUnavailablePanel({
    super.key,
    required this.title,
    required this.verdict,
    required this.detail,
    this.missing = const <String>[],
    this.archNotes = const <String>[],
    this.compositionMode = QtPlatformCompositionMode.textureLayer,
    this.platformStatus,
  });

  final String title;
  final QtHostVerdict verdict;
  final String detail;
  final List<String> missing;
  final List<String> archNotes;

  /// 宿主当前声明的合成模式（冻结契约 v2 第 (9)/(10) 条）。
  final QtPlatformCompositionMode compositionMode;

  /// 平台探针快照。null 表示这条面板分支根本没有探针
  /// （参数非法 / 非 Android 宿主），此时不渲染「组合模式约束」区块——
  /// 宁可少显示，也不用 unknown 冒充观测值。
  final QtHostStatus? platformStatus;

  static const Color _bg = Color(0xFF1B1B1F);
  static const Color _fg = Color(0xFFE6E1E5);
  static const Color _muted = Color(0xFF938F99);
  static const Color _warn = Color(0xFFFFB4AB);

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>(qtPlatformViewUnavailablePanelKey),
      color: _bg,
      padding: const EdgeInsets.all(16),
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(title, style: const TextStyle(color: _fg, fontSize: 16)),
            const SizedBox(height: 8),
            Text('[${verdict.name}] $detail',
                style: const TextStyle(color: _muted, fontSize: 13)),
            if (missing.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text('缺失项：${missing.join('、')}',
                  style: const TextStyle(color: _warn, fontSize: 13)),
            ],
            for (final String note in archNotes) ...<Widget>[
              const SizedBox(height: 6),
              Text('· $note', style: const TextStyle(color: _muted, fontSize: 12)),
            ],
            ..._compositionSection(),
          ],
        ),
      ),
    );
  }

  /// 「最小 Qt 适配面 / 组合模式约束」区块（冻结契约 v2 第 (9) 条的面板面）。
  ///
  /// 只陈列**观测到的**事实与**宿主的选择**，不给任何「已可用」结论：
  /// 面板本身的存在就说明这条分支不是 ready。
  List<Widget> _compositionSection() {
    final QtHostStatus? status = platformStatus;
    if (status == null) {
      return const <Widget>[];
    }
    final String? warning = qtCompositionWarning(compositionMode, status);
    return <Widget>[
      const SizedBox(height: 12),
      const Text('组合模式约束（最小 Qt 适配面）',
          style: TextStyle(color: _fg, fontSize: 13)),
      const SizedBox(height: 4),
      _kvRow('compositionMode', compositionMode.wireName),
      _kvRow('qtWindowAttached', status.qtWindowAttached.toString()),
      _kvRow('surfaceContainerKind', status.surfaceContainerKind),
      _kvRow('viewCompositionRequired', status.viewCompositionRequired.toString()),
      _kvRow('touchPassthrough', status.touchPassthrough.toString()),
      _kvRow('resizeOwner', status.resizeOwner),
      _kvRow('imeOwner', status.imeOwner),
      _kvRow('safeAreaOwner', status.safeAreaOwner),
      _kvRow('activityIsQtActivityBase', status.activityIsQtActivityBase.toString()),
      if (warning != null) ...<Widget>[
        const SizedBox(height: 8),
        Text('⚠ $warning', style: const TextStyle(color: _warn, fontSize: 12)),
      ],
    ];
  }

  Widget _kvRow(String key, String value) => Text(
        '$key: $value',
        style: const TextStyle(color: _muted, fontSize: 12),
      );
}

/// 纯函数：把平台侧探针 map 转成判定，供不依赖引擎的单元测试直接调用。
@visibleForTesting
QtHostStatus describeQtHostStatus(Map<String, Object?> probe) =>
    QtHostStatus.fromMap(probe);

/// 便于切片脚本记录的一条对账行：Flutter 语义状态 vs Qt 应有状态。
@visibleForTesting
String qtLifecycleReconciliationLine(
  AppLifecycleState flutterState,
  QtAppState observed,
) {
  final QtAppState expected = qtAppStateForFlutterLifecycle(flutterState);
  final String verdict = expected == observed ? 'MATCH' : 'MISMATCH';
  return 'flutter=${flutterState.name} expectedQt=0x${expected.wireValue.toRadixString(16)} observedQt=0x${observed.wireValue.toRadixString(16)} $verdict';
}

/// 方便集成测试断言「没有假 Qt」：面板必须是这个 key。
const String qtPlatformViewUnavailablePanelKey = 'qt-platform-view-unavailable';

/// JSON 编码助手：切片报告落盘用（与平台侧 probe 输出同一 schema）。
String encodeQtHostStatus(QtHostStatus status) =>
    const JsonEncoder.withIndent('  ').convert(status.toMap());