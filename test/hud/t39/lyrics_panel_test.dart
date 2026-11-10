// T39-W3 / 横屏歌词面板 1:1 Qt 语义验收测试（先写后实现，全程不执行）。
//
// 唯一真值来源：
//   Qt/src/NativeHudDetail.cpp:217-338  NativeHud::lyricsPanel（全部布局、绘制、命中）
//   Qt/src/LyricsController.h:29-38      status/message/index/offsetMs 等字段
//   Qt/src/LyricsController.cpp:470-509  document 形状（lines[].startMs/text/translation、plainText）
//   Qt/src/NativeHudInput.cpp:122-127    滚轮：browse 位置与 plainOffset 增量
//   Qt/src/NativeHud.cpp:10-15/34-43/77-120  ink()/clip/text/limited/button/hit 命令形状
//   Qt/src/UiMotion.cpp:63-84            ReelCurve 49 点样条（带初速、末帧落点）
//
// 断言口径：精确命令形状 + 相对顺序 + 精确几何 + 精确 alpha；禁止集合化/排序化比较。
// 本文件只被测 lib/hud/modals/lyrics_panel.dart，不运行、不依赖 Flutter Widget。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/lyrics_panel.dart';

// ── ink 调色板：Qt/src/NativeHud.cpp:10-15 ─────────────────────────────────
const List<Object?> inkLight = <Object?>[0.08, 0.085, 0.075, 1.0, 'calibratedRGB'];
const List<Object?> inkDark = <Object?>[0.92, 0.92, 0.92, 1.0, 'calibratedWhite'];

/// muted = ink 且 alpha 乘 0.45（NativeHudDetail.cpp:221-222 是直接赋 0.45）。
const List<Object?> mutedLight = <Object?>[0.08, 0.085, 0.075, 0.45, 'calibratedRGB'];
const List<Object?> mutedDark = <Object?>[0.92, 0.92, 0.92, 0.45, 'calibratedWhite'];

/// 逐 code unit 计宽的只读度量替身。
///
/// 这是测试夹具而非字体真值：unit 默认 1，宽度与字号无关，便于手算换行行数。
/// wrap 复刻 Glyphs::wrap 的贪心断行（'\n' 强制断行，逐字簇累加宽度）。
class FixtureGlyphs implements GlyphsPort {
  const FixtureGlyphs({this.unit = 1.0});

  final double unit;

  @override
  double width(String value, double size, String weight) => value.length * unit;

  @override
  List<String> wrap(String value, double limit, double size, String weight) {
    final List<String> rows = <String>[];
    String line = '';
    for (final String cluster in value.split('')) {
      if (cluster == '\n') {
        rows.add(line);
        line = '';
        continue;
      }
      if (line.isNotEmpty && width(line + cluster, size, weight) > limit) {
        rows.add(line);
        line = cluster;
      } else {
        line += cluster;
      }
    }
    rows.add(line);
    return rows;
  }
}

/// 冻结曲线替身：采样恒等于曲线起点，速度恒 0。
///
/// 用它可以把 scroll 精确停在任意值上验证裁剪/edge 公式，而不引入任何计时器。
class FrozenMotion implements LyricsMotionPort {
  const FrozenMotion();

  @override
  ReelCurve curve({
    required double from,
    required double target,
    required double velocity,
    required double start,
    required double duration,
  }) =>
      ReelCurve(
        from: from,
        target: target,
        velocity: velocity,
        start: start,
        duration: duration,
      );

  @override
  List<double> sample(ReelCurve curve, double time) => <double>[curve.from, 0.0];
}

/// 单条歌词行夹具。
Map<String, Object?> line(Object? startMs, String text, [String translation = '']) =>
    <String, Object?>{'startMs': startMs, 'text': text, 'translation': translation};

/// 歌词文档夹具；lines 为空即「无歌词行」分支。
Map<String, Object?> doc(List<Map<String, Object?>> lines, {String plainText = ''}) =>
    <String, Object?>{
      'version': 1,
      'timing': 'line',
      'lines': lines,
      'plainText': plainText,
      'offsetMs': 0.0,
    };

List<List<Object?>> textCommands(LyricsPanelDrawing drawing) =>
    drawing.commands.where((List<Object?> c) => c[0] == 'text').toList();

List<Map<String, Object?>> hitsOf(LyricsPanelDrawing drawing, String action) =>
    drawing.hits.where((Map<String, Object?> h) => h['action'] == action).toList();

List<List<Object?>> opCommands(LyricsPanelDrawing drawing, String op) =>
    drawing.commands.where((List<Object?> c) => c[0] == op).toList();

double alphaOf(List<Object?> text) => (text[7] as List<Object?>)[3]! as double;

