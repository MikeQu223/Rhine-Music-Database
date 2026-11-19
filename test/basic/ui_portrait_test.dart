import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/input/hit_layer.dart';
import 'package:rhine_music_database/hud/portrait/portrait_layout.dart'
    show portraitListTop;
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/protocol/hud_frame.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/ui/layout/portrait_stage.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';

SirenSong _song(String id, String title) => SirenSong(
      id: id,
      title: title,
      artist: '塞壬唱片',
      album: '专辑',
      albumId: 'album-1',
      cover: '',
      sourceUrl: 'https://example.invalid/$id.mp3',
      lyricUrl: '',
      durationMs: 180000,
    );

BasicGlyphPorts _ports() {
  final GlyphFontSet fonts = GlyphFontSet.empty;
  final GlyphText text = GlyphText.resourceOnly(fonts);
  return BasicGlyphPorts(glyphs: fonts, text: text);
}

BasicViewState _library() => BasicViewState(
      phase: BasicPhase.library,
      songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首'), _song('s3', '第三首')],
      albums: <SirenAlbum>[
        SirenAlbum(id: 'album-1', name: '测试专辑', artist: '塞壬唱片', cover: '', songCount: 2, songs: <SirenSong>[_song('s1', '第一首')]),
      ],
      catalogLoaded: true,
      dark: true,
    );

HudHit _hit(BasicHudFrame frame, String action) =>
    frame.hits.firstWhere((HudHit hit) => hit.action == action);

