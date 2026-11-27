// Tests for the fallback predicate (lib/hud/text/fallback_shaper.dart).
//
// Qt 的 Glyphs::needsLayout 是唯一权威：缺字、组合标记、复杂脚本、RTL 等七项逐条钉住，
// 命中即 break。正例只让被测那一项成立，其余用 fixture 屏蔽。

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/hud/text/fallback_shaper.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';

// ---------------------------------------------------------------------------
// Resource fixtures
// ---------------------------------------------------------------------------

/// Lettering fixture: irrelevant here, but parseGlyphResources wants a valid
/// document of the shipped shape (same idea as glyph_run_test.dart).
const String _letteringJson = r'{"access":{"text":"AB","weight":"Normal",'
    r'"units":1000,"letters":['
    r'{"width":0.5,"path":"M100 100L900 100L900 800L100 800Z"}]}}';

/// Glyph fixture in font units (kGlyphUnits per em), y-up.
///
/// regular carries one character per whitelisted script, so the term (4)
/// negatives can answer false without term (7) firing:
///   A     Latin, 0.5 em advance
///   U+4E00 Han
///   U+3042 Hiragana
///   U+30A2 Katakana
///   U+AC00 Hangul syllable, U+D7A3 the other end of the block
/// light carries only 'B', so the same character 'A' can be switched between
/// "resource outline present" and "resource outline absent" by the weight
/// argument alone.
const String _glyphJson =
    r'{"regular":{"units":1000,"ascent":1044,"descent":-282,"glyphs":{'
    r'"A":{"advance":0.5,"path":"M0 0L1000 0L1000 700L0 700Z"},'
    r'"\u4e00":{"advance":1,"path":"M0 0L1000 0L1000 1000L0 1000Z"},'
    r'"\u3042":{"advance":1,"path":"M0 0L1000 0L1000 1000Z"},'
    r'"\u30a2":{"advance":1,"path":"M0 0L1000 0L1000 1000Z"},'
    r'"\uac00":{"advance":1,"path":"M0 0L1000 0L1000 1000Z"},'
    r'"\ud7a3":{"advance":1,"path":"M0 0L1000 0L1000 1000Z"}}},'
    r'"light":{"units":1000,"ascent":1044,"descent":-282,"glyphs":{'
    r'"B":{"advance":0.5,"path":"M0 0L1000 0L1000 700Z"}}}}';

/// Minimal table: only 'A' in regular, so 'Q' reaches term (7).
const String _sparseGlyphJson =
    r'{"regular":{"units":1000,"ascent":1044,"descent":-282,"glyphs":{'
    r'"A":{"advance":0.5,"path":"M0 0L1000 0L1000 700L0 700Z"}}}}';

/// Table that does NOT carry 'A': used to prove the gate captures its
/// GlyphFontSet instead of re-reading some global one.
const String _glyphJsonWithoutA =
    r'{"regular":{"units":1000,"ascent":1044,"descent":-282,"glyphs":{'
    r'"B":{"advance":0.5,"path":"M0 0L1000 0L1000 700Z"}}}}';

/// Symbol-face stand-in: answers exactly the injected set.
class _FakeSymbolCoverage extends SymbolCoverage {
  const _FakeSymbolCoverage(this.covered);

  final Set<int> covered;

  @override
  bool supportsCodePoint(int codePoint) => covered.contains(codePoint);
}

/// Code points that terms (1)..(6) use, declared covered by the symbol face.
///
/// This is a masking fixture: with these covered, term (7) can never be the
/// reason a test in groups A1-A6 passes, so each assertion pins the term it
/// names. Members are annotated with the term that needs them.
const Set<int> _symbolMask = <int>{
  0x0021, // '!' Common script, whitelisted (term 4 negative)
  0x0301, // combining acute accent, Mn (term 2)
  0x093F, // devanagari vowel sign i, Mc (term 2)
  0x20DD, // combining enclosing circle, Me (term 2)
  0x1100, // hangul choseong kieok, jamo below U+AC00 (term 3)
  0x3131, // hangul letter kieok, compatibility jamo (term 3)
  0x0416, // cyrillic zhe (term 4)
  0x0E01, // thai ko kai (term 4)
  0x03B1, // greek small alpha (term 4)
  0x0915, // devanagari ka (term 4)
  0xE000, // private use, Script_Unknown (term 4)
  0x0378, // unassigned code point, Script_Unknown (term 4 / G, no overlap)
  0x200C, // ZWNJ, must stay on the outline path (term 5 negative)
  0x200D, // ZWJ (term 5)
  0x200F, // right-to-left mark, DirR with Common script (term 6)
  0x05D0, // hebrew alef, DirR (term 6)
  0x0627, // arabic alef, DirAL (term 6)
  0x0660, // arabic-indic digit zero, DirAN (term 6 negative)
  0x1F600, // grinning face, outside the BMP (term 1)
};

