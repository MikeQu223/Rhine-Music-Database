// Faithful Dart port of Glyphs::needsLayout (Qt/src/Glyphs.cpp:108-139).
//
// Atom A4 of . This file answers exactly one question and nothing else:
// "does this string have to leave the per-character outline path and be shaped
// by a real text engine?" It does not shape, measure, wrap, or draw; A1
// (glyph_font.dart) owns the outlines, A2 (glyph_run.dart) owns placement and
// advances, A3 (text_fitter.dart) owns fitting. Keeping the predicate alone
// here makes it testable without any font resource on disk.
//
// Qt is the only authority. The original predicate is:
//
//   for (char32_t point : text.toUcs4()) {
//       const auto category  = QChar::category(point);
//       const auto direction = QChar::direction(point);
//       const auto script    = QChar::script(point);
//       const bool combining = category == QChar::Mark_NonSpacing ||
//                              category == QChar::Mark_SpacingCombining ||
//                              category == QChar::Mark_Enclosing;
//       const bool hangulJamo = script == QChar::Script_Hangul &&
//                               (point < 0xac00 || point > 0xd7a3);
//       const bool contextual = script != QChar::Script_Common && ... ;
//       if (point > 0xffff || combining || hangulJamo || contextual ||
//           point == 0x200d || direction == QChar::DirR ||
//           direction == QChar::DirAL ||
//           (!font.supportsCharacter(point) && !symbols.supportsCharacter(point))) {
//           required = true;
//           break;
//       }
//   }
//                                                          (Glyphs.cpp:117-134)
//
// Every term is preserved in the same order, so a reviewer can diff the two
// side by side. Qt short-circuits on the first hit and so does this port.
//
// Why Unicode data is injected instead of imported
// The Dart SDK exposes no direct general-category, script, or bidi-class call
// for a code point. String.runes gives scalar values, String.codeUnits gives
// UTF-16 units, package:characters gives grapheme clusters. RegExp does
// support Unicode property escapes in unicode mode -- the SDK documents
// RegExp(r'^\p{L}$', unicode: true) (dart-sdk/lib/core/regexp.dart:393-396) --
// and ECMAScript property escapes cover General_Category and Script. The SDK
// shows only a General_Category example, but the dart:core contract is
// explicit: RegExp has "the same syntax and semantics as JavaScript regular
// expressions" (regexp.dart:17-20) and implements the ECMAScript RegExp
// specification (:91-92), which includes the Script= property. No in-tree
// pattern used it before this fix, and this phase forbids executing tests, so
// that support is contract-backed rather than demonstrated here; the
// resource-only path in glyph_run.dart uses \p{M} for Qt's combining
// categories and \p{Script=...} for the script whitelist, and the resource
// table for term (7) coverage. Property escapes do not cover Bidi_Class,
// and each test compiles a pattern and scans the subject, so RegExp cannot
// answer QChar::direction at all. Rather than pay per-code-point regexp cost and
// still miss one of the three queries, the table is a port:
// [UnicodeClassifier]. The resource-only path in glyph_run.dart uses RegExp
// directly for the combining and script checks, but this predicate cannot:
// its term (6) needs Bidi_Class, which no property escape exposes, so a
// caller with no table must not call this predicate at all.
//
// The classifier is REQUIRED and must carry real data. This file refuses to
// answer against [UnicodeClassifier.none]: [requiresFallback] throws a
// StateError for a port whose [UnicodeClassifier.hasScriptData] is false.
// The reason is that terms (2) combining marks, (3) Hangul jamo,
// (4) non-whitelisted scripts and (6) RTL would all stay silent, so a
// combining mark, a Hebrew or an Arabic string would be reported as plain text
// and painted as raw code points exactly where Qt runs QTextLayout. "No
// fallback" from a port that cannot tell is a wrong answer, not a conservative
// one, so an unusable port is a build/wiring error instead of a silent default.
// A caller that has no table yet must not call this predicate; the
// resource-only path in glyph_run.dart fails fast on the structural and
// Unicode-property cases it can decide and documents the rest.
//
// What [GlyphFontSet.hasOutline] really means (term 7)
// Qt asks the mapped QRawFont (QRawFont::supportsCharacter), i.e. the actual
// cmap of RhineMiSans-<weight>.otf. The Dart port asks the resource table of
// the same weight in misans-glyphs.json. Those are not the same set, and the
// difference is large:
//
//   RhineMiSans-regular.otf cmap ................. 29415 code points
//     (20976 CJK URO, 6582 CJK Ext-A, 202 CJK Ext-B+, 183 kana, 180 Latin
//      Extended, 136 Cyrillic, 112 box drawing, 100 ASCII, 100 fullwidth,
//      80 Greek, 54 General Punctuation, ...)
//   misans-glyphs.json, per weight ................ 1007 code points
//     (a strict subset of the cmap above, with 0 resource entries missing from
//      the OTF, as measured offline by A1/; this phase forbids running
//      anything, so that measurement is not reproducible here)
//   NotoSansSymbols2-Regular.ttf cmap ............ 2955 code points
//     (813 emoji-range, 145 dingbats, 121 misc symbols, 96 geometric shapes,
//      102 Latin Extended, 98 ASCII, ...)
//
// The measurable consequence: for the ~28400 code points that the OTF covers
// but the resource table does not, term (7) in this port reports true while
// Qt reports false, because the Dart fast path can only draw outlines that
// exist in the resource. That is a deliberate superset -- those characters get
// shaped instead of silently disappearing -- and it is invisible only when
// the JSON carries the whole cmap. A1/ decide whether the resource is
// regenerated to full coverage; until then this predicate is the conservative
// answer, never the permissive one.
//
// Script_Unknown is contextual, literally like Qt
// Qt applies term (4) to QChar::Script_Unknown too, because Script_Unknown is
// outside the whitelist of {Common, Inherited, Latin, Han, Hiragana, Katakana,
// Hangul}. Private-use, noncharacter and unassigned code points therefore count
// as "contextual" in Qt, and this port keeps that literal reading:
// kScriptUnknown is contextual unconditionally.
//
// An earlier draft softened this for a data-free port through
// [UnicodeClassifier.hasScriptData], which made "no table" indistinguishable
// from "table says Unknown" and silently suppressed terms (2), (3), (4) and
// (6). That reading is gone: a port without data is rejected up front, so the
// flag now only tells the guard that this port really answers all three
// queries. There is no mode in which a missing table is treated as plain text.

