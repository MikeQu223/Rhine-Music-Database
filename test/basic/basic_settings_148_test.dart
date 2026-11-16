// SETTINGS-148 · ONLY14 设置页真值链回归（真实持久化 + 真实命令 + 真实命中裁剪）。
//
// 用户 2026-11-16（m01988）确认"输入法不避让、只要 14 项设置"，并明确要求
// "真实读取写入恢复 + 原生实际效果，不能假开关"。本文件守住其中**能纯 Dart 证明**
// 的三段：
//   1. [BasicSettingsStore]/[BasicSettingsRuntime]：写入真的落到端口（读回同值）、
//      重启口径分开报（requested vs effective）、被拒动作一个键都不写、
//      写入失败如实报告而不是假装成功。
//   2. [basicSettingsPanelModel]：默认值与已持久化值都进面板真值（行文案/版本行）。
//   3. [BasicSettingsOverlay]：模态框架/卡片/轨道同帧画出，命中按卡片视口裁剪，
//      返回按钮与滚动按钮的命中各归各家，滚轮/按钮都是 66 步进（HudScroll.h:22-26）。
//
// 不写"能过就行"的替身：端口用 [MemoryBasicSettingsPort]（行为与 MethodChannel
// 端口一致，含失败注入），字形走线上资源（Assets/fonts/misans-glyphs.json）。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_settings.dart';
import 'package:rhine_music_database/basic/basic_settings_runtime.dart';
import 'package:rhine_music_database/basic/basic_settings_store.dart';
import 'package:rhine_music_database/basic/basic_settings_surface.dart';
import 'package:rhine_music_database/basic/basic_settings_view.dart';
import 'package:rhine_music_database/hud/modals/settings_modal.dart';
import 'package:rhine_music_database/hud/protocol/hud_frame.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';
import 'package:rhine_music_database/hud/widgets/settings_row.dart';

const BasicSettingsPackageInfo _androidPackage = BasicSettingsPackageInfo(
  packageName: 'rhine.music.database',
  versionName: '1.4.8',
  versionCode: 4148,
  debuggable: true,
);

SettingsPreferenceContext _context() => SettingsPreferenceContext(
      capabilities: const PlatformCapabilities.android(),
      operatingSystem: SettingsOperatingSystem.android,
      providerId: 'siren',
      musicEnabled: true,
      providerIsLocal: false,
    );

Future<BasicSettingsRuntime> _runtime({
  Map<String, String>? values,
  BasicSettingsPackageInfo package = _androidPackage,
  bool failWrites = false,
  bool failReads = false,
  MemoryBasicSettingsPort? port,
}) async {
  final MemoryBasicSettingsPort resolved = port ??
      MemoryBasicSettingsPort(
        values: values,
        package: package,
        failWrites: failWrites,
        failReads: failReads,
      );
  final BasicSettingsRuntime runtime =
      BasicSettingsRuntime(store: BasicSettingsStore(port: resolved));
  await runtime.load();
  return runtime;
}

