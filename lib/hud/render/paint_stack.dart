//  HUD renderer core - executes the native HUD command stack.
//
// Qt authority for every branch below:
//   Qt/src/Glyphs.cpp:637-829  dispatch loop
//     for (const auto &v : commands) { const auto a = v.toArray();
//       auto op = a[0].toString();
//       auto n = [&](int i) { return a[i].toDouble(); }; ... }
//   Qt/src/Hud.cpp:17-20       QQuickPaintedItem with setOpaquePainting(false) and
//                              setAntialiasing(true); the content is clipped by item geometry.
//   Qt/qml/Overlay.qml:22-23   stageScale = height > 0 ? height / 1080 : 1;
//                              stageWidth = width / stageScale;
//   Qt/qml/Overlay.qml:179-184 controls Item { width: stageWidth; height: 1080;
//                              scale: stageScale; transformOrigin: Item.TopLeft }
//
// IRON RULES honoured here:
//  * commands are executed in List order - never sorted, deduped or merged;
//  * all 17 ops are implemented and a *known* op is never silently swallowed:
//    a missing port or an unusable argument records a HudPaintIssue;
//  * unknown ops never reach this layer: the decode layer drops them and records
//    HudIssueKind.unknownOperation (Qt/src/Glyphs.cpp:637-829 has no trailing
//    else branch, so the drop happens exactly once, at decode time);
//  * calibrated colours are already gamma(1.8)->sRGB decoded by the decode layer
//    and alpha never enters that transform (Qt/src/Glyphs.cpp:35-49);
//  * the dash pattern is device-absolute above the 1e-4 pen floor:
//    Qt/src/Glyphs.cpp:749-756 divides each entry and the offset by
//    qMax(penWidth, .0001) only because QPen pattern units are multiples of the
//    pen width, and QPen/QStroker multiply that unit back by the pen width, so
//    the device length equals the wire original for every pen width at or above
//    the floor (every value the Qt producers emit).
//
// CITATION NOTE: third_party/qt is an unpopulated submodule in this worktree
// (qtbase/ is empty), so the qpen.cpp / qstroker.cpp / qpainter.cpp line numbers
// below and in the sibling files are upstream Qt 6 references, not files
// verified in-tree. Every behavioural claim that can be checked against this
// repository was checked against Qt/src.
//

import 'dart:ui' as ui;

import '../protocol/hud_command.dart';
import 'clip_alpha.dart';
import 'gradient_mask.dart';

/// Draws a `text` op through the glyph text port (`GlyphText.paintText`, ).
///
/// The port owns the Qt baseline shift: the body at `Glyphs.cpp:530-564`
/// translates by `(x, y + size * 1.044)` and scales by
/// `(size / 1000, -size / 1000)` in every branch (:536-537, :547-548,
/// :558-559) before drawing the run, so [y] here is the wire `n(3)` value
/// unchanged.
typedef HudTextDrawFn = void Function(
  ui.Canvas canvas,
  String value,
  double x,
  double y,
  double size,
  String weight,
  double tracking,
  ui.Color color,
);

/// Draws an `art` op through the art port (`paintArt`, ).
///
/// `Glyphs.cpp:565-588` translates by `(x, y)` with **no** baseline factor and
/// scales by `(size / 1000, size / 1000)`, so [y] is the art box top, unchanged.
typedef HudArtDrawFn = void Function(
  ui.Canvas canvas,
  String key,
  double x,
  double y,
  double size,
  int count,
  double tracking,
  ui.Color color,
);

/// Resolves a `fill-path` / `path` key to a vector path (`Glyphs.cpp:529-535`
/// and the `path(key)` lookup used at `:745` / `:738-760`).
typedef HudPathLookupFn = ui.Path? Function(String key);

/// Resolves an `image` key to a raster image (`Glyphs.cpp:813-824`).
typedef HudImageLookupFn = ui.Image? Function(String key);

