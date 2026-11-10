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
    required this.boundsEm,
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

  /// TIGHT bounds of [outlineEm] in font units. Required, never a hull.
  ///
  /// Qt answers bounds() and inset() with QPainterPath::boundingRect(), which
  /// solves curve extrema analytically (Glyphs.cpp:327-330,344-348). Dart
  /// exposes only Skia's Path.getBounds(), the control-point hull, which is at
  /// least as large as the true box and strictly larger whenever a control
  /// point lies off the curve; reporting it would silently loosen a result
  /// that claims Qt's answer. The port must
  /// therefore compute the tight rectangle from the shaped run (the same
  /// extrema math as glyph_font.parseSvgOutline). A port that cannot do that
  /// must not implement [ComplexTextPort] at all.
  final ui.Rect boundsEm;
}

/// Decides whether one string must go through [ComplexTextPort].
///
/// Qt's needsLayout() (Glyphs.cpp:109-139) walks the code points and answers
/// per STRING, not per port, so the decision cannot live inside the shaping
/// port. fallback_shaper.requiresFallback is the real implementation; keeping
/// the decision a separate function lets a caller reuse it for the resource
/// table it was built against.
typedef ComplexTextGate = bool Function(String text, String weight);

/// Injection port for the QTextLayout branch of Glyphs.cpp.
///
/// Qt shapes missing, combining, complex, RTL, Hangul-Jamo and ZWJ text with
/// QTextLayout and the system fallback faces (Glyphs.cpp:109-139,142-188).
/// A pure-Dart build cannot reproduce that shaping here, so the shaping lives
/// behind this port and the per-string decision behind [ComplexTextGate];
/// [GlyphText] takes both or neither, never one alone.
///
/// An implementation must return the run Qt's layoutText() would actually
/// draw and measure: real shaped outlines, the real net advance and the real
/// tight bounds. A port that returns an empty path, a concatenation of the
/// per-code-unit resource glyphs, or a zero advance is not a shaping port; it
/// would make the complex branch look correct while painting the wrong run,
/// which is worse than refusing to build the pair.
abstract class ComplexTextPort {
  const ComplexTextPort();

  /// [trackingEm] is letter spacing in font units: Qt passes
  /// "tracking * 1000 / size" to QTextLayout (Glyphs.cpp:142-158,534).
  ///
  /// Preconditions, all three load-bearing:
  ///  * [SimpleTextLayout.advanceEm] is already net of [trackingEm], mirroring
  ///    "qMax(0., line.horizontalAdvance() - spacing) / 1000"
  ///    (Glyphs.cpp:170);
  ///  * [SimpleTextLayout.outlineEm] holds the real shaped outlines in font
  ///    units, y-up, non-zero fill, in the same space as [Glyph.path];
  ///  * [SimpleTextLayout.boundsEm] is their TIGHT box, never Skia's hull.
  SimpleTextLayout layout(String text, String weight, double trackingEm);
}

