/// T13-S01 - Dart-side HUD command executor (spike, isolated).
///
/// Scope: translate the seventeen production HUD operations into an inspectable
/// record stream. This file never draws, never imports Flutter (no widgets, no
/// canvas) and is never wired into the production painter
/// (`lib/hud/render/hud_painter.dart` stays the only stage painter).
///
/// Authority for the op set and the wire field order is the production protocol,
/// [HudCommand] in `lib/hud/protocol/hud_command.dart` (seventeen sealed
/// subclasses, line references below). The record keeps the wire `index` of the
/// command it came from: index is the array offset in the flat wire command
/// list, and order is semantic (save/restore pairing, alpha nesting). Nothing
/// here sorts, merges or deduplicates commands.
///
/// Op table (seventeen ops), fields exactly as decoded by the protocol:
///
/// | op          | wire fields (array index)                                  | protocol |
/// |-------------|------------------------------------------------------------|----------|
/// | save        | -                                                          | :19      |
/// | restore     | -                                                          | :27      |
/// | alpha       | 1 value                                                    | :33      |
/// | translate   | 1 x, 2 y                                                   | :40      |
/// | scale       | 1 sx, 2 sy                                                 | :48      |
/// | rotate      | 1 radians                                                  | :60      |
/// | clip        | 1 x, 2 y, 3 width, 4 height                                | :68      |
/// | fill        | 1 color, 2 x, 3 y, 4 width, 5 height                       | :79      |
/// | ellipse     | 1 color, 2 x, 3 y, 4 width, 5 height                       | :107     |
/// | text        | 1 value, 2 x, 3 y, 4 size, 5 weight, 6 tracking, 7 color   | :126     |
/// | art         | 1 key, 2 x, 3 y, 4 size, 5 count, 6 tracking, 7 color      | :152     |
/// | fill-path   | 1 key, 2 color                                             | :177     |
/// | path        | 1 key, 2 penWidth, 3 color, 4 dashPattern, 5 dashOffset    | :191     |
/// | arc         | 1 cx, 2 cy, 3 radius, 4 start, 5 sweep, 6 penWidth, 7 color | :221    |
/// | right-mask  | 1 color, 2 start, 3 span, 4 right, 5 height                | :249     |
/// | gradient    | 1 dark                                                     | :268     |
/// | image       | 1 key, 2 x, 3 y, 4 width, 5 height                         | :276     |
///
/// The executor reproduces only the painter-state slice that does not need a
/// canvas: save/restore snapshots, multiplicative alpha and clip intersection.
/// The remaining ops are pure payload records. The production semantics being
/// mirrored live in `lib/hud/render/paint_stack.dart` (dispatch) and
/// `lib/hud/render/clip_alpha.dart` (state).
library;

import 'dart:math' as math;

import '../../hud/protocol/hud_command.dart';

/// The seventeen HUD operation names, in protocol order.
///
/// Copied verbatim from `hudKnownOperationNames`
/// (`lib/hud/protocol/hud_command.dart:399-417`); the test companion asserts
/// this list against the protocol list, so any drift fails loudly.
const List<String> kSpikeHudOperationNames = <String>[
  'save',
  'restore',
  'alpha',
  'translate',
  'scale',
  'rotate',
  'clip',
  'fill',
  'ellipse',
  'text',
  'art',
  'fill-path',
  'path',
  'arc',
  'right-mask',
  'gradient',
  'image',
];

/// Number of production HUD operations (`hud_command.dart:399-417`).
const int kSpikeHudOperationCount = 17;

/// One colour in HUD wire form: red/green/blue/alpha, each 0..1
/// (`HudColor`, `hud_command.dart:297`). The alpha is the colour's own alpha;
/// painter opacity is tracked separately by [SpikeHudRecord.opacity].
List<double> spikeColorWire(HudColor color) => List<double>.unmodifiable(
      <double>[color.red, color.green, color.blue, color.alpha],
    );

/// A stage-space rectangle in the same space as the wire `clip` op.
final class SpikeHudRect {
  const SpikeHudRect(this.x, this.y, this.width, this.height);

  /// The null rect Qt returns for every empty intersection
  /// (`clip_alpha.dart:59-101`, QRectF() at origin with zero size).
  static const SpikeHudRect zero = SpikeHudRect(0, 0, 0, 0);

  final double x;
  final double y;
  final double width;
  final double height;

  double get left => x;
  double get top => y;
  double get right => x + width;
  double get bottom => y + height;

