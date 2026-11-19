// native HUD render operations — accumulated opacity and intersected clip.
//
// Single source of truth is the Qt painter dispatch in
// `Qt/src/Glyphs.cpp:637-829`, a flat JSON array walk: element 0
// is the op name and there is no envelope, id, sequence number or z index. Two
// ops own the state modelled here:
//
//   alpha -> c.setOpacity(c.opacity() * n(1))            Glyphs.cpp:658-659
//   clip  -> c.setClipRect(QRectF(n1,n2,n3,n4), Qt::IntersectClip)
//                                                        Glyphs.cpp:676-678
//
// `save` / `restore` (Glyphs.cpp:644-657) are `QPainter::save()` /
// `QPainter::restore()`: a save snapshots opacity and clip, a restore puts
// the snapshot back, and an unbalanced restore only warns and leaves the state
// untouched (third_party/qt/qtbase/src/gui/painting/qpainter.cpp:1603-1606).
//
// This file is pure value math on `dart:ui` types: no Canvas, no Paint,
// no command decoding, no golden. The op dispatcher
// (lib/hud/protocol/hud_command.dart) owns dropping unknown ops before they
// ever reach the painter.
//
// CITATION NOTE: third_party/qt is an unpopulated submodule in this worktree
// (qtbase/ is empty), so the qpainter.cpp / qrect.cpp line numbers below are
// upstream Qt 6 references, not files verified in-tree. The behaviour modelled
// here was checked against Qt/src (Glyphs.cpp:658-659 for alpha, :676-678 for
// clip, :644-657 for save/restore); the setOpacity clamp claim is an
// upstream-API claim, disclosed as unverified rather than asserted.

import 'dart:ui' as ui;

/// Multiplies the accumulated HUD opacity by [factor].
///
/// Qt: `c.setOpacity(c.opacity() * n(1))` (Qt/src/Glyphs.cpp:658-659),
/// so nested `alpha` ops accumulate multiplicatively instead of replacing
/// each other: 1.0 * 0.5 * 0.5 == 0.25.
///
/// The product is deliberately **not** clamped here. Qt clamps inside
/// `QPainter::setOpacity` — `qMin(qreal(1), qMax(qreal(0), opacity))`,
/// qpainter.cpp:2073 — and that clamp changes what later `alpha` ops
/// multiply, so it belongs to the painter's `alpha` op. This file keeps the
/// pure product and clamps nothing. For factors already inside [0, 1] the pure
/// product and the clamped product are identical.
///
/// Known residual divergence. Qt clamps **before storing**, so
/// later `alpha` ops multiply the clamped value: `alpha(2.0)` then
/// `alpha(0.4)` is 0.4 in Qt (1.0 clamped, then * 0.4) but 0.8 here, and
/// clamping only at consumption still gives 0.8. The frozen API mandates the
/// pure product, so this file cannot close that gap alone; clamping belongs at
/// the API boundary (either in accumulation, or in the painter while accepting
/// the residual). Every producer in Qt feeds an animation/detail opacity whose
/// intended range is [0, 1] (NativeHudBoot.cpp:164-166, NativeHudDetail.cpp:64,
/// :507, NativeHudModal.cpp:84, NativeHud.cpp:583, :601 — the only
/// `setOpacity` call sites are Glyphs.cpp:659 and DesktopLyricsView.cpp:84) and
/// the decoder does not clamp
/// (lib/hud/protocol/hud_command.dart:486-487), so the consuming paint layer
/// folds the accumulated opacity into the final ink colour and clamps that
/// product into [0, 1] (`lib/hud/render/paint_stack.dart`, `_hudInk`); the
/// accumulator itself never clamps.
double composeHudOpacity(double currentOpacity, double factor) =>
    currentOpacity * factor;

