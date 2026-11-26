// 竖屏播放队列页的可滚动性。
//
// 钉住三件事：页面把用上的滚动量与上界回存给宿主、上界随内容长、
// 竖屏拖动按画布网格推进且松手后走同一套惯性。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/portrait/portrait_canvas.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_queue.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';
import 'package:rhine_music_database/ui/layout/portrait_stage.dart';

SirenSong _song(int index) => SirenSong(
      id: 'q$index',
      title: '队列第 $index 首',
      artist: '塞壬唱片',
      album: '专辑',
      albumId: 'album-1',
      cover: '',
      sourceUrl: 'https://example.invalid/q$index.mp3',
      lyricUrl: '',
      durationMs: 180000,
    );

BasicGlyphPorts _ports() {
  final GlyphFontSet fonts = GlyphFontSet.empty;
  final GlyphText text = GlyphText.resourceOnly(fonts);
  return BasicGlyphPorts(glyphs: fonts, text: text);
}

/// 队列里 n 首（舞台/领域两侧都放同一批，`_portraitQueueRows` 读 state.queue）。
BasicViewState _queue(int count) => BasicViewState(
      phase: BasicPhase.library,
      songs: <SirenSong>[for (int i = 0; i < 40; i++) _song(i)],
      catalogLoaded: true,
      dark: true,
      selectedLane: 1,
      queue: <SirenSong>[for (int i = 0; i < count; i++) _song(i)],
      queueIndex: 0,
      queueMode: 'all',
    );

PortraitCanvas _canvas({double gridWidth = 393, double height = 862}) =>
    PortraitCanvas(
      metrics: PortraitMetrics(
        width: (String value, double size, String weight) => value.length * size * .6,
        wrap: (String value, double limit, double size, String weight) => <String>[value],
        bounds: (String value, double size, String weight) =>
            PortraitGlyphBounds(width: value.length * size * .6, height: size),
      ),
      unit: 1,
      gridWidth: gridWidth,
      height: height,
      dark: true,
    );

List<PortraitQueueRow> _rows(int count) => <PortraitQueueRow>[
      for (int i = 0; i < count; i++)
        (title: '队列第 $i 首', artist: '塞壬唱片', stamp: '03:00', image: ''),
    ];

void main() {
  group('页面自报滚动真值（Qt m_scroll / m_maximum）', () {
    test('onLayout 回存实际用上的滚动量与 Qt 口径上界', () {
      double resolved = -1;
      double maximum = -1;
      _canvas().let((PortraitCanvas c) {
        c.contentBottom = c.height - 144;
        final double end = paintPortraitQueuePage(
          c,
          title: '在播曲',
          artist: '塞壬唱片',
          tracks: _rows(40),
          currentIndex: 7,
          mode: 'all',
          modesExpanded: false,
          scroll: null,
          onLayout: (double r, double m) {
            resolved = r;
            maximum = m;
          },
        );
        expect(end, greaterThan(0));
        expect(maximum, closeTo(end - c.contentBottom, 1e-6),
            reason: '上界就是 Qt 的 max(0, end - c.contentBottom)');
      });
      // currentIndex=7 且没给 scroll ⇒ Qt newScope 规则「当前行置顶」。
      expect(resolved, greaterThan(0), reason: '当前行 7 必须把内容上移');
      expect(maximum, greaterThan(resolved),
          reason: '40 首的上界必须大于「当前行置顶」的滚动量，否则最后几首永远拖不出来');
    });

    test('内容越长上界越大，且给出 scroll 时不改变上界', () {
      double shortMax = -1;
      double longMax = -1;
      for (final int count in <int>[3, 40]) {
        _canvas().let((PortraitCanvas c) {
          c.contentBottom = c.height - 144;
          paintPortraitQueuePage(
            c,
            title: '在播曲',
            artist: '塞壬唱片',
            tracks: _rows(count),
            currentIndex: 0,
            mode: 'all',
            modesExpanded: false,
            scroll: 0,
            onLayout: (double r, double m) {
              if (count == 3) {
                shortMax = m;
              } else {
                longMax = m;
              }
            },
          );
        });
      }
      expect(shortMax, greaterThanOrEqualTo(0));
      expect(longMax, greaterThan(shortMax), reason: '40 首要显著比 3 首可滚');
    });
  });

  testWidgets('竖屏队列页拖动按画布网格推进，松手后仍有惯性', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<double> scrolls = <double>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        // 竖屏必须挂在 PortraitStage 下（`StageGeometryScope.of` 由它提供）。
        body: PortraitStage(
          child: BasicHudSurface(
            state: _queue(40),
            ports: _ports(),
            onAction: (String _) {},
            modal: 'queue',
            onQueueScrollChanged: scrolls.add,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );

    // 拖动起点必须落在手势域内：竖屏队列页的可拖区来自
    // `modalShellBounds(playerModal, stageWidth: 1080)` 的 (50,122,980,836) 再往下
    // 340（页头/当前歌曲卡/模式区不参与拖动）⇒ stage 单位 (50,462,980,596)。
    // 本层逻辑坐标与 stage 同比例（PortraitStage 只做 DPI 缩放），取该矩形中部。
    final TestGesture gesture = await tester.startGesture(const Offset(540, 760));
    await tester.pump(const Duration(milliseconds: 32));
    Duration stamp = const Duration(milliseconds: 32);
    for (var i = 0; i < 6; i++) {
      stamp += const Duration(milliseconds: 32);
      await gesture.moveBy(const Offset(0, -40), timeStamp: stamp);
      await tester.pump(const Duration(milliseconds: 32));
    }
    expect(scrolls, isNotEmpty, reason: '竖屏队列拖动必须回写滚动量（修复前这段被丢弃）');
    final double draggedTo = scrolls.last;
    expect(draggedTo, greaterThan(0), reason: '上滑 = 内容上移 = 滚动量增大');

    stamp += const Duration(milliseconds: 32);
    await gesture.up(timeStamp: stamp);
    await tester.pump();

    final int beforeFling = scrolls.length;
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scrolls.length, greaterThan(beforeFling + 3),
        reason: '松手后要继续多帧发滚动量（与其它弹层页同一套惯性）');
    expect(scrolls.last, greaterThan(draggedTo));
    expect(scrolls.last.isFinite, isTrue);
  });
}

extension<T> on T {
  void let(void Function(T value) block) => block(this);
}