  /// QRectF::normalized() (`clip_alpha.dart:67-69`): a negative width or height
  /// moves the origin to the opposite edge instead of being clipped away.
  SpikeHudRect normalized() {
    double l = left;
    double r = right;
    double t = top;
    double b = bottom;
    if (l > r) {
      final double swap = l;
      l = r;
      r = swap;
    }
    if (t > b) {
      final double swap = t;
      t = b;
      b = swap;
    }
    return SpikeHudRect(l, t, r - l, b - t);
  }

  /// QRectF::operator& with Qt::IntersectClip semantics, ported from
  /// `intersectHudClip` (`clip_alpha.dart:62-104`).
  SpikeHudRect intersect(SpikeHudRect other) {
    final SpikeHudRect a = normalized();
    final SpikeHudRect b = other.normalized();
    if (a.width == 0 || a.height == 0 || b.width == 0 || b.height == 0) {
      return zero;
    }
    if (a.left >= b.right || b.left >= a.right) {
      return zero;
    }
    if (a.top >= b.bottom || b.top >= a.bottom) {
      return zero;
    }
    final double l = math.max(a.left, b.left);
    final double t = math.max(a.top, b.top);
    return SpikeHudRect(l, t, math.min(a.right, b.right) - l, math.min(a.bottom, b.bottom) - t);
  }

  List<double> toWire() => List<double>.unmodifiable(<double>[x, y, width, height]);

  @override
  bool operator ==(Object other) =>
      other is SpikeHudRect &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'SpikeHudRect($x, $y, $width, $height)';
}

/// A 2D affine transform in the same column layout Flutter's canvas uses:
/// `x' = a*x + c*y + e`, `y' = b*x + d*y + f`.
///
/// The production painter keeps the transform on the canvas, not in
/// `HudPaintStateStack` (`clip_alpha.dart:146-152`). The spike has no canvas,
/// so it carries the matrix explicitly and composes it with the same order as
/// `Canvas.translate/scale/rotate`.
final class SpikeHudTransform {
  const SpikeHudTransform(this.a, this.b, this.c, this.d, this.e, this.f);

  static const SpikeHudTransform identity = SpikeHudTransform(1, 0, 0, 1, 0, 0);

  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;

  SpikeHudTransform translated(double tx, double ty) =>
      SpikeHudTransform(a, b, c, d, a * tx + c * ty + e, b * tx + d * ty + f);

  SpikeHudTransform scaled(double sx, double sy) =>
      SpikeHudTransform(a * sx, b * sx, c * sy, d * sy, e, f);

  SpikeHudTransform rotated(double radians) {
    final double cosine = math.cos(radians);
    final double sine = math.sin(radians);
    return SpikeHudTransform(
      a * cosine + c * sine,
      b * cosine + d * sine,
      -a * sine + c * cosine,
      -b * sine + d * cosine,
      e,
      f,
    );
  }

  /// Maps a stage-space point through the current matrix.
  List<double> apply(double x, double y) => <double>[
        a * x + c * y + e,
        b * x + d * y + f,
      ];

  List<double> get values => List<double>.unmodifiable(<double>[a, b, c, d, e, f]);

  @override
  bool operator ==(Object other) =>
      other is SpikeHudTransform &&
      other.a == a &&
      other.b == b &&
      other.c == c &&
      other.d == d &&
      other.e == e &&
      other.f == f;

  @override
  int get hashCode => Object.hash(a, b, c, d, e, f);

  @override
  String toString() => 'SpikeHudTransform($a, $b, $c, $d, $e, $f)';
}

/// One translated command plus the painter state immediately after it ran.
final class SpikeHudRecord {
  const SpikeHudRecord({
    required this.index,
    required this.sequence,
    required this.operation,
    required this.arguments,
    required this.opacity,
    required this.saveDepth,
    required this.transform,
    required this.clip,
  });

  /// Wire array index of the source command (`HudCommand.index`).
  final int index;

  /// Position in the execution stream (0-based, order preserving).
  final int sequence;

  /// One of [kSpikeHudOperationNames].
  final String operation;

  /// Decoded wire fields, keyed exactly like the protocol getters. Colours are
  /// 0..1 RGBA lists; nested lists are unmodifiable.
  final Map<String, Object?> arguments;

  /// Accumulated painter opacity after this command (`composeHudOpacity`,
  /// `clip_alpha.dart:59-60`).
  final double opacity;

