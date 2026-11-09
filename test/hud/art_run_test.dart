// Tests for the boot lettering layer (atom S06, lib/hud/text/art_run.dart).
//
// Every expectation is derived from the Qt port, not from the Dart code:
// artWidth() mirrors Glyphs::artWidth (Qt/src/Glyphs.cpp:403-412) and paintArt()
// mirrors Glyphs::art (Qt/src/Glyphs.cpp:565-588). The recording canvas below is
// what pins the two properties that are easiest to break by accident:
//
//   * the y scale is POSITIVE and y is the top of the artwork box, so there is no
//     size * 1.044 baseline offset anywhere in this file;
//   * the pen advance is advance * size + tracking, applied after each letter.
//
// The tests are written but not executed in this phase (running tests is
// forbidden here); no golden images are produced.

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import '../../lib/hud/text/art_run.dart';
import '../../lib/hud/text/glyph_font.dart';

/// Two-letter lettering fixture with the same shape as boot-lettering-art.json:
/// letters carry an em advance plus a y-DOWN outline in a 1000 unit em box.
const String _letteringJson = r'{"access":{"text":"AB","weight":"Normal",'
    r'"units":1000,"letters":['
    r'{"width":0.5,"path":"M100 100L900 100L900 800L100 800Z"},'
    r'{"width":0.25,"path":"M0 0L10 0L10 10Z"}]}}';

const String _glyphJson = r'{"regular":{"units":1000,"ascent":1044,'
    r'"descent":-282,"glyphs":{"A":{"advance":0.666,"path":"M0 0L10 0L10 10Z"}}}}';

GlyphFontSet _fonts() => parseGlyphResources(
      glyphJson: _glyphJson,
      letteringJson: _letteringJson,
    );

/// Records the canvas calls paintArt() makes, so the transform can be asserted
/// exactly instead of being taken on trust.
class _RecordingCanvas implements ui.Canvas {
  final List<List<Object?>> ops = <List<Object?>>[];

  @override
  void save() => ops.add(<Object?>['save']);

  @override
  void restore() => ops.add(<Object?>['restore']);

  @override
  void translate(double dx, double dy) => ops.add(<Object?>['translate', dx, dy]);

  @override
  void scale(double sx, [double? sy]) => ops.add(<Object?>['scale', sx, sy ?? sx]);

  @override
  void drawPath(ui.Path path, ui.Paint paint) =>
      ops.add(<Object?>['drawPath', path, paint]);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unstubbed canvas call: ' + invocation.memberName.toString());

  List<String> get shape =>
      ops.map((List<Object?> op) => op.first.toString()).toList();

  List<Object?> op(int index) => ops[index];
}