/// Stand-in for a real script outside the seven whitelisted ones.
///
/// T31's compact enum only has slots for the whitelist plus Unknown/Common/
/// Inherited (fallback_shaper.dart:137-160), so a classifier that sees
/// Cyrillic, Greek, Thai or an Indic script has no slot to name it. 8 is the
/// first value outside the enum ON PURPOSE: the predicate's default arm answers
/// contextual for every number it does not list
/// (fallback_shaper.dart:374-388), and an out-of-enum value proves that arm
/// rather than merely kScriptUnknown.
const int _scriptOutsideWhitelist = 8;

/// Stand-in for a bidi class the predicate must ignore (DirAN in real data).
///
/// Qt compares equality against DirR and DirAL only (Glyphs.cpp:129), so any
/// other class has to fall through. The number is deliberately neither DirL nor
/// DirR nor DirAL, so a port that widened the test to "not DirL" fails.
const int _bidiArabicNumberStandIn = 3;

/// Table-driven, call-recording stand-in for the three Unicode queries Qt gets
/// from QChar (Glyphs.cpp:118-120).
///
/// Every query is answered from a map and falls back to a documented default,
/// and every call is logged with its code point, so a test can prove which code
/// points were examined and which were never reached. The maps are the injected
/// Unicode data; when a map pins a script to a value real Unicode would not
/// report, the test says so and explains why (isolation of the term).
final class _FakeClassifier extends UnicodeClassifier {
  _FakeClassifier({
    Map<int, int>? categories,
    Map<int, int>? scripts,
    Map<int, int>? directions,
    this.defaultScript = kScriptLatin,
  })  : _hasData = true, defaultCategory = kCategoryOther, defaultDirection = kDirectionLeftToRight, _categories = categories ?? <int, int>{},
        _scripts = scripts ?? <int, int>{},
        _directions = directions ?? <int, int>{};

  final Map<int, int> _categories;
  final Map<int, int> _scripts;
  final Map<int, int> _directions;

  /// Answer used for a code point the test did not pin; kCategoryOther and
  /// kDirectionLeftToRight are the "plain" answers, kScriptLatin makes the
  /// character whitelisted so term (4) stays quiet by default.
  final int defaultCategory;
  final int defaultScript;
  final int defaultDirection;

  final bool _hasData;

  /// Code points in call order, one log per query.
  final List<int> categoryCalls = <int>[];
  final List<int> scriptCalls = <int>[];
  final List<int> directionCalls = <int>[];

  @override
  int category(int codePoint) {
    categoryCalls.add(codePoint);
    return _categories[codePoint] ?? defaultCategory;
  }

  @override
  int script(int codePoint) {
    scriptCalls.add(codePoint);
    return _scripts[codePoint] ?? defaultScript;
  }

  @override
  int direction(int codePoint) {
    directionCalls.add(codePoint);
    return _directions[codePoint] ?? defaultDirection;
  }

  @override
  bool get hasScriptData => _hasData;
}

// ---------------------------------------------------------------------------
// Font sets
// ---------------------------------------------------------------------------

/// The mask applied: every code point used by terms (1)..(6) is "covered" by
/// the symbol face so term (7) cannot answer.
GlyphFontSet _maskedFonts() => parseGlyphResources(
      glyphJson: _glyphJson,
      letteringJson: _letteringJson,
      symbols: const _FakeSymbolCoverage(_symbolMask),
    );

/// Regular carries only 'A', no symbol coverage at all: 'Q' hits term (7).
GlyphFontSet _sparseFonts() => parseGlyphResources(
      glyphJson: _sparseGlyphJson,
      letteringJson: _letteringJson,
    );

/// Regular does NOT carry 'A': used by the gate-capture test.
GlyphFontSet _fontsWithoutA() => parseGlyphResources(
      glyphJson: _glyphJsonWithoutA,
      letteringJson: _letteringJson,
    );

/// Sparse table plus symbol coverage of 'Q' alone.
GlyphFontSet _coveredFonts() => parseGlyphResources(
      glyphJson: _sparseGlyphJson,
      letteringJson: _letteringJson,
      symbols: const _FakeSymbolCoverage(<int>{0x0051}),
    );

/// Matcher for the StateError the port raises for a data-less classifier.
Matcher _throwsStateErrorContaining(String needle) => throwsA(
      isA<StateError>().having(
        (StateError error) => error.message,
        'message',
        contains(needle),
      ),
    );

