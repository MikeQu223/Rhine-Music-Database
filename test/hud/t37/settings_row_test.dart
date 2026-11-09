// Qt SettingsCard 行层移植的独立校验。
//
// 每条断言都对着 Qt 源里逐字存在的数值，注释给出来处：
// - 常量/纯函数   Qt/src/SettingsCard.cpp:9-34
// - 行绘制        Qt/src/SettingsCard.cpp:47-236
// - 行布局        Qt/src/SettingsCard.cpp:239-292
// - 行/选项可见性 Qt/src/SettingsCard.cpp:294-326
// - 命中裁剪      Qt/src/HudScroll.h:13-26,67-86
// - stroke 展开   Qt/src/NativeHudSettings.cpp:195-200
// - 编辑状态机    Qt/src/NativeHudSettings.cpp:109-161
// - 提交/失败分类 Qt/src/NativeHudSettings.cpp:382-490
// - 派发与滚轮    Qt/src/NativeHudController.cpp:394-402, NativeHudInput.cpp:23-26
// - 展开项        Qt/src/NativeHudController.cpp:774-780
//
// 状态：本轮禁止执行 dart test / flutter test / dart analyze，
// 本文件按「RED/GREEN 未执行」交付，逻辑由独立只读 review 复核。

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/hud/widgets/settings_row.dart';

/// 断言行右控件下发的文本截断宽度（Canvas::fit 的参数）。
void expectLastFit(SettingsRowRecorder recorder, String value, double size, double maxWidth,
    SettingsFontWeight weight) {
  expect(recorder.fitCalls, isNotEmpty);
  expect(recorder.fitCalls.last, <Object>[value, size, maxWidth, weight]);
}

SettingsPalette darkPalette() =>
    SettingsPalette.fromInk(const SettingsRgba(1, 1, 1, 1), dark: true);

SettingsRowSpec choiceRow({
  String id = 'close-behavior',
  String titleZh = '点击关闭窗口',
  String action = 'close-behavior',
  String actionPrefix = 'setting:close-behavior:',
  String label = '退出',
  String canonical = 'ask',
  int choiceCount = 3,
  bool enabled = true,
  bool expanded = false,
  String restartHint = '',
}) {
  const List<SettingsChoice> all = <SettingsChoice>[
    SettingsChoice(value: 'quit', label: '退出'),
    SettingsChoice(value: 'tray', label: '最小化到托盘'),
    SettingsChoice(value: 'ask', label: '每次询问'),
  ];
  return SettingsRowSpec(
    id: id,
    kind: SettingsRowKind.choice,
    bindingKind: SettingsBindingKind.preference,
    action: action,
    actionPrefix: actionPrefix,
    titleEn: 'CLOSE WINDOW',
    titleZh: titleZh,
    label: label,
    restartHint: restartHint,
    value: SettingsRowValue(canonical: canonical, integer: 0),
    choices: all.take(choiceCount).toList(),
    enabled: enabled,
    expanded: expanded,
  );
}

SettingsRowSpec stepperRow({
  String id = 'render-scale',
  String actionPrefix = 'render-scale:',
  String action = '',
  String label = '75%',
  int integer = 75,
  List<int> numericValues = const <int>[50, 60, 75, 90, 100],
  String decrementValue = 'down',
  String incrementValue = 'up',
  bool enabled = true,
  bool expanded = false,
}) {
  return SettingsRowSpec(
    id: id,
    kind: SettingsRowKind.stepper,
    bindingKind: SettingsBindingKind.preference,
    action: action,
    actionPrefix: actionPrefix,
    preferenceKey: id,
    titleEn: 'RENDER SCALE',
    titleZh: '渲染分辨率',
    label: label,
    value: SettingsRowValue(canonical: integer.toString(), integer: integer),
    numericValues: numericValues,
    decrementValue: decrementValue,
    incrementValue: incrementValue,
    enabled: enabled,
    expanded: expanded,
  );
}

SettingsRowSpec actionRow({bool enabled = true}) => SettingsRowSpec(
      id: 'window',
      kind: SettingsRowKind.action,
      bindingKind: SettingsBindingKind.action,
      action: 'window:fullscreen',
      titleEn: 'WINDOW',
      titleZh: '窗口显示',
      actionLabel: '切换全屏 / F11',
      enabled: enabled,
    );

SettingsRowSpec textInputRow({bool enabled = true}) => SettingsRowSpec(
      id: 'profile-name',
      kind: SettingsRowKind.textInput,
      bindingKind: SettingsBindingKind.preference,
      action: 'profile-name',
      titleEn: 'PROFILE',
      titleZh: '用户名称',
      label: '默认',
      value: const SettingsRowValue(canonical: '默认'),
      enabled: enabled,
    );

SettingsRowSpec linkRow({bool enabled = true}) => SettingsRowSpec(
      id: 'project-home',
      kind: SettingsRowKind.link,
      bindingKind: SettingsBindingKind.external,
      action: 'project:home',
      titleEn: 'PROJECT HOME',
      titleZh: '项目主页',
      actionLabel: '项目主页',
      enabled: enabled,
    );

SettingsRowSpec customRow() => const SettingsRowSpec(
      id: 'provider',
      kind: SettingsRowKind.custom,
      bindingKind: SettingsBindingKind.customSection,
      titleEn: 'PROVIDER',
      titleZh: '音乐来源',
    );