void main() {
  group('artWidth', () {
    test('sums the visible advances and subtracts exactly one tracking', () {
      final fonts = _fonts();
      // 0.5 * 1000 + 0.25 * 1000 == 750, and the trailing tracking is removed.
      expect(artWidth(fonts, 'access', 1000), 750);
      // (500 + 10) + (250 + 10) - 10 == 760.
      expect(artWidth(fonts, 'access', 1000, tracking: 10), 760);
    });

    test('a shortened run still subtracts the one trailing tracking', () {
      final fonts = _fonts();
      // One visible letter: 500 + 10 - 10 == 500, never 490.
      expect(artWidth(fonts, 'access', 1000, tracking: 10, count: 1), 500);
      expect(artWidth(fonts, 'access', 1000, count: 2), 750);
    });

    test('scales the advances with the size', () {
      final fonts = _fonts();
      // 0.5 * 100 + 0.25 * 100 == 75.
      expect(artWidth(fonts, 'access', 100), 75);
    });

    test('answers zero for an unknown key, an empty run or a zero count', () {
      final fonts = _fonts();
      expect(artWidth(fonts, 'missing', 1000), 0);
      expect(artWidth(GlyphFontSet.empty, 'access', 1000), 0);
      expect(artWidth(fonts, 'access', 1000, count: 0), 0);
    });

    test('keeps the literal Qt arithmetic when the size collapses to zero', () {
      final fonts = _fonts();
      // Qt evaluates (0 + 10) + (0 + 10) - 10 == 10; the formula is never
      // rewritten into advance * size * count + tracking * count - tracking.
      expect(artWidth(fonts, 'access', 0, tracking: 10), 10);
    });
  });

  group('paintArt', () {
    test('wraps every letter in its own save, translate, scale, draw, restore', () {
      final fonts = _fonts();
      final canvas = _RecordingCanvas();
      paintArt(canvas, fonts, 'access', 10, 20, 1000,
          tracking: 5, color: const ui.Color(0xFFFFFFFF));

      final letters = fonts.letteringFor('access')!.letters;
      // size / kGlyphUnits == 1.0 here, so the outline is drawn 1:1 and the
      // second letter starts at 10 + 0.5 * 1000 + 5 == 515.
      expect(canvas.ops.length, 10);
      expect(canvas.shape, <String>[
        'save', 'translate', 'scale', 'drawPath', 'restore',
        'save', 'translate', 'scale', 'drawPath', 'restore',
      ]);
      expect(canvas.op(1), <Object?>['translate', 10, 20]);
      expect(canvas.op(2), <Object?>['scale', 1.0, 1.0]);
      expect(canvas.op(3)[0], 'drawPath');
      expect(identical(canvas.op(3)[1], letters[0].path), isTrue);
      expect(canvas.op(3)[2], isA<ui.Paint>());
      expect(canvas.op(6), <Object?>['translate', 515, 20]);
      expect(canvas.op(7), <Object?>['scale', 1.0, 1.0]);
      expect(canvas.op(8)[0], 'drawPath');
      expect(identical(canvas.op(8)[1], letters[1].path), isTrue);
    });

    test('never applies the text baseline offset to lettering', () {
      final fonts = _fonts();
      final canvas = _RecordingCanvas();
      paintArt(canvas, fonts, 'access', 0, 200, 1000,
          color: const ui.Color(0xFFFFFFFF));
      // text() would translate to 200 + 1000 * 1.044 == 1244; lettering must
      // translate to exactly 200, because y is the top of the artwork box.
      expect(canvas.op(1), <Object?>['translate', 0, 200]);
    });

    test('keeps both scale factors positive and equal', () {
      final fonts = _fonts();
      final canvas = _RecordingCanvas();
      paintArt(canvas, fonts, 'access', 0, 0, 500,
          color: const ui.Color(0xFFFFFFFF));
      // A negative y scale (the text convention) would flip the artwork.
      expect(canvas.op(2), <Object?>['scale', 0.5, 0.5]);
      final scale = canvas.op(2);
      expect((scale[1] as double) > 0, isTrue);
      expect((scale[2] as double) > 0, isTrue);
    });

    test('reuses one paint carrying the requested color', () {
      final fonts = _fonts();
      final canvas = _RecordingCanvas();
      paintArt(canvas, fonts, 'access', 0, 0, 1000,
          color: const ui.Color(0xFF112233));
      final first = canvas.op(3)[2] as ui.Paint;
      final second = canvas.op(8)[2] as ui.Paint;
      expect(first.color, const ui.Color(0xFF112233));
      expect(identical(first, second), isTrue);
    });

    test('stops after count letters and draws nothing without a key', () {
      final fonts = _fonts();
      final one = _RecordingCanvas();
      paintArt(one, fonts, 'access', 0, 0, 1000,
          count: 1, color: const ui.Color(0xFFFFFFFF));
      expect(one.ops.length, 5);

      final none = _RecordingCanvas();
      paintArt(none, fonts, 'access', 0, 0, 1000,
          count: 0, color: const ui.Color(0xFFFFFFFF));
      expect(none.ops, isEmpty);

      final unknown = _RecordingCanvas();
      paintArt(unknown, fonts, 'missing', 0, 0, 1000,
          color: const ui.Color(0xFFFFFFFF));
      expect(unknown.ops, isEmpty);
    });

    test('advances the pen by advance * size + tracking after each letter', () {
      final fonts = _fonts();
      final canvas = _RecordingCanvas();
      paintArt(canvas, fonts, 'access', 100, 50, 200,
          tracking: 3, color: const ui.Color(0xFFFFFFFF));
      // 100 + 0.5 * 200 + 3 == 203.
      expect(canvas.op(6), <Object?>['translate', 203, 50]);
    });
  });
}