/// Intersects two logical clip rectangles exactly like `QRectF::operator&`.
///
/// `QRectF::intersected()` is `operator&` (qrect.h:876-879); the body is
/// third_party/qt/qtbase/src/corelib/tools/qrect.cpp:2226-2276 and it does:
///
/// 1. normalize both operands first (`normalized()`, qrect.cpp:1553-1565):
///    a negative width or height moves the origin to the opposite edge instead
///    of being clipped away;
/// 2. treat a rect with a zero-width axis or a zero-height axis as null and
///    return `QRectF()` — origin (0, 0), zero size. Qt tests each axis on its
///    own: `if (l1 == r1) return QRectF();` for width (qrect.cpp:2234-2235 /
///    2243-2244) and `if (t1 == b1)` for height (qrect.cpp:2255-2256 /
///    2264-2265). `QRectF::isNull()` is the both-axes form (qrect.h:687-688)
///    and is deliberately NOT the test used here, so a rect that is only
///    zero-width still collapses to the null rect;
/// 3. return that same null rect when the two rects do not overlap by a
///    positive area, so edge-adjacent rects never produce a zero-thickness
///    strip at the shared edge (qrect.cpp:2246-2247, 2267-2268);
/// 4. otherwise return `(qMax(left), qMax(top))` sized by
///    `qMin(right) - left` and `qMin(bottom) - top` (qrect.cpp:2270-2275).
///
/// Every empty outcome is [ui.Rect.zero], not a degenerate rect parked at the
/// touching edge. That is the value Qt returns and it keeps clips comparable by
/// value downstream.
///
/// Space invariant (review F3): both operands are combined in STAGE (logical)
/// space, with no knowledge of the painter transform. Qt instead records the
/// matrix that was live when each clip was set
/// (`QPainterClipInfo(rect, op, d->state->matrix)`, qpainter.cpp:2768) and maps
/// each rect with its own matrix before intersecting
/// (`r = info.matrix.mapRect(r); ... bounds &= r;`, qpainter.cpp:2702-2721) —
/// Qt accumulates clips in DEVICE space. So this value equals Qt's clip only
/// while the transform is constant between clip ops inside one save scope. The
/// painter must call `canvas.clipRect` with the per-op rect under the
/// then-current transform and treat the stack value as a state readout, not as
/// the device clip; if a translate/scale/rotate appears between two clips in
/// one scope it must report an issue instead of trusting this intersection
/// (Qt's own clip replayer punts on exactly that,
/// Qt/src/render/HudDirtyRect.h:98-101).
ui.Rect intersectHudClip(ui.Rect current, ui.Rect next) {
  final a = _normalizeRect(current);
  final b = _normalizeRect(next);
  // Qt short-circuits per axis as soon as an operand is null. After
  // normalization a null axis is exactly == 0, never negative.
  if (a.width == 0 || a.height == 0 || b.width == 0 || b.height == 0) {
    return ui.Rect.zero;
  }
  if (a.left >= b.right || b.left >= a.right) return ui.Rect.zero;
  if (a.top >= b.bottom || b.top >= a.bottom) return ui.Rect.zero;
  return ui.Rect.fromLTRB(
    _qMax(a.left, b.left),
    _qMax(a.top, b.top),
    _qMin(a.right, b.right),
    _qMin(a.bottom, b.bottom),
  );
}

/// Immutable snapshot of the painter state this file owns.
///
/// One instance is pushed per [HudPaintStateStack.save]; it is a copy, exactly
/// like the `QPainterState` Qt allocates in `QPainter::save()`
/// (qpainter.cpp:1562-1587), so later `alpha` / `clip` ops can never mutate
/// a snapshot that was already taken.
final class HudPainterState {
  const HudPainterState({
    required this.opacity,
    required this.clip,
    required this.depth,
  });

  /// Accumulated opacity at snapshot time, in `QPainter::opacity()` units.
  ///
  /// Default 1.0: `qreal opacity = 1;` in qpainter_p.h:136.
  final double opacity;

  /// Intersected clip at snapshot time, or null when no `clip` op has run
  /// yet. Null ("everything is paintable") is not the same value as an empty
  /// rect ("nothing is paintable"); [HudPaintStateStack.hasClip] keeps the two
  /// apart.
  final ui.Rect? clip;

  /// Save-stack depth at snapshot time. 0 is the root frame.
  final int depth;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HudPainterState &&
          other.opacity == opacity &&
          other.clip == clip &&
          other.depth == depth;

  @override
  int get hashCode => Object.hash(opacity, clip, depth);

  @override
  String toString() =>
      'HudPainterState(opacity: $opacity, clip: $clip, depth: $depth)';
}

/// The `save` / `restore` / `alpha` / `clip` slice of the Qt painter state.
///
/// Qt semantics reproduced one to one:
///
/// * [save] snapshots opacity and clip and raises [depth]; later ops never
///   mutate a taken snapshot because Qt copies the state
///   (qpainter.cpp:1562-1587).
/// * [restore] puts the newest snapshot back and returns true. On an unbalanced
///   stack Qt warns `QPainter::restore: Unbalanced save/restore` and
///   returns without touching the state (qpainter.cpp:1603-1606); this stack
///   returns false and likewise changes nothing — depth included, so repeated
///   unbalanced restores are all no-ops.
/// * [hasClip] separates "no clip op has run" (null, whole stage paintable) from
///   "clipped to nothing" (empty rect). Qt's painter stays clipped once
///   `setClipRect` has run, even when the intersection is empty, so an empty
///   clip is never turned back into null here.
///
/// The stack is a Flutter-local wrapper, not a Qt wire structure: the wire has
/// no sequence numbers, ids or frames, only the flat command array.
///
/// Pairing contract (review F4): this stack owns opacity, clip and depth only —
/// the transform lives on the canvas, just as `QPainterState` keeps
/// `worldMatrix` / `matrix` (qpainter_p.h:131-132). The painter must call
/// [save] exactly where it calls `canvas.save()` and [restore] exactly where it
/// calls `canvas.restore()`; an uneven pair drifts from Qt silently and nothing
/// in this file can detect it.
final class HudPaintStateStack {
  HudPaintStateStack({double opacity = 1.0, ui.Rect? clip})
      : _opacity = opacity,
        _clip = _normalizeOptionalRect(clip);

