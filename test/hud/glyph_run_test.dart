// Tests for the glyph-run layer (atom A2, lib/hud/text/glyph_run.dart).
//
// Every expectation is derived from Qt, not from the Dart code:
// width()/bounds()/inset()/text() mirror Glyphs::width/bounds/inset/text
// (Qt/src/Glyphs.cpp:286-349,530-564), including the "advance * size +
// tracking" order and the single trailing tracking that width() removes.
//
// This file also pins the F15 fail-fast contract, which has no Qt counterpart
// because Qt always has QTextLayout available:
//   * a full GlyphText takes the decision (gate) and the shaper (port) as a
//     pair, so half-wired configurations no longer compile;
//   * a resource-only GlyphText refuses (StateError, also in release) every
//     class it can recognise without an injected table -- outside the BMP,
//     an unpaired surrogate, U+200D, a combining mark, a Hangul Jamo and a
//     non-whitelisted script -- and every code point the resource table
//     cannot outline, instead of painting default 1 em glyphs;
//   * the shaped branch measures with advanceEm/boundsEm and paints the port's
//     outline, never Skia's control-point hull.
//
// The tests are written but not executed in this phase (running tests is
// forbidden here); no golden images are produced.

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import '../../lib/hud/text/glyph_font.dart';
import '../../lib/hud/text/glyph_run.dart';

/// Lettering fixture: irrelevant to this file, but the loader wants a valid
/// document (same shape as boot-lettering-art.json).
const String _letteringJson = r'{"access":{"text":"AB","weight":"Normal",'
    r'"units":1000,"letters":['
    r'{"width":0.5,"path":"M100 100L900 100L900 800L100 800Z"}]}}';

/// Glyph fixture in font units (kGlyphUnits per em), y-up:
///   A: 0.5 em advance, rectangle 0..1000 x 0..700 (line-only, exact bounds);
///   B: 0.25 em advance, tiny triangle 0..10 x 0..10;
///   C: 0.4 em advance, a cubic whose control points (y up to 500) exceed its
///      true extremum (y max 375 at t = 0.5), so the analytic box and a Skia
///      Path.getBounds() hull are distinguishable on the resource branch;
///   D: 0.5 em advance, box 120..400 x 0..500, so a non-zero left side
///      bearing makes "first code unit only" observable.
///   E: U+0301 combining acute (zero advance), F: U+0416 Cyrillic,
///   G: U+1100 Hangul Jamo, H: U+4E00 Han, I: U+3042 Hiragana,
///   J: U+30A2 Katakana, K: U+AC00 Hangul syllable, L: '!' Common. All eight
///   are in the table so a property refusal cannot be satisfied by term (7).
const String _glyphJson = r'{"regular":{"units":1000,"ascent":1044,'
    r'"descent":-282,"glyphs":{'
    r'"A":{"advance":0.5,"path":"M0 0L1000 0L1000 700L0 700Z"},'
    r'"B":{"advance":0.25,"path":"M0 0L10 0L10 10Z"},'
    r'"C":{"advance":0.4,"path":"M0 0C0 500 500 500 500 0Z"},'
    r'"D":{"advance":0.5,"path":"M120 0L400 0L400 500L120 500Z"},'
    r'"\u0301":{"advance":0.0,"path":"M0 0L10 0L10 10Z"},'
    r'"\u0416":{"advance":1.0,"path":"M0 0L1000 0L1000 1000L0 1000Z"},'
    r'"\u1100":{"advance":1.0,"path":"M0 0L1000 0L1000 1000L0 1000Z"},'
    r'"\u4E00":{"advance":1.0,"path":"M0 0L1000 0L1000 1000L0 1000Z"},'
    r'"\u3042":{"advance":1.0,"path":"M0 0L1000 0L1000 1000L0 1000Z"},'
    r'"\u30A2":{"advance":1.0,"path":"M0 0L1000 0L1000 1000L0 1000Z"},'
    r'"\uAC00":{"advance":1.0,"path":"M0 0L1000 0L1000 1000L0 1000Z"},'
    r'"!":{"advance":1.0,"path":"M0 0L1000 0L1000 1000L0 1000Z"}}}}';

GlyphFontSet _fonts() => parseGlyphResources(
      glyphJson: _glyphJson,
      letteringJson: _letteringJson,
    );

