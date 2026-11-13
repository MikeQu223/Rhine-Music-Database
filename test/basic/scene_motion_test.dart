// Fixture tests for lib/basic/scene_motion.dart.
//
// Every expectation is derived from the Qt sources at baseline
// a959ded3f98d748059d8c3eaeaa8c41f7e17b9c6:
//   Qt/src/SceneMotion.h (93 lines),
//   Qt/src/SceneMotion.cpp (268 lines),
//   Qt/src/SceneLifetimePolicy.h (57 lines).
// The golden numbers were produced by an independent Python replica of the
// Qt formulas (see the SCENE-MOTION-105 report); the 1e-9 tolerance absorbs
// last-bit differences between the platform libm and the Dart VM for
// exp/sin/cos/sqrt. No device, build or render claim is made here.
//
// STATUS: written, deliberately NOT executed in this phase. The task contract
// forbids dart test / flutter test / analyze / build in this worktree.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/scene_motion.dart';

/// Real Qt curves from the Siren wall timeline, copied from
/// Qt/src/SceneMotion.cpp:35-39 (forwarded through `Decryption`).
const Curve growCurve = <CurveKey>[
  CurveKey(34.24, 0),
  CurveKey(34.4, 0.19),
  CurveKey(34.64, 0.57),
  CurveKey(34.96, 0.79),
  CurveKey(35.28, 0.92),
  CurveKey(35.6, 0.973),
  CurveKey(36.04, 1),
];

const Curve revealCurve = <CurveKey>[
  CurveKey(38.84, 0),
  CurveKey(38.92, 0.28),
  CurveKey(39, 0.51),
  CurveKey(39.16, 0.74),
  CurveKey(39.32, 0.94),
  CurveKey(39.56, 1),
];

const Curve retractCurve = <CurveKey>[
  CurveKey(37.72, 1),
  CurveKey(37.88, 0.72),
  CurveKey(38, 0.38),
  CurveKey(38.12, 0.22),
  CurveKey(38.24, 0.14),
  CurveKey(38.4, 0.075),
  CurveKey(38.64, 0.024),
  CurveKey(38.84, 0),
];

const Curve peakCurve = <CurveKey>[
  CurveKey(0, 0),
  CurveKey(1, 1),
  CurveKey(2, 0),
];

void _expectClose(double actual, double expected, {double tolerance = 1e-9}) {
  expect(
    actual,
    closeTo(expected, tolerance),
    reason: 'expected $expected, got $actual',
  );
}

