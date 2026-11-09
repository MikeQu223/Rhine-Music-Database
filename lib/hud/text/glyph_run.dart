// Faithful Dart port of the glyph-run measurement and painting layer in
// Qt/src/Glyphs.cpp: width(), bounds(), inset() and text().
//
// The Qt sources are the only authority for this module:
//
//  * width() walks the string as UTF-16 code units and adds
//    "advance * size + tracking" for every unit, then subtracts exactly ONE
//    tracking at the end. The last code unit therefore never carries tracking,
//    which is what the per-glyph painting loop leaves unused.
//                                                    (Glyphs.cpp:301-310)
//  * width() for a layout run shapes through QTextLayout with letter spacing
//    converted to font units ("tracking * 1000 / size") and multiplies the em
//    advance by "size".                              (Glyphs.cpp:296-299)
//  * bounds() maps the outline with translate(0, size * 1.044) followed by
//    scale(size / 1000, -size / 1000), and advances the per-character pen by
//    "advance * size" only: bounds() has no tracking argument at all.
//                                                    (Glyphs.cpp:312-338)
//  * inset() answers 0 for an empty string, uses only the first code unit of a
//    plain run, and scales the outline left edge by "size / 1000" WITHOUT the
//    baseline translate (x is unaffected by it).      (Glyphs.cpp:339-349)
//  * text() uses the same transform as bounds(), per code unit, and advances
//    the pen by "advance * size + tracking" AFTER the glyph is drawn.
//                                                    (Glyphs.cpp:530-564)
//
// Numeric fidelity rules: every product Qt computes is kept in the same
// operation order. "advance * size + tracking" is never reassociated into
// "advance * size * count + tracking * count", and "left * size / 1000" is
// never rewritten as "left * (size / 1000)"; the two differ in the last ulp.
//
// Fill rule: outlines arrive from parseSvgPath() with PathFillType.nonZero
// (Qt::WindingFill, Glyphs.cpp:172,437). Any run-level path built from these
// outlines must stay nonZero so overlapping glyphs never punch holes into each
// other.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'glyph_font.dart';

/// Result of shaping one string: an em advance plus a y-up outline in font
/// units.
///
/// This is the Dart stand-in for Qt's private Glyphs::Glyph (Glyphs.h:21-24).
class SimpleTextLayout {
  const SimpleTextLayout({
    required this.advanceEm,
    required this.outlineEm,
    this.boundsEm,
  });

  /// Advance in em with the letter spacing ALREADY subtracted, mirroring
  /// "qMax(0., line.horizontalAdvance() - spacing) / 1000" (Glyphs.cpp:170).
  ///
  /// A port must subtract the spacing it was given, because width() multiplies
  /// this value by the caller's size and does not subtract tracking again on
  /// the layout path (Glyphs.cpp:297).
  final double advanceEm;

  /// Outline in font units (kGlyphUnits per em), y-up, non-zero fill.
  ///
  /// Same coordinate space as [Glyph.path]: Qt maps it with
  /// translate(0, size * 1.044) then scale(size / 1000, -size / 1000).
  final ui.Path outlineEm;

  /// Tight bounds of [outlineEm] in font units, when the port can supply them.
  ///
  /// Qt answers bounds() and inset() with QPainterPath::boundingRect(), which
  /// solves curve extrema. A Dart path can only report Skia's control-point
  /// hull through Path.getBounds(), so a shaping port that cares about the
  /// difference passes the tight rectangle here; null falls back to the hull
  /// and is documented as the looser answer.
  final ui.Rect? boundsEm;

  /// Tight bounds of [outlineEm], falling back to the Skia hull.
  ui.Rect get tightBoundsEm => boundsEm ?? outlineEm.getBounds();
}

/// Injection port for the QTextLayout branch of Glyphs.cpp.
///
/// Qt shapes missing, combining, complex, RTL and Hangul-Jamo text with
/// QTextLayout and the system fallback faces (Glyphs.cpp:109-139,142-188).
/// A pure-Dart build cannot reproduce that shaping here, so the decision and
/// the shaping both live behind this port; fallback_shaper.dart supplies the
/// real implementation. Until a port is injected, [GlyphText] stays on the
/// per-code-unit resource path, exactly like a string Qt does not need to
/// layout.
/// Decides whether one string must go through [ComplexTextPort].
///
/// Qt's needsLayout() (Glyphs.cpp:109-139) walks the code points and answers
/// per string, so the decision cannot live in the port alone. fallback_shaper
/// .requiresFallback is the real implementation; injecting the decision keeps
/// it next to the shaping it justifies.
typedef ComplexTextGate = bool Function(String text, String weight);

abstract class ComplexTextPort {
  const ComplexTextPort();

