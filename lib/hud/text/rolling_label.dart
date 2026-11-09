// Faithful Dart port of UiMotion::ReelCurve and UiMotion::RollingLabel.
//
// Qt/src/UiMotion.{h,cpp} is the only authority for this module:
//
//  * ReelCurve builds 49 fixed samples and always ends exactly on the target,
//    so a reel lands on the requested value.                (UiMotion.cpp:63-84)
//  * RollingLabel keeps one slot per character and emits draw commands itself;
//    a stable label collapses to a single text command.     (UiMotion.cpp:122-254)
//  * emitted commands stay inside the 17-command flat array contract and are
//    never sorted or de-duplicated.
//  * a numeric reel uses a ten stop digit wheel with line = size * 1.1, a text
//    reel appends the incoming character to its own wheel with line = size * 1.326.
//  * the direction of a numeric reel comes from the leading integer prefix of the
//    old and new strings, never from parsing the whole string as a number.

import 'dart:math' as math;

/// Default reel duration in seconds (UiMotion.h:15,18).
const double kReelDuration = 0.46;

/// Retired slots fade out over duration * 0.65 (UiMotion.cpp:211).
const double kRetiredDurationFactor = 0.65;

/// Clip-box line height factor for a numeric reel (UiMotion.cpp:228).
const double kReelLineFactorNumeric = 1.1;

/// Clip-box line height factor for a text reel (UiMotion.cpp:228).
const double kReelLineFactorText = 1.326;

/// Horizontal slack added for the width of the clip box (UiMotion.cpp:239).
const double kReelClipPaddingFactor = 0.3;

/// Slack subtracted from the clip box origin (UiMotion.cpp:239).
const double kReelClipLeadFactor = 0.15;

/// Alpha at or below which a slot is skipped entirely (UiMotion.cpp:234).
const double kReelAlphaCutoff = 0.001;

/// Position tolerance below which a slot counts as settled (UiMotion.cpp:164).
const double kReelSettleEpsilon = 0.00001;

/// std::clamp for doubles.
///
/// num.clamp() is declared to return num, so using it inline would make every
/// expression below num-typed and fail to compile against the double fields.
double _clampDouble(double value, double low, double high) =>
    value < low ? low : (value > high ? high : value);

/// One sample of a reel curve: position plus the velocity carried forward.
class ReelSample {
  const ReelSample(this.position, this.velocity);

  final double position;
  final double velocity;
}

/// The 49 point reel curve, see UiMotion::ReelCurve.
class ReelCurve {
  ReelCurve({
    this.from = 0,
    this.target = 0,
    double velocity = 0,
    this.start = 0,
    this.duration = kReelDuration,
  }) {
    final displacement = from - target;
    final magnitude = displacement.abs() > 1 ? displacement.abs() : 1.0;
    final cap = (magnitude * 12) / duration;
    final impulse = _clampDouble(velocity, -cap, cap) * duration;
    for (var i = 0; i <= 48; i++) {
      final t = i / 48.0;
      _points[i] = i == 48
          ? target
          : target +
              (displacement + (impulse + 10 * displacement) * t) *
                  math.exp(-10 * t);
    }
  }

  final double from;
  final double target;
  final double start;
  final double duration;

  final List<double> _points = List<double>.filled(49, 0);

  /// Samples position and velocity at [time]; past the end the velocity is 0.
  ReelSample sample(double time) {
    final position = _clampDouble((time - start) / duration, 0, 1) * 48;
    if (position >= 48) {
      return ReelSample(_points[48], 0);
    }
    final index = position.floor();
    return ReelSample(
      _points[index] +
          (_points[index + 1] - _points[index]) * (position - index),
      ((_points[index + 1] - _points[index]) * 48) / duration,
    );
  }
}

/// Signature of the measuring callback handed to [RollingLabel.render].
///
/// Qt passes Glyphs::width here, so the callback must return the advance in
/// logical pixels for the same (text, size, weight, tracking) tuple.
typedef RollingMeasure = double Function(
  String text,
  double size,
  String weight,
  double tracking,
);

