/// Pure motion math shared by the archive wall, ported from the Qt client.
///
/// Source of truth (fixed; `git hash-object` of each file is identical at
/// commits 8ed3067b0812eb2612f7841ec127a6e8ca93231b,
/// eeda62c6596b5826cb08f878350ac6c5ff0d3fac and
/// a959ded3f98d748059d8c3eaeaa8c41f7e17b9c6):
///
///  * `Qt/src/SceneMotion.h`, 93 lines, blob
///    c8136ec5cb8a7dd9fa0aaa1a0bc1f7237964937e
///  * `Qt/src/SceneMotion.cpp`, 268 lines, blob
///    2fa0a75508b5bc53742f1b2596a0af183804c4b1
///  * `Qt/src/SceneLifetimePolicy.h`, 57 lines, blob
///    441817506f2050b92ba7e851621e9e8089cf659d, for [returnStep]
///
/// Scope. Only the pure functions are ported: [track], [smooth], [ease],
/// [bell], [archiveWave], [settlingWave], [extraction], [cinematicField],
/// [returnStep], [Spring], [Cell], [FieldPulse] and [ArchiveField]. The Qt
/// `ThemeWave`, `Decryption` and `BootTimeline` objects are stateful
/// presentation code and stay outside this module: nothing here integrates
/// time, renders, allocates GPU work or touches a device.
///
/// Conventions copied verbatim from the Qt source:
///
///  * Every progress value is clamped to `[0, 1]` before evaluation
///    (SceneMotion.cpp:9-11).
///  * [track] expects keys ordered by strictly increasing [CurveKey.time], as
///    the Qt callers provide; the interpolation does not clamp interior values
///    to the neighbouring key range.
///  * Times are seconds on the single Qt shot timeline: the archive wave runs
///    from 22 s to 26.35 s, the settling wave is anchored at 25.05 s.
library;

import 'dart:math' as math;

/// Absolute angle magnitude, in radians, treated as "close enough to zero".
///
/// Literal `0.001` from `SceneLifetimePolicy.h:37`; not a Qt symbol name.
const double kReturnAngleSnap = 0.001;

/// Exponential decay rate of the return-to-centre step, in 1/s.
///
/// Literal `7` from `SceneLifetimePolicy.h:36`.
const double kReturnAngleRate = 7;

/// Decay rate used when the system asks for reduced motion
/// (`SceneLifetimePolicy.h:36`, literal `35`).
const double kReturnAngleRateReduced = 35;

/// Clamps [value] to `[0, 1]` (`std::clamp`, SceneMotion.cpp:9-11).
double _clamp01(double value) => value < 0 ? 0 : (value > 1 ? 1 : value);

/// Quintic smootherstep used as the Qt soft step (SceneMotion.cpp:42-45).
///
/// `v * v * v * (10 + v * (-15 + 6 * v))` on the clamped input.
double smooth(double value) {
  final double v = _clamp01(value);
  return v * v * v * (10 + v * (-15 + 6 * v));
}

/// Cubic smoothstep used for shorter Qt transitions (SceneMotion.cpp:46-49).
///
/// `v * v * (3 - 2 * v)` on the clamped input.
double ease(double value) {
  final double v = _clamp01(value);
  return v * v * (3 - 2 * v);
}

/// Gaussian bell centred on zero (SceneMotion.cpp:13-14).
///
/// `exp(-0.5 * (value / width) ** 2)`; `width` must be non-zero.
double bell(double value, double width) {
  final double ratio = value / width;
  return math.exp(-0.5 * ratio * ratio);
}