void main() {
  // =========================================================================
  // A. the seven terms
  // =========================================================================

  group('term (1): code point outside the BMP', () {
    test('U+1F600 needs layout because it is outside the BMP', () {
      // Qt: "point > 0xffff" is the first arm of the if (Glyphs.cpp:128).
      // Isolation: the fake classifier answers Other/Latin/DirL for every code
      // point and the fixture declares the symbol face as covering U+1F600, so
      // terms (2)..(7) cannot fire and only the BMP test can answer true.
      final fonts = _maskedFonts();
      expect(fonts.symbolSupports(0x1F600), isTrue);
      expect(
        requiresFallback('\u{1F600}', fonts: fonts, classifier: _FakeClassifier()),
        isTrue,
      );
    });

    test('the same character is one rune but two UTF-16 units', () {
      // Qt iterates text.toUcs4(), which is code points (Glyphs.cpp:117), and
      // Dart's String.runes is the same unit. The port therefore must not see
      // two lone surrogates here; it sees one code point above 0xffff.
      expect('\u{1F600}'.length, 2);
      expect('\u{1F600}'.runes.length, 1);
      expect('\u{1F600}'.runes.single, 0x1F600);
    });
  });

  group('term (2): combining marks (Mn / Mc / Me)', () {
    test('Mn U+0301 fires through the combining arm alone', () {
      // Qt: category == QChar::Mark_NonSpacing (Glyphs.cpp:121).
      // U+0301 COMBINING ACUTE ACCENT is Mn; its real script is Inherited,
      // which is whitelisted (:124-127), and the fake classifier answers the
      // default Latin, also whitelisted, so term (4) stays quiet either way.
      // Its bidi class is NSM (not DirR/DirAL) and the fixture covers it with
      // the symbol face, so terms (3)..(7) are all quiet.
      final fonts = _maskedFonts();
      // The port asks the classifier for the category instead of reading a
      // Unicode table (fallback_shaper.dart:283-288), so the Mn answer has to
      // be injected: with the default Mark_Other this arm cannot fire at all.
      final classifier = _FakeClassifier(
        categories: <int, int>{0x0301: kCategoryNonSpacingMark},
      );
      expect(fonts.symbolSupports(0x0301), isTrue);
      expect(
        requiresFallback('\u0301', fonts: fonts, classifier: classifier),
        isTrue,
      );
    });

    test('a decomposed A + acute needs layout while plain A does not', () {
      // Same two code points Qt sees: 'A' is Other/Latin/DirL and the fixture
      // regular table really carries its outline, U+0301 is Mn. Qt answers true
      // at the second code point.
      //
      // The base must be a character the resource table carries. With 'e' the
      // table would miss it and term (7) would answer true for the wrong
      // reason; pinning plain 'A' to false is what proves the true answer comes
      // from the combining arm rather than from a missing outline.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        categories: <int, int>{0x0301: kCategoryNonSpacingMark},
      );
      expect(fonts.hasOutline('A'), isTrue);
      expect(
        requiresFallback('A\u0301', fonts: fonts, classifier: classifier),
        isTrue,
      );
      expect(
        requiresFallback('A', fonts: fonts, classifier: classifier),
        isFalse,
      );
    });

    test('Mc U+093F fires through the combining arm (script pinned)', () {
      // Qt: category == QChar::Mark_SpacingCombining (Glyphs.cpp:122).
      // Real data: U+093F DEVANAGARI VOWEL SIGN I is Mc AND script Devanagari,
      // which is outside the whitelist, so Qt's term (4) would report true as
      // well -- and term (2) is evaluated first (:121 before :124), so a true
      // answer could not tell the two arms apart. This case therefore pins the
      // injected script to Common (the fake stands in for QChar::script,
      // Glyphs.cpp:120) so term (4) cannot fire; a port that dropped the Mc arm
      // answers false here, because every other term is plain. The Mc category
      // is injected for the same reason: the port reads it from the classifier
      // (fallback_shaper.dart:283-288), so the default Mark_Other would silence
      // this arm.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        categories: <int, int>{0x093F: kCategorySpacingCombiningMark},
        scripts: <int, int>{0x093F: kScriptCommon},
      );
      expect(fonts.symbolSupports(0x093F), isTrue);
      expect(
        requiresFallback('\u093F', fonts: fonts, classifier: classifier),
        isTrue,
      );
    });

    test('Me U+20DD fires through the combining arm alone', () {
      // Qt: category == QChar::Mark_Enclosing (Glyphs.cpp:122).
      // U+20DD COMBINING ENCLOSING CIRCLE is Me, script Common (whitelisted)
      // and bidi NSM, which is neither DirR nor DirAL, so the port's three-value
      // narrowing must report "not right to left" (fallback_shaper.dart:190-193
      // keeps only the classes the predicate distinguishes). Symbol-covered by
      // the fixture, so term (7) is out.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        categories: <int, int>{0x20DD: kCategoryEnclosingMark},
      );
      expect(fonts.symbolSupports(0x20DD), isTrue);
      expect(
        requiresFallback('\u20DD', fonts: fonts, classifier: classifier),
        isTrue,
      );
    });
  });

  group('term (3): Hangul outside U+AC00..U+D7A3', () {
    test('conjoining jamo U+1100 needs composition', () {
      // Qt: script == QChar::Script_Hangul && (point < 0xac00 || point > 0xd7a3)
      // (Glyphs.cpp:123). U+1100 HANGUL CHOSEONG KIEOK is Hangul and below the
      // syllable block. Symbol-covered by the fixture so term (7) cannot answer
      // instead, and DirL so term (6) is quiet.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        scripts: <int, int>{0x1100: kScriptHangul},
      );
      expect(fonts.symbolSupports(0x1100), isTrue);
      expect(
        requiresFallback('\u1100', fonts: fonts, classifier: classifier),
        isTrue,
      );
    });

    test('compatibility jamo U+3131 also needs composition', () {
      // Same Qt term: U+3131 HANGUL LETTER KIEOK is script Hangul and below
      // U+AC00, so the "outside the precomposed block" test fires.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        scripts: <int, int>{0x3131: kScriptHangul},
      );
      expect(fonts.symbolSupports(0x3131), isTrue);
      expect(
        requiresFallback('\u3131', fonts: fonts, classifier: classifier),
        isTrue,
      );
    });

    test('both ends of the block, U+AC00 and U+D7A3, stay on the outline path', () {
      // Qt's comparison is strict: point < 0xac00 || point > 0xd7a3
      // (Glyphs.cpp:123), so the first and the last precomposed syllable are
      // NOT jamo. With a resource outline present (asserted first, so term (7)
      // cannot explain the answer), script Hangul whitelisted (:127), not
      // U+200D, and DirL, both must answer false.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        scripts: <int, int>{0xAC00: kScriptHangul, 0xD7A3: kScriptHangul},
      );
      expect(fonts.hasOutline('\uAC00'), isTrue);
      expect(fonts.hasOutline('\uD7A3'), isTrue);
      expect(
        requiresFallback('\uAC00', fonts: fonts, classifier: classifier),
        isFalse,
      );
      expect(
        requiresFallback('\uD7A3', fonts: fonts, classifier: classifier),
        isFalse,
      );
    });
  });

  group('term (4): script outside the plain-text whitelist', () {
    test('a script outside the whitelist is contextual (default arm)', () {
      // Qt: contextual == script is none of Common/Inherited/Latin/Han/
      // Hiragana/Katakana/Hangul (Glyphs.cpp:124-127). Cyrillic, Greek, Thai and
      // Devanagari are all outside it, all DirL (term 6 quiet) and all
      // symbol-covered by the fixture (term 7 quiet). The injected script value
      // is out of T31's enum -- see _scriptOutsideWhitelist -- which is the arm
      // a classifier uses for every script the compact enum does not carry.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        scripts: <int, int>{
          0x0416: _scriptOutsideWhitelist,
          0x0E01: _scriptOutsideWhitelist,
          0x03B1: _scriptOutsideWhitelist,
          0x0915: _scriptOutsideWhitelist,
        },
      );
      const Map<String, int> cases = <String, int>{
        '\u0416': 0x0416, // cyrillic zhe
        '\u0E01': 0x0E01, // thai ko kai
        '\u03B1': 0x03B1, // greek small alpha
        '\u0915': 0x0915, // devanagari ka
      };
      for (final MapEntry<String, int> entry in cases.entries) {
        expect(
          requiresFallback(entry.key, fonts: fonts, classifier: classifier),
          isTrue,
          reason: 'U+${entry.value.toRadixString(16).toUpperCase()}',
        );
      }
    });

    test('Script_Unknown is contextual too (private use)', () {
      // U+E000 is private use: Unicode assigns it no script, so QChar::script
      // answers Script_Unknown, and Glyphs.cpp:124-127 is an allow-list -- an
      // unlisted script is contextual, Unknown included. Symbol-covered by the
      // fixture so term (7) cannot answer instead.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        scripts: <int, int>{0xE000: kScriptUnknown},
      );
      expect(fonts.symbolSupports(0xE000), isTrue);
      expect(
        requiresFallback('\uE000', fonts: fonts, classifier: classifier),
        isTrue,
      );
    });

    test('the seven whitelisted scripts are not contextual', () {
      // Qt lists exactly the seven scripts at Glyphs.cpp:124-127 and reports
      // contextual only for the rest. U+AC00 is a Hangul syllable inside the
      // composition block so term (3) is quiet as well; every character here is
      // either carried by the regular resource table or symbol-covered, so
      // term (7) cannot answer either.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        scripts: <int, int>{
          0x0041: kScriptLatin,
          0x4E00: kScriptHan,
          0x3042: kScriptHiragana,
          0x30A2: kScriptKatakana,
          0xAC00: kScriptHangul,
          0x0021: kScriptCommon,
          0x200C: kScriptInherited,
        },
      );
      const Map<String, int> cases = <String, int>{
        'A': 0x0041, // Latin
        '\u4E00': 0x4E00, // Han
        '\u3042': 0x3042, // Hiragana
        '\u30A2': 0x30A2, // Katakana
        '\uAC00': 0xAC00, // Hangul
        '!': 0x0021, // Common
        '\u200C': 0x200C, // Inherited
      };
      for (final MapEntry<String, int> entry in cases.entries) {
        expect(
          requiresFallback(entry.key, fonts: fonts, classifier: classifier),
          isFalse,
          reason: 'U+${entry.value.toRadixString(16).toUpperCase()}',
        );
      }
    });
  });

  group('term (5): ZERO WIDTH JOINER', () {
    test('U+200D needs layout while U+200C does not', () {
      // Qt: point == 0x200d (Glyphs.cpp:128). Both joiners are symbol-covered
      // by the fixture, so term (7) cannot explain either answer; both are
      // Common or Inherited (whitelisted), Cf (not a mark, term 2 quiet) and
      // neither R nor AL (term 6 quiet). The only difference left is the
      // literal code point -- exactly Qt's test.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        scripts: <int, int>{0x200D: kScriptCommon, 0x200C: kScriptInherited},
      );
      expect(fonts.symbolSupports(0x200D), isTrue);
      expect(
        requiresFallback('\u200D', fonts: fonts, classifier: classifier),
        isTrue,
      );
      expect(
        requiresFallback('\u200C', fonts: fonts, classifier: classifier),
        isFalse,
      );
      expect(
        requiresFallback('A\u200DB', fonts: fonts, classifier: classifier),
        isTrue,
      );
    });
  });

  group('term (6): strong right-to-left bidi classes', () {
    test('DirR fires: U+200F has a whitelisted script, so only bidi can answer', () {
      // Qt: direction == QChar::DirR (Glyphs.cpp:129). U+200F RIGHT-TO-LEFT
      // MARK is script Common (inside the whitelist at :124), category Cf so no
      // mark, not U+200D, and symbol-covered by the fixture: the bidi class is
      // the only term left.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        scripts: <int, int>{0x200F: kScriptCommon},
        directions: <int, int>{0x200F: kDirectionRightToLeft},
      );
      expect(fonts.symbolSupports(0x200F), isTrue);
      expect(
        requiresFallback('\u200F', fonts: fonts, classifier: classifier),
        isTrue,
      );
    });

    test('DirR fires for Hebrew, which term (4) would already explain', () {
      // U+05D0 HEBREW LETTER ALEF is script Hebrew, outside the whitelist, so
      // with real data Qt answers true at term (4) before term (6) is reached
      // (Glyphs.cpp:124 before :129). Both arms are exercised here by reporting
      // the real (non-whitelisted) script AND DirR: the answer true is what Qt
      // gives for either reason.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        scripts: <int, int>{0x05D0: _scriptOutsideWhitelist},
        directions: <int, int>{0x05D0: kDirectionRightToLeft},
      );
      expect(
        requiresFallback('\u05D0', fonts: fonts, classifier: classifier),
        isTrue,
      );
    });

    test('DirAL fires: script pinned to Common, and real Arabic on top of term (4)', () {
      // Qt: direction == QChar::DirAL (Glyphs.cpp:129). U+0627 ARABIC LETTER
      // ALEF is script Arabic, which already fires term (4) with real data, so
      // the isolating half pins the script to Common: only the AL arm can
      // answer true there. The second half keeps the real (non-whitelisted)
      // script so the pair stays visible in one place.
      final fonts = _maskedFonts();
      final alOnly = _FakeClassifier(
        scripts: <int, int>{0x0627: kScriptCommon},
        directions: <int, int>{0x0627: kDirectionArabicLetter},
      );
      expect(
        requiresFallback('\u0627', fonts: fonts, classifier: alOnly),
        isTrue,
      );
      final realArabic = _FakeClassifier(
        scripts: <int, int>{0x0627: _scriptOutsideWhitelist},
        directions: <int, int>{0x0627: kDirectionArabicLetter},
      );
      expect(
        requiresFallback('\u0627', fonts: fonts, classifier: realArabic),
        isTrue,
      );
    });

    test('DirAN and DirL fall through: Qt compares only DirR and DirAL', () {
      // Qt: "direction == QChar::DirR || direction == QChar::DirAL"
      // (Glyphs.cpp:129) is equality against two classes, not "anything that is
      // not left to right". U+0660 ARABIC-INDIC DIGIT ZERO is bidi class AN;
      // the fixture reports the stand-in value (see
      // _bidiArabicNumberStandIn), script pinned to Common, symbol-covered, so
      // a port that widened the comparison would be the only way to answer true
      // here. 'A' is the DirL control.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        scripts: <int, int>{0x0660: kScriptCommon},
        directions: <int, int>{0x0660: _bidiArabicNumberStandIn},
      );
      expect(fonts.symbolSupports(0x0660), isTrue);
      expect(
        requiresFallback('\u0660', fonts: fonts, classifier: classifier),
        isFalse,
      );
      expect(
        requiresFallback('A', fonts: fonts, classifier: _FakeClassifier()),
        isFalse,
      );
    });
  });

  group('term (7): no outline in this weight and no symbol coverage', () {
    test('a Latin letter the resource table lacks needs layout', () {
      // Qt: "!font.supportsCharacter(point) && !symbols.supportsCharacter(point)"
      // (Glyphs.cpp:130). 'Q' is Other/Latin/DirL, so terms (1)..(6) are all
      // false and only term (7) can answer true; 'A' is the same character
      // class with a resource outline and must stay false.
      final fonts = _sparseFonts();
      expect(fonts.hasOutline('A'), isTrue);
      expect(fonts.hasOutline('Q'), isFalse);
      expect(fonts.symbolSupports(0x51), isFalse);
      expect(
        requiresFallback('Q', fonts: fonts, classifier: _FakeClassifier()),
        isTrue,
      );
      expect(
        requiresFallback('A', fonts: fonts, classifier: _FakeClassifier()),
        isFalse,
      );
    });

    test('symbol-face coverage is enough to keep the outline path', () {
      // Same string, same classifier, same resource table: only the injected
      // symbol probe differs, and Qt asks exactly that probe in the second
      // operand of the && at Glyphs.cpp:130.
      final fonts = _coveredFonts();
      expect(fonts.hasOutline('Q'), isFalse);
      expect(fonts.symbolSupports(0x51), isTrue);
      expect(
        requiresFallback('Q', fonts: fonts, classifier: _FakeClassifier()),
        isFalse,
      );
    });

    test('the weight argument selects the resource table', () {
      // Qt resolves the face with fonts.value(weight, fonts["regular"])
      // (Glyphs.cpp:114 for needsLayout, :147 for layoutText) and every metric
      // entry point defaults the weight to "regular" (Glyphs.h:25-28). The
      // fixture ships 'A' in regular and only 'B' in light, so the same
      // character flips answer with the weight argument alone. This flip is
      // manufactured by the fixture to prove the weight reaches hasOutline; it
      // is not a claim that the shipping fonts differ per weight.
      final fonts = _maskedFonts();
      expect(fonts.hasOutline('A'), isTrue);
      expect(fonts.hasOutline('A', 'light'), isFalse);
      expect(
        requiresFallback('A', fonts: fonts, classifier: _FakeClassifier()),
        isFalse,
      );
      expect(
        requiresFallback(
          'A',
          weight: 'light',
          fonts: fonts,
          classifier: _FakeClassifier(),
        ),
        isTrue,
      );
    });
  });

  // =========================================================================
  // A (continued). the break at the first hit
  // =========================================================================

  group('first hit breaks the loop (Glyphs.cpp:132)', () {
    test('a combining first code point hides the rest of the string', () {
      // Qt leaves the for loop at the first true arm (:131-132), so no later
      // code point is examined. The first code point here is Mn (term 2); the
      // second, 'Q', would hit term (7) on its own in this font set. Zero
      // classifier calls for 0x51 is therefore the proof that the port broke
      // out instead of scanning the whole string.
      //
      // Note on where the port is lazier than Qt: Qt computes category,
      // direction and script for a code point before the if (:118-120), while
      // the port stops at the winning term. That difference is unobservable in
      // the answer, so only the break is pinned here, not the order of the
      // three queries inside one code point.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        categories: <int, int>{0x0301: kCategoryNonSpacingMark},
      );
      expect('\u0301Q'.runes.length, 2);
      expect(
        requiresFallback('\u0301Q', fonts: fonts, classifier: classifier),
        isTrue,
      );
      expect(classifier.categoryCalls, <int>[0x0301]);
      // The port stops at the winning arm, so neither later query ran at all --
      // not for 'Q' and not even for the first code point. Asserting the empty
      // lists is stronger than "does not contain 0x51", which an empty list
      // satisfies vacuously.
      expect(classifier.scriptCalls, isEmpty);
      expect(classifier.directionCalls, isEmpty);
    });

    test('the loop has to reach the hit code point first', () {
      // The mirror case: a plain 'A' followed by the Mn. The first code point
      // must be fully classified (it is not a hit), then the loop advances and
      // stops at the second, so category sees both code points in order. A port
      // that only ever looked at the first code point would answer false.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        categories: <int, int>{0x0301: kCategoryNonSpacingMark},
      );
      expect(
        requiresFallback('A\u0301', fonts: fonts, classifier: classifier),
        isTrue,
      );
      expect(classifier.categoryCalls, <int>[0x41, 0x0301]);
    });

    test('a term (7) hit also stops the loop', () {
      // term (7) is the last arm of the if (:130) and still inside the loop, so
      // it must break as well. 'Q' has no outline in this table and no symbol
      // coverage, so the answer is decided at index 0; the astral code point
      // behind it is never examined (its category is never asked).
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier();
      expect(
        requiresFallback('Q\u{1F600}', fonts: fonts, classifier: classifier),
        isTrue,
      );
      expect(classifier.categoryCalls, <int>[0x51]);
      expect(classifier.categoryCalls, isNot(contains(0x1F600)));
    });
  });

  // =========================================================================
  // C. the empty string, answered before the port is validated
  // =========================================================================

  group('empty text is answered before the port is validated', () {
    test('the empty string never needs layout, even without Unicode data', () {
      // Qt: for an empty QString the loop body never runs (Glyphs.cpp:117) and
      // required keeps its initial false (:116), so needsLayout("") is false
      // without QChar being consulted at all.
      //
      // Port contract: fallback_shaper.dart:273-275 answers the empty string
      // BEFORE _requireUnicodeData (:276). This is the regression guard -- if
      // the guard were moved above the empty check, both lines below throw and
      // the fix is undone.
      expect(
        requiresFallback(
          '',
          fonts: GlyphFontSet.empty,
          classifier: UnicodeClassifier.none,
        ),
        isFalse,
      );
      expect(
        requiresFallback(
          '',
          fonts: _sparseFonts(),
          classifier: UnicodeClassifier.none,
        ),
        isFalse,
      );
    });
  });

  // =========================================================================
  // B. a data-less classifier is never a silent false
  // =========================================================================

  group('a data-less classifier is rejected, never answered false', () {
    test('requiresFallback throws a StateError that names UnicodeClassifier', () {
      // No Qt counterpart: QChar always answers. This is the port contract of
      // fallback_shaper.dart:52-63 and :350-365. It has to be an ERROR and not
      // false, because terms (2), (3), (4) and (6) would otherwise stay silent
      // and a combining mark or Hebrew string would be declared plain text
      // exactly where Qt runs QTextLayout.
      final fonts = _sparseFonts();
      expect(
        () => requiresFallback(
          'A',
          fonts: fonts,
          classifier: UnicodeClassifier.none,
        ),
        _throwsStateErrorContaining('UnicodeClassifier'),
      );
      // The text would be true anyway (U+0301 is a combining mark): the
      // rejection must not depend on the answer being true or false.
      expect(
        () => requiresFallback(
          '\u0301',
          fonts: fonts,
          classifier: UnicodeClassifier.none,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('the no-data port answers exactly the neutral constants', () {
      // These answers are why the guard exists: Other / Unknown / DirL is
      // indistinguishable from "known to be plain", so answering false would be
      // a wrong answer rather than a conservative one
      // (fallback_shaper.dart:195-212).
      expect(UnicodeClassifier.none.hasScriptData, isFalse);
      expect(UnicodeClassifier.none.category(0x0301), kCategoryOther);
      expect(UnicodeClassifier.none.script(0x0301), kScriptUnknown);
      expect(UnicodeClassifier.none.direction(0x05D0), kDirectionLeftToRight);
    });
  });

  // =========================================================================
  // D. the gate used by glyph_run.dart
  // =========================================================================

  group('requiresFallbackGate', () {
    test('wiring with a data-less classifier throws before the closure exists', () {
      // Port contract (fallback_shaper.dart:334-348): the check runs while the
      // closure is built, so a misconfigured app fails while constructing its
      // text stack instead of on the first Arabic string. The closure type is
      // glyph_run.dart's ComplexTextGate, "bool Function(String, String)".
      bool Function(String text, String weight)? gate;
      expect(
        () => gate = requiresFallbackGate(
          fonts: _sparseFonts(),
          classifier: UnicodeClassifier.none,
        ),
        _throwsStateErrorContaining('requiresFallbackGate'),
      );
      expect(gate, isNull);
    });

    test('the closure is the same decision as the direct call', () {
      // The gate is what GlyphText asks, and the direct call is what
      // needsLayout parity is measured with; a divergence would make the
      // decision and the measurement disagree.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        categories: <int, int>{0x0301: kCategoryNonSpacingMark},
        scripts: <int, int>{
          0x4E00: kScriptHan,
          0x05D0: _scriptOutsideWhitelist,
        },
        directions: <int, int>{0x05D0: kDirectionRightToLeft},
      );
      final bool Function(String text, String weight) gate =
          requiresFallbackGate(fonts: fonts, classifier: classifier);
      const List<String> texts = <String>[
        '',
        'A',
        'Q',
        '\u4E00',
        '\u0301',
        '\u05D0',
        'A\u0301Q',
        'A\u200DB',
        '\u{1F600}',
      ];
      const List<String> weights = <String>['regular', 'light', 'bold'];
      for (final String text in texts) {
        for (final String weight in weights) {
          expect(
            gate(text, weight),
            requiresFallback(
              text,
              weight: weight,
              fonts: fonts,
              classifier: classifier,
            ),
            reason: '$weight:$text',
          );
        }
      }
    });

    test('the closure captured the resource table it was wired with', () {
      // term (7) has to ask the same table the painter draws from
      // (fallback_shaper.dart:324-333), so the answer must follow the captured
      // GlyphFontSet. 'A' is Other/Latin/DirL in both gates, so term (7) is the
      // only arm that can differ between them.
      final withA = _maskedFonts();
      final withoutA = _fontsWithoutA();
      expect(withA.hasOutline('A'), isTrue);
      expect(withoutA.hasOutline('A'), isFalse);
      final withGate = requiresFallbackGate(
        fonts: withA,
        classifier: _FakeClassifier(),
      );
      final withoutGate = requiresFallbackGate(
        fonts: withoutA,
        classifier: _FakeClassifier(),
      );
      expect(withGate('A', 'regular'), isFalse);
      expect(withoutGate('A', 'regular'), isTrue);
    });
  });

  // =========================================================================
  // E. the weight default
  // =========================================================================

  group('default weight', () {
    test("kDefaultGlyphWeight is Qt's \"regular\"", () {
      // Qt: every metric entry point declares "QString weight = regular"
      // (Glyphs.h:25-28) and needsLayout resolves the face through
      // fonts.value(weight, fonts["regular"]) (Glyphs.cpp:114).
      expect(kDefaultGlyphWeight, 'regular');
    });

    test('requiresFallback uses that default when the weight is omitted', () {
      // Same fixture and classifier in all three calls: 'A' is in the regular
      // table and not in light, so the omitted-weight call must equal the
      // explicit 'regular' call and differ from 'light'.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier();
      expect(fonts.hasOutline('A'), isTrue);
      expect(fonts.hasOutline('A', 'light'), isFalse);
      expect(
        requiresFallback('A', fonts: fonts, classifier: classifier),
        isFalse,
      );
      expect(
        requiresFallback(
          'A',
          weight: 'regular',
          fonts: fonts,
          classifier: classifier,
        ),
        isFalse,
      );
      expect(
        requiresFallback(
          'A',
          weight: 'light',
          fonts: fonts,
          classifier: classifier,
        ),
        isTrue,
      );
    });
  });

  // =========================================================================
  // F. the private numbering contract
  // =========================================================================

  group('private contract: kScript* are T31 slots, not QChar::Script', () {
    test('the compact enum is numbered 0..7 in this order', () {
      // fallback_shaper.dart:125-160 fixes the order on purpose: the predicate
      // only needs the whitelist bit, so the identity of a script is not kept.
      expect(kScriptUnknown, 0);
      expect(kScriptCommon, 1);
      expect(kScriptInherited, 2);
      expect(kScriptLatin, 3);
      expect(kScriptHan, 4);
      expect(kScriptHiragana, 5);
      expect(kScriptKatakana, 6);
      expect(kScriptHangul, 7);
      // Eight distinct slots, so no two scripts share a value.
      expect(
        <int>{
          kScriptUnknown,
          kScriptCommon,
          kScriptInherited,
          kScriptLatin,
          kScriptHan,
          kScriptHiragana,
          kScriptKatakana,
          kScriptHangul,
        }.length,
        8,
      );
    });

    test("Qt's numbers for the first three slots are different", () {
      // QChar::Script numbers Script_Unknown 0, Script_Inherited 1,
      // Script_Common 2 in that order. T31 swaps slots 1 and 2, so feeding
      // QChar::Script values straight in reads Qt-Common (2) as
      // kScriptInherited and Qt-Inherited (1) as kScriptCommon. Both of those
      // are whitelisted, which is exactly why the mistake would stay invisible
      // until a real script with a Qt number above 2 fell into the default arm
      // and silently shaped everything (the hazard the file warns about at
      // fallback_shaper.dart:126-135).
      const int qtScriptUnknown = 0;
      const int qtScriptInherited = 1;
      const int qtScriptCommon = 2;
      expect(kScriptCommon, isNot(qtScriptCommon));
      expect(kScriptInherited, isNot(qtScriptInherited));
      expect(kScriptCommon, qtScriptInherited); // the swap, pinned
      expect(kScriptInherited, qtScriptCommon); // the swap, pinned
      // Unknown happens to coincide, which is the one slot where a QChar::Script
      // value is also the right T31 value; the two other slots are what make the
      // numbering a contract instead of an alias.
      expect(kScriptUnknown, qtScriptUnknown);
    });

    test('the direction slots mirror DirL / DirR / DirAL only', () {
      // Qt compares against DirR and DirAL (Glyphs.cpp:129); the port carries
      // exactly those two plus the "other" bucket
      // (fallback_shaper.dart:162-169), which is what lets DirAN fall through.
      expect(kDirectionLeftToRight, 0);
      expect(kDirectionRightToLeft, 1);
      expect(kDirectionArabicLetter, 2);
    });
  });

  // =========================================================================
  // G. Script_Unknown is contextual
  // =========================================================================

  group('kScriptUnknown is contextual, literally like Qt', () {
    test('a classifier that answers Unknown everywhere forces layout', () {
      // Qt's contextual term is an allow-list of seven scripts
      // (Glyphs.cpp:124-127); Script_Unknown is not among them, so unknown
      // code points are contextual. 'A' carries a resource outline, so with a
      // Latin answer the same table stays on the outline path -- the flip below
      // is caused by the script value alone.
      final fonts = _maskedFonts();
      expect(fonts.hasOutline('A'), isTrue);
      expect(
        requiresFallback(
          'A',
          fonts: fonts,
          classifier: _FakeClassifier(defaultScript: kScriptUnknown),
        ),
        isTrue,
      );
      expect(
        requiresFallback('A', fonts: fonts, classifier: _FakeClassifier()),
        isFalse,
      );
    });

    test('an unassigned code point reported as Unknown is contextual', () {
      // U+0378 is unassigned: it has no script assignment, so the real QChar
      // answers Script_Unknown, and Glyphs.cpp:124-127 counts it as contextual.
      // The string mixes it with a plain 'A' to show one unknown code point is
      // enough for the whole string. Group A.4 keeps the private-use U+E000
      // case, so the two groups no longer assert the same fact twice.
      final fonts = _maskedFonts();
      final classifier = _FakeClassifier(
        scripts: <int, int>{0x0378: kScriptUnknown},
      );
      expect(
        requiresFallback('A\u0378', fonts: fonts, classifier: classifier),
        isTrue,
      );
      expect(
        requiresFallback('A', fonts: fonts, classifier: classifier),
        isFalse,
      );
    });
  });
}
