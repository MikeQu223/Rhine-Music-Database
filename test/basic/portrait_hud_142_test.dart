// HUD-SYNC-TEXT-142 · 列表 <-> 3D 双向连续跟随（HUD 侧接线回归）。
//
// 约定接口（与 FINAL-INTEGRATION-141 一致）：
//   BasicHudSurface 新增 OPTIONAL `ValueChanged<double>? onLibraryScrollUpdate`，
//   列表拖动期间每次 move 都发**连续条目位置**（可含小数）；抬手仍只走旧
//   `onLibraryScroll`（commit-on-end）。141 负责 BasicApp/controller/native 接线，
//   本文件只证明 HUD 这一侧真的在抬手前多次回调、且外部 state.listPosition 在
//   非拖动状态不被 _dragPosition 遮住。
//
// 只写不跑：tests/analyze/build/ADB 的唯一执行者是 FINAL-INTEGRATION-141。
// 141 仍须设备验证：真机列表拖动时 3D 层连续跟手、抬手不跳变，横竖屏各一次。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/input/hit_layer.dart';
import 'package:rhine_music_database/hud/protocol/hud_command.dart' show HudCommand, HudText, decodeHudCommands;
import 'package:rhine_music_database/hud/protocol/hud_frame.dart' show HudStage;
import 'package:rhine_music_database/hud/render/hud_painter.dart' show HudStagePainter;
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';
import 'package:rhine_music_database/ui/layout/portrait_bands.dart';
import 'package:rhine_music_database/ui/layout/portrait_stage.dart';

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

BasicViewState _library({double? listPosition}) => BasicViewState(
      phase: BasicPhase.library,
      songs: <SirenSong>[
        _song('s1', '第一首'),
        _song('s2', '第二首'),
        _song('s3', '第三首'),
        _song('s4', '第四首'),
        _song('s5', '第五首'),
      ],
      catalogLoaded: true,
      dark: true,
      listPosition: listPosition,
    );

/// 列表带右侧（landscape x>1100, y 219..829）的行 text 指纹：value@y。
///
/// 只取 ruler 行文字：滚动标题在列表带左侧（x<1100），不会被动画命令形状污染；
/// 同一 state 下的行位置只由滚动窗口决定，窗口不同则指纹必然不同。
List<String> _listBandRows(List<HudCommand> commands) => <String>[
      for (final HudCommand command in commands)
        if (command is HudText &&
            command.x > 1100 &&
            command.y > 219 &&
            command.y < 829)
          '${command.value}@${command.y}',
    ];

