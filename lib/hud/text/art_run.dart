// Faithful Dart port of the boot lettering layer in Qt/src/Glyphs.cpp:
// artWidth() and art().
//
// The Qt sources are the only authority for this module:
//
//  * boot-lettering-art.json is { key: { text, weight, units, letters: [
//    { width, path } ] } }. Loading stores "width" as the advance in em and
//    the path string unchanged.                          (Glyphs.cpp:83-89)
//  * Glyphs.h declares artWidth(key, size, tracking = 0, count = -1) and
//    art(ctx, key, x, y, size, count, tracking).        (Glyphs.h:29,32)
//  * artWidth() sums "advance * size + tracking" over the visible letters and
//    then subtracts exactly ONE tracking, so the last letter never carries
//    tracking. An empty visible range answers 0.     (Glyphs.cpp:403-412)
//  * art() draws every visible letter with
//    save() -> translate(x, y) -> scale(size / 1000, size / 1000) ->
//    fillPath(path) -> restore(), advancing the pen by
//    "advance * size + tracking" AFTER the letter is drawn, so the trailing
//    tracking of the last letter is accumulated but never drawn — which is
//    exactly why artWidth() subtracts it.              (Glyphs.cpp:565-588)
//  * art() paints with whatever brush the caller left on the painter; the
//    command executor sets that brush from the color array first
//    ("c.setBrush(color(a[7]))", Glyphs.cpp:726). The port therefore takes the
//    color explicitly instead of reading painter state.
//  * the Android run cache (artRunPath, Glyphs.cpp:454-475) is gated behind
//    RHINE_HUD_RUN_CACHE and is OFF by default (Glyphs.cpp:414-420), so the
//    per-letter loop above is the shipping path; no cached run is ported.
//  * Qt hardcodes 1000 as the em divisor here and never reads the per-key
//    "units" field of the lettering resource, so the port uses [kGlyphUnits]
//    (a constant equal to 1000) and ignores Lettering.units.
//
// Coordinate system — the one thing that is NOT shared with text:
//
//   boot-lettering-art.json outlines are already y-DOWN. They are authored in
//   the 1000-unit em box with y growing downward (measured over the shipped
//   resource: 86..935, most control points 100..800), while misans-glyphs.json
//   outlines are y-UP and are therefore
//   drawn through scale(size / 1000, -size / 1000) with a translate that adds
//   the baseline offset size * 1.044 (Glyphs.cpp:536-537,558-559).
//   Lettering is drawn with BOTH scale factors positive, with no y flip and NO
//   baseline offset: art() has no "y + size * 1.044" term at all, because y is
//   the TOP of the artwork box itself and not a baseline. Adding
//   [kBaselineFactor] or negating the y scale here would push every boot mark
//   out of the frame, which is the single easiest way to break this port.
//
// Numeric fidelity rules: "advance * size + tracking" is never reassociated
// into "advance * size * count + tracking * count". The running sum keeps the
// C++ operation order and [tracking] is subtracted once, after the loop.
//
// Fill rule: outlines arrive from parseSvgPath() with PathFillType.nonZero
// (Qt::WindingFill, Glyphs.cpp:172,437), so overlapping lettering strokes never
// punch holes into each other.

import 'dart:ui' as ui;

import 'glyph_font.dart';

/// Width of one boot lettering run, in logical pixels.
///
/// Mirrors Glyphs::artWidth (Glyphs.cpp:403-412):
///
/// ```cpp
/// double Glyphs::artWidth(QString key, double size, double tracking, int count) {
///     double result = 0;
///     const auto letters = lettering.value(key);
///     const auto visible = letters.mid(0, count < 0 ? letters.size() : count);
///     for (auto g : visible) {
///         result += g.advance * size + tracking;
///     }
///     return visible.isEmpty() ? 0 : result - tracking;
/// }
/// ```
///
/// [count] < 0 means the whole run; `count == 0`, an unknown [key] and a key
/// with no letters all answer 0. The single subtraction after the loop is what
/// keeps the last letter at "advance * size" only, so a run of n letters spans
/// n advances plus exactly n-1 trackings.
double artWidth(
  GlyphFontSet fonts,
  String key,
  double size, {
  double tracking = 0,
  int count = -1,
}) {
  final letters = fonts.letteringFor(key)?.letters ?? const <LetteringGlyph>[];
  final visible = count < 0 ? letters : letters.take(count).toList();
  var result = 0.0;
  for (final letter in visible) {
    result += letter.advance * size + tracking;
  }
  return visible.isEmpty ? 0.0 : result - tracking;
}

/// Paints one boot lettering run with the top-left of its artwork box at
/// ([x], [y]).
///
/// Mirrors Glyphs::art (Glyphs.cpp:565-588):
///
/// ```cpp
/// for (auto g : lettering[key].mid(0, count < 0 ? lettering[key].size() : count)) {
///     c.save();
///     c.translate(x, y);
///     c.scale(size / 1000, size / 1000);
///     c.fillPath(g.path, c.brush());
///     c.restore();
///     x += g.advance * size + tracking;
/// }
/// ```
///
/// [y] is the top of the artwork box, NOT a baseline: there is no
/// `size * 1.044` offset and the y scale stays positive (see the file header).
/// The pen advance is applied in device-independent units and is never scaled,
/// because each letter is drawn under its own save/restore pair.
///
/// One [ui.Paint] is created outside the loop and reused for every letter, the
/// same way Qt reuses the painter's current brush. Flutter's [ui.Paint]
/// defaults to antialiasing on, matching the antialiased HUD painter Qt uses
/// for these commands.
void paintArt(
  ui.Canvas canvas,
  GlyphFontSet fonts,
  String key,
  double x,
  double y,
  double size, {
  int count = -1,
  double tracking = 0,
  required ui.Color color,
}) {
  final letters = fonts.letteringFor(key)?.letters ?? const <LetteringGlyph>[];
  final visible = count < 0 ? letters : letters.take(count).toList();
  if (visible.isEmpty) {
    return;
  }
  final paint = ui.Paint()..color = color;
  var penX = x;
  for (final letter in visible) {
    canvas.save();
    canvas.translate(penX, y);
    canvas.scale(size / kGlyphUnits, size / kGlyphUnits);
    canvas.drawPath(letter.path, paint);
    canvas.restore();
    penX += letter.advance * size + tracking;
  }
}