  final List<HudPainterState> _saved = <HudPainterState>[];

  double _opacity;
  ui.Rect? _clip;
  int _depth = 0;

  /// Current accumulated opacity; starts at 1.0 like a fresh `QPainter`
  /// (qpainter_p.h:136).
  double get opacity => _opacity;

  /// Current clip, or null when no `clip` op has been applied.
  ui.Rect? get clip => _clip;

  /// True once a clip has been set, including when the clip is an empty rect.
  bool get hasClip => _clip != null;

  /// Number of outstanding [save] frames; 0 at the root, never negative.
  int get depth => _depth;

  /// True when every [save] has been paired with a [restore].
  bool get isBalanced => _depth == 0;

  /// Read-only snapshot of the save stack, oldest frame first.
  ///
  /// This is a copy: a list already handed out is unaffected by later [save]
  /// and [restore] calls, so callers can diff a state machine without racing
  /// it.
  List<HudPainterState> get states =>
      List<HudPainterState>.unmodifiable(_saved);

  /// Pushes the current opacity and clip, like `c.save()` (Glyphs.cpp:644-650).
  void save() {
    _saved.add(HudPainterState(opacity: _opacity, clip: _clip, depth: _depth));
    _depth++;
  }

  /// Pops the newest snapshot, restoring opacity, clip and depth.
  ///
  /// Returns false and leaves every field untouched when the stack is
  /// unbalanced (`depth == 0`), mirroring Qt's unbalanced branch
  /// (qpainter.cpp:1603-1606). The caller must record that as an issue; this
  /// 文件 never swallows it silently.
  bool restore() {
    if (_depth == 0 || _saved.isEmpty) return false;
    final HudPainterState previous = _saved.removeLast();
    _opacity = previous.opacity;
    _clip = previous.clip;
    // Equal to _depth - 1 while save/restore stay paired; taking it from the
    // snapshot keeps depth and the stack length in lockstep by construction.
    _depth = previous.depth;
    return true;
  }

  /// Multiplies the accumulated opacity by [factor] (Glyphs.cpp:658-659).
  ///
  /// Stores the raw product; see the F2 note on [composeHudOpacity] for the
  /// residual divergence when a factor leaves [0, 1].
  void applyAlpha(double factor) {
    _opacity = composeHudOpacity(_opacity, factor);
  }

  /// Intersects the current clip with [rect] and returns the new clip.
  ///
  /// The first call replaces "no clip" with the normalized rect; every later
  /// call is [intersectHudClip] against the accumulated clip, which is what
  /// `c.setClipRect(next, Qt::IntersectClip)` does (Glyphs.cpp:676-678).
  ///
  /// The result is nullable only because the frozen API declares it so. In
  /// practice it is never null after a rect is passed, and it is always
  /// identical to [clip].
  ///
  /// The value is a STAGE-space clip; the space invariant on [intersectHudClip]
  /// applies to every call after the first.
  ui.Rect? applyClip(ui.Rect rect) {
    final ui.Rect? current = _clip;
    _clip = current == null
        ? _normalizeRect(rect)
        : intersectHudClip(current, rect);
    return _clip;
  }
}

/// `QRectF::normalized()` (qrect.cpp:1553-1565): a negative width or
/// height moves the origin to the opposite edge and makes the extent positive.
ui.Rect _normalizeRect(ui.Rect rect) {
  var left = rect.left;
  var top = rect.top;
  var right = rect.right;
  var bottom = rect.bottom;
  if (rect.width < 0) {
    left = rect.left + rect.width;
    right = rect.left;
  }
  if (rect.height < 0) {
    top = rect.top + rect.height;
    bottom = rect.top;
  }
  return ui.Rect.fromLTRB(left, top, right, bottom);
}

ui.Rect? _normalizeOptionalRect(ui.Rect? rect) =>
    rect == null ? null : _normalizeRect(rect);

/// Qt's `qMax` / `qMin` — `(a < b) ? b : a` and `(a < b) ? a : b`.
///
/// Deliberately not `dart:math`: this file imports only `dart:ui`, and
/// these forms also keep NaN operands behaving like the C++ original instead of
/// picking a different operand.
double _qMax(double a, double b) => a < b ? b : a;

double _qMin(double a, double b) => a < b ? a : b;