void main() {
  group('smooth', () {
    test('clamps outside the unit interval and pins the end points', () {
      expect(smooth(-3), 0);
      expect(smooth(0), 0);
      expect(smooth(1), 1);
      expect(smooth(4), 1);
    });

    test('matches the quintic smootherstep values', () {
      _expectClose(smooth(0.25), 0.103515625, tolerance: 1e-15);
      _expectClose(smooth(0.5), 0.5, tolerance: 1e-15);
      _expectClose(smooth(0.6), 0.6825600000000001);
    });

    test('is symmetric around the half point', () {
      for (final double x in <double>[0.1, 0.25, 0.4, 0.75]) {
        _expectClose(smooth(x) + smooth(1 - x), 1, tolerance: 1e-12);
      }
    });

    test('is non-decreasing across the interval', () {
      double previous = smooth(0);
      for (int step = 1; step <= 200; step += 1) {
        final double current = smooth(step / 200);
        expect(current, greaterThanOrEqualTo(previous));
        previous = current;
      }
    });
  });

  group('ease', () {
    test('clamps outside the unit interval and pins the end points', () {
      expect(ease(-1), 0);
      expect(ease(0), 0);
      expect(ease(1), 1);
      expect(ease(2), 1);
    });

    test('matches the cubic smoothstep values', () {
      _expectClose(ease(0.25), 0.15625, tolerance: 1e-15);
      _expectClose(ease(0.6), 0.648);
    });

    test('is symmetric around the half point', () {
      for (final double x in <double>[0.2, 0.35, 0.45]) {
        _expectClose(ease(x) + ease(1 - x), 1, tolerance: 1e-12);
      }
    });
  });

  group('bell', () {
    test('peaks at one and matches the gaussian falloff', () {
      expect(bell(0, 0.55), 1);
      _expectClose(bell(0.55, 0.55), 0.6065306597126334);
      _expectClose(bell(1.1, 0.55), 0.1353352832366127);
      _expectClose(bell(1.1, 0.55), math.exp(-2));
    });

    test('is even in the value argument', () {
      _expectClose(bell(-0.55, 0.55), bell(0.55, 0.55), tolerance: 1e-15);
      _expectClose(bell(-2.4, 3.8), bell(2.4, 3.8), tolerance: 1e-15);
    });
  });

  group('archiveWave', () {
    test('is dormant outside the 22 s..26.35 s scan window', () {
      expect(archiveWave(12, 2, 0), 0);
      expect(archiveWave(12, 2, 21.999), 0);
      expect(archiveWave(12, 2, 22), 0);
      expect(archiveWave(12, 2, 26.35), 0);
      expect(archiveWave(12, 2, 30), 0);
    });

    test('matches the sampled packet train', () {
      _expectClose(archiveWave(12, 2, 23), 0.07835326587550881);
      _expectClose(archiveWave(12, 2, 26), -2.5412358627963508e-05);
    });

    test('shifts phase by 0.65 per lane', () {
      for (final double time in <double>[22.4, 23, 24.5, 26]) {
        _expectClose(
          archiveWave(12, 3, time),
          archiveWave(12.65, 2, time),
          tolerance: 1e-12,
        );
        _expectClose(
          archiveWave(12, 1, time),
          archiveWave(11.35, 2, time),
          tolerance: 1e-12,
        );
      }
    });
  });

  group('settlingWave', () {
    test('matches the damped ring samples', () {
      _expectClose(settlingWave(0, 30), 2.1500695558575535);
      _expectClose(settlingWave(2, 28), 1.9485335232395755);
    });

    test('depends on the absolute distance', () {
      _expectClose(settlingWave(-2, 28), settlingWave(2, 28), tolerance: 1e-15);
    });

    test('floors the envelope at -0.42 for far rows', () {
      _expectClose(settlingWave(16.1, 30), -0.42041205027458417);
    });

    test('is zero before its 25.05 s anchor', () {
      expect(settlingWave(0, 25), 0);
      expect(settlingWave(4, 20), 0);
    });

    test('stays finite at extreme distances', () {
      _expectClose(settlingWave(1000, 30), 0, tolerance: 1e-12);
    });
  });

  group('track', () {
    test('returns zero for an empty curve', () {
      expect(track(const <CurveKey>[], 3), 0);
    });

    test('holds the end values outside the key range', () {
      expect(track(growCurve, 34), 0);
      expect(track(growCurve, 34.24), 0);
      expect(track(growCurve, 36.04), 1);
      expect(track(growCurve, 40), 1);
    });

    test('interpolates a two key curve linearly when ends are free', () {
      const Curve line = <CurveKey>[CurveKey(0, 0), CurveKey(1, 1)];
      _expectClose(track(line, 0.25), 0.25, tolerance: 1e-15);
      _expectClose(track(line, 0.7), 0.7, tolerance: 1e-15);
    });

    test('interpolates a two key curve with a smoothstep when ends rest', () {
      const Curve line = <CurveKey>[CurveKey(0, 0), CurveKey(1, 1)];
      _expectClose(track(line, 0.25, stationaryEnds: true), 0.15625);
    });

    test('stationary ends flatten the first grow segment', () {
      _expectClose(track(growCurve, 34.3), 0.06904444280659996);
      _expectClose(
        track(growCurve, 34.3, stationaryEnds: true),
        0.04121241155659965,
      );
      _expectClose(track(growCurve, 34.32), 0.09186320754717014);
      _expectClose(
        track(growCurve, 34.32, stationaryEnds: true),
        0.06811320754717015,
      );
    });

    test('only the end tangents depend on stationaryEnds', () {
      _expectClose(track(growCurve, 34.4), 0.19);
      _expectClose(track(growCurve, 34.4, stationaryEnds: true), 0.19);
      _expectClose(track(growCurve, 34.5), 0.35493646714432475);
      _expectClose(
        track(growCurve, 34.5, stationaryEnds: true),
        0.35493646714432475,
      );
    });

    test('matches the reveal curve with a resting start', () {
      _expectClose(
        track(revealCurve, 39.08, stationaryEnds: true),
        0.6380635062611814,
      );
    });

    test('matches the retract curve with both end variants', () {
      _expectClose(track(retractCurve, 37.8), 0.8687653239930014);
      _expectClose(
        track(retractCurve, 37.8, stationaryEnds: true),
        0.903765323993003,
      );
    });

    test('zeroes the tangent at an interior turning point', () {
      _expectClose(track(peakCurve, 0.5), 0.625);
      _expectClose(track(peakCurve, 1.5), 0.625);
    });

    test('stays monotone between monotone keys', () {
      double previous = track(growCurve, 34.24, stationaryEnds: true);
      for (int step = 1; step <= 500; step += 1) {
        final double time = 34.24 + (36.04 - 34.24) * step / 500;
        final double current = track(growCurve, time, stationaryEnds: true);
        expect(current, greaterThanOrEqualTo(previous - 1e-12));
        previous = current;
      }
      _expectClose(previous, 1, tolerance: 1e-12);
    });
  });

  group('extraction', () {
    test('is zero until the first lift starts', () {
      expect(extraction(25), 0);
      expect(extraction(25.58), 0);
      expect(extraction(20), 0);
    });

    test('matches the three overlap samples', () {
      _expectClose(extraction(26.4), 0.4);
      _expectClose(extraction(28), 1.0762225856668426);
      _expectClose(extraction(30), 3.3905440000000002);
      _expectClose(extraction(32), 3.827792);
    });

    test('settles at the 4.05 detail page lift', () {
      _expectClose(extraction(40), 4.05, tolerance: 1e-12);
    });

    test('is non-decreasing', () {
      double previous = extraction(25);
      for (int step = 1; step <= 400; step += 1) {
        final double current = extraction(25 + 20 * step / 400);
        expect(current, greaterThanOrEqualTo(previous - 1e-12));
        previous = current;
      }
    });
  });

  group('cinematicField', () {
    test('starts from zero before the archive scan', () {
      expect(cinematicField(12, 2, 20), 0);
    });

    test('equals the archive wave while both blends are zero', () {
      for (final double time in <double>[22.2, 23, 24]) {
        _expectClose(
          cinematicField(12, 2, time),
          archiveWave(12, 2, time),
          tolerance: 1e-12,
        );
        _expectClose(
          cinematicField(9.5, 5, time),
          archiveWave(9.5, 5, time),
          tolerance: 1e-12,
        );
      }
    });

    test('matches the handoff samples', () {
      _expectClose(cinematicField(12, 2, 24.9), 0.8416288925874305);
      _expectClose(cinematicField(12, 2, 25.5), 2.0592017478432187);
    });

    test('equals the settling wave once the handoff completes', () {
      _expectClose(cinematicField(12, 2, 30), settlingWave(0, 30));
      _expectClose(cinematicField(12, 2, 30), 2.1500695558575535);
    });

    test('matches off centre samples', () {
      _expectClose(cinematicField(13.5, 4, 31.2), 0.5053946136602812);
      _expectClose(cinematicField(14, 0, 26.56), 0.49690966912704615);
    });

    test('keeps a quarter strength on far lanes', () {
      _expectClose(cinematicField(12, 50, 40), 0.5375000002628487);
    });

    test('honours the optional centre and focus arguments', () {
      _expectClose(
        cinematicField(14, 0, 30, 14, 0),
        settlingWave(0, 30),
        tolerance: 1e-12,
      );
      _expectClose(
        cinematicField(8, 6, 30, 8, 6),
        settlingWave(0, 30),
        tolerance: 1e-12,
      );
    });
  });

  group('returnStep', () {
    test('returns the angle unchanged without elapsed time', () {
      expect(returnStep(1.2, 0), 1.2);
      expect(returnStep(1.2, -1), 1.2);
    });

    test('decays at seven per second by default', () {
      _expectClose(returnStep(1, 0.1), 0.4965853037914095, tolerance: 1e-12);
    });

    test('decays at thirty five per second for reduced motion', () {
      _expectClose(
        returnStep(1, 0.1, true),
        0.0301973834223185,
        tolerance: 1e-12,
      );
    });

    test('snaps to exactly zero at or below one milliradian', () {
      expect(returnStep(0.002, 0.1), 0);
      expect(returnStep(-0.002, 0.1), 0);
    });

    test('keeps a value just above the snap threshold', () {
      _expectClose(returnStep(0.0015, 0.01), 0.0013985907298589223);
    });

    test('reaches zero within 600 frames from 1.2 radians', () {
      double angle = 1.2;
      int frames = 0;
      while (angle != 0.0 && frames < 600) {
        final double next = returnStep(angle, 1 / 60);
        expect(next.abs(), lessThanOrEqualTo(angle.abs()));
        angle = next;
        frames += 1;
      }
      expect(angle, 0);
      expect(frames, lessThan(600));
    });
  });

  group('Spring', () {
    test('starts at rest', () {
      final Spring spring = Spring();
      expect(spring.value, 0);
      expect(spring.velocity, 0);
    });

    test('matches the first two damped steps', () {
      final Spring spring = Spring(1, 0);
      spring.damp(0, 4.5, 1 / 60);
      _expectClose(spring.value, 0.9973242478031943, tolerance: 1e-12);
      _expectClose(spring.velocity, -0.3131134266358866, tolerance: 1e-12);
      spring.damp(0, 4.5, 1 / 60);
      _expectClose(spring.value, 0.9898141728888165, tolerance: 1e-12);
      _expectClose(spring.velocity, -0.580977884086914, tolerance: 1e-12);
    });

    test('folds an initial velocity into the first step', () {
      final Spring spring = Spring(0, 1);
      spring.damp(0, 4, 0.1);
      _expectClose(spring.value, 0.06703200460356394, tolerance: 1e-12);
      _expectClose(spring.velocity, 0.40219202762138356, tolerance: 1e-12);
    });

    test('converges on the target without crossing it early', () {
      final Spring spring = Spring(0, 0);
      for (int frame = 0; frame < 600; frame += 1) {
        spring.damp(1, 4.5, 1 / 60);
        expect(spring.value, lessThanOrEqualTo(1 + 1e-9));
      }
      _expectClose(spring.value, 1, tolerance: 1e-6);
      _expectClose(spring.velocity, 0, tolerance: 1e-4);
    });
  });

  group('Cell', () {
    test('keys lane before row like the Qt implementation', () {
      expect(const Cell(2, 12).key(), '2:12');
      expect(const Cell().key(), '0:0');
      expect(const Cell(-1, 0).key(), '-1:0');
    });

    test('compares by value', () {
      expect(const Cell(1, 2), const Cell(1, 2));
      expect(const Cell(1, 2), isNot(const Cell(2, 1)));
      expect(const Cell(1, 2).hashCode, const Cell(1, 2).hashCode);
      expect(<Cell>{const Cell(1, 2), const Cell(1, 2)}.length, 1);
    });

    test('renders its coordinates', () {
      expect(const Cell(2, 12).toString(), 'Cell(2, 12)');
    });
  });

  group('FieldPulse', () {
    test('defaults its time to zero', () {
      const FieldPulse pulse = FieldPulse(Cell(3, 4));
      expect(pulse.cell, const Cell(3, 4));
      expect(pulse.time, 0);
    });

    test('keeps the supplied time', () {
      const FieldPulse pulse = FieldPulse(Cell(0, 0), 31);
      expect(pulse.time, 31);
    });
  });

  group('ArchiveField', () {
    test('starts from the Qt defaults', () {
      final ArchiveField field = ArchiveField();
      expect(field.origin, const Cell());
      expect(field.scanTime, 29.1);
      expect(field.scanBlend, 0);
      expect(field.shoulder, 12);
      expect(field.laneFocus, 2);
      expect(field.idleGain, 0);
      expect(field.time, 0);
      expect(field.pulseGain, 1);
      expect(field.selectionWave, isTrue);
      expect(field.pulses, isEmpty);
    });

    test('matches the default settling samples', () {
      final ArchiveField field = ArchiveField();
      _expectClose(field.sample(0, 0), 0.0658857108662684);
      _expectClose(field.sample(3, 1), 0.2906387761928447);
      _expectClose(field.sample(5, 2), 1.0778397648173648);
      _expectClose(field.sample(5, 20), 0.2694599412043412);
      _expectClose(field.sample(12, 50), 0.5509285456249292);
    });

    test('adds the scan wave scaled by the blend', () {
      final ArchiveField field = ArchiveField()
        ..scanBlend = 1
        ..scanTime = 26;
      _expectClose(field.sample(0, 0), 0.007550716552704249);

      final double none = ArchiveField().sample(0, 0);
      final double half = (ArchiveField()
            ..scanBlend = 0.5
            ..scanTime = 26)
          .sample(0, 0);
      _expectClose(half, (none + field.sample(0, 0)) / 2, tolerance: 1e-12);
    });

    test('offsets the scan by the origin cell', () {
      final ArchiveField field = ArchiveField()
        ..scanBlend = 1
        ..scanTime = 26
        // Cell is lane-first, so this is lane 1 and row 2; the field then
        // scans global row 2, lane 1.
        ..origin = const Cell(1, 2);
      _expectClose(field.sample(0, 0), -0.007311931645324343);
    });

    test('adds one live pulse ripple', () {
      final ArchiveField field = ArchiveField()
        ..time = 31.6
        ..pulses = <FieldPulse>[const FieldPulse(Cell(0, 0), 31.0)];
      _expectClose(field.sample(0, 0), -0.07287136123657417);
      _expectClose(
        field.sample(0, 0) - ArchiveField().sample(0, 0),
        -0.13875707210284258,
      );
    });

    test('scales and gates the ripple', () {
      final ArchiveField field = ArchiveField()
        ..time = 31.6
        ..pulseGain = 0
        ..pulses = <FieldPulse>[const FieldPulse(Cell(0, 0), 31.0)];
      _expectClose(field.sample(0, 0), 0.0658857108662684);
      field.pulseGain = 1;
      field.selectionWave = false;
      _expectClose(field.sample(0, 0), 0.0658857108662684);
    });

    test('ignores pulses outside the 3.2 s window', () {
      final ArchiveField field = ArchiveField()
        ..time = 31.6
        ..pulses = <FieldPulse>[
          const FieldPulse(Cell(0, 0), 28),
          const FieldPulse(Cell(0, 0), 31.7),
        ];
      _expectClose(field.sample(0, 0), 0.0658857108662684);
    });

    test('clamps the summed ripple to plus or minus 0.6', () {
      final ArchiveField field = ArchiveField()
        ..time = 31.6
        ..pulses = List<FieldPulse>.filled(
          100,
          const FieldPulse(Cell(0, 0), 31.0),
        );
      _expectClose(field.sample(0, 0), -0.5341142891337316);
      _expectClose(
        field.sample(0, 0) - ArchiveField().sample(0, 0),
        -0.6,
        tolerance: 1e-12,
      );
    });

    test('adds idle breathing only when the gain is set', () {
      final ArchiveField idle = ArchiveField()..idleGain = 1;
      _expectClose(idle.sample(0, 0), 0.0658857108662684);
      idle.time = 2;
      _expectClose(idle.sample(0, 0), 0.16310627524539711);
      final ArchiveField still = ArchiveField()..time = 2;
      _expectClose(still.sample(0, 0), 0.0658857108662684);
    });

    test('moves the settling pull with the shoulder row', () {
      final ArchiveField field = ArchiveField();
      _expectClose(
        field.sample(5, 0) - field.sample(4, 0),
        0.04341426640295307,
      );
    });

    test('is a pure read', () {
      final ArchiveField field = ArchiveField()
        ..time = 31.6
        ..pulses = <FieldPulse>[const FieldPulse(Cell(0, 0), 31.0)];
      final double first = field.sample(1, 1);
      final double second = field.sample(1, 1);
      expect(first, second);
      expect(field.time, 31.6);
      expect(field.pulses, hasLength(1));
    });
  });
}