/// One animated character of a rolling label, see UiMotion::RollingLabel::Slot.
class RollingLabelSlot {
  RollingLabelSlot({
    required this.wheel,
    required this.position,
    required this.x,
    required this.width,
    required this.alpha,
  });

  List<String> wheel;
  ReelCurve position;
  ReelCurve x;
  ReelCurve width;
  ReelCurve alpha;

  bool hasMotionAt(double time) =>
      time < position.start + position.duration ||
      time < x.start + x.duration ||
      time < width.start + width.duration ||
      time < alpha.start + alpha.duration;
}

/// Owns per-character reel state and emits the draw commands for one label.
class RollingLabel {
  String _value = '';
  List<RollingLabelSlot> _slots = <RollingLabelSlot>[];
  List<RollingLabelSlot> _retired = <RollingLabelSlot>[];
  bool _initialized = false;

  /// True while any live or retired slot is still animating.
  bool active(double time) {
    for (final slot in _slots) {
      if (slot.hasMotionAt(time)) {
        return true;
      }
    }
    for (final slot in _retired) {
      if (slot.hasMotionAt(time)) {
        return true;
      }
    }
    return false;
  }

  /// The last text handed to [render].
  String get value => _value;

  /// Mirrors UiMotion::RollingLabel::render.
  ///
  /// [ink] is the raw color array that Glyphs::color consumes; it is nested
  /// unchanged inside every emitted text command.
  List<List<Object?>> render({
    required String next,
    required double x,
    required double y,
    required double size,
    required String weight,
    required double tracking,
    required double time,
    required bool animated,
    required bool numeric,
    required List<Object?> ink,
    required RollingMeasure measure,
  }) {
    final characters = next.runes.toList(growable: false);
    final oldNumber = leadingInteger(_value);
    final newNumber = leadingInteger(next);

    if (next != _value || !_initialized) {
      final previous = _slots;
      final fresh = <RollingLabelSlot>[];
      var cursor = 0.0;
      for (var i = 0; i < characters.length; i++) {
        final ch = String.fromCharCode(characters[i]);
        final width = measure(ch, size, weight, tracking) + tracking;
        final endX = cursor;
        cursor += width;
        if (i < previous.length && _initialized && animated) {
          final slot = previous[i];
          final position = slot.position.sample(time);
          final p = position.position;
          final velocity = position.velocity;
          final xx = slot.x.sample(time);
          final ww = slot.width.sample(time);
          final landed = slot.wheel[wrapIndex(p.floor(), slot.wheel.length)];
          if (landed != ch || (p - p.roundToDouble()).abs() > kReelSettleEpsilon) {
            if (numeric && isDigitCharacter(ch)) {
              var target = (p / 10).floor() * 10 + (double.tryParse(ch) ?? 0);
              if (newNumber > oldNumber && target < p) {
                target += 10;
              }
              if (newNumber < oldNumber && target > p) {
                target -= 10;
              }
              while (target < 0) {
                target += 10;
              }
              slot.wheel = digits();
              slot.position = ReelCurve(
                from: p < 0 ? p + 10 : p,
                target: target,
                velocity: velocity,
                start: time,
              );
            } else {
              final base = p.floor();
              final fraction = p - base;
              final wheel = <String>[
                slot.wheel[wrapIndex(base, slot.wheel.length)],
              ];
              if (fraction > kReelSettleEpsilon) {
                wheel.add(slot.wheel[wrapIndex(base + 1, slot.wheel.length)]);
              }
              if (wheel.last != ch) {
                wheel.add(ch);
              }
              final target = (wheel.length - 1).toDouble();
              slot.wheel = wheel;
              slot.position = ReelCurve(
                from: fraction,
                target: target,
                velocity: math.min(
                  math.max(0.0, velocity),
                  ((target - fraction) * 10000) / 460,
                ),
                start: time,
              );
            }
          }
          slot.x = ReelCurve(
            from: xx.position,
            target: endX,
            velocity: xx.velocity,
            start: time,
          );
          slot.width = ReelCurve(
            from: ww.position,
            target: width,
            velocity: ww.velocity,
            start: time,
          );
          slot.alpha = ReelCurve(
            from: slot.alpha.sample(time).position,
            target: 1,
            velocity: 0,
            start: time,
          );
          fresh.add(slot);
        } else {
          final digit =
              numeric && isDigitCharacter(ch) ? (double.tryParse(ch) ?? 0) : 0.0;
          fresh.add(RollingLabelSlot(
            wheel: numeric && isDigitCharacter(ch) ? digits() : <String>[ch],
            position: ReelCurve(from: digit, target: digit, start: time),
            x: ReelCurve(from: endX, target: endX, start: time),
            width: ReelCurve(from: width, target: width, start: time),
            alpha: ReelCurve(
              from: _initialized && animated ? 0 : 1,
              target: 1,
              start: time,
            ),
          ));
        }
      }

      _retired = <RollingLabelSlot>[];
      if (animated && previous.length > characters.length) {
        for (var i = characters.length; i < previous.length; i++) {
          final slot = previous[i];
          slot.alpha = ReelCurve(
            from: slot.alpha.sample(time).position,
            target: 0,
            start: time,
            duration: kReelDuration * kRetiredDurationFactor,
          );
          _retired.add(slot);
        }
      }
      _slots = fresh;
      _value = next;
      _initialized = true;
    }

    final commands = <List<Object?>>[];

    void emitText(String text, double left, double top) {
      commands.add(<Object?>[
        'text',
        text,
        left,
        top,
        size,
        weight,
        tracking,
        ink,
      ]);
    }

    if (!animated || !active(time)) {
      _retired = <RollingLabelSlot>[];
      emitText(next, x, y);
      return commands;
    }

    final line = size * (numeric ? kReelLineFactorNumeric : kReelLineFactorText);

    void draw(RollingLabelSlot slot) {
      final p = slot.position.sample(time).position;
      final xx = slot.x.sample(time).position;
      final width = slot.width.sample(time).position;
      final alpha = slot.alpha.sample(time).position;
      if (alpha <= kReelAlphaCutoff) {
        return;
      }
      commands.add(<Object?>['save']);
      commands.add(<Object?>['alpha', alpha]);
      commands.add(<Object?>[
        'clip',
        x + xx - size * kReelClipLeadFactor,
        y,
        width + size * kReelClipPaddingFactor,
        line,
      ]);
      final lower = p.floor();
      final upper = math.max(lower, p.ceil());
      for (var index = lower; index <= upper; index++) {
        emitText(
          slot.wheel[wrapIndex(index, slot.wheel.length)],
          x + xx,
          y + (index - p) * line,
        );
      }
      commands.add(<Object?>['restore']);
    }

    for (final slot in _slots) {
      draw(slot);
    }
    for (final slot in _retired) {
      draw(slot);
    }
    return commands;
  }
}

