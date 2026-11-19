// 候选 A（PlatformView 切片）的宿主契约 + 「没有假 Qt」不变量 + 真机切片门。
//
// 前置依赖（未落地前无法按设备命令真机运行）：
//   pubspec.yaml 的 dev_dependencies 需增加 integration_test: sdk: flutter，
//   并把 flutter_test import 换成 integration_test、在 main 首行加
//   IntegrationTestWidgetsFlutterBinding.ensureInitialized。pubspec.yaml 是共享
//   文件、不属本文件改动范围，留给装配方；在那之前本文件用 flutter_test 即可运行。
//
// 契约 v2 依赖：本文件按冻结契约 v2 引用下列符号，实现位于
// lib/platform/qt_platform_view.dart 与
// android/app/src/main/kotlin/rhine/music/database/porting/QtPlatformViewHost.kt：
//   QtPlatformCompositionMode / wireName / fromWire、
//   qtPlatformCompositionTextureLayer / qtPlatformCompositionViewComposition、
//   QtProbeKeys 的 8 个新 key、QtHostStatus 的 8 个新字段、
//   QtPlatformView.compositionMode、QtPlatformViewController.compositionMode /
//   applyCompositionMode。
//   本文件只做契约锁定：断言 key 名、词表、verdict 语义与「不发布像素」的形状，
//   不复制实现，也不替代实现侧的静态核对。行号随实现漂移，复核以函数名重查。
//
// MainActivity / 引擎注册 patch（候选隔离；本文件不落地）：
//   1. MainActivity.configureFlutterEngine 里调用 QtPlatformViewHost.registerWith(engine)。
//      MainActivity 是共享文件，不在本文件改动范围。
//   2. Flutter 的 plugin 自动注册不会注册 PlatformViewFactory —— 必须显式注册，
//      否则 AndroidView/PlatformViewLink 会以 MissingPluginException 结束。
//   3. view composition 只改 Dart 侧的创建 API（PlatformViewLink +
//      initExpensiveAndroidView，Flutter SDK platform_views.dart:193-194 注明
//      "Always creates a Hybrid Composition (HC) view"），viewType 与注册方式不变。
//   4. Context 必须能剥到 Activity：QtLoader.java:73-76 要求 baseContext 是
//      Activity/Service，否则构造器抛 IllegalArgumentException、QtView 捕获后放弃
//      启动（QtView.java:144-148）——视图会建出来但 Qt 起不来。不要传 Application context。

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/platform/qt_platform_view.dart';

/// 真机切片门。默认关闭：没有 Qt android jar / qt_libs 清单 / Qt 的 .so 时
/// 切片只能证明 archBlocked，不能证明画面与性能（ 才能裁决）。
const bool qtSliceDeviceGate =
    bool.fromEnvironment('QT_SLICE_DEVICE', defaultValue: false);

// ── 取值词表（冻结契约 v2 第 (3) 条；与 Kotlin 侧 SURFACE_*/IME_*/RESIZE_*/SAFE_AREA_*
//    常量逐字相同）。Dart 侧契约只要求这 8 个字段与 8 个 key 名，不要求同名常量，
//    所以这里用测试私有字面量做「值级」对账，不去发明生产符号。
const String _surfaceView = 'surface-view';
const String _surfaceTextureView = 'texture-view';
const String _surfaceNone = 'none';
const String _surfaceUnknown = 'unknown';
const String _imeOwnerQt = 'qt-input-delegate';
const String _resizeOwnerQtView = 'qtview-layout-listener';
const String _safeAreaOwnerQtWindow = 'qtwindow-safe-area-listener';
const String _safeAreaOwnerUnavailable = 'unavailable-no-qactivitybase';

/// 契约 v2 第 (4) 条的 8 个新字段名（也是 QtProbeKeys 的新常量名）。
const List<String> _v2ProbeKeyNames = <String>[
  'qtWindowAttached',
  'surfaceContainerKind',
  'touchPassthrough',
  'imeOwner',
  'resizeOwner',
  'safeAreaOwner',
  'activityIsQtActivityBase',
  'viewCompositionRequired',
];

