/// T34-S03-M12 查看器 HUD（lib/hud/pages/viewer_hud.dart）的独立单元测试。
///
/// 期望值全部对着 Qt 真值写，不引用本页的内部符号：
/// - Qt/src/NativeHudDetail.cpp:513-529  viewer() 的 11 条 text 与 6 条 hit（顺序即语义）
/// - Qt/src/NativeHudDetail.cpp:514-516  空 current 早退（零命令零命中）
/// - Qt/src/NativeHud.cpp:10-15         ink() 的 calibrated 五元色
/// - Qt/src/NativeHud.cpp:40-43         text 命令八字段
/// - Qt/src/NativeHud.cpp:48-79         fit() 的二分截断与 "…" 规则
/// - Qt/src/NativeHud.cpp:102-109       hit 六字段
/// - Qt/src/NativeHud.cpp:110-120       button = hit + text(x, y + (h - size) / 2 - 4)
/// - Qt/src/NativeViewer.cpp:108-130    action() 的 scene 仲裁（close 不受 ready 限制，其余受限）
///
/// 本任务禁止执行任何构建 / 测试 / 分析命令，因此本文件的 RED/GREEN 均为"未执行"，
/// 只作为待执行的源码证据提交（报告里记录 validationExecuted=false）。
/// 任务书写的是 package:test，但仓库 dev_dependencies 实际只有 flutter_test，
/// 按父裁决 B 统一使用 package:flutter_test（不改 pubspec、不加依赖）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/pages/viewer_hud.dart';

/// 字形端口替身：等宽近似，字符宽 = size * charWidth + tracking。
class _FakeGlyphs implements ViewerHudGlyphsPort {
  const _FakeGlyphs() : charWidth = 0.5;
  final double charWidth;

  @override
  double width(String value, double size, String weight, [double tracking = 0]) =>
      value.length * size * charWidth + value.length * tracking;
}

const _FakeGlyphs _glyphs = _FakeGlyphs();

const ViewerHudItem _item = ViewerHudItem(id: 'netease:42', title: '测试歌曲');

ViewerHudState _state({
  ViewerHudItem? item = _item,
  bool dark = false,
  String transition = viewerHudTransitionOpen,
  String surface = viewerHudSurfaceClear,
  double clarity = 1.0,
  double targetClarity = 1.0,
  bool resetting = false,
  bool ready = true,
}) =>
    ViewerHudState(
      item: item,
      dark: dark,
      transition: transition,
      surface: surface,
      clarity: clarity,
      targetClarity: targetClarity,
      resetting: resetting,
      ready: ready,
    );

ViewerHudDrawing _render(ViewerHudState state, [double width = 1080]) =>
    renderViewerHud(state, width, glyphs: _glyphs);

List<List<Object?>> _byOp(List<Object?> commands, String op) => commands
    .whereType<List<Object?>>()
    .where((List<Object?> command) => command.isNotEmpty && command.first == op)
    .toList();

List<List<Object?>> _texts(List<Object?> commands) => _byOp(commands, 'text');

Map<String, Object?> _hit(ViewerHudDrawing drawing, int index) => drawing.hits[index];

/// 等宽字符重复（Dart 的 String 没有 * 运算符）。
String _repeat(String unit, int count) => List<String>.filled(count, unit).join();

/// 逐元素比较颜色列表（QJsonArray 的五元组）。
void _expectColor(Object? actual, List<Object?> expected) {
  expect(actual, isA<List<Object?>>());
  final List<Object?> list = actual! as List<Object?>;
  expect(list.length, expected.length);
  for (int i = 0; i < expected.length; i++) {
    expect(list[i], expected[i], reason: '颜色第 $i 项');
  }
}

