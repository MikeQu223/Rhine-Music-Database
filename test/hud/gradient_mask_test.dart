// T30-C18 render atom tests, WRITTEN BUT NOT EXECUTED.
//
// The card forbids `flutter test`, `dart test`, `flutter analyze`, builds,
// formatters and code generation, so RED and GREEN are both recorded as
// "not executed" in the atom report. Every expectation below was derived by
// reading the Qt source cited beside it (Qt/src/Glyphs.cpp:775-812,
// Qt/src/Hud.cpp:18-19) and the dart:ui API of the pinned SDK.
//
// `ui.Gradient` exposes no from/to/centre accessors, so the right-mask segment
// geometry is pinned behaviourally in the last test: a 1x64 strip is rasterised
// and the PadSpread clamp regions are probed, which is the only observable
// definition of the endpoints.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/render/gradient_mask.dart';

/// Alpha byte exactly as dart:ui encodes it (`_floatToInt8`: round(x * 255)).
int alphaByte(ui.Color color) => (color.toARGB32() >> 24) & 0xFF;

/// Qt right-mask ramp, `base.alpha == 255`, steps 0..16.
///
/// `Qt/src/Glyphs.cpp:798-803`: `progress = step / 16`,
/// `eased = progress * progress * (3 - 2 * progress)`,
/// `alpha = round(baseAlphaF * eased * 255)`.
const List<int> expectedRamp255 = <int>[
  0, 3, 11, 24, 40, 59, 81, 104, 128, 151, 174, 196, 215, 231, 244, 252, 255,
];

/// Rasterises one right-mask gradient into a [width]x1 strip and returns the
/// per-pixel alpha bytes.
Future<List<int>> rasterizeMaskAlpha(
  ui.Color base,
  double start,
  double span,
  int width,
) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  final ui.Paint paint = ui.Paint()
    ..isAntiAlias = false
    ..shader = hudRightMaskGradient(base, start, span);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, width.toDouble(), 1), paint);
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = picture.toImageSync(width, 1);
  final ByteData? data =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  expect(data, isNotNull);
  final Uint8List bytes =
      data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return <int>[for (int x = 0; x < width; x++) bytes[x * 4 + 3]];
}

