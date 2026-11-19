/// 竖屏设置页的 stepper 行（右侧画面遮罩 / 渲染分辨率）必须真的能调。
///
/// 用户 2026-11-19：「部分设置（如右侧遮罩和渲染分辨率）无法调整」。根因是 stepper
/// 分支之后又叠了一层行级点击区，它盖在 ± 之上把点击吞掉，而这两行本来就没有
/// `binding.action`，于是点什么都没反应。Qt compact `settings()` 的 Slider|Stepper
/// 分支只注册 ± 两个按钮（Qt/src/ResponsiveHudPages.cpp:600-606）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_settings.dart';
import 'package:rhine_music_database/basic/basic_settings_portrait.dart';
import 'package:rhine_music_database/hud/modals/settings_modal.dart';
import 'package:rhine_music_database/hud/protocol/hud_frame.dart';

BasicSettingsPanelModel _model() => basicSettingsPanelModel(
      context: const SettingsPreferenceContext(),
      snapshot: const SettingsPreferenceSnapshot(),
      version: const BasicSettingsVersion(version: '1.0.0'),
    );

/// 竖屏页按 393 网格排版：视图给到 2600 高，两行 stepper 都落在可见区里。
/// （Column 会构建全部子项，但被 ClipRect 裁掉的部分点不到。）
Future<List<String>> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final List<String> actions = <String>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: BasicPortraitSettingsPage(
        stage: const HudStage(scale: 1, width: 1080, height: 2600),
        model: _model(),
        dark: false,
        onAction: actions.add,
      ),
    ),
  ));
  await tester.pump();
  return actions;
}

void main() {
  testWidgets('右侧画面遮罩：+ / − 发出真实的目标值动作', (WidgetTester tester) async {
    final List<String> actions = await _pump(tester);

    // 出厂默认 0 → 点 + 是 10（不是 +10 的增量串），点 − 会被夹在 0。
    await tester.tap(find.byKey(
      const ValueKey<String>('settings-portrait-step-archive-mask-inc'),
    ));
    await tester.pump();
    expect(actions, <String>['archive-mask:10']);

    await tester.tap(find.byKey(
      const ValueKey<String>('settings-portrait-step-archive-mask-dec'),
    ));
    await tester.pump();
    expect(actions.last, 'archive-mask:0');
  });

  testWidgets('渲染分辨率：− 发出上一档（100% → 90%）', (WidgetTester tester) async {
    final List<String> actions = await _pump(tester);

    await tester.tap(find.byKey(
      const ValueKey<String>('settings-portrait-step-render-scale-dec'),
    ));
    await tester.pump();
    expect(actions, contains('render-scale:90'));
  });

  testWidgets('stepper 行不再被行级热区吞点击：一次点击只发一条动作', (WidgetTester tester) async {
    final List<String> actions = await _pump(tester);
    await tester.tap(find.byKey(
      const ValueKey<String>('settings-portrait-step-archive-mask-inc'),
    ));
    await tester.pump();
    expect(actions.length, 1, reason: '± 之外不许再有一条空动作/行级动作');
    expect(actions.single, isNotEmpty);
  });

  testWidgets('choice 行仍然整行可点（expand:<id>）', (WidgetTester tester) async {
    final List<String> actions = await _pump(tester);
    // 行内热区在右侧控件区（Qt 也是 {195, y+4, 178, 44}），点标题不算命中；
    // Text 自身不参与命中测试，所以按坐标点它的中心（落在行级 GestureDetector 上）。
    await tester.tapAt(tester.getCenter(find.text('亮色')));
    await tester.pump();
    expect(actions, contains('expand:theme'));
  });
}