  /// [trackingEm] is letter spacing in font units: Qt passes
  /// "tracking * 1000 / size" to QTextLayout (Glyphs.cpp:142-158,534).
  SimpleTextLayout layout(String text, String weight, double trackingEm);
}

/// Default port: present so [GlyphText] is usable without shaping, but never
/// reached, because [GlyphText.requiresComplexLayout] is false for it.
class _NoComplexTextPort extends ComplexTextPort {
  const _NoComplexTextPort();

  @override
  SimpleTextLayout layout(String text, String weight, double trackingEm) {
    throw UnsupportedError(
      'ComplexTextPort.layout was called without a shaping port. Inject one '
      '(fallback_shaper) before measuring text that requires complex layout.',
    );
  }
}

/// Measurement and painting of a single glyph run.
///
/// Mirrors the non-cached surface of Qt's Glyphs: width/bounds/inset/text.
/// The Qt object also carries an internal QCache keyed by (size, weight,
/// tracking, text); caching is deliberately NOT reproduced here, because the
/// callers in lib/hud own their layout invalidation and a hidden cache would
/// make golden output depend on call order.
class GlyphText {
  GlyphText(this.fonts, {ComplexTextPort? complex, this.gate})
      : complex = complex ?? const _NoComplexTextPort();

  /// Resource glyphs and symbol coverage (glyph_font.dart).
  final GlyphFontSet fonts;

  /// Shaping port; [_NoComplexTextPort] keeps everything on the resource path.
  final ComplexTextPort complex;

  /// Per-string shaping decision (Qt needsLayout). Null means "never shape",
  /// which is the safe side: Qt only leaves the resource path when its own
  /// needsLayout returns true, so an absent gate must not route plain ASCII
  /// through shaping.
  final ComplexTextGate? gate;

  /// True when a real shaping port is installed.
  bool get hasComplexPort => complex is! _NoComplexTextPort;

  /// Letter spacing in font units for Qt's QTextLayout branch.
  ///
  /// "size > 0 ? tracking * 1000 / size : 0" (Glyphs.cpp:297,534). The guard is
  /// not defensive: without it a zero size yields infinity/NaN spacing.
  double trackingEm(double tracking, double size) =>
      size > 0 ? tracking * kGlyphUnits / size : 0;

  /// Whether [text] must go through [complex] (Qt's needsLayout,
  /// Glyphs.cpp:109-139).
  ///
  /// Both halves must agree: a shaping port has to be installed AND the gate
  /// has to report that this particular string needs it. With no gate the
  /// resource path is used even when a port exists, because Qt only shapes a
  /// string whose needsLayout() (Glyphs.cpp:109-139) came back true — shaping
  /// every string would change advances and break the 1:1 picture.
  bool requiresComplexLayout(String text, String weight) {
    if (gate == null) {
      assert(
        !_structurallyNeedsShaping(text),
        'text needs shaping (a code point outside the BMP or U+200D) but no '
        'ComplexTextPort/gate is installed; Qt would run QTextLayout here. '
        'Inject fallback_shaper.requiresFallback as the gate.',
      );
      return false;
    }
    return hasComplexPort && gate!(text, weight);
  }

  /// Data-free subset of Qt's needsLayout: code points that need shaping even
  /// without a Unicode table.
  ///
  /// Only the two structural terms are checked, because a combining mark or a
  /// complex script cannot be recognised without category and script data;
  /// those stay the gate's job. This exists to turn a missing port from a
  /// silent wrong picture into a debug-build failure.
  static bool _structurallyNeedsShaping(String text) {
    for (final rune in text.runes) {
      if (rune > 0xffff || rune == 0x200d) {
        return true;
      }
    }
    return false;
  }

  /// Width in logical pixels: Qt Glyphs::width (Glyphs.cpp:286-311).
  double width(
    String text,
    double size, {
    String weight = kDefaultGlyphWeight,
    double tracking = 0,
  }) {
    if (requiresComplexLayout(text, weight)) {
      final shaped = complex.layout(text, weight, trackingEm(tracking, size));
      return shaped.advanceEm * size;
    }
    var result = 0.0;
    for (final unit in text.codeUnits) {
      final glyph = fonts.lookup(String.fromCharCode(unit), weight);
      result += glyph.advance * size + tracking;
    }
    // One tracking is added for the character AFTER the last one; Qt removes it
    // and clamps at zero so negative tracking on short text cannot go negative.
    return math.max(0.0, result - tracking);
  }