void main() {
  // ── 几何常量：Qt/src/NativeHudDetail.cpp:229-230、304 ────────────────────
  group('几何常量', () {
    test('top=360 bottom=889 focusY=515 与 Qt constexpr 一致', () {
      expect(lyricsPanelTop, 360.0);
      expect(lyricsPanelBottom, 889.0);
      expect(lyricsPanelFocusY, 515.0);
      expect(lyricsPanelBodySize, 34.0);
      expect(lyricsPanelLineHeight, 47.0);
      expect(lyricsPanelTranslationHeight, 26.0);
      expect(lyricsPanelRowGap, 32.0);
      expect(lyricsPanelPlainWindow, 9);
      expect(LyricsPanelBounds.calibrated.top, 360.0);
      expect(LyricsPanelBounds.calibrated.bottom, 889.0);
    });
  });

  // ── 无歌词行分支：NativeHudDetail.cpp:233-252 ───────────────────────────
  group('无歌词行（plain 分支）', () {
    test('plainText 优先、size=27、正文 bold、颜色 muted，命令顺序 save/clip/text/restore', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final LyricsPanelModel model = LyricsPanelModel(
        x: 0,
        width: 400,
        title: '标题',
        artist: '艺人',
        document: doc(const <Map<String, Object?>>[], plainText: '纯音乐段落'),
        status: 'plain',
        message: '不该出现的 message',
      );
      final LyricsPanelDrawing drawing =
          paintLyricsPanel(model, glyphs, motion: const FrozenMotion());

      final List<List<Object?>> body = drawing.commands
          .where((List<Object?> c) => c[0] == 'save' || c[0] == 'clip' || c[0] == 'restore' || c[0] == 'text')
          .toList();
      // 顶部标题/艺人文本在前（limited 各发一条 text）。
      expect(body[0], <Object?>['text', '标题', 0.0, 278.0, 20.0, 'demibold', 0, inkLight]);
      expect(body[1], <Object?>['text', '艺人', 0.0, 310.0, 13.0, 'regular', 0, inkLight]);
      // 关闭按钮 = hit + text（button 先 hit 后 text）。
      expect(body[2], <Object?>['text', '关闭', 340.0, 287.0, 14.0, 'regular', 0, inkLight]);
      expect(body[3], <Object?>['save']);
      expect(body[4], <Object?>['clip', 0.0, 360.0, 400.0, 529.0]);
      expect(body[5], <Object?>['text', '纯音乐段落', 0.0, 415.0, 27.0, 'bold', 0, mutedLight]);
      expect(body[6], <Object?>['restore']);
      expect(body.length, 7);
      // plain 分支没有底部两个按钮。
      expect(hitsOf(drawing, 'player:lyrics-offset'), isEmpty);
      expect(hitsOf(drawing, 'player:lyrics-follow'), isEmpty);
    });

    test('plainText 为空时回退 lyrics.message，size=24', () {
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(
          width: 400,
          document: doc(const <Map<String, Object?>>[]),
          status: 'empty',
          message: '暂无歌词 / 纯音乐',
        ),
        const FixtureGlyphs(),
        motion: const FrozenMotion(),
      );
      final List<List<Object?>> texts = textCommands(drawing);
      // 前 3 条是头部（标题/艺人/关闭），正文从下标 3 起。
      expect(texts[3], <Object?>['text', '暂无歌词 / 纯音乐', 0.0, 415.0, 24.0, 'bold', 0, mutedLight]);
    });

    test('plainText 与 message 都为空时用默认文案「播放歌曲后显示歌词」，size=24', () {
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(width: 400, document: doc(const <Map<String, Object?>>[])),
        const FixtureGlyphs(),
        motion: const FrozenMotion(),
      );
      expect(textCommands(drawing)[3],
          <Object?>['text', '播放歌曲后显示歌词', 0.0, 415.0, 24.0, 'bold', 0, mutedLight]);
    });

    test('dark=true 时 muted 用 calibratedWhite 且 alpha=0.45', () {
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(
          width: 400,
          dark: true,
          document: doc(const <Map<String, Object?>>[], plainText: '纯音乐'),
        ),
        const FixtureGlyphs(),
        motion: const FrozenMotion(),
      );
      // title 为空时 limited 仍发一条空文本命令（Qt fit("") 返回 ""）。
      expect(textCommands(drawing)[0], <Object?>['text', '', 0.0, 278.0, 20.0, 'demibold', 0, inkDark]);
      expect(textCommands(drawing)[3], <Object?>['text', '纯音乐', 0.0, 415.0, 27.0, 'bold', 0, mutedDark]);
      expect(textCommands(drawing)[3][7], mutedDark);
    });

    test('9 行窗口：超过 9 行只画 9 行，y 步进 48', () {
      const String plain = 'AAAAAABBBBBBCCCCCCDDDDDDEEEEEEFFFFFFGGGGGGHHHHHHIIIIIIJJJJJJKKKKKKLLLLLL';
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(
          width: 30,
          document: doc(const <Map<String, Object?>>[], plainText: plain),
        ),
        const FixtureGlyphs(),
        motion: const FrozenMotion(),
      );
      final List<List<Object?>> texts = textCommands(drawing);
      // 3 条头部文本 + 9 条正文。
      expect(texts.length, 12);
      expect(texts[3][1], 'AAAAAA');
      expect(texts[3][3], 415.0);
      expect(texts[11][1], 'IIIIII');
      expect(texts[11][3], 415.0 + 8 * 48);
    });

    test('plainOffset 生效：从第 4 行起画，跳过前三行', () {
      const String plain = 'AAAAAABBBBBBCCCCCCDDDDDDEEEEEEFFFFFFGGGGGGHHHHHHIIIIIIJJJJJJKKKKKKLLLLLL';
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(
          width: 30,
          document: doc(const <Map<String, Object?>>[], plainText: plain),
          plainOffset: 3,
        ),
        const FixtureGlyphs(),
        motion: const FrozenMotion(),
      );
      final List<List<Object?>> texts = textCommands(drawing);
      expect(texts.length, 12);
      expect(texts[3][1], 'DDDDDD');
      expect(texts[11][1], 'LLLLLL');
    });

    test('plainOffset clamp 到 max(0, rows-9)：9 行时偏移归零', () {
      const String plain = 'AAAAAABBBBBBCCCCCCDDDDDDEEEEEEFFFFFFGGGGGGHHHHHHIIIIII';
      final LyricsPanelModel model = LyricsPanelModel(
        width: 30,
        document: doc(const <Map<String, Object?>>[], plainText: plain),
        plainOffset: 5,
      );
      final LyricsPanelDrawing drawing =
          paintLyricsPanel(model, const FixtureGlyphs(), motion: const FrozenMotion());
      expect(drawing.view.plainOffset, 0);
      expect(textCommands(drawing)[3][1], 'AAAAAA');
    });

    test('plainOffset 在 12 行时 clamp 到 3', () {
      const String plain = 'AAAAAABBBBBBCCCCCCDDDDDDEEEEEEFFFFFFGGGGGGHHHHHHIIIIIIJJJJJJKKKKKKLLLLLL';
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(
          width: 30,
          document: doc(const <Map<String, Object?>>[], plainText: plain),
          plainOffset: 7,
        ),
        const FixtureGlyphs(),
        motion: const FrozenMotion(),
      );
      expect(drawing.view.plainOffset, 3);
      expect(textCommands(drawing)[3][1], 'DDDDDD');
    });

    test('仅 status=error / empty 出现「重新查找歌词 ↗」按钮', () {
      LyricsPanelDrawing frame(String status) => paintLyricsPanel(
            LyricsPanelModel(
              width: 400,
              document: doc(const <Map<String, Object?>>[], plainText: '纯音乐'),
              status: status,
            ),
            const FixtureGlyphs(),
            motion: const FrozenMotion(),
          );

      final LyricsPanelDrawing error = frame('error');
      expect(hitsOf(error, 'player:lyrics-retry'), <Map<String, Object?>>[
        <String, Object?>{
          'x': 0.0,
          'y': 909.0,
          'width': 170.0,
          'height': 36.0,
          'action': 'player:lyrics-retry',
          'label': '重新查找歌词 ↗',
        }
      ]);
      // 按钮文字：y + (36 - 14)/2 - 4 = 916。
      expect(textCommands(error).last,
          <Object?>['text', '重新查找歌词 ↗', 0.0, 916.0, 14.0, 'regular', 0, inkLight]);
      expect(hitsOf(frame('empty'), 'player:lyrics-retry').length, 1);
      expect(hitsOf(frame('ready'), 'player:lyrics-retry'), isEmpty);
      expect(hitsOf(frame('plain'), 'player:lyrics-retry'), isEmpty);
      expect(hitsOf(frame('idle'), 'player:lyrics-retry'), isEmpty);
    });

    test('plain 分支仍发「歌词来源 ⌃」，retry 文本排在 restore 之后', () {
      // 来源按钮在 233 行分支判定之前（NativeHudDetail.cpp:226-228）；
      // retry 在 245-252 的 restore 之后才 append。
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(
          x: 100,
          width: 400,
          document: doc(const <Map<String, Object?>>[], plainText: '纯音乐'),
          status: 'error',
          isLocal: true,
          provider: 'local',
        ),
        const FixtureGlyphs(),
        motion: const FrozenMotion(),
      );
      expect(hitsOf(drawing, 'player:lyrics-sources'), <Map<String, Object?>>[
        <String, Object?>{
          'x': 256.0,
          'y': 914.0,
          'width': 120.0,
          'height': 32.0,
          'action': 'player:lyrics-sources',
          'label': '歌词来源 ⌃',
        }
      ]);
      final int restoreIndex =
          drawing.commands.lastIndexWhere((List<Object?> c) => c[0] == 'restore');
      final int retryTextIndex = drawing.commands.indexWhere(
          (List<Object?> c) => c[0] == 'text' && c[1] == '重新查找歌词 ↗');
      expect(restoreIndex, greaterThanOrEqualTo(0));
      expect(retryTextIndex, greaterThan(restoreIndex));
    });
  });

  // ── 有歌词行：排版（NativeHudDetail.cpp:253-281） ────────────────────────
  group('有歌词行（排版）', () {
    test('行高公式 = max(1,textRows)*47 + translationRows*26 + 32，top 逐行累加', () {
      final Map<String, Object?> document = doc(<Map<String, Object?>>[
        line(0, 'a'),
        line(1000, 'b', 't'),
        line(2000, ''),
      ]);
      final LyricsPanelLayout layout =
          buildLyricsLayout(document, 400, const FixtureGlyphs());
      expect(layout.rows.length, 3);
      expect(layout.rows[0].top, 0.0);
      expect(layout.rows[0].text, <String>['a']);
      expect(layout.rows[0].translation, isEmpty);
      expect(layout.rows[1].top, 79.0); // 1*47 + 0*26 + 32
      expect(layout.rows[1].translation, <String>['t']);
      expect(layout.rows[2].top, 184.0); // 79 + 1*47 + 1*26 + 32
      // 空文本用「•••」（NativeHudDetail.cpp:262-264）。
      expect(layout.rows[2].text, <String>['•••']);
      expect(layout.totalHeight, 184.0 + 1 * 47 + 0 * 26 + 32);
    });

    test('换行按 width-24：正文 34 bold、译文 17 regular', () {
      final Map<String, Object?> document = doc(<Map<String, Object?>>[
        line(0, 'abcdefgh', 'WXYZ'),
      ]);
      // limit = 20-24 < 0 → 每个字符独占一行。
      final LyricsPanelLayout narrow =
          buildLyricsLayout(document, 20, const FixtureGlyphs());
      expect(narrow.rows[0].text.length, 8);
      expect(narrow.rows[0].translation.length, 4);
      expect(narrow.rows[0].top, 0.0);

      // limit = 424-24=400 → 单行。
      final LyricsPanelLayout wide =
          buildLyricsLayout(document, 424, const FixtureGlyphs());
      expect(wide.rows[0].text, <String>['abcdefgh']);
      expect(wide.rows[0].translation, <String>['WXYZ']);
    });

    test('缓存语义：同 document 同 width 命中已缓存布局实例，宽或文档变化才重排', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document = doc(<Map<String, Object?>>[line(0, 'a'), line(1000, 'b')]);
      final LyricsPanelLayout first = buildLyricsLayout(document, 400, glyphs);
      final LyricsPanelLayout second = buildLyricsLayout(document, 400, glyphs);
      // 纯函数：同输入返回同布局（值等价）。
      expect(second.rows.map((LyricsPanelRow r) => r.top).toList(),
          first.rows.map((LyricsPanelRow r) => r.top).toList());
      expect(second.matches(document, 400), isTrue);

      final LyricsPanelModel cached = LyricsPanelModel(
        width: 400,
        document: document,
        index: 0,
        layout: first,
        prevScroll: 0,
      );
      final LyricsPanelView view = resolveLyricsView(cached, glyphs, motion: const FrozenMotion());
      expect(view.layoutRebuilt, isFalse);
      expect(identical(view.layout, first), isTrue);

      final LyricsPanelView widened =
          resolveLyricsView(cached.copyWith(width: 401), glyphs, motion: const FrozenMotion());
      expect(widened.layoutRebuilt, isTrue);
      expect(identical(widened.layout, first), isFalse);

      // 文档变化（键值改了）也要重排：QJsonObject 比较是深比较。
      final Map<String, Object?> changed = doc(<Map<String, Object?>>[line(0, 'a'), line(2000, 'b')]);
      final LyricsPanelView altered =
          resolveLyricsView(cached.copyWith(document: changed), glyphs, motion: const FrozenMotion());
      expect(altered.layoutRebuilt, isTrue);
    });

    test('重排时把 scroll 直接落在 active 行 top，并清空 browse/target/curve', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document =
          doc(<Map<String, Object?>>[line(0, 'a'), line(1000, 'b'), line(2000, 'c')]);
      final LyricsPanelView view = resolveLyricsView(
        LyricsPanelModel(width: 400, document: document, index: 2, browse: 210.0),
        glyphs,
        motion: const FrozenMotion(),
      );
      expect(view.layoutRebuilt, isTrue);
      expect(view.browse, isNull);
      expect(view.follow.scroll, view.layout!.rows[2].top);
      expect(view.follow.scroll, 158.0); // (47+32)*2
      expect(view.follow.curve, isNotNull);
      expect(view.follow.target, view.layout!.rows[2].top);
    });
  });

  // ── 有歌词行：绘制（NativeHudDetail.cpp:304-337） ────────────────────────
  group('有歌词行（绘制）', () {
    test('命令顺序：头部 → save/clip → 逐行 text+hit → restore → 底部两按钮', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document = doc(<Map<String, Object?>>[line(0, 'a'), line(1000, 'b')]);
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(
          x: 100,
          width: 400,
          title: '标题',
          artist: '艺人',
          document: document,
          index: 0,
          seekable: true,
          layout: buildLyricsLayout(document, 400, glyphs),
        ),
        glyphs,
        motion: const FrozenMotion(),
      );
      final List<String> ops =
          drawing.commands.map((List<Object?> c) => c[0]! as String).toList();
      expect(ops, <String>[
        'text', // 标题
        'text', // 艺人
        'text', // 关闭
        'save',
        'clip',
        'text', // 第 0 行正文
        'text', // 第 1 行正文
        'restore',
        'text', // 歌词偏移
        'text', // 回到当前句
      ]);
      // 底部按钮在 restore 之后（NativeHudDetail.cpp:335-337）。
      expect(drawing.commands[7], <Object?>['restore']);
      expect(drawing.commands[8][0], 'text');
      expect(drawing.commands[9][0], 'text');

      final List<String> actions = drawing.hits.map((Map<String, Object?> h) => h['action']! as String).toList();
      expect(actions, <String>['player:lyrics-close', 'player:lyric-line:0', 'player:lyric-line:1',
        'player:lyrics-offset', 'player:lyrics-follow']);
    });

    test('active 判定按 startMs 相等：相邻行同 startMs 都被判 active', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document = doc(<Map<String, Object?>>[
        line(5000, 'a'),
        line(5000, 'b'),
        line(9000, 'c'),
      ]);
      final LyricsPanelLayout layout = buildLyricsLayout(document, 400, glyphs);
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(
          width: 400,
          document: document,
          index: 1,
          layout: layout,
          prevScroll: layout.rows[1].top,
        ),
        glyphs,
        motion: const FrozenMotion(),
      );
      final List<List<Object?>> texts = textCommands(drawing);
      // texts[0]=标题, [1]=艺人, [2]=关闭, [3..]=正文三行。
      expect(alphaOf(texts[3]), 1.0);
      expect(alphaOf(texts[4]), 1.0); // 同 startMs → 也 active
      expect(alphaOf(texts[5]), closeTo(0.28, 1e-12));
    });

    test('edge alpha：y+height<top 或 y>bottom 跳过；贴边时 alpha 归零', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document = doc(<Map<String, Object?>>[
        line(0, 'a'),
        line(1000, 'b'),
      ]);
      final LyricsPanelLayout layout = buildLyricsLayout(document, 400, glyphs);
      // 卷到 202：行 0 的 y+height = 515+0-202+47 = 360 → edge=0（不跳过，仍在视口内）。
      final LyricsPanelDrawing top =
          paintLyricsPanel(
        LyricsPanelModel(
          width: 400,
          document: document,
          index: -1,
          layout: layout,
          prevScroll: 202,
        ),
        glyphs,
        motion: const FrozenMotion(),
      );
      final List<List<Object?>> topTexts = textCommands(top);
      expect(topTexts.length, 7); // 3 头部 + 2 行正文 + 2 底部按钮文字
      expect(alphaOf(topTexts[3]), 0.0);

      // 卷到 700：两行都在上方（行 0 的 y+height=-138，行 1 的 y+height=-59，均 < 360）→ 全跳过。
      final LyricsPanelDrawing up = paintLyricsPanel(
        LyricsPanelModel(
          width: 400,
          document: document,
          index: -1,
          layout: layout,
          prevScroll: 700,
        ),
        glyphs,
        motion: const FrozenMotion(),
      );
      expect(textCommands(up).length, 5); // 3 头部 + 2 底部按钮文字（正文全被 cull）

      // 反向卷到 -350：行 0 的 y=865 仍在视口且贴底，行 1 的 y=944 > 889 被跳过。
      final LyricsPanelDrawing down = paintLyricsPanel(
        LyricsPanelModel(
          width: 400,
          document: document,
          index: -1,
          layout: layout,
          prevScroll: -350,
        ),
        glyphs,
        motion: const FrozenMotion(),
      );
      expect(textCommands(down).length, 6); // 3 头部 + 行 0 + 2 底部按钮文字
      // edge = min((865+47-360)/55, (889-865)/55) = 24/55。
      expect(alphaOf(textCommands(down)[3]), closeTo(0.28 * (24 / 55), 1e-12));
    });

    test('译文 alpha 再乘 0.65；正文 alpha = (active?1:0.28)*edge', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document = doc(<Map<String, Object?>>[
        line(0, 'a', 'ta'),
        line(1000, 'b', 'tb'),
      ]);
      final LyricsPanelLayout layout = buildLyricsLayout(document, 400, glyphs);
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(
          width: 400,
          document: document,
          index: 0,
          layout: layout,
          prevScroll: layout.rows[0].top,
        ),
        glyphs,
        motion: const FrozenMotion(),
      );
      final List<List<Object?>> texts = textCommands(drawing);
      // 行 0：正文（active）→ 译文；行 1：正文（非 active）→ 译文。
      expect(texts[3][1], 'a');
      expect(alphaOf(texts[3]), 1.0);
      expect(texts[4][1], 'ta');
      expect(texts[4][4], 17.0);
      expect(texts[4][5], 'regular');
      expect(alphaOf(texts[4]), 0.65);
      // 译文 y = 行 y + textRows*47。
      expect(texts[4][3], texts[3][3] + 47);
      expect(texts[5][1], 'b');
      expect(alphaOf(texts[5]), closeTo(0.28, 1e-12));
      expect(alphaOf(texts[6]), closeTo(0.28 * 0.65, 1e-12));
    });

    test('正文 y = focusY + row.top - scroll，逐行步进 47', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document = doc(<Map<String, Object?>>[line(0, 'a', 'ta')]);
      final LyricsPanelLayout layout = buildLyricsLayout(document, 400, glyphs);
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(
          width: 400,
          document: document,
          index: 0,
          layout: layout,
          prevScroll: 40,
        ),
        glyphs,
        motion: const FrozenMotion(),
      );
      final List<List<Object?>> texts = textCommands(drawing);
      expect(texts[3][3], 515.0 + 0.0 - 40.0);
      expect(texts[3][4], 34.0);
      expect(texts[3][5], 'bold');
      expect(texts[4][3], 475.0 + 47.0);
    });

    test('hit 仅 seekable；几何 = (x, max(top,y), width, max(0,min(bottom,y+height+20)-hitY))', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document = doc(<Map<String, Object?>>[line(0, 'a'), line(1000, '')]);
      final LyricsPanelLayout layout = buildLyricsLayout(document, 400, glyphs);

      final LyricsPanelDrawing seekable = paintLyricsPanel(
        LyricsPanelModel(
          x: 100,
          width: 400,
          document: document,
          index: 0,
          seekable: true,
          layout: layout,
          prevScroll: 0,
        ),
        glyphs,
        motion: const FrozenMotion(),
      );
      expect(seekable.hits.where((Map<String, Object?> h) => (h['action']! as String).startsWith('player:lyric-line:')).toList(),
          <Map<String, Object?>>[
            <String, Object?>{
              'x': 100.0,
              'y': 515.0,
              'width': 400.0,
              'height': 67.0, // min(889, 515+47+20) - 515 = 67
              'action': 'player:lyric-line:0',
              'label': 'a',
            },
            <String, Object?>{
              'x': 100.0,
              'y': 594.0,
              'width': 400.0,
              'height': 67.0,
              'action': 'player:lyric-line:1',
              'label': '间奏',
            },
          ]);

      final LyricsPanelDrawing plain = paintLyricsPanel(
        LyricsPanelModel(
          x: 100,
          width: 400,
          document: document,
          index: 0,
          layout: layout,
          prevScroll: 0,
        ),
        glyphs,
        motion: const FrozenMotion(),
      );
      expect(plain.hits.where((Map<String, Object?> h) => (h['action']! as String).startsWith('player:lyric-line:')),
          isEmpty);
    });

    test('hit 顶部裁到 top=360、底部裁到 bottom=889', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document = doc(<Map<String, Object?>>[line(0, 'a')]);
      final LyricsPanelLayout layout = buildLyricsLayout(document, 400, glyphs);
      List<Map<String, Object?>> lineHits(double scroll) {
        final LyricsPanelDrawing drawing = paintLyricsPanel(
          LyricsPanelModel(
            width: 400,
            document: document,
            index: -1,
            seekable: true,
            layout: layout,
            prevScroll: scroll,
          ),
          glyphs,
          motion: const FrozenMotion(),
        );
        return drawing.hits
            .where((Map<String, Object?> h) => (h['action']! as String).startsWith('player:lyric-line:'))
            .toList();
      }

      // 顶部裁切：scroll=175 → y=340（未 cull），hitY=max(360,340)=360，高度 67→47。
      expect(lineHits(175).single['y'], 360.0);
      expect(lineHits(175).single['height'], 47.0);
      // 底部裁切：scroll=-350 → y=865，min(889,865+47+20)=889，高度 67→24。
      expect(lineHits(-350).single['y'], 865.0);
      expect(lineHits(-350).single['height'], 24.0);
      // 完全滚出视口（y+height<top）时该行连 hit 都不发。
      expect(lineHits(300), isEmpty);
    });

    test('每条 hit 六字段、键序 x/y/width/height/action/label，且不带 fixed', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document = doc(<Map<String, Object?>>[line(0, 'a', 't')]);
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(
          x: 100,
          width: 400,
          document: document,
          index: 0,
          seekable: true,
          isLocal: true,
          provider: 'local',
          layout: buildLyricsLayout(document, 400, glyphs),
        ),
        glyphs,
        motion: const FrozenMotion(),
      );
      expect(drawing.hits.length, 5);
      for (final Map<String, Object?> hit in drawing.hits) {
        expect(hit.keys.toList(), <String>['x', 'y', 'width', 'height', 'action', 'label']);
        expect(hit.containsKey('fixed'), isFalse);
      }
    });

    test('有歌词行时忽略 plainText（NativeHudDetail.cpp:254 分支只排 lines）', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document =
          doc(<Map<String, Object?>>[line(0, '第一句')], plainText: '不该出现的纯文本');
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(width: 400, document: document, index: 0),
        glyphs,
        motion: const FrozenMotion(),
      );
      final List<List<Object?>> texts = textCommands(drawing);
      expect(
          texts.any((List<Object?> t) => t[1] == '不该出现的纯文本'),
          isFalse);
      expect(texts.any((List<Object?> t) => t[1] == '第一句'), isTrue);
    });
  });

  // ── 固定动作与来源按钮（NativeHudDetail.cpp:223-228、336-337） ───────────
  group('固定动作与来源按钮', () {
    LyricsPanelDrawing frame({bool isLocal = false, String provider = '', bool hasLines = true}) {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document = hasLines
          ? doc(<Map<String, Object?>>[line(0, 'a')])
          : doc(const <Map<String, Object?>>[], plainText: '纯音乐');
      return paintLyricsPanel(
        LyricsPanelModel(
          x: 100,
          width: 400,
          title: '标题',
          artist: '艺人',
          document: document,
          index: 0,
          isLocal: isLocal,
          provider: provider,
        ),
        glyphs,
        motion: const FrozenMotion(),
      );
    }

    test('关闭按钮几何 x+width-60 / 278 / 60x40 / 14', () {
      final LyricsPanelDrawing drawing = frame();
      expect(hitsOf(drawing, 'player:lyrics-close'), <Map<String, Object?>>[
        <String, Object?>{
          'x': 440.0,
          'y': 278.0,
          'width': 60.0,
          'height': 40.0,
          'action': 'player:lyrics-close',
          'label': '关闭',
        }
      ]);
      expect(textCommands(drawing)[2], <Object?>['text', '关闭', 440.0, 287.0, 14.0, 'regular', 0, inkLight]);
    });

    test('来源按钮仅 isLocal && provider==local：x+156 / 914 / 120x32 / 13', () {
      final LyricsPanelDrawing shown = frame(isLocal: true, provider: 'local');
      expect(hitsOf(shown, 'player:lyrics-sources'), <Map<String, Object?>>[
        <String, Object?>{
          'x': 256.0,
          'y': 914.0,
          'width': 120.0,
          'height': 32.0,
          'action': 'player:lyrics-sources',
          'label': '歌词来源 ⌃',
        }
      ]);
      // 文字 y = 914 + (32-13)/2 - 4 = 919.5。
      expect(textCommands(shown)[3],
          <Object?>['text', '歌词来源 ⌃', 256.0, 919.5, 13.0, 'regular', 0, inkLight]);

      expect(hitsOf(frame(isLocal: true, provider: 'netease'), 'player:lyrics-sources'), isEmpty);
      expect(hitsOf(frame(isLocal: false, provider: 'local'), 'player:lyrics-sources'), isEmpty);
      expect(hitsOf(frame(), 'player:lyrics-sources'), isEmpty);
    });

    test('底部按钮几何：偏移 x/914/144x32，跟随 x+width-125/914/125x32', () {
      final LyricsPanelDrawing drawing = frame();
      expect(hitsOf(drawing, 'player:lyrics-offset'), <Map<String, Object?>>[
        <String, Object?>{
          'x': 100.0,
          'y': 914.0,
          'width': 144.0,
          'height': 32.0,
          'action': 'player:lyrics-offset',
          'label': '歌词偏移 ⌃',
        }
      ]);
      expect(hitsOf(drawing, 'player:lyrics-follow'), <Map<String, Object?>>[
        <String, Object?>{
          'x': 375.0,
          'y': 914.0,
          'width': 125.0,
          'height': 32.0,
          'action': 'player:lyrics-follow',
          'label': '回到当前句',
        }
      ]);
      final List<List<Object?>> texts = textCommands(drawing);
      expect(texts[texts.length - 2],
          <Object?>['text', '歌词偏移 ⌃', 100.0, 919.5, 13.0, 'regular', 0, inkLight]);
      expect(texts.last,
          <Object?>['text', '回到当前句', 375.0, 919.5, 13.0, 'regular', 0, inkLight]);
    });

    test('limited 截断规则：按 fit 二分到 width 内再 chop(1)+「…」', () {
      // 20 字标题，可用宽 15 → 二分得 15，再 left(14)+…。
      const String title = 'ABCDEFGHIJKLMNOPQRST';
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(
          x: 0,
          width: 100,
          title: title,
          document: doc(const <Map<String, Object?>>[], plainText: 'x'),
        ),
        const FixtureGlyphs(),
        motion: const FrozenMotion(),
      );
      expect(textCommands(drawing)[0][1], 'ABCDEFGHIJKLMN…');
      // 放得下就不截断。
      final LyricsPanelDrawing wide = paintLyricsPanel(
        LyricsPanelModel(
          x: 0,
          width: 400,
          title: title,
          document: doc(const <Map<String, Object?>>[], plainText: 'x'),
        ),
        const FixtureGlyphs(),
        motion: const FrozenMotion(),
      );
      expect(textCommands(wide)[0][1], title);
    });
  });

  // ── 索引 / 浏览 / 跟随（NativeHudDetail.cpp:282-303） ────────────────────
  group('索引与浏览', () {
    Map<String, Object?> fiveLines() => doc(<Map<String, Object?>>[
          line(0, 'a'),
          line(1000, 'b'),
          line(2000, 'c'),
          line(3000, 'd'),
          line(4000, 'e'),
        ]);

    test('lineUpdates 到 2 时重置 browse（每更新两行歌词重置歌词位置）', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document = fiveLines();
      final LyricsPanelLayout layout = buildLyricsLayout(document, 400, glyphs);

      LyricsPanelView step({
        required int index,
        required int lastIndex,
        required int lineUpdates,
        double? browse,
        double prevScroll = 0,
      }) =>
          resolveLyricsView(
            LyricsPanelModel(
              width: 400,
              document: document,
              index: index,
              lastIndex: lastIndex,
              lineUpdates: lineUpdates,
              browse: browse,
              layout: layout,
              prevScroll: prevScroll,
            ),
            glyphs,
            motion: const FrozenMotion(),
          );

      // 第一次换行：updates 1，browse 保留。
      final LyricsPanelView first = step(index: 0, lastIndex: -1, lineUpdates: 0, browse: 300);
      expect(first.lastIndex, 0);
      expect(first.lineUpdates, 1);
      expect(first.browse, 300);

      // 第二次换行：updates 归零且 browse 清空。
      final LyricsPanelView second = step(index: 1, lastIndex: 0, lineUpdates: 1, browse: 300);
      expect(second.lastIndex, 1);
      expect(second.lineUpdates, 0);
      expect(second.browse, isNull);
      expect(second.follow.target, layout.rows[1].top);

      // index 未变：不累计。
      final LyricsPanelView same = step(index: 1, lastIndex: 1, lineUpdates: 1, browse: 300);
      expect(same.lineUpdates, 1);
      expect(same.browse, 300);

      // index 变负：只更新 lastIndex，不累计。
      final LyricsPanelView negative = step(index: -1, lastIndex: 1, lineUpdates: 1, browse: 300);
      expect(negative.lastIndex, -1);
      expect(negative.lineUpdates, 1);
      expect(negative.browse, 300);
    });

    test('target = browse ?? layout[active].top；active 由注入 index clamp', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document = fiveLines();
      final LyricsPanelLayout layout = buildLyricsLayout(document, 400, glyphs);

      final LyricsPanelView browse = resolveLyricsView(
        LyricsPanelModel(width: 400, document: document, index: 3, layout: layout, browse: 260),
        glyphs,
        motion: const FrozenMotion(),
      );
      expect(browse.active, 3);
      expect(browse.follow.target, 260.0);

      final LyricsPanelView over = resolveLyricsView(
        LyricsPanelModel(width: 400, document: document, index: 99, layout: layout),
        glyphs,
        motion: const FrozenMotion(),
      );
      expect(over.active, 4);
      expect(over.follow.target, layout.rows[4].top);

      final LyricsPanelView under = resolveLyricsView(
        LyricsPanelModel(width: 400, document: document, index: -5, layout: layout),
        glyphs,
        motion: const FrozenMotion(),
      );
      expect(under.active, 0);
      expect(under.follow.target, 0.0);
    });

    test('browse 时曲线时长 0.18s，跟随时 0.42s', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document = fiveLines();
      final LyricsPanelLayout layout = buildLyricsLayout(document, 400, glyphs);

      final LyricsPanelView following = resolveLyricsView(
        LyricsPanelModel(width: 400, document: document, index: 2, layout: layout),
        glyphs,
        motion: const FrozenMotion(),
      );
      expect(following.follow.curve!.duration, 0.42);
      expect(following.follow.curve!.from, 0.0);
      expect(following.follow.curve!.target, layout.rows[2].top);

      final LyricsPanelView browsing = resolveLyricsView(
        LyricsPanelModel(width: 400, document: document, index: 2, layout: layout, browse: 500),
        glyphs,
        motion: const FrozenMotion(),
      );
      expect(browsing.follow.curve!.duration, 0.18);
    });
  });

  // ── followStep：纯状态机（Qt ReelCurve 语义，UiMotion.cpp:63-84） ───────
  group('followStep 纯状态机', () {
    test('reduced motion 直接跳到 target 且不建曲线', () {
      final LyricsFollowState state = followStep(
        prevScroll: 0,
        target: 100,
        browse: false,
        reduced: true,
        frameTime: 5,
      );
      expect(state.scroll, 100.0);
      expect(state.curve, isNull);
      expect(state.target, 100.0);
    });

    test('非 reduced：首帧不位移，只建立带初速的曲线；中间帧严格落在起点与终点之间', () {
      final LyricsFollowState first = followStep(
        prevScroll: 0,
        target: 100,
        browse: false,
        reduced: false,
        frameTime: 0,
      );
      expect(first.scroll, 0.0);
      expect(first.curve, isNotNull);
      expect(first.curve!.duration, 0.42);

      final LyricsFollowState mid = followStep(
        prevScroll: first.scroll,
        target: 100,
        browse: false,
        reduced: false,
        frameTime: 0.21,
        prevTarget: first.target,
        curve: first.curve,
      );
      expect(mid.scroll, greaterThan(0.0));
      expect(mid.scroll, lessThan(100.0));
      expect(mid.velocity, greaterThan(0.0));

      final LyricsFollowState end = followStep(
        prevScroll: mid.scroll,
        target: 100,
        browse: false,
        reduced: false,
        frameTime: 0.42,
        prevTarget: mid.target,
        curve: mid.curve,
      );
      expect(end.scroll, 100.0);
      expect(end.velocity, 0.0);
    });

    test('target 未变时不重建曲线（同一实例继续采样）', () {
      final LyricsFollowState first = followStep(
        prevScroll: 0,
        target: 100,
        browse: false,
        reduced: false,
        frameTime: 0,
      );
      final LyricsFollowState second = followStep(
        prevScroll: first.scroll,
        target: 100,
        browse: true,
        reduced: false,
        frameTime: 0.05,
        prevTarget: first.target,
        curve: first.curve,
      );
      expect(identical(second.curve, first.curve), isTrue);
      expect(second.target, 100.0);
    });

    test('切换 reduced 时清掉曲线并直达', () {
      final LyricsFollowState first = followStep(
        prevScroll: 0,
        target: 100,
        browse: false,
        reduced: false,
        frameTime: 0,
      );
      final LyricsFollowState jump = followStep(
        prevScroll: first.scroll,
        target: 240,
        browse: false,
        reduced: true,
        frameTime: 0.05,
        prevTarget: first.target,
        curve: first.curve,
      );
      expect(jump.scroll, 240.0);
      expect(jump.curve, isNull);
    });

    test('ReelCurve 端点与 49 点样条：末点精确落 target', () {
      final ReelCurve curve = const ReelMotion().curve(
        from: 0,
        target: 300,
        velocity: 0,
        start: 10,
        duration: 0.42,
      );
      final List<double> before = const ReelMotion().sample(curve, 9.9);
      expect(before[0], 0.0); // 采样被 clamp 到 t=0，位置即起点
      expect(before[1], greaterThan(0.0)); // 起点段速度非 0（样条首段斜率）
      // 明确越过末尾：10.5 处 (time-start)/duration > 1 → clamp 到 1 → position == 48 → 硬落末点。
      final List<double> after = const ReelMotion().sample(curve, 10.5);
      expect(after[0], 300.0);
      expect(after[1], 0.0);
      // 恰好落在 start+duration（10.42）：(0.42)/0.42 = 0.99999999999999989，乘 48 得
      // 47.999999999999992895 < 48，不进退位分支，按末段线性插值返回，速度取末段斜率
      // （Qt/src/UiMotion.cpp:77 的 clamp 与 :78-80 的 position >= 48 判定）。
      final List<double> atEnd = const ReelMotion().sample(curve, 10.42);
      expect(atEnd[0], closeTo(300.0, 1e-9));
      expect(atEnd[1], closeTo((curve.points[48] - curve.points[47]) * 48 / 0.42, 1e-9));
      expect(curve.points.length, 49);
      expect(curve.points.last, 300.0);
    });
  });

  // ── 滚轮：browse 与 plainOffset 增量（NativeHudInput.cpp:122-127） ────────
  group('滚轮与偏移', () {
    // 默认取 1000*0.56 == 560.0（二进制可精确表示），让落点判定不依赖舍入；
    // 1200*0.56 = 672.00000000000011（Qt 用同一 double 乘法，672 同样判为界外，
    // NativeHudInput.cpp:122 不做任何容差），该情形由「落点判定」测试显式覆盖。
    LyricsWheelInput wheel({
      double x = 560,
      double y = 500,
      double width = 1000,
      double scroll = 0,
      double? browse,
      int plainOffset = 0,
      double lastTop = 1000,
      double? distance,
      double delta = 0,
      int step = 0,
      String kind = 'song',
      bool lyricsMode = true,
    }) =>
        LyricsWheelInput(
          pointerX: x,
          pointerY: y,
          width: width,
          scroll: scroll,
          browse: browse,
          plainOffset: plainOffset,
          lastTop: lastTop,
          distance: distance,
          delta: delta,
          step: step,
          kind: kind,
          lyricsMode: lyricsMode,
        );

    test('落点判定 = lyricsMode && kind==song && x>=width*0.56 && y∈[360,889)', () {
      // 1000*0.56 == 560.0 精确可表示，故 560 满足闭下界、559.9 在界外。
      expect(wheel(x: 559.9).insideLyrics, isFalse);
      expect(wheel(x: 560).insideLyrics, isTrue);
      // 与 Qt 同一 double 运算：1200*0.56 = 672.00000000000011 > 672，
      // 故 672 判为界外（NativeHudInput.cpp:122 的 x >= width * 0.56 无容差）。
      expect(wheel(x: 672, width: 1200).insideLyrics, isFalse);
      expect(wheel(x: 672.1, width: 1200).insideLyrics, isTrue);
      expect(wheel(y: 359.9).insideLyrics, isFalse);
      expect(wheel(y: 360).insideLyrics, isTrue);
      expect(wheel(y: 888.9).insideLyrics, isTrue);
      expect(wheel(y: 889).insideLyrics, isFalse); // 上界开区间
      expect(wheel(kind: 'radio').insideLyrics, isFalse);
      expect(wheel(lyricsMode: false).insideLyrics, isFalse);
    });

    test('distance 优先于 delta：browse = clamp((browse ?? scroll) + distance, 0, lastTop)', () {
      final LyricsWheelResult r =
          applyLyricsWheel(wheel(scroll: 100, distance: 45, lastTop: 1000));
      expect(r.handled, isTrue);
      expect(r.browse, 145.0);
      // browse 已有值时为基准（Qt m_lyricsBrowse.value_or(m_lyricsScroll)）。
      expect(
          applyLyricsWheel(wheel(scroll: 100, browse: 700, distance: 45)).browse,
          745.0);
    });

    test('delta 路径：movement = (-delta / 120) * 65', () {
      expect(applyLyricsWheel(wheel(delta: -120)).browse, 65.0);
      expect(applyLyricsWheel(wheel(scroll: 100, delta: -120)).browse, 165.0);
      // movement = -130 → 100 - 130 < 0 → clamp 到 0。
      expect(applyLyricsWheel(wheel(scroll: 100, delta: 240)).browse, 0.0);
    });

    test('browse 上限 clamp 到 lastTop；空布局 lastTop=0 时恒为 0', () {
      expect(applyLyricsWheel(wheel(distance: 5000, lastTop: 1000)).browse, 1000.0);
      expect(applyLyricsWheel(wheel(distance: 5000, lastTop: 0)).browse, 0.0);
    });

    test('plainOffset = max(0, plainOffset + step)', () {
      expect(applyLyricsWheel(wheel(step: 3)).plainOffset, 3);
      expect(applyLyricsWheel(wheel(plainOffset: 5, step: 2)).plainOffset, 7);
      expect(applyLyricsWheel(wheel(plainOffset: 5, step: -8)).plainOffset, 0);
    });

    test('未命中歌词区：handled=false 且 browse/plainOffset 原样返回（Qt 直接 return）', () {
      final LyricsWheelResult r = applyLyricsWheel(
          wheel(x: 100, browse: 300, plainOffset: 4, distance: 50, step: 2));
      expect(r.handled, isFalse);
      expect(r.browse, 300.0);
      expect(r.plainOffset, 4);
    });

    test('lyricsLastTop：空布局/空 rows 为 0，否则等于最后一行 top（NativeHudInput.cpp:123）', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      expect(lyricsLastTop(null), 0.0);
      expect(
          lyricsLastTop(buildLyricsLayout(
              doc(const <Map<String, Object?>>[]), 400, glyphs)),
          0.0);
      // 第一行 47+32=79，故第二行 top=79。
      final LyricsPanelLayout layout = buildLyricsLayout(
          doc(<Map<String, Object?>>[line(0, 'a'), line(1000, 'b', 't')]), 400, glyphs);
      expect(lyricsLastTop(layout), 79.0);
    });
  });

  // ── ReelCurve：49 点样条与采样（UiMotion.cpp:63-84） ─────────────────────
  group('ReelCurve 样条', () {
    /// Qt UiMotion.cpp:64-70 的位置公式（初速先夹取到 ±cap）。
    double pointOf(double from, double target, double velocity, double duration, int index) {
      final double displacement = from - target;
      final double cap = (math.max(displacement.abs(), 1.0) * 12) / duration;
      final double impulse = velocity.clamp(-cap, cap) * duration;
      final double t = index / 48.0;
      return target + (displacement + (impulse + 10 * displacement) * t) * math.exp(-10 * t);
    }

    test('首点等于 from、共 49 点、末点硬落 target（i==48 不走公式）', () {
      final ReelCurve curve = const ReelMotion()
          .curve(from: 120, target: 400, velocity: 0, start: 0, duration: 0.42);
      expect(curve.points.length, 49);
      expect(curve.points.first, 120.0);
      expect(curve.points.last, 400.0);
      expect(curve.points[47], isNot(400.0));
    });

    test('初速夹取到 ±cap：velocity=±1e9 与 ±cap 逐点等价', () {
      const double duration = 0.42;
      final double cap = (math.max(100.0, 1.0) * 12) / duration;
      final ReelCurve huge = const ReelMotion()
          .curve(from: 0, target: 100, velocity: 1e9, start: 0, duration: duration);
      final ReelCurve atCap = const ReelMotion()
          .curve(from: 0, target: 100, velocity: cap, start: 0, duration: duration);
      for (int i = 0; i <= 48; i++) {
        expect(huge.points[i], closeTo(atCap.points[i], 1e-9));
        expect(huge.points[i], closeTo(pointOf(0, 100, cap, duration, i), 1e-9));
      }
      final ReelCurve belowCap = const ReelMotion()
          .curve(from: 0, target: 100, velocity: -1e9, start: 0, duration: duration);
      expect(belowCap.points[24], closeTo(pointOf(0, 100, -cap, duration, 24), 1e-9));
    });

    test('sample 半程：位置取整点 24，速度 = 段斜率 * 48 / duration', () {
      const double duration = 0.42;
      final ReelCurve curve = const ReelMotion()
          .curve(from: 0, target: 300, velocity: 0, start: 10, duration: duration);
      final List<double> mid =
          const ReelMotion().sample(curve, 10 + duration * 0.5);
      expect(mid[0], closeTo(curve.points[24], 1e-9));
      expect(
          mid[1],
          closeTo(
              (curve.points[25] - curve.points[24]) * 48 / duration, 1e-9));
    });

    test('sample 时间轴夹取：早于 start 取起点段，越过末尾取末点且速度为 0', () {
      const double duration = 0.42;
      final ReelCurve curve = const ReelMotion()
          .curve(from: 0, target: 300, velocity: 0, start: 10, duration: duration);
      final List<double> early = const ReelMotion().sample(curve, 9.0);
      expect(early[0], curve.points[0]);
      expect(
          early[1],
          closeTo((curve.points[1] - curve.points[0]) * 48 / duration, 1e-9));
      final List<double> late = const ReelMotion().sample(curve, 10.5);
      expect(late[0], 300.0);
      expect(late[1], 0.0);
    });
  });

  // ── 契约 ─────────────────────────────────────────────────────────────────
  group('契约', () {
    test('commands 是 flat array：每条非空且首元素是 op 字符串', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> document = doc(<Map<String, Object?>>[line(0, 'a', 't')]);
      final LyricsPanelDrawing drawing = paintLyricsPanel(
        LyricsPanelModel(width: 400, document: document, index: 0),
        glyphs,
        motion: const FrozenMotion(),
      );
      for (final List<Object?> command in drawing.commands) {
        expect(command, isNotEmpty);
        expect(command.first, isA<String>());
      }
      expect(opCommands(drawing, 'clip').length, 1);
      expect(opCommands(drawing, 'save').length, 1);
      expect(opCommands(drawing, 'restore').length, 1);
    });

    test('无歌词行时只裁一次且不画底部按钮；有歌词行时 clip 向左扩 4 向右扩 8', () {
      final FixtureGlyphs glyphs = const FixtureGlyphs();
      final Map<String, Object?> empty = doc(const <Map<String, Object?>>[], plainText: 'p');
      final LyricsPanelDrawing plain =
          paintLyricsPanel(LyricsPanelModel(x: 100, width: 400, document: empty), glyphs, motion: const FrozenMotion());
      expect(opCommands(plain, 'clip'), <List<Object?>>[
        <Object?>['clip', 100.0, 360.0, 400.0, 529.0]
      ]);

      final Map<String, Object?> withLines = doc(<Map<String, Object?>>[line(0, 'a')]);
      final LyricsPanelDrawing lyrics = paintLyricsPanel(
        LyricsPanelModel(x: 100, width: 400, document: withLines, index: 0),
        glyphs,
        motion: const FrozenMotion(),
      );
      expect(opCommands(lyrics, 'clip'), <List<Object?>>[
        <Object?>['clip', 96.0, 360.0, 408.0, 529.0]
      ]);
    });

    test('copyWith 保留全部状态字段，视图状态可回填下一帧', () {
      final LyricsPanelModel model = LyricsPanelModel(
        x: 100,
        width: 400,
        document: doc(const <Map<String, Object?>>[], plainText: 'p'),
        index: 3,
        status: 'ready',
        message: 'm',
        offsetMs: 200,
        seekable: true,
        localSource: 'local',
        provider: 'local',
        isLocal: true,
        title: 't',
        artist: 'a',
        dark: true,
        browse: 12,
        lastIndex: 2,
        lineUpdates: 1,
        plainOffset: 4,
        prevScroll: 88,
        reducedMotion: true,
        frameTime: 3.5,
      );
      final LyricsPanelModel copy = model.copyWith(width: 401);
      expect(copy.x, 100.0);
      expect(copy.width, 401.0);
      expect(copy.index, 3);
      expect(copy.status, 'ready');
      expect(copy.message, 'm');
      expect(copy.offsetMs, 200.0);
      expect(copy.seekable, isTrue);
      expect(copy.localSource, 'local');
      expect(copy.provider, 'local');
      expect(copy.isLocal, isTrue);
      expect(copy.title, 't');
      expect(copy.artist, 'a');
      expect(copy.dark, isTrue);
      expect(copy.browse, 12.0);
      expect(copy.lastIndex, 2);
      expect(copy.lineUpdates, 1);
      expect(copy.plainOffset, 4);
      expect(copy.prevScroll, 88.0);
      expect(copy.reducedMotion, isTrue);
      expect(copy.frameTime, 3.5);
      expect(copy.bounds, model.bounds);
    });
  });
}