/// 一条 text 命令的八字段断言。
void _expectText(
  List<Object?> command, {
  required String value,
  required double x,
  required double y,
  required double size,
  required String weight,
  double tracking = 0,
  required bool dark,
}) {
  expect(command.length, 8);
  expect(command[0], 'text');
  expect(command[1], value);
  expect(command[2], x);
  expect(command[3], y);
  expect(command[4], size);
  expect(command[5], weight);
  expect(command[6], tracking);
  _expectColor(command[7], dark
      ? <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite']
      : <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB']);
}

/// 一条 hit 的六字段断言（绝不带 fixed）。
void _expectHit(
  Map<String, Object?> hit, {
  required double x,
  required double y,
  required double width,
  required double height,
  required String action,
  required String label,
}) {
  expect(hit.keys.toList(), <String>['x', 'y', 'width', 'height', 'action', 'label']);
  expect(hit['x'], x);
  expect(hit['y'], y);
  expect(hit['width'], width);
  expect(hit['height'], height);
  expect(hit['action'], action);
  expect(hit['label'], label);
}

void main() {
  group('空 current：NativeHudDetail.cpp:514-516', () {
    test('item 为 null 时零命令零命中', () {
      final ViewerHudDrawing drawing = _render(_state(item: null));
      expect(drawing.commands, isEmpty);
      expect(drawing.hits, isEmpty);
      expect(drawing.isEmpty, isTrue);
    });

    test('空 item 与空串 title/id 不同：空串仍然绘制 11 条', () {
      final ViewerHudDrawing drawing =
          _render(_state(item: const ViewerHudItem()));
      expect(drawing.commands.length, 11);
      expect(drawing.hits.length, 6);
      expect(_texts(drawing.commands)[2][1], ' / 封面');
    });
  });

  group('1080 宽度的固定命中（NativeHudDetail.cpp:518-528）', () {
    late ViewerHudDrawing drawing;
    setUp(() => drawing = _render(_state()));

    test('命中 6 条、顺序与 Qt 调用顺序一致', () {
      expect(drawing.hits.length, 6);
      expect(drawing.hits.map((Map<String, Object?> hit) => hit['action']).toList(), <String>[
        'viewer:close',
        'viewer:clear',
        'viewer:frosted',
        'viewer:reset',
        'music:cover-front',
        'viewer:reset',
      ]);
    });

    test('关闭按钮 rect(59,69,300,54) action viewer:close', () {
      _expectHit(_hit(drawing, 0),
          x: 59,
          y: 69,
          width: 300,
          height: 54,
          action: 'viewer:close',
          label: '← 返回音乐   ESC');
    });

    test('清晰 rect(833,189,84,38) / 磨砂 rect(933,189,84,38)', () {
      _expectHit(_hit(drawing, 1),
          x: 833, y: 189, width: 84, height: 38, action: 'viewer:clear', label: '清晰');
      _expectHit(_hit(drawing, 2),
          x: 933, y: 189, width: 84, height: 38, action: 'viewer:frosted', label: '磨砂');
    });

    test('原始视角 rect(375,914,154,46) / 封面正面 rect(558,914,154,46)', () {
      _expectHit(_hit(drawing, 3),
          x: 375, y: 914, width: 154, height: 46, action: 'viewer:reset', label: '原始视角');
      _expectHit(_hit(drawing, 4),
          x: 558, y: 914, width: 154, height: 46, action: 'music:cover-front', label: '封面正面');
    });

    test('复位视角 rect(886,914,135,46) 复用 viewer:reset', () {
      _expectHit(_hit(drawing, 5),
          x: 886, y: 914, width: 135, height: 46, action: 'viewer:reset', label: '复位视角 ↗');
      expect(drawing.hits.where((Map<String, Object?> hit) => hit['action'] == 'viewer:reset').length, 2);
    });

    test('所有命中都落在 1080x1080 舞台内', () {
      for (final Map<String, Object?> hit in drawing.hits) {
        final double x = hit['x']! as double;
        final double y = hit['y']! as double;
        final double w = hit['width']! as double;
        final double h = hit['height']! as double;
        expect(x, greaterThanOrEqualTo(0));
        expect(x + w, lessThanOrEqualTo(1080));
        expect(y, greaterThanOrEqualTo(0));
        expect(y + h, lessThanOrEqualTo(1080));
      }
    });
  });

  group('1728 宽度的固定命中（同一 Qt 公式，width 变化）', () {
    late ViewerHudDrawing drawing;
    setUp(() => drawing = _render(_state(), 1728));

    test('关闭按钮不随宽度移动：rect(59,69,300,54)', () {
      _expectHit(_hit(drawing, 0),
          x: 59, y: 69, width: 300, height: 54, action: 'viewer:close', label: '← 返回音乐   ESC');
    });

    test('清晰 rect(1481,189,84,38) / 磨砂 rect(1581,189,84,38)', () {
      _expectHit(_hit(drawing, 1),
          x: 1481, y: 189, width: 84, height: 38, action: 'viewer:clear', label: '清晰');
      _expectHit(_hit(drawing, 2),
          x: 1581, y: 189, width: 84, height: 38, action: 'viewer:frosted', label: '磨砂');
    });

    test('原始视角 rect(699,914,154,46) / 封面正面 rect(882,914,154,46)', () {
      _expectHit(_hit(drawing, 3),
          x: 699, y: 914, width: 154, height: 46, action: 'viewer:reset', label: '原始视角');
      _expectHit(_hit(drawing, 4),
          x: 882, y: 914, width: 154, height: 46, action: 'music:cover-front', label: '封面正面');
    });

    test('复位视角 rect(1534,914,135,46)', () {
      _expectHit(_hit(drawing, 5),
          x: 1534, y: 914, width: 135, height: 46, action: 'viewer:reset', label: '复位视角 ↗');
    });

    test('所有命中都落在 1728x1080 舞台内', () {
      for (final Map<String, Object?> hit in drawing.hits) {
        final double x = hit['x']! as double;
        final double y = hit['y']! as double;
        final double w = hit['width']! as double;
        final double h = hit['height']! as double;
        expect(x, greaterThanOrEqualTo(0));
        expect(x + w, lessThanOrEqualTo(1728));
        expect(y, greaterThanOrEqualTo(0));
        expect(y + h, lessThanOrEqualTo(1080));
      }
    });
  });

  group('1080 宽度的文本命令（NativeHudDetail.cpp:518-528）', () {
    late List<List<Object?>> texts;
    setUp(() => texts = _texts(_render(_state()).commands));

    test('命令总数 11，全部是 text', () {
      expect(texts.length, 11);
    });

    test('关闭按钮文案 y = 69 + (54-20)/2 - 4 = 82', () {
      _expectText(texts[0],
          value: '← 返回音乐   ESC', x: 59, y: 82, size: 20, weight: 'demibold', dark: false);
    });

    test('顶部标题 tracking 1.5，位于宽/2-145, 70, 11 号 regular', () {
      _expectText(texts[1],
          value: 'RHINE LAB / MUSIC DATABASE / COVER',
          x: 395,
          y: 70,
          size: 11,
          weight: 'regular',
          tracking: 1.5,
          dark: false);
    });

    test('曲名 + " / 封面"，宽/2-145, 95, 28 号 demibold', () {
      _expectText(texts[2],
          value: '测试歌曲 / 封面', x: 395, y: 95, size: 28, weight: 'demibold', dark: false);
    });

    test('item id 位于宽/2-145, 139, 12 号 regular', () {
      _expectText(texts[3],
          value: 'netease:42', x: 395, y: 139, size: 12, weight: 'regular', dark: false);
    });

    test('"360°" 位于宽-185, 72, 55 号 light', () {
      _expectText(texts[4], value: '360°', x: 895, y: 72, size: 55, weight: 'light', dark: false);
    });

    test('清晰 / 磨砂文字 y = 189 + (38-14)/2 - 4 = 197，14 号 regular', () {
      _expectText(texts[5], value: '清晰', x: 833, y: 197, size: 14, weight: 'regular', dark: false);
      _expectText(texts[6], value: '磨砂', x: 933, y: 197, size: 14, weight: 'regular', dark: false);
    });

    test('底部提示位于 59, 965, 13 号 regular', () {
      _expectText(texts[7],
          value: '拖动旋转     ↑ ↓ ← → 平移     滚轮缩放',
          x: 59,
          y: 965,
          size: 13,
          weight: 'regular',
          dark: false);
    });

    test('原始视角 / 封面正面 y = 914 + (46-15)/2 - 4 = 925.5，15 号 regular', () {
      _expectText(texts[8], value: '原始视角', x: 375, y: 925.5, size: 15, weight: 'regular', dark: false);
      _expectText(texts[9], value: '封面正面', x: 558, y: 925.5, size: 15, weight: 'regular', dark: false);
    });

    test('复位视角 y = 914 + (46-14)/2 - 4 = 926，14 号 regular', () {
      _expectText(texts[10],
          value: '复位视角 ↗', x: 886, y: 926, size: 14, weight: 'regular', dark: false);
    });

    test('按钮文字与同名命中同源（label 即 text）', () {
      expect(texts[0][1], _hit(_render(_state()), 0)['label']);
      for (int i = 1; i <= 2; i++) {
        expect(texts[4 + i][1], _hit(_render(_state()), i)['label']);
      }
      expect(texts[8][1], _hit(_render(_state()), 3)['label']);
      expect(texts[9][1], _hit(_render(_state()), 4)['label']);
      expect(texts[10][1], _hit(_render(_state()), 5)['label']);
    });
  });

  group('1728 宽度的文本命令', () {
    late List<List<Object?>> texts;
    setUp(() => texts = _texts(_render(_state(), 1728).commands));

    test('居中列随宽/2 移动：heading/title/id 的 x = 719', () {
      expect(texts[1][2], 719);
      expect(texts[2][2], 719);
      expect(texts[3][2], 719);
    });

    test('"360°" x = 1728-185 = 1543', () {
      expect(texts[4][2], 1543);
    });

    test('清晰 x = 1481、磨砂 x = 1581', () {
      expect(texts[5][2], 1481);
      expect(texts[6][2], 1581);
    });

    test('原始视角 x = 699、封面正面 x = 882、复位视角 x = 1534', () {
      expect(texts[8][2], 699);
      expect(texts[9][2], 882);
      expect(texts[10][2], 1534);
    });

    test('固定左缘与底部提示不随宽度变化', () {
      expect(texts[0][2], 59);
      expect(texts[7][2], 59);
      expect(texts[7][3], 965);
    });
  });

  group('标题限宽：NativeHud.cpp:48-79 fit()', () {
    test('1080 时限宽 290：等宽 14px/字符，20 字符为上限', () {
      // size 28 * charWidth 0.5 = 14；290 / 14 = 20.71 => 20 字符可容纳。
      expect(const ViewerHudGeometry(1080).titleLimit, 290);
      final String title = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
      final List<Object?> command = _texts(_render(_state(item: ViewerHudItem(id: '1', title: title))).commands)[2];
      // 完整串 = 26 + " / 封面"(5) = 31 字符；截到 20 后再砍 1 位并加 "…"。
      expect(command[1], '${title.substring(0, 19)}…');
    });

    test('1728 时限宽 614：43 字符可容纳，不截断', () {
      expect(const ViewerHudGeometry(1728).titleLimit, 614);
      final String title = _repeat('A', 30); // 30 + 5 = 35 字符 * 14 = 490 <= 614
      final List<Object?> command = _texts(_render(_state(item: ViewerHudItem(id: '1', title: title)), 1728).commands)[2];
      expect(command[1], '$title / 封面');
    });

    test('截断阈值边界：恰好 20 字符的完整串不截断', () {
      // 15 + 5 = 20 字符 * 14 = 280 <= 290。
      final String title = _repeat('A', 15);
      final List<Object?> command = _texts(_render(_state(item: ViewerHudItem(id: '1', title: title))).commands)[2];
      expect(command[1], '$title / 封面');
    });

    test('限宽与 tracking 无关：limited 不带 tracking', () {
      final List<Object?> command = _texts(_render(_state()).commands)[2];
      expect(command[6], 0);
    });
  });

  group('颜色：NativeHud.cpp:10-15 ink()', () {
    test('浅色主题每条 text 都是 calibratedRGB', () {
      for (final List<Object?> command in _texts(_render(_state()).commands)) {
        _expectColor(command[7], <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB']);
      }
    });

    test('深色主题每条 text 都是 calibratedWhite', () {
      for (final List<Object?> command in _texts(_render(_state(dark: true)).commands)) {
        _expectColor(command[7], <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite']);
      }
    });
  });

  group('命令形态：viewer 页没有 save/alpha/fill/rule/image', () {
    test('11 text + 0 其它 op', () {
      final ViewerHudDrawing drawing = _render(_state());
      expect(drawing.commands.length, 11);
      expect(drawing.commands.every((Object? command) =>
          command is List<Object?> && command.isNotEmpty && command.first == 'text'), isTrue);
    });

    test('命令顺序与 Qt 调用顺序一致', () {
      final List<Object?> values =
          _texts(_render(_state()).commands).map((List<Object?> command) => command[1]).toList();
      expect(values, <Object?>[
        '← 返回音乐   ESC',
        'RHINE LAB / MUSIC DATABASE / COVER',
        '测试歌曲 / 封面',
        'netease:42',
        '360°',
        '清晰',
        '磨砂',
        '拖动旋转     ↑ ↓ ← → 平移     滚轮缩放',
        '原始视角',
        '封面正面',
        '复位视角 ↗',
      ]);
    });

    test('没有任何 3D 贴图 / 场景命令泄漏进 HUD 流', () {
      final ViewerHudDrawing drawing = _render(_state());
      final Set<Object?> ops = drawing.commands
          .whereType<List<Object?>>()
          .map((List<Object?> command) => command.first)
          .toSet();
      expect(ops, <Object?>{'text'});
      expect(viewerHudChannel, 'hud-stage');
    });
  });

  group('状态字段：viewerState 不参与绘制（NativeViewer.cpp:349-353）', () {
    test('opening / closing / open / closed 判定', () {
      expect(_state(transition: viewerHudTransitionOpening).opening, isTrue);
      expect(_state(transition: viewerHudTransitionOpening).closing, isFalse);
      expect(_state(transition: viewerHudTransitionOpening).isOpen, isTrue);
      expect(_state(transition: viewerHudTransitionOpen).opening, isFalse);
      expect(_state(transition: viewerHudTransitionClosing).closing, isTrue);
      expect(_state(transition: viewerHudTransitionClosing).isOpen, isTrue,
          reason: 'closing 期间 m_open 仍为 true（NativeViewer.cpp:115, 215）');
      expect(_state(transition: viewerHudTransitionClosed).isOpen, isFalse);
      expect(_state(transition: viewerHudTransitionClosed).closing, isFalse);
    });

    test('reset ≡ resetting', () {
      expect(_state(resetting: true).reset, isTrue);
      expect(_state(resetting: false).reset, isFalse);
    });

    test('frosted / clear 判定与 targetClarity 默认值', () {
      expect(_state(surface: viewerHudSurfaceFrosted).frosted, isTrue);
      expect(_state(surface: viewerHudSurfaceFrosted).clear, isFalse);
      expect(_state(surface: viewerHudSurfaceClear).clear, isTrue);
      expect(const ViewerHudState().targetClarity, 1.0);
      expect(const ViewerHudState().clarity, 1.0);
      expect(const ViewerHudState().surface, 'clear');
      expect(const ViewerHudState().transition, 'closed');
      expect(const ViewerHudState().ready, isFalse);
    });

    test('closeAction 指向 viewer:close', () {
      expect(const ViewerHudState().closeAction, 'viewer:close');
      expect(viewerHudCloseAction, 'viewer:close');
    });

    test('任何 transition / surface / clarity 组合下输出完全相同', () {
      final ViewerHudDrawing base = _render(_state());
      final List<ViewerHudState> variants = <ViewerHudState>[
        _state(transition: viewerHudTransitionOpening, ready: false),
        _state(transition: viewerHudTransitionClosing),
        _state(transition: viewerHudTransitionClosed, ready: false),
        _state(surface: viewerHudSurfaceFrosted, clarity: 0.37, targetClarity: 0.0),
        _state(surface: viewerHudSurfaceClear, clarity: 0.98, targetClarity: 1),
        _state(resetting: true),
      ];
      for (final ViewerHudState variant in variants) {
        final ViewerHudDrawing drawing = _render(variant);
        expect(drawing.commands, base.commands, reason: '$variant');
        expect(drawing.hits, base.hits, reason: '$variant');
      }
    });
  });

  group('viewer:* 动作仲裁：NativeViewer.cpp:108-130', () {
    test('closed 状态下 close 也被拒绝', () {
      expect(viewerHudActionAccepted(_state(transition: viewerHudTransitionClosed), 'viewer:close'),
          isFalse);
    });

    test('closing 状态下所有 viewer 动作被拒绝', () {
      final ViewerHudState closing = _state(transition: viewerHudTransitionClosing);
      expect(viewerHudActionAccepted(closing, 'viewer:close'), isFalse);
      expect(viewerHudActionAccepted(closing, 'viewer:clear'), isFalse);
      expect(viewerHudActionAccepted(closing, 'viewer:frosted'), isFalse);
      expect(viewerHudActionAccepted(closing, 'viewer:reset'), isFalse);
    });

    test('opening 且未 ready：close 可接受，clear/frosted/reset 被拒绝', () {
      final ViewerHudState opening = _state(transition: viewerHudTransitionOpening, ready: false);
      expect(viewerHudActionAccepted(opening, 'viewer:close'), isTrue);
      expect(viewerHudActionAccepted(opening, 'viewer:clear'), isFalse);
      expect(viewerHudActionAccepted(opening, 'viewer:frosted'), isFalse);
      expect(viewerHudActionAccepted(opening, 'viewer:reset'), isFalse);
    });

    test('open 且 ready：clear/frosted/reset 均接受', () {
      final ViewerHudState open = _state();
      expect(viewerHudActionAccepted(open, 'viewer:clear'), isTrue);
      expect(viewerHudActionAccepted(open, 'viewer:frosted'), isTrue);
      expect(viewerHudActionAccepted(open, 'viewer:reset'), isTrue);
    });

    test('music:cover-front 不经过 NativeViewer::action，不在本仲裁范围内', () {
      expect(viewerHudActionAccepted(_state(), 'music:cover-front'), isFalse);
      expect(viewerHudActionAccepted(_state(ready: false), 'music:cover-front'), isFalse);
    });
  });

  group('几何对象：ViewerHudGeometry', () {
    test('1080 的派生值', () {
      const ViewerHudGeometry g = ViewerHudGeometry(1080);
      expect(g.center, 540);
      expect(g.headingX, 395);
      expect(g.headingY, 70);
      expect(g.titleLimit, 290);
      expect(g.degreeX, 895);
      expect(g.clear, isA<ViewerHudRect>());
      expect(g.close.top, 69);
      expect(g.reset.left, 375);
      expect(g.coverFront.left, 558);
      expect(g.resetCorner.right, 1021);
    });

    test('hit 与 geometry 同源（1080 / 1728）', () {
      for (final double width in <double>[1080, 1728]) {
        final ViewerHudDrawing drawing = _render(_state(), width);
        final ViewerHudGeometry g = ViewerHudGeometry(width);
        _expectHit(_hit(drawing, 0),
            x: g.close.x, y: g.close.y, width: g.close.width, height: g.close.height,
            action: 'viewer:close', label: '← 返回音乐   ESC');
        _expectHit(_hit(drawing, 5),
            x: g.resetCorner.x, y: g.resetCorner.y,
            width: g.resetCorner.width, height: g.resetCorner.height,
            action: 'viewer:reset', label: '复位视角 ↗');
      }
    });
  });
}