/// Archive packet wave, active only inside the 22 s..26.35 s scan window
/// (SceneMotion.cpp:15-28).
///
/// The two packet trains sweep along `phase`, so `row` and `lane` shift the
/// sampled phase rather than changing the wave shape.
double archiveWave(double row, double lane, double time) {
  final double elapsed = time - 22;
  if (elapsed <= 0 || elapsed >= 4.35) {
    return 0.0;
  }
  final double phase = row + (lane - 2) * 0.65;
  double packet(double distance) {
    return 2.5 * bell(distance, 3.8) - 0.58 * bell(distance - 6, 3.5);
  }

  return smooth(elapsed / 0.32) *
      (packet(phase - (3 + elapsed * 19)) *
              (1 - smooth((elapsed - 2.15) / 0.65)) +
          packet(phase - (32 - (elapsed - 2.3) * 24)) *
              smooth((elapsed - 2.17) / 0.32) *
              (1 - smooth((elapsed - 3.5) / 0.85)));
}

/// Damped ring that settles around the centre row (SceneMotion.cpp:29-34).
///
/// [distance] is measured from the centre row (12 by default). The envelope
/// floors at -0.42 so a far cell still receives a small negative pull.
double settlingWave(double distance, double time) {
  final double age = time - 25.05 - distance.abs() * 0.065;
  final double envelope =
      math.max(-0.42, 2.15 - 0.17 * (math.sqrt(distance * distance + 1) - 1));
  final double ring =
      age > 0 ? math.sin(age * 5.1) * math.exp(-age * 1.3) : 0.0;
  return envelope *
      (smooth(age / 0.62) + 0.18 * ring * smooth(age / 0.16));
}

/// One key of a [track] curve: a [time] in seconds and its [value].
class CurveKey {
  /// Creates a key at [time] holding [value].
  const CurveKey(this.time, this.value);

  /// Shot time of the key, in seconds.
  final double time;

  /// Value of the curve at [time].
  final double value;
}

/// An ordered list of [CurveKey]s, as consumed by [track].
typedef Curve = List<CurveKey>;

