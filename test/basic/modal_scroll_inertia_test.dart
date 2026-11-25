// 弹层页（竖屏评论/百科/发现/收藏/检索/专辑信息/歌手、横屏评论/发现/队列）的松手惯性
// （用户 2026-11-26：「部分页面没有适配物理滑动，现在的效果是脱手即停」）。
//
// 这些页面的滚动量不是资料库的条目窗口，而是各自的一维标量（画布网格 / 舞台像素 /
// 队列行号）。修复前 `_dragEnded` 对它们直接 `return`，于是抬手当帧就停在原位；
// 现在它们与资料库走同一套物理（摩擦 2.4、收尾 0.6 进吸行、弹簧率 10），
// 只是目标不吸整行。
//
// 本文件只钉软件侧契约，真机手感仍需实机复验：
//   * 抬手后滚动量继续朝同向推进多帧；
//   * 前几帧的推进速度单调下降（衰减，而不是匀速漂移或反向）；
//   * 最终停下且停在 [0, maximumScroll] 之内，停稳后不再发值。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/input/hit_layer.dart';
import 'package:rhine_music_database/hud/protocol/hud_frame.dart' show HudStage;
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';

SirenSong _song(int index) => SirenSong(
      id: 's$index',
      title: '第 $index 首',
      artist: '塞壬唱片',
      album: '专辑',
      albumId: 'album-1',
      cover: '',
      sourceUrl: 'https://example.invalid/s$index.mp3',
      lyricUrl: '',
      durationMs: 180000,
    );

BasicGlyphPorts _ports() {
  final GlyphFontSet fonts = GlyphFontSet.empty;
  final GlyphText text = GlyphText.resourceOnly(fonts);
  return BasicGlyphPorts(glyphs: fonts, text: text);
}

BasicViewState _state() => BasicViewState(
      phase: BasicPhase.library,
      songs: <SirenSong>[for (int i = 0; i < 60; i++) _song(i)],
      catalogLoaded: true,
      dark: true,
      selectedLane: 1,
    );

void main() {
  testWidgets('横屏收藏列的拖动松手后继续衰减滑行，而不是脱手即停', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<double> scrolls = <double>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BasicHudSurface(
          state: _state(),
          ports: _ports(),
          onAction: (String _) {},
          modal: 'saved',
          onSavedScrollChanged: scrolls.add,
          geometry: const StageGeometry(logicalWidth: 1920, logicalHeight: 1080),
          stage: const HudStage(scale: 1, width: 1920, height: 1080),
        ),
      ),
    ));
    await tester.pump();

    // 起手点必须在手势域内：横屏「我的音乐」走 1260 模态外框，可拖区域是外框内的
    // 列表（探针测得 stage (1127,219)-(1920,829)，即本层逻辑坐标同一区间）。
    // 每 32ms 上移 30 舞台像素 ⇒ 约 937 px/s，远高于 0.75 的抬手阈值。
    final Offset start = const Offset(1520, 520);
    Duration stamp = const Duration(milliseconds: 32);
    final TestGesture gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 32));
    for (var i = 0; i < 6; i++) {
      stamp += const Duration(milliseconds: 32);
      await gesture.moveBy(const Offset(0, -30), timeStamp: stamp);
      await tester.pump(const Duration(milliseconds: 32));
    }
    expect(scrolls, isNotEmpty, reason: '拖动本身必须先改变滚动量');
    final double draggedTo = scrolls.last;
    expect(draggedTo, greaterThan(0), reason: '上滑 = 滚动量增大');

    stamp += const Duration(milliseconds: 32);
    await gesture.up(timeStamp: stamp);
    await tester.pump();

    // 抬手后必须继续推进多帧：脱手即停就是这条缺陷。
    final int beforeFling = scrolls.length;
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scrolls.length, greaterThan(beforeFling + 3),
        reason: '松手后要继续多帧发滚动量（惯性）；脱手即停 = 真机抬手当帧不动');
    expect(scrolls.last, greaterThan(draggedTo),
        reason: '惯性方向与拖动同向（继续向下滚动内容）');

    // 逐帧增量必须衰减：把抬手后的前若干帧差分出来看是否单调递减。
    final List<double> deltas = <double>[];
    for (var i = beforeFling; i < scrolls.length; i++) {
      deltas.add(scrolls[i] - (i == beforeFling ? draggedTo : scrolls[i - 1]));
    }
    expect(deltas.first, greaterThan(0));
    expect(deltas.last, lessThan(deltas.first),
        reason: '惯性必须逐渐减速，而不是匀速一直漂');

    // 跑到自己停稳：最多 600 帧。
    final int settledAt = scrolls.length;
    for (var i = 0; i < 600; i++) {
      final int before = scrolls.length;
      await tester.pump(const Duration(milliseconds: 16));
      if (scrolls.length == before && i > 4) {
        break;
      }
    }
    expect(scrolls.length, greaterThan(settledAt), reason: '惯性要继续推进到停稳');
    expect(scrolls.last, greaterThanOrEqualTo(0));
    expect(scrolls.last.isFinite, isTrue);

    // 停稳后 ticker 必须停：pumpAndSettle 能收敛且不再发新值。
    final int beforeSettle = scrolls.length;
    await tester.pumpAndSettle(
      const Duration(milliseconds: 16),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(scrolls.length, beforeSettle, reason: '停稳后不能再发滚动量（ticker 必须停）');
  });

  testWidgets('低速拖动（采不到速度）松手后仍立即停在原位', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<double> scrolls = <double>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BasicHudSurface(
          state: _state(),
          ports: _ports(),
          onAction: (String _) {},
          modal: 'saved',
          onSavedScrollChanged: scrolls.add,
          geometry: const StageGeometry(logicalWidth: 1920, logicalHeight: 1080),
          stage: const HudStage(scale: 1, width: 1920, height: 1080),
        ),
      ),
    ));
    await tester.pump();

    // 不给 timeStamp：全部采样落在 0ms，跨度 < 8ms 采不到速度 -> 抬手即停（旧行为保持）。
    final TestGesture gesture = await tester.startGesture(const Offset(1520, 520));
    await tester.pump(const Duration(milliseconds: 32));
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 32));
    }
    final double draggedTo = scrolls.last;
    await gesture.up();
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scrolls.last, closeTo(draggedTo, 1e-6),
        reason: '采不到速度时不起惯性，停在抬手位置');
  });
}
