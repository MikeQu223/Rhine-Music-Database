// T04 contract test: text metrics, baselines, fit and calibrated color.
//
// Status: NOT EXECUTED. The T04 module contract forbids running
// flutter test, dart test, dart analyze or any build tooling, so RED/GREEN
// is unknown at authoring time. This file is a written-down expectation,
// not a pass claim.
//
// Harness: the flutter_test dependency already declared in pubspec.yaml (no
// pubspec change, no new package, no widget binding). No renderer, no
// production imports. The fixture is the machine-readable projection of
// docs/flutter-migration/contracts/text-color.md.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

const String fixturePath = 'test/fixtures/glyph_metrics.json';
const String baselineCommit = '8ed3067b0812eb2612f7841ec127a6e8ca93231b';
const String ellipsis = '…';

Map<String, dynamic> loadFixture() {
  final File file = File(fixturePath);
  if (!file.existsSync()) {
    fail('fixture missing: ' + fixturePath);
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

List<double> doubles(Object? raw) {
  return (raw as List<dynamic>)
      .map((dynamic v) => (v as num).toDouble())
      .toList();
}

/// Qt Glyphs::color: calibrated arrays run pow(v, 1.8) then the sRGB
/// encoding; alpha is copied verbatim; no marker means no conversion.
List<double> calibrated(List<Object?> rgba) {
  final List<double> out = <double>[
    (rgba[0] as num).toDouble(),
    (rgba[1] as num).toDouble(),
    (rgba[2] as num).toDouble(),
    rgba.length > 3 ? (rgba[3] as num).toDouble() : 1.0,
  ];
  final String marker = rgba.length > 4 ? rgba[4].toString() : '';
  if (marker.startsWith('calibrated')) {
    out[0] = encodeChannel(out[0]);
    out[1] = encodeChannel(out[1]);
    out[2] = encodeChannel(out[2]);
  }
  return out;
}

double encodeChannel(double v) {
  final double linear = math.pow(v, 1.8).toDouble();
  if (linear <= 0.0031308) {
    return 12.92 * linear;
  }
  return 1.055 * math.pow(linear, 1 / 2.4).toDouble() - 0.055;
}

/// Qt Glyphs::width over known per-UTF-16-code-unit advances.
double width(List<double> advances, double size, double tracking) {
  double result = 0.0;
  for (final double advance in advances) {
    result += advance * size + tracking;
  }
  return math.max(0.0, result - tracking);
}

/// Qt NativeHud::fit. Returns [emittedText, searchLength].
List<Object> fit(
  String value,
  List<double> advances,
  double size,
  double limit,
) {
  int length = value.length;
  if (width(advances, size, 0) > limit) {
    int low = 1;
    int high = length;
    while (low < high) {
      final int middle = (low + high + 1) ~/ 2;
      if (width(advances.sublist(0, middle), size, 0) <= limit) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    length = low;
  }
  if (length != value.length) {
    final int kept = length - 1 < 0 ? 0 : length - 1;
    return <Object>[value.substring(0, kept) + ellipsis, length];
  }
  return <Object>[value, length];
}

void main() {
  final Map<String, dynamic> fixture = loadFixture();

  group('contract fixture', () {
    test('declares the frozen baseline and font program', () {
      expect(fixture['schema'], 'rhine-hud-glyph-metrics/1');
      final Map<String, dynamic> source = fixture['source'] as Map<String, dynamic>;
      expect(source['baseline'], baselineCommit);
      final Map<String, dynamic> program = fixture['fontProgram'] as Map<String, dynamic>;
      expect(program['unitsPerEm'], 1000);
      expect(program['ascent'], 1044);
      expect(program['descent'], -282);
      expect(
        program['baselineFactor'],
        closeTo(
          (program['ascent'] as num) / (program['unitsPerEm'] as num),
          1e-12,
        ),
        reason: 'baselineFactor must equal ascent / unitsPerEm (1044 / 1000)',
      );
      expect(program['baselineFactor'], closeTo(1044 / 1000, 1e-12));
      expect(program['defaultGlyphAdvance'], 1.0);
      final Map<String, dynamic> table = program['glyphTable'] as Map<String, dynamic>;
      expect(table['glyphsPerWeight'], 1007);
      expect((table['weights'] as List<dynamic>).length, 4);
      final Map<String, dynamic> unusable =
          fixture['ordinaryTextUnusable'] as Map<String, dynamic>;
      expect(unusable['section'], 'text-color.md#6');
      expect((unusable['reasons'] as List<dynamic>).length, 7);
    });

    test('baseline offsets are size * 1.044', () {
      final Map<String, dynamic> program = fixture['fontProgram'] as Map<String, dynamic>;
      final double factor = (program['baselineFactor'] as num).toDouble();
      final List<dynamic> groups = fixture['baselineGroups'] as List<dynamic>;
      expect(groups.length, 4);
      for (final dynamic raw in groups) {
        final Map<String, dynamic> group = raw as Map<String, dynamic>;
        if (group.containsKey('size')) {
          expect(
            (group['size'] as num) * factor,
            closeTo((group['expectedOffset'] as num).toDouble(), 1e-9),
            reason: group['id'].toString(),
          );
        } else {
          expect(174 - 16 * factor, closeTo((group['expectedValue'] as num).toDouble(), 1e-9));
        }
      }
    });

    test('advance groups match the Qt width formula', () {
      for (final dynamic raw in fixture['advanceGroups'] as List<dynamic>) {
        final Map<String, dynamic> group = raw as Map<String, dynamic>;
        final List<double> advances = doubles(group['advances']);
        expect(advances.length, (group['text'] as String).length, reason: group['id'].toString());
        expect(
          width(advances, (group['size'] as num).toDouble(), (group['tracking'] as num).toDouble()),
          closeTo((group['expectedWidth'] as num).toDouble(), 1e-9),
          reason: group['id'].toString(),
        );
      }
    });

    test('fit reproduces the frozen binary search', () {
      final Map<String, dynamic> group = fixture['fitGroup'] as Map<String, dynamic>;
      final List<double> advances = doubles(group['advances']);
      final double size = (group['size'] as num).toDouble();
      final double limit = (group['limit'] as num).toDouble();
      final int searchLength = group['searchLength'] as int;
      expect(width(advances, size, 0), closeTo((group['originalWidth'] as num).toDouble(), 1e-9));
      final List<Object> result = fit(group['text'] as String, advances, size, limit);
      expect(result[1], searchLength);
      expect(result[0], group['fitted']);
      expect(
        width(advances.sublist(0, searchLength), size, 0),
        closeTo((group['prefixWidth'] as num).toDouble(), 1e-9),
      );
      final List<double> fitted = doubles(group['fittedAdvances']);
      expect(fitted.length, searchLength);
      expect(
        width(fitted, size, 0),
        closeTo((group['fittedWidth'] as num).toDouble(), 1e-9),
      );
      expect(width(fitted, size, 0) > limit, isTrue,
          reason: 'fit never re-measures the emitted ellipsis');
    });

    test('color conversion follows calibrated gamma 1.8 -> sRGB', () {
      for (final dynamic raw in fixture['colorGroups'] as List<dynamic>) {
        final Map<String, dynamic> group = raw as Map<String, dynamic>;
        final List<double> actual = calibrated(group['input'] as List<dynamic>);
        final List<double> expected = doubles(group['expected']);
        for (int i = 0; i < 4; i++) {
          expect(actual[i], closeTo(expected[i], 1e-9),
              reason: group['id'].toString() + ' channel ' + i.toString());
        }
      }
    });

    test('alpha is copied and never gamma-converted', () {
      final Map<String, dynamic> probe = fixture['alphaProbe'] as Map<String, dynamic>;
      final List<double> actual = calibrated(probe['input'] as List<dynamic>);
      final List<double> expected = doubles(probe['expected']);
      expect(actual[0], closeTo(expected[0], 1e-9));
      expect(actual[1], closeTo(expected[1], 1e-9));
      expect(actual[2], closeTo(expected[2], 1e-9));
      expect(actual[3], expected[3], reason: 'alpha is copied bit-for-bit');
    });
  });
}