/// Everything the native renderer can refuse to draw, without lying about it.
enum HudPaintIssueKind {
  missingTextPort,
  missingArtPort,
  missingPath,
  missingImage,
  nonPositiveDash,
  unbalancedRestore,
  unknownCommandSubtype,
}

/// One refusal, pinned to the index of the command that caused it.
final class HudPaintIssue {
  const HudPaintIssue({
    required this.index,
    required this.op,
    required this.kind,
    required this.detail,
  });

  final int index;
  final String op;
  final HudPaintIssueKind kind;
  final String detail;

  @override
  String toString() =>
      'HudPaintIssue(#$index $op ${kind.name}: $detail)';

  @override
  bool operator ==(Object other) =>
      other is HudPaintIssue &&
      other.index == index &&
      other.op == op &&
      other.kind == kind &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(index, op, kind, detail);
}

/// The state left behind by one frame, plus everything that was refused.
final class HudPaintResult {
  const HudPaintResult({required this.state, required this.issues});

  final HudPaintStateStack state;
  final List<HudPaintIssue> issues;

  bool get hasIssues => issues.isNotEmpty;

  @override
  String toString() => 'HudPaintResult(issues: ${issues.length}, depth: ${state.depth})';
}

/// The pen-unit floor Qt uses: `qMax(penWidth, .0001)` (`Glyphs.cpp:751-752`,
/// `:756`).
const double _hudDashPenFloor = 0.0001;

double _hudPenUnit(double penWidth) =>
    penWidth > _hudDashPenFloor ? penWidth : _hudDashPenFloor;

/// Wire dash entries -> QPen units (the pattern divided by one pen width),
/// exactly as `Glyphs.cpp:751-752` does before `pen.setDashPattern(d)`.
List<double> normalizeHudDashPattern(List<double> pattern, double penWidth) {
  final double unit = _hudPenUnit(penWidth);
  final List<double> normalized = <double>[];
  for (final double value in pattern) {
    normalized.add(value / unit);
  }
  return normalized;
}

/// Wire dash offset -> QPen units, exactly as `Glyphs.cpp:756` does before
/// `pen.setDashOffset(n(5) / qMax(penWidth, .0001))`.
double normalizeHudDashOffset(double offset, double penWidth) =>
    offset / _hudPenUnit(penWidth);

/// Builds the dashed copy of [source].
///
/// [pattern] and [dashOffset] are **device-absolute lengths**: Qt divides the
/// wire values by `qMax(penWidth, .0001)` and QPen/QStroker multiply them back
/// by `penWidth` (`qpen.cpp:100-101`, `:487-490`, `qstroker.cpp:1086`), so the
/// length that reaches the device is the wire original. Dividing a second time
/// here would shorten every dash by `penWidth`.
///
/// Degenerate input (empty, non-finite, non-positive, or a pattern whose total
/// is zero) yields [source] unchanged, i.e. a solid line: Qt silently clamps
/// negative entries to zero (`qstroker.cpp:1086`) and then draws nothing when the
/// pattern sums to zero (`:1092-1093`); the painter surfaces that as a
/// `nonPositiveDash` issue instead of hiding it, and this function keeps a
/// defined behaviour for direct callers.
ui.Path dashHudPath(ui.Path source, List<double> pattern, double dashOffset) {
  if (pattern.isEmpty) return source;
  final List<double> dashes = <double>[];
  double total = 0;
  for (final double value in pattern) {
    if (!value.isFinite || value <= 0) return source;
    dashes.add(value);
    total += value;
  }
  if (!(total > 0)) return source;
  double offset = dashOffset.isFinite ? dashOffset % total : 0;
  if (offset < 0) offset += total;
  int index = 0;
  while (offset >= dashes[index]) {
    offset -= dashes[index];
    index = (index + 1) % dashes.length;
  }
  bool on = index.isEven;
  double remaining = dashes[index] - offset;
  final ui.Path dashed = ui.Path();
  for (final ui.PathMetric metric in source.computeMetrics()) {
    final double length = metric.length;
    if (!(length > 0)) continue;
    double distance = 0;
    while (distance < length) {
      final double step =
          remaining < length - distance ? remaining : length - distance;
      // A step below one ulp of `distance` would never advance the cursor and
      // would spin forever on a subnormal/1e-300 pattern; treat it as done.
      if (!(step > 0)) break;
      if (on) {
        dashed.addPath(
          metric.extractPath(distance, distance + step),
          ui.Offset.zero,
        );
      }
      distance += step;
      index = (index + 1) % dashes.length;
      on = !on;
      remaining = dashes[index];
    }
  }
  return dashed;
}

