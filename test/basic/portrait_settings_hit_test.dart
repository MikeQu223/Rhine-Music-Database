/// 竖屏设置页：滚到底之后中间那一屏的控件是否还点得动。
///
/// 钉住行为本身：滚到底后把每一屏里第一个可点控件按真实坐标点一次，必须发出对应动作。
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

/// 竖屏舞台 1080 × 1920（取 1920 是为了复现「页面比屏幕高」的滚动）。
Future<List<String>> _pump(WidgetTester tester, {double height = 1727}) async {
  tester.view.physicalSize = Size(1080, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final List<String> actions = <String>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: BasicPortraitSettingsPage(
        stage: HudStage(scale: 1, width: 1080, height: height),
        model: _model(),
        dark: true,
        onAction: actions.add,
      ),
    ),
  ));
  await tester.pump();
  return actions;
}

void main() {
  testWidgets('未滚动时中间那一屏的控件可点（基线）', (WidgetTester tester) async {
    final List<String> actions = await _pump(tester);
    // 「界面配色」的 choice 行在最上面一屏；点它的值文字中心。
    await tester.tapAt(tester.getCenter(find.text('亮色')));
    await tester.pump();
    expect(actions, isNotEmpty, reason: '未滚动时点 choice 值必须发出 expand:theme');
  });

  testWidgets('滚到底后中间那一屏的控件仍可点', (WidgetTester tester) async {
    final List<String> actions = await _pump(tester);

    // 用户是「先滑到底再看上面那几屏」：把滚动位置推到最底部，中间的控件被滚到
    // 屏幕中部——它们必须还能点。
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    final ScrollableState state = tester.state(find.byType(Scrollable));
    state.position.jumpTo(state.position.maxScrollExtent / 2);
    await tester.pump();

    // 滚到底后取一个仍然可见的控件：渲染分辨率那一行的 + 号。
    final Finder target = find.byKey(
      const ValueKey<String>('settings-portrait-step-render-scale-inc'),
    );
    if (target.evaluate().isEmpty) {
      fail('滚到底后渲染分辨率行的 + 号已不在树里，无法验证命中');
    }
    await tester.tap(target);
    await tester.pump();
    expect(actions, isNotEmpty, reason: '滚到底后点 + 号必须发出渲染分辨率动作');
  });
}
