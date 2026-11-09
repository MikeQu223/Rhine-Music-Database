// Tests for the label fitting rule and the glyph resource parser.
//
// The expected values below are derived from the Qt sources only:
//   Qt/src/Glyphs.cpp:868-882  fit lambda (size loop, then truncation)
//   Qt/src/Glyphs.cpp:35-49    calibrated color conversion
//   Qt/src/Glyphs.cpp:190-265  svg path tokenizer
//   Qt/src/Glyphs.cpp:266-285  glyph lookup with the advance-1 fallback
//
// These tests are written but deliberately NOT executed in this phase.
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import '../../lib/hud/text/glyph_font.dart';
import '../../lib/hud/text/text_fitter.dart';

/// A width function that charges one unit per UTF-16 code unit times a factor,
/// so the size loop and the truncation loop can be driven deterministically.
double Function(String, double) _perUnit(double unitWidth) =>
    (String text, double size) => text.length * unitWidth;

void main() {
  group('fitSize', () {
    test('steps down by 2 until the measurement fits', () {
      expect(
        fitSize(
          maximum: 40,
          width: (double size) => size > 36 ? 1000.0 : 900.0,
        ),
        36,
      );
    });

    test('returns the maximum when it already fits', () {
      expect(fitSize(maximum: 40, width: (double size) => 100.0), 40);
    });

    test('stops at the minimum when every step overflows', () {
      expect(
        fitSize(maximum: 100, width: (double size) => 5000.0),
        kLabelMinSize,
      );
    });

    test('overshoots the minimum when the maximum sits just above it', () {
      // Qt tests 'size > 34' before it steps, so a maximum of 35 becomes 33 and
      // the loop then stops: the answer is below kLabelMinSize, exactly as in
      // Glyphs.cpp:870. "Never below the minimum" would be the wrong claim.
      expect(
        fitSize(maximum: 35, width: (double size) => 5000.0),
        33,
      );
    });
  });

  group('truncateToWidth', () {
    test('leaves a fitting string untouched', () {
      expect(
        truncateToWidth('AB', size: 10, width: _perUnit(10)),
        'AB',
      );
    });

    test('appends the ellipsis after dropping one extra code unit', () {
      // 20 per unit with a limit of 45 leaves 'AB' (40) as the longest prefix
      // that fits; the extra chop then reserves one unit for the ellipsis.
      final result = truncateToWidth(
        'ABCDE',
        size: 10,
        width: (String text, double size) => text.length * 20.0,
        limit: 45,
      );
      expect(result, 'A' + kEllipsis);
    });

    test('counts UTF-16 code units, not graphemes', () {
      final result = truncateToWidth(
        'A😀B',
        size: 10,
        width: (String text, double size) => text.length * 100.0,
        limit: 100,
      );
      // Three removals leave a single code unit, which the ellipsis branch
      // then chops away, so only the ellipsis survives.
      expect(result, kEllipsis);
    });

    test('splits a surrogate pair exactly like QString::chop', () {
      final result = truncateToWidth(
        '😀',
        size: 10,
        width: (String text, double size) => text.length * 100.0,
        limit: 100,
      );
      // The pair is two removable units exactly like QString::chop, so the
      // high surrogate is dropped and only the ellipsis remains.
      expect(result, kEllipsis);
      expect(result.codeUnits.first, 0x2026);
    });
  });

  group('fitLabel', () {
    test('picks the size against the original string, then truncates', () {
      // The size loop runs against the original string and steps off 40,
      // because 10 * 40 exceeds the 380 threshold; the chosen size then fits
      // the whole string without truncation.
      final label = fitLabel(
        'ABCDEFGHIJ',
        maximum: 40,
        width: (String text, double size) =>
            text.length * size > 380 ? 1000.0 : 200.0,
      );
      expect(label.size, 38);
      expect(label.text, 'ABCDEFGHIJ');
    });

    test('applies one limit to both the size loop and truncation', () {
      final label = fitLabel(
        'ABCDEFGHIJ',
        maximum: 40,
        limit: 100,
        width: (String text, double size) => text.length * 30.0,
      );
      // The parameterized 100 limit is narrower than every candidate (the
      // string alone measures 300), so the size loop bottoms out at the
      // minimum and truncation keeps 'ABC' (90 <= 100) before reserving the
      // ellipsis unit. Qt hardcodes 954 for both loops; this case holds only
      // because the limit is injectable.
      expect(label.size, kLabelMinSize);
      expect(label.text, 'AB' + kEllipsis);
    });

    test('keeps the Qt default limit in both loops', () {
      final label = fitLabel(
        'ABCDEFGHIJ',
        maximum: 40,
        width: (String text, double size) => text.length * 30.0,
      );
      // With the Qt default 954 both loops accept the whole string (300), so
      // the size stays at the maximum and nothing is chopped.
      expect(label.size, 40);
      expect(label.text, 'ABCDEFGHIJ');
    });
  });

  group('calibratedColor', () {
    test('leaves an unmarked color as plain sRGB', () {
      final color = calibratedColor(<Object?>[0.92, 0.92, 0.92, 1]);
      expect(color, const ui.Color(0xFFEBEBEB));
    });

    test('converts a calibrated linear color to sRGB', () {
      final color =
          calibratedColor(<Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite']);
      expect(color, const ui.Color(0xFFEFEFEF));
    });

    test('keeps pure white and pure black fixed points', () {
      expect(
        calibratedColor(<Object?>[1, 1, 1, 1, 'calibratedWhite']),
        const ui.Color(0xFFFFFFFF),
      );
      expect(
        calibratedColor(<Object?>[0, 0, 0, 1, 'calibratedWhite']),
        const ui.Color(0xFF000000),
      );
    });

    test('treats a missing alpha as fully opaque', () {
      expect(calibratedColor(<Object?>[1, 0, 0]), const ui.Color(0xFFFF0000));
    });

    test('applies the sRGB split at 0.0031308', () {
      // 0.01 ** 1.8 == 2.508e-4 and 0.001 ** 1.8 == 3.99e-6, both below the
      // split, so both take the 12.92 * linear branch and round to 1 and 0.
      final above = calibratedColor(<Object?>[0.01, 0, 0, 1, 'calibratedRGB']);
      final below = calibratedColor(<Object?>[0.001, 0, 0, 1, 'calibratedRGB']);
      expect(above.red, 1);
      expect(below.red, 0);
    });
  });

  group('parseSvgPath', () {
    test('parses absolute move and line commands', () {
      final path = parseSvgPath('M100 200L300 400Z');
      final bounds = path.getBounds();
      expect(bounds.left, 100);
      expect(bounds.top, 200);
      expect(bounds.right, 300);
      expect(bounds.bottom, 400);
    });

    test('treats lowercase commands as relative to the current point', () {
      final path = parseSvgPath('m100 200l10 10');
      final bounds = path.getBounds();
      expect(bounds.left, 100);
      expect(bounds.top, 200);
      expect(bounds.right, 110);
      expect(bounds.bottom, 210);
    });

    test('repeats a move as an implicit line', () {
      final path = parseSvgPath('M0 0 10 10');
      final bounds = path.getBounds();
      expect(bounds.right, 10);
      expect(bounds.bottom, 10);
    });

    test('honours horizontal and vertical shorthands', () {
      final path = parseSvgPath('M0 0H10V20Z');
      final bounds = path.getBounds();
      expect(bounds.right, 10);
      expect(bounds.bottom, 20);
    });

    test('stops at an unknown command and keeps what was built', () {
      final path = parseSvgPath('M0 0L10 10K20 20');
      final bounds = path.getBounds();
      expect(bounds.right, 10);
    });

    test('uses the non-zero fill rule', () {
      expect(parseSvgPath('M0 0L1 1Z').fillType, ui.PathFillType.nonZero);
    });
  });

  group('parseGlyphResources', () {
    const String glyphJson = r'{"regular":{"units":1000,"ascent":1044,'
        r'"descent":-282,"glyphs":{"A":{"advance":0.666,'
        r'"path":"M0 0L10 0L10 10Z"}}}}';
    const String letteringJson = r'{"access":{"text":"AB","weight":"Normal",'
        r'"units":1000,"letters":[{"width":0.5,"path":"M0 0L1 0"},'
        r'{"width":0.25,"path":"M0 0L2 0"}]}}';

    test('reads advances and outlines per weight', () {
      final fonts = parseGlyphResources(
        glyphJson: glyphJson,
        letteringJson: letteringJson,
      );
      expect(fonts.lookup('A').advance, 0.666);
      expect(fonts.weight('regular')!.units, 1000);
      expect(fonts.weight('regular')!.ascent, 1044);
      expect(fonts.weight('regular')!.descent, -282);
    });

    test('falls back to the advance-1 default glyph for a missing character',
        () {
      final fonts = parseGlyphResources(
        glyphJson: glyphJson,
        letteringJson: letteringJson,
      );
      expect(fonts.lookup('B').advance, kMissingGlyphAdvance);
      expect(fonts.hasOutline('B'), isFalse);
      expect(fonts.hasOutline('A'), isTrue);
    });

    test('reads boot lettering keys, texts and letter advances', () {
      final fonts = parseGlyphResources(
        glyphJson: glyphJson,
        letteringJson: letteringJson,
      );
      final art = fonts.letteringFor('access')!;
      expect(art.text, 'AB');
      expect(art.weight, 'Normal');
      expect(art.letters.map((LetteringGlyph g) => g.advance).toList(),
          <double>[0.5, 0.25]);
    });

    test('exposes the 1.044 baseline factor derived from ascent over units',
        () {
      expect(kBaselineFactor, 1.044);
      expect(kGlyphAscent / kGlyphUnits, kBaselineFactor);
    });

    test('reports symbol coverage through the injected probe', () {
      final fonts = parseGlyphResources(
        glyphJson: glyphJson,
        letteringJson: letteringJson,
        symbols: const _FixedSymbolCoverage(<int>{0x266A}),
      );
      expect(fonts.symbolSupports(0x266A), isTrue);
      expect(fonts.symbolSupports(0x41), isFalse);
    });
  });
}

class _FixedSymbolCoverage extends SymbolCoverage {
  const _FixedSymbolCoverage(this.supported);

  final Set<int> supported;

  @override
  bool supportsCodePoint(int codePoint) => supported.contains(codePoint);
}