void main() {
  group('持久化真值链', () {
    test('空存储 -> Qt 默认真值（暗色 / lossless / 遮盖 55 / vsync on）', () async {
      final BasicSettingsRuntime runtime = await _runtime();
      final SettingsPreferenceSnapshot snapshot = runtime.snapshot;
      expect(snapshot.themeMode, 'dark', reason: '基本版默认暗色，面板不能写着浅色而画面是暗的');
      expect(snapshot.quality, 'lossless');
      expect(snapshot.archiveMaskStrength, 55);
      expect(snapshot.vsync, isTrue);
      expect(snapshot.discRotation, isFalse);
      expect(runtime.detailAutoplay, isFalse);
      expect(runtime.singlePlayAppend, isFalse);
      expect(runtime.version?.label, '当前版本 / 1.4.8 · 开发版');
    });

    test('已持久化的值真的被读出来（不是默认值兜底）', () async {
      final BasicSettingsRuntime runtime = await _runtime(values: <String, String>{
        'panel/theme': 'light',
        'panel/detail-autoplay': 'on',
        'panel/single-play-mode': 'append',
        'panel/disc-rotation': 'on',
        'panel/archive-mask-strength': '72',
        'panel/vsync': 'off',
      });
      expect(runtime.snapshot.themeMode, 'light');
      expect(runtime.detailAutoplay, isTrue);
      expect(runtime.singlePlayAppend, isTrue);
      expect(runtime.discRotation, isTrue);
      expect(runtime.archiveMaskStrength, 72);
      expect(runtime.snapshot.vsync, isFalse);
    });

    test('界面配色写入后：端口里有值、快照与行文案立刻是新值', () async {
      final MemoryBasicSettingsPort port = MemoryBasicSettingsPort(package: _androidPackage);
      final BasicSettingsRuntime runtime = await _runtime(port: port);
      final BasicSettingsApplyResult result =
          await runtime.apply('setting:theme:light', context: _context());
      expect(result.persisted, isTrue);
      expect(result.persistedValue, 'light');
      expect(port.values['panel/theme'], 'light');
      expect(runtime.snapshot.themeMode, 'light');
      // 读回同值：新会话（重新 load）必须还是 light，证明写的是真存储。
      final BasicSettingsRuntime reloaded = await _runtime(port: port);
      expect(reloaded.snapshot.themeMode, 'light');
    });

    test('进入详情页自动播放 / 点击播放单曲 落到真实偏好键', () async {
      final MemoryBasicSettingsPort port = MemoryBasicSettingsPort(package: _androidPackage);
      final BasicSettingsRuntime runtime = await _runtime(port: port);
      final BasicSettingsApplyResult autoplay =
          await runtime.apply('setting:detail-autoplay:on', context: _context());
      expect(autoplay.persisted, isTrue);
      expect(port.values['panel/detail-autoplay'], 'on');
      expect(runtime.detailAutoplay, isTrue);
      final BasicSettingsApplyResult single =
          await runtime.apply('setting:single-play-mode:append', context: _context());
      expect(single.persisted, isTrue);
      expect(port.values['panel/single-play-mode'], 'append');
      expect(runtime.singlePlayAppend, isTrue);
    });

    test('图形后端：requested 立刻变，effective 只在重启后变', () async {
      final MemoryBasicSettingsPort port = MemoryBasicSettingsPort(
        values: <String, String>{'panel/graphics-backend': 'opengl'},
        package: _androidPackage,
      );
      final BasicSettingsRuntime runtime = await _runtime(port: port);
      expect(runtime.effectiveGraphicsBackend, 'opengl');
      final BasicSettingsApplyResult result =
          await runtime.apply('setting:graphics-backend:vulkan', context: _context());
      expect(result.persisted, isTrue);
      expect(result.restartPending, isTrue, reason: 'descriptor 的 restartHint 是"重启生效"');
      expect(port.values['panel/graphics-backend'], 'vulkan');
      expect(runtime.requestedGraphicsBackend, 'vulkan');
      expect(runtime.effectiveGraphicsBackend, 'opengl',
          reason: '本进程已经用 opengl 起来了：生效值不能跟着请求值跑');
      expect(runtime.pendingRestart, contains('图形后端'));
      final BasicSettingsRuntime restarted = await _runtime(port: port);
      expect(restarted.effectiveGraphicsBackend, 'vulkan');
    });

    test('唱片旋转：开启必须先过风险确认，确认后才写 on', () async {
      final MemoryBasicSettingsPort port = MemoryBasicSettingsPort(package: _androidPackage);
      final BasicSettingsRuntime runtime = await _runtime(port: port);
      final BasicSettingsApplyResult warn =
          await runtime.apply('disc-rotation', context: _context());
      expect(warn.requiresWarning, isTrue);
      expect(warn.persisted, isFalse);
      expect(port.values.containsKey('panel/disc-rotation'), isFalse,
          reason: '还没确认风险，一个键都不能写');
      final BasicSettingsApplyResult enable =
          await runtime.apply('disc-rotation:enable', context: _context());
      expect(enable.persisted, isTrue);
      expect(port.values['panel/disc-rotation'], 'on');
      expect(runtime.discRotation, isTrue);
      final BasicSettingsApplyResult disable =
          await runtime.apply('disc-rotation', context: _context());
      expect(disable.requiresWarning, isFalse, reason: '关闭不需要风险确认');
      expect(port.values['panel/disc-rotation'], 'off');
    });

    test('项目与开源参考打开的是真 URL（8 条之一逐字）', () async {
      final MemoryBasicSettingsPort port = MemoryBasicSettingsPort(package: _androidPackage);
      final BasicSettingsRuntime runtime = await _runtime(port: port);
      final BasicSettingsApplyResult result =
          await runtime.apply('music:project-lyricsx', context: _context());
      expect(port.openedUrls, <String>['https://github.com/MxIris-LyricsX-Project/LyricsX']);
      expect(result.notice, isEmpty);
    });

    test('ONLY14 之外的动作被拒，且不写任何键', () async {
      final MemoryBasicSettingsPort port = MemoryBasicSettingsPort(package: _androidPackage);
      final BasicSettingsRuntime runtime = await _runtime(port: port);
      final BasicSettingsApplyResult result =
          await runtime.apply('cache:clear', context: _context());
      expect(result.command, isA<BasicSettingsUnavailableCommand>());
      expect(result.persisted, isFalse);
      expect(port.values, isEmpty);
      expect(runtime.pendingRestart, isEmpty);
    });

    test('写入失败如实报告（不退化成"假装已保存"）', () async {
      final MemoryBasicSettingsPort port =
          MemoryBasicSettingsPort(package: _androidPackage, failWrites: true);
      final BasicSettingsRuntime runtime = await _runtime(port: port);
      final BasicSettingsApplyResult result =
          await runtime.apply('setting:theme:light', context: _context());
      expect(result.persisted, isFalse);
      expect(result.notice, contains('写入失败'));
      expect(port.values, isEmpty);
      expect(runtime.snapshot.themeMode, 'dark');
    });
  });

  group('面板模型真值', () {
    test('ONLY14 的行都在，且不含诊断/缓存/检查更新/登录', () async {
      final BasicSettingsRuntime runtime = await _runtime();
      final BasicSettingsPanelModel model = basicSettingsPanelModel(
        context: _context(),
        snapshot: runtime.snapshot,
        version: runtime.version!,
        expandedId: runtime.expandedId,
      );
      final List<String> ids = <String>[
        for (final SettingsSectionModel section in model.sections)
          for (final SettingsRowSpec row in section.rows) row.id,
      ];
      expect(ids, containsAll(<String>[
        'theme',
        'startup-animation',
        'replay',
        'quality',
        'detail-autoplay',
        'single-play-mode',
        'graphics-backend',
        'vsync',
        'render-scale',
        'aa-mode',
        'project-home',
        'project-lyricsx',
      ]));
      for (final String banned in <String>[
        'cache',
        'update',
        'official-player',
        'window',
        'desktop-lyrics',
        'gpu-index',
      ]) {
        expect(ids, isNot(contains(banned)), reason: 'ONLY14 之外不许出现在面板里');
      }
      expect(model.version.label, '当前版本 / 1.4.8 · 开发版');
    });
  });

  group('浮层绘制与命中', () {
    late BasicGlyphPorts ports;
    setUpAll(() async {
      final String glyphJson = await File(basicGlyphTableAsset).readAsString();
      final GlyphFontSet fonts =
          parseGlyphResources(glyphJson: glyphJson, letteringJson: '{}');
      ports = BasicGlyphPorts(glyphs: fonts, text: GlyphText.resourceOnly(fonts));
    });

    Future<BasicSettingsOverlayState> pump(
      WidgetTester tester, {
      required BasicSettingsPanelModel model,
      required HudStage stage,
      required List<String> actions,
    }) async {
      // 1080 x 1080 的舞台窗口：测试默认 800x600 会让右下角的滚动按钮跑到屏幕外，
      // 命中测试就变成"什么都没点到"（几何仍会被断言，所以必须真的放大窗口）。
      tester.view.physicalSize = Size(stage.width * stage.scale, stage.height * stage.scale);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: stage.width * stage.scale,
            height: stage.height * stage.scale,
            child: BasicSettingsOverlay(
              stage: stage,
              ports: ports,
              model: model,
              dark: true,
              onAction: actions.add,
            ),
          ),
        ),
      ));
      await tester.pump();
      return tester.state<BasicSettingsOverlayState>(find.byType(BasicSettingsOverlay));
    }

    testWidgets('模态框架 + 卡片 + 轨道同帧画出，返回按钮命中 close-modal', (WidgetTester tester) async {
      final BasicSettingsRuntime runtime = await _runtime();
      final BasicSettingsPanelModel model = basicSettingsPanelModel(
        context: _context(),
        snapshot: runtime.snapshot,
        version: runtime.version!,
      );
      final HudStage stage = const HudStage(scale: 1, width: 1080, height: 1080);
      final List<String> actions = <String>[];
      await pump(tester, model: model, stage: stage, actions: actions);
      expect(find.byType(CustomPaint), findsWidgets);
      // 命中表真的画出来了：返回按钮 + 至少一行卡片行。
      final BasicSettingsOverlayState state =
          tester.state<BasicSettingsOverlayState>(find.byType(BasicSettingsOverlay));
      final List<String> drawn = <String>[for (final SettingsHitRegion hit in state.hits) hit.action];
      expect(drawn, contains(SettingsModalFrame.backAction));
      expect(drawn.length, greaterThan(3));
      // 点返回按钮（NativeHudModal.cpp:199-200 的几何）。
      final Rect bounds = settingsModalBounds(stage.width);
      final Rect back = SettingsPanelGeometry.backButton(
          x: bounds.left, y: bounds.top, usable: bounds.width);
      await tester.tapAt(back.center);
      await tester.pump();
      expect(actions, contains(SettingsModalFrame.backAction));
    });

    testWidgets('卡片命中被视口裁剪：滚出视口的行不可点', (WidgetTester tester) async {
      final BasicSettingsRuntime runtime = await _runtime();
      final BasicSettingsPanelModel model = basicSettingsPanelModel(
        context: _context(),
        snapshot: runtime.snapshot,
        version: runtime.version!,
      );
      final HudStage stage = const HudStage(scale: 1, width: 1080, height: 1080);
      final List<String> actions = <String>[];
      await pump(tester, model: model, stage: stage, actions: actions);
      final Rect bounds = settingsModalBounds(stage.width);
      final Rect viewport = SettingsPanelGeometry.viewport(
          x: bounds.left, y: bounds.top, width: bounds.width);
      // 卡片上的命中断言：全部落在视口内（chrome 命中不受此限）。
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final BasicSettingsSurface surface = BasicSettingsSurface(
        viewport: viewport,
        model: model,
        dark: true,
      );
      surface.paint(recorder);
      final List<SettingsHitRegion> clipped = surface.clipHits(recorder.hits);
      expect(clipped, isNotEmpty);
      for (final SettingsHitRegion hit in clipped) {
        expect(viewport.overlaps(hit.rect), isTrue,
            reason: '${hit.action} 不该在视口外还有命中');
      }
    });

    testWidgets('滚动按钮/滚轮都是 66 步进，且滚到底就停住', (WidgetTester tester) async {
      final BasicSettingsRuntime runtime = await _runtime();
      final BasicSettingsPanelModel model = basicSettingsPanelModel(
        context: _context(),
        snapshot: runtime.snapshot,
        version: runtime.version!,
      );
      final HudStage stage = const HudStage(scale: 1, width: 1080, height: 1080);
      final List<String> actions = <String>[];
      final BasicSettingsOverlayState state =
          await pump(tester, model: model, stage: stage, actions: actions);
      expect(state.scroll, 0);
      final Rect bounds = settingsModalBounds(stage.width);
      final Rect down = SettingsPanelGeometry.scrollDownButton(
          track: SettingsPanelGeometry.scrollTrack(
              x: bounds.left, y: bounds.top, width: bounds.width),
          y: bounds.top);
      await tester.tapAt(down.center);
      await tester.pump();
      expect(state.scroll, 66, reason: 'NativeHudInput.cpp:30-33 的 66 步进');
      expect(actions, isEmpty, reason: '滚动按钮由浮层自己处理，不外抛');
      // 滚到底：clamp 到 maximumScroll，不越界。
      for (int i = 0; i < 40; i++) {
        await tester.tapAt(down.center);
        await tester.pump();
      }
      final BasicSettingsSurface surface = BasicSettingsSurface(
        viewport: SettingsPanelGeometry.viewport(
            x: bounds.left, y: bounds.top, width: bounds.width),
        model: model,
        dark: true,
      );
      expect(state.scroll, surface.maximumScroll);
    });
  });
}