void main() {
  group('portrait re-layout keeps one stage coordinate space', () {
    testWidgets('portrait archive page is a 393 grid: lane tabs, list band and 播放全部', (WidgetTester tester) async {
      // 竖屏排版在 147 之后换成了原 Qt compact 的 393 网格（lib/hud/portrait/），
      // 不再是「把横屏 1080 稿整块下移 1080」——旧断言随旧排版一起作废。
      final BasicHudFrame portrait = BasicHudFrame.build(
        state: _library(),
        ports: _ports(),
        width: 1080,
        height: 1920,
        portrait: true,
      );
      final double unit = 1080 / 393;
      final double gridHeight = 1920 / unit;
      final double listTop = portraitListTop(gridHeight);

      // 五个来源 tab 全部有命中（顺序由 basicSirenSourceOrder 决定，不是 0..4）。
      final Iterable<HudHit> lanes =
          portrait.hits.where((HudHit hit) => hit.action.startsWith('mobile:lane:'));
      expect(lanes.length, basicSirenColumns.length);

      // 当前行：position = 0（列表顶端）时占「第一槽」，槽位随 position 连续长到第二槽。
      // Qt 原始版式恒为 listTop + 48，顶端会把第一槽空着、一屏四行只剩三行
      // （用户 2026-11-18「只显示三个」）；这里把两种位置都钉住。
      final HudHit open = _hit(portrait, 'open');
      expect(open.y, closeTo(listTop * unit, 1.0));
      final BasicHudFrame scrolled = BasicHudFrame.build(
        state: _library(),
        ports: _ports(),
        width: 1080,
        height: 1920,
        portrait: true,
        listPosition: 1,
      );
      // 滚一级后当前行回到第二槽（Qt slotY = listTop + 48）：此时第 0 行仍在
      // 「上一行」位置并且同样发 'open'（archive.index 是 0），所以取 y 最大的那条。
      final List<HudHit> scrolledOpens = scrolled.hits
          .where((HudHit hit) => hit.action == 'open')
          .toList()
        ..sort((HudHit a, HudHit b) => a.y.compareTo(b.y));
      expect(scrolledOpens.last.y, closeTo((listTop + 48) * unit, 1.0));
      expect(open.width, closeTo(347 * unit, 1.0));

      // 「播放全部」与曲目行同一页，且整条命令流在 393 网格坐标系里（scale(unit)）。
      expect(portrait.hits.any((HudHit hit) => hit.action == 'music:play-loaded'), isTrue);
      final bool hasScale = portrait.commands.any((List<Object?> command) =>
          command.length >= 3 && command[0] == 'scale' && command[1] == unit);
      expect(hasScale, isTrue);
      expect(open.x + open.width, lessThanOrEqualTo(393 * unit + 1));
    });

    testWidgets('player bar stays below the list band in both orientations', (WidgetTester tester) async {
      final BasicGlyphPorts ports = _ports();
      final BasicHudFrame landscape = BasicHudFrame.build(
        state: _library(),
        ports: ports,
        width: 1920,
        height: 1080,
        portrait: false,
      );
      final BasicHudFrame portrait = BasicHudFrame.build(
        state: _library(),
        ports: ports,
        width: 1080,
        height: 1920,
        portrait: true,
      );
      // 横屏播放条仍钉在 stage 底部（height - playerBarRowHeight = 984）。
      expect(_hit(landscape, 'player:toggle').y, greaterThanOrEqualTo(984));
      // 竖屏是「列表带 → 迷你播放条 → 底栏」三段：播放条在列表下面，
      // 底栏又在播放条下面，且整块不出舞台。
      final double unit = 1080 / 393;
      final double gridHeight = 1920 / unit;
      final double listBottom = portraitListTop(gridHeight) + 48 * 4;
      final HudHit toggle = _hit(portrait, 'player:toggle');
      expect(toggle.y, greaterThanOrEqualTo(listBottom * unit));
      expect(_hit(portrait, 'open').y, lessThan(toggle.y));
      final HudHit nav =
          portrait.hits.firstWhere((HudHit hit) => hit.action == 'mobile:nav:archive');
      expect(nav.y, greaterThan(toggle.y));
      expect(nav.y + nav.height, lessThanOrEqualTo(1920 + 1));
    });

    testWidgets('PortraitStage injects stage geometry that the surface consumes', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 场景现在无条件挂载（含竖屏）：widget 测试不创建真实 PlatformView，
      // 走 QtSceneView 的非 Android 可见说明分支，避免依赖引擎视口。
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final List<String> actions = <String>[];
        await tester.pumpWidget(MaterialApp(
          home: PortraitStage(
            child: BasicHudSurface(state: _library(), ports: _ports(), onAction: actions.add),
          ),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
      } finally {
        // flutter_test 在跑 tearDown 之前就检查 foundation 调试点，所以必须在这里复位，
        // 不能靠 addTearDown（否则 "The value of a foundation debug variable was changed"）。
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('non-unit stage scale still routes portrait taps to HUD hits', (WidgetTester tester) async {
      // 432 宽 -> stageScale = 0.4。92 把 Transform.scale 内的舞台坐标直接交给
      // HitLayer（它按窗口逻辑坐标再除一次 scale），竖屏命中整体放大约 2.5 倍，
      // 落在空白处 -> 点击无反应。这里用真实 PortraitStage 复现并锁定修复。
      tester.view.physicalSize = const Size(432, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final List<String> actions = <String>[];
        await tester.pumpWidget(MaterialApp(
          home: PortraitStage(
            child: BasicHudSurface(state: _library(), ports: _ports(), onAction: actions.add),
          ),
        ));
        await tester.pump();
        await _assertNonUnitScaleTap(tester, actions);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

Future<void> _assertNonUnitScaleTap(WidgetTester tester, List<String> actions) async {
      final BuildContext surfaceContext = tester.element(find.byType(BasicHudSurface));
      final StageGeometry geometry = StageGeometryScope.of(surfaceContext);
      final HudStage stage = HudStageScope.of(surfaceContext);
      expect(geometry.stageScale, closeTo(0.4, 1e-9));

      final BasicHudFrame frame = BasicHudFrame.build(
        state: _library(),
        ports: _ports(),
        width: stage.width,
        height: stage.height,
        portrait: true,
      );
      final HudHit toggle = _hit(frame, 'player:toggle');
      final Offset logicalCenter = geometry.toLogical(
        Offset(toggle.x + toggle.width / 2, toggle.y + toggle.height / 2),
      );
      await tester.tapAt(logicalCenter);
      await tester.pump();
      expect(actions, contains('player:toggle'));
      expect(actions, isNot(contains('open')));
}
