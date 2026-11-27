/// T34-S01-M12-W3 动作行（lib/hud/widgets/action_row.dart）的独立单元测试。
///
/// 断言全部对着 Qt 真值写：
/// - Qt/src/SongDetailCard.cpp:17-46    actions()：gap/height/width/跳格/实心/四边框/hit/text
/// - Qt/src/SongDetailCard.cpp:69-70    476 primary / 532 secondary 两次调用
/// - Qt/src/NativeHudDetail.cpp:56-62    x=width*0.56、usable=width-x-59、buttonWidth
/// - Qt/src/NativeHudDetail.cpp:142-148  调用方 fit(label, 14, buttonWidth-24, weight)
/// - Qt/src/NativeHudDetail.cpp:203-213  官方客户端/试听片段/从歌单移除 三列（y=910,h=44,size=13）
/// - Qt/src/NativeHud.cpp:10-15/37-43/48-76/102-129  ink/fill/text/fit/hit/button/rule
///
/// 本任务禁止执行任何构建或测试命令，因此本文件的 RED/GREEN 均为“未执行”，
/// 只作为待执行的源码证据提交（报告里记录 validationExecuted=false）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/widgets/action_row.dart';

/// 等宽字形替身：宽度 = UTF-16 code unit 数 * size * charWidth。
///
/// Qt 的 Glyphs::width 同样按 code unit 计长（QString::left 切的是 code unit），
/// 所以这里用 value.length 而不是 runes.length，才能覆盖代理对被切开的边界。
class _MonoGlyphs implements GlyphsPort {
  _MonoGlyphs() : charWidth = 0.5;

  final double charWidth;
  int calls = 0;
  final List<String> weights = <String>[];

  @override
  double width(String value, double size, String weight) {
    calls++;
    weights.add(weight);
    return value.length * size * charWidth;
  }
}

const double _stageWidth = 1920;

/// NativeHudDetail.cpp:56,60 —— x = width*0.56，usable = width - x - 59。
double _usable(double width) => width - width * 0.56 - 59;

List<List<Object?>> _ops(Drawing drawing) =>
    drawing.commands.cast<List<Object?>>().toList();

List<List<Object?>> _fills(Drawing drawing) =>
    _ops(drawing).where((List<Object?> c) => c[0] == 'fill').toList();

List<List<Object?>> _texts(Drawing drawing) =>
    _ops(drawing).where((List<Object?> c) => c[0] == 'text').toList();

ActionRowModel _row({
  double x = 100,
  double width = 792,
  double y = 476,
  bool dark = false,
  bool primaryRow = false,
  required List<ActionRowItem> items,
}) =>
    ActionRowModel(
      x: x,
      width: width,
      y: y,
      dark: dark,
      primaryRow: primaryRow,
      items: items,
    );

const List<ActionRowItem> _threeSlots = <ActionRowItem>[
  ActionRowItem('▶ 播放歌曲', 'music:play'),
  ActionRowItem('♡ 喜欢', 'music:like'),
  ActionRowItem('＋ 加入歌单', 'music:add-to-playlist'),
];