import 'glyph_font.dart';

/// Unicode general category: everything the predicate does not care about.
///
/// Mirrors QChar::Other_* (QChar::Other_Control ... QChar::Other_NotAssigned).
const int kCategoryOther = 0;

/// Mirrors QChar::Mark_NonSpacing (Mn).
const int kCategoryNonSpacingMark = 1;

/// Mirrors QChar::Mark_SpacingCombining (Mc).
const int kCategorySpacingCombiningMark = 2;

/// Mirrors QChar::Mark_Enclosing (Me).
const int kCategoryEnclosingMark = 3;

// PRIVATE CONTRACT: the kScript* numbers below are 's own compact enum.
// They are NOT QChar::Script values (Qt numbers Unknown 0, Inherited 1,
// Common 2 and then the remaining scripts in its own order). A classifier must
// translate a real Unicode script into these numbers; handing QChar::Script
// values straight in would land every non-whitelist script in the default arm
// of _isContextualScript, which reports contextual -- i.e. it would silently
// shape every string instead of raising an error. The whitelist is what the
// predicate needs, not the identity of the script, so a compact enum is
// enough as long as the translation is explicit.

/// Script slot for unassigned, private-use and noncharacter code points, and
/// also what a port without table data reports.
const int kScriptUnknown = 0;

/// Script slot for Common.
const int kScriptCommon = 1;

/// Script slot for Inherited.
const int kScriptInherited = 2;

/// Script slot for Latin.
const int kScriptLatin = 3;

/// Script slot for Han.
const int kScriptHan = 4;

/// Script slot for Hiragana.
const int kScriptHiragana = 5;

/// Script slot for Katakana.
const int kScriptKatakana = 6;

/// Script slot for Hangul.
const int kScriptHangul = 7;

/// Mirrors QChar::DirL.
const int kDirectionLeftToRight = 0;

/// Mirrors QChar::DirR (Hebrew and other strong right-to-left scripts).
const int kDirectionRightToLeft = 1;

/// Mirrors QChar::DirAL (Arabic, Syriac, Thaana, N'Ko, ...).
const int kDirectionArabicLetter = 2;

/// Port for the three Unicode queries Qt gets from QChar.
///
/// Implement this with a real table (a generated code-point range table over
/// UnicodeData.txt / Scripts.txt / DerivedBidiClass.txt, or a whole-Unicode
/// binary resource) and inject it into [requiresFallback]. The Dart SDK cannot
/// answer QChar::direction itself; for category and script a caller may build
/// a stopgap on RegExp Unicode property escapes instead (see the file header).
abstract class UnicodeClassifier {
  const UnicodeClassifier();

