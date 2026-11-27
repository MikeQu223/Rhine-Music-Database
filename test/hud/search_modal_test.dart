// Behavior/state assertions for atom T35-C19-A1-search_modal (W1).
// Expected values come from Qt:
//   NativeHudSearch.cpp:52-129  toolbar tabs / group tabs / header / group-back
//   NativeHudSearch.cpp:232-253 footer label and hints
//   NativeHudSearch.cpp:259-281 auto-fill gate
//   NativeHudMusic.cpp:148-185  kind/group/expand/group-back semantics
//   MusicLibrary.cpp:435-455    query limits on trimmed toUcs4 size
//   Overlay.qml:520-566         hints, visibility, Enter/Escape
//   Engine.cpp:1006-1012        searchAccepted(text, modifiers)
// Tests only; never executed in this card (RED/GREEN unexecuted).

import 'dart:ui' show Color, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/search_modal.dart';
import 'package:rhine_music_database/hud/modals/search_results.dart'
    show SearchColor, SearchResultsLayer, SearchResultsPort, SearchRow;

/// Deterministic stand-in for the host glyph advance. Only layout math is under
/// test; production always uses the real host advance through SearchModalPorts.
const Map<String, double> _advance = <String, double>{
  '歌曲': 40,
  '专辑': 40,
  '文件夹': 50,
  '歌单': 40,
  '歌手': 40,
  '原序': 30,
  '歌手分组': 50,
  '专辑分组': 50,
  '← 全部分组': 60,
};

double _glyph(String text, double size, String weight) =>
    _advance[text] ?? text.runes.length * (size * 0.5 + 2);

/// Repeat helper (Dart has no string * n operator).
String _repeat(String unit, int count) => List<String>.filled(count, unit).join();

const SearchPalette _palette = SearchPalette(
  ink: SearchColor(0.10, 0.11, 0.10, 1),
  dark: true,
);

/// Minimal port: the cross-file color test never draws; it only proves the
/// results layer accepts the palette's SearchColor without any conversion.
class _NoopResultsPort implements SearchResultsPort {
  const _NoopResultsPort();

  @override
  double glyphWidth(String text, double size, String weight) => 0;

  @override
  String fit(String text, double size, double maxWidth, String weight) => text;

  @override
  void save() {}

  @override
  void clip(Rect rect) {}

  @override
  void restore() {}

  @override
  void fill(Rect rect, SearchColor color) {}

  @override
  void text(
    String text,
    double x,
    double y,
    double size,
    String weight,
    double letterSpacing,
    SearchColor color,
  ) {}

  @override
  void hit(
    double x,
    double y,
    double width,
    double height,
    String action,
    String label,
  ) {}
}