void main() {
  group('几何 SongDetailCard.cpp:19-21/29', () {
    test('1920 舞台：usable=785.8，列宽是浮点除法不取整', () {
      final double usable = _usable(_stageWidth);
      expect(usable, closeTo(785.8, 1e-9));
      expect(actionRowColumnWidth(usable), closeTo(761.8 / 3, 1e-9));
      expect(actionRowColumnWidth(usable), closeTo(253.93333333333334, 1e-9));
    });

    test('792 宽：列宽 256、步长 268、三格 x 依次 100/368/636', () {
      final double column = actionRowColumnWidth(792);
      expect(column, 256.0);
      expect(actionRowCellX(rowX: 100, columnWidth: column, index: 0), 100.0);
      expect(actionRowCellX(rowX: 100, columnWidth: column, index: 1), 368.0);
      expect(actionRowCellX(rowX: 100, columnWidth: column, index: 2), 636.0);

      final Drawing drawing = buildActionRow(_row(items: _threeSlots));
      final List<HudFlatHit> hits = drawing.hits;
      expect(hits.map((HudFlatHit h) => h['x']).toList(), <double>[100.0, 368.0, 636.0]);
      expect(hits.every((HudFlatHit h) => h['width'] == 256.0), isTrue);
      expect(hits.every((HudFlatHit h) => h['height'] == 44.0), isTrue);
    });

    test('小数列宽时 x 仍是小数（Qt 的 const auto width 是 double）', () {
      final double usable = _usable(_stageWidth);
      final double column = actionRowColumnWidth(usable);
      final double third = actionRowCellX(rowX: 1075.2, columnWidth: column, index: 2);
      expect(third, closeTo(1075.2 + 2 * (column + 12), 1e-9));
      expect(third, isNot(equals(third.roundToDouble())));
    });
  });

  group('空 route 整格跳过 SongDetailCard.cpp:26-28', () {
    test('中间格空 route：不绘制、不命中，后面的格子仍然用 index 定位', () {
      final Drawing drawing = buildActionRow(_row(items: const <ActionRowItem>[
        ActionRowItem('A', 'a'),
        ActionRowItem('', ''),
        ActionRowItem('C', 'c'),
      ]));
      expect(drawing.hits.length, 2);
      expect(drawing.hits[1]['action'], 'c');
      expect(drawing.hits[1]['x'], 636.0); // 2 * (256 + 12)，不是第 2 个“已绘制”格
      expect(_fills(drawing).length, 8); // 2 格 * 4 条边框
      expect(_texts(drawing).length, 2);
      expect(_texts(drawing).map((List<Object?> c) => c[1]).toList(), <Object?>['A', 'C']);
    });

    test('三格全空：Drawing 完全为空', () {
      final Drawing drawing = buildActionRow(_row(items: const <ActionRowItem>[
        ActionRowItem('', ''),
        ActionRowItem('', ''),
        ActionRowItem('', ''),
      ]));
      expect(drawing.isEmpty, isTrue);
      expect(drawing.commands, isEmpty);
      expect(drawing.hits, isEmpty);
    });

    test('超出三格的输入不裁剪（Qt 不设上限，这里保持同行为）', () {
      final Drawing drawing = buildActionRow(_row(items: const <ActionRowItem>[
        ActionRowItem('A', 'a'),
        ActionRowItem('B', 'b'),
        ActionRowItem('C', 'c'),
        ActionRowItem('D', 'd'),
      ]));
      expect(drawing.hits.length, 4);
      expect(drawing.hits[3]['x'], closeTo(100 + 3 * 268, 1e-9));
    });
  });

  group('primary 实心格 SongDetailCard.cpp:30-32/42-44', () {
    test('深色：首格实心前景、文字 demibold+反相色', () {
      final Drawing drawing = buildActionRow(_row(dark: true, primaryRow: true, items: _threeSlots));
      final List<Object?> first = _ops(drawing).first;
      expect(first[0], 'fill');
      expect(first[1], cardInk(true));
      expect(first.sublist(2), <Object?>[100.0, 476.0, 256.0, 44.0]);

      // 首格没有四条 1px 边框：命令 1 就是文字（index 1），第 2 格才出现边框。
      final List<Object?> firstText = _ops(drawing)[1];
      expect(firstText[0], 'text');
      expect(firstText[1], '▶ 播放歌曲');
      expect(firstText[2], 112.0); // x + 12
      expect(firstText[3], 488.0); // y + 12
      expect(firstText[4], 14.0);
      expect(firstText[5], 'demibold');
      expect(firstText[6], 0.0);
      expect(firstText[7], cardInverse(true));
      expect(cardInverse(true).length, 4); // 卡片色不带 calibrated 标记
    });

    test('浅色：首格实心用 cardInk(false)，文字用 cardInverse(false)', () {
      final Drawing drawing = buildActionRow(_row(primaryRow: true, items: _threeSlots));
      expect(_ops(drawing).first[1], cardInk(false));
      expect(_texts(drawing).first[7], cardInverse(false));
      expect(cardInk(false), <Object?>[0.133, 0.165, 0.145, 1]);
      expect(cardInverse(false), <Object?>[0.973, 0.969, 0.933, 1]);
    });

    test('primaryRow=false 时首格也必须走四边框（primary = primaryRow && index==0）', () {
      final Drawing drawing = buildActionRow(_row(primaryRow: false, items: _threeSlots));
      expect(_fills(drawing).length, 12);
      expect(_texts(drawing).first[5], 'regular');
      expect(_texts(drawing).first[7], cardInk(false));
    });

    test('primaryRow=true 但首格 route 为空：实心填充随格一起消失', () {
      final Drawing drawing = buildActionRow(_row(primaryRow: true, items: const <ActionRowItem>[
        ActionRowItem('A', ''),
        ActionRowItem('B', 'b'),
        ActionRowItem('C', 'c'),
      ]));
      expect(_fills(drawing).length, 8); // 只剩两格描边，没有实心底
      expect(_texts(drawing).map((List<Object?> c) => c[5]).toList(), <Object?>['regular', 'regular']);
    });
  });

  group('描边格 SongDetailCard.cpp:33-39', () {
    test('四条 1px 边框顺序为 上/下/左/右，alpha=0.2，rgb 与前景相同', () {
      final Drawing drawing = buildActionRow(_row(items: const <ActionRowItem>[
        ActionRowItem('X', 'x'),
        ActionRowItem('', ''),
        ActionRowItem('', ''),
      ]));
      final List<List<Object?>> fills = _fills(drawing);
      expect(fills.length, 4);
      expect(fills[0].sublist(2), <Object?>[100.0, 476.0, 256.0, 1.0]);
      expect(fills[1].sublist(2), <Object?>[100.0, 519.0, 256.0, 1.0]); // y + 44 - 1
      expect(fills[2].sublist(2), <Object?>[100.0, 476.0, 1.0, 44.0]);
      expect(fills[3].sublist(2), <Object?>[355.0, 476.0, 1.0, 44.0]); // x + 256 - 1
      for (final List<Object?> fill in fills) {
        final List<Object?> color = fill[1]! as List<Object?>;
        expect(color[0], cardInk(false)[0]);
        expect(color[1], cardInk(false)[1]);
        expect(color[2], cardInk(false)[2]);
        expect(color[3], 0.2);
      }
    });

    test('withAlpha 不改调色板本身（Qt 是 auto color = ink() 后改副本）', () {
      final List<Object?> palette = cardInk(true);
      final List<Object?> border = withAlpha(palette, 0.2);
      expect(border[3], 0.2);
      expect(palette[3], 1.0);
      expect(border, isNot(same(palette)));
    });

    test('深色描边 rgb 是 cardInk(true)', () {
      final Drawing drawing = buildActionRow(_row(
        dark: true,
        items: const <ActionRowItem>[ActionRowItem('X', 'x')],
      ));
      expect(_fills(drawing).first[1], <Object?>[0.92, 0.93, 0.88, 0.2]);
    });
  });

  group('命中 NativeHud.cpp:102-108', () {
    test('六字段且键序固定，绝无 fixed（PlayerBar.cpp:46-53 专属）', () {
      final Drawing drawing = buildActionRow(_row(items: _threeSlots));
      expect(drawing.hits.length, 3);
      for (final HudFlatHit hit in drawing.hits) {
        expect(hit.keys.toList(), <String>['x', 'y', 'width', 'height', 'action', 'label']);
        expect(hit.containsKey('fixed'), isFalse);
      }
      expect(drawing.hits.map((HudFlatHit h) => h['action']).toList(), <Object?>[
        'music:play',
        'music:like',
        'music:add-to-playlist',
      ]);
      expect(drawing.hits.map((HudFlatHit h) => h['label']).toList(), <Object?>[
        '▶ 播放歌曲',
        '♡ 喜欢',
        '＋ 加入歌单',
      ]);
      expect(drawing.hits.map((HudFlatHit h) => h['y']).toList(), <Object?>[476.0, 476.0, 476.0]);
    });

    test('label 为 null 才回退 action，空串保持空串（Qt 判 isNull）', () {
      expect(hitRecord(x: 1, y: 2, width: 3, height: 4, action: 'a')['label'], 'a');
      expect(hitRecord(x: 1, y: 2, width: 3, height: 4, action: 'a', label: null)['label'], 'a');
      expect(hitRecord(x: 1, y: 2, width: 3, height: 4, action: 'a', label: '')['label'], '');
    });

    test('顺序即语义：命中按格序 append，不排序不去重', () {
      final Drawing drawing = buildActionRow(_row(items: const <ActionRowItem>[
        ActionRowItem('B', 'b'),
        ActionRowItem('A', 'a'),
        ActionRowItem('B2', 'b'),
      ]));
      expect(drawing.hits.map((HudFlatHit h) => h['action']).toList(), <Object?>['b', 'a', 'b']);
      expect(drawing.hits.map((HudFlatHit h) => h['label']).toList(), <Object?>['B', 'A', 'B2']);
    });
  });

  group('命令形状 NativeHud.cpp:16-18/37-43', () {
    test('命令是扁平 List（不是 Map），fill 6 项、text 8 项', () {
      final Drawing drawing = buildActionRow(_row(primaryRow: true, items: _threeSlots));
      for (final Object? command in drawing.commands) {
        expect(command, isA<List<Object?>>());
        expect(command, isNot(isA<Map<String, Object?>>()));
      }
      for (final List<Object?> fill in _fills(drawing)) {
        expect(fill.length, 6);
        expect(fill[0], 'fill');
        expect(fill[1], isA<List<Object?>>());
      }
      for (final List<Object?> text in _texts(drawing)) {
        expect(text.length, 8);
        expect(text[0], 'text');
        expect(text[1], isA<String>());
        expect(text[5], isA<String>());
        expect(text[6], 0.0);
        expect(text[7], isA<List<Object?>>());
      }
    });

    test('text 命令的形状与 textCommand 一致', () {
      expect(
        textCommand('v', 1, 2, 3, 'regular', 0, const <Object?>[0, 0, 0, 1]),
        <Object?>['text', 'v', 1.0, 2.0, 3.0, 'regular', 0.0, <Object?>[0, 0, 0, 1]],
      );
      expect(
        fillCommand(1, 2, 3, 4, const <Object?>[0, 0, 0, 1]),
        <Object?>['fill', <Object?>[0, 0, 0, 1], 1.0, 2.0, 3.0, 4.0],
      );
    });

    test('build 出来的列表不可变（宿主只能追加自己的副本）', () {
      final Drawing drawing = buildActionRow(_row(items: _threeSlots));
      expect(() => drawing.hits.add(hitRecord(x: 0, y: 0, width: 0, height: 0, action: 'x')),
          throwsUnsupportedError);
      expect(() => drawing.commands.add(<Object?>['save']), throwsUnsupportedError);
    });
  });

  group('字体裁剪 NativeHud.cpp:48-76', () {
    test('整体放得下：原样返回，只测一次', () {
      final _MonoGlyphs glyphs = _MonoGlyphs();
      expect(fitGlyphText('ABCDEFGHIJ', 10, 50, 'regular', glyphs), 'ABCDEFGHIJ');
      expect(glyphs.calls, 1);
    });

    test('二分出最长前缀，然后丢掉 1 个 code unit 换成省略号', () {
      final _MonoGlyphs glyphs = _MonoGlyphs(); // 每 code unit 5
      // 22 宽最多容纳 4 个（20），第 5 个是 25 超宽。
      expect(fitGlyphText('ABCDEFGHIJ', 10, 22, 'regular', glyphs), 'ABC\u2026');
      expect(fitGlyphText('ABCDEFGHIJ', 10, 22, 'regular', glyphs).length, 4);
    });

    test('边界用 <=：宽度刚好等于前缀宽度时该前缀算放得下', () {
      final _MonoGlyphs glyphs = _MonoGlyphs();
      expect(fitGlyphText('ABCDEFGHIJ', 10, 25, 'regular', glyphs), 'ABCD\u2026');
      expect(fitGlyphText('ABCDEFGHIJ', 10, 20, 'regular', glyphs), 'ABC\u2026');
    });

    test('单字符超宽不截断（low=1 且 length==size，Qt 不会出现省略号）', () {
      final _MonoGlyphs glyphs = _MonoGlyphs();
      expect(fitGlyphText('W', 10, 2, 'regular', glyphs), 'W');
      expect(fitGlyphText('W', 10, 2, 'regular', glyphs).contains('\u2026'), isFalse);
    });

    test('两字符都放不下：只剩省略号（left(0) + 省略号）', () {
      final _MonoGlyphs glyphs = _MonoGlyphs();
      expect(fitGlyphText('WW', 10, 2, 'regular', glyphs), '\u2026');
    });

    test('空串不截断', () {
      final _MonoGlyphs glyphs = _MonoGlyphs();
      expect(fitGlyphText('', 10, 0, 'regular', glyphs), '');
    });

    test('按 UTF-16 code unit 切（QString::left 语义，代理对可能被切开）', () {
      final _MonoGlyphs glyphs = _MonoGlyphs(); // 每个 code unit 5
      final String value = '𝄞A'; // 代理对 + A，共 3 个 code unit
      expect(value.length, 3);
      final String fitted = fitGlyphText(value, 10, 12, 'regular', glyphs);
      expect(fitted.length, 2); // 1 个 code unit + 省略号
      expect(fitted.codeUnitAt(0), 0xD834); // 只剩高代理
      expect(fitted.endsWith('\u2026'), isTrue);
    });

    test('fitActionRowLabels：主行按 route 选字重，裁剪宽度是 columnWidth-24', () {
      final _MonoGlyphs glyphs = _MonoGlyphs(); // 每 code unit 7
      final List<ActionRowItem> fitted = fitActionRowLabels(
        <ActionRowItem>[
          const ActionRowItem('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'music:play'), // 40 个 A
          const ActionRowItem('B', 'music:like'),
          const ActionRowItem('', ''),
        ],
        fontSize: 14,
        columnWidth: 256, // fit 宽度 = 232，最多 33 个 code unit
        glyphs: glyphs,
        weightOf: (ActionRowItem item) => item.route == 'music:play' ? 'demibold' : 'regular',
      );
      expect(fitted[0].label.length, 33);
      expect(fitted[0].label.endsWith('\u2026'), isTrue);
      expect(fitted[0].route, 'music:play');
      expect(glyphs.weights.first, 'demibold');
      expect(glyphs.weights.last, 'regular');
      expect(fitted[1].label, 'B');
      expect(fitted[2].label, '');
    });

    test('fitActionRowLabels 不传 weightOf 时一律 regular（NativeHudDetail.cpp:147）', () {
      final _MonoGlyphs glyphs = _MonoGlyphs();
      fitActionRowLabels(
        const <ActionRowItem>[ActionRowItem('X', 'x')],
        fontSize: 14,
        columnWidth: 256,
        glyphs: glyphs,
      );
      expect(glyphs.weights.toSet(), <String>{'regular'});
    });
  });

  group('两行组合 SongDetailCard.cpp:69-70', () {
    test('476 primary + 532 secondary：命令 12+15、命中 6、顺序不变', () {
      final Drawing drawing = songDetailActionRows(
        x: 100,
        width: 792,
        dark: false,
        primaryActions: _threeSlots,
        secondaryActions: const <ActionRowItem>[
          ActionRowItem('＋ 加入队列', 'music:enqueue'),
          ActionRowItem('▷ 下一首播放', 'music:play-next'),
          ActionRowItem('↗ 歌手作品', 'music:artist:0'),
        ],
      );
      expect(drawing.commands.length, 12 + 15);
      expect(drawing.hits.length, 6);
      expect(drawing.hits.map((HudFlatHit h) => h['y']).toList(),
          <Object?>[476.0, 476.0, 476.0, 532.0, 532.0, 532.0]);
      expect(_ops(drawing)[0][3], 476.0);
      expect(_ops(drawing)[12][3], 532.0); // 第 13 条命令进入第二行（首格边框上边）
      expect(_texts(drawing).last[3], 544.0); // 532 + 12
    });

    test('y 常量与 Qt 一致', () {
      expect(kSongDetailPrimaryRowY, 476.0);
      expect(kSongDetailSecondaryRowY, 532.0);
      expect(kActionRowGap, 12.0);
      expect(kActionRowHeight, 44.0);
      expect(kActionRowTextInsetX, 12.0);
      expect(kActionRowTextInsetY, 12.0);
      expect(kActionRowFontSize, 14.0);
      expect(kActionRowBorderAlpha, 0.2);
      expect(kActionRowFitInset, 24.0);
    });
  });

  group('封面动作行 NativeHudDetail.cpp:61-62/203-213 + NativeHud.cpp:110-120', () {
    const double x = 1075.2;
    final double usable = _usable(_stageWidth);
    final double column = actionRowColumnWidth(usable);
    final double pitch = column + kActionRowGap;

    test('三格齐全：只 hit+text，不画底也不裁字；文字垂直居中到 y+(44-13)/2-4', () {
      final Drawing drawing = buildFooterActionRow(FooterActionRowModel(
        x: x,
        width: usable,
        y: 910,
        dark: true,
        slots: const <FooterActionSlot?>[
          FooterActionSlot('官方客户端 ↗', 'music:official'),
          FooterActionSlot('试听片段', 'music:preview'),
          FooterActionSlot('从歌单移除', 'music:remove-track'),
        ],
      ));
      expect(drawing.commands.length, 3); // 只有 text：非模态分支没有 fill
      expect(_fills(drawing), isEmpty);
      expect(drawing.hits.length, 3);
      expect(drawing.hits[0]['x'], closeTo(x, 1e-9));
      expect(drawing.hits[1]['x'], closeTo(x + pitch, 1e-9));
      expect(drawing.hits[2]['x'], closeTo(x + 2 * pitch, 1e-9));
      expect(drawing.hits[0]['width'], closeTo(column, 1e-9));
      expect(drawing.hits[0]['height'], 44.0);
      expect(drawing.hits.map((HudFlatHit h) => h['action']).toList(), <Object?>[
        'music:official',
        'music:preview',
        'music:remove-track',
      ]);

      final List<Object?> text = _texts(drawing).first;
      expect(text[1], '官方客户端 ↗');
      expect(text[2], closeTo(x, 1e-9));
      expect(text[3], 921.5); // 910 + (44-13)/2 - 4
      expect(text[4], 13.0);
      expect(text[5], 'regular');
      expect(text[7], hudInk(true));
      expect((text[7]! as List<Object?>).length, 5); // 带 calibrated 标记
    });

    test('中间条件不成立：只有两格命中，第三格仍在第 3 列', () {
      final Drawing drawing = buildFooterActionRow(FooterActionRowModel(
        x: x,
        width: usable,
        y: 910,
        dark: false,
        slots: const <FooterActionSlot?>[
          FooterActionSlot('官方客户端 ↗', 'music:official'),
          null,
          FooterActionSlot('从歌单移除', 'music:remove-track'),
        ],
      ));
      expect(drawing.hits.length, 2);
      expect(drawing.hits[1]['x'], closeTo(x + 2 * pitch, 1e-9));
      expect(_texts(drawing)[1][7], hudInk(false));
    });

    test('三格全缺：空 Drawing', () {
      final Drawing drawing = buildFooterActionRow(FooterActionRowModel(
        x: x,
        width: usable,
        y: 910,
        dark: false,
        slots: const <FooterActionSlot?>[null, null, null],
      ));
      expect(drawing.isEmpty, isTrue);
    });

    test('modalControls=true：先 hit，再半透明底，再按 width-2*inset 裁字', () {
      final Drawing drawing = buildFooterActionRow(FooterActionRowModel(
        x: 100,
        width: 792, // 列宽 256 -> inset = min(10, 32) = 10
        y: 910,
        dark: true,
        modalControls: true,
        glyphs: _MonoGlyphs(),
        slots: const <FooterActionSlot?>[
          FooterActionSlot('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'a'),
          null,
          null,
        ],
      ));
      expect(_ops(drawing).length, 2); // fill + text
      expect(_fills(drawing).length, 1);
      expect(_fills(drawing).first[1], <Object?>[0.55, 0.59, 0.46, 0.13]);
      expect(_fills(drawing).first.sublist(2), <Object?>[100.0, 910.0, 256.0, 44.0]);
      final List<Object?> text = _texts(drawing).first;
      expect(text[2], 110.0); // x + inset
      expect(text[3], 921.5);
      expect((text[1]! as String).length, 36); // fit 宽度 256-20=236，13*0.5=6.5/unit -> 36
      expect((text[1]! as String).endsWith('\u2026'), isTrue);
    });

    test('modalControls=true 且列宽很窄时 inset 取 columnWidth/8', () {
      final Drawing drawing = buildFooterActionRow(FooterActionRowModel(
        x: 0,
        width: 120, // 列宽 32 -> inset = 4
        y: 0,
        dark: false,
        modalControls: true,
        glyphs: _MonoGlyphs(),
        slots: const <FooterActionSlot?>[FooterActionSlot('ABCDEFGHIJ', 'a'), null, null],
      ));
      expect(_fills(drawing).first[1], <Object?>[0.44, 0.49, 0.36, 0.1]);
      expect(_fills(drawing).first[4], 32.0);
      final List<Object?> text = _texts(drawing).first;
      expect(text[2], 4.0);
      expect((text[1]! as String).length, 3); // fit 宽度 24、6.5/unit -> left(2)+省略号
    });

    test('modalControls=true 缺少 glyphs 直接报错（Qt 在这条分支里必须 fit）', () {
      expect(
        () => buildFooterActionRow(FooterActionRowModel(
          x: 0,
          width: 792,
          y: 0,
          dark: false,
          modalControls: true,
          slots: const <FooterActionSlot?>[FooterActionSlot('A', 'a'), null, null],
        )),
        throwsArgumentError,
      );
    });
  });

  group('ink 形态 NativeHud.cpp:10-15 / SongDetailCard.cpp:7-9', () {
    test('hudInk 五元色且标记逐字正确（深色 calibratedWhite、浅色 calibratedRGB）', () {
      expect(hudInk(true), <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite']);
      expect(hudInk(false), <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB']);
      expect(hudInk(true).length, 5);
    });

    test('cardInk 四元色，绝无标记（与 hudInk 不可混用）', () {
      expect(cardInk(true).length, 4);
      expect(cardInk(false).length, 4);
      expect(cardInk(true).contains('calibratedWhite'), isFalse);
      expect(cardInk(true), <Object?>[0.92, 0.93, 0.88, 1]);
    });

    test('hudRuleCommand 是 1px 横线，alpha 换成 opacity', () {
      expect(
        hudRuleCommand(10, 898, 785.8, 0.18, false),
        <Object?>['fill', <Object?>[0.08, 0.085, 0.075, 0.18, 'calibratedRGB'], 10.0, 898.0, 785.8, 1.0],
      );
    });
  });

  group('动作行绝不可当 3D 贴图', () {
    test('命令流里不含 image/art/draw 之类场景通道命令', () {
      final Drawing drawing = songDetailActionRows(
        x: 100,
        width: 792,
        dark: true,
        primaryActions: _threeSlots,
        secondaryActions: _threeSlots,
      );
      for (final List<Object?> command in _ops(drawing)) {
        expect(command[0], isIn(<Object?>['fill', 'text']));
      }
    });
  });
}