  /// Outline bounds in logical pixels: Qt Glyphs::bounds (Glyphs.cpp:312-338).
  ///
  /// Returns [ui.Rect.zero] when no code unit has an outline (Qt returns a
  /// default-constructed, null QRectF).
  ui.Rect bounds(
    String text,
    double size, {
    String weight = kDefaultGlyphWeight,
  }) {
    if (requiresComplexLayout(text, weight)) {
      final shaped = complex.layout(text, weight, 0);
      return _mapRect(shaped.tightBoundsEm, 0, 0, size);
    }
    ui.Rect? union;
    var x = 0.0;
    for (final unit in text.codeUnits) {
      final glyph = fonts.lookup(String.fromCharCode(unit), weight);
      // Qt unions only glyphs whose path is not empty (element count, NOT
      // area: Glyphs.cpp:327), but still advances x for the empty ones.
      final tight = glyph.bounds;
      if (glyph.hasOutline && tight != null) {
        final mapped = _mapRect(tight, x, 0, size);
        union = union == null ? mapped : union.expandToInclude(mapped);
      }
      x += glyph.advance * size;
    }
    return union ?? ui.Rect.zero;
  }

  /// Left side bearing of the first glyph: Qt Glyphs::inset (Glyphs.cpp:339-349).
  ///
  /// No baseline translate and no tracking: only x*size/1000 is handled, and a
  /// glyph without an outline answers 0 rather than its advance.
  double inset(
    String text,
    double size, {
    String weight = kDefaultGlyphWeight,
  }) {
    if (text.isEmpty) {
      return 0;
    }
    if (requiresComplexLayout(text, weight)) {
      final shaped = complex.layout(text, weight, 0);
      return shaped.tightBoundsEm.left * size / kGlyphUnits;
    }
    final glyph = fonts.lookup(String.fromCharCode(text.codeUnitAt(0)), weight);
    final tight = glyph.bounds;
    if (!glyph.hasOutline || tight == null) {
      return 0;
    }
    // Qt: glyph.path.boundingRect().x() * size / 1000, i.e. the TIGHT left
    // edge, not the control-point hull.
    return tight.left * size / kGlyphUnits;
  }

  /// Draws [text] with its em-box top-left at (x, y): Qt Glyphs::text
  /// (Glyphs.cpp:530-564).
  ///
  /// Each outline is drawn under its own save/translate/scale/restore, so the
  /// pen advance is applied in device-independent units and NOT scaled; the
  /// trailing tracking after the last glyph is accumulated but never drawn,
  /// which is exactly why width() subtracts it (Glyphs.cpp:562 + 306).
  void paintText(
    ui.Canvas canvas,
    String text,
    double x,
    double y,
    double size, {
    String weight = kDefaultGlyphWeight,
    double tracking = 0,
    required ui.Paint ink,
  }) {
    if (requiresComplexLayout(text, weight)) {
      final shaped = complex.layout(text, weight, trackingEm(tracking, size));
      _paintOutline(canvas, shaped.outlineEm, x, y, size, ink);
      return;
    }
    var penX = x;
    for (final unit in text.codeUnits) {
      final glyph = fonts.lookup(String.fromCharCode(unit), weight);
      _paintOutline(canvas, glyph.path, penX, y, size, ink);
      penX += glyph.advance * size + tracking;
    }
  }

  /// Maps a tight rectangle from font units into logical pixels at (x, y).
  ///
  /// Qt maps path.boundingRect() through translate(x, y + size * 1.044) then
  /// scale(size / 1000, -size / 1000) (Glyphs.cpp:328, 345). A scale plus
  /// translate maps an axis-aligned box exactly, so the rectangle is
  /// transformed directly instead of transforming the outline again: a glyph
  /// point p lands at (x + p.x * size / 1000, y + size * 1.044 - p.y * size /
  /// 1000), which swaps top and bottom in the y-up font space.
  static ui.Rect _mapRect(ui.Rect rect, double x, double y, double size) {
    final scale = size / kGlyphUnits;
    final baseline = y + size * kBaselineFactor;
    return ui.Rect.fromLTRB(
      x + rect.left * scale,
      baseline - rect.bottom * scale,
      x + rect.right * scale,
      baseline - rect.top * scale,
    );
  }

  /// Per-outline painter transform: Qt c.save(); c.translate(x, y + size *
  /// 1.044); c.scale(size / 1000, -size / 1000); c.fillPath(path); c.restore()
  /// (Glyphs.cpp:535-539, 557-561).
  ///
  /// Canvas concatenation applies the scale to the geometry before the
  /// translate, matching Qt, and save/restore are unconditional and paired on
  /// the same straight-line path.
  static void _paintOutline(
    ui.Canvas canvas,
    ui.Path outline,
    double x,
    double y,
    double size,
    ui.Paint ink,
  ) {
    canvas.save();
    canvas.translate(x, y + size * kBaselineFactor);
    canvas.scale(size / kGlyphUnits, -size / kGlyphUnits);
    canvas.drawPath(outline, ink);
    canvas.restore();
  }
}