/// Runs [commands] against [canvas] in List order.
///
/// One `save`/`restore` pair of the wire maps onto one `Canvas.save`/
/// `Canvas.restore` pair; a `clip` is a `Canvas.save` plus an intersecting
/// `Canvas.clipRect(..., doAntiAlias: false)` (`Glyphs.cpp:676-678` sets
/// `Qt::IntersectClip`), and the enclosing wire `restore` pops it again, exactly
/// as Qt's painter state does. A `clip` with no wire `save` open has no wire
/// `restore` coming: its canvas save is closed when this call returns, while
/// the clip stays visible in the returned state (Qt keeps the clip until the
/// painter is torn down). A `restore` without a matching `save` leaves the
/// state untouched and records `unbalancedRestore` - it does not touch the
/// canvas (Qt's upstream `QPainter::restore()` warns and ignores the pop).
HudPaintResult paintHudCommands({
  required ui.Canvas canvas,
  required List<HudCommand> commands,
  HudTextDrawFn? text,
  HudArtDrawFn? art,
  HudPathLookupFn? path,
  HudImageLookupFn? image,
  HudPaintStateStack? state,
}) {
  final HudPaintStateStack stack = state ?? HudPaintStateStack();
  final List<HudPaintIssue> issues = <HudPaintIssue>[];
  // Canvas saves opened by a `clip` op, attributed to the wire save scope they
  // belong to. `HudPainterStateStack` owns the Qt-visible state (opacity, clip
  // rect, depth); this mirror only keeps Canvas.save/restore balanced, because
  // Flutter has no "change the clip in place" call.
  final List<int> clipSavesPerSave = <int>[];
  // Canvas saves opened by a clip that had no enclosing wire save to own them;
  // popped before this call returns so the caller's save/restore stays balanced.
  int rootClipSaves = 0;

  void record(int index, String op, HudPaintIssueKind kind, String detail) {
    issues.add(HudPaintIssue(index: index, op: op, kind: kind, detail: detail));
  }

  ui.Paint fillPaint(ui.Color color) => ui.Paint()
    ..isAntiAlias = true
    ..style = ui.PaintingStyle.fill
    ..color = color;

  ui.Paint strokePaint(
    ui.Color color,
    double penWidth,
    ui.StrokeCap cap,
    ui.StrokeJoin join,
  ) =>
      ui.Paint()
        ..isAntiAlias = true
        ..style = ui.PaintingStyle.stroke
        ..color = color
        ..strokeWidth = penWidth
        ..strokeCap = cap
        ..strokeJoin = join
        // Qt's QPen default miter limit is 2.0 (qpen.cpp: the QPenData
        // constructor stores miter_limit(2)); the path/arc branches never call
        // setMiterLimit (Glyphs.cpp:748-752, :761-774), so a sharp corner in a
        // wire path is bevelled at the same threshold Qt uses. dart:ui's
        // default is 4.0, which would keep the miter instead.
        ..strokeMiterLimit = 2.0;

  for (final HudCommand command in commands) {
    final int index = command.index;
    switch (command) {
      case HudSave():
        stack.save();
        canvas.save();
        clipSavesPerSave.add(0);
        break;
      case HudRestore():
        if (stack.restore()) {
          final int clipped =
              clipSavesPerSave.isEmpty ? 0 : clipSavesPerSave.removeLast();
          for (int i = 0; i <= clipped; i++) {
            canvas.restore();
          }
        } else {
          record(
            index,
            'restore',
            HudPaintIssueKind.unbalancedRestore,
            'restore without a matching save (depth was 0); Qt only warns '
            'and leaves the state untouched',
          );
        }
        break;
      case HudAlpha(:final double value):
        // Glyphs.cpp:658-659 c.setOpacity(c.opacity() * n(1)) - multiplicative,
        // never an assignment: nested alphas compound. Qt clamps inside
        // setOpacity (qpainter.cpp:2073) before storing; this file keeps the
        // pure product (clip_alpha.dart F2 residual) and clamps at ink
        // consumption, which is identical for every in-range factor.
        stack.applyAlpha(value);
        break;
      case HudTranslate(:final double x, :final double y):
        canvas.translate(x, y);
        break;
      case HudScale(:final double sx, :final double sy):
        canvas.scale(sx, sy);
        break;
      case HudRotate(:final double radians):
        // Glyphs.cpp:671-672 c.rotate(n(1) * 180 / pi): Qt takes degrees, Flutter
        // takes radians, and both conventions are "positive = clockwise" in the
        // y-down device space (dart:ui painting.dart:7045 'radians clockwise'),
        // so the wire radians are passed through unchanged.
        canvas.rotate(radians);
        break;
      case HudClip(
          :final double x,
          :final double y,
          :final double width,
          :final double height
        ):
        final ui.Rect clipRect = ui.Rect.fromLTWH(x, y, width, height);
        // The stack records the intersection in stage space; the canvas needs
        // the same rectangle under the CURRENT transform, so the accumulated
        // clip is never used here. Both sides normalize the wire rect (negative
        // extents swap, exactly like `intersectHudClip`), so the recorded clip
        // and the painted region cannot disagree; only a zero-area or
        // non-finite extent becomes the empty region. dart:ui's only clipRect
        // precondition is the NaN assert (painting.dart:25-28, asserted at
        // :3298), so the rect is normalized here rather than relying on Skia.

        stack.applyClip(clipRect);
        canvas.save();
        canvas.clipRect(_canvasHudClipRect(clipRect), doAntiAlias: false);
        if (clipSavesPerSave.isNotEmpty) {
          clipSavesPerSave[clipSavesPerSave.length - 1] =
              clipSavesPerSave.last + 1;
        } else {
          rootClipSaves++;
        }
        break;
      case HudFill(
          :final HudColor color,
          :final double x,
          :final double y,
          :final double width,
          :final double height
        ):
        canvas.drawRect(
          ui.Rect.fromLTWH(x, y, width, height),
          fillPaint(_hudInk(color, stack.opacity)),
        );
        break;
      case HudEllipse(
          :final HudColor color,
          :final double x,
          :final double y,
          :final double width,
          :final double height
        ):
        // Glyphs.cpp:699-701 c.setPen(Qt::NoPen); c.setBrush(color(a[1]));
        // c.drawEllipse(rect) - fill only. Flutter paints carry their own
        // colour, so Qt's pen/brush leak does not exist here; every other op
        // sets its own pen/brush before drawing, so no visible difference.
        canvas.drawOval(
          ui.Rect.fromLTWH(x, y, width, height),
          fillPaint(_hudInk(color, stack.opacity)),
        );
        break;
      case HudText(
          :final String value,
          :final double x,
          :final double y,
          :final double size,
          :final String weight,
          :final double tracking,
          :final HudColor color
        ):
        if (text == null) {
          record(
            index,
            'text',
            HudPaintIssueKind.missingTextPort,
            'no text port; Glyphs.cpp:530-564 cannot draw the run',
          );
          break;
        }
        text(canvas, value, x, y, size, weight, tracking,
            _hudInk(color, stack.opacity));
        break;
      case HudArt(
          :final String key,
          :final double x,
          :final double y,
          :final double size,
          :final int count,
          :final double tracking,
          :final HudColor color
        ):
        if (art == null) {
          record(
            index,
            'art',
            HudPaintIssueKind.missingArtPort,
            'no art port; Glyphs.cpp:565-588 cannot draw the glyph art',
          );
          break;
        }
        art(canvas, key, x, y, size, count, tracking,
            _hudInk(color, stack.opacity));
        break;
      case HudFillPath(:final String key, :final HudColor color):
        final ui.Path? fillShape = path?.call(key);
        if (fillShape == null) {
          record(
            index,
            'fill-path',
            HudPaintIssueKind.missingPath,
            'no path registered for key "$key"',
          );
          break;
        }
        canvas.drawPath(fillShape, fillPaint(_hudInk(color, stack.opacity)));
        break;
      case HudStrokePath(
          :final String key,
          :final double penWidth,
          :final HudColor color,
          :final List<double> dashPattern,
          :final double? dashOffset
        ):
        final ui.Path? strokeShape = path?.call(key);
        if (strokeShape == null) {
          record(
            index,
            'path',
            HudPaintIssueKind.missingPath,
            'no path registered for key "$key"',
          );
          break;
        }
        final ui.Paint stroke = strokePaint(
          _hudInk(color, stack.opacity),
          penWidth,
          ui.StrokeCap.butt,
          ui.StrokeJoin.miter,
        );
        if (dashPattern.isEmpty) {
          canvas.drawPath(strokeShape, stroke);
          break;
        }
        if (_hasNonPositiveDash(dashPattern)) {
          record(
            index,
            'path',
            HudPaintIssueKind.nonPositiveDash,
            'dash pattern $dashPattern has a non-positive entry; Qt clamps it to 0 (qstroker.cpp:1086) and would draw nothing for an all-zero pattern (:1092-1093); this atom draws a defined solid line instead',
          );
          canvas.drawPath(strokeShape, stroke);
          break;
        }
        // Glyphs.cpp:749-756 puts *QPen units* on the pen: every entry and the
        // offset divided by qMax(penWidth, .0001). QPen/QStroker multiply one
        // unit back by the pen width, so a device length is
        // `entry / unit * penWidth` - exactly the wire value for every pen
        // width at or above the floor, and honestly shrunk towards zero for a
        // pen width below it, where Qt does not preserve the wire length.
        final List<double> devicePattern = <double>[
          for (final double value in normalizeHudDashPattern(
            dashPattern,
            penWidth,
          ))
            value * penWidth,
        ];
        if (devicePattern.length.isOdd) {
          // qpen.cpp:502-515: an odd pattern makes QPen append one pen unit,
          // which is one pen width on the device.
          devicePattern.add(penWidth);
        }
        final double deviceOffset = normalizeHudDashOffset(
              dashOffset ?? 0,
              penWidth,
            ) *
            penWidth;
        canvas.drawPath(
          dashHudPath(strokeShape, devicePattern, deviceOffset),
          stroke,
        );
        break;
      case HudArc(
          :final double cx,
          :final double cy,
          :final double radius,
          :final double start,
          :final double sweep,
          :final double penWidth,
          :final HudColor color
        ):
        // Glyphs.cpp:761-774:
        //   QRectF r(n(1) - n(3), n(2) - n(3), n(3) * 2, n(3) * 2);
        //   p.arcMoveTo(r, -n(4) * 180 / pi);
        //   p.arcTo(r, -n(4) * 180 / pi, -n(5) * 180 / pi);
        //   c.setPen(QPen(color(a[7]), n(6), Qt::SolidLine, Qt::RoundCap));
        //   c.setBrush(Qt::NoBrush); c.drawPath(p);
        //
        // Qt negates the wire radians because Qt arc angles are
        // counter-clockwise on screen (qpainterpath.cpp:68-115 puts angle 90 at
        // the TOP), while the wire angles are already y-down clockwise: the
        // producer of this very op places the arc cap dot at
        //   (960 + cos(start + sweep) * r, 540 + sin(start + sweep) * r)
        // (NativeHudBoot.cpp:364-369) and the orbit dots at
        //   (960 + cos(a) * r, 540 + sin(a) * r) (NativeHudBoot.cpp:358-362).
        // Flutter measures arcs in radians from 3 o'clock, positive clockwise
        // (dart:ui Path.arcTo, painting.dart:3003/3297) - the same screen
        // convention - so the wire (start, sweep) pass through unchanged and the
        // negation cancels out. Passing (-start, -sweep) here would mirror the
        // arc vertically and is a Qt-parity defect; see the file report.
        final ui.Path arcPath = ui.Path()
          ..arcTo(
            ui.Rect.fromLTWH(
              cx - radius,
              cy - radius,
              radius * 2,
              radius * 2,
            ),
            start,
            sweep,
            true,
          );
        canvas.drawPath(
          arcPath,
          strokePaint(
            _hudInk(color, stack.opacity),
            penWidth,
            ui.StrokeCap.round,
            ui.StrokeJoin.bevel,
          ),
        );
        break;
      case HudRightMask(
          :final HudColor color,
          :final double start,
          :final double span,
          :final double right,
          :final double height
        ):
        // Glyphs.cpp:775-805: a QLinearGradient from (start, 0) to
        // (start + span, 0) with MaskSteps = 16 smoothstep alpha stops
        // (progress * progress * (3 - 2 * progress)), filled into
        // QRectF(start, 0, n(4) - start, n(5)).
        final ui.Color maskBase = _hudInk(color, stack.opacity);
        canvas.drawRect(
          ui.Rect.fromLTWH(start, 0, right - start, height),
          fillPaint(maskBase)..shader = hudRightMaskGradient(maskBase, start, span),
        );
        break;
      case HudGradient(:final bool dark):
        // Glyphs.cpp:806-812: QRadialGradient(QPointF(979.2, 518.4), 1100) with
        // the 0 / .76 / 1 stops of gradient_mask.dart, filled into
        // QRectF(-4096, -4096, 8192, 8192). The centre is fixed: the op carries
        // only the dark flag.
        final ui.Paint gradientPaint = ui.Paint()
          ..isAntiAlias = true
          ..shader = hudBackgroundGradient(dark: dark);
        final double opacity = stack.opacity;
        if (opacity < 1) {
          // Qt's setOpacity composites everything drawn afterwards through a
          // layer; the gradient colours come from gradient_mask.dart and carry
          // no alpha knob, so the layer carries the opacity instead.
          canvas.saveLayer(
            hudBackgroundGradientRect,
            ui.Paint()
              ..color = ui.Color.from(
                alpha: _clampHudUnit(opacity),
                red: 0,
                green: 0,
                blue: 0,
              ),
          );
        }
        canvas.drawRect(hudBackgroundGradientRect, gradientPaint);
        if (opacity < 1) canvas.restore();
        break;
      case HudImage(
          :final String key,
          :final double x,
          :final double y,
          :final double width,
          :final double height
        ):
        final ui.Image? raster = image?.call(key);
        if (raster == null) {
          record(
            index,
            'image',
            HudPaintIssueKind.missingImage,
            image == null
                ? 'no image port; Glyphs.cpp:813-824 cannot draw the raster'
                : 'no image registered for key "$key"',
          );
          break;
        }
        canvas.drawImageRect(
          raster,
          ui.Rect.fromLTWH(
            0,
            0,
            raster.width.toDouble(),
            raster.height.toDouble(),
          ),
          ui.Rect.fromLTWH(x, y, width, height),
          ui.Paint()
            ..isAntiAlias = true
            ..filterQuality = ui.FilterQuality.low
            ..color = ui.Color.from(
              alpha: _clampHudUnit(stack.opacity),
              red: 1,
              green: 1,
              blue: 1,
            ),
        );
        break;
      default:
        // Unreachable for the frozen 17-op sealed hierarchy, but a silent drop
        // would be worse than a noisy one: Qt/src/Glyphs.cpp:637-829 has no else
        // branch and the decode layer already drops wire-unknown ops with a
        // HudIssueKind.unknownOperation issue.
        record(
          index,
          command.runtimeType.toString(),
          HudPaintIssueKind.unknownCommandSubtype,
          'unrecognised HudCommand subtype; nothing was drawn',
        );
        break;
    }
  }

  // A stream that ends with open save frames is a producer defect, but Qt does
  // not surface it: every item paint gets a fresh QPainter and Hud.cpp:151-166's
  // single trailing restore simply discards the rest. Flutter shares one
  // RecordingCanvas per frame, so the raised saves WOULD be inherited by the
  // next painter. Closing them here reproduces Qt's per-paint lifetime and is
  // Canvas bookkeeping only — it is not an issue and does not change the
  // returned state, which keeps reporting the unclosed depth. Frames are closed
  // innermost first (reverse push order), and before the root clip saves below
  // them, so each restore pops the state it was opened for.
  for (final int clipped in clipSavesPerSave.reversed) {
    for (int i = 0; i <= clipped; i++) {
      canvas.restore();
    }
  }
  clipSavesPerSave.clear();

  // Close the canvas saves of clips that had no wire save to own them. They sit
  // below every wire frame, so they are unwound last. The clip itself stays in
  // [stack] because Qt's painter keeps it until the painter is torn down; only
  // the Canvas bookkeeping is unwound here.
  for (int i = 0; i < rootClipSaves; i++) {
    canvas.restore();
  }

  return HudPaintResult(
    state: stack,
    issues: List<HudPaintIssue>.unmodifiable(issues),
  );
}