  /// Unicode general category of [codePoint], as one of the kCategory*
  /// constants. Qt: QChar::category (Glyphs.cpp:118).
  int category(int codePoint);

  /// Unicode script of [codePoint], translated into one of the kScript*
  /// slots ('s private numbering, not QChar::Script; see the note above
  /// kScriptUnknown). Qt: QChar::script (Glyphs.cpp:120).
  int script(int codePoint);

  /// Unicode bidirectional class of [codePoint], narrowed to the three values
  /// the predicate distinguishes, as one of the kDirection* constants.
  /// Qt: QChar::direction (Glyphs.cpp:119).
  int direction(int codePoint);

  /// Capability flag: this port answers [category], [script] and [direction]
  /// from real Unicode tables, so kScriptUnknown really means Script_Unknown
  /// (which Glyphs.cpp:124-127 counts as contextual).
  ///
  /// Defaults to true because a table-backed classifier is the only usable
  /// implementation. [UnicodeClassifier.none] reports false, and
  /// [requiresFallback] / [requiresFallbackGate] reject any port that reports
  /// false instead of answering with four of the seven terms suppressed.
  bool get hasScriptData => true;

  /// The no-data port, present only so the rejection is diagnosable.
  ///
  /// Reports kCategoryOther / kScriptUnknown / kDirectionLeftToRight for every
  /// code point, which means "unknown", never "known to be simple", and
  /// reports [hasScriptData] false. [requiresFallback] throws a StateError for
  /// it, so it can never turn a string Qt would shape into a plain-text answer.
  static const UnicodeClassifier none = _UnknownUnicodeClassifier();
}

/// The null port behind [UnicodeClassifier.none]; see its documentation.
class _UnknownUnicodeClassifier extends UnicodeClassifier {
  const _UnknownUnicodeClassifier();

  @override
  int category(int codePoint) => kCategoryOther;

  @override
  int script(int codePoint) => kScriptUnknown;

  @override
  int direction(int codePoint) => kDirectionLeftToRight;

  @override
  bool get hasScriptData => false;
}

/// True when [text] must be shaped by a real text engine instead of the
/// per-character outline path (Glyphs.cpp:109 needsLayout).
///
/// Returns true on the first code point that satisfies any of the seven terms
/// below; false when every code point is plain. Empty text never needs layout
/// (Qt's loop body never runs, Glyphs.cpp:117), so it is answered before the
/// port is validated: with no code point there is no term for a data-less port
/// to suppress, and refusing the empty string would reject a correct answer.
///
/// Terms, in Qt order (Glyphs.cpp:128-130):
///   1. codePoint > 0xFFFF -- anything outside the BMP, i.e. surrogate pairs.
///   2. the general category is a combining mark (Mn, Mc, Me).
///   3. Hangul script outside the precomposed syllable block (U+AC00..U+D7A3),
///      i.e. conjoining jamo that need composition.
///   4. the script is outside {Common, Inherited, Latin, Han, Hiragana,
///      Katakana, Hangul} -- every "complex" or otherwise unlisted script,
///      which is what lets Qt delegate Arabic, Hebrew, Indic, Thai, emoji
///      presentation and friends to the system shaper.
///   5. codePoint == U+200D (ZERO WIDTH JOINER), the emoji/Indic join control.
///   6. the bidi class is DirR or DirAL (a per-code-point check; DirAN inside
///      Arabic text does not fire, exactly as in Qt).
///   7. the resource table of [weight] has no outline for the character AND
///      the symbol face does not cover its code point.
///
/// [weight] follows the Qt default ("regular", Glyphs.h:25) through
/// [kDefaultGlyphWeight]; [fonts] is the same resource set A1 loads.
///
/// [classifier] is required and must carry real data:
/// [UnicodeClassifier.hasScriptData] false throws a StateError, because terms
/// (2), (3), (4) and (6) would otherwise report "plain" for text Qt shapes.
///
/// The predicate takes no paragraph-level direction argument, because Qt's
/// needsLayout has none either (Glyphs.cpp:108-139): direction is consulted
/// per code point only, through term (6). A caller that has resolved a
/// paragraph direction and needs the whole string shaped must route it to the
/// ComplexTextPort itself instead of widening this predicate.
bool requiresFallback(
  String text, {
  String weight = kDefaultGlyphWeight,
  required GlyphFontSet fonts,
  required UnicodeClassifier classifier,
}) {
  if (text.isEmpty) {
    return false;
  }
  _requireUnicodeData(classifier, 'requiresFallback');
  for (final int codePoint in text.runes) {
    // (1) Outside the BMP. Qt: point > 0xffff (Glyphs.cpp:128).
    if (codePoint > 0xffff) {
      return true;
    }
    // (2) Combining mark: Mn / Mc / Me. Qt: combining (Glyphs.cpp:121-122).
    final int category = classifier.category(codePoint);
    if (category == kCategoryNonSpacingMark ||
        category == kCategorySpacingCombiningMark ||
        category == kCategoryEnclosingMark) {
      return true;
    }
    final int script = classifier.script(codePoint);
    // (3) Conjoining Hangul jamo, or compatibility jamo: Hangul script outside
    // U+AC00..U+D7A3. Qt: hangulJamo (Glyphs.cpp:123).
    if (script == kScriptHangul &&
        (codePoint < 0xac00 || codePoint > 0xd7a3)) {
      return true;
    }
    // (4) Script outside the plain-text whitelist. Qt: contextual
    // (Glyphs.cpp:124-127). kScriptUnknown counts as contextual, literally like
    // Qt; see the note in the file header.
    if (_isContextualScript(script)) {
      return true;
    }
    // (5) ZERO WIDTH JOINER. Qt: point == 0x200d (Glyphs.cpp:128).
    if (codePoint == 0x200d) {
      return true;
    }
    // (6) Strong right-to-left / Arabic letter bidi class. Qt:
    // direction == DirR || direction == DirAL (Glyphs.cpp:129).
    final int direction = classifier.direction(codePoint);
    if (direction == kDirectionRightToLeft ||
        direction == kDirectionArabicLetter) {
      return true;
    }
    // (7) Neither the resource table of this weight nor the symbol face can
    // draw it. Qt: !font.supportsCharacter(point) &&
    // !symbols.supportsCharacter(point) (Glyphs.cpp:130).
    if (!fonts.hasOutline(String.fromCharCode(codePoint), weight) &&
        !fonts.symbolSupports(codePoint)) {
      return true;
    }
  }
  return false;
}