  /// Save-frame depth after this command (0 at the root).
  final int saveDepth;

  /// Canvas-equivalent transform after this command.
  final SpikeHudTransform transform;

  /// Accumulated stage-space clip, or null when no clip op has run yet
  /// (`HudPaintStateStack.clip`, `clip_alpha.dart:203-206`).
  final SpikeHudRect? clip;

  @override
  String toString() =>
      'SpikeHudRecord(#$sequence index=$index $operation args=$arguments '
      'opacity=$opacity depth=$saveDepth clip=$clip transform=$transform)';
}

/// A state-machine problem the executor kept instead of swallowing.
final class SpikeHudIssue {
  const SpikeHudIssue({
    required this.index,
    required this.operation,
    required this.kind,
    required this.detail,
  });

  /// Wire index of the offending command, or -1 for an end-of-stream issue.
  final int index;
  final String operation;

  /// `unbalancedRestore` or `unbalancedSave`.
  final String kind;
  final String detail;

  @override
  String toString() => 'SpikeHudIssue(index=$index, op=$operation, kind=$kind, $detail)';
}

/// Result of one execution pass.
final class SpikeHudExecution {
  const SpikeHudExecution({
    required this.records,
    required this.issues,
    required this.openFrames,
  });

  final List<SpikeHudRecord> records;
  final List<SpikeHudIssue> issues;

  /// Save frames still open when the command list ended. Zero is the only
  /// balanced value; Qt only warns on the next unbalanced restore, but a spike
  /// must not hide a missing restore.
  final int openFrames;

  bool get balanced => openFrames == 0 && !issues.any((SpikeHudIssue i) => i.kind == 'unbalancedRestore');

  /// Records of one operation name, in stream order.
  List<SpikeHudRecord> recordsOf(String operation) =>
      records.where((SpikeHudRecord r) => r.operation == operation).toList(growable: false);

  List<String> get operationSequence =>
      records.map((SpikeHudRecord r) => r.operation).toList(growable: false);
}

/// Executes [commands] in order and returns the translation record stream.
///
/// This is the whole T13-S01 surface: no canvas, no widgets, no drawing. The
/// executor is stateless between calls (a fresh one is created per call).
SpikeHudExecution executeSpikeHudCommands(List<HudCommand> commands) =>
    SpikeHudExecutor().execute(commands);

/// Stateful worker behind [executeSpikeHudCommands].
final class SpikeHudExecutor {
  final List<SpikeHudRecord> _records = <SpikeHudRecord>[];
  final List<SpikeHudIssue> _issues = <SpikeHudIssue>[];
  final List<_SpikeFrame> _frames = <_SpikeFrame>[];

  double _opacity = 1;
  int _depth = 0;
  SpikeHudTransform _transform = SpikeHudTransform.identity;
  SpikeHudRect? _clip;

  SpikeHudExecution execute(List<HudCommand> commands) {
    _records.clear();
    _issues.clear();
    _frames.clear();
    _opacity = 1;
    _depth = 0;
    _transform = SpikeHudTransform.identity;
    _clip = null;

    for (final HudCommand command in commands) {
      _apply(command);
    }
    if (_frames.isNotEmpty) {
      _issues.add(SpikeHudIssue(
        index: -1,
        operation: 'end',
        kind: 'unbalancedSave',
        detail: '${_frames.length} save frame(s) left open at end of stream',
      ));
    }
    return SpikeHudExecution(
      records: List<SpikeHudRecord>.unmodifiable(_records),
      issues: List<SpikeHudIssue>.unmodifiable(_issues),
      openFrames: _frames.length,
    );
  }