void main() {
  group('kind tabs (NativeHudSearch.cpp:63-83)', () {
    test('local labels are 歌曲/专辑/文件夹/歌手', () {
      expect(
        searchKindLabels(localMusic: true),
        <String>['歌曲', '专辑', '文件夹', '歌手'],
      );
    });

    test('online labels are 歌曲/专辑/歌单/歌手', () {
      expect(
        searchKindLabels(localMusic: false),
        <String>['歌曲', '专辑', '歌单', '歌手'],
      );
    });

    test('kinds order is song/album/playlist/artist', () {
      expect(kSearchKinds, <String>['song', 'album', 'playlist', 'artist']);
    });

    test('searchActiveKind maps kinds and falls back for folder', () {
      expect(searchActiveKind('song'), 0);
      expect(searchActiveKind('album'), 1);
      expect(searchActiveKind('playlist'), 2);
      expect(searchActiveKind('artist'), 3);
      expect(searchActiveKind('folder'), 2);
      expect(searchActiveKind(''), -1);
      expect(searchActiveKind('video'), -1);
    });

    test('action strings are exact', () {
      expect(searchKindAction(0), 'music:kind:0');
      expect(searchKindAction(3), 'music:kind:3');
      expect(searchGroupAction(0), 'music:group:0');
      expect(searchGroupAction(2), 'music:group:2');
      expect(kSearchGroupBackAction, 'music:group-back');
    });
  });

  group('toolbar layout order and geometry (NativeHudSearch.cpp:52-129)', () {
    test('1920: bar, gold bar, QUERY, then tab hit/text/underline', () {
      final SearchModalLayout layout = buildSearchToolbarLayout(
        stageWidth: 1920,
        localMusic: false,
        searchKind: '',
        groupBy: 'none',
        activeGroup: '',
        hasSongRows: false,
        palette: _palette,
        glyphWidth: _glyph,
      );
      // 3 chrome + (4 hits + 4 texts, no active underline) + 2 rules + 3 headers
      expect(layout.ops.length, 16);
      final SearchFillOp bar = layout.ops[0] as SearchFillOp;
      expect(bar.rect, const Rect.fromLTWH(960, 294, 795, 66));
      expect(bar.color, _palette.searchBarFill);
      final SearchFillOp gold = layout.ops[1] as SearchFillOp;
      expect(gold.rect, const Rect.fromLTWH(960, 294, 3, 66));
      expect(gold.color, SearchPalette.accentColor);
      final SearchTextOp query = layout.ops[2] as SearchTextOp;
      expect(query.text, 'QUERY / 检索词');
      expect(query.x, 978); // left + 18
      expect(query.y, 304); // 122 + 172 + 10
      expect(query.size, 9);
      expect(query.letterSpacing, 0.08);
      expect(query.color, _palette.mutedInk);

      final List<SearchHitOp> hits = layout.hits.toList();
      expect(hits.length, 4);
      expect(hits[0].x, 956); // 960 - 4
      expect(hits[0].y, 374); // 122 + 252
      expect(hits[0].width, 48); // 40 + 8
      expect(hits[0].height, 36);
      expect(hits[0].action, 'music:kind:0');
      expect(hits[0].label, '歌曲');
      expect(hits[1].action, 'music:kind:1');
      expect(hits[2].action, 'music:kind:2');
      expect(hits[3].action, 'music:kind:3');

      // cursor stepping: 40 + 26 = 66
      final List<SearchTextOp> tabTexts =
          layout.texts.where((SearchTextOp op) => op.size == 13).toList();
      expect(tabTexts.length, 4);
      expect(tabTexts[0].x, 960);
      expect(tabTexts[1].x, 1026);
      expect(tabTexts[2].x, 1092);
      expect(tabTexts[3].x, 1158);
      expect(tabTexts[0].y, 384); // 252 + 10
      expect(tabTexts[0].weight, 'regular'); // no active kind
      expect(tabTexts[0].color, _palette.mutedInk);
    });

    test('active kind gets demibold + ink + 3px underline at y+285', () {
      final SearchModalLayout layout = buildSearchToolbarLayout(
        stageWidth: 1920,
        localMusic: false,
        searchKind: 'song',
        groupBy: 'none',
        activeGroup: '',
        hasSongRows: false,
        palette: _palette,
        glyphWidth: _glyph,
      );
      final List<SearchTextOp> tabTexts =
          layout.texts.where((SearchTextOp op) => op.size == 13).toList();
      expect(tabTexts[0].weight, 'demibold');
      expect(tabTexts[0].color, _palette.ink);
      final SearchFillOp underline = layout.fills
          .firstWhere((SearchFillOp op) => op.rect.height == 3);
      expect(underline.rect, const Rect.fromLTWH(960, 407, 40, 3));
      expect(underline.color, SearchPalette.accentColor);
    });

    test('folder fallback highlights the third label (local subset)', () {
      final SearchModalLayout layout = buildSearchToolbarLayout(
        stageWidth: 1920,
        localMusic: true,
        searchKind: 'folder',
        groupBy: 'none',
        activeGroup: '',
        hasSongRows: false,
        palette: _palette,
        glyphWidth: _glyph,
      );
      final List<SearchTextOp> tabTexts =
          layout.texts.where((SearchTextOp op) => op.size == 13).toList();
      expect(tabTexts[2].text, '文件夹');
      expect(tabTexts[2].weight, 'demibold');
      expect(tabTexts[2].color, _palette.ink);
      final SearchFillOp underline = layout.fills
          .firstWhere((SearchFillOp op) => op.rect.height == 3);
      expect(underline.rect, const Rect.fromLTWH(1092, 407, 50, 3));
    });

    test('group tabs exist only when a song row is loaded', () {
      final SearchModalLayout without = buildSearchToolbarLayout(
        stageWidth: 1920,
        localMusic: false,
        searchKind: 'song',
        groupBy: 'none',
        activeGroup: '',
        hasSongRows: false,
        palette: _palette,
        glyphWidth: _glyph,
      );
      expect(without.hits.where((SearchHitOp op) => op.action.startsWith('music:group')), isEmpty);

      final SearchModalLayout withGroups = buildSearchToolbarLayout(
        stageWidth: 1920,
        localMusic: false,
        searchKind: 'song',
        groupBy: 'none',
        activeGroup: '',
        hasSongRows: true,
        palette: _palette,
        glyphWidth: _glyph,
      );
      final List<SearchHitOp> groupHits = withGroups.hits
          .where((SearchHitOp op) => op.action.startsWith('music:group'))
          .toList();
      expect(groupHits.length, 3);
      expect(groupHits[0].action, 'music:group:0');
      expect(groupHits[0].label, '原序');
      expect(groupHits[1].action, 'music:group:1');
      expect(groupHits[1].label, '歌手分组');
      expect(groupHits[2].action, 'music:group:2');
      expect(groupHits[2].label, '专辑分组');
    });

    test('group tab geometry: widths 30/50/50, gap 20, sortX from right', () {
      final SearchModalLayout layout = buildSearchToolbarLayout(
        stageWidth: 1920,
        localMusic: false,
        searchKind: 'song',
        groupBy: 'none',
        activeGroup: '',
        hasSongRows: true,
        palette: _palette,
        glyphWidth: _glyph,
      );
      // total = 30 + 50 + 50 + 20*2 = 170; sortX = 960 + 901 - 53 - 170 = 1638
      final SearchRuleOp divider = layout.rules.first;
      expect(divider.rect, const Rect.fromLTWH(1622, 380, 1, 24)); // sortX-16, 252+6
      expect(divider.alpha, 0.18);

      final List<SearchHitOp> groupHits = layout.hits
          .where((SearchHitOp op) => op.action.startsWith('music:group'))
          .toList();
      expect(groupHits[0].x, 1634); // 1638 - 4
      expect(groupHits[0].width, 38); // 30 + 8
      expect(groupHits[0].y, 374);
      expect(groupHits[0].height, 36);
      expect(groupHits[1].x, 1684); // 1638 + 30 + 20 - 4
      expect(groupHits[1].width, 58); // 50 + 8
      expect(groupHits[2].x, 1754); // 1688 + 50 + 20 - 4

      final List<SearchTextOp> groupTexts =
          layout.texts.where((SearchTextOp op) => op.size == 11).toList();
      expect(groupTexts[0].x, 1638);
      expect(groupTexts[0].y, 385); // 252 + 11
      expect(groupTexts[0].weight, 'demibold'); // groupBy == none
      final SearchFillOp underline = layout.fills
          .firstWhere((SearchFillOp op) => op.rect.height == 2);
      expect(underline.rect, const Rect.fromLTWH(1638, 408, 30, 2)); // 252+36-2
    });

    test('active group tab underline follows groupBy', () {
      final SearchModalLayout layout = buildSearchToolbarLayout(
        stageWidth: 1920,
        localMusic: false,
        searchKind: 'song',
        groupBy: 'album',
        activeGroup: '',
        hasSongRows: true,
        palette: _palette,
        glyphWidth: _glyph,
      );
      final List<SearchTextOp> groupTexts =
          layout.texts.where((SearchTextOp op) => op.size == 11).toList();
      expect(groupTexts[2].weight, 'demibold');
      final SearchFillOp underline = layout.fills
          .firstWhere((SearchFillOp op) => op.rect.height == 2);
      expect(underline.rect, const Rect.fromLTWH(1758, 408, 50, 2));
    });

    test('table header and rules at y+288 / y+302 / y+318', () {
      final SearchModalLayout layout = buildSearchToolbarLayout(
        stageWidth: 1920,
        localMusic: false,
        searchKind: 'song',
        groupBy: 'none',
        activeGroup: '',
        hasSongRows: false,
        palette: _palette,
        glyphWidth: _glyph,
      );
      expect(layout.rules.length, 2);
      expect(layout.rules.elementAt(0).rect, const Rect.fromLTWH(960, 410, 795, 1));
      expect(layout.rules.elementAt(0).alpha, 0.18);
      expect(layout.rules.elementAt(1).rect, const Rect.fromLTWH(960, 440, 795, 1));
      expect(layout.rules.elementAt(1).alpha, 0.24);

      final List<SearchTextOp> headers =
          layout.texts.where((SearchTextOp op) => op.size == 9).toList();
      // QUERY (before tabs) is also size 9: index 0; headers follow.
      final List<SearchTextOp> tableHeaders = headers.sublist(1);
      expect(tableHeaders.length, 3);
      expect(tableHeaders[0].text, 'ID / 编号');
      expect(tableHeaders[0].x, 960);
      expect(tableHeaders[0].y, 424); // 122 + 302
      expect(tableHeaders[0].letterSpacing, 0.07);
      expect(tableHeaders[1].text, 'TITLE / 音乐');
      expect(tableHeaders[1].x, 1067); // left + 107
      expect(tableHeaders[2].text, 'OPEN');
      expect(tableHeaders[2].x, 1725); // left + 901 - 136
    });

    test('group-back entry appears only with activeGroup', () {
      final SearchModalLayout layout = buildSearchToolbarLayout(
        stageWidth: 1920,
        localMusic: false,
        searchKind: 'song',
        groupBy: 'artist',
        activeGroup: 'artist:42',
        hasSongRows: true,
        palette: _palette,
        glyphWidth: _glyph,
      );
      final SearchHitOp back = layout.hits
          .firstWhere((SearchHitOp op) => op.action == 'music:group-back');
      // labelWidth = glyph(← 全部分组,11,regular) + 16 = 60 + 16 = 76
      // actionX = 960 + 901 - 53 - 150 - 76 = 1582
      expect(back.x, 1582);
      expect(back.y, 417); // 302 - 7
      expect(back.width, 76);
      expect(back.height, 28);
      expect(back.label, '全部分组');
      final SearchTextOp text = layout.texts
          .firstWhere((SearchTextOp op) => op.text == kSearchGroupBackText);
      expect(text.x, 1590); // actionX + 8
      expect(text.y, 424);
      expect(text.size, 11);
      expect(text.color, _palette.ink);
    });
  });

  group('footer (NativeHudSearch.cpp:232-253)', () {
    test('label is null when nothing loaded and not loading', () {
      expect(
        searchFooterLabel(
          loaded: 0,
          totalItems: 0,
          sourceLoading: false,
          hasMore: false,
        ),
        isNull,
      );
    });

    test('loading hint', () {
      expect(
        searchFooterLabel(
          loaded: 5,
          totalItems: 9,
          sourceLoading: true,
          hasMore: true,
        ),
        '已载入 5 / 9 · 正在加载…',
      );
    });

    test('has more hint', () {
      expect(
        searchFooterLabel(
          loaded: 5,
          totalItems: 9,
          sourceLoading: false,
          hasMore: true,
        ),
        '已载入 5 / 9 · SCROLL / 滚动加载',
      );
    });

    test('all loaded hint and total = max(totals, loaded)', () {
      expect(
        searchFooterLabel(
          loaded: 5,
          totalItems: 9,
          sourceLoading: false,
          hasMore: false,
        ),
        '已载入 5 / 9 · 全部已载入',
      );
      expect(
        searchFooterLabel(
          loaded: 5,
          totalItems: 3,
          sourceLoading: false,
          hasMore: false,
        ),
        '已载入 5 / 5 · 全部已载入',
      );
    });

    test('footer ops: 5x5 accent square, status at x+66, right aligned label', () {
      final SearchModalLayout layout = buildSearchFooterLayout(
        stageWidth: 1920,
        status: '找到 9 条结果',
        loaded: 5,
        totalItems: 9,
        sourceLoading: false,
        hasMore: false,
        palette: _palette,
        glyphWidth: _glyph,
      );
      expect(layout.ops.length, 3);
      final SearchFillOp square = layout.ops[0] as SearchFillOp;
      expect(square.rect, const Rect.fromLTWH(1013, 911, 5, 5)); // x+53, 786+3
      expect(square.color, SearchPalette.accentColor);
      final SearchTextOp status = layout.ops[1] as SearchTextOp;
      expect(status.text, '找到 9 条结果');
      expect(status.x, 1026); // x + 53 + 13
      expect(status.y, 908); // 122 + 786
      expect(status.size, 10);
      expect(status.maxWidth, 581); // 901 - 320
      final SearchTextOp label = layout.ops[2] as SearchTextOp;
      expect(label.text, '已载入 5 / 9 · 全部已载入');
      expect(label.size, 9);
      expect(label.letterSpacing, 0.04);
      expect(label.x + _glyph(label.text, 9, 'regular'), 1808); // right - 53
    });

    test('footer without loaded block still draws square + status', () {
      final SearchModalLayout layout = buildSearchFooterLayout(
        stageWidth: 1920,
        status: '',
        loaded: 0,
        totalItems: 0,
        sourceLoading: false,
        hasMore: false,
        palette: _palette,
        glyphWidth: _glyph,
      );
      expect(layout.ops.length, 2);
      expect(layout.texts.length, 1);
    });
  });

  group('query limits (MusicLibrary.cpp:435-455)', () {
    test('provider qq is 60, everything else 100', () {
      expect(searchQueryLimit('qq'), 60);
      for (final String provider in <String>[
        'netease',
        'kugou',
        'local',
        'siren',
        '',
      ]) {
        expect(searchQueryLimit(provider), 100, reason: provider);
      }
    });

    test('length counts trimmed code points, not UTF-16 units', () {
      expect(searchQueryLength('abc'), 3);
      expect(searchQueryLength('  abc  '), 3);
      expect(searchQueryLength('😀'), 1);
      expect('😀'.length, 2); // surrogate pair: String.length would be wrong
      expect(searchQueryLength('a😀b'), 3);
      expect('a😀b'.length, 4);
      expect(searchQueryLength(''), 0);
      expect(searchQueryLength('   '), 0);
    });

    test('overflow status is exact with en dash U+2013', () {
      expect(searchQueryOverflowStatus(60), '请输入 1–60 字关键词');
      expect(searchQueryOverflowStatus(100), '请输入 1–100 字关键词');
    });

    test('empty or overflow predicate', () {
      expect(searchQueryEmptyOrOverflow('', 100), isTrue);
      expect(searchQueryEmptyOrOverflow('   ', 100), isTrue);
      expect(searchQueryEmptyOrOverflow('abc', 100), isFalse);
      expect(searchQueryEmptyOrOverflow(_repeat('a', 100), 100), isFalse);
      expect(searchQueryEmptyOrOverflow(_repeat('a', 101), 100), isTrue);
      // 40 emoji = 40 code points = 80 UTF-16 units: still allowed at limit 60.
      final String emoji40 = _repeat('😀', 40);
      expect(emoji40.length, 80);
      expect(searchQueryLength(emoji40), 40);
      expect(searchQueryEmptyOrOverflow(emoji40, 60), isFalse);
      expect(searchQueryEmptyOrOverflow(_repeat('a', 60), 60), isFalse);
      expect(searchQueryEmptyOrOverflow(_repeat('a', 61), 60), isTrue);
    });
  });

  group('input layer (Overlay.qml:520-566 + Engine.cpp:1006-1012)', () {
    test('visibility for search/saved only', () {
      expect(searchInputVisibleForModal('search'), isTrue);
      expect(searchInputVisibleForModal('saved'), isTrue);
      expect(searchInputVisibleForModal('detail'), isFalse);
      expect(searchInputVisibleForModal(''), isFalse);
    });

    test('hint strings, placeholder == accessibility string', () {
      expect(searchInputHint(localMusic: true), '检索本地歌曲、歌手、专辑或文件夹');
      expect(searchInputHint(localMusic: false), '搜索歌曲、歌手、专辑或歌单');
    });

    test('Enter with control maps to key(Enter, command: true)', () {
      final SearchAcceptedCommand control = searchAccepted('abc', true);
      expect(control.isKey, isTrue);
      expect(control.keyName, 'Enter');
      expect(control.command, isTrue);
      expect(control.query, isNull);
      expect(control.actionString, 'key(Enter, command: true)');
    });

    test('Enter without control maps to query(text)', () {
      final SearchAcceptedCommand plain = searchAccepted('abc', false);
      expect(plain.isKey, isFalse);
      expect(plain.keyName, isNull);
      expect(plain.query, 'abc');
      expect(plain.actionString, 'query(abc)');
    });

    test('Escape closes the modal', () {
      expect(kSearchEscapeAction, 'close-modal');
    });
  });

  group('auto-fill gate (NativeHudSearch.cpp:268-281)', () {
    bool gate({
      String modal = 'search',
      bool closing = false,
      String query = 'abc',
      String keyword = 'abc',
      bool sourceLoading = false,
      bool hasMore = true,
      int rowCount = 6,
      int autoFillSize = 5,
    }) =>
        shouldAutoFillSearch(
          modal: modal,
          closing: closing,
          query: query,
          keyword: keyword,
          sourceLoading: sourceLoading,
          hasMore: hasMore,
          rowCount: rowCount,
          autoFillSize: autoFillSize,
        );

    test('fires only for the search modal, open, matching trimmed query', () {
      expect(gate(), isTrue);
      expect(gate(query: ' abc '), isTrue); // query.trimmed() == keyword
      expect(gate(modal: 'saved'), isFalse);
      expect(gate(closing: true), isFalse);
      expect(gate(query: 'abcd'), isFalse);
      expect(gate(sourceLoading: true), isFalse);
      expect(gate(hasMore: false), isFalse);
      expect(gate(rowCount: 5), isFalse); // count <= m_searchAutoFillSize
      expect(gate(rowCount: 4), isFalse);
    });

    test('needs more while count * 72 < 430', () {
      expect(searchAutoFillNeedsMore(0), isTrue);
      expect(searchAutoFillNeedsMore(5), isTrue); // 360 < 430
      expect(searchAutoFillNeedsMore(6), isFalse); // 432 < 430 is false
      expect(searchAutoFillNeedsMore(7), isFalse);
    });
  });

  group('palette (NativeHudSearch.cpp:20-42)', () {
    test('accent is the Qt gold', () {
      expect(SearchPalette.accentColor, const SearchColor(0.835, 0.639, 0.282, 1));
      expect(_palette.accent, SearchPalette.accentColor);
    });

    test('mutedInk keeps ink rgb and sets alpha 0.55', () {
      expect(_palette.mutedInk, const SearchColor(0.10, 0.11, 0.10, 0.55));
    });

    test('search bar fill dark/light', () {
      expect(_palette.searchBarFill, const SearchColor(0.169, 0.200, 0.173, 1));
      const SearchPalette light = SearchPalette(
        ink: SearchColor(0.10, 0.11, 0.10, 1),
        dark: false,
      );
      expect(
        light.searchBarFill,
        const SearchColor(0.898, 0.906, 0.855, 1),
      );
    });
  });

  group('cross-file SearchColor (W1 palette -> W2 layer)', () {
    test('palette ink feeds the results layer without conversion', () {
      final SearchResultsLayer layer = SearchResultsLayer(
        port: const _NoopResultsPort(),
        originX: 0,
        originY: 122,
        modalWidth: 900,
        rows: const <SearchRow>[],
        scroll: 0,
        lane: 0,
        ink: _palette.ink,
        dark: true,
        localMusic: false,
        emptyMessage: '空',
        query: '',
      );
      expect(layer.ink, _palette.ink);
      // 0.10 * 255 = 25.5 -> 26 (half away from zero), like the HUD renderer.
      expect(layer.ink.toColor(), const Color.fromARGB(255, 26, 28, 26));
    });
  });
}