void main() {
  testWidgets('横屏列表拖动：抬手前连续发 ENTRY 位置，抬手才提交 onLibraryScroll',
      (WidgetTester tester) async {
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
    expect(list.left, greaterThan(0));
    final Offset start = Offset(list.center.dx, list.top + 120);

    final TestGesture gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 16));
    }

    // 抬手前必须已多次回调（start 一次 + 每次 move 一次），且是连续条目位置。
    expect(updates.length, greaterThanOrEqualTo(3),
        reason: '连续跟随要求拖动期间回调，而不是只在抬手时给一次');
    expect(commits, isEmpty, reason: '抬手前不能提交落点');
    expect(updates.first, closeTo(0, 1e-9), reason: '起点 = 当前窗口（选中项 0）');
    for (var i = 1; i < updates.length; i++) {
      expect(updates[i], greaterThanOrEqualTo(updates[i - 1]),
          reason: '手指向上 = 窗口朝更大的条目号连续推进');
      expect(updates[i], inInclusiveRange(0, 4));
    }
    expect(updates.last, greaterThan(updates.first), reason: '拖动必须真的改变窗口');

    await gesture.up();
    await tester.pump();
    expect(commits, hasLength(1), reason: '抬手只提交一次');
    expect(commits.single, closeTo(updates.last, 1e-9),
        reason: '提交落点必须等于最后一次连续位置（3D 与列表不跳变）');
  });

  testWidgets('抬手后外部 state.listPosition 生效：下一次拖动从新值起手（_dragPosition 不残留）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<double> updates = <double>[];
    final BasicGlyphPorts ports = _ports();
    late StateSetter rebuild;
    BasicViewState state = _library();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (BuildContext context, StateSetter setState) {
          rebuild = setState;
          return BasicHudSurface(
            state: state,
            ports: ports,
            onAction: (String _) {},
            onLibraryScrollUpdate: updates.add,
            onLibraryScroll: (double _) {},
            geometry: const StageGeometry(logicalWidth: 1920, logicalHeight: 1080),
            stage: const HudStage(scale: 1, width: 1920, height: 1080),
          );
        }),
      ),
    ));
    await tester.pump();

    final Rect list = basicLibraryListStageRect(portrait: false, width: 1920);
    final Offset start = Offset(list.center.dx, list.top + 120);

    // 先真的拖一次再抬手：只有 _dragEnded 清掉 _dragPosition，下面外部值才可能生效；
    // 若清理丢失，残留的拖动窗口会遮住外部 listPosition，本用例必须红。
    TestGesture gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 16));
    expect(updates, isNotEmpty, reason: '拖动期间必须有连续位置');
    await gesture.up();
    await tester.pump();
    updates.clear();

    // 模拟宿主把 3D 层的连续位置投影回 state（141 的 controller.listPosition）。
    rebuild(() => state = _library(listPosition: 3.0));
    await tester.pump();

    gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 16));

    expect(updates, isNotEmpty);
    expect(updates.first, closeTo(3.0, 1e-9),
        reason: '外部 listPosition 必须是非拖动状态的窗口；残留 _dragPosition 会遮住它');

    // 但回调只看 _windowOf，真正会露馅的是"非拖动帧画了哪个窗口"：把屏上
    // 列表带的 text 与同一 state/listPosition=3.0 的参考帧逐条比对，残留
    // _dragPosition（例如 0.68）会画出不同的行/基线 → 红。
    await gesture.up();
    await tester.pump();
    // 显式重建一次并等滚动动画收敛：读到的既是"非拖动帧"（_dragPosition 已清空），
    // 也是静态命令形状（滚动标签收敛为单条 text），与参考帧可直接逐条比对。
    rebuild(() {});
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    final HudStagePainter painted = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((CustomPaint p) => p.painter)
        .whereType<HudStagePainter>()
        .single;
    final BasicHudFrame reference = BasicHudFrame.build(
      state: state,
      ports: ports,
      width: 1920,
      height: 1080,
      portrait: false,
      listPosition: 3.0,
    );
    expect(
      _listBandRows(painted.envelope.commands.commands),
      _listBandRows(decodeHudCommands(reference.commands).commands),
      reason: '非拖动帧必须按外部 listPosition=3.0 绘制列表',
    );
  });

  testWidgets('竖屏 PortraitStage：同一 scale 下连续回调，动画自然收敛（ticker 不空转）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<double> updates = <double>[];
    final List<double> commits = <double>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PortraitStage(
          child: BasicHudSurface(
            state: _library(),
            ports: _ports(),
            onAction: (String _) {},
            onLibraryScrollUpdate: updates.add,
            onLibraryScroll: commits.add,
          ),
        ),
      ),
    ));

    // 初始帧的滚动动画必须自己走到终态并停 ticker：不停就是 pumpAndSettle 超时（红）。
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );

    // 命中带用同一处真值算（DPI 适配后 1 网格 = 1.3dp，带顶不再固定在网上）：
    // 直接取 basicLibraryListStageRect 的中心，避免测试自己拍一套 1080/393 的旧坐标。
    final Rect band = basicLibraryListStageRect(
      portrait: true,
      width: 1080,
      height: 1920,
      stageScale: 1,
    );
    final TestGesture gesture = await tester.startGesture(band.center);
    await tester.pump(const Duration(milliseconds: 16));
    // 第一次 move 会被 VerticalDragGestureRecognizer 的 touch slop（18px）吃掉，
    // 不产生 onUpdate（interaction_133_native_test.dart:547-554 有同源说明）；
    // 因此发三次 move：start + 两次有效 update = 3 次连续位置。
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(updates.length, greaterThanOrEqualTo(3));
    expect(commits, isEmpty);
    expect(updates.first, closeTo(0, 1e-9));
    expect(updates.last, greaterThan(updates.first));
    expect(updates.last, inInclusiveRange(0, 4));

    await gesture.up();
    await tester.pump();
    expect(commits, hasLength(1));
    expect(commits.single, closeTo(updates.last, 1e-9));
  });

  testWidgets('D7：720 逻辑宽仍是 1080 舞台 + 唯一 scale，列表命中不被 720-789<0 误判',
      (WidgetTester tester) async {
    // 真机 LOGICAL 宽 720，舞台恒 1080（portraitStageWidthConstant）。列表 x 在
    // **舞台**坐标是 navigationLeft(1080)-4 = 287 ≥ 0；用 720 去减 789 得到负数
    // 是混用坐标系，不是布局缺陷。这里用真实 PortraitStage 走一次 720 窗口。
    expect(portraitStageWidthConstant, 1080);
    expect(basicLibraryListStageRect(portrait: true, width: 1080).left, 287);

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<double> updates = <double>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PortraitStage(
          child: BasicHudSurface(
            state: _library(),
            ports: _ports(),
            onAction: (String _) {},
            onLibraryScrollUpdate: updates.add,
            onLibraryScroll: (double _) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );

    // stageScale = 720/1080 = 0.6667：屏幕 (600,933) → 舞台 (900,1400)，落在列表内。
    final TestGesture gesture = await tester.startGesture(const Offset(600, 933));
    await tester.pump(const Duration(milliseconds: 16));
    // 与其它拖动用例同规则：第一次 move 被 touch slop 吃掉（只 _checkStart），
    // 所以发两次 move 才有 start + 1 次有效 update = 2 次连续位置。
    for (var i = 0; i < 2; i++) {
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(updates.length, greaterThanOrEqualTo(2),
        reason: '窗口缩放后列表仍必须收到拖动（命中与绘制共用同一 scale）');
    expect(updates.last, inInclusiveRange(0, 4));
    await gesture.up();
    await tester.pump();
  });
}