/// The ten stop digit wheel used by numeric reels (UiMotion.cpp:33-35).
List<String> digits() => <String>['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];

/// True for a single ASCII digit (UiMotion.cpp:29-31).
bool isDigitCharacter(String text) =>
    text.length == 1 && text.codeUnitAt(0) >= 0x30 && text.codeUnitAt(0) <= 0x39;

/// Positive modulo, matching UiMotion's wrapIndex (UiMotion.cpp:24-27).
int wrapIndex(int value, int length) => ((value % length) + length) % length;

/// Reads the leading integer prefix of [text] (UiMotion.cpp:37-55).
///
/// Supports an optional sign, an optional 0x/0X prefix and decimal digits, and
/// returns 0 when [text] does not start with an integer.
double leadingInteger(String text) {
  final match = _leadingIntegerPattern.firstMatch(text);
  if (match == null) {
    return 0;
  }
  var value = 0.0;
  final hexPrefix = match.group(2);
  if (hexPrefix != null && hexPrefix.isNotEmpty) {
    for (final unit in match.group(3)!.codeUnits) {
      value = value * 16 + (unit <= 0x39 ? unit - 0x30 : (unit | 0x20) - 0x61 + 10);
    }
  } else {
    value = double.tryParse(match.group(4) ?? '') ?? 0;
  }
  return match.group(1) == '-' ? -value : value;
}

final RegExp _leadingIntegerPattern =
    RegExp(r'^\s*([+-]?)(?:(0[xX])([0-9a-fA-F]+)|(\d+))');
