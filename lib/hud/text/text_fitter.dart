// Faithful Dart port of the label fitting rule in Qt/src/Glyphs.cpp:868-882.
//
// The Qt sources are the only authority for this module. The original is the
// `fit` lambda inside Glyphs::label():
//
//     auto fit = [&](QString s, double y, double maximum, QString weight) {
//         double size = maximum;
//         while (width(s, size, weight) > 954 && size > 34) {
//             size -= 2;
//         }
//         QString shown = s;
//         while (width(shown, size, weight) > 954 && shown.size() > 1) {
//             shown.chop(1);
//         }
//         if (shown != s) {
//             shown.chop(1);
//             shown += "…";
//         }
//         text(c, shown, 30, y, size, weight, 0, ink);
//     };
//
// Two facts drive the whole contract and must not be "improved" here:
//
//  * the size search measures the ORIGINAL, untruncated string, and only then
//    is the string truncated at that fixed size. Doing it the other way round
//    picks a larger size than Qt would. (Glyphs.cpp:870-874)
//  * truncation happens at one extra character past the last one that fits,
//    because the ellipsis itself must fit inside the same 954 limit. That is
//    why the loop stops on the first fitting prefix and then chops once more.
//                                                              (Glyphs.cpp:877-880)
//
// Both loops are pure text/measure loops: no IO, no fonts, no globals. The
// width measurement is injected so this file stays dependency free and can be
// driven by the glyph layer (lib/hud/text/glyph_font.dart) or by a fixture.

/// Widest advance, in em-box pixels, a fitted label may occupy
/// (Glyphs.cpp:870, Glyphs.cpp:874).
const double kLabelFitLimit = 954;

/// Smallest size the size loop steps down to (Glyphs.cpp:870).
const double kLabelMinSize = 34;

/// Decrement applied per size-loop iteration (Glyphs.cpp:871).
const double kLabelSizeStep = 2;

/// Single-character ellipsis appended after the final chop (Glyphs.cpp:879).
const String kEllipsis = '\u2026';

/// First candidate of the series [maximum], [maximum] - [step], ... whose
/// [width] is at most [limit] (Glyphs.cpp:870-872).
///
/// Mirrors `while (width(s, size) > 954 && size > 34) size -= 2;` exactly, so
/// three properties of the Qt loop survive and none of them may be "fixed":
///
///  * the loop tests [minimum] BEFORE it steps, so a [maximum] that falls in
///    (minimum, minimum + step) overshoots downwards: maximum 35 answers 33,
///    not 34 and not 35.
///  * the answer is the first member of the series that fits, not the largest
///    feasible size in a continuous range.
///  * when even [minimum] is wider than [limit] the loop still stops there, so
///    the returned size may overflow [limit].
///
/// [step] must be positive; Qt hardcodes 2.
double fitSize({
  required double maximum,
  required double Function(double size) width,
  double limit = kLabelFitLimit,
  double minimum = kLabelMinSize,
  double step = kLabelSizeStep,
}) {
  var size = maximum;
  while (width(size) > limit && size > minimum) {
    size -= step;
  }
  return size;
}

/// [text] shortened so that it fits [limit] at [size], with an ellipsis.
///
/// Mirrors Glyphs.cpp:873-880 exactly:
///
///     QString shown = s;
///     while (width(shown, size) > 954 && shown.size() > 1) shown.chop(1);
///     if (shown != s) { shown.chop(1); shown += "…"; }
///
/// The first loop leaves the longest prefix that fits (or a single character),
/// and the trailing chop of the second branch reserves room for the ellipsis.
/// A string that already fits is returned unchanged, and an empty string stays
/// empty.
///
/// Length is counted in UTF-16 code units, like `QString::size()` and
/// `chop(1)`; a surrogate pair is therefore treated as two removable units,
/// matching Qt byte for byte rather than grapheme clusters.
String truncateToWidth(
  String text, {
  required double size,
  required double Function(String text, double size) width,
  double limit = kLabelFitLimit,
  String ellipsis = kEllipsis,
}) {
  var shown = text;
  while (width(shown, size) > limit && shown.length > 1) {
    shown = shown.substring(0, shown.length - 1);
  }
  if (shown != text) {
    shown = shown.substring(0, shown.length - 1);
    shown = shown + ellipsis;
  }
  return shown;
}

/// A label resolved to its final [size] and final [text] (Glyphs.cpp:868-882).
class FittedLabel {
  const FittedLabel(this.size, this.text);

  /// Size handed to `Glyphs::text` (Glyphs.cpp:881).
  final double size;

  /// String handed to `Glyphs::text` (Glyphs.cpp:881).
  final String text;
}

/// Resolves a label the way Glyphs::label() does: pick the size first, then
/// truncate at that size (Glyphs.cpp:868-882).
///
/// The order is the contract. Fitting the size against the already-truncated
/// string would be a different algorithm and a different picture.
FittedLabel fitLabel(
  String text, {
  required double maximum,
  required double Function(String text, double size) width,
  double limit = kLabelFitLimit,
  double minimum = kLabelMinSize,
  double step = kLabelSizeStep,
  String ellipsis = kEllipsis,
}) {
  final double size = fitSize(
    maximum: maximum,
    width: (double candidate) => width(text, candidate),
    limit: limit,
    minimum: minimum,
    step: step,
  );
  final String shown = truncateToWidth(
    text,
    size: size,
    width: width,
    limit: limit,
    ellipsis: ellipsis,
  );
  return FittedLabel(size, shown);
}