/// Builds the per-string decision for a GlyphText full configuration.
///
/// The returned function is structurally glyph_run.dart's ComplexTextGate
/// ("bool Function(String text, String weight)"), so it can be passed to the
/// GlyphText constructor without this file importing the measurement layer
/// (which would make the two files cyclically dependent). [fonts] is captured
/// here on purpose: term (7) must ask the SAME resource table the painter
/// draws from, otherwise the gate can decide "resource path" for a string
/// whose outlines only exist in another set.
///
/// Throws at wiring time when [classifier] carries no data, so a misconfigured
/// app fails while constructing its text stack instead of on the first Arabic
/// or combining string.
bool Function(String text, String weight) requiresFallbackGate({
  required GlyphFontSet fonts,
  required UnicodeClassifier classifier,
}) {
  _requireUnicodeData(classifier, 'requiresFallbackGate');
  return (String text, String weight) => requiresFallback(
        text,
        weight: weight,
        fonts: fonts,
        classifier: classifier,
      );
}

/// Rejects a classifier that cannot answer all three Unicode queries.
///
/// See [UnicodeClassifier.hasScriptData]; the message names the affected terms
/// so a wiring failure explains itself.
void _requireUnicodeData(UnicodeClassifier classifier, String api) {
  if (classifier.hasScriptData) {
    return;
  }
  throw StateError(
    '$api needs a UnicodeClassifier with real category, script and bidi '
    'data: with UnicodeClassifier.none terms (2) combining marks, (3) Hangul '
    'jamo, (4) non-whitelisted scripts and (6) RTL never fire, so text that Qt '
    'shapes (Glyphs.cpp:121-129) is reported as plain and painted as raw code '
    'points. Inject a table-backed classifier.',
  );
}

/// True when [script] is outside {Common, Inherited, Latin, Han, Hiragana,
/// Katakana, Hangul}, exactly like Qt's contextual term (Glyphs.cpp:124-127).
///
/// kScriptUnknown IS contextual: Qt treats Script_Unknown as outside the
/// whitelist (Glyphs.cpp:124-127), and private-use, noncharacter or unassigned
/// code points really are outside it. A port without data is rejected before
/// this function runs, so "Unknown" here always means the real Unicode value.
bool _isContextualScript(int script) {
  switch (script) {
    case kScriptCommon:
    case kScriptInherited:
    case kScriptLatin:
    case kScriptHan:
    case kScriptHiragana:
    case kScriptKatakana:
    case kScriptHangul:
      return false;
    default:
      // Every other script is contextual, kScriptUnknown included: Qt's
      // whitelist check (Glyphs.cpp:124-127) makes no exception for it.
      return true;
  }
}