/// Records the canvas calls paintText() makes, so the transform can be
/// asserted exactly instead of being taken on trust (same shape as the
/// recording canvas in art_run_test.dart).
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

/// Shaping port that records its calls and returns a fixed run.
class _RecordingPort implements ComplexTextPort {
  _RecordingPort({
    required this.advanceEm,
    required this.outlineEm,
    required this.boundsEm,
  });

  final double advanceEm;
  final ui.Path outlineEm;
  final ui.Rect boundsEm;
  final List<List<Object?>> calls = <List<Object?>>[];

  @override
  SimpleTextLayout layout(String text, String weight, double trackingEm) {
    calls.add(<Object?>[text, weight, trackingEm]);
    return SimpleTextLayout(
      advanceEm: advanceEm,
      outlineEm: outlineEm,
      boundsEm: boundsEm,
    );
  }
}

/// GlyphText with a fixed gate answer and a recording port.
GlyphText _full(
  GlyphFontSet fonts,
  _RecordingPort port, {
  required bool answer,
  List<List<Object?>>? gateCalls,
}) =>
    GlyphText(
      fonts,
      complex: port,
      gate: (String text, String weight) {
        gateCalls?.add(<Object?>[text, weight]);
        return answer;
      },
    );

void main() {
  group('resource-only configuration', () {
    final fonts = _fonts();
    final text = GlyphText.resourceOnly(fonts);

    test('accepts text Qt would not lay out', () {
      expect(text.requiresComplexLayout('', 'regular'), isFalse);
      expect(text.requiresComplexLayout('AB', 'regular'), isFalse);
      expect(text.isResourceOnly, isTrue);
    });

    test('throws for a code point outside the BMP instead of splitting it', () {
      // Qt: point > 0xffff (Glyphs.cpp:128). The resource path would paint two
      // lone surrogates, each with the 1 em missing-glyph advance.
      expect(
        () => text.requiresComplexLayout('\u{1F600}', 'regular'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            allOf(contains('U+1F600'), contains('resourceOnly')),
          ),
        ),
      );
      // 0x1F600 is outside the BMP in every Dart string form.
      expect(
        () => text.width('\u{1F600}', 16),
        throwsA(isA<StateError>()),
      );
    });

    test('throws for U+200D instead of painting a bare joiner', () {
      // Qt: point == 0x200d (Glyphs.cpp:128).
      expect(
        () => text.requiresComplexLayout('A\u200dB', 'regular'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('U+200D'),
          ),
        ),
      );
    });

    test('throws for a lone high surrogate instead of painting it', () {
      // Qt's toUcs4() replaces an invalid sequence with U+FFFD
      // (qstring.cpp:5811-5814); neither shipped face maps U+FFFD, so Qt's
      // term (7) routes the string to QTextLayout. The resource path would
      // paint the lone code unit as the default 1 em glyph, and text.runes
      // cannot see it.
      final String lone = String.fromCharCode(0xd800);
      expect(
        () => text.requiresComplexLayout(lone, 'regular'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('U+D800'),
          ),
        ),
      );
    });

    test('throws for a lone low surrogate instead of painting it', () {
      final String lone = String.fromCharCode(0xdc00);
      expect(
        () => text.requiresComplexLayout(lone, 'regular'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('U+DC00'),
          ),
        ),
      );
    });

    test('throws for a combining mark the table carries', () {
      // Qt term (2): Mark_NonSpacing. The fixture has U+0301, so term (7)
      // alone would not refuse it.
      expect(
        () => text.requiresComplexLayout('A\u0301', 'regular'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('U+0301'),
          ),
        ),
      );
    });

    test('throws for a non-whitelisted script the table carries', () {
      // Qt term (4): U+0416 is Script_Cyrillic; the fixture has its outline.
      expect(
        () => text.requiresComplexLayout('\u0416', 'regular'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('U+0416'),
          ),
        ),
      );
    });

    test('throws for a Hangul Jamo the table carries', () {
      // Qt term (3): Script_Hangul outside U+AC00..U+D7A3.
      expect(
        () => text.requiresComplexLayout('\u1100', 'regular'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('U+1100'),
          ),
        ),
      );
    });

    test('throws for a whitelisted code point the table lacks', () {
      // Qt term (7) is a coverage question: Q is Script_Latin, not a mark,
      // not a Jamo, but the fixture has no outline for it.
      expect(
        () => text.requiresComplexLayout('Q', 'regular'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('U+0051'),
          ),
        ),
      );
    });

    test('accepts whitelisted scripts the table carries', () {
      // A false positive in the property patterns would throw here; all five
      // code points are in the fixture table, so term (7) stays silent.
      expect(text.requiresComplexLayout('!', 'regular'), isFalse);
      expect(text.requiresComplexLayout('\u4E00', 'regular'), isFalse);
      expect(text.requiresComplexLayout('\u3042', 'regular'), isFalse);
      expect(text.requiresComplexLayout('\u30A2', 'regular'), isFalse);
      expect(text.requiresComplexLayout('\uAC00', 'regular'), isFalse);
    });

    test('measures plain text on the Qt per-code-unit path', () {
      // (0.5 * 100 + 2) + (0.25 * 100 + 2) - 2 == 77 (Glyphs.cpp:301-310).
      expect(text.width('AB', 100, tracking: 2), 77);
      // Empty text clamps at zero instead of going negative.
      expect(text.width('', 100, tracking: 2), 0);
      // 0.5 * 1000 == 500, one trailing tracking removed.
      expect(text.width('A', 1000, tracking: 10), 500);
    });
  });

  group('full configuration', () {
    final fonts = _fonts();
    final outline = ui.Path()..addRect(const ui.Rect.fromLTRB(0.0, 0.0, 1000.0, 1000.0));
    final port = _RecordingPort(
      advanceEm: 0.75,
      outlineEm: outline,
      boundsEm: const ui.Rect.fromLTRB(10.0, -20.0, 400.0, 300.0),
    );

    // The port is shared by every test in this group and each test asserts on
    // its own calls, so the log must not leak across tests: .single() would
    // throw on the second recorded call and the isEmpty expectation below
    // would see the earlier tests' calls.
    setUp(port.calls.clear);

    test('the gate alone decides, and a true answer uses the port', () {
      final gateCalls = <List<Object?>>[];
      final text = _full(fonts, port, answer: true, gateCalls: gateCalls);
      expect(text.isResourceOnly, isFalse);
      expect(text.width('A', 1000, tracking: 10), 750);
      // The gate sees the Qt weight and the string, exactly once per query.
      expect(gateCalls.single, <Object?>['A', 'regular']);
      // Qt converts tracking to font units before QTextLayout (Glyphs.cpp:297).
      expect(port.calls.single, <Object?>['A', 'regular', 10.0]);
    });

    test('the shaped width is advanceEm * size with no second tracking', () {
      final text = _full(fonts, port, answer: true);
      // 0.75 * 1000 == 750; tracking is already inside the port's advance.
      expect(text.width('A', 1000, tracking: 40), 750);
      expect(port.calls.single[2], 40.0);
    });

    test('bounds and inset use the port\'s tight rectangle, never the hull', () {
      final text = _full(fonts, port, answer: true);
      // outlineEm.getBounds() would answer (0, 0, 1000, 1000); the port says
      // the tight box is (10, -20, 400, 300), so a hull fallback is visible.
      // Mapped at size 1000: x + left*size/1000, 1044 - bottom*size/1000.
      expect(
        text.bounds('A', 1000),
        const ui.Rect.fromLTRB(10.0, 744.0, 400.0, 1064.0),
      );
      // inset() keeps only x * size / 1000, without the baseline translate.
      expect(text.inset('A', 1000), 10.0);
      // The hull would map to (0, 44, 1000, 1044), a 1000 unit tall box.
      expect(
        text.bounds('A', 1000),
        isNot(const ui.Rect.fromLTRB(0.0, 44.0, 1000.0, 1044.0)),
      );
    });

    test('paints the shaped outline as one run under the Qt transform', () {
      final text = _full(fonts, port, answer: true);
      final canvas = _RecordingCanvas();
      text.paintText(
        canvas,
        'A',
        5.0,
        7.0,
        1000.0,
        tracking: 3.0,
        ink: ui.Paint(),
      );
      expect(canvas.shape, <String>['save', 'translate', 'scale', 'drawPath', 'restore']);
      expect(canvas.op(1), <Object?>['translate', 5.0, 7.0 + 1000.0 * 1.044]);
      expect(canvas.op(2), <Object?>['scale', 1.0, -1.0]);
      expect(identical(canvas.op(3)[1], outline), isTrue);
    });

    test('a real port with a null gate fails before shaping', () {
      // The constructor pair contract is not enforced by a release assert:
      // requiresComplexLayout must refuse before it silently ignores the port.
      final text = GlyphText(fonts, complex: port, gate: null);
      expect(text.isResourceOnly, isTrue);
      expect(
        () => text.requiresComplexLayout('A', 'regular'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('null gate'),
          ),
        ),
      );
      expect(port.calls, isEmpty);
    });

    test('a false answer keeps even a surrogate pair on the resource path', () {
      // The real gate (fallback_shaper.requiresFallback) answers true here; a
      // hand-built gate that lies is the caller's bug, and the pair contract
      // only guarantees the port exists, not that the gate is wise.
      final text = _full(fonts, port, answer: false);
      // Two UTF-16 units, 1 em each, size 10 -> 20.
      expect(text.width('\u{1F600}', 10), 20);
      expect(port.calls, isEmpty);
    });
  });

  group('resource-path geometry', () {
    final fonts = _fonts();
    final text = GlyphText.resourceOnly(fonts);

    test('bounds map the analytic tight box and union per code unit', () {
      expect(
        text.bounds('A', 1000),
        const ui.Rect.fromLTRB(0.0, 344.0, 1000.0, 1044.0),
      );
      // B starts after A's 500 unit advance (500..510 wide, 1034..1044 tall),
      // but A's own box already reaches x = 1000, so the union is still A's
      // box: Qt unions each glyph's boundingRect() (Glyphs.cpp:325-336).
      expect(
        text.bounds('AB', 1000),
        const ui.Rect.fromLTRB(0.0, 344.0, 1000.0, 1044.0),
      );
      // Reversed, the pen starts from B's 0.25 em advance and A lands at
      // x = 250, so the union really does extend past A's own right edge
      // (Glyphs.cpp:335 advances the pen by advance * size only).
      expect(
        text.bounds('BA', 1000),
        const ui.Rect.fromLTRB(0.0, 344.0, 1250.0, 1044.0),
      );
      // C's cubic peaks at y = 375 (t = 0.5), not at its control-point y = 500:
      // Qt answers QPainterPath::boundingRect() (Glyphs.cpp:327-330), so the
      // tight box is (0, 669, 500, 1044) at size 1000, while a Skia
      // getBounds() fallback would answer (0, 544, 500, 1044).
      expect(
        text.bounds('C', 1000),
        const ui.Rect.fromLTRB(0.0, 669.0, 500.0, 1044.0),
      );
      // No outline anywhere: Qt returns a default (null) QRectF, ported as zero.
      expect(text.bounds('', 1000), ui.Rect.zero);
    });

    test('inset reads only the first code unit, without the baseline', () {
      expect(text.inset('AB', 1000), 0.0);
      expect(text.inset('', 1000), 0.0);
      // Only the FIRST code unit is read (Glyphs.cpp:339-349 asks character 0):
      // D's left edge is 120 while A's is 0, so a min-over-string or
      // last-code-unit implementation would answer 0 here instead of 120.
      expect(text.inset('DA', 1000), 120.0);
    });

    test('paintText advances the pen by advance * size + tracking', () {
      final canvas = _RecordingCanvas();
      text.paintText(canvas, 'AB', 0.0, 0.0, 1000.0, tracking: 10.0, ink: ui.Paint());
      expect(
        canvas.shape,
        <String>[
          'save',
          'translate',
          'scale',
          'drawPath',
          'restore',
          'save',
          'translate',
          'scale',
          'drawPath',
          'restore',
        ],
      );
      // First glyph at x = 0, second at 0 + 0.5 * 1000 + 10.
      expect(canvas.op(1), <Object?>['translate', 0.0, 1044.0]);
      expect(canvas.op(6), <Object?>['translate', 510.0, 1044.0]);
      expect(canvas.op(2), <Object?>['scale', 1.0, -1.0]);
    });

    test('trackingEm converts tracking to font units and guards size 0', () {
      expect(text.trackingEm(10.0, 1000.0), 10.0);
      expect(text.trackingEm(10.0, 100.0), 100.0);
      expect(text.trackingEm(10.0, 0.0), 0.0);
    });
  });
}