void main() {
  // ── 组 1：纯 Dart 契约（不依赖引擎、不依赖设备）──────────────────────────
  group('Qt host contract', () {
    test('Qt 应用状态位与 QtNative.java:224-229 一致', () {
      // 这些数值是 Qt 的稳定 ABI（源码注释要求与 qnamespace.h 同步），偏差即契约破裂。
      expect(QtAppState.suspended.wireValue, 0x0);
      expect(QtAppState.hidden.wireValue, 0x1);
      expect(QtAppState.inactive.wireValue, 0x2);
      expect(QtAppState.active.wireValue, 0x4);
      expect(QtAppState.fromWire(0x4), QtAppState.active);
      expect(QtAppState.fromWire(0x3), isNull);
      expect(QtAppState.fromWire(null), isNull);
    });

    test('生命周期映射与 QtEmbeddedDelegate.java:33-82 对齐', () {
      expect(qtAppStateForFlutterLifecycle(AppLifecycleState.resumed),
          QtAppState.active);
      expect(qtAppStateForFlutterLifecycle(AppLifecycleState.inactive),
          QtAppState.inactive);
      expect(qtAppStateForFlutterLifecycle(AppLifecycleState.hidden),
          QtAppState.suspended);
      expect(qtAppStateForFlutterLifecycle(AppLifecycleState.paused),
          QtAppState.suspended);
      expect(qtAppStateForFlutterLifecycle(AppLifecycleState.detached),
          QtAppState.suspended);
    });

    test('窗口常量与 AndroidWindow.cpp:16,18,22 一致', () {
      expect(QtWindowShape.sensorLandscape, 6);
      expect(QtWindowShape.windowFlags, 0x00000400 | 0x00000080);
      expect(
        QtWindowShape.immersiveSticky,
        0x00000002 |
            0x00000004 |
            0x00000100 |
            0x00000200 |
            0x00000400 |
            0x00001000,
      );
      expect(QtWindowShape.isLandscape(const Size(1920, 1080)), isTrue);
      expect(QtWindowShape.isLandscape(const Size(1080, 1920)), isFalse);
    });

    test('参数校验复刻 Qt 的构造器文案', () {
      const QtPlatformViewArgs empty =
          QtPlatformViewArgs(qmlUri: '', qtAppLibraryName: '');
      expect(
        empty.validate(),
        contains("argument 'qmlUri' may not be empty or null"),
      );
      expect(
        empty.validate(),
        contains("argument 'appLibName' may not be empty or null"),
      );
      const QtPlatformViewArgs badImports = QtPlatformViewArgs(
        qmlUri: 'qrc:/main.qml',
        qtAppLibraryName: 'appRhineMusicDatabase',
        qmlImportPaths: <String>[''],
      );
      expect(
        badImports.validate(),
        contains('qmlImportPaths contains an empty entry'),
      );
      const QtPlatformViewArgs good = QtPlatformViewArgs(
        qmlUri: 'qrc:/main.qml',
        qtAppLibraryName: 'appRhineMusicDatabase',
      );
      expect(good.validate(), isEmpty);
      expect(good.toCreationParams()['qmlUri'], 'qrc:/main.qml');
    });

    test('探针解析：垃圾输入一律降级为 archBlocked，不乐观放行', () {
      final QtHostStatus garbage = describeQtHostStatus(<String, Object?>{
        'verdict': 'totally-made-up',
      });
      expect(garbage.verdict, QtHostVerdict.archBlocked);
      expect(garbage.isReady, isFalse);
      expect(garbage.mayRenderQtPixels, isFalse);
      // v2 新增字段同样不许因为「没填」就变成可用：缺省一律按契约词表降级。
      expect(garbage.surfaceContainerKind, _surfaceUnknown);
      expect(garbage.viewCompositionRequired, isFalse);
      expect(garbage.qtWindowAttached, isFalse);

      final QtHostStatus notAMap = QtHostStatus.fromMap('nope');
      expect(notAMap.verdict, QtHostVerdict.archBlocked);
      expect(notAMap.missing, contains('probe'));
    });

    test('反幌子不变量：只有 ready 允许当 Qt 画面', () {
      const QtHostStatus ready = QtHostStatus(
        verdict: QtHostVerdict.ready,
        reason: 'all Qt embedding preconditions satisfied',
        qtLibsArrayPresent: true,
        hostMetaDataPresent: true,
        nativeQtLibsPresent: true,
        activityContextUsable: true,
      );
      expect(ready.isReady, isTrue);
      expect(ready.mayRenderQtPixels, isTrue);

      const QtHostStatus device = QtHostStatus(
        verdict: QtHostVerdict.deviceBlocked,
        reason: 'no Qt native libraries in nativeLibraryDir',
      );
      expect(device.isReady, isFalse);
      expect(device.mayRenderQtPixels, isFalse);

      const QtHostStatus arch = QtHostStatus(
        verdict: QtHostVerdict.archBlocked,
        reason: 'missing Qt android classes: org.qtproject.qt.android.QtQuickView',
      );
      expect(arch.mayRenderQtPixels, isFalse);
    });

    test('完整探针 map 往返（与 Kotlin probe() 同 schema）', () {
      final QtHostStatus parsed = describeQtHostStatus(<String, Object?>{
        'verdict': 'archBlocked',
        'reason': 'missing Qt android classes: org.qtproject.qt.android.QtQuickView',
        'missing': <String>['org.qtproject.qt.android.QtQuickView'],
        QtProbeKeys.qtClassesPresent: <String, bool>{'QtQuickView': false},
        QtProbeKeys.qtLibsArrayPresent: false,
        QtProbeKeys.hostMetaDataPresent: false,
        QtProbeKeys.nativeQtLibsPresent: false,
        QtProbeKeys.activityContextUsable: true,
        QtProbeKeys.surfaceOwner:
            'QtQuickView/QtView.addQtWindow (index 0, MATCH_PARENT)',
        QtProbeKeys.inputOwner: 'QtQuickView 自身触摸路径',
        QtProbeKeys.lifecycleOwner:
            'QtEmbeddedDelegate (Application.ActivityLifecycleCallbacks)',
      });
      expect(parsed.verdict, QtHostVerdict.archBlocked);
      expect(parsed.qtClassesPresent['QtQuickView'], isFalse);
      expect(parsed.activityContextUsable, isTrue);
      expect(parsed.lifecycleOwner, contains('QtEmbeddedDelegate'));
      final Map<String, Object?> round = parsed.toMap();
      expect(round['verdict'], 'archBlocked');
      expect(jsonEncode(round), contains('qtClassesPresent'));
      expect(() => jsonDecode(encodeQtHostStatus(parsed)), returnsNormally);
    });

    test('生命周期对账行给出 MATCH/MISMATCH', () {
      expect(
        qtLifecycleReconciliationLine(
            AppLifecycleState.resumed, QtAppState.active),
        allOf(contains('expectedQt=0x4'), contains('observedQt=0x4'), contains('MATCH')),
      );
      expect(
        qtLifecycleReconciliationLine(
            AppLifecycleState.resumed, QtAppState.suspended),
        contains('MISMATCH'),
      );
    });

    test('控制器状态机：未 ready 不产生 Qt 像素授权', () {
      final QtPlatformViewController controller = QtPlatformViewController();
      expect(controller.status.isReady, isFalse);
      expect(controller.platformViewId, -1);
      controller.applyStatus(const QtHostStatus(
        verdict: QtHostVerdict.ready,
        reason: 'all Qt embedding preconditions satisfied',
      ));
      expect(controller.status.isReady, isTrue);
      controller.applyError('boom');
      expect(controller.lastError, 'boom');
      controller.dispose();
    });

    // ── 以下为冻结契约 v2 的静态契约（RED 未验证 / GREEN 未验证）──────────────

    test('组合模式 wire 名与 fromWire 往返（null/未知 → textureLayer）', () {
      // 契约 v2 (1)：两个顶层 const + enum 的 wireName/fromWire。
      expect(qtPlatformCompositionTextureLayer, 'texture-layer');
      expect(qtPlatformCompositionViewComposition, 'view-composition');
      expect(QtPlatformCompositionMode.textureLayer.wireName, 'texture-layer');
      expect(QtPlatformCompositionMode.viewComposition.wireName,
          'view-composition');
      for (final QtPlatformCompositionMode mode
          in QtPlatformCompositionMode.values) {
        expect(QtPlatformCompositionMode.fromWire(mode.wireName), mode,
            reason: 'wireName/fromWire 必须自分自洽：${mode.name}');
      }
      // 容错方向只落一个安全值：textureLayer 是「不额外要求 view composition」的既有分支，
      // 未知输入绝不能升级成 viewComposition（那等于悄悄换渲染路径）。
      expect(QtPlatformCompositionMode.fromWire(null),
          QtPlatformCompositionMode.textureLayer);
      expect(QtPlatformCompositionMode.fromWire(''),
          QtPlatformCompositionMode.textureLayer);
      expect(QtPlatformCompositionMode.fromWire('nonsense'),
          QtPlatformCompositionMode.textureLayer);
      expect(QtPlatformCompositionMode.fromWire('TEXTURE-LAYER'),
          QtPlatformCompositionMode.textureLayer);
    });

    test('qtCompositionMismatch：ready + 需要 VC + 非 VC 才判不匹配（MF-D14-1 纯决策）',
        () {
      const QtHostStatus readyRequired = QtHostStatus(
        verdict: QtHostVerdict.ready,
        reason: 'QtQuickView constructed from appRhineMusicDatabase',
        surfaceContainerKind: 'surface-view',
        viewCompositionRequired: true,
      );
      // 宿主 ready 且观测到 SurfaceView，但默认仍是纹理路径：必须判不匹配，
      // 让 build() 走「Qt 组合模式不匹配」面板，而不是建一个注定空白的 AndroidView。
      expect(
        qtCompositionMismatch(
            QtPlatformCompositionMode.textureLayer, readyRequired),
        isTrue,
      );
      expect(
        qtCompositionMismatch(
            QtPlatformCompositionMode.viewComposition, readyRequired),
        isFalse,
      );

      const QtHostStatus readyTextureOnly = QtHostStatus(
        verdict: QtHostVerdict.ready,
        reason: 'ready without a SurfaceView container',
        viewCompositionRequired: false,
      );
      expect(
        qtCompositionMismatch(
            QtPlatformCompositionMode.textureLayer, readyTextureOnly),
        isFalse,
      );

      // 未 ready 时这条纯判定必须让位：宿主真正的降级理由归主面板，
      // 不能用一个组合模式文案把 archBlocked/deviceBlocked 的原因盖掉。
      const QtHostStatus blocked = QtHostStatus(
        verdict: QtHostVerdict.archBlocked,
        reason: 'missing resources array "qt_libs"',
        viewCompositionRequired: true,
      );
      expect(
        qtCompositionMismatch(
            QtPlatformCompositionMode.textureLayer, blocked),
        isFalse,
      );
    });

    test('新增 8 个探针 key 名逐字冻结，既有 key 一个都没改名', () {
      expect(QtProbeKeys.qtWindowAttached, 'qtWindowAttached');
      expect(QtProbeKeys.surfaceContainerKind, 'surfaceContainerKind');
      expect(QtProbeKeys.touchPassthrough, 'touchPassthrough');
      expect(QtProbeKeys.imeOwner, 'imeOwner');
      expect(QtProbeKeys.resizeOwner, 'resizeOwner');
      expect(QtProbeKeys.safeAreaOwner, 'safeAreaOwner');
      expect(QtProbeKeys.activityIsQtActivityBase, 'activityIsQtActivityBase');
      expect(QtProbeKeys.viewCompositionRequired, 'viewCompositionRequired');

      // 回归护闸：这些是 v2 之前的既有 key，名字必须逐字不变（Kotlin 侧同名输出）。
      expect(QtProbeKeys.qtClassesPresent, 'qtClassesPresent');
      expect(QtProbeKeys.missing, 'missing');
      expect(QtProbeKeys.qtLibsArrayPresent, 'qtLibsArrayPresent');
      expect(QtProbeKeys.hostMetaDataPresent, 'hostMetaDataPresent');
      expect(QtProbeKeys.nativeQtLibsPresent, 'nativeQtLibsPresent');
      expect(QtProbeKeys.activityContextUsable, 'activityContextUsable');
      expect(QtProbeKeys.surfaceOwner, 'surfaceOwner');
      expect(QtProbeKeys.inputOwner, 'inputOwner');
      expect(QtProbeKeys.lifecycleOwner, 'lifecycleOwner');
    });

    test('新字段缺省词表：缺 key 时按契约限定缺省，不乐观取值', () {
      // 契约 v2 (4) 的缺省顺序：
      // false / 'unknown' / false / 'qt-input-delegate' / 'qtview-layout-listener' /
      // 'unknown' / false / false
      final QtHostStatus defaults = QtHostStatus.fromMap(<String, Object?>{
        'verdict': 'archBlocked',
        'reason': 'probe without v2 fields',
      });
      expect(defaults.qtWindowAttached, isFalse);
      expect(defaults.surfaceContainerKind, _surfaceUnknown);
      expect(defaults.touchPassthrough, isFalse);
      expect(defaults.imeOwner, _imeOwnerQt);
      expect(defaults.resizeOwner, _resizeOwnerQtView);
      expect(defaults.safeAreaOwner, _surfaceUnknown);
      expect(defaults.activityIsQtActivityBase, isFalse);
      expect(defaults.viewCompositionRequired, isFalse);

      // 缺 key ≠ 可用：缺省组合仍然不许放出 Qt 像素。
      expect(defaults.mayRenderQtPixels, isFalse);
    });

    test('显式探针值原样透传：Dart 不自行推导 viewCompositionRequired', () {
      // 推导源只有宿主一处（契约 v2 (3)：viewCompositionRequired =
      // (surfaceContainerKind=='surface-view')，由 Kotlin 观测函数算出）。
      // Dart 侧只做字段透传：宿主自相矛盾时也要把矛盾原样交给上层，
      // 不许「顺手修正」——修正会把宿主 bug 变成 Dart 的静默行为。
      final QtHostStatus texture = QtHostStatus.fromMap(<String, Object?>{
        'verdict': 'ready',
        'reason': 'QtQuickView constructed from appRhineMusicDatabase',
        QtProbeKeys.qtWindowAttached: true,
        QtProbeKeys.surfaceContainerKind: _surfaceTextureView,
        QtProbeKeys.touchPassthrough: true,
        QtProbeKeys.imeOwner: _imeOwnerQt,
        QtProbeKeys.resizeOwner: _resizeOwnerQtView,
        QtProbeKeys.safeAreaOwner: _safeAreaOwnerQtWindow,
        QtProbeKeys.activityIsQtActivityBase: false,
        QtProbeKeys.viewCompositionRequired: false,
      });
      expect(texture.qtWindowAttached, isTrue);
      expect(texture.surfaceContainerKind, _surfaceTextureView);
      expect(texture.touchPassthrough, isTrue);
      expect(texture.imeOwner, _imeOwnerQt);
      expect(texture.resizeOwner, _resizeOwnerQtView);
      expect(texture.safeAreaOwner, _safeAreaOwnerQtWindow);
      expect(texture.activityIsQtActivityBase, isFalse);
      expect(texture.viewCompositionRequired, isFalse);

      // 宿主自报 SurfaceView 却把 viewCompositionRequired 置 false：原样透传 false。
      final QtHostStatus inconsistent = QtHostStatus.fromMap(<String, Object?>{
        QtProbeKeys.surfaceContainerKind: _surfaceView,
        QtProbeKeys.viewCompositionRequired: false,
      });
      expect(inconsistent.surfaceContainerKind, _surfaceView);
      expect(inconsistent.viewCompositionRequired, isFalse);

      // 反向：texture-view 却要求 view composition，也原样透传 true。
      final QtHostStatus reverse = QtHostStatus.fromMap(<String, Object?>{
        QtProbeKeys.surfaceContainerKind: _surfaceTextureView,
        QtProbeKeys.viewCompositionRequired: true,
      });
      expect(reverse.viewCompositionRequired, isTrue);

      // toMap 必须全量写出这 8 个 key（少写一个，切片报告就丢一条证据）。
      final Map<String, Object?> round = texture.toMap();
      for (final String key in _v2ProbeKeyNames) {
        expect(round.containsKey(key), isTrue, reason: 'toMap 必须写出 $key');
      }
      expect(round[QtProbeKeys.surfaceContainerKind], _surfaceTextureView);
      expect(round[QtProbeKeys.imeOwner], _imeOwnerQt);
      expect(round[QtProbeKeys.activityIsQtActivityBase], isFalse);
      expect(jsonDecode(encodeQtHostStatus(texture)), isA<Map<String, dynamic>>());
    });

    test('取值词表逐字：容器类型 4 值、IME/尺寸 owner 的合法值与 safe area 两态', () {
      // surfaceContainerKind ∈ {'surface-view','texture-view','none','unknown'}
      for (final String kind in <String>[
        _surfaceView,
        _surfaceTextureView,
        _surfaceNone,
        _surfaceUnknown,
      ]) {
        expect(
          QtHostStatus.fromMap(<String, Object?>{
            QtProbeKeys.surfaceContainerKind: kind,
          }).surfaceContainerKind,
          kind,
          reason: '词表值必须逐字透传：$kind',
        );
      }

      // imeOwner 只有 'qt-input-delegate' 一个合法值（缺省即该值）：
      // 证据 QtInputDelegate.java:214-240 showSoftwareKeyboard / QtEditText.java:111-133
      // onCreateInputConnection —— IME 全部由 Qt C++ 经 QtInputInterface 驱动。
      expect(_imeOwnerQt, 'qt-input-delegate');
      expect(
        QtHostStatus.fromMap(<String, Object?>{
          QtProbeKeys.imeOwner: _imeOwnerQt,
        }).imeOwner,
        _imeOwnerQt,
      );

      // resizeOwner 只有 'qtview-layout-listener' 一个合法值：
      // 证据 QtView.java:50-69 addOnLayoutChangeListener → resizeWindow。
      expect(_resizeOwnerQtView, 'qtview-layout-listener');
      expect(
        QtHostStatus.fromMap(<String, Object?>{
          QtProbeKeys.resizeOwner: _resizeOwnerQtView,
        }).resizeOwner,
        _resizeOwnerQtView,
      );

      // safeAreaOwner ∈ {'qtwindow-safe-area-listener','unavailable-no-qactivitybase'}：
      // 证据 QtWindow.java:92（方法体 :90-150）—— 只有 getContext() instanceof QtActivityBase
      // 才注册 setOnApplyWindowInsetsListener；Flutter 宿主不是 QtActivityBase，合法值是后者。
      expect(_safeAreaOwnerQtWindow, 'qtwindow-safe-area-listener');
      expect(_safeAreaOwnerUnavailable, 'unavailable-no-qactivitybase');
      for (final String owner in <String>[
        _safeAreaOwnerQtWindow,
        _safeAreaOwnerUnavailable,
      ]) {
        expect(
          QtHostStatus.fromMap(<String, Object?>{
            QtProbeKeys.safeAreaOwner: owner,
          }).safeAreaOwner,
          owner,
        );
      }
    });
  });

  // ── 组 2：宿主平台上的渲染不变量（当前主机不是 Android）──────────────────
  group('No-fake rendering', () {
    // SF-1（旧审 selfFoundDefects，已达标，保留并显式记录）：flutter_test 会把
    // defaultTargetPlatform 强制成 android（_platform_io.dart:29-34），
    // 所以必须显式指定一个非 Android 宿主，否则测不到「非 Android → 诊断面板」这条分支。
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    });

    tearDown(() {
      // 必须复位成 null，否则覆盖会泄漏到同进程后面的测试（包括组 3 的门）。
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('非 Android 平台上不允许出现 AndroidView，只能渲染诊断面板', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: QtPlatformView(
            args: QtPlatformViewArgs(
              qmlUri: 'qrc:/main.qml',
              qtAppLibraryName: 'appRhineMusicDatabase',
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>(qtPlatformViewUnavailablePanelKey)),
        findsOneWidget,
      );
      // SF-2（旧审 selfFoundDefects，已达标）：面板上必须出现「本平台没有 Qt/Android」
      // 的真实原因，而不是伪装加载动画。这里只做 textContaining('Android')，
      // 不再自造同义反复 matcher。
      expect(find.textContaining('Android'), findsWidgets);
      // 反幌子的硬断言：这条分支上不存在 AndroidView，也就没有任何容器能冒充 Qt 表面。
      expect(find.byType(AndroidView), findsNothing);
    });

    testWidgets('非法参数直接拒绝，且不落到平台视图', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: QtPlatformView(
            args: QtPlatformViewArgs(qmlUri: '', qtAppLibraryName: ''),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('主机参数不合法'), findsOneWidget);
      expect(find.textContaining("qmlUri"), findsWidgets);
    });

    // SF-3（旧审 selfFoundDefects）：原测试先 controller.applyStatus(...) 再断言刚设进去的
    // 同一个值，是同义反复且与测试名不符。改造后：解析一份**真实形状的 archBlocked 探针
    // map**（缺 Qt 类 / 缺 qt_libs 清单 / use_local_qt_libs 未置位 / nativeQtLibsPresent=false），
    // 断言 verdict/reason/missing/observed 字段与缺省词表，再把解析结果喂给面板，
    // 断言面板文本里出现 verdict 与缺失类名。测试名与断言一一对应。
    testWidgets('archBlocked 探针 map 原样渲染，且不发布 Qt 像素', (WidgetTester tester) async {
      // 这份 map 就是 QtPlatformViewHost.probe() 在「本 Flutter 工程没有 Qt android jar」
      // 时的真实输出形状（QtPlatformViewHost.probe()）：缺类 → archBlocked 的第一因。
      final Map<String, Object?> probe = <String, Object?>{
        'verdict': 'archBlocked',
        'reason': 'missing Qt android classes: '
            'org.qtproject.qt.android.QtQuickView; '
            'missing resources array "qt_libs" (androiddeployqt); '
            'resources string "use_local_qt_libs" is not 1',
        'missing': <String>[
          'org.qtproject.qt.android.QtQuickView',
          'org.qtproject.qt.android.QtView',
        ],
        QtProbeKeys.qtClassesPresent: <String, bool>{
          'QtQuickView': false,
          'QtView': false,
        },
        QtProbeKeys.qtLibsArrayPresent: false,
        QtProbeKeys.hostMetaDataPresent: false,
        QtProbeKeys.nativeQtLibsPresent: false,
        QtProbeKeys.activityContextUsable: true,
        QtProbeKeys.surfaceOwner:
            'QtQuickView/QtView.addQtWindow (index 0, MATCH_PARENT)',
        QtProbeKeys.inputOwner:
            'QtQuickView 自身触摸路径 (Flutter EagerGestureRecognizer 全量交出)',
        QtProbeKeys.lifecycleOwner:
            'QtEmbeddedDelegate (Application.ActivityLifecycleCallbacks)',
      };
      final QtHostStatus parsed = describeQtHostStatus(probe);

      // 1) 裁决/原因/缺失项逐字段对账（不是「我刚设进去的值」）。
      expect(parsed.verdict, QtHostVerdict.archBlocked);
      expect(parsed.reason, contains('missing Qt android classes'));
      expect(parsed.reason, contains('org.qtproject.qt.android.QtQuickView'));
      expect(parsed.missing, contains('org.qtproject.qt.android.QtQuickView'));
      expect(parsed.missing, contains('org.qtproject.qt.android.QtView'));

      // 2) observed（宿主实测）字段。
      expect(parsed.qtClassesPresent['QtQuickView'], isFalse);
      expect(parsed.qtClassesPresent['QtView'], isFalse);
      expect(parsed.qtLibsArrayPresent, isFalse);
      expect(parsed.hostMetaDataPresent, isFalse);
      expect(parsed.nativeQtLibsPresent, isFalse);
      expect(parsed.activityContextUsable, isTrue);
      expect(parsed.surfaceOwner, contains('addQtWindow'));
      expect(parsed.inputOwner, contains('QtQuickView'));
      expect(parsed.lifecycleOwner, contains('QtEmbeddedDelegate'));

      // 3) v2 新字段在 archBlocked 探针里缺席 → 按契约缺省词表降级。
      expect(parsed.qtWindowAttached, isFalse);
      expect(parsed.surfaceContainerKind, _surfaceUnknown);
      expect(parsed.touchPassthrough, isFalse);
      expect(parsed.imeOwner, _imeOwnerQt);
      expect(parsed.resizeOwner, _resizeOwnerQtView);
      expect(parsed.safeAreaOwner, _surfaceUnknown);
      expect(parsed.activityIsQtActivityBase, isFalse);
      expect(parsed.viewCompositionRequired, isFalse);

      // 4) 不变量：archBlocked 永远不许被当成可以出 Qt 像素。
      expect(parsed.isReady, isFalse);
      expect(parsed.mayRenderQtPixels, isFalse);

      // 5) 面板原样渲染：用解析结果（而不是字面量）喂面板，断言 verdict 与缺失类名可见。
      //    面板接线与 _QtPlatformViewBody.build 的拒绝分支同构（title 带裁决名，
      //    detail 用 reason，missing 用探针的 missing）。
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QtPlatformViewUnavailablePanel(
            title: 'Qt 宿主未就绪（${parsed.verdict.name}）',
            verdict: parsed.verdict,
            detail: parsed.reason,
            missing: parsed.missing,
          ),
        ),
      ));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>(qtPlatformViewUnavailablePanelKey)),
        findsOneWidget,
      );
      expect(find.textContaining('archBlocked'), findsWidgets);
      expect(find.textContaining('QtQuickView'), findsWidgets);
      expect(find.textContaining('缺失项'), findsOneWidget);
      // 面板不是 Qt 画面：这条分支里连 AndroidView 都不存在。
      expect(find.byType(AndroidView), findsNothing);
    });

    testWidgets('诊断面板原样展示裁决、原因、缺失项与架构备注', (WidgetTester tester) async {
      // 真实失败路径的画面：Qt 在编译期/加载期缺席时，用户看到的就是这些文字。
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: QtPlatformViewUnavailablePanel(
            title: 'Qt 宿主未就绪（archBlocked）',
            verdict: QtHostVerdict.archBlocked,
            detail: 'missing Qt android classes: org.qtproject.qt.android.QtQuickView',
            missing: <String>['org.qtproject.qt.android.QtQuickView'],
            archNotes: <String>['缺 Qt 的 .so：没有 native 侧就无法产生任何 Qt 表面。'],
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('Qt 宿主未就绪（archBlocked）'), findsOneWidget);
      expect(find.textContaining('archBlocked'), findsWidgets);
      expect(find.textContaining('QtQuickView'), findsWidgets);
      expect(find.textContaining('缺失项'), findsOneWidget);
      expect(find.textContaining('缺 Qt 的 .so'), findsOneWidget);
    });

    testWidgets('QtPlatformView 默认组合模式是 textureLayer，显式 viewComposition 能落到控制器',
        (WidgetTester tester) async {
      // 契约 v2 (9)+(10)：widget 有 final compositionMode（默认 textureLayer），
      // 控制器有同名可读字段 + applyCompositionMode。
      final QtPlatformViewController byDefault = QtPlatformViewController();
      expect(byDefault.compositionMode, QtPlatformCompositionMode.textureLayer,
          reason: '控制器默认必须是既有纹理分支，不许默认升级成 HC');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QtPlatformView(
            args: const QtPlatformViewArgs(
              qmlUri: 'qrc:/main.qml',
              qtAppLibraryName: 'appRhineMusicDatabase',
            ),
            controller: byDefault,
          ),
        ),
      ));
      await tester.pump();
      expect(byDefault.compositionMode, QtPlatformCompositionMode.textureLayer);

      final QtPlatformViewController explicit = QtPlatformViewController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QtPlatformView(
            args: const QtPlatformViewArgs(
              qmlUri: 'qrc:/main.qml',
              qtAppLibraryName: 'appRhineMusicDatabase',
            ),
            controller: explicit,
            compositionMode: QtPlatformCompositionMode.viewComposition,
          ),
        ),
      ));
      await tester.pump();
      expect(explicit.compositionMode, QtPlatformCompositionMode.viewComposition,
          reason: '显式 view-composition 必须原样落到控制器，供切片报告记录实际路径');
      expect(explicit.status.viewCompositionRequired, isFalse,
          reason: 'compositionMode 是宿主选择，不能反过来伪造探针结论');

      // 控制器自己的 applyCompositionMode 也要能切回来（组 3 用它记录「实际可行路径」）。
      explicit.applyCompositionMode(QtPlatformCompositionMode.textureLayer);
      expect(explicit.compositionMode, QtPlatformCompositionMode.textureLayer);
    });

    testWidgets('宿主自报需要 view composition 而当前是 textureLayer 时不许出现 AndroidView',
        (WidgetTester tester) async {
      // 反幌子不变量（契约 v2 (3)(9)）：surfaceContainerKind=='surface-view' ⇒
      // viewCompositionRequired==true，而 SurfaceView 的像素不会被合成进 Flutter 的
      // 纹理路径（Flutter SDK platform_views.dart:131-133 的 TLHC/VirtualDisplay 回退），
      // 所以这条组合在 textureLayer 下不能当作「可用 Qt 画面」。
      final QtHostStatus mismatch = QtHostStatus.fromMap(<String, Object?>{
        'verdict': 'ready',
        'reason': 'QtQuickView constructed from appRhineMusicDatabase',
        QtProbeKeys.qtWindowAttached: true,
        QtProbeKeys.surfaceContainerKind: _surfaceView,
        QtProbeKeys.touchPassthrough: true,
        QtProbeKeys.viewCompositionRequired: true,
      });
      expect(mismatch.surfaceContainerKind, _surfaceView);
      expect(mismatch.viewCompositionRequired, isTrue);

      final QtPlatformViewController controller = QtPlatformViewController()
        ..applyStatus(mismatch)
        ..applyCompositionMode(QtPlatformCompositionMode.textureLayer);
      expect(controller.compositionMode, QtPlatformCompositionMode.textureLayer);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QtPlatformView(
            args: const QtPlatformViewArgs(
              qmlUri: 'qrc:/main.qml',
              qtAppLibraryName: 'appRhineMusicDatabase',
            ),
            controller: controller,
          ),
        ),
      ));
      await tester.pump();
      // 非 Android 宿主上这条面板由平台门（defaultTargetPlatform != android）先命中，
      // 所以本断言只能证明「没有任何 AndroidView 容器在这里冒充 Qt 表面」，
      // **不能**证明组合模式警示文案本身：文案只能在真实 Android 宿主上观察，
      // 已列为组 3 第 7 步。此处刻意不写死任何自造文案 —— 否则就是 SF-3 那类
      // 「自造文案 + 自证」的同义反复。
      expect(find.byType(AndroidView), findsNothing);
      expect(
        find.byKey(const ValueKey<String>(qtPlatformViewUnavailablePanelKey)),
        findsOneWidget,
      );
      expect(controller.status.mayRenderQtPixels, isTrue,
          reason: 'verdict==ready 时 mayRenderQtPixels 按既有语义为 true；'
              '组合模式不一致是**渲染路径**问题，不许在 Dart 侧篡改裁决');
    });
  });

  // ── 组 3：真机切片（需要 Android 设备 + Qt 产物；默认 skip）───────────────
  group('On-device Qt slice', () {
    testWidgets(
      '宿主探针 + 输入回执 + 生命周期对账（DEVICE_BLOCKED 前不得宣称可用）',
      (WidgetTester tester) async {
        // 补齐 integration_test 依赖与 Qt 产物后
        // 按下列顺序跑；每一步都必须在报告里留下**观测值**，不许用截图或「编译通过」代替。
        //
        //   1. touch：tester.dragFrom 在平台视图区域内拖动。
        //      链路证据：QtHostRootView.dispatchTouchEvent 只计数后 super 原样转发
        //      （QtPlatformViewHost.QtHostRootView.dispatchTouchEvent，不消费、不改坐标、不 setOnTouchListener）
        //      → QtWindow.onTouchEvent (QtWindow.java:246-266) 在首次触摸时才初始化 editText
        //      焦点，然后 windowFocusChanged(true,getId()) →
        //      QtInputDelegate.sendTouchEvent(event, getId())（QtWindow.java:262；
        //      实现 QtInputDelegate.java:654-708，包内可见、宿主不可直接调）。
        //      MotionEvent 坐标就是相对本视图的局部坐标（QtInputDelegate.java:683-684
        //      直接 getX(i)/getY(i)），所以宿主**不得**自己再做一次坐标映射；
        //      断言 touchEvents > 0 且 lastTouchAction 与实际手势一致，不做任何像素比对。
        //
        //   2. resize：拖动窗口/改变分屏 → 宿主 onSizeChanged 报真实尺寸
        //      （QtPlatformViewHost.QtHostRootView.onSizeChanged），Qt 侧自己按
        //      QtView.java:50-69 的 addOnLayoutChangeListener → resizeWindow( ... )（:42-43
        //      native 声明，:63 调用）重排。宿主只提供真实尺寸，不自算、不补偿。
        //      断言：surfaceSize 事件里的宽高 == 视图实际宽高。
        //
        //   3. IME：点 QML 输入框。证据 QtInputDelegate.java:214-240 showSoftwareKeyboard
        //      （由 Qt C++ 侧经 QtInputInterface 调用）+ QtEditText.java:111-133
        //      onCreateInputConnection；softInputMode 由 QtActivityDelegateBase.java:83-104
        //      从 manifest 读出后交给 QtInputDelegate。
        //      断言：宿主不出现任何 InputMethodManager.show/hide 调用 —— 宿主不驱动 IME。
        //
        //   4. texture：Qt 侧 createSurface（QtWindow.java:303-325）按 surfaceContainerType
        //      选容器：==0 → QtSurface（SurfaceView，QtSurface.java:14-28），否则 →
        //      QtTextureView（QtTextureView.java:14-29）。SurfaceView 在 Flutter 的
        //      纹理合成路径下不会被合成（Flutter SDK platform_views.dart:131-133：
        //      能用 TLHC 就用 TLHC，否则退回 Virtual Display），因此
        //      surfaceContainerKind=='surface-view' 时 viewCompositionRequired 必须为 true，
        //      Dart 侧必须走 compositionMode=viewComposition（initExpensiveAndroidView，
        //      platform_views.dart:193-194）。
        //
        //   5. 旋转/前后台：manifest 两个 Activity 都是 sensorLandscape
        //      （AndroidManifest.xml:89、:103），运行期 AndroidWindow.cpp:25-51 的
        //      applyWindowShape() 在 runOnAndroidMainThread 里再请求一次方向/标志
        //      （注释说明标志只能 UI 线程改，主线程直接 JNI 会 CalledFromWrongThreadException）；
        //      前台/后台由 AndroidWindow.cpp:85-118 的 applicationStateChanged 处理
        //      （setVisible / quick->setVisible / trimMemory）。
        //      断言：activityIsQtActivityBase==false（Flutter 宿主不是 QtActivityBase）、
        //      safeAreaOwner=='unavailable-no-qactivitybase'（QtWindow.java:92，方法体 :90-150；
        //      inset listener 只在 QtActivityBase 下注册；QtWindow.java:338-345 的
        //      setGeometry 同样只对 QtActivityBase 生效），并记录旋转前后 surfaceSize。
        //
        //   6. 媒体会话：AndroidMediaSession::ensureStarted()（AndroidWindow.cpp:79）由 Qt 侧
        //      configureAndroidWindow 在首帧前拉起前台服务；Flutter 宿主不 drive 它。
        //      断言：只记录「Qt 侧是否已启动」，不许把宿主自己的 Service 状态当成 Qt 的。
        //
        //   7. 组合模式警示：viewCompositionRequired==true 且 compositionMode==textureLayer
        //      时，面板/警示文案必须出现（本条只能在真实 Android 宿主观察，见组 2 同名
        //      测试的说明）。记录实际文案与 Qt 容器类型。
        //
        //   8. 收尾：verdict != ready 时把 missing/reason 原样写进切片报告，这就是本树的
        //      真实结论；archBlocked/deviceBlocked 绝不改写成「通过」，也不许用静态截图
        //      或「编译通过」冒充嵌入可用。
        //
        // 本占位断言只证明「门确实被打开过」，不是任何功能的证据。
        expect(qtSliceDeviceGate, isTrue,
            reason: '组 3 需 -d <device> 且 --dart-define=QT_SLICE_DEVICE=true');
      },
      skip: !qtSliceDeviceGate,
    );
  });
}