  void _apply(HudCommand command) {
    switch (command) {
      case HudSave():
        _frames.add(_SpikeFrame(opacity: _opacity, clip: _clip, depth: _depth, transform: _transform));
        _depth += 1;
        _record(command.index, 'save', const <String, Object?>{});
      case HudRestore():
        if (_frames.isEmpty) {
          _issues.add(SpikeHudIssue(
            index: command.index,
            operation: 'restore',
            kind: 'unbalancedRestore',
            detail: 'restore without a matching save; state left untouched',
          ));
        } else {
          final _SpikeFrame frame = _frames.removeLast();
          _opacity = frame.opacity;
          _clip = frame.clip;
          _depth = frame.depth;
          _transform = frame.transform;
        }
        _record(command.index, 'restore', const <String, Object?>{});
      case HudAlpha(:final value):
        _opacity = _opacity * value;
        _record(command.index, 'alpha', <String, Object?>{'value': value});
      case HudTranslate(:final x, :final y):
        _transform = _transform.translated(x, y);
        _record(command.index, 'translate', <String, Object?>{'x': x, 'y': y});
      case HudScale(:final sx, :final sy):
        _transform = _transform.scaled(sx, sy);
        _record(command.index, 'scale', <String, Object?>{'sx': sx, 'sy': sy});
      case HudRotate(:final radians):
        _transform = _transform.rotated(radians);
        _record(command.index, 'rotate', <String, Object?>{'radians': radians});
      case HudClip(:final x, :final y, :final width, :final height):
        final SpikeHudRect rect = SpikeHudRect(x, y, width, height);
        _clip = _clip == null ? rect.normalized() : _clip!.intersect(rect);
        _record(command.index, 'clip', <String, Object?>{'x': x, 'y': y, 'width': width, 'height': height});
      case HudFill(:final color, :final x, :final y, :final width, :final height):
        _record(command.index, 'fill', <String, Object?>{
          'color': spikeColorWire(color),
          'x': x,
          'y': y,
          'width': width,
          'height': height,
        });
      case HudEllipse(:final color, :final x, :final y, :final width, :final height):
        _record(command.index, 'ellipse', <String, Object?>{
          'color': spikeColorWire(color),
          'x': x,
          'y': y,
          'width': width,
          'height': height,
        });
      case HudText(
          :final value,
          :final x,
          :final y,
          :final size,
          :final weight,
          :final tracking,
          :final color,
        ):
        _record(command.index, 'text', <String, Object?>{
          'value': value,
          'x': x,
          'y': y,
          'size': size,
          'weight': weight,
          'tracking': tracking,
          'color': spikeColorWire(color),
        });
      case HudArt(
          :final key,
          :final x,
          :final y,
          :final size,
          :final count,
          :final tracking,
          :final color,
        ):
        _record(command.index, 'art', <String, Object?>{
          'key': key,
          'x': x,
          'y': y,
          'size': size,
          'count': count,
          'tracking': tracking,
          'color': spikeColorWire(color),
        });
      case HudFillPath(:final key, :final color):
        _record(command.index, 'fill-path', <String, Object?>{
          'key': key,
          'color': spikeColorWire(color),
        });
      case HudStrokePath(
          :final key,
          :final penWidth,
          :final color,
          :final dashPattern,
          :final dashOffset,
        ):
        _record(command.index, 'path', <String, Object?>{
          'key': key,
          'penWidth': penWidth,
          'color': spikeColorWire(color),
          'dashPattern': List<double>.unmodifiable(dashPattern),
          'dashOffset': dashOffset,
        });
      case HudArc(
          :final cx,
          :final cy,
          :final radius,
          :final start,
          :final sweep,
          :final penWidth,
          :final color,
        ):
        _record(command.index, 'arc', <String, Object?>{
          'cx': cx,
          'cy': cy,
          'radius': radius,
          'start': start,
          'sweep': sweep,
          'penWidth': penWidth,
          'color': spikeColorWire(color),
        });
      case HudRightMask(
          :final color,
          :final start,
          :final span,
          :final right,
          :final height,
        ):
        _record(command.index, 'right-mask', <String, Object?>{
          'color': spikeColorWire(color),
          'start': start,
          'span': span,
          'right': right,
          'height': height,
        });
      case HudGradient(:final dark):
        _record(command.index, 'gradient', <String, Object?>{'dark': dark});
      case HudImage(:final key, :final x, :final y, :final width, :final height):
        _record(command.index, 'image', <String, Object?>{
          'key': key,
          'x': x,
          'y': y,
          'width': width,
          'height': height,
        });
    }
  }

  void _record(int index, String operation, Map<String, Object?> arguments) {
    _records.add(SpikeHudRecord(
      index: index,
      sequence: _records.length,
      operation: operation,
      arguments: Map<String, Object?>.unmodifiable(arguments),
      opacity: _opacity,
      saveDepth: _depth,
      transform: _transform,
      clip: _clip,
    ));
  }
}

final class _SpikeFrame {
  const _SpikeFrame({
    required this.opacity,
    required this.clip,
    required this.depth,
    required this.transform,
  });

  final double opacity;
  final SpikeHudRect? clip;
  final int depth;
  final SpikeHudTransform transform;
}