/// Weighted-harmonic monotone cubic Hermite interpolation
/// (SceneMotion.cpp:52-95).
///
/// [keys] must be sorted by strictly increasing [CurveKey.time]; the Qt caller
/// owns that invariant. Outside the key range the end values are held. Interior
/// tangents use the harmonic mean of the neighbouring secants and collapse to
/// zero when the secants disagree in sign, which keeps the interpolant monotone
/// between monotone keys. With [stationaryEnds] the two end tangents are zero
/// (the Qt `stationaryEnds = true` call sites), otherwise each end reuses its
/// single adjacent secant.
double track(Curve keys, double time, {bool stationaryEnds = false}) {
  if (keys.isEmpty) {
    return 0.0;
  }
  if (time <= keys.first.time) {
    return keys.first.value;
  }
  final int last = keys.length - 1;
  if (time >= keys.last.time) {
    return keys.last.value;
  }

  double slope(int index) {
    return (keys[index + 1].value - keys[index].value) /
        (keys[index + 1].time - keys[index].time);
  }

  double tangent(int index) {
    if (index == 0 || index == last) {
      if (stationaryEnds) {
        return 0.0;
      }
      return slope(index == 0 ? 0 : last - 1);
    }
    final double ascending = slope(index - 1);
    final double descending = slope(index);
    if (ascending * descending <= 0) {
      return 0.0;
    }
    final double left = keys[index].time - keys[index - 1].time;
    final double right = keys[index + 1].time - keys[index].time;
    final double weight0 = 2 * right + left;
    final double weight1 = right + 2 * left;
    return (weight0 + weight1) / (weight0 / ascending + weight1 / descending);
  }

  // std::lower_bound(keys, time, [](key, value) { return key.first < value; })
  // returns the first key with `time >= value` (SceneMotion.cpp:85-86).
  int low = 0;
  int high = keys.length;
  while (low < high) {
    final int middle = low + ((high - low) >> 1);
    if (keys[middle].time < time) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  final int index = low - 1;

  final double span = keys[index + 1].time - keys[index].time;
  final double amount = (time - keys[index].time) / span;
  final double square = amount * amount;
  final double cube = square * amount;
  final double start = tangent(index);
  final double end = tangent(index + 1);
  return (2 * cube - 3 * square + 1) * keys[index].value +
      (cube - 2 * square + amount) * span * start +
      (-2 * cube + 3 * square) * keys[index + 1].value +
      (cube - square) * span * end;
}

/// Camera lift that carries the wall into the detail page
/// (SceneMotion.cpp:97-101).
///
/// Three overlapping [smooth] segments reach the 4.05 document lift; the
/// comment in the Qt source records that total.
double extraction(double time) {
  return 0.4 * smooth((time - 25.58) / 0.82) +
      2.95 * smooth((time - 27.55) / 1.3) +
      0.7 * smooth((time - 29) / 5);
}

/// Sum of the archive wave and the settling wave during the 25 s handoff
/// (SceneMotion.cpp:102-108).
///
/// [center] is the settling wave's centre row and [focus] the lane that keeps
/// full settling strength; both match the Qt defaults of 12 and 2.
double cinematicField(
  double row,
  double lane,
  double time, [
  double center = 12,
  double focus = 2,
]) {
  final double handoff = smooth((time - 24.95) / 0.45);
  final double selection = smooth((time - 25.4) / 0.95);
  final double shoulderTime = time + 0.3 * handoff * (1 - selection);
  final double strength =
      1 + (0.25 + 0.75 * bell(lane - focus, 0.55) - 1) * selection;
  return archiveWave(row, lane, time) * (1 - handoff) +
      settlingWave(row - center, shoulderTime) * strength;
}

/// One step of the Qt return-to-centre angle decay
/// (SceneMotion.cpp:109-112, forwarding `SceneLifetime::returnAngleStep` in
/// SceneLifetimePolicy.h:31-38).
///
/// A non-positive [seconds] returns [angle] untouched. Otherwise the angle
/// decays exponentially at [kReturnAngleRate], or [kReturnAngleRateReduced]
/// when [reduced] is set, and snaps to exactly zero once the remaining
/// magnitude is at most [kReturnAngleSnap].
double returnStep(double angle, double seconds, [bool reduced = false]) {
  if (seconds <= 0) {
    return angle;
  }
  final double rate = reduced ? kReturnAngleRateReduced : kReturnAngleRate;
  final double next = angle * math.exp(-seconds * rate);
  return next.abs() <= kReturnAngleSnap ? 0.0 : next;
}

/// Critically damped-ish spring integrator (SceneMotion.cpp:113-119).
///
/// The Qt struct starts at rest (`value = 0`, `velocity = 0`) and is advanced
/// by [damp] once per frame with the call site's `rate`.
class Spring {
  /// Creates a spring at rest unless [value] and [velocity] are given.
  Spring([this.value = 0, this.velocity = 0]);

  /// Current spring position.
  double value;

  /// Current spring velocity, in units per second.
  double velocity;

  /// Advances the spring by [seconds] towards [target] at [rate].
  ///
  /// The closed form is the Qt one: the velocity is folded into the position
  /// before the exponential decay, and both fields are updated in place. No
  /// sub-stepping or clamping is applied, matching the source.
  void damp(double target, double rate, double seconds) {
    final double delta = value - target;
    final double impulse = velocity + rate * delta;
    final double decay = math.exp(-rate * seconds);
    value = target + (delta + impulse * seconds) * decay;
    velocity = (velocity - rate * impulse * seconds) * decay;
  }
}

/// Archive grid address with the Qt `lane:row` key (SceneMotion.cpp:120-122).
class Cell {
  /// Creates a cell; the Qt aggregate defaults both coordinates to zero.
  const Cell([this.lane = 0, this.row = 0]);

  /// Column of the wall.
  final int lane;

  /// Row of the wall.
  final int row;

  /// Stable identifier in the Qt `"<lane>:<row>"` form.
  String key() => '$lane:$row';

  @override
  bool operator ==(Object other) {
    return other is Cell && other.lane == lane && other.row == row;
  }

  @override
  int get hashCode => Object.hash(lane, row);

  @override
  String toString() => 'Cell($lane, $row)';
}

/// One selection pulse that feeds the [ArchiveField] ripple
/// (SceneMotion.h `FieldPulse`).
class FieldPulse {
  /// Creates a pulse at [cell] emitted at [time], in seconds.
  const FieldPulse(this.cell, [this.time = 0]);

  /// Cell that emitted the pulse.
  final Cell cell;

  /// Shot time of the pulse, in seconds; the ripple is live for 3.2 s.
  final double time;
}

/// Sampled archive field: scan wave, settling pull, idle breathing and
/// selection ripples (SceneMotion.cpp:123-147).
///
/// The fields mirror the Qt defaults from SceneMotion.h:33-45. [sample] is a
/// pure read: it never advances [time] and never mutates [pulses].
class ArchiveField {
  /// Creates a field with the Qt default parameters.
  ArchiveField();

  /// Global grid offset added to every sampled cell.
  Cell origin = const Cell();

  /// Shot time used for the scan wave, in seconds.
  double scanTime = 29.1;

  /// Blend of the scan wave, `0` when the scan is not playing.
  double scanBlend = 0;

  /// Centre row of the settling wave.
  double shoulder = 12;

  /// Lane that keeps full settling strength.
  double laneFocus = 2;

  /// Gain of the idle breathing term.
  double idleGain = 0;

  /// Shot time of the field, in seconds.
  double time = 0;

  /// Gain applied to the clamped selection ripple.
  double pulseGain = 1;

  /// Whether live [pulses] contribute a ripple.
  bool selectionWave = true;

  /// Pulses currently alive on the wall.
  List<FieldPulse> pulses = <FieldPulse>[];

  /// Samples the field at [row] / [lane] for the current parameters.
  double sample(double row, double lane) {
    final double globalRow = row + origin.row;
    final double globalLane = lane + origin.lane;
    final double height =
        archiveWave(globalRow, globalLane, scanTime) * scanBlend;
    final double strength = 0.25 + 0.75 * bell(lane - laneFocus, 0.55);
    final double breathing = (0.075 *
                math.sin(time * math.pi * 2 / 8 +
                    globalRow * 0.3 -
                    globalLane * 0.45) +
            0.027 *
                math.sin(time * math.pi * 2 / 13 -
                    globalRow * 0.17 +
                    globalLane * 0.3)) *
        idleGain;
    double ripple = 0.0;
    if (selectionWave) {
      for (final FieldPulse pulse in pulses) {
        final double age = time - pulse.time;
        if (age < 0 || age > 3.2) {
          continue;
        }
        final double distance =
            _hypot(row - pulse.cell.row, (lane - pulse.cell.lane) * 2.2);
        final double phase = distance - age * 8;
        ripple += 0.8 *
            smooth(age / 0.2) *
            math.exp(-age * 1.15) *
            math.cos(phase * 0.58) *
            bell(phase, 3.4);
      }
    }
    final double clampedRipple =
        ripple < -0.6 ? -0.6 : (ripple > 0.6 ? 0.6 : ripple);
    return height +
        settlingWave(row - shoulder, 26.56) * strength +
        breathing +
        clampedRipple * pulseGain;
  }
}

/// `std::hypot` evaluated with the usual scaling by the larger magnitude, so
/// large distances cannot overflow. Equal to a correctly rounded hypot to
/// within one ulp; the Qt source calls `std::hypot` here (SceneMotion.cpp:139).
double _hypot(double x, double y) {
  final double ax = x.abs();
  final double ay = y.abs();
  final double larger = ax > ay ? ax : ay;
  if (larger == 0) {
    return 0.0;
  }
  final double smaller = ax > ay ? ay : ax;
  final double ratio = smaller / larger;
  return larger * math.sqrt(1 + ratio * ratio);
}