/// Placeholder port of [GlyphText.resourceOnly], never a real shaper.
///
/// [GlyphText.requiresComplexLayout] never routes a run here: a resource-only
/// instance answers false only for text whose resource table can paint its code
/// units and whose Unicode-property checks are plain, and throws for the
/// classes it can prove need layout, so arriving in [layout] means the pair
/// was wired wrong. (A bidi-only case is the documented gap, not a proof of
/// plain text.)
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
  /// Full configuration: Qt's decision and Qt's shaping, always as a pair.
  ///
  /// Both halves are required. Qt leaves the resource path only when
  /// needsLayout() returns true (Glyphs.cpp:109-139,296-299) and then always
  /// shapes the run. A port without a gate would shape nothing; a gate without
  /// a port would answer "this needs layout" with nothing to lay it out.
  /// Omitting either half is a wiring bug and fails to compile. An explicit
  /// null [gate] still compiles because the type is nullable, so
  /// [requiresComplexLayout] rejects that state before it can ignore the port
  /// instead of degrading to a silent resource-path picture.
  ///
  /// [gate] must be built over the SAME resource set as [fonts]: its term-7
  /// coverage check (Glyphs.cpp:130) answers "Qt would shape" when both the
  /// resource table and the symbol face lack the code point, so a gate built
  /// against another font set would disagree with the outlines painted here.
  /// fallback_shaper.requiresFallbackGate closes over the set for that reason.
  GlyphText(this.fonts, {required this.complex, required this.gate});

  /// Deliberate resource-only mode: no gate, no shaper.
  ///
  /// A PARTIAL candidate for Qt's needsLayout(), not an equivalent of it. It is
  /// an explicit choice, never a default, and [requiresComplexLayout] refuses
  /// in release builds too every string this path can prove it cannot paint
  /// faithfully: a code point outside the BMP, an unpaired UTF-16 surrogate,
  /// U+200D, a combining mark (Qt's three Mark_* categories), a Hangul Jamo, a
  /// code point outside Qt's script whitelist, or a code point the resource
  /// table of this weight has no outline for. A missing wiring therefore cannot
  /// turn one emoji into two lone surrogates, and cannot turn a Hebrew, Arabic,
  /// Devanagari, Thai, Hangul Jamo or combining-mark string into silent 1 em
  /// blanks.
  ///
  /// This is a tripwire over the supplied resource table, not a claim that
  /// complex Qt layout is equivalent. What is still missing: a case whose
  /// evidence is bidi data (term (6) of Qt's loop). No Dart API exposes
  /// Bidi_Class -- the SDK documents no bidi query and RegExp property escapes
  /// have no Bidi_Class group -- so only an injected table can answer it. A
  /// shipping caller must pass the full constructor with fallback_shaper, and
  /// a real [ComplexTextPort] (QTextLayout plus the system fallback faces) is
  /// not implemented in this layer yet.
  GlyphText.resourceOnly(this.fonts)
      : complex = const _NoComplexTextPort(),
        gate = null;

  /// Resource glyphs and symbol coverage (glyph_font.dart).
  final GlyphFontSet fonts;

  /// Shaping port for runs the gate accepts.
  final ComplexTextPort complex;

  /// Per-string shaping decision (Qt needsLayout); null for
  /// [GlyphText.resourceOnly]. The full constructor also accepts null at the
  /// type level, and [requiresComplexLayout] throws for that invalid pair
  /// before it can ignore the injected port.
  final ComplexTextGate? gate;

  /// True when [gate] is null: [GlyphText.resourceOnly], or the invalid
  /// full-constructor state that [requiresComplexLayout] rejects.
  bool get isResourceOnly => gate == null;

  /// Letter spacing in font units for Qt's QTextLayout branch.
  ///
  /// "size > 0 ? tracking * 1000 / size : 0" (Glyphs.cpp:297,534). The guard is
  /// not defensive: without it a zero size yields infinity/NaN spacing.
  double trackingEm(double tracking, double size) =>
      size > 0 ? tracking * kGlyphUnits / size : 0;

  /// Whether [text] must go through [complex] (Qt's needsLayout,
  /// Glyphs.cpp:109-139).
  ///
  /// The full configuration answers with [gate] alone: the gate IS Qt's
  /// needsLayout for this string, and the constructor guarantees that a port
  /// exists to shape whatever the gate accepts. Shaping every string instead
  /// would change advances and break the 1:1 picture, so the answer is never
  /// "yes" without the gate's consent.
  ///
  /// [GlyphText.resourceOnly] is a partial answer, never an equivalent one. It
  /// answers false only for text whose code units its resource table can paint
  /// and whose Unicode-property checks are plain, and throws [StateError] for
  /// everything it can prove it cannot paint: Qt would have run QTextLayout
  /// (Glyphs.cpp:128) where the UTF-16 resource path paints a surrogate pair as
  /// two default glyphs, a bare joiner, a standalone combining mark, a
  /// non-whitelisted script, or a silent 1 em blank for a code point the
  /// resource table does not carry. A case whose evidence is only bidi data
  /// (Qt's term (6)) is not detectable in this layer at all: that is the
  /// documented gap the injected classifier exists to supply, not a case this
  /// constructor proves plain.
  ///
  /// Throwing rather than asserting is the point: a debug-only guard is
  /// stripped from release builds, which left exactly the silent wrong picture
  /// this method exists to prevent. Catching the error is not an alternative to
  /// wiring the pair — the resource path has no correct measurement for such a
  /// string.
  bool requiresComplexLayout(String text, String weight) {
    final gate = this.gate;
    if (gate != null) {
      return gate(text, weight);
    }
    // A port was injected but the per-string decision is missing, so this
    // instance would ignore the port and paint the resource path exactly for
    // the runs the port exists to shape. Fail instead of dropping it silently:
    // isResourceOnly is true in this state, which would otherwise tell callers
    // that the pair was wired.
    if (complex is! _NoComplexTextPort) {
      throw StateError(
        'GlyphText was built with a ComplexTextPort but a null gate: the '
        'resource path has no correct measurement for a run the port exists to '
        'shape. Pass the per-string decision together with the port '
        '(fallback_shaper.requiresFallbackGate), or construct with '
        'GlyphText.resourceOnly and no port at all.',
      );
    }
    final int offending = _firstStructurallyComplex(text);
    if (offending >= 0) {
      final String hex =
          offending.toRadixString(16).toUpperCase().padLeft(4, '0');
      throw StateError(
        'GlyphText.resourceOnly cannot measure or paint a string containing '
        'U+$hex: Qt routes it through QTextLayout (Glyphs.cpp:128), while the '
        'resource path would paint its UTF-16 units independently -- a default '
        '1 em glyph for a missing outline, a standalone mark, or a bare '
        'joiner -- instead of the shaped run Qt draws. Construct GlyphText '
        'with a ComplexTextPort and the fallback_shaper gate '
        '(requiresFallbackGate) instead of the resource-only constructor.',
      );
    }
    final int unpaintable = _firstUnpaintable(text, weight);
    if (unpaintable >= 0) {
      final String hex =
          unpaintable.toRadixString(16).toUpperCase().padLeft(4, '0');
      throw StateError(
        'GlyphText.resourceOnly cannot paint U+$hex: the resource table of this '
        'weight has no outline for that code point, so the UTF-16 fast path '
        'would emit the default 1 em empty glyph, while Qt draws the outline '
        'from another face or routes the run through QTextLayout '
        '(Glyphs.cpp:109-139, 266-285). Inject the ComplexTextPort + gate pair, '
        'or add the glyph to the resource table.',
      );
    }
    return false;
  }

  /// First code point the resource path cannot paint faithfully for a
  /// structural or Unicode-property reason, or -1.
  ///
  /// These classes are decidable without an injected Unicode table:
  ///   * a code point outside the BMP (a surrogate pair), Glyphs.cpp:128;
  ///   * an unpaired UTF-16 surrogate. String.runes cannot see it, while Qt's
  ///     toUcs4() replaces every invalid sequence with U+FFFD
  ///     (third_party/qt/qtbase/src/corelib/text/qstring.cpp:5811-5814).
  ///     Neither the shipped OTF nor the symbol face maps U+FFFD, so Qt's
  ///     term (7) sends the string through QTextLayout (Glyphs.cpp:117-134).
  ///     The resource path would paint the lone code unit as a 1 em default
  ///     glyph instead, so code units are scanned first and resource-only
  ///     refuses rather than guess at Qt's replacement;
  ///   * U+200D, the emoji/Indic join control, Glyphs.cpp:128;
  ///   * a combining mark (Qt's Mark_NonSpacing, Mark_SpacingCombining and
  ///     Mark_Enclosing, term (2)), via the \p{M} General_Category group;
  ///   * a Hangul Jamo (Script_Hangul outside the precomposed syllable block
  ///     U+AC00..U+D7A3, term (3));
  ///   * any other script outside Qt's whitelist {Common, Inherited, Latin,
  ///     Han, Hiragana, Katakana, Hangul} (term (4)), via \p{Script=...}.
  ///
  /// The property escapes are backed by the SDK contract: dart:core RegExp has
  /// "the same syntax and semantics as JavaScript regular expressions"
  /// (dart-sdk/lib/core/regexp.dart:17-20) and implements the ECMAScript RegExp
  /// specification (:91-92); ECMAScript property escapes include Script= and
  /// the General_Category groups. No pattern in this tree used them before this
  /// fix, and this phase forbids running tests, so their behaviour here is
  /// contract-backed rather than executed.
  ///
  /// Term (6), bidi (DirR/DirAL), is NOT decidable this way: ECMAScript
  /// property escapes do not expose Bidi_Class. It stays in the injected
  /// classifier; resource-only mode documents it as missing rather than
  /// pretending to cover it. Term (7) coverage is answered separately and
  /// deliberately more strictly by [_firstUnpaintable].
  static int _firstStructurallyComplex(String text) {
    final List<int> units = text.codeUnits;
    for (var i = 0; i < units.length; i++) {
      final int unit = units[i];
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (i + 1 < units.length) {
          final int next = units[i + 1];
          if (next >= 0xdc00 && next <= 0xdfff) {
            return 0x10000 + ((unit - 0xd800) << 10) + (next - 0xdc00);
          }
        }
        return unit;
      }
      if (unit >= 0xdc00 && unit <= 0xdfff) {
        return unit;
      }
      if (unit == 0x200d) {
        return unit;
      }
      // ASCII is Common or Latin, never a mark or Jamo, so the property
      // checks only need non-ASCII input.
      if (unit < 0x80) {
        continue;
      }
      final String character = String.fromCharCode(unit);
      if (_combiningMark.hasMatch(character)) {
        return unit;
      }
      if (_hangulJamo.hasMatch(character) &&
          (unit < 0xac00 || unit > 0xd7a3)) {
        return unit;
      }
      if (!_whitelistedScript.hasMatch(character)) {
        return unit;
      }
    }
    return -1;
  }

  /// Qt term (2): Mark_NonSpacing, Mark_SpacingCombining, Mark_Enclosing.
  static final RegExp _combiningMark = RegExp(r'^\p{M}$', unicode: true);

  /// Qt term (3): Script_Hangul; the caller excludes precomposed syllables.
  static final RegExp _hangulJamo =
      RegExp(r'^\p{Script=Hangul}$', unicode: true);

  /// Qt term (4): the scripts Qt does not treat as contextual.
  static final RegExp _whitelistedScript = RegExp(
    r'^[\p{Script=Common}\p{Script=Inherited}\p{Script=Latin}'
    r'\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}'
    r'\p{Script=Hangul}]$',
    unicode: true,
  );

  /// First code point this resource-only instance cannot paint, or -1.
  ///
  /// Not Qt's term (7), and deliberately stricter than it. Qt asks the mapped
  /// QRawFont and the symbol face (QRawFont::supportsCharacter), so a code
  /// point the resource table misses can still be painted from the OTF; this
  /// path can only draw what misans-glyphs.json carries, and glyph_font.dart
  /// answers the 1 em default glyph for anything else. Dropping term (7) from
  /// the predicate above does NOT make such a code point paintable, so the
  /// missing outline is checked here where the font set is in scope.
  ///
  /// The shipped table makes the overlap concrete: 1007 code points per
  /// weight. Its key ranges are ASCII/Latin-1 letters and punctuation, CJK
  /// Unified Ideographs, and a small set of Common punctuation and symbols
  /// (arrows, geometric shapes, fullwidth forms); every key is Common, Latin or
  /// Han script, and none is a combining mark, a kana or a Hangul Jamo. The
  /// whitelisted code points the OTF covers but the table misses (Latin
  /// Extended, kana, U+2014, ...) are refused here; the non-whitelisted
  /// scripts and marks, whether or not the OTF covers them (U+05D0, U+0627,
  /// U+0E01, U+0905, U+0410, U+03B1, U+1100, U+0301, U+FE0F), are refused
  /// earlier by the property checks in [_firstStructurallyComplex].
  /// Resource-only mode therefore needs no hand-written code-point table:
  /// the property escapes answer the Unicode classes, and this table lookup
  /// answers coverage from data this tree can read and check.
  ///
  /// \p{Script=...} is not used here: term (7) is a coverage question, and the
  /// script whitelist is decided earlier. The Dart SDK's RegExp contract makes
  /// those property escapes contractual; see [_firstStructurallyComplex].
  int _firstUnpaintable(String text, String weight) {
    for (final rune in text.runes) {
      if (!fonts.hasOutline(String.fromCharCode(rune), weight)) {
        return rune;
      }
    }
    return -1;
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
      return _mapRect(shaped.boundsEm, 0, 0, size);
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
      return shaped.boundsEm.left * size / kGlyphUnits;
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
  /// scale(size / 1000, -size / 1000) (Glyphs.cpp:316-317, 328-330). A scale plus
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
