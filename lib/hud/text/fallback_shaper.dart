// Faithful Dart port of Glyphs::needsLayout (Qt/src/Glyphs.cpp:108-139).
//
// Atom A4 of T31. This file answers exactly one question and nothing else:
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
// ---------------------------------------------------------------------------
// Why Unicode data is injected instead of imported
// ---------------------------------------------------------------------------
// The Dart SDK exposes no direct general-category, script, or bidi-class call
// for a code point. String.runes gives scalar values, String.codeUnits gives
// UTF-16 units, package:characters gives grapheme clusters. RegExp does
// support Unicode property escapes in unicode mode -- the SDK documents
// RegExp(r'^\p{L}$', unicode: true) (dart-sdk/lib/core/regexp.dart:393-396) --
// and ECMAScript property escapes cover General_Category and Script. They do
// not cover Bidi_Class, and each test compiles a pattern and scans the
// subject, so RegExp cannot answer QChar::direction at all. Rather than pay
// per-code-point regexp cost and still miss one of the three queries, the
// table is a port: [UnicodeClassifier]. RegExp stays a legitimate stopgap for
// a caller that cannot ship a table: \p{Mn}, \p{Mc}, \p{Me} answer Qt's
// combining categories and \p{Script=...} answers the whitelist check; bidi
// still needs table data because no escape exposes Bidi_Class.
//
// The default port reports kCategoryOther / kScriptUnknown /
// kDirectionLeftToRight for every code point, and this file is written so
// that a missing table never fabricates a positive answer.
//
// Consequence of the default port, stated explicitly so callers cannot be
// surprised: with UnicodeClassifier.none only these terms can fire --
//   (1) codePoint > 0xFFFF,
//   (5) codePoint == 0x200D,
//   (7) no outline in the resource table and no symbol coverage.
// Terms (2), (3) and (4) need real data and stay silent until a real port is
// injected. A shipping caller must inject a table; the default port is for
// "no data available, be conservative about what we cannot see" only.
//
// ---------------------------------------------------------------------------
// What [GlyphFontSet.hasOutline] really means (term 7)
// ---------------------------------------------------------------------------
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
//     (a strict subset of the cmap above; verified: 0 resource entries are
//      missing from the OTF)
//   NotoSansSymbols2-Regular.ttf cmap ............ 2955 code points
//     (813 emoji-range, 145 dingbats, 121 misc symbols, 96 geometric shapes,
//      102 Latin Extended, 98 ASCII, ...)
//
// The measurable consequence: for the ~28400 code points that the OTF covers
// but the resource table does not, term (7) in this port reports true while
// Qt reports false, because the Dart fast path can only draw outlines that
// exist in the resource. That is a deliberate superset -- those characters get
// shaped instead of silently disappearing -- and it is invisible only when
// the JSON carries the whole cmap. A1/T31-V4 decide whether the resource is
// regenerated to full coverage; until then this predicate is the conservative
// answer, never the permissive one.
//
// ---------------------------------------------------------------------------
// Script_Unknown: the one place where "no data" and "Unknown" must differ
// ---------------------------------------------------------------------------
// Qt applies term (4) to QChar::Script_Unknown too, because Script_Unknown is
// outside the whitelist of {Common, Inherited, Latin, Han, Hiragana, Katakana,
// Hangul}. Private-use and unassigned code points therefore count as
// "contextual" in Qt. The port must keep that literal reading for a real
// table, yet must never let the no-data port report true for every string, so
// [UnicodeClassifier] separates the two readings: [UnicodeClassifier.hasScriptData]
// is true by default (a real classifier means "Unknown really is Unknown") and
// false for [UnicodeClassifier.none] ("this port has no data").
// _isContextualScript treats kScriptUnknown as contextual only when the
// classifier reports script data.

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

// ---------------------------------------------------------------------------
// PRIVATE CONTRACT: the kScript* numbers below are T31's own compact enum.
// They are NOT QChar::Script values (Qt numbers Unknown 0, Inherited 1,
// Common 2 and then the remaining scripts in its own order). A classifier must
// translate a real Unicode script into these numbers; handing QChar::Script
// values straight in would land every non-whitelist script in the default arm
// of _isContextualScript, which reports contextual -- i.e. it would silently
// shape every string instead of raising an error. The whitelist is what the
// predicate needs, not the identity of the script, so a compact enum is
// enough as long as the translation is explicit.
// ---------------------------------------------------------------------------

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
  /// slots (T31's private numbering, not QChar::Script; see the note above
  /// kScriptUnknown). Qt: QChar::script (Glyphs.cpp:120).
  int script(int codePoint);

  /// Unicode bidirectional class of [codePoint], narrowed to the three values
  /// the predicate distinguishes, as one of the kDirection* constants.
  /// Qt: QChar::direction (Glyphs.cpp:119).
  int direction(int codePoint);

  /// Whether [script] carries real Unicode data, i.e. kScriptUnknown really
  /// means Script_Unknown (Glyphs.cpp:124-127 counts it as contextual).
  ///
  /// Defaults to true because a real table is the expected implementation.
  /// [UnicodeClassifier.none] reports false so that "no data" does not turn
  /// every string into a fallback; see _isContextualScript.
  bool get hasScriptData => true;

  /// Default port: no Unicode data at all.
  ///
  /// Reports kCategoryOther / kScriptUnknown / kDirectionLeftToRight for every
  /// code point, which means "unknown", never "known to be simple", and
  /// reports [hasScriptData] false. Terms (2), (3) and (4) of
  /// [requiresFallback] cannot fire under this port.
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
/// (Qt's loop body never runs, Glyphs.cpp:117).
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
/// The predicate takes no paragraph-level direction argument, because Qt's
/// needsLayout has none either (Glyphs.cpp:108-139): direction is consulted
/// per code point only, through term (6). A caller that has resolved a
/// paragraph direction and needs the whole string shaped must route it to the
/// ComplexTextPort itself instead of widening this predicate.
bool requiresFallback(
  String text, {
  String weight = kDefaultGlyphWeight,
  required GlyphFontSet fonts,
  UnicodeClassifier classifier = UnicodeClassifier.none,
}) {
  if (text.isEmpty) {
    return false;
  }
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
    // (Glyphs.cpp:124-127). kScriptUnknown is contextual for a real table and
    // silent for the no-data port; see the note in the file header.
    if (_isContextualScript(script, hasScriptData: classifier.hasScriptData)) {
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

/// True when [script] is outside {Common, Inherited, Latin, Han, Hiragana,
/// Katakana, Hangul}, exactly like Qt's contextual term (Glyphs.cpp:124-127).
///
/// kScriptUnknown has two readings and [hasScriptData] picks one: with real
/// data it is Qt's Script_Unknown, which Qt counts as contextual; without
/// data it only means "the port has no table", and treating it as contextual
/// would make [UnicodeClassifier.none] report true for every string.
bool _isContextualScript(int script, {required bool hasScriptData}) {
  switch (script) {
    case kScriptUnknown:
      return hasScriptData;
    case kScriptCommon:
    case kScriptInherited:
    case kScriptLatin:
    case kScriptHan:
    case kScriptHiragana:
    case kScriptKatakana:
    case kScriptHangul:
      return false;
    default:
      return true;
  }
}