void main() {
  group('hudRightMaskSteps', () {
    test('is Qt MaskSteps (16) so a mask has 17 stops', () {
      // Qt/src/Glyphs.cpp:797-798.
      expect(hudRightMaskSteps, 16);
      expect(
        hudRightMaskStopColors(const ui.Color(0xFFFFFFFF)).length,
        hudRightMaskSteps + 1,
      );
    });
  });

  group('hudRightMaskEase', () {
    test('is the exact smoothstep of Qt/src/Glyphs.cpp:800', () {
      expect(hudRightMaskEase(0), 0.0);
      expect(hudRightMaskEase(1), 1.0);
      expect(hudRightMaskEase(0.5), 0.5);
      expect(hudRightMaskEase(0.25), 0.15625);
      expect(hudRightMaskEase(0.75), 0.84375);
    });

    test('matches progress * progress * (3 - 2 * progress) at every stop', () {
      for (int step = 0; step <= hudRightMaskSteps; step++) {
        final double progress = step / hudRightMaskSteps;
        expect(
          hudRightMaskEase(progress),
          progress * progress * (3 - 2 * progress),
        );
      }
    });

    test('is monotonic and symmetric around 0.5', () {
      double previous = hudRightMaskEase(0);
      for (int step = 1; step <= hudRightMaskSteps; step++) {
        final double eased = hudRightMaskEase(step / hudRightMaskSteps);
        expect(eased, greaterThan(previous));
        previous = eased;
      }
      for (int step = 0; step <= hudRightMaskSteps; step++) {
        final double progress = step / hudRightMaskSteps;
        expect(
          hudRightMaskEase(progress) + hudRightMaskEase(1 - progress),
          closeTo(1, 1e-12),
        );
      }
    });
  });

  group('hudRightMaskStopColors', () {
    test('returns exactly 17 stops', () {
      expect(hudRightMaskStopColors(const ui.Color(0xFFFFFFFF)).length, 17);
      expect(hudRightMaskStopColors(const ui.Color(0x00000000)).length, 17);
    });

    test('stop 0 is transparent and stop 16 keeps the base alpha', () {
      const List<ui.Color> bases = <ui.Color>[
        ui.Color(0xFFFFFFFF),
        ui.Color(0x80AABBCC),
        ui.Color.fromARGB(1, 0, 0, 0),
        ui.Color(0x00000000),
      ];
      for (final ui.Color base in bases) {
        final List<ui.Color> stops = hudRightMaskStopColors(base);
        expect(stops.first.a, 0.0);
        expect(stops.last.a, base.a);
        expect(alphaByte(stops.last), alphaByte(base));
      }
    });

    test('alpha bytes never decrease and stay within the base alpha', () {
      const List<ui.Color> bases = <ui.Color>[
        ui.Color(0xFFFFFFFF),
        ui.Color(0x80FFFFFF),
        ui.Color(0x33123456),
      ];
      for (final ui.Color base in bases) {
        final List<ui.Color> stops = hudRightMaskStopColors(base);
        int previous = -1;
        for (final ui.Color stop in stops) {
          final int byte = alphaByte(stop);
          expect(byte, greaterThanOrEqualTo(previous));
          expect(byte, lessThanOrEqualTo(alphaByte(base)));
          previous = byte;
        }
      }
    });

    test('only alpha changes: every stop keeps the base RGB', () {
      // Qt/src/Glyphs.cpp:801-802 copies baseColor and only calls setAlphaF.
      const ui.Color base = ui.Color(0xFF3C5A78);
      final List<ui.Color> stops = hudRightMaskStopColors(base);
      for (final ui.Color stop in stops) {
        expect(stop.r, base.r);
        expect(stop.g, base.g);
        expect(stop.b, base.b);
        expect(stop.toARGB32() & 0x00FFFFFF, base.toARGB32() & 0x00FFFFFF);
      }
    });

    test('reproduces the Qt ramp byte for byte when base alpha is 255', () {
      final List<ui.Color> stops =
          hudRightMaskStopColors(const ui.Color(0xFFFFFFFF));
      expect(stops.map(alphaByte).toList(growable: false), expectedRamp255);
    });

    test('scales the ramp by a non-255 base alpha', () {
      final List<ui.Color> stops =
          hudRightMaskStopColors(const ui.Color(0x80FFFFFF));
      expect(alphaByte(stops.first), 0);
      expect(alphaByte(stops.last), 128);
      // eased(0.5) == 0.5, so the middle stop is half of 128/255.
      expect(alphaByte(stops[8]), inInclusiveRange(63, 65));
    });

    test('a fully transparent base stays fully transparent everywhere', () {
      final List<ui.Color> stops =
          hudRightMaskStopColors(const ui.Color(0x00FFFFFF));
      for (final ui.Color stop in stops) {
        expect(stop.a, 0.0);
        expect(alphaByte(stop), 0);
      }
    });
  });

  group('hudRightMaskGradient', () {
    test('builds a shader for the wire segment', () {
      expect(
        hudRightMaskGradient(const ui.Color(0xFFFFFFFF), 40, 160),
        isA<ui.Gradient>(),
      );
    });

    testWidgets('runs from (start, 0) to (start + span, 0) with PadSpread',
        (WidgetTester tester) async {
      await tester.runAsync(() async {
        const ui.Color base = ui.Color(0xFFFFFFFF);
        final List<int> shifted = await rasterizeMaskAlpha(base, 10, 20, 64);
        // Qt/src/Glyphs.cpp:796: QLinearGradient(QPointF(start, 0), QPointF(start + span, 0)).
        expect(shifted[0], 0); // left of start: first (transparent) stop
        expect(shifted[2], 0);
        expect(shifted[19], inExclusiveRange(0, 255)); // inside the 16-step ramp
        expect(shifted[34], 255); // right of start + span: last stop
        expect(shifted[63], 255);

        // Moving start moves the ramp: at x == 2 the ramp has begun.
        final List<int> atOrigin = await rasterizeMaskAlpha(base, 0, 20, 64);
        expect(atOrigin[0], 0);
        expect(atOrigin[2], inExclusiveRange(0, 255));
        expect(atOrigin[34], 255);
      });
    });
  });

  group('hudBackgroundGradient constants', () {
    test('centre and radius match Qt/src/Glyphs.cpp:807', () {
      expect(hudBackgroundGradientCenterX, 979.2);
      expect(hudBackgroundGradientCenterY, 518.4);
      expect(hudBackgroundGradientRadius, 1100);
    });

    test('stops are exactly [0, .76, 1]', () {
      expect(hudBackgroundGradientStops.length, 3);
      expect(hudBackgroundGradientStops, <double>[0, .76, 1]);
    });

    test('fill rectangle is the Qt -4096..4096 square', () {
      // Qt/src/Glyphs.cpp:812: QRectF(-4096, -4096, 8192, 8192).
      expect(hudBackgroundGradientRect.left, -4096);
      expect(hudBackgroundGradientRect.top, -4096);
      expect(hudBackgroundGradientRect.width, 8192);
      expect(hudBackgroundGradientRect.height, 8192);
      expect(hudBackgroundGradientRect.right, 4096);
      expect(hudBackgroundGradientRect.bottom, 4096);
    });
  });

  group('hudBackgroundGradientColor', () {
    test('light stops are the exact Qt RGB triples', () {
      // Qt/src/Glyphs.cpp:809-811.
      expect(
        hudBackgroundGradientColor(dark: false, stop: 0).toARGB32(),
        0xFFE7E7E1,
      );
      expect(
        hudBackgroundGradientColor(dark: false, stop: 1).toARGB32(),
        0xFFE3E1DC,
      );
      expect(
        hudBackgroundGradientColor(dark: false, stop: 2).toARGB32(),
        0xFFE4DFDB,
      );
    });

    test('dark stops are the exact Qt RGB triples', () {
      // Qt/src/Glyphs.cpp:809-811.
      expect(
        hudBackgroundGradientColor(dark: true, stop: 0).toARGB32(),
        0xFF202A2F,
      );
      expect(
        hudBackgroundGradientColor(dark: true, stop: 1).toARGB32(),
        0xFF172125,
      );
      expect(
        hudBackgroundGradientColor(dark: true, stop: 2).toARGB32(),
        0xFF11181B,
      );
    });

    test('every stop is fully opaque', () {
      for (final bool dark in <bool>[false, true]) {
        for (int stop = 0; stop < 3; stop++) {
          final ui.Color color =
              hudBackgroundGradientColor(dark: dark, stop: stop);
          expect(color.a, 1.0);
          expect(alphaByte(color), 255);
        }
      }
    });

    test('an out-of-range stop index throws instead of being swallowed', () {
      expect(
        () => hudBackgroundGradientColor(dark: false, stop: -1),
        throwsRangeError,
      );
      expect(
        () => hudBackgroundGradientColor(dark: true, stop: 3),
        throwsRangeError,
      );
    });
  });

  group('hudBackgroundGradient', () {
    test('builds a radial shader for both themes', () {
      expect(hudBackgroundGradient(dark: false), isA<ui.Gradient>());
      expect(hudBackgroundGradient(dark: true), isA<ui.Gradient>());
    });
  });
}
