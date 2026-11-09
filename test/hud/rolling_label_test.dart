// Tests for the reel curve and the rolling label state machine.
//
// Expected values are derived from Qt/src/UiMotion.{h,cpp} only:
//   UiMotion.cpp:63-84   ReelCurve construction and sampling
//   UiMotion.cpp:24-55   wrapIndex, isDigit, digits, leadingInteger
//   UiMotion.cpp:122-133 RollingLabel::active
//   UiMotion.cpp:139-254 RollingLabel::render
//
// These tests are written but deliberately NOT executed in this phase.
import 'package:flutter_test/flutter_test.dart';

import '../../lib/hud/text/rolling_label.dart';

double _measureUnit(String text, double size, String weight, double tracking) =>
    text.isEmpty ? 0 : 0.5 * size + tracking;

void main() {
  group('ReelCurve', () {
    test('starts at the from value', () {
      final curve = ReelCurve(from: 0, target: 10, start: 0);
      expect(curve.sample(0).position, closeTo(0, 1e-9));
    });

    test('lands exactly on the target and drops the velocity', () {
      final curve = ReelCurve(from: 0, target: 10, start: 0);
      final end = curve.sample(kReelDuration);
      expect(end.position, 10);
      expect(end.velocity, 0);
    });

    test('clamps a sample before the start time', () {
      final curve = ReelCurve(from: 0, target: 10, start: 5);
      expect(curve.sample(0).position, closeTo(0, 1e-9));
    });

    test('carries an interrupted velocity forward', () {
      final curve = ReelCurve(from: 0, target: 10, velocity: 40, start: 0);
      // A positive incoming velocity must overshoot the plain curve early on.
      final plain = ReelCurve(from: 0, target: 10, start: 0);
      expect(curve.sample(0.05).position,
          greaterThan(plain.sample(0.05).position));
    });

    test('caps the carried velocity by the displacement', () {
      // cap == (max(|displacement|, 1) * 12) / duration, so every velocity
      // above the cap yields exactly the same curve.
      final capped = ReelCurve(from: 0, target: 1, velocity: 100000, start: 0);
      final absurd = ReelCurve(from: 0, target: 1, velocity: 1e9, start: 0);
      expect(capped.sample(0).position, 0);
      expect(capped.sample(0.1).position, absurd.sample(0.1).position);
      expect(capped.sample(0.1).position, lessThanOrEqualTo(1.0));
    });
  });

  group('helpers', () {
    test('wrapIndex wraps in both directions', () {
      expect(wrapIndex(-1, 10), 9);
      expect(wrapIndex(11, 10), 1);
      expect(wrapIndex(0, 10), 0);
    });

    test('isDigitCharacter accepts exactly one ascii digit', () {
      expect(isDigitCharacter('7'), isTrue);
      expect(isDigitCharacter('77'), isFalse);
      expect(isDigitCharacter('a'), isFalse);
      expect(isDigitCharacter(''), isFalse);
    });

    test('leadingInteger reads the prefix only', () {
      expect(leadingInteger('12abc'), 12);
      expect(leadingInteger('-5'), -5);
      expect(leadingInteger(' 42'), 42);
      expect(leadingInteger('0x10'), 16);
      expect(leadingInteger('abc'), 0);
      expect(leadingInteger(''), 0);
    });

    test('digits exposes the ten stop numeric wheel', () {
      expect(digits().length, 10);
      expect(digits().first, '0');
      expect(digits().last, '9');
    });
  });

  group('RollingLabel', () {
    test('emits a single text command when animation is off', () {
      final label = RollingLabel();
      final commands = label.render(
        next: '42',
        x: 10,
        y: 20,
        size: 100,
        weight: 'bold',
        tracking: 0,
        time: 0,
        animated: false,
        numeric: true,
        ink: const <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite'],
        measure: _measureUnit,
      );
      expect(commands.length, 1);
      expect(commands.single, <Object?>[
        'text',
        '42',
        10,
        20,
        100,
        'bold',
        0,
        const <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite'],
      ]);
    });

    test('collapses to one text command once the reels settle', () {
      final label = RollingLabel();
      label.render(
        next: '42',
        x: 0,
        y: 0,
        size: 100,
        weight: 'bold',
        tracking: 0,
        time: 0,
        animated: true,
        numeric: true,
        ink: const <Object?>[1, 1, 1, 1],
        measure: _measureUnit,
      );
      final settled = label.render(
        next: '42',
        x: 0,
        y: 0,
        size: 100,
        weight: 'bold',
        tracking: 0,
        time: 10,
        animated: true,
        numeric: true,
        ink: const <Object?>[1, 1, 1, 1],
        measure: _measureUnit,
      );
      expect(settled.length, 1);
      expect(settled.single.first, 'text');
    });

    test('emits save, alpha, clip, text and restore while reeling', () {
      final label = RollingLabel();
      final commands = label.render(
        next: '4',
        x: 0,
        y: 0,
        size: 100,
        weight: 'bold',
        tracking: 0,
        time: 0,
        animated: true,
        numeric: true,
        ink: const <Object?>[1, 1, 1, 1],
        measure: _measureUnit,
      );
      expect(commands.first, <Object?>['save']);
      expect(commands[1].first, 'alpha');
      expect(commands[2].first, 'clip');
      expect(commands.last, <Object?>['restore']);
      final text = commands[3];
      expect(text[0], 'text');
      expect(text[1], '4');
    });

    test('keeps the numeric line factor at 1.1 and the text factor at 1.326',
        () {
      final numeric = RollingLabel();
      final numericCommands = numeric.render(
        next: '7',
        x: 0,
        y: 0,
        size: 100,
        weight: 'bold',
        tracking: 0,
        time: 0,
        animated: true,
        numeric: true,
        ink: const <Object?>[1, 1, 1, 1],
        measure: _measureUnit,
      );
      // 100.0 * 1.1 is 110.00000000000001 in binary64, exactly as
      // UiMotion.cpp:228 computes it, so the assertion needs a tolerance.
      expect(numericCommands[2][4], closeTo(100 * 1.1, 1e-12));

      final textLabel = RollingLabel();
      final textCommands = textLabel.render(
        next: 'x',
        x: 0,
        y: 0,
        size: 100,
        weight: 'bold',
        tracking: 0,
        time: 0,
        animated: true,
        numeric: false,
        ink: const <Object?>[1, 1, 1, 1],
        measure: _measureUnit,
      );
      expect(textCommands[2][4], closeTo(132.6, 1e-9));
    });

    test('rolls a digit forward through ten when the number grows', () {
      final label = RollingLabel();
      label.render(
        next: '9',
        x: 0,
        y: 0,
        size: 100,
        weight: 'bold',
        tracking: 0,
        time: 0,
        animated: true,
        numeric: true,
        ink: const <Object?>[1, 1, 1, 1],
        measure: _measureUnit,
      );
      final settle = RollingLabel();
      settle.render(
        next: '9',
        x: 0,
        y: 0,
        size: 100,
        weight: 'bold',
        tracking: 0,
        time: 0,
        animated: true,
        numeric: true,
        ink: const <Object?>[1, 1, 1, 1],
        measure: _measureUnit,
      );
      final commands = settle.render(
        next: '10',
        x: 0,
        y: 0,
        size: 100,
        weight: 'bold',
        tracking: 0,
        time: 0.46,
        animated: true,
        numeric: true,
        ink: const <Object?>[1, 1, 1, 1],
        measure: _measureUnit,
      );
      expect(commands.first.first, 'save');
      expect(label.value, '9');
      expect(settle.value, '10');

      // Halfway through the reel the single slot sits near position 10.92, so
      // it paints the wrapped wheel stops 10 and 11, i.e. the digits '0' and
      // '1': the reel travels forward through ten instead of jumping to '1'.
      final midway = settle.render(
        next: '10',
        x: 0,
        y: 0,
        size: 100,
        weight: 'bold',
        tracking: 0,
        time: 0.69,
        animated: true,
        numeric: true,
        ink: const <Object?>[1, 1, 1, 1],
        measure: _measureUnit,
      );
      final glyphs = midway
          .where((List<Object?> command) => command.first == 'text')
          .map((List<Object?> command) => command[1])
          .toList();
      expect(glyphs, contains('0'));
      expect(glyphs, contains('1'));
    });

    test('retires surplus slots with a shortened fade duration', () {
      expect(kReelDuration * kRetiredDurationFactor, closeTo(0.299, 1e-9));
    });

    test('active() is false before any render', () {
      expect(RollingLabel().active(0), isFalse);
    });
  });
}