void main() {
  const Rect viewport = Rect.fromLTWH(0, 176, 1280, 660);
  final double left = viewport.left + SettingsRowMetrics.contentInset;
  final double width = viewport.width - SettingsRowMetrics.contentInset * 2;
  const double cursor = 176;

  group('常量与纯函数（SettingsCard.cpp:9-34 / HudScroll.h:13-26）', () {
    test('十一个几何常量与 Qt 字面值一致', () {
      expect(SettingsRowMetrics.headerHeight, 46);
      expect(SettingsRowMetrics.sectionGap, 24);
      expect(SettingsRowMetrics.rowHeight, 66);
      expect(SettingsRowMetrics.rowStep, 76);
      expect(SettingsRowMetrics.optionHeight, 50);
      expect(SettingsRowMetrics.bottomPad, 28);
      expect(SettingsRowMetrics.contentInset, 14);
      expect(SettingsRowMetrics.controlWidth, 300);
      expect(SettingsRowMetrics.linkGap, 16);
      expect(SettingsRowMetrics.linkRowHeight, 50);
      expect(SettingsRowMetrics.linkRowStep, 60);
    });

    test('rowIndex 是两位零填充的 1 基序号（SettingsCard.cpp:32-34）', () {
      expect(SettingsRowMetrics.rowIndex(0), '01');
      expect(SettingsRowMetrics.rowIndex(8), '09');
      expect(SettingsRowMetrics.rowIndex(9), '10');
      expect(SettingsRowMetrics.rowIndex(99), '100');
    });

    test('actionFor 前缀优先，为空才回退 binding.action（SettingsCard.cpp:27-30）', () {
      expect(SettingsRowMetrics.actionFor(choiceRow()), 'setting:close-behavior:');
      expect(SettingsRowMetrics.actionFor(choiceRow(actionPrefix: '')), 'close-behavior');
      expect(SettingsRowMetrics.actionFor(actionRow()), 'window:fullscreen');
    });

    test('Project 两列宽度与体高（SettingsCard.cpp:256,264）', () {
      expect(SettingsRowMetrics.linkWidth(1252), 618);
      expect(SettingsRowMetrics.linkWidth(1252), (1252 - 16) / 2);
      expect(SettingsRowMetrics.linkBodyHeight(1), 60);
      expect(SettingsRowMetrics.linkBodyHeight(2), 60);
      expect(SettingsRowMetrics.linkBodyHeight(3), 120);
      expect(SettingsRowMetrics.linkBodyHeight(8), 240);
    });

    test('展开高度 = choices * 50 + 4（SettingsCard.cpp:277）', () {
      expect(SettingsRowMetrics.optionsHeightFor(0), 4);
      expect(SettingsRowMetrics.optionsHeightFor(3), 154);
      expect(SettingsRowMetrics.optionsHeightFor(6), 304);
    });

    test('滚动上限与夹取（HudScroll.h:13-19）', () {
      expect(SettingsRowMetrics.maximumScroll(100, 660), 0);
      expect(SettingsRowMetrics.maximumScroll(1000, 660), 340);
      expect(SettingsRowMetrics.clampScroll(-5, 1000, 660), 0);
      expect(SettingsRowMetrics.clampScroll(999, 1000, 660), 340);
      expect(SettingsRowMetrics.clampScroll(100, 1000, 660), 100);
    });

    test('stroke 展开为四条 1px 填充，顺序与 Qt 一致（NativeHudSettings.cpp:195-200）', () {
      const Rect rect = Rect.fromLTWH(10, 20, 100, 40);
      final List<Rect> fills = SettingsRowMetrics.strokeFillRects(rect);
      expect(fills.length, 4);
      expect(fills[0], const Rect.fromLTWH(10, 20, 100, 1));
      expect(fills[1], const Rect.fromLTWH(10, 59, 100, 1));
      expect(fills[2], const Rect.fromLTWH(10, 20, 1, 40));
      expect(fills[3], const Rect.fromLTWH(109, 20, 1, 40));
    });

    test('fade 直接把 alpha 置为给定值，不是相乘（SettingsCard.cpp:21-25）', () {
      const SettingsRgba ink = SettingsRgba(0.2, 0.4, 0.6, 1);
      expect(ink.fade(0.35), const SettingsRgba(0.2, 0.4, 0.6, 0.35));
      expect(ink.fade(0.35).a, 0.35);
    });

    test('配色派生值与 Qt 一致（NativeHudSettings.cpp:172-179）', () {
      final SettingsPalette dark = SettingsPalette.fromInk(const SettingsRgba(1, 1, 1, 1), dark: true);
      expect(dark.muted, const SettingsRgba(1, 1, 1, 0.55));
      expect(dark.faint, const SettingsRgba(1, 1, 1, 0.12));
      expect(dark.line, const SettingsRgba(1, 1, 1, 0.25));
      expect(dark.soft, const SettingsRgba(1, 1, 1, 0.05));
      expect(dark.gold, const SettingsRgba(0.835, 0.639, 0.282, 1));
      expect(dark.panel, const SettingsRgba(0.15, 0.15, 0.15, 1));

      final SettingsPalette light =
          SettingsPalette.fromInk(const SettingsRgba(0, 0, 0, 1), dark: false);
      expect(light.soft, const SettingsRgba(0, 0, 0, 0.04));
      expect(light.panel, const SettingsRgba(0.929, 0.922, 0.894, 1));
    });
  });

  group('行布局（SettingsCard.cpp:239-292）', () {
    test('未展开的普通行：bounds/control 几何与光标只推进 RowStep', () {
      final SettingsRowPlacement placed =
          placeSettingsRow(row: choiceRow(), left: left, width: width, cursor: cursor);
      expect(placed.layout.bounds, Rect.fromLTWH(14, 176, 1252, 66));
      expect(placed.layout.control, Rect.fromLTWH(966, 185, 300, 48));
      expect(placed.layout.optionsHeight, 0);
      expect(placed.layout.options, Rect.zero);
      expect(placed.nextCursor, 176 + 76);
    });

    test('展开且 enabled：options 在行下 2px，光标再多推进 optionsHeight', () {
      final SettingsRowPlacement placed = placeSettingsRow(
          row: choiceRow(expanded: true), left: left, width: width, cursor: cursor);
      expect(placed.layout.optionsHeight, 3 * 50 + 4);
      expect(placed.layout.options, Rect.fromLTWH(966, 176 + 66 + 2, 300, 154));
      expect(placed.nextCursor, 176 + 76 + 154);
    });

    test('展开但 disabled：不占位、无 options、光标只推进 RowStep（SettingsCard.cpp:275）', () {
      final SettingsRowPlacement placed = placeSettingsRow(
          row: choiceRow(expanded: true, enabled: false), left: left, width: width, cursor: cursor);
      expect(placed.layout.optionsHeight, 0);
      expect(placed.layout.options, Rect.zero);
      expect(placed.nextCursor, 176 + 76);
    });

    test('展开但没有选项时仍占 4px（choices 为空的 Choice 不会出现，但几何如此）', () {
      final SettingsRowPlacement placed = placeSettingsRow(
          row: choiceRow(expanded: true, choiceCount: 0), left: left, width: width, cursor: cursor);
      expect(placed.layout.optionsHeight, 4);
      expect(placed.nextCursor, 176 + 80);
    });

    test('Project 两列：同行同 y，隔行加 60（SettingsCard.cpp:255-264）', () {
      final SettingsRowLayout a =
          placeProjectLink(row: linkRow(), index: 0, left: left, width: width, cursor: cursor);
      final SettingsRowLayout b =
          placeProjectLink(row: linkRow(), index: 1, left: left, width: width, cursor: cursor);
      final SettingsRowLayout c =
          placeProjectLink(row: linkRow(), index: 2, left: left, width: width, cursor: cursor);
      expect(a.bounds, Rect.fromLTWH(14, 176, 618, 50));
      expect(b.bounds, Rect.fromLTWH(14 + 618 + 16, 176, 618, 50));
      expect(c.bounds, Rect.fromLTWH(14, 236, 618, 50));
      expect(a.control, Rect.zero);
      expect(a.optionsHeight, 0);
    });

    test('translated 同步平移 bounds/control/options（SettingsCard.cpp:300-302）', () {
      final SettingsRowLayout layout = placeSettingsRow(
              row: choiceRow(expanded: true), left: left, width: width, cursor: cursor)
          .layout;
      final SettingsRowLayout moved = layout.translated(-120);
      expect(moved.bounds, Rect.fromLTWH(14, 56, 1252, 66));
      expect(moved.control, Rect.fromLTWH(966, 65, 300, 48));
      expect(moved.options, Rect.fromLTWH(966, 124, 300, 154));
      expect(moved.optionsHeight, layout.optionsHeight);
    });
  });

  group('行 chrome（SettingsCard.cpp:194-204）', () {
    test('下划线是最后 1px，行号/titleEn/titleZh 的位置与字重逐字一致', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsRowLayout layout =
          placeSettingsRow(row: choiceRow(restartHint: '重启生效'), left: left, width: width, cursor: cursor)
              .layout;
      paintSettingsRow(
        layout: layout,
        index: 0,
        canvas: recorder,
        palette: darkPalette(),
        viewport: viewport,
      );
      final SettingsPalette palette = darkPalette();
      expect(recorder.fills.first, const SettingsFillOp(14, 241, 1252, 1, SettingsRgba(1, 1, 1, 0.25)));
      expect(recorder.textAt('01')!.left, 14);
      expect(recorder.textAt('01')!.top, 201);
      expect(recorder.textAt('01')!.size, 11);
      expect(recorder.textAt('01')!.tracking, 0.04);
      expect(recorder.textAt('01')!.color, palette.muted);
      expect(recorder.textAt('CLOSE WINDOW')!.left, 44);
      expect(recorder.textAt('CLOSE WINDOW')!.top, 186);
      expect(recorder.textAt('CLOSE WINDOW')!.size, 11);
      expect(recorder.textAt('CLOSE WINDOW')!.tracking, 0.08);
      expect(recorder.textAt('点击关闭窗口')!.left, 44);
      expect(recorder.textAt('点击关闭窗口')!.top, 201);
      expect(recorder.textAt('点击关闭窗口')!.size, 17);
      expect(recorder.textAt('点击关闭窗口')!.weight, SettingsFontWeight.demibold);
      expect(recorder.textAt('点击关闭窗口')!.tracking, -0.01);
      expect(recorder.textAt('点击关闭窗口')!.color, palette.ink);
      expect(recorder.textAt('重启生效')!.top, 226);
      expect(recorder.textAt('重启生效')!.size, 10);
      expect(recorder.textAt('重启生效')!.tracking, 0.03);
    });

    test('restartHint 为空时不画提示（SettingsCard.cpp:201）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsRow(
        layout:
            placeSettingsRow(row: choiceRow(), left: left, width: width, cursor: cursor).layout,
        index: 0,
        canvas: recorder,
        palette: darkPalette(),
        viewport: viewport,
      );
      // 行号 / titleEn / titleZh 三条，加上控件自身的标签与箭头两条。
      expect(recorder.texts.length, 5);
      expect(recorder.textAt('重启生效'), isNull);
    });

    test('disabled 行用 ink@0.35 / muted@0.28（SettingsCard.cpp:195-196）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsPalette palette = darkPalette();
      paintSettingsRow(
        layout: placeSettingsRow(row: choiceRow(enabled: false), left: left, width: width, cursor: cursor)
            .layout,
        index: 0,
        canvas: recorder,
        palette: palette,
        viewport: viewport,
      );
      expect(recorder.textAt('点击关闭窗口')!.color, palette.ink.fade(0.35));
      expect(recorder.textAt('01')!.color, palette.muted.fade(0.28));
    });

    test('Link 行提前返回：没有行号、没有下划线，只有 actionLabel 与箭头', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsRow(
        layout: placeProjectLink(row: linkRow(), index: 0, left: left, width: width, cursor: cursor),
        index: 0,
        canvas: recorder,
        palette: darkPalette(),
        viewport: viewport,
      );
      expect(recorder.fills.length, 1);
      expect(recorder.texts.length, 2);
      expect(recorder.textAt('项目主页'), isNotNull);
      expect(recorder.textAt('↗'), isNotNull);
    });
  });

  group('Choice/Switch 控件（SettingsCard.cpp:66-94）', () {
    test('控件底色与描边、标签位置、fit 宽度 252', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsPalette palette = darkPalette();
      final SettingsRowLayout layout =
          placeSettingsRow(row: choiceRow(), left: left, width: width, cursor: cursor).layout;
      paintSettingsChoice(layout: layout, canvas: recorder, palette: palette, fit: recorder.fitter);

      expect(recorder.fills.first, SettingsFillOp(966, 185, 300, 48, palette.soft));
      expect(recorder.strokes.first, SettingsStrokeOp(Rect.fromLTWH(966, 185, 300, 48), palette.line));
      expectLastFit(recorder, '退出', 15, 300 - 48, SettingsFontWeight.regular);
      expect(recorder.textAt('退出')!.left, 980);
      expect(recorder.textAt('退出')!.top, 200);
      expect(recorder.textAt('退出')!.size, 15);
      expect(recorder.textAt('退出')!.weight, SettingsFontWeight.regular);
      expect(recorder.textAt('退出')!.color, palette.ink);
    });

    test('未展开画 ▾、展开画 ▴，都在 control.right-24 / top+14（SettingsCard.cpp:72-73）', () {
      final SettingsRowRecorder closed = SettingsRowRecorder();
      paintSettingsChoice(
        layout: placeSettingsRow(row: choiceRow(), left: left, width: width, cursor: cursor).layout,
        canvas: closed,
        palette: darkPalette(),
      );
      expect(closed.textAt('▾')!.left, 966 + 300 - 24);
      expect(closed.textAt('▾')!.top, 199);
      expect(closed.textAt('▾')!.size, 14);

      final SettingsRowRecorder opened = SettingsRowRecorder();
      paintSettingsChoice(
        layout: placeSettingsRow(row: choiceRow(expanded: true), left: left, width: width, cursor: cursor)
            .layout,
        canvas: opened,
        palette: darkPalette(),
      );
      expect(opened.textAt('▴'), isNotNull);
      expect(opened.textAt('▾'), isNull);
    });

    test('disabled 且 expanded 仍画 ▾（NativeHudSettings.cpp:66 的 enabled 与运算，回归 F-01）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsChoice(
        layout: placeSettingsRow(
                row: choiceRow(expanded: true, enabled: false), left: left, width: width, cursor: cursor)
            .layout,
        canvas: recorder,
        palette: darkPalette(),
      );
      // Qt 的 RowModel.expanded = expandedId == id && enabled，disabled 行永远落到 ▾。
      expect(recorder.textAt('▴'), isNull);
      expect(recorder.textAt('▾'), isNotNull);
    });

    test('enabled 时 control 命中 expand:<id>，label 是 titleZh（SettingsCard.cpp:74-76）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsChoice(
        layout: placeSettingsRow(row: choiceRow(), left: left, width: width, cursor: cursor).layout,
        canvas: recorder,
        palette: darkPalette(),
      );
      expect(recorder.hits.length, 1);
      expect(recorder.hitAt('expand:close-behavior')!.rect, Rect.fromLTWH(966, 185, 300, 48));
      expect(recorder.hitAt('expand:close-behavior')!.label, '点击关闭窗口');
    });

    test('disabled 时不注册任何命中（SettingsCard.cpp:74）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsChoice(
        layout: placeSettingsRow(row: choiceRow(enabled: false), left: left, width: width, cursor: cursor)
            .layout,
        canvas: recorder,
        palette: darkPalette(),
      );
      expect(recorder.hits, isEmpty);
      expect(recorder.textAt('退出')!.color, darkPalette().ink.fade(0.35));
      expect(recorder.textAt('▾')!.color, darkPalette().muted.fade(0.3));
    });

    test('Android 默认不注册左侧标题热区（SettingsCard.cpp:82-92 未启用）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsChoice(
        layout: placeSettingsRow(row: choiceRow(), left: left, width: width, cursor: cursor).layout,
        canvas: recorder,
        palette: darkPalette(),
      );
      expect(recorder.hasHit('close-behavior'), isFalse);
    });

    test('桌面分支：标题热区几何与 binding.action（SettingsCard.cpp:84-89）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsRowLayout layout =
          placeSettingsRow(row: choiceRow(), left: left, width: width, cursor: cursor).layout;
      paintSettingsChoice(
        layout: layout,
        canvas: recorder,
        palette: darkPalette(),
        desktopTitleLoopHit: true,
      );
      // labelLeft = bounds.left + 30 = 44；labelWidth = control.left - 44 - 8 = 914
      final SettingsHitRegion region = recorder.hitAt('close-behavior')!;
      expect(region.rect, Rect.fromLTWH(44, 180, 914, 58));
      expect(region.label, '点击关闭窗口');
    });

    test('桌面分支：binding.action 为空或 labelWidth<=0 时不注册（SettingsCard.cpp:84,87）', () {
      final SettingsRowRecorder noAction = SettingsRowRecorder();
      paintSettingsChoice(
        layout: placeSettingsRow(row: choiceRow(action: ''), left: left, width: width, cursor: cursor)
            .layout,
        canvas: noAction,
        palette: darkPalette(),
        desktopTitleLoopHit: true,
      );
      expect(noAction.hits.length, 1);
      expect(noAction.hasHit(''), isFalse);

      final SettingsRowRecorder narrow = SettingsRowRecorder();
      paintSettingsChoice(
        layout: placeSettingsRow(row: choiceRow(), left: 0, width: 320, cursor: cursor).layout,
        canvas: narrow,
        palette: darkPalette(),
        desktopTitleLoopHit: true,
      );
      // control.left = 0 + 320 - 300 = 20；labelLeft = 30 → labelWidth = -18 → 不注册
      expect(narrow.hits.length, 1);
      expect(narrow.hasHit('close-behavior'), isFalse);
    });
  });

  group('展开选项列表（SettingsCard.cpp:47-64）', () {
    test('每项几何、活动项 3px 金条与 demibold', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsPalette palette = darkPalette();
      final SettingsRowLayout layout = placeSettingsRow(
              row: choiceRow(expanded: true, canonical: 'tray'), left: left, width: width, cursor: cursor)
          .layout;
      paintSettingsOptions(layout: layout, canvas: recorder, palette: palette, fit: recorder.fitter);

      final Rect options = Rect.fromLTWH(966, 244, 300, 154);
      expect(recorder.fills.first, SettingsFillOp(options.left, options.top, 300, 154, palette.soft));
      expect(recorder.strokes.first, SettingsStrokeOp(options, palette.line));

      // 第 0 项未选中：没有金条；第 1 项选中：左上 3x46 金条。
      final SettingsFillOp gold = recorder.fills[1];
      expect(gold, SettingsFillOp(966 + 2, 244 + 2 + 50, 3, 46, palette.gold));
      expect(recorder.fills.length, 2);

      expect(recorder.textAt('退出')!.left, 966 + 2 + 14);
      expect(recorder.textAt('退出')!.top, 244 + 2 + 15);
      expect(recorder.textAt('退出')!.weight, SettingsFontWeight.regular);
      expect(recorder.textAt('最小化到托盘')!.weight, SettingsFontWeight.demibold);
      expect(recorder.textAt('最小化到托盘')!.color, palette.ink);
    });

    test('fit 宽度是选项宽 - 32，命中动作带选项 value（SettingsCard.cpp:59-62）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsRowLayout layout =
          placeSettingsRow(row: choiceRow(expanded: true), left: left, width: width, cursor: cursor)
              .layout;
      paintSettingsOptions(layout: layout, canvas: recorder, palette: darkPalette(), fit: recorder.fitter);
      expectLastFit(recorder, '每次询问', 15, 300 - 4 - 32, SettingsFontWeight.regular);
      expect(recorder.hitAt('setting:close-behavior:quit')!.rect, Rect.fromLTWH(968, 246, 296, 46));
      expect(recorder.hitAt('setting:close-behavior:quit')!.label, '退出');
      expect(recorder.hitAt('setting:close-behavior:ask')!.rect, Rect.fromLTWH(968, 346, 296, 46));
      expect(recorder.hits.length, 3);
    });

    test('choiceCount 为 0 时选项区只画底色与描边，不注册命中', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsRowLayout layout = placeSettingsRow(
              row: choiceRow(expanded: true, choiceCount: 0), left: left, width: width, cursor: cursor)
          .layout;
      paintSettingsOptions(layout: layout, canvas: recorder, palette: darkPalette());
      expect(recorder.fills.length, 1);
      expect(recorder.hits, isEmpty);
    });
  });

  group('Stepper/Slider 控件（SettingsCard.cpp:96-146）', () {
    test('标签 fit 96 demibold，±按钮几何与居中符号', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsPalette palette = darkPalette();
      final SettingsRowLayout layout =
          placeSettingsRow(row: stepperRow(), left: left, width: width, cursor: cursor).layout;
      paintSettingsStepper(layout: layout, canvas: recorder, palette: palette, fit: recorder.fitter);

      expectLastFit(recorder, '75%', 15, 96, SettingsFontWeight.demibold);
      expect(recorder.textAt('75%')!.left, 966 + 2);
      expect(recorder.textAt('75%')!.top, 200);
      expect(recorder.textAt('75%')!.weight, SettingsFontWeight.demibold);

      final Rect minus = Rect.fromLTWH(966 + 100, 193, 32, 32);
      final Rect plus = Rect.fromLTWH(966 + 300 - 40, 193, 32, 32);
      expect(recorder.strokes[1], SettingsStrokeOp(minus, palette.line));
      expect(recorder.strokes[2], SettingsStrokeOp(plus, palette.line));
      expect(recorder.centered[0].value, '−');
      expect(recorder.centered[0].size, 19);
      expect(recorder.centered[0].horizontal, isTrue);
      expect(recorder.centered[0].x, minus.center.dx);
      expect(recorder.centered[0].cy, minus.center.dy);
      expect(recorder.centered[1].value, '＋');
      expect(recorder.centered[1].size, 16);
      expect(recorder.centered[1].x, plus.center.dx);
    });

    test('轨道几何、选中比例与滑块（SettingsCard.cpp:111-126）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsPalette palette = darkPalette();
      final SettingsRowLayout layout =
          placeSettingsRow(row: stepperRow(), left: left, width: width, cursor: cursor).layout;
      paintSettingsStepper(layout: layout, canvas: recorder, palette: palette, fit: recorder.fitter);

      final Rect minus = Rect.fromLTWH(1066, 193, 32, 32);
      final Rect plus = Rect.fromLTWH(1226, 193, 32, 32);
      final Rect track =
          Rect.fromLTWH(minus.right + 12, layout.control.center.dy - 2, plus.left - minus.right - 24, 4);
      // track.width = plus.left - minus.right - 24 = 1226 - 1098 - 24 = 104（SettingsCard.cpp:113）
      expect(track, Rect.fromLTWH(1110, 207, 104, 4));
      expect(recorder.fills[1], SettingsFillOp(track.left, track.top, track.width, track.height, palette.faint));
      // 75 在下标 2，count 5 → fraction = 2/4 = 0.5 → gold 宽 = 104 * 0.5 = 52
      expect(recorder.fills[2], SettingsFillOp(1110, 207, 52, 4, palette.gold));
      // knob.left = track.left + 52 - 4 = 1158（SettingsCard.cpp:123-124）
      expect(recorder.fills[3], SettingsFillOp(1158, 202, 8, 14, palette.ink));
    });

    test('当前值不在 numericValues 里时 fraction 为 0（SettingsCard.cpp:115-123）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsRowLayout layout =
          placeSettingsRow(row: stepperRow(integer: 123, label: '123%'), left: left, width: width, cursor: cursor)
              .layout;
      paintSettingsStepper(layout: layout, canvas: recorder, palette: darkPalette());
      expect(recorder.fills[2], const SettingsFillOp(1110, 207, 0, 4, SettingsRgba(0.835, 0.639, 0.282, 1)));
      expect(recorder.fills[3].left, 1106);
    });

    test('numericValues 只有一个元素时不画轨道（SettingsCard.cpp:111）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsRowLayout layout = placeSettingsRow(
              row: stepperRow(numericValues: <int>[75]), left: left, width: width, cursor: cursor)
          .layout;
      paintSettingsStepper(layout: layout, canvas: recorder, palette: darkPalette());
      expect(recorder.fills.length, 1);
      expect(recorder.centered.length, 2);
    });

    test('每个数值一段命中，最后一段正好到轨道右端（SettingsCard.cpp:127-133）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsRowLayout layout =
          placeSettingsRow(row: stepperRow(), left: left, width: width, cursor: cursor).layout;
      paintSettingsStepper(layout: layout, canvas: recorder, palette: darkPalette());
      // segment = track.width / count = 104 / 5 = 20.8（SettingsCard.cpp:127-133）
      const double segment = 104 / 5;
      expect(segment, 20.8);
      expect(recorder.hitAt('render-scale:50')!.rect, Rect.fromLTWH(1110, 197, segment, 24));
      expect(recorder.hitAt('render-scale:75')!.rect, Rect.fromLTWH(1110 + 2 * segment, 197, segment, 24));
      expect(recorder.hitAt('render-scale:100')!.rect, Rect.fromLTWH(1110 + 4 * segment, 197, segment, 24));
      // 末段右端正好落在 track.right = 1110 + 104 = 1214 上
      expect(recorder.hitAt('render-scale:100')!.rect.right, 1214);
      expect(recorder.hitAt('render-scale:75')!.label, '渲染分辨率');
    });

    test('±命中带 decrement/increment，空串不注册（SettingsCard.cpp:136-144）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsStepper(
        layout: placeSettingsRow(row: stepperRow(), left: left, width: width, cursor: cursor).layout,
        canvas: recorder,
        palette: darkPalette(),
      );
      expect(recorder.hitAt('render-scale:down')!.rect, Rect.fromLTWH(1066, 193, 32, 32));
      expect(recorder.hitAt('render-scale:up')!.rect, Rect.fromLTWH(1226, 193, 32, 32));

      final SettingsRowRecorder bare = SettingsRowRecorder();
      paintSettingsStepper(
        layout: placeSettingsRow(
                row: stepperRow(decrementValue: '', incrementValue: ''), left: left, width: width, cursor: cursor)
            .layout,
        canvas: bare,
        palette: darkPalette(),
      );
      expect(bare.hasHit('render-scale:down'), isFalse);
      expect(bare.hasHit('render-scale:up'), isFalse);
      expect(bare.hits.length, 5);
    });

    test('disabled 时轨道仍绘制但整行不注册命中（SettingsCard.cpp:127,136）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsRowLayout layout = placeSettingsRow(
              row: stepperRow(enabled: false), left: left, width: width, cursor: cursor)
          .layout;
      paintSettingsStepper(layout: layout, canvas: recorder, palette: darkPalette());
      expect(recorder.fills.length, 4);
      expect(recorder.hits, isEmpty);
      expect(recorder.textAt('75%')!.color, darkPalette().ink.fade(0.35));
    });

    test('actionPrefix 为空时命中回退到 binding.action（SettingsCard.cpp:27-30,131）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsStepper(
        layout: placeSettingsRow(
                row: stepperRow(actionPrefix: '', action: 'render-scale'), left: left, width: width, cursor: cursor)
            .layout,
        canvas: recorder,
        palette: darkPalette(),
      );
      expect(recorder.hasHit('render-scale75'), isTrue);
    });
  });

  group('Action / TextInput 控件（SettingsCard.cpp:148-175）', () {
    test('Action：fit 252、→ 在 right-24、命中 binding.action', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsPalette palette = darkPalette();
      final SettingsRowLayout layout =
          placeSettingsRow(row: actionRow(), left: left, width: width, cursor: cursor).layout;
      paintSettingsAction(layout: layout, canvas: recorder, palette: palette, fit: recorder.fitter);
      expectLastFit(recorder, '切换全屏 / F11', 15, 252, SettingsFontWeight.regular);
      expect(recorder.textAt('切换全屏 / F11')!.left, 980);
      expect(recorder.textAt('→')!.left, 1242);
      expect(recorder.textAt('→')!.top, 199);
      expect(recorder.textAt('→')!.size, 14);
      expect(recorder.hitAt('window:fullscreen')!.rect, Rect.fromLTWH(966, 185, 300, 48));
      expect(recorder.hitAt('window:fullscreen')!.label, '窗口显示');
    });

    test('Action disabled：无命中且颜色 fade', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsAction(
        layout: placeSettingsRow(row: actionRow(enabled: false), left: left, width: width, cursor: cursor)
            .layout,
        canvas: recorder,
        palette: darkPalette(),
      );
      expect(recorder.hits, isEmpty);
      expect(recorder.textAt('切换全屏 / F11')!.color, darkPalette().ink.fade(0.35));
      expect(recorder.textAt('→')!.color, darkPalette().muted.fade(0.3));
    });

    test('TextInput：✎ 图标、命中 setting-edit:<id>（SettingsCard.cpp:163-175）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsRowLayout layout =
          placeSettingsRow(row: textInputRow(), left: left, width: width, cursor: cursor).layout;
      paintSettingsTextInput(
          layout: layout, canvas: recorder, palette: darkPalette(), fit: recorder.fitter);
      expect(recorder.textAt('✎')!.left, 1242);
      expect(recorder.textAt('✎')!.top, 199);
      expect(recorder.hitAt('setting-edit:profile-name')!.rect, Rect.fromLTWH(966, 185, 300, 48));
      expect(recorder.hitAt('setting-edit:profile-name')!.label, '用户名称');
    });

    test('TextInput disabled：不注册编辑命中', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsTextInput(
        layout: placeSettingsRow(row: textInputRow(enabled: false), left: left, width: width, cursor: cursor)
            .layout,
        canvas: recorder,
        palette: darkPalette(),
      );
      expect(recorder.hits, isEmpty);
    });
  });

  group('Link 控件（SettingsCard.cpp:177-186）', () {
    test('用 bounds 全宽绘制，14pt 文本，箭头 13pt', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsPalette palette = darkPalette();
      final SettingsRowLayout layout =
          placeProjectLink(row: linkRow(), index: 0, left: left, width: width, cursor: cursor);
      paintSettingsLink(layout: layout, canvas: recorder, palette: palette, fit: recorder.fitter);
      expect(recorder.fills.first, SettingsFillOp(14, 176, 618, 50, palette.soft));
      expect(recorder.strokes.first, SettingsStrokeOp(Rect.fromLTWH(14, 176, 618, 50), palette.line));
      expectLastFit(recorder, '项目主页', 14, 618 - 40, SettingsFontWeight.regular);
      expect(recorder.textAt('项目主页')!.left, 26);
      expect(recorder.textAt('项目主页')!.top, 191);
      expect(recorder.textAt('项目主页')!.size, 14);
      expect(recorder.textAt('项目主页')!.color, palette.ink);
      expect(recorder.textAt('↗')!.left, 610);
      expect(recorder.textAt('↗')!.size, 13);
      expect(recorder.textAt('↗')!.color, palette.muted);
    });

    test('命中无条件注册（无 enabled 判断），label 是 actionLabel', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsLink(
        layout: placeProjectLink(row: linkRow(enabled: false), index: 0, left: left, width: width, cursor: cursor),
        canvas: recorder,
        palette: darkPalette(),
      );
      expect(recorder.hitAt('project:home')!.rect, Rect.fromLTWH(14, 176, 618, 50));
      expect(recorder.hitAt('project:home')!.label, '项目主页');
    });
  });

  group('Custom 行（SettingsCard.cpp:226-227）', () {
    test('只画 chrome，不注册任何控件命中', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsRow(
        layout: placeSettingsRow(row: customRow(), left: left, width: width, cursor: cursor).layout,
        index: 0,
        canvas: recorder,
        palette: darkPalette(),
        viewport: viewport,
      );
      expect(recorder.textAt('音乐来源'), isNotNull);
      expect(recorder.hits, isEmpty);
      expect(recorder.customs, isEmpty);
    });
  });

  group('行加选项时的可见性（SettingsCard.cpp:294-326）', () {
    test('行可见时整行绘制，选项只画一次', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsRowLayout layout = placeSettingsRow(
              row: choiceRow(expanded: true), left: left, width: width, cursor: cursor)
          .layout;
      paintSettingsRowLayer(
          layout: layout, index: 0, canvas: recorder, palette: darkPalette(), viewport: viewport);
      expect(recorder.fills.where((SettingsFillOp f) => f.width == 296).length, 0);
      expect(recorder.strokes.where((SettingsStrokeOp s) => s.rect.width == 300 && s.rect.top == 244).length,
          1);
      expect(recorder.hitAt('expand:close-behavior'), isNotNull);
      expect(recorder.hitAt('setting:close-behavior:quit'), isNotNull);
    });

    test('行滚出视口、选项仍在视口内时，只补画选项（SettingsCard.cpp:321-323）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsRowLayout layout = placeSettingsRow(
              row: choiceRow(expanded: true), left: left, width: width, cursor: cursor)
          .layout;
      const Rect scrolled = Rect.fromLTWH(0, 244, 1280, 660);
      paintSettingsRowLayer(
          layout: layout, index: 0, canvas: recorder, palette: darkPalette(), viewport: scrolled);
      expect(recorder.textAt('01'), isNull);
      expect(recorder.hitAt('expand:close-behavior'), isNull);
      expect(recorder.hitAt('setting:close-behavior:quit'), isNotNull);
    });

    test('行与选项都在视口外时什么都不画', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsRowLayout layout = placeSettingsRow(
              row: choiceRow(expanded: true), left: left, width: width, cursor: cursor)
          .layout;
      const Rect below = Rect.fromLTWH(0, 900, 1280, 660);
      paintSettingsRowLayer(
          layout: layout, index: 0, canvas: recorder, palette: darkPalette(), viewport: below);
      expect(recorder.ops, isEmpty);
      expect(recorder.hits, isEmpty);
    });

    test('展开但 disabled 时选项不画（SettingsCard.cpp:230）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsRowLayout layout = placeSettingsRow(
              row: choiceRow(expanded: true, enabled: false), left: left, width: width, cursor: cursor)
          .layout;
      paintSettingsRowLayer(
          layout: layout, index: 0, canvas: recorder, palette: darkPalette(), viewport: viewport);
      expect(recorder.hitAt('setting:close-behavior:quit'), isNull);
    });
  });

  group('命中裁剪（HudScroll.h:67-86）', () {
    test('部分重叠裁剪成交集，完全在内原样保留', () {
      final List<SettingsHitRegion> regions = <SettingsHitRegion>[
        const SettingsHitRegion(Rect.fromLTWH(0, 100, 100, 50), 'a', 'A'),
        const SettingsHitRegion(Rect.fromLTWH(10, 180, 20, 20), 'b', 'B'),
      ];
      final List<SettingsHitRegion> clipped =
          clipSettingsHits(regions, const Rect.fromLTWH(0, 120, 1280, 660));
      expect(clipped.length, 2);
      expect(clipped[0].rect, const Rect.fromLTWH(0, 120, 100, 30));
      expect(clipped[0].action, 'a');
      expect(clipped[1].rect, const Rect.fromLTWH(10, 180, 20, 20));
    });

    test('完全在外或被压成 0 宽高的命中被丢弃', () {
      final List<SettingsHitRegion> regions = <SettingsHitRegion>[
        const SettingsHitRegion(Rect.fromLTWH(0, 10, 100, 50), 'above', 'A'),
        const SettingsHitRegion(Rect.fromLTWH(0, 120, 100, 0), 'flat', 'F'),
        const SettingsHitRegion(Rect.fromLTWH(0, 120, 0, 50), 'thin', 'T'),
      ];
      expect(clipSettingsHits(regions, const Rect.fromLTWH(0, 120, 1280, 660)), isEmpty);
    });

    test('first 之前的命中原样保留：既不裁剪也不丢弃（HudScroll.h:71-82）', () {
      final List<SettingsHitRegion> regions = <SettingsHitRegion>[
        const SettingsHitRegion(Rect.fromLTWH(0, 10, 100, 50), 'earlier-layer', 'E'),
        const SettingsHitRegion(Rect.fromLTWH(0, 10, 100, 50), 'this-layer', 'R'),
      ];
      // 两条都在裁剪区之外：first=1 时第 0 条原样留下，第 1 条被丢掉。
      final List<SettingsHitRegion> clipped =
          clipSettingsHits(regions, const Rect.fromLTWH(0, 120, 1280, 660), first: 1);
      expect(clipped.length, 1);
      expect(clipped[0].rect, const Rect.fromLTWH(0, 10, 100, 50));
      expect(clipped[0].action, 'earlier-layer');
      // first 缺省为 0 时两条都参与裁剪 → 全丢。
      expect(clipSettingsHits(regions, const Rect.fromLTWH(0, 120, 1280, 660)), isEmpty);
    });
  });

  group('展开项（NativeHudController.cpp:774-780）', () {
    test('再点同一行折叠，点别的行换成那一行', () {
      expect(toggleExpandedPreference('', 'theme'), 'theme');
      expect(toggleExpandedPreference('theme', 'theme'), '');
      expect(toggleExpandedPreference('theme', 'vsync'), 'vsync');
      expect(toggleExpandedPreference('', ''), '');
    });

    test('expanded 由 expandedPreference 与行 id 相等决定', () {
      expect(settingsRowExpanded('theme', 'theme'), isTrue);
      expect(settingsRowExpanded('theme', 'vsync'), isFalse);
      expect(settingsRowExpanded('', 'theme'), isFalse);
    });
  });

  group('编辑浮层状态机（NativeHudSettings.cpp:109-161）', () {
    final SettingsRowLayout laidOut =
        placeSettingsRow(row: textInputRow(), left: left, width: width, cursor: cursor).layout;

    test('descriptor 不存在或 kind 不是 TextInput 时状态不动', () {
      const SettingsEditState idle = SettingsEditState();
      expect(
          beginSettingEdit(
              state: idle, id: 'x', descriptor: null, laidOut: laidOut, scroll: 0),
          idle);
      expect(
          beginSettingEdit(
              state: idle,
              id: 'close-behavior',
              descriptor: choiceRow(),
              laidOut: laidOut,
              scroll: 0),
          idle);
    });

    test('layout 里找不到该行（未布局或 disabled）时状态不动', () {
      const SettingsEditState idle = SettingsEditState();
      expect(
          beginSettingEdit(
              state: idle, id: 'profile-name', descriptor: textInputRow(), laidOut: null, scroll: 0),
          idle);
      expect(
          beginSettingEdit(
              state: idle,
              id: 'other',
              descriptor: textInputRow(),
              laidOut: laidOut,
              scroll: 0),
          idle);
    });

    test('成功时取 canonical 文本，控件矩形按 scroll 上移', () {
      final SettingsEditState opened = beginSettingEdit(
        state: const SettingsEditState(),
        id: 'profile-name',
        descriptor: textInputRow(),
        laidOut: laidOut,
        scroll: 40,
      );
      expect(opened.isActive, isTrue);
      expect(opened.settingId, 'profile-name');
      expect(opened.text, '默认');
      expect(opened.rect, Rect.fromLTWH(966, 145, 300, 48));
    });

    test('setSettingEditText 只在激活时生效', () {
      const SettingsEditState idle = SettingsEditState();
      expect(setSettingEditText(idle, 'abc'), idle);
      final SettingsEditState opened = setSettingEditText(
          const SettingsEditState(settingId: 'profile-name', text: '默认'), '新名字');
      expect(opened.text, '新名字');
      expect(opened.settingId, 'profile-name');
    });

    test('空提交不产生值，状态原样返回', () {
      const SettingsEditState idle = SettingsEditState();
      final SettingsEditCommit commit = commitSettingEdit(idle);
      expect(commit.hasValue, isFalse);
      expect(commit.id, isNull);
      expect(commit.next, idle);
    });

    test('提交先清空状态再交出 id/text', () {
      const SettingsEditState opened =
          SettingsEditState(settingId: 'profile-name', text: '新名字', rect: Rect.fromLTWH(1, 2, 3, 4));
      final SettingsEditCommit commit = commitSettingEdit(opened);
      expect(commit.hasValue, isTrue);
      expect(commit.id, 'profile-name');
      expect(commit.text, '新名字');
      expect(commit.next.isActive, isFalse);
      expect(commit.next.text, '');
      expect(commit.next.rect, Rect.zero);
    });

    test('取消只清状态，不写值', () {
      const SettingsEditState opened = SettingsEditState(settingId: 'profile-name', text: '新名字');
      final SettingsEditState cancelled = cancelSettingEdit(opened);
      expect(cancelled.isActive, isFalse);
      expect(cancelled.text, '');
      const SettingsEditState idle = SettingsEditState();
      expect(cancelSettingEdit(idle), idle);
    });

    test('派发规则：非 setting-edit 动作先取消编辑（NativeHudController.cpp:396-402）', () {
      expect(settingsActionCancelsEdit('profile-name', 'menu'), isTrue);
      expect(settingsActionCancelsEdit('profile-name', 'setting-edit:other'), isFalse);
      expect(settingsActionCancelsEdit('', 'menu'), isFalse);
      expect(settingsEditIdFromAction('setting-edit:profile-name'), 'profile-name');
    });

    test('滚轮在编辑中先取消编辑（NativeHudInput.cpp:23-26）', () {
      expect(settingsWheelCancelsEdit('profile-name'), isTrue);
      expect(settingsWheelCancelsEdit(''), isFalse);
    });
  });

  group('提交分类与失败语义（NativeHudSettings.cpp:382-490）', () {
    SettingsApplyPlan plan(SettingsRowSpec? descriptor, String target, String current,
            {bool isDarwin = false}) =>
        planSettingsApply(
            descriptor: descriptor, target: target, currentCanonical: current, isDarwin: isDarwin);

    test('descriptor 不存在 → unknownDescriptor，什么都不做', () {
      final SettingsApplyPlan p = plan(null, 'x', 'y');
      expect(p.outcome, SettingsCommitOutcome.unknownDescriptor);
      expect(p.preferenceKey, isNull);
      expect(p.action, isNull);
    });

    test('目标值与当前 canonical 相同 → unchanged，不写也不派发', () {
      final SettingsApplyPlan p = plan(choiceRow(), 'ask', 'ask');
      expect(p.outcome, SettingsCommitOutcome.unchanged);
      expect(p.preferenceKey, isNull);
      expect(p.action, isNull);
    });

    test('theme 写偏好并更新场景主题（:394-404）', () {
      final SettingsApplyPlan p = plan(choiceRow(id: 'theme'), 'dark', 'light');
      expect(p.outcome, SettingsCommitOutcome.applied);
      expect(p.preferenceKey, 'theme');
      expect(p.updatesSceneTheme, isTrue);
      expect(p.action, isNull);
    });

    test('graphics-backend 只写偏好，不动场景（:405-409）', () {
      final SettingsApplyPlan p = plan(choiceRow(id: 'graphics-backend'), 'vulkan', 'auto');
      expect(p.outcome, SettingsCommitOutcome.applied);
      expect(p.preferenceKey, 'graphics-backend');
      expect(p.updatesSceneTheme, isFalse);
    });

    test('fg 只在 Darwin 生效，Android/Windows/Linux 整段被编译掉：静默 no-op（:443-448）', () {
      final SettingsApplyPlan android = plan(choiceRow(id: 'fg'), 'on', 'off');
      expect(android.outcome, SettingsCommitOutcome.platformNoop);
      expect(android.preferenceKey, isNull);
      expect(android.action, isNull);

      // Qt 用 #ifdef Q_OS_DARWIN：Windows/Linux 与 Android 一样是 no-op，不是「非 Android 即生效」。
      final SettingsApplyPlan linux = plan(choiceRow(id: 'fg'), 'on', 'off');
      expect(linux.outcome, SettingsCommitOutcome.platformNoop);

      final SettingsApplyPlan mac = plan(choiceRow(id: 'fg'), 'on', 'off', isDarwin: true);
      expect(mac.outcome, SettingsCommitOutcome.applied);
      expect(mac.preferenceKey, 'fg');
    });

    test('二元项与旧动作同名（:410-438）', () {
      for (final String id in <String>[
        'motion',
        'startup-animation',
        'vsync',
        'detail-autoplay',
        'single-play-mode',
        'close-behavior',
        'alternative',
      ]) {
        final SettingsApplyPlan p = plan(choiceRow(id: id), 'on', 'off');
        expect(p.outcome, SettingsCommitOutcome.applied);
        expect(p.action, id);
        expect(p.preferenceKey, isNull);
      }
    });

    test('official-player 派发 music:activate（:439-442）', () {
      final SettingsApplyPlan p = plan(choiceRow(id: 'official-player'), 'on', 'off');
      expect(p.action, 'music:activate');
    });

    test('带目标值的特例动作串（:449-484）', () {
      expect(plan(choiceRow(id: 'archive-mask'), '50', '0').action, 'archive-mask:50');
      expect(plan(choiceRow(id: 'render-scale'), '75', '100').action, 'render-scale:75');
      expect(plan(choiceRow(id: 'aa-mode'), 'fxaa', 'off').action, 'aa-mode:fxaa');
      expect(plan(choiceRow(id: 'aa-scale'), '2', '1').action, 'aa-scale:2');
      expect(plan(choiceRow(id: 'msaa'), '4', '0').action, 'msaa:4');
      expect(plan(choiceRow(id: 'fsr-quality'), 'quality', 'off').action, 'fsr-quality:quality');
      expect(plan(choiceRow(id: 'fsr-sharpness'), '0.5', '0').action, 'fsr-sharpness:0.5');
      expect(plan(choiceRow(id: 'gpu-index'), '1', '0').action, 'gpu-index:1');
      expect(plan(choiceRow(id: 'quality'), 'high', 'low').action, 'quality:set:high');
    });

    test('普通 Preference 行走通用写入（:486-489）', () {
      // 通用分支写的是 descriptor->binding.preferenceKey（Qt 侧 :487），
      // 所以这里的行必须真的带上自己的偏好键。
      final SettingsRowSpec row =
          choiceRow(id: 'language', actionPrefix: 'language:').copyWith(preferenceKey: 'language');
      final SettingsApplyPlan p = plan(row, 'zh', 'en');
      expect(p.outcome, SettingsCommitOutcome.applied);
      expect(p.preferenceKey, 'language');
      expect(p.action, isNull);
    });

    test('非 Preference 且无特例 → unbound，落到函数末尾什么都不做（:486-489）', () {
      final SettingsApplyPlan p = plan(linkRow(), 'open', 'closed');
      expect(p.outcome, SettingsCommitOutcome.unbound);
      expect(p.preferenceKey, isNull);
      expect(p.action, isNull);
    });

    test('Qt 没有保存失败 UI：唯一瞬时文案是 Storage 的成功文案，失败分类不带文本', () {
      expect(storageCacheActionLabel(''), '清除缓存');
      expect(storageCacheActionLabel('已清除'), '已清除');
      expect(storageCacheHitLabel, '清除缓存');
      final SettingsApplyPlan p = plan(null, 'x', 'y');
      expect(p.outcome, SettingsCommitOutcome.unknownDescriptor);
      expect(p.preferenceKey, isNull);
      expect(p.action, isNull);
    });
  });
}
