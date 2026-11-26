// 列表拖动松手惯性：抬手后按 Qt 的一维 archive 动量继续滑行，最后吸到整行。
//
// 钉住：抬手后多帧推进且方向一致、停稳才提交且只提交一次、提交值等于最后连续位置、
// 停稳后不再发值。move 的 timeStamp 必须显式给，否则采不到速度。

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

/// 行足够多：惯性要能越过拖动落点还留在范围内（夹边会把惯性和 clamp 混淆）。
const int _rowCount = 40;

BasicViewState _library() => BasicViewState(
      phase: BasicPhase.library,
      songs: <SirenSong>[for (int i = 0; i < _rowCount; i++) _song(i)],
      catalogLoaded: true,
      dark: true,
    );

void main() {
  testWidgets('快速上滑松手后继续滑行多帧，停稳只提交一次吸附行', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<double> updates = <double>[];
    final List<double> commits = <double>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BasicHudSurface(
          state: _library(),
          ports: _ports(),
          onAction: (String _) {},
          onLibraryScrollUpdate: updates.add,
          onLibraryScroll: commits.add,
          geometry: const StageGeometry(logicalWidth: 1920, logicalHeight: 1080),
          stage: const HudStage(scale: 1, width: 1920, height: 1080),
        ),
      ),
    ));
    await tester.pump();

    final Rect list = basicLibraryListStageRect(portrait: false, width: 1920);
    final Offset start = Offset(list.center.dx, list.top + 400);

    // 每 32ms 上移 20 舞台像素 ≈ 7.1 行/秒，是一次普通快滑，足够采样速度。
    Duration stamp = const Duration(milliseconds: 32);
    final TestGesture gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 32));
    for (var i = 0; i < 5; i++) {
      stamp += const Duration(milliseconds: 32);
      await gesture.moveBy(const Offset(0, -20), timeStamp: stamp);
      await tester.pump(const Duration(milliseconds: 32));
    }
    expect(commits, isEmpty, reason: '抬手前不能提交落点');
    final double draggedTo = updates.last;
    expect(draggedTo, greaterThan(0), reason: '拖动本身必须先改变窗口');

    stamp += const Duration(milliseconds: 32);
    await gesture.up(timeStamp: stamp);
    await tester.pump();

    // 抬手后：动量必须继续推进多帧（抬手即停就是本缺陷）。
    final int beforeFling = updates.length;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(commits, isEmpty,
        reason: '滑行/吸行途中不能提交：落行要等运动停稳');
    expect(updates.length, greaterThan(beforeFling + 3),
        reason: '松手后必须继续多帧发连续位置（惯性）；抬手即停 = 33→34 后不动');
    expect(updates.last, greaterThan(draggedTo),
        reason: '惯性方向与拖动同向（继续朝更大的条目号）');

    // 跑到自己停稳：最多 600 帧（约 9.6s 帧时钟），必须停下并只提交一次。
    for (var i = 0; i < 600 && commits.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(commits, hasLength(1), reason: '停稳只提交一次');
    final double snapped = commits.single;
    expect(snapped, closeTo(snapped.roundToDouble(), 1e-6),
        reason: '提交的是吸附行（整行位置），不是手指离开时的小数位置');
    expect(updates.last, closeTo(snapped, 1e-3),
        reason: '最后一次连续位置就是吸附行（列表与 3D 不跳变）');
    expect(snapped, greaterThan(draggedTo),
        reason: '惯性必须真的把窗口带过拖动落点');

    // 停稳后不得再动：ticker 必须停，pumpAndSettle 能收敛。
    final int settled = updates.length;
    await tester.pumpAndSettle(
      const Duration(milliseconds: 16),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(updates.length, settled, reason: '停稳后不能再发连续位置（ticker 必须停）');
    expect(commits, hasLength(1), reason: '停稳后不得重复提交');
  });
}
