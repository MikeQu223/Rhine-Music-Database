import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/qt_scene_view.dart';
import 'package:rhine_music_database/hud/input/hit_layer.dart';
import 'package:rhine_music_database/hud/protocol/hud_frame.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';
import 'package:rhine_music_database/ui/layout/portrait_stage.dart';

BasicGlyphPorts _ports() {
  final GlyphFontSet fonts = GlyphFontSet.empty;
  final GlyphText text = GlyphText.resourceOnly(fonts);
  return BasicGlyphPorts(glyphs: fonts, text: text);
}

/// 刚启动、尚未加载曲库：没有任何选中 id，正是 92 永远不挂 3D 的那种状态。
BasicViewState _emptyLibrary() => const BasicViewState(
      phase: BasicPhase.library,
      status: '正在读取塞壬唱片曲库…',
    );

Widget _landscapeHarness({required Size size, required BasicViewState state}) {
  final StageGeometry geometry = StageGeometry(
    logicalWidth: size.width,
    logicalHeight: size.height,
  );
  final HudStage stage = HudStage(
    scale: geometry.stageScale,
    width: geometry.stageWidth,
    height: StageGeometry.baseHeight,
  );
  return Directionality(
    textDirection: TextDirection.ltr,
    child: SizedBox(
      width: size.width,
      height: size.height,
      child: StageGeometryScope(
        geometry: geometry,
        child: HudStageScope(
          stage: stage,
          child: BasicHudSurface(
            state: state,
            ports: _ports(),
            onAction: (String _) {},
            geometry: geometry,
            stage: stage,
          ),
        ),
      ),
    ),
  );
}

void main() {
  test('竖屏场景占上半屏（3D 与列表 1:1）', () {
    expect(
      basicSceneStageRect(portrait: true, width: 1080, height: 1920),
      const Rect.fromLTWH(0, 0, 1080, 960),
    );
    expect(
      basicSceneStageRect(portrait: true, width: 1080, height: 900),
      const Rect.fromLTWH(0, 0, 1080, 450),
    );
  });

  test('横屏场景就是整个 stage（原 Qt 整窗 3D，不是左栏小窗）', () {
    // NATIVE-RECOVERY-132R：Qt 场景按整窗视口投影（Qt/src/Engine.cpp 的
    // resize → scene.resize(w / (h / 1080), 1080)），而 stage 权威尺寸是
    // 1728x1080（docs/flutter-migration/acceptance/landscape.md），与本机窗口同比例。
    // 之前只给导航列左侧 1131x984，宽高比 1.15 ≠ 1.6，归档被压扁、抽出的唱片被裁。
    expect(
      basicSceneStageRect(portrait: false, width: 1920, height: 1080),
      const Rect.fromLTWH(0, 0, 1920, 1080),
    );
  });

  test('退化尺寸不挂载场景', () {
    expect(
      basicSceneStageRect(portrait: true, width: 300, height: 1920),
      isNull,
    );
    // 横屏改成整窗后，方形窗口不再是"退化"；真正退化的是任一边不足 320。
    expect(
      basicSceneStageRect(portrait: false, width: 1080, height: 200),
      isNull,
    );
  });

  test('横屏 stage 矩形只经 rectToLogical 换算一次 scale', () {
    final StageGeometry geometry = StageGeometry(
      logicalWidth: 2560,
      logicalHeight: 1440,
    );
    final Rect stageRect = basicSceneStageRect(
      portrait: false,
      width: geometry.stageWidth,
      height: StageGeometry.baseHeight,
    )!;
    expect(stageRect, const Rect.fromLTWH(0, 0, 1920, 1080));
    final Rect logical = geometry.rectToLogical(stageRect);
    expect(logical.left, 0);
    expect(logical.top, 0);
    expect(logical.width, closeTo(1920 * 4 / 3, 1e-6));
    expect(logical.height, closeTo(1080 * 4 / 3, 1e-6));
  });

  test('Qt 场景视图类型就是注册到 Flutter 的那个 viewType', () {
    // 原生侧 QtSceneViewFactory（android/.../qt/QtSceneViewFactory.kt）注册的名字
    // 必须与这里一致，否则页面上只会拿到 "no factory registered"。
    expect(qtSceneViewType, 'rhine/qt_scene');
  });

  testWidgets('空曲库、无选中 id 时横屏仍挂载场景（不是静态图）', (WidgetTester tester) async {
    // widget 测试不创建真实 PlatformView：把 target platform 指到非 Android，走
    // QtSceneView 自己的可见说明分支（Android 真机上这块矩形是 Qt 的 QQuickView）。
    // 必须在测试体内 finally 复位：flutter_test 一离开 body 就检查 foundation debug
    // 变量，addTearDown 已经在检查之后，太晚。
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        _landscapeHarness(size: const Size(1920, 1080), state: _emptyLibrary()),
      );
      await tester.pump();
      expect(find.byType(QtSceneView), findsOneWidget);
      expect(tester.getSize(find.byType(QtSceneView)), const Size(1920, 1080));
      expect(find.text('3D 场景预览仅在 Android 可用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('竖屏首页同样挂载场景，尺寸是上半屏', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(MaterialApp(
        home: PortraitStage(
          child: BasicHudSurface(
            state: _emptyLibrary(),
            ports: _ports(),
            onAction: (String _) {},
          ),
        ),
      ));
      await tester.pump();
      expect(find.byType(QtSceneView), findsOneWidget);
      expect(tester.getSize(find.byType(QtSceneView)), const Size(1080, 960));
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // 退化尺寸（任一边 < 320）由上面的 basicSceneStageRect 单测直接覆盖：widget 级
  // harness 的 HudStage 高度恒为 1080 设计高，无法在横屏构造出退化 stage。
  // 这里改为断言"横屏方形窗口照样整窗挂载"，防止有人把整窗矩形又改回左栏小窗。
  testWidgets('横屏方形窗口仍按整窗挂载场景', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        _landscapeHarness(size: const Size(1080, 1080), state: _emptyLibrary()),
      );
      await tester.pump();
      expect(find.byType(QtSceneView), findsOneWidget);
      expect(tester.getSize(find.byType(QtSceneView)), const Size(1080, 1080));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
