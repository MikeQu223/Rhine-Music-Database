import 'package:flutter/foundation.dart';
// Factory<T> 来自 package:flutter/foundation.dart（dart:core 的 typedef），
// gestures.dart 只导出 OneSequenceGestureRecognizer 这类具体识别器。
import 'package:flutter/gestures.dart' show OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart'
    show AndroidViewController, PlatformViewController, PlatformViewsService;

/// PARITY QT-OVERLAY-128 — 把本仓库 **Qt 自己的场景层**挂进 Flutter 页面。
///
/// 这里不是近似重写，也不是"看起来像 3D"的东西：
///  * 原生实现是 Qt 的 `QQuickView`（材质、改过的模型、相机、归档布局、抽出返回、
///    触摸与动画全部由 Qt 的 RhiScene/NativeScene* 负责），在同一个进程里创建；
///  * Java 对端是 org.qtproject.qt.android.RhineQtView extends QtView（
///    android/app/src/main/java/org/qtproject/qt/android/RhineQtView.java），
///    它把 QQuickView 的窗口挂到 Flutter 的 platform view 上；
///  * 本文件只负责"给这块原生视图一个矩形"，不复制相机/HUD，也不再有 WebView、
///    Three.js、截图或 startActivity。
///
/// 必须用 hybrid composition（[PlatformViewsService.initExpensiveAndroidView]）：
/// Qt 的 `QtWindow` 内部是真 `SurfaceView`（QtSurface），纹理层合成拿不到它，
/// 而 hybrid composition 把原生视图放进同一棵 Android 视图树——触摸因此是 Android
/// 自己的派发路径，Flutter 侧不拦、不改写，Qt 的手势不会被吞。
///
/// 非 Android 平台给显式说明（不渲染模型、不伪造旋转动画）。
const String qtSceneViewType = 'rhine/qt_scene';

/// 只有 Android 有真正的 Qt 视图实现。
bool get qtScenePlatformSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

String qtScenePlatformLabel() => kIsWeb ? 'Web' : defaultTargetPlatform.name;

const Color _sceneBackground = Color(0xFF11181B);
const Color _sceneText = Color(0xFFE7E0D7);
const Color _sceneMuted = Color(0xFF98A2A6);

/// 页面里的 Qt 场景视图。
///
/// [onCreated] 收到 platform view id；调用方只用来打日志/排障。
/// 分工是明确的：场景状态（材质、模型、相机、归档布局、触摸、动画）由 Qt 的
/// Engine/场景层持有；Siren 界面的曲库与播放仍由 Flutter 这一侧持有（移动端的
/// Engine 不建播放权威，main.cpp 里 PlaybackConnection 只在非 RHINE_MOBILE 下创建），
/// 因此这个矩形里不存在第二套播放器或第二份曲库。
class QtSceneView extends StatelessWidget {
  const QtSceneView({super.key, this.onCreated});

  final ValueChanged<int>? onCreated;

  @override
  Widget build(BuildContext context) {
    if (!qtScenePlatformSupported) {
      return QtSceneUnsupported(platformLabel: qtScenePlatformLabel());
    }
    // Hybrid composition 的 layoutDirection 在创建 controller 时必须给定，
    // PlatformViewCreationParams 本身不带这个字段（Flutter 3.47），从 Directionality 取。
    final TextDirection layoutDirection = Directionality.maybeOf(context) ??
        TextDirection.ltr;
    return PlatformViewLink(
      viewType: qtSceneViewType,
      surfaceFactory: (BuildContext context, PlatformViewController controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          // opaque：这块矩形归 Qt。HUD 的其它层若需要命中，由 Flutter 自己的
          // gesture detector 处理，两边各自成立、互不改写对方的事件。
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          // 空集合 = 所有触摸原样交给原生视图（Qt）。这里刻意不注册
          // EagerGestureRecognizer 之外的任何识别器，也不在 Flutter 侧再叠一套
          // 相机拖拽——那会与 Qt 的 NativeSceneInput 抢同一次拖动。
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        );
      },
      onCreatePlatformView: (PlatformViewCreationParams params) {
        final AndroidViewController controller =
            PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: qtSceneViewType,
          layoutDirection: layoutDirection,
          // onFocus 在这里不注册：Qt 视图自己拿 focus（QtView/QtWindow 的舞台与
          // 输入层由 Qt 的 Overlay/输入路径管理），Flutter 侧不参与焦点仲裁。
        );
        final ValueChanged<int>? listener = onCreated;
        if (listener != null) {
          controller.addOnPlatformViewCreatedListener(listener);
        }
        return controller;
      },
    );
  }
}

/// 非 Android 的显式占位：说明这里没有场景实现，而不是画一张假的 3D 图。
class QtSceneUnsupported extends StatelessWidget {
  const QtSceneUnsupported({super.key, required this.platformLabel});

  final String platformLabel;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _sceneBackground,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.view_in_ar_outlined,
                size: 30,
                color: _sceneMuted,
              ),
              const SizedBox(height: 10),
              const Text(
                '3D 场景预览仅在 Android 可用',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _sceneText,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '当前平台：$platformLabel。这里不渲染模型、截图或旋转动画；'
                'Android 上这个矩形里是 Qt 自己的 QQuickView（同进程原生视图）。',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: _sceneMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