/// sRGB colour with Qt's painter opacity multiplied into the alpha channel
/// (`Glyphs.cpp:658-659` c.setOpacity(c.opacity() * n(1)) combined with
/// `Glyphs.cpp:35-49`, where alpha never enters the gamma transform).
ui.Color _hudInk(HudColor color, double opacity) => ui.Color.from(
      alpha: _clampHudUnit(color.alpha * opacity),
      red: _clampHudUnit(color.red),
      green: _clampHudUnit(color.green),
      blue: _clampHudUnit(color.blue),
    );

/// True when any dash entry is non-finite or non-positive - the case this file
/// refuses to swallow (`qstroker.cpp:1086` clamps such entries silently).
bool _hasNonPositiveDash(List<double> pattern) {
  for (final double value in pattern) {
    if (!value.isFinite || value <= 0) return true;
  }
  return false;
}

/// Normalizes a wire clip rectangle for a `Canvas.clipRect` call.
///
/// Qt's clip is a region: a rect with a negative extent is normalized by
/// `QRectF::normalized` (exactly what [intersectHudClip] mirrors in the
/// recorded state), and only a zero-area rect becomes the empty region that
/// clips everything away (Glyphs.cpp:676-678 feeds `n(1)..n(4)` straight into
/// `QPainter::setClipRect(QRectF, Qt::IntersectClip)`). Non-finite input
/// collapses because dart:ui asserts on NaN; returning [ui.Rect.zero] for the
/// empty case is deterministic instead of relying on Skia's rect sorting,
/// which is not part of the dart:ui contract.
ui.Rect _canvasHudClipRect(ui.Rect rect) {
  if (!rect.left.isFinite ||
      !rect.top.isFinite ||
      !rect.right.isFinite ||
      !rect.bottom.isFinite) {
    return ui.Rect.zero;
  }
  final double left = rect.left <= rect.right ? rect.left : rect.right;
  final double right = rect.left <= rect.right ? rect.right : rect.left;
  final double top = rect.top <= rect.bottom ? rect.top : rect.bottom;
  final double bottom = rect.top <= rect.bottom ? rect.bottom : rect.top;
  // A negative extent is normalized exactly like intersectHudClip normalizes
  // the recorded state, so the canvas region and the reported clip can never
  // disagree; only a genuinely zero-area extent becomes the empty region.
  if (right <= left || bottom <= top) return ui.Rect.zero;
  return ui.Rect.fromLTRB(left, top, right, bottom);
}

/// Clamps a colour component into the 0..1 range dart:ui accepts; non-finite
/// input collapses to 0 (a NaN opacity must not become a paint assertion).
double _clampHudUnit(double value) {
  if (!value.isFinite) return 0;
  if (value < 0) return 0;
  if (value > 1) return 1;
  return value;
}
