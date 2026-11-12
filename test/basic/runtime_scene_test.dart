import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/scene_preview.dart';
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
  test('竖屏场景占满顶部 1080 设计高度（曲目列以下留白之前）', () {
    expect(
      basicSceneStageRect(portrait: true, width: 1080, height: 1920),
      const Rect.fromLTWH(0, 0, 1080, 1080),
    );
    expect(
      basicSceneStageRect(portrait: true, width: 1080, height: 900),
      const Rect.fromLTWH(0, 0, 1080, 900),
    );
  });

  test('横屏场景与 Qt 左侧 3D 容器同矩形（导航列左侧、播放条以上）', () {
    expect(
      basicSceneStageRect(portrait: false, width: 1920, height: 1080),
      const Rect.fromLTWH(0, 0, 1131, 984),
    );
  });

  test('退化尺寸不挂载场景', () {
    expect(
      basicSceneStageRect(portrait: true, width: 300, height: 1920),
      isNull,
    );
    expect(
      basicSceneStageRect(portrait: false, width: 1080, height: 1080),
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
    expect(stageRect, const Rect.fromLTWH(0, 0, 1131, 984));
    final Rect logical = geometry.rectToLogical(stageRect);
    expect(logical.left, 0);
    expect(logical.top, 0);
    expect(logical.width, closeTo(1131 * 4 / 3, 1e-6));
    expect(logical.height, closeTo(984 * 4 / 3, 1e-6));
  });

  testWidgets('空曲库、无选中 id 时横屏仍挂载真实场景（不是静态图）', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(
      _landscapeHarness(size: const Size(1920, 1080), state: _emptyLibrary()),
    );
    await tester.pump();
    expect(find.byType(ScenePreview), findsOneWidget);
    expect(tester.getSize(find.byType(ScenePreview)), const Size(1131, 984));
    // 非 Android 走 ScenePreview 自己的可见说明；Android 上这里是真实 WebView。
    expect(find.text('3D 场景预览仅在 Android 可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('竖屏首页同样挂载场景，尺寸正好 1080 设计高度', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
    expect(find.byType(ScenePreview), findsOneWidget);
    expect(tester.getSize(find.byType(ScenePreview)), const Size(1080, 1080));
    expect(tester.takeException(), isNull);
  });

  testWidgets('阶段退化时宁可不挂载，也不伪造 3D', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(
      _landscapeHarness(size: const Size(1080, 1080), state: _emptyLibrary()),
    );
    await tester.pump();
    expect(find.byType(ScenePreview), findsNothing);
  });
}
