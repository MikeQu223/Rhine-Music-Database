import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/input/hit_layer.dart';
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
    testWidgets('track list hits shift by exactly one 1080 design height', (WidgetTester tester) async {
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
      final HudHit landscapeOpen = _hit(landscape, 'open');
      final HudHit portraitOpen = _hit(portrait, 'open');
      expect(portraitOpen.x, landscapeOpen.x);
      expect(portraitOpen.width, landscapeOpen.width);
      expect(portraitOpen.y - landscapeOpen.y, basicPortraitListOffset);
      expect(portraitOpen.action, landscapeOpen.action);
      // 竖屏命令流确实用 save/translate/restore 承载同一次平移。
      final bool hasShift = portrait.commands.any((List<Object?> command) =>
          command.length >= 3 && command[0] == 'translate' && command[1] == 0 && command[2] == basicPortraitListOffset);
      expect(hasShift, isTrue);
    });

    testWidgets('player bar stays pinned to the bottom in both orientations', (WidgetTester tester) async {
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
      expect(_hit(landscape, 'player:toggle').y, greaterThanOrEqualTo(984));
      expect(_hit(portrait, 'player:toggle').y, greaterThanOrEqualTo(1824));
      // 列表行不会盖到播放条上（竖屏平移量小于 stage 高度 - 播放条）。
      expect(_hit(portrait, 'open').y, lessThan(_hit(portrait, 'player:toggle').y));
    });

    testWidgets('PortraitStage injects stage geometry that the surface consumes', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 场景现在无条件挂载（含竖屏）：widget 测试不创建真实 PlatformView，
      // 走 QtSceneView 的非 Android 可见说明分支，避免依赖引擎视口。
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final List<String> actions = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: PortraitStage(
          child: BasicHudSurface(state: _library(), ports: _ports(), onAction: actions.add),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
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
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final List<String> actions = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: PortraitStage(
          child: BasicHudSurface(state: _library(), ports: _ports(), onAction: actions.add),
        ),
      ));
      await tester.pump();

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
    });
  });
}
